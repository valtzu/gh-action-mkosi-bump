#!/usr/bin/env bash
# Fast, dependency-free unit tests for scripts/bump.sh.
# Uses tests/fake-mkosi as a stand-in for the real CLI, so it runs anywhere.
# The real-mkosi matrix lives in .github/workflows/test.yml.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUMP="$ROOT/scripts/bump.sh"

pass=0 fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

workdir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin"
  cp "$HERE/fake-mkosi" "$d/bin/mkosi"
  chmod +x "$d/bin/mkosi"
  printf '%s' "$d"
}

run_bump() {
  # run_bump <workdir> KEY=VAL ...
  local wd="$1"; shift
  ( cd "$wd"
    export PATH="$wd/bin:$PATH"
    export GITHUB_OUTPUT="$wd/output"
    : > "$GITHUB_OUTPUT"
    env "$@" bash "$BUMP" >"$wd/log" 2>&1 )
  return $?
}
outval() { sed -nE "s/^$2=(.*)/\1/p" "$1/output" | tail -n1; }

# --------------------------------------------------------------------------
echo "test: bump mode increments mkosi.version"
wd="$(workdir)"; echo -n "1.2.3" > "$wd/mkosi.version"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=bump
check "new-version" "$(outval "$wd" new-version)" "1.2.4"
check "old-version" "$(outval "$wd" old-version)" "1.2.3"
check "changed"     "$(outval "$wd" changed)"     "true"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: snapshot mode rewrites existing Snapshot="
wd="$(workdir)"
printf '[Distribution]\nDistribution=debian\nSnapshot=20230101T000000Z\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=snapshot FAKE_MKOSI_SNAPSHOT=20240202T000000Z
check "new-snapshot" "$(outval "$wd" new-snapshot)" "20240202T000000Z"
check "file updated"  "$(grep -c 'Snapshot=20240202T000000Z' "$wd/mkosi.conf")" "1"
check "old kept once" "$(grep -c 'Snapshot=' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: snapshot mode inserts Snapshot= under [Distribution] when missing"
wd="$(workdir)"
printf '[Distribution]\nDistribution=debian\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=snapshot FAKE_MKOSI_SNAPSHOT=20240303T000000Z
check "inserted" "$(grep -c 'Snapshot=20240303T000000Z' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: no change when snapshot already current -> changed=false"
wd="$(workdir)"
printf '[Distribution]\nSnapshot=20240115T000000Z\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=snapshot FAKE_MKOSI_SNAPSHOT=20240115T000000Z
check "changed" "$(outval "$wd" changed)" "false"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: latest-snapshot failure is fatal"
wd="$(workdir)"
printf '[Distribution]\nSnapshot=x\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=snapshot FAKE_MKOSI_SNAPSHOT_RC=1
check "exit code" "$?" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: both mode + tag prefix/suffix in version output"
wd="$(workdir)"; echo -n "0.1.0" > "$wd/mkosi.version"
printf '[Distribution]\nSnapshot=old\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_MODE=both INPUT_TAG_PREFIX=v INPUT_TAG_SUFFIX=-ci FAKE_MKOSI_SNAPSHOT=new
check "version" "$(outval "$wd" version)" "v0.1.1-ci"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: end-to-end commit + tag in a real git repo (no push)"
wd="$(workdir)"; ( cd "$wd"
  git init -q -b main; git config user.email a@b.c; git config user.name t
  echo -n "1.0.0" > mkosi.version
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init )
run_bump "$wd" INPUT_MODE=both INPUT_SKIP_PUSH=true INPUT_TAG_PREFIX=v FAKE_MKOSI_SNAPSHOT=s1
rc=$?
check "exit code" "$rc" "0"
check "committed"  "$(cd "$wd" && git log -1 --pretty=%s)" "ci: bump mkosi packages to v1.0.1"
check "tagged"     "$(cd "$wd" && git tag)" "v1.0.1"
check "new-tag out" "$(outval "$wd" new-tag)" "v1.0.1"
rm -rf "$wd"

# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
