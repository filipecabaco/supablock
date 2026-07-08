defmodule Superblock.Doctor do
  @moduledoc """
  Environment checks for `superblock doctor`. Each check yields
  `{name, :ok}` or `{name, {:error, fix_suggestion}}`.
  """

  import Bitwise, only: [&&&: 2]

  alias Superblock.Paths

  @spec run() :: [{String.t(), :ok | {:error, String.t()}}]
  def run do
    [
      fuse_device(),
      unmount_tool(),
      config_dir_perms(),
      credentials_perms(),
      port_binary()
    ]
  end

  defp fuse_device do
    case :os.type() do
      {:unix, :darwin} ->
        if File.exists?("/Library/Filesystems/macfuse.fs") or
             System.find_executable("mount_macfuse") do
          {"macFUSE installed", :ok}
        else
          {"macFUSE installed", {:error, "install macFUSE from https://macfuse.github.io"}}
        end

      _linux ->
        if File.exists?("/dev/fuse") do
          {"/dev/fuse present", :ok}
        else
          {"/dev/fuse present",
           {:error, "load the fuse kernel module (modprobe fuse) or install the fuse3 package"}}
        end
    end
  end

  defp unmount_tool do
    tools = ["fusermount3", "fusermount", "umount"]

    case Enum.find(tools, &System.find_executable/1) do
      nil ->
        {"unmount tool on PATH", {:error, "install fuse3 (Linux) so fusermount3 is available"}}

      tool ->
        {"unmount tool on PATH (#{tool})", :ok}
    end
  end

  defp config_dir_perms do
    dir = Paths.config_dir()

    case File.stat(dir) do
      {:ok, %File.Stat{mode: mode}} ->
        if (mode &&& 0o777) == 0o700 do
          {"config dir mode 0700", :ok}
        else
          {"config dir mode 0700", {:error, "run: chmod 700 #{dir}"}}
        end

      {:error, :enoent} ->
        {"config dir mode 0700", :ok}

      {:error, reason} ->
        {"config dir mode 0700", {:error, "cannot stat #{dir}: #{inspect(reason)}"}}
    end
  end

  defp credentials_perms do
    path = Paths.credentials_file()

    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if (mode &&& 0o777) == 0o600 do
          {"credentials mode 0600", :ok}
        else
          {"credentials mode 0600", {:error, "run: chmod 600 #{path}"}}
        end

      {:error, :enoent} ->
        {"credentials mode 0600 (no credentials stored)", :ok}

      {:error, reason} ->
        {"credentials mode 0600", {:error, "cannot stat #{path}: #{inspect(reason)}"}}
    end
  end

  defp port_binary do
    Application.load(:efuse)

    path =
      try do
        Application.app_dir(:efuse, "priv/efuse")
      rescue
        _any -> nil
      end

    if path && File.exists?(path) do
      {"efuse port binary compiled", :ok}
    else
      {"efuse port binary compiled",
       {:error, "rebuild with libfuse3-dev installed: mix deps.compile efuse --force"}}
    end
  end
end
