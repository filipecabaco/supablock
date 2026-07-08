# FUSE-level tests need /dev/fuse and a compiled port; the e2e suite
# additionally needs the supabase CLI and the prod release. Run explicitly:
#   mix test --include fuse
#   mix test --include e2e
ExUnit.start(exclude: [:fuse, :e2e])
