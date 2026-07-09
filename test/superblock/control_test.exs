defmodule Superblock.ControlTest do
  use ExUnit.Case, async: false

  alias Superblock.{Control, TestEnv}

  setup do
    TestEnv.isolate_xdg!()

    {:ok, _pid} = Control.start("/tmp/does-not-matter")
    on_exit(fn -> Control.stop() end)
    :ok
  end

  test "flush over a real local socket" do
    assert File.exists?(Superblock.Paths.control_socket())
    assert {:ok, "ok"} = Control.send_cmd("flush")
  end

  test "unknown commands get an error reply" do
    assert {:ok, "err unknown"} = Control.send_cmd("format-disk")
  end

  test "check reports cache occupancy without flushing" do
    Superblock.Cache.flush()
    Superblock.Cache.fetch(:probe_key, 60_000, fn -> {:ok, 1} end)

    assert {:ok, reply} = Control.send_cmd("check")
    assert reply =~ ~r/^ok entries=\d+ stale=\d+$/
    # the entry we just inserted is still cached (check does not flush)
    assert {:hit, {:ok, 1}} = Superblock.Cache.lookup(:probe_key)
  end

  test "send_cmd without a socket reports not mounted" do
    Control.stop()
    assert {:error, :not_mounted} = Control.send_cmd("flush")
  end
end
