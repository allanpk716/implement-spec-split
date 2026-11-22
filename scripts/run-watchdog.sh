#!/usr/bin/env bash
# Background watchdog for dispatched implementing roles.
#
# Usage:
#   scripts/run-watchdog.sh --watch <worktree>[=<worker run dir>] [--watch ...]
#                            [--stall <seconds>] [--interval <seconds>] [--max <seconds>]
#
# Every --interval seconds each watched object is fingerprinted from its git HEAD,
# a checksum of `git status --porcelain`, the newest file mtime inside the
# worktree (excluding .git) and, when a worker run dir is appended after `=`,
# the newest file mtime inside that run dir. A changed fingerprint counts as
# progress. A worktree that no longer exists counts as finished, not stalled.
#
# Exit codes:
#   0   every object finished
#   2   --max reached while objects were still progressing
#   3   an object's fingerprint stayed unchanged for --stall seconds
#   64  usage error
#
# stdout carries exactly one line per object, each prefixed with the local
# time from `date '+%m-%d %H:%M'`, so an Orchestrator can consume the result
# when this background command completes.

set -u

SCRIPT_NAME=${0##*/}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --watch <worktree>[=<worker run dir>] [--watch ...]
                    [--stall <seconds, default 2700>]
                    [--interval <seconds, default 300>]
                    [--max <seconds, default 7200>]
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

WORKTREES=()
RUN_DIRS=()
STALL_SECONDS=2700
INTERVAL_SECONDS=300
MAX_SECONDS=7200

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --watch)
      [ "$#" -ge 2 ] || usage_error '--watch requires a path'
      watch_value=$2
      watch_worktree=${watch_value%%=*}
      watch_run_dir=
      case "$watch_value" in
        *=*) watch_run_dir=${watch_value#*=} ;;
      esac
      [ -n "$watch_worktree" ] ||
        usage_error '--watch worktree path cannot be empty'
      WORKTREES+=("$watch_worktree")
      RUN_DIRS+=("$watch_run_dir")
      shift 2
      ;;
    --stall)
      [ "$#" -ge 2 ] || usage_error '--stall requires a positive integer'
      STALL_SECONDS=$2
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || usage_error '--interval requires a positive integer'
      INTERVAL_SECONDS=$2
      shift 2
      ;;
    --max)
      [ "$#" -ge 2 ] || usage_error '--max requires a positive integer'
      MAX_SECONDS=$2
      shift 2
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ "${#WORKTREES[@]}" -ge 1 ] || usage_error 'at least one --watch is required'
case "$STALL_SECONDS" in
  ''|0|*[!0-9]*) usage_error '--stall must be a positive integer' ;;
esac
case "$INTERVAL_SECONDS" in
  ''|0|*[!0-9]*) usage_error '--interval must be a positive integer' ;;
esac
case "$MAX_SECONDS" in
  ''|0|*[!0-9]*) usage_error '--max must be a positive integer' ;;
esac

command -v node >/dev/null 2>&1 ||
  { printf '%s: node is required but was not found on PATH\n' "$SCRIPT_NAME" >&2; exit 64; }

latest_mtime() {
  directory=$1
  exclude_git=$2
  node -e '
    const fs = require("fs");
    const path = require("path");
    const root = process.argv[1];
    const excludeGit = process.argv[2] === "1";
    let latest = 0;
    const walk = directory => {
      let entries;
      try {
        entries = fs.readdirSync(directory, { withFileTypes: true });
      } catch (_) {
        return;
      }
      for (const entry of entries) {
        if (excludeGit && entry.name === ".git") continue;
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
          walk(full);
        } else if (entry.isFile()) {
          try {
            const modified = fs.statSync(full).mtimeMs;
            if (modified > latest) latest = modified;
          } catch (_) {}
        }
      }
    };
    walk(root);
    process.stdout.write(String(Math.floor(latest / 1000)));
  ' "$directory" "$exclude_git"
}

