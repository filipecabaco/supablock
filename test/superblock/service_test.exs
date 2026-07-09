defmodule Superblock.ServiceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Superblock.{CLI, Service, TestEnv}

  setup do
    base = TestEnv.isolate_xdg!()
    # Point executable resolution at a real file.
    System.put_env("SUPERBLOCK_BIN", "/bin/sh")
    on_exit(fn -> System.delete_env("SUPERBLOCK_BIN") end)
    {:ok, base: base}
  end

  test "install requires a configured mountpoint" do
    assert {:error, message} = Service.install()
    assert message =~ "no mountpoint configured"
  end

  test "install writes a systemd user unit under XDG_CONFIG_HOME", %{base: base} do
    :ok = Superblock.Config.set("mountpoint", "/mnt/supabase")

    assert {:ok, messages} = Service.install()
    assert Enum.any?(messages, &(&1 =~ "superblock.service"))

    unit_path = Path.join([base, "config", "systemd", "user", "superblock.service"])
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
             "Usage: superblock service"
  end

  test "cli service install surfaces missing mountpoint as an error" do
    stderr = capture_io(:stderr, fn -> assert CLI.run(["service", "install"]) == 1 end)
    assert stderr =~ "no mountpoint configured"
  end
end
