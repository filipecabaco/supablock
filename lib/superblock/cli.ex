defmodule Superblock.CLI do
  @moduledoc """
  Command-line entry point.

      superblock login [--token sbp_...]
      superblock logout
      superblock status | whoami
      superblock doctor
      superblock config set <key> <value> | config get <key> | config list
      superblock mount [mountpoint] [--verbose]
      superblock unmount [mountpoint]
      superblock refresh
      superblock help

  Exit codes: 0 ok · 1 usage error · 2 not authenticated · 3 API/network
  error · 4 environment error.
  """

  alias Superblock.{Auth, Config, Control, Credentials, Doctor, Fs, Paths, Signals}

  @usage """
  superblock — browse the Supabase Management API as a filesystem

  Usage:
    superblock login [--token sbp_...]   Authenticate with a personal access token
    superblock logout                    Delete the stored token
    superblock status                    Auth, mount and rate-limit overview
    superblock whoami                    Alias of status
    superblock doctor                    Check the environment for FUSE readiness
    superblock config set <key> <value>  Set a config key
    superblock config get <key>          Read a config key
    superblock config list               Show effective config
    superblock mount [mountpoint]        Mount (foreground; Ctrl-C unmounts)
    superblock unmount [mountpoint]      Unmount a running superblock
    superblock refresh                   Flush the cache of a mounted superblock
    superblock help                      This help

  Config keys: #{Enum.join(Superblock.Config.valid_keys(), ", ")}
  """

  @doc "Release entry point: run and halt with the exit code."
  def main(argv \\ nil) do
    argv
    |> resolve_argv()
    |> run()
    |> System.halt()
  end

  # `release eval` does not always deliver argv; the launcher also passes the
  # args via SUPERBLOCK_ARGV (unit-separator joined) as a fallback.
  defp resolve_argv(argv) when is_list(argv) and argv != [], do: argv

  defp resolve_argv(_empty) do
    case System.argv() do
      [] ->
        case System.get_env("SUPERBLOCK_ARGV") do
          nil -> []
          joined -> String.split(joined, "\x1f", trim: true)
        end

      argv ->
        argv
    end
  end

  @doc "Run a command; returns the exit code (no halt — testable)."
  @spec run([String.t()]) :: non_neg_integer
  def run(argv) do
    # `release eval` boots a clean node: the :superblock application (cache
    # tables and all) is not started until we ask.
    {:ok, _apps} = Application.ensure_all_started(:superblock)

    case argv do
      [] -> help()
      ["help" | _rest] -> help()
      ["-h" | _rest] -> help()
      ["--help" | _rest] -> help()
      ["login" | rest] -> login(rest)
      ["logout" | _rest] -> logout()
      ["status" | _rest] -> status()
      ["whoami" | _rest] -> status()
      ["doctor" | _rest] -> doctor()
      ["config" | rest] -> config(rest)
      ["mount" | rest] -> mount(rest)
      ["unmount" | rest] -> unmount(rest)
      ["refresh" | _rest] -> refresh()
      [unknown | _rest] -> usage_error("Unknown command: #{unknown}")
    end
  end

  defp help do
    IO.puts(@usage)
    0
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "Run: superblock help")
    1
  end

  ## login / logout

  defp login(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [token: :string])

    token =
      case opts[:token] do
        nil -> prompt_token()
        token -> token
      end

    case token do
      nil ->
        usage_error("No token given.")

      token ->
        token = String.trim(token)

        case Auth.validate(token) do
          {:ok, org_count} ->
            :ok = Credentials.store(token)
            IO.puts("✓ Token valid — authenticated, #{org_count} organizations found.")
            IO.puts("  Stored in #{Paths.credentials_file()} (mode 0600).")
            0

          {:error, :unauthorized} ->
            IO.puts(
              :stderr,
              "Token rejected — check it at app.supabase.com → Account → Access Tokens"
            )

            2

          {:error, reason} ->
            IO.puts(:stderr, "Could not reach the Supabase API: #{describe_error(reason)}")
            IO.puts(:stderr, "Check your network and try again.")
            3
        end
    end
  end

  defp prompt_token do
    prompt = "Paste your Supabase personal access token (sbp_...): "

    case hidden_input(prompt) do
      "" -> nil
      token -> token
    end
  end

  defp hidden_input(prompt) do
    IO.write(prompt)

    input =
      try do
        case :io.get_password() do
          data when is_list(data) or is_binary(data) -> to_string(data)
          _other -> stty_input()
        end
      rescue
        _any -> stty_input()
      catch
        _kind, _reason -> stty_input()
      end

    IO.write("\n")
    String.trim(input)
  end

  defp stty_input do
    System.cmd("stty", ["-echo"], stderr_to_stdout: true)

    try do
      case IO.gets("") do
        :eof -> ""
        {:error, _reason} -> ""
        line -> to_string(line)
      end
    after
      System.cmd("stty", ["echo"], stderr_to_stdout: true)
    end
  end

  defp logout do
    Credentials.delete()
    IO.puts("Logged out.")
    0
  end

  ## status

  defp status do
    case Credentials.load() do
      :missing ->
        IO.puts("Not authenticated. Run: superblock login")
        2

      {:ok, _token} ->
        IO.puts("Authenticated: token #{Credentials.masked()}")

        code =
          case Auth.validate() do
            {:ok, org_count} ->
              IO.puts("Organizations: #{org_count}")
              0

            {:error, :unauthorized} ->
              IO.puts("Token no longer valid — run: superblock login")
              2

            {:error, reason} ->
              IO.puts("API unreachable: #{describe_error(reason)}")
              3
          end

        print_mount_status()
        print_ratelimits()
        code
    end
  end

  defp print_mount_status do
    if File.exists?(Paths.control_socket()) do
      mountpoint =
        case File.read(Paths.mount_info_file()) do
          {:ok, body} -> String.trim(body)
          {:error, _reason} -> "(unknown)"
        end

      IO.puts("Mounted: yes, at #{mountpoint}")
    else
      IO.puts("Mounted: no")
    end
  end

  defp print_ratelimits do
    case Superblock.Client.ratelimits() do
      [] ->
        :ok

      limits ->
        IO.puts("Rate limits (last seen):")

        Enum.each(limits, fn {scope, remaining, _reset} ->
          IO.puts("  #{scope}: #{remaining} remaining")
        end)
    end
  end

  ## doctor

  defp doctor do
    results = Doctor.run()

    Enum.each(results, fn
      {name, :ok} -> IO.puts("✓ #{name}")
      {name, {:error, fix}} -> IO.puts("✗ #{name}\n  fix: #{fix}")
    end)

    if Enum.any?(results, &match?({_name, {:error, _fix}}, &1)), do: 4, else: 0
  end

  ## config

  defp config(["set", key, value]) do
    case Config.set(key, value) do
      :ok ->
        IO.puts("#{key} = #{value}")
        0

      {:error, message} ->
        IO.puts(:stderr, message)
        1
    end
  end

  defp config(["get", key]) do
    if key in Config.valid_keys() do
      IO.puts(format_value(Config.get(key)))
      0
    else
      usage_error("Unknown key: #{key}. Valid keys: #{Enum.join(Config.valid_keys(), ", ")}")
    end
  end

  defp config(["list"]) do
    Enum.each(Config.valid_keys(), fn key ->
      IO.puts("#{key} = #{format_value(Config.get(key))}")
    end)

    0
  end

  defp config(_other) do
    usage_error("Usage: superblock config set <key> <value> | get <key> | list")
  end

  defp format_value(nil), do: "(unset)"
  defp format_value(value), do: to_string(value)

  ## mount / unmount / refresh

  defp mount(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [verbose: :boolean])

    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    with {:ok, mountpoint} <- resolve_mountpoint(rest),
         :authed <- require_auth() do
      attach_file_logger()
      Signals.install()

      case Fs.mount(mountpoint) do
        :ok ->
          IO.puts("Mounted at #{mountpoint}. Ctrl-C to unmount.")
          Process.sleep(:infinity)
          0

        {:error, reason} ->
          IO.puts(:stderr, "Mount failed: #{inspect(reason)}")
          IO.puts(:stderr, "Run: superblock doctor")
          4
      end
    else
      {:exit, code} -> code
    end
  end

  defp resolve_mountpoint(args) do
    case args do
      [mountpoint | _rest] ->
        {:ok, mountpoint}

      [] ->
        case Config.get("mountpoint") do
          mountpoint when is_binary(mountpoint) and mountpoint != "" ->
            {:ok, mountpoint}

          _unset ->
            IO.puts(
              :stderr,
              "No mountpoint. Pass one or run: superblock config set mountpoint /mnt/supabase"
            )

            {:exit, 1}
        end
    end
  end

  # Mirror the mount's log output into <state_dir>/superblock.log using the
  # built-in OTP handler. Everything logged is already token-scrubbed (see
  # Superblock.Client.redact/2).
  defp attach_file_logger do
    Paths.ensure!()

    :logger.add_handler(:superblock_file_log, :logger_std_h, %{
      config: %{file: String.to_charlist(Paths.log_file())},
      formatter: Logger.Formatter.new()
    })

    :ok
  rescue
    _any -> :ok
  end

  defp require_auth do
    case Credentials.load() do
      {:ok, _token} ->
        :authed

      :missing ->
        IO.puts(:stderr, "Not authenticated. Run: superblock login")
        {:exit, 2}
    end
  end

  defp unmount(args) do
    mountpoint =
      case args do
        [mountpoint | _rest] ->
          mountpoint

        [] ->
          case File.read(Paths.mount_info_file()) do
            {:ok, body} -> String.trim(body)
            {:error, _reason} -> Config.get("mountpoint")
          end
      end

    case Control.send_cmd("unmount") do
      {:ok, "ok"} ->
        wait_for_shutdown()
        File.rm(Paths.mount_info_file())
        IO.puts("Unmounted #{mountpoint || ""}." |> String.replace(" .", "."))
        0

      _no_socket ->
        case mountpoint do
          nil ->
            IO.puts(:stderr, "Not mounted.")
            1

          mountpoint ->
            Fs.recover_stale_mount(mountpoint)
            File.rm(Paths.mount_info_file())
            IO.puts("Unmounted #{mountpoint}.")
            0
        end
    end
  end

  defp wait_for_shutdown do
    Enum.find(1..50, fn _attempt ->
      if File.exists?(Paths.control_socket()) do
        Process.sleep(100)
        false
      else
        true
      end
    end)

    :ok
  end

  defp refresh do
    case Control.send_cmd("flush") do
      {:ok, "ok"} ->
        IO.puts("Cache flushed.")
        0

      _other ->
        IO.puts(:stderr, "Not mounted.")
        1
    end
  end

  defp describe_error(:timeout), do: "request timed out"
  defp describe_error(:rate_limited), do: "rate limited (429) — wait a moment and retry"
  defp describe_error(:forbidden), do: "access denied (403)"
  defp describe_error({:http, status}), do: "unexpected HTTP #{status}"
  defp describe_error({:transport, reason}), do: "network error (#{inspect(reason)})"
  defp describe_error(other), do: inspect(other)
end
