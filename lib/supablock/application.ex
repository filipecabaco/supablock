defmodule Supablock.Application do
  @moduledoc """
  Boot is deliberately minimal: only the cache (a couple of ETS tables and a
  single-flight coordinator) starts. CLI commands like `login` never touch
  the FUSE machinery; `supablock mount` starts the `:userfs` application and
  the control socket dynamically.
  """

  use Application

  def start(_type, _args) do
    children = [
      Supablock.Cache,
      Supablock.TokenStore
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Supablock.Supervisor)

    if System.get_env("__BURRITO") do
      spawn(fn ->
        args = :init.get_plain_arguments() |> Enum.map(&to_string/1)
        System.halt(Supablock.CLI.run(args))
      end)
    end

    result
  end
end
