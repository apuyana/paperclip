#!/usr/bin/env bash
# Pack the managed install payload that `installGitPayload` leaves under
# ~/.paperclip/cli/installs/git/<sha12>/. The checkout must already be built
# the same way that command builds it (pnpm install, scripts/build-npm.sh,
# then `pnpm -r --filter @paperclipai/server... run build`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-"$REPO_ROOT/dist-payload"}"
mkdir -p "$OUT_DIR"

cd "$REPO_ROOT"
unset NODE_ENV

if [[ ! -f cli/dist/index.js ]]; then
  echo "cli/dist/index.js is missing. Run scripts/build-npm.sh before packing." >&2
  exit 1
fi

# @paperclipai/server lists ui-dist and skills in `files`. The release flow
# creates both before packaging; a fresh checkout has neither.
bash "$REPO_ROOT/scripts/prepare-server-ui-dist.sh"
for pkg_dir in server packages/adapters/claude-local packages/adapters/codex-local; do
  rm -rf "$REPO_ROOT/$pkg_dir/skills"
  cp -r "$REPO_ROOT/skills" "$REPO_ROOT/$pkg_dir/skills"
done

SHA="$(git rev-parse HEAD)"
SHA12="${SHA:0:12}"
VERSION="$(node -e "process.stdout.write(JSON.parse(require('node:fs').readFileSync('cli/package.json','utf8')).version)")"
STAGING="$(mktemp -d)"
PAYLOAD="$STAGING/payload"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

PACKAGE_LIST="$(node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
const checkoutPath = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(path.join(checkoutPath, "scripts/release-package-manifest.json"), "utf8"));
const packageByName = new Map(manifest.map((entry) => [entry.name, entry]));
const visiting = new Set();
const visited = new Set();
const ordered = [];
const visit = (packageName) => {
  if (visited.has(packageName)) return;
  if (visiting.has(packageName)) throw new Error(`Circular workspace dependency while staging ${packageName}.`);
  const entry = packageByName.get(packageName);
  if (!entry) throw new Error(`Git install cannot stage workspace dependency ${packageName}; it is missing from scripts/release-package-manifest.json.`);
  visiting.add(packageName);
  const packageJson = JSON.parse(fs.readFileSync(path.join(checkoutPath, entry.dir, "package.json"), "utf8"));
  for (const section of ["dependencies", "optionalDependencies", "peerDependencies"]) {
    const dependencies = packageJson[section];
    if (!dependencies || typeof dependencies !== "object") continue;
    for (const dependencyName of Object.keys(dependencies)) {
      if (dependencyName.startsWith("@paperclipai/")) visit(dependencyName);
    }
  }
  visiting.delete(packageName);
  visited.add(packageName);
  ordered.push(entry.dir);
};
visit("@paperclipai/server");
process.stdout.write(ordered.join("\n") + "\n");
' "$REPO_ROOT")"
mapfile -t PACKAGE_DIRS <<< "$PACKAGE_LIST"

# npm ignores pnpm-lock.yaml, so a fresh resolve can give @paperclipai/shared
# and @paperclipai/server different zod 4 copies. Schemas built with one copy
# then break `z.toJSONSchema` from the other (ANU-726: project-tools MCP 500).
# Force every zod to the version the pnpm lockfile gives the server. Every
# zod consumer in the payload accepts it (ranges are ^4, or ^3.x || ^4).
ZOD_VERSION="$(node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  const pkg = path.join(process.argv[1], "server/node_modules/zod/package.json");
  process.stdout.write(JSON.parse(fs.readFileSync(fs.realpathSync(pkg), "utf8")).version);
' "$REPO_ROOT")"
if [[ "$ZOD_VERSION" != 4.* ]]; then
  echo "server resolves zod ${ZOD_VERSION:-<none>}; expected a zod 4 release." >&2
  exit 1
fi
# prepare-bundled-package.mjs applies the same pin to bundled closures.
export PAPERCLIP_BUNDLED_ZOD_VERSION="$ZOD_VERSION"

