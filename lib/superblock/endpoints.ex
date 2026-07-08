defmodule Superblock.Endpoints do
  @moduledoc """
  Single source of truth for every Supabase Management API endpoint used by
  superblock. All of them are `GET`; nothing else in the codebase hardcodes
  URLs. Each endpoint carries the TTL class the Router uses for caching.

  Verified against the Management API reference (supabase.com/docs/reference/api):
  health takes a comma-separated `services` query parameter, database config
  lives at `config/database/postgres`, and regions at
  `/v1/projects/available-regions`.
  """

  @health_services "auth,db,realtime,rest,storage"

  @type key ::
          :orgs
          | :org
          | :org_members
          | :projects
          | :project
          | :health
          | :auth_config
          | :db_config
          | :api_keys
          | :functions
          | :function
          | :branches
          | :regions

  @spec path(key, map) :: String.t()
  def path(key, args \\ %{})

  def path(:orgs, _args), do: "/v1/organizations"
  def path(:org, %{slug: slug}), do: "/v1/organizations/#{slug}"
  def path(:org_members, %{slug: slug}), do: "/v1/organizations/#{slug}/members"
  def path(:projects, _args), do: "/v1/projects"
  def path(:project, %{ref: ref}), do: "/v1/projects/#{ref}"
  def path(:health, %{ref: ref}), do: "/v1/projects/#{ref}/health?services=#{@health_services}"
  def path(:auth_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/auth"
  def path(:db_config, %{ref: ref}), do: "/v1/projects/#{ref}/config/database/postgres"
  def path(:api_keys, %{ref: ref}), do: "/v1/projects/#{ref}/api-keys"
  def path(:functions, %{ref: ref}), do: "/v1/projects/#{ref}/functions"
  def path(:function, %{ref: ref, fn_slug: fn_slug}), do: "/v1/projects/#{ref}/functions/#{fn_slug}"
  def path(:branches, %{ref: ref}), do: "/v1/projects/#{ref}/branches"
  def path(:regions, _args), do: "/v1/projects/available-regions"

  @doc "TTL class for the endpoint, matching the `ttl` config map keys."
  @spec ttl_class(key) :: String.t()
  def ttl_class(key) when key in [:orgs, :org, :org_members], do: "orgs"
  def ttl_class(key) when key in [:projects, :project, :auth_config, :db_config], do: "project"
  def ttl_class(key) when key in [:functions, :function, :branches], do: "project"
  def ttl_class(:health), do: "health"
  def ttl_class(key) when key in [:api_keys, :regions], do: "static"
end
