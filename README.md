# supablock

Browse your Supabase account as a filesystem.

supablock is a **read-only FUSE filesystem** that mirrors the Supabase
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
                │   ├── database.json
                │   ├── realtime.json
                │   ├── storage.json
                │   └── auth/
                │       ├── sso/<provider-id>/info.json
                │       └── third-party/<id>/info.json
                ├── api-keys/
                │   ├── publishable
                │   └── secret              # REDACTED unless you opt in
                ├── functions/
                │   └── hello/
                │       ├── info.json
                │       └── body            # raw eszip bundle
                ├── storage/
                │   └── buckets/<name>/info.json
                ├── branches/
                │   └── main/info.json
                └── database/               # every project, via its Data API
                    └── public/             # one folder per exposed schema
                        └── users/          # one folder per table
                            ├── rows-000000.csv   # rows 0–499
                            └── rows-000500.csv   # rows 500–999, …
```

The Management API half is `GET`-only: supablock physically cannot create,
change or delete anything in your Supabase account. The `database/` tree
(row browsing) reads through each project's **Data API** (PostgREST) over
`GET` requests only — no write verb is ever sent — reusing a key supablock
already fetches from the Management API, so it needs **no database password
and no extra credential**. Every mount is read-only at the kernel level
(`-o ro` — any write attempt fails with `EROFS`).

## Install

One line (downloads the CI-built single-file binary from GitHub releases —
no Erlang/Elixir needed; macOS additionally needs
[macFUSE](https://macfuse.github.io) or [FUSE-T](https://www.fuse-t.org)).
Prebuilt binaries cover Linux x86_64/aarch64 and Apple-silicon macOS;
on an Intel Mac, build from source instead:

```bash
curl -fsSL https://filipecabaco.github.io/supablock/install.sh | sh
```

`SUPABLOCK_VERSION` picks a release tag (default: latest, falling back to
the rolling `canary` build); `SUPABLOCK_INSTALL_DIR` overrides the default
`~/.local/bin`.

### Docker

Nothing to install at all — one `docker run` logs you in, mounts your
account inside the container, and drops you into a shell at the mountpoint:

```bash
docker run -it --rm \
  --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v supablock-config:/root/.config/supablock \
  filipecabaco/supablock
```

On the first run the container has no credential, so it starts the login
flow: open the printed URL on your host browser, type the verification code
back at the prompt, and you land in a shell at `/supabase` — `ls
organizations`, `cat`, `grep` away. The credential is written to the
`supablock-config` volume on the host, so every later run skips login and
goes straight to the mounted shell. Exiting the shell stops the container
and unmounts. (`docker volume rm supablock-config` is the container
equivalent of `supablock logout`.)

Already have the supablock binary? It remembers that command for you:

```bash
supablock docker    # assembles the exact docker run above and drops you in
```

`SUPABLOCK_DOCKER_IMAGE` and `SUPABLOCK_DOCKER_VOLUME` override the image
and credentials volume, and a set `SUPABLOCK_TOKEN` is forwarded into the
container (skipping the login flow).

The image is multi-arch (amd64/arm64), Alpine-based and ~100 MB; pushes to
`main` refresh `filipecabaco/supablock:latest` and version tags publish
`:X.Y.Z` (`.github/workflows/docker.yml`).

Details worth knowing:

* **The FUSE flags are not optional.** A FUSE mount inside a container
  needs the host's FUSE device (`--device /dev/fuse`) and mount permission
  (`--cap-add SYS_ADMIN`; `--security-opt apparmor=unconfined` because the
  default Docker AppArmor profile denies `mount` on Debian/Ubuntu hosts —
  harmless where AppArmor isn't in play). The mount lives *inside* the
  container's namespace; it is not visible on the host.
* **Run a one-off command instead of a shell** — everything after the image
  name runs at the mountpoint once it's up:

  ```bash
  docker run -it --rm --device /dev/fuse --cap-add SYS_ADMIN \
    --security-opt apparmor=unconfined \
    -v supablock-config:/root/.config/supablock \
    filipecabaco/supablock grep -r '"site_url"' organizations
  ```

* **Plain subcommands pass through** without mounting: `docker run --rm -it
  … filipecabaco/supablock status` (also `login`, `logout`, `doctor`,
  `config`, …). `ls` and `cat` read the tree API-side, so they need none
  of the FUSE flags at all — see [For AI agents](#for-ai-agents).
* **Headless / CI:** skip the login flow entirely with
  `-e SUPABLOCK_TOKEN=sbp_…` — no volume or TTY needed.
* **Login flow in a container:** the image intentionally uses the
  dashboard session flow (URL + verification code) rather than OAuth — the
  OAuth callback listens on `127.0.0.1:53682`, which port-publishing cannot
  reach across the container boundary. On Linux you can still opt into
  OAuth with `--network host` plus your own app identity
  (`-e SUPABLOCK_OAUTH_CLIENT_ID=… -e SUPABLOCK_OAUTH_CLIENT_SECRET=…`).
* `SUPABLOCK_MOUNTPOINT` changes the in-container mountpoint (default
  `/supabase`).

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
ln -sf "$PWD/bin/supablock" ~/.local/bin/supablock   # or copy
```

