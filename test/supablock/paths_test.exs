defmodule Supablock.PathsTest do
  use ExUnit.Case, async: false

  alias Supablock.{Paths, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  describe "validate_control_socket/0" do
    test "an ordinary state dir fits" do
      System.put_env("XDG_STATE_HOME", "/tmp/sb-short")
      assert :ok = Paths.validate_control_socket()
    end

    test "a deep state dir — a sandbox scratch path — is rejected with its numbers" do
      deep = "/tmp/" <> String.duplicate("nested/", 20)
      System.put_env("XDG_STATE_HOME", deep)

      assert {:error, message} = Paths.validate_control_socket()
      assert message =~ "over the 103"
      assert message =~ "XDG_STATE_HOME"
      assert message =~ to_string(byte_size(Paths.control_socket()))
    end

    test "the limit is checked in bytes, not characters" do
      # 60 two-byte characters is 120 bytes: under the limit by length,
      # over it by the measure the kernel actually applies.
      System.put_env("XDG_STATE_HOME", "/tmp/" <> String.duplicate("é", 60))

      assert String.length(Paths.control_socket()) <= 103
      assert {:error, _message} = Paths.validate_control_socket()
    end
  end
end
