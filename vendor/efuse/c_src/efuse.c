// Author: Michael Wright <mjw@methodanalysis.com>
// Copyright 2015 Michael Wright <mjw@methodanalysis.com>
//
// This file is part of the Erlang FUSE (Filesystem in Userspace)
// interface called 'efuse'.
//
// 'efuse' is free software, licensed under the MIT license.
//
// Modified for superblock (https://github.com/filipecabaco/supablock):
//   - ported from libfuse2 (FUSE_USE_VERSION 26) to libfuse3 (31)
//   - forced single-threaded FUSE loop; the port protocol below is a
//     single synchronous conversation and is not thread safe
//   - mounted read-only (-o ro) with attr/entry timeouts, so the kernel
//     rejects every write with EROFS before it reaches this process
//   - replaced the fixed 20KiB reply buffer (which could overflow) with
//     a growable bounded buffer
//   - error codes returned by the Erlang side are passed through to the
//     kernel instead of always becoming ENOENT
//   - a watchdog thread unmounts and exits when the Erlang VM goes away
//     (EOF/HUP on the port pipe), so a dead BEAM never leaves a stale
//     mount behind


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
#include <poll.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <syslog.h>

#define FUSE_USE_VERSION 31

#include <fuse.h>
#include <fuse_lowlevel.h>
#include <errno.h>
#include <fcntl.h>


#include "efuse_defs.h"


// Replies are staged in a growable buffer; requests are tiny (a path).
#define BUFFER_INITIAL (64 * 1024)
#define BUFFER_MAX (64 * 1024 * 1024)
#define REQ_BUFFER_SIZE 8192

static unsigned char reqmsg[REQ_BUFFER_SIZE];
static unsigned char * erlmsg = NULL;
static size_t erlmsg_size = 0;


static int fusecb_getattr(const char *, struct stat *, struct fuse_file_info *);
static int fusecb_readdir(const char *, void *, fuse_fill_dir_t, off_t,
		struct fuse_file_info *, enum fuse_readdir_flags);
static int fusecb_read(const char *, char *, size_t, off_t, struct fuse_file_info *);
static int fusecb_readlink(const char * path, char * buf, size_t);

int read_from_erlang(void);
int write_to_erlang(const unsigned int, const unsigned char *);


static struct fuse_operations efuse_oper = {
	.getattr  = fusecb_getattr,
	.readlink = fusecb_readlink,
	.readdir  = fusecb_readdir,
	.read     = fusecb_read,
};


static struct fuse * global_fuse = NULL;


// Watch the pipe from the Erlang VM; if it goes away (EOF/HUP) the VM died
// or closed the port, so end the session and unmount. fuse_unmount() from
// this thread wakes the main thread's blocked /dev/fuse read (ENODEV), so
// the loop exits promptly even when no FS operation ever arrives again.

static void * erlang_watchdog(void * arg) {

	(void) arg;
	struct pollfd pfd = { .fd = 3, .events = 0 };

	for (;;) {
		int rc = poll(&pfd, 1, -1);
		if (rc > 0 && (pfd.revents & (POLLHUP | POLLERR | POLLNVAL))) {
			syslog(LOG_NOTICE, "efuse[%d]: erlang VM went away, unmounting", getpid());
			if (global_fuse != NULL) {
				fuse_session_exit(fuse_get_session(global_fuse));
				fuse_unmount(global_fuse);
			}
			return NULL;
		}
		if (rc < 0 && errno != EINTR)
			return NULL;
	}

}


// Port entry. Mount read-only and run the single-threaded FUSE loop in the
// foreground. The mount point is the last argument (the Erlang side passes
// exactly one argument).

