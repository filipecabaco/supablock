defmodule Supablock.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Supablock.{Client, Config, TestEnv}

  @token "sbp_supersecrettokenvalue00000000000000cafe"

  setup do
    TestEnv.isolate_xdg!()
    :ok = Supablock.Credentials.store(@token)
    :ok
  end

  test "deadline exceeded returns {:error, :timeout}" do
    :ok = Config.set("http_timeout_ms", "100")

    TestEnv.stub_api!(%{
      "/v1/organizations" => fn conn ->
        Process.sleep(500)
        Plug.Conn.send_resp(conn, 200, "[]")
      end
    })

    assert {:error, :timeout} = Client.get("/v1/organizations")
  end

  test "429 with Retry-After beyond the deadline is an immediate :rate_limited" do
    :ok = Config.set("http_timeout_ms", "500")

    TestEnv.stub_api!(%{
      "/v1/organizations" => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "3600")
        |> Plug.Conn.send_resp(429, ~s({"message":"too many"}))
      end
    })

    started = System.monotonic_time(:millisecond)
    assert {:error, :rate_limited} = Client.get("/v1/organizations")
    assert System.monotonic_time(:millisecond) - started < 400
    assert TestEnv.hits("/v1/organizations") == 1
  end

  test "status codes map to reasons" do
    TestEnv.stub_api!(%{
      "/v1/organizations" => {:status, 401, %{}},
      "/v1/projects" => {:status, 403, %{}},
      "/v1/projects/x" => {:status, 404, %{}},
      "/v1/projects/y" => {:status, 500, %{}}
    })

    assert {:error, :unauthorized} = Client.get("/v1/organizations")
    assert {:error, :forbidden} = Client.get("/v1/projects")
    assert {:error, :not_found} = Client.get("/v1/projects/x")
    assert {:error, {:http, 500}} = Client.get("/v1/projects/y")
  end

  test "a 400 entitlement gate is :unavailable, a plain 400 stays {:http, 400}" do
    TestEnv.stub_api!(%{
      "/v1/projects/a" => {:status, 400, %{"error" => %{"code" => "entitlement_required"}}},
      "/v1/projects/b" =>
        {:status, 400, %{"message" => "Custom domains require the Custom Domain add-on."}},
      "/v1/projects/c" => {:status, 400, %{"message" => "invalid request body"}}
    })

    assert {:error, :unavailable} = Client.get("/v1/projects/a")
    assert {:error, :unavailable} = Client.get("/v1/projects/b")
    assert {:error, {:http, 400}} = Client.get("/v1/projects/c")
  end

  test "rate limit headers land in the ratelimit table with the right scope" do
    TestEnv.stub_api!(%{
      "/v1/projects/projaone1234567890ab/health" => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "41")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "[]")
      end
    })

    assert {:ok, _body} = Client.get("/v1/projects/projaone1234567890ab/health?services=db")

    assert [{"projaone1234567890ab", 41, _reset}] =
             Enum.filter(Client.ratelimits(), fn {scope, _r, _t} ->
               scope == "projaone1234567890ab"
             end)
  end

  test "scope_for classifies paths" do
    assert Client.scope_for("/v1/organizations") == "user"
    assert Client.scope_for("/v1/organizations/org-a/members") == "org-a"
    assert Client.scope_for("/v1/projects/ref123") == "ref123"
    assert Client.scope_for("/v1/projects/available-regions") == "user"
  end

  test "the raw token never appears in logs, even for failing requests" do
    :ok = Config.set("http_timeout_ms", "100")

    TestEnv.stub_api!(%{
      "/v1/organizations" => fn conn ->
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, "[]")
      end
    })

    log =
      capture_log([level: :debug], fn ->
        assert {:error, :timeout} = Client.get("/v1/organizations")
        # also exercise the explicit redaction helper
        Logger.debug(Client.redact("Authorization: Bearer #{@token}", @token))
        Logger.flush()
      end)

    refute log =~ @token
    refute log =~ String.trim_leading(@token, "sbp_")
  end

  test "redact scrubs bearer values and sbp_ tokens from arbitrary terms" do
    assert Client.redact("Bearer #{@token}") == "Bearer sbp_…"
    assert Client.redact(%{"authorization" => "Bearer #{@token}"}) =~ "sbp_…"
    refute Client.redact({:error, "boom #{@token}"}, @token) =~ "supersecret"
  end
end
