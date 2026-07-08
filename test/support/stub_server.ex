defmodule Superblock.StubServer do
  @moduledoc """
  A tiny real HTTP server on 127.0.0.1 serving the canned Management API
  fixtures. The e2e suite needs this instead of the in-process Req plug stub
  because it exercises separate OS processes — the released superblock binary
  and the supabase CLI — which must speak actual HTTP.

  GET-only. Requests without a Bearer token get a 401, mirroring the real
  API. Route values follow `Superblock.TestEnv.stub_api!/1`: a JSON-encodable
  value (200) or `{:status, code, value}`.
  """

  @doc "Start the server; returns `{:ok, port}`. Stops when `stop/0` is called."
  def start(routes \\ Superblock.Fixtures.routes()) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ifaddr: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    acceptor = spawn(fn -> accept_loop(listener, routes) end)
    :persistent_term.put(__MODULE__, {listener, acceptor})

    {:ok, port}
  end

  def stop do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        :ok

      {listener, acceptor} ->
        :gen_tcp.close(listener)
        Process.exit(acceptor, :kill)
        :persistent_term.erase(__MODULE__)
        :ok
    end
  end

  defp accept_loop(listener, routes) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, routes) end)
        accept_loop(listener, routes)

      {:error, _closed} ->
        :ok
    end
  end

  defp handle(socket, routes) do
    with {:ok, request} <- read_head(socket, ""),
         {:ok, method, path, headers} <- parse(request) do
      respond(socket, method, path, headers, routes)
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> read_head(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse(request) do
    [head | _body] = String.split(request, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ") do
      [method, target | _version] ->
        headers =
          Map.new(header_lines, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] -> {String.downcase(name), String.trim(value)}
              _other -> {line, ""}
            end
          end)

        {:ok, method, target, headers}

      _other ->
        {:error, :bad_request}
    end
  end

  defp respond(socket, "GET", target, headers, routes) do
    path = target |> String.split("?", parts: 2) |> hd()
    bump(path)

    cond do
      not authorized?(headers) ->
        send_json(socket, 401, %{"message" => "Unauthorized"})

      true ->
        case Map.get(routes, path) do
          nil -> send_json(socket, 404, %{"message" => "not found"})
          {:status, code, value} -> send_json(socket, code, value)
          value -> send_json(socket, 200, value)
        end
    end
  end

  defp respond(socket, _method, _target, _headers, _routes) do
    # Read-only API: anything but GET is refused outright.
    send_json(socket, 405, %{"message" => "method not allowed"})
  end

  defp authorized?(headers) do
    case Map.get(headers, "authorization") do
      "Bearer " <> token when byte_size(token) > 0 -> true
      _other -> false
    end
  end

  defp send_json(socket, code, value) do
    body = Jason.encode!(value)

    response = [
      "HTTP/1.1 #{code} #{reason_phrase(code)}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(_code), do: "Error"

  defp bump(path) do
    if :ets.whereis(:superblock_test_hits) != :undefined do
      :ets.update_counter(:superblock_test_hits, path, 1, {path, 0})
    end
  rescue
    _any -> :ok
  end
end
