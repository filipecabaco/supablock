defmodule Supablock.DatabaseTest do
  use ExUnit.Case, async: false

  alias Supablock.{Cache, Config, DataApiStub, Database, TestEnv}

  @ref "projaone1234567890ab"

  setup do
    TestEnv.isolate_xdg!()
    TestEnv.fake_login!()
    # The exposed-schema list comes from the Management API PostgREST config.
    TestEnv.stub_api!()
    Cache.flush()

    on_exit(fn -> Application.delete_env(:supablock, :data_api_fun) end)
    :ok
  end

  # app.widgets: 1200 rows (id, name); app.empty: 0 rows; public: no tables.
  defp model do
    %{
      "app" => %{
        "widgets" => %{
          columns: ["id", "name"],
          pk: ["id"],
          rows: for(i <- 0..1199, do: %{"id" => i, "name" => "w#{i}"})
        },
        "empty" => %{columns: ["id"], pk: ["id"], rows: []}
      },
      "public" => %{}
    }
  end

  defp stub_data_api(model \\ model()) do
    Application.put_env(:supablock, :data_api_fun, DataApiStub.fun(model))
  end

  describe "key selection" do
    test "defaults to the secret (service_role) key" do
      assert Database.key_kind() == :secret

      keys = [
        %{"name" => "anon", "api_key" => "sb_publishable_X"},
        %{"name" => "service_role", "api_key" => "sb_secret_Y"}
      ]

      assert Database.select_key(keys, :secret) == "sb_secret_Y"
      assert Database.select_key(keys, :publishable) == "sb_publishable_X"
    end

    test "db_key=publishable switches to the anon key" do
      Config.set("db_key", "publishable")
      assert Database.key_kind() == :publishable
    end

    test "classifies by name or type" do
      assert Database.classify_key(%{"type" => "secret"}) == :secret
      assert Database.classify_key(%{"name" => "service_role"}) == :secret
      assert Database.classify_key(%{"name" => "anon"}) == :publishable
      assert Database.classify_key(%{"type" => "publishable"}) == :publishable
      assert Database.classify_key(%{"name" => "other"}) == :other
    end
  end

  describe "rendering" do
    test "csv: header, NULL as empty, and comma/quote/newline escaping" do
      cols = ["id", "note"]
      rows = [[1, "plain"], [2, nil], [3, "has,comma"], [4, ~s(has"quote)], [5, "a\nb"]]

      csv = Database.render(cols, rows, :csv)

      assert csv == """
             id,note
             1,plain
             2,
             3,"has,comma"
             4,"has""quote"
             5,"a
             b"
             """
    end

    test "csv: numbers, booleans, jsonb and arrays" do
      cols = ["n", "ok", "meta", "tags"]
      rows = [[1.5, true, %{"k" => "v"}, ["a", "b"]]]
      csv = Database.render(cols, rows, :csv)
      [_header, line] = String.split(csv, "\n", trim: true)

      assert line =~ "1.5"
      assert line =~ "true"
      assert line =~ ~s("{""k"":""v""}")
      assert line =~ ~s("[""a"",""b""]")
    end

    test "json: array of objects preserving column order, null and nested types" do
      cols = ["id", "meta", "tags", "note"]
      rows = [[1, %{"k" => "v"}, ["a", "b"], nil]]
      json = Database.render(cols, rows, :json)

      assert {:ok, [obj]} = Jason.decode(json)
      assert obj == %{"id" => 1, "meta" => %{"k" => "v"}, "tags" => ["a", "b"], "note" => nil}
      assert String.match?(json, ~r/"id".*"meta".*"tags".*"note"/s)
    end

    test "empty result renders just the header (csv) / empty array (json)" do
      assert Database.render(["a", "b"], [], :csv) == "a,b\n"
      assert Database.render(["a", "b"], [], :json) == "[]\n"
    end
  end

  describe "Data API path (stubbed transport)" do
    test "schemas come from the PostgREST config and are cached" do
      stub_data_api()

      assert {:ok, ["app", "public"]} = Database.schemas(@ref)
      assert TestEnv.hits("/v1/projects/#{@ref}/postgrest") == 1

      # a second call is served from cache — no extra Management API request
      assert {:ok, ["app", "public"]} = Database.schemas(@ref)
      assert TestEnv.hits("/v1/projects/#{@ref}/postgrest") == 1
    end

    test "tables come from the OpenAPI spec, sorted" do
      stub_data_api()
      assert {:ok, ["empty", "widgets"]} = Database.tables(@ref, "app")
      assert {:ok, []} = Database.tables(@ref, "public")
    end

    test "row_count reads the Content-Range total" do
      stub_data_api()
      assert {:ok, 1200} = Database.row_count(@ref, "app", "widgets")
      assert {:ok, 0} = Database.row_count(@ref, "app", "empty")
    end

    test "rows returns ordered columns and a page window" do
      stub_data_api()
      assert {:ok, page} = Database.rows(@ref, "app", "widgets", 0, 500)
      assert page.columns == ["id", "name"]
      assert length(page.rows) == 500
      assert hd(page.rows) == [0, "w0"]
      assert List.last(page.rows) == [499, "w499"]
    end

    test "render_page uses the configured page size as the limit" do
      stub_data_api()
      Config.set("db_page_size", "250")

      assert {:ok, body} = Database.render_page(@ref, "app", "widgets", 250, :csv)
      lines = String.split(body, "\n", trim: true)
      assert hd(lines) == "id,name"
      # rows 250..499 -> 250 rows + header
      assert length(lines) == 251
      assert Enum.at(lines, 1) == "250,w250"
    end

    test "a missing table is enoent" do
      stub_data_api()
      assert {:error, :enoent} = Database.rows(@ref, "app", "gone", 0, 500)
    end

    test "a forbidden Data API response maps to eacces" do
      Application.put_env(:supablock, :data_api_fun, fn _ref, _path, _headers ->
        {:ok, %{status: 403, headers: %{}, body: ""}}
      end)

      assert {:error, :eacces} = Database.row_count(@ref, "app", "widgets")
    end

    test "a transport error maps to eagain" do
      Application.put_env(:supablock, :data_api_fun, fn _ref, _path, _headers ->
        {:error, :timeout}
      end)

      assert {:error, :eagain} = Database.tables(@ref, "app")
    end
  end
end
