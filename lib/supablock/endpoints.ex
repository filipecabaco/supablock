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
  def path(key, args \\ %{})

  def path(:orgs, _args), do: "/v1/organizations"
  def path(:org, %{slug: slug}), do: "/v1/organizations/#{slug}"
  def path(:org_members, %{slug: slug}), do: "/v1/organizations/#{slug}/members"
  def path(:projects, _args), do: "/v1/projects"
  def path(:project, %{ref: ref}), do: "/v1/projects/#{ref}"

  def path(:health, %{ref: ref}) do
    query = Enum.map_join(@health_services, "&", &("services=" <> &1))
    "/v1/projects/#{ref}/health?#{query}"
  end

  def path(:auth_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth"
  def path(:db_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/postgres"
  def path(:realtime_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/realtime"
  def path(:storage_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/storage"
  def path(:buckets, %{ref: ref}), do: "/v1/projects/#{ref}/storage/buckets"
  def path(:sso_providers, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth/sso/providers"
  def path(:third_party_auth, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth/third-party-auth"
  def path(:api_keys, %{ref: ref, reveal: true}), do: "/v1/projects/#{ref}/api-keys?reveal=true"
  def path(:api_keys, %{ref: ref}), do: "/v1/projects/#{ref}/api-keys"
  def path(:postgrest_config, %{ref: ref}), do: "/v1/projects/#{ref}/postgrest"
  def path(:functions, %{ref: ref}), do: "/v1/projects/#{ref}/functions"
  def path(:function, %{ref: ref, fn_slug: fn_slug}), do: "/v1/projects/#{ref}/functions/#{fn_slug}"

  def path(:function_body, %{ref: ref, fn_slug: fn_slug}),
    do: "/v1/projects/#{ref}/functions/#{fn_slug}/body"

  def path(:branches, %{ref: ref}), do: "/v1/projects/#{ref}/branches"

  def path(:regions, %{slug: slug}),
    do: "/v1/projects/available-regions?organization_slug=#{slug}"

  def path(:logs, %{ref: ref, sql: sql, iso_start: iso_start, iso_end: iso_end}),
    do:
      "/v1/projects/#{ref}/analytics/endpoints/logs.all" <>
        "?sql=#{URI.encode_www_form(sql)}" <>
        "&iso_timestamp_start=#{URI.encode_www_form(iso_start)}" <>
        "&iso_timestamp_end=#{URI.encode_www_form(iso_end)}"

  def path(:advisors_security, %{ref: ref}), do: "/v1/projects/#{ref}/advisors/security"
  def path(:advisors_performance, %{ref: ref}), do: "/v1/projects/#{ref}/advisors/performance"
  def path(:typescript_types, %{ref: ref}), do: "/v1/projects/#{ref}/types/typescript"
  def path(:secrets, %{ref: ref}), do: "/v1/projects/#{ref}/secrets"
  def path(:migrations, %{ref: ref}), do: "/v1/projects/#{ref}/database/migrations"
  def path(:backups, %{ref: ref}), do: "/v1/projects/#{ref}/database/backups"
  def path(:readonly, %{ref: ref}), do: "/v1/projects/#{ref}/readonly"
  def path(:network_restrictions, %{ref: ref}), do: "/v1/projects/#{ref}/network-restrictions"
  def path(:ssl_enforcement, %{ref: ref}), do: "/v1/projects/#{ref}/ssl-enforcement"
  def path(:custom_hostname, %{ref: ref}), do: "/v1/projects/#{ref}/custom-hostname"
  def path(:vanity_subdomain, %{ref: ref}), do: "/v1/projects/#{ref}/vanity-subdomain"
  def path(:upgrade_eligibility, %{ref: ref}), do: "/v1/projects/#{ref}/upgrade/eligibility"
  def path(:pgbouncer_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/pgbouncer"
  def path(:pooler_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/pooler"
  def path(:disk_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/disk"

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

  # Advisor runs, generated types and network settings change rarely and some
  # are expensive server-side — cache them at the long-lived tier.
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
