#!/usr/bin/env bash
# Tests for scripts/merge-ticket.sh (temporary git repositories; no Orca).
# The test command is passed as an argument the way a Spec session passes it;
# the fake it names records its working directory and arguments, and fails
# while the file TEST_FAIL names exists.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/merge-ticket.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/merge-ticket-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN=$WORK/bin
MAIN=$WORK/main
ORIGIN=$WORK/origin.git
INTEGRATION=$WORK/integration
TICKET=$WORK/ticket
TEST_LOG=$WORK/test.log
TEST_FAIL=$WORK/test-fail
PASSED=0
FAILED=0
RUN_EXIT=

ok() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    ok "$name"
  else
    bad "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    ok "$name"
  else
    bad "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    bad "$name" "unexpected [$text]"
  else
    ok "$name"
  fi
}

expect_head() { # sha name — the Integration branch's HEAD is <sha>
  head=$(git -C "$INTEGRATION" rev-parse HEAD 2>/dev/null)
  if [ "$head" = "$1" ]; then
    ok "$2"
  else
    bad "$2" "HEAD is ${head:-unknown}, expected $1"
  fi
}

expect_merged() { # sha name — the Integration branch's HEAD contains <sha>
  if git -C "$INTEGRATION" merge-base --is-ancestor "$1" HEAD 2>/dev/null; then
    ok "$2"
  else
    bad "$2" "HEAD $(git -C "$INTEGRATION" rev-parse --short HEAD 2>/dev/null) does not contain $1"
  fi
}

expect_clean() { # name — no changes and no merge in progress in the Integration worktree
  out=$(git -C "$INTEGRATION" status --porcelain 2>/dev/null)
  if [ -n "$out" ]; then
    bad "$1" "status: $out"
  elif git -C "$INTEGRATION" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    bad "$1" "MERGE_HEAD still exists"
  else
    ok "$1"
  fi
}

expect_test_ran() { # name
  if [ -s "$TEST_LOG" ]; then
    ok "$1"
  else
    bad "$1" "the test command did not run"
  fi
}

expect_test_not_run() { # name
  if [ -s "$TEST_LOG" ]; then
    bad "$1" "$(cat "$TEST_LOG")"
  else
    ok "$1"
  fi
}

run_merge() { # OUT [arguments]
  out=$1
  shift
  env TEST_LOG="$TEST_LOG" TEST_FAIL="$TEST_FAIL" PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@" > "$out" 2> "$out.err"
  RUN_EXIT=$?
}

mkdir -p "$BIN" "$MAIN" || exit 1

cat > "$BIN/fake-test" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'cwd=%s\n' "$PWD" >> "$TEST_LOG"
printf 'args=%s\n' "$*" >> "$TEST_LOG"
printf 'sample=%s\n' "${SAMPLE:-}" >> "$TEST_LOG"
if [ -e "$TEST_FAIL" ]; then
  printf '%s\n' 'FAIL sample-test: expected 1, got 2'
  exit 1
fi
printf '%s\n' 'ok sample-test'
EOF
chmod +x "$BIN/fake-test"

# A repository with a bare origin (the test-close-self.sh layout), then the
# Integration branch spec-101 in its own worktree and the Ticket branch
# spec-101-t7 in another, with one commit on top of it.
git init --quiet --initial-branch=main "$MAIN"
git -C "$MAIN" config user.name 'Merge Ticket Test'
git -C "$MAIN" config user.email 'merge-ticket@example.invalid'
git -C "$MAIN" config commit.gpgsign false
printf '%s\n' 'test repository' > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit --quiet -m 'initial commit'
git init --quiet --bare --initial-branch=main "$ORIGIN"
git -C "$MAIN" remote add origin "$ORIGIN"
git -C "$MAIN" push --quiet origin main
git -C "$MAIN" fetch --quiet origin
git -C "$MAIN" remote set-head origin -a

