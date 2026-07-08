defmodule Superblock.RawFile do
  @moduledoc """
  File reads that bypass Erlang's file server (`:file_server_2`).

  Anything on the FUSE-serving path (Config, Credentials) must not touch the
  file server: a process reading a superblock-mounted file from the same VM
  parks the file server inside a FUSE syscall, and if serving that FUSE
  request then needs the file server too, the filesystem deadlocks. `:raw`
  operations run in the calling process, so the cycle cannot form.
  """

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
