import Config

if config_env() == :prod do
  config :logger, level: :info
end

if config_env() == :test do
  config :logger, level: :warning
end
