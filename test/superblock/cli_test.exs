defmodule Superblock.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Superblock.{CLI, Credentials, Paths, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  test "help exits 0, unknown command exits 1" do
    assert capture_io(fn -> assert CLI.run(["help"]) == 0 end) =~ "Usage:"

    assert capture_io(:stderr, fn -> assert CLI.run(["frobnicate"]) == 1 end) =~
             "Unknown command"
  end

  test "login with a valid token stores it and reports the org count" do
    TestEnv.stub_api!()

    output =
      capture_io(fn ->
        assert CLI.run(["login", "--token", "sbp_valid00000000000000000000000000000cafe"]) == 0
      end)

    assert output =~ "✓ Token valid — authenticated, 2 organizations found."
    assert output =~ "Stored in"
    assert {:ok, "sbp_valid00000000000000000000000000000cafe"} = Credentials.load()

    assert {:ok, %File.Stat{mode: mode}} = File.stat(Paths.credentials_file())
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "login with a rejected token exits 2 and writes nothing" do
    TestEnv.stub_api!(%{"/v1/organizations" => {:status, 401, %{"message" => "bad"}}})

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert CLI.run(["login", "--token", "sbp_bad0000000000000000000000000000000bad0"]) ==
                   2
        end)
      end)

    assert stderr =~ "Token rejected — check it at supabase.com/dashboard/account/tokens"
    assert Credentials.load() == :missing
    refute File.exists?(Paths.credentials_file())
  end

  test "login network failure exits 3" do
    TestEnv.stub_api!(%{"/v1/organizations" => {:status, 503, %{}}})

    capture_io(:stderr, fn ->
      capture_io(fn ->
        assert CLI.run(["login", "--token", "sbp_x0000000000000000000000000000000000000"]) == 3
      end)
    end)
  end

  # Plays the dashboard: ECDH + AES-256-GCM with the tag appended,
  # exactly as api.supabase.com encrypts the minted token.
  defp encrypt_for(public_key_hex, plaintext) do
    {:ok, public_key} = Base.decode16(public_key_hex, case: :mixed)
    {server_pub, server_priv} = :crypto.generate_key(:ecdh, :prime256v1)
    secret = :crypto.compute_key(:ecdh, public_key, server_priv, :prime256v1)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, nonce, plaintext, <<>>, 16, true)

    %{
      "id" => "00000000-0000-4000-8000-000000000000",
      "created_at" => "2026-01-01T00:00:00Z",
      "access_token" => Base.encode16(ciphertext <> tag, case: :lower),
      "public_key" => Base.encode16(server_pub, case: :lower),
      "nonce" => Base.encode16(nonce, case: :lower)
    }
  end

  # The dashboard learns our public key from the login URL the browser
  # opens. Stand in for the browser: a fake xdg-open that records the URL.
  defp fake_browser! do
    dir = Path.join(System.tmp_dir!(), "superblock-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    url_file = Path.join(dir, "url")

    opener = Path.join(dir, "xdg-open")
    File.write!(opener, "#!/bin/sh\nprintf '%s' \"$1\" > #{url_file}\n")
    File.chmod!(opener, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original_path)

    ExUnit.Callbacks.on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(dir)
    end)

    url_file
  end

  defp await_file(path, retries \\ 200) do
    case File.read(path) do
      {:ok, body} when body != "" -> body
      _missing when retries > 0 -> Process.sleep(10) && await_file(path, retries - 1)
      _missing -> flunk("browser was never opened (no URL recorded)")
    end
  end

  describe "browser login (no --token)" do
    test "opens the browser, exchanges the code, and stores the token" do
      url_file = fake_browser!()
      fake_token = "sbp_" <> String.duplicate("f", 40)

      routes =
        Map.merge(Superblock.Fixtures.routes(), %{
          {:prefix, "/platform/cli/login/"} => fn conn ->
            url = await_file(url_file)
            query = URI.decode_query(URI.parse(url).query)

            conn = Plug.Conn.fetch_query_params(conn)
            assert conn.query_params["device_code"] == "ABC123"
            assert conn.request_path == "/platform/cli/login/" <> query["session_id"]
            assert Plug.Conn.get_req_header(conn, "authorization") == []

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(encrypt_for(query["public_key"], fake_token)))
          end
        })

      TestEnv.stub_api!(routes)

      output =
        capture_io([input: "ABC123\n"], fn ->
          assert CLI.run(["login"]) == 0
        end)

      assert output =~ "Here is your login link"
      assert output =~ "supabase.com/dashboard/cli/login?"
      assert output =~ "✓ Token valid — authenticated, 2 organizations found."
      assert {:ok, ^fake_token} = Credentials.load()

      # the printed URL and the browser URL are the same session
      url = await_file(url_file)
      assert output =~ url
    end

    test "--no-browser prints the URL without spawning an opener" do
      url_file = fake_browser!()

      capture_io(:stderr, fn ->
        output =
          capture_io([input: ""], fn ->
            assert CLI.run(["login", "--no-browser"]) == 2
          end)

        assert output =~ "Here is your login link"
      end)

      refute File.exists?(url_file)
    end

    test "wrong codes retry, then exit 2 after three failures" do
      TestEnv.stub_api!(%{})

      stderr =
        capture_io(:stderr, fn ->
          capture_io([input: "BAD1\nBAD2\nBAD3\n"], fn ->
            assert CLI.run(["login", "--no-browser"]) == 2
          end)
        end)

      assert stderr =~ "Verification failed: code not recognized"
      assert stderr =~ "Too many failed attempts"
      assert Credentials.load() == :missing
    end

    test "EOF at the code prompt exits 2 politely" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io([input: ""], fn ->
            assert CLI.run(["login", "--no-browser"]) == 2
          end)
        end)

      assert stderr =~ "No verification code given."
    end
  end

  test "logout deletes credentials and is idempotent" do
    :ok = Credentials.store("sbp_t000000000000000000000000000000000000t")
    assert capture_io(fn -> assert CLI.run(["logout"]) == 0 end) =~ "Logged out."
    assert capture_io(fn -> assert CLI.run(["logout"]) == 0 end) =~ "Logged out."
  end

  test "status without auth exits 2" do
    output = capture_io(fn -> assert CLI.run(["status"]) == 2 end)
    assert output =~ "Not authenticated. Run: superblock login"
  end

  test "status with auth shows masked token, orgs and mount state" do
    TestEnv.fake_login!()
    TestEnv.stub_api!()

    output = capture_io(fn -> assert CLI.run(["status"]) == 0 end)
    assert output =~ "Authenticated: token sbp_…0000"
    assert output =~ "Organizations: 2"
    assert output =~ "Mounted: no"
    refute output =~ "sbp_0000000000"
  end

  test "mount without a mountpoint exits 1 with the hint" do
    TestEnv.fake_login!()

    stderr = capture_io(:stderr, fn -> assert CLI.run(["mount"]) == 1 end)

    assert stderr =~
             "No mountpoint. Pass one or run: superblock config set mountpoint /mnt/supabase"
  end

  test "mount without auth exits 2 with the exact hint" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["mount", "/tmp/sb-nope"]) == 2 end)
    assert stderr =~ "Not authenticated. Run: superblock login"
  end

  test "a configured mountpoint satisfies mount's mountpoint check (auth still required)" do
    assert capture_io(fn -> CLI.run(["config", "set", "mountpoint", "/tmp/sb-conf"]) end)

    stderr = capture_io(:stderr, fn -> assert CLI.run(["mount"]) == 2 end)
    assert stderr =~ "Not authenticated"
  end

  test "refresh without a mount exits 1" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["refresh"]) == 1 end)
    assert stderr =~ "Not mounted."
  end

  test "config set/get/list round trip" do
    assert capture_io(fn -> assert CLI.run(["config", "set", "ttl.orgs", "90"]) == 0 end) =~
             "ttl.orgs = 90"

    assert capture_io(fn -> assert CLI.run(["config", "get", "ttl.orgs"]) == 0 end) =~ "90"
    assert capture_io(fn -> assert CLI.run(["config", "list"]) == 0 end) =~ "mountpoint = (unset)"

    assert capture_io(:stderr, fn -> assert CLI.run(["config", "set", "nope", "1"]) == 1 end) =~
             "Unknown key: nope"

    assert capture_io(:stderr, fn -> assert CLI.run(["config", "get", "nope"]) == 1 end) =~
             "Unknown key: nope"
  end

  test "doctor reports checks and exits 0 or 4" do
    output = capture_io(fn -> CLI.run(["doctor"]) end)
    assert output =~ "unmount tool on PATH"
    assert output =~ "efuse port binary compiled"
  end
end