display_epoch() {
  epoch=$1
  displayed=$(date -r "$epoch" '+%m-%d %H:%M' 2>/dev/null) ||
    displayed=$(date -d "@$epoch" '+%m-%d %H:%M' 2>/dev/null) ||
    displayed='unknown'
  printf '%s' "$displayed"
}

object_head() {
  fingerprint=$1
  head=${fingerprint%%|*}
  if [ -z "$head" ] || [ "$head" = '?' ]; then
    printf '%s' '?'
  else
    printf '%s' "$head" | cut -c1-7
  fi
}

print_line() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M')" "$1"
}

sample_object() {
  index=$1
  worktree=${WORKTREES[$index]}
  run_dir=${RUN_DIRS[$index]}
  if [ ! -d "$worktree" ]; then
    printf 'done'
    return
  fi
  head=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" rev-parse HEAD 2>/dev/null) ||
    head='?'
  status_checksum=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain 2>/dev/null | cksum) ||
    status_checksum='?'
  worktree_mtime=$(latest_mtime "$worktree" 1)
  run_dir_mtime=0
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    run_dir_mtime=$(latest_mtime "$run_dir" 0)
  fi
  printf '%s|%s|%s|%s' "$head" "$status_checksum" "$worktree_mtime" "$run_dir_mtime"
}

COUNT=${#WORKTREES[@]}
FINGERPRINTS=()
LAST_CHANGE=()
IS_DONE=()
STARTED=$(date +%s)

while :; do
  NOW=$(date +%s)
  for ((index = 0; index < COUNT; index++)); do
    fingerprint=$(sample_object "$index")
    if [ "$fingerprint" != "${FINGERPRINTS[$index]:-}" ]; then
      FINGERPRINTS[$index]=$fingerprint
      LAST_CHANGE[$index]=$NOW
    fi
    if [ "$fingerprint" = done ]; then
      IS_DONE[$index]=1
    else
      IS_DONE[$index]=0
    fi
  done

  all_done=1
  for ((index = 0; index < COUNT; index++)); do
    [ "${IS_DONE[$index]}" -eq 0 ] && all_done=0
  done
  if [ "$all_done" -eq 1 ]; then
    for ((index = 0; index < COUNT; index++)); do
      print_line "DONE ${WORKTREES[$index]} 已结束"
    done
    exit 0
  fi

  stalled_index=-1
  for ((index = 0; index < COUNT; index++)); do
    [ "${IS_DONE[$index]}" -eq 1 ] && continue
    age=$(( NOW - LAST_CHANGE[index] ))
    if [ "$age" -ge "$STALL_SECONDS" ]; then
      stalled_index=$index
      break
    fi
  done
  if [ "$stalled_index" -ge 0 ]; then
    for ((index = 0; index < COUNT; index++)); do
      worktree=${WORKTREES[$index]}
      if [ "${IS_DONE[$index]}" -eq 1 ]; then
        print_line "DONE $worktree 已结束"
        continue
      fi
      head=$(object_head "${FINGERPRINTS[$index]}")
      changed=$(display_epoch "${LAST_CHANGE[$index]}")
      if [ "$index" -eq "$stalled_index" ]; then
        minutes=$(((NOW - LAST_CHANGE[index]) / 60))
        print_line "STALLED ${worktree} 无进展 ${minutes} 分钟（HEAD ${head}，最近改动 ${changed}）"
      else
        print_line "OK ${worktree} 正常（HEAD ${head}，最近改动 ${changed}）"
      fi
    done
    exit 3
  fi

  if [ $(( NOW - STARTED )) -ge "$MAX_SECONDS" ]; then
    for ((index = 0; index < COUNT; index++)); do
      worktree=${WORKTREES[$index]}
      if [ "${IS_DONE[$index]}" -eq 1 ]; then
        print_line "DONE $worktree 已结束"
      else
        head=$(object_head "${FINGERPRINTS[$index]}")
        changed=$(display_epoch "${LAST_CHANGE[$index]}")
        print_line "ALIVE ${worktree} 仍有进展（HEAD ${head}，最近改动 ${changed}）"
      fi
    done
    exit 2
  fi

  sleep "$INTERVAL_SECONDS"
done
