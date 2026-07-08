defmodule Superblock.Credentials do
  @moduledoc """
  Storage for the Supabase personal access token.

  The token lives in a single-line file with mode 0600 inside the config
  directory. The `SUPERBLOCK_TOKEN` environment variable overrides the stored
  credential (CI escape hatch); everything else goes through the file.
  """

  alias Superblock.Paths

  @spec store(String.t()) :: :ok | {:error, term}
  def store(token) when is_binary(token) do
    Paths.ensure!()
    path = Paths.credentials_file()

    with :ok <- File.write(path, token <> "\n") do
      File.chmod!(path, 0o600)
      :ok
    end
  end

  @spec load() :: {:ok, String.t()} | :missing
  def load do
    case System.get_env("SUPERBLOCK_TOKEN") do
      env when is_binary(env) and env != "" ->
        {:ok, String.trim(env)}

      _absent ->
        # RawFile (not File) — loaded on the FUSE-serving path; see
        # Superblock.RawFile.
        case Superblock.RawFile.read(Paths.credentials_file()) do
          {:ok, body} ->
            case String.trim(body) do
              "" -> :missing
              token -> {:ok, token}
            end

          {:error, _reason} ->
            :missing
        end
    end
  end

  @spec delete() :: :ok
  def delete do
    File.rm(Paths.credentials_file())
    :ok
  end

  @doc """
  The stored token masked for display: prefix plus the last 4 characters,
  never anything more.
  """
  @spec masked() :: String.t() | nil
  def masked do
    case load() do
      {:ok, token} -> mask(token)
      :missing -> nil
    end
  end

  @spec mask(String.t()) :: String.t()
  def mask(token) when is_binary(token) do
    last4 = String.slice(token, -4, 4) || ""
    "sbp_…" <> last4
  end
end
