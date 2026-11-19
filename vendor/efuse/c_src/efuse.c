// Author: Michael Wright <mjw@methodanalysis.com>
// Copyright 2015 Michael Wright <mjw@methodanalysis.com>
//
// This file is part of the Erlang FUSE (Filesystem in Userspace)
// interface called 'efuse'.
//
// 'efuse' is free software, licensed under the MIT license.
//
// Modified for supablock (https://github.com/filipecabaco/supablock):
//   - supports both the libfuse3 API (31, Linux default) and the libfuse
//     2.9 API (26) — the latter is what macFUSE and FUSE-T implement on
//     macOS; the Makefile picks whichever is available
//   - multithreaded FUSE loop: every request carries an id, so callbacks
//     run concurrently and one slow request (a big table page, a slow API)
//     no longer blocks every other `ls`/`cat` on the mount. A reader thread
//     owns the reply pipe and hands each reply to the callback waiting on
//     its id; writes to Erlang are serialised so frames never interleave
//   - mounted read-only (-o ro) with attr/entry timeouts, so the kernel
//     rejects every write with EROFS before it reaches this process
//   - replies are heap buffers sized to the reply (bounded by BUFFER_MAX);
//     the original fixed 20KiB buffer could overflow
//   - error codes returned by the Erlang side are passed through to the
//     kernel instead of always becoming ENOENT
//   - read requests carry offset and size, so only the requested chunk
//     crosses the pipe (it used to be the whole file on every read)
//   - an `open` request lets the Erlang side ask for direct I/O on files
//     whose size is not known up front (they report st_size 0 and are read
//     until EOF, like /proc)
//   - when the Erlang VM goes away (EOF on the port pipe) the reader thread
//     fails every pending call, unmounts and ends the loop, so a dead BEAM
//     never leaves a stale mount behind
//
// Wire format (all integers 32 bit big endian unless noted):
//   request  = len, cookie, reqcode, reqid, [args], path
//   reply    = len, cookie, reqcode, reqid, result, [data]
// where `len` counts everything after itself. READ args are offset (64
// bit) and size; the other requests have none.


// This port provides an interface between Erlang and FUSE. It works
// by registering appropriate callbacks for handing file system
// functions, each of which sends the request on to the Erlang process
// that started the port. The Erlang process must respond appropriately
// and the port, upon receiving the response, provides it to FUSE.
//
// Not all the possible FUSE callbacks are implemented.


#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <syslog.h>

#ifdef SUPABLOCK_FUSE2
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <fuse_lowlevel.h>
#else
#define FUSE_USE_VERSION 31
#include <fuse.h>
#include <fuse_lowlevel.h>
#endif

#include <errno.h>
#include <fcntl.h>


#include "efuse_defs.h"


// Requests are tiny (a path); replies are bounded so one runaway body
// cannot exhaust memory. A reply the Erlang side never sends (it has its
// own 60s fetch deadline) fails the call after REPLY_TIMEOUT_S.
#define BUFFER_MAX (64 * 1024 * 1024)
#define REQ_BUFFER_SIZE 8192
#define REPLY_TIMEOUT_S 120

#define PORT_IN 3
#define PORT_OUT 4


#ifdef SUPABLOCK_FUSE2
static int fusecb_getattr(const char *, struct stat *);
static int fusecb_readdir(const char *, void *, fuse_fill_dir_t, off_t,
		struct fuse_file_info *);
#else
static int fusecb_getattr(const char *, struct stat *, struct fuse_file_info *);
static int fusecb_readdir(const char *, void *, fuse_fill_dir_t, off_t,
		struct fuse_file_info *, enum fuse_readdir_flags);
#endif
static int fusecb_open(const char *, struct fuse_file_info *);
static int fusecb_read(const char *, char *, size_t, off_t, struct fuse_file_info *);
static int fusecb_readlink(const char * path, char * buf, size_t);


