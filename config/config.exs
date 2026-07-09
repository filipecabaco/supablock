import Config

if config_env() == :prod do
  # `supablock mount --verbose` flips this to :debug at runtime.
  config :logger, level: :info
end

if config_env() == :test do
  # The FUSE tests log every getattr/readdir/read at :debug; keep the suite
  # (and CI logs) readable by only surfacing warnings and above.
  config :logger, level: :warning
end
