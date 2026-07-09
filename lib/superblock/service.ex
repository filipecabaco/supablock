defmodule Superblock.Service do
  @moduledoc """
  Auto-start integration: installs `superblock mount` as a user-level
  service — a systemd user unit on Linux, a launchd agent on macOS — so the
  mount comes up at login and is restarted on failure.

  Everything is per-user (no root): the unit lands in
  `~/.config/systemd/user/` / `~/Library/LaunchAgents/`, and the service
  reads the same config/credentials files the CLI uses.
  """

  alias Superblock.{Config, Paths}

  @unit_name "superblock.service"
  @agent_label "io.github.filipecabaco.superblock"

  @spec install() :: {:ok, [String.t()]} | {:error, String.t()}
  def install do
    with {:ok, bin} <- executable_path() do
      mountpoint = Config.mountpoint()

      case platform() do
        :linux -> install_systemd(bin, mountpoint)
        :darwin -> install_launchd(bin, mountpoint)
      end
    end
  end

  @spec uninstall() :: {:ok, [String.t()]}
  def uninstall do
    case platform() do
      :linux ->
        run_quiet("systemctl", ["--user", "disable", "--now", @unit_name])
        File.rm(systemd_unit_path())
        run_quiet("systemctl", ["--user", "daemon-reload"])
        {:ok, ["Removed #{systemd_unit_path()}"]}

      :darwin ->
        run_quiet("launchctl", ["unload", "-w", launchd_plist_path()])
        File.rm(launchd_plist_path())
        {:ok, ["Removed #{launchd_plist_path()}"]}
    end
  end

  @spec status() :: {:installed, String.t(), String.t()} | :not_installed
  def status do
    {path, state} =
      case platform() do
        :linux ->
          {systemd_unit_path(),
           case run_quiet("systemctl", ["--user", "is-active", @unit_name]) do
             {out, 0} -> String.trim(out)
             {out, _nonzero} -> String.trim(out)
           end}

        :darwin ->
          {launchd_plist_path(),
           case run_quiet("launchctl", ["list", @agent_label]) do
             {_out, 0} -> "loaded"
             {_out, _nonzero} -> "not loaded"
           end}
      end

    if File.exists?(path), do: {:installed, path, state}, else: :not_installed
  end

  ## Linux (systemd user unit)

  defp install_systemd(bin, mountpoint) do
    path = systemd_unit_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    [Unit]
    Description=superblock — Supabase account mounted at #{mountpoint}
    After=network-online.target

    [Service]
    Type=simple
    ExecStart=#{bin} mount
    Restart=on-failure
    RestartSec=3

    [Install]
    WantedBy=default.target
    """)

    messages = ["Wrote #{path}"]

    if System.find_executable("systemctl") do
      run_quiet("systemctl", ["--user", "daemon-reload"])

      case run_quiet("systemctl", ["--user", "enable", "--now", @unit_name]) do
        {_out, 0} ->
          {:ok, messages ++ ["Enabled and started #{@unit_name} (systemd user unit)."]}

        {out, _nonzero} ->
          {:ok,
           messages ++
             [
               "Could not enable via systemctl (#{String.trim(out)}).",
               "Enable manually: systemctl --user enable --now #{@unit_name}"
             ]}
      end
    else
      {:ok, messages ++ ["systemctl not found — enable manually once under systemd."]}
    end
  end

  ## macOS (launchd agent)

  defp install_launchd(bin, mountpoint) do
    path = launchd_plist_path()
    File.mkdir_p!(Path.dirname(path))
    Paths.ensure!()

    File.write!(path, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{@agent_label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{bin}</string>
        <string>mount</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key>
      <dict><key>SuccessfulExit</key><false/></dict>
      <key>StandardOutPath</key><string>#{Paths.log_file()}</string>
      <key>StandardErrorPath</key><string>#{Paths.log_file()}</string>
      <key>Comment</key><string>superblock mount at #{mountpoint}</string>
    </dict>
    </plist>
    """)

    messages = ["Wrote #{path}"]

    if System.find_executable("launchctl") do
      case run_quiet("launchctl", ["load", "-w", path]) do
        {_out, 0} -> {:ok, messages ++ ["Loaded launchd agent #{@agent_label}."]}
        {out, _nonzero} -> {:ok, messages ++ ["launchctl load failed: #{String.trim(out)}"]}
      end
    else
      {:ok, messages ++ ["launchctl not found — load manually."]}
    end
  end

  ## Helpers

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      _other -> :linux
    end
  end

  defp systemd_unit_path do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([base, "systemd", "user", @unit_name])
  end

  defp launchd_plist_path do
    Path.join([System.user_home!(), "Library", "LaunchAgents", "#{@agent_label}.plist"])
  end

  # The absolute program the service should run: the Burrito wrapper when
  # running as a wrapped binary, the launcher script otherwise.
  defp executable_path do
    candidates = [
      System.get_env("__BURRITO_BIN_PATH"),
      System.get_env("SUPERBLOCK_BIN"),
      System.find_executable("superblock")
    ]

    case Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) do
      nil ->
        {:error,
         "cannot determine the superblock executable path — " <>
           "install the binary on your PATH or set SUPERBLOCK_BIN"}

      bin ->
        {:ok, Path.expand(bin)}
    end
  end

  defp run_quiet(cmd, args) do
    case System.find_executable(cmd) do
      nil -> {"#{cmd} not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  rescue
    error -> {Exception.message(error), 1}
  end
end
