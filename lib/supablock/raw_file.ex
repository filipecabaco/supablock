defmodule Supablock.RawFile do
  @moduledoc """
  File reads that bypass Erlang's file server (`:file_server_2`).

  Anything on the FUSE-serving path (Config, Credentials) must not touch the
  file server: a process reading a supablock-mounted file from the same VM
  parks the file server inside a FUSE syscall, and if serving that FUSE
  request then needs the file server too, the filesystem deadlocks. `:raw`
  operations run in the calling process, so the cycle cannot form.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc """
  Atomically replace `path` with `data` at `mode`, all with raw operations:
  write a sibling tmp file, chmod it, rename over the target. Token refresh
  runs on the FUSE-serving path, so a crash mid-write must never leave a
  truncated credentials file — and none of this may touch the file server.
  """
  @spec write_atomic(Path.t(), iodata, non_neg_integer) :: :ok | {:error, term}
  def write_atomic(path, data, mode) do
    tmp = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- write_raw(tmp, data),
         :ok <- chmod_raw(tmp, mode),
         :ok <- :prim_file.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        :prim_file.delete(tmp)
        {:error, reason}
    end
  end

  defp write_raw(path, data) do
    case :file.open(path, [:write, :binary, :raw]) do
      {:ok, device} ->
        try do
          with :ok <- :file.write(device, data), do: :file.datasync(device)
        after
          :file.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chmod_raw(path, mode) do
    with {:ok, info} <- :prim_file.read_file_info(path) do
      :prim_file.write_file_info(path, file_info(info, mode: mode))
    end
  end

  @spec read(Path.t()) :: {:ok, binary} | {:error, :file.posix() | term}
  def read(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          read_all(device, [])
        after
          :file.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_all(device, acc) do
    case :file.read(device, 65_536) do
      {:ok, chunk} -> read_all(device, [acc | chunk])
      :eof -> {:ok, IO.iodata_to_binary(acc)}
      {:error, reason} -> {:error, reason}
    end
  end
end
