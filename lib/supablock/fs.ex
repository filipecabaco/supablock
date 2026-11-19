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

  alias Supablock.{Cache, Control, Paths, Router}

  @errno %{enoent: 2, eio: 5, eagain: 11, eacces: 13, erofs: 30}

  # Body snapshots: `getattr` renders a file once and keeps the bytes; every
  # `read` of that path then serves the same bytes. So the size the kernel
  # caches from `stat` always matches what `cat` gets (no truncated or padded
  # reads when the cache refreshes in between), a multi-chunk read never
  # splices two versions, and a file is rendered once per open, not once per
  # 128 KiB chunk. `supablock refresh` (a cache generation bump) drops them
  # all. A snapshot lives while it is in use: each hit pushes its expiry
  # @snapshot_idle_ms further out, so a long read stays consistent and a file
  # sees fresh data once it has been left alone that long. Total bytes are
  # capped; least recently used snapshots go first.
  #
  # Callbacks run concurrently (one process per FUSE request), so snapshots
  # live in a public ETS table created per mount, not in the callback state.
  # When two requests render the same path at once the first stored body
  # wins and both serve it.
  @snapshot_idle_ms 10_000
  @snapshot_max_bytes 64 * 1024 * 1024

  @impl true
  def userfs_init(_mount_point, opts) do
    table = :ets.new(:supablock_snapshots, [:set, :public, read_concurrency: true])
    {:ok, %{opts: opts, snapshots: table}}
  end

  @impl true
  def userfs_getattr(state, path) do
    result =
      case Router.kind(path) do
        {:ok, :dir} ->
          {:ok, :dir}

        # Row pages: size unknown until fetched; opened with direct I/O.
        {:ok, :file} ->
          if Router.unsized?(path), do: {:ok, :unsized}, else: body(state, path)

        {:error, _reason} = error ->
          error
      end

    Logger.debug("supablock: getattr #{path} -> #{inspect(elem(result, 0))}")

    case result do
      {:ok, :dir} -> {:ok, {0o555, @attr_dir, 0}, state}
      {:ok, :unsized} -> {:ok, {0o444, @attr_file, 0}, state}
      {:ok, body} -> {:ok, {0o444, @attr_file, byte_size(body)}, state}
      {:error, error} -> {:error, errno(error), state}
    end
  end

  @impl true
  def userfs_open(state, path) do
    flags = if Router.unsized?(path), do: @open_direct_io, else: 0
    {:ok, flags, state}
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
    result = body(state, path)
    Logger.debug("supablock: read #{path} -> #{inspect(elem(result, 0))}")

    case result do
      {:ok, body} -> {:ok, body, state}
      {:error, error} -> {:error, errno(error), state}
    end
  end

  @doc false
  # The snapshot for `path` if one is live, else a fresh render (stored on
  # success; errors are never snapshotted). Public for tests; `now` is
  # injectable for the same reason.
  def body(%{snapshots: table}, path, now \\ System.monotonic_time(:millisecond)) do
    generation = Cache.generation()

    case live_snapshot(table, path, generation, now) do
      {:ok, body} ->
        {:ok, body}

      :none ->
        with {:ok, body} <- Router.read(path) do
          {:ok, store(table, path, body, generation, now)}
        end
    end
  end

  # {path, body, last_used, generation, bytes}
  defp live_snapshot(table, path, generation, now) do
    case :ets.lookup(table, path) do
      [{^path, body, used, ^generation, _bytes}] when now - used < @snapshot_idle_ms ->
        :ets.update_element(table, path, {3, now})
        {:ok, body}

      _missing_idle_or_flushed ->
        :none
    end
  end

  defp store(_table, _path, body, _generation, _now) when byte_size(body) > @snapshot_max_bytes,
    do: body

  defp store(table, path, body, generation, now) do
    entry = {path, body, now, generation, byte_size(body)}

    # A concurrent render of the same path may have stored first: serve
    # that one, so every reader of this path sees the same bytes.
    body =
      if :ets.insert_new(table, entry) do
        body
      else
        case live_snapshot(table, path, generation, now) do
          {:ok, theirs} ->
            theirs

          :none ->
            :ets.insert(table, entry)
            body
        end
      end

    prune(table, generation, now)
    body
  end

  # Drop idle and pre-flush snapshots, then the least recently used ones
  # until the total is under the cap. Runs only when a body is stored.
  defp prune(table, generation, now) do
    cutoff = now - @snapshot_idle_ms

    :ets.select_delete(table, [
      {{:_, :_, :"$1", :"$2", :_}, [{:orelse, {:"=<", :"$1", cutoff}, {:"/=", :"$2", generation}}],
       [true]}
    ])

    entries = :ets.select(table, [{{:"$1", :_, :"$2", :_, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    total = Enum.reduce(entries, 0, fn {_path, _used, bytes}, acc -> acc + bytes end)

    if total > @snapshot_max_bytes do
      entries
      |> Enum.sort_by(fn {_path, used, _bytes} -> used end)
      |> Enum.reduce_while(total, fn {path, _used, bytes}, left ->
        if left <= @snapshot_max_bytes do
          {:halt, left}
        else
          :ets.delete(table, path)
          {:cont, left - bytes}
        end
      end)
    end

    :ok
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

    # The control socket comes first: if it is refused (a daemon is already
    # running, or the socket path is unusable) nothing has been mounted yet.
    # The reverse order left a live FUSE mount with no daemon owning it,
    # which reads as ENOTCONN until someone force-unmounts.
    with :ok <- ensure_mountpoint(mountpoint),
         {:ok, _control} <- Control.start(mountpoint),
         {:ok, _apps} <- stop_control_on_error(Application.ensure_all_started(:userfs)),
         {:ok, _pid} <- stop_control_on_error(Userfs.mount(mountpoint, __MODULE__, nil)) do
      File.write(Paths.mount_info_file(), mountpoint <> "\n")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_control_on_error({:error, _reason} = error) do
    Control.stop()
    error
  end

  defp stop_control_on_error(ok), do: ok

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
