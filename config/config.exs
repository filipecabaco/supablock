import Config

if config_env() == :prod do
  # `superblock mount --verbose` flips this to :debug at runtime.
  config :logger, level: :info
end
