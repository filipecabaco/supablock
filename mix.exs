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

  # Dependencies are declared with standard hex version requirements, except
  # for the two vendored packages:
  #
  #   * userfs/efuse — vendored (with patches; see vendor/*/mix.exs) because
  #     upstream needed fixes: libfuse3 port, read-only mount, single-threaded
  #     loop, bounded reply buffer, errno passthrough, stale-mount watchdog.
  #     castore is likewise vendored so it ships with the release.
  #
  # `mix deps.get` needs hex.pm reachable; if the build environment blocks it,
  # configure a hex mirror (HEX_MIRROR) or run deps.get where hex is available.
  defp deps do
    [
      {:userfs, path: "vendor/userfs", runtime: false},
      {:efuse, path: "vendor/efuse", override: true, runtime: false},
      {:req, "~> 0.5.18", override: true},
      {:jason, "~> 1.4.4", override: true},
      # The `database/` tree (row viewing) reads through a project's Data API
      # (PostgREST) over HTTPS with `req` — no direct database connection, and
      # no credential beyond a key fetched from the GET-only Management API.
      {:finch, "~> 0.20.0", override: true},
      {:mint, "~> 1.9.1", override: true},
      {:hpax, "~> 1.0.4", override: true},
      {:mime, "~> 2.0.7", override: true},
      {:nimble_options, "~> 1.1.1", override: true},
      {:nimble_pool, "~> 1.1.0", override: true},
      {:telemetry, "~> 1.3.0", override: true},
      {:castore, path: "vendor/castore", override: true},
      # Build-time only: wraps the release into a single-file binary.
      {:burrito, "~> 1.5.0", runtime: false},
      {:typed_struct, "~> 0.3.0", override: true, runtime: false},
      # OAuth login callback server: Francis (route DSL) on top of Bandit.
      # Started on demand during `supablock login` only — boot stays a no-op.
      {:francis, "~> 0.3.3"},
      {:bandit, "~> 1.11.1", override: true},
      {:thousand_island, "~> 1.4.3", override: true},
      {:websock, "~> 0.5.3", override: true},
      {:websock_adapter, "~> 0.5.9", override: true},
      {:plug, "~> 1.20.1", override: true},
      {:plug_crypto, "~> 2.1.1", override: true}
    ]
  end
end
