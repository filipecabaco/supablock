defmodule Supablock.Database.DataApi do
  @moduledoc """
  Read-only HTTP transport for a project's **Data API** (PostgREST, served at
  `https://<ref>.supabase.co/rest/v1`).

  This is how the `database/` tree reads rows now: instead of a direct Postgres
  connection (and a database password the user has to hand over), supablock
  reuses a key it can already fetch from the `GET`-only Management API — the
  project's `service_role` (secret) key by default, or the `anon` (publishable)
  key when `db_key` is set to `publishable`. The `service_role` key bypasses RLS
  so every row is visible, matching the old direct-Postgres behaviour; the
  `anon` key is subject to RLS. Nothing here is ever anything but a `GET`.

  The single request seam is swappable for tests via the
  `:supablock, :data_api_fun` application env — a
  `(ref, path, headers) -> {:ok, %{status, headers, body}} | {:error, reason}`
  fun. `headers` is a lowercase-keyed map with single string values; `body` is
  the raw (undecoded) response body.
  """

  alias Supablock.{Client, Database, Endpoints}

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
    case Application.get_env(:supablock, :data_api_fun) do
      fun when is_function(fun, 3) -> fun.(ref, path, headers)
      _unset -> real_get(ref, path, headers)
    end
  end

  defp real_get(ref, path, headers) do
    with true <- Client.valid_ref?(ref),
         {:ok, key} <- api_key(ref),
         request_headers = [{"apikey", key}, {"authorization", "Bearer " <> key} | headers],
         {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} <-
           Client.raw_get(base_url(ref) <> path, headers: request_headers) do
      {:ok, %{status: status, headers: normalize_headers(resp_headers), body: to_body(body)}}
    else
      false -> {:error, :invalid_ref}
      {:error, _reason} = error -> error
    end
  end

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

  defp base_url(ref) do
    case System.get_env("SUPABLOCK_DATA_API_URL_" <> Client.env_key(ref)) do
      url when is_binary(url) and url != "" -> String.trim_trailing(String.trim(url), "/")
      _unset -> "https://#{ref}.supabase.co"
    end
  end

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
end
