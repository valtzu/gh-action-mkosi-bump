#!/usr/bin/env bash
# Integration test against a REAL mkosi install (whatever `mkosi` is on PATH).
# Exercises `mkosi bump` end to end; also `mkosi latest-snapshot` if available.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

echo "mkosi: $(mkosi --version)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r "$HERE/fixtures/bump/." "$work/"
cd "$work" || exit 1
git init -q -b main
git config user.email test@example.com
git config user.name test
git add -A && git commit -qm init

export GITHUB_OUTPUT="$work/gh_output"; : > "$GITHUB_OUTPUT"
outval() { sed -nE "s/^$1=(.*)/\1/p" "$GITHUB_OUTPUT" | tail -n1; }

# --- bump ---
INPUT_BUMP_SNAPSHOT=false INPUT_SKIP_PUSH=true INPUT_TAG_PREFIX=v \
  bash "$ROOT/scripts/bump.sh"

old="$(outval old-version)"; new="$(outval new-version)"
echo "bump: $old -> $new"
[ "$new" != "$old" ] || { echo "FAIL: version not bumped"; exit 1; }
[ "$(git log -1 --pretty=%s)" = "ci: bump mkosi packages to v${new}" ] || { echo "FAIL: commit subject"; exit 1; }
git rev-parse "v${new}" >/dev/null || { echo "FAIL: tag missing"; exit 1; }
echo "PASS: bump"

# --- Snapshot= via mkosi latest-snapshot (needs snapshot.debian.org reachable) ---
: > "$GITHUB_OUTPUT"
git checkout -q .
INPUT_BUMP_VERSION=false INPUT_SKIP_COMMIT=true MKOSI_BUMP_DRY_RUN=1 \
  bash "$ROOT/scripts/bump.sh"
snap="$(outval new-snapshot)"
[ -n "$snap" ] || { echo "FAIL: empty snapshot"; exit 1; }
grep -q "Snapshot=${snap}" mkosi.conf || { echo "FAIL: Snapshot= not written"; exit 1; }
echo "PASS: Snapshot -> $snap"

# --- ToolsTreeSnapshot= into [Build], with explicit tools-tree distro args ---
: > "$GITHUB_OUTPUT"
git checkout -q .
INPUT_BUMP_VERSION=false INPUT_BUMP_SNAPSHOT=false INPUT_BUMP_TOOLS_TREE_SNAPSHOT=true \
  INPUT_SKIP_COMMIT=true MKOSI_BUMP_DRY_RUN=1 \
  INPUT_TOOLS_TREE_LATEST_SNAPSHOT_ARGS="--distribution debian --release testing" \
  bash "$ROOT/scripts/bump.sh"
tt="$(outval new-tools-tree-snapshot)"
[ -n "$tt" ] || { echo "FAIL: empty tools-tree snapshot"; exit 1; }
grep -q "ToolsTreeSnapshot=${tt}" mkosi.conf || { echo "FAIL: ToolsTreeSnapshot= not written"; exit 1; }
awk '/^\[Build\]/{b=1} b&&/ToolsTreeSnapshot=/{ok=1} END{exit !ok}' mkosi.conf \
  || { echo "FAIL: ToolsTreeSnapshot= not under [Build]"; exit 1; }
echo "PASS: ToolsTreeSnapshot -> $tt"
