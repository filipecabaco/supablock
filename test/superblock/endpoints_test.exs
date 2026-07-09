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
end
