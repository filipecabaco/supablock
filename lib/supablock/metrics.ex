defmodule Supablock.Metrics do
  @moduledoc """
  Fetches Prometheus-format metrics from a project's privileged endpoint:
  `https://<ref>.supabase.co/customer/v1/privileged/metrics`

  Authentication is Basic Auth: username `service_role`, password is the
  project's secret API key (`sb_secret_…`), fetched from the Management API
  and already cached via the `api-keys` endpoint.

  Results are cached under the `logs` TTL class (default 60s) — consistent
  with the API's "scrape once per minute" recommendation.

  The request seam is swappable for tests via the `:supablock, :req_plug`
  application env (same as every other HTTP call in this codebase).
  """

  require Logger

  alias Supablock.{Cache, Client, Config, Endpoints}

  @doc """
  Fetch the current Prometheus metrics for `ref`. Returns `{:ok, binary}` with
  the raw text or `{:error, reason}`.
  """
  @spec fetch(String.t()) :: {:ok, binary} | {:error, term}
  def fetch(ref) do
    ttl_ms = Config.ttl_ms("logs")
    Cache.fetch({:metrics, ref}, ttl_ms, fn -> real_fetch(ref) end)
  end

  defp real_fetch(ref) do
    with {:ok, key} <- secret_key(ref) do
      budget_ms = Config.get("http_timeout_ms") || 8_000
      url = base_url(ref) <> "/customer/v1/privileged/metrics"

      req =
        Req.new(
          url: url,
          auth: {:basic, "service_role:#{key}"},
          receive_timeout: budget_ms,
          connect_options: Client.connect_options(budget_ms),
          decode_body: false,
          retry: false
        )
        |> apply_test_plug()

      case Req.request(req) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, to_string(body)}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: 403}} ->
          {:error, :forbidden}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http, status}}

        {:error, %{__exception__: true} = error} ->
          Logger.debug("supablock: metrics #{ref} failed: #{Exception.message(error)}")
          {:error, {:transport, error.__struct__}}
      end
    end
  end

  defp secret_key(ref) do
    with {:ok, keys} <- Client.get(Endpoints.path(:api_keys, %{ref: ref, reveal: true})) do
      case find_secret(keys) do
        key when is_binary(key) and key != "" -> {:ok, key}
        _none -> {:error, :no_key}
      end
    end
  end

  defp find_secret(keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      name = to_string(key["name"] || "")
      if name in ["service_role", "secret"], do: to_string(key["api_key"] || "")
    end)
  end

  defp find_secret(_), do: nil

  defp apply_test_plug(req) do
    case Application.get_env(:supablock, :req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug, retry: false)
    end
  end

  defp base_url(ref) do
    case System.get_env("SUPABLOCK_METRICS_URL_" <> env_key(ref)) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _unset -> "https://#{ref}.supabase.co"
    end
  end

  defp env_key(ref), do: ref |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "_")
end
