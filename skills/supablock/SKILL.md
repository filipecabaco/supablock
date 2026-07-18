---
name: supablock
description: >-
  Read and verify Supabase account state (organizations, projects, config,
  API keys, edge functions, storage buckets, auth providers, table rows)
  through supablock, a read-only view of the Supabase Management API with
  filesystem semantics. Use when asked to inspect, audit, compare or verify
  anything in a Supabase account — project settings, health, signup policy,
  bucket visibility, deployed functions, row data — without risk of writes.
---

# supablock — verify Supabase state, read-only by construction

supablock exposes a Supabase account as a directory tree. Every read is a
`GET` against the Management API (plus each project's Data API for rows);
no write verb exists in the tool, so you cannot damage anything by
exploring. Output is deterministic — JSON pretty-printed with sorted keys —
so `diff` between two projects is meaningful.

## Getting the tool

Pick the first option that works in your environment:

1. **Already installed?** `supablock help` — if it prints usage, skip ahead.
2. **Native install** (Linux/macOS):
   `curl -fsSL https://filipecabaco.github.io/supablock/install.sh | sh`
3. **Docker** (no install, needs a token):
   `docker run --rm -e SUPABLOCK_TOKEN=$SUPABLOCK_TOKEN filipecabaco/supablock <command>`

## Authentication

- Best for agents: a personal access token in the environment —
  `SUPABLOCK_TOKEN=sbp_…`. It overrides any stored credential; nothing is
  written to disk. Ask the user for one (created at
  supabase.com/dashboard/account/tokens) if none is set.
- `supablock login --token sbp_…` stores it for repeated use.
- Interactive fallback: `supablock login --no-browser` prints a URL for the
  user to open, then prompts for the verification code shown there — hand
  those steps to the user.
- Check where you stand with `supablock status` (exit 2 = not
  authenticated).

## Reading — no mount needed

`ls`, `cat`, `head`, `tail`, `find` and `grep` resolve tree paths straight
off the API. They work in any sandbox: no FUSE, no /dev/fuse, no
privileges, no daemon.

```bash
supablock ls                                    # -> organizations
supablock ls organizations                      # org slugs
supablock ls organizations/<org>/projects       # project refs
supablock cat organizations/<org>/projects/<ref>/health
supablock cat organizations/<org>/projects/<ref>/config/auth.json

# discover paths without knowing the tree by heart
supablock find organizations/<org> -name '*.json' -maxdepth 3
supablock find organizations/<org>/projects/<ref> -type d

# search file contents; directories recurse (grep -r semantics)
supablock grep -l '"public": true' organizations/<org>/projects/<ref>/storage
supablock grep -in 'site_url' organizations/<org>/projects/<ref>/config

# peek at big row files before reading all pages
supablock head -n 20 organizations/<org>/projects/<ref>/database/public/users/rows-000000.csv
```

`find` takes `-type f|d`, `-name <glob>`, `-maxdepth <n>` and `-print0`;
`grep` takes `-i` (ignore case), `-l` (paths only), `-n` (line numbers) and
`--maxdepth <n>`, and exits `1` when nothing matched — branch on that like
you would with grep(1). Both print paths you can feed straight back to
`supablock cat`, including through a pipe — `cat -` reads paths from stdin
(`-0` pairs with `find -print0` for odd names):

```bash
supablock find organizations/<org> -type f -name '*.json' | supablock cat -
```

Keep walks scoped (a start path plus `-maxdepth`) — an unbounded walk of a
big account burns the 120 req/min budget.

## Batch reads: share one warm cache

Each supablock invocation normally starts with a cold cache. Before a
burst of reads, start the mountless cache daemon (no FUSE, no privileges):

```bash
supablock serve &            # every ls/cat/find/grep now reuses its cache
# ... run your checks ...
supablock serve stop
```

While it runs, all supablock reads on the machine resolve through it
automatically (a live `supablock mount` works the same way), so repeated
listings and walks cost one set of API requests instead of one per
invocation. `SUPABLOCK_DIRECT=1` opts a command out.

If FUSE **is** available (e.g. the Docker image run with
`--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined`),
`supablock mount ~/Supabase` gives you the same tree as real files, and
your normal file tools (grep -r, find, diff) work across the whole account
with a shared warm cache. Prefer the mount when you plan many reads;
prefer `ls`/`cat` for a handful of targeted checks.

## The tree

```
organizations/<org>/
  info.json  members.json  regions.json
  projects/<ref>/
    info.json                 # name, region, status
    health                    # "auth: healthy" … one line per service
    advisors/{security,performance}.json   # lints: RLS off, slow queries, …
    config/{auth,database,disk,pgbouncer,pooler,postgrest,realtime,storage}.json
    config/auth/sso/<id>/info.json
    config/auth/third-party/<id>/info.json
    api-keys/{publishable,secret}    # secret is REDACTED unless opted in
    secrets.json              # edge-function secret names, values REDACTED
    functions/<slug>/{info.json,body}  # body = deployed eszip bundle
    storage/buckets/<name>/info.json
    branches/<branch>/info.json
    database/{backups,migrations,readonly}.json
    database/<schema>/<table>/schema.json       # columns, types, primary key
    database/<schema>/<table>/rows-000000.csv   # paged rows, 500/page
    network/{restrictions,ssl-enforcement,custom-hostname,vanity-subdomain}.json
    types.ts                  # generated TypeScript types
    upgrade-eligibility.json
```

## Verification recipes

```bash
# Is every service of a project healthy?
supablock cat organizations/<org>/projects/<ref>/health

# Are signups disabled in production?
supablock cat organizations/<org>/projects/<ref>/config/auth.json | jq .disable_signup

# Compare staging vs production auth config
diff <(supablock cat .../projects/<staging>/config/auth.json) \
     <(supablock cat .../projects/<prod>/config/auth.json)

# Any public storage buckets?
supablock grep -l '"public": true' organizations/<org>/projects/<ref>/storage

# Any security advisor findings (RLS disabled, exposed views, …)?
supablock cat organizations/<org>/projects/<ref>/advisors/security.json | jq '.lints[].name'

# What shape is a table, without reading rows?
supablock cat organizations/<org>/projects/<ref>/database/public/users/schema.json

# Which migrations are applied?
supablock cat organizations/<org>/projects/<ref>/database/migrations.json

# What changed since the last audit? (snapshot once, diff later)
supablock snapshot /tmp/snap && supablock diff /tmp/snap --brief

# What functions are deployed, and at which version?
supablock ls organizations/<org>/projects/<ref>/functions
supablock cat organizations/<org>/projects/<ref>/functions/<slug>/info.json

# Look at actual table data (reads via the project's Data API, GET only)
supablock ls  organizations/<org>/projects/<ref>/database/public
supablock cat organizations/<org>/projects/<ref>/database/public/users/rows-000000.csv
```

## Behaviour you should expect

- **Exit codes:** 0 ok · 1 usage/no-such-path (grep: also "no matches") ·
  2 not authenticated · 3 API/network/rate-limit · 4 environment ·
  141 downstream pipe closed. Branch on them.
- **Pipes work like coreutils:** `supablock cat … | jq .`,
  `supablock cat rows-000000.csv | head -5`, and
  `supablock find … -type f | while read f; do …` are all fine — output
  is byte-exact for binary bodies and a closed pipe ends the command
  quietly (exit 141), never with a stack trace.
- **Rate limits:** the Management API allows 120 req/min. Exit 3 with a
  "Rate limited" message means back off and retry. For bursts, start
  `supablock serve &` first (shared warm cache — see above) and keep
  walks scoped with `-maxdepth`; don't loop tightly.
- **Secrets:** `api-keys/secret` renders `REDACTED …` and `secrets.json`
  values render `"REDACTED"` unless the user opted in
  (`supablock config set expose_secrets true`). Do not enable that
  yourself unless the user asks.
- **MCP:** if your host speaks the Model Context Protocol, `supablock mcp`
  serves the same tree as stdio tools (ls, cat, find, grep) — register it
  as command `supablock`, args `["mcp"]` instead of shelling out.
- **Rows:** `database/` reads honour the project's exposed schemas. By
  default they use the service-role key internally (bypassing RLS); the
  key is never printed.
- **Read-only:** every request is a GET; there is nothing you can break.
