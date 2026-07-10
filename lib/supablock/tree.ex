defmodule Supablock.Tree do
  @moduledoc """
  Tree reads for the CLI commands (`ls`, `cat`, `head`, `tail`, `find`,
  `grep`): try a running supablock daemon first — a mount or `supablock
  serve`, over the control socket — so every read shares its warm cache,
  and fall back to resolving directly through `Supablock.Router`.

  Path errors from the daemon are authoritative (it ran the same Router
  this process would); transport-level trouble — no daemon, a stale
  socket, an older daemon without the read commands — silently degrades
  to a direct read, never to a user-visible error. `SUPABLOCK_DIRECT=1`
  skips the daemon entirely.
  """

  alias Supablock.{Control, Router}

  @spec kind(String.t()) :: {:ok, :dir | :file} | {:error, Router.error()}
  def kind(path), do: resolve(:kind, path, fn -> Router.kind(path) end)

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, Router.error()}
  def list(path), do: resolve(:list, path, fn -> Router.list(path) end)

  @spec read(String.t()) :: {:ok, binary} | {:error, Router.error()}
  def read(path), do: resolve(:read, path, fn -> Router.read(path) end)

  defp resolve(op, path, direct) do
    if direct?() do
      direct.()
    else
      case Control.remote(op, path) do
        {:error, :unavailable} -> direct.()
        result -> result
      end
    end
  end

  defp direct?, do: System.get_env("SUPABLOCK_DIRECT") not in [nil, "", "0"]
end
