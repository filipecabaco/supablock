defmodule Superblock.CLI do
  @moduledoc """
  Command-line entry point.

      superblock login [--token sbp_...] [--no-browser]
      superblock logout
      superblock status | whoami
      superblock doctor
      superblock config set <key> <value> | config get <key> | config list
      superblock mount [--path <dir>] [dir] [--foreground] [--verbose]
      superblock unmount [mountpoint]
      superblock refresh [--check]
      superblock help

  Exit codes: 0 ok · 1 usage error · 2 not authenticated · 3 API/network
  error · 4 environment error.
  """

  alias Superblock.{
    Auth,
    AuthCallback,
    BrowserLogin,
    Config,
    Control,
    Credentials,
    Doctor,
    Fs,
    OAuth,
    Paths,
    Profile,
    Service,
    Signals
  }

  @usage """
  superblock — browse the Supabase Management API as a filesystem

  Usage:
    superblock setup [profile]           One-command onboarding: apply a team profile
                                         (URL or file), log in, offer auto-start
    superblock login                     Browser login: OAuth2 + PKCE when an OAuth app
                                         is configured, dashboard session flow otherwise
    superblock login --token sbp_...     Authenticate with a personal access token
    superblock login --no-browser        Print the login URL instead of opening it
    superblock logout                    Delete (and revoke) the stored credential
    superblock status                    Auth, mount and rate-limit overview
    superblock whoami                    Alias of status
    superblock doctor                    Check the environment for FUSE readiness
    superblock config set <key> <value>  Set a config key
    superblock config get <key>          Read a config key
    superblock config list               Show effective config
    superblock mount [--path <dir>] [dir]  Mount in background and return (default ~/Supabase)
    superblock mount --foreground [dir]    Mount in foreground (blocks; Ctrl-C unmounts)
    superblock unmount [mountpoint]        Unmount a running superblock
    superblock refresh                   Flush the cache of a mounted superblock
    superblock refresh --check           Report cache staleness without flushing
    superblock service install           Auto-start the mount at login (systemd/launchd)
    superblock service uninstall         Remove the auto-start service
    superblock service status            Show the auto-start service state
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
      ["setup" | rest] -> setup(rest)
      ["login" | rest] -> login(rest)
      ["logout" | _rest] -> logout()
      ["status" | _rest] -> status()
      ["whoami" | _rest] -> status()
      ["doctor" | _rest] -> doctor()
      ["config" | rest] -> config(rest)
      ["mount" | rest] -> mount(rest)
      ["unmount" | rest] -> unmount(rest)
      ["refresh" | rest] -> refresh(rest)
      ["service" | rest] -> service(rest)
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
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [token: :string, no_browser: :boolean])

    run_login(opts)
  end

  defp run_login(opts) do
    no_browser? = opts[:no_browser] || false

    cond do
      is_binary(opts[:token]) ->
        validate_and_store(String.trim(opts[:token]))

      OAuth.configured?() ->
        oauth_login(no_browser?)

      true ->
        IO.puts("No OAuth app configured (oauth.client_id) — using the dashboard session flow.")
        browser_login(no_browser?)
    end
  end

  ## setup (one-command onboarding)

  # Apply a shared team profile, make sure the user is logged in, offer the
  # auto-start service. Everything is idempotent — rerunning is safe.
  defp setup(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [service: :boolean, no_browser: :boolean, token: :string]
      )

    case apply_profile(List.first(rest)) do
      :ok ->
        case ensure_authenticated(opts) do
          0 ->
            maybe_install_service(opts[:service])
            IO.puts("")
            IO.puts("All set. Mount with: superblock mount   (default: #{Config.mountpoint()})")
            0

          code ->
            code
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        1
    end
  end

  defp apply_profile(nil), do: :ok

  defp apply_profile(source) do
    IO.puts("Applying team profile from #{source} …")

    with {:ok, profile} <- Profile.fetch(source),
         {:ok, applied, skipped} <- Profile.apply(profile) do
      Enum.each(applied, fn key -> IO.puts("  #{key} = #{display_config_value(key)}") end)
      Enum.each(skipped, fn key -> IO.puts("  skipped unknown key: #{key}") end)
      :ok
    end
  end

  # never echo the app secret back
  defp display_config_value("oauth.client_secret"), do: "(set)"
  defp display_config_value(key), do: format_value(Config.get(key))

  defp ensure_authenticated(opts) do
    case Credentials.load() do
      :missing ->
        run_login(opts)

      {:ok, _token} ->
        case Auth.validate() do
          {:ok, org_count} ->
            IO.puts("Already authenticated — #{org_count} organizations found.")
            0

          {:error, :unauthorized} ->
            IO.puts("Stored credential no longer valid — logging in again.")
            run_login(opts)

          {:error, reason} ->
            # a network hiccup is not a reason to redo the login
            IO.puts(:stderr, "Could not verify authentication: #{describe_error(reason)}")
            3
        end
    end
  end

  defp maybe_install_service(false), do: :ok
  defp maybe_install_service(true), do: install_service_quietly()

  defp maybe_install_service(nil) do
    case IO.gets("Install the auto-start service (mounts at login)? [y/N] ") do
      line when is_binary(line) ->
        if String.downcase(String.trim(line)) in ["y", "yes"] do
          install_service_quietly()
        else
          :ok
        end

      _eof ->
        :ok
    end
  end

  # setup should not fail as a whole when only the service step does
  defp install_service_quietly do
    case Service.install() do
      {:ok, messages} -> Enum.each(messages, &IO.puts("  " <> &1))
      {:error, message} -> IO.puts(:stderr, "  service install failed: #{message}")
    end

    :ok
  end

  # The documented OAuth2 flow (PKCE S256 + state, loopback callback):
  # tokens come back short-lived, scoped to what the app registration
  # allows, and refresh automatically. See Superblock.OAuth.
  defp oauth_login(no_browser?) do
    request = OAuth.new_request()

    case AuthCallback.start_listener(self()) do
      {:ok, listener} ->
        try do
          IO.puts("Open this link in your browser to authorize superblock:\n")
          IO.puts("  #{request.url}\n")

          unless no_browser? do
            BrowserLogin.open_browser(request.url)
          end

          IO.puts("Waiting for the callback on #{request.redirect_uri} …")
          await_oauth_callback(request)
        after
          AuthCallback.stop_listener(listener)
        end

      {:error, :port_in_use} ->
        IO.puts(
          :stderr,
          "Port #{OAuth.callback_port()} is in use — close whatever holds it, " <>
            "or use: superblock login --token sbp_..."
        )

        4

      {:error, reason} ->
        IO.puts(:stderr, "Could not start the callback server: #{inspect(reason)}")
        4
    end
  end

  defp await_oauth_callback(request) do
    receive do
      {:oauth_callback, %{"error" => error} = params} ->
        description = params["error_description"] || error
        IO.puts(:stderr, "Authorization was not granted: #{description}")
        2

      {:oauth_callback, %{"code" => code, "state" => state}} when is_binary(code) ->
        if Plug.Crypto.secure_compare(state || "", request.state) do
          finish_oauth_login(request, code)
        else
          IO.puts(:stderr, "State mismatch on the OAuth callback — try again.")
          2
        end

      {:oauth_callback, _params} ->
        IO.puts(:stderr, "Malformed OAuth callback — try again.")
        2
    after
      180_000 ->
        IO.puts(:stderr, "No authorization within 3 minutes. Run: superblock login")
        2
    end
  end

  defp finish_oauth_login(request, code) do
    with {:ok, tokens} <- OAuth.exchange_code(request, code),
         {:ok, org_count} <- Auth.validate(tokens.access_token),
         :ok <-
           Credentials.store_oauth(tokens.access_token, tokens.refresh_token, tokens.expires_at) do
      IO.puts("✓ Logged in via OAuth — authenticated, #{org_count} organizations found.")
      IO.puts("  Stored in #{Paths.credentials_file()} (mode 0600).")
      IO.puts("  Tokens are short-lived and refresh automatically.")
      0
    else
      {:error, :unauthorized} ->
        IO.puts(
          :stderr,
          "Token exchange rejected — check oauth.client_id / oauth.client_secret."
        )

        2

      {:error, reason} ->
        IO.puts(:stderr, "OAuth login failed: #{describe_error(reason)}")
        3
    end
  end

  # Replicates the official supabase CLI: dashboard session + verification
  # code + end-to-end-encrypted token delivery (see Superblock.BrowserLogin).
  defp browser_login(no_browser?) do
    session = BrowserLogin.new_session()

    IO.puts("Here is your login link, open it in the browser:\n")
    IO.puts("  #{session.url}\n")

    unless no_browser? do
      BrowserLogin.open_browser(session.url)
    end

    prompt_code_and_fetch(session, 3)
  end

  defp prompt_code_and_fetch(_session, 0) do
    IO.puts(:stderr, "Too many failed attempts. Run: superblock login")
    2
  end

  defp prompt_code_and_fetch(session, attempts_left) do
    case IO.gets("Enter your verification code: ") do
      :eof ->
        IO.puts(:stderr, "No verification code given.")
        2

      {:error, _reason} ->
        IO.puts(:stderr, "Could not read the verification code.")
        2

      line ->
        code = String.trim(to_string(line))

        case code_to_token(session, code) do
          {:ok, token} ->
            validate_and_store(token)

          {:error, reason} ->
            IO.puts(:stderr, "Verification failed: #{describe_error(reason)}")
            prompt_code_and_fetch(session, attempts_left - 1)
        end
    end
  end

  defp code_to_token(_session, ""), do: {:error, :empty_code}
  defp code_to_token(session, code), do: BrowserLogin.fetch_token(session, code)

  defp validate_and_store(token) do
    case Auth.validate(token) do
      {:ok, org_count} ->
        :ok = Credentials.store(token)
        IO.puts("✓ Token valid — authenticated, #{org_count} organizations found.")
        IO.puts("  Stored in #{Paths.credentials_file()} (mode 0600).")
        0

      {:error, :unauthorized} ->
        IO.puts(
          :stderr,
          "Token rejected — check it at supabase.com/dashboard/account/tokens"
        )

        2

      {:error, reason} ->
        IO.puts(:stderr, "Could not reach the Supabase API: #{describe_error(reason)}")
        IO.puts(:stderr, "Check your network and try again.")
        3
    end
  end

  defp logout do
    # For an OAuth credential, also revoke the grant server-side (best
    # effort — the local delete is what logs this machine out either way).
    case Credentials.load_credential() do
      {:ok, %Credentials.Credential{type: :oauth, refresh_token: refresh}}
      when is_binary(refresh) ->
        case OAuth.revoke(refresh) do
          :ok -> IO.puts("Revoked the OAuth authorization.")
          {:error, _reason} -> IO.puts("Could not revoke server-side; deleted locally.")
        end

      _other ->
        :ok
    end

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
    {opts, rest, _invalid} =
      OptionParser.parse(args, strict: [verbose: :boolean, foreground: :boolean, path: :string])

    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    with :authed <- require_auth(),
         {:ok, mountpoint} <- resolve_mountpoint(opts, rest) do
      if opts[:foreground] do
        mount_foreground(mountpoint)
      else
        mount_daemon(mountpoint, opts)
      end
    else
      {:exit, code} -> code
    end
  end

  defp mount_foreground(mountpoint) do
    attach_file_logger()
    Signals.install()

    case Fs.mount(mountpoint) do
      :ok ->
        IO.puts("Mounted at #{mountpoint}. Ctrl-C to unmount.")
        IO.puts("Log: #{Paths.log_file()}")
        Process.sleep(:infinity)
        0

      {:error, reason} ->
        IO.puts(:stderr, "Mount failed: #{inspect(reason)}")
        IO.puts(:stderr, "Run: superblock doctor")
        4
    end
  end

  # Spawn a background process running `mount --foreground` and return
  # immediately. The orphaned child is reparented to init by the OS.
  defp mount_daemon(mountpoint, opts) do
    case find_self() do
      {:ok, bin} ->
        Paths.ensure!()
        log = Paths.log_file()
        verbose = if opts[:verbose], do: ["--verbose"], else: []
        argv = [bin, "mount", "--foreground"] ++ verbose ++ [mountpoint]
        cmd = Enum.map_join(argv, " ", &sh_escape/1) <> " >> " <> sh_escape(log) <> " 2>&1 &"
        System.cmd("sh", ["-c", cmd])
        IO.puts("Mounting at #{mountpoint} (background).")
        IO.puts("Log: #{log}")
        IO.puts("Check status: superblock status")
        0

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.puts(:stderr, "Hint: superblock mount --foreground #{mountpoint}")
        4
    end
  end

  # Resolution order: --path flag > positional arg > config value > ~/Supabase.
  defp resolve_mountpoint(opts, args) do
    mountpoint = opts[:path] || List.first(args) || Config.mountpoint()
    # Best effort: a stale mount makes mkdir_p fail, and Fs.mount both
    # recovers stale mounts and reports real errors with a doctor hint.
    _ = File.mkdir_p(mountpoint)
    {:ok, mountpoint}
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

  defp find_self do
    candidates = [
      System.get_env("__BURRITO_BIN_PATH"),
      System.get_env("SUPERBLOCK_BIN"),
      System.find_executable("superblock")
    ]

    case Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) do
      nil ->
        {:error,
         "cannot determine the superblock binary path — " <>
           "set SUPERBLOCK_BIN or use: superblock mount --foreground"}

      bin ->
        {:ok, Path.expand(bin)}
    end
  end

  defp sh_escape(str) do
    "'" <> String.replace(str, "'", ~s|'\\''|) <> "'"
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

  ## service (auto-start)

  defp service(["install"]) do
    case Service.install() do
      {:ok, messages} ->
        Enum.each(messages, &IO.puts/1)
        0

      {:error, message} ->
        IO.puts(:stderr, message)
        1
    end
  end

  defp service(["uninstall"]) do
    {:ok, messages} = Service.uninstall()
    Enum.each(messages, &IO.puts/1)
    0
  end

  defp service(["status"]) do
    case Service.status() do
      {:installed, path, state} ->
        IO.puts("Service installed: #{path}")
        IO.puts("State: #{state}")
        0

      :not_installed ->
        IO.puts("Service not installed. Run: superblock service install")
        1
    end
  end

  defp service(_other) do
    usage_error("Usage: superblock service install | uninstall | status")
  end

  defp refresh(["--check" | _rest]), do: refresh_check()
  defp refresh(["check" | _rest]), do: refresh_check()

  defp refresh(_flush) do
    case Control.send_cmd("flush") do
      {:ok, "ok"} ->
        IO.puts("Cache flushed.")
        0

      _other ->
        IO.puts(:stderr, "Not mounted.")
        1
    end
  end

  defp refresh_check do
    case Control.send_cmd("check") do
      {:ok, "ok " <> stats} ->
        {entries, stale} = parse_check(stats)
        IO.puts("Cache: #{entries} entries, #{stale} stale (past TTL).")

        if stale > 0 do
          IO.puts("Stale data present — run: superblock refresh")
        else
          IO.puts("Cache is fresh — no refresh needed.")
        end

        0

      _not_mounted ->
        IO.puts("Not mounted — nothing is cached.")
        0
    end
  end

  defp parse_check(stats) do
    fields =
      stats
      |> String.split(" ", trim: true)
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    {to_int(fields["entries"]), to_int(fields["stale"])}
  end

  defp to_int(value) do
    case Integer.parse(value || "") do
      {n, _rest} -> n
      :error -> 0
    end
  end

  defp describe_error(:empty_code), do: "no code entered — copy it from the browser page"
  defp describe_error(:not_found), do: "code not recognized — check it and try again"
  defp describe_error(:decrypt_failed), do: "could not decrypt the token — restart the login"
  defp describe_error(:unexpected_response), do: "unexpected API response — try again"
  defp describe_error(:timeout), do: "request timed out"
  defp describe_error(:rate_limited), do: "rate limited (429) — wait a moment and retry"
  defp describe_error(:forbidden), do: "access denied (403)"
  defp describe_error({:http, status}), do: "unexpected HTTP #{status}"
  defp describe_error({:transport, reason}), do: "network error (#{inspect(reason)})"
  defp describe_error(other), do: inspect(other)
end
