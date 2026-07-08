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

    assert stderr =~ "Token rejected — check it at app.supabase.com"
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
