defmodule Supablock.Config do
  @moduledoc """
  Configuration stored in `config.json` under the config directory.

  Resolution order everywhere: CLI flag/arg -> config.json -> default.
  """

  alias Supablock.Paths

  @defaults %{
    "mountpoint" => nil,
    "expose_secrets" => false,
    "inline_docs" => false,
    "http_timeout_ms" => 8_000,
    "db_page_size" => 500,
    "db_format" => "csv",
    "db_key" => "secret",
    "log_limit" => 100,
    "ttl" => %{
      "orgs" => 60,
      "project" => 30,
      "health" => 10,
      "static" => 300,
      "db" => 30,
      "logs" => 60
    }
  }

  @valid_keys [
    "mountpoint",
    "expose_secrets",
    "inline_docs",
    "http_timeout_ms",
    "db_page_size",
    "db_format",
    "db_key",
    "oauth.client_id",
    "oauth.client_secret",
    "ttl.orgs",
    "ttl.project",
    "ttl.health",
    "ttl.static",
    "ttl.db",
    "ttl.logs",
    "log_limit"
  ]

  @boolean_keys ~w(expose_secrets inline_docs)

  def defaults, do: @defaults

  def valid_keys, do: @valid_keys

  @doc "Read a top-level key with defaults applied. Boolean keys coerce to a strict boolean."
  def get(key) when is_binary(key) do
    value = get_in_path(String.split(key, "."))
    if key in @boolean_keys, do: value == true, else: value
  end

  @doc "Read a nested value, e.g. `get_in_path([\"ttl\", \"orgs\"])`."
  def get_in_path(path) when is_list(path) do
    case fetch_in(load(), path) do
      {:ok, value} -> value
      :error -> fetch_in(@defaults, path) |> unwrap_default()
    end
  end

  @doc """
  The effective mountpoint: the configured one, or `~/Supabase` — a real
  default so a fresh install can `login` and `mount` with zero config.
  """
  def mountpoint do
    case get("mountpoint") do
      configured when is_binary(configured) and configured != "" -> configured
      _unset -> Path.join(System.user_home!(), "Supabase")
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

  defp coerce("mountpoint", value) do
    if safe_value?(value),
      do: {:ok, value},
      else: {:error, "mountpoint must not contain control characters"}
  end

  defp coerce("oauth." <> _key, value) do
    if safe_value?(value),
      do: {:ok, value},
      else: {:error, "value must not contain control characters"}
  end

  defp coerce("expose_secrets", value) when value in ~w(true false),
    do: {:ok, value == "true"}

  defp coerce("expose_secrets", _),
    do: {:error, "expose_secrets must be true or false"}

  defp coerce("inline_docs", value) when value in ~w(true false),
    do: {:ok, value == "true"}

  defp coerce("inline_docs", _),
    do: {:error, "inline_docs must be true or false"}

  defp coerce("db_format", value) when value in ~w(csv json), do: {:ok, value}

  defp coerce("db_format", _), do: {:error, "db_format must be csv or json"}

  defp coerce("db_key", value) when value in ~w(secret publishable), do: {:ok, value}

  defp coerce("db_key", _), do: {:error, "db_key must be secret or publishable"}

  defp coerce(key, value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp safe_value?(value), do: not String.contains?(value, ["\n", "\r", <<0>>])

  defp load do
    with {:ok, body} <- Supablock.RawFile.read(Paths.config_file()),
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
        File.chmod!(Paths.config_file(), 0o600)
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
