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
cd "$work"
git init -q -b main
git config user.email test@example.com
git config user.name test
git add -A && git commit -qm init

export GITHUB_OUTPUT="$work/gh_output"; : > "$GITHUB_OUTPUT"
outval() { sed -nE "s/^$1=(.*)/\1/p" "$GITHUB_OUTPUT" | tail -n1; }

# --- bump ---
INPUT_MODE=bump INPUT_SKIP_PUSH=true INPUT_TAG_PREFIX=v \
  bash "$ROOT/scripts/bump.sh"

old="$(outval old-version)"; new="$(outval new-version)"
echo "bump: $old -> $new"
[ "$new" != "$old" ] || { echo "FAIL: version not bumped"; exit 1; }
[ "$(git log -1 --pretty=%s)" = "ci: bump mkosi packages to v${new}" ] || { echo "FAIL: commit subject"; exit 1; }
git rev-parse "v${new}" >/dev/null || { echo "FAIL: tag missing"; exit 1; }
echo "PASS: bump"

# --- latest-snapshot (best effort: needs a reachable mirror) ---
if mkosi latest-snapshot --help >/dev/null 2>&1; then
  : > "$GITHUB_OUTPUT"
  git checkout -q .
  if INPUT_MODE=snapshot INPUT_SKIP_COMMIT=true MKOSI_BUMP_DRY_RUN=1 \
       bash "$ROOT/scripts/bump.sh"; then
    echo "PASS: latest-snapshot -> $(outval new-snapshot)"
  else
    echo "SKIP: latest-snapshot failed (mirror unreachable?)"
  fi
else
  echo "SKIP: this mkosi has no latest-snapshot verb"
fi
