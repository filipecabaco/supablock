defmodule Supablock.DataApiStub do
  @moduledoc """
  Builds a `:data_api_fun` for tests: a fake PostgREST that answers the three
  request shapes `Supablock.Database` makes — the OpenAPI root spec (per
  `Accept-Profile`), a `count=exact` probe, and a row page — from an in-memory
  model.

  Model shape:

      %{
        "app" => %{
          "widgets" => %{
            columns: ["id", "name"],
            pk: ["id"],
            rows: [%{"id" => 0, "name" => "w0"}, ...]
          }
        }
      }

  Install with `Application.put_env(:supablock, :data_api_fun, DataApiStub.fun(model))`.
  """

  @doc "A `(ref, path, headers) -> {:ok, resp} | {:error, term}` fun over `model`."
  def fun(model) do
    fn _ref, path, headers ->
      schema = header(headers, "accept-profile") || "public"
      tables = Map.get(model, schema, %{})

      cond do
        root?(path) ->
          {:ok, ok(200, %{}, openapi_body(tables))}

        count?(headers) ->
          count = row_count(tables, table_of(path))
          {:ok, ok(206, %{"content-range" => content_range(count)}, "[]")}

        true ->
          {:ok, ok(200, %{}, rows_body(tables, table_of(path), offset_of(path), limit_of(path)))}
      end
    end
  end

  defp ok(status, headers, body), do: %{status: status, headers: headers, body: body}

  defp root?(path), do: strip_query(path) == "/rest/v1/"

  defp count?(headers) do
    case header(headers, "prefer") do
      value when is_binary(value) -> String.contains?(value, "count=")
      _none -> false
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp table_of(path) do
    path
    |> strip_query()
    |> String.trim_leading("/rest/v1/")
    |> URI.decode()
  end

  defp strip_query(path), do: path |> String.split("?", parts: 2) |> hd()

  defp query_param(path, key) do
    case String.split(path, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query) |> Map.get(key)
      _none -> nil
    end
  end

  defp offset_of(path), do: to_int(query_param(path, "offset"), 0)
  defp limit_of(path), do: to_int(query_param(path, "limit"), 1_000)

  defp to_int(nil, default), do: default

  defp to_int(value, default) do
    case Integer.parse(value) do
      {n, _rest} -> n
      :error -> default
    end
  end

  defp row_count(tables, table) do
    case Map.get(tables, table) do
      %{rows: rows} -> length(rows)
      _missing -> 0
    end
  end

  defp content_range(0), do: "*/0"
  defp content_range(count), do: "0-0/#{count}"

  defp rows_body(tables, table, offset, limit) do
    rows =
      case Map.get(tables, table) do
        %{rows: rows} -> rows |> Enum.drop(offset) |> Enum.take(limit)
        _missing -> []
      end

    Jason.encode!(rows)
  end

  # A minimal PostgREST Swagger doc: column order is preserved (ordered
  # objects), and primary-key columns carry the `<pk/>` marker in `description`.
  defp openapi_body(tables) do
    definitions =
      tables
      |> Enum.map(fn {table, %{columns: columns} = spec} ->
        pk = Map.get(spec, :pk, [])

        properties =
          columns
          |> Enum.map(fn column ->
            description = if column in pk, do: "Note:\nThis is a Primary Key.<pk/>", else: ""

            {column, %{"type" => "string", "format" => "text", "description" => description}}
          end)
          |> Jason.OrderedObject.new()

        {table, %{"properties" => properties, "required" => pk}}
      end)
      |> Jason.OrderedObject.new()

    Jason.encode!(%{"swagger" => "2.0", "definitions" => definitions})
  end
end
