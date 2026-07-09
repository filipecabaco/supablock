defmodule Superblock.DbCredentials do
  @moduledoc """
  Storage for per-project Postgres connection URLs, used by the `database/`
  tree to read table contents directly from a project's database.

  The Management API cannot return row data — it is `GET`-only and exposes no
  data endpoint — so row viewing connects straight to Postgres with the
  credentials the user supplies here. URLs live in `db.json` (mode 0600)
  inside the config directory, keyed by project ref:

      {"projref...": "postgres://user:pass@host:5432/postgres"}

  The `SUPERBLOCK_DB_URL_<REF>` environment variable overrides a stored URL
  for that ref (CI/testing escape hatch).
  """

  alias Superblock.Paths

  @doc "Store (or replace) the connection URL for a project ref."
  @spec put(String.t(), String.t()) :: :ok | {:error, term}
  def put(ref, url) when is_binary(ref) and is_binary(url) do
    Paths.ensure!()
    creds = Map.put(load(), ref, String.trim(url))
    persist(creds)
  end

  @doc "Remove the stored URL for a project ref. Idempotent."
  @spec delete(String.t()) :: :ok | {:error, term}
  def delete(ref) when is_binary(ref) do
    creds = Map.delete(load(), ref)

    if creds == %{} do
      File.rm(db_file())
      :ok
    else
      persist(creds)
    end
  end

  @doc "The connection URL for `ref`, or `:missing`."
  @spec fetch(String.t()) :: {:ok, String.t()} | :missing
  def fetch(ref) when is_binary(ref) do
    case System.get_env("SUPERBLOCK_DB_URL_" <> env_key(ref)) do
      env when is_binary(env) and env != "" ->
        {:ok, String.trim(env)}

      _absent ->
        case Map.get(load(), ref) do
          url when is_binary(url) and url != "" -> {:ok, url}
          _none -> :missing
        end
    end
  end

  @doc "Whether a URL is configured for `ref` (stored or via env override)."
  @spec configured?(String.t()) :: boolean
  def configured?(ref), do: match?({:ok, _url}, fetch(ref))

  @doc "All configured refs, sorted."
  @spec refs() :: [String.t()]
  def refs, do: load() |> Map.keys() |> Enum.sort()

  @doc """
  A connection URL with its password masked for display
  (`postgres://user:****@host:5432/db`).
  """
  @spec masked(String.t()) :: String.t()
  def masked(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} = uri when is_binary(userinfo) ->
        user = userinfo |> String.split(":", parts: 2) |> hd()
        uri |> Map.put(:userinfo, user <> ":****") |> URI.to_string()

      _no_userinfo ->
        url
    end
  end

  # RawFile (not File): DbCredentials is read on the FUSE-serving path (the
  # Router calls configured?/1 while answering readdir/getattr); see
  # Superblock.RawFile.
  defp load do
    with {:ok, body} <- Superblock.RawFile.read(db_file()),
         {:ok, %{} = creds} <- Jason.decode(body) do
      creds
    else
      _any -> %{}
    end
  end

  defp persist(creds) do
    Paths.ensure!()
    body = Jason.encode!(creds, pretty: true) <> "\n"

    case File.write(db_file(), body) do
      :ok ->
        File.chmod!(db_file(), 0o600)
        :ok

      {:error, reason} ->
        {:error, "could not write #{db_file()}: #{inspect(reason)}"}
    end
  end

  defp db_file, do: Path.join(Paths.config_dir(), "db.json")

  # Env-var suffix: refs are alphanumeric, but normalise defensively.
  defp env_key(ref), do: ref |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "_")
end
