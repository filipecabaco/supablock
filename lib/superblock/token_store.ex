defmodule Superblock.TokenStore do
  @moduledoc """
  Serializes access to the stored credential so OAuth refresh is
  **single-flight and single-use-safe**: Supabase refresh tokens die on use
  (each refresh returns a new pair), so exactly one process may ever refresh,
  and the new pair must hit disk (atomic tmp+rename in `Credentials`) before
  anything else happens.

  All reads go through this GenServer:

    * a PAT (or `SUPERBLOCK_TOKEN`) passes straight through;
    * an OAuth credential expiring within #{60}s is refreshed first — one
      refresh no matter how many concurrent readers;
    * `after_401/1` refreshes once when the API rejects a token, unless a
      concurrent caller already rotated it (then the fresh token is returned
      without another refresh).

  A failed refresh on a not-yet-expired token returns the old token (it may
  still work); on an expired one it surfaces `:missing` → `EACCES` plus the
  "run: superblock login" hint downstream.
  """

  use GenServer

  alias Superblock.{Credentials, OAuth}
  alias Superblock.Credentials.Credential

  @refresh_margin_s 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The access token to use right now, refreshed if it was about to expire."
  @spec access_token() :: {:ok, String.t()} | :missing
  def access_token, do: GenServer.call(__MODULE__, :access_token, 20_000)

  @doc "The API said 401 for `failed_token`: rotate once, or reuse a concurrent rotation."
  @spec after_401(String.t()) :: {:ok, String.t()} | {:error, term}
  def after_401(failed_token), do: GenServer.call(__MODULE__, {:after_401, failed_token}, 20_000)

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call(:access_token, _from, state) do
    reply =
      case Credentials.load_credential() do
        :missing ->
          :missing

        {:ok, %Credential{type: :pat, access_token: token}} ->
          {:ok, token}

        {:ok, %Credential{type: :oauth} = credential} ->
          if expiring?(credential) do
            case rotate(credential) do
              {:ok, token} ->
                {:ok, token}

              # refresh failed but the old token may still be valid
              {:error, _reason} when not is_nil(credential.expires_at) ->
                if expired?(credential), do: :missing, else: {:ok, credential.access_token}

              {:error, _reason} ->
                {:ok, credential.access_token}
            end
          else
            {:ok, credential.access_token}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:after_401, failed_token}, _from, state) do
    reply =
      case Credentials.load_credential() do
        {:ok, %Credential{type: :oauth, access_token: ^failed_token} = credential} ->
          rotate(credential)

        {:ok, %Credential{type: :oauth, access_token: current}} ->
          # someone already rotated while this caller was getting its 401
          {:ok, current}

        {:ok, %Credential{type: :pat}} ->
          {:error, :unauthorized}

        :missing ->
          {:error, :unauthorized}
      end

    {:reply, reply, state}
  end

  defp rotate(%Credential{refresh_token: refresh}) when is_binary(refresh) do
    case OAuth.refresh(refresh) do
      {:ok, tokens} ->
        # persist the new pair BEFORE returning: the old refresh token is
        # already dead, so losing these tokens means a forced re-login
        case Credentials.store_oauth(
               tokens.access_token,
               tokens.refresh_token,
               tokens.expires_at
             ) do
          :ok -> {:ok, tokens.access_token}
          {:error, reason} -> {:error, {:store_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rotate(%Credential{}), do: {:error, :no_refresh_token}

  defp expiring?(%Credential{expires_at: expires_at}) when is_integer(expires_at) do
    System.os_time(:second) >= expires_at - @refresh_margin_s
  end

  defp expiring?(%Credential{}), do: false

  defp expired?(%Credential{expires_at: expires_at}) when is_integer(expires_at) do
    System.os_time(:second) >= expires_at
  end

  defp expired?(%Credential{}), do: false
end