int main (int argc, char ** argv) {

	if (argc < 2) {
		syslog(LOG_ERR, "efuse[%d]: no mount point given", getpid());
		exit(1);
	}
	char * mountpoint = argv[argc-1];

	erlmsg_size = BUFFER_INITIAL;
	if ((erlmsg = malloc(erlmsg_size)) == NULL) {
		syslog(LOG_ERR, "efuse[%d]: failure initialising (out of memory)", getpid());
		exit(1);
	}

	// report my PID back to Erlang
	((uint32_t*)erlmsg)[0] = htonl(EFUSE_STATUS_DATA);
	((uint32_t*)erlmsg)[1] = htonl(getpid());
	if (write_to_erlang(8, erlmsg) != 8) {
		syslog(
			LOG_ERR,
			"efuse[%d]: failure initialising (error writing pid to erlang VM)",
			getpid()
			);
		exit(1);
	}

	char * fuse_argv[] = { argv[0], "-o", "ro,attr_timeout=5,entry_timeout=5" };
	struct fuse_args args = FUSE_ARGS_INIT(3, fuse_argv);

	global_fuse = fuse_new(&args, &efuse_oper, sizeof(efuse_oper), NULL);
	if (global_fuse == NULL) {
		syslog(LOG_ERR, "efuse[%d]: fuse_new failed", getpid());
		exit(1);
	}

	if (fuse_mount(global_fuse, mountpoint) != 0) {
		syslog(LOG_ERR, "efuse[%d]: fuse mount %s failed", getpid(), mountpoint);
		exit(1);
	}

	// SIGTERM/SIGINT/SIGHUP end the loop cleanly (libfuse handlers). Keep
	// those signals blocked in the watchdog thread so a process-directed
	// signal always interrupts the main thread's /dev/fuse read.
	fuse_set_signal_handlers(fuse_get_session(global_fuse));

	sigset_t sigs;
	sigemptyset(&sigs);
	sigaddset(&sigs, SIGTERM);
	sigaddset(&sigs, SIGINT);
	sigaddset(&sigs, SIGHUP);
	pthread_sigmask(SIG_BLOCK, &sigs, NULL);

	pthread_t watchdog;
	pthread_create(&watchdog, NULL, erlang_watchdog, NULL);

	pthread_sigmask(SIG_UNBLOCK, &sigs, NULL);

	syslog(LOG_NOTICE, "efuse[%d]: fuse mount %s", getpid(), mountpoint);
	int rc = fuse_loop(global_fuse);
	syslog(LOG_NOTICE, "efuse[%d]: fuse umount %s (rc %d)", getpid(), mountpoint, rc);

	fuse_remove_signal_handlers(fuse_get_session(global_fuse));
	fuse_unmount(global_fuse);
	fuse_destroy(global_fuse);

	exit(0);

}


// Write data to Erlang, with a 32 bit header declaring the length of
// the data (excluding the header).

int write_to_erlang(
		const unsigned int datalen,
		const unsigned char * data) {

	int writelen;

	uint32_t dataheader = htonl(datalen + sizeof(uint32_t));
	if ((writelen = write(4, (unsigned char *) &dataheader, 4)) != 4) {
		syslog(LOG_WARNING, "efuse[%d]: write: port error writing data header (wrote %d)",
				getpid(), writelen);
		return -1;
	}

	uint32_t magiccookie1 = htonl(EFUSE_MAGICCOOKIE);
	if ((writelen = write(4, (unsigned char *) &magiccookie1, 4)) != 4) {
		syslog(LOG_CRIT, "efuse[%d]: write: port error writing magic cookie 1 (wrote %d)",
				getpid(), writelen);
		exit(1);
	}

	if (datalen > 0) {
		int writelen;
		if ((writelen = write(4, data, datalen)) != datalen) {
			syslog(LOG_WARNING, "efuse[%d]: write: port error writing data (wrote %d)",
					getpid(), writelen);
			return -1;
		}
	}

	return datalen;

}


// Read data from Erlang, formed of a 32 bit header declaring the length
// of the data (after the header). The reply lands in the growable
// erlmsg buffer; returns the data length or -1 on error.

int read_from_erlang(void) {

	uint32_t datalen;

	int readlen;
	if ((readlen = read(3, (unsigned char *) &datalen, 4)) != 4) {
		syslog(LOG_WARNING, "efuse[%d]: read: port error reading data header (read %d)",
				getpid(), readlen);
		return -1;
	}
	datalen = ntohl(datalen);

	uint32_t magiccookie1;
	if ((readlen = read(3, (unsigned char *) &magiccookie1, 4)) != 4) {
		syslog(LOG_CRIT, "efuse[%d]: read: port error reading data header (read %d)",
			getpid(), readlen);
		exit(1);
	}
	magiccookie1 = ntohl(magiccookie1);
	if (magiccookie1 != EFUSE_MAGICCOOKIE) {
		syslog(LOG_CRIT, "efuse[%d]: read: port read invalid magic cookie %u",
				getpid(), magiccookie1);
		exit(1);
	}
	datalen -= sizeof(uint32_t);

	if (datalen > BUFFER_MAX) {
		syslog(LOG_CRIT, "efuse[%d]: read: reply of %u bytes exceeds limit",
				getpid(), datalen);
		exit(1);
	}
	if (datalen > erlmsg_size) {
		size_t newsize = erlmsg_size;
		while (newsize < datalen)
			newsize *= 2;
		unsigned char * newbuf = realloc(erlmsg, newsize);
		if (newbuf == NULL) {
			syslog(LOG_CRIT, "efuse[%d]: read: out of memory for %u byte reply",
					getpid(), datalen);
			exit(1);
		}
		erlmsg = newbuf;
		erlmsg_size = newsize;
	}

	uint32_t readtotal = 0;
	while (readtotal < datalen) {
		readlen = read(3, erlmsg+readtotal, datalen-readtotal);
		if (readlen <= 0) {
			syslog(LOG_ERR, "efuse[%d]: read: port read %d (expected %d)",
					getpid(), readtotal, datalen);
			return -1;
		}
		readtotal += readlen;
		if (readtotal < datalen)
			syslog(LOG_WARNING, "efuse[%d]: read: port short read (%d of %d)",
					getpid(), readtotal, datalen);
	}

	return datalen;

}


