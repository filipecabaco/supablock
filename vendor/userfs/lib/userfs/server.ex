# Vendored from elixir-userfs. Modified for supablock: the port is spawned
# with :spawn_executable (no shell splitting of the mount point), and
# unmounting tries fusermount3/fusermount before umount so it works for
# unprivileged users on Linux.
defmodule Userfs.Server do
  @moduledoc """
  The server joins the FS implementation (the `Userfs.Fs` callback module) to the
  port (which joins the Elixir run time to the OS / kernel).
  """

  use GenServer
  use Userfs.Fs, attribs: true

  defstruct mount_point: nil,
            fs_mod: nil,
            fs_state: nil,
            phase: :init,
            port: nil,
            port_os_pid: nil

  @doc """
  Called by the `Userfs.MountSup` supervisor, `start_link` starts an FS
  as a `GenServer`. The three arguments are the same as for `Userfs.mount/3`.
  """

  @spec start_link(String.t(), module, term) :: {:ok, pid} | {:error, term}

  def start_link(mount_point, fs_mod, fs_opts) do
    GenServer.start_link(__MODULE__, [mount_point, fs_mod, fs_opts], [])
  end

  @doc """
  Called to stop an FS. A single argument, the PID of the server, is given.
  This is the same as `Userfs.umount/1` except it requires the PID of the
  `GenServer` process, instead of the mount point.
  """

  @spec stop(pid) :: :ok

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Return a tuple representing the state of the FS. This PID of the `GenServer`
  process must be passed as an argument.

  The tuple elements are the mount point, callback module, the internal
  state of the callback module and the OS PID of the port process.
  """

  @spec status(pid) :: {String.t(), atom, term, integer}

  def status(pid) do
    {:ok, status} = GenServer.call(pid, :status)
    status
  end

  @doc false
  def init([mount_point, fs_mod, fs_opts]) do
    {:ok, port_path} = Userfs.App.find_port!()

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(port_path)},
        [{:args, [mount_point]}, {:packet, 4}, :nouse_stdio, :exit_status, :binary]
      )

    {:ok, fs_state} = fs_mod.userfs_init(mount_point, fs_opts)

    state = %__MODULE__{
      mount_point: mount_point,
      fs_mod: fs_mod,
      fs_state: fs_state,
      port: port
    }

    Process.sleep(50)
    {:ok, state}
  end

  def terminate(
        _reason,
        %__MODULE__{
          port_os_pid: nil
        } = _state
      ) do
    :undefined
  end

  def terminate(_reason, state) do
    server_stop_port(state)
    :undefined
  end

  @doc false
  # The bytes of `content` in [offset, offset + size); empty past EOF.
  def chunk(content, offset, _size) when offset >= byte_size(content), do: <<>>

  def chunk(content, offset, size),
    do: binary_part(content, offset, min(size, byte_size(content) - offset))

  @requests [@request_readdir, @request_getattr, @request_readlink, @request_read, @request_open]

  # Supablock: requests carry an id, and each one runs in its own process
  # that replies to the port directly (any process may write to a port; the
  # reply echoes the id so the port matches it to the waiting FUSE thread).
  # So a slow callback — a large table page, a slow API — no longer holds up
  # every other `ls`/`cat` on the mount. The callback module's state is
  # therefore read-only after `userfs_init/2`: the state a callback returns
  # is ignored, and anything it must share between calls (Supablock.Fs keeps
  # body snapshots) lives in ETS.
  def handle_info(
        {port, {:data, <<@magiccookie::size(32), code::size(32), id::size(32), args::binary>>}},
        %__MODULE__{port: port, fs_mod: fs_mod, fs_state: fs_state} = state
      )
      when code in @requests do
    spawn(fn ->
      reply = run_request(fs_mod, fs_state, code, args)

      try do
        Port.command(port, <<@magiccookie::size(32), code::size(32), id::size(32), reply::binary>>)
      rescue
        # the port closed (unmounted) while this request ran
        ArgumentError -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(
        {port,
         {:data, <<@magiccookie::size(32), @status_data::size(32), port_os_pid::size(32)>>}},
        %__MODULE__{phase: :init, port: port} = state
      ) do
    {:noreply, %__MODULE__{state | phase: :ready, port_os_pid: port_os_pid}}
  end

  def handle_info(
        {port, {:exit_status, 0}},
        %__MODULE__{port: port} = state
      ) do
    {:noreply, server_slow_stop(%{state | port_os_pid: nil}, :normal)}
  end

  def handle_info(
        {port, {:exit_status, 143}},
        %__MODULE__{phase: :stopping, port: port} = state
      ) do
    {:noreply, %{state | port_os_pid: nil}}
  end

  def handle_info(
        {port, {:exit_status, _nonzero}},
        %__MODULE__{port: port} = state
      ) do
    {:noreply, server_slow_stop(%{state | port_os_pid: nil}, :normal)}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), data::binary>>}},
        %__MODULE__{port: port, port_os_pid: port_os_pid} = state
      ) do
    log_error(
      "ignoring port (PID #{port_os_pid}) unrecognised data #{inspect(data)} to userfs #{:erlang.pid_to_list(self())}"
    )

    {:noreply, state}
  end

  def handle_info(
        {port, {:data, data}},
        %__MODULE__{port: port, port_os_pid: port_os_pid} = state
      ) do
    log_error(
      "port (PID #{port_os_pid}) data #{inspect(data)} to userfs #{:erlang.pid_to_list(self())} received without correct cookie"
    )

    {_method, state} = server_stop_port(state)

    {:noreply,
     server_slow_stop(state, {:error, "communication with port fatally compromised (bad cookie)"})}
  end

  def handle_info(
        {:slow_stop, {reason, {:genserver_client, client}}},
        %__MODULE__{phase: :stopping} = state
      ) do
    GenServer.reply(client, :ok)
    {:stop, reason, state}
  end

  def handle_info({:slow_stop, reason}, %__MODULE__{phase: :stopping} = state) do
    {:stop, reason, state}
  end

  def handle_call(:stop, from, %__MODULE__{phase: :init} = state) do
    {:noreply, server_slow_stop(state, {:normal, from})}
  end

  def handle_call(:stop, from, %__MODULE__{} = state) do
    case server_stop_port(state) do
      {:unmounted, state} ->
        {:reply, :ok, server_slow_stop(state, :normal)}

      {:killed, state} ->
        {:noreply, server_slow_stop(state, {:normal, {:genserver_client, from}})}
    end
  end

  def handle_call(:status, _from, %__MODULE__{port_os_pid: port_os_pid} = state) do
    status = {
      state.mount_point,
      state.fs_mod,
      state.fs_state,
      port_os_pid
    }

    {:reply, {:ok, status}, state}
  end

  defp server_stop_port(%__MODULE__{mount_point: mount_point, port_os_pid: port_os_pid} = state) do
    case try_unmount(mount_point) do
      :ok ->
        {:unmounted, %{state | port_os_pid: nil}}

      :error ->
        Process.sleep(50)
        System.cmd("kill", ["#{port_os_pid}"], stderr_to_stdout: true)
        Process.sleep(50)
        {:killed, %{state | port_os_pid: nil}}
    end
  end

  defp try_unmount(mount_point) do
    Enum.find_value(unmount_cmds(), :error, fn {cmd, args} ->
      case System.find_executable(cmd) do
        nil ->
          nil

        _found ->
          case System.cmd(cmd, args ++ [mount_point], stderr_to_stdout: true) do
            {_out, 0} -> :ok
            {_out, _err} -> nil
          end
      end
    end)
  end

  defp unmount_cmds do
    case :os.type() do
      {:unix, :darwin} -> [{"umount", []}, {"diskutil", ["unmount"]}]
      _other -> [{"fusermount3", ["-u"]}, {"fusermount", ["-u"]}, {"umount", []}]
    end
  end

  defp server_slow_stop(%__MODULE__{phase: phase} = state, _info) when phase === :stopping do
    state
  end

  defp server_slow_stop(state, info) do
    Process.send_after(self(), {:slow_stop, info}, 100, [])
    %{state | phase: :stopping}
  end

  # The reply after code and id: result (0 or an errno), then the data.
  @doc false
  def run_request(fs_mod, fs_state, code, args) do
    {cb_fun, cb_args, encode} = request(code, args)

    case callback(fs_mod, cb_fun, [fs_state | cb_args]) do
      {:ok, reply, _state} -> <<0::size(32), encode.(reply)::binary>>
      {:error, err_code, _state} when is_integer(err_code) -> <<err_code::size(32)>>
    end
  catch
    # A crashing callback (or a malformed request) must not take the mount
    # down, nor leave the FUSE thread waiting: reply EIO (5).
    kind, reason ->
      log_error("userfs request #{code} to #{fs_mod} crashed: #{inspect({kind, reason})}")
      <<5::size(32)>>
  end

  defp request(@request_readdir, path),
    do: {:userfs_readdir, [path], fn names -> for name <- names, into: <<>>, do: <<name::binary, 0>> end}

  defp request(@request_getattr, path) do
    {:userfs_getattr, [path],
     fn {mode, type, size} when is_integer(mode) and is_integer(type) and is_integer(size) ->
       <<mode::size(32), type::size(32), size::size(32)>>
     end}
  end

  defp request(@request_readlink, path),
    do: {:userfs_readlink, [path], fn dest when is_binary(dest) -> <<dest::binary, 0>> end}

  # The port sends the kernel's offset and size with every read, so only that
  # chunk goes back over the pipe (a sub-binary, no copy here).
  defp request(@request_read, <<offset::size(64), size::size(32), path::binary>>),
    do: {:userfs_read, [path], fn content when is_binary(content) -> chunk(content, offset, size) end}

  defp request(@request_open, path),
    do: {:userfs_open, [path], fn flags when is_integer(flags) -> <<flags::size(32)>> end}

  # `userfs_open/2` is optional: without it every file opens with no flags.
  defp callback(fs_mod, :userfs_open, [fs_state, _path] = args) do
    if function_exported?(fs_mod, :userfs_open, 2),
      do: apply(fs_mod, :userfs_open, args),
      else: {:ok, 0, fs_state}
  end

  defp callback(fs_mod, cb_fun, args), do: apply(fs_mod, cb_fun, args)


  defp log_error(msg) do
    :ok = :error_logger.error_msg(String.to_charlist(msg))
  end
end
