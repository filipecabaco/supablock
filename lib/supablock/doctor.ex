defmodule Supablock.Doctor do
  @moduledoc """
  Environment checks for `supablock doctor`, grouped by the capability each
  one gates.

  Only the `:reading` group is required. The tree readers resolve straight
  off the API — no FUSE, no privileges, no daemon — so a sandbox, container
  or CI runner that fails every `:mounting` check is still a working
  supablock, and reporting it as broken sends people looking for privileges
  they do not need. `reads_ok?/1` is the signal worth branching on.

  Each check yields `{name, :ok}` or `{name, {:error, fix_suggestion}}`.
  """

  import Bitwise, only: [&&&: 2]

  alias Supablock.{Credentials, Paths}

  @type check :: {String.t(), :ok | {:error, String.t()}}
  @type group :: {:reading | :daemon | :mounting, String.t(), [check]}

  @spec run() :: [group]
  def run do
    [
      {:reading, "Reading — ls, cat, head, tail, find, grep, snapshot, mcp",
       [credential(), config_dir_perms(), credentials_perms()]},
      {:daemon, "Shared cache daemon — serve (optional)", [control_socket_path()]},
      {:mounting, "Mounting — mount (optional, needs FUSE)",
       [fuse_device(), unmount_tool(), port_binary()]}
    ]
  end

  @doc """
  True when every required check passed — i.e. the tree readers will work.
  Failures outside the `:reading` group gate optional features only.
  """
  @spec reads_ok?([group]) :: boolean
  def reads_ok?(groups) do
    Enum.all?(groups, fn
      {:reading, _title, checks} -> Enum.all?(checks, &passed?/1)
      {_optional, _title, _checks} -> true
    end)
  end

  @doc "True when some optional check failed, so the caller can say so once."
  @spec optional_gaps?([group]) :: boolean
  def optional_gaps?(groups) do
    Enum.any?(groups, fn
      {:reading, _title, _checks} -> false
      {_optional, _title, checks} -> Enum.any?(checks, &(not passed?(&1)))
    end)
  end

  defp passed?({_name, :ok}), do: true
  defp passed?({_name, {:error, _fix}}), do: false

  defp credential do
    case Credentials.load() do
      {:ok, _token} ->
        {"credential available", :ok}

      :missing ->
        {"credential available",
         {:error,
          "run: supablock login — or export SUPABLOCK_TOKEN, which is the " <>
            "headless path (export it, never pass it on a command line)"}}
    end
  end

  defp control_socket_path do
    {"control socket path fits a Unix socket address", Paths.validate_control_socket()}
  end

  defp fuse_device do
    case :os.type() do
      {:unix, :darwin} ->
        # Either userspace FUSE works: macFUSE (kext/FSKit) or FUSE-T (NFS-backed).
        if File.exists?("/Library/Filesystems/macfuse.fs") or
             System.find_executable("mount_macfuse") != nil or
             File.exists?("/Library/Application Support/fuse-t") or
             File.exists?("/usr/local/lib/libfuse-t.dylib") or
             File.exists?("/opt/homebrew/lib/libfuse-t.dylib") do
          {"macFUSE or FUSE-T installed", :ok}
        else
          {"macFUSE or FUSE-T installed",
           {:error,
            "install macFUSE (https://macfuse.github.io) or FUSE-T (https://www.fuse-t.org)"}}
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

    cond do
      path == nil or not File.exists?(path) ->
        {"efuse port binary compiled",
         {:error, "rebuild with libfuse3-dev installed: mix deps.compile efuse --force"}}

      missing_shared_libs?(path) ->
        {"efuse port binary compiled",
         {:error,
          "the port is dynamically linked against a FUSE library that is not " <>
            "installed here — install the fuse3 (Linux) / macFUSE (macOS) package, " <>
            "or rebuild the port statically (the default when libfuse3.a is present)"}}

      true ->
        {"efuse port binary compiled", :ok}
    end
  end

  defp missing_shared_libs?(path) do
    with {:unix, :linux} <- :os.type(),
         ldd when is_binary(ldd) <- System.find_executable("ldd"),
         {out, 0} <- System.cmd(ldd, [path], stderr_to_stdout: true) do
      String.contains?(out, "not found")
    else
      _other -> false
    end
  end
end
