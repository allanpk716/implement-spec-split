#!/usr/bin/env bash
# Isolated tests for scripts/run-watchdog.sh. The scratch tree is retained so
# this test never recursively deletes a temporary directory, and no network
# access is needed.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/run-watchdog.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/run-watchdog-test.XXXXXX")
WORK=$(cd "$WORK" && pwd)
PASSED=0
FAILED=0
RUN_EXIT=
RUN_OUT=
RUN_ERR=
WRITER_PIDS=

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  for pid in $WRITER_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

record() {
  status=$1
  name=$2
  detail=${3:-}
  if [ "$status" = PASS ]; then
    printf 'PASS %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$name" "${detail:+: $detail}"
    FAILED=$((FAILED + 1))
  fi
}

run_watchdog() {
  RUN_OUT=$("$SCRIPT" "$@" 2>"$WORK/stderr.txt")
  RUN_EXIT=$?
  RUN_ERR=$(cat "$WORK/stderr.txt")
}

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected stderr=$RUN_ERR"
  fi
}

expect_output_contains() {
  text=$1
  name=$2
  if printf '%s\n' "$RUN_OUT" | grep -Fq -- "$text"; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] output=$(printf '%s\n' "$RUN_OUT")"
  fi
}

expect_output_lacks() {
  text=$1
  name=$2
  if printf '%s\n' "$RUN_OUT" | grep -Fq -- "$text"; then
    record FAIL "$name" "unexpected [$text] output=$(printf '%s\n' "$RUN_OUT")"
  else
    record PASS "$name"
  fi
}

make_repo_with_worktree() {
  repo=$1
  worktree=$2
  mkdir -p "$repo" || exit 1
  git -C "$repo" init --quiet --initial-branch=main || exit 1
  git -C "$repo" config user.name 'Watchdog Test'
  git -C "$repo" config user.email watchdog-test@example.invalid
  git -C "$repo" config commit.gpgsign false
  printf '%s\n' 'fixture' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit --quiet -m 'initial commit'
  git -C "$repo" worktree add --quiet "$worktree" -b ticket-1 || exit 1
}

start_commit_writer() {
  worktree=$1
  flag=$2
  (
    count=0
    while [ -f "$flag" ]; do
      count=$((count + 1))
      printf '%s\n' "$count" >> "$worktree/progress.txt"
      git -C "$worktree" add progress.txt >/dev/null 2>&1 || true
      git -C "$worktree" commit --quiet -m "progress $count" \
        >/dev/null 2>&1 || true
      sleep 0.4
    done
  ) &
  WRITER_PIDS="$WRITER_PIDS $!"
}

start_file_writer() {
  directory=$1
  flag=$2
  mkdir -p "$directory" || exit 1
  (
    count=0
    while [ -f "$flag" ]; do
      count=$((count + 1))
      printf '%s\n' "$count" >> "$directory/events.log"
      sleep 0.25
    done
  ) &
  WRITER_PIDS="$WRITER_PIDS $!"
}

stop_writers() {
  for flag in "$@"; do
    rm -f "$flag"
  done
  for pid in $WRITER_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  WRITER_PIDS=
}

# 1. A quiet worktree stalls.
STALL_REPO=$WORK/stall-repo
STALL_WT=$WORK/stall-wt
make_repo_with_worktree "$STALL_REPO" "$STALL_WT"
run_watchdog --watch "$STALL_WT" --interval 1 --stall 3 --max 10
expect_exit 3 'quiet worktree reports stalled'
expect_output_contains "STALLED $STALL_WT" 'stalled line names the worktree'
expect_output_contains '无进展' 'stalled line says no progress'
expect_output_contains 'HEAD ' 'stalled line includes the head'
expect_output_contains '最近改动 ' 'stalled line includes the last change time'

# 2. Continuous commits keep the object alive until max.
PROGRESS_REPO=$WORK/progress-repo
PROGRESS_WT=$WORK/progress-wt
PROGRESS_FLAG=$WORK/progress-writer-flag
make_repo_with_worktree "$PROGRESS_REPO" "$PROGRESS_WT"
: > "$PROGRESS_FLAG"
start_commit_writer "$PROGRESS_WT" "$PROGRESS_FLAG"
run_watchdog --watch "$PROGRESS_WT" --interval 1 --stall 3 --max 4
STOP_STATUS=$RUN_EXIT
stop_writers "$PROGRESS_FLAG"
RUN_EXIT=$STOP_STATUS
expect_exit 2 'progressing worktree reaches max alive'
expect_output_lacks 'STALLED' 'progressing worktree does not stall'
expect_output_contains "ALIVE $PROGRESS_WT" 'alive line names the worktree'

