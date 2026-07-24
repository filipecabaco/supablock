defmodule Supablock.TokenStoreTest do
  use ExUnit.Case, async: false

  alias Supablock.{Config, Credentials, TestEnv, TokenStore}

  setup do
    TestEnv.isolate_xdg!()
    :ok = Config.set("oauth.client_id", "11111111-2222-4333-8444-555555555555")
    :ok = Config.set("oauth.client_secret", "sb_secret_test_client_secret")
    :ok
  end

  defp now, do: System.os_time(:second)
  defp new_access, do: "sbp_oauth_" <> String.duplicate("d", 40)

  defp stub_token_endpoint! do
    TestEnv.stub_api!(%{
      "/v1/oauth/token" => fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => new_access(),
            "refresh_token" => "oauth_refresh_" <> String.duplicate("e", 20),
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end
    })
  end

  test "a PAT passes straight through" do
    :ok = Credentials.store("sbp_" <> String.duplicate("f", 40))
    assert {:ok, "sbp_" <> _rest} = TokenStore.access_token()
  end

  test "a fresh OAuth token is returned without refreshing" do
    TestEnv.stub_api!(%{})
    :ok = Credentials.store_oauth("sbp_oauth_fresh", "oauth_refresh_x", now() + 3600)

    assert {:ok, "sbp_oauth_fresh"} = TokenStore.access_token()
    assert TestEnv.hits("/v1/oauth/token") == 0
  end

  test "an expiring OAuth token refreshes exactly once under concurrency" do
    stub_token_endpoint!()
    :ok = Credentials.store_oauth("sbp_oauth_stale", "oauth_refresh_old", now() + 30)

    results =
      1..50
      |> Enum.map(fn _i -> Task.async(&TokenStore.access_token/0) end)
      |> Task.await_many(15_000)

    fresh = new_access()
    assert Enum.all?(results, &(&1 == {:ok, fresh}))
    assert TestEnv.hits("/v1/oauth/token") == 1

    assert {:ok, credential} = Credentials.load_credential()
    assert credential.access_token == fresh
    assert credential.refresh_token == "oauth_refresh_" <> String.duplicate("e", 20)
  end

  test "after_401 rotates once; a second caller reuses the rotation" do
    stub_token_endpoint!()
    :ok = Credentials.store_oauth("sbp_oauth_rejected", "oauth_refresh_old", now() + 3600)

    assert {:ok, fresh} = TokenStore.after_401("sbp_oauth_rejected")
    assert fresh == new_access()
    assert TestEnv.hits("/v1/oauth/token") == 1

    assert {:ok, ^fresh} = TokenStore.after_401("sbp_oauth_rejected")
    assert TestEnv.hits("/v1/oauth/token") == 1
  end

  test "after_401 on a PAT cannot rotate" do
    :ok = Credentials.store("sbp_" <> String.duplicate("f", 40))
    assert {:error, :unauthorized} = TokenStore.after_401("sbp_" <> String.duplicate("f", 40))
  end

  test "failed refresh: not-yet-expired token is returned, expired one is missing" do
    TestEnv.stub_api!(%{"/v1/oauth/token" => {:status, 500, %{}}})

    :ok = Credentials.store_oauth("sbp_oauth_stillok", "oauth_refresh_x", now() + 30)
    assert {:ok, "sbp_oauth_stillok"} = TokenStore.access_token()

    :ok = Credentials.store_oauth("sbp_oauth_gone", "oauth_refresh_x", now() - 10)
    assert :missing = TokenStore.access_token()
  end

  test "a dead refresh token (grant revoked) on an expired credential is missing" do
    TestEnv.stub_api!(%{"/v1/oauth/token" => {:status, 401, %{}}})
    :ok = Credentials.store_oauth("sbp_oauth_gone", "oauth_refresh_dead", now() - 10)
    assert :missing = TokenStore.access_token()
  end
end
