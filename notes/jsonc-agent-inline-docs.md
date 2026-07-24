# Exploration: inline "how to change it" docs for agents

> **Status (2026-07): IMPLEMENTED (the recommendation below).** Every
> project now carries a `how-to-change.md` (default, `jq`-clean) rendered
> from a single source of truth, `Supablock.Endpoints.mutation/1`; the
> literal in-body JSONC header is available opt-in via `config set
> inline_docs true`. See `lib/supablock/write_docs.ex`,
> `lib/supablock/endpoints.ex` (`mutation/1`), and the Router wiring.
> supablock stays read-only — see "Non-negotiable: still GET-only" below.
> The rest of this note is the original exploration that led there; the
> "granularity" open question (per-file sibling vs per-directory doc) was
> resolved to **one `how-to-change.md` per project**: a sibling per mutable
> file would add ~30 entries across eight listing sites (and their tests,
> the docker e2e, README and completions) for marginal locality; the
> per-project doc is discoverable, deterministic, and costs no extra API
> request. The opt-in inline header still gives true per-file locality when
> you want it.

## The idea

> "perhaps each file could be a jsonc and then you can add comments with
> the relevant API/CLI commands the agent needs to make changes"
>
> "I didn't mean add writes to the filesystem, just add comments exposing
> to agents how they can update the relevant services (essentially inline
> docs)"
>   — Filipe Cabaço

Today supablock answers *"what is the state of my Supabase account?"* An
agent can `cat config/auth.json` and read `"disable_signup": true`, but the
tree says nothing about *how* to flip it. The agent has to leave the
filesystem, guess the Management API shape, and hope. The proposal is to
carry the **write path** alongside the **read**: next to each mutable
resource, show the exact `curl`/CLI command that changes it. supablock
itself still never writes — it just stops making the agent guess.

This is a documentation feature, not a mutation feature. The output is
strings the agent then runs *itself*, with its own credentials, outside
supablock.

## Non-negotiable: still GET-only

The write metadata is **static text derived from the endpoint map** — it is
not fetched, not templated from live secrets, and never sent anywhere. No
new HTTP verb enters the codebase; `Supablock.Client` stays GET-only, the
mount stays `-o ro`. The redaction rules are untouched: a command string
like `curl … -d '{"jwt_secret":"<new-secret>"}'` carries a placeholder, not
a real value. Nothing about the read-only contract changes in any option
below.

## Where the write metadata lives

`Supablock.Endpoints` is already the single source of truth for every URL
supablock touches, keyed by an atom (`:auth_config`, `:storage_config`, …)
and carrying its TTL class. It is the natural home for the *mutation*
companion to each `GET`. Sketch:

```elixir
# lib/supablock/endpoints.ex
@doc "How to mutate the resource behind `key`, or nil if it is read-only/derived."
@spec mutation(key) :: %{method: String.t(), path: String.t(),
                          cli: String.t() | nil, note: String.t() | nil} | nil
def mutation(:auth_config), do: %{
  method: "PATCH",
  path: "/v1/projects/{ref}/config/auth",
  cli: nil,  # no first-class CLI verb; config.toml + `supabase db push` is indirect
  note: "Body is a partial auth config; send only the keys you change."
}
def mutation(:storage_config), do: %{method: "PATCH", path: "/v1/projects/{ref}/config/storage", cli: nil, note: nil}
def mutation(:secrets),        do: %{method: "POST",  path: "/v1/projects/{ref}/secrets",         cli: "supabase secrets set NAME=value", note: "DELETE the same path to remove."}
def mutation(:function),       do: %{method: "PATCH", path: "/v1/projects/{ref}/functions/{slug}", cli: "supabase functions deploy {slug}", note: nil}
# health, advisors, metrics, logs, types.ts, api-keys → read-only/derived:
def mutation(_key), do: nil
```

