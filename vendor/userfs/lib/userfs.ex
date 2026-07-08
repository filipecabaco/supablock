# Vendored from elixir-userfs (MIT, Michael Wright); unchanged apart from
# formatting.
defmodule Userfs do
  @moduledoc """
  API calls to mount, and manage filesystems.
  """

  defstruct mount_point: nil, fs_data: nil

  @efuse_attr_dir :userfs_defs.attr_dir()
  @efuse_attr_file :userfs_defs.attr_file()
  @efuse_attr_symlink :userfs_defs.attr_symlink()

  @type type :: unquote(@efuse_attr_dir) | unquote(@efuse_attr_file) | unquote(@efuse_attr_symlink)
  @type mode :: unquote(0o755) | unquote(0o644)

  @doc """
  Mount a filesystem. The three parameters are the mount point, the callback
  module which implements the filesystem, and a term, which can be anything, and
  is passed to the filesystem implementation initialisation.

  See `Userfs.Fs` for information on how to implement a filesystem callback
  module.
  """

  @spec mount(String.t(), module, term) :: {:ok, pid}

  def mount(mount_point, fs_mod, fs_state) do
    Userfs.MountSup.start_child(mount_point, fs_mod, fs_state)
  end

  @doc """
  Unmount a filesystem.
  """

  @spec umount(String.t()) :: {:ok, pid} | {:error, :not_mounted}

  def umount(mount_point) do
    case Enum.filter(
           list(),
           fn {_pid, {this_mount_point, _fs_mod, _fs_state, _os_pid}} ->
             this_mount_point == mount_point
           end
         ) do
      [] ->
        {:error, :not_mounted}

      [{pid, _status} | _rest] ->
        try do
          :ok = Userfs.Server.stop(pid)
        catch
          # The server may finish stopping (normally) while the call is in
          # flight; any exit here means it is going away, which is the goal.
          :exit, _reason -> :ok
        end

        {:ok, pid}
    end
  end

  @doc """
  Enumerate the mounted filesystems. Returns a list of tuples, each
  tuple having two elements, the first being the PID of the Elixir process
  managing the FS, and the second being the status of the FS reported by it.
  """

  @spec list() :: [{pid, {String.t(), atom, term, integer}}]

  def list() do
    Enum.filter(
      Enum.map(
        Userfs.MountSup.which_children(),
        fn {:undefined, pid, :worker, [Userfs.Server]} ->
          status =
            try do
              Userfs.Server.status(pid)
            catch
              :exit, {:noproc, _} -> :stopped
              :exit, {:normal, _} -> :stopped
              :exit, {:timeout, _} -> :stopped
            end

          {pid, status}
        end
      ),
      fn {_pid, status} -> status !== :stopped end
    )
  end
end
