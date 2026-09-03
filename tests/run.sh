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
  ( cd "$wd" || exit 1
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
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_BUMP_SNAPSHOT=false
check "new-version" "$(outval "$wd" new-version)" "1.2.4"
check "old-version" "$(outval "$wd" old-version)" "1.2.3"
check "changed"     "$(outval "$wd" changed)"     "true"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: snapshot mode rewrites existing Snapshot="
wd="$(workdir)"
printf '[Distribution]\nDistribution=debian\nSnapshot=20230101T000000Z\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_BUMP_VERSION=false FAKE_MKOSI_SNAPSHOT=20240202T000000Z
check "new-snapshot" "$(outval "$wd" new-snapshot)" "20240202T000000Z"
check "file updated"  "$(grep -c 'Snapshot=20240202T000000Z' "$wd/mkosi.conf")" "1"
check "old kept once" "$(grep -c 'Snapshot=' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: snapshot mode inserts Snapshot= under [Distribution] when missing"
wd="$(workdir)"
printf '[Distribution]\nDistribution=debian\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_BUMP_VERSION=false FAKE_MKOSI_SNAPSHOT=20240303T000000Z
check "inserted" "$(grep -c 'Snapshot=20240303T000000Z' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: no change when snapshot already current -> changed=false"
wd="$(workdir)"
printf '[Distribution]\nSnapshot=20240115T000000Z\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_BUMP_VERSION=false FAKE_MKOSI_SNAPSHOT=20240115T000000Z
check "changed" "$(outval "$wd" changed)" "false"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: latest-snapshot failure is fatal"
wd="$(workdir)"
printf '[Distribution]\nSnapshot=x\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_BUMP_VERSION=false FAKE_MKOSI_SNAPSHOT_RC=1
check "exit code" "$?" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: ToolsTreeSnapshot inserted into [Build], Snapshot untouched"
wd="$(workdir)"
printf '[Distribution]\nDistribution=arch\nSnapshot=20240101T000000Z\n\n[Build]\nToolsTree=default\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 \
  INPUT_BUMP_VERSION=false INPUT_BUMP_SNAPSHOT=false INPUT_BUMP_TOOLS_TREE_SNAPSHOT=true \
  INPUT_TOOLS_TREE_LATEST_SNAPSHOT_ARGS=--tools \
  FAKE_MKOSI_TT_SNAPSHOT=20240505T000000Z
check "tt output"    "$(outval "$wd" new-tools-tree-snapshot)" "20240505T000000Z"
check "tt in file"   "$(grep -c 'ToolsTreeSnapshot=20240505T000000Z' "$wd/mkosi.conf")" "1"
check "in [Build]"   "$(awk '/^\[Build\]/{b=1} b&&/ToolsTreeSnapshot=/{print "yes"; exit}' "$wd/mkosi.conf")" "yes"
check "Snapshot kept" "$(grep -c '^Snapshot=20240101T000000Z' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: both snapshot settings at once, different values"
wd="$(workdir)"
printf '[Distribution]\nSnapshot=old\n\n[Build]\nToolsTreeSnapshot=oldtt\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 \
  INPUT_BUMP_VERSION=false INPUT_BUMP_SNAPSHOT=true INPUT_BUMP_TOOLS_TREE_SNAPSHOT=true \
  INPUT_TOOLS_TREE_LATEST_SNAPSHOT_ARGS=--tools \
  FAKE_MKOSI_SNAPSHOT=newmain FAKE_MKOSI_TT_SNAPSHOT=newtt
check "main"     "$(outval "$wd" new-snapshot)" "newmain"
check "tt"       "$(outval "$wd" new-tools-tree-snapshot)" "newtt"
check "file main" "$(grep -c 'Snapshot=newmain' "$wd/mkosi.conf")" "1"
check "file tt"   "$(grep -c 'ToolsTreeSnapshot=newtt' "$wd/mkosi.conf")" "1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: both mode + tag prefix/suffix in version output"
wd="$(workdir)"; echo -n "0.1.0" > "$wd/mkosi.version"
printf '[Distribution]\nSnapshot=old\n' > "$wd/mkosi.conf"
run_bump "$wd" MKOSI_BUMP_DRY_RUN=1 INPUT_TAG_PREFIX=v INPUT_TAG_SUFFIX=-ci FAKE_MKOSI_SNAPSHOT=new
check "version" "$(outval "$wd" version)" "v0.1.1-ci"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: end-to-end commit + tag in a real git repo (no push)"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  echo -n "1.0.0" > mkosi.version
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init )
run_bump "$wd" INPUT_SKIP_PUSH=true INPUT_TAG_PREFIX=v FAKE_MKOSI_SNAPSHOT=s1
rc=$?
check "exit code" "$rc" "0"
check "committed"  "$(cd "$wd" && git log -1 --pretty=%s)" "Release v1.0.1"
check "tagged"     "$(cd "$wd" && git tag)" "v1.0.1"
check "new-tag out" "$(outval "$wd" new-tag)" "v1.0.1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: bump-version=patch increments the latest tag, leaves mkosi.version alone"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf '#!/bin/sh\necho scripted\n' > mkosi.version; chmod +x mkosi.version
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init
  git tag 0.8.3; git tag 0.8.4; git tag 0.10.0-rc1 )   # last one must be ignored