INDEX=0
for DIR in "${PACKAGE_DIRS[@]}"; do
  BUNDLED="$(node -e '
    const pkg = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const bundled = pkg.bundleDependencies ?? pkg.bundledDependencies ?? [];
    process.stdout.write(String(bundled.length));
  ' "$REPO_ROOT/$DIR/package.json")"
  if [[ "$BUNDLED" != "0" ]]; then
    STAGED_PACKAGE="$STAGING/workspace-package-$INDEX"
    node "$REPO_ROOT/scripts/prepare-bundled-package.mjs" "$REPO_ROOT/$DIR" "$STAGED_PACKAGE"
    npm pack "$STAGED_PACKAGE" --pack-destination "$STAGING" --ignore-scripts
  else
    PAPERCLIP_RELEASE_REUSE_UI_DIST=1 corepack pnpm --dir "$DIR" pack --pack-destination "$STAGING"
  fi
  INDEX=$((INDEX + 1))
done

(cd "$REPO_ROOT/cli" && npm pack --pack-destination "$STAGING")

mapfile -t TARBALLS < <(find "$STAGING" -maxdepth 1 -name '*.tgz' -printf '%f\n' | sort)
CLI_TARBALL="paperclipai-${VERSION}.tgz"
WORKSPACE_COUNT=0
for ENTRY in "${TARBALLS[@]}"; do
  if [[ "$ENTRY" == "$CLI_TARBALL" ]]; then
    continue
  fi
  WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))
done
if [[ ! -f "$STAGING/$CLI_TARBALL" || "$WORKSPACE_COUNT" -ne "${#PACKAGE_DIRS[@]}" ]]; then
  echo "Packaging produced ${WORKSPACE_COUNT} workspace tarballs; expected ${#PACKAGE_DIRS[@]}." >&2
  printf '  %s\n' "${TARBALLS[@]}" >&2
  exit 1
fi

# Workspace specs are rewritten to the parent package version (server 0.3.1
# asks for @paperclipai/plugin-sdk@0.3.1, but the packed sdk is 1.0.0). That
# version is not on the registry. Install every packed tarball and override
# the whole tree to those files.
mkdir -p "$PAYLOAD"
node --input-type=module -e '
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const staging = process.argv[1];
const payload = process.argv[2];
const specs = {};
for (const name of fs.readdirSync(staging).filter((entry) => entry.endsWith(".tgz"))) {
  const manifest = JSON.parse(execFileSync("tar", ["-xOf", path.join(staging, name), "package/package.json"], { encoding: "utf8" }));
  specs[manifest.name] = pathToFileURL(path.join(staging, name)).href;
}
const overrides = { ...specs, zod: process.argv[3] };
fs.writeFileSync(path.join(payload, "package.json"), JSON.stringify({ private: true, dependencies: specs, overrides }, null, 2) + "\n");
' "$STAGING" "$PAYLOAD" "$ZOD_VERSION"
npm install --prefix "$PAYLOAD" --no-audit --no-fund

# Fail when the installed tree still holds more than one zod 4 copy.
ZOD4_VERSIONS="$(find "$PAYLOAD/node_modules" -path '*/node_modules/zod/package.json' -print0 \
  | xargs -0 node -e '
    const fs = require("node:fs");
    const versions = new Set();
    for (const file of process.argv.slice(1)) {
      const { version } = JSON.parse(fs.readFileSync(file, "utf8"));
      if (version.startsWith("4.")) versions.add(version);
      console.error(`zod ${version} ${file}`);
    }
    process.stdout.write([...versions].sort().join(" "));
  ')"
if [[ "$ZOD4_VERSIONS" != "$ZOD_VERSION" ]]; then
  echo "Payload has zod 4 versions [${ZOD4_VERSIONS}]; expected only ${ZOD_VERSION}." >&2
  exit 1
fi

ENTRYPOINT="$PAYLOAD/node_modules/paperclipai/dist/index.js"
if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "Installed package is missing its CLI entrypoint: $ENTRYPOINT" >&2
  exit 1
fi
REPORTED="$(node "$ENTRYPOINT" --version | awk '{print $1}')"
if [[ "$REPORTED" != "$VERSION" ]]; then
  echo "Installed CLI smoke check reported ${REPORTED:-no version}; expected ${VERSION}." >&2
  exit 1
fi

ASSET="$OUT_DIR/paperclip-payload-${SHA12}.tar.gz"
META="$OUT_DIR/paperclip-payload-${SHA12}.json"
tar -C "$PAYLOAD" -czf "$ASSET" .
node -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    sha: process.argv[2],
    sha12: process.argv[3],
    version: process.argv[4],
    repo: "apuyana/paperclip",
    ref: "fork/slim-operational-skill",
    os: "linux",
    arch: "amd64",
  }, null, 2) + "\n");
' "$META" "$SHA" "$SHA12" "$VERSION"

echo "Packed $ASSET ($VERSION, $SHA12)"
