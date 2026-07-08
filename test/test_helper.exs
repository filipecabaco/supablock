# FUSE-level tests need /dev/fuse and a compiled port; run them explicitly:
#   mix test --include fuse
ExUnit.start(exclude: [:fuse])
