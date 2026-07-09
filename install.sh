#!/bin/sh
# supablock installer — https://filipecabaco.github.io/supablock
#
#   curl -fsSL https://filipecabaco.github.io/supablock/install.sh | sh
#
# Downloads the single-file supablock binary for this platform from the
# GitHub releases of filipecabaco/supablock and installs it. No Erlang or
# Elixir needed; on Linux the FUSE userspace library is built in, on macOS
# you additionally need macFUSE (https://macfuse.github.io) or FUSE-T.
#
# Environment overrides:
#   SUPABLOCK_VERSION      release tag to install (default: latest, falling
#                           back to the rolling "canary" prerelease)
#   SUPABLOCK_INSTALL_DIR  where to put the binary (default: ~/.local/bin)

set -eu

REPO="filipecabaco/supablock"
VERSION="${SUPABLOCK_VERSION:-latest}"
INSTALL_DIR="${SUPABLOCK_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) fail "unsupported OS: $(uname -s) (supablock runs on Linux and macOS)" ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac

# Prebuilt binaries: linux x86_64/aarch64 and macos aarch64 (Apple silicon).
# Intel Macs are not prebuilt — build from source instead.
if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
    fail "no prebuilt binary for Intel macOS — build from source:
  https://github.com/$REPO#building-from-source"
fi

asset="supablock-${os}-${arch}"

url_for() {
    if [ "$1" = "latest" ]; then
        printf 'https://github.com/%s/releases/latest/download/%s' "$REPO" "$asset"
    else
        printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$1" "$asset"
    fi
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

say "downloading $asset ($VERSION)..."
if ! curl -fsSL "$(url_for "$VERSION")" -o "$tmp"; then
    if [ "$VERSION" = "latest" ]; then
        say "no stable release yet — falling back to the canary build"
        curl -fsSL "$(url_for canary)" -o "$tmp" ||
            fail "download failed; see https://github.com/$REPO/releases"
    else
        fail "download failed for version $VERSION; see https://github.com/$REPO/releases"
    fi
fi

mkdir -p "$INSTALL_DIR"
install -m 755 "$tmp" "$INSTALL_DIR/supablock"

say "installed $INSTALL_DIR/supablock"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) say "note: $INSTALL_DIR is not on your PATH — add it, e.g.:"
       say "  export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
esac

if [ "$os" = "macos" ]; then
    say "note: macOS needs macFUSE (https://macfuse.github.io) or FUSE-T installed"
fi

say ""
say "next steps:"
say "  supablock doctor"
say "  supablock login"
say "  supablock mount"