Keeping it here means the read path and the write path can never drift into
different files, and one `mutation/1` clause is the whole edit to teach
supablock a new command. Honesty rule: a clause exists **only** where a real
write endpoint exists. Derived/computed files (`health`, `metrics`,
`advisors/*`, `types.ts`, `api-keys/*`) return `nil` and get no doc — the
tree must never imply you can `PATCH` a lint result.

## The tension: JSONC breaks the "clean JSON" contract

Filipe's literal phrasing is "each file could be a jsonc" — a `//` comment
header inside the body. That is the most faithful reading, and it is also
the one that collides hardest with what makes supablock nice:

- **`jq` is the canonical tool here.** The README leans on ordinary Unix
  tools, and agents will pipe `cat config/auth.json | jq '.site_url'`.
  `jq`, `python -m json.tool`, and supablock's own `Jason.decode!` all
  **reject** `//` comments. A JSONC body silently breaks the read pipeline
  the feature is supposed to complement.
- **`.json` is load-bearing.** ~105 `.json` path assertions in `test/`, the
  docker e2e `schema.json` checks, every README one-liner, the MCP tool
  descriptions, `docs/llms.txt`, and shell completions all name `.json`.
  Renaming to `.jsonc` is a wide, mechanical, break-everything churn.
- **Determinism holds either way.** Comments are static, so byte-stable
  `stat` sizes and clean cross-project `diff` survive. That guarantee is
  *not* the blocker — parseability is.

So the real design question is **placement**, not whether to do it.

## Options

