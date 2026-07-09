defmodule Superblock.Fixtures do
  @moduledoc """
  Canned Management API responses: 2 orgs, 3 projects (2 in org A, 1 in
  org B), 2 functions, 1 branch.
  """

  # `slug` mirrors `id` here: superblock names org folders by slug || id, so
  # keeping them equal leaves the tree unchanged, while satisfying the supabase
  # CLI's schema (its `orgs list` requires a slug on every organization).
  def orgs do
    [
      %{"id" => "org-alpha", "slug" => "org-alpha", "name" => "Alpha Org"},
      %{"id" => "org-beta", "slug" => "org-beta", "name" => "Beta Org"}
    ]
  end

  def org_alpha,
    do: %{"id" => "org-alpha", "slug" => "org-alpha", "name" => "Alpha Org", "plan" => "pro"}

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

  @doc "PostgREST config: the exposed schemas drive the `database/` tree."
  def postgrest_config do
    %{
      "db_schema" => "app, public",
      "max_rows" => 1000,
      "db_extra_search_path" => "public, extensions"
    }
  end

  def realtime_config do
    %{"enabled" => true, "private_only" => false, "max_concurrent_users" => 500}
  end

  def storage_config do
    %{"fileSizeLimit" => 52_428_800, "features" => %{"imageTransformation" => %{"enabled" => true}}}
  end

  def buckets do
    [
      %{
        "id" => "avatars",
        "name" => "avatars",
        "public" => true,
        "created_at" => "2026-01-01T00:00:00Z"
      },
      %{"id" => "docs", "name" => "docs", "public" => false, "created_at" => "2026-01-02T00:00:00Z"}
    ]
  end

  # The SSO list endpoint wraps providers in an `items` envelope; superblock
  # unwraps it. Providers have no human-friendly slug, so folders are keyed by id.
  def sso_providers do
    %{
      "items" => [
        %{
          "id" => "11111111-1111-1111-1111-111111111111",
          "created_at" => "2026-01-01T00:00:00Z",
          "saml" => %{"entity_id" => "https://idp.example.com"},
          "domains" => [%{"domain" => "example.com"}]
        }
      ]
    }
  end

  # Third-party auth integrations come back as a bare array.
  def third_party_auth do
    [
      %{
        "id" => "tpa-firebase",
        "type" => "firebase",
        "oidc_issuer_url" => "https://securetoken.google.com/demo"
      }
    ]
  end

  # The function body endpoint returns an opaque eszip bundle (binary), not JSON.
  def function_body, do: "ESZIP2" <> <<0>> <> "fake-eszip-bundle-for-hello"

  @doc "Route handler serving the raw (non-JSON) function body bytes verbatim."
  def function_body_route do
    {:raw, "application/octet-stream", function_body()}
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
      "/v1/organizations/org-beta" => %{
        "id" => "org-beta",
        "slug" => "org-beta",
        "name" => "Beta Org",
        "plan" => "free"
      },
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
      "/v1/projects/projaone1234567890ab/postgrest" => postgrest_config(),
      "/v1/projects/projatwo1234567890ab/postgrest" => postgrest_config(),
      "/v1/projects/projbone1234567890ab/postgrest" => postgrest_config(),
      "/v1/projects/projaone1234567890ab/config/realtime" => realtime_config(),
      "/v1/projects/projatwo1234567890ab/config/realtime" => realtime_config(),
      "/v1/projects/projbone1234567890ab/config/realtime" => realtime_config(),
      "/v1/projects/projaone1234567890ab/config/storage" => storage_config(),
      "/v1/projects/projatwo1234567890ab/config/storage" => storage_config(),
      "/v1/projects/projbone1234567890ab/config/storage" => storage_config(),
      "/v1/projects/projaone1234567890ab/storage/buckets" => buckets(),
      "/v1/projects/projatwo1234567890ab/storage/buckets" => [],
      "/v1/projects/projbone1234567890ab/storage/buckets" => [],
      # org-alpha's first project has SAML on; the second 404s (SAML not
      # enabled), which superblock surfaces as an empty provider list.
      "/v1/projects/projaone1234567890ab/config/auth/sso/providers" => sso_providers(),
      "/v1/projects/projatwo1234567890ab/config/auth/sso/providers" =>
        {:status, 404, %{"message" => "SAML 2.0 support is not enabled for this project"}},
      "/v1/projects/projbone1234567890ab/config/auth/sso/providers" => %{"items" => []},
      "/v1/projects/projaone1234567890ab/config/auth/third-party-auth" => third_party_auth(),
      "/v1/projects/projatwo1234567890ab/config/auth/third-party-auth" => [],
      "/v1/projects/projbone1234567890ab/config/auth/third-party-auth" => [],
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
      "/v1/projects/projaone1234567890ab/functions/hello/body" => function_body_route(),
      "/v1/projects/projaone1234567890ab/functions/goodbye/body" => function_body_route(),
      "/v1/projects/projaone1234567890ab/branches" => branches(),
      "/v1/projects/projatwo1234567890ab/branches" => [],
      "/v1/projects/projbone1234567890ab/branches" => [],
      "/v1/projects/available-regions" => regions_route()
    }
  end
end
