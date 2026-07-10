#!/bin/sh
# Entrypoint for the filipecabaco/supablock image.
#
# Default behaviour (no args, or a non-supablock command):
#   1. log in if the credentials volume is empty (dashboard session flow —
#      open the printed URL on the host, type the verification code here)
#   2. mount the account at $SUPABLOCK_MOUNTPOINT (default /supabase)
#   3. drop into a shell at the mountpoint — or run the given command there
#
# A first arg that is a supablock subcommand bypasses all of that:
#   docker run --rm -it ... filipecabaco/supablock status
set -eu

MOUNTPOINT="${SUPABLOCK_MOUNTPOINT:-/supabase}"
CREDENTIALS="${XDG_CONFIG_HOME:-$HOME/.config}/supablock/credentials"

# Pass supablock subcommands straight through.
case "${1:-}" in
    setup|login|logout|status|whoami|doctor|config|mount|unmount|refresh|service|help|-h|--help)
        exec supablock "$@"
        ;;
esac

if [ ! -c /dev/fuse ]; then
    cat >&2 <<'EOF'
/dev/fuse is not available in this container. Run the image with:

  docker run -it --rm \
    --device /dev/fuse --cap-add SYS_ADMIN \
    --security-opt apparmor=unconfined \
    -v supablock-config:/root/.config/supablock \
    filipecabaco/supablock
EOF
    exit 4
fi

# First run: no stored credential and no token in the environment.
if [ ! -s "$CREDENTIALS" ] && [ -z "${SUPABLOCK_TOKEN:-}" ]; then
    if [ -t 0 ]; then
        echo "No credential found — starting login (stored in the volume at $CREDENTIALS)."
        supablock login --no-browser
    else
        cat >&2 <<'EOF'
Not authenticated and no TTY to run the login flow. Either:
  * run interactively once (-it) so the login flow can prompt you, keeping
    the credentials volume: -v supablock-config:/root/.config/supablock
  * or pass a personal access token: -e SUPABLOCK_TOKEN=sbp_...
EOF
        exit 2
    fi
fi

mkdir -p "$MOUNTPOINT"
supablock mount "$MOUNTPOINT"

# `mount` returns immediately (background daemon); wait for the kernel mount.
tries=0
until grep -q " $MOUNTPOINT " /proc/mounts; do
    tries=$((tries + 1))
    if [ "$tries" -gt 75 ]; then
        echo "Mount did not come up at $MOUNTPOINT. Recent log:" >&2
        tail -n 20 "$HOME/.local/state/supablock/supablock.log" >&2 || true
        exit 4
    fi
    sleep 0.2
done

cd "$MOUNTPOINT"

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

cat <<EOF

  Supabase account mounted at $MOUNTPOINT (read-only).
  Try:  ls organizations
        cat organizations/*/projects/*/health
  Exiting this shell stops the container and unmounts.

EOF
exec sh
