defmodule Superblock.SupabaseCliE2eTest do
  @moduledoc """
  End-to-end tests that drive the *released* superblock binary through a real
  kernel FUSE mount and cross-check what it serves against the official
  `supabase` CLI — both talk to the same Management API, so their views must
  agree.

  Excluded by default; run with:

      MIX_ENV=prod mix release            # the suite drives bin/superblock
      mix test --include e2e

  Prerequisites: the `supabase` CLI on PATH, /dev/fuse, and the prod release
  built. Two modes:

    * hermetic (default) — a local stub API (Superblock.StubServer) serves
      the canned fixtures; the CLI is pointed at it via `--profile` and
      superblock via SUPERBLOCK_API_URL. Runs anywhere, no credentials.

    * live — set SUPERBLOCK_E2E_LIVE=1 and SUPABASE_ACCESS_TOKEN=sbp_… to run
      the same assertions against the real api.supabase.com using your
      account. Read-only: superblock cannot issue anything but GET, and the
      CLI commands used (orgs list, projects list) are reads.
  """

  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias Superblock.Router

  setup_all do
    launcher = Path.expand("../../bin/superblock", __DIR__)
    release = Path.expand("../../_build/prod/rel/superblock/bin/superblock", __DIR__)

    unless File.exists?(release) do
      raise "e2e needs the prod release; run: MIX_ENV=prod mix release"
    end

    supabase =
      System.find_executable("supabase") ||
        raise "e2e needs the supabase CLI on PATH (https://supabase.com/docs/guides/local-development/cli/getting-started)"

    live? = System.get_env("SUPERBLOCK_E2E_LIVE") == "1"

    base = Path.join(System.tmp_dir!(), "superblock-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(base, "workdir"))
    mountpoint = Path.join(base, "mnt")

    {token, sb_env, cli_env} =
      if live? do
        token =
          System.get_env("SUPABASE_ACCESS_TOKEN") ||
            raise "live e2e needs SUPABASE_ACCESS_TOKEN (a real sbp_… token)"

        {token, [], []}
      else
        {:ok, api_port} = Superblock.StubServer.start()

        # Constructed at runtime (never a literal): must satisfy the CLI's
        # ^sbp_[a-f0-9]{40}$ token pattern.
        token = "sbp_" <> String.duplicate("f", 40)

        profile = Path.join(base, "profile.yaml")

        File.write!(profile, """
        name: superblock-e2e
        api_url: http://127.0.0.1:#{api_port}
        dashboard_url: http://127.0.0.1:#{api_port}
        project_host: localhost
        """)

        {token, [{"SUPERBLOCK_API_URL", "http://127.0.0.1:#{api_port}"}],
         [{"SUPABASE_PROFILE", profile}]}
      end

    common_env = [
      {"XDG_CONFIG_HOME", Path.join(base, "config")},
      {"XDG_STATE_HOME", Path.join(base, "state")},
      {"LC_ALL", "C.UTF-8"}
    ]

    on_exit(fn ->
      System.cmd(launcher, ["unmount", mountpoint],
        env: common_env,
        stderr_to_stdout: true
      )

      Enum.each([{"fusermount3", ["-u"]}, {"fusermount", ["-u"]}, {"umount", []}], fn
        {cmd, args} ->
          if System.find_executable(cmd) do
            System.cmd(cmd, args ++ [mountpoint], stderr_to_stdout: true)
          end
      end)

      unless live?, do: Superblock.StubServer.stop()
      File.rm_rf!(base)
    end)

    {:ok,
     launcher: launcher,
     supabase: supabase,
     token: token,
     live?: live?,
     mountpoint: mountpoint,
     sb_env: common_env ++ sb_env,
     cli_env: [{"SUPABASE_ACCESS_TOKEN", token} | cli_env],
     workdir: Path.join(base, "workdir")}
  end

  test "the mounted tree agrees with the supabase CLI", ctx do
    # -- login stores the credential through the release binary
    {out, 0} = superblock(ctx, ["login", "--token", ctx.token])
    assert out =~ "Token valid"

    # -- mount in a background OS process, wait for the kernel mount
    mount_port = start_mount(ctx)
    assert wait_until(fn -> mounted?(ctx.mountpoint) end, 15_000), "mount did not appear"

    {status_out, 0} = superblock(ctx, ["status"])
    assert status_out =~ "Mounted: yes"

    # -- organizations/ must equal the CLI's org listing
    cli_org_ids = cli_orgs(ctx)
    assert cli_org_ids != [], "supabase orgs list returned nothing"

    fs_orgs = ls!(Path.join(ctx.mountpoint, "organizations"))
    assert Enum.sort(fs_orgs) == Enum.sort(Enum.map(cli_org_ids, &Router.sanitize/1))

    # -- each org's projects/ must equal the CLI's project listing for it
    cli_projects = cli_projects(ctx)

    for org <- fs_orgs do
      expected =
        cli_projects
        |> Enum.filter(&(&1["organization_id"] == org))
        |> Enum.map(&Router.sanitize(&1["id"]))

      fs_projects = ls!(Path.join([ctx.mountpoint, "organizations", org, "projects"]))
      assert Enum.sort(fs_projects) == Enum.sort(expected), "project mismatch for org #{org}"
    end

    # -- a project's info.json carries the same facts as the CLI
    case cli_projects do
      [] ->
        :ok

      [project | _rest] ->
        info_path =
          Path.join([
            ctx.mountpoint,
            "organizations",
            project["organization_id"],
            "projects",
            project["id"],
            "info.json"
          ])

        info = info_path |> File.read!() |> Jason.decode!()
        assert info["id"] == project["id"]
        assert info["name"] == project["name"]
        assert info["region"] == project["region"]

        # stat size is exact
        %File.Stat{size: size} = File.stat!(info_path)
        assert size == byte_size(File.read!(info_path))
    end

    # -- read-only, even for root
    assert {:error, :erofs} = File.touch(Path.join(ctx.mountpoint, "nope"))
    assert {:error, :erofs} = File.mkdir(Path.join(ctx.mountpoint, "nope"))

    # -- refresh flushes the live mount's cache
    {refresh_out, 0} = superblock(ctx, ["refresh"])
    assert refresh_out =~ "Cache flushed."

    # -- unmount from "another terminal"
    {unmount_out, 0} = superblock(ctx, ["unmount"])
    assert unmount_out =~ "Unmounted"
    assert wait_until(fn -> not mounted?(ctx.mountpoint) end, 10_000), "unmount left the mount"

    close_mount(mount_port)
  end

  ## superblock release driver

  defp superblock(ctx, args) do
    System.cmd(ctx.launcher, args, env: ctx.sb_env, stderr_to_stdout: true)
  end

  defp start_mount(ctx) do
    env = Enum.map(ctx.sb_env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    Port.open({:spawn_executable, String.to_charlist(ctx.launcher)}, [
      :binary,
      :exit_status,
      args: ["mount", ctx.mountpoint],
      env: env
    ])
  end

  defp close_mount(port) do
    if Port.info(port), do: Port.close(port)
  catch
    _kind, _reason -> :ok
  end

  ## supabase CLI drivers

  defp cli(ctx, args) do
    System.cmd(ctx.supabase, args ++ ["--workdir", ctx.workdir],
      env: ctx.cli_env,
      stderr_to_stdout: false
    )
  end

  defp cli_orgs(ctx) do
    {out, 0} = cli(ctx, ["orgs", "list"])
    parse_org_table(out)
  end

  defp cli_projects(ctx) do
    {out, 0} = cli(ctx, ["projects", "list", "--output", "json"])
    out |> String.trim() |> Jason.decode!()
  end

  # `supabase orgs list` only renders an ASCII table (no --output json); pull
  # the first column out of its data rows.
  defp parse_org_table(out) do
    out
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&Regex.match?(~r/^[-+| ]+$/, &1))
    |> Enum.reject(&Regex.match?(~r/^\|?\s*ID\b/i, &1))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("|")
      |> String.split(~r/\s{2,}|\|/, trim: true)
      |> List.first()
      |> to_string()
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  ## helpers

  defp ls!(dir), do: dir |> File.ls!() |> Enum.sort()

  defp mounted?(mountpoint) do
    case File.read("/proc/mounts") do
      {:ok, mounts} -> mounts =~ " #{mountpoint} fuse"
      _error -> false
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(200) && do_wait_until(fun, deadline)
    end
  end
end
