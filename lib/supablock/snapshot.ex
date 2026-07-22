defmodule Supablock.Snapshot do
  @moduledoc """
  Materialize the tree into a real directory (`supablock snapshot`) and
  compare the live tree against such a directory (`supablock diff`).

  A snapshot is just the tree written to disk — the same deterministic
  bodies the mount serves, at full tree paths (`organizations/...`), so
  `diff -r` between two snapshots and `git diff` on a snapshot directory
  both work, and any snapshot can later be compared against any scope.

  By default the volatile or heavyweight parts of the tree are skipped:
  `logs/`, `metrics`, `database/<schema>/` row data and
  `functions/<fn>/body`. What remains is the configuration surface where
  drift is meaningful. `all: true` includes everything. Skipped subtrees
  are pruned before listing, so they cost no requests.
  """

  alias Supablock.{Tree, Walk}

  @type errno :: Supablock.Router.error()
  @type write_event ::
          {:wrote, String.t(), non_neg_integer}
          | {:pruned, String.t()}
          | {:error, String.t(), errno}
  @type diff_event ::
          {:added, String.t(), binary}
          | {:removed, String.t()}
          | {:changed, String.t(), Path.t(), binary}
          | {:error, String.t(), errno}

  @doc """
  Walk the tree under `start` and write every file below `dest`.
  Emits `{:wrote, rel, bytes}` per file, `{:error, path, reason}` per
  failure (the walk continues, like find), and — with `prune: true` —
  `{:pruned, rel}` for stale files removed from `dest`.
  """
  @spec write(String.t(), Path.t(), keyword, (write_event -> any)) :: :ok
  def write(start, dest, opts, emit) do
    all? = Keyword.get(opts, :all, false)
    prune? = Keyword.get(opts, :prune, false)

    written =
      Walk.reduce(start, :infinity, MapSet.new(), fn
        {:dir, path}, acc ->
          if skip?(path, :dir, all?), do: {:prune, acc}, else: acc

        {:file, path}, acc ->
          rel = rel_path(path)

          if skip?(path, :file, all?) do
            acc
          else
            case Tree.read(Walk.router_path(path)) do
              {:ok, body} ->
                target = Path.join(dest, rel)
                File.mkdir_p!(Path.dirname(target))
                File.write!(target, body)
                emit.({:wrote, rel, byte_size(body)})
                MapSet.put(acc, rel)

              {:error, reason} ->
                emit.({:error, path, reason})
                acc
            end
          end

        {:error, path, reason}, acc ->
          emit.({:error, path, reason})
          acc
      end)

    if prune? do
      prefix = rel_path(start)

      for rel <- disk_files(dest),
          in_scope?(rel, prefix),
          not skip?(rel, :file, all?),
          not MapSet.member?(written, rel) do
        File.rm(Path.join(dest, rel))
        emit.({:pruned, rel})
      end

      remove_empty_dirs(dest)
    end

    :ok
  end

  @doc """
  Compare the live tree under `start` against the snapshot in `dest`.
  Emits `{:changed, rel, snapshot_file, live_body}`, `{:added, rel, body}`
  (in the tree but not the snapshot), `{:removed, rel}` (in the snapshot
  but gone from the tree) and `{:error, path, reason}`. Returns whether
  any difference was seen.
  """
  @spec diff(String.t(), Path.t(), keyword, (diff_event -> any)) :: %{
          different?: boolean,
          errors: non_neg_integer
        }
  def diff(start, dest, opts, emit) do
    all? = Keyword.get(opts, :all, false)

    {seen, different?, errors} =
      Walk.reduce(start, :infinity, {MapSet.new(), false, 0}, fn
        {:dir, path}, {seen, diff?, errs} = acc ->
          if skip?(path, :dir, all?), do: {:prune, acc}, else: {seen, diff?, errs}

        {:file, path}, {seen, diff?, errs} = acc ->
          rel = rel_path(path)

          if skip?(path, :file, all?) do
            acc
          else
            case Tree.read(Walk.router_path(path)) do
              {:ok, body} ->
                seen = MapSet.put(seen, rel)
                snap_file = Path.join(dest, rel)

                case File.read(snap_file) do
                  {:ok, ^body} ->
                    {seen, diff?, errs}

                  {:ok, _other} ->
                    emit.({:changed, rel, snap_file, body})
                    {seen, true, errs}

                  {:error, :enoent} ->
                    emit.({:added, rel, body})
                    {seen, true, errs}

                  {:error, _reason} ->
                    emit.({:error, rel, :eio})
                    {seen, diff?, errs + 1}
                end

              {:error, reason} ->
                emit.({:error, path, reason})
                {seen, diff?, errs + 1}
            end
          end

        {:error, path, reason}, {seen, diff?, errs} ->
          emit.({:error, path, reason})
          {seen, diff?, errs + 1}
      end)

    prefix = rel_path(start)

    removed =
      for rel <- Enum.sort(disk_files(dest)),
          in_scope?(rel, prefix),
          not skip?(rel, :file, all?),
          not MapSet.member?(seen, rel) do
        emit.({:removed, rel})
        rel
      end

    %{different?: different? or removed != [], errors: errors}
  end

  @doc false
  # The volatile/heavy subtrees skipped unless `--all`: logs, metrics,
  # database row data (the database/*.json files stay), function bodies.
  # `kind` disambiguates database/<x>: a file there is one of the
  # Management API JSONs (kept), a directory is a Data API schema (skipped).
  def skip?(path, kind, all?)
  def skip?(_path, _kind, true), do: false

  def skip?(path, kind, false) do
    case String.split(Walk.router_path(path), "/", trim: true) do
      ["organizations", _org, "projects", _ref | rest] -> skip_rest?(rest, kind)
      _other -> false
    end
  end

  defp skip_rest?(["logs" | _more], _kind), do: true
  defp skip_rest?(["metrics"], _kind), do: true
  defp skip_rest?(["functions", _fn, "body"], _kind), do: true
  defp skip_rest?(["database", _schema], :dir), do: true
  defp skip_rest?(["database", _schema, _child | _more], _kind), do: true
  defp skip_rest?(_other, _kind), do: false

  @doc false
  # Caller spelling -> the full tree-relative path stored in snapshots.
  def rel_path(path) do
    path |> Walk.router_path() |> String.split("/", trim: true) |> Enum.join("/")
  end

  defp in_scope?(_rel, ""), do: true
  defp in_scope?(rel, prefix), do: rel == prefix or String.starts_with?(rel, prefix <> "/")

  defp disk_files(dir), do: disk_files(dir, "")

  defp disk_files(dir, rel) do
    full = if rel == "", do: dir, else: Path.join(dir, rel)

    case File.ls(full) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          child = if rel == "", do: name, else: rel <> "/" <> name

          case File.lstat(Path.join(dir, child)) do
            {:ok, %File.Stat{type: :directory}} -> disk_files(dir, child)
            {:ok, %File.Stat{type: :regular}} -> [child]
            _other -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp remove_empty_dirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          child = Path.join(dir, name)

          if File.dir?(child) do
            remove_empty_dirs(child)
            # rmdir fails on non-empty directories, which is exactly the point
            _ = File.rmdir(child)
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end
end
