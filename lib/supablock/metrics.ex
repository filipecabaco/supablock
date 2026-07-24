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

  alias Supablock.{Cache, Client, Config, Database, Endpoints}

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
    with true <- Client.valid_ref?(ref),
         {:ok, key} <- secret_key(ref),
         url = base_url(ref) <> "/customer/v1/privileged/metrics",
         {:ok, resp} <- Client.raw_get(url, auth: {:basic, "service_role:#{key}"}) do
      case resp do
        %Req.Response{status: 200, body: body} -> {:ok, to_string(body)}
        %Req.Response{status: 401} -> {:error, :unauthorized}
        %Req.Response{status: 403} -> {:error, :forbidden}
        %Req.Response{status: status} -> {:error, {:http, status}}
      end
    else
      false -> {:error, :invalid_ref}
      {:error, _reason} = error -> error
    end
  end

  defp secret_key(ref) do
    with {:ok, keys} <- Client.get(Endpoints.path(:api_keys, %{ref: ref, reveal: true})) do
      case Database.select_key(keys, :secret) do
        key when is_binary(key) and key != "" -> {:ok, key}
        _none -> {:error, :no_key}
      end
    end
  end

  defp base_url(ref) do
    case System.get_env("SUPABLOCK_METRICS_URL_" <> Client.env_key(ref)) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _unset -> "https://#{ref}.supabase.co"
    end
  end
end
