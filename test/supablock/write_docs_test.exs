defmodule Supablock.WriteDocsTest do
  use ExUnit.Case, async: true

  alias Supablock.{Endpoints, WriteDocs}

  describe "Endpoints.mutation/1" do
    test "mutable resources carry a write path" do
      for key <- [
            :auth_config,
            :db_config,
            :disk_config,
            :pooler_config,
            :postgrest_config,
            :realtime_config,
            :storage_config,
            :secrets,
            :function,
            :buckets,
            :branches,
            :migrations,
            :backups,
            :readonly,
            :sso_providers,
            :third_party_auth,
            :network_restrictions,
            :ssl_enforcement,
            :custom_hostname,
            :vanity_subdomain,
            :project,
            :api_keys,
            :upgrade_eligibility
          ] do
        assert %{method: method, path: path} = Endpoints.mutation(key)
        assert method in ~w(POST PUT PATCH DELETE)
        # Management API paths are relative; a project-gateway API (Storage)
        # is a full URL and must name its own credential.
        assert String.starts_with?(path, "/v1/") or String.starts_with?(path, "https://")
      end
    end

    test "buckets go through the project's Storage API with the project key" do
      assert %{path: "https://" <> _rest, auth: "$SUPABASE_SERVICE_ROLE_KEY"} =
               Endpoints.mutation(:buckets)

      refute Endpoints.mutation(:buckets).path =~ "api.supabase.com"
    end

    test "read-only and derived resources have no write path" do
      # These have no write endpoint at all in the Management API spec
      # (pgbouncer config is GET-only; health/advisors/metrics/logs/types are
      # derived; orgs/regions are not project-writable here).
      for key <- [
            :health,
            :advisors_security,
            :advisors_performance,
            :typescript_types,
            :pgbouncer_config,
            :functions,
            :function_body,
            :metrics,
            :logs,
            :orgs,
            :org,
            :org_members,
            :projects,
            :regions
          ] do
        assert Endpoints.mutation(key) == nil
      end
    end
  end

  describe "project_doc/1" do
    test "is pure static text substituting the project ref" do
      ref = "projaone1234567890ab"
      doc = WriteDocs.project_doc(ref)

      assert String.starts_with?(doc, "# How to change this project")
      assert doc =~ "read-only"
      # Endpoint paths are rendered with the ref filled in.
      assert doc =~ "/v1/projects/#{ref}/config/auth"
      assert doc =~ "/v1/projects/#{ref}/secrets"
      assert doc =~ "/v1/projects/#{ref}/config/disk"
      assert doc =~ "/v1/projects/#{ref}/config/realtime"
      # Buckets are written through the project's Storage API, not the
      # Management API, with the project's secret key.
      assert doc =~ "https://#{ref}.supabase.co/storage/v1/bucket"
      assert doc =~ "$SUPABASE_SERVICE_ROLE_KEY"
      # Project metadata, api-key rotation and the Postgres upgrade are
      # documented too.
      assert doc =~ "PATCH"
      assert doc =~ "/v1/projects/#{ref}/api-keys"
      assert doc =~ "/v1/projects/#{ref}/upgrade"
      # CLI equivalents appear only where one genuinely exists.
      assert doc =~ "supabase secrets set"
      assert doc =~ "supabase functions deploy"
      assert doc =~ "supabase db push"
      # Same ref appears everywhere; no leftover template placeholder.
      refute doc =~ "{ref}"
    end

    test "covers only mutable resources, never derived ones" do
      doc = WriteDocs.project_doc("ref00000000000000000")

      assert doc =~ "config/auth.json"
      assert doc =~ "network/ssl-enforcement.json"
      assert doc =~ "api-keys/"
      # Derived resources have no section.
      refute doc =~ "health"
      refute doc =~ "advisors"
      refute doc =~ "types.ts"
    end
  end
end
