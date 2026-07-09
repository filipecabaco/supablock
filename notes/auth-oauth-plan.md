# Plan: OAuth2 login with a Francis-powered localhost callback

> Companion feature, already implemented: `superblock service
> install|uninstall|status` auto-starts the mount at login via a systemd
> user unit (Linux) or launchd agent (macOS) — see `Superblock.Service`.
> OAuth + auto-start compose: the service reads the same credentials file,
> and once refresh tokens land (milestone 1 below) a service-managed mount
> keeps itself authenticated without the user ever re-pasting a token.

Replaces token-paste as the default `superblock login` experience. Reviewed
against the Supabase OAuth integration docs
(supabase.com/docs/guides/integrations/build-a-supabase-oauth-integration)
and the Francis source (github.com/francis-build/francis, v0.3.3).

## Why

Today `login` means: open the dashboard, create a personal access token,
paste it. That PAT is long-lived and all-powerful (it can delete projects —
superblock just chooses not to). OAuth fixes both:

* browser login with an explicit consent screen, no copy/paste;
* tokens are **short-lived, refreshable, and scoped** — the OAuth app is
  registered with read-only scopes, so even a leaked token cannot mutate
  anything. That upgrades hard rule #1 (read-only) from a client-side
  promise to a server-side guarantee.

## Verified facts

* Authorize: `GET https://api.supabase.com/v1/oauth/authorize` with
  `client_id`, `redirect_uri`, `response_type=code`, `state`, and PKCE
  (`code_challenge`, `code_challenge_method=S256`; strongly recommended by
  the docs).
* Exchange/refresh: `POST https://api.supabase.com/v1/oauth/token` with
  `grant_type=authorization_code` (+ `code_verifier`) or `refresh_token`.
  The docs authenticate this call with client id + secret (basic auth).
* OAuth apps are registered per-organization in the dashboard, with a
  fixed `redirect_uri` and a scope selection (read/write per resource
  group). Management API OAuth access tokens follow the
  `sbp_oauth_<40 hex>` shape, so the existing masking/scrubbing patterns
  extend naturally.
* Francis: `use Francis, bandit_opts: [...]` gives a Plug/Bandit app with a
  route DSL (`get "/callback", fn conn -> ... end`) and a supervisor
  `child_spec/start` — startable and stoppable on demand, which is exactly
  the shape of an ephemeral login callback server.

## Flow

```
superblock login
  │ 1. generate state + PKCE verifier/challenge
  │ 2. start Superblock.AuthCallback (Francis) on 127.0.0.1:53682
  │ 3. open browser at api.supabase.com/v1/oauth/authorize?...
  │        (fallback: print the URL when no DISPLAY / --no-browser)
  │ 4. user consents; Supabase redirects to
  │        http://localhost:53682/callback?code=...&state=...
  │ 5. Francis handler checks state, hands the code to the waiting
  │        login process, renders a small "you can close this tab" page
  │ 6. stop the server; POST /v1/oauth/token (code + verifier)
  │ 7. store {access, refresh, expires_at} at 0600
  └─ ✓ Logged in as <org count> organizations
```

## Changes by module

* **`Superblock.AuthCallback`** (new): `use Francis,
  bandit_opts: [ip: {127, 0, 0, 1}, port: 53682]`; one GET route; sends
  `{:oauth_code, code}` to the login process; 60–120s timeout, then the
  CLI falls back with a clear error. Loopback-only binding, single use.
* **`Superblock.OAuth`** (new): builds the authorize URL, PKCE pair,
  exchanges/refreshes tokens via the existing `Client` plumbing (deadline,
  scrubbing, proxy handling). Client id (and the not-actually-secret client
  secret, see below) ship as config with env overrides.
* **`Superblock.Credentials` v2**: file becomes JSON —
  `{"type":"oauth","access_token":…,"refresh_token":…,"expires_at":…}` —
  while the loader stays backward-compatible with the legacy single-line
  PAT and the `SUPERBLOCK_TOKEN` env override (CI path unchanged).
* **`Superblock.Client`**: when the stored credential is OAuth and expires
  within ~60s, refresh before the request (single-flight, same pattern as
  the cache); on a 401, refresh once and retry; a failed refresh maps to
  `EACCES` plus the "run: superblock login" hint. This deliberately
  supersedes the v1 "no token refresh" out-of-scope line.
* **CLI**: `login` defaults to OAuth; `login --token sbp_…` keeps the PAT
  path; `--no-browser` prints the URL instead of spawning
  `xdg-open`/`open`. `logout` deletes the credential (and calls the revoke
  endpoint if one exists — to verify during implementation).
* **Deps**: `{:francis, git, tag: "v0.3.3"}` plus its closure as git pins,
  matching the repo's convention — bandit, thousand_island, websock,
  websock_adapter (plug/plug_crypto/hpax/telemetry are already pinned).
  Started on demand during `login` only, like userfs at mount: boot stays
  a no-op.

## Security notes

* PKCE (S256) + `state` on every flow; callback binds to 127.0.0.1 only.
* The client secret embedded in a distributed CLI is **not confidential**
  — that is the standard public-client reality (gh, gcloud et al. ship
  theirs). Mitigations: PKCE, loopback-only redirect URI, and read-only
  scopes so the blast radius of app impersonation is "can read what the
  user consents to". A hosted token-exchange broker could remove the
  embedded secret later; explicitly out of scope now.
* Refresh tokens are as sensitive as PATs: same 0600 file, same scrubbing
  (extend `redact/2` to the stored refresh token), never rendered in the
  tree or logs.

## Testing

* `StubServer` grows `POST /v1/oauth/token` and a fake authorize page so
  the whole dance runs hermetically; a unit test drives the Francis
  callback with a real local HTTP request (mirrors `control_test`).
* Client refresh: stub returns 401 once then 200 → exactly one refresh;
  expiry-window refresh is single-flight under 50 concurrent reads.
* e2e: `login --no-browser` prints the authorize URL; the test curls the
  callback with code+state itself, then the existing mount/compare flow
  runs on the OAuth credential.

## Prerequisite (owner action)

Register the OAuth app under the Supabase org (dashboard → org settings →
OAuth Apps): name `superblock`, redirect `http://localhost:53682/callback`,
read-only scopes for organizations, projects, rest/auth/database config,
edge functions, and (optionally) secrets. Drop the client id into
`Superblock.OAuth`'s defaults.

## Milestones

1. Credentials v2 + Client refresh, stub-tested (no UI change yet).
2. Francis dep closure + `AuthCallback` + `OAuth`; `login` switches to the
   browser flow with `--token`/`--no-browser` fallbacks.
3. StubServer OAuth endpoints + e2e extension.
4. README / landing page / doctor (`doctor` learns to check the callback
   port is free).
