defmodule Supablock.Fs do
  @moduledoc """
  FUSE-facing adapter: translates `Userfs.Fs` callbacks to `Supablock.Router`
  calls, and owns the mount lifecycle (stale-mount recovery, mount, unmount).

  The filesystem is read-only twice over: the efuse port mounts with `-o ro`
  (so the kernel answers every write attempt with `EROFS` before it reaches
  us), and the userfs behaviour has no mutating callbacks at all — only
  readdir/getattr/read/readlink exist.
  """

  use Userfs.Fs

  require Logger

  alias Supablock.{Control, Paths, Router}

  @errno %{enoent: 2, eio: 5, eagain: 11, eacces: 13, erofs: 30}

  @impl true
  def userfs_init(_mount_point, opts), do: {:ok, opts}

  @impl true
  def userfs_getattr(state, path) do
    result = Router.describe(path)
    Logger.debug("supablock: getattr #{path} -> #{inspect(elem(result, 0))}")

    case result do
      {:ok, :dir} -> {:ok, {0o555, @attr_dir, 0}, state}
      {:ok, {:file, size}} -> {:ok, {0o444, @attr_file, size}, state}
      {:error, error} -> {:error, errno(error), state}
    end
  end

  @impl true
  def userfs_readdir(state, path) do
    result = Router.list(path)
    Logger.debug("supablock: readdir #{path} -> #{inspect(elem(result, 0))}")

    case result do
      {:ok, names} -> {:ok, names, state}
      {:error, error} -> {:error, errno(error), state}
    end
  end

  @impl true
  def userfs_read(state, path) do
    result = Router.read(path)
    Logger.debug("supablock: read #{path} -> #{inspect(elem(result, 0))}")

    case result do
      {:ok, body} -> {:ok, body, state}
      {:error, error} -> {:error, errno(error), state}
    end
  end

  @impl true
  def userfs_readlink(state, _path) do
    {:error, errno(:enoent), state}
  end

  defp errno(error), do: Map.get(@errno, error, @errno.eio)

  @doc """
  Mount at `mountpoint`: recover any stale mount, start the FUSE machinery
  (the `:userfs` application is loaded but not started at boot), the control
  socket, and record `mount.info`.
  """
  @spec mount(String.t()) :: :ok | {:error, term}
  def mount(mountpoint) do
    recover_stale_mount(mountpoint)

    with :ok <- ensure_mountpoint(mountpoint),
         {:ok, _apps} <- Application.ensure_all_started(:userfs),
         {:ok, _pid} <- Userfs.mount(mountpoint, __MODULE__, nil),
         {:ok, _control} <- Control.start(mountpoint) do
      File.write(Paths.mount_info_file(), mountpoint <> "\n")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unmount whatever this VM has mounted (or `mountpoint` explicitly)."
  @spec unmount(String.t() | nil) :: :ok | {:error, :not_mounted}
  def unmount(mountpoint \\ nil) do
    try do
      case mounted_at() do
        nil ->
          if mountpoint, do: external_unmount(mountpoint), else: {:error, :not_mounted}

        mounted ->
          case Userfs.umount(mounted) do
            {:ok, _pid} -> :ok
            {:error, :not_mounted} -> external_unmount(mounted)
          end
      end
    catch
      _kind, _reason ->
        if mountpoint, do: external_unmount(mountpoint), else: {:error, :not_mounted}
    after
      File.rm(Paths.mount_info_file())
      Control.stop()
    end
  end

  @doc "The mountpoint of this VM's active FUSE mount, or nil."
  @spec mounted_at() :: String.t() | nil
  def mounted_at do
    if userfs_running?() do
      case Userfs.list() do
        [{_pid, {mountpoint, __MODULE__, _fs_state, _os_pid}} | _rest] -> mountpoint
        _none -> nil
      end
    end
  end

  defp userfs_running? do
    Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :userfs end)
  end

  @doc """
  If `mountpoint` is (or looks like) a dead FUSE mount — listed in
  /proc/mounts, or stat fails with ENOTCONN — force an unmount so a fresh
  mount can proceed. Failures are ignored; this is best-effort recovery.
  """
  @spec recover_stale_mount(String.t()) :: :ok
  def recover_stale_mount(mountpoint) do
    if stale?(mountpoint) do
      Logger.debug("supablock: recovering stale mount at #{mountpoint}")
      external_unmount(mountpoint)
    end

    :ok
  end

  defp stale?(mountpoint) do
    case File.stat(mountpoint) do
      {:error, :enotconn} -> true
      _other -> listed_as_mounted?(mountpoint)
    end
  end

  defp listed_as_mounted?(mountpoint) do
    case File.read("/proc/mounts") do
      {:ok, mounts} ->
        mounts
        |> String.split("\n")
        |> Enum.any?(fn line ->
          case String.split(line, " ") do
            [_dev, mp, fstype | _rest] -> mp == escape_mount(mountpoint) and fstype =~ "fuse"
            _other -> false
          end
        end)

      {:error, _reason} ->
        case System.cmd("mount", [], stderr_to_stdout: true) do
          {out, 0} -> String.contains?(out, " on #{mountpoint} ")
          _other -> false
        end
    end
  end

  defp escape_mount(mountpoint) do
    mountpoint
    |> String.replace(" ", "\\040")
    |> String.replace("\t", "\\011")
  end

  defp external_unmount(mountpoint) do
    cmds =
      case :os.type() do
        {:unix, :darwin} ->
          [{"umount", [mountpoint]}]

        _other ->
          [
            {"fusermount3", ["-u", mountpoint]},
            {"fusermount", ["-u", mountpoint]},
            {"umount", [mountpoint]}
          ]
      end

    Enum.find_value(cmds, {:error, :not_mounted}, fn {cmd, args} ->
      with path when is_binary(path) <- System.find_executable(cmd),
           {_out, 0} <- System.cmd(cmd, args, stderr_to_stdout: true) do
        :ok
      else
        _any -> nil
      end
    end)
  end

  defp ensure_mountpoint(mountpoint) do
    case File.mkdir_p(mountpoint) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mountpoint, reason}}
    end
  end
end
