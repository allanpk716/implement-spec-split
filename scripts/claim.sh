#!/usr/bin/env bash
# Atomic spec worktree claims shared by all git worktrees of one repository.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LOCK="$HERE/lock.sh"
# shellcheck source=lib-owner.sh
source "$HERE/lib-owner.sh"

usage() {
  cat <<'EOF'
usage:
  claim.sh take <n> [--base <main branch>]
  claim.sh resume <n> [--force]
  claim.sh status <n>
  claim.sh release <n> [--force]
EOF
}

die() {
  echo "claim.sh: $*" >&2
  exit 64
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage >&2; exit 64; }
shift

SPEC=""
BASE_OPTION=""
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ -n "${2:-}" ] || die "--base needs a branch name"
      BASE_OPTION="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *)
      if [ -z "$SPEC" ]; then
        SPEC="$1"
      else
        die "unknown or repeated argument: $1"
      fi
      shift ;;
  esac
done

case "$COMMAND" in take|resume|status|release) ;; *) die "unknown command: $COMMAND" ;; esac
[[ "$SPEC" =~ ^[1-9][0-9]*$ ]] || die "spec number must be a positive integer"
BRANCH="spec-$SPEC"

GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || die "must run inside a Git repository"
GIT_COMMON=$(cd "$GIT_COMMON" && pwd)
CLAIM_DIR="$GIT_COMMON/implement-spec-split/claims"
CLAIM_FILE="$CLAIM_DIR/spec-$SPEC.json"
BRANCH_REF="refs/heads/$BRANCH"

mkdir -p "$CLAIM_DIR"

claim_branch_exists() {
  git show-ref --verify --quiet "$BRANCH_REF"
}

# Old integration branches were named spec-<n>-<role>. Ticket branches
# (spec-<n>-t<number>) and fix branches were independently coordinated and do not
# claim the integration branch.
claim_old_branch_exists() {
  local branch
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    [[ "$branch" =~ ^spec-${SPEC}-t[0-9]+$ ]] && continue
    [[ "$branch" =~ ^spec-${SPEC}-fix ]] && continue
    return 0
  done < <(git for-each-ref --format='%(refname:short)' "refs/heads/spec-$SPEC-*")
  return 1
}

claim_already_claimed() {
  claim_branch_exists || claim_old_branch_exists
}

claim_record_line() {
  CLAIM_FILE_ACT="$(printf '%s' "$CLAIM_FILE")" node -e '
    const fs = require("fs");
    try { process.stdout.write(fs.readFileSync(process.env.CLAIM_FILE_ACT, "utf8").trim()); }
    catch { process.stdout.write("none"); }
  '
}

claim_owner_fields() {
  CLAIM_FILE_ACT="$(printf '%s' "$CLAIM_FILE")" node -e '
    const fs = require("fs");
    const clean = v => String(v ?? "").replace(/[\t\n\r]+/g, " ");
    try {
      const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE_ACT, "utf8"));
      process.stdout.write([clean(c.pid), clean(c.pid_start)].join("\t"));
    } catch { process.stdout.write("\t"); }
  '
}

claim_print_state() {
  local record pid pid_start
  record=$(claim_record_line)
  if claim_already_claimed; then
    IFS=$'\t' read -r pid pid_start <<< "$(claim_owner_fields)"
    if [ -n "$pid" ] && owner_alive "$pid" "${pid_start:-}"; then
      echo "active $record"
    else
      echo "interrupted $record"
    fi
  else
    echo free
  fi
}

claim_main_worktree() {
  local first
  first=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
  [ -n "$first" ] || return 1
  cd "$first" && pwd
}

claim_paths() {
  MAIN_WORKTREE=$(claim_main_worktree) || return 1
  REPO_PARENT=$(dirname "$MAIN_WORKTREE")
  REPO_NAME=$(basename "$MAIN_WORKTREE")
  WORKTREE_PATH="$REPO_PARENT/$REPO_NAME-wt/spec-$SPEC"
}

