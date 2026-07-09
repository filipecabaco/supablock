# Vendored from https://github.com/mwri/elixir-userfs (MIT, Michael Wright).
# Modified for supablock: efuse comes from the sibling vendor directory,
# dev-only dependencies are dropped, and the supervision/port handling is
# modernised — see lib/userfs/server.ex and lib/userfs/mount_sup.ex.

defmodule Userfs.MixProject do
  use Mix.Project

  def project do
    [
      app: :userfs,
      version: "1.0.4",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Userfs.App, []},
      extra_applications: [:logger, :efuse]
    ]
  end

  defp deps do
    [
      {:efuse, path: "../efuse"}
    ]
  end
end
