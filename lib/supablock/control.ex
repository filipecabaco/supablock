defmodule Supablock.Control do
  @moduledoc """
  Control socket for a mounted supablock: a Unix domain socket in the state
  directory speaking a newline-terminated protocol.

      flush\\n    -> ok\\n                       (drop the cache)
      check\\n    -> ok entries=N stale=M\\n     (cache occupancy; no flush)
      unmount\\n  -> ok\\n                       (then unmount and stop the VM)
      <else>\\n   -> err unknown\\n

  The socket file exists only while mounted; `supablock status` uses its
  presence as the "mounted" signal, and `supablock refresh`/`unmount` are
  clients.
  """

  use GenServer

  require Logger

  alias Supablock.Paths

  @connect_timeout 2_000

  ## Server side

  def start(mountpoint) do
    case GenServer.start(__MODULE__, mountpoint, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Remounting after a crash: reuse the running control server.
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop do
    if pid = Process.whereis(__MODULE__) do
      GenServer.stop(pid, :normal, 1_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(mountpoint) do
    Paths.ensure!()
    sock_path = Paths.control_socket()
    File.rm(sock_path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true,
           ifaddr: {:local, String.to_charlist(sock_path)}
         ]) do
      {:ok, listener} ->
        state = %{listener: listener, sock_path: sock_path, mountpoint: mountpoint}
        {:ok, spawn_acceptor(state)}

      {:error, reason} ->
        {:stop, {:control_socket, reason}}
    end
  end

  @impl true
  def handle_info({:accepted, socket, command}, state) do
    handle_command(String.trim(command), socket, state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.sock_path)
    :ok
  end

  defp spawn_acceptor(state) do
    server = self()
    listener = state.listener

    spawn_link(fn -> accept_loop(listener, server) end)
    state
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, command} -> send(server, {:accepted, socket, command})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept_loop(listener, server)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listener, server)
    end
  end

  defp handle_command("flush", socket, _state) do
    Supablock.Cache.flush()
    :gen_tcp.send(socket, "ok\n")
    :gen_tcp.close(socket)
  end

  defp handle_command("check", socket, _state) do
    %{entries: entries, stale: stale} = Supablock.Cache.stats()
    :gen_tcp.send(socket, "ok entries=#{entries} stale=#{stale}\n")
    :gen_tcp.close(socket)
  end

  defp handle_command("unmount", socket, state) do
    :gen_tcp.send(socket, "ok\n")
    :gen_tcp.close(socket)

    spawn(fn ->
      Supablock.Fs.unmount(state.mountpoint)
      System.stop(0)
    end)
  end

  defp handle_command(_unknown, socket, _state) do
    :gen_tcp.send(socket, "err unknown\n")
    :gen_tcp.close(socket)
  end

  ## Client side

  @doc """
  Send a command over the control socket. Returns `{:ok, reply_line}` or
  `{:error, :not_mounted | term}`.
  """
  @spec send_cmd(String.t()) :: {:ok, String.t()} | {:error, term}
  def send_cmd(command) do
    sock_path = Paths.control_socket()

    if File.exists?(sock_path) do
      case :gen_tcp.connect(
             {:local, String.to_charlist(sock_path)},
             0,
             [:binary, packet: :line, active: false],
             @connect_timeout
           ) do
        {:ok, socket} ->
          :gen_tcp.send(socket, command <> "\n")
          reply = :gen_tcp.recv(socket, 0, @connect_timeout)
          :gen_tcp.close(socket)

          case reply do
            {:ok, line} -> {:ok, String.trim(line)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_mounted}
    end
  end
end
