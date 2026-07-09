defmodule Superblock.DbCredentialsTest do
  use ExUnit.Case, async: false

  alias Superblock.{DbCredentials, Paths, TestEnv}

  @ref "projaone1234567890ab"
  @url "postgres://sbuser:sbpass@db.example.com:5432/postgres"

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  test "put/fetch/refs/delete round-trip" do
    assert :missing = DbCredentials.fetch(@ref)
    refute DbCredentials.configured?(@ref)

    assert :ok = DbCredentials.put(@ref, @url)
    assert {:ok, @url} = DbCredentials.fetch(@ref)
    assert DbCredentials.configured?(@ref)
    assert DbCredentials.refs() == [@ref]

    assert :ok = DbCredentials.delete(@ref)
    assert :missing = DbCredentials.fetch(@ref)
    assert DbCredentials.refs() == []
  end

  test "the db file is written 0600" do
    :ok = DbCredentials.put(@ref, @url)
    path = Path.join(Paths.config_dir(), "db.json")
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "multiple refs are stored and listed sorted" do
    :ok = DbCredentials.put("zzz", @url)
    :ok = DbCredentials.put("aaa", @url)
    assert DbCredentials.refs() == ["aaa", "zzz"]

    # deleting one leaves the other
    :ok = DbCredentials.delete("aaa")
    assert DbCredentials.refs() == ["zzz"]
  end

  test "masked hides the password but keeps the rest" do
    assert DbCredentials.masked(@url) == "postgres://sbuser:****@db.example.com:5432/postgres"
    # no userinfo -> unchanged
    assert DbCredentials.masked("postgres://db.example.com/postgres") ==
             "postgres://db.example.com/postgres"
  end

  test "SUPERBLOCK_DB_URL_<REF> overrides the stored URL" do
    :ok = DbCredentials.put(@ref, @url)
    override = "postgres://other:pass@localhost:5432/postgres"
    System.put_env("SUPERBLOCK_DB_URL_PROJAONE1234567890AB", override)

    assert {:ok, ^override} = DbCredentials.fetch(@ref)

    System.delete_env("SUPERBLOCK_DB_URL_PROJAONE1234567890AB")
    assert {:ok, @url} = DbCredentials.fetch(@ref)
  end
end
