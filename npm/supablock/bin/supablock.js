#!/usr/bin/env node
"use strict";

// Thin launcher for the real Burrito binary, which ships inside the
// platform package matching this machine (an optionalDependency, so npm
// downloads exactly one). The binary must live inside the npm tarball —
// a postinstall that fetched it from GitHub releases would defeat the
// point of this channel, which is sandboxes whose egress allows
// registry.npmjs.org but blocks GitHub's release CDN.

const { spawnSync } = require("child_process");
const os = require("os");

const PLATFORM_PACKAGES = {
  "linux-x64": "supablock-linux-x64",
  "linux-arm64": "supablock-linux-arm64",
  "darwin-arm64": "supablock-darwin-arm64",
};

// Exit code 4 = environment problem, matching the CLI's own convention.
const EX_ENVIRONMENT = 4;

const key = `${process.platform}-${process.arch}`;
const pkg = PLATFORM_PACKAGES[key];
if (!pkg) {
  console.error(
    `supablock: no prebuilt binary for ${key} ` +
      `(available: ${Object.keys(PLATFORM_PACKAGES).join(", ")}).\n` +
      "Build from source instead: " +
      "https://github.com/filipecabaco/supablock#building-from-source"
  );
  process.exit(EX_ENVIRONMENT);
}

let bin;
try {
  bin = require.resolve(`${pkg}/bin/supablock`);
} catch {
  console.error(
    `supablock: the ${pkg} package is missing.\n` +
      "It is an optionalDependency of supablock — reinstall without " +
      "--omit=optional / --no-optional so npm can fetch it."
  );
  process.exit(EX_ENVIRONMENT);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(`supablock: failed to run ${bin}: ${result.error.message}`);
  process.exit(EX_ENVIRONMENT);
}
if (result.signal) {
  // Shell convention (128 + signal number), so documented exit codes that
  // are really signal deaths — 141 = SIGPIPE — survive the shim.
  process.exit(128 + (os.constants.signals[result.signal] || 0));
}
process.exit(result.status);
