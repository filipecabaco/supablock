defmodule Superblock.MixProject do
  use Mix.Project

  def project do
    [
      app: :superblock,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      default_release: :superblock,
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Superblock.Application, []}
    ]
  end

  defp releases do
    [
      # Classic release, used by bin/superblock (the thin launcher) and the
      # e2e suite: MIX_ENV=prod mix release
      superblock: [
        include_executables_for: [:unix],
        strip_beams: true,
        # userfs/efuse are runtime: false deps (CLI commands like `login`
        # must not start the FUSE machinery); `mount` starts them on demand.
        applications: [userfs: :load, efuse: :load]
      ],
      # Single-file binary via Burrito (needs zig 0.15.x and xz on PATH):
      #   MIX_ENV=prod mix release superblock_burrito
      # Binaries land in burrito_out/. The bundled efuse FUSE port is a
      # native executable compiled on the build machine, so build each
      # platform's binary natively (no useful cross-targets).
      superblock_burrito: [
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

  # hex.pm is not reachable from the environment this project is developed
  # in, so every dependency is pinned as a git tag or vendored:
  #
  #   * userfs/efuse — vendored (with patches; see vendor/*/mix.exs) because
  #     upstream needed fixes: libfuse3 port, read-only mount, single-threaded
  #     loop, bounded reply buffer, errno passthrough, stale-mount watchdog.
  #   * req and its transitive closure — git tags matching the hex releases.
  defp deps do
    [
      {:userfs, path: "vendor/userfs", runtime: false},
      {:efuse, path: "vendor/efuse", override: true, runtime: false},
      {:req, git: "https://github.com/wojtekmach/req.git", tag: "v0.5.18", override: true},
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4", override: true},
      {:finch, git: "https://github.com/sneako/finch.git", tag: "v0.20.0", override: true},
      {:mint, git: "https://github.com/elixir-mint/mint.git", tag: "v1.9.1", override: true},
      {:hpax, git: "https://github.com/elixir-mint/hpax.git", tag: "v1.0.4", override: true},
      {:mime, git: "https://github.com/elixir-plug/mime.git", tag: "v2.0.7", override: true},
      {:nimble_options,
       git: "https://github.com/dashbitco/nimble_options.git", tag: "v1.1.1", override: true},
      {:nimble_pool,
       git: "https://github.com/dashbitco/nimble_pool.git", tag: "v1.1.0", override: true},
      {:telemetry,
       git: "https://github.com/beam-telemetry/telemetry.git", tag: "v1.3.0", override: true},
      {:castore, path: "vendor/castore", override: true},
      # Build-time only: wraps the release into a single-file binary.
      {:burrito,
       git: "https://github.com/burrito-elixir/burrito.git", tag: "v1.5.0", runtime: false},
      {:typed_struct,
       git: "https://github.com/ejpcmac/typed_struct.git",
       tag: "v0.3.0",
       override: true,
       runtime: false},
      # OAuth login callback server: Francis (route DSL) on top of Bandit.
      # Started on demand during `superblock login` only — boot stays a no-op.
      {:francis, git: "https://github.com/filipecabaco/francis.git", tag: "v0.3.3"},
      {:bandit, git: "https://github.com/mtrudel/bandit.git", tag: "1.11.1", override: true},
      {:thousand_island,
       git: "https://github.com/mtrudel/thousand_island.git", tag: "1.4.3", override: true},
      {:websock,
       git: "https://github.com/phoenixframework/websock.git", tag: "0.5.3", override: true},
      {:websock_adapter,
       git: "https://github.com/phoenixframework/websock_adapter.git", tag: "0.5.9", override: true},
      {:plug, git: "https://github.com/elixir-plug/plug.git", tag: "v1.20.1", override: true},
      {:plug_crypto,
       git: "https://github.com/elixir-plug/plug_crypto.git", tag: "v2.1.1", override: true}
    ]
  end
end
