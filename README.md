# superblock

Browse your Supabase account as a filesystem.

superblock is a **read-only FUSE filesystem** that mirrors the Supabase
[Management API](https://supabase.com/docs/reference/api/introduction) as a
directory tree. Authenticate once with a personal access token, mount, and
inspect organizations, projects, config, keys and functions with ordinary
Unix tools — `ls`, `cat`, `grep`, `find`, `diff`.

```
/mnt/supabase
├── organizations/
│   └── my-org/
│       ├── info.json
│       ├── members.json
│       └── projects/
│           └── abcdefghijklmnopqrst/
│               ├── info.json
│               ├── health                  # "db: healthy" etc.
│               ├── config/
│               │   ├── auth.json
│               │   └── database.json
│               ├── api-keys/
│               │   ├── publishable
│               │   └── secret              # REDACTED unless you opt in
│               ├── functions/
│               │   └── hello/info.json
│               └── branches/
│                   └── main/info.json
└── regions.json
```

Everything is `GET`-only: superblock physically cannot create, change or
delete anything in your Supabase account, and the mount itself is read-only
at the kernel level (`-o ro` — any write attempt fails with `EROFS`).

## Install

Prerequisites:

* Erlang/OTP 25+ and Elixir 1.17+ (see `.tool-versions`)
* Linux: `libfuse3-dev`, `fuse3` and `pkg-config` (Debian/Ubuntu:
  `apt install libfuse3-dev fuse3 pkg-config`); macOS: [macFUSE](https://macfuse.github.io)
* a C compiler (the FUSE port is a small C program)

Build:

```bash
mix deps.get
MIX_ENV=prod mix release
ln -sf "$PWD/bin/superblock" ~/.local/bin/superblock   # or copy
```

Dependencies are pinned as git tags / vendored (see `mix.exs` and
`vendor/`), so the build does not need hex.pm.

## Quickstart

```bash
superblock login          # paste a token from app.supabase.com → Account → Access Tokens
superblock config set mountpoint /mnt/supabase
superblock mount          # foreground; Ctrl-C unmounts
```

From another shell:

```bash
ls /mnt/supabase/organizations
cat /mnt/supabase/organizations/*/projects/*/health
```

## Example one-liners

```bash
# Which projects disable signups?
grep -l '"disable_signup": true' /mnt/supabase/organizations/*/projects/*/config/auth.json

# Compare two projects' auth config
diff /mnt/supabase/organizations/my-org/projects/{refA,refB}/config/auth.json

# All project refs and their regions
grep '"region"' /mnt/supabase/organizations/*/projects/*/info.json

# Site URLs across the whole account
grep -r '"site_url"' /mnt/supabase/organizations/*/projects/*/config/auth.json
```

Output is deterministic — JSON is pretty-printed with sorted keys — so
`diff` between projects is clean and `stat` sizes are exact.

## Commands

```
superblock login [--token sbp_...]   validate + store a token (0600)
superblock logout                    delete the stored token
superblock status | whoami           auth, org count, mount state, rate limits
superblock doctor                    environment checks with fix hints
superblock config set|get|list       mountpoint, TTLs, timeouts, expose_secrets
superblock mount [mountpoint]        mount in the foreground
superblock unmount [mountpoint]      unmount from another shell
superblock refresh                   drop the cache; next reads re-fetch
```

Exit codes: `0` ok · `1` usage · `2` not authenticated · `3` API/network ·
`4` environment (doctor-detectable).

## Caching and rate limits

Responses are cached in memory per endpoint (TTLs configurable:
`ttl.orgs`=60s, `ttl.project`=30s, `ttl.health`=10s, `ttl.static`=300s), with
single-flight de-duplication and negative caching, so `ls -R` costs a handful
of requests, not hundreds. On `429` the filesystem degrades to `EAGAIN`
(never hangs); request deadlines (`http_timeout_ms`, default 8000) turn slow
calls into `EIO`. `superblock refresh` flushes the cache of a live mount.

## Security notes

* The token lives in `~/.config/superblock/credentials`, mode `0600`, in a
  `0700` directory. It is never logged, never rendered into the tree, and
  `status` shows it masked (`sbp_…f23a`). `SUPERBLOCK_TOKEN` overrides the
  stored token (CI escape hatch) — that is the only environment variable in
  play.
* `api-keys/secret` renders as
  `REDACTED — run: superblock config set expose_secrets true` until you
  explicitly opt in. `api-keys/publishable` is always shown.
* The mounted tree is `0444`/`0555` and mounted read-only; mutating FUSE
  operations are rejected by the kernel.

## Troubleshooting

* **`superblock doctor`** checks `/dev/fuse`, unmount tools, file
  permissions and the compiled FUSE port, with a fix hint per failure.
* **Stale mount** (`Transport endpoint is not connected`): run
  `superblock mount` again — it recovers stale mounts automatically — or
  `fusermount3 -u <mountpoint>`. If the VM is killed (`kill -9`), the port
  process notices and unmounts by itself.
* **Rate limited**: reads fail with `EAGAIN` (`Resource temporarily
  unavailable`); `superblock status` shows the last-seen remaining budget.
* Logs go to `~/.local/state/superblock/superblock.log` while mounted
  (`--verbose` for debug level). Tokens are scrubbed from log output.

## Development

```bash
mix test                 # unit + router/cache/CLI tests (no FUSE needed)
mix test --include fuse  # tests against a real mount
                         # (needs /dev/fuse; in CI use a container with
                         #  --device /dev/fuse --cap-add SYS_ADMIN)

MIX_ENV=prod mix release # the e2e suite drives the released binary...
mix test --include e2e   # ...and cross-checks the mounted tree against the
                         # official supabase CLI (must be on PATH)
```

The e2e suite runs hermetically by default: a local stub Management API
serves canned fixtures, the supabase CLI is pointed at it with a custom
`SUPABASE_PROFILE`, and superblock with `SUPERBLOCK_API_URL` (both are
test-only escape hatches). Set `SUPERBLOCK_E2E_LIVE=1` and
`SUPABASE_ACCESS_TOKEN=sbp_…` to run the same read-only assertions against
your real account instead.

`vendor/` contains patched copies of
[elixir-userfs](https://github.com/mwri/elixir-userfs) and
[erlang-efuse](https://github.com/mwri/erlang-efuse) (both MIT) — see
`notes/userfs-api.md` for the exact API contract and the list of patches —
plus a pruned [castore](https://github.com/elixir-mint/castore)
(Apache-2.0).

## Out of scope (v1)

No writes of any kind, no OAuth, no token refresh, no `auth.users` browsing,
no logs endpoints, no daemon mode — `mount` is foreground-only.
