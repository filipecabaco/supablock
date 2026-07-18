# supablock

Browse your Supabase account as a filesystem.

**[filipecabaco.github.io/supablock](https://filipecabaco.github.io/supablock)**

supablock is a **read-only FUSE filesystem** that mirrors the Supabase
[Management API](https://supabase.com/docs/reference/api/introduction) as a
directory tree. Log in once, mount, and inspect organizations, projects,
config, keys, functions and table data with ordinary Unix tools — `ls`,
`cat`, `grep`, `find`, `diff`.

```
/mnt/supabase
└── organizations/
    └── my-org/
        ├── info.json
        ├── members.json
        └── projects/
            └── abcdefghijklmnopqrst/
                ├── info.json
                ├── health                  # "db: healthy" etc.
                ├── advisors/               # security.json · performance.json (lints)
                ├── config/                 # auth, database, disk, pgbouncer, pooler,
                │                           #   postgrest, realtime, storage .json
                ├── api-keys/               # publishable · secret (REDACTED unless you opt in)
                ├── secrets.json            # edge-function secret names (values REDACTED)
                ├── functions/hello/        # info.json · body (raw eszip bundle)
                ├── storage/buckets/
                ├── branches/
                ├── database/               # rows via the project's Data API
                │   ├── backups.json        # + migrations.json, readonly.json
                │   └── public/users/
                │       ├── schema.json     # columns, types, primary key
                │       ├── rows-000000.csv # rows 0–499
                │       └── rows-000500.csv # rows 500–999, …
                ├── network/                # restrictions, ssl-enforcement,
                │                           #   custom-hostname, vanity-subdomain .json
                ├── logs/<source>           # NDJSON: postgres, auth, edge, storage, …
                ├── metrics                 # Prometheus text, project-wide
                └── types.ts                # generated TypeScript types
```

**It cannot change anything.** Every request is a `GET`, and every mount is
read-only at the kernel level (`-o ro` — writes fail with `EROFS`). Row
browsing reuses a key supablock already fetches from the Management API, so
it needs no database password.

## Install

One line — downloads the prebuilt binary (Linux x86_64/aarch64,
Apple-silicon macOS). No Erlang/Elixir needed. macOS also needs
[macFUSE](https://macfuse.github.io) or [FUSE-T](https://www.fuse-t.org);
Intel Macs must [build from source](#building-from-source).

```bash
curl -fsSL https://filipecabaco.github.io/supablock/install.sh | sh
```

`SUPABLOCK_VERSION` picks a release tag; `SUPABLOCK_INSTALL_DIR` overrides
the default `~/.local/bin`.

### Docker

Nothing to install — one `docker run` logs you in, mounts your account
inside the container, and drops you into a shell at the mountpoint:

```bash
docker run -it --rm \
  --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v supablock-config:/root/.config/supablock \
  filipecabaco/supablock
```

The FUSE flags are required for mounting. The credential is saved to the
`supablock-config` volume, so later runs skip login. Notes:

* **One-off command:** anything after the image name runs at the mountpoint
  (e.g. `… filipecabaco/supablock grep -r '"site_url"' organizations`).
* **Subcommands pass through** without mounting (`status`, `login`,
  `logout`, `doctor`, …). `ls`/`cat` read API-side and need none of the
  FUSE flags — see [For AI agents](#for-ai-agents).
* **Headless / CI:** skip login with `-e SUPABLOCK_TOKEN=sbp_…`.
* `SUPABLOCK_MOUNTPOINT` changes the in-container mountpoint (default
  `/supabase`).

### Building from source

Prerequisites:

* Toolchain via [mise](https://mise.jdx.dev): `mise install` pins Erlang
  27.3, Elixir 1.18.4 and Zig 0.15.2. (Without mise: Erlang/OTP 25+,
  Elixir 1.17+, 1.18.x recommended.)
* Linux: `libfuse3-dev fuse3 pkg-config`; macOS:
  [macFUSE](https://macfuse.github.io)
* a C compiler (the FUSE port is a small C program)

```bash
mix deps.get
MIX_ENV=prod mix release
ln -sf "$PWD/bin/supablock" ~/.local/bin/supablock
```

For a self-contained single-file binary (no Erlang/Elixir on the target;
FUSE still needed), package with
[Burrito](https://github.com/burrito-elixir/burrito):

```bash
MIX_ENV=prod mix release supablock_burrito   # needs zig 0.15.x + xz
ls burrito_out/                              # -> supablock_burrito_native
```

On Linux the FUSE port statically links `libfuse3`, so the binary needs no
FUSE package installed. On macOS the kernel side (macFUSE / FUSE-T) must be
installed by the user — as with every macOS FUSE app.

## Quickstart

```bash
supablock login          # browser consent — that's the whole setup
supablock mount          # mounts at ~/Supabase; Ctrl-C unmounts
```

`supablock config set mountpoint /mnt/supabase` overrides the default
mountpoint. From another shell:

```bash
ls  /mnt/supabase/organizations
cat /mnt/supabase/organizations/*/projects/*/health
```

### Login flows

`supablock login` picks the best available flow:

1. **OAuth2 + PKCE (recommended)** — used when an OAuth app identity is
   present (config, `SUPABLOCK_OAUTH_CLIENT_ID`/`_SECRET`, or the identity
   baked into a released binary). Short-lived scoped tokens that refresh
   automatically; register the app read-only and read-only is enforced
   server-side. `logout` revokes the grant.
2. **Dashboard session flow** — no OAuth app configured: mirrors the
   supabase CLI (opens the dashboard, you type a verification code, token
   arrives end-to-end encrypted). Works over SSH with `--no-browser`.
3. **Token paste** — `supablock login --token sbp_...` always works.

### Team onboarding

One command applies a shared team profile, logs in, and offers the
auto-start service:

```bash
supablock setup https://team.example.com/supablock.json
```

The profile is a flat JSON object of config keys (never tokens or
passwords) — commit it to your dotfiles or wiki. Only known keys are
applied.

### Reading without a mount

`supablock ls`, `cat`, `head`, `tail`, `find` and `grep` resolve the same
tree straight off the API — no FUSE, no privileges, no background process —
with the same guarantees (GET-only, redaction, deterministic output):

```bash
supablock ls   organizations/my-org/projects
supablock cat  organizations/my-org/projects/<ref>/config/auth.json
supablock head -n 20 organizations/my-org/projects/<ref>/database/public/users/rows-000000.csv
supablock find organizations/my-org -name '*.json' -maxdepth 3
supablock grep -l '"disable_signup": false' organizations/my-org
supablock tail -f organizations/my-org/projects/<ref>/logs/postgres
supablock cat  organizations/my-org/projects/<ref>/metrics
```

`find` and `grep` walk directories recursively (`-maxdepth` bounds the
walk); `grep` exits `1` when nothing matched, like grep(1), and flags
binary files instead of dumping bytes. Commands connect with ordinary
shell pipes — `find -print0` pairs with `cat -0 -`, and `cat -` reads
paths from stdin as they arrive:

```bash
supablock find organizations/my-org -type f -name '*.json' | supablock cat -
```

This is the right mode for restricted environments (containers, CI, agent
sandboxes). For many reads, share one warm cache across invocations:
`supablock serve` starts a small daemon (no FUSE, no privileges — just the
cache), and every `ls`/`cat`/`find`/`grep` on the machine automatically
reads through it while it runs. A live mount serves the same role.
`SUPABLOCK_DIRECT=1` forces direct API reads.

```bash
supablock serve &            # or: supablock mount
supablock grep -l '"disable_signup": false' organizations/my-org
supablock serve stop
```

## Example one-liners

```bash
# Which projects disable signups?
grep -l '"disable_signup": true' /mnt/supabase/organizations/*/projects/*/config/auth.json

# Compare two projects' auth config
diff /mnt/supabase/organizations/my-org/projects/{refA,refB}/config/auth.json

# Site URLs across the whole account
grep -r '"site_url"' /mnt/supabase/organizations/*/projects/*/config/auth.json

# Which projects have a public storage bucket?
grep -l '"public": true' /mnt/supabase/organizations/*/projects/*/storage/buckets/*/info.json

# Which projects have security advisor findings (e.g. RLS disabled)?
grep -l '"level": "ERROR"' /mnt/supabase/organizations/*/projects/*/advisors/security.json

# Pull a project's generated TypeScript types straight into your app
supablock cat organizations/my-org/projects/<ref>/types.ts > src/db-types.ts

# Unpack an edge function's source (the body is an eszip bundle)
npx eszip extract /mnt/supabase/.../functions/hello/body ./hello-src
```

Output is deterministic — JSON is pretty-printed with sorted keys — so
`diff` between projects is clean and `stat` sizes are exact.

## Snapshots and drift

The tree's determinism makes drift tracking a one-liner. `snapshot` writes
the tree to a real directory; `diff` compares the live tree against it:

```bash
supablock snapshot ~/supabase-snapshot            # the config surface, on disk
supablock diff ~/supabase-snapshot                # what changed since? (exit 1 = drift)
supablock diff ~/supabase-snapshot --brief        # names only
supablock snapshot ~/supabase-snapshot --prune    # refresh, dropping deleted files
```

By default snapshots cover the *configuration surface* — logs, metrics,
database rows and function bodies are skipped (`--all` includes them, and
skipped subtrees cost no API requests). Snapshots store full tree paths, so
`diff -r` between two snapshots works, and committing a snapshot directory
to git turns your Supabase account history into an audit trail:

```bash
cd ~/supabase-audit && supablock snapshot . --prune && git add -A \
  && git commit -m "supabase config $(date -I)"
```

`diff` exits like diff(1): `0` identical, `1` differences, `2` errors.

## Browsing table data

The Management API exposes no rows, so `database/` reads through each
project's **Data API** (PostgREST). Nothing to set up: every project has a
`database/` folder, populated on first read, using a key supablock fetches
itself — no database password.

```bash
ls  .../database                 # exposed schemas (+ backups/migrations/readonly.json)
ls  .../database/public          # tables/views
cat .../database/public/users/schema.json        # columns, types, primary key
cat .../database/public/users/rows-000000.csv
```

Every table also carries a `schema.json` — column names, types and formats
in ordinal order, the primary key and NOT NULL columns — rendered from the
same cached PostgREST spec that powers listings, so it costs no extra
requests. Rows are paged into files of `db_page_size` rows (default 500),
named by offset and ordered by primary key. CSV by default (RFC-4180 quoted, `NULL`
= empty field); switch with config:

```bash
supablock config set db_format json       # csv (default) | json
supablock config set db_page_size 1000    # rows per file
supablock config set db_key publishable   # secret (default, bypasses RLS) | publishable (anon, under RLS)
```

By default supablock reads with the **`service_role`** key (bypasses RLS —
you see every row). `db_key publishable` reads under RLS with the **`anon`**
key. A custom-domain or self-hosted project can be pointed at with
`SUPABLOCK_DATA_API_URL_<REF>`.

## Commands

```
supablock setup [profile]           one-command onboarding: profile + login + service
supablock login [--token|--no-browser]  browser login, pasted token, or SSH-friendly URL
supablock logout                    delete the credential (and revoke the OAuth grant)
supablock status [--json] | whoami  auth, org count, mount state, rate limits
supablock doctor                    environment checks with fix hints
supablock config set|get|list       mountpoint, TTLs, timeouts, expose_secrets, db_*, oauth.*
supablock mount [mountpoint]        mount in the foreground (default ~/Supabase)
supablock unmount [mountpoint]      unmount from another shell
supablock ls|cat <path>             read the tree straight off the API (no mount)
                                    cat -: paths from stdin; -0: NUL-delimited
supablock head|tail [-n N] <path>   first/last lines of tree files (no mount)
                                    tail -f [-s secs] follows a logs/<source> file
supablock find [path] [filters]     walk the tree; -type f|d, -name <glob>, -maxdepth N,
                                    -print0
supablock grep [-iln] <pat> [path]  search file contents; dirs recurse, exit 1 = no match
supablock snapshot <dir> [path]     write the tree to a real directory (--all, --prune)
supablock diff <dir> [path]         live tree vs snapshot: unified diffs; --brief
supablock mcp                       MCP server on stdio (tools: ls, cat, find, grep)
supablock serve [stop]              mountless cache daemon: ls/cat/find/grep reuse it
supablock refresh [--check]         drop the cache (or report staleness)
supablock completions bash|zsh|fish shell completion (subcommands, keys, tree paths)
supablock service install|status|uninstall   auto-start at login (systemd/launchd)
```

Exit codes: `0` ok · `1` usage · `2` not authenticated · `3` API/network ·
`4` environment (doctor-detectable) · `141` downstream pipe closed —
`supablock cat … | head` ends quietly, coreutils-style, and non-UTF-8
bodies pass through pipes byte-exact.

## For AI agents

supablock is a good fit for agents: read-only by construction, deterministic
output, and the filesystem shape means existing file tools (or plain
`ls`/`cat`) are the whole integration.

* **Agent skill** — `npx skills add filipecabaco/supablock` teaches an agent
  to get the tool, authenticate, and run the common checks.
* **MCP server** — `supablock mcp` speaks the Model Context Protocol over
  stdio with four read-only tools (`ls`, `cat`, `find`, `grep`), resolved by
  the same Router as the mount, so GET-only, redaction and deterministic
  rendering carry over. Register it in any MCP client as command
  `supablock`, args `["mcp"]`:

  ```json
  {"mcpServers": {"supabase-tree": {"command": "supablock", "args": ["mcp"]}}}
  ```
* **No-mount reads** — `supablock ls|cat|head|tail|find|grep` work in any
  sandbox (no FUSE device, no privileges) and honour `SUPABLOCK_TOKEN`;
  `supablock serve &` first gives every subsequent read one shared warm
  cache, still with no FUSE:

  ```bash
  docker run --rm -e SUPABLOCK_TOKEN=sbp_... filipecabaco/supablock \
    cat organizations/<org>/projects/<ref>/health
  ```

* **llms.txt** — a machine-oriented summary at
  [filipecabaco.github.io/supablock/llms.txt](https://filipecabaco.github.io/supablock/llms.txt).

Give an agent a scoped, revocable token rather than your interactive
credential, and leave `expose_secrets` off.

## Security notes

* The credential lives in `~/.config/supablock/credentials` (mode `0600`,
  `0700` dir), written atomically. Tokens are never logged or rendered into
  the tree; `status` shows them masked. `SUPABLOCK_TOKEN` overrides it.
* The only non-GET requests supablock ever makes are the OAuth token/revoke
  POSTs, which manage the session — never account resources. With read-only
  scopes, read-only is enforced server-side.
* `api-keys/secret` is `REDACTED` until you `config set expose_secrets true`.
  Row browsing still uses a key internally (never written to the tree).
* `secrets.json` shows edge-function secret *names* with every value
  `REDACTED` under the same `expose_secrets` gate. (The API endpoint has no
  names-only mode, so values are redacted at render time and never written
  anywhere — including snapshots.)
* The mounted tree is `0444`/`0555` and read-only; mutating operations are
  rejected by the kernel.

## Caching and rate limits

Responses are cached in memory per endpoint (TTLs configurable via
`ttl.*`), with single-flight de-duplication and negative caching, so `ls -R`
costs a handful of requests. The Management API allows 120 req/min per user;
supablock tracks `X-RateLimit-*` per scope (see `status`) and degrades to
`EAGAIN` on `429` (never hangs). `supablock refresh` flushes a live mount.

## Troubleshooting

* **`supablock doctor`** checks `/dev/fuse`, unmount tools, permissions and
  the compiled FUSE port, with a fix hint per failure.
* **Stale mount** (`Transport endpoint is not connected`): re-run
  `supablock mount` (it recovers automatically) or `fusermount3 -u <mp>`.
* **Rate limited**: reads fail with `EAGAIN`; `status` shows the remaining
  budget.
* Logs: `~/.local/state/supablock/supablock.log` (`--verbose` for debug).
  Tokens are scrubbed.

## Development

```bash
mix test                 # unit + router/cache/CLI tests (no FUSE needed)
mix test --include fuse  # tests against a real mount (needs /dev/fuse)
mix test --include e2e   # cross-check the mounted tree against the supabase CLI
```

CI runs the unit suite on every push; separate jobs run the FUSE +
supabase-CLI end-to-ends and build/test the multi-arch Docker image against
a real local Supabase project before pushing to Docker Hub.

`vendor/` holds patched copies of
[elixir-userfs](https://github.com/mwri/elixir-userfs) and
[erlang-efuse](https://github.com/mwri/erlang-efuse) (MIT) plus a pruned
[castore](https://github.com/elixir-mint/castore) (Apache-2.0).
