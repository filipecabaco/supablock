defmodule Superblock.Database do
  @moduledoc """
  Reads schemas, tables and row pages straight from a project's Postgres
  database and renders them as CSV or JSON.

  This is the one place superblock touches something other than the `GET`-only
  Management API: row data has no API endpoint, so it comes from a direct,
  read-only Postgres connection using the URL stored via `superblock db add`.
  Only `SELECT` (and `information_schema` introspection) is ever issued — the
  SQL is generated here and never taken from the user — so the connection
  cannot write.

  Results are cached (the `ttl.db` class) and single-flighted through
  `Superblock.Cache`, so an `ls -R` over a schema costs a handful of queries,
  not one per file. The executor is swappable for tests via the
  `:superblock, :db_query_fun` application env (a `(ref, sql, params) ->
  {:ok, %{columns: [...], rows: [[...]]}} | {:error, reason}` fun).
  """

  alias Superblock.{Cache, Config, DbCredentials}
  alias Superblock.Database.Connections

  @type errno :: :enoent | :eio | :eagain | :eacces
  @type result :: %{columns: [String.t()], rows: [[term]]}

  @system_schemas ~w(pg_catalog information_schema pg_toast)

  ## Public API used by the Router

  @doc "Whether row browsing is available for `ref` (a DB URL is configured)."
  @spec configured?(String.t()) :: boolean
  def configured?(ref), do: DbCredentials.configured?(ref)

  @doc "Non-system schema names for `ref`."
  @spec schemas(String.t()) :: {:ok, [String.t()]} | {:error, errno}
  def schemas(ref) do
    cached({:db, ref, :schemas}, fn ->
      with {:ok, %{rows: rows}} <- query(ref, schemas_sql(), []) do
        {:ok, Enum.map(rows, fn [name] -> name end)}
      end
    end)
  end

  @doc "Base-table names in `schema`."
  @spec tables(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, errno}
  def tables(ref, schema) do
    cached({:db, ref, :tables, schema}, fn ->
      with {:ok, %{rows: rows}} <- query(ref, tables_sql(), [schema]) do
        {:ok, Enum.map(rows, fn [name] -> name end)}
      end
    end)
  end

  @doc "Exact row count of `schema.table`."
  @spec row_count(String.t(), String.t(), String.t()) :: {:ok, non_neg_integer} | {:error, errno}
  def row_count(ref, schema, table) do
    cached({:db, ref, :count, schema, table}, fn ->
      with {:ok, %{rows: [[count]]}} <- query(ref, count_sql(schema, table), []) do
        {:ok, to_int(count)}
      end
    end)
  end

  @doc "A page of rows from `schema.table` (`columns` + `rows`)."
  @spec rows(String.t(), String.t(), String.t(), non_neg_integer, pos_integer) ::
          {:ok, result} | {:error, errno}
  def rows(ref, schema, table, offset, limit) do
    cached({:db, ref, :rows, schema, table, offset, limit}, fn ->
      query(ref, rows_sql(schema, table), [limit, offset])
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

  @doc """
  Validate a connection URL by opening it and running `SELECT 1`.
  Returns `:ok` or `{:error, message}`. Used by `superblock db add`.
  """
  @spec ping(String.t()) :: :ok | {:error, String.t()}
  def ping(url) do
    # Postgrex logs every failed connect attempt; ping turns failures into a
    # single clean message, so silence the logger for the probe's duration.
    previous = Logger.level()
    Logger.configure(level: :none)

    try do
      do_ping(url)
    after
      Logger.configure(level: previous)
    end
  end

  defp do_ping(url) do
    parent = self()

    # A failed Postgrex pool exits and would take a linked caller down with
    # it, so run the probe in an isolated, monitored process that traps that
    # exit and reports a plain error instead.
    {pid, ref} = spawn_monitor(fn -> send(parent, {:ping, self(), run_probe(url)}) end)

    receive do
      {:ping, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, human_error(reason)}
    after
      probe_timeout() + 5_000 ->
        Process.exit(pid, :kill)
        {:error, "connection timed out"}
    end
  end

  defp run_probe(url) do
    Process.flag(:trap_exit, true)

    with {:ok, opts} <- Connections.Opts.parse(url),
         {:ok, pid} <- start_probe(opts) do
      try do
        case Postgrex.query(pid, "SELECT 1", [], timeout: probe_timeout()) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, human_error(reason)}
        end
      after
        stop_probe(pid)
      end
    else
      {:error, reason} -> {:error, human_error(reason)}
    end
  end

  defp probe_timeout, do: min(Config.get("db_timeout_ms") || 15_000, 8_000)

  ## Query execution (real or injected)

  @doc false
  @spec query(String.t(), String.t(), [term]) :: {:ok, result} | {:error, term}
  def query(ref, sql, params) do
    case Application.get_env(:superblock, :db_query_fun) do
      fun when is_function(fun, 3) -> fun.(ref, sql, params)
      _unset -> real_query(ref, sql, params)
    end
  end

  defp real_query(ref, sql, params) do
    with {:ok, pid} <- Connections.get(ref) do
      case Postgrex.query(pid, sql, params, timeout: Config.get("db_timeout_ms") || 15_000) do
        {:ok, %Postgrex.Result{columns: columns, rows: rows}} ->
          {:ok, %{columns: columns || [], rows: rows || []}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_probe(opts) do
    Postgrex.start_link(Keyword.merge(opts, pool_size: 1, backoff_type: :stop, sync_connect: true))
  rescue
    error -> {:error, error}
  end

  defp stop_probe(pid) do
    GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _reason -> :ok
  end

  ## SQL builders (pure)

  @doc false
  def schemas_sql do
    placeholders = @system_schemas |> Enum.map(&"'#{&1}'") |> Enum.join(", ")

    """
    SELECT schema_name FROM information_schema.schemata
    WHERE schema_name NOT IN (#{placeholders})
      AND schema_name NOT LIKE 'pg_temp_%'
      AND schema_name NOT LIKE 'pg_toast_temp_%'
    ORDER BY schema_name
    """
  end

  @doc false
  def tables_sql do
    """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = $1 AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """
  end

  @doc false
  def count_sql(schema, table), do: "SELECT count(*) FROM #{qualify(schema, table)}"

  @doc false
  def rows_sql(schema, table) do
    "SELECT * FROM #{qualify(schema, table)} ORDER BY ctid LIMIT $1 OFFSET $2"
  end

  @doc false
  def qualify(schema, table), do: quote_ident(schema) <> "." <> quote_ident(table)

  @doc "Quote a Postgres identifier, doubling embedded double-quotes."
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name) do
    ~s(") <> String.replace(to_string(name), ~s("), ~s("")) <> ~s(")
  end

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

  # A scalar string for CSV, or nil for SQL NULL.
  defp scalar(nil), do: nil
  defp scalar(value) when is_binary(value), do: printable(value)
  defp scalar(value) when is_boolean(value), do: to_string(value)
  defp scalar(value) when is_number(value), do: to_string(value)
  defp scalar(value) when is_list(value), do: Jason.encode!(json_value(value))

  defp scalar(value) when is_map(value) and not is_struct(value),
    do: Jason.encode!(json_value(value))

  defp scalar(value) when is_struct(value), do: struct_string(value)
  defp scalar(value), do: inspect(value)

  # A JSON-encodable term for a decoded Postgres value.
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

  # Dates, times, Decimal, INET, etc. — all implement String.Chars; fall back
  # to inspect for anything exotic that does not.
  defp struct_string(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end

  # Keep valid UTF-8 as-is; render bytea and other raw binaries as \xHEX.
  defp printable(value) do
    if String.valid?(value), do: value, else: "\\x" <> Base.encode16(value, case: :lower)
  end

  ## Cache + error mapping

  defp cached(key, fun) do
    Cache.fetch(key, Config.ttl_ms("db"), fn -> map_errors(fun.()) end)
  end

  defp map_errors({:ok, _value} = ok), do: ok
  defp map_errors({:error, reason}), do: {:error, db_errno(reason)}

  defp db_errno(%Postgrex.Error{postgres: %{code: code}})
       when code in [:undefined_table, :undefined_schema, :undefined_column],
       do: :enoent

  defp db_errno(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :insufficient_privilege,
              :invalid_password,
              :invalid_authorization_specification
            ],
       do: :eacces

  defp db_errno(%Postgrex.Error{}), do: :eio
  defp db_errno(%DBConnection.ConnectionError{}), do: :eagain
  defp db_errno(:not_configured), do: :enoent
  defp db_errno(:invalid_url), do: :eio
  defp db_errno(_other), do: :eio

  defp human_error(%Postgrex.Error{} = error), do: Exception.message(error)
  defp human_error(%DBConnection.ConnectionError{} = error), do: Exception.message(error)
  defp human_error(:invalid_url), do: "not a valid postgres:// URL"
  defp human_error(:not_configured), do: "no connection URL configured"
  defp human_error(reason) when is_binary(reason), do: reason

  # The pool reports a failed connect as a killed-checkout tuple, which hides
  # the underlying cause (bad password, host, port, sslmode). Postgres logs
  # the specifics; give the user the actionable checklist here.
  defp human_error(_reason),
    do: "could not connect — check the host, port, database, user, password and sslmode in the URL"

  defp to_int(value) when is_integer(value), do: value
  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
