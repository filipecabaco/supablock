defmodule Supablock.TokenStore do
  @moduledoc """
  Serializes access to the stored credential so OAuth refresh is
  **single-flight and single-use-safe**: Supabase refresh tokens die on use
  (each refresh returns a new pair), so exactly one process may ever refresh,
  and the new pair must hit disk (atomic tmp+rename in `Credentials`) before
  anything else happens.

  All reads go through this GenServer:

    * a PAT (or `SUPABLOCK_TOKEN`) passes straight through;
    * an OAuth credential expiring within #{60}s is refreshed first — one
      refresh no matter how many concurrent readers;
    * `after_401/1` refreshes once when the API rejects a token, unless a
      concurrent caller already rotated it (then the fresh token is returned
      without another refresh).

  Across processes (the daemon, `serve` and each CLI command are separate
  VMs over one credentials file) a lock file next to the credentials makes
  refresh single-flight too, and whoever gets the lock second picks up the
  pair the first one wrote instead of spending a dead refresh token.

  A failed refresh on a not-yet-expired token returns the old token (it may
  still work); on an expired one it surfaces `:missing` → `EACCES` plus the
  "run: supablock login" hint downstream.
  """

  use GenServer

  alias Supablock.{Credentials, OAuth}
  alias Supablock.Credentials.Credential

  @refresh_margin_s 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The access token to use right now, refreshed if it was about to expire."
  @spec access_token() :: {:ok, String.t()} | :missing
  def access_token, do: GenServer.call(__MODULE__, :access_token, 20_000)

  @doc "The API said 401 for `failed_token`: rotate once, or reuse a concurrent rotation."
  @spec after_401(String.t()) :: {:ok, String.t()} | {:error, term}
  def after_401(failed_token), do: GenServer.call(__MODULE__, {:after_401, failed_token}, 20_000)

  @impl true
  # `unsaved` holds a rotated OAuth pair that could not be written to disk
  # (read-only HOME, full disk). The refresh already burned the old refresh
  # token, so dropping the new pair would log the user out for good; keep it
  # in memory, prefer it over the stale file, and retry the write on each use.
  def init(nil), do: {:ok, %{unsaved: nil}}

  @impl true
  def handle_call(:access_token, _from, state) do
    {credential, state} = current_credential(state)

    {reply, state} =
      case credential do
        :missing ->
          {:missing, state}

        {:ok, %Credential{type: :pat, access_token: token}} ->
          {{:ok, token}, state}

        {:ok, %Credential{type: :oauth} = credential} ->
          if expiring?(credential) do
            case rotate(credential, state) do
              {{:ok, token}, state} ->
                {{:ok, token}, state}

              {{:error, _reason}, state} when not is_nil(credential.expires_at) ->
                if expired?(credential),
                  do: {:missing, state},
                  else: {{:ok, credential.access_token}, state}

              {{:error, _reason}, state} ->
                {{:ok, credential.access_token}, state}
            end
          else
            {{:ok, credential.access_token}, state}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:after_401, failed_token}, _from, state) do
    {credential, state} = current_credential(state)

    {reply, state} =
      case credential do
        {:ok, %Credential{type: :oauth, access_token: ^failed_token} = credential} ->
          rotate(credential, state)

        {:ok, %Credential{type: :oauth, access_token: current}} ->
          {{:ok, current}, state}

        {:ok, %Credential{type: :pat}} ->
          {{:error, :unauthorized}, state}

        :missing ->
          {{:error, :unauthorized}, state}
      end

    {:reply, reply, state}
  end

  defp current_credential(%{unsaved: nil} = state), do: {Credentials.load_credential(), state}

  defp current_credential(%{unsaved: %Credential{} = unsaved} = state) do
    case persist(unsaved) do
      :ok -> {{:ok, unsaved}, %{state | unsaved: nil}}
      {:error, _reason} -> {{:ok, unsaved}, state}
    end
  end

  # This GenServer makes refresh single-flight within one VM, but the daemon,
  # `supablock serve` and every CLI command are separate VMs sharing one
  # credentials file. Two of them refreshing with the same single-use token
  # means the loser's request kills the grant. So rotation takes a lock file
  # and, holding it, re-reads the file: if someone else already rotated, use
  # their pair instead of spending a token that is now dead.
  defp rotate(%Credential{refresh_token: refresh} = credential, state) when is_binary(refresh) do
    with_refresh_lock(fn ->
      case rotated_elsewhere(credential, state) do
        {:ok, %Credential{access_token: token}} -> {{:ok, token}, state}
        :no -> do_rotate(credential, state)
      end
    end)
  end

  defp rotate(%Credential{}, state), do: {{:error, :no_refresh_token}, state}

  # Only when the file is authoritative: with an unsaved pair in memory the
  # file holds the *older*, already-spent pair.
  defp rotated_elsewhere(%Credential{refresh_token: ours}, %{unsaved: nil}) do
    case Credentials.load_credential() do
      {:ok, %Credential{type: :oauth, refresh_token: theirs} = fresh}
      when is_binary(theirs) and theirs != ours ->
        {:ok, fresh}

      _same_or_gone ->
        :no
    end
  end

  defp rotated_elsewhere(_credential, _state), do: :no

  @lock_wait_ms 8_000
  @lock_stale_ms 30_000
  @lock_poll_ms 50

  @doc false
  # Run `fun` holding the cross-process refresh lock. A lock older than
  # @lock_stale_ms belongs to a process that died mid-refresh and is taken
  # over. If the lock cannot be created at all (read-only config dir) the
  # refresh still runs: being logged out is worse than the race.
  def with_refresh_lock(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @lock_wait_ms
    lock = Supablock.Paths.refresh_lock_file()

    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)

        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, :eexist} ->
        cond do
          stale_lock?(lock) ->
            File.rm(lock)
            with_refresh_lock(fun, deadline)

          System.monotonic_time(:millisecond) < deadline ->
            Process.sleep(@lock_poll_ms)
            with_refresh_lock(fun, deadline)

          true ->
            fun.()
        end

      {:error, _unwritable} ->
        fun.()
    end
  end

  defp stale_lock?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        (System.os_time(:second) - mtime) * 1_000 > @lock_stale_ms

      {:error, _gone} ->
        false
    end
  end

  defp do_rotate(%Credential{refresh_token: refresh}, state) do
    case OAuth.refresh(refresh) do
      {:ok, tokens} ->
        rotated = %Credential{
          type: :oauth,
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_at: tokens.expires_at
        }

        case persist(rotated) do
          :ok ->
            {{:ok, rotated.access_token}, %{state | unsaved: nil}}

          {:error, reason} ->
            require Logger

            Logger.warning(
              "supablock: refreshed OAuth token could not be saved (#{inspect(reason)}); " <>
                "keeping it in memory — this process stays logged in, but a restart will need `supablock login`"
            )

            {{:ok, rotated.access_token}, %{state | unsaved: rotated}}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # `Paths.ensure!/0` raises on an unwritable state dir; that is a failed
  # write like any other, not a reason to crash with the only live token.
  defp persist(%Credential{} = c) do
    Credentials.store_oauth(c.access_token, c.refresh_token, c.expires_at)
  rescue
    error -> {:error, error}
  end

  defp expiring?(%Credential{expires_at: expires_at}) when is_integer(expires_at) do
    System.os_time(:second) >= expires_at - @refresh_margin_s
  end

  defp expiring?(%Credential{}), do: false

  defp expired?(%Credential{expires_at: expires_at}) when is_integer(expires_at) do
    System.os_time(:second) >= expires_at
  end

  defp expired?(%Credential{}), do: false
end
