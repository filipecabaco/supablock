defmodule Superblock.ConfigTest do
  use ExUnit.Case, async: false

  alias Superblock.{Config, Paths, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  test "defaults apply when nothing is stored" do
    assert Config.get("mountpoint") == nil
    assert Config.get("expose_secrets") == false
    assert Config.get("http_timeout_ms") == 8_000
    assert Config.get("ttl.orgs") == 60
    assert Config.get("ttl.project") == 30
    assert Config.get("ttl.health") == 10
    assert Config.get("ttl.static") == 300
  end

  test "set/get round-trips with type coercion" do
    assert :ok = Config.set("mountpoint", "/mnt/supabase")
    assert Config.get("mountpoint") == "/mnt/supabase"

    assert :ok = Config.set("expose_secrets", "true")
    assert Config.get("expose_secrets") == true

    assert :ok = Config.set("http_timeout_ms", "1234")
    assert Config.get("http_timeout_ms") == 1234

    assert :ok = Config.set("ttl.orgs", "90")
    assert Config.get("ttl.orgs") == 90
    # setting one ttl leaves the others at their defaults
    assert Config.get("ttl.health") == 10
  end

  test "unknown keys and bad values are rejected" do
    assert {:error, message} = Config.set("nope", "1")
    assert message =~ "Unknown key: nope"
    assert message =~ "Valid keys:"

    assert {:error, _message} = Config.set("http_timeout_ms", "abc")
    assert {:error, _message} = Config.set("expose_secrets", "maybe")
  end

  test "config dir is 0700 and config file 0644 after a write" do
    :ok = Config.set("mountpoint", "/mnt/x")

    assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(Paths.config_dir())
    assert Bitwise.band(dir_mode, 0o777) == 0o700

    assert {:ok, %File.Stat{mode: file_mode}} = File.stat(Paths.config_file())
    assert Bitwise.band(file_mode, 0o777) == 0o644
  end

  test "ttl_ms converts seconds to milliseconds" do
    assert Config.ttl_ms("orgs") == 60_000
    :ok = Config.set("ttl.orgs", "2")
    assert Config.ttl_ms("orgs") == 2_000
  end
end
