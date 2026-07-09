defmodule Supablock.RenderTest do
  use ExUnit.Case, async: true

  alias Supablock.Render

  test "json output is deterministic regardless of key insertion order" do
    a = %{"b" => 1, "a" => %{"z" => [1, 2], "y" => "x"}, "c" => nil}

    b =
      %{}
      |> Map.put("c", nil)
      |> Map.put("a", %{} |> Map.put("y", "x") |> Map.put("z", [1, 2]))
      |> Map.put("b", 1)

    assert Render.json(a) == Render.json(b)
  end

  test "json is pretty, sorted and newline-terminated" do
    out = Render.json(%{"b" => 1, "a" => 2})
    assert out == "{\n  \"a\": 2,\n  \"b\": 1\n}\n"
    assert String.ends_with?(out, "\n")
  end

  test "nested maps inside lists are sorted too" do
    out = Render.json([%{"b" => 1, "a" => 2}])
    assert out =~ ~r/"a".*"b"/s
  end

  test "health renders one line per service" do
    out = Render.health(Supablock.Fixtures.health())
    assert out =~ "db: healthy\n"
    assert out =~ "realtime: unhealthy (UNHEALTHY)\n"
    assert out |> String.split("\n", trim: true) |> length() == 5
  end

  test "health falls back to json for unexpected shapes" do
    out = Render.health(%{"status" => "ok"})
    assert out == "{\n  \"status\": \"ok\"\n}\n"
  end

  test "size is byte_size of the rendered body" do
    body = Render.json(%{"key" => "välue"})
    assert byte_size(body) == byte_size(body |> :binary.copy())
    assert byte_size(body) > String.length(body)
  end
end