static struct fuse_operations efuse_oper = {
	.getattr  = fusecb_getattr,
	.readlink = fusecb_readlink,
	.readdir  = fusecb_readdir,
	.open     = fusecb_open,
	.read     = fusecb_read,
};


static struct fuse * global_fuse = NULL;
static char * global_mountpoint = NULL;
static atomic_flag unmounted = ATOMIC_FLAG_INIT;

#ifdef SUPABLOCK_FUSE2
static struct fuse_chan * global_chan = NULL;
#endif


// ---------------------------------------------------------------------
// Pending calls: one per FUSE callback waiting for its reply.

struct pending {
	uint32_t id;
	int done;               // reply (or failure) delivered
	int err;                // negative errno when the call failed in transit
	unsigned char * buf;    // reply from reqcode on (malloc'd), when !err
	uint32_t len;
	pthread_cond_t cond;
	struct pending * next;
};

static pthread_mutex_t pending_mu = PTHREAD_MUTEX_INITIALIZER;
static struct pending * pending_head = NULL;
static uint32_t next_reqid = 1;
static int port_closed = 0;

static pthread_mutex_t write_mu = PTHREAD_MUTEX_INITIALIZER;


static void pending_unlink(struct pending * p) {
	for (struct pending ** at = &pending_head; *at != NULL; at = &(*at)->next) {
		if (*at == p) {
			*at = p->next;
			return;
		}
	}
}

static struct pending * pending_take(uint32_t id) {
	for (struct pending ** at = &pending_head; *at != NULL; at = &(*at)->next) {
		if ((*at)->id == id) {
			struct pending * p = *at;
			*at = p->next;
			return p;
		}
	}
	return NULL;
}


// ---------------------------------------------------------------------
// Pipe I/O.

static int write_all(int fd, const unsigned char * data, size_t len) {
	while (len > 0) {
		ssize_t n = write(fd, data, len);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		data += n;
		len -= (size_t) n;
	}
	return 0;
}

static int read_all(int fd, unsigned char * data, size_t len) {
	while (len > 0) {
		ssize_t n = read(fd, data, len);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		data += n;
		len -= (size_t) n;
	}
	return 0;
}

static int discard(int fd, size_t len) {
	unsigned char sink[65536];
	while (len > 0) {
		size_t want = len < sizeof(sink) ? len : sizeof(sink);
		if (read_all(fd, sink, want) != 0)
			return -1;
		len -= want;
	}
	return 0;
}

static void put32(unsigned char * at, uint32_t value) {
	uint32_t be = htonl(value);
	memcpy(at, &be, 4);
}

static uint32_t get32(const unsigned char * at) {
	uint32_t be;
	memcpy(&be, at, 4);
	return ntohl(be);
}

// Send one frame (length header, cookie, payload) as a single write under
// the write lock: concurrent callbacks must never interleave their bytes.
static int send_frame(const unsigned char * payload, size_t len) {
	unsigned char frame[8 + REQ_BUFFER_SIZE + 16];
	if (len > sizeof(frame) - 8)
		return -1;
	put32(frame, (uint32_t) (len + 4));
	put32(frame + 4, EFUSE_MAGICCOOKIE);
	memcpy(frame + 8, payload, len);

	pthread_mutex_lock(&write_mu);
	int rc = write_all(PORT_OUT, frame, len + 8);
	pthread_mutex_unlock(&write_mu);
	return rc;
}


// ---------------------------------------------------------------------
// Unmount and shutdown.

// Unmount exactly once, whichever thread gets here first. With the 2.9 API
// fuse_unmount() destroys the channel, so a second call would be a
// use-after-free; with fuse3 it is merely redundant.
static void unmount_once(void) {

	if (atomic_flag_test_and_set(&unmounted))
		return;

#ifdef SUPABLOCK_FUSE2
	fuse_unmount(global_mountpoint, global_chan);
#else
	fuse_unmount(global_fuse);
#endif

}

