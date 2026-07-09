defmodule Superblock.Credentials do
  @moduledoc """
  Storage for the Supabase credential, mode 0600 inside the config directory.

  Two formats live in the same file:

    * **v2 (OAuth)** — a JSON object
      `{"type":"oauth","access_token":…,"refresh_token":…,"expires_at":…}`
      written atomically (tmp + rename) because OAuth refresh tokens are
      single-use: a crash mid-rotation must never strand the user logged out.
    * **legacy (PAT)** — a single `sbp_…` line, kept working forever.

  The `SUPERBLOCK_TOKEN` environment variable overrides the stored credential
  (CI escape hatch); everything else goes through the file. All reads and the
  OAuth write run with raw file operations — this module is on the
  FUSE-serving path (see `Superblock.RawFile`).
  """

  alias Superblock.{Paths, RawFile}

  defmodule Credential do
    @moduledoc "A loaded credential: a long-lived PAT or a refreshable OAuth pair."
    defstruct [:type, :access_token, :refresh_token, :expires_at]

    @type t :: %__MODULE__{
            type: :pat | :oauth,
            access_token: String.t(),
            refresh_token: String.t() | nil,
            expires_at: non_neg_integer | nil
          }
  end

  @spec store(String.t()) :: :ok | {:error, term}
  def store(token) when is_binary(token) do
    Paths.ensure!()
    RawFile.write_atomic(Paths.credentials_file(), token <> "\n", 0o600)
  end

  @spec store_oauth(String.t(), String.t(), non_neg_integer) :: :ok | {:error, term}
  def store_oauth(access_token, refresh_token, expires_at)
      when is_binary(access_token) and is_binary(refresh_token) and is_integer(expires_at) do
    Paths.ensure!()

    body =
      Jason.encode!(%{
        "type" => "oauth",
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "expires_at" => expires_at
      })

    RawFile.write_atomic(Paths.credentials_file(), body <> "\n", 0o600)
  end

  @doc "The access token to send, whatever the credential type."
  @spec load() :: {:ok, String.t()} | :missing
  def load do
    case load_credential() do
      {:ok, %Credential{access_token: token}} -> {:ok, token}
      :missing -> :missing
    end
  end

  @spec load_credential() :: {:ok, Credential.t()} | :missing
  def load_credential do
    case System.get_env("SUPERBLOCK_TOKEN") do
      env when is_binary(env) and env != "" ->
        {:ok, %Credential{type: :pat, access_token: String.trim(env)}}

      _absent ->
        case RawFile.read(Paths.credentials_file()) do
          {:ok, body} -> parse(String.trim(body))
          {:error, _reason} -> :missing
        end
    end
  end

  defp parse(""), do: :missing

  defp parse(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "oauth", "access_token" => access} = map} when is_binary(access) ->
        {:ok,
         %Credential{
           type: :oauth,
           access_token: access,
           refresh_token: map["refresh_token"],
           expires_at: map["expires_at"]
         }}

      _not_json ->
        # legacy single-line PAT
        {:ok, %Credential{type: :pat, access_token: body}}
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
