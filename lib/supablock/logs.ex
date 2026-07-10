defmodule Supablock.Logs do
  @moduledoc """
  Fetches recent log entries from the Supabase Analytics API
  (`GET /v1/projects/{ref}/analytics/endpoints/logs.all`).

  Each log source maps to a BigQuery/ClickHouse table queryable with SQL.
  Results are cached under the `logs` TTL class (default 60s) to stay
  comfortably inside the API's rate limits.

  `fetch_since/3` bypasses the cache and is intended for the `logs follow`
  streaming command, where each call queries a unique timestamp range.
  """

  alias Supablock.{Cache, Client, Config, Endpoints}

  @sources ~w(auth auth-audit edge functions functions-edge pgbouncer postgres postgrest realtime storage supavisor)

  @tables %{
    "auth" => "auth_logs",
    "auth-audit" => "auth_audit_logs",
    "edge" => "edge_logs",
    "functions" => "function_logs",
    "functions-edge" => "function_edge_logs",
    "pgbouncer" => "pgbouncer",
    "postgres" => "postgres_logs",
    "postgrest" => "postgrest",
    "realtime" => "realtime_logs",
    "storage" => "storage_logs",
    "supavisor" => "supavisor"
  }

  @doc "Ordered list of log source names (filesystem directory entries)."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "True when `source` is a known log source name."
  @spec valid_source?(String.t()) :: boolean
  def valid_source?(source), do: source in @sources

  @doc "Configured row limit (log_limit config key, default 100)."
  @spec limit() :: pos_integer
  def limit do
    case Config.get("log_limit") do
      n when is_integer(n) and n > 0 -> n
      _other -> 100
    end
  end

  @doc """
  Fetch the most-recent `log_limit` rows for `source` under project `ref`.
  Results are cached under the `logs` TTL.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, term} | {:error, term}
  def fetch(ref, source) do
    table = Map.fetch!(@tables, source)

    sql =
      "SELECT timestamp, event_message, metadata FROM #{table} ORDER BY timestamp DESC LIMIT #{limit()}"

    now = DateTime.utc_now()
    iso_end = DateTime.to_iso8601(now)
    iso_start = DateTime.to_iso8601(DateTime.add(now, -86_400, :second))
    path = Endpoints.path(:logs, %{ref: ref, sql: sql, iso_start: iso_start, iso_end: iso_end})
    ttl_ms = Config.ttl_ms("logs")
    # Key on {ref, source} — NOT the URL, whose iso_start/iso_end embed the
    # current time and change every call, which would defeat the cache.
    Cache.fetch({:logs, ref, source}, ttl_ms, fn -> Client.get(path, timeout_ms: 30_000) end)
  end

  @doc """
  Fetch log rows for `source` newer than `since_us` (Unix microseconds).
  Bypasses the cache — each call has a unique timestamp range.
  """
  @spec fetch_since(String.t(), String.t(), integer) :: {:ok, term} | {:error, term}
  def fetch_since(ref, source, since_us) when is_integer(since_us) do
    table = Map.fetch!(@tables, source)

    # `timestamp` is a BigQuery TIMESTAMP, so the microsecond watermark has to
    # be wrapped in TIMESTAMP_MICROS/1 — a bare integer comparison errors out.
    sql =
      "SELECT timestamp, event_message, metadata FROM #{table} WHERE timestamp > TIMESTAMP_MICROS(#{since_us}) ORDER BY timestamp DESC LIMIT #{limit()}"

    iso_start = since_us |> div(1_000_000) |> DateTime.from_unix!() |> DateTime.to_iso8601()
    iso_end = DateTime.to_iso8601(DateTime.utc_now())
    path = Endpoints.path(:logs, %{ref: ref, sql: sql, iso_start: iso_start, iso_end: iso_end})
    Client.get(path, timeout_ms: 30_000)
  end
end
