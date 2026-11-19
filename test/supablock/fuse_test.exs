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

    Application.put_env(
      :supablock,
      :data_api_fun,
      Supablock.DataApiStub.fun(Supablock.DataApiStub.sample_model(3))
    )

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
      {:ok, mounts} ->
        mounts =~ " #{mountpoint} fuse"

      # macOS has no /proc: `mount` prints "<dev> on <path> (macfuse, …)".
      # The tmp dir resolves through /private, so match either spelling.
      _no_proc ->
        {out, _status} = System.cmd("mount", [], stderr_to_stdout: true)

        Enum.any?(
          [mountpoint, "/private" <> mountpoint],
          &String.contains?(out, " on #{&1} (")
        )
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

  test "a file much larger than one kernel read comes back whole, at any offset",
       %{mountpoint: mp} do
    # 500 rows x ~1 KiB names = one ~500 KiB page: several 128 KiB kernel
    # reads, each sending its offset and size over the port.
    wide = String.duplicate("x", 1_000)

    model = %{
      "app" => %{
        "wide" => %{
          columns: ["id", "name"],
          pk: ["id"],
          rows: for(i <- 0..499, do: %{"id" => i, "name" => "#{i}-#{wide}"})
        }
      }
    }

    Application.put_env(:supablock, :data_api_fun, Supablock.DataApiStub.fun(model))
    Supablock.Cache.flush()

    page =
      Path.join(
        mp,
        "organizations/org-alpha/projects/#{@proj_a1}/database/app/wide/rows-000000.csv"
      )

    body = File.read!(page)

    assert byte_size(body) > 3 * 128 * 1024
    # Row pages report size 0 (knowing it means fetching the page) and are
    # read with direct I/O until EOF, so the whole body still comes back.
    assert File.stat!(page).size == 0
    assert String.starts_with?(body, "id,name\n0-x") or String.starts_with?(body, "id,name\n0,0-x")
    assert body |> String.split("\n", trim: true) |> length() == 501

    # Random-access reads land on the same bytes as the sequential one.
    {:ok, fd} = :file.open(String.to_charlist(page), [:read, :binary, :raw])

    for offset <- [0, 1, 131_071, 131_072, 300_000, byte_size(body) - 10] do
      assert {:ok, chunk} = :file.pread(fd, offset, 4_096)
      assert chunk == binary_part(body, offset, byte_size(chunk))
    end

    assert :eof == :file.pread(fd, byte_size(body), 16)
    :file.close(fd)
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

    budget = 138
    assert TestEnv.total_hits() <= budget

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
    assert %File.Stat{size: 0, type: :regular} = File.stat!(page)
  end

  test "ls -l on a table does not fetch its row pages", %{mountpoint: mp} do
    # 1200 rows: several pages.
    stub = Supablock.DataApiStub.fun(Supablock.DataApiStub.sample_model())
    Application.put_env(:supablock, :data_api_fun, stub)
    Supablock.Cache.flush()

    table = Path.join(mp, "organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets")
    pages = table |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "rows-"))
    assert length(pages) > 1

    test_pid = self()

    Application.put_env(:supablock, :data_api_fun, fn ref, path, headers ->
      if String.contains?(path, "offset="), do: send(test_pid, {:page_fetch, path})
      stub.(ref, path, headers)
    end)

    for page <- pages, do: File.stat!(Path.join(table, page))
    refute_received {:page_fetch, _path}
  end

  test "row pages (size 0) copy whole with GNU cat and cp", %{mountpoint: mp} do
    page =
      Path.join(
        mp,
        "organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets/rows-000000.csv"
      )

    expected = File.read!(page)
    assert byte_size(expected) > 0

    assert {^expected, 0} = System.cmd("cat", [page])

    copy = Path.join(System.tmp_dir!(), "row-page-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(copy) end)
    assert {_out, 0} = System.cmd("cp", [page, copy])
    assert File.read!(copy) == expected
  end

  test "a slow request does not block the rest of the mount", %{mountpoint: mp} do
    stub = Supablock.DataApiStub.fun(Supablock.DataApiStub.sample_model(3))

    Application.put_env(:supablock, :data_api_fun, fn ref, path, headers ->
      # Row pages of app.widgets take 3s: a huge table on a slow link.
      if String.contains?(path, "widgets") and String.contains?(path, "offset="),
        do: Process.sleep(3_000)

      stub.(ref, path, headers)
    end)

    page =
      Path.join(
        mp,
        "organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets/rows-000000.csv"
      )

    # Warm the listing so the slow read below is the only slow thing. The
    # slow reader is a separate OS process (as another user of the mount
    # would be): File.read!/File.ls! in this VM share OTP's single
    # file_server process and would queue behind each other here, not in
    # the mount.
    File.stat!(page)
    slow = Task.async(fn -> System.cmd("cat", [page]) end)
    Process.sleep(300)

    {elapsed_us, _} =
      :timer.tc(fn ->
        assert Enum.sort(File.ls!(Path.join(mp, "organizations"))) == ["org-alpha", "org-beta"]
        assert File.read!(Path.join(mp, "organizations/org-beta/info.json")) =~ "org-beta"
      end)

    assert elapsed_us < 1_500_000,
           "other requests waited #{div(elapsed_us, 1000)}ms behind the slow one"

    assert {body, 0} = Task.await(slow, 15_000)
    assert String.starts_with?(body, "id,name\n0,w0\n")
  end

  test "kill -9 of the port leaves a recoverable state", %{mountpoint: mp} do
    {_pid, {^mp, Supablock.Fs, _fs_state, os_pid}} =
      Enum.find(Userfs.list(), fn {_pid, {mountpoint, _mod, _state, _os}} ->
        mountpoint == mp
      end)

    {_out, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
    wait_unmounted(mp)

    :ok = Fs.recover_stale_mount(mp)

    :ok = Fs.mount(mp)
    wait_mounted!(mp)
    assert Enum.sort(File.ls!(mp)) == ["organizations"]
  end
end
