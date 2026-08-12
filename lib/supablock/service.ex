defmodule Supablock.Service do
  @moduledoc """
  Auto-start integration: installs `supablock mount` as a user-level
  service — a systemd user unit on Linux, a launchd agent on macOS — so the
  mount comes up at login and is restarted on failure.

  Everything is per-user (no root): the unit lands in
  `~/.config/systemd/user/` / `~/Library/LaunchAgents/`, and the service
  reads the same config/credentials files the CLI uses.
  """

  alias Supablock.{Config, Paths}

  @unit_name "supablock.service"
  @agent_label "io.github.filipecabaco.supablock"

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

  defp install_systemd(bin, mountpoint) do
    path = systemd_unit_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, systemd_unit(bin, mountpoint))

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

  defp install_launchd(bin, mountpoint) do
    path = launchd_plist_path()
    File.mkdir_p!(Path.dirname(path))
    Paths.ensure!()

    File.write!(path, launchd_plist(bin, mountpoint))

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

  @doc """
  The systemd user unit for `bin` mounting at `mountpoint`. Public so the
  escaping below is testable on any platform, not only Linux.
  """
  @spec systemd_unit(String.t(), String.t()) :: String.t()
  def systemd_unit(bin, mountpoint) do
    """
    [Unit]
    Description=supablock — Supabase account mounted at #{unit_value(mountpoint)}
    After=network-online.target

    [Service]
    Type=simple
    ExecStart="#{exec_arg(bin)}" mount --foreground
    Restart=on-failure
    RestartSec=3

    [Install]
    WantedBy=default.target
    """
  end

  # A unit file is line-oriented, so a newline in a value opens a new directive
  # and a second [Service]/ExecStart would win. Control characters are dropped
  # rather than escaped — no legitimate mountpoint carries one.
  defp unit_value(value) do
    value |> to_string() |> String.replace(~r/[\x00-\x1f\x7f]/, "")
  end

  # ExecStart is shell-like: whitespace splits arguments, and `\` and `"` stay
  # meaningful inside the quotes the caller wraps this in.
  defp exec_arg(value) do
    value
    |> unit_value()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  @doc """
  The launchd agent plist for `bin` mounting at `mountpoint`. Public so the
  escaping below is testable on any platform, not only macOS.
  """
  @spec launchd_plist(String.t(), String.t()) :: String.t()
  def launchd_plist(bin, mountpoint) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{@agent_label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{xml(bin)}</string>
        <string>mount</string>
        <string>--foreground</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key>
      <dict><key>SuccessfulExit</key><false/></dict>
      <key>StandardOutPath</key><string>#{xml(Paths.log_file())}</string>
      <key>StandardErrorPath</key><string>#{xml(Paths.log_file())}</string>
      <key>Comment</key><string>supablock mount at #{xml(mountpoint)}</string>
    </dict>
    </plist>
    """
  end

  # The plist is XML, so a value carrying `</string>` would close the element
  # and let the rest be read as further plist keys — a later duplicate
  # `ProgramArguments` wins, which is a login-time command. `mountpoint` is
  # the reachable input: `config set` and `setup <profile>` both accept it,
  # and the profile can come off the network. `Config.coerce/2` refuses
  # newlines on the way in, but only on the write path — the config file is
  # read back without revalidation, so both writers escape their own format.
  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

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

  defp executable_path do
    candidates = [
      System.get_env("__BURRITO_BIN_PATH"),
      System.get_env("SUPABLOCK_BIN"),
      System.find_executable("supablock")
    ]

    case Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) do
      nil ->
        {:error,
         "cannot determine the supablock executable path — " <>
           "install the binary on your PATH or set SUPABLOCK_BIN"}

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
