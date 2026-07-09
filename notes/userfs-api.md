# elixir-userfs / erlang-efuse — verified API notes

Findings from reading the upstream sources (github.com/mwri/elixir-userfs,
github.com/mwri/erlang-efuse), recorded per the spec's VERIFY step, plus the
patches this project applies to its vendored copies.

## Behaviour contract (`Userfs.Fs`)

Five callbacks; the FS is inherently **read-only** — the behaviour defines no
mutating callbacks at all:

| Callback | Args | Success return | Error return |
|---|---|---|---|
| `userfs_init/2` | mount_point, opts | `{:ok, state}` | `{:error, reason}` |
| `userfs_readdir/2` | state, path | `{:ok, [name], state}` | `{:error, errno, state}` |
| `userfs_getattr/2` | state, path | `{:ok, {mode, type, size}, state}` | `{:error, errno, state}` |
| `userfs_readlink/2` | state, path | `{:ok, dest, state}` | `{:error, errno, state}` |
| `userfs_read/2` | state, path | `{:ok, whole_body, state}` | `{:error, errno, state}` |

* `type` is `@attr_dir` (1), `@attr_file` (2) or `@attr_symlink` (3);
  attributes come from `use Userfs.Fs`.
* `userfs_read/2` has **no size/offset** — the callback returns the whole
  body and the C port slices per kernel read. Bodies must therefore be cached
  on the Elixir side (superblock serves them from ETS).
* `errno` is a plain integer, passed through the port.

## Mount / unmount API

* `Userfs.mount(mount_point, fs_mod, fs_opts)` → `{:ok, pid}` — starts a
  `Userfs.Server` (GenServer) under `Userfs.MountSup`, which opens the efuse
  port (`priv/efuse`, compiled C).
* `Userfs.umount(mount_point)` → `{:ok, pid} | {:error, :not_mounted}`.
* `Userfs.list()` → `[{pid, {mount_point, fs_mod, fs_state, os_pid}}]`.
* No mount options are exposed (no read-only flag, no attr timeouts) — those
  are handled in the vendored C port instead (see below).

## Port protocol

4-byte-length packets, each `<<magic_cookie::32, payload::binary>>`
(cookie `3223410092`). Requests C→Erlang: `<<code::32, path::binary>>` with
codes readdir=3, getattr=4, readlink=5, read=6; replies Erlang→C:
`<<code::32, errno_or_0::32, data::binary>>`. At startup the port reports its
OS pid with code 100.

## Why the copies under vendor/ are patched

Upstream (efuse 1.0.2 / userfs 1.0.4, last touched ~2019) has issues that
matter here, and hex.pm was unreachable from this build environment anyway,
so both are vendored with fixes:

`vendor/efuse` (C port, `c_src/efuse.c`):

1. Supports both the libfuse3 API (31, Linux default) and the libfuse 2.9
   API (26) — the latter is what macFUSE and FUSE-T implement on macOS; the
   Makefile picks via pkg-config (`fuse3` → `fuse` → `fuse-t`), overridable
   with `SUPERBLOCK_FUSE_API=2|3`. On Linux the port statically links
   libfuse3 when the archive exists (portable single binary; opt out with
   `SUPERBLOCK_STATIC_FUSE=0`). The old Makefile also linked
   `-lerl_interface` (removed in OTP 23) and hardcoded OTP-20 paths — none
   of which it actually used.
2. Forced **single-threaded** loop: the protocol is one synchronous
   conversation over a shared buffer; upstream ran fuse_main multithreaded,
   a latent race.
3. Mounts with `-o ro,attr_timeout=5,entry_timeout=5` — the kernel answers
   every write with EROFS before it reaches userspace.
4. The fixed 20 KiB reply buffer could overflow (no bounds check in
   `read_from_erlang`, and `fusecb_read` `memcpy`d past the reply); replaced
   with a growable bounded buffer (64 MiB cap) and clamped copies.
5. Errors are passed through (`-errno`) instead of everything becoming
   ENOENT — superblock needs EACCES/EAGAIN/EIO distinctions.
6. A watchdog thread polls the port pipe: when the Erlang VM dies (even
   `kill -9`) it exits the session and unmounts, so no stale mount is left.
   Signals stay blocked in that thread so SIGTERM/SIGINT always interrupt
   the main loop's `/dev/fuse` read.
7. Built via `fuse_new`/`fuse_mount`/`fuse_loop` instead of `fuse_main` so
   the watchdog owns a session handle.

`vendor/userfs` (Elixir):

1. `:simple_one_for_one` supervisor / `Supervisor.Spec` → DynamicSupervisor.
2. Port spawned with `:spawn_executable` + args (no shell word-splitting of
   the mount point).
3. Unmount tries `fusermount3`/`fusermount` before `umount` (works for
   unprivileged users on Linux).
4. A crashing FS callback replies EIO instead of killing the server (which
   closed the port and wedged the kernel mount).
5. `Userfs.umount/1` tolerates every exit reason from a server that is
   already stopping.

`vendor/castore`: runtime module + cacerts.pem only; the upstream git tree
ships a dev-only mix task that cannot compile as a prod dep (the hex package
prunes it, but hex.pm was not reachable).

## Gotcha worth remembering

`File.*` operations in Elixir go through the `:file_server_2` singleton. A
process reading a superblock-mounted file **from the same VM** parks that
server inside a FUSE syscall; if serving the request then also needs
`File.*`, the filesystem deadlocks. Everything on the serving path
(Config/Credentials) therefore uses raw reads (`Superblock.RawFile`).
