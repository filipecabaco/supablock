# Vendored from elixir-userfs; converted from :simple_one_for_one to
# DynamicSupervisor for current Elixir.
defmodule Userfs.MountSup do
  @moduledoc """
  Mount supervisor.
  """

  use DynamicSupervisor

  @doc """
  Starts the supervisor and links to it.
  """

  @spec start_link(term) :: {:ok, pid} | {:error, term}

  def start_link(_opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a child (a supervised filesystem). The arguments are the mount
  point, the implementation module and the options / config. See `Userfs.mount/3`
  for more details.
  """

  @spec start_child(String.t(), module, term) :: {:ok, pid} | {:error, term}

  def start_child(mount_point, fs_mod, fs_state) do
    spec = %{
      id: Userfs.Server,
      start: {Userfs.Server, :start_link, [mount_point, fs_mod, fs_state]},
      restart: :transient,
      shutdown: 30_000,
      type: :worker,
      modules: [Userfs.Server]
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Return the supervisors running children. See `DynamicSupervisor.which_children/1`
  for more details.
  """

  def which_children() do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
