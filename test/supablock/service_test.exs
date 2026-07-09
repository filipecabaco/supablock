defmodule Supablock.ServiceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Supablock.{CLI, Service, TestEnv}

  setup do
    base = TestEnv.isolate_xdg!()
    # Point executable resolution at a real file.
    System.put_env("SUPABLOCK_BIN", "/bin/sh")
    on_exit(fn -> System.delete_env("SUPABLOCK_BIN") end)
    {:ok, base: base}
  end

  test "install without a configured mountpoint uses the ~/Supabase default", %{base: base} do
    assert {:ok, _messages} = Service.install()

    unit_path = Path.join([base, "config", "systemd", "user", "supablock.service"])
    assert File.read!(unit_path) =~ Path.join(System.user_home!(), "Supabase")

    assert {:ok, _messages} = Service.uninstall()
  end

  test "install writes a systemd user unit under XDG_CONFIG_HOME", %{base: base} do
    :ok = Supablock.Config.set("mountpoint", "/mnt/supabase")

    assert {:ok, messages} = Service.install()
    assert Enum.any?(messages, &(&1 =~ "supablock.service"))

    unit_path = Path.join([base, "config", "systemd", "user", "supablock.service"])
    assert File.exists?(unit_path)

    unit = File.read!(unit_path)
    assert unit =~ "ExecStart=/bin/sh mount"
    assert unit =~ "Restart=on-failure"
    assert unit =~ "/mnt/supabase"

    assert {:installed, ^unit_path, _state} = Service.status()

    assert {:ok, _messages} = Service.uninstall()
    refute File.exists?(unit_path)
    assert Service.status() == :not_installed
  end

  test "cli service subcommands report status and usage" do
    assert capture_io(fn -> assert CLI.run(["service", "status"]) == 1 end) =~
             "Service not installed"

    assert capture_io(:stderr, fn -> assert CLI.run(["service", "bogus"]) == 1 end) =~
             "Usage: supablock service"
  end
end
