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
      Superblock.Cache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Superblock.Supervisor)
  end
end
