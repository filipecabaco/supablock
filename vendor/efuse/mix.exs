# Vendored from https://github.com/mwri/erlang-efuse (MIT, Michael Wright).
# Modified for superblock: converted from rebar3 to Mix (so the build needs
# neither rebar3 plugins nor hex.pm), and the C port is patched — see
# c_src/efuse.c for the list of changes.

defmodule Mix.Tasks.Compile.EfuseMake do
  use Mix.Task.Compiler

  @moduledoc false

  def run(_args) do
    # -B: the C build is cheap and the flags (API selection, static vs
    # dynamic) come from the environment, which make's mtime check can't see.
    case System.cmd("make", ["-B", "-C", "c_src"], stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, []}

      {out, status} ->
        Mix.shell().error(out)
        Mix.raise("efuse C port build failed (make exited #{status}); " <>
          "install libfuse3-dev (Linux) or macFUSE (macOS) and pkg-config")
    end
  end

  def clean do
    System.cmd("make", ["-C", "c_src", "clean"], stderr_to_stdout: true)
    :ok
  end
end

defmodule Efuse.MixProject do
  use Mix.Project

  def project do
    [
      app: :efuse,
      version: "1.0.2",
      language: :erlang,
      compilers: [:efuse_make, :erlang, :app],
      deps: []
    ]
  end

  def application do
    [
      registered: [],
      mod: {:efuse_app, []},
      extra_applications: []
    ]
  end
end
