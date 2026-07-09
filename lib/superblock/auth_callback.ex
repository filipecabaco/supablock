defmodule Superblock.AuthCallback do
  @moduledoc """
  The ephemeral OAuth callback server: a Francis app bound to
  `127.0.0.1:53682`, alive only while `superblock login` waits for the
  browser redirect. One GET route; the query params (code/state or an error)
  are handed to the waiting login process, the browser gets a small
  "return to your terminal" page, and the server is stopped.

  Loopback-only binding: nothing off this machine can reach it, and the PKCE
  verifier (never in any URL) is what makes a stolen code useless anyway.
  """

  use Francis,
    bandit_opts: [ip: {127, 0, 0, 1}, port: 53682, startup_log: false],
    static: false,
    log_level: :debug

  @page """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8">
      <title>superblock — logged in</title>
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
        <h1><span class="ok">✓</span> superblock is connected</h1>
        <p>You can close this tab and return to your terminal.</p>
      </main>
    </body>
  </html>
  """

  get("/callback", fn conn ->
    conn = Plug.Conn.fetch_query_params(conn)

    case :persistent_term.get({__MODULE__, :waiter}, nil) do
      pid when is_pid(pid) -> send(pid, {:oauth_callback, conn.query_params})
      _none -> :ok
    end

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, @page)
  end)

  @doc """
  Start the listener; callback params are sent to `waiter` as
  `{:oauth_callback, params}`. Returns a handle to pass to `stop_listener/1`,
  or a friendly error when the port is taken.

  The Bandit supervisor is owned by a dedicated keeper process: an OTP
  supervisor shuts down whenever its parent exits, and a failed bind must
  not crash the caller through the start link either.
  """
  @spec start_listener(pid) :: {:ok, pid} | {:error, :port_in_use | term}
  def start_listener(waiter) when is_pid(waiter) do
    :persistent_term.put({__MODULE__, :waiter}, waiter)
    caller = self()

    keeper =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        waiter_ref = Process.monitor(waiter)

        case start() do
          {:ok, supervisor} ->
            send(caller, {__MODULE__, self(), :ok})

            receive do
              {:stop, from} ->
                Supervisor.stop(supervisor)
                send(from, {__MODULE__, self(), :stopped})

              # the login process died: no point serving callbacks anymore
              {:DOWN, ^waiter_ref, :process, _pid, _reason} ->
                Supervisor.stop(supervisor)

              {:EXIT, ^supervisor, _reason} ->
                :ok
            end

          {:error, reason} ->
            send(caller, {__MODULE__, self(), {:error, reason}})
        end
      end)

    receive do
      {__MODULE__, ^keeper, :ok} ->
        {:ok, keeper}

      {__MODULE__, ^keeper, {:error, reason}} ->
        :persistent_term.erase({__MODULE__, :waiter})
        if port_in_use?(reason), do: {:error, :port_in_use}, else: {:error, reason}
    after
      10_000 ->
        :persistent_term.erase({__MODULE__, :waiter})
        {:error, :listener_start_timeout}
    end
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
