defmodule Superblock.EndpointsTest do
  use ExUnit.Case, async: true

  alias Superblock.Endpoints

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

  test "every endpoint carries a known TTL class" do
    keys = [
      :realtime_config,
      :storage_config,
      :buckets,
      :sso_providers,
      :third_party_auth,
      :function_body,
      :postgrest_config
    ]

    for key <- keys do
      assert Endpoints.ttl_class(key) in ["orgs", "project", "health", "static"]
    end
  end
end
