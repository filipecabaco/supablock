defmodule Supablock.RouterTest do
  use ExUnit.Case, async: false

  alias Supablock.{Cache, Config, Render, Router, TestEnv}

  @proj_a1 "projaone1234567890ab"

  setup do
    TestEnv.isolate_xdg!()
    TestEnv.fake_login!()
    TestEnv.stub_api!()
    Cache.flush()
    :ok
  end

  describe "describe/list on directories" do
    test "root" do
      assert {:ok, :dir} = Router.describe("/")
      assert {:ok, ["organizations"]} = Router.list("/")
    end

    test "organizations listing" do
      assert {:ok, :dir} = Router.describe("/organizations")
      assert {:ok, ["org-alpha", "org-beta"]} = Router.list("/organizations")
    end

    test "org dir and children" do
      assert {:ok, :dir} = Router.describe("/organizations/org-alpha")

      assert {:ok, ["info.json", "members.json", "projects", "regions.json"]} =
               Router.list("/organizations/org-alpha")
    end

    test "projects are partitioned per organization" do
      assert {:ok, refs_a} = Router.list("/organizations/org-alpha/projects")
      assert refs_a == ["projaone1234567890ab", "projatwo1234567890ab"]

      assert {:ok, refs_b} = Router.list("/organizations/org-beta/projects")
      assert refs_b == ["projbone1234567890ab"]
    end

    test "project dir children" do
      assert {:ok, children} = Router.list("/organizations/org-alpha/projects/#{@proj_a1}")

      assert children ==
               [
                 "info.json",
                 "health",
                 "advisors",
                 "config",
                 "api-keys",
                 "secrets.json",
                 "functions",
                 "storage",
                 "branches",
                 "database",
                 "network",
                 "logs",
                 "metrics",
                 "types.ts",
                 "upgrade-eligibility.json"
               ]
    end

    test "functions and branches listings" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}"
      assert {:ok, ["hello", "goodbye"]} = Router.list("#{base}/functions")
      assert {:ok, ["body", "info.json"]} = Router.list("#{base}/functions/hello")
      assert {:ok, ["main"]} = Router.list("#{base}/branches")
      assert {:ok, ["info.json"]} = Router.list("#{base}/branches/main")
    end

    test "storage buckets listing" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}"
      assert {:ok, ["buckets"]} = Router.list("#{base}/storage")
      assert {:ok, ["avatars", "docs"]} = Router.list("#{base}/storage/buckets")
      assert {:ok, ["info.json"]} = Router.list("#{base}/storage/buckets/avatars")
    end

    test "auth config subtree (sso + third-party)" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/config/auth"
      assert {:ok, ["sso", "third-party"]} = Router.list(base)

      assert {:ok, ["11111111-1111-1111-1111-111111111111"]} = Router.list("#{base}/sso")
      assert {:ok, ["info.json"]} = Router.list("#{base}/sso/11111111-1111-1111-1111-111111111111")

      assert {:ok, ["tpa-firebase"]} = Router.list("#{base}/third-party")
      assert {:ok, ["info.json"]} = Router.list("#{base}/third-party/tpa-firebase")
    end

    test "sso 404 (SAML not enabled) surfaces as an empty listing, not an error" do
      # org-alpha's second project 404s the sso endpoint in the fixtures.
      base = "/organizations/org-alpha/projects/projatwo1234567890ab/config/auth"
      assert {:ok, []} = Router.list("#{base}/sso")
    end

    test "logs directory lists all sources" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}"
      assert {:ok, :dir} = Router.describe("#{base}/logs")
      assert {:ok, sources} = Router.list("#{base}/logs")

      for src <-
            ~w(auth auth-audit edge functions functions-edge pgbouncer postgres postgrest realtime storage supavisor) do
        assert src in sources, "expected #{src} in logs sources"
      end
    end

    test "metrics is a file" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/metrics"
      assert {:ok, :file} = Router.kind(path)
    end
  end

  describe "files" do
    test "describe reports exact rendered byte sizes" do
      path = "/organizations/org-alpha/info.json"
      assert {:ok, {:file, size}} = Router.describe(path)
      assert {:ok, body} = Router.read(path)
      assert size == byte_size(body)
      assert String.ends_with?(body, "\n")
    end

    test "info.json bodies are deterministic sorted JSON" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/info.json"
      assert {:ok, body1} = Router.read(path)
      Cache.flush()
      assert {:ok, body2} = Router.read(path)
      assert body1 == body2
      assert body1 == Render.json(Supablock.Fixtures.project(@proj_a1))
    end

    test "health renders per-service lines" do
      assert {:ok, body} = Router.read("/organizations/org-alpha/projects/#{@proj_a1}/health")
      assert body =~ "db: healthy\n"
    end

    test "config leaves" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/config"

      assert {:ok,
              [
                "auth.json",
                "database.json",
                "disk.json",
                "pgbouncer.json",
                "pooler.json",
                "postgrest.json",
                "realtime.json",
                "storage.json",
                "auth"
              ]} = Router.list(base)

      assert {:ok, body} = Router.read("#{base}/auth.json")
      assert body =~ ~s("site_url")
      assert {:ok, body} = Router.read("#{base}/database.json")
      assert body =~ ~s("max_connections")
      assert {:ok, body} = Router.read("#{base}/realtime.json")
      assert body =~ ~s("private_only")
      assert {:ok, body} = Router.read("#{base}/storage.json")
      assert body =~ ~s("fileSizeLimit")
      assert {:ok, body} = Router.read("#{base}/disk.json")
      assert body =~ ~s("iops")
      assert {:ok, body} = Router.read("#{base}/pgbouncer.json")
      assert body =~ ~s("pool_mode")
      assert {:ok, body} = Router.read("#{base}/pooler.json")
      assert body =~ ~s("database_type")
      assert {:ok, body} = Router.read("#{base}/postgrest.json")
      assert body =~ ~s("db_schema")
    end

    test "advisors directory and lint files" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/advisors"
      assert {:ok, :dir} = Router.describe(base)
      assert {:ok, ["performance.json", "security.json"]} = Router.list(base)

      assert {:ok, body} = Router.read("#{base}/security.json")
      assert body =~ "rls_disabled_in_public"
      assert body =~ ~s("level": "ERROR")

      assert {:ok, body} = Router.read("#{base}/performance.json")
      assert body =~ ~s("lints": [])
    end

    test "network directory: present resources render, unconfigured ones read as {}" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/network"

      assert {:ok,
              [
                "custom-hostname.json",
                "restrictions.json",
                "ssl-enforcement.json",
                "vanity-subdomain.json"
              ]} = Router.list(base)

      assert {:ok, body} = Router.read("#{base}/restrictions.json")
      assert body =~ "dbAllowedCidrs"
      assert {:ok, body} = Router.read("#{base}/ssl-enforcement.json")
      assert body =~ "currentConfig"
      assert {:ok, body} = Router.read("#{base}/custom-hostname.json")
      assert body =~ "db.example.com"

      # projatwo has no custom hostname: the endpoint 404s, the file reads {}
      other = "/organizations/org-alpha/projects/projatwo1234567890ab/network"
      assert {:ok, "{}\n"} = Router.read("#{other}/custom-hostname.json")
      assert {:ok, {:file, 3}} = Router.describe("#{other}/custom-hostname.json")
      assert {:ok, "{}\n"} = Router.read("#{other}/vanity-subdomain.json")
    end

    test "types.ts renders the raw generated TypeScript source" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/types.ts"
      assert {:ok, :file} = Router.kind(path)
      assert {:ok, body} = Router.read(path)
      assert body == "export type Json = string | number\nexport interface Database {}\n"
    end

    test "upgrade-eligibility.json renders" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/upgrade-eligibility.json"
      assert {:ok, body} = Router.read(path)
      assert body =~ ~s("eligible": true)
    end

    test "database dir carries backups/migrations/readonly files alongside schemas" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/database"
      assert {:ok, entries} = Router.list(base)
      assert ["backups.json", "migrations.json", "readonly.json" | schemas] = entries
      assert "public" in schemas

      assert {:ok, body} = Router.read("#{base}/backups.json")
      assert body =~ ~s("pitr_enabled")
      assert {:ok, body} = Router.read("#{base}/migrations.json")
      assert body =~ "add_users"
      assert {:ok, body} = Router.read("#{base}/readonly.json")
      assert body =~ ~s("enabled": false)
    end

    test "storage bucket and auth provider info.json render from the cached listing" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}"

      assert {:ok, bucket} = Router.read("#{base}/storage/buckets/avatars/info.json")
      assert bucket =~ ~s("public": true)

      assert {:ok, provider} =
               Router.read("#{base}/config/auth/sso/11111111-1111-1111-1111-111111111111/info.json")

      assert provider =~ "idp.example.com"

      assert {:ok, tpa} = Router.read("#{base}/config/auth/third-party/tpa-firebase/info.json")
      assert tpa =~ "firebase"
    end

    test "edge-function body is served as raw eszip bytes with an exact stat size" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/functions/hello/body"
      assert {:ok, body} = Router.read(path)
      assert body == Supablock.Fixtures.function_body()
      # opaque binary, not JSON-rendered
      refute String.ends_with?(body, "\n")
      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "regions.json lives under the organization (organization_slug required)" do
      path = "/organizations/org-alpha/regions.json"
      assert {:ok, {:file, _size}} = Router.describe(path)
      assert {:ok, body} = Router.read(path)
      assert body =~ "americas"

      # the root no longer exposes regions.json (the endpoint needs a slug)
      assert {:error, :enoent} = Router.describe("/regions.json")
    end

    test "reading a directory is an error" do
      assert {:error, :eio} = Router.read("/organizations")
      assert {:error, :eio} = Router.list("/organizations/org-alpha/regions.json")
    end

    test "log source file returns NDJSON rows, chronological, trailing newline" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/logs/auth"
      assert {:ok, body} = Router.read(path)
      assert String.ends_with?(body, "\n")

      rows =
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert [%{"event_message" => _, "timestamp" => _} | _] = rows
      # Chronological: earlier timestamp comes first.
      timestamps = Enum.map(rows, & &1["timestamp"])
      assert timestamps == Enum.sort(timestamps)

      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "all log sources are readable as NDJSON" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/logs"

      for source <-
            ~w(auth auth-audit edge functions functions-edge pgbouncer postgres postgrest realtime storage supavisor) do
        assert {:ok, body} = Router.read("#{base}/#{source}"), "expected ok for #{source}"
        lines = String.split(body, "\n", trim: true)
        assert Enum.all?(lines, fn line -> match?({:ok, %{}}, Jason.decode(line)) end)
      end
    end

    test "unknown log source is :enoent" do
      assert {:error, :enoent} =
               Router.describe("/organizations/org-alpha/projects/#{@proj_a1}/logs/unknown")
    end

    test "metrics file returns Prometheus text" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/metrics"
      assert {:ok, body} = Router.read(path)
      assert body =~ "pg_stat_activity_count"
      assert body =~ "pg_database_size_bytes"
      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end
  end

  describe "api-keys" do
    test "publishable is always visible" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/api-keys/publishable"
      assert {:ok, body} = Router.read(path)
      assert body == "sb_publishable_FAKEFAKEFAKE\n"
    end

    test "secret is redacted by default, with matching size" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/api-keys/secret"
      assert {:ok, body} = Router.read(path)
      assert body == "REDACTED — run: supablock config set expose_secrets true\n"
      refute body =~ "TOPSECRET"
      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "secret is shown when expose_secrets is enabled" do
      :ok = Config.set("expose_secrets", "true")
      path = "/organizations/org-alpha/projects/#{@proj_a1}/api-keys/secret"
      assert {:ok, "sb_secret_TOPSECRETVALUE\n"} = Router.read(path)
    end
  end

  describe "secrets.json" do
    test "names are visible but values are redacted by default" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/secrets.json"
      assert {:ok, body} = Router.read(path)
      assert body =~ "STRIPE_KEY"
      assert body =~ ~s("value": "REDACTED")
      refute body =~ "sk_live_SUPERSECRET"
      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "values are shown when expose_secrets is enabled" do
      :ok = Config.set("expose_secrets", "true")
      path = "/organizations/org-alpha/projects/#{@proj_a1}/secrets.json"
      assert {:ok, body} = Router.read(path)
      assert body =~ "sk_live_SUPERSECRET"
    end

    test "an empty secrets list renders as []" do
      path = "/organizations/org-alpha/projects/projatwo1234567890ab/secrets.json"
      assert {:ok, "[]\n"} = Router.read(path)
    end
  end

  describe "errors" do
    test "unknown paths are :enoent" do
      assert {:error, :enoent} = Router.describe("/nope")
      assert {:error, :enoent} = Router.describe("/organizations/org-nope")
      assert {:error, :enoent} = Router.describe("/organizations/org-alpha/nope")
      assert {:error, :enoent} = Router.describe("/organizations/org-alpha/projects/nope")

      assert {:error, :enoent} =
               Router.describe("/organizations/org-alpha/projects/#{@proj_a1}/functions/nope")
    end

    test "a bogus sibling name resolves via the cached parent list (no extra API call)" do
      assert {:ok, _names} = Router.list("/organizations")
      orgs_hits = TestEnv.hits("/v1/organizations")
      assert {:error, :enoent} = Router.describe("/organizations/org-nope")
      assert TestEnv.hits("/v1/organizations") == orgs_hits
    end

    test "404 endpoints surface as :enoent (leaf effectively dropped)" do
      TestEnv.stub_api!(Map.delete(Supablock.Fixtures.routes(), "/v1/projects/available-regions"))
      assert {:error, :enoent} = Router.describe("/organizations/org-alpha/regions.json")
    end

    test "401 maps to :eacces, 429 to :eagain, 500 to :eio" do
      routes = Supablock.Fixtures.routes()

      TestEnv.stub_api!(%{routes | "/v1/organizations" => {:status, 401, %{}}})
      Cache.flush()
      assert {:error, :eacces} = Router.list("/organizations")

      TestEnv.stub_api!(%{routes | "/v1/organizations" => {:status, 429, %{}}})
      Cache.flush()
      assert {:error, :eagain} = Router.list("/organizations")

      TestEnv.stub_api!(%{routes | "/v1/organizations" => {:status, 500, %{}}})
      Cache.flush()
      assert {:error, :eio} = Router.list("/organizations")
    end
  end

  describe "name sanitization" do
    test "slashes and NULs become underscores, empty becomes _" do
      assert Router.sanitize("a/b") == "a_b"
      assert Router.sanitize("a" <> <<0>> <> "b") == "a_b"
      assert Router.sanitize("") == "_"
      assert Router.sanitize("ok-name") == "ok-name"
    end

    test "collisions get deterministic ~2/~3 suffixes in list order" do
      pairs = [{"dup", 1}, {"dup", 2}, {"other", 3}, {"dup", 4}]

      assert Router.uniquify(pairs) == [
               {"dup", 1},
               {"dup~2", 2},
               {"other", 3},
               {"dup~3", 4}
             ]
    end

    test "sanitized names route back to the original entity" do
      routes =
        Map.merge(Supablock.Fixtures.routes(), %{
          "/v1/projects/projaone1234567890ab/functions" => [
            %{"slug" => "weird/name", "status" => "ACTIVE"}
          ]
        })

      TestEnv.stub_api!(routes)
      base = "/organizations/org-alpha/projects/#{@proj_a1}/functions"
      assert {:ok, ["weird_name"]} = Router.list(base)
      assert {:ok, :dir} = Router.describe("#{base}/weird_name")
    end
  end

  describe "database tree" do
    setup do
      # Exposed schemas come from the stubbed Management API PostgREST config
      # (org-alpha fixtures expose "app, public"); row data comes from the
      # in-memory Data API stub below.
      Application.put_env(:supablock, :data_api_fun, Supablock.DataApiStub.fun(db_model()))
      Cache.flush()
      on_exit(fn -> Application.delete_env(:supablock, :data_api_fun) end)
      :ok
    end

    # Models app.widgets (1200 rows) and app.empty (0 rows); public has none.
    defp db_model do
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

    test "database appears in every project's children" do
      assert {:ok, children} = Router.list("/organizations/org-alpha/projects/#{@proj_a1}")
      assert "database" in children

      other = "/organizations/org-alpha/projects/projatwo1234567890ab"
      assert {:ok, children2} = Router.list(other)
      assert "database" in children2
    end

    test "schemas and tables are listed" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/database"
      assert {:ok, ["backups.json", "migrations.json", "readonly.json", "app", "public"]} =
               Router.list(base)
      assert {:ok, :dir} = Router.describe("#{base}/app")
      assert {:ok, ["empty", "widgets"]} = Router.list("#{base}/app")
      assert {:ok, []} = Router.list("#{base}/public")
    end

    test "an empty table has no page files and no readable page" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/database/app/empty"
      assert {:ok, ["schema.json"]} = Router.list(base)
      assert {:error, :enoent} = Router.describe("#{base}/rows-000000.csv")
    end

    test "a table lists one page file per page_size rows" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets"
      assert {:ok, files} = Router.list(path)
      assert files == ["schema.json", "rows-000000.csv", "rows-000500.csv", "rows-001000.csv"]
    end

    test "schema.json renders columns in ordinal order with pk and required" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets/schema.json"
      assert {:ok, :file} = Router.kind(path)
      assert {:ok, body} = Router.read(path)
      assert {:ok, decoded} = Jason.decode(body)

      assert %{"columns" => columns, "primary_key" => ["id"], "required" => ["id"]} = decoded
      assert Enum.map(columns, & &1["name"]) == ["id", "name"]
      assert [%{"type" => "string", "format" => "text"} | _rest] = columns

      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "reading a csv page renders header + rows with exact stat size" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets/rows-001000.csv"

      assert {:ok, body} = Router.read(path)
      assert String.starts_with?(body, "id,name\n1000,w1000\n")
      # last page holds rows 1000..1199 -> 200 rows + header
      assert length(String.split(body, "\n", trim: true)) == 201

      assert {:ok, {:file, size}} = Router.describe(path)
      assert size == byte_size(body)
    end

    test "json pages are readable even when csv is the default" do
      path = "/organizations/org-alpha/projects/#{@proj_a1}/database/app/widgets/rows-000000.json"
      assert {:ok, body} = Router.read(path)
      assert {:ok, decoded} = Jason.decode(body)
      assert length(decoded) == 500
      assert hd(decoded) == %{"id" => 0, "name" => "w0"}
    end

    test "bad schema, table, and page names are enoent" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/database"
      assert {:error, :enoent} = Router.describe("#{base}/nope")
      assert {:error, :enoent} = Router.describe("#{base}/app/missing")
      # offset not on a page boundary
      assert {:error, :enoent} = Router.describe("#{base}/app/widgets/rows-000123.csv")
      # offset past the end
      assert {:error, :enoent} = Router.describe("#{base}/app/widgets/rows-999999.csv")
      # not a page file at all
      assert {:error, :enoent} = Router.describe("#{base}/app/widgets/whatever.txt")
    end
  end

  describe "caching behaviour" do
    test "repeated reads of the same leaf hit the API once" do
      path = "/organizations/org-alpha/info.json"
      assert {:ok, _body} = Router.read(path)
      assert {:ok, _body} = Router.read(path)
      assert {:ok, {:file, _size}} = Router.describe(path)
      assert TestEnv.hits("/v1/organizations/org-alpha") == 1
    end

    test "flush causes a re-fetch" do
      path = "/organizations/org-alpha/info.json"
      assert {:ok, _body} = Router.read(path)
      assert TestEnv.hits("/v1/organizations/org-alpha") == 1
      Cache.flush()
      assert {:ok, _body} = Router.read(path)
      assert TestEnv.hits("/v1/organizations/org-alpha") == 2
    end
  end
end
