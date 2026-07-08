defmodule Superblock.MixProject do
  use Mix.Project

  def project do
    [
      app: :superblock,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: [
        superblock: [
          include_executables_for: [:unix],
          strip_beams: true,
          # userfs/efuse are runtime: false deps (CLI commands like `login`
          # must not start the FUSE machinery); `mount` starts them on demand.
          applications: [userfs: :load, efuse: :load]
        ]
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Superblock.Application, []}
    ]
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
      {:req, git: "https://github.com/wojtekmach/req.git", tag: "v0.5.18"},
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
      {:plug,
       git: "https://github.com/elixir-plug/plug.git", tag: "v1.20.1", override: true, only: :test},
      {:plug_crypto,
       git: "https://github.com/elixir-plug/plug_crypto.git",
       tag: "v2.1.1",
       override: true,
       only: :test}
    ]
  end
end
