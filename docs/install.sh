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
# The download is checked against the SHA256SUMS asset published alongside
# it by the release workflow. That only proves the release is internally
# consistent — for real provenance (which workflow, repo and commit built
# the binary) verify the sigstore attestation after installing:
#
#   gh attestation verify ~/.local/bin/supablock --repo filipecabaco/supablock
#
# Environment overrides:
#   SUPABLOCK_VERSION      release tag to install (default: latest, falling
#                           back to the rolling "canary" prerelease)
#   SUPABLOCK_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
#   SUPABLOCK_SHA256       expected digest, checked instead of SHA256SUMS
#                           (use when you pin a digest out of band)
#   SUPABLOCK_SKIP_VERIFY  set to 1 to install without checking the digest
#                           (only needed for releases predating SHA256SUMS)

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

# $1 = release tag ("latest" or a tag), $2 = asset name.
url_for() {
    if [ "$1" = "latest" ]; then
        printf 'https://github.com/%s/releases/latest/download/%s' "$REPO" "$2"
    else
        printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$1" "$2"
    fi
}

# sha256sum (Linux) or shasum -a 256 (macOS); prints the bare digest.
digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        return 1
    fi
}

tmp="$(mktemp)"
sums="$(mktemp)"
trap 'rm -f "$tmp" "$sums"' EXIT

# The resolved tag, so the checksums are fetched from the same release the
# binary came from — not from "latest" after a canary fallback.
release="$VERSION"

say "downloading $asset ($VERSION)..."
if ! curl -fsSL "$(url_for "$release" "$asset")" -o "$tmp"; then
    if [ "$VERSION" = "latest" ]; then
        say "no stable release yet — falling back to the canary build"
        release="canary"
        curl -fsSL "$(url_for "$release" "$asset")" -o "$tmp" ||
            fail "download failed; see https://github.com/$REPO/releases"
    else
        fail "download failed for version $VERSION; see https://github.com/$REPO/releases"
    fi
fi

actual="$(digest_of "$tmp")" ||
    fail "no sha256sum or shasum on PATH — cannot verify the download"

if [ "${SUPABLOCK_SKIP_VERIFY:-}" = "1" ]; then
    say "warning: skipping checksum verification (SUPABLOCK_SKIP_VERIFY=1)"
elif [ -n "${SUPABLOCK_SHA256:-}" ]; then
    [ "$actual" = "$SUPABLOCK_SHA256" ] ||
        fail "checksum mismatch for $asset
  expected $SUPABLOCK_SHA256 (SUPABLOCK_SHA256)
  got      $actual"
    say "verified against SUPABLOCK_SHA256"
else
    curl -fsSL "$(url_for "$release" SHA256SUMS)" -o "$sums" ||
        fail "could not fetch SHA256SUMS from the $release release.
Releases published before checksums existed have no such asset — pin a
digest with SUPABLOCK_SHA256=<sha256>, or set SUPABLOCK_SKIP_VERIFY=1 to
install unverified."

    expected="$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$sums")"
    [ -n "$expected" ] || fail "$asset is not listed in the $release SHA256SUMS"
    [ "$actual" = "$expected" ] ||
        fail "checksum mismatch for $asset
  expected $expected (SHA256SUMS)
  got      $actual
Do not run this file. Report it at https://github.com/$REPO/issues"
    say "verified against SHA256SUMS"
fi

say "sha256 $actual"

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
say "verify provenance (optional, needs the gh CLI):"
say "  gh attestation verify $INSTALL_DIR/supablock --repo $REPO"
say ""
say "next steps:"
say "  supablock doctor"
say "  supablock login"
say "  supablock mount"
