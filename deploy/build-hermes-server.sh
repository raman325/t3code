#!/usr/bin/env bash
# Build a deployable t3 tarball from the Hermes fork worktree.
#
# The bundle bakes in the relay/Clerk values from .env at build time, so T3
# Connect works against the production relay. Output is a plain npm tarball
# containing dist/ (server bundle + bundled web client).
#
# Usage: build-hermes-server.sh [worktree] [out-dir]
set -euo pipefail

WORKTREE="${1:-$HOME/projects/t3code-hermes}"
OUT_DIR="${2:-/tmp}"
export PATH="$HOME/.local/share/vite-plus/bin:$PATH"

cd "$WORKTREE"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "[build] seeded .env from .env.example (production relay + Clerk keys)"
fi

echo "[build] building CLI package (pulls in the web client)…"
vp run --filter t3 build

# pnpm `catalog:` specs are unresolvable by npm on the target host, so resolve
# them into concrete versions the way the repo's own publish path does, pack,
# then restore package.json.
cd apps/server
cp package.json /tmp/t3-pkg-backup.json
trap 'mv -f /tmp/t3-pkg-backup.json "$WORKTREE/apps/server/package.json" 2>/dev/null || true' EXIT
node -e '
const fs=require("fs"), YAML=require("yaml");
const cat=(YAML.parse(fs.readFileSync("../../pnpm-workspace.yaml","utf8")).catalog)||{};
const pkg=JSON.parse(fs.readFileSync("package.json","utf8"));
for (const [name,spec] of Object.entries(pkg.dependencies||{})) {
  if (typeof spec==="string" && spec.startsWith("catalog:")) {
    const key=spec.slice(8).trim()||name;
    if(!cat[key]) throw new Error("no catalog entry for "+key);
    pkg.dependencies[name]=cat[key];
  }
}
// devDependencies reference private workspace packages (@t3tools/*, workspace:*)
// that do not exist on npm; a consumer install never needs them.
delete pkg.devDependencies;
fs.writeFileSync("package.json", JSON.stringify(pkg,null,2)+"\n");
'
TARBALL="$(npm pack --pack-destination "$OUT_DIR" 2>/dev/null | tail -1)"
mv -f /tmp/t3-pkg-backup.json package.json
trap - EXIT
cd "$WORKTREE"

SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "[build] artifact: ${OUT_DIR}/${TARBALL}"
echo "[build] source:   ${BRANCH} @ ${SHA}"
echo "${OUT_DIR}/${TARBALL}"
