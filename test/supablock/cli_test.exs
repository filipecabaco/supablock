defmodule Supablock.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Supablock.{CLI, Credentials, Paths, TestEnv}

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
    dir = Path.join(System.tmp_dir!(), "supablock-browser-#{System.unique_integer([:positive])}")
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
        Map.merge(Supablock.Fixtures.routes(), %{
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

  defp oauth_routes(test_pid) do
    Map.merge(Supablock.Fixtures.routes(), %{
      "/v1/oauth/token" => fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_form, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "sbp_oauth_" <> String.duplicate("a", 40),
            "refresh_token" => "oauth_refresh_" <> String.duplicate("b", 20),
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end
    })
  end

  # GET the loopback callback, retrying while the listener is still coming up.
  defp get_callback!(params, retries \\ 100) do
    Req.get!("http://127.0.0.1:53682/callback", params: params, retry: false)
  rescue
    error in [Req.TransportError] ->
      if retries > 0 do
        Process.sleep(20)
        get_callback!(params, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  describe "OAuth login (oauth.client_id configured)" do
    setup do
      :ok = Supablock.Config.set("oauth.client_id", "11111111-2222-4333-8444-555555555555")
      :ok = Supablock.Config.set("oauth.client_secret", "sb_secret_test_client_secret")
      :ok
    end

    test "full flow: browser consent, loopback callback, exchange, store" do
      url_file = fake_browser!()
      TestEnv.stub_api!(oauth_routes(self()))

      login =
        Task.async(fn ->
          capture_io(fn -> assert CLI.run(["login"]) == 0 end)
        end)

      # stand in for the user's browser: read the authorize URL the CLI
      # opened, approve, and follow the redirect to the loopback callback
      authorize_url = await_file(url_file)
      query = URI.decode_query(URI.parse(authorize_url).query)
      assert URI.parse(authorize_url).path == "/v1/oauth/authorize"
      assert query["code_challenge_method"] == "S256"
      assert query["redirect_uri"] == "http://localhost:53682/callback"

      response = get_callback!(code: "consented123", state: query["state"])
      assert response.status == 200

      output = Task.await(login, 15_000)
      assert output =~ "✓ Logged in via OAuth — authenticated, 2 organizations found."
      assert output =~ "refresh automatically"

      assert_received {:token_form, form}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "consented123"
      assert is_binary(form["code_verifier"])

      assert {:ok, credential} = Credentials.load_credential()
      assert credential.type == :oauth
      assert credential.refresh_token == "oauth_refresh_" <> String.duplicate("b", 20)
    end

    test "a state mismatch on the callback is rejected" do
      url_file = fake_browser!()
      TestEnv.stub_api!(oauth_routes(self()))

      login =
        Task.async(fn ->
          capture_io(:stderr, fn ->
            capture_io(fn -> assert CLI.run(["login"]) == 2 end)
          end)
        end)

      await_file(url_file)
      get_callback!(code: "stolen", state: "forged-state")

      stderr = Task.await(login, 15_000)
      assert stderr =~ "State mismatch"
      refute_received {:token_form, _form}
      assert Credentials.load() == :missing
    end

    test "a denied consent exits politely" do
      TestEnv.stub_api!(oauth_routes(self()))

      login =
        Task.async(fn ->
          capture_io(:stderr, fn ->
            capture_io(fn -> assert CLI.run(["login", "--no-browser"]) == 2 end)
          end)
        end)

      get_callback!(error: "access_denied", error_description: "User denied access")

      stderr = Task.await(login, 15_000)
      assert stderr =~ "Authorization was not granted: User denied access"
      assert Credentials.load() == :missing
    end

    test "logout revokes the OAuth grant server-side" do
      test_pid = self()

      TestEnv.stub_api!(%{
        "/v1/oauth/revoke" => fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:revoked, Jason.decode!(body)["refresh_token"]})
          Plug.Conn.send_resp(conn, 204, "")
        end
      })

      :ok =
        Credentials.store_oauth(
          "sbp_oauth_" <> String.duplicate("a", 40),
          "oauth_refresh_gone",
          System.os_time(:second) + 3600
        )

      output = capture_io(fn -> assert CLI.run(["logout"]) == 0 end)
      assert output =~ "Revoked the OAuth authorization."
      assert output =~ "Logged out."
      assert_received {:revoked, "oauth_refresh_gone"}
      assert Credentials.load() == :missing
    end
  end

  describe "setup (one-command onboarding)" do
    test "applies a profile, runs the OAuth login, and skips the service on --no-service",
         %{} = _ctx do
      url_file = fake_browser!()
      TestEnv.stub_api!(oauth_routes(self()))

      base = Path.dirname(System.get_env("XDG_CONFIG_HOME"))
      profile_path = Path.join(base, "team.json")

      File.write!(
        profile_path,
        Jason.encode!(%{
          "oauth.client_id" => "11111111-2222-4333-8444-555555555555",
          "oauth.client_secret" => "sb_secret_team",
          "mountpoint" => "/mnt/team"
        })
      )

      setup_task =
        Task.async(fn ->
          capture_io(fn ->
            assert CLI.run(["setup", profile_path, "--no-service"]) == 0
          end)
        end)

      authorize_url = await_file(url_file)
      query = URI.decode_query(URI.parse(authorize_url).query)
      get_callback!(code: "setup123", state: query["state"])

      output = Task.await(setup_task, 15_000)
      assert output =~ "Applying team profile"
      assert output =~ "mountpoint = /mnt/team"
      assert output =~ "oauth.client_secret = (set)"
      refute output =~ "sb_secret_team"
      assert output =~ "✓ Logged in via OAuth"
      assert output =~ "All set. Mount with: supablock mount"
      assert output =~ "/mnt/team"

      assert {:ok, %{type: :oauth}} = Credentials.load_credential()
      assert Supablock.Config.get("mountpoint") == "/mnt/team"
    end

    test "already-authenticated setup is a no-op login" do
      TestEnv.fake_login!()
      TestEnv.stub_api!()

      output =
        capture_io(fn ->
          assert CLI.run(["setup", "--no-service"]) == 0
        end)

      assert output =~ "Already authenticated — 2 organizations found."
      assert output =~ "All set."
    end

    test "a bad profile fails before any login" do
      base = Path.dirname(System.get_env("XDG_CONFIG_HOME"))
      bad = Path.join(base, "bad.json")
      File.write!(bad, "[]")

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(["setup", bad, "--no-service"]) == 1 end)
        end)

      assert stderr =~ "JSON object"
      assert Credentials.load() == :missing
    end

    test "an unreachable API does not trigger a fresh login" do
      TestEnv.fake_login!()
      TestEnv.stub_api!(%{"/v1/organizations" => {:status, 503, %{}}})

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(["setup", "--no-service"]) == 3 end)
        end)

      assert stderr =~ "Could not verify authentication"
    end

    test "the service prompt defaults to no" do
      TestEnv.fake_login!()
      TestEnv.stub_api!()

      output =
        capture_io([input: "\n"], fn ->
          assert CLI.run(["setup"]) == 0
        end)

      assert output =~ "Install the auto-start service"
      assert output =~ "All set."
      assert Supablock.Service.status() == :not_installed
    end
  end

  test "logout deletes credentials and is idempotent" do
    :ok = Credentials.store("sbp_t000000000000000000000000000000000000t")
    assert capture_io(fn -> assert CLI.run(["logout"]) == 0 end) =~ "Logged out."
    assert capture_io(fn -> assert CLI.run(["logout"]) == 0 end) =~ "Logged out."
  end

  test "status without auth exits 2" do
    output = capture_io(fn -> assert CLI.run(["status"]) == 2 end)
    assert output =~ "Not authenticated. Run: supablock login"
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

  test "mount without auth exits 2 with the exact hint" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["mount", "/tmp/sb-nope"]) == 2 end)
    assert stderr =~ "Not authenticated. Run: supablock login"
  end

  test "mount needs no mountpoint config (defaults apply; auth still required first)" do
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

  describe "ls / cat (the tree without a mount)" do
    @proj_a1 "projaone1234567890ab"

    setup do
      TestEnv.fake_login!()
      TestEnv.stub_api!()
      :ok
    end

    test "ls with no path lists the tree root" do
      assert capture_io(fn -> assert CLI.run(["ls"]) == 0 end) == "organizations\n"
    end

    test "ls resolves the same paths as the mount, relative or absolute" do
      output = capture_io(fn -> assert CLI.run(["ls", "organizations"]) == 0 end)
      assert output == "org-alpha\norg-beta\n"

      output =
        capture_io(fn ->
          assert CLI.run(["ls", "/organizations/org-alpha/projects"]) == 0
        end)

      assert output == "projaone1234567890ab\nprojatwo1234567890ab\n"
    end

    test "ls on a file prints its name, like ls(1)" do
      output =
        capture_io(fn ->
          assert CLI.run(["ls", "organizations/org-alpha/projects/#{@proj_a1}/health"]) == 0
        end)

      assert output == "health\n"
    end

    test "cat prints file bodies verbatim" do
      output =
        capture_io(fn ->
          assert CLI.run(["cat", "organizations/org-alpha/projects/#{@proj_a1}/health"]) == 0
        end)

      assert output =~ "auth: healthy"
      assert output =~ "realtime: unhealthy (UNHEALTHY)"
    end

    test "cat concatenates multiple paths" do
      base = "organizations/org-alpha/projects/#{@proj_a1}"

      output =
        capture_io(fn ->
          assert CLI.run(["cat", "#{base}/health", "#{base}/config/auth.json"]) == 0
        end)

      assert output =~ "db: healthy"
      assert output =~ "\"site_url\""
    end

    test "cat on a directory says so and exits 1" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["cat", "organizations"]) == 1
        end)

      assert stderr =~ "Is a directory: /organizations"
    end

    test "a bogus path exits 1 with a clear message" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["ls", "organizations/nope"]) == 1
        end)

      assert stderr =~ "No such path: /organizations/nope"

      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["cat", "organizations/org-alpha/frobnicate"]) == 1
        end)

      assert stderr =~ "No such path"
    end

    test "cat without a path is a usage error" do
      assert capture_io(:stderr, fn -> assert CLI.run(["cat"]) == 1 end) =~
               "Usage: supablock cat"
    end

    test "a rate-limited API maps to exit 3" do
      TestEnv.stub_api!(%{"/v1/organizations" => {:status, 429, %{}}})

      assert capture_io(:stderr, fn -> assert CLI.run(["ls", "organizations"]) == 3 end) =~
               "Rate limited"
    end

    test "SUPABLOCK_TOKEN alone is enough — no stored credential needed" do
      File.rm(Supablock.Paths.credentials_file())
      System.put_env("SUPABLOCK_TOKEN", "sbp_env000000000000000000000000000000000000")
      on_exit(fn -> System.delete_env("SUPABLOCK_TOKEN") end)

      assert capture_io(fn -> assert CLI.run(["ls"]) == 0 end) == "organizations\n"
    end
  end

  describe "find / grep / head / tail (agent-friendly reads without a mount)" do
    @proj_a1 "projaone1234567890ab"
    @proj_base "organizations/org-alpha/projects/projaone1234567890ab"

    setup do
      TestEnv.fake_login!()
      TestEnv.stub_api!()
      :ok
    end

    test "find walks the tree in listing order, inclusive of the start" do
      output =
        capture_io(fn ->
          assert CLI.run(["find", "organizations/org-alpha", "-maxdepth", "1"]) == 0
        end)

      assert output == """
             organizations/org-alpha
             organizations/org-alpha/info.json
             organizations/org-alpha/members.json
             organizations/org-alpha/projects
             organizations/org-alpha/regions.json
             """
    end

    test "find filters by -type and -name" do
      output =
        capture_io(fn ->
          assert CLI.run(["find", "organizations/org-alpha", "-maxdepth", "1", "-type", "d"]) ==
                   0
        end)

      assert output == "organizations/org-alpha\norganizations/org-alpha/projects\n"

      output =
        capture_io(fn ->
          assert CLI.run([
                   "find",
                   "organizations/org-alpha",
                   "-maxdepth",
                   "1",
                   "-name",
                   "*.json"
                 ]) == 0
        end)

      assert output == """
             organizations/org-alpha/info.json
             organizations/org-alpha/members.json
             organizations/org-alpha/regions.json
             """
    end

    test "find never fetches file bodies" do
      capture_io(fn ->
        assert CLI.run(["find", "#{@proj_base}/config", "-maxdepth", "1"]) == 0
      end)

      assert TestEnv.hits("/v1/projects/#{@proj_a1}/config/auth") == 0
      assert TestEnv.hits("/v1/projects/#{@proj_a1}/config/database/postgres") == 0
    end

    test "find on a bogus path exits 1" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["find", "organizations/nope"]) == 1
        end)

      assert stderr =~ "No such path"
    end

    test "find rejects bad flags" do
      assert capture_io(:stderr, fn -> assert CLI.run(["find", "-type", "x"]) == 1 end) =~
               "invalid -type"

      assert capture_io(:stderr, fn -> assert CLI.run(["find", "-frobnicate"]) == 1 end) =~
               "unknown option"
    end

    test "grep -l prints matching file paths, searching directories recursively" do
      output =
        capture_io(fn ->
          assert CLI.run(["grep", "-l", "site_url", "#{@proj_base}/config"]) == 0
        end)

      assert output == "#{@proj_base}/config/auth.json\n"
    end

    test "grep on a single file omits the path prefix; -n adds line numbers" do
      output =
        capture_io(fn ->
          assert CLI.run(["grep", "-n", "site_url", "#{@proj_base}/config/auth.json"]) == 0
        end)

      assert output == ~s(5:  "site_url": "https://alpha-one.example.com"\n)
    end

    test "grep prefixes paths when searching multiple files" do
      output =
        capture_io(fn ->
          assert CLI.run([
                   "grep",
                   "healthy",
                   "#{@proj_base}/health",
                   "#{@proj_base}/config/auth.json"
                 ]) == 0
        end)

      assert output =~ "#{@proj_base}/health:auth: healthy"
      refute output =~ "auth.json"
    end

    test "grep -i ignores case" do
      assert capture_io(fn ->
               assert CLI.run(["grep", "-i", "SITE_URL", "#{@proj_base}/config/auth.json"]) == 0
             end) =~ "site_url"
    end

    test "grep exits 1 when nothing matches, like grep(1)" do
      assert capture_io(fn ->
               assert CLI.run(["grep", "no-such-string-anywhere", "#{@proj_base}/health"]) == 1
             end) == ""
    end

    test "grep reports binary files without dumping bytes" do
      output =
        capture_io(fn ->
          assert CLI.run(["grep", "eszip", "#{@proj_base}/functions/hello/body"]) == 0
        end)

      assert output == "Binary file #{@proj_base}/functions/hello/body matches\n"
    end

    test "grep without a pattern is a usage error" do
      assert capture_io(:stderr, fn -> assert CLI.run(["grep"]) == 1 end) =~
               "Usage: supablock grep"

      assert capture_io(:stderr, fn -> assert CLI.run(["grep", "-z", "x", "."]) == 1 end) =~
               "unknown option -z"
    end

    test "grep rejects an invalid pattern" do
      assert capture_io(:stderr, fn ->
               assert CLI.run(["grep", "(", "#{@proj_base}/health"]) == 1
             end) =~ "bad pattern"
    end

    test "head and tail print the first/last lines" do
      output =
        capture_io(fn ->
          assert CLI.run(["head", "-n", "2", "#{@proj_base}/health"]) == 0
        end)

      assert output == "auth: healthy\ndb: healthy\n"

      output =
        capture_io(fn ->
          assert CLI.run(["tail", "-n", "1", "#{@proj_base}/health"]) == 0
        end)

      assert output == "storage: healthy\n"
    end

    test "head with multiple paths prints ==> headers <==" do
      output =
        capture_io(fn ->
          assert CLI.run(["head", "-n1", "#{@proj_base}/health", "#{@proj_base}/config/auth.json"]) ==
                   0
        end)

      assert output ==
               "==> #{@proj_base}/health <==\nauth: healthy\n\n==> #{@proj_base}/config/auth.json <==\n{\n"
    end

    test "head passes binary bodies through byte-exact (no unicode errors)" do
      output =
        capture_io(fn ->
          assert CLI.run(["head", "-n", "1", "#{@proj_base}/functions/hello/body"]) == 0
        end)

      assert output == Supablock.Fixtures.function_body() <> "\n"
    end

    test "a downstream reader closing the pipe exits 141 quietly" do
      # Model `supablock ls | head -0`: stdout's device is gone mid-write.
      # The group leader is swapped for a StringIO that is closed before
      # the command writes, which fails exactly like a broken pipe
      # (`{:error, :terminated}`).
      {:ok, dead} = StringIO.open("")
      previous = Process.group_leader()
      Process.group_leader(self(), dead)

      try do
        StringIO.close(dead)
        assert CLI.run(["ls"]) == 141
      after
        Process.group_leader(self(), previous)
      end
    end

    test "cat - reads paths from stdin, one per line (find | cat - pipelines)" do
      input = "#{@proj_base}/health\n#{@proj_base}/config/auth.json\n"

      output =
        capture_io(input, fn ->
          assert CLI.run(["cat", "-"]) == 0
        end)

      assert output =~ "db: healthy"
      assert output =~ "site_url"
    end

    test "cat -0 - reads NUL-delimited paths (find -print0 pairing)" do
      input = "#{@proj_base}/health" <> <<0>> <> "#{@proj_base}/config/auth.json" <> <<0>>

      output =
        capture_io(input, fn ->
          assert CLI.run(["cat", "-0", "-"]) == 0
        end)

      assert output =~ "db: healthy"
      assert output =~ "site_url"
    end

    test "find -print0 emits NUL-delimited paths" do
      output =
        capture_io(fn ->
          assert CLI.run([
                   "find",
                   "organizations/org-alpha",
                   "-maxdepth",
                   "1",
                   "-type",
                   "f",
                   "-print0"
                 ]) == 0
        end)

      assert output ==
               Enum.join(
                 [
                   "organizations/org-alpha/info.json",
                   "organizations/org-alpha/members.json",
                   "organizations/org-alpha/regions.json"
                 ],
                 <<0>>
               ) <> <<0>>
    end

    test "CLI reads work end-to-end through a running daemon" do
      {:ok, _pid} = Supablock.Control.start(nil)
      on_exit(fn -> Supablock.Control.stop() end)

      assert capture_io(fn -> assert CLI.run(["ls", "organizations"]) == 0 end) ==
               "org-alpha\norg-beta\n"

      assert capture_io(fn ->
               assert CLI.run(["cat", "#{@proj_base}/health"]) == 0
             end) =~ "db: healthy"

      assert capture_io(fn ->
               assert CLI.run(["grep", "-l", "site_url", "#{@proj_base}/config"]) == 0
             end) == "#{@proj_base}/config/auth.json\n"
    end

    # `serve stop` against a live daemon is not exercised here: the daemon
    # answers by stopping the VM, which would take the test node with it.
    test "serve refuses to double-start" do
      {:ok, _pid} = Supablock.Control.start(nil)
      on_exit(fn -> Supablock.Control.stop() end)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["serve"]) == 1 end)
      assert stderr =~ "already running"
    end

    test "serve stop without a daemon says so" do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["serve", "stop"]) == 1 end)
      assert stderr =~ "No supablock daemon running."
    end

    test "head on a directory says so and exits 1" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["head", "organizations"]) == 1
        end)

      assert stderr =~ "Is a directory: /organizations"
    end

    test "head without a path is a usage error" do
      assert capture_io(:stderr, fn -> assert CLI.run(["head"]) == 1 end) =~
               "Usage: supablock head"

      assert capture_io(:stderr, fn -> assert CLI.run(["tail", "-n", "x", "p"]) == 1 end) =~
               "non-negative integer"
    end
  end

  test "find and grep without auth exit 2" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["find"]) == 2 end)
    assert stderr =~ "Not authenticated. Run: supablock login"

    stderr = capture_io(:stderr, fn -> assert CLI.run(["grep", "x", "."]) == 2 end)
    assert stderr =~ "Not authenticated. Run: supablock login"
  end

  test "ls and cat without auth exit 2" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["ls"]) == 2 end)
    assert stderr =~ "Not authenticated. Run: supablock login"

    stderr = capture_io(:stderr, fn -> assert CLI.run(["cat", "organizations"]) == 2 end)
    assert stderr =~ "Not authenticated. Run: supablock login"
  end

  # `supablock docker` was removed — the containerized workflow is a plain
  # `docker run` the user invokes directly (see the README / image docs), so
  # the CLI no longer has a docker subcommand.
  test "docker is not a subcommand" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["docker"]) == 1 end)
    assert stderr =~ "Unknown command: docker"
  end

  describe "completions" do
    test "emits a script per shell, no auth required" do
      bash = capture_io(fn -> assert CLI.run(["completions", "bash"]) == 0 end)
      assert bash =~ "complete -F _supablock supablock"
      assert bash =~ "snapshot"
      assert bash =~ "expose_secrets"

      zsh = capture_io(fn -> assert CLI.run(["completions", "zsh"]) == 0 end)
      assert zsh =~ "compdef _supablock supablock"

      fish = capture_io(fn -> assert CLI.run(["completions", "fish"]) == 0 end)
      assert fish =~ "complete -c supablock"
      assert fish =~ "__supablock_paths"
    end

    test "unknown shell exits 1" do
      stderr =
        capture_io(:stderr, fn -> assert CLI.run(["completions", "tcsh"]) == 1 end)

      assert stderr =~ "Unknown shell"
    end
  end

  describe "status --json" do
    test "unauthenticated: authenticated false, exit 2" do
      output = capture_io(fn -> assert CLI.run(["status", "--json"]) == 2 end)
      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["authenticated"] == false
      assert decoded["mounted"] == false
      assert decoded["daemon"] == "none"
    end

    test "authenticated: org count, masked token, exit 0" do
      TestEnv.fake_login!()
      TestEnv.stub_api!()

      output = capture_io(fn -> assert CLI.run(["status", "--json"]) == 0 end)
      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["authenticated"] == true
      assert decoded["organizations"] == 2
      assert is_binary(decoded["token"])
      refute decoded["token"] =~ ~r/^sbp_[a-z0-9]{36,}$/
      assert is_list(decoded["rate_limits"])
    end
  end

  describe "snapshot / diff (drift tracking)" do
    @snap_base "organizations/org-alpha/projects/projaone1234567890ab"

    setup do
      TestEnv.fake_login!()
      TestEnv.stub_api!()

      dir = Path.join(System.tmp_dir!(), "supablock-snap-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "snapshot writes the config surface, skipping volatile subtrees", %{dir: dir} do
      output = capture_io(fn -> assert CLI.run(["snapshot", dir]) == 0 end)
      assert output =~ ~r/Snapshot: \d+ files \(\d+ bytes\) -> /

      assert File.exists?(Path.join(dir, "organizations/org-alpha/info.json"))
      assert File.exists?(Path.join(dir, "#{@snap_base}/config/auth.json"))
      assert File.exists?(Path.join(dir, "#{@snap_base}/advisors/security.json"))
      assert File.exists?(Path.join(dir, "#{@snap_base}/database/migrations.json"))
      assert File.exists?(Path.join(dir, "#{@snap_base}/types.ts"))

      # volatile/heavy subtrees are skipped by default
      refute File.exists?(Path.join(dir, "#{@snap_base}/metrics"))
      refute File.exists?(Path.join(dir, "#{@snap_base}/logs"))
      refute File.exists?(Path.join(dir, "#{@snap_base}/functions/hello/body"))

      # redaction carries into snapshots
      assert File.read!(Path.join(dir, "#{@snap_base}/api-keys/secret")) =~ "REDACTED"
      assert File.read!(Path.join(dir, "#{@snap_base}/secrets.json")) =~ ~s("REDACTED")
    end

    test "snapshot scoped to a subtree writes only that subtree", %{dir: dir} do
      capture_io(fn ->
        assert CLI.run(["snapshot", dir, "organizations/org-beta"]) == 0
      end)

      assert File.exists?(Path.join(dir, "organizations/org-beta/info.json"))
      refute File.exists?(Path.join(dir, "organizations/org-alpha"))
    end

    test "diff is quiet and 0 on an identical tree, unified output and 1 on drift", %{dir: dir} do
      capture_io(fn -> assert CLI.run(["snapshot", dir]) == 0 end)
      assert capture_io(fn -> assert CLI.run(["diff", dir]) == 0 end) == ""

      # rewrite one snapshot file to simulate config drift since the snapshot
      target = Path.join(dir, "#{@snap_base}/config/auth.json")
      File.write!(target, String.replace(File.read!(target), "3600", "60"))

      output = capture_io(fn -> assert CLI.run(["diff", dir]) == 1 end)
      assert output =~ "snapshot/#{@snap_base}/config/auth.json"
      assert output =~ "tree/#{@snap_base}/config/auth.json"
      assert output =~ "+  \"jwt_exp\": 3600"

      output = capture_io(fn -> assert CLI.run(["diff", dir, "--brief"]) == 1 end)
      assert output == "changed: #{@snap_base}/config/auth.json\n"
    end

    test "diff reports files only in the tree or only in the snapshot", %{dir: dir} do
      capture_io(fn -> assert CLI.run(["snapshot", dir]) == 0 end)

      File.rm!(Path.join(dir, "#{@snap_base}/config/auth.json"))
      File.write!(Path.join(dir, "organizations/org-alpha/stale.json"), "{}\n")

      output = capture_io(fn -> assert CLI.run(["diff", dir, "--brief"]) == 1 end)
      assert output =~ "added: #{@snap_base}/config/auth.json"
      assert output =~ "removed: organizations/org-alpha/stale.json"
    end

    test "diff respects the scope argument", %{dir: dir} do
      capture_io(fn -> assert CLI.run(["snapshot", dir]) == 0 end)
      File.write!(Path.join(dir, "organizations/org-alpha/stale.json"), "{}\n")

      # outside the scope: the beta subtree still matches its snapshot
      assert capture_io(fn ->
               assert CLI.run(["diff", dir, "organizations/org-beta"]) == 0
             end) == ""
    end

    test "snapshot --prune removes stale snapshot files", %{dir: dir} do
      capture_io(fn -> assert CLI.run(["snapshot", dir]) == 0 end)
      stale = Path.join(dir, "organizations/org-alpha/stale.json")
      File.write!(stale, "{}\n")

      output = capture_io(fn -> assert CLI.run(["snapshot", dir, "--prune"]) == 0 end)
      assert output =~ "pruned: organizations/org-alpha/stale.json"
      refute File.exists?(stale)
    end

    test "diff on a missing snapshot directory exits 2" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["diff", "/nonexistent-snapshot-dir"]) == 2
        end)

      assert stderr =~ "Not a snapshot directory"
    end
  end
end