run_bump "$wd" INPUT_BUMP_VERSION=patch INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s1
check "exit code"      "$?" "0"
check "new-version"    "$(outval "$wd" new-version)" "0.8.5"
check "tagged"         "$(cd "$wd" && git tag --points-at HEAD)" "0.8.5"
check "script intact"  "$(head -n1 "$wd/mkosi.version")" "#!/bin/sh"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: bump-version=minor / major reset lower components"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init; git tag v1.2.3 )
run_bump "$wd" INPUT_BUMP_VERSION=minor INPUT_TAG_PREFIX=v INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s1
check "minor" "$(outval "$wd" new-version)" "1.3.0"
rm -rf "$wd"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init; git tag v1.2.3 )
run_bump "$wd" INPUT_BUMP_VERSION=major INPUT_TAG_PREFIX=v INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s1
check "major" "$(outval "$wd" new-version)" "2.0.0"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: bump-version=patch with no tags starts at 0.0.1"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init )
run_bump "$wd" INPUT_BUMP_VERSION=patch INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s1
check "first" "$(outval "$wd" new-version)" "0.0.1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: dispatch-workflow fires on the new tag after push"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init; git tag 0.1.0
  git init -q --bare "$wd/remote.git"; git remote add origin "$wd/remote.git"
  git push -q origin main )
cat > "$wd/bin/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$wd/gh.log"
EOF
chmod +x "$wd/bin/gh"
run_bump "$wd" INPUT_BUMP_VERSION=patch INPUT_DISPATCH_WORKFLOW=release.yml FAKE_MKOSI_SNAPSHOT=s1
check "dispatched" "$(cat "$wd/gh.log" 2>/dev/null)" "gh workflow run release.yml --ref 0.1.1"
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: semver bump skips when tree is identical to the last release"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf 'log\noutput\nbin/\n' > .gitignore   # the harness scaffolding
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init; git tag 0.1.0 )
# snapshot unchanged (s0), no new commits -> nothing to release
run_bump "$wd" INPUT_BUMP_VERSION=patch INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s0
check "changed" "$(outval "$wd" changed)" "false"
check "no tag"  "$(cd "$wd" && git tag -l 0.1.1)" ""
rm -rf "$wd"

# --------------------------------------------------------------------------
echo "test: semver bump releases when commits landed since the last tag"
wd="$(workdir)"; ( cd "$wd" || exit 1
  git init -q -b main; git config user.email a@b.c; git config user.name t
  printf 'log\noutput\nbin/\n' > .gitignore
  printf '[Distribution]\nSnapshot=s0\n' > mkosi.conf
  git add -A; git commit -qm init; git tag 0.1.0
  echo 'unreleased change' > NEWFILE; git add -A; git commit -qm 'a fix' )
run_bump "$wd" INPUT_BUMP_VERSION=patch INPUT_SKIP_PUSH=true FAKE_MKOSI_SNAPSHOT=s0
check "changed" "$(outval "$wd" changed)" "true"
check "new-tag" "$(outval "$wd" new-tag)" "0.1.1"
rm -rf "$wd"

# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
