defmodule Superblock.CredentialsTest do
  use ExUnit.Case, async: false

  alias Superblock.{Credentials, Paths, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  test "store/load/delete round-trip with 0600 perms" do
    assert Credentials.load() == :missing

    :ok = Credentials.store("sbp_ZZZZef1234567890abcdef1234567890abcd4f23")
    assert {:ok, "sbp_ZZZZef1234567890abcdef1234567890abcd4f23"} = Credentials.load()

    assert {:ok, %File.Stat{mode: mode}} = File.stat(Paths.credentials_file())
    assert Bitwise.band(mode, 0o777) == 0o600

    :ok = Credentials.delete()
    assert Credentials.load() == :missing
    # deleting again is still fine
    assert :ok = Credentials.delete()
  end

  test "SUPERBLOCK_TOKEN env var overrides the stored credential" do
    :ok = Credentials.store("sbp_stored000000000000000000000000000000stor")
    System.put_env("SUPERBLOCK_TOKEN", "sbp_envenv0000000000000000000000000000000env")
    on_exit(fn -> System.delete_env("SUPERBLOCK_TOKEN") end)

    assert {:ok, "sbp_envenv0000000000000000000000000000000env"} = Credentials.load()
  end

  test "masked shows at most the last 4 characters" do
    :ok = Credentials.store("sbp_ZZZZef1234567890abcdef1234567890abcd4f23")
    assert Credentials.masked() == "sbp_…4f23"
    refute Credentials.masked() =~ "abcdef"
  end
end
