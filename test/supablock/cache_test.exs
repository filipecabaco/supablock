defmodule Supablock.CacheTest do
  use ExUnit.Case, async: false

  alias Supablock.Cache

  setup do
    Cache.flush()
    :ok
  end

  test "stats counts total and stale entries" do
    assert Cache.stats() == %{entries: 0, stale: 0}

    Cache.fetch(:fresh, 60_000, fn -> {:ok, 1} end)
    Cache.fetch(:stale, 0, fn -> {:ok, 2} end)

    stats = Cache.stats()
    assert stats.entries == 2
    # the zero-TTL entry is immediately past its deadline
    assert stats.stale == 1
  end

  test "hit within TTL returns the stored value without re-running the fun" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:ok, :value}
    end

    assert {:ok, :value} = Cache.fetch(:k1, 1_000, fun)
    assert {:ok, :value} = Cache.fetch(:k1, 1_000, fun)
    assert :counters.get(counter, 1) == 1
  end

  test "TTL expiry re-runs the fun" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:ok, :value}
    end

    assert {:ok, :value} = Cache.fetch(:k2, 30, fun)
    Process.sleep(60)
    assert {:ok, :value} = Cache.fetch(:k2, 30, fun)
    assert :counters.get(counter, 1) == 2
  end

  test "negative caching: a 404 result is served from cache" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:error, :not_found}
    end

    assert {:error, :not_found} = Cache.fetch(:k3, 60_000, fun)
    assert {:error, :not_found} = Cache.fetch(:k3, 60_000, fun)
    assert {:error, :not_found} = Cache.fetch(:k3, 60_000, fun)
    assert :counters.get(counter, 1) == 1
  end

  test "other errors are negative-cached too" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:error, :timeout}
    end

    assert {:error, :timeout} = Cache.fetch(:k4, 60_000, fun)
    assert {:error, :timeout} = Cache.fetch(:k4, 60_000, fun)
    assert :counters.get(counter, 1) == 1
  end

  test "single-flight: 50 concurrent fetches of one cold key run the fun once" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(100)
      {:ok, :slow_value}
    end

    results =
      1..50
      |> Enum.map(fn _i -> Task.async(fn -> Cache.fetch(:k5, 1_000, fun) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &(&1 == {:ok, :slow_value}))
    assert :counters.get(counter, 1) == 1
  end

  test "a crashing fetch fun becomes a cached error, not a crash" do
    fun = fn -> raise "boom" end
    assert {:error, {:fetch_crashed, _kind, _reason}} = Cache.fetch(:k6, 1_000, fun)
  end

  test "flush drops everything" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:ok, :v}
    end

    assert {:ok, :v} = Cache.fetch(:k7, 60_000, fun)
    :ok = Cache.flush()
    assert {:ok, :v} = Cache.fetch(:k7, 60_000, fun)
    assert :counters.get(counter, 1) == 2
  end
end
