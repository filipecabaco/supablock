defmodule Supablock.DockerEntrypointTest do
  @moduledoc """
  Guards the Docker image's subcommand passthrough against drift.

  `docker/entrypoint.sh` forwards a first argument it recognises straight to
  the CLI; anything else falls through to the mount path, which refuses to
  run without `--device /dev/fuse --cap-add SYS_ADMIN --security-opt
  apparmor=unconfined`. A subcommand missing from that list therefore does
  not merely fail — it tells the user to re-run the image with capabilities
  it never needed. `mcp` was missing exactly this way, so every MCP user was
  being pointed at a privileged container.
  """
  use ExUnit.Case, async: true

  @cli_source "lib/supablock/cli.ex"
  @entrypoint "docker/entrypoint.sh"

  # The quoted heads of Supablock.CLI.dispatch/1's case clauses — the
  # authoritative list of subcommands. `[]` and the `[unknown | _rest]`
  # catch-all carry no literal, so they fall out naturally.
  defp cli_subcommands do
    body =
      @cli_source
      |> File.read!()
      |> then(&Regex.run(~r/defp dispatch\(argv\) do\n(.*?)\n  end\n/s, &1))
      |> Enum.at(1)

    refute is_nil(body), "could not locate dispatch/1 in #{@cli_source}"

    ~r/^\s+\["([^"]+)"\s*\|/m
    |> Regex.scan(body)
    |> MapSet.new(&Enum.at(&1, 1))
  end

  # The alternation in the entrypoint's passthrough `case` branch.
  defp entrypoint_subcommands do
    alternation =
      @entrypoint
      |> File.read!()
      |> then(&Regex.run(~r/\n\s+([a-z0-9|_-]+\|--help)\)/, &1))
      |> Enum.at(1)

    refute is_nil(alternation), "could not locate the passthrough case in #{@entrypoint}"

    MapSet.new(String.split(alternation, "|"))
  end

  test "the entrypoint forwards every CLI subcommand" do
    missing = MapSet.difference(cli_subcommands(), entrypoint_subcommands())

    assert MapSet.equal?(missing, MapSet.new()),
           """
           #{@entrypoint} does not forward: #{missing |> Enum.sort() |> Enum.join(", ")}

           Inside the image these fall through to the mount path, which exits 4
           demanding --cap-add SYS_ADMIN and --device /dev/fuse for a command
           that needs neither. Add them to the passthrough case.
           """
  end

  test "the entrypoint forwards nothing the CLI would reject" do
    unknown = MapSet.difference(entrypoint_subcommands(), cli_subcommands())

    assert MapSet.equal?(unknown, MapSet.new()),
           "#{@entrypoint} forwards subcommands the CLI does not have: " <>
             (unknown |> Enum.sort() |> Enum.join(", "))
  end

  test "only mount and unmount are documented as needing FUSE privileges" do
    entrypoint = File.read!(@entrypoint)

    # The privileged flags may appear only in the /dev/fuse guard's help text
    # and comments — never as the advice for a plain read. If this fires,
    # check that the unprivileged form is still what a reader sees first.
    assert entrypoint =~ "--cap-drop ALL",
           "the entrypoint should show the unprivileged run as the default advice"

    assert entrypoint =~ ~r/Most work does not need a mount/,
           "the /dev/fuse guard should point at the unprivileged readers first"
  end
end
