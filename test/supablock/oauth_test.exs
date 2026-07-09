defmodule Supablock.OAuthTest do
  use ExUnit.Case, async: false

  alias Supablock.{Config, OAuth, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok = Config.set("oauth.client_id", "11111111-2222-4333-8444-555555555555")
    :ok = Config.set("oauth.client_secret", "sb_secret_test_client_secret")
    :ok
  end

  # Parses the form body of a token-endpoint request inside a plug stub.
  defp read_form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  defp token_json(conn, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "access_token" => "sbp_oauth_" <> String.duplicate("a", 40),
          "refresh_token" => "oauth_refresh_" <> String.duplicate("b", 20),
          "expires_in" => 3600,
          "token_type" => "Bearer"
        },
        overrides
      )

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  describe "new_request/0" do
    test "builds a PKCE S256 authorize URL with state" do
      request = OAuth.new_request()

      uri = URI.parse(request.url)
      assert uri.path == "/v1/oauth/authorize"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == "11111111-2222-4333-8444-555555555555"
      assert query["response_type"] == "code"
      assert query["redirect_uri"] == "http://localhost:53682/callback"
      assert query["state"] == request.state
      assert query["code_challenge_method"] == "S256"

      # challenge really is BASE64URL(SHA256(verifier)), unpadded
      expected =
        Base.url_encode64(:crypto.hash(:sha256, request.verifier), padding: false)

      assert query["code_challenge"] == expected

      # RFC 7636: verifier length within [43, 128]
      assert byte_size(request.verifier) in 43..128
    end

    test "every request gets fresh state and verifier" do
      a = OAuth.new_request()
      b = OAuth.new_request()
      assert a.state != b.state
      assert a.verifier != b.verifier
    end
  end

  describe "exchange_code/2" do
    test "posts the code + verifier form with basic auth" do
      test_pid = self()

      TestEnv.stub_api!(%{
        "/v1/oauth/token" => fn conn ->
          {form, conn} = read_form(conn)
          send(test_pid, {:form, form})
          send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
          token_json(conn)
        end
      })

      request = OAuth.new_request()
      assert {:ok, tokens} = OAuth.exchange_code(request, "authcode123")

      assert tokens.access_token == "sbp_oauth_" <> String.duplicate("a", 40)
      assert tokens.refresh_token == "oauth_refresh_" <> String.duplicate("b", 20)
      assert_in_delta tokens.expires_at, System.os_time(:second) + 3600, 5

      assert_received {:form, form}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "authcode123"
      assert form["redirect_uri"] == request.redirect_uri
      assert form["code_verifier"] == request.verifier

      expected_auth =
        "Basic " <>
          Base.encode64("11111111-2222-4333-8444-555555555555:sb_secret_test_client_secret")

      assert_received {:auth, [^expected_auth]}
    end

    test "a rejected exchange surfaces :unauthorized" do
      TestEnv.stub_api!(%{"/v1/oauth/token" => {:status, 401, %{"message" => "nope"}}})
      assert {:error, :unauthorized} = OAuth.exchange_code(OAuth.new_request(), "bad")
    end
  end

  describe "refresh/1" do
    test "posts grant_type=refresh_token and returns the new pair" do
      test_pid = self()

      TestEnv.stub_api!(%{
        "/v1/oauth/token" => fn conn ->
          {form, conn} = read_form(conn)
          send(test_pid, {:form, form})
          token_json(conn, %{"access_token" => "sbp_oauth_" <> String.duplicate("c", 40)})
        end
      })

      assert {:ok, tokens} = OAuth.refresh("oauth_refresh_old")
      assert tokens.access_token == "sbp_oauth_" <> String.duplicate("c", 40)

      assert_received {:form, form}
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "oauth_refresh_old"
    end

    test "a dead refresh token means reauth" do
      TestEnv.stub_api!(%{"/v1/oauth/token" => {:status, 401, %{}}})
      assert {:error, :reauth_required} = OAuth.refresh("oauth_refresh_dead")

      TestEnv.stub_api!(%{"/v1/oauth/token" => {:status, 400, %{}}})
      assert {:error, :reauth_required} = OAuth.refresh("oauth_refresh_dead")
    end
  end

  describe "revoke/1" do
    test "posts the client credentials + refresh token, 204 is ok" do
      test_pid = self()

      TestEnv.stub_api!(%{
        "/v1/oauth/revoke" => fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:revoke, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 204, "")
        end
      })

      assert :ok = OAuth.revoke("oauth_refresh_gone")

      assert_received {:revoke, body}
      assert body["client_id"] == "11111111-2222-4333-8444-555555555555"
      assert body["client_secret"] == "sb_secret_test_client_secret"
      assert body["refresh_token"] == "oauth_refresh_gone"
    end
  end

  test "configured?/0 needs both id and secret" do
    assert OAuth.configured?()

    TestEnv.isolate_xdg!()
    refute OAuth.configured?()

    :ok = Config.set("oauth.client_id", "only-id")
    refute OAuth.configured?()
  end
end