claim_default_base() {
  local ref
  if ref=$(git symbolic-ref --short --quiet refs/remotes/origin/HEAD 2>/dev/null) && \
     [[ "$ref" == origin/* ]]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  if ref=$(git rev-parse --abbrev-ref --quiet origin/HEAD 2>/dev/null) && \
     [[ "$ref" == origin/* ]]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  printf 'master'
}

claim_write_record() {
  CLAIM_DIR_ENV="$(printf '%s' "$CLAIM_DIR")" CLAIM_FILE_ENV="$(printf '%s' "$CLAIM_FILE")" \
  CLAIM_SPEC="$SPEC" CLAIM_BRANCH="$BRANCH" CLAIM_WORKTREE="$(printf '%s' "$WORKTREE_PATH")" \
  CLAIM_PID="$OWNER_PID" CLAIM_START="$(printf '%s' "$OWNER_PID_START")" \
  CLAIM_AT="$(owner_iso_now)" node -e '
    const fs = require("fs"), path = require("path");
    const e = process.env;
    const value = JSON.stringify({
      spec: +e.CLAIM_SPEC, branch: e.CLAIM_BRANCH, worktree: e.CLAIM_WORKTREE,
      pid: +e.CLAIM_PID, pid_start: e.CLAIM_START,
      claimed_at: e.CLAIM_AT
    });
    fs.mkdirSync(e.CLAIM_DIR_ENV, {recursive: true});
    const temporary = path.join(e.CLAIM_DIR_ENV, `spec-${e.CLAIM_SPEC}.json.$$`);
    fs.writeFileSync(temporary, value + "\n");
    fs.renameSync(temporary, e.CLAIM_FILE_ENV);
  '
}

OWNER_PID=""
OWNER_PID_START=""
claim_resolve_owner() {
  OWNER_PID=$(owner_resolve_pid) || return 1
  OWNER_PID_START=$(owner_start_for "$OWNER_PID")
  [ -n "$OWNER_PID_START" ]
}

CLAIM_LOCK_HELD=false
claim_release_lock() {
  if $CLAIM_LOCK_HELD; then
    CLAIM_LOCK_HELD=false
    "$LOCK" release claim --scope repo --owner-pid "$OWNER_PID" >/dev/null 2>&1 || true
  fi
}

claim_exit() {
  local rc="$1"
  trap - EXIT HUP INT TERM
  claim_release_lock
  exit "$rc"
}
trap 'claim_exit $?' EXIT
trap 'claim_exit 129' HUP
trap 'claim_exit 130' INT
trap 'claim_exit 143' TERM

claim_acquire_lock() {
  claim_resolve_owner || die "could not resolve claim owner"
  "$LOCK" acquire claim --scope repo --wait 60 --owner-pid "$OWNER_PID" >/dev/null || return
  CLAIM_LOCK_HELD=true
}

case "$COMMAND" in
  take)
    claim_paths || die "could not determine the main worktree"
    BASE="${BASE_OPTION:-$(claim_default_base)}"
    claim_acquire_lock || exit 2
    if claim_already_claimed; then
      claim_print_state
      exit 3
    fi

    attempt=1
    while :; do
      WORKTREE_OUTPUT=$(git worktree add -b "$BRANCH" "$WORKTREE_PATH" "$BASE" 2>&1)
      WORKTREE_STATUS=$?
      if [ "$WORKTREE_STATUS" -eq 0 ]; then
        break
      fi
      if printf '%s' "$WORKTREE_OUTPUT" | grep -q '\.lock' && [ "$attempt" -lt 3 ]; then
        attempt=$((attempt + 1))
        sleep 3
        continue
      fi
      printf '%s\n' "$WORKTREE_OUTPUT" >&2
      exit 1
    done
    claim_write_record
    printf '%s\n' "$WORKTREE_PATH"
    ;;

  resume)
    claim_branch_exists || { echo "claim.sh: branch $BRANCH does not exist" >&2; exit 3; }
    claim_paths || die "could not determine the main worktree"
    claim_acquire_lock || exit 2
    OLD_PID=""; OLD_START=""
    IFS=$'\t' read -r OLD_PID OLD_START <<< "$(claim_owner_fields)"
    if ! $FORCE && ! owner_same "$OWNER_PID" "$OWNER_PID_START" "${OLD_PID:-}" "${OLD_START:-}"; then
      [ -n "$OLD_PID" ] && owner_alive "$OLD_PID" "${OLD_START:-}" && {
        echo "claim.sh: spec $SPEC is actively held by pid $OLD_PID" >&2
        exit 3
      }
    fi
    claim_write_record
    ;;

  status)
    claim_print_state
    ;;

  release)
    claim_resolve_owner || die "could not resolve claim owner"
    claim_acquire_lock || exit 2
    if [ -f "$CLAIM_FILE" ]; then
      OLD_PID=""; OLD_START=""
      IFS=$'\t' read -r OLD_PID OLD_START <<< "$(claim_owner_fields)"
      if ! $FORCE && ! owner_same "$OWNER_PID" "$OWNER_PID_START" "${OLD_PID:-}" "${OLD_START:-}"; then
        echo "claim.sh: claim is held by another owner" >&2
        exit 3
      fi
      rm -f "$CLAIM_FILE"
    fi
    ;;
esac
