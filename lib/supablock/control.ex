defmodule Supablock.Control do
  @moduledoc """
  Control socket for a running supablock daemon — a mount, or a mountless
  cache daemon (`supablock serve`). A Unix domain socket in the state
  directory speaking a newline-terminated protocol:

      flush\\n         -> ok\\n                    (drop the cache)
      check\\n         -> ok entries=N stale=M\\n  (cache occupancy; no flush)
      unmount\\n       -> ok\\n                    (unmount if mounted, stop the VM)
      kind <path>\\n   -> ok dir|file\\n           | err <errno>\\n
      list <path>\\n   -> ok <bytes>\\n<payload>   | err <errno>\\n
      read <path>\\n   -> ok <bytes>\\n<payload>   | err <errno>\\n
      <else>\\n        -> err unknown\\n

  The `kind`/`list`/`read` commands resolve tree paths through this node's
  Router — and therefore through its warm cache — so `supablock ls|cat|grep`
  on the same machine reuse everything the daemon has already fetched
  instead of starting cold (see `Supablock.Tree`). They are served in their
  own processes: a slow API fetch never blocks `flush`/`unmount`.

  The socket file exists only while the daemon runs; `supablock status`
  uses its presence as the "running" signal, and `supablock
  refresh`/`unmount`/`serve stop` are clients.
  """

  use GenServer

  require Logger

  alias Supablock.{Paths, Router}

  @connect_timeout 2_000

  # A remote read may have to fetch from the API on a cold daemon cache, so
  # give it several HTTP budgets before the client falls back to fetching
  # directly itself.
  @read_timeout 30_000

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
        # Belt-and-suspenders with the 0700 state dir: the socket itself is
        # owner-only, so no other local user can drive the daemon's API
        # (which reads the account with the owner's token).
        File.chmod(sock_path, 0o600)
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
      # A `supablock serve` daemon has no mount to undo.
      if state.mountpoint, do: Supablock.Fs.unmount(state.mountpoint)
      System.stop(0)
    end)
  end

  defp handle_command("kind " <> path, socket, _state) do
    serve_async(socket, fn ->
      case Router.kind(path) do
        {:ok, kind} -> :gen_tcp.send(socket, "ok #{kind}\n")
        {:error, reason} -> :gen_tcp.send(socket, "err #{reason}\n")
      end
    end)
  end

  defp handle_command("list " <> path, socket, _state) do
    serve_async(socket, fn ->
      case Router.list(path) do
        {:ok, entries} -> send_payload(socket, Enum.map(entries, &[&1, ?\n]))
        {:error, reason} -> :gen_tcp.send(socket, "err #{reason}\n")
      end
    end)
  end

  defp handle_command("read " <> path, socket, _state) do
    serve_async(socket, fn ->
      case Router.read(path) do
        {:ok, body} -> send_payload(socket, body)
        {:error, reason} -> :gen_tcp.send(socket, "err #{reason}\n")
      end
    end)
  end

  defp handle_command(_unknown, socket, _state) do
    :gen_tcp.send(socket, "err unknown\n")
    :gen_tcp.close(socket)
  end

  # Reads can hit the API; keep them off the control GenServer so flush and
  # unmount stay responsive. Sending/closing a passive socket from another
  # process is fine — the acceptor stays the owner.
  defp serve_async(socket, fun) do
    spawn(fn ->
      fun.()
      :gen_tcp.close(socket)
    end)
  end

  defp send_payload(socket, payload) do
    data = IO.iodata_to_binary(payload)
    :gen_tcp.send(socket, ["ok #{byte_size(data)}\n", data])
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

  @doc """
  Resolve a tree path through a running daemon's warm cache. Path errors
  (`:enoent`, `:eacces`, `:eagain`, `:eio`) are authoritative — the daemon
  ran the same Router the caller would. Anything transport-shaped (no
  daemon, stale socket, an older daemon without the read commands) is
  `{:error, :unavailable}`, telling the caller to read directly instead.
  """
  @spec remote(:kind | :list | :read, String.t()) ::
          {:ok, :dir | :file | [String.t()] | binary} | {:error, atom}
  def remote(op, path) do
    sock_path = Paths.control_socket()

    if File.exists?(sock_path) do
      case :gen_tcp.connect(
             {:local, String.to_charlist(sock_path)},
             0,
             [:binary, packet: :line, active: false],
             @connect_timeout
           ) do
        {:ok, socket} ->
          :gen_tcp.send(socket, "#{op} #{path}\n")
          reply = recv_reply(op, socket)
          :gen_tcp.close(socket)
          reply

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp recv_reply(op, socket) do
    case :gen_tcp.recv(socket, 0, @read_timeout) do
      {:ok, "ok " <> rest} -> parse_ok(op, String.trim(rest), socket)
      {:ok, "err " <> reason} -> {:error, errno(String.trim(reason))}
      {:ok, _other} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp parse_ok(:kind, "dir", _socket), do: {:ok, :dir}
  defp parse_ok(:kind, "file", _socket), do: {:ok, :file}

  defp parse_ok(op, size, socket) when op in [:list, :read] do
    with {bytes, ""} <- Integer.parse(size),
         {:ok, payload} <- recv_exact(socket, bytes) do
      case op do
        :read -> {:ok, payload}
        :list -> {:ok, String.split(payload, "\n", trim: true)}
      end
    else
      _other -> {:error, :unavailable}
    end
  end

  defp parse_ok(_op, _other, _socket), do: {:error, :unavailable}

  defp recv_exact(_socket, 0), do: {:ok, ""}

  defp recv_exact(socket, bytes) do
    # The header came through the line packetizer; the payload is raw.
    :inet.setopts(socket, packet: :raw)

    case :gen_tcp.recv(socket, bytes, @read_timeout) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp errno("enoent"), do: :enoent
  defp errno("eacces"), do: :eacces
  defp errno("eagain"), do: :eagain
  defp errno("eio"), do: :eio
  # "unknown" from an older daemon, or anything unexpected: fall back.
  defp errno(_other), do: :unavailable
end
