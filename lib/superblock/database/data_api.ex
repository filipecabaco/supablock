defmodule Superblock.Database.DataApi do
  @moduledoc """
  Read-only HTTP transport for a project's **Data API** (PostgREST, served at
  `https://<ref>.supabase.co/rest/v1`).

  This is how the `database/` tree reads rows now: instead of a direct Postgres
  connection (and a database password the user has to hand over), superblock
  reuses a key it can already fetch from the `GET`-only Management API — the
  project's `service_role` (secret) key by default, or the `anon` (publishable)
  key when `db_key` is set to `publishable`. The `service_role` key bypasses RLS
  so every row is visible, matching the old direct-Postgres behaviour; the
  `anon` key is subject to RLS. Nothing here is ever anything but a `GET`.

  The single request seam is swappable for tests via the
  `:superblock, :data_api_fun` application env — a
  `(ref, path, headers) -> {:ok, %{status, headers, body}} | {:error, reason}`
  fun. `headers` is a lowercase-keyed map with single string values; `body` is
  the raw (undecoded) response body.
  """

  require Logger

  alias Superblock.{Client, Config, Database, Endpoints}

  @type response :: %{
          status: non_neg_integer,
          headers: %{optional(String.t()) => String.t()},
          body: binary
        }

  @doc """
  GET `path` (e.g. `/rest/v1/users?select=*`) against `ref`'s Data API, with
  the given extra request `headers`. Returns the raw body undecoded so callers
  can decode row data and the OpenAPI spec differently.
  """
  @spec get(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, response} | {:error, term}
  def get(ref, path, headers \\ []) do
    case Application.get_env(:superblock, :data_api_fun) do
      fun when is_function(fun, 3) -> fun.(ref, path, headers)
      _unset -> real_get(ref, path, headers)
    end
  end

  defp real_get(ref, path, headers) do
    with {:ok, key} <- api_key(ref) do
      budget_ms = Config.get("http_timeout_ms") || 8_000

      req =
        Req.new(
          url: base_url(ref) <> path,
          method: :get,
          headers: [{"apikey", key}, {"authorization", "Bearer " <> key} | headers],
          receive_timeout: budget_ms,
          connect_options: Client.connect_options(budget_ms),
          decode_body: false,
          retry: false
        )

      case Req.request(req) do
        {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
          {:ok, %{status: status, headers: normalize_headers(resp_headers), body: to_body(body)}}

        {:error, %{__exception__: true} = error} ->
          Logger.debug(
            "superblock: data-api #{path} failed: #{Client.redact(Exception.message(error), key)}"
          )

          {:error, transport_reason(error)}
      end
    end
  end

  # The Data API key is fetched from the Management API's api-keys endpoint —
  # the same call `api-keys/secret` renders — so no extra credential is needed.
  # `service_role` needs `reveal=true`; `anon` is returned without it.
  defp api_key(ref) do
    kind = Database.key_kind()

    endpoint =
      case kind do
        :publishable -> Endpoints.path(:api_keys, %{ref: ref})
        :secret -> Endpoints.path(:api_keys, %{ref: ref, reveal: true})
      end

    with {:ok, keys} <- Client.get(endpoint) do
      case Database.select_key(keys, kind) do
        key when is_binary(key) and key != "" -> {:ok, key}
        _none -> {:error, :no_key}
      end
    end
  end

  # Hosted projects answer at `<ref>.supabase.co`. A custom domain or a
  # self-hosted project can point elsewhere with `SUPERBLOCK_DATA_API_URL_<REF>`.
  defp base_url(ref) do
    case System.get_env("SUPERBLOCK_DATA_API_URL_" <> env_key(ref)) do
      url when is_binary(url) and url != "" -> String.trim_trailing(String.trim(url), "/")
      _unset -> "https://#{ref}.supabase.co"
    end
  end

  defp env_key(ref), do: ref |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "_")

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} ->
      {String.downcase(to_string(name)), value |> List.wrap() |> List.first() |> to_string()}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {name, value} ->
      {String.downcase(to_string(name)), to_string(value)}
    end)
  end

  defp to_body(body) when is_binary(body), do: body
  defp to_body(body), do: Jason.encode!(body)

  defp transport_reason(%{reason: :timeout}), do: :timeout
  defp transport_reason(%{reason: reason}), do: {:transport, reason}
  defp transport_reason(error), do: {:transport, error.__struct__}
end
