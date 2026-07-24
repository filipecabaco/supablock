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

  @version "0.5.1"
  defp version, do: System.get_env("SUPABLOCK_BUILD_VERSION", @version)

  def application do
    [
      extra_applications: [:logger],
      mod: {Supablock.Application, []}
    ]
  end

  defp releases do
    [
      supablock: [
        include_executables_for: [:unix],
        strip_beams: true,
        applications: [userfs: :load, efuse: :load]
      ],
      supablock_burrito: [
        include_executables_for: [:unix],
        strip_beams: true,
        applications: [userfs: :load, efuse: :load],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

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
