# superblock

Browse your Supabase account as a filesystem.

superblock is a **read-only FUSE filesystem** that mirrors the Supabase
[Management API](https://supabase.com/docs/reference/api/introduction) as a
directory tree. Log in once through the Supabase dashboard, mount, and
inspect organizations, projects, config, keys and functions with ordinary
Unix tools — `ls`, `cat`, `grep`, `find`, `diff`.

```
/mnt/supabase
└── organizations/
    └── my-org/
        ├── info.json
        ├── members.json
        ├── regions.json
        └── projects/
            └── abcdefghijklmnopqrst/
                ├── info.json
                ├── health                  # "db: healthy" etc.
                ├── config/
                │   ├── auth.json
                │   └── database.json
                ├── api-keys/
                │   ├── publishable
                │   └── secret              # REDACTED unless you opt in
                ├── functions/
                │   └── hello/info.json
                └── branches/
                    └── main/info.json
```

Everything is `GET`-only: superblock physically cannot create, change or
delete anything in your Supabase account, and the mount itself is read-only
at the kernel level (`-o ro` — any write attempt fails with `EROFS`).

## Install

One line (downloads the CI-built single-file binary from GitHub releases —
no Erlang/Elixir needed; macOS additionally needs
[macFUSE](https://macfuse.github.io) or [FUSE-T](https://www.fuse-t.org)):

```bash
curl -fsSL https://filipecabaco.github.io/supablock/install.sh | sh
```

`SUPERBLOCK_VERSION` picks a release tag (default: latest, falling back to
the rolling `canary` build); `SUPERBLOCK_INSTALL_DIR` overrides the default
`~/.local/bin`.

### Building from source

Prerequisites:

* The toolchain is managed with [mise](https://mise.jdx.dev): `mise install`
  gives you the pinned Erlang 27.3, Elixir 1.18.4 and Zig 0.15.2 from
  `mise.toml`. (Without mise: Erlang/OTP 25+ and Elixir 1.17+ — Elixir
  **1.18.x** recommended, it is the version Burrito's own CI tests against.)
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

### Single-file binary (Burrito)

For easier distribution, superblock can be packaged as a self-contained
executable with [Burrito](https://github.com/burrito-elixir/burrito) — no
Erlang/Elixir needed on the target machine (FUSE still is):

```bash
# extra build prerequisites: zig 0.15.x (mise install provides it) and xz
MIX_ENV=prod mix release superblock_burrito
ls burrito_out/    # -> superblock_burrito_native (~5 MB)
```

The binary self-extracts on first run and behaves exactly like the launcher
(`superblock_burrito_native login`, `… mount`, and so on). The release
workflow (`.github/workflows/release.yml`) builds these binaries per
platform on tag pushes, so nobody needs a local toolchain — grab the
artifact and run it.

### What is (and isn't) inside the single binary

FUSE has a userspace half and a kernel half, and only the first can travel
with the binary:

* **Linux — fully bundled.** The FUSE port statically links `libfuse3`
  whenever the static archive is available (the default; opt out with
  `SUPERBLOCK_STATIC_FUSE=0`). The shipped binary therefore needs **no
  FUSE package installed**: the kernel module is part of every mainstream
  kernel, and `fusermount3` (needed only for non-root mounts, and only
  because it must be setuid — that's why it can't be bundled) ships by
  default on all major distros.
* **macOS — userspace API supported, kernel side must be installed.** The
  port speaks the libfuse **2.9** API that both
  [macFUSE](https://macfuse.github.io) and [FUSE-T](https://www.fuse-t.org)
  implement (auto-detected via pkg-config at build time). What cannot be
  bundled — by anyone — is the kernel extension/daemon itself: Apple
  requires the user to install and approve it, which is why every macOS
  FUSE app (rclone, Cryptomator, …) asks for macFUSE or FUSE-T as its one
  prerequisite. Once either is installed, the superblock binary is
  self-sufficient.

More build notes:

* The build targets the **native** platform only: the FUSE port is a C
  executable compiled on the build machine, so cross-compiled targets
  would ship a broken port. The CI matrix builds each platform natively.
* Burrito normally downloads a precompiled ERTS; on build hosts without
  access to its CDN, point `BURRITO_ERTS_PATH` at an unpacked local OTP
  root (e.g. `/usr/lib/erlang`) to bundle the ERTS you built with.
* To clear the self-extracted payload cache after an upgrade gone wrong:
  remove `~/.local/share/.burrito/`.

## Quickstart

```bash
superblock login          # opens the Supabase dashboard; type the code it shows
superblock config set mountpoint /mnt/supabase
superblock mount          # foreground; Ctrl-C unmounts
```

### How login works

`superblock login` picks the best available flow, in this order:

1. **OAuth2 (recommended)** — used when an OAuth app is configured. The
   browser opens the documented consent page
   (`/v1/oauth/authorize`, PKCE S256 + `state`), Supabase redirects to a
   loopback callback on `127.0.0.1:53682`, and the code is exchanged for
   **short-lived, scoped tokens** that refresh automatically (Supabase
   refresh tokens are single-use; rotation is atomic and serialized).
   Register the app read-only and the read-only guarantee is enforced by
   the server, not just this client. `logout` also revokes the grant
   server-side. Configure once:

   ```bash
   superblock config set oauth.client_id <uuid from your OAuth app>
   superblock config set oauth.client_secret <its secret>
   ```

   (Register the app under your org: dashboard → org settings → OAuth Apps,
   redirect URI `http://localhost:53682/callback`, read-only scopes.)

2. **Dashboard session flow** — with no OAuth app configured, `login`
   replicates the official supabase CLI: it opens
   `supabase.com/dashboard/cli/login`, the dashboard mints a personal
   access token and shows a short verification code, you type the code at
   the prompt, and the token arrives end-to-end encrypted
   (ECDH P-256 + AES-256-GCM). Zero setup, works over SSH with
   `--no-browser`.

3. **Token paste** — `superblock login --token sbp_...` always works.

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
superblock login                     browser login: OAuth2+PKCE, or dashboard session flow
superblock login --token sbp_...     validate + store a pasted token instead
superblock login --no-browser        print the login URL (SSH-friendly)
superblock logout                    delete the credential (and revoke the OAuth grant)
superblock status | whoami           auth, org count, mount state, rate limits
superblock doctor                    environment checks with fix hints
superblock config set|get|list       mountpoint, TTLs, timeouts, expose_secrets, oauth.*
superblock mount [mountpoint]        mount in the foreground
superblock unmount [mountpoint]      unmount from another shell
superblock refresh                   drop the cache; next reads re-fetch
```

Exit codes: `0` ok · `1` usage · `2` not authenticated · `3` API/network ·
`4` environment (doctor-detectable).

## Auto-start (service)

To have the mount come up at login and restart on failure:

```bash
superblock config set mountpoint /mnt/supabase
superblock service install     # systemd user unit (Linux) / launchd agent (macOS)
superblock service status
superblock service uninstall
```

Everything is per-user — no root: the unit lands in
`~/.config/systemd/user/superblock.service` (Linux) or
`~/Library/LaunchAgents/io.github.filipecabaco.superblock.plist` (macOS)
and runs `superblock mount` in the foreground under the service manager,
which also gives you `systemctl --user status superblock` / log collection
for free. Stopping the service unmounts cleanly (SIGTERM handling).

## Caching and rate limits

Responses are cached in memory per endpoint (TTLs configurable:
`ttl.orgs`=60s, `ttl.project`=30s, `ttl.health`=10s, `ttl.static`=300s), with
single-flight de-duplication and negative caching, so `ls -R` costs a handful
of requests, not hundreds. The Management API allows 120 requests/minute per
user, tracked independently per project/organization — superblock records the
`X-RateLimit-*` headers per scope (visible in `superblock status`) and on a
`429` the filesystem degrades to `EAGAIN` (never hangs); request deadlines
(`http_timeout_ms`, default 8000) turn slow calls into `EIO`.
`superblock refresh` flushes the cache of a live mount.

## Security notes

* The credential lives in `~/.config/superblock/credentials`, mode `0600`,
  in a `0700` directory — a single-line PAT, or a JSON
  `{access_token, refresh_token, expires_at}` for OAuth, written atomically
  (tmp + rename) because Supabase refresh tokens are single-use. Tokens are
  never logged, never rendered into the tree, and `status` shows them
  masked (`sbp_…f23a`). `SUPERBLOCK_TOKEN` overrides the stored credential
  (CI escape hatch) — that is the only environment variable in play.
* The OAuth token POSTs (`/v1/oauth/token`, `/v1/oauth/revoke`) are the
  only non-GET requests superblock ever makes; they manage the OAuth
  session itself, never account resources. With read-only scopes on the
  app registration, read-only is enforced server-side.
* The OAuth client id/secret identify the app, not you; in a distributed
  CLI they are not confidential (PKCE + the loopback-only redirect are
  what protect the flow).
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

No writes to account resources of any kind, no `auth.users` browsing, no
logs endpoints. `mount` runs in the foreground; use
`superblock service install` for auto-start.
