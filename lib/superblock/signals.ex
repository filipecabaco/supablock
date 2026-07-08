defmodule Superblock.Signals do
  @moduledoc """
  Signal handling for the foreground `superblock mount` process: SIGTERM and
  SIGQUIT unmount cleanly before stopping the VM.

  This is a `:gen_event` handler swapped in for OTP's default
  `:erl_signal_handler`. Ctrl-C (SIGINT) is not routable here — the runtime
  owns it — but that case is covered on the other side of the port: the efuse
  process gets the terminal's SIGINT too (same process group) and libfuse's
  own signal handlers unmount before exiting, and its watchdog unmounts if
  the VM dies first. Either way, no stale mount.
  """

  @behaviour :gen_event

  @doc "Install the handler (idempotent)."
  def install do
    :os.set_signal(:sigterm, :handle)
    :os.set_signal(:sigquit, :handle)

    case :gen_event.swap_sup_handler(
           :erl_signal_server,
           {:erl_signal_handler, []},
           {__MODULE__, []}
         ) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl true
  def init({_args, _term}), do: {:ok, %{}}
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_event(signal, state) when signal in [:sigterm, :sigquit, :sigint] do
    spawn(fn ->
      Superblock.Fs.unmount()
      System.stop(0)
    end)

    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}
end
