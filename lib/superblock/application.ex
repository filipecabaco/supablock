defmodule Superblock.Application do
  @moduledoc """
  Boot is deliberately minimal: only the cache (a couple of ETS tables and a
  single-flight coordinator) starts. CLI commands like `login` never touch
  the FUSE machinery; `superblock mount` starts the `:userfs` application and
  the control socket dynamically.
  """

  use Application

  def start(_type, _args) do
    children = [
      Superblock.Cache,
      Superblock.Database.Connections,
      # Serializes credential reads + OAuth refresh (single-flight, and
      # single-use-safe for Supabase's one-shot refresh tokens).
      Superblock.TokenStore
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Superblock.Supervisor)

    # Inside a Burrito-wrapped binary the application boot IS the CLI
    # invocation: dispatch argv and halt with the exit code. (`__BURRITO` is
    # set by Burrito's wrapper; a classic release goes through
    # `Superblock.CLI.main/0` via bin/superblock instead.)
    if System.get_env("__BURRITO") do
      spawn(fn ->
        args = :init.get_plain_arguments() |> Enum.map(&to_string/1)
        System.halt(Superblock.CLI.run(args))
      end)
    end

    result
  end
end
