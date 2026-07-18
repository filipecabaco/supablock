defmodule Supablock.CLI do
  @moduledoc """
  Command-line entry point.

      supablock login [--token sbp_...] [--no-browser]
      supablock logout
      supablock status | whoami
      supablock doctor
      supablock config set <key> <value> | config get <key> | config list
      supablock mount [--path <dir>] [dir] [--foreground] [--verbose]
      supablock unmount [mountpoint]
      supablock ls [path]
      supablock cat [-0] <path|-> [path...]
      supablock head|tail [-n <count>] <path> [path...]
      supablock find [path] [-type f|d] [-name <glob>] [-maxdepth <n>] [-print0]
      supablock grep [-iln] [--maxdepth <n>] <pattern> [path...]
      supablock serve [stop]
      supablock refresh [--check]
      supablock help

  Exit codes: 0 ok · 1 usage error · 2 not authenticated · 3 API/network
  error · 4 environment error · 141 downstream pipe closed (128+SIGPIPE,
  coreutils-style).
  """

  alias Supablock.{
    Auth,
    AuthCallback,
    BrowserLogin,
    Config,
    Control,
    Credentials,
    Doctor,
    Fs,
    Logs,
    OAuth,
    Paths,
    Profile,
    Service,
    Signals,
    Snapshot,
    Tree,
    Walk
  }

  @usage """
  supablock — browse the Supabase Management API as a filesystem

  Usage:
    supablock setup [profile]           One-command onboarding: apply a team profile
                                         (URL or file), log in, offer auto-start
    supablock login                     Browser login: OAuth2 + PKCE when an OAuth app
                                         is configured, dashboard session flow otherwise
    supablock login --token sbp_...     Authenticate with a personal access token
    supablock login --no-browser        Print the login URL instead of opening it
    supablock logout                    Delete (and revoke) the stored credential
    supablock status [--json]           Auth, mount and rate-limit overview
    supablock whoami                    Alias of status
    supablock doctor                    Check the environment for FUSE readiness
    supablock config set <key> <value>  Set a config key
    supablock config get <key>          Read a config key
    supablock config list               Show effective config
    supablock mount [--path <dir>] [dir]  Mount in background and return (default ~/Supabase)
    supablock mount --foreground [dir]    Mount in foreground (blocks; Ctrl-C unmounts)
    supablock unmount [mountpoint]        Unmount a running supablock
    supablock ls [path]                 List a tree directory straight off the API (no mount)
    supablock cat <path> [path...]      Print tree file(s) straight off the API (no mount)
                                        "-" reads paths from stdin (find … | cat -);
                                        -0 makes stdin NUL-delimited (find -print0)
    supablock head <path> [path...]     First lines of tree file(s); -n <count>, default 10
    supablock tail <path> [path...]     Last lines of tree file(s); -n <count>, default 10
                                        -f streams new entries; -s <secs> sets the poll
                                        interval (default 30s). Works on log file paths.
    supablock find [path]               Walk the tree, print each path (no mount)
                                        Filters: -type f|d, -name <glob>, -maxdepth <n>;
                                        -print0 for NUL-delimited output
    supablock grep <pattern> [path...]  Search file contents (no mount); directories
                                        recurse. -i ignore case, -l paths only,
                                        -n line numbers, --maxdepth <n>.
                                        Exits 1 when nothing matches, like grep(1)
    supablock snapshot <dir> [path]     Write the tree to a real directory. Skips logs,
                                        metrics, database rows and function bodies
                                        unless --all; --prune deletes snapshot files
                                        that no longer exist in the tree
    supablock diff <dir> [path]         Compare the live tree against a snapshot dir:
                                        unified diffs for changed files (--brief for
                                        names only), --all as in snapshot. Exits 0 when
                                        identical, 1 on differences, 2 on errors
    supablock mcp                       Serve the tree as an MCP server on stdio
                                        (tools: ls, cat, find, grep) for AI clients
    supablock serve                     Serve a shared warm cache for ls/cat/find/grep
                                        (no FUSE needed; stop with: supablock serve stop)
    supablock refresh                   Flush the cache of a mounted supablock
    supablock refresh --check           Report cache staleness without flushing
    supablock completions <shell>       Completion script for bash, zsh or fish
                                        (bash/zsh: eval "$(supablock completions bash)")
    supablock service install           Auto-start the mount at login (systemd/launchd)
    supablock service uninstall         Remove the auto-start service
    supablock service status            Show the auto-start service state
    supablock help                      This help

  Config keys: #{Enum.join(Supablock.Config.valid_keys(), ", ")}
  """

  @doc "Release entry point: run and halt with the exit code."
  def main(argv \\ nil) do
    argv
    |> resolve_argv()
    |> run()
    |> System.halt()
  end

  # `release eval` does not always deliver argv; the launcher also passes the
  # args via SUPABLOCK_ARGV (unit-separator joined) as a fallback.
  defp resolve_argv(argv) when is_list(argv) and argv != [], do: argv

  defp resolve_argv(_empty) do
    case System.argv() do
      [] ->
        case System.get_env("SUPABLOCK_ARGV") do
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
    # `release eval` boots a clean node: the :supablock application (cache
    # tables and all) is not started until we ask.
    {:ok, _apps} = Application.ensure_all_started(:supablock)
    stdio_opts = :io.getopts(:standard_io)

    try do
      dispatch(argv)
    catch
      # The downstream reader closed the pipe (supablock cat … | head -1).
      # Coreutils die of SIGPIPE here; mirror that as a quiet 128+SIGPIPE.
      :epipe -> 141
    after
      # Undo raw_stdout!/0: on OTP 26+ the io server behind stdout can be
      # shared with other standard devices, so a leaked latin1 flip would
      # outlive the command (in tests, it bled into ExUnit's captures).
      restore_stdio(stdio_opts)
    end
  end

  defp restore_stdio(opts) when is_list(opts) do
    case List.keyfind(opts, :encoding, 0) do
      {:encoding, encoding} -> _ = :io.setopts(:standard_io, encoding: encoding)
      nil -> :ok
    end

    :ok
  end

  defp restore_stdio(_error), do: :ok

  defp dispatch(argv) do
    case argv do
      [] -> help()
      ["help" | _rest] -> help()
      ["-h" | _rest] -> help()
      ["--help" | _rest] -> help()
      ["setup" | rest] -> setup(rest)
      ["login" | rest] -> login(rest)
      ["logout" | _rest] -> logout()
      ["status" | rest] -> status(rest)
      ["whoami" | rest] -> status(rest)
      ["doctor" | _rest] -> doctor()
      ["config" | rest] -> config(rest)
      ["mount" | rest] -> mount(rest)
      ["unmount" | rest] -> unmount(rest)
      ["ls" | rest] -> ls(rest)
      ["cat" | rest] -> cat(rest)
      ["head" | rest] -> head_tail(:head, rest)
      ["tail" | rest] -> head_tail(:tail, rest)
      ["find" | rest] -> find(rest)
      ["grep" | rest] -> grep(rest)
      ["snapshot" | rest] -> snapshot(rest)
      ["diff" | rest] -> diff_cmd(rest)
      ["mcp" | _rest] -> mcp()
      ["completions" | rest] -> completions(rest)
      ["serve" | rest] -> serve(rest)
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
    IO.puts(:stderr, "Run: supablock help")
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
            IO.puts("All set. Mount with: supablock mount   (default: #{Config.mountpoint()})")
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
  # allows, and refresh automatically. See Supablock.OAuth.
  defp oauth_login(no_browser?) do
    request = OAuth.new_request()

    case AuthCallback.start_listener(self()) do
      {:ok, listener} ->
        try do
          IO.puts("Open this link in your browser to authorize supablock:\n")
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
            "or use: supablock login --token sbp_..."
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
        IO.puts(:stderr, "No authorization within 3 minutes. Run: supablock login")
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
  # code + end-to-end-encrypted token delivery (see Supablock.BrowserLogin).
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
    IO.puts(:stderr, "Too many failed attempts. Run: supablock login")
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

  defp status(args) do
    if "--json" in args, do: status_json(), else: status_text()
  end

  defp status_text do
    case Credentials.load() do
      :missing ->
        IO.puts("Not authenticated. Run: supablock login")
        2

      {:ok, _token} ->
        IO.puts("Authenticated: token #{Credentials.masked()}")

        code =
          case Auth.validate() do
            {:ok, org_count} ->
              IO.puts("Organizations: #{org_count}")
              0

            {:error, :unauthorized} ->
              IO.puts("Token no longer valid — run: supablock login")
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

  # The same facts as the text form, machine-readable (sorted keys, stable
  # rendering via Render.json). Exit codes match the text form.
  defp status_json do
    {code, fields} =
      case Credentials.load() do
        :missing ->
          {2, %{"authenticated" => false}}

        {:ok, _token} ->
          {code, auth_fields} =
            case Auth.validate() do
              {:ok, org_count} ->
                {0, %{"authenticated" => true, "organizations" => org_count}}

              {:error, :unauthorized} ->
                {2, %{"authenticated" => false, "error" => "token no longer valid"}}

              {:error, reason} ->
                {3, %{"authenticated" => false, "error" => describe_error(reason)}}
            end

          {code, Map.put(auth_fields, "token", Credentials.masked())}
      end

    {mounted?, mountpoint, daemon} = mount_state()

    rate_limits =
      for {scope, remaining, _reset} <- Supablock.Client.ratelimits() do
        %{"scope" => scope, "remaining" => remaining}
      end

    fields
    |> Map.merge(%{
      "mounted" => mounted?,
      "mountpoint" => mountpoint,
      "daemon" => daemon,
      "rate_limits" => rate_limits
    })
    |> Supablock.Render.json()
    |> IO.write()

    code
  end

  defp mount_state do
    cond do
      not File.exists?(Paths.control_socket()) ->
        {false, nil, "none"}

      File.exists?(Paths.mount_info_file()) ->
        mountpoint =
          case File.read(Paths.mount_info_file()) do
            {:ok, body} -> String.trim(body)
            {:error, _reason} -> nil
          end

        {true, mountpoint, "mount"}

      true ->
        # A control socket without a mountpoint on record: supablock serve.
        {false, nil, "serve"}
    end
  end

  defp print_mount_status do
    case mount_state() do
      {true, mountpoint, _daemon} -> IO.puts("Mounted: yes, at #{mountpoint || "(unknown)"}")
      {false, _mp, "serve"} -> IO.puts("Mounted: no (cache daemon running — supablock serve)")
      {false, _mp, _daemon} -> IO.puts("Mounted: no")
    end
  end

  defp print_ratelimits do
    case Supablock.Client.ratelimits() do
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
    usage_error("Usage: supablock config set <key> <value> | get <key> | list")
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
        IO.puts(:stderr, "Run: supablock doctor")
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
        IO.puts("Check status: supablock status")
        0

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.puts(:stderr, "Hint: supablock mount --foreground #{mountpoint}")
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

  # Mirror the mount's log output into <state_dir>/supablock.log using the
  # built-in OTP handler. Everything logged is already token-scrubbed (see
  # Supablock.Client.redact/2).
  defp attach_file_logger do
    Paths.ensure!()

    :logger.add_handler(:supablock_file_log, :logger_std_h, %{
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
      System.get_env("SUPABLOCK_BIN"),
      System.find_executable("supablock")
    ]

    case Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) do
      nil ->
        {:error,
         "cannot determine the supablock binary path — " <>
           "set SUPABLOCK_BIN or use: supablock mount --foreground"}

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
        IO.puts(:stderr, "Not authenticated. Run: supablock login")
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

  ## ls / cat — the tree without a mount
  #
  # The same paths the FUSE tree serves, resolved by the same Router, read
  # straight off the API. This is the path for environments that cannot
  # mount at all — containers without /dev/fuse, CI, AI-agent sandboxes —
  # and it keeps every guarantee of the mount (GET-only, redaction,
  # deterministic rendering) because it *is* the same code.
  #
  # All tree output goes through out/out_bytes so pipelines behave like
  # coreutils: raw bytes (IO.puts raises on non-UTF-8 bodies), and a
  # vanished downstream reader ends the command quietly instead of
  # crashing (see the :epipe catch in run/1).

  defp out(line), do: out_bytes([line, ?\n])

  defp out_bytes(bytes) do
    case IO.binwrite(bytes) do
      :ok -> :ok
      # :terminated — stdout is gone because the reader closed the pipe.
      {:error, _reason} -> throw(:epipe)
    end
  rescue
    # Some OTP releases raise instead of returning the error tuple.
    ErlangError -> throw(:epipe)
  end

  # Tree output is bytes, not chardata. A unicode-mode stdout device (the
  # default under noshell since OTP 26, and whenever the launcher sets it)
  # re-encodes binwrite's latin1-typed bytes, double-encoding every UTF-8
  # body. Byte-oriented mode makes writes pass through verbatim.
  defp raw_stdout! do
    _ = :io.setopts(:standard_io, encoding: :latin1)
    :ok
  end

  defp ls(args) do
    with :authed <- require_auth() do
      raw_stdout!()
      path = tree_path(List.first(args) || "/")

      case Tree.kind(path) do
        {:ok, :dir} ->
          case Tree.list(path) do
            {:ok, entries} ->
              Enum.each(entries, &out/1)
              0

            {:error, reason} ->
              path_error(path, reason)
          end

        {:ok, :file} ->
          out(Path.basename(path))
          0

        {:error, reason} ->
          path_error(path, reason)
      end
    else
      {:exit, code} -> code
    end
  end

  defp cat(args) do
    {null_flags, paths} = Enum.split_with(args, &(&1 in ["-0", "--null"]))
    null? = null_flags != []

    case paths do
      [] ->
        usage_error("Usage: supablock cat [-0] <path|-> [path...]")

      paths ->
        with :authed <- require_auth() do
          raw_stdout!()

          paths
          |> expand_stdin_paths(null?)
          |> Enum.reduce_while(0, fn path, _ok ->
            case cat_one(tree_path(path)) do
              :ok -> {:cont, 0}
              {:error, code} -> {:halt, code}
            end
          end)
        else
          {:exit, code} -> code
        end
    end
  end

  # "-" pulls paths from stdin, so discovery pipes into reading with one
  # warm process on the reading side: supablock find … -type f | supablock
  # cat -. Line-delimited stdin is consumed lazily (each path is read as it
  # arrives); -0 pairs with find -print0 for names with spaces or newlines.
  defp expand_stdin_paths(paths, null?) do
    Stream.flat_map(paths, fn
      "-" -> stdin_paths(null?)
      path -> [path]
    end)
  end

  defp stdin_paths(false) do
    IO.stream(:stdio, :line)
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == ""))
  end

  defp stdin_paths(true) do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> String.split(data, <<0>>, trim: true)
      _eof_or_error -> []
    end
  end

  defp cat_one(path) do
    case Tree.read(path) do
      {:ok, body} ->
        out_bytes(body)
        :ok

      {:error, :eio} ->
        # Router says :eio both for "that's a directory" and for real API
        # trouble; kind (resolution only, no render) tells them apart.
        case Tree.kind(path) do
          {:ok, :dir} ->
            err("Is a directory: #{path}")
            {:error, 1}

          _not_a_dir ->
            {:error, path_error(path, :eio)}
        end

      {:error, reason} ->
        {:error, path_error(path, reason)}
    end
  end

  ## head / tail — partial reads (know a rows file before catting all of it)

  defp head_tail(mode, args) do
    with :authed <- require_auth(),
         {:ok, count, paths, follow_opts} <- parse_head_tail(mode, args) do
      raw_stdout!()

      cond do
        follow_opts != nil and mode != :tail ->
          usage_error("tail: -f is only supported for tail")

        follow_opts != nil and length(paths) != 1 ->
          usage_error("tail: -f requires exactly one path")

        follow_opts != nil ->
          [path] = paths

          case tail_follow(tree_path(path), count, follow_opts) do
            :ok -> 0
            {:error, code} -> code
          end

        true ->
          header? = length(paths) > 1

          paths
          |> Enum.with_index()
          |> Enum.reduce_while(0, fn {path, index}, _ok ->
            if header? do
              if index > 0, do: out("")
              out("==> #{path} <==")
            end

            case head_tail_one(mode, count, tree_path(path)) do
              :ok -> {:cont, 0}
              {:error, code} -> {:halt, code}
            end
          end)
      end
    else
      {:exit, code} -> code
      {:error, message} -> usage_error(message)
    end
  end

  defp head_tail_one(mode, count, path) do
    case Tree.read(path) do
      {:ok, body} ->
        lines = split_lines(body)

        shown =
          case mode do
            :head -> Enum.take(lines, count)
            :tail -> Enum.take(lines, -count)
          end

        Enum.each(shown, &out/1)
        :ok

      {:error, :eio} ->
        case Tree.kind(path) do
          {:ok, :dir} ->
            err("Is a directory: #{path}")
            {:error, 1}

          _not_a_dir ->
            {:error, path_error(path, :eio)}
        end

      {:error, reason} ->
        {:error, path_error(path, reason)}
    end
  end

  ## tail -f — follow a log file, polling for new entries

  defp tail_follow(path, count, follow_opts) do
    case Tree.read(path) do
      {:ok, body} ->
        lines = split_lines(body)
        Enum.each(Enum.take(lines, -count), &out/1)

        case parse_log_path(path) do
          {:ok, ref, source} ->
            # Fall back to now (microseconds) so the first poll only fetches
            # entries that arrive after we started watching.
            last_us = last_log_timestamp(body) || DateTime.to_unix(DateTime.utc_now(), :microsecond)
            tail_log_follow_loop(ref, source, follow_opts.interval, last_us)

          :error ->
            IO.puts(:stderr, "tail: -f is only supported for log file paths (.../logs/<source>)")
            {:error, 1}
        end

      {:error, :eio} ->
        case Tree.kind(path) do
          {:ok, :dir} ->
            err("Is a directory: #{path}")
            {:error, 1}

          _not_a_dir ->
            {:error, path_error(path, :eio)}
        end

      {:error, reason} ->
        {:error, path_error(path, reason)}
    end
  end

  defp tail_log_follow_loop(ref, source, interval, last_us) do
    Process.sleep(interval * 1_000)

    case Logs.fetch_since(ref, source, last_us) do
      {:ok, %{"result" => rows}} when is_list(rows) ->
        new_rows =
          Enum.filter(rows, fn r -> is_integer(r["timestamp"]) and r["timestamp"] > last_us end)

        Enum.each(new_rows, fn row -> out_bytes([Jason.encode!(row), "\n"]) end)

        new_last_us =
          new_rows
          |> Enum.map(& &1["timestamp"])
          |> Enum.max(fn -> nil end)

        tail_log_follow_loop(ref, source, interval, new_last_us || last_us)

      {:error, :rate_limited} ->
        err("tail: rate limited — backing off 60s")
        Process.sleep(60_000)
        tail_log_follow_loop(ref, source, interval, last_us)

      # Unrecoverable: the token or project won't fix itself by retrying.
      {:error, reason} when reason in [:unauthorized, :forbidden, :not_found] ->
        err("tail: #{reason} — stopping")
        {:error, 1}

      # Transient (timeout, transport, 5xx): warn and keep polling.
      {:error, reason} ->
        err("tail: #{inspect(reason)} — retrying")
        tail_log_follow_loop(ref, source, interval, last_us)

      # Unexpected success shape (no "result" list): skip this poll, keep going.
      {:ok, _other} ->
        tail_log_follow_loop(ref, source, interval, last_us)
    end
  end

  defp parse_log_path(path) do
    case String.split(path, "/", trim: true) do
      ["organizations", _org, "projects", ref, "logs", source] ->
        if Logs.valid_source?(source), do: {:ok, ref, source}, else: :error

      _other ->
        :error
    end
  end

  defp last_log_timestamp(body) do
    body
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil ->
        nil

      line ->
        case Jason.decode(line) do
          {:ok, %{"timestamp" => ts}} when is_integer(ts) -> ts
          _ -> nil
        end
    end
  end

  defp parse_head_tail(mode, args), do: parse_head_tail(args, 10, [], false, 30, mode)

  defp parse_head_tail([], _count, [], _follow?, _interval, mode),
    do: {:error, "Usage: supablock #{mode} [-n <count>] [-f [-s <secs>]] <path> [path...]"}

  defp parse_head_tail([], count, paths, follow?, interval, _mode) do
    follow_opts = if follow?, do: %{interval: interval}, else: nil
    {:ok, count, Enum.reverse(paths), follow_opts}
  end

  defp parse_head_tail([flag, value | rest], _count, paths, follow?, interval, mode)
       when flag in ["-n", "--lines"] do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> parse_head_tail(rest, n, paths, follow?, interval, mode)
      _other -> {:error, "#{mode}: #{flag} needs a non-negative integer"}
    end
  end

  defp parse_head_tail(["-n" <> digits | rest], _count, paths, follow?, interval, mode)
       when digits != "" do
    case Integer.parse(digits) do
      {n, ""} when n >= 0 -> parse_head_tail(rest, n, paths, follow?, interval, mode)
      _other -> {:error, "#{mode}: -n needs a non-negative integer"}
    end
  end

  defp parse_head_tail([flag], _count, _paths, _follow?, _interval, mode)
       when flag in ["-n", "--lines"],
       do: {:error, "#{mode}: #{flag} needs a value"}

  defp parse_head_tail([flag | rest], count, paths, _follow?, interval, mode)
       when flag in ["-f", "--follow"],
       do: parse_head_tail(rest, count, paths, true, interval, mode)

  defp parse_head_tail([flag, value | rest], count, paths, follow?, _interval, mode)
       when flag in ["-s", "--interval"] do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> parse_head_tail(rest, count, paths, follow?, n, mode)
      _other -> {:error, "#{mode}: #{flag} needs a positive integer"}
    end
  end

  defp parse_head_tail([flag], _count, _paths, _follow?, _interval, mode)
       when flag in ["-s", "--interval"],
       do: {:error, "#{mode}: #{flag} needs a value"}

  defp parse_head_tail(["-" <> _rest = flag | _more], _count, _paths, _follow?, _interval, mode),
    do: {:error, "#{mode}: unknown option #{flag}"}

  defp parse_head_tail([path | rest], count, paths, follow?, interval, mode),
    do: parse_head_tail(rest, count, [path | paths], follow?, interval, mode)

  ## find — walk the tree, print matching paths (find(1)-style flags)

  defp find(args) do
    with :authed <- require_auth(),
         {:ok, start, opts} <- parse_find(args) do
      raw_stdout!()

      Walk.reduce(start, opts.max_depth, 0, fn
        {:error, path, reason}, code ->
          max(code, path_error(path, reason))

        {kind, path}, code ->
          if find_match?(path, kind, opts) do
            if opts.print0, do: out_bytes([path, 0]), else: out(path)
          end

          code
      end)
    else
      {:exit, code} -> code
      {:error, message} -> usage_error(message)
    end
  end

  defp find_match?(path, kind, opts) do
    (opts.type == nil or opts.type == kind) and
      (opts.name == nil or Regex.match?(opts.name, Path.basename(path)))
  end

  defp parse_find(args),
    do: parse_find(args, nil, %{type: nil, name: nil, max_depth: :infinity, print0: false})

  defp parse_find([], path, opts), do: {:ok, path || ".", opts}

  defp parse_find([flag, value | rest], path, opts) when flag in ["-type", "--type"] do
    case value do
      "f" -> parse_find(rest, path, %{opts | type: :file})
      "d" -> parse_find(rest, path, %{opts | type: :dir})
      other -> {:error, "find: invalid #{flag} '#{other}' (use f or d)"}
    end
  end

  defp parse_find([flag, glob | rest], path, opts) when flag in ["-name", "--name"] do
    parse_find(rest, path, %{opts | name: glob_regex(glob)})
  end

  defp parse_find([flag, value | rest], path, opts)
       when flag in ["-maxdepth", "--maxdepth"] do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> parse_find(rest, path, %{opts | max_depth: n})
      _other -> {:error, "find: #{flag} needs a non-negative integer"}
    end
  end

  defp parse_find([flag | rest], path, opts) when flag in ["-print0", "--print0"] do
    parse_find(rest, path, %{opts | print0: true})
  end

  defp parse_find([flag], _path, _opts)
       when flag in ["-type", "--type", "-name", "--name", "-maxdepth", "--maxdepth"],
       do: {:error, "find: #{flag} needs a value"}

  defp parse_find(["-" <> _rest = flag | _more], _path, _opts),
    do: {:error, "find: unknown option #{flag}"}

  defp parse_find([arg | rest], nil, opts), do: parse_find(rest, arg, opts)

  defp parse_find([arg | _rest], _path, _opts),
    do: {:error, "find: one start path only (extra argument: #{arg})"}

  # Shell-glob basename matching: * and ? only, anchored.
  defp glob_regex(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> pattern <> "$")
  end

  ## grep — search file contents; directories recurse (like grep -r)

  defp grep(args) do
    with :authed <- require_auth(),
         {:ok, pattern, paths, opts} <- parse_grep(args),
         {:ok, regex} <- compile_grep_pattern(pattern, opts) do
      raw_stdout!()

      # grep(1) prefixes matches with the file name unless the operand is
      # one explicit file.
      prefix? =
        case paths do
          [single] -> Tree.kind(tree_path(single)) != {:ok, :file}
          _many -> true
        end

      {matched?, code} =
        Enum.reduce(paths, {false, 0}, fn path, acc ->
          grep_path(regex, path, opts, prefix?, acc)
        end)

      cond do
        code > 0 -> code
        matched? -> 0
        true -> 1
      end
    else
      {:exit, code} -> code
      {:error, message} -> usage_error(message)
    end
  end

  defp grep_path(regex, path, opts, prefix?, {matched?, code}) do
    case Tree.kind(tree_path(path)) do
      {:ok, :file} ->
        grep_file(regex, path, opts, prefix?, {matched?, code})

      {:ok, :dir} ->
        Walk.reduce(path, opts.max_depth, {matched?, code}, fn
          {:file, file}, acc -> grep_file(regex, file, opts, prefix?, acc)
          {:dir, _dir}, acc -> acc
          {:error, bad, reason}, {m, c} -> {m, max(c, path_error(bad, reason))}
        end)

      {:error, reason} ->
        {matched?, max(code, path_error(path, reason))}
    end
  end

  defp grep_file(regex, path, opts, prefix?, {matched?, code}) do
    case Tree.read(tree_path(path)) do
      {:ok, body} -> {grep_body(regex, path, body, opts, prefix?) or matched?, code}
      {:error, reason} -> {matched?, max(code, path_error(path, reason))}
    end
  end

  defp grep_body(regex, path, body, opts, prefix?) do
    if String.contains?(body, <<0>>) do
      # An opaque binary (a function's eszip body): report like grep(1)
      # instead of dumping bytes into the terminal.
      if Regex.match?(regex, body) do
        out(if opts.files_only, do: path, else: "Binary file #{path} matches")
        true
      else
        false
      end
    else
      matches =
        body
        |> split_lines()
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)

      cond do
        matches == [] ->
          false

        opts.files_only ->
          out(path)
          true

        true ->
          Enum.each(matches, fn {line, n} ->
            out(grep_line(path, n, line, opts, prefix?))
          end)

          true
      end
    end
  end

  defp grep_line(path, n, line, opts, prefix?) do
    IO.iodata_to_binary([
      if(prefix?, do: [path, ":"], else: []),
      if(opts.line_numbers, do: [Integer.to_string(n), ":"], else: []),
      line
    ])
  end

  defp compile_grep_pattern(pattern, opts) do
    case Regex.compile(pattern, if(opts.ignore_case, do: "i", else: "")) do
      {:ok, regex} -> {:ok, regex}
      {:error, {message, at}} -> {:error, "grep: bad pattern at #{at}: #{message}"}
    end
  end

  @grep_usage "Usage: supablock grep [-iln] [--maxdepth <n>] <pattern> [path...]"

  defp parse_grep(args) do
    opts = %{ignore_case: false, files_only: false, line_numbers: false, max_depth: :infinity}
    parse_grep(args, [], opts, false)
  end

  defp parse_grep([], positional, opts, _raw?) do
    case Enum.reverse(positional) do
      [pattern | paths] -> {:ok, pattern, if(paths == [], do: ["."], else: paths), opts}
      [] -> {:error, @grep_usage}
    end
  end

  defp parse_grep(["--" | rest], positional, opts, false),
    do: parse_grep(rest, positional, opts, true)

  defp parse_grep(["--maxdepth", value | rest], positional, opts, false) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> parse_grep(rest, positional, %{opts | max_depth: n}, false)
      _other -> {:error, "grep: --maxdepth needs a non-negative integer"}
    end
  end

  defp parse_grep(["--maxdepth"], _positional, _opts, false),
    do: {:error, "grep: --maxdepth needs a value"}

  defp parse_grep(["-" <> flags = arg | rest], positional, opts, false) when flags != "" do
    case grep_flags(flags, opts) do
      {:ok, opts} -> parse_grep(rest, positional, opts, false)
      :error -> {:error, "grep: unknown option #{arg}\n#{@grep_usage}"}
    end
  end

  defp parse_grep([arg | rest], positional, opts, raw?),
    do: parse_grep(rest, [arg | positional], opts, raw?)

  # Combined short flags (-rin). -r/-R are accepted for muscle memory but
  # change nothing: directories always recurse.
  defp grep_flags(flags, opts) do
    flags
    |> String.graphemes()
    |> Enum.reduce_while({:ok, opts}, fn
      "i", {:ok, opts} -> {:cont, {:ok, %{opts | ignore_case: true}}}
      "l", {:ok, opts} -> {:cont, {:ok, %{opts | files_only: true}}}
      "n", {:ok, opts} -> {:cont, {:ok, %{opts | line_numbers: true}}}
      r, {:ok, opts} when r in ["r", "R"] -> {:cont, {:ok, opts}}
      _other, _acc -> {:halt, :error}
    end)
  end

  ## snapshot / diff — materialize the tree, then track drift against it

  defp snapshot(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [all: :boolean, prune: :boolean])

    case {rest, invalid} do
      {[dir | scope], []} when length(scope) <= 1 ->
        with :authed <- require_auth() do
          raw_stdout!()
          start = List.first(scope) || "."
          stats = :counters.new(3, [])

          Snapshot.write(start, dir, [all: opts[:all] || false, prune: opts[:prune] || false], fn
            {:wrote, _rel, bytes} ->
              :counters.add(stats, 1, 1)
              :counters.add(stats, 2, bytes)

            {:pruned, rel} ->
              out("pruned: #{rel}")

            {:error, path, reason} ->
              :counters.put(stats, 3, max(:counters.get(stats, 3), path_error(path, reason)))
          end)

          files = :counters.get(stats, 1)
          bytes = :counters.get(stats, 2)
          out("Snapshot: #{files} files (#{bytes} bytes) -> #{dir}")
          :counters.get(stats, 3)
        else
          {:exit, code} -> code
        end

      _bad ->
        usage_error("Usage: supablock snapshot <dir> [path] [--all] [--prune]")
    end
  end

  defp diff_cmd(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [all: :boolean, brief: :boolean])

    case {rest, invalid} do
      {[dir | scope], []} when length(scope) <= 1 ->
        cond do
          not File.dir?(dir) ->
            IO.puts(:stderr, "Not a snapshot directory: #{dir}")
            2

          true ->
            with :authed <- require_auth() do
              raw_stdout!()
              start = List.first(scope) || "."
              brief? = opts[:brief] || false

              result =
                Snapshot.diff(start, dir, [all: opts[:all] || false], fn
                  {:changed, rel, snap_file, body} ->
                    if brief?,
                      do: out("changed: #{rel}"),
                      else: print_unified_diff(rel, snap_file, body)

                  {:added, rel, body} ->
                    if brief?, do: out("added: #{rel}"), else: print_added(rel, body)

                  {:removed, rel} ->
                    if brief?, do: out("removed: #{rel}"), else: out("Only in snapshot: #{rel}")

                  {:error, path, reason} ->
                    _ = path_error(path, reason)
                    :ok
                end)

              cond do
                result.errors > 0 -> 2
                result.different? -> 1
                true -> 0
              end
            else
              {:exit, code} -> code
            end
        end

      _bad ->
        usage_error("Usage: supablock diff <dir> [path] [--all] [--brief]")
    end
  end

  # A unified diff via diff(1) when available (snapshot/… vs tree/… labels,
  # so the output reads old -> new); a plain marker line otherwise.
  defp print_unified_diff(rel, snap_file, live_body) do
    case System.find_executable("diff") do
      nil ->
        out("Files differ: #{rel}")

      diff_bin ->
        tmp =
          Path.join(
            System.tmp_dir!(),
            "supablock-diff-#{:erlang.unique_integer([:positive])}"
          )

        try do
          File.write!(tmp, live_body)

          {output, _code} =
            System.cmd(
              diff_bin,
              ["-u", "--label", "snapshot/#{rel}", "--label", "tree/#{rel}", snap_file, tmp],
              stderr_to_stdout: true
            )

          out_bytes(output)
        after
          File.rm(tmp)
        end
    end
  end

  defp print_added(rel, body) do
    out("Only in tree: #{rel} (#{byte_size(body)} bytes)")
  end

  ## completions

  defp completions([shell]) do
    case Supablock.Completions.script(shell) do
      {:ok, script} ->
        IO.write(script)
        0

      :unknown ->
        usage_error("Unknown shell: #{shell}. Supported: bash, zsh, fish")
    end
  end

  defp completions(_other),
    do: usage_error("Usage: supablock completions bash|zsh|fish")

  ## mcp — the tree as an MCP stdio server

  defp mcp do
    with :authed <- require_auth() do
      # stdout is the protocol channel: nothing but JSON-RPC may reach it,
      # so the default (stdout) log handler is replaced by the file logger.
      _ = :logger.remove_handler(:default)
      attach_file_logger()
      raw_stdout!()
      Supablock.MCP.serve()
      0
    else
      {:exit, code} -> code
    end
  end

  ## serve — a mountless cache daemon
  #
  # Same warm shared cache a mount gives ls/cat/find/grep (they resolve
  # through it via the control socket, see Supablock.Tree) — but with no
  # FUSE, no privileges, no mountpoint. This is the batch-read mode for
  # sandboxes that can run the CLI but cannot mount.

  defp serve(["stop" | _rest]) do
    case Control.send_cmd("unmount") do
      {:ok, "ok"} ->
        IO.puts("Stopped.")
        0

      _no_daemon ->
        IO.puts(:stderr, "No supablock daemon running.")
        1
    end
  end

  defp serve([]) do
    with :authed <- require_auth() do
      case Control.send_cmd("check") do
        {:ok, "ok" <> _stats} ->
          IO.puts(:stderr, "A supablock daemon is already running (mount or serve).")
          1

        _not_running ->
          serve_foreground()
      end
    else
      {:exit, code} -> code
    end
  end

  defp serve(_other), do: usage_error("Usage: supablock serve [stop]")

  defp serve_foreground do
    attach_file_logger()
    Signals.install()

    case Control.start(nil) do
      {:ok, _pid} ->
        IO.puts("Serving a shared cache on #{Paths.control_socket()}")
        IO.puts("ls/cat/find/grep on this machine now reuse it automatically.")
        IO.puts("Stop with: supablock serve stop   (or Ctrl-C)")
        Process.sleep(:infinity)
        0

      {:error, reason} ->
        IO.puts(:stderr, "Could not start the cache daemon: #{inspect(reason)}")
        4
    end
  end

  # Body → lines, without a phantom empty line from the trailing newline.
  defp split_lines(body) do
    lines = String.split(body, "\n")
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  # Accept mount-style ("/organizations/acme"), relative ("organizations/acme")
  # and shell-ish (".", "./x") spellings; the Router ignores duplicate slashes.
  defp tree_path(path), do: Walk.router_path(path)

  # These can fire while raw_stdout!/0 has the io server in byte mode, so
  # they write bytes (never chardata needing transcoding) and stick to
  # ASCII text; only `path` can carry non-ASCII, and bytes pass through.
  defp err(line), do: IO.binwrite(:standard_error, [line, ?\n])

  defp path_error(path, :enoent) do
    err("No such path: #{path}")
    1
  end

  defp path_error(path, :eacces) do
    err("Access denied for #{path} - run: supablock login")
    2
  end

  defp path_error(path, :eagain) do
    err("Rate limited while reading #{path} - try again shortly.")
    3
  end

  defp path_error(path, _reason) do
    err("API error reading #{path}")
    3
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
        IO.puts("Service not installed. Run: supablock service install")
        1
    end
  end

  defp service(_other) do
    usage_error("Usage: supablock service install | uninstall | status")
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
          IO.puts("Stale data present — run: supablock refresh")
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
