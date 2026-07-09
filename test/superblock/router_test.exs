defmodule Superblock.RouterTest do
  use ExUnit.Case, async: false

  alias Superblock.{Cache, Config, Render, Router, TestEnv}

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
      assert children == ["info.json", "health", "config", "api-keys", "functions", "branches"]
    end

    test "functions and branches listings" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}"
      assert {:ok, ["hello", "goodbye"]} = Router.list("#{base}/functions")
      assert {:ok, ["info.json"]} = Router.list("#{base}/functions/hello")
      assert {:ok, ["main"]} = Router.list("#{base}/branches")
      assert {:ok, ["info.json"]} = Router.list("#{base}/branches/main")
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
      assert body1 == Render.json(Superblock.Fixtures.project(@proj_a1))
    end

    test "health renders per-service lines" do
      assert {:ok, body} = Router.read("/organizations/org-alpha/projects/#{@proj_a1}/health")
      assert body =~ "db: healthy\n"
    end

    test "config leaves" do
      base = "/organizations/org-alpha/projects/#{@proj_a1}/config"
      assert {:ok, ["auth.json", "database.json"]} = Router.list(base)
      assert {:ok, body} = Router.read("#{base}/auth.json")
      assert body =~ ~s("site_url")
      assert {:ok, body} = Router.read("#{base}/database.json")
      assert body =~ ~s("max_connections")
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
      assert body == "REDACTED — run: superblock config set expose_secrets true\n"
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
      TestEnv.stub_api!(Map.delete(Superblock.Fixtures.routes(), "/v1/projects/available-regions"))
      assert {:error, :enoent} = Router.describe("/organizations/org-alpha/regions.json")
    end

    test "401 maps to :eacces, 429 to :eagain, 500 to :eio" do
      routes = Superblock.Fixtures.routes()

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
        Map.merge(Superblock.Fixtures.routes(), %{
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
