defmodule Supablock.FsSnapshotTest do
  @moduledoc """
  The mount's per-file body snapshots (`Supablock.Fs.body/3`) and the
  server-side read slicing (`Userfs.Server.chunk/3`), without a real mount.
  The FUSE suite covers the same path end to end.
  """
  use Supablock.AuthedCase, async: false

  alias Supablock.{Fixtures, Fs, TestEnv}

  @path "/organizations/org-alpha/info.json"
  @api "/v1/organizations/org-alpha"

  defp init_state do
    {:ok, state} = Fs.userfs_init("/unused", nil)
    state
  end

  # Swap the API answer and drop the cached response *without* a flush, the
  # way a TTL expiry would: only the snapshot can still be serving old bytes.
  defp change_upstream!(name) do
    TestEnv.stub_api!(Map.put(Fixtures.routes(), @api, Map.put(Fixtures.org_alpha(), "name", name)))
    :ets.delete_all_objects(:supablock_cache)
  end

  test "a live snapshot keeps serving the same bytes after the cache changes" do
    {{:ok, first}, state} = Fs.body(init_state(), @path, 0)
    assert first =~ "Alpha Org"

    change_upstream!("Renamed Org")

    # Used again 5s later: still the snapshot, and its idle clock restarts.
    assert {{:ok, ^first}, state} = Fs.body(state, @path, 5_000)
    assert {{:ok, ^first}, state} = Fs.body(state, @path, 14_000)

    # Left alone for 10s: the next access renders afresh.
    assert {{:ok, fresh}, _state} = Fs.body(state, @path, 24_000)
    assert fresh =~ "Renamed Org"
  end

  test "a cache flush (supablock refresh) drops every snapshot at once" do
    {{:ok, first}, state} = Fs.body(init_state(), @path, 0)
    change_upstream!("Flushed Org")
    Supablock.Cache.flush()

    assert {{:ok, fresh}, _state} = Fs.body(state, @path, 1)
    refute fresh == first
    assert fresh =~ "Flushed Org"
  end

  test "errors are not snapshotted" do
    state = init_state()
    missing = "/organizations/org-alpha/nope.json"

    assert {{:error, :enoent}, state} = Fs.body(state, missing, 0)
    assert state.snapshots == %{}
  end

  test "getattr reports the snapshot's size, so stat and read agree" do
    state = init_state()
    {:ok, {_mode, _type, size}, state} = Fs.userfs_getattr(state, @path)

    change_upstream!("A much, much longer organization name than before")

    {:ok, body, _state} = Fs.userfs_read(state, @path)
    assert byte_size(body) == size
  end

  describe "Userfs.Server.chunk/3" do
    test "returns the requested window, clamped at EOF" do
      assert Userfs.Server.chunk("abcdef", 0, 4) == "abcd"
      assert Userfs.Server.chunk("abcdef", 4, 4) == "ef"
      assert Userfs.Server.chunk("abcdef", 6, 4) == ""
      assert Userfs.Server.chunk("abcdef", 100, 4) == ""
      assert Userfs.Server.chunk("", 0, 4) == ""
    end
  end
end
