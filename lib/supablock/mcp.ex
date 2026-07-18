defmodule Supablock.MCP do
  @moduledoc """
  A minimal MCP (Model Context Protocol) server over stdio: newline-delimited
  JSON-RPC 2.0, the `initialize`/`tools/list`/`tools/call` subset every MCP
  client speaks. Exposes the tree through four read-only tools — `ls`, `cat`,
  `find` and `grep` — resolved by the same Router as the mount and the CLI,
  so every guarantee (GET-only, redaction, deterministic rendering) carries
  over unchanged.

  Register with any MCP client as command `supablock`, args `["mcp"]`
  (`SUPABLOCK_TOKEN` works for headless use). Protocol notes: requests come
  one JSON object per line; notifications get no response; unknown methods
  get a JSON-RPC error; tool failures come back as `isError: true` results,
  as the spec prescribes.
  """

  alias Supablock.{Tree, Walk}

  # Accepted protocol versions, newest first; an unknown client version is
  # answered with our newest (the client may then disconnect, per spec).
  @protocol_versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  @instructions """
  supablock exposes a read-only Supabase account tree:
  organizations/<org>/{info.json,members.json,regions.json} and
  organizations/<org>/projects/<ref>/ with info.json, health, advisors/,
  config/, api-keys/, secrets.json, functions/, storage/, branches/,
  database/ (schema dirs with schema.json + rows-*.csv, plus
  backups/migrations/readonly.json), network/, logs/<source>, metrics,
  types.ts and upgrade-eligibility.json. Start with: ls "" then descend.
  """

  @doc "Serve MCP over `input`/`output` until EOF. Blocks."
  @spec serve(term, term) :: :ok
  def serve(input \\ :stdio, output \\ :stdio) do
    case IO.binread(input, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        case handle_line(String.trim(line)) do
          :noreply -> :ok
          reply -> IO.binwrite(output, [Jason.encode!(reply), "\n"])
        end

        serve(input, output)
    end
  end

  defp handle_line(""), do: :noreply

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, request} when is_map(request) -> handle(request)
      _bad -> error_reply(nil, -32700, "parse error")
    end
  end

  ## JSON-RPC dispatch

  defp handle(%{"method" => "initialize", "id" => id} = request) do
    client_version = get_in(request, ["params", "protocolVersion"])

    version =
      if client_version in @protocol_versions, do: client_version, else: hd(@protocol_versions)

    result_reply(id, %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "supablock", "version" => version()},
      "instructions" => @instructions
    })
  end

  defp handle(%{"method" => "ping", "id" => id}), do: result_reply(id, %{})

  defp handle(%{"method" => "tools/list", "id" => id}),
    do: result_reply(id, %{"tools" => tools()})

  defp handle(%{"method" => "tools/call", "id" => id} = request) do
    name = get_in(request, ["params", "name"])
    args = get_in(request, ["params", "arguments"]) || %{}

    case call_tool(name, args) do
      {:ok, text} ->
        result_reply(id, %{
          "content" => [%{"type" => "text", "text" => text}],
          "isError" => false
        })

      {:error, message} ->
        result_reply(id, %{
          "content" => [%{"type" => "text", "text" => message}],
          "isError" => true
        })

      :unknown_tool ->
        error_reply(id, -32602, "unknown tool: #{inspect(name)}")
    end
  end

  # Notifications (no id / notifications/*) get no response.
  defp handle(%{"method" => _method, "id" => id}),
    do: error_reply(id, -32601, "method not found")

  defp handle(_notification), do: :noreply

  defp result_reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_reply(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  ## Tools

  defp tools do
    path_property = %{
      "type" => "string",
      "description" =>
        "Tree path, e.g. \"organizations\" or \"organizations/<org>/projects/<ref>/health\". Empty or \"/\" is the root."
    }

    [
      %{
        "name" => "ls",
        "description" => "List a directory of the Supabase tree (file body name for a file).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"path" => path_property},
          "required" => []
        }
      },
      %{
        "name" => "cat",
        "description" => "Read a file of the Supabase tree.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"path" => path_property},
          "required" => ["path"]
        }
      },
      %{
        "name" => "find",
        "description" =>
          "Walk the tree under a path and list every node. Optional filters: type (\"f\"|\"d\"), name (glob on the basename), maxdepth.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => path_property,
            "type" => %{"type" => "string", "enum" => ["f", "d"]},
            "name" => %{"type" => "string"},
            "maxdepth" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => []
        }
      },
      %{
        "name" => "grep",
        "description" =>
          "Search file contents under a path with a regular expression. Directories recurse.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => path_property,
            "pattern" => %{"type" => "string"},
            "ignore_case" => %{"type" => "boolean"},
            "files_only" => %{"type" => "boolean"},
            "maxdepth" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => ["pattern"]
        }
      }
    ]
  end

  defp call_tool("ls", args) do
    path = tool_path(args)

    case Tree.kind(path) do
      {:ok, :dir} ->
        with {:ok, entries} <- Tree.list(path) |> tool_result(path) do
          {:ok, Enum.join(entries, "\n") <> "\n"}
        end

      {:ok, :file} ->
        {:ok, Path.basename(path) <> "\n"}

      {:error, reason} ->
        {:error, describe(path, reason)}
    end
  end

  defp call_tool("cat", args) do
    path = tool_path(args)

    case Tree.read(path) do
      {:ok, body} ->
        if String.valid?(body) and not String.contains?(body, <<0>>),
          do: {:ok, body},
          else: {:error, "binary file (#{byte_size(body)} bytes): #{display(path)}"}

      {:error, :eio} ->
        case Tree.kind(path) do
          {:ok, :dir} -> {:error, "is a directory: #{display(path)}"}
          _not_dir -> {:error, describe(path, :eio)}
        end

      {:error, reason} ->
        {:error, describe(path, reason)}
    end
  end

  defp call_tool("find", args) do
    start = display(tool_path(args))
    max_depth = args["maxdepth"] || :infinity
    type = %{"f" => :file, "d" => :dir}[args["type"]]
    name_regex = if is_binary(args["name"]), do: glob_regex(args["name"])

    {lines, errors} =
      Walk.reduce(start, max_depth, {[], []}, fn
        {:error, path, reason}, {lines, errors} ->
          {lines, [describe(path, reason) | errors]}

        {kind, path}, {lines, errors} ->
          if (type == nil or type == kind) and
               (name_regex == nil or Regex.match?(name_regex, Path.basename(path))) do
            {[path | lines], errors}
          else
            {lines, errors}
          end
      end)

    render_walk_output(Enum.reverse(lines), Enum.reverse(errors))
  end

  defp call_tool("grep", args) do
    with {:ok, regex} <-
           Regex.compile(args["pattern"] || "", if(args["ignore_case"], do: "i", else: "")) do
      start = display(tool_path(args))
      max_depth = args["maxdepth"] || :infinity
      files_only? = args["files_only"] || false

      {lines, errors} =
        Walk.reduce(start, max_depth, {[], []}, fn
          {:error, path, reason}, {lines, errors} ->
            {lines, [describe(path, reason) | errors]}

          {:dir, _path}, acc ->
            acc

          {:file, path}, {lines, errors} ->
            case Tree.read(Walk.router_path(path)) do
              {:ok, body} ->
                {grep_file(regex, path, body, files_only?, lines), errors}

              {:error, reason} ->
                {lines, [describe(path, reason) | errors]}
            end
        end)

      case render_walk_output(Enum.reverse(lines), Enum.reverse(errors)) do
        {:ok, "\n"} -> {:ok, "no matches\n"}
        other -> other
      end
    else
      {:error, {message, at}} -> {:error, "bad pattern at #{at}: #{message}"}
    end
  end

  defp call_tool(_name, _args), do: :unknown_tool

  defp grep_file(regex, path, body, files_only?, lines) do
    cond do
      String.contains?(body, <<0>>) ->
        if Regex.match?(regex, body), do: ["Binary file #{path} matches" | lines], else: lines

      files_only? ->
        if Regex.match?(regex, body), do: [path | lines], else: lines

      true ->
        body
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> line != "" and Regex.match?(regex, line) end)
        |> Enum.reduce(lines, fn {line, n}, lines -> ["#{path}:#{n}:#{line}" | lines] end)
    end
  end

  defp render_walk_output([], []), do: {:ok, "\n"}
  defp render_walk_output([], errors), do: {:error, Enum.join(errors, "\n") <> "\n"}

  defp render_walk_output(lines, errors) do
    suffix = if errors == [], do: "", else: "\nerrors:\n" <> Enum.join(errors, "\n") <> "\n"
    {:ok, Enum.join(lines, "\n") <> "\n" <> suffix}
  end

  defp tool_result({:ok, value}, _path), do: {:ok, value}
  defp tool_result({:error, reason}, path), do: {:error, describe(path, reason)}

  defp tool_path(args) do
    case args["path"] do
      path when is_binary(path) and path != "" -> Walk.router_path(path)
      _none -> "/"
    end
  end

  defp display(path), do: path |> String.trim_leading("/") |> then(&if(&1 == "", do: ".", else: &1))

  defp describe(path, :enoent), do: "no such path: #{display(path)}"
  defp describe(path, :eacces), do: "access denied: #{display(path)} (run: supablock login)"
  defp describe(path, :eagain), do: "rate limited: #{display(path)} — retry shortly"
  defp describe(path, _reason), do: "API error reading #{display(path)}"

  # Shell-glob basename matching: * and ? only, anchored (same as find).
  defp glob_regex(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> pattern <> "$")
  end

  defp version do
    case Application.spec(:supablock, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _unknown -> "0.0.0"
    end
  end
end
