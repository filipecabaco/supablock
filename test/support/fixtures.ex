defmodule Superblock.Fixtures do
  @moduledoc """
  Canned Management API responses: 2 orgs, 3 projects (2 in org A, 1 in
  org B), 2 functions, 1 branch.
  """

  def orgs do
    [
      %{"id" => "org-alpha", "name" => "Alpha Org"},
      %{"id" => "org-beta", "name" => "Beta Org"}
    ]
  end

  def org_alpha, do: %{"id" => "org-alpha", "name" => "Alpha Org", "plan" => "pro"}

  def org_members do
    [
      %{"user_name" => "filipe", "email" => "filipe@example.com", "role_name" => "Owner"},
      %{"user_name" => "ana", "email" => "ana@example.com", "role_name" => "Developer"}
    ]
  end

  def projects do
    [
      %{
        "id" => "projaone1234567890ab",
        "organization_id" => "org-alpha",
        "name" => "Alpha One",
        "region" => "eu-west-1",
        "status" => "ACTIVE_HEALTHY",
        "created_at" => "2026-01-01T00:00:00Z"
      },
      %{
        "id" => "projatwo1234567890ab",
        "organization_id" => "org-alpha",
        "name" => "Alpha Two",
        "region" => "us-east-1",
        "status" => "INACTIVE",
        "created_at" => "2026-02-01T00:00:00Z"
      },
      %{
        "id" => "projbone1234567890ab",
        "organization_id" => "org-beta",
        "name" => "Beta One",
        "region" => "ap-southeast-1",
        "status" => "ACTIVE_HEALTHY",
        "created_at" => "2026-03-01T00:00:00Z"
      }
    ]
  end

  def project(ref), do: Enum.find(projects(), &(&1["id"] == ref))

  def health do
    [
      %{"name" => "auth", "healthy" => true, "status" => "ACTIVE_HEALTHY"},
      %{"name" => "db", "healthy" => true, "status" => "ACTIVE_HEALTHY"},
      %{"name" => "realtime", "healthy" => false, "status" => "UNHEALTHY"},
      %{"name" => "rest", "healthy" => true, "status" => "ACTIVE_HEALTHY"},
      %{"name" => "storage", "healthy" => true, "status" => "ACTIVE_HEALTHY"}
    ]
  end

  def auth_config do
    %{
      "site_url" => "https://alpha-one.example.com",
      "jwt_exp" => 3600,
      "disable_signup" => false,
      "external_email_enabled" => true
    }
  end

  def db_config do
    %{"max_connections" => 100, "statement_timeout" => "2min"}
  end

  def api_keys(reveal? \\ true) do
    [
      %{"name" => "anon", "api_key" => "sb_publishable_FAKEFAKEFAKE"},
      %{
        "name" => "service_role",
        "api_key" => if(reveal?, do: "sb_secret_TOPSECRETVALUE", else: "sb_secret_TOPS****")
      }
    ]
  end

  @doc """
  Route handler mirroring the real api-keys endpoint: secret key material is
  masked unless `reveal=true` is passed.
  """
  def api_keys_route do
    {:params, fn params -> {200, api_keys(params["reveal"] == "true")} end}
  end

  def functions do
    [
      %{"slug" => "hello", "name" => "hello", "status" => "ACTIVE", "version" => 3},
      %{"slug" => "goodbye", "name" => "goodbye", "status" => "ACTIVE", "version" => 1}
    ]
  end

  def function_hello do
    %{
      "slug" => "hello",
      "name" => "hello",
      "status" => "ACTIVE",
      "version" => 3,
      "verify_jwt" => true
    }
  end

  def branches do
    [
      %{
        "id" => "branch-1",
        "name" => "main",
        "project_ref" => "projaone1234567890ab",
        "is_default" => true
      }
    ]
  end

  def regions do
    %{"smart_regions" => ["americas", "emea", "apac"], "regions" => ["eu-west-1", "us-east-1"]}
  end

  @doc """
  Route handler mirroring the real available-regions endpoint:
  `organization_slug` is a required query parameter (400 without it).
  """
  def regions_route do
    {:params,
     fn params ->
       case params["organization_slug"] do
         slug when is_binary(slug) and slug != "" -> {200, regions()}
         _missing -> {400, %{"message" => "organization_slug required"}}
       end
     end}
  end

  @doc "Default route table for the stub: path (without query) -> JSON value."
  def routes do
    %{
      "/v1/organizations" => orgs(),
      "/v1/organizations/org-alpha" => org_alpha(),
      "/v1/organizations/org-alpha/members" => org_members(),
      "/v1/organizations/org-beta" => %{"id" => "org-beta", "name" => "Beta Org", "plan" => "free"},
      "/v1/organizations/org-beta/members" => [],
      "/v1/projects" => projects(),
      "/v1/projects/projaone1234567890ab" => project("projaone1234567890ab"),
      "/v1/projects/projatwo1234567890ab" => project("projatwo1234567890ab"),
      "/v1/projects/projbone1234567890ab" => project("projbone1234567890ab"),
      "/v1/projects/projaone1234567890ab/health" => health(),
      "/v1/projects/projatwo1234567890ab/health" => health(),
      "/v1/projects/projbone1234567890ab/health" => health(),
      "/v1/projects/projaone1234567890ab/config/auth" => auth_config(),
      "/v1/projects/projatwo1234567890ab/config/auth" => auth_config(),
      "/v1/projects/projbone1234567890ab/config/auth" => auth_config(),
      "/v1/projects/projaone1234567890ab/config/database/postgres" => db_config(),
      "/v1/projects/projatwo1234567890ab/config/database/postgres" => db_config(),
      "/v1/projects/projbone1234567890ab/config/database/postgres" => db_config(),
      "/v1/projects/projaone1234567890ab/api-keys" => api_keys_route(),
      "/v1/projects/projatwo1234567890ab/api-keys" => api_keys_route(),
      "/v1/projects/projbone1234567890ab/api-keys" => api_keys_route(),
      "/v1/projects/projaone1234567890ab/functions" => functions(),
      "/v1/projects/projatwo1234567890ab/functions" => [],
      "/v1/projects/projbone1234567890ab/functions" => [],
      "/v1/projects/projaone1234567890ab/functions/hello" => function_hello(),
      "/v1/projects/projaone1234567890ab/functions/goodbye" => %{
        "slug" => "goodbye",
        "name" => "goodbye",
        "status" => "ACTIVE",
        "version" => 1,
        "verify_jwt" => false
      },
      "/v1/projects/projaone1234567890ab/branches" => branches(),
      "/v1/projects/projatwo1234567890ab/branches" => [],
      "/v1/projects/projbone1234567890ab/branches" => [],
      "/v1/projects/available-regions" => regions_route()
    }
  end
end