// Send a request (a code plus the path) to Erlang and read the reply
// into erlmsg, validating the reply code. Returns the reply length, or
// a negative errno suitable for returning to FUSE.

static int erlang_roundtrip(unsigned int reqcode, const char * path, const char * what) {

	size_t pathlen = strlen(path);
	if (pathlen + 4 > REQ_BUFFER_SIZE)
		return -ENAMETOOLONG;

	((uint32_t*)reqmsg)[0] = htonl(reqcode);
	memcpy((char *) reqmsg+4, path, pathlen);
	write_to_erlang(pathlen+4, reqmsg);

	int replylen;
	if ((replylen = read_from_erlang()) < 0) {
		syslog(LOG_ERR, "efuse[%d]: no response from FS implementation (%s %s)",
				getpid(), what, path);
		return -EIO;
	}
	if (replylen < 8) {
		syslog(LOG_ERR, "efuse[%d]: short response from FS implementation (%s %s)",
				getpid(), what, path);
		return -EIO;
	}

	// check response correct code
	unsigned int replycode = ntohl(((uint32_t*)erlmsg)[0]);
	if (replycode != reqcode) {
		syslog(LOG_ERR,
				"efuse[%d]: unexpected response %d (expected %d) from FS implementation (%s %s)",
				getpid(), replycode, reqcode, what, path);
		return -EIO;
	}

	// check response not an error; pass the errno through to the kernel
	unsigned int replyresult = ntohl(((uint32_t*)erlmsg)[1]);
	if (replyresult != 0) {
		syslog(LOG_INFO,
				"efuse[%d]: response result code %d (error) from FS implementation (%s %s)",
				getpid(), replyresult, what, path);
		return replyresult < 4096 ? -((int) replyresult) : -EIO;
	}

	return replylen;

}


// Implement the 'getattr' FUSE callback.

static int fusecb_getattr(
		const char * path,
		struct stat * stbuf,
		struct fuse_file_info * fi) {

	(void) fi;

	int replylen = erlang_roundtrip(EFUSE_REQUEST_GETATTR, path, "getattr");
	if (replylen < 0)
		return replylen;
	if (replylen < 20)
		return -EIO;

	// pass data in response back to FUSE
	unsigned int mode = ntohl(((uint32_t*)erlmsg)[2]);
	unsigned int type = ntohl(((uint32_t*)erlmsg)[3]);
	unsigned int size = ntohl(((uint32_t*)erlmsg)[4]);
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


// Implement the 'readdir' FUSE callback.

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

	int replylen = erlang_roundtrip(EFUSE_REQUEST_READDIR, path, "readdir");
	if (replylen < 0)
		return replylen;

	// pass data in response back to FUSE
	filler(buf, ".", NULL, 0, 0);
	filler(buf, "..", NULL, 0, 0);
	for (int i = 8; i < replylen; i += strlen((char *) erlmsg+i)+1) {
		filler(buf, (char *) erlmsg+i, NULL, 0, 0);
	}

	return 0;

}


// Implement the 'read' FUSE callback.

static int fusecb_read(
		const char *            path,
		char *                  buf,
		size_t                  size,
		off_t                   offset,
		struct fuse_file_info * fi) {

	(void) fi;

	int replylen = erlang_roundtrip(EFUSE_REQUEST_READ, path, "read");
	if (replylen < 0)
		return replylen;

	// pass data in response back to FUSE, clamped to what is available
	replylen -= 8;
	if (offset < replylen) {
		size_t returneddatalen =
			(size_t) replylen - offset < size
			? (size_t) replylen - offset
			: size;
		memcpy(buf, ((char *) erlmsg+8) + offset, returneddatalen);
		return returneddatalen;
	} else {
		return 0;
	}

}


// Implement the 'readlink' FUSE callback.

static int fusecb_readlink(
		const char * path,
		char       * buf,
		size_t     size
		) {

	int replylen = erlang_roundtrip(EFUSE_REQUEST_READLINK, path, "readlink");
	if (replylen < 0)
		return replylen;

	// pass data in response back to FUSE (NUL terminated by the Erlang side)
	size_t destlen = strlen((char *) erlmsg+8);
	if (destlen >= size)
		destlen = size - 1;
	memcpy(buf, (char *) erlmsg+8, destlen);
	buf[destlen] = '\0';

	return 0;

}
