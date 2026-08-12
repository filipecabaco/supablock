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

  # `sockaddr_un.sun_path` holds 104 bytes on the BSDs (macOS) and 108 on
  # Linux, terminating NUL included — 103 is the portable ceiling. A deep
  # `XDG_STATE_HOME` (a sandbox or CI scratch directory, typically) pushes
  # the control socket past it, and the bind then fails with a bare
  # `:einval` that names nothing.
  @sun_path_max 103

  @doc """
  Whether the control socket path fits in a Unix socket address. Checked
  before binding so the failure arrives with its cause and its fix rather
  than as an unexplained `:einval`.
  """
  @spec validate_control_socket() :: :ok | {:error, String.t()}
  def validate_control_socket do
    path = control_socket()
    size = byte_size(path)

    if size <= @sun_path_max do
      :ok
    else
      {:error,
       "the socket path is #{size} bytes, over the #{@sun_path_max} a Unix " <>
         "socket address holds (#{path}) — point XDG_STATE_HOME somewhere " <>
         "shorter, e.g. XDG_STATE_HOME=/tmp/supablock"}
    end
  end

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
