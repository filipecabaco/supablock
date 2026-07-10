defmodule Supablock.MixProject do
  use Mix.Project

  def project do
    [
      app: :supablock,
      version: version(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      default_release: :supablock,
      releases: releases(),
      deps: deps()
    ]
  end

  # Burrito's wrapper unpacks the payload into a per-user cache dir keyed by
  # "<release>_erts-<ertsvsn>_<app_version>" and reuses it whenever that key
  # already exists — so every published binary must carry a unique version,
  # or an upgraded binary silently keeps running the previously unpacked
  # code. The release workflow sets SUPABLOCK_BUILD_VERSION per build (the
  # tag for versioned releases, "<base>-canary.<sha>" for canary builds);
  # local builds fall back to the static default.
  @version "0.1.0"
  defp version, do: System.get_env("SUPABLOCK_BUILD_VERSION", @version)

  def application do
    [
      extra_applications: [:logger],
      mod: {Supablock.Application, []}
    ]
  end

  defp releases do
    [
      # Classic release, used by bin/supablock (the thin launcher) and the
      # e2e suite: MIX_ENV=prod mix release
      supablock: [
        include_executables_for: [:unix],
        strip_beams: true,
        # userfs/efuse are runtime: false deps (CLI commands like `login`
        # must not start the FUSE machinery); `mount` starts them on demand.
        applications: [userfs: :load, efuse: :load]
      ],
      # Single-file binary via Burrito (needs zig 0.15.x and xz on PATH):
      #   MIX_ENV=prod mix release supablock_burrito
      # Binaries land in burrito_out/. The bundled efuse FUSE port is a
      # native executable compiled on the build machine, so build each
      # platform's binary natively (no useful cross-targets).
      supablock_burrito: [
        include_executables_for: [:unix],
        strip_beams: true,
        applications: [userfs: :load, efuse: :load],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

  # Native target only (see note above). BURRITO_ERTS_PATH overrides where
  # the ERTS comes from (an unpacked OTP root, e.g. /usr/lib/erlang) for
  # build hosts that cannot reach Burrito's precompiled-ERTS CDN.
  defp burrito_targets do
    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        _other -> :linux
      end

    cpu =
      case to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _rest -> :aarch64
        "arm" <> _rest -> :aarch64
        _other -> :x86_64
      end

    case System.get_env("BURRITO_ERTS_PATH") do
      nil -> [native: [os: os, cpu: cpu]]
      path -> [native: [os: os, cpu: cpu, custom_erts: path]]
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:userfs, path: "vendor/userfs", runtime: false},
      {:efuse, path: "vendor/efuse", override: true, runtime: false},
      {:castore, path: "vendor/castore", override: true},
      {:req, "~> 0.5.18"},
      {:jason, "~> 1.4"},
      {:francis, "~> 0.3.3"},
      {:burrito, "~> 1.5.0", runtime: false}
    ]
  end
end
