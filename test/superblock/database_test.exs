defmodule Superblock.DatabaseTest do
  use ExUnit.Case, async: false

  alias Superblock.{Cache, Database, DbCredentials, TestEnv}
  alias Superblock.Database.Connections

  @ref "projaone1234567890ab"

  setup do
    TestEnv.isolate_xdg!()
    Cache.flush()
    DbCredentials.put(@ref, "postgres://u:p@localhost:5432/postgres?sslmode=disable")

    on_exit(fn -> Application.delete_env(:superblock, :db_query_fun) end)
    :ok
  end

  # Route generated SQL to canned results so no real Postgres is needed.
  defp stub(fun), do: Application.put_env(:superblock, :db_query_fun, fun)

  describe "SQL builders" do
    test "identifiers are quoted and embedded quotes doubled" do
      assert Database.quote_ident("users") == ~s("users")
      assert Database.quote_ident(~s(od"d)) == ~s("od""d")
      assert Database.qualify("app", "wid,gets") == ~s("app"."wid,gets")
    end

    test "rows_sql paginates by ctid with bound params" do
      sql = Database.rows_sql("public", "users")
      assert sql =~ ~s(SELECT * FROM "public"."users")
      assert sql =~ "ORDER BY ctid"
      assert sql =~ "LIMIT $1 OFFSET $2"
    end

    test "schemas_sql excludes system schemas" do
      assert Database.schemas_sql() =~ "pg_catalog"
      assert Database.schemas_sql() =~ "information_schema"
    end

    test "tables_sql filters to base tables in a schema" do
      assert Database.tables_sql() =~ "table_schema = $1"
      assert Database.tables_sql() =~ "BASE TABLE"
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
      # column order is preserved (id first, note last)
      assert String.match?(json, ~r/"id".*"meta".*"tags".*"note"/s)
    end

    test "empty result renders just the header (csv) / empty array (json)" do
      assert Database.render(["a", "b"], [], :csv) == "a,b\n"
      assert Database.render(["a", "b"], [], :json) == "[]\n"
    end
  end

  describe "cached query path (stubbed executor)" do
    test "schemas/tables/row_count/rows go through the stub and are cached" do
      counter = :counters.new(1, [])

      stub(fn _ref, sql, _params ->
        :counters.add(counter, 1, 1)

        cond do
          sql =~ "information_schema.schemata" ->
            {:ok, %{columns: ["s"], rows: [["public"], ["app"]]}}

          sql =~ "information_schema.tables" ->
            {:ok, %{columns: ["t"], rows: [["users"]]}}

          sql =~ "count(*)" ->
            {:ok, %{columns: ["c"], rows: [[1200]]}}

          true ->
            {:ok, %{columns: ["id"], rows: [[1], [2]]}}
        end
      end)

      assert {:ok, ["public", "app"]} = Database.schemas(@ref)
      assert {:ok, ["users"]} = Database.tables(@ref, "public")
      assert {:ok, 1200} = Database.row_count(@ref, "public", "users")
      assert {:ok, %{rows: [[1], [2]]}} = Database.rows(@ref, "public", "users", 0, 500)

      hits = :counters.get(counter, 1)
      # a second identical call is served from cache
      assert {:ok, ["public", "app"]} = Database.schemas(@ref)
      assert :counters.get(counter, 1) == hits
    end

    test "render_page uses the configured page size as the limit" do
      test_pid = self()

      stub(fn _ref, sql, params ->
        if sql =~ "SELECT *", do: send(test_pid, {:params, params})
        {:ok, %{columns: ["id"], rows: [[1]]}}
      end)

      Superblock.Config.set("db_page_size", "250")
      assert {:ok, body} = Database.render_page(@ref, "public", "users", 250, :csv)
      assert body == "id\n1\n"
      assert_received {:params, [250, 250]}
    end

    test "Postgres errors map to filesystem errnos" do
      stub(fn _ref, _sql, _params ->
        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}}
      end)

      assert {:error, :enoent} = Database.row_count(@ref, "public", "gone")

      Cache.flush()

      stub(fn _ref, _sql, _params ->
        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}
      end)

      assert {:error, :eacces} = Database.schemas(@ref)

      Cache.flush()
      stub(fn _ref, _sql, _params -> {:error, %DBConnection.ConnectionError{message: "down"}} end)
      assert {:error, :eagain} = Database.schemas(@ref)
    end
  end

  describe "url parsing" do
    test "parses host, port, database, credentials and sslmode" do
      assert {:ok, opts} =
               Connections.Opts.parse(
                 "postgres://me:secret@h.example.com:6543/mydb?sslmode=disable"
               )

      assert opts[:hostname] == "h.example.com"
      assert opts[:port] == 6543
      assert opts[:username] == "me"
      assert opts[:password] == "secret"
      assert opts[:database] == "mydb"
      assert opts[:ssl] == false
    end

    test "defaults: port 5432, database postgres, ssl on without verification" do
      assert {:ok, opts} = Connections.Opts.parse("postgres://me:secret@h.example.com/")
      assert opts[:port] == 5432
      assert opts[:database] == "postgres"
      assert opts[:ssl] == [verify: :verify_none]
    end

    test "verify-full turns on peer verification" do
      assert {:ok, opts} =
               Connections.Opts.parse("postgres://me:secret@h.example.com/db?sslmode=verify-full")

      assert opts[:ssl][:verify] == :verify_peer
    end

    test "rejects non-postgres URLs" do
      assert {:error, :invalid_url} = Connections.Opts.parse("mysql://x/y")
      assert {:error, :invalid_url} = Connections.Opts.parse("not a url")
    end
  end
end
