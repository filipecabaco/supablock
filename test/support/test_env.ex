defmodule Superblock.TestEnv do
  @moduledoc """
  Test helpers: isolated XDG directories, an API stub installed as the Req
  plug, and per-path hit counters (so tests can assert exact request budgets).
  """

  @hits :superblock_test_hits

  @doc "Point XDG dirs at a fresh tmp dir; returns the base dir."
  def isolate_xdg! do
    base =
      Path.join(
        System.tmp_dir!(),
        "superblock-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    System.put_env("XDG_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("XDG_STATE_HOME", Path.join(base, "state"))
    System.delete_env("SUPERBLOCK_TOKEN")

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("XDG_CONFIG_HOME")
      System.delete_env("XDG_STATE_HOME")
      File.rm_rf!(base)
    end)

    Superblock.Cache.flush()
    base
  end

  @doc """
  Install an API stub. `routes` maps request paths (no query string) to:

    * a JSON-encodable value (responds 200),
    * `{:status, code, json_value}`,
    * `{:params, fun}` — fun takes the query params map, returns
      `{code, json_value}` (also understood by `Superblock.StubServer`),
    * or a `conn -> conn` fun for full control.

  A `{:prefix, "/some/base/"}` key matches any path under it (exact keys
  win). Unknown paths get a 404. Every request bumps a per-path counter.
  """
  def stub_api!(routes \\ Superblock.Fixtures.routes()) do
    reset_hits()

    Application.put_env(:superblock, :req_plug, fn conn ->
      path = conn.request_path
      :ets.update_counter(@hits, path, 1, {path, 0})

      case Map.get(routes, path) || prefix_route(routes, path) do
        nil ->
          json_resp(conn, 404, %{"message" => "not found"})

        {:status, code, value} ->
          json_resp(conn, code, value)

        {:params, fun} when is_function(fun, 1) ->
          conn = Plug.Conn.fetch_query_params(conn)
          {code, value} = fun.(conn.query_params)
          json_resp(conn, code, value)

        fun when is_function(fun, 1) ->
          fun.(conn)

        value ->
          json_resp(conn, 200, value)
      end
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:superblock, :req_plug)
    end)

    :ok
  end

  @doc "Requests seen for `path` (no query string)."
  def hits(path) do
    case :ets.lookup(@hits, path) do
      [{^path, n}] -> n
      [] -> 0
    end
  end

  @doc "Total requests seen by the stub."
  def total_hits do
    @hits |> :ets.tab2list() |> Enum.map(fn {_path, n} -> n end) |> Enum.sum()
  end

  defp prefix_route(routes, path) do
    Enum.find_value(routes, fn
      {{:prefix, prefix}, handler} -> if String.starts_with?(path, prefix), do: handler
      _exact -> nil
    end)
  end

  defp reset_hits do
    if :ets.whereis(@hits) == :undefined do
      :ets.new(@hits, [:named_table, :public, :set])
    else
      :ets.delete_all_objects(@hits)
    end
  end

  defp json_resp(conn, code, value) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(code, Jason.encode!(value))
  end

  @doc "Store a fake credential so Client finds a token."
  def fake_login! do
    :ok = Superblock.Credentials.store("sbp_FAKEZ00000000000000000000000000000000000")
  end
end
