defmodule Supablock.EndpointsTest do
  use ExUnit.Case, async: true

  alias Supablock.Endpoints

  test "health sends services as repeated params (OpenAPI form/explode default)" do
    assert Endpoints.path(:health, %{ref: "abc"}) ==
             "/v1/projects/abc/health?services=auth&services=db&services=realtime&services=rest&services=storage"
  end

  test "available regions require the organization_slug" do
    assert Endpoints.path(:regions, %{slug: "org-alpha"}) ==
             "/v1/projects/available-regions?organization_slug=org-alpha"
  end

  test "api-keys asks for secret material only with reveal: true" do
    assert Endpoints.path(:api_keys, %{ref: "abc"}) == "/v1/projects/abc/api-keys"

    assert Endpoints.path(:api_keys, %{ref: "abc", reveal: true}) ==
             "/v1/projects/abc/api-keys?reveal=true"
  end

  test "postgrest config drives the exposed-schema list" do
    assert Endpoints.path(:postgrest_config, %{ref: "abc"}) == "/v1/projects/abc/postgrest"
  end

  test "realtime, storage, bucket and auth-provider endpoints" do
    assert Endpoints.path(:realtime_config, %{ref: "abc"}) == "/v1/projects/abc/config/realtime"
    assert Endpoints.path(:storage_config, %{ref: "abc"}) == "/v1/projects/abc/config/storage"
    assert Endpoints.path(:buckets, %{ref: "abc"}) == "/v1/projects/abc/storage/buckets"

    assert Endpoints.path(:sso_providers, %{ref: "abc"}) ==
             "/v1/projects/abc/config/auth/sso/providers"

    assert Endpoints.path(:third_party_auth, %{ref: "abc"}) ==
             "/v1/projects/abc/config/auth/third-party-auth"
  end

  test "edge-function body endpoint" do
    assert Endpoints.path(:function_body, %{ref: "abc", fn_slug: "hello"}) ==
             "/v1/projects/abc/functions/hello/body"
  end

  test "logs endpoint encodes the SQL query into the path" do
    sql =
      "SELECT timestamp, event_message, metadata FROM auth_logs ORDER BY timestamp DESC LIMIT 100"

    path =
      Endpoints.path(:logs, %{
        ref: "abc",
        sql: sql,
        iso_start: "2026-07-10T00:00:00Z",
        iso_end: "2026-07-11T00:00:00Z"
      })

    assert String.starts_with?(path, "/v1/projects/abc/analytics/endpoints/logs.all?sql=")
    assert path =~ URI.encode_www_form(sql)
    assert path =~ "iso_timestamp_start=#{URI.encode_www_form("2026-07-10T00:00:00Z")}"
    assert path =~ "iso_timestamp_end=#{URI.encode_www_form("2026-07-11T00:00:00Z")}"
    assert Endpoints.ttl_class(:logs) == "logs"
  end

  test "advisor, types, secrets and database endpoints" do
    assert Endpoints.path(:advisors_security, %{ref: "abc"}) ==
             "/v1/projects/abc/advisors/security"

    assert Endpoints.path(:advisors_performance, %{ref: "abc"}) ==
             "/v1/projects/abc/advisors/performance"

    assert Endpoints.path(:typescript_types, %{ref: "abc"}) == "/v1/projects/abc/types/typescript"
    assert Endpoints.path(:secrets, %{ref: "abc"}) == "/v1/projects/abc/secrets"
    assert Endpoints.path(:migrations, %{ref: "abc"}) == "/v1/projects/abc/database/migrations"
    assert Endpoints.path(:backups, %{ref: "abc"}) == "/v1/projects/abc/database/backups"
    assert Endpoints.path(:readonly, %{ref: "abc"}) == "/v1/projects/abc/readonly"
  end

  test "network and upgrade endpoints" do
    assert Endpoints.path(:network_restrictions, %{ref: "abc"}) ==
             "/v1/projects/abc/network-restrictions"

    assert Endpoints.path(:ssl_enforcement, %{ref: "abc"}) == "/v1/projects/abc/ssl-enforcement"
    assert Endpoints.path(:custom_hostname, %{ref: "abc"}) == "/v1/projects/abc/custom-hostname"
    assert Endpoints.path(:vanity_subdomain, %{ref: "abc"}) == "/v1/projects/abc/vanity-subdomain"

    assert Endpoints.path(:upgrade_eligibility, %{ref: "abc"}) ==
             "/v1/projects/abc/upgrade/eligibility"
  end

  test "database config endpoints" do
    assert Endpoints.path(:pgbouncer_config, %{ref: "abc"}) ==
             "/v1/projects/abc/config/database/pgbouncer"

    assert Endpoints.path(:pooler_config, %{ref: "abc"}) ==
             "/v1/projects/abc/config/database/pooler"

    assert Endpoints.path(:disk_config, %{ref: "abc"}) == "/v1/projects/abc/config/disk"
  end

  test "every endpoint maps to its exact TTL class" do
    expected = [
      {:realtime_config, "project"},
      {:storage_config, "project"},
      {:buckets, "project"},
      {:sso_providers, "project"},
      {:third_party_auth, "project"},
      {:function_body, "project"},
      {:postgrest_config, "project"},
      {:secrets, "project"},
      {:migrations, "project"},
      {:backups, "project"},
      {:readonly, "project"},
      {:pgbouncer_config, "project"},
      {:pooler_config, "project"},
      {:disk_config, "project"},
      {:advisors_security, "static"},
      {:advisors_performance, "static"},
      {:typescript_types, "static"},
      {:network_restrictions, "static"},
      {:ssl_enforcement, "static"},
      {:custom_hostname, "static"},
      {:vanity_subdomain, "static"},
      {:upgrade_eligibility, "static"},
      {:logs, "logs"}
    ]

    for {key, class} <- expected do
      assert Endpoints.ttl_class(key) == class
    end
  end

  describe "identifier encoding" do
    test "ref, slug and fn_slug are percent-encoded before interpolation" do
      assert Endpoints.path(:org, %{slug: "evil/../../v1/projects"}) ==
               "/v1/organizations/evil%2F..%2F..%2Fv1%2Fprojects"

      assert Endpoints.path(:project, %{ref: "abc?reveal=true"}) ==
               "/v1/projects/abc%3Freveal%3Dtrue"

      assert Endpoints.path(:function_body, %{ref: "abc", fn_slug: "a/b"}) ==
               "/v1/projects/abc/functions/a%2Fb/body"

      assert Endpoints.path(:regions, %{slug: "a&b"}) ==
               "/v1/projects/available-regions?organization_slug=a%26b"
    end

    test "dot segments cannot walk the request up the tree" do
      assert Endpoints.path(:project, %{ref: ".."}) == "/v1/projects/%2E%2E"
      assert Endpoints.path(:org, %{slug: "."}) == "/v1/organizations/%2E"
    end

    test "ordinary identifiers keep their bytes" do
      assert Endpoints.path(:project, %{ref: "projaone1234567890ab"}) ==
               "/v1/projects/projaone1234567890ab"

      assert Endpoints.path(:function, %{ref: "abc", fn_slug: "hello-world_1"}) ==
               "/v1/projects/abc/functions/hello-world_1"
    end

    test "the logs clause still encodes its own query parameters exactly once" do
      path =
        Endpoints.path(:logs, %{
          ref: "abc",
          sql: "SELECT 1",
          iso_start: "2024-01-01T00:00:00Z",
          iso_end: "2024-01-02T00:00:00Z"
        })

      assert path =~ "sql=SELECT+1"
      refute path =~ "%25"
    end
  end
end
