defmodule Supablock.MCPTest do
  use ExUnit.Case, async: false

  alias Supablock.{Cache, MCP, TestEnv}

  @proj_a1 "projaone1234567890ab"
  @base "organizations/org-alpha/projects/projaone1234567890ab"

  setup do
    TestEnv.isolate_xdg!()
    TestEnv.fake_login!()
    TestEnv.stub_api!()
    Cache.flush()
    :ok
  end

  # Drive the server with newline-delimited JSON-RPC and decode its replies.
  defp roundtrip(requests) do
    input_data = Enum.map_join(requests, "", &(Jason.encode!(&1) <> "\n"))
    {:ok, input} = StringIO.open(input_data)
    {:ok, output} = StringIO.open("")

    assert :ok = MCP.serve(input, output)

    {"", out} = StringIO.contents(output)

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp call(id, name, args) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }
  end

  defp text(reply) do
    assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} = reply
    text
  end

  test "initialize negotiates a protocol version and advertises tools" do
    [reply] =
      roundtrip([
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}
        }
      ])

    assert %{"id" => 1, "result" => result} = reply
    assert result["protocolVersion"] == "2025-03-26"
    assert result["serverInfo"]["name"] == "supablock"
    assert %{"tools" => %{}} = result["capabilities"]
    assert result["instructions"] =~ "organizations/"
  end

  test "an unknown client protocol version is answered with our newest" do
    [reply] =
      roundtrip([
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "1999-01-01"}
        }
      ])

    assert reply["result"]["protocolVersion"] == "2025-06-18"
  end

  test "notifications get no reply; ping and tools/list do" do
    replies =
      roundtrip([
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"},
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      ])

    assert [%{"id" => 2, "result" => %{}}, %{"id" => 3, "result" => %{"tools" => tools}}] =
             replies

    assert Enum.map(tools, & &1["name"]) == ["ls", "cat", "find", "grep"]
    assert Enum.all?(tools, &match?(%{"inputSchema" => %{"type" => "object"}}, &1))
  end

  test "ls lists directories, defaulting to the root" do
    [root, projects] =
      roundtrip([
        call(1, "ls", %{}),
        call(2, "ls", %{"path" => "organizations/org-alpha/projects"})
      ])

    assert text(root) == "organizations\n"
    assert text(projects) == "projaone1234567890ab\nprojatwo1234567890ab\n"
  end

  test "cat reads file bodies through the same Router as the mount" do
    [health, secret] =
      roundtrip([
        call(1, "cat", %{"path" => "#{@base}/health"}),
        call(2, "cat", %{"path" => "#{@base}/api-keys/secret"})
      ])

    assert text(health) =~ "db: healthy"
    # redaction applies over MCP exactly as everywhere else
    assert text(secret) =~ "REDACTED"
  end

  test "cat on a binary body refuses instead of dumping bytes" do
    [reply] = roundtrip([call(1, "cat", %{"path" => "#{@base}/functions/hello/body"})])
    assert reply["result"]["isError"] == true
    assert text(reply) =~ "binary file"
  end

  test "cat on a missing path is an isError result, not a protocol error" do
    [reply] = roundtrip([call(1, "cat", %{"path" => "organizations/nope"})])
    assert reply["result"]["isError"] == true
    assert text(reply) =~ "no such path"
  end

  test "find walks with filters" do
    [reply] =
      roundtrip([
        call(1, "find", %{
          "path" => "organizations/org-alpha",
          "maxdepth" => 1,
          "type" => "f",
          "name" => "*.json"
        })
      ])

    assert text(reply) == """
           organizations/org-alpha/info.json
           organizations/org-alpha/members.json
           organizations/org-alpha/regions.json
           """
  end

  test "grep searches file contents and reports line numbers" do
    [reply] = roundtrip([call(1, "grep", %{"pattern" => "site_url", "path" => "#{@base}/config"})])
    assert text(reply) =~ "#{@base}/config/auth.json:"
    assert text(reply) =~ "site_url"

    [none] =
      roundtrip([call(2, "grep", %{"pattern" => "no-such-string", "path" => "#{@base}/config"})])

    assert text(none) == "no matches\n"
  end

  test "unknown tool and unknown method are JSON-RPC errors" do
    replies =
      roundtrip([
        call(1, "rm", %{"path" => "organizations"}),
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "resources/list"}
      ])

    assert [%{"error" => %{"code" => -32602}}, %{"error" => %{"code" => -32601}}] = replies
  end

  test "malformed JSON gets a parse error and the loop continues" do
    {:ok, input} = StringIO.open("this is not json\n" <> Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"}) <> "\n")
    {:ok, output} = StringIO.open("")
    assert :ok = MCP.serve(input, output)
    {"", out} = StringIO.contents(output)
    assert [parse_error, pong] = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert parse_error["error"]["code"] == -32700
    assert pong["id"] == 7
  end
end
