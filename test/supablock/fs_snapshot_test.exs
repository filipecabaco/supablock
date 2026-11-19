defmodule Supablock.FsSnapshotTest do
  @moduledoc """
  The mount's per-file body snapshots (`Supablock.Fs.body/3`), row pages
  served without a known size, and the server-side request handling
  (`Userfs.Server.run_request/4`, `chunk/3`), without a real mount. The FUSE
  suite covers the same paths end to end.
  """
  use Supablock.AuthedCase, async: false

  alias Supablock.{DataApiStub, Fixtures, Fs, TestEnv}

  @path "/organizations/org-alpha/info.json"
  @api "/v1/organizations/org-alpha"
  @page "/organizations/org-alpha/projects/projaone1234567890ab/database/app/widgets/rows-000000.csv"

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
    state = init_state()
    {:ok, first} = Fs.body(state, @path, 0)
    assert first =~ "Alpha Org"

    change_upstream!("Renamed Org")

    # Used again 5s later: still the snapshot, and its idle clock restarts.
    assert {:ok, ^first} = Fs.body(state, @path, 5_000)
    assert {:ok, ^first} = Fs.body(state, @path, 14_000)

    # Left alone for 10s: the next access renders afresh.
    assert {:ok, fresh} = Fs.body(state, @path, 24_000)
    assert fresh =~ "Renamed Org"
  end

  test "a cache flush (supablock refresh) drops every snapshot at once" do
    state = init_state()
    {:ok, first} = Fs.body(state, @path, 0)
    change_upstream!("Flushed Org")
    Supablock.Cache.flush()

    assert {:ok, fresh} = Fs.body(state, @path, 1)
    refute fresh == first
    assert fresh =~ "Flushed Org"
  end

  test "errors are not snapshotted" do
    state = init_state()
    missing = "/organizations/org-alpha/nope.json"

    assert {:error, :enoent} = Fs.body(state, missing, 0)
    assert :ets.tab2list(state.snapshots) == []
  end

  test "getattr reports the snapshot's size, so stat and read agree" do
    state = init_state()
    {:ok, {_mode, _type, size}, state} = Fs.userfs_getattr(state, @path)

    change_upstream!("A much, much longer organization name than before")

    {:ok, body, _state} = Fs.userfs_read(state, @path)
    assert byte_size(body) == size
  end

  test "concurrent first reads of one path all get the same body" do
    state = init_state()

    bodies =
      1..20
      |> Enum.map(fn _i -> Task.async(fn -> Fs.body(state, @path, 0) end) end)
      |> Task.await_many(10_000)
      |> Enum.uniq()

    assert [{:ok, body}] = bodies
    assert [{@path, ^body, _used, _gen, _bytes}] = :ets.tab2list(state.snapshots)
  end

  describe "row pages (size unknown up front)" do
    setup do
      Application.put_env(:supablock, :data_api_fun, DataApiStub.fun(DataApiStub.sample_model()))
      on_exit(fn -> Application.delete_env(:supablock, :data_api_fun) end)
      :ok
    end

    test "stat reports size 0 without fetching the page; open asks for direct I/O" do
      state = init_state()

      assert {:ok, {0o444, _file, 0}, _state} = Fs.userfs_getattr(state, @page)
      assert :ets.tab2list(state.snapshots) == []

      assert {:ok, 1, _state} = Fs.userfs_open(state, @page)
      assert {:ok, 0, _state} = Fs.userfs_open(state, @path)

      assert {:ok, body, _state} = Fs.userfs_read(state, @page)
      assert String.starts_with?(body, "id,name\n0,w0\n")
    end

    test "only row page files are unsized" do
      assert Supablock.Router.unsized?(@page)
      assert Supablock.Router.unsized?(String.replace(@page, ".csv", ".json"))
      refute Supablock.Router.unsized?(String.replace(@page, "rows-000000.csv", "schema.json"))
      refute Supablock.Router.unsized?(@path)
      refute Supablock.Router.unsized?("/rows-000000.csv")
    end
  end

  describe "Userfs.Server request handling" do
    test "a read returns result 0 and only the requested chunk" do
      state = init_state()
      {:ok, body} = Fs.body(state, @path)

      request = <<3::size(64), 5::size(32), @path::binary>>
      reply = Userfs.Server.run_request(Fs, state, 6, request)

      assert <<0::size(32), chunk::binary>> = reply
      assert chunk == binary_part(body, 3, 5)
    end

    test "errors come back as their errno; malformed requests as EIO, not a crash" do
      state = init_state()

      assert <<2::size(32)>> =
               Userfs.Server.run_request(Fs, state, 4, "/organizations/org-alpha/nope.json")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert <<5::size(32)>> = Userfs.Server.run_request(Fs, state, 6, <<1, 2>>)
        end)

      assert log =~ "crashed"
    end

    test "open falls back to no flags for a filesystem without userfs_open" do
      defmodule NoOpenFs do
        def userfs_init(_mp, _opts), do: {:ok, nil}
      end

      assert <<0::size(32), 0::size(32)>> = Userfs.Server.run_request(NoOpenFs, nil, 7, "/x")
    end

    test "chunk/3 returns the requested window, clamped at EOF" do
      assert Userfs.Server.chunk("abcdef", 0, 4) == "abcd"
      assert Userfs.Server.chunk("abcdef", 4, 4) == "ef"
      assert Userfs.Server.chunk("abcdef", 6, 4) == ""
      assert Userfs.Server.chunk("abcdef", 100, 4) == ""
      assert Userfs.Server.chunk("", 0, 4) == ""
    end
  end
end
