defmodule Superblock.ProfileTest do
  use ExUnit.Case, async: false

  alias Superblock.{Config, Profile, TestEnv}

  setup do
    base = TestEnv.isolate_xdg!()
    {:ok, base: base}
  end

  defp write_profile!(base, map) do
    path = Path.join(base, "profile.json")
    File.write!(path, Jason.encode!(map))
    path
  end

  test "applies known keys with the same coercion as config set", %{base: base} do
    path =
      write_profile!(base, %{
        "oauth.client_id" => "11111111-2222-4333-8444-555555555555",
        "oauth.client_secret" => "sb_secret_team",
        "mountpoint" => "/mnt/team",
        "ttl.orgs" => 120,
        "expose_secrets" => false
      })

    assert {:ok, profile} = Profile.fetch(path)
    assert {:ok, applied, []} = Profile.apply(profile)

    assert Enum.sort(applied) ==
             ["expose_secrets", "mountpoint", "oauth.client_id", "oauth.client_secret", "ttl.orgs"]

    assert Config.get("mountpoint") == "/mnt/team"
    assert Config.get("ttl.orgs") == 120
    assert Config.get("expose_secrets") == false
    assert Superblock.OAuth.configured?()
  end

  test "unknown keys are skipped, not applied", %{base: base} do
    path =
      write_profile!(base, %{
        "mountpoint" => "/mnt/team",
        "evil.key" => "x",
        "token" => "sbp_nope"
      })

    assert {:ok, profile} = Profile.fetch(path)
    assert {:ok, ["mountpoint"], skipped} = Profile.apply(profile)
    assert Enum.sort(skipped) == ["evil.key", "token"]
  end

  test "a value that fails coercion reports the key", %{base: base} do
    path = write_profile!(base, %{"ttl.orgs" => "many"})

    assert {:ok, profile} = Profile.fetch(path)
    assert {:error, message} = Profile.apply(profile)
    assert message =~ "ttl.orgs"
  end

  test "non-object or invalid JSON is rejected", %{base: base} do
    path = Path.join(base, "bad.json")

    File.write!(path, "[1,2,3]")
    assert {:error, message} = Profile.fetch(path)
    assert message =~ "JSON object"

    File.write!(path, "{nope")
    assert {:error, message} = Profile.fetch(path)
    assert message =~ "not valid JSON"

    assert {:error, message} = Profile.fetch(Path.join(base, "missing.json"))
    assert message =~ "could not read"
  end

  test "fetches a profile over http via the stubbed transport" do
    TestEnv.stub_api!(%{
      "/team/superblock.json" => fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"mountpoint" => "/mnt/from-url"}))
      end
    })

    assert {:ok, profile} = Profile.fetch("https://team.example.com/team/superblock.json")
    assert {:ok, ["mountpoint"], []} = Profile.apply(profile)
    assert Config.get("mountpoint") == "/mnt/from-url"
  end
end
