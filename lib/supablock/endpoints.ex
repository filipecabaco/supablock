defmodule Supablock.Endpoints do
  @moduledoc """
  Single source of truth for every Supabase Management API endpoint used by
  supablock. All of them are `GET`; nothing else in the codebase hardcodes
  URLs. Each endpoint carries the TTL class the Router uses for caching.

  Verified against the Management API OpenAPI spec (api.supabase.com/api/v1):
  `services` on health is an array parameter (OpenAPI form/explode default —
  repeated `services=` keys, exactly what the official CLI's generated client
  sends), database config lives at `config/database/postgres`, available
  regions require an `organization_slug`, and api-keys returns secrets only
  when `reveal=true`.
  """

  @health_services ~w(auth db realtime rest storage)

  @type key ::
          :orgs
          | :org
          | :org_members
          | :projects
          | :project
          | :health
          | :auth_config
          | :db_config
          | :pgbouncer_config
          | :pooler_config
          | :disk_config
          | :realtime_config
          | :storage_config
          | :buckets
          | :sso_providers
          | :third_party_auth
          | :api_keys
          | :postgrest_config
          | :functions
          | :function
          | :function_body
          | :branches
          | :regions
          | :logs
          | :advisors_security
          | :advisors_performance
          | :typescript_types
          | :secrets
          | :migrations
          | :backups
          | :readonly
          | :network_restrictions
          | :ssl_enforcement
          | :custom_hostname
          | :vanity_subdomain
          | :upgrade_eligibility

  @spec path(key, map) :: String.t()
  def path(key, args \\ %{}), do: build(key, encode_ids(args))

  # `ref`, `slug` and `fn_slug` are interpolated straight into the request
  # path, and they arrive from Management API responses rather than from a
  # constant — so they are percent-encoded here, once, before any clause sees
  # them. Without this a value carrying `/`, `?`, `#` or `..` would steer the
  # request at a different endpoint than the tree path names. (`Client.valid_ref?/1`
  # is the equivalent guard for the per-project *hostname*.) The `:logs` clause
  # encodes its own query parameters, so only these three keys are touched.
  defp encode_ids(args) do
    Enum.reduce([:ref, :slug, :fn_slug], args, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> %{acc | key => segment(value)}
        _absent -> acc
      end
    end)
  end

  # `.` is unreserved, so percent-encoding alone would leave a "." or ".."
  # segment intact — and RFC 3986 dot-segment removal (which the HTTP client
  # applies when resolving the path against the base URL) would then walk the
  # request up the tree. Those two spellings are escaped explicitly; every
  # other value keeps its usual bytes.
  defp segment("."), do: "%2E"
  defp segment(".."), do: "%2E%2E"
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp build(:orgs, _args), do: "/v1/organizations"
  defp build(:org, %{slug: slug}), do: "/v1/organizations/#{slug}"
  defp build(:org_members, %{slug: slug}), do: "/v1/organizations/#{slug}/members"
  defp build(:projects, _args), do: "/v1/projects"
  defp build(:project, %{ref: ref}), do: "/v1/projects/#{ref}"

  defp build(:health, %{ref: ref}) do
    query = Enum.map_join(@health_services, "&", &("services=" <> &1))
    "/v1/projects/#{ref}/health?#{query}"
  end

  defp build(:auth_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth"
  defp build(:db_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/postgres"
  defp build(:realtime_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/realtime"
  defp build(:storage_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/storage"
  defp build(:buckets, %{ref: ref}), do: "/v1/projects/#{ref}/storage/buckets"
  defp build(:sso_providers, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth/sso/providers"
  defp build(:third_party_auth, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth/third-party-auth"
  defp build(:api_keys, %{ref: ref, reveal: true}), do: "/v1/projects/#{ref}/api-keys?reveal=true"
  defp build(:api_keys, %{ref: ref}), do: "/v1/projects/#{ref}/api-keys"
  defp build(:postgrest_config, %{ref: ref}), do: "/v1/projects/#{ref}/postgrest"
  defp build(:functions, %{ref: ref}), do: "/v1/projects/#{ref}/functions"

  defp build(:function, %{ref: ref, fn_slug: fn_slug}),
    do: "/v1/projects/#{ref}/functions/#{fn_slug}"

  defp build(:function_body, %{ref: ref, fn_slug: fn_slug}),
    do: "/v1/projects/#{ref}/functions/#{fn_slug}/body"

  defp build(:branches, %{ref: ref}), do: "/v1/projects/#{ref}/branches"

  defp build(:regions, %{slug: slug}),
    do: "/v1/projects/available-regions?organization_slug=#{slug}"

  defp build(:logs, %{ref: ref, sql: sql, iso_start: iso_start, iso_end: iso_end}),
    do:
      "/v1/projects/#{ref}/analytics/endpoints/logs.all" <>
        "?sql=#{URI.encode_www_form(sql)}" <>
        "&iso_timestamp_start=#{URI.encode_www_form(iso_start)}" <>
        "&iso_timestamp_end=#{URI.encode_www_form(iso_end)}"

  defp build(:advisors_security, %{ref: ref}), do: "/v1/projects/#{ref}/advisors/security"
  defp build(:advisors_performance, %{ref: ref}), do: "/v1/projects/#{ref}/advisors/performance"
  defp build(:typescript_types, %{ref: ref}), do: "/v1/projects/#{ref}/types/typescript"
  defp build(:secrets, %{ref: ref}), do: "/v1/projects/#{ref}/secrets"
  defp build(:migrations, %{ref: ref}), do: "/v1/projects/#{ref}/database/migrations"
  defp build(:backups, %{ref: ref}), do: "/v1/projects/#{ref}/database/backups"
  defp build(:readonly, %{ref: ref}), do: "/v1/projects/#{ref}/readonly"
  defp build(:network_restrictions, %{ref: ref}), do: "/v1/projects/#{ref}/network-restrictions"
  defp build(:ssl_enforcement, %{ref: ref}), do: "/v1/projects/#{ref}/ssl-enforcement"
  defp build(:custom_hostname, %{ref: ref}), do: "/v1/projects/#{ref}/custom-hostname"
  defp build(:vanity_subdomain, %{ref: ref}), do: "/v1/projects/#{ref}/vanity-subdomain"
  defp build(:upgrade_eligibility, %{ref: ref}), do: "/v1/projects/#{ref}/upgrade/eligibility"
  defp build(:pgbouncer_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/pgbouncer"
  defp build(:pooler_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/pooler"
  defp build(:disk_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/disk"

  @doc """
  How to *change* the resource behind `key`, as static documentation only —
  supablock never issues these requests, it merely shows them so an agent
  standing on a read-only file knows the write path instead of guessing it.

  Returns `nil` only for genuinely read-only or derived resources that have
  no write endpoint at all — health, advisors, metrics, logs, generated
  types, org listings, available regions, pgbouncer config (GET-only in the
  spec): those must never be presented as writable. Everything the
  Management API can change carries a clause, including `api_keys`
  (create/rotate/delete). The api-keys *files* render raw key material, so
  consumers must not inline a comment header there — that is a rendering
  concern (a JSON-body guard), not a reason to hide the write path from the
  per-project doc.

  `path` carries `{ref}`/`{slug}` placeholders the caller fills from the
  tree path. A path starting with `https://` is not a Management API
  surface — buckets, for example, are written through the project's own
  Storage API — and `auth` then names the credential to use instead of the
  management token. `cli` is the equivalent `supabase` CLI verb only when
  one genuinely exists — an approximate incantation is worse than none, so
  it stays `nil` otherwise. `body: false` marks endpoints that take no
  request body. Consumers should render the "verify against the reference"
  pointer too: paths and verbs below are checked against the Management API
  OpenAPI spec, but request bodies evolve.
  """
  @type mutation :: %{
          method: String.t(),
          path: String.t(),
          cli: String.t() | nil,
          note: String.t() | nil,
          auth: String.t() | nil,
          body: boolean
        }

  @spec mutation(key) :: mutation | nil
  def mutation(:project),
    do:
      mut("PATCH", "/v1/projects/{ref}",
        note: "Updates project settings (e.g. name). DELETE /v1/projects/{ref} removes the project."
      )

  def mutation(:auth_config),
    do:
      mut("PATCH", "/v1/projects/{ref}/config/auth",
        note: "Partial update — send only the keys you change."
      )

  def mutation(:db_config),
    do: mut("PUT", "/v1/projects/{ref}/config/database/postgres")

  def mutation(:disk_config),
    do: mut("POST", "/v1/projects/{ref}/config/disk")

  def mutation(:pooler_config),
    do: mut("PATCH", "/v1/projects/{ref}/config/database/pooler")

  def mutation(:postgrest_config),
    do: mut("PATCH", "/v1/projects/{ref}/postgrest")

  def mutation(:realtime_config),
    do: mut("PATCH", "/v1/projects/{ref}/config/realtime")

  def mutation(:storage_config),
    do: mut("PATCH", "/v1/projects/{ref}/config/storage")

  def mutation(:secrets),
    do:
      mut("POST", "/v1/projects/{ref}/secrets",
        cli: "supabase secrets set NAME=value",
        note:
          "DELETE the same path with a JSON array of names to remove secrets " <>
            "(CLI: supabase secrets unset NAME)."
      )

  def mutation(:sso_providers),
    do:
      mut("POST", "/v1/projects/{ref}/config/auth/sso/providers",
        note: "PUT .../{slug} updates a provider, DELETE .../{slug} removes it."
      )

  def mutation(:third_party_auth),
    do:
      mut("POST", "/v1/projects/{ref}/config/auth/third-party-auth",
        note: "DELETE .../{slug} removes an integration."
      )

  def mutation(:function),
    do:
      mut("PATCH", "/v1/projects/{ref}/functions/{slug}",
        cli: "supabase functions deploy {slug}",
        note: "PATCH updates metadata; deploy new code with the CLI. DELETE .../{slug} removes."
      )

  def mutation(:buckets),
    do:
      mut("POST", "https://{ref}.supabase.co/storage/v1/bucket",
        auth: "$SUPABASE_SERVICE_ROLE_KEY",
        note:
          "Storage API, not the Management API — authenticate with the secret " <>
            "(service_role) key from api-keys/secret. " <>
            "PUT .../bucket/{slug} updates, DELETE .../bucket/{slug} removes."
      )

  def mutation(:branches),
    do:
      mut("POST", "/v1/projects/{ref}/branches",
        cli: "supabase branches create",
        note:
          "Per-branch operations live at /v1/branches/{branch-id}: PATCH updates, " <>
            "DELETE removes (CLI: supabase branches delete)."
      )

  def mutation(:migrations),
    do:
      mut("POST", "/v1/projects/{ref}/database/migrations",
        cli: "supabase db push",
        note:
          "Applies a migration (version, name, SQL). " <>
            "PUT upserts a migration without applying it."
      )

  def mutation(:backups),
    do:
      mut("PATCH", "/v1/projects/{ref}/database/backups/schedule",
        note: "Changes the backup schedule time only; restores are separate endpoints."
      )

  def mutation(:readonly),
    do:
      mut("POST", "/v1/projects/{ref}/readonly/temporary-disable",
        body: false,
        note: "Disables read-only mode for the next 15 minutes. No request body."
      )

  def mutation(:network_restrictions),
    do: mut("POST", "/v1/projects/{ref}/network-restrictions/apply")

  def mutation(:ssl_enforcement),
    do: mut("PUT", "/v1/projects/{ref}/ssl-enforcement")

  def mutation(:custom_hostname),
    do:
      mut("POST", "/v1/projects/{ref}/custom-hostname/initialize",
        note: "Then POST .../custom-hostname/reverify and .../custom-hostname/activate."
      )

  def mutation(:vanity_subdomain),
    do: mut("POST", "/v1/projects/{ref}/vanity-subdomain/activate")

  def mutation(:api_keys),
    do:
      mut("POST", "/v1/projects/{ref}/api-keys",
        note:
          "Creates an API key. PATCH/DELETE /v1/projects/{ref}/api-keys/{id} rotates or removes one."
      )

  def mutation(:upgrade_eligibility),
    do:
      mut("POST", "/v1/projects/{ref}/upgrade",
        note: "Upgrades the project's Postgres version; check this file (eligibility) first."
      )

  def mutation(_key), do: nil

  defp mut(method, path, opts \\ []) do
    %{
      method: method,
      path: path,
      cli: opts[:cli],
      note: opts[:note],
      auth: opts[:auth],
      body: Keyword.get(opts, :body, true)
    }
  end

  @doc "TTL class for the endpoint, matching the `ttl` config map keys."
  @spec ttl_class(key) :: String.t()
  def ttl_class(key) when key in [:orgs, :org, :org_members], do: "orgs"
  def ttl_class(key) when key in [:projects, :project, :auth_config, :db_config], do: "project"

  def ttl_class(key)
      when key in [:realtime_config, :storage_config, :buckets, :sso_providers, :third_party_auth],
      do: "project"

  def ttl_class(key) when key in [:functions, :function, :function_body, :branches], do: "project"
  def ttl_class(:postgrest_config), do: "project"

  def ttl_class(key)
      when key in [:pgbouncer_config, :pooler_config, :disk_config, :secrets, :migrations],
      do: "project"

  def ttl_class(key) when key in [:backups, :readonly], do: "project"
  def ttl_class(:health), do: "health"
  def ttl_class(key) when key in [:api_keys, :regions], do: "static"

  def ttl_class(key)
      when key in [:advisors_security, :advisors_performance, :typescript_types],
      do: "static"

  def ttl_class(key)
      when key in [
             :network_restrictions,
             :ssl_enforcement,
             :custom_hostname,
             :vanity_subdomain,
             :upgrade_eligibility
           ],
      do: "static"

  def ttl_class(:logs), do: "logs"
end