// The Erlang VM went away: fail every waiting call, then end the session
// and unmount. Unmounting wakes the loop's blocked /dev/fuse reads (ENODEV),
// so it exits promptly even when no FS operation ever arrives again.
static void port_gone(void) {

	pthread_mutex_lock(&pending_mu);
	port_closed = 1;
	for (struct pending * p = pending_head; p != NULL; p = p->next) {
		p->done = 1;
		p->err = -EIO;
		pthread_cond_signal(&p->cond);
	}
	pending_head = NULL;
	pthread_mutex_unlock(&pending_mu);

	syslog(LOG_NOTICE, "efuse[%d]: erlang VM went away, unmounting", getpid());
	if (global_fuse != NULL) {
		fuse_session_exit(fuse_get_session(global_fuse));
		unmount_once();
	}

}

// Deliver one reply (or a transit failure) to the call waiting on `id`. A
// reply nobody waits for any more (that call timed out) is dropped.
static void deliver(uint32_t id, unsigned char * buf, uint32_t len, int err) {

	pthread_mutex_lock(&pending_mu);
	struct pending * p = pending_take(id);
	if (p != NULL) {
		p->buf = buf;
		p->len = len;
		p->err = err;
		p->done = 1;
		pthread_cond_signal(&p->cond);
	}
	pthread_mutex_unlock(&pending_mu);

	if (p == NULL) {
		syslog(LOG_INFO, "efuse[%d]: dropping late reply %u", getpid(), id);
		free(buf);
	}

}


// ---------------------------------------------------------------------
// The reader thread: the only reader of the reply pipe.

static void * erlang_reader(void * arg) {

	(void) arg;

	for (;;) {
		unsigned char head[8];
		if (read_all(PORT_IN, head, 8) != 0)
			break;

		uint32_t len = get32(head);
		if (get32(head + 4) != EFUSE_MAGICCOOKIE) {
			syslog(LOG_CRIT, "efuse[%d]: read: invalid magic cookie", getpid());
			exit(1);
		}
		if (len < 4) {
			syslog(LOG_CRIT, "efuse[%d]: read: reply length %u shorter than the cookie",
					getpid(), len);
			exit(1);
		}
		len -= 4;

		// Without reqcode and id there is nobody to deliver to: skip it.
		if (len < 8) {
			syslog(LOG_ERR, "efuse[%d]: read: %u byte reply has no request id", getpid(), len);
			if (discard(PORT_IN, len) != 0)
				break;
			continue;
		}

		unsigned char ids[8];
		if (read_all(PORT_IN, ids, 8) != 0)
			break;
		uint32_t id = get32(ids + 4);
		uint32_t rest = len - 8;

		// One oversized reply fails that one call (EIO), not the mount: drain
		// its bytes so the stream stays framed.
		if (len > BUFFER_MAX) {
			syslog(LOG_ERR, "efuse[%d]: read: reply of %u bytes exceeds limit, discarding",
					getpid(), len);
			if (discard(PORT_IN, rest) != 0)
				break;
			deliver(id, NULL, 0, -EIO);
			continue;
		}

		unsigned char * buf = malloc(len > 0 ? len : 1);
		if (buf == NULL) {
			syslog(LOG_CRIT, "efuse[%d]: read: out of memory for %u byte reply", getpid(), len);
			exit(1);
		}
		memcpy(buf, ids, 8);
		if (read_all(PORT_IN, buf + 8, rest) != 0) {
			free(buf);
			break;
		}

		deliver(id, buf, len, 0);
	}

	port_gone();
	return NULL;

}


// ---------------------------------------------------------------------
// One request/reply exchange, safe to run from many FUSE threads at once.
//
// Sends reqcode, a fresh id, `args` and `path`, then waits for the reply
// carrying that id. On success returns the reply length and sets *out to
// the reply (reqcode, id, result, data...), which the caller frees; data
// starts at byte 12. Otherwise returns a negative errno for FUSE.

