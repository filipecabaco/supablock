# Plan: OAuth2 login with a Francis-powered localhost callback

> **Decision (2026-07): replicate the official supabase CLI flow instead.**
> `superblock login` now implements the session-polling flow described
> under "The official supabase CLI" below — ephemeral ECDH P-256 keypair,
> dashboard login URL, verification code typed into the CLI, token fetched
> from `/platform/cli/login/{session_id}` and decrypted locally
> (`Superblock.BrowserLogin`). Accepted trade-offs, eyes open:
>
> * it rides the **private `/platform/*` API** — if it changes upstream,
>   `login --token` remains as the escape hatch (and is tested);
> * the result is a **full-power long-lived PAT**, not a scoped OAuth
>   token — read-only stays a client-side promise for now.
>
> Why anyway: no OAuth app registration or embedded client secret, no
> localhost callback server (works over SSH), identical UX to the tool our
> users already know, and end-to-end-encrypted token delivery. Francis is
> therefore **not needed for login**; the OAuth plan below is retained as
> the future path to server-enforced read-only scopes, and the auto-start
> service (`Superblock.Service`) is already shipped.

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

## Research: how Supabase and other CLIs actually do this

### The official supabase CLI (read from source, v2.40.7)

`supabase login` does **not** use OAuth. From `internal/login/login.go`:

1. The CLI generates an ephemeral **ECDH P-256 keypair**, a session UUID,
   and a token name derived from the device (`cli_user@host_hash`).
2. It opens `https://supabase.com/dashboard/cli/login?session_id=…&
   token_name=…&public_key=<hex>` (and always prints the URL as a
   fallback).
3. The logged-in dashboard mints a **regular PAT**, encrypts it with
   AES-GCM under the ECDH shared secret, and shows the user a short
   verification code.
4. The user types the code into the CLI, which fetches
   `GET api.supabase.com/platform/cli/login/{session_id}?device_code=…`,
   decrypts the token locally, and saves it.

Properties: no localhost server, no OAuth app, no client secret, works
over SSH, end-to-end-encrypted token delivery. **Why superblock should
not copy it:** it rides the private, undocumented `/platform/*` API (not
`/v1`), so it can change without notice and is not an intended
third-party surface; and it produces a full-power, long-lived PAT — no
scopes, no expiry — which is exactly what we want to move away from.
Ideas worth stealing regardless: device-derived token names, always
printing the URL, and a code entered *into the CLI* as the
session-binding step.

### The supported third-party path: Supabase OAuth apps

From the integration docs (`build-a-supabase-oauth-integration`):

* Authorize: `GET https://api.supabase.com/v1/oauth/authorize` with
  `client_id`, `redirect_uri`, `response_type=code`, `state`, and PKCE
  (`code_challenge`, `code_challenge_method=S256` — "strongly
  recommended").
* Exchange/refresh: `POST https://api.supabase.com/v1/oauth/token` with
  `grant_type=authorization_code` (+ `code_verifier`) or
  `grant_type=refresh_token`. The docs authenticate this call with
  **client id + secret via basic auth** — there is no documented
  secret-less public-client mode, so a distributed CLI must embed the
  secret (see security notes).
* Access tokens are short-lived; **refresh tokens are single-use** (each
  refresh returns a new one — the store must be updated atomically on
  every refresh, and a crashed refresh must not lose the new token).
* Users can revoke a specific OAuth app at any time; revocation kills all
  its sessions and refresh tokens. Scopes are fixed at app registration
  (read/write per resource group) — registering read-only makes the
  read-only guarantee server-enforced.
* Management API OAuth tokens follow the `sbp_oauth_<40 hex>` shape (the
  official CLI's token regex accepts both), so existing
  masking/scrubbing extends naturally.

Note: Supabase also ships a separate per-project **OAuth 2.1 server**
(Supabase Auth, for end-user apps/MCP). That is a different product; the
Management API integration above is the relevant one here.

### How the wider ecosystem does CLI auth

* **Loopback + PKCE (RFC 8252)** — gcloud and most modern CLIs: temporary
  HTTP server on 127.0.0.1, browser to the authorize endpoint, PKCE S256
  mandatory. PKCE is what makes the loopback safe: a hostile local
  process that races the port and steals the code cannot exchange it
  without the verifier.
* **Device authorization grant (RFC 8628)** — `gh auth login`'s default:
  the CLI shows a user code, the user enters it at a verification URL on
  any device. The only flow that works headless/over SSH — but Supabase's
  Management API does not offer a device grant today.
* **Vendor session-polling** — supabase CLI (above), Stripe and Fly do
  similar browser+poll pairing. First-party only; depends on private
  endpoints.
* **The 2026 convergence** (gh, vercel, stripe, supabase): *try loopback
  first, fall back to device flow when headless, always keep a
  paste-a-token escape hatch.* Without a device grant at Supabase, our
  version of that ladder is: loopback → `--no-browser` (print URL; the
  redirect still needs to reach the user's machine, e.g.
  `ssh -L 53682:localhost:53682`) → PAT paste.
* **Token storage**: gh stores tokens in the OS keyring when available.
  Worth a follow-up milestone: `secret-tool` (Linux) / Keychain (macOS)
  with the 0600 file as fallback.

### Francis fit

`use Francis, bandit_opts: [...]` gives a Plug/Bandit app with a route DSL
(`get "/callback", fn conn -> ... end`) and a supervisor `child_spec` —
startable and stoppable on demand, which is exactly the shape of an
ephemeral login callback server.

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
  supersedes the v1 "no token refresh" out-of-scope line. Because Supabase
  refresh tokens are **single-use**, the refresh must be serialized
  through one process and the new pair written to disk (tmp file + rename)
  *before* the old one is discarded — a crash mid-refresh must never
  strand the user logged out.
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

1. Credentials v2 + Client refresh (single-use-safe, atomic writes),
   stub-tested (no UI change yet).
2. Francis dep closure + `AuthCallback` + `OAuth`; `login` switches to the
   browser flow with `--token`/`--no-browser` fallbacks.
3. StubServer OAuth endpoints + e2e extension.
4. README / landing page / doctor (`doctor` learns to check the callback
   port is free).
5. (Optional, later) OS keyring storage for the refresh token
   (secret-tool / macOS Keychain, 0600 file fallback), and a hosted
   token-exchange broker to un-embed the client secret — a one-endpoint
   Francis app would do.
