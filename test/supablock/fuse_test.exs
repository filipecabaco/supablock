defmodule Supablock.FuseTest do
  @moduledoc """
  End-to-end tests against a real FUSE mount (served by the efuse port,
  backed by the API stub). Excluded by default; run with:

      mix test --include fuse

  Needs /dev/fuse and the compiled port (see `supablock doctor`). In CI,
  run inside a container started with `--device /dev/fuse --cap-add SYS_ADMIN`.
  """

  use ExUnit.Case, async: false

  @moduletag :fuse
  @moduletag timeout: 60_000

  alias Supablock.{Fs, Render, TestEnv}

  @proj_a1 "projaone1234567890ab"

  setup do
    TestEnv.isolate_xdg!()
    TestEnv.fake_login!()
    TestEnv.stub_api!()
    # Every project now has a database/ tree; stub its Data API so any mount
    # traversal (including walk!/1) stays hermetic and never touches the network.
    Application.put_env(:supablock, :data_api_fun, Supablock.DataApiStub.fun(db_model()))
    Supablock.Cache.flush()

    mountpoint =
      Path.join(System.tmp_dir!(), "supablock-fuse-#{System.unique_integer([:positive])}")

    {:ok, _apps} = Application.ensure_all_started(:userfs)
    :ok = Fs.mount(mountpoint)
    wait_mounted!(mountpoint)

    on_exit(fn ->
      Fs.unmount(mountpoint)
      wait_unmounted(mountpoint)
      File.rmdir(mountpoint)
      Application.delete_env(:supablock, :data_api_fun)
    end)

    {:ok, mountpoint: mountpoint}
  end

  defp wait_mounted!(mountpoint) do
    unless Enum.any?(1..100, fn _i ->
             mounted?(mountpoint) || (Process.sleep(50) && false)
           end) do
      raise "FUSE mount did not appear at #{mountpoint}"
    end
  end

  defp wait_unmounted(mountpoint) do
    Enum.any?(1..40, fn _i -> !mounted?(mountpoint) || (Process.sleep(50) && false) end)
  end

  defp mounted?(mountpoint) do
    case File.read("/proc/mounts") do
      {:ok, mounts} -> mounts =~ " #{mountpoint} fuse"
      _error -> false
    end
  end

  test "ls and cat behave like a filesystem", %{mountpoint: mp} do
    assert Enum.sort(File.ls!(mp)) == ["organizations"]
    assert Enum.sort(File.ls!(Path.join(mp, "organizations"))) == ["org-alpha", "org-beta"]

    info = File.read!(Path.join(mp, "organizations/org-alpha/info.json"))
    assert info == Render.json(Supablock.Fixtures.org_alpha())

    health = File.read!(Path.join(mp, "organizations/org-alpha/projects/#{@proj_a1}/health"))
    assert health =~ "db: healthy\n"
  end

  test "stat sizes are exact byte counts", %{mountpoint: mp} do
    path = Path.join(mp, "organizations/org-alpha/info.json")
    %File.Stat{size: size, mode: mode, type: :regular} = File.stat!(path)
    assert size == byte_size(File.read!(path))
    assert Bitwise.band(mode, 0o777) == 0o444

    %File.Stat{type: :directory, mode: dir_mode} = File.stat!(Path.join(mp, "organizations"))
    assert Bitwise.band(dir_mode, 0o777) == 0o555
  end

  test "a full recursive walk stays within the request budget", %{mountpoint: mp} do
    walk!(mp)

    # Distinct endpoints behind the fixture tree; every one may be fetched
    # exactly once thanks to the cache:
    #   orgs(1) projects(1) org info+members+regions(6)
    #   per project (x3): info health auth db api-keys functions branches
    #     realtime-config storage-config buckets sso third-party (12 -> 36)
    #   per project (x3): postgrest config for database/ schemas (3)
    #   per function (x2): info + body (4)
    #   per project (x3): logs/<source> for 11 sources (33)
    #   per project (x3): metrics -> api-keys(reveal) + metrics scrape (6)
    #     (Metrics.fetch calls the API directly, so its api-keys read is
    #      a separate hit from api-keys/secret above.)
    #   per project (x3): advisors security+performance (6)
    #   per project (x3): secrets, types.ts, upgrade-eligibility (9)
    #   per project (x3): config disk pgbouncer pooler postgrest (12)
    #   per project (x3): database backups migrations readonly (9)
    #   per project (x3): network restrictions ssl-enforcement
    #     custom-hostname vanity-subdomain (12)
    # (Data API row/table/schema reads go through the injected stub, not
    #  the API.)
    budget = 138
    assert TestEnv.total_hits() <= budget

    # walking again is free (everything within TTL)
    before = TestEnv.total_hits()
    walk!(mp)
    assert TestEnv.total_hits() == before
  end

  defp walk!(dir) do
    Enum.each(File.ls!(dir), fn name ->
      path = Path.join(dir, name)

      case File.stat!(path) do
        %File.Stat{type: :directory} -> walk!(path)
        %File.Stat{type: :regular} -> File.read!(path)
      end
    end)
  end

  test "every write attempt fails read-only", %{mountpoint: mp} do
    file = Path.join(mp, "organizations/org-alpha/info.json")

    assert {:error, :erofs} = File.write(file, "x")
    assert {:error, :erofs} = File.mkdir(Path.join(mp, "newdir"))
    assert {:error, :erofs} = File.rm(file)
    assert {:error, :erofs} = File.touch(Path.join(mp, "newfile"))
    assert {:error, :erofs} = File.rename(file, Path.join(mp, "renamed"))
  end

  test "secret api key is redacted by default", %{mountpoint: mp} do
    secret =
      File.read!(Path.join(mp, "organizations/org-alpha/projects/#{@proj_a1}/api-keys/secret"))

    assert secret =~ "REDACTED"
    refute secret =~ "TOPSECRET"

    publishable =
      File.read!(Path.join(mp, "organizations/org-alpha/projects/#{@proj_a1}/api-keys/publishable"))

    assert publishable == "sb_publishable_FAKEFAKEFAKE\n"
  end

  test "flush over the control socket causes a re-fetch", %{mountpoint: mp} do
    path = Path.join(mp, "organizations/org-alpha/info.json")
    File.read!(path)
    assert TestEnv.hits("/v1/organizations/org-alpha") == 1

    assert {:ok, "ok"} = Supablock.Control.send_cmd("flush")

    File.read!(path)
    assert TestEnv.hits("/v1/organizations/org-alpha") == 2
  end

  # End-to-end for the database/ tree over a real mount: the rows come from the
  # stubbed Data API set up in `setup` (Supablock.DataApiStub), so this is
  # hermetic — no network, no database. Exposed schemas still come from the
  # stubbed Management API.
  test "database tree serves rows over the mount", %{mountpoint: mp} do
    project = Path.join(mp, "organizations/org-alpha/projects/#{@proj_a1}")
    db = Path.join(project, "database")

    assert "database" in File.ls!(project)
    assert "app" in File.ls!(db)
    assert "widgets" in File.ls!(Path.join(db, "app"))

    widgets = Path.join(db, "app/widgets")
    assert "rows-000000.csv" in File.ls!(widgets)

    page = Path.join(widgets, "rows-000000.csv")
    body = File.read!(page)
    assert String.starts_with?(body, "id,name\n0,w0\n")
    # stat size matches the rendered bytes
    assert File.stat!(page).size == byte_size(body)
  end

  defp db_model do
    %{
      "app" => %{
        "widgets" => %{
          columns: ["id", "name"],
          pk: ["id"],
          rows: for(i <- 0..2, do: %{"id" => i, "name" => "w#{i}"})
        }
      },
      "public" => %{}
    }
  end

  test "kill -9 of the port leaves a recoverable state", %{mountpoint: mp} do
    # Servers from earlier tests may still be winding down; pick ours.
    {_pid, {^mp, Supablock.Fs, _fs_state, os_pid}} =
      Enum.find(Userfs.list(), fn {_pid, {mountpoint, _mod, _state, _os}} ->
        mountpoint == mp
      end)

    {_out, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
    wait_unmounted(mp)

    :ok = Fs.recover_stale_mount(mp)

    # a fresh mount over the same mountpoint works
    :ok = Fs.mount(mp)
    wait_mounted!(mp)
    assert Enum.sort(File.ls!(mp)) == ["organizations"]
  end
end