# 3. Disappearing worktrees finish the watch.
GONE_REPO=$WORK/gone-repo
GONE_WT=$WORK/gone-wt
make_repo_with_worktree "$GONE_REPO" "$GONE_WT"
MISSING_WT=$WORK/never-created-wt
(
  sleep 1.2
  mv "$GONE_WT" "$WORK/gone-wt-moved" 2>/dev/null || true
) &
WRITER_PIDS="$WRITER_PIDS $!"
run_watchdog --watch "$GONE_WT" --watch "$MISSING_WT" --interval 1 --stall 3 --max 10
STOP_STATUS=$RUN_EXIT
stop_writers "$WORK/unused-flag"
RUN_EXIT=$STOP_STATUS
expect_exit 0 'all objects gone exits zero'
expect_output_contains "DONE $GONE_WT" 'removed worktree is done'
expect_output_contains "DONE $MISSING_WT" 'missing worktree is done'
expect_output_lacks 'STALLED' 'gone worktrees never stall'

# 4. Mixed objects report stalled, ok and done together.
MIX_STALL_REPO=$WORK/mix-stall-repo
MIX_STALL_WT=$WORK/mix-stall-wt
MIX_PROGRESS_REPO=$WORK/mix-progress-repo
MIX_PROGRESS_WT=$WORK/mix-progress-wt
MIX_MISSING_WT=$WORK/mix-missing-wt
MIX_FLAG=$WORK/mix-writer-flag
make_repo_with_worktree "$MIX_STALL_REPO" "$MIX_STALL_WT"
make_repo_with_worktree "$MIX_PROGRESS_REPO" "$MIX_PROGRESS_WT"
: > "$MIX_FLAG"
start_commit_writer "$MIX_PROGRESS_WT" "$MIX_FLAG"
run_watchdog --watch "$MIX_STALL_WT" --watch "$MIX_PROGRESS_WT" \
  --watch "$MIX_MISSING_WT" --interval 1 --stall 3 --max 10
STOP_STATUS=$RUN_EXIT
stop_writers "$MIX_FLAG"
RUN_EXIT=$STOP_STATUS
expect_exit 3 'mixed set reports the stalled object'
expect_output_contains "STALLED $MIX_STALL_WT" 'mixed stalled line'
expect_output_contains "OK $MIX_PROGRESS_WT" 'mixed progressing object is ok'
expect_output_contains "DONE $MIX_MISSING_WT" 'mixed missing object is done'

# 5. Worker run dir activity also counts as progress.
RUNDIR_REPO=$WORK/rundir-repo
RUNDIR_WT=$WORK/rundir-wt
RUNDIR_DIR=$WORK/rundir-worker
RUNDIR_FLAG=$WORK/rundir-writer-flag
make_repo_with_worktree "$RUNDIR_REPO" "$RUNDIR_WT"
: > "$RUNDIR_FLAG"
start_file_writer "$RUNDIR_DIR" "$RUNDIR_FLAG"
run_watchdog --watch "$RUNDIR_WT=$RUNDIR_DIR" --interval 1 --stall 3 --max 4
STOP_STATUS=$RUN_EXIT
stop_writers "$RUNDIR_FLAG"
RUN_EXIT=$STOP_STATUS
expect_exit 2 'run dir progress reaches max alive'
expect_output_lacks 'STALLED' 'run dir progress prevents stall'
expect_output_contains "ALIVE $RUNDIR_WT" 'run dir alive line names the worktree'

# 6. Argument errors.
run_watchdog
expect_exit 64 'no watch is a usage error'
run_watchdog --watch
expect_exit 64 'watch without value is a usage error'
run_watchdog --watch "$STALL_WT" --stall 0
expect_exit 64 'zero stall is a usage error'
run_watchdog --watch "$STALL_WT" --interval abc
expect_exit 64 'non-numeric interval is a usage error'
run_watchdog --watch "$STALL_WT" --max -1
expect_exit 64 'negative max is a usage error'
run_watchdog --watched "$STALL_WT"
expect_exit 64 'unknown argument is a usage error'

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
