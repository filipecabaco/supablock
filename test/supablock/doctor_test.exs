defmodule Supablock.DoctorTest do
  use ExUnit.Case, async: false

  alias Supablock.{Doctor, Paths, TestEnv}

  setup do
    TestEnv.isolate_xdg!()
    :ok
  end

  describe "grouping" do
    test "reads, daemon and mounting are reported separately" do
      assert [
               {:reading, _reading_title, reading_checks},
               {:daemon, _daemon_title, _daemon_checks},
               {:mounting, _mount_title, mount_checks}
             ] = Doctor.run()

      # The FUSE checks are the ones a sandbox fails, and they must not sit
      # in the required group.
      names = fn checks -> Enum.map(checks, fn {name, _result} -> name end) end
      refute Enum.any?(names.(reading_checks), &(&1 =~ ~r/fuse|FUSE/))
      assert Enum.any?(names.(mount_checks), &(&1 =~ ~r/fuse|FUSE/))
    end
  end

  describe "reads_ok?/1" do
    test "ignores failures outside the reading group" do
      groups = [
        {:reading, "r", [{"credential available", :ok}]},
        {:daemon, "d", [{"socket", {:error, "nope"}}]},
        {:mounting, "m", [{"/dev/fuse present", {:error, "no fuse here"}}]}
      ]

      assert Doctor.reads_ok?(groups)
      assert Doctor.optional_gaps?(groups)
    end

    test "a failed reading check is fatal" do
      groups = [
        {:reading, "r", [{"credential available", {:error, "log in"}}]},
        {:mounting, "m", [{"/dev/fuse present", :ok}]}
      ]

      refute Doctor.reads_ok?(groups)
      refute Doctor.optional_gaps?(groups)
    end
  end

  describe "credential check" do
    test "passes on SUPABLOCK_TOKEN alone, with no stored credential" do
      System.put_env("SUPABLOCK_TOKEN", "sbp_headless000000000000000000000000cafe")
      on_exit(fn -> System.delete_env("SUPABLOCK_TOKEN") end)

      refute File.exists?(Paths.credentials_file())
      assert Doctor.reads_ok?(Doctor.run())
    end

    test "fails with no credential anywhere" do
      refute Doctor.reads_ok?(Doctor.run())
    end
  end
end