static int erlang_call(unsigned int reqcode, const unsigned char * args,
		size_t argslen, const char * path, const char * what, unsigned char ** out) {

	*out = NULL;
	size_t pathlen = strlen(path);
	if (pathlen + argslen + 8 > REQ_BUFFER_SIZE)
		return -ENAMETOOLONG;

	struct pending p = { .done = 0, .err = 0, .buf = NULL, .len = 0, .next = NULL };
	pthread_cond_init(&p.cond, NULL);

	pthread_mutex_lock(&pending_mu);
	if (port_closed) {
		pthread_mutex_unlock(&pending_mu);
		pthread_cond_destroy(&p.cond);
		return -EIO;
	}
	p.id = next_reqid++;
	if (next_reqid == 0)
		next_reqid = 1;
	p.next = pending_head;
	pending_head = &p;
	pthread_mutex_unlock(&pending_mu);

	unsigned char req[REQ_BUFFER_SIZE];
	put32(req, reqcode);
	put32(req + 4, p.id);
	if (argslen > 0)
		memcpy(req + 8, args, argslen);
	memcpy(req + 8 + argslen, path, pathlen);

	if (send_frame(req, 8 + argslen + pathlen) != 0) {
		pthread_mutex_lock(&pending_mu);
		if (!p.done)
			pending_unlink(&p);
		pthread_mutex_unlock(&pending_mu);
		free(p.buf);
		pthread_cond_destroy(&p.cond);
		syslog(LOG_ERR, "efuse[%d]: could not send %s %s", getpid(), what, path);
		return -EIO;
	}

	struct timespec deadline;
	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += REPLY_TIMEOUT_S;

	pthread_mutex_lock(&pending_mu);
	while (!p.done) {
		if (pthread_cond_timedwait(&p.cond, &pending_mu, &deadline) == ETIMEDOUT && !p.done) {
			pending_unlink(&p);
			p.done = 1;
			p.err = -EIO;
			syslog(LOG_ERR, "efuse[%d]: no response in %ds from FS implementation (%s %s)",
					getpid(), REPLY_TIMEOUT_S, what, path);
		}
	}
	pthread_mutex_unlock(&pending_mu);
	pthread_cond_destroy(&p.cond);

	if (p.err != 0) {
		free(p.buf);
		return p.err;
	}

	if (p.len < 12) {
		syslog(LOG_ERR, "efuse[%d]: short response from FS implementation (%s %s)",
				getpid(), what, path);
		free(p.buf);
		return -EIO;
	}

	unsigned int replycode = get32(p.buf);
	if (replycode != reqcode) {
		syslog(LOG_ERR,
				"efuse[%d]: unexpected response %u (expected %u) from FS implementation (%s %s)",
				getpid(), replycode, reqcode, what, path);
		free(p.buf);
		return -EIO;
	}

	// a non-zero result is an errno; pass it through to the kernel
	unsigned int result = get32(p.buf + 8);
	if (result != 0) {
		syslog(LOG_INFO,
				"efuse[%d]: response result code %u (error) from FS implementation (%s %s)",
				getpid(), result, what, path);
		free(p.buf);
		return result < 4096 ? -((int) result) : -EIO;
	}

	*out = p.buf;
	return (int) p.len;

}


// ---------------------------------------------------------------------
// Port entry. Mount read-only and run the multithreaded FUSE loop in the
// foreground. The mount point is the last argument (the Erlang side passes
// exactly one argument).

