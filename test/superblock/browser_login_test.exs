defmodule Superblock.BrowserLoginTest do
  use ExUnit.Case, async: false

  alias Superblock.{BrowserLogin, TestEnv}

  # Plays the dashboard's role: ECDH against the session's public key, then
  # AES-256-GCM with the Go convention (16-byte tag appended to the
  # ciphertext). This is exactly what the CLI must undo.
  defp server_encrypt(session_public_key, plaintext) do
    {server_pub, server_priv} = :crypto.generate_key(:ecdh, :prime256v1)
    secret = :crypto.compute_key(:ecdh, session_public_key, server_priv, :prime256v1)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, nonce, plaintext, <<>>, 16, true)

    %{
      "access_token" => Base.encode16(ciphertext <> tag, case: :lower),
      "public_key" => Base.encode16(server_pub, case: :lower),
      "nonce" => Base.encode16(nonce, case: :lower)
    }
  end

  defp fake_token, do: "sbp_" <> String.duplicate("f", 40)

  describe "new_session/0" do
    test "builds a session with fresh keys and a dashboard URL" do
      session = BrowserLogin.new_session()

      # uncompressed P-256 point: 0x04 || X (32) || Y (32)
      assert byte_size(session.public_key) == 65
      assert <<4, _rest::binary>> = session.public_key

      assert session.session_id =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert session.token_name =~ ~r/^superblock_/

      uri = URI.parse(session.url)
      assert uri.host == "supabase.com"
      assert uri.path == "/dashboard/cli/login"

      query = URI.decode_query(uri.query)
      assert query["session_id"] == session.session_id
      assert query["token_name"] == session.token_name
      assert query["public_key"] == Base.encode16(session.public_key, case: :lower)
    end

    test "two sessions never share ids or keys" do
      a = BrowserLogin.new_session()
      b = BrowserLogin.new_session()
      assert a.session_id != b.session_id
      assert a.public_key != b.public_key
    end

    test "SUPERBLOCK_DASHBOARD_URL overrides the dashboard host" do
      System.put_env("SUPERBLOCK_DASHBOARD_URL", "http://localhost:9999/dashboard")
      on_exit(fn -> System.delete_env("SUPERBLOCK_DASHBOARD_URL") end)

      session = BrowserLogin.new_session()
      assert String.starts_with?(session.url, "http://localhost:9999/dashboard/cli/login?")
    end
  end

  describe "decrypt/4" do
    test "round-trips a token encrypted the way the dashboard does" do
      session = BrowserLogin.new_session()
      payload = server_encrypt(session.public_key, fake_token())

      assert {:ok, token} =
               BrowserLogin.decrypt(
                 payload["access_token"],
                 payload["public_key"],
                 payload["nonce"],
                 session.private_key
               )

      assert token == fake_token()
    end

    test "a tampered ciphertext fails closed" do
      session = BrowserLogin.new_session()
      payload = server_encrypt(session.public_key, fake_token())

      flipped =
        case payload["access_token"] do
          "0" <> rest -> "1" <> rest
          <<_first, rest::binary>> -> "0" <> rest
        end

      assert {:error, :decrypt_failed} =
               BrowserLogin.decrypt(
                 flipped,
                 payload["public_key"],
                 payload["nonce"],
                 session.private_key
               )
    end

    test "the wrong private key fails closed" do
      session = BrowserLogin.new_session()
      other = BrowserLogin.new_session()
      payload = server_encrypt(session.public_key, fake_token())

      assert {:error, :decrypt_failed} =
               BrowserLogin.decrypt(
                 payload["access_token"],
                 payload["public_key"],
                 payload["nonce"],
                 other.private_key
               )
    end

    test "garbage inputs fail closed, never raise" do
      session = BrowserLogin.new_session()

      assert {:error, :decrypt_failed} =
               BrowserLogin.decrypt("zz", "zz", "zz", session.private_key)

      assert {:error, :decrypt_failed} =
               BrowserLogin.decrypt("00", "04ff", "00", session.private_key)
    end
  end

  describe "fetch_token/2" do
    setup do
      TestEnv.isolate_xdg!()
      :ok
    end

    test "fetches, decrypts, and never sends an Authorization header" do
      session = BrowserLogin.new_session()
      payload = server_encrypt(session.public_key, fake_token())
      test_pid = self()

      TestEnv.stub_api!(%{
        "/platform/cli/login/#{session.session_id}" => fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:auth_header, Plug.Conn.get_req_header(conn, "authorization")})
          send(test_pid, {:device_code, conn.query_params["device_code"]})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(payload))
        end
      })

      assert {:ok, token} = BrowserLogin.fetch_token(session, "ABC123")
      assert token == fake_token()
      assert_received {:auth_header, []}
      assert_received {:device_code, "ABC123"}
    end

    test "a wrong code (404) surfaces as an error" do
      session = BrowserLogin.new_session()
      TestEnv.stub_api!(%{})

      assert {:error, :not_found} = BrowserLogin.fetch_token(session, "WRONG1")
    end

    test "a malformed response surfaces as an error" do
      session = BrowserLogin.new_session()

      TestEnv.stub_api!(%{
        "/platform/cli/login/#{session.session_id}" => %{"unexpected" => true}
      })

      assert {:error, :unexpected_response} = BrowserLogin.fetch_token(session, "ABC123")
    end
  end
end
