#!/usr/bin/env bash
# Isolated tests for scripts/ticket-watch.sh. The scratch tree is retained so
# this test never recursively deletes a temporary directory.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/ticket-watch.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ticket-watch-test.XXXXXX")
WORK=$(cd "$WORK" && pwd)
PASSED=0
FAILED=0
RUN_EXIT=
RUN_OUT=
RUN_ERR=

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

run_script() {
  RUN_OUT=$("$SCRIPT" "$@" 2>"$WORK/stderr.txt")
  RUN_EXIT=$?
  RUN_ERR=$(cat "$WORK/stderr.txt")
}

expect_contains() {
  text=$1
  name=$2
  if printf '%s\n' "$RUN_OUT" | grep -Fq -- "$text"; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text]"
  fi
}

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_usage_failure() {
  name=$1
  if [ "$RUN_EXIT" -ne 0 ] && printf '%s\n' "$RUN_ERR$RUN_OUT" | grep -Fq 'usage:'; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT stderr=$RUN_ERR"
  fi
}

REPO=$WORK/repo
TICKET_WT=$WORK/ticket-wt
WORKER_RUN=$WORK/worker-run
mkdir -p "$REPO" "$WORKER_RUN" || exit 1
git -C "$REPO" init --quiet --initial-branch=main || exit 1
git -C "$REPO" config user.name 'Ticket Watch Test'
git -C "$REPO" config user.email ticket-watch-test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf '%s\n' 'fixture' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git -C "$REPO" branch spec-12
git -C "$REPO" worktree add --quiet "$TICKET_WT" -b spec-12-t34 || exit 1
printf '%s\n' 'ticket change' > "$TICKET_WT/change.txt"
git -C "$TICKET_WT" add change.txt
git -C "$TICKET_WT" commit --quiet -m 'Implement ticket 34'
printf '%s\n' 'uncommitted' > "$TICKET_WT/dirty.txt"

run_script --worktree "$TICKET_WT" --base spec-12 --once
expect_exit 0 'once exits zero'
expect_contains "$TICKET_WT" 'once shows the worktree'
expect_contains 'spec-12-t34' 'once shows the branch'
expect_contains 'Implement ticket 34' 'once shows the leading commit'
expect_contains '?? dirty.txt' 'once shows the dirty file'
expect_contains 'last commit:' 'once shows the latest commit time'

run_script --worktree "$TICKET_WT" --base spec-12 --run-dir "$WORKER_RUN" --once
expect_exit 0 'run-dir once exits zero'
expect_contains 'External worker progress:' 'run-dir adds worker progress'
expect_contains 'state: dead' 'run-dir shows worker state'

run_script --worktree "$WORK/does-not-exist" --base spec-12 --once
expect_exit 0 'missing worktree exits zero'
expect_contains 'worktree 已清理，标签可关闭' 'missing worktree explains cleanup'

run_script --base spec-12 --once
expect_usage_failure 'missing --worktree fails'
run_script --worktree "$TICKET_WT" --once
expect_usage_failure 'missing --base fails'
run_script --worktree "$TICKET_WT" --base spec-12 --interval 0 --once
expect_usage_failure 'zero interval fails'

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
