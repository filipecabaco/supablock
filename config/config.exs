import Config

if config_env() == :prod do
  config :logger, level: :info
end

if config_env() == :test do
  config :logger, level: :warning
  # Never open a real browser tab from the suite; fake_browser!/0 swaps in a stub.
  config :supablock, browser_opener: false
  # Never run systemctl/launchctl from the suite; TestEnv also redirects the
  # LaunchAgents dir into its tmp base.
  config :supablock, service_manager: false
end
