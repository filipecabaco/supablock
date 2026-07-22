# supablock

Browse and verify a Supabase account as a **read-only filesystem**.
supablock mirrors the Supabase Management API (organizations, projects,
config, API keys, edge functions, storage buckets, auth providers,
branches) and each project's table rows as a directory tree. Every request
is a GET — the tool physically cannot create, change or delete anything.

This package delivers the prebuilt single-file binary through the npm
registry, so it installs in restricted sandboxes (CI, AI agents) where
GitHub's release downloads are blocked but `registry.npmjs.org` is
allowlisted. The binary itself ships inside a per-platform
optionalDependency; this package is a thin launcher.

```bash
npm install -g supablock     # or one-shot: npx supablock ls organizations

export SUPABLOCK_TOKEN=sbp_...   # supabase.com/dashboard/account/tokens
supablock ls organizations
supablock cat organizations/<org>/projects/<ref>/health
```

Supported platforms: Linux x64/arm64, macOS arm64. Everything else:
[build from source](https://github.com/filipecabaco/supablock#building-from-source).

Full documentation: [filipecabaco.github.io/supablock](https://filipecabaco.github.io/supablock)
· [README](https://github.com/filipecabaco/supablock)
· [llms.txt](https://filipecabaco.github.io/supablock/llms.txt)