git -C "$MAIN" worktree add --quiet -b spec-101 "$INTEGRATION" main
git -C "$MAIN" worktree add --quiet -b spec-101-t7 "$TICKET" spec-101
# macOS gives /var/... while the script compares physical paths.
INTEGRATION=$(cd "$INTEGRATION" && pwd -P)
TICKET=$(cd "$TICKET" && pwd -P)
printf '%s\n' 'ticket seven' > "$TICKET/feature7.txt"
git -C "$TICKET" add feature7.txt
git -C "$TICKET" commit --quiet -m 'ticket 7 work'
TIP7=$(git -C "$TICKET" rev-parse HEAD)

# --- clean merge: merge commit, tests in the Integration worktree ------------
BEFORE=$(git -C "$INTEGRATION" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/clean.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t7 --test 'fake-test unit'
expect_exit 0 "clean merge with passing tests exits 0"
expect_has 'merge-ticket: merged spec-101-t7 into spec-101' "clean merge reports the merge" "$WORK/clean.out"
expect_merged "$TIP7" "clean merge lands the ticket commit on the integration branch"
parents=$(git -C "$INTEGRATION" log -1 --format='%P' HEAD)
if [ "$parents" = "$BEFORE $TIP7" ]; then
  ok "clean merge is a merge commit of the previous tip and the ticket"
else
  bad "clean merge is a merge commit of the previous tip and the ticket" "parents=[$parents]"
fi
expect_has "cwd=$INTEGRATION" "tests run in the integration worktree" "$TEST_LOG"
expect_has 'args=unit' "tests get the command as given" "$TEST_LOG"
expect_has 'ok sample-test' "test output is passed through" "$WORK/clean.out"
expect_clean "clean merge leaves a clean worktree"
HEAD_AFTER_CLEAN=$(git -C "$INTEGRATION" rev-parse HEAD)

# --- usage --------------------------------------------------------------------
: > "$TEST_LOG"
run_merge "$WORK/no-args.out"
expect_exit 64 "no arguments exits 64"
expect_has 'usage:' "no arguments prints usage" "$WORK/no-args.out.err"
run_merge "$WORK/bogus.out" --bogus
expect_exit 64 "unknown argument exits 64"
run_merge "$WORK/help.out" --help
expect_exit 0 "--help exits 0"
expect_has 'usage:' "--help prints usage" "$WORK/help.out"
run_merge "$WORK/no-test.out" --worktree "$INTEGRATION" --integration spec-101 --ticket spec-101-t7
expect_exit 64 "a missing --test exits 64"
expect_has '--test is required' "a missing --test names the argument" "$WORK/no-test.out.err"
run_merge "$WORK/empty-test.out" --worktree "$INTEGRATION" --integration spec-101 --ticket spec-101-t7 --test ''
expect_exit 64 "an empty --test exits 64"
run_merge "$WORK/twice.out" --worktree "$INTEGRATION" --integration spec-101 --integration spec-101 \
  --ticket spec-101-t7 --test 'fake-test'
expect_exit 64 "an option given twice exits 64"
expect_test_not_run "usage errors run no tests"
expect_head "$HEAD_AFTER_CLEAN" "usage errors merge nothing"

# --- gate: no new commits -------------------------------------------------------
: > "$TEST_LOG"
run_merge "$WORK/already.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t7 --test 'fake-test'
expect_exit 2 "an already merged ticket exits 2"
expect_has 'has no commits' "an already merged ticket says why" "$WORK/already.out.err"
expect_has 'gate not met' "an already merged ticket names the gate" "$WORK/already.out.err"
expect_test_not_run "an already merged ticket runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "an already merged ticket changes nothing"

TICKET8=$WORK/ticket8
git -C "$MAIN" worktree add --quiet -b spec-101-t8 "$TICKET8" spec-101
TICKET8=$(cd "$TICKET8" && pwd -P)
: > "$TEST_LOG"
run_merge "$WORK/empty.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a ticket branch without commits exits 2"
expect_has 'has no commits' "a ticket branch without commits says why" "$WORK/empty.out.err"
expect_test_not_run "a ticket branch without commits runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "a ticket branch without commits changes nothing"
# From here on spec-101-t8 has a commit, so the gate gets past the commit count.
printf '%s\n' 'ticket eight' > "$TICKET8/feature8.txt"
git -C "$TICKET8" add feature8.txt
git -C "$TICKET8" commit --quiet -m 'ticket 8 work'

# --- gate: ticket worktree not clean ------------------------------------------
printf '%s\n' 'untracked' > "$TICKET8/untracked.txt"
: > "$TEST_LOG"
run_merge "$WORK/dirty-untracked.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "an untracked file in the ticket worktree exits 2"
expect_has "ticket worktree $TICKET8 has uncommitted or untracked changes" \
  "an untracked file in the ticket worktree names the worktree" "$WORK/dirty-untracked.out.err"
expect_test_not_run "an untracked file in the ticket worktree runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "an untracked file in the ticket worktree changes nothing"
rm -f "$TICKET8/untracked.txt"

printf '%s\n' 'work in progress' > "$TICKET8/README.md"
: > "$TEST_LOG"
run_merge "$WORK/dirty-modified.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a modified file in the ticket worktree exits 2"
expect_has 'uncommitted or untracked changes' "a modified file in the ticket worktree says why" "$WORK/dirty-modified.out.err"
expect_head "$HEAD_AFTER_CLEAN" "a modified file in the ticket worktree changes nothing"
git -C "$TICKET8" checkout --quiet -- README.md

# --- gate: ticket branch unknown or without a worktree -------------------------
: > "$TEST_LOG"
run_merge "$WORK/no-branch.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t999 --test 'fake-test'
expect_exit 2 "a missing ticket branch exits 2"
expect_has 'ticket branch spec-101-t999 does not exist' "a missing ticket branch says which" "$WORK/no-branch.out.err"
expect_test_not_run "a missing ticket branch runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "a missing ticket branch changes nothing"

TICKET9=$WORK/ticket9
git -C "$MAIN" worktree add --quiet -b spec-101-t9 "$TICKET9" spec-101
printf '%s\n' 'ticket nine' > "$TICKET9/feature9.txt"
git -C "$TICKET9" add feature9.txt
git -C "$TICKET9" commit --quiet -m 'ticket 9 work'
git -C "$MAIN" worktree remove "$TICKET9"
: > "$TEST_LOG"
run_merge "$WORK/no-ticket-worktree.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t9 --test 'fake-test'
expect_exit 2 "a ticket branch without a worktree exits 2"
expect_has 'no worktree has the ticket branch spec-101-t9 checked out' \
  "a ticket branch without a worktree says which" "$WORK/no-ticket-worktree.out.err"
expect_test_not_run "a ticket branch without a worktree runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "a ticket branch without a worktree changes nothing"

# --- gate: integration worktree not clean --------------------------------------
printf '%s\n' 'untracked' > "$INTEGRATION/untracked.txt"
: > "$TEST_LOG"
run_merge "$WORK/dirty-integration.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "an untracked file in the integration worktree exits 2"
expect_has "integration worktree $INTEGRATION has uncommitted or untracked changes" \
  "an untracked file in the integration worktree names the worktree" "$WORK/dirty-integration.out.err"
expect_test_not_run "an untracked file in the integration worktree runs no tests"
expect_head "$HEAD_AFTER_CLEAN" "an untracked file in the integration worktree changes nothing"
rm -f "$INTEGRATION/untracked.txt"

# --- gate: worktree is not on the integration branch ---------------------------
: > "$TEST_LOG"
run_merge "$WORK/other-branch.out" --worktree "$MAIN" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a worktree on another branch exits 2"
expect_has "is on branch 'main', not the integration branch spec-101" \
  "a worktree on another branch names both branches" "$WORK/other-branch.out.err"
git -C "$MAIN" checkout --quiet --detach
run_merge "$WORK/detached.out" --worktree "$MAIN" --integration main --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a detached HEAD exits 2"
expect_has 'detached HEAD' "a detached HEAD says why" "$WORK/detached.out.err"
expect_test_not_run "a wrong integration branch runs no tests"
git -C "$MAIN" checkout --quiet main
run_merge "$WORK/no-dir.out" --worktree "$WORK/no-such-dir" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a missing worktree path exits 2"
expect_has 'does not exist' "a missing worktree path says why" "$WORK/no-dir.out.err"
expect_head "$HEAD_AFTER_CLEAN" "a missing worktree path changes nothing"
run_merge "$WORK/not-git.out" --worktree "$WORK" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a directory outside any git worktree exits 2"
expect_has 'is not a git worktree' "a directory outside any git worktree says why" "$WORK/not-git.out.err"
mkdir -p "$INTEGRATION/sub"
run_merge "$WORK/subdir.out" --worktree "$INTEGRATION/sub" --integration spec-101 \
  --ticket spec-101-t8 --test 'fake-test'
expect_exit 2 "a subdirectory of the worktree exits 2"
expect_has 'is not the top level of its git worktree' "a subdirectory of the worktree says why" "$WORK/subdir.out.err"
expect_test_not_run "a subdirectory of the worktree runs no tests"
rm -rf "$INTEGRATION/sub"
expect_head "$HEAD_AFTER_CLEAN" "a subdirectory of the worktree changes nothing"

# --- conflict ------------------------------------------------------------------
TICKET10=$WORK/ticket10
git -C "$MAIN" worktree add --quiet -b spec-101-t10 "$TICKET10" spec-101
TICKET10=$(cd "$TICKET10" && pwd -P)
printf '%s\n' 'ticket ten readme' > "$TICKET10/README.md"
git -C "$TICKET10" add README.md
git -C "$TICKET10" commit --quiet -m 'ticket 10 edits the readme'
TIP10=$(git -C "$TICKET10" rev-parse HEAD)
# The Integration branch moves to touch the same line.
printf '%s\n' 'integration readme' > "$INTEGRATION/README.md"
git -C "$INTEGRATION" add README.md
git -C "$INTEGRATION" commit --quiet -m 'integration edits the readme'
INTEG_MOVED=$(git -C "$INTEGRATION" rev-parse HEAD)

: > "$TEST_LOG"
run_merge "$WORK/conflict.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t10 --test 'fake-test'
expect_exit 3 "a conflict exits 3"
expect_has 'conflict merging spec-101-t10 into spec-101' "a conflict names both branches" "$WORK/conflict.out.err"
expect_has 'conflicted files:' "a conflict announces the file list" "$WORK/conflict.out.err"
expect_has 'README.md' "a conflict lists the conflicted file" "$WORK/conflict.out.err"
expect_has 'back to the state before the merge' "a conflict reports the restore" "$WORK/conflict.out.err"
expect_without 'merge-ticket: merged' "a conflict reports no merge" "$WORK/conflict.out"
expect_head "$INTEG_MOVED" "a conflict leaves the Integration branch where it was"
expect_clean "a conflict leaves no half-merged state"
expect_without '<<<<<<<' "a conflict leaves no conflict markers" "$INTEGRATION/README.md"
expect_has 'integration readme' "a conflict restores the file's content" "$INTEGRATION/README.md"
expect_test_not_run "a conflict runs no tests"

# --- tests fail after the merge: the merge commit stays ------------------------
TICKET11=$WORK/ticket11
git -C "$MAIN" worktree add --quiet -b spec-101-t11 "$TICKET11" spec-101
printf '%s\n' 'ticket eleven' > "$TICKET11/feature11.txt"
git -C "$TICKET11" add feature11.txt
git -C "$TICKET11" commit --quiet -m 'ticket 11 work'
TIP11=$(git -C "$TICKET11" rev-parse HEAD)

: > "$TEST_FAIL"
: > "$TEST_LOG"
run_merge "$WORK/test-fail.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t11 --test 'fake-test all'
expect_exit 4 "failing tests exit 4"
expect_has 'merge-ticket: merged spec-101-t11 into spec-101' "failing tests come after the merge" "$WORK/test-fail.out"
expect_has 'FAIL sample-test: expected 1, got 2' "failing tests leave their output on stdout" "$WORK/test-fail.out"
expect_has 'tests failed (exit 1)' "failing tests say so on stderr" "$WORK/test-fail.out.err"
expect_has 'merge commit' "failing tests name the commit that stays" "$WORK/test-fail.out.err"
expect_merged "$TIP11" "failing tests keep the merge commit on the Integration branch"
expect_test_ran "failing tests did run in the integration worktree"
expect_has "cwd=$INTEGRATION" "failing tests ran in the integration worktree" "$TEST_LOG"
expect_clean "failing tests leave a clean worktree"
rm -f "$TEST_FAIL"
HEAD_AFTER_T11=$(git -C "$INTEGRATION" rev-parse HEAD)

# --- the Integration branch moved since the Ticket branched: still a merge ----
# spec-101-t12 branched from INTEG_MOVED; spec-101 has moved on by t11 since.
TICKET12=$WORK/ticket12
git -C "$MAIN" worktree add --quiet -b spec-101-t12 "$TICKET12" "$INTEG_MOVED"
printf '%s\n' 'ticket twelve' > "$TICKET12/feature12.txt"
git -C "$TICKET12" add feature12.txt
git -C "$TICKET12" commit --quiet -m 'ticket 12 work'
TIP12=$(git -C "$TICKET12" rev-parse HEAD)

: > "$TEST_LOG"
run_merge "$WORK/moved.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t12 --test 'SAMPLE=1 fake-test a && fake-test b'
expect_exit 0 "a merge onto a moved Integration branch exits 0"
parents=$(git -C "$INTEGRATION" log -1 --format='%P' HEAD)
if [ "$parents" = "$HEAD_AFTER_T11 $TIP12" ]; then
  ok "a moved Integration branch is the first parent of the merge commit"
else
  bad "a moved Integration branch is the first parent of the merge commit" "parents=[$parents]"
fi
expect_merged "$TIP11" "a moved Integration branch keeps the earlier ticket"
expect_merged "$TIP12" "a moved Integration branch gets the new ticket"
expect_has 'args=a' "a compound test command runs its first part" "$TEST_LOG"
expect_has 'args=b' "a compound test command runs its second part" "$TEST_LOG"
expect_has 'sample=1' "an environment prefix reaches the test command" "$TEST_LOG"
expect_has 'tests passed' "a passing test command is reported" "$WORK/moved.out"
expect_clean "a merge onto a moved Integration branch leaves a clean worktree"

# --- the test command itself cannot run ----------------------------------------
TICKET13=$WORK/ticket13
git -C "$MAIN" worktree add --quiet -b spec-101-t13 "$TICKET13" spec-101
printf '%s\n' 'ticket thirteen' > "$TICKET13/feature13.txt"
git -C "$TICKET13" add feature13.txt
git -C "$TICKET13" commit --quiet -m 'ticket 13 work'
TIP13=$(git -C "$TICKET13" rev-parse HEAD)

: > "$TEST_LOG"
run_merge "$WORK/no-runner.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t13 --test 'no-such-test-runner'
expect_exit 4 "a test command that cannot run exits 4"
expect_has 'no-such-test-runner' "a test command that cannot run shows bash's message" "$WORK/no-runner.out.err"
expect_has 'tests failed (exit 127)' "a test command that cannot run reports bash's exit code" "$WORK/no-runner.out.err"
expect_merged "$TIP13" "a test command that cannot run keeps the merge commit"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
