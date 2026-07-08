# Vendored from https://github.com/elixir-mint/castore v1.0.19 (Apache-2.0).
# Only the runtime module and the certificate bundle are kept: the upstream
# git checkout ships a dev-only mix task (certdata) that cannot compile as a
# prod dependency, and hex.pm (where the pruned package lives) is not
# reachable from this project's build environment.
defmodule CAStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :castore,
      version: "1.0.19",
      elixir: "~> 1.0",
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
