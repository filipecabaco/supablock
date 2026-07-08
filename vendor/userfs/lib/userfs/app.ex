# Vendored from elixir-userfs; modernised child specs for current Elixir.
defmodule Userfs.App do
  use Application

  @moduledoc """
  Userfs application callback module.
  """

  def start(_type, _args) do
    {:ok, _port_path} = find_port!()

    children = [
      Userfs.MountSup
    ]

    opts = [strategy: :one_for_one, name: Userfs.Sup]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Finds the path of the port and returns `{:ok, path}` if successful.
  """

  def find_port!() do
    port_path = Application.app_dir(:efuse) <> "/priv/efuse"
    {true, port_path} = {:filelib.is_file(String.to_charlist(port_path)), port_path}
    {:ok, port_path}
  end
end
