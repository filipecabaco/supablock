defmodule Supablock.Walk do
  @moduledoc """
  Depth-first traversal of the Router tree for the no-mount commands
  (`find`, `grep`). Cheap by construction: nodes are classified with
  `Tree.kind/1` and directories expanded with `Tree.list/1` (both prefer a
  running daemon's warm cache — see `Supablock.Tree`), so a walk performs
  the same (cached) listing requests `ls -R` on a mount would — file
  bodies are never fetched unless the caller reads them.
  """

  alias Supablock.{Router, Tree}

  @type event ::
          {:dir, String.t()} | {:file, String.t()} | {:error, String.t(), Router.error()}

  @doc """
  Reduce `fun` over every node under `path` (inclusive), depth-first, in
  listing order. Failures on single nodes are `{:error, path, reason}`
  events — like find(1), the walk reports them and continues. `max_depth`
  bounds descent relative to the start: `0` visits only `path` itself.

  Returning `{:prune, acc}` from a `{:dir, _}` event keeps `acc` and skips
  that directory's children entirely — the directory is never listed, so
  pruned subtrees cost no requests.

  Paths in events keep the caller's spelling (relative stays relative,
  `.` becomes `./…`), so output can be fed straight back to
  `supablock cat`.
  """
  @spec reduce(String.t(), non_neg_integer | :infinity, acc, (event, acc -> acc)) :: acc
        when acc: var
  def reduce(path, max_depth, acc, fun) do
    case Tree.kind(router_path(path)) do
      {:ok, :dir} -> walk_dir(path, 0, max_depth, acc, fun)
      {:ok, :file} -> fun.({:file, path}, acc)
      {:error, reason} -> fun.({:error, path, reason}, acc)
    end
  end

  defp walk_dir(path, depth, max_depth, acc, fun) do
    case fun.({:dir, path}, acc) do
      {:prune, acc} ->
        acc

      acc ->
        # `depth < :infinity` holds for any integer (Erlang term order).
        if depth < max_depth do
          case Tree.list(router_path(path)) do
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
  end

  defp walk_child(path, depth, max_depth, acc, fun) do
    case Tree.kind(router_path(path)) do
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

  @doc """
  Compile a shell-style glob (`*`, `?`) into an anchored regex for matching
  a single path basename, as `find -name` does. Literal regex metacharacters
  in the glob are escaped first, so only `*`/`?` are special.
  """
  @spec glob_regex(String.t()) :: Regex.t()
  def glob_regex(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> pattern <> "$")
  end
end
