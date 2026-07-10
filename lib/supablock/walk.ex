defmodule Supablock.Walk do
  @moduledoc """
  Depth-first traversal of the `Supablock.Router` tree for the no-mount
  commands (`find`, `grep`). Cheap by construction: nodes are classified
  with `Router.kind/1` and directories expanded with `Router.list/1`, so a
  walk performs the same (cached) listing requests `ls -R` on a mount
  would — file bodies are never fetched unless the caller reads them.
  """

  alias Supablock.Router

  @type event ::
          {:dir, String.t()} | {:file, String.t()} | {:error, String.t(), Router.error()}

  @doc """
  Reduce `fun` over every node under `path` (inclusive), depth-first, in
  listing order. Failures on single nodes are `{:error, path, reason}`
  events — like find(1), the walk reports them and continues. `max_depth`
  bounds descent relative to the start: `0` visits only `path` itself.

  Paths in events keep the caller's spelling (relative stays relative,
  `.` becomes `./…`), so output can be fed straight back to
  `supablock cat`.
  """
  @spec reduce(String.t(), non_neg_integer | :infinity, acc, (event, acc -> acc)) :: acc
        when acc: var
  def reduce(path, max_depth, acc, fun) do
    case Router.kind(router_path(path)) do
      {:ok, :dir} -> walk_dir(path, 0, max_depth, acc, fun)
      {:ok, :file} -> fun.({:file, path}, acc)
      {:error, reason} -> fun.({:error, path, reason}, acc)
    end
  end

  defp walk_dir(path, depth, max_depth, acc, fun) do
    acc = fun.({:dir, path}, acc)

    # `depth < :infinity` holds for any integer (Erlang term order).
    if depth < max_depth do
      case Router.list(router_path(path)) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn name, acc ->
            walk_child(join(path, name), depth + 1, max_depth, acc, fun)
          end)

        {:error, reason} ->
          fun.({:error, path, reason}, acc)
      end
    else
      acc
    end
  end

  defp walk_child(path, depth, max_depth, acc, fun) do
    case Router.kind(router_path(path)) do
      {:ok, :dir} -> walk_dir(path, depth, max_depth, acc, fun)
      {:ok, :file} -> fun.({:file, path}, acc)
      {:error, reason} -> fun.({:error, path, reason}, acc)
    end
  end

  @doc """
  Mount-style (`/organizations/x`), relative (`organizations/x`) and
  shell-ish (`.`, `./x`) spellings → the absolute path the Router speaks
  (the Router ignores duplicate slashes).
  """
  @spec router_path(String.t()) :: String.t()
  def router_path(path) do
    case String.trim(path) do
      "." -> "/"
      "./" <> rest -> "/" <> rest
      trimmed -> "/" <> trimmed
    end
  end

  defp join(".", name), do: "./" <> name
  defp join(path, name), do: String.trim_trailing(path, "/") <> "/" <> name
end
