defmodule Supablock.CredentialsTest do
  use ExUnit.Case, async: false

  alias Supablock.{Credentials, Paths, TestEnv}

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
    assert :ok = Credentials.delete()
  end

  test "SUPABLOCK_TOKEN env var overrides the stored credential" do
    :ok = Credentials.store("sbp_stored000000000000000000000000000000stor")
    System.put_env("SUPABLOCK_TOKEN", "sbp_envenv0000000000000000000000000000000env")
    on_exit(fn -> System.delete_env("SUPABLOCK_TOKEN") end)

    assert {:ok, "sbp_envenv0000000000000000000000000000000env"} = Credentials.load()
  end

  test "masked shows at most the last 4 characters" do
    :ok = Credentials.store("sbp_ZZZZef1234567890abcdef1234567890abcd4f23")
    assert Credentials.masked() == "sbp_…4f23"
    refute Credentials.masked() =~ "abcdef"
  end

  describe "OAuth credentials (v2)" do
    test "store_oauth round-trips the full pair at 0600" do
      expires_at = System.os_time(:second) + 3600
      :ok = Credentials.store_oauth("sbp_oauth_ZZZZaccess", "oauth_refresh_ZZZZ", expires_at)

      assert {:ok, credential} = Credentials.load_credential()
      assert credential.type == :oauth
      assert credential.access_token == "sbp_oauth_ZZZZaccess"
      assert credential.refresh_token == "oauth_refresh_ZZZZ"
      assert credential.expires_at == expires_at

      assert {:ok, "sbp_oauth_ZZZZaccess"} = Credentials.load()
      assert Credentials.masked() == "sbp_…cess"

      assert {:ok, %File.Stat{mode: mode}} = File.stat(Paths.credentials_file())
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "a legacy single-line PAT file still loads as a :pat credential" do
      :ok = Credentials.store("sbp_ZZZZlegacy00000000000000000000000000ZZZZ")

      assert {:ok, credential} = Credentials.load_credential()
      assert credential.type == :pat
      assert credential.refresh_token == nil
      assert credential.expires_at == nil
    end

    test "the write is atomic: no tmp files survive, content is never partial" do
      :ok = Credentials.store_oauth("sbp_oauth_a", "oauth_refresh_a", 1)
      :ok = Credentials.store_oauth("sbp_oauth_b", "oauth_refresh_b", 2)

      dir = Path.dirname(Paths.credentials_file())
      leftovers = dir |> File.ls!() |> Enum.filter(&String.contains?(&1, ".tmp."))
      assert leftovers == []

      assert {:ok, %{access_token: "sbp_oauth_b"}} = Credentials.load_credential()
    end

    test "SUPABLOCK_TOKEN overrides an OAuth credential as a PAT" do
      :ok = Credentials.store_oauth("sbp_oauth_stored", "oauth_refresh_x", 1)
      System.put_env("SUPABLOCK_TOKEN", "sbp_envenv0000000000000000000000000000000env")
      on_exit(fn -> System.delete_env("SUPABLOCK_TOKEN") end)

      assert {:ok, %{type: :pat, access_token: "sbp_envenv" <> _rest}} =
               Credentials.load_credential()
    end
  end
end
