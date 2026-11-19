defmodule Supablock.AuthCallback do
  @moduledoc """
  The ephemeral OAuth callback server: a Francis app bound to
  `127.0.0.1:53682`, alive only while `supablock login` waits for the
  browser redirect. One GET route; the query params (code/state or an error)
  are handed to the waiting login process, the browser gets a small
  "return to your terminal" page, and the server is stopped.

  Loopback-only binding: nothing off this machine can reach it, and the PKCE
  verifier (never in any URL) is what makes a stolen code useless anyway.
  """

  use Francis,
    bandit_opts: [ip: {127, 0, 0, 1}, port: 53682, startup_log: false],
    static: false,
    log_level: :warning

  @page """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8">
      <title>supablock — logged in</title>
      <style>
        body { font-family: ui-sans-serif, system-ui, sans-serif; background: #171717;
               color: #ededed; display: grid; place-items: center; min-height: 100vh; margin: 0; }
        main { text-align: center; padding: 24px; }
        h1 { font-size: 20px; } p { color: #8f8f8f; }
        .ok { color: #3ecf8e; }
      </style>
    </head>
    <body>
      <main>
        <h1><span class="ok">✓</span> supablock is connected</h1>
        <p>You can close this tab and return to your terminal.</p>
      </main>
    </body>
  </html>
  """

  @port 53682
  @ipv6 {0, 0, 0, 0, 0, 0, 0, 1}

  @denied_page String.replace(@page, ~r/<main>.*<\/main>/s, """
               <main>
                 <h1>supablock was not authorized</h1>
                 <p>Return to your terminal for details.</p>
               </main>
               """)

  @stray_page """
  <!doctype html>
  <html><head><meta charset="utf-8"><title>supablock</title></head>
  <body><p>This callback does not belong to a supablock login in progress.</p></body></html>
  """

  get("/callback", fn conn ->
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    case :persistent_term.get({__MODULE__, :waiter}, nil) do
      {pid, expected} when is_pid(pid) ->
        if state_matches?(params["state"], expected) do
          send(pid, {:oauth_callback, params})
          reply_html(conn, 200, if(Map.has_key?(params, "code"), do: @page, else: @denied_page))
        else
          reply_html(conn, 400, @stray_page)
        end

      _none ->
        reply_html(conn, 400, @stray_page)
    end
  end)

  defp reply_html(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, body)
  end

  @doc false
  # `state[]=x` decodes to a list; only a string of the right length compares.
  def state_matches?(given, expected)
      when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected),
      do: Plug.Crypto.secure_compare(given, expected)

  def state_matches?(_given, _expected), do: false

  @doc """
  Start the listener for a login whose authorization request carried
  `state`; matching callback params are sent to `waiter` as
  `{:oauth_callback, params}`. Returns a handle to pass to `stop_listener/1`,
  or a friendly error when the port is taken.

  The Bandit supervisor is owned by a dedicated keeper process: an OTP
  supervisor shuts down whenever its parent exits, and a failed bind must
  not crash the caller through the start link either.
  """
  @spec start_listener(pid, String.t()) :: {:ok, pid} | {:error, :port_in_use | term}
  def start_listener(waiter, state) when is_pid(waiter) and is_binary(state) do
    caller = self()

    keeper =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        waiter_ref = Process.monitor(waiter)

        case start_both() do
          {:ok, supervisor} ->
            send(caller, {__MODULE__, self(), :ok})

            receive do
              {:stop, from} ->
                Supervisor.stop(supervisor)
                send(from, {__MODULE__, self(), :stopped})

              {:DOWN, ^waiter_ref, :process, _pid, _reason} ->
                Supervisor.stop(supervisor)
                :persistent_term.erase({__MODULE__, :waiter})

              {:EXIT, ^supervisor, _reason} ->
                :ok
            end

          {:error, reason} ->
            send(caller, {__MODULE__, self(), {:error, reason}})
        end
      end)

    receive do
      # Recorded only once bound: a second login that fails on a taken port
      # must not overwrite (or erase) the waiter of the one holding it.
      {__MODULE__, ^keeper, :ok} ->
        :persistent_term.put({__MODULE__, :waiter}, {waiter, state})
        {:ok, keeper}

      {__MODULE__, ^keeper, {:error, reason}} ->
        if port_in_use?(reason), do: {:error, :port_in_use}, else: {:error, reason}
    after
      10_000 -> {:error, :listener_start_timeout}
    end
  end

  # IPv4 must bind. IPv6 is added when the host has it; if ::1:53682 is
  # *taken* (not merely unavailable) the login refuses to run, since a
  # browser resolving localhost to ::1 would hand the code to that process.
  defp start_both do
    with {:ok, supervisor} <- start() do
      case Supervisor.start_child(supervisor, bandit_spec(:ipv6, @ipv6)) do
        {:ok, _pid} ->
          {:ok, supervisor}

        {:error, reason} ->
          if port_in_use?(reason) do
            Supervisor.stop(supervisor)
            {:error, reason}
          else
            {:ok, supervisor}
          end
      end
    end
  end

  defp bandit_spec(id, ip) do
    Supervisor.child_spec(
      {Bandit, plug: __MODULE__, ip: ip, port: @port, startup_log: false},
      id: id
    )
  end

  @spec stop_listener(pid) :: :ok
  def stop_listener(keeper) when is_pid(keeper) do
    send(keeper, {:stop, self()})

    receive do
      {__MODULE__, ^keeper, :stopped} -> :ok
    after
      5_000 -> :ok
    end

    :persistent_term.erase({__MODULE__, :waiter})
    :ok
  end

  defp port_in_use?(reason), do: reason |> inspect() |> String.contains?("eaddrinuse")
end
