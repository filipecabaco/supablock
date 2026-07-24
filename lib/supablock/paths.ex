defmodule Supablock.Paths do
  @moduledoc """
  XDG-style directory resolution for supablock's config and state files.
  """

  @spec config_dir() :: String.t()
  def config_dir do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(home(), ".config")
    Path.join(base, "supablock")
  end

  @spec state_dir() :: String.t()
  def state_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.join(home(), ".local/state")
    Path.join(base, "supablock")
  end

  @spec config_file() :: String.t()
  def config_file, do: Path.join(config_dir(), "config.json")

  @spec credentials_file() :: String.t()
  def credentials_file, do: Path.join(config_dir(), "credentials")

  @spec log_file() :: String.t()
  def log_file, do: Path.join(state_dir(), "supablock.log")

  @spec control_socket() :: String.t()
  def control_socket, do: Path.join(state_dir(), "control.sock")

  @spec mount_info_file() :: String.t()
  def mount_info_file, do: Path.join(state_dir(), "mount.info")

  @doc """
  Create the config and state directories, both locked down to the owner.
  The config dir holds the credentials; the state dir holds the control
  socket, and any local user who could reach that socket could drive the
  daemon's API with the owner's token — so it must be owner-only too.
  """
  @spec ensure!() :: :ok
  def ensure! do
    File.mkdir_p!(config_dir())
    File.chmod!(config_dir(), 0o700)
    File.mkdir_p!(state_dir())
    File.chmod!(state_dir(), 0o700)
    :ok
  end

  defp home do
    System.user_home() || "/root"
  end
end
