# Thin Management API stub for the Docker image e2e.
#
# The supabase CLI's local stack (`supabase start`) emulates a real
# *project* — Postgres, PostgREST, working API keys — but the platform
# Management API (organization/project metadata) exists only at
# api.supabase.com and has no local emulator. This stub serves just that
# thin metadata layer and points supablock at the real local stack: its
# api-keys endpoint returns the stack's actual anon/service_role JWTs
# (passed in via the ANON_KEY and SERVICE_ROLE_KEY environment variables,
# from `supabase status -o env`), so the `database/` tree reads real
# seeded rows through the real PostgREST.
#
# The health endpoint is synthesized — the local stack exposes no
# Management-API-shaped health resource.
#
# A standalone Mix.install script (francis, like the app itself) so the
# workflow can run it with nothing but the official elixir image.
#
# Usage: ANON_KEY=... SERVICE_ROLE_KEY=... elixir mgmt_api_stub.exs [port]
#        (default port 54340, binds 127.0.0.1)

Mix.install([{:francis, "~> 0.3.3"}])

for var <- ~w(ANON_KEY SERVICE_ROLE_KEY) do
  System.get_env(var) ||
    (IO.puts(:stderr, "mgmt_api_stub: #{var} must be set (see: supabase status -o env)") &&
       System.halt(1))
end

# The module body cannot reach script locals, so the port travels via the
# environment (a .exs compiles at run time, so argv is already available).
port =
  case System.argv() do
    [port | _rest] -> String.to_integer(port)
    [] -> 54340
  end

System.put_env("STUB_PORT", Integer.to_string(port))

defmodule MgmtApiStub do
  use Francis,
    bandit_opts: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("STUB_PORT"))]

  @ref "supablocklocal123456"

  get("/v1/organizations", fn _ ->
    [%{id: "org-local", slug: "org-local", name: "Local Org"}]
  end)

  get("/v1/projects", fn _ ->
    [
      %{
        id: @ref,
        organization_id: "org-local",
        name: "Local Project (supabase start)",
        region: "local",
        status: "ACTIVE_HEALTHY",
        created_at: "2026-01-01T00:00:00Z"
      }
    ]
  end)

  get("/v1/projects/#{@ref}/health", fn _ ->
    [
      %{name: "db", healthy: true, status: "ACTIVE_HEALTHY"},
      %{name: "rest", healthy: true, status: "ACTIVE_HEALTHY"}
    ]
  end)

  get("/v1/projects/#{@ref}/api-keys", fn _ ->
    [
      %{name: "anon", api_key: System.fetch_env!("ANON_KEY")},
      %{name: "service_role", api_key: System.fetch_env!("SERVICE_ROLE_KEY")}
    ]
  end)

  # Exposed schemas drive the database/ tree: naming `app` next to `public`
  # here is what makes supablock list both (config.toml adds `app` to the
  # local PostgREST's schemas so the reads actually work).
  get("/v1/projects/#{@ref}/postgrest", fn _ ->
    %{
      db_schema: "public, app",
      max_rows: 1000,
      db_extra_search_path: "public, extensions"
    }
  end)

  # database/{backups,migrations,readonly}.json render these endpoints as
  # files. A FUSE mount stats every entry a readdir returns, so they must
  # answer 200 — a 404 turns into ENOENT and breaks plain `ls` of database/.
  get("/v1/projects/#{@ref}/database/backups", fn _ ->
    %{region: "local", pitr_enabled: false, walg_enabled: false, backups: []}
  end)

  get("/v1/projects/#{@ref}/database/migrations", fn _ ->
    [%{version: "20260101000000", name: "e2e"}]
  end)

  get("/v1/projects/#{@ref}/readonly", fn _ ->
    %{enabled: false, override_enabled: false}
  end)

  unmatched(fn _ -> %{message: "not found"} end)
end

{:ok, _pid} = MgmtApiStub.start()
IO.puts(:stderr, "mgmt_api_stub: serving on 127.0.0.1:#{port}")
Process.sleep(:infinity)