int main (int argc, char ** argv) {

	if (argc < 2) {
		syslog(LOG_ERR, "efuse[%d]: no mount point given", getpid());
		exit(1);
	}
	global_mountpoint = argv[argc-1];

	// report my PID back to Erlang
	unsigned char hello[8];
	put32(hello, EFUSE_STATUS_DATA);
	put32(hello + 4, (uint32_t) getpid());
	if (send_frame(hello, sizeof(hello)) != 0) {
		syslog(
			LOG_ERR,
			"efuse[%d]: failure initialising (error writing pid to erlang VM)",
			getpid()
			);
		exit(1);
	}

	char * fuse_argv[] = { argv[0], "-o", "ro,attr_timeout=5,entry_timeout=5" };
	struct fuse_args args = FUSE_ARGS_INIT(3, fuse_argv);

#ifdef SUPABLOCK_FUSE2
	global_chan = fuse_mount(global_mountpoint, &args);
	if (global_chan == NULL) {
		syslog(LOG_ERR, "efuse[%d]: fuse mount %s failed", getpid(), global_mountpoint);
		exit(1);
	}

	global_fuse = fuse_new(global_chan, &args, &efuse_oper, sizeof(efuse_oper), NULL);
	if (global_fuse == NULL) {
		syslog(LOG_ERR, "efuse[%d]: fuse_new failed", getpid());
		fuse_unmount(global_mountpoint, global_chan);
		exit(1);
	}
#else
	global_fuse = fuse_new(&args, &efuse_oper, sizeof(efuse_oper), NULL);
	if (global_fuse == NULL) {
		syslog(LOG_ERR, "efuse[%d]: fuse_new failed", getpid());
		exit(1);
	}

	if (fuse_mount(global_fuse, global_mountpoint) != 0) {
		syslog(LOG_ERR, "efuse[%d]: fuse mount %s failed", getpid(), global_mountpoint);
		exit(1);
	}
#endif

	// SIGTERM/SIGINT/SIGHUP end the loop cleanly (libfuse handlers). Keep
	// those signals blocked in the reader thread (libfuse blocks them in its
	// own workers) so a process-directed signal always reaches the main
	// thread waiting in the loop.
	fuse_set_signal_handlers(fuse_get_session(global_fuse));

	sigset_t sigs;
	sigemptyset(&sigs);
	sigaddset(&sigs, SIGTERM);
	sigaddset(&sigs, SIGINT);
	sigaddset(&sigs, SIGHUP);
	pthread_sigmask(SIG_BLOCK, &sigs, NULL);

	pthread_t reader;
	pthread_create(&reader, NULL, erlang_reader, NULL);

	pthread_sigmask(SIG_UNBLOCK, &sigs, NULL);

	syslog(LOG_NOTICE, "efuse[%d]: fuse mount %s", getpid(), global_mountpoint);
#ifdef SUPABLOCK_FUSE2
	int rc = fuse_loop_mt(global_fuse);
#else
	int rc = fuse_loop_mt(global_fuse, 0);
#endif
	syslog(LOG_NOTICE, "efuse[%d]: fuse umount %s (rc %d)", getpid(), global_mountpoint, rc);

	fuse_remove_signal_handlers(fuse_get_session(global_fuse));
	unmount_once();
	fuse_destroy(global_fuse);

	exit(0);

}


// ---------------------------------------------------------------------
// FUSE callbacks.

