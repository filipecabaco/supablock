#!/usr/bin/env bash
# Publishes the npm channel for a release: one package per platform, each
# carrying that target's Burrito binary, then the "supablock" meta package
# whose optionalDependencies pin them at the exact same version. npm exists
# as a channel because restricted sandboxes (CI, AI agents) commonly
# allowlist registry.npmjs.org while blocking the GitHub Pages installer
# and GitHub's release-asset CDN — and npm only delivers binaries that are
# inside the tarball, so the binaries are packed here, never downloaded by
# an install script.
#
#   npm/publish.sh <version> <dist-dir>
#
# <dist-dir> holds the release assets under their published names
# (supablock-linux-x86_64 etc.). Auth comes from NODE_AUTH_TOKEN (the
# actions/setup-node convention). NPM_DRY_RUN=1 stages and packs the
# tarballs into npm/out/ without touching the registry.
set -euo pipefail

VERSION="${1:?usage: publish.sh <version> <dist-dir>}"
DIST="$(cd "${2:?usage: publish.sh <version> <dist-dir>}" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"

# release asset name -> package suffix, process.platform, process.arch
TARGETS=(
  "supablock-linux-x86_64  linux-x64    linux  x64"
  "supablock-linux-aarch64 linux-arm64  linux  arm64"
  "supablock-macos-aarch64 darwin-arm64 darwin arm64"
)

if [ -z "${NODE_AUTH_TOKEN:-}" ] && [ -z "${NPM_DRY_RUN:-}" ]; then
  echo "NODE_AUTH_TOKEN not set — skipping npm publish (set the NPM_TOKEN repo secret to enable)"
  exit 0
fi

# All platforms or none: the meta package pins every platform package at
# this exact version, so publishing with one binary missing would brick
# installs on that platform while the release looks fine elsewhere.
for t in "${TARGETS[@]}"; do
  read -r asset _ <<<"$t"
  if [ ! -f "$DIST/$asset" ]; then
    echo "missing $DIST/$asset — refusing to publish a partial npm release" >&2
    exit 1
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT"

publish() {
  local dir="$1"
  local name
  name="$(node -p "require('$dir/package.json').name")"
  if [ -n "${NPM_DRY_RUN:-}" ]; then
    (cd "$dir" && npm pack --silent --pack-destination "$OUT" >/dev/null)
    echo "staged $name@$VERSION (dry run)"
    return
  fi
  # Re-runs of the publish job must not fail on already-published versions.
  if [ "$(npm view "$name@$VERSION" version 2>/dev/null || true)" = "$VERSION" ]; then
    echo "$name@$VERSION already on the registry — skipping"
    return
  fi
  local tag_args=()
  case "$VERSION" in *-*) tag_args=(--tag canary) ;; esac
  (cd "$dir" && npm publish --access public "${tag_args[@]}")
}

for t in "${TARGETS[@]}"; do
  read -r asset suffix osname cpu <<<"$t"
  pkgdir="$OUT/supablock-$suffix"
  mkdir -p "$pkgdir/bin"
  install -m 0755 "$DIST/$asset" "$pkgdir/bin/supablock"
  node - "$pkgdir" "supablock-$suffix" "$VERSION" "$osname" "$cpu" <<'EOF'
const fs = require("fs");
const [dir, name, version, os, cpu] = process.argv.slice(2);
fs.writeFileSync(
  `${dir}/package.json`,
  JSON.stringify(
    {
      name,
      version,
      description: `supablock prebuilt binary for ${os}-${cpu}`,
      repository: { type: "git", url: "git+https://github.com/filipecabaco/supablock.git" },
      os: [os],
      cpu: [cpu],
      preferUnplugged: true,
    },
    null,
    2
  ) + "\n"
);
EOF
  publish "$pkgdir"
done

# Meta package last, so it never points at platform versions that are not
# on the registry yet.
metadir="$OUT/supablock"
cp -R "$HERE/supablock" "$metadir"
node - "$metadir" "$VERSION" <<'EOF'
const fs = require("fs");
const [dir, version] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(`${dir}/package.json`, "utf8"));
pkg.version = version;
for (const name of Object.keys(pkg.optionalDependencies)) {
  pkg.optionalDependencies[name] = version;
}
fs.writeFileSync(`${dir}/package.json`, JSON.stringify(pkg, null, 2) + "\n");
EOF
publish "$metadir"
