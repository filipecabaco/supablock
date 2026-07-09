defmodule Supablock.Database do
  @moduledoc """
  Reads schemas, tables and row pages through a project's **Data API**
  (PostgREST) and renders them as CSV or JSON.

  Row data has no Management API endpoint, so it used to come from a direct
  Postgres connection with a password the user supplied via `supablock db add`.
  It now comes from the project's Data API instead — reusing a key supablock can
  already fetch from the `GET`-only Management API (`service_role` by default,
  or `anon` when `db_key` is `publishable`). No extra credential is required, and
  every request is a `GET`, so the tree stays strictly read-only.

  What the Data API can show is what PostgREST exposes: the project's *exposed
  schemas* (`db_schema` in its config, default `public`) and the tables/views in
  them. Non-exposed schemas are invisible; if the Data API is disabled the tree
  simply errors on read. Rows are ordered by primary key for stable paging;
  a table without a primary key has no guaranteed page order.

  Results are cached (the `ttl.db` class) and single-flighted through
  `Supablock.Cache`. The HTTP request seam is swappable for tests via the
  `:supablock, :data_api_fun` application env — see `Supablock.Database.DataApi`.
  """

  alias Supablock.{Cache, Client, Config, Endpoints}
  alias Supablock.Database.DataApi

  @type errno :: :enoent | :eio | :eagain | :eacces
  @type result :: %{columns: [String.t()], rows: [[term]]}
  @type schema_desc :: %{optional(String.t()) => %{columns: [String.t()], pk: [String.t()]}}

  ## Public API used by the Router

  @doc "Exposed (PostgREST) schema names for `ref`."
  @spec schemas(String.t()) :: {:ok, [String.t()]} | {:error, errno}
  def schemas(ref) do
    cached({:db, ref, :schemas}, fn -> exposed_schemas(ref) end)
  end

  @doc "Table/view names exposed in `schema`."
  @spec tables(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, errno}
  def tables(ref, schema) do
    with {:ok, desc} <- describe_schema(ref, schema) do
      {:ok, desc |> Map.keys() |> Enum.sort()}
    end
  end

  @doc "Exact row count of `schema.table` (via PostgREST `count=exact`)."
  @spec row_count(String.t(), String.t(), String.t()) :: {:ok, non_neg_integer} | {:error, errno}
  def row_count(ref, schema, table) do
    cached({:db, ref, :count, schema, table}, fn ->
      headers = [{"accept-profile", schema}, {"prefer", "count=exact"}, {"range", "0-0"}]

      case DataApi.get(ref, "/rest/v1/#{encode(table)}?select=*", headers) do
        {:ok, %{status: status, headers: h}} when status in [200, 206] -> parse_count(h)
        {:ok, %{status: 404}} -> {:error, :enoent}
        {:ok, %{status: status}} -> {:error, http_errno(status)}
        {:error, reason} -> {:error, errno(reason)}
      end
    end)
  end

  @doc "A page of rows from `schema.table` (`columns` + `rows`)."
  @spec rows(String.t(), String.t(), String.t(), non_neg_integer, pos_integer) ::
          {:ok, result} | {:error, errno}
  def rows(ref, schema, table, offset, limit) do
    cached({:db, ref, :rows, schema, table, offset, limit}, fn ->
      with {:ok, desc} <- describe_schema(ref, schema),
           {:ok, columns} <- columns_for(desc, table) do
        query =
          "/rest/v1/#{encode(table)}?select=*&limit=#{limit}&offset=#{offset}" <>
            order_clause(desc, table)

        case DataApi.get(ref, query, [{"accept-profile", schema}]) do
          {:ok, %{status: status, body: body}} when status in [200, 206] ->
            {:ok, %{columns: columns, rows: decode_rows(body, columns)}}

          {:ok, %{status: 404}} ->
            {:error, :enoent}

          {:ok, %{status: status}} ->
            {:error, http_errno(status)}

          {:error, reason} ->
            {:error, errno(reason)}
        end
      end
    end)
  end

  @doc "Render a page of `schema.table` at `offset` as `:csv` or `:json`."
  @spec render_page(String.t(), String.t(), String.t(), non_neg_integer, :csv | :json) ::
          {:ok, binary} | {:error, errno}
  def render_page(ref, schema, table, offset, format) do
    limit = page_size()

    with {:ok, %{columns: columns, rows: rows}} <- rows(ref, schema, table, offset, limit) do
      {:ok, render(columns, rows, format)}
    end
  end

  @doc "Configured page size (rows per file), default 500."
  @spec page_size() :: pos_integer
  def page_size do
    case Config.get("db_page_size") do
      n when is_integer(n) and n > 0 -> n
      _other -> 500
    end
  end

  @doc "Configured default file format (`:csv` or `:json`)."
  @spec format() :: :csv | :json
  def format do
    case Config.get("db_format") do
      "json" -> :json
      _csv -> :csv
    end
  end

  ## Key selection (shared with the Data API transport)

  @doc "Which API key the Data API path uses: `:secret` (default) or `:publishable`."
  @spec key_kind() :: :secret | :publishable
  def key_kind do
    case Config.get("db_key") do
      "publishable" -> :publishable
      "anon" -> :publishable
      _secret -> :secret
    end
  end

  @doc "Pick the `api_key` string of the given `kind` from an api-keys list."
  @spec select_key([map], :secret | :publishable) :: String.t() | nil
  def select_key(keys, kind) when is_list(keys) do
    case Enum.find(keys, fn key -> classify_key(key) == kind end) do
      nil -> nil
      key -> to_string(key["api_key"] || "")
    end
  end

  def select_key(_other, _kind), do: nil

  @doc false
  def classify_key(key) do
    name = to_string(key["name"] || "")
    type = to_string(key["type"] || "")

    cond do
      type == "publishable" or name in ["anon", "publishable"] -> :publishable
      type == "secret" or name in ["service_role", "secret"] -> :secret
      true -> :other
    end
  end

  ## Schema discovery + introspection

  # Exposed schemas come from the Management API's PostgREST config
  # (`db_schema`, a comma-separated list). Anything unexpected degrades to the
  # default single `public` schema so the tree still works.
  defp exposed_schemas(ref) do
    case Client.get(Endpoints.path(:postgrest_config, %{ref: ref})) do
      {:ok, %{"db_schema" => db_schema}} when is_binary(db_schema) ->
        {:ok, parse_schema_list(db_schema)}

      {:ok, _other} ->
        {:ok, ["public"]}

      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        {:error, :eacces}

      {:error, _other} ->
        {:ok, ["public"]}
    end
  end

  defp parse_schema_list(csv) do
    csv
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Table names, ordered column lists, and primary keys for a schema, read from
  # the PostgREST OpenAPI spec (root `/rest/v1/`, one profile per request).
  @spec describe_schema(String.t(), String.t()) :: {:ok, schema_desc} | {:error, errno}
  defp describe_schema(ref, schema) do
    cached({:db, ref, :describe, schema}, fn ->
      case DataApi.get(ref, "/rest/v1/", [{"accept-profile", schema}]) do
        {:ok, %{status: 200, body: body}} -> {:ok, parse_openapi(body)}
        {:ok, %{status: status}} -> {:error, http_errno(status)}
        {:error, reason} -> {:error, errno(reason)}
      end
    end)
  end

  # PostgREST's Swagger doc: `definitions.<table>.properties` lists columns in
  # ordinal order (decoded as ordered objects to keep it), and a primary-key
  # column's description carries the `<pk/>` marker.
  defp parse_openapi(body) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = doc} ->
        doc
        |> ordered_get("definitions")
        |> build_tables()

      _other ->
        %{}
    end
  end

  defp build_tables(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn {table, tdef} ->
      {columns, pk} = columns_and_pk(ordered_get(tdef, "properties"))
      {table, %{columns: columns, pk: pk}}
    end)
  end

  defp build_tables(_other), do: %{}

  defp columns_and_pk(%Jason.OrderedObject{values: values}) do
    columns = Enum.map(values, fn {name, _def} -> name end)

    pk =
      values
      |> Enum.filter(fn {_name, def} -> primary_key?(def) end)
      |> Enum.map(fn {name, _def} -> name end)

    {columns, pk}
  end

  defp columns_and_pk(_other), do: {[], []}

  defp primary_key?(def) do
    case ordered_get(def, "description") do
      desc when is_binary(desc) -> String.contains?(desc, "<pk/>")
      _other -> false
    end
  end

  defp ordered_get(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp ordered_get(_other, _key), do: nil

  defp columns_for(desc, table) do
    case Map.get(desc, table) do
      %{columns: columns} -> {:ok, columns}
      _missing -> {:error, :enoent}
    end
  end

  # Order by primary key for stable offset paging; without one, PostgREST's
  # order is unspecified (documented caveat) and we send no `order`.
  defp order_clause(desc, table) do
    case Map.get(desc, table) do
      %{pk: [_ | _] = pk} -> "&order=" <> Enum.map_join(pk, ",", &encode/1)
      _none -> ""
    end
  end

  # PostgREST returns rows as JSON objects; align them to the (ordered) column
  # list so rendering keeps the table's column order. Missing keys become nil.
  defp decode_rows(body, columns) do
    case Jason.decode(body) do
      {:ok, objects} when is_list(objects) ->
        Enum.map(objects, fn object ->
          Enum.map(columns, fn column -> Map.get(object, column) end)
        end)

      _other ->
        []
    end
  end

  # PostgREST reports the total in `Content-Range: <start>-<end>/<total>`
  # (or `*/0` for an empty table). `*` as the total means the count was not
  # returned.
  defp parse_count(headers) do
    with range when is_binary(range) <- Map.get(headers, "content-range"),
         [_range, total] <- String.split(range, "/", parts: 2),
         {count, _rest} <- Integer.parse(total) do
      {:ok, count}
    else
      _no_count -> {:error, :eio}
    end
  end

  defp encode(name), do: URI.encode(to_string(name), &URI.char_unreserved?/1)

  ## Rendering (pure)

  @doc "Render `columns`/`rows` as a CSV or JSON body with a trailing newline."
  @spec render([String.t()], [[term]], :csv | :json) :: binary
  def render(columns, rows, :csv) do
    header = Enum.map_join(columns, ",", &csv_field/1)

    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(row, ",", &csv_field/1)
      end)

    case body do
      "" -> header <> "\n"
      _rows -> header <> "\n" <> body <> "\n"
    end
  end

  def render(columns, rows, :json) do
    objects =
      Enum.map(rows, fn row ->
        columns
        |> Enum.zip(row)
        |> Enum.map(fn {col, value} -> {col, json_value(value)} end)
        |> Jason.OrderedObject.new()
      end)

    Jason.encode!(objects, pretty: true) <> "\n"
  end

  defp csv_field(value) do
    case scalar(value) do
      nil -> ""
      string -> escape_csv(string)
    end
  end

  defp escape_csv(string) do
    if String.contains?(string, [",", "\"", "\n", "\r"]) do
      ~s(") <> String.replace(string, ~s("), ~s("")) <> ~s(")
    else
      string
    end
  end

  # A scalar string for CSV, or nil for a JSON/SQL null.
  defp scalar(nil), do: nil
  defp scalar(value) when is_binary(value), do: printable(value)
  defp scalar(value) when is_boolean(value), do: to_string(value)
  defp scalar(value) when is_number(value), do: to_string(value)
  defp scalar(value) when is_list(value), do: Jason.encode!(json_value(value))

  defp scalar(value) when is_map(value) and not is_struct(value),
    do: Jason.encode!(json_value(value))

  defp scalar(value) when is_struct(value), do: struct_string(value)
  defp scalar(value), do: inspect(value)

  # A JSON-encodable term for a decoded value.
  defp json_value(nil), do: nil
  defp json_value(value) when is_binary(value), do: printable(value)
  defp json_value(value) when is_number(value) or is_boolean(value), do: value
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), json_value(val)} end)
    |> Jason.OrderedObject.new()
  end

  defp json_value(value) when is_struct(value), do: struct_string(value)
  defp json_value(value), do: inspect(value)

  defp struct_string(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end

  # Keep valid UTF-8 as-is; render raw binaries as \xHEX.
  defp printable(value) do
    if String.valid?(value), do: value, else: "\\x" <> Base.encode16(value, case: :lower)
  end

  ## Cache + error mapping

  defp cached(key, fun) do
    Cache.fetch(key, Config.ttl_ms("db"), fun)
  end

  defp http_errno(401), do: :eacces
  defp http_errno(403), do: :eacces
  defp http_errno(404), do: :enoent
  defp http_errno(406), do: :enoent
  defp http_errno(429), do: :eagain
  defp http_errno(status) when status in 500..599, do: :eagain
  defp http_errno(_other), do: :eio

  defp errno(:unauthorized), do: :eacces
  defp errno(:forbidden), do: :eacces
  defp errno(:no_key), do: :eacces
  defp errno(:not_found), do: :enoent
  defp errno(:rate_limited), do: :eagain
  defp errno(:timeout), do: :eagain
  defp errno({:transport, _reason}), do: :eagain
  defp errno(_other), do: :eio
end