#ifdef SUPABLOCK_FUSE2
static int fusecb_getattr(
		const char * path,
		struct stat * stbuf) {
#else
static int fusecb_getattr(
		const char * path,
		struct stat * stbuf,
		struct fuse_file_info * fi) {

	(void) fi;
#endif

	unsigned char * reply;
	int replylen = erlang_call(EFUSE_REQUEST_GETATTR, NULL, 0, path, "getattr", &reply);
	if (replylen < 0)
		return replylen;
	if (replylen < 24) {
		free(reply);
		return -EIO;
	}

	unsigned int mode = get32(reply + 12);
	unsigned int type = get32(reply + 16);
	unsigned int size = get32(reply + 20);
	free(reply);

	memset(stbuf, 0, sizeof(struct stat));
	stbuf->st_mode = mode | (
			type == EFUSE_ATTR_DIR ?
				S_IFDIR :
			type == EFUSE_ATTR_FILE ?
				S_IFREG :
			type == EFUSE_ATTR_SYMLINK ?
				S_IFLNK :
			0);
	stbuf->st_nlink = type == EFUSE_ATTR_DIR ? 2 : 1;
	stbuf->st_size = size;

	return 0;

}


#ifdef SUPABLOCK_FUSE2
#define EFUSE_FILL(buf, name) filler(buf, name, NULL, 0)
static int fusecb_readdir(
		const char *path,
		void *buf,
		fuse_fill_dir_t filler,
		off_t offset,
		struct fuse_file_info *fi) {

	(void) offset;
	(void) fi;
#else
#define EFUSE_FILL(buf, name) filler(buf, name, NULL, 0, 0)
static int fusecb_readdir(
		const char *path,
		void *buf,
		fuse_fill_dir_t filler,
		off_t offset,
		struct fuse_file_info *fi,
		enum fuse_readdir_flags flags) {

	(void) offset;
	(void) fi;
	(void) flags;
#endif

	unsigned char * reply;
	int replylen = erlang_call(EFUSE_REQUEST_READDIR, NULL, 0, path, "readdir", &reply);
	if (replylen < 0)
		return replylen;

	// NUL-separated names; never read past the reply even if the last one
	// is unterminated.
	EFUSE_FILL(buf, ".");
	EFUSE_FILL(buf, "..");
	int i = 12;
	while (i < replylen) {
		size_t namelen = strnlen((char *) reply + i, (size_t) (replylen - i));
		if (i + (int) namelen >= replylen)
			break;
		EFUSE_FILL(buf, (char *) reply + i);
		i += (int) namelen + 1;
	}

	free(reply);
	return 0;

}


// Ask whether this file wants direct I/O: one whose size is not known up
// front reports st_size 0 and must be read until EOF, which the kernel only
// does when the page cache (bounded by st_size) is bypassed.
static int fusecb_open(const char * path, struct fuse_file_info * fi) {

	unsigned char * reply;
	int replylen = erlang_call(EFUSE_REQUEST_OPEN, NULL, 0, path, "open", &reply);
	if (replylen < 0)
		return replylen;

	unsigned int flags = replylen >= 16 ? get32(reply + 12) : 0;
	free(reply);

	if (flags & EFUSE_OPEN_DIRECT_IO)
		fi->direct_io = 1;

	return 0;

}


static int fusecb_read(
		const char *            path,
		char *                  buf,
		size_t                  size,
		off_t                   offset,
		struct fuse_file_info * fi) {

	(void) fi;

	if (offset < 0)
		return -EINVAL;

	// The request carries offset (64 bit) and size (32 bit), so the Erlang
	// side returns only this chunk: a large file no longer crosses the pipe
	// once per kernel read, and no reply exceeds `size`.
	uint64_t off = (uint64_t) offset;
	uint32_t want = size > UINT32_MAX ? UINT32_MAX : (uint32_t) size;
	unsigned char args[12];
	put32(args, (uint32_t) (off >> 32));
	put32(args + 4, (uint32_t) (off & 0xffffffffu));
	put32(args + 8, want);

	unsigned char * reply;
	int replylen = erlang_call(EFUSE_REQUEST_READ, args, sizeof(args), path, "read", &reply);
	if (replylen < 0)
		return replylen;

	// the reply is the chunk itself; clamp defensively to the buffer
	size_t datalen = (size_t) (replylen - 12);
	if (datalen > size)
		datalen = size;
	memcpy(buf, reply + 12, datalen);
	free(reply);
	return (int) datalen;

}


static int fusecb_readlink(
		const char * path,
		char       * buf,
		size_t     size
		) {

	unsigned char * reply;
	int replylen = erlang_call(EFUSE_REQUEST_READLINK, NULL, 0, path, "readlink", &reply);
	if (replylen < 0)
		return replylen;

	// pass data in response back to FUSE (NUL terminated by the Erlang side)
	size_t destlen = strnlen((char *) reply + 12, (size_t) (replylen - 12));
	if (destlen >= size)
		destlen = size - 1;
	memcpy(buf, reply + 12, destlen);
	buf[destlen] = '\0';
	free(reply);

	return 0;

}
