defmodule Supablock.Cache do
  @moduledoc """
  ETS-backed cache with TTLs, negative caching and single-flight fetches.

  Entries are `{key, value, fetched_at_ms, ttl_ms}` where `value` is
  `{:ok, term}` or `{:error, reason}`. Errors are cached too (negative
  caching): `:not_found` for 10s, anything else for 5s, so a storm of FUSE
  callbacks on a broken path cannot hammer the API.

  `fetch/3` is single-flight: concurrent misses on the same key result in
  exactly one run of the fetch fun; every other caller waits for that result.

  Two bounds keep a long-running mount healthy:

    * every fetch has a deadline (60s): a server that trickles its body
      forever is killed and its waiters get `{:error, :timeout}` instead of
      hanging the FUSE callback behind them;
    * expired entries are swept every 60s, so walking every table page
      does not grow memory for the daemon's lifetime.
  """

  use GenServer

  @table :supablock_cache
  @ratelimit_table :supablock_ratelimit

  @not_found_ttl_ms 10_000
  @error_ttl_ms 5_000
  @fetch_deadline_ms 60_000
  @sweep_every_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the cached value for `key` if fresh, otherwise run `fun` (once,
  regardless of how many callers race here) and cache its result.
  """
  @spec fetch(term, non_neg_integer, (-> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    case lookup(key) do
      {:hit, value} -> value
      :miss -> GenServer.call(__MODULE__, {:fetch, key, ttl_ms, fun}, :infinity)
    end
  end

  @doc "Peek without fetching."
  @spec lookup(term) :: {:hit, {:ok, term} | {:error, term}} | :miss
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, fetched_at, ttl_ms}] ->
        if now_ms() - fetched_at < ttl_ms do
          {:hit, value}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Drop every cache entry (used by `supablock refresh`). Also bumps
  `generation/0`, so derived copies held elsewhere (the mount's per-file body
  snapshots) know to drop theirs too.
  """
  def flush do
    :ets.delete_all_objects(@table)
    :persistent_term.put({__MODULE__, :generation}, generation() + 1)
    :ok
  end

  @doc "Incremented by every `flush/0`; cheap to read on every FUSE call."
  @spec generation() :: non_neg_integer
  def generation, do: :persistent_term.get({__MODULE__, :generation}, 0)

  @doc """
  Cache occupancy, used by `supablock refresh --check`: total entries and how
  many are past their TTL (a refresh would drop all of them and re-fetch the
  stale ones on next access).
  """
  @spec stats() :: %{entries: non_neg_integer, stale: non_neg_integer}
  def stats do
    now = now_ms()

    {entries, stale} =
      :ets.foldl(
        fn {_key, _value, fetched_at, ttl_ms}, {total, expired} ->
          expired = if now - fetched_at >= ttl_ms, do: expired + 1, else: expired
          {total + 1, expired}
        end,
        {0, 0},
        @table
      )

    %{entries: entries, stale: stale}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@ratelimit_table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{inflight: %{}}}
  end

  @doc "Delete every entry past its TTL; returns how many were dropped."
  @spec sweep() :: non_neg_integer
  def sweep do
    now = now_ms()
    # {key, value, fetched_at, ttl}: expired when fetched_at + ttl =< now.
    spec = [{{:_, :_, :"$1", :"$2"}, [{:"=<", {:+, :"$1", :"$2"}, now}], [true]}]
    :ets.select_delete(@table, spec)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  @impl true
  def handle_call({:fetch, key, ttl_ms, fun}, from, state) do
    case lookup(key) do
      {:hit, value} ->
        {:reply, value, state}

      :miss ->
        case Map.fetch(state.inflight, key) do
          {:ok, {ref, ttl_ms0, waiters}} ->
            inflight = Map.put(state.inflight, key, {ref, ttl_ms0, [from | waiters]})
            {:noreply, %{state | inflight: inflight}}

          :error ->
            server = self()

            {pid, ref} =
              spawn_monitor(fn ->
                result =
                  try do
                    fun.()
                  catch
                    kind, reason -> {:error, {:fetch_crashed, kind, reason}}
                  end

                send(server, {:fetch_result, key, result})
              end)

            deadline = Application.get_env(:supablock, :cache_fetch_deadline_ms, @fetch_deadline_ms)
            Process.send_after(self(), {:fetch_deadline, key, ref, pid}, deadline)
            inflight = Map.put(state.inflight, key, {ref, ttl_ms, [from]})
            {:noreply, %{state | inflight: inflight}}
        end
    end
  end

  @impl true
  def handle_info({:fetch_result, key, result}, state) do
    case Map.pop(state.inflight, key) do
      {nil, _inflight} ->
        {:noreply, state}

      {{ref, ttl_ms, waiters}, inflight} ->
        Process.demonitor(ref, [:flush])
        store(key, result, ttl_ms)
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info({:fetch_deadline, key, ref, pid}, state) do
    case Map.fetch(state.inflight, key) do
      {:ok, {^ref, _ttl, waiters}} ->
        # Demonitor first so the kill below is not also reported as a crash.
        Process.demonitor(ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:error, :timeout}))
        Process.exit(pid, :kill)
        store(key, {:error, :timeout}, @error_ttl_ms)
        {:noreply, %{state | inflight: Map.delete(state.inflight, key)}}

      _done_or_replaced ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.inflight, fn {_k, {r, _ttl, _w}} -> r == ref end) do
      nil ->
        {:noreply, state}

      {key, {_ref, _ttl, waiters}} ->
        result = {:error, {:fetch_crashed, reason}}
        store(key, result, @error_ttl_ms)
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:noreply, %{state | inflight: Map.delete(state.inflight, key)}}
    end
  end

  defp store(key, result, ttl_ms) do
    ttl_ms =
      case result do
        {:ok, _value} -> ttl_ms
        {:error, :not_found} -> @not_found_ttl_ms
        {:error, _reason} -> @error_ttl_ms
      end

    :ets.insert(@table, {key, result, now_ms(), ttl_ms})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
