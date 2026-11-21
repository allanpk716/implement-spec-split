#!/usr/bin/env bash
# Read-only Orca progress display for one ticket or integration worktree.

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
WORKTREE=
BASE=
RUN_DIR=
INTERVAL=10
ONCE=0

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --worktree <ticket worktree> --base <integration branch>
                 [--run-dir <external worker run dir>] [--interval 10] [--once]
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --worktree)
      [ "$#" -ge 2 ] || usage_error '--worktree requires a path'
      [ -z "$WORKTREE" ] || usage_error '--worktree may only be given once'
      WORKTREE=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || usage_error '--base requires a branch'
      [ -z "$BASE" ] || usage_error '--base may only be given once'
      BASE=$2
      shift 2
      ;;
    --run-dir)
      [ "$#" -ge 2 ] || usage_error '--run-dir requires a path'
      [ -z "$RUN_DIR" ] || usage_error '--run-dir may only be given once'
      RUN_DIR=$2
      [ -n "$RUN_DIR" ] || usage_error '--run-dir cannot be empty'
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || usage_error '--interval requires a positive integer'
      INTERVAL=$2
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$WORKTREE" ] || usage_error '--worktree is required'
[ -n "$BASE" ] || usage_error '--base is required'
case "$INTERVAL" in
  ''|0|*[!0-9]*) usage_error '--interval must be a positive integer' ;;
esac

while :; do
  if [ ! -d "$WORKTREE" ]; then
    printf '%s\n' 'worktree 已清理，标签可关闭'
    exit 0
  fi

  # Keep the display read-only; git status otherwise takes opportunistic locks.
  printf '\033[2J\033[H'
  printf 'Ticket progress\n'
  printf 'Worktree: %s\n' "$WORKTREE"
  if BRANCH=$(GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" branch --show-current 2>&1); then
    printf 'Branch: %s\n' "$BRANCH"
  else
    printf 'Branch unavailable: %s\n' "$BRANCH"
  fi

  printf '\nCommits ahead of %s (max 20):\n' "$BASE"
  if COMMITS=$(GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" log --oneline --max-count=20 "$BASE..HEAD" 2>&1); then
    if [ -n "$COMMITS" ]; then
      printf '%s\n' "$COMMITS"
    else
      printf '%s\n' '(none)'
    fi
  else
    printf 'git log unavailable: %s\n' "$COMMITS"
  fi

  printf '\nWorking tree (max 30):\n'
  if STATUS=$(GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" status --short 2>&1); then
    if [ -n "$STATUS" ]; then
      printf '%s\n' "$STATUS" | awk 'NR <= 30 { print }'
    else
      printf '%s\n' '(clean)'
    fi
  else
    printf 'git status unavailable: %s\n' "$STATUS"
  fi

  printf '\n'
  if LAST_COMMIT=$(GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" log -1 --format='last commit: %cI (%cr)' 2>&1); then
    printf '%s\n' "$LAST_COMMIT"
  else
    printf 'last commit unavailable: %s\n' "$LAST_COMMIT"
  fi

  if [ -n "$RUN_DIR" ]; then
    printf '\nExternal worker progress:\n'
    if ! "$SCRIPT_DIR/progress.sh" "$RUN_DIR"; then
      printf 'progress.sh failed for run dir: %s\n' "$RUN_DIR"
    fi
  fi

  [ "$ONCE" -eq 1 ] && exit 0
  sleep "$INTERVAL"
done
