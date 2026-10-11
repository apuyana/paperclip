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

SHA="$(git rev-parse HEAD)"
SHA12="${SHA:0:12}"
VERSION="$(node -e "process.stdout.write(JSON.parse(require('node:fs').readFileSync('cli/package.json','utf8')).version)")"
STAGING="$(mktemp -d)"
PAYLOAD="$STAGING/payload"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

mapfile -t PACKAGE_DIRS < <(node --input-type=module -e '
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
' "$REPO_ROOT")

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
    npm pack "$STAGED_PACKAGE" --pack-destination "$STAGING"
  else
    PAPERCLIP_RELEASE_REUSE_UI_DIST=1 corepack pnpm --dir "$DIR" pack --pack-destination "$STAGING"
  fi
  INDEX=$((INDEX + 1))
done

(cd "$REPO_ROOT/cli" && npm pack --pack-destination "$STAGING")

mapfile -t TARBALLS < <(find "$STAGING" -maxdepth 1 -name '*.tgz' -printf '%f\n' | sort)
CLI_TARBALL="paperclipai-${VERSION}.tgz"
WORKSPACE_COUNT=0
INSTALL_ARGS=()
for ENTRY in "${TARBALLS[@]}"; do
  if [[ "$ENTRY" == "$CLI_TARBALL" ]]; then
    continue
  fi
  WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))
  INSTALL_ARGS+=("$STAGING/$ENTRY")
done
if [[ ! -f "$STAGING/$CLI_TARBALL" || "$WORKSPACE_COUNT" -ne "${#PACKAGE_DIRS[@]}" ]]; then
  echo "Packaging produced ${WORKSPACE_COUNT} workspace tarballs; expected ${#PACKAGE_DIRS[@]}." >&2
  printf '  %s\n' "${TARBALLS[@]}" >&2
  exit 1
fi

npm install --prefix "$PAYLOAD" "$STAGING/$CLI_TARBALL" "${INSTALL_ARGS[@]}" --no-audit --no-fund

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
