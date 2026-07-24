defmodule Supablock.ControlTest do
  use ExUnit.Case, async: false

  alias Supablock.{Control, TestEnv}

  setup do
    TestEnv.isolate_xdg!()

    {:ok, _pid} = Control.start("/tmp/does-not-matter")
    on_exit(fn -> Control.stop() end)
    :ok
  end

  test "flush over a real local socket" do
    assert File.exists?(Supablock.Paths.control_socket())
    assert {:ok, "ok"} = Control.send_cmd("flush")
  end

  test "unknown commands get an error reply" do
    assert {:ok, "err unknown"} = Control.send_cmd("format-disk")
  end

  test "check reports cache occupancy without flushing" do
    Supablock.Cache.flush()
    Supablock.Cache.fetch(:probe_key, 60_000, fn -> {:ok, 1} end)

    assert {:ok, reply} = Control.send_cmd("check")
    assert reply =~ ~r/^ok entries=\d+ stale=\d+$/
    assert {:hit, {:ok, 1}} = Supablock.Cache.lookup(:probe_key)
  end

  test "send_cmd without a socket reports not mounted" do
    Control.stop()
    assert {:error, :not_mounted} = Control.send_cmd("flush")
  end

  describe "remote reads (kind / list / read over the socket)" do
    @health_path "/organizations/org-alpha/projects/projaone1234567890ab/health"

    setup do
      TestEnv.fake_login!()
      TestEnv.stub_api!()
      :ok
    end

    test "kind classifies without rendering" do
      assert {:ok, :dir} = Control.remote(:kind, "/organizations")
      assert {:ok, :file} = Control.remote(:kind, @health_path)
    end

    test "list returns entries, read returns the exact body" do
      assert {:ok, ["org-alpha", "org-beta"]} = Control.remote(:list, "/organizations")

      assert {:ok, body} = Control.remote(:read, @health_path)
      assert body =~ "db: healthy"
      assert body == Supablock.Render.health(Supablock.Fixtures.health())
    end

    test "read passes binary bodies through byte-exact" do
      path = "/organizations/org-alpha/projects/projaone1234567890ab/functions/hello/body"
      assert {:ok, body} = Control.remote(:read, path)
      assert body == Supablock.Fixtures.function_body()
    end

    test "path errors are authoritative, not fallbacks" do
      assert {:error, :enoent} = Control.remote(:kind, "/organizations/nope")
      assert {:error, :enoent} = Control.remote(:read, "/organizations/nope")
    end

    test "remote without a daemon is :unavailable" do
      Control.stop()
      assert {:error, :unavailable} = Control.remote(:read, "/organizations")
    end

    test "Tree prefers the daemon and falls back when it is gone" do
      assert {:ok, :dir} = Supablock.Tree.kind("/organizations")

      Control.stop()
      assert {:ok, :dir} = Supablock.Tree.kind("/organizations")
      assert {:ok, entries} = Supablock.Tree.list("/organizations")
      assert entries == ["org-alpha", "org-beta"]
    end
  end
end