| # | Placement | Faithful to "jsonc" | Keeps `jq` clean | Churn | Discoverable |
|---|---|---|---|---|---|
| A | `//` header inside `*.json` body | ✅ | ❌ breaks parsers | low | ✅ (it's right there) |
| B | Rename mutable files `*.jsonc` | ✅ | ❌ + ⚠️ path churn | high | ✅ |
| C | Sibling companion, e.g. `config/auth.json` + `config/auth.write.md` | ➖ | ✅ | low | ✅ (`ls` shows it) |
| D | One `config/how-to-change.md` per dir | ➖ | ✅ | low | ✅ |
| E | Config-gated JSONC header (A, default **off**) | ✅ when on | ✅ by default | low | ✅ |

- **A / B** honour the wording but sacrifice the read pipeline — a poor
  trade for a project whose pitch is "inspect with `cat`, `grep`, `jq`,
  `diff`."
- **C** keeps every existing `.json` byte-identical and jq-clean, and adds
  a greppable, `cat`-able companion an agent finds by listing the directory.
  It reframes "inline" as "adjacent" — arguably closer to Filipe's *intent*
  ("essentially inline docs") than his *literal example*.
- **E** is the compromise that preserves the exact wording: default output
  is unchanged pure JSON; `supablock config set inline_docs true` prepends
  the `//` header for agents that opt into JSONC and pass `--json-comments`
  to their parser. It composes with the existing config surface
  (`expose_secrets`, `db_*`) and ships zero risk to current users.

## Recommendation

**Ship C as the default, gate A behind E.** Concretely:

1. Add `Endpoints.mutation/1` (the source of truth above).
2. For every mutable resource, expose a companion `*.write.md` sibling
   rendered from `mutation/1` — non-breaking, jq-clean, discoverable via
   `ls`. A directory-level `how-to-change.md` (option D) can aggregate them
   if per-file siblings feel noisy.
3. Add a `inline_docs` config key (default `false`). When on, `Render.json/1`
   for mutable resources prepends the same `mutation/1` text as a `//`
   header — this is Filipe's literal JSONC, opt-in, for agents that want it
   truly inline and parse with comment support.

This gives Filipe the JSONC he described, gives everyone else an unbroken
`jq`, and keeps one source of truth feeding both surfaces.

## Worked example

`config/auth.json` today:

```json
{
  "disable_signup": true,
  "site_url": "https://example.com"
}
```

Companion `config/auth.write.md` (option C), or the header injected when
`inline_docs` is on (option E):

```
// To change this resource (supablock is read-only; run this yourself):
//   PATCH /v1/projects/{ref}/config/auth
//   Send only the keys you change (partial update).
//
//   curl -X PATCH \
//     https://api.supabase.com/v1/projects/{ref}/config/auth \
//     -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
//     -H "Content-Type: application/json" \
//     -d '{"disable_signup": false}'
//
// No first-class CLI verb; the config.toml + `supabase db push` route is indirect.
```

`{ref}` is already known from the path the agent is standing in
(`organizations/<org>/projects/<ref>/…`), so the render can substitute the
real ref rather than leave a placeholder — a nice touch that costs nothing.

## Coverage: which files get a doc

Mutable (get a `mutation/1` clause; verbs verified against the Management
API OpenAPI spec, 2026-07):

- `config/auth.json` `PATCH .../config/auth` ·
  `config/database.json` `PUT .../config/database/postgres` ·
  `config/disk.json` `POST .../config/disk` ·
  `config/pooler.json` `PATCH` · `config/postgrest.json` `PATCH` ·
  `config/realtime.json` `PATCH` · `config/storage.json` `PATCH`
  (note: **not** uniformly PATCH, and `pgbouncer` is GET-only in the spec —
  read-only)
- `config/auth/sso/*` — `POST`, `PUT`/`DELETE .../{id}`;
  `config/auth/third-party/*` — `POST`, `DELETE .../{id}`
- `secrets.json` — `POST`/`DELETE .../secrets` · `supabase secrets set/unset`
- `functions/<slug>/*` — `PATCH`/`DELETE .../functions/{slug}` ·
  `supabase functions deploy <slug>`
- `storage/buckets/*` — **not a Management API surface** (its buckets
  endpoint is GET-only): writes go through the project's Storage API
  (`POST {ref}.supabase.co/storage/v1/bucket`, `PUT`/`DELETE
  .../bucket/{id}`) with the secret key, verified against the official
  storage-js client
- `branches/*` — `POST .../projects/{ref}/branches`; per-branch ops at
  `/v1/branches/{branch-id}` · `supabase branches create/delete`
- `database/migrations.json` — `POST .../database/migrations` applies ·
  `supabase db push`; `database/backups.json` — `PATCH
  .../backups/schedule`; `database/readonly.json` — `POST
  .../readonly/temporary-disable` (15 minutes, no body)
- `network/*` — `POST .../network-restrictions/apply`, `PUT
  .../ssl-enforcement`, `POST .../custom-hostname/initialize`, `POST
  .../vanity-subdomain/activate`
- `database/<schema>/<table>/*` (rows) — the honest path is the Data API /
  SQL / migrations, not documented per-file

Read-only / derived (return `nil`, no doc — must not imply writability):

- `health`, `metrics`, `logs/*`, `advisors/*.json`, `types.ts`,
  `config/pgbouncer.json`, `info.json` listings, `upgrade-eligibility.json`
- `api-keys/*` — deliberately `nil` even though rotation endpoints exist
  (`POST/PATCH/DELETE .../api-keys`): the files render raw key material,
  where an inline comment header would corrupt reads

## Open questions for Filipe

1. **Literal JSONC vs adjacent doc.** Is the goal specifically JSONC
   in-body (accept the `jq` cost, default it on), or is "how do I change
   this, right next to the data" the real goal (companion file, `jq` stays
   clean)? This is the one load-bearing call. The recommendation hedges by
   shipping both, JSONC opt-in.
2. **Per-file `*.write.md` vs one `how-to-change.md` per directory** —
   noise vs locality.
3. **Substitute the real `{ref}`/`{slug}`** into the commands (agent
   copy-pastes and runs) **or** keep placeholders (portable, but one more
   step)? Substituting seems strictly more useful and costs nothing.
4. **CLI honesty.** Several resources have no clean `supabase` CLI verb
   (most `config/*` PATCHes). Prefer showing only the truthful Management
   API `curl` there rather than an approximate CLI incantation. Agreed?
