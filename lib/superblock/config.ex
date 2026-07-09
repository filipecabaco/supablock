defmodule Superblock.Config do
  @moduledoc """
  Configuration stored in `config.json` under the config directory.

  Resolution order everywhere: CLI flag/arg -> config.json -> default.
  """

  alias Superblock.Paths

  @defaults %{
    "mountpoint" => nil,
    "expose_secrets" => false,
    "http_timeout_ms" => 8_000,
    "ttl" => %{
      "orgs" => 60,
      "project" => 30,
      "health" => 10,
      "static" => 300
    }
  }

  @valid_keys [
    "mountpoint",
    "expose_secrets",
    "http_timeout_ms",
    "oauth.client_id",
    "oauth.client_secret",
    "ttl.orgs",
    "ttl.project",
    "ttl.health",
    "ttl.static"
  ]

  def defaults, do: @defaults

  def valid_keys, do: @valid_keys

  @doc "Read a top-level key with defaults applied."
  def get(key) when is_binary(key) do
    get_in_path(String.split(key, "."))
  end

  @doc "Read a nested value, e.g. `get_in_path([\"ttl\", \"orgs\"])`."
  def get_in_path(path) when is_list(path) do
    case fetch_in(load(), path) do
      {:ok, value} -> value
      :error -> fetch_in(@defaults, path) |> unwrap_default()
    end
  end

  @doc "TTL for a class (\"orgs\" | \"project\" | \"health\" | \"static\"), in ms."
  def ttl_ms(class) when is_binary(class) do
    seconds = get_in_path(["ttl", class]) || 30
    seconds * 1_000
  end

  @doc """
  Set a (dotted) key, validating and coercing the value, and persist the file.
  Returns `:ok` or `{:error, message}`.
  """
  def set(key, raw_value) when is_binary(key) and is_binary(raw_value) do
    with :ok <- validate_key(key),
         {:ok, value} <- coerce(key, raw_value) do
      config = put_in_path(load(), String.split(key, "."), value)
      persist(config)
    end
  end

  @doc "Current effective config (defaults deep-merged with the stored file)."
  def list do
    deep_merge(@defaults, load())
  end

  defp validate_key(key) do
    if key in @valid_keys do
      :ok
    else
      {:error, "Unknown key: #{key}. Valid keys: #{Enum.join(@valid_keys, ", ")}"}
    end
  end

  defp coerce("mountpoint", value), do: {:ok, value}
  defp coerce("oauth." <> _key, value), do: {:ok, value}

  defp coerce("expose_secrets", value) when value in ~w(true false),
    do: {:ok, value == "true"}

  defp coerce("expose_secrets", _),
    do: {:error, "expose_secrets must be true or false"}

  defp coerce(key, value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  # RawFile (not File) — Config.load runs on the FUSE-serving path, which
  # must never wait on the file server; see Superblock.RawFile.
  defp load do
    with {:ok, body} <- Superblock.RawFile.read(Paths.config_file()),
         {:ok, %{} = config} <- Jason.decode(body) do
      config
    else
      _any -> %{}
    end
  end

  defp persist(config) do
    Paths.ensure!()
    body = Jason.encode!(config, pretty: true) <> "\n"

    case File.write(Paths.config_file(), body) do
      :ok ->
        File.chmod!(Paths.config_file(), 0o644)
        :ok

      {:error, reason} ->
        {:error, "could not write #{Paths.config_file()}: #{inspect(reason)}"}
    end
  end

  defp fetch_in(map, []) when not is_map(map), do: {:ok, map}
  defp fetch_in(value, []), do: {:ok, value}

  defp fetch_in(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_in(value, rest)
      :error -> :error
    end
  end

  defp fetch_in(_other, _path), do: :error

  defp unwrap_default({:ok, value}), do: value
  defp unwrap_default(:error), do: nil

  defp put_in_path(_map, [], value), do: value

  defp put_in_path(map, [key | rest], value) when is_map(map) do
    Map.put(map, key, put_in_path(Map.get(map, key, %{}), rest, value))
  end

  defp put_in_path(_other, path, value), do: put_in_path(%{}, path, value)

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
