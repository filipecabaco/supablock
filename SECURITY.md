# Security

## Reporting a vulnerability

Report privately through [GitHub Security
Advisories](https://github.com/filipecabaco/supablock/security/advisories/new).
Please don't open a public issue for anything exploitable.

## What supablock can do

The blast radius is deliberately small, and most of it is enforced by
construction rather than by policy:

* **Reads only.** Every request against a Supabase account is a `GET`. No
  code path issues a `POST`, `PATCH`, `PUT` or `DELETE` to an account
  resource. The only non-GET requests in the codebase are the OAuth
  token/revoke calls that manage supablock's own session.
* **Read-only at the kernel too.** A mount is `-o ro` with `0444`/`0555`
  nodes; writes fail with `EROFS`.
* **Server-side enforcement, when available.** Registering the OAuth app
  read-only means read-only is enforced by Supabase, not by supablock.
* **Redaction by default.** `api-keys/secret` and every value in
  `secrets.json` render as `REDACTED` unless the user opts in with
  `config set expose_secrets true`. Redaction happens at render time, so
  snapshots never contain the values either.
* **Credential handling.** The credential lives at
  `~/.config/supablock/credentials` (`0600`, in a `0700` directory),
  written atomically. It is never logged, never rendered into the tree,
  and masked in `status`. `SUPABLOCK_TOKEN` overrides it and touches no
  disk. Row browsing uses a key supablock fetches itself — no database
  password, and the key is never printed.

## The agent skill

`skills/supablock/SKILL.md` is written for a threat model where the agent
reading an account is not the only author of what it reads. Its properties:

* **Bounded capability.** The skill declares `allowed-tools:
  Bash(supablock:*)` — one read-only command, nothing else. There is no
  downloader, package manager, container runtime or shell utility in its
  grant, and every recipe is expressed in supablock's own
  `ls`/`cat`/`head`/`find`/`grep` so the bound is sufficient rather than
  aspirational.
* **No installation path.** The skill contains no install command and no
  download URL. If the tool is absent, the agent's instruction is to stop
  and tell the user. Install options live in the README, for a human to
  choose — see [Distribution](#distribution) below.
* **Untrusted output, with a stated boundary.** Table rows, project and
  bucket names, config strings, deployed function bodies, advisor and log
  messages are third-party text. The skill's first section establishes
  that account content is data, quotes it inside a fence labelled with its
  tree path, and forbids it from becoming a command, path, URL, tool
  argument or scope change. `supablock mcp` repeats the same rule in every
  tool description, so the boundary holds whichever way a host reaches the
  tree.
* **The credential is never handled by the agent.** The skill directs the
  user to run `supablock login` themselves or export `SUPABLOCK_TOKEN` in
  their own shell, and forbids tokens in the conversation, on command
  lines, in files or in output. It recommends a scoped, revocable token
  over an interactive session credential.
* **Data minimisation.** `database/` reads resolve with a service key, so
  a rows file is the whole table. The skill prefers `schema.json` over
  rows, bounds row reads, and asks for findings rather than dumps —
  because everything read lands in a transcript.
* **Writes are delivered, not executed.** Each project carries a
  `how-to-change.md` documenting the Management API / CLI request for
  every mutable resource. It is static text; supablock issues none of it.
  The skill cannot run those requests — `curl` and `supabase` are outside
  its grant — so it hands the filled-in request to the user, who runs it
  with their own credential. Content read out of an account is never a
  reason to make a change.
* **Privileges are never requested to unblock work.** Mounting is the only
  feature needing FUSE. Every read works without it, so the skill has no
  reason to ask for elevated privileges and no instructions for obtaining
  them.

## Distribution

Three channels, all verifiable:

* **Native installer** — checks the downloaded binary against the release's
  `SHA256SUMS` and aborts on mismatch. `SUPABLOCK_SHA256=<digest>` pins a
  digest obtained elsewhere.
* **Build provenance** — release binaries carry a [sigstore attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
  tying them to the workflow, repo and commit that produced them:
  `gh attestation verify $(command -v supablock) --repo filipecabaco/supablock`.
  This is the check a checksum served from the same host cannot replace.
* **npm** — `npm install -g supablock` ships the same binaries inside the
  tarball under npm's integrity hashes, with no install script.
* **Docker** — reads need no capabilities and no host devices; pin by
  digest for reproducibility.

## Known scanner findings

Automated skill scanners flag the following. They are accurate about what
they see; here is the reasoning.

| Finding | Where | Status |
| --- | --- | --- |
| `curl … install.sh \| sh` | README, docs site | **Accepted, human-facing only.** It is one of three documented install channels, with checksum verification and a documented two-step read-then-run form. It appears in no agent-facing surface: not in `SKILL.md`, not in `llms.txt`. |
| Skill accesses sensitive account state | `SKILL.md` | **By design, read-only.** Auditing configuration and keys is the purpose. Every request is a `GET`, secrets are redacted by default, and the skill minimises what it opens. |
| Skill processes untrusted external data | `SKILL.md` | **Known and addressed.** This is the primary threat the skill is written against — see the boundary described above. |
| Elevated container flags for FUSE | README | **Accepted, human-facing only.** Documented behind a collapsed section describing exactly what the flags cost, for users who want a mount. The agent skill neither names nor requests them. |

If a scan surfaces something outside this table, it is worth treating as a
real finding.
