#!/usr/bin/env bash
# mkosi bump action - see action.yml for the input contract.
set -euo pipefail

log()  { printf '%s\n' "$*" >&2; }
group_begin() { printf '::group::%s\n' "$*" >&2; }
group_end()   { printf '::endgroup::\n' >&2; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# Fallbacks so the script is runnable outside GitHub Actions (test suite).
: "${GITHUB_OUTPUT:=/dev/null}"
: "${GITHUB_PATH:=/dev/null}"
: "${MKOSI_BUMP_DRY_RUN:=0}"

# Input defaults (kept in sync with action.yml).
: "${INPUT_BUMP_VERSION:=true}"
: "${INPUT_BUMP_SNAPSHOT:=true}"
: "${INPUT_BUMP_TOOLS_TREE_SNAPSHOT:=false}"
: "${INPUT_MKOSI_CONFIG:=}"
: "${INPUT_MKOSI_ARGS:=}"
: "${INPUT_LATEST_SNAPSHOT_ARGS:=}"
: "${INPUT_TOOLS_TREE_LATEST_SNAPSHOT_ARGS:=}"
: "${INPUT_GIT_USER_NAME:=github-actions[bot]}"
: "${INPUT_GIT_USER_EMAIL:=41898282+github-actions[bot]@users.noreply.github.com}"
[ -n "${INPUT_COMMIT_MESSAGE:-}" ] || INPUT_COMMIT_MESSAGE='ci: bump mkosi packages to {{version}}'
: "${INPUT_TAG_PREFIX:=}"
: "${INPUT_TAG_SUFFIX:=}"
: "${INPUT_SKIP_TAG:=false}"
: "${INPUT_SKIP_COMMIT:=false}"
: "${INPUT_SKIP_PUSH:=false}"
: "${INPUT_COMMIT_NO_VERIFY:=false}"
: "${INPUT_TARGET_BRANCH:=}"
: "${INPUT_PULL_REQUEST:=false}"
: "${INPUT_PULL_REQUEST_STRATEGY:=update}"
: "${INPUT_PULL_REQUEST_BRANCH:=mkosi-bump}"
: "${INPUT_BASE_BRANCH:=}"
[ -n "${INPUT_PULL_REQUEST_TITLE:-}" ] || INPUT_PULL_REQUEST_TITLE='ci: bump mkosi packages to {{version}}'
[ -n "${INPUT_PULL_REQUEST_BODY:-}" ]  || INPUT_PULL_REQUEST_BODY='{{summary}}'
: "${INPUT_PULL_REQUEST_LABELS:=}"

is_true() { [ "${1,,}" = "true" ] || [ "$1" = "1" ]; }

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

MKOSI=(mkosi)
# shellcheck disable=SC2206
[ -n "$INPUT_MKOSI_ARGS" ] && MKOSI+=($INPUT_MKOSI_ARGS)

command -v mkosi >/dev/null 2>&1 || die "mkosi not found on PATH (set install-mkosi: true or install it in a previous step)"
log "Using $("${MKOSI[@]}" --version 2>/dev/null | head -n1)"

# Which snapshot settings to update, derived from the per-setting toggles.
SNAPSHOT_SETTINGS=()
is_true "$INPUT_BUMP_SNAPSHOT"            && SNAPSHOT_SETTINGS+=(Snapshot)
is_true "$INPUT_BUMP_TOOLS_TREE_SNAPSHOT" && SNAPSHOT_SETTINGS+=(ToolsTreeSnapshot)

if ! is_true "$INPUT_BUMP_VERSION" && [ ${#SNAPSHOT_SETTINGS[@]} -eq 0 ]; then
  die "nothing to do: enable at least one of bump-version / bump-snapshot / bump-tools-tree-snapshot"
fi

###############################################################################
# 1. Capture current state
###############################################################################
read_version_file() {
  [ -f mkosi.version ] || return 0
  tr -d '[:space:]' < mkosi.version
}

# The config section each supported snapshot setting belongs to.
declare -A SETTING_SECTION=(
  [Snapshot]=Distribution
  [ToolsTreeSnapshot]=Build
)

# find_config <SettingName> -> path of the config file to edit for that setting.
find_config() {
  local name="$1" f
  if [ -n "$INPUT_MKOSI_CONFIG" ]; then printf '%s\n' "$INPUT_MKOSI_CONFIG"; return; fi
  for f in mkosi.conf mkosi.conf.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE "^\s*${name}=" "$f"; then printf '%s\n' "$f"; return; fi
  done
  [ -f mkosi.conf ] && { printf 'mkosi.conf\n'; return; }
  printf '\n'
}

read_setting() {
  local name="$1" f="$2"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sed -nE "s/^\s*${name}=\s*(.*[^[:space:]])\s*\$/\1/p" "$f" | tail -n1
}

OLD_VERSION="$(read_version_file)"
NEW_VERSION="$OLD_VERSION"
log "old version:  ${OLD_VERSION:-<none>}"

# Per-setting bookkeeping, populated in section 2.
declare -A OLD_SNAP NEW_SNAP SNAP_FILE
SNAPSHOT_SUMMARY=""

###############################################################################
# 2. Apply updates
###############################################################################
if is_true "$INPUT_BUMP_VERSION"; then
  group_begin "mkosi bump"
  "${MKOSI[@]}" bump
  group_end
  NEW_VERSION="$(read_version_file)"
  log "new version: ${NEW_VERSION:-<none>}"
fi

# update_snapshot <SettingName> <extra latest-snapshot args...>
update_snapshot() {
  local name="$1"; shift
  local section="${SETTING_SECTION[$name]:-Distribution}"
  local cfg old latest rc
  cfg="$(find_config "$name")"
  old="$(read_setting "$name" "$cfg")"
  SNAP_FILE[$name]="$cfg"
  OLD_SNAP[$name]="$old"

  # `--tools-tree=` disables the default tools tree for this call: `mkosi
  # latest-snapshot` otherwise looks for `curl` inside the (usually unbuilt)
  # tools tree. It only needs the host's curl. A later `--tools-tree=<path>` in
  # the user's args wins, so this stays overridable.
  group_begin "mkosi latest-snapshot ($name)"
  set +e
  latest="$("${MKOSI[@]}" latest-snapshot --tools-tree= "$@" 2>&1)"; rc=$?
  set -e
  group_end
  if [ $rc -ne 0 ]; then
    log "$latest"
    die "mkosi latest-snapshot failed for $name (rc=$rc)"
  fi
  latest="$(printf '%s\n' "$latest" | tail -n1 | tr -d '[:space:]')"
  log "$name: ${old:-<none>} -> $latest  (${cfg:-<none>})"
  NEW_SNAP[$name]="$latest"

  [ "$latest" = "$old" ] && return 0
  [ -n "$cfg" ] || die "could not determine which config file to write $name= to (set mkosi-config)"

  if grep -qE "^\s*${name}=" "$cfg"; then
    sed -i -E "s|^(\s*)${name}=.*|\1${name}=${latest}|" "$cfg"
  elif grep -qE "^\[${section}\]" "$cfg"; then
    sed -i -E "0,/^\[${section}\]/s||[${section}]\n${name}=${latest}|" "$cfg"
  else
    printf '\n[%s]\n%s=%s\n' "$section" "$name" "$latest" >> "$cfg"
  fi
}

# `mkosi latest-snapshot` fetches over the network inside mkosi's sandbox, which
# needs an unprivileged user namespace. GitHub-hosted runners disable those via
# AppArmor; relax it when we can (best effort, ephemeral runner).
relax_userns() {
  local knob=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  [ -r "$knob" ] && [ "$(cat "$knob")" = 1 ] || return 0
  if sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null 2>&1; then
    log "relaxed kernel.apparmor_restrict_unprivileged_userns for the mkosi sandbox"
  else
    log "note: kernel.apparmor_restrict_unprivileged_userns=1 and it could not be" \
        "relaxed (no passwordless sudo); 'mkosi latest-snapshot' may fail"
  fi
}
[ ${#SNAPSHOT_SETTINGS[@]} -gt 0 ] && relax_userns

for s in "${SNAPSHOT_SETTINGS[@]}"; do
  case "$s" in
    Snapshot)          # shellcheck disable=SC2086
      update_snapshot Snapshot $INPUT_LATEST_SNAPSHOT_ARGS ;;
    ToolsTreeSnapshot)
      _tt_args="${INPUT_TOOLS_TREE_LATEST_SNAPSHOT_ARGS:-$INPUT_LATEST_SNAPSHOT_ARGS}"
      # shellcheck disable=SC2086
      update_snapshot ToolsTreeSnapshot $_tt_args ;;
  esac
done

# Primary snapshot values exposed to templates / outputs.
OLD_SNAPSHOT="${OLD_SNAP[Snapshot]:-}"
NEW_SNAPSHOT="${NEW_SNAP[Snapshot]:-$OLD_SNAPSHOT}"
OLD_TT_SNAPSHOT="${OLD_SNAP[ToolsTreeSnapshot]:-}"
NEW_TT_SNAPSHOT="${NEW_SNAP[ToolsTreeSnapshot]:-$OLD_TT_SNAPSHOT}"

for s in "${!NEW_SNAP[@]}"; do
  if [ "${NEW_SNAP[$s]}" != "${OLD_SNAP[$s]}" ]; then
    SNAPSHOT_SUMMARY+=$'\n'"- ${s}: \`${OLD_SNAP[$s]:-none}\` → \`${NEW_SNAP[$s]}\` (\`${SNAP_FILE[$s]}\`)"
  fi
done

FULL_VERSION="${INPUT_TAG_PREFIX}${NEW_VERSION}${INPUT_TAG_SUFFIX}"

###############################################################################
# 3. Did anything change?
###############################################################################
CHANGED=false
if git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --quiet || CHANGED=true
  # also catch new untracked files (e.g. first-time mkosi.version)
  [ -z "$(git status --porcelain)" ] || CHANGED=true
else
  [ "$NEW_VERSION" != "$OLD_VERSION" ] && CHANGED=true
  for s in "${!NEW_SNAP[@]}"; do
    [ "${NEW_SNAP[$s]}" != "${OLD_SNAP[$s]}" ] && CHANGED=true
  done
fi

out changed "$CHANGED"
out old-version "$OLD_VERSION"
out new-version "$NEW_VERSION"
out version "$FULL_VERSION"
out old-snapshot "$OLD_SNAPSHOT"
out new-snapshot "$NEW_SNAPSHOT"
out old-tools-tree-snapshot "$OLD_TT_SNAPSHOT"
out new-tools-tree-snapshot "$NEW_TT_SNAPSHOT"
out new-tag ""
out pull-request-number ""
out pull-request-url ""

if [ "$CHANGED" != "true" ]; then
  log "Nothing changed, done."
  exit 0
fi

###############################################################################
# 4. Render templates
###############################################################################
render() {
  local s="$1"
  s="${s//\{\{version\}\}/$FULL_VERSION}"
  s="${s//\{\{snapshot\}\}/$NEW_SNAPSHOT}"
  s="${s//\{\{tools_tree_snapshot\}\}/$NEW_TT_SNAPSHOT}"
  s="${s//\{\{old_version\}\}/$OLD_VERSION}"
  s="${s//\{\{old_snapshot\}\}/$OLD_SNAPSHOT}"
  s="${s//\{\{summary\}\}/$SUMMARY}"
  printf '%s' "$s"
}

SUMMARY="Automated mkosi update:"$'\n'
[ "$NEW_VERSION" != "$OLD_VERSION" ] && SUMMARY+=$'\n'"- version: \`${OLD_VERSION:-none}\` → \`${NEW_VERSION}\`"
SUMMARY+="$SNAPSHOT_SUMMARY"

COMMIT_MSG="$(render "$INPUT_COMMIT_MESSAGE")"
log "commit message: $COMMIT_MSG"

if is_true "$MKOSI_BUMP_DRY_RUN"; then
  log "MKOSI_BUMP_DRY_RUN set - skipping git/gh operations."
  exit 0
fi

if is_true "$INPUT_SKIP_COMMIT"; then
  log "skip-commit set - leaving changes uncommitted."
  exit 0
fi

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

###############################################################################
# 5. Commit + tag + (push | pull request)
###############################################################################
git config user.name  "$INPUT_GIT_USER_NAME"
git config user.email "$INPUT_GIT_USER_EMAIL"

COMMIT_ARGS=(--all --message "$COMMIT_MSG")
is_true "$INPUT_COMMIT_NO_VERIFY" && COMMIT_ARGS+=(--no-verify)

default_branch() {
  git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' \
    || echo "${GITHUB_REF_NAME:-main}"
}

make_tag() {
  is_true "$INPUT_SKIP_TAG" && return 0
  git tag -f "$FULL_VERSION" -m "$COMMIT_MSG"
  out new-tag "$FULL_VERSION"
}

if ! is_true "$INPUT_PULL_REQUEST"; then
  # ---- direct commit to target branch (phips28-style) ----
  BRANCH="${INPUT_TARGET_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}}"
  log "committing to $BRANCH"
  if [ -n "$INPUT_TARGET_BRANCH" ] && [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
    # move the working-tree changes onto the requested branch
    git stash push --include-untracked --message mkosi-bump >/dev/null 2>&1 || true
    git fetch origin "$BRANCH" || true
    git checkout -B "$BRANCH" "origin/$BRANCH" 2>/dev/null || git checkout -B "$BRANCH"
    git stash pop >/dev/null 2>&1 || true
  fi
  git commit "${COMMIT_ARGS[@]}"
  make_tag
  if ! is_true "$INPUT_SKIP_PUSH"; then
    git push origin "HEAD:$BRANCH" --follow-tags
  fi
  exit 0
fi

# ---- pull request mode ----
BASE="${INPUT_BASE_BRANCH:-$(default_branch)}"
STRATEGY="$INPUT_PULL_REQUEST_STRATEGY"
HEAD="$INPUT_PULL_REQUEST_BRANCH"
if [ "$STRATEGY" = "new" ]; then
  slug="$(printf '%s' "${FULL_VERSION}-${NEW_SNAPSHOT}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  HEAD="${HEAD}/${slug}"
fi
log "PR mode: base=$BASE head=$HEAD strategy=$STRATEGY"

# Stash the working-tree changes, move onto a fresh branch from base, re-apply.
git stash push --include-untracked --message mkosi-bump >/dev/null 2>&1 || true
git fetch origin "$BASE"
git checkout -B "$HEAD" "origin/$BASE"
git stash pop >/dev/null 2>&1 || true

git commit "${COMMIT_ARGS[@]}"
# Tags are intentionally not created in PR mode - tag when the PR is merged.

PUSH_ARGS=(origin "HEAD:$HEAD")
[ "$STRATEGY" = "update" ] && PUSH_ARGS+=(--force)
git push "${PUSH_ARGS[@]}"

command -v gh >/dev/null 2>&1 || die "gh CLI not available for PR creation"

PR_TITLE="$(render "$INPUT_PULL_REQUEST_TITLE")"
PR_BODY="$(render "$INPUT_PULL_REQUEST_BODY")"

existing="$(gh pr list --head "$HEAD" --base "$BASE" --state open --json number,url --jq '.[0] // empty' 2>/dev/null || true)"
if [ -n "$existing" ]; then
  num="$(printf '%s' "$existing" | sed -nE 's/.*"number":([0-9]+).*/\1/p')"
  url="$(printf '%s' "$existing" | sed -nE 's/.*"url":"([^"]+)".*/\1/p')"
  log "updating existing PR #$num"
  gh pr edit "$num" --title "$PR_TITLE" --body "$PR_BODY" >/dev/null || true
else
  url="$(gh pr create --base "$BASE" --head "$HEAD" --title "$PR_TITLE" --body "$PR_BODY")"
  num="$(printf '%s' "$url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p')"
  log "created PR #$num"
fi

if [ -n "$INPUT_PULL_REQUEST_LABELS" ]; then
  gh pr edit "$num" --add-label "$INPUT_PULL_REQUEST_LABELS" >/dev/null || log "could not add labels"
fi

out pull-request-number "$num"
out pull-request-url "$url"