Dependencies are pinned as git tags / vendored (see `mix.exs` and
`vendor/`), so the build does not need hex.pm.

### Single-file binary (Burrito)

For easier distribution, supablock can be packaged as a self-contained
executable with [Burrito](https://github.com/burrito-elixir/burrito) — no
Erlang/Elixir needed on the target machine (FUSE still is):

```bash
# extra build prerequisites: zig 0.15.x (mise install provides it) and xz
MIX_ENV=prod mix release supablock_burrito
ls burrito_out/    # -> supablock_burrito_native (~5 MB)
```

The binary self-extracts on first run and behaves exactly like the launcher
(`supablock_burrito_native login`, `… mount`, and so on). The release
workflow (`.github/workflows/release.yml`) builds these binaries per
platform on tag pushes, so nobody needs a local toolchain — grab the
artifact and run it.

### What is (and isn't) inside the single binary

FUSE has a userspace half and a kernel half, and only the first can travel
with the binary:

* **Linux — fully bundled.** The FUSE port statically links `libfuse3`
  whenever the static archive is available (the default; opt out with
  `SUPABLOCK_STATIC_FUSE=0`). The shipped binary therefore needs **no
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
  prerequisite. Once either is installed, the supablock binary is
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
supablock login          # browser consent — that's the whole setup
supablock mount          # mounts at ~/Supabase by default; Ctrl-C unmounts
```

The mountpoint defaults to `~/Supabase` (created on demand);
`supablock config set mountpoint /mnt/supabase` overrides it.

### Team onboarding: `supablock setup`

One command applies a shared team profile, logs in, and offers the
auto-start service:

```bash
supablock setup https://team.example.com/supablock.json
```

The profile is a flat JSON object of config keys — commit it to your
dotfiles repo or wiki. Only known config keys are applied (same validation
as `config set`); anything else is skipped and reported. Tokens and
database passwords never belong in a profile.

```json
{
  "oauth.client_id": "11111111-…",
  "oauth.client_secret": "sb_secret_…",
  "mountpoint": "/mnt/supabase",
  "ttl.orgs": 120
}
```

`setup` also takes a local file path, `--token sbp_…`, `--no-browser`, and
`--service`/`--no-service` (default: asks). Re-running it is safe.

### How login works

`supablock login` picks the best available flow, in this order:

1. **OAuth2 (recommended)** — used when an OAuth app identity is present.
   The browser opens the documented consent page
   (`/v1/oauth/authorize`, PKCE S256 + `state`), Supabase redirects to a
   loopback callback on `127.0.0.1:53682`, and the code is exchanged for
   **short-lived, scoped tokens** that refresh automatically (Supabase
   refresh tokens are single-use; rotation is atomic and serialized).
   Register the app read-only and the read-only guarantee is enforced by
   the server, not just this client. `logout` also revokes the grant
   server-side.

   The app identity resolves in this order: `oauth.client_id` /
   `oauth.client_secret` config (set by hand or via a `setup` profile) →
   `SUPABLOCK_OAUTH_CLIENT_ID`/`_SECRET` env → **the identity baked into
   the released binary at build time** (CI injects the supablock OAuth
   app's credentials from repo secrets, the same way `gh`/`gcloud` ship
   theirs) — so on a released binary, plain `supablock login` needs zero
   configuration.

   To use your own app instead: register it under your org (dashboard →
   org settings → OAuth Apps, redirect URI
   `http://localhost:53682/callback`, read-only scopes) and drop its
   id/secret into config or your team profile.

2. **Dashboard session flow** — with no OAuth app configured, `login`
   replicates the official supabase CLI: it opens
   `supabase.com/dashboard/cli/login`, the dashboard mints a personal
   access token and shows a short verification code, you type the code at
   the prompt, and the token arrives end-to-end encrypted
   (ECDH P-256 + AES-256-GCM). Zero setup, works over SSH with
   `--no-browser`.

3. **Token paste** — `supablock login --token sbp_...` always works.

From another shell:

```bash
ls /mnt/supabase/organizations
cat /mnt/supabase/organizations/*/projects/*/health
```

### Reading without a mount: `ls` and `cat`

The same tree can be read straight off the API — no FUSE, no `/dev/fuse`,
no privileges, no background process. `supablock ls` and `supablock cat`
resolve the exact paths the mount serves, through the same router, with
the same guarantees (GET-only, redaction, deterministic output):

```bash
supablock ls organizations
supablock ls organizations/my-org/projects
supablock cat organizations/my-org/projects/<ref>/health
supablock cat organizations/my-org/projects/<ref>/config/auth.json
```

This is the right mode for restricted environments — minimal containers,
CI, AI-agent sandboxes — and for quick one-off checks where starting a
mount isn't worth it. Each invocation is a fresh process with a cold
cache, so for many reads (or `grep -r` across the account) prefer a real
mount; for a handful of targeted reads, `ls`/`cat` is simpler. `cat`
takes several paths at once, which shares one process and one cache.

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

# Which projects have a public storage bucket?
grep -l '"public": true' /mnt/supabase/organizations/*/projects/*/storage/buckets/*/info.json

# Realtime enabled per project
grep -H '"enabled"' /mnt/supabase/organizations/*/projects/*/config/realtime.json

# Unpack an edge function's source (the body is an eszip bundle)
npx eszip extract \
  /mnt/supabase/organizations/my-org/projects/<ref>/functions/hello/body ./hello-src
```

Beyond the Management-API config already shown, each project now also exposes
its **realtime** and **storage** configuration (`config/realtime.json`,
`config/storage.json`), its **storage buckets**
(`storage/buckets/<name>/info.json`), its **SSO** and **third-party auth**
integrations (`config/auth/sso/…`, `config/auth/third-party/…`), and each
**edge function's** deployed bundle (`functions/<slug>/body`, the raw eszip).
All are `GET`-only, so the read-only guarantee is unchanged.

Output is deterministic — JSON is pretty-printed with sorted keys — so
`diff` between projects is clean and `stat` sizes are exact.

## Browsing table data

The Management API exposes no row data, so table browsing reads through each
project's **Data API** (PostgREST at `https://<ref>.supabase.co/rest/v1`).
There is nothing to set up: every project already has a `database/` folder,
populated on first read. No `db add`, no database password — supablock
fetches the key it needs from the same Management API endpoint that backs
`api-keys/secret`.

```bash
ls  /mnt/supabase/organizations/*/projects/<ref>/database                 # schemas
ls  .../database/public                                                    # tables
ls  .../database/public/users                                             # rows-000000.csv, …
cat .../database/public/users/rows-000000.csv
```

Each exposed **schema** is a folder, each **table/view** a sub-folder, and
rows are paged into files of `db_page_size` rows (default 500). Files are
named by their offset — `rows-000000.csv`, `rows-000500.csv`, … — and ordered
by primary key so paging is stable (a table without a primary key has no
guaranteed order). The default format is CSV; switch to JSON (or read a single
page as either extension regardless of the default):

```bash
supablock config set db_format json     # csv (default) | json
supablock config set db_page_size 1000  # rows per file (≤ the project's PostgREST max_rows)
cat .../database/public/users/rows-000000.json
```

CSV is RFC-4180-quoted (commas, quotes and newlines are escaped), `NULL`
renders as an empty field, and `jsonb`/array columns render as embedded JSON.
JSON files are an array of row objects that keep the table's column order.

### Which key, and what you'll see

By default supablock reads with the project's **`service_role` (secret)**
key, which bypasses Row Level Security — so you see every row, the same view a
direct database connection gave. It is fetched on demand (the same call
`api-keys/secret` makes), used only in `GET`s to the Data API, and never
written to the tree.

Prefer to browse under RLS with the public **`anon`** key instead? Set:

```bash
supablock config set db_key publishable   # secret (default) | publishable
```

With `publishable`, only rows your RLS policies allow the anon role to read
appear — tables with RLS enabled and no anon policy will look empty.

What shows up is what PostgREST exposes: the project's **exposed schemas**
(its `db_schema` config, default `public`) and the tables/views in them.
Non-exposed schemas are invisible, and if a project has the Data API disabled
its `database/` folder simply errors on read. A project on a custom domain or
self-hosted host can be pointed at it with the
`SUPABLOCK_DATA_API_URL_<REF>` environment variable.

## Is the cache stale?

`supablock refresh` drops the whole cache of a live mount; the next reads
re-fetch. To see whether a refresh would actually change anything without
flushing:

```bash
supablock refresh --check
# Cache: 42 entries, 7 stale (past TTL).
# Stale data present — run: supablock refresh
```

## Commands

```
supablock setup [profile]           one-command onboarding: profile + login + service
supablock login                     browser login: OAuth2+PKCE, or dashboard session flow
supablock login --token sbp_...     validate + store a pasted token instead
supablock login --no-browser        print the login URL (SSH-friendly)
supablock logout                    delete the credential (and revoke the OAuth grant)
supablock status | whoami           auth, org count, mount state, rate limits
supablock doctor                    environment checks with fix hints
supablock config set|get|list       mountpoint, TTLs, timeouts, expose_secrets, oauth.*
supablock mount [mountpoint]        mount in the foreground (default ~/Supabase)
supablock unmount [mountpoint]      unmount from another shell
supablock ls [path]                 list a tree directory straight off the API (no mount)
supablock cat <path> [path...]      print tree file(s) straight off the API (no mount)
supablock refresh                   drop the cache; next reads re-fetch
supablock refresh --check           report cache staleness without flushing
supablock docker                    interactive containerized session (wraps docker run)
```

Exit codes: `0` ok · `1` usage · `2` not authenticated · `3` API/network ·
`4` environment (doctor-detectable).

## For AI agents

supablock is a good fit for agents: it is read-only by construction (an
agent cannot break anything by exploring), its output is deterministic,
and the filesystem shape means agents' existing file tools — or plain
`ls`/`cat` — are the whole integration. Three affordances exist
specifically for agent use:

* **An agent skill.** `skills/supablock/SKILL.md` teaches an agent how to
  get the tool, authenticate, and verify account state, with recipes for
  the common checks (health, signup policy, public buckets, config drift).
  Install it into a skills-aware agent (Claude Code and friends) with:

  ```bash
  npx skills add filipecabaco/supablock
  ```

* **No-mount reads.** `supablock ls|cat` (see above) work in any sandbox —
  no FUSE device, no privileges, no daemon — and honour `SUPABLOCK_TOKEN`
  for headless auth. Exit codes are stable and scriptable. The Docker
  image needs none of the FUSE flags in this mode:

  ```bash
  docker run --rm -e SUPABLOCK_TOKEN=sbp_... filipecabaco/supablock \
    cat organizations/<org>/projects/<ref>/health
  ```

* **llms.txt.** A machine-oriented summary of the tool lives at
  [filipecabaco.github.io/supablock/llms.txt](https://filipecabaco.github.io/supablock/llms.txt)
  — point an agent at it and it knows the tree shape, the auth story and
  the ground rules (rate limits, redaction, exit codes).

Give an agent a scoped, revocable personal access token rather than your
interactive credential, and leave `expose_secrets` off — the tree then
contains nothing more sensitive than the account metadata itself.

## Auto-start (service)

To have the mount come up at login and restart on failure:

```bash
supablock config set mountpoint /mnt/supabase
supablock service install     # systemd user unit (Linux) / launchd agent (macOS)
supablock service status
supablock service uninstall
```

Everything is per-user — no root: the unit lands in
`~/.config/systemd/user/supablock.service` (Linux) or
`~/Library/LaunchAgents/io.github.filipecabaco.supablock.plist` (macOS)
and runs `supablock mount` in the foreground under the service manager,
which also gives you `systemctl --user status supablock` / log collection
for free. Stopping the service unmounts cleanly (SIGTERM handling).

## Caching and rate limits

Responses are cached in memory per endpoint (TTLs configurable:
`ttl.orgs`=60s, `ttl.project`=30s, `ttl.health`=10s, `ttl.static`=300s), with
single-flight de-duplication and negative caching, so `ls -R` costs a handful
of requests, not hundreds. The Management API allows 120 requests/minute per
user, tracked independently per project/organization — supablock records the
`X-RateLimit-*` headers per scope (visible in `supablock status`) and on a
`429` the filesystem degrades to `EAGAIN` (never hangs); request deadlines
(`http_timeout_ms`, default 8000) turn slow calls into `EIO`.
`supablock refresh` flushes the cache of a live mount.

## Security notes

* The credential lives in `~/.config/supablock/credentials`, mode `0600`,
  in a `0700` directory — a single-line PAT, or a JSON
  `{access_token, refresh_token, expires_at}` for OAuth, written atomically
  (tmp + rename) because Supabase refresh tokens are single-use. Tokens are
  never logged, never rendered into the tree, and `status` shows them
  masked (`sbp_…f23a`). `SUPABLOCK_TOKEN` overrides the stored credential
  (CI escape hatch) — that is the only environment variable in play.
* The OAuth token POSTs (`/v1/oauth/token`, `/v1/oauth/revoke`) are the
  only non-GET requests supablock ever makes; they manage the OAuth
  session itself, never account resources. With read-only scopes on the
  app registration, read-only is enforced server-side.
* The OAuth client id/secret identify the app, not you; in a distributed
  CLI they are not confidential (PKCE + the loopback-only redirect are
  what protect the flow).
* `api-keys/secret` renders as
  `REDACTED — run: supablock config set expose_secrets true` until you
  explicitly opt in. `api-keys/publishable` is always shown. Note that the
  `database/` tree fetches and uses a key internally regardless of this
  setting (`service_role` by default, or `anon` with `db_key publishable`) —
  `expose_secrets` only governs whether the key is *rendered* into the tree,
  not whether row browsing works. The key is used only for `GET`s to the Data
  API and is never written anywhere.
* The mounted tree is `0444`/`0555` and mounted read-only; mutating FUSE
  operations are rejected by the kernel.

## Troubleshooting

* **`supablock doctor`** checks `/dev/fuse`, unmount tools, file
  permissions and the compiled FUSE port, with a fix hint per failure.
* **Stale mount** (`Transport endpoint is not connected`): run
  `supablock mount` again — it recovers stale mounts automatically — or
  `fusermount3 -u <mountpoint>`. If the VM is killed (`kill -9`), the port
  process notices and unmounts by itself.
* **Rate limited**: reads fail with `EAGAIN` (`Resource temporarily
  unavailable`); `supablock status` shows the last-seen remaining budget.
* Logs go to `~/.local/state/supablock/supablock.log` while mounted
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

The `database/` tree is exercised end-to-end (schemas, tables, paged rows)
against a stubbed Data API in the router, database and FUSE suites, so it
needs no real project or Postgres to test.

CI (`.github/workflows/ci.yml`) runs the unit suite on every push, and a
separate job runs the FUSE + supabase-CLI end-to-ends — the same commands as
above, with the CLI installed and the release prebuilt. A third workflow
(`.github/workflows/docker.yml`) builds the container image per
architecture and end-to-end-tests the real image against a real local
Supabase project — `supabase start` via `supabase/setup-cli`, seeded
with a table; only the platform Management API metadata layer, which
has no local emulator, is served by a thin shim
(`docker/e2e/mgmt_api_shim.py`) that hands supablock the stack's real
keys. Both modes are exercised: agent-style `ls`/`cat` with no FUSE
flags, and the full entrypoint flow over a FUSE mount inside the
container, each reading real rows through the local PostgREST. Only
then is the multi-arch manifest pushed to Docker Hub
(`filipecabaco/supablock`), on pushes to `main` and version tags.

The e2e suite runs hermetically by default: a local stub Management API
serves canned fixtures, the supabase CLI is pointed at it with a custom
`SUPABASE_PROFILE`, and supablock with `SUPABLOCK_API_URL` (both are
test-only escape hatches). Set `SUPABLOCK_E2E_LIVE=1` and
`SUPABASE_ACCESS_TOKEN=sbp_…` to run the same read-only assertions against
your real account instead.

`vendor/` contains patched copies of
[elixir-userfs](https://github.com/mwri/elixir-userfs) and
[erlang-efuse](https://github.com/mwri/erlang-efuse) (both MIT) — see
`notes/userfs-api.md` for the exact API contract and the list of patches —
plus a pruned [castore](https://github.com/elixir-mint/castore)
(Apache-2.0).
