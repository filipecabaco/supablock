defmodule Supablock.Profile do
  @moduledoc """
  Shared team profile: a flat JSON object of config keys, fetched from a URL
  or a local file and applied to this machine's config. One artifact a team
  commits to its dotfiles/wiki turns onboarding into:

      supablock setup https://team.example.com/supablock.json

  Example profile:

      {
        "oauth.client_id": "11111111-…",
        "oauth.client_secret": "sb_secret_…",
        "mountpoint": "/mnt/supabase",
        "ttl.orgs": 120,
        "expose_secrets": false
      }

  Only keys in `Supablock.Config.valid_keys/0` are applied (same validation
  and coercion as `config set`); anything else is reported and skipped, so a
  malicious or stale profile cannot touch credentials or arbitrary state.
  Personal things — tokens, database passwords — never belong in a profile.
  """

  alias Supablock.{Client, Config}

  @timeout_ms 8_000

  @doc "Load a profile from an http(s) URL or a local file path."
  @spec fetch(String.t()) :: {:ok, map} | {:error, String.t()}
  def fetch(source) do
    with {:ok, body} <- read_source(source),
         {:ok, %{} = profile} <- decode(body) do
      {:ok, profile}
    end
  end

  @doc """
  Apply a profile map to the local config. Returns
  `{:ok, applied_keys, skipped_keys}`; application stops at the first write
  error.
  """
  @spec apply(map) :: {:ok, [String.t()], [String.t()]} | {:error, String.t()}
  def apply(%{} = profile) do
    {valid, skipped} =
      profile
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.split_with(fn {key, _value} -> key in Config.valid_keys() end)

    valid
    |> Enum.reduce_while({:ok, [], skipped_keys(skipped)}, fn {key, value},
                                                              {:ok, applied, skipped} ->
      case Config.set(key, to_string(value)) do
        :ok -> {:cont, {:ok, applied ++ [key], skipped}}
        {:error, message} -> {:halt, {:error, "#{key}: #{message}"}}
      end
    end)
  end

  defp skipped_keys(pairs), do: Enum.map(pairs, fn {key, _value} -> key end)

  defp read_source("http://" <> _rest = url), do: http_get(url)
  defp read_source("https://" <> _rest = url), do: http_get(url)

  defp read_source(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp http_get(url) do
    request =
      Req.new(
        url: url,
        receive_timeout: @timeout_ms,
        connect_options: Client.connect_options(@timeout_ms),
        retry: false,
        redirect: true
      )
      |> then(fn request ->
        case Application.get_env(:supablock, :req_plug) do
          nil -> request
          plug -> Req.merge(request, plug: plug)
        end
      end)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        # Req may already have JSON-decoded it
        {:ok, Jason.encode!(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "profile fetch failed: HTTP #{status}"}

      {:error, %{__exception__: true} = error} ->
        {:error, "profile fetch failed: #{Exception.message(error)}"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = profile} -> {:ok, profile}
      {:ok, _other} -> {:error, "profile must be a JSON object of config keys"}
      {:error, _reason} -> {:error, "profile is not valid JSON"}
    end
  end
end
