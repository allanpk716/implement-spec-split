#!/usr/bin/env bash
# Tests for scripts/merge-ticket.sh (temporary git repositories; no Orca).
# The test command is passed as an argument the way a Spec session passes it;
# the fake it names records its working directory and arguments, and fails
# while the file TEST_FAIL names exists. Shared counters (a numbered directory,
# a version file) have their own gate: when both sides added the same one the
# script exits 6 and merges nothing, so the second half of the file builds a
# branch group with docs/adr, VERSION, CHANGELOG.md and pyproject.toml.

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
# A Ticket branch already part of the Integration branch (a Recovery run of
# step 5 finds the ticket landed) is not a gate failure: exit 5, apart from 2,
# so the caller releases the Ticket worktree and goes on instead of
# dispatching the ticket again.
: > "$TEST_LOG"
run_merge "$WORK/already.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t7 --test 'fake-test'
expect_exit 5 "an already merged ticket exits 5"
expect_has 'ticket branch spec-101-t7 is already part of spec-101 (behind a merge commit): the ticket has landed, nothing to merge' "an already merged ticket says why" "$WORK/already.out.err"
expect_has 'do not dispatch the ticket again' "an already merged ticket tells the caller to go on" "$WORK/already.out.err"
expect_without 'gate not met' "an already merged ticket is not a gate failure" "$WORK/already.out.err"
expect_without 'has no commits' "an already merged ticket is not read as a ticket that is not done" "$WORK/already.out.err"
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

# --- no new commit: landed behind a merge is 5, a fresh branch is 2 -------------
# t11 landed by a --no-ff merge and the Integration branch has moved on since:
# its tip is behind a merge commit, on no first-parent line of spec-101.
: > "$TEST_LOG"
run_merge "$WORK/landed-moved.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t11 --test 'fake-test'
expect_exit 5 "a landed ticket behind later merges exits 5"
expect_has 'already part of spec-101 (behind a merge commit)' "a landed ticket behind later merges says why" "$WORK/landed-moved.out.err"
expect_without 'gate not met' "a landed ticket behind later merges is not a gate failure" "$WORK/landed-moved.out.err"
expect_test_not_run "a landed ticket behind later merges runs no tests"
# A branch created off an older commit of the Integration branch with nothing
# of its own: its tip sits on the first-parent line, so it is not "landed".
HEAD_AFTER_T13=$(git -C "$INTEGRATION" rev-parse HEAD)
TICKET14=$WORK/ticket14
git -C "$MAIN" worktree add --quiet -b spec-101-t14 "$TICKET14" "$HEAD_AFTER_T11"
run_merge "$WORK/fresh-old.out" --worktree "$INTEGRATION" --integration spec-101 \
  --ticket spec-101-t14 --test 'fake-test'
expect_exit 2 "a fresh branch off an older Integration commit exits 2"
expect_has 'has no commits' "a fresh branch off an older Integration commit says why" "$WORK/fresh-old.out.err"
expect_without 'already part of' "a fresh branch off an older Integration commit is not read as landed" "$WORK/fresh-old.out.err"
expect_test_not_run "a fresh branch off an older Integration commit runs no tests"
expect_head "$HEAD_AFTER_T13" "a fresh branch off an older Integration commit changes nothing"

# --- shared counters ------------------------------------------------------------
# A new branch group off main (spec-102) so the assertions above keep their
# Integration branch: a numbered directory docs/adr with two entries already, a
# VERSION file, a CHANGELOG and a pyproject.toml. From here on the expect_*
# helpers read INTEGRATION, so it points at the new group.

expect_quiet() { # stderr file name — the run printed nothing on stderr
  if [ -s "$1" ]; then
    bad "$2" "$(cat "$1")"
  else
    ok "$2"
  fi
}

expect_untouched() { # worktree sha name — the worktree's HEAD is <sha> and it is clean
  head=$(git -C "$1" rev-parse HEAD 2>/dev/null)
  out=$(git -C "$1" status --porcelain 2>/dev/null)
  if [ "$head" != "$2" ]; then
    bad "$3" "HEAD is ${head:-unknown}, expected $2"
  elif [ -n "$out" ]; then
    bad "$3" "status: $out"
  else
    ok "$3"
  fi
}

expect_content() { # worktree path content name — HEAD:<path> in the worktree holds exactly <content>
  got=$(git -C "$1" show "HEAD:$2" 2>/dev/null)
  if [ "$got" = "$3" ]; then
    ok "$4"
  else
    bad "$4" "content is [${got}], expected [$3]"
  fi
}

expect_absent() { # worktree path name — HEAD:<path> does not exist in the worktree
  if git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null; then
    bad "$3" "$2 exists at HEAD"
  else
    ok "$3"
  fi
}

commit_in() { # worktree message — stage everything and commit
  git -C "$1" add -A
  git -C "$1" commit --quiet -m "$2"
}

new_ticket() { # m base — a Ticket worktree spec-102-t<m> off <base>, its physical path in T
  T=$WORK/spec-102-t$1
  git -C "$MAIN" worktree add --quiet -b "spec-102-t$1" "$T" "$2"
  T=$(cd "$T" && pwd -P)
}

SPEC102=$WORK/spec-102
git -C "$MAIN" worktree add --quiet -b spec-102 "$SPEC102" main
INTEGRATION=$(cd "$SPEC102" && pwd -P)
mkdir -p "$INTEGRATION/docs/adr"
printf '%s\n' 'adr one' > "$INTEGRATION/docs/adr/0001-one.md"
printf '%s\n' 'adr two' > "$INTEGRATION/docs/adr/0002-two.md"
printf '%s\n' '1.0.0' > "$INTEGRATION/VERSION"
printf '%s\n' '# changelog' '' '- base' > "$INTEGRATION/CHANGELOG.md"
printf '%s\n' '[project]' 'version = "1.0.0"' '' '[tool.x]' 'key = 1' > "$INTEGRATION/pyproject.toml"
commit_in "$INTEGRATION" 'spec 102 base: two ADRs, VERSION 1.0.0'
BASE102=$(git -C "$INTEGRATION" rev-parse HEAD)
HEAD_AFTER_USAGE=$BASE102

# The two --counter usage errors: an empty path, and the option without one.
# (--counter repeating is exercised further down; --no-ticket-worktree has its
# own cases in the step 9.1 shape below.)
: > "$TEST_LOG"
run_merge "$WORK/counter-empty.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-101-t7 --test 'fake-test' --counter ''
expect_exit 64 "an empty --counter exits 64"
run_merge "$WORK/counter-lone.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-101-t7 --test 'fake-test' --counter
expect_exit 64 "a --counter without a path exits 64"
expect_test_not_run "usage errors of the counter options run no tests"
expect_head "$HEAD_AFTER_USAGE" "usage errors of the counter options change nothing"

# --- both classes collide: t1 landed first, t2 merged the Integration branch back ---
# t1 adds ADR 0005-a and bumps VERSION to 1.1.0; nothing on the Integration
# side has changed since the base, so the gate has nothing to compare against.
new_ticket 1 "$BASE102"
T1=$T
printf '%s\n' 'adr five a' > "$T1/docs/adr/0005-a.md"
printf '%s\n' '1.1.0' > "$T1/VERSION"
commit_in "$T1" 'ticket one adds ADR 0005-a and bumps VERSION to 1.1.0'
TIP1=$(git -C "$T1" rev-parse HEAD)
SHORT1=$(git -C "$T1" rev-parse --short HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-t1.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t1 --test 'fake-test'
expect_exit 0 "a ticket adding a numbered entry against an unmoved Integration branch merges"
expect_quiet "$WORK/counter-t1.out.err" "a gate with nothing to compare prints nothing"
expect_merged "$TIP1" "the first ticket lands"
expect_test_ran "the first ticket's merge runs the tests"
HEAD_AFTER_T1=$(git -C "$INTEGRATION" rev-parse HEAD)

# t2 branched from the same base, adds ADR 0005-b and also bumps VERSION to
# 1.1.0, then merges the Integration branch back before reporting: the
# merge-base has moved to the Integration tip, so only the first-parent base
# still finds t1's additions.
new_ticket 2 "$BASE102"
T2=$T
printf '%s\n' 'adr five b' > "$T2/docs/adr/0005-b.md"
printf '%s\n' '1.1.0' > "$T2/VERSION"
commit_in "$T2" 'ticket two adds ADR 0005-b and bumps VERSION to 1.1.0'
SHORT2=$(git -C "$T2" rev-parse --short HEAD)
git -C "$T2" merge --quiet --no-edit spec-102
TIP2=$(git -C "$T2" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-both.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t2 --test 'fake-test'
expect_exit 6 "both sides adding ADR 0005 and VERSION 1.1.0 exits 6"
expect_has 'numbered-dir docs/adr 0005' "the collision names the numbered directory and its prefix" "$WORK/counter-both.out.err"
expect_has 'version VERSION' "the collision names the version file" "$WORK/counter-both.out.err"
expect_has 'docs/adr/0005-a.md' "the collision names the Integration side's entry" "$WORK/counter-both.out.err"
expect_has 'docs/adr/0005-b.md' "the collision names the ticket side's entry" "$WORK/counter-both.out.err"
expect_has $'integration\t'"$SHORT1" "the collision cites the Integration side's commit" "$WORK/counter-both.out.err"
expect_has $'ticket\t'"$SHORT2" "the collision cites the ticket side's commit" "$WORK/counter-both.out.err"
expect_has 'nothing merged' "the collision says nothing was merged" "$WORK/counter-both.out.err"
expect_head "$HEAD_AFTER_T1" "a counter collision leaves the Integration branch where it was"
expect_clean "a counter collision leaves no half-merged state"
expect_test_not_run "a counter collision runs no tests"
expect_untouched "$T2" "$TIP2" "a counter collision leaves the ticket branch and worktree alone"
expect_without 'gate not met' "a counter collision is not a gate failure" "$WORK/counter-both.out.err"
if [ -s "$WORK/counter-both.out" ]; then
  bad "a counter collision prints nothing on stdout" "$(cat "$WORK/counter-both.out")"
else
  ok "a counter collision prints nothing on stdout"
fi

# Re-bump on the ticket side only: 0005-b renamed to 0006-b, VERSION 1.1.1, no
# merge-back. The ticket side's net additions no longer collide and its VERSION
# differs from the Integration tip, so the rerun merges.
git -C "$T2" mv docs/adr/0005-b.md docs/adr/0006-b.md
printf '%s\n' '1.1.1' > "$T2/VERSION"
commit_in "$T2" 'ticket two re-bumps: ADR 0006-b, VERSION 1.1.1'
TIP2=$(git -C "$T2" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-rebump.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t2 --test 'fake-test'
expect_exit 0 "after the re-bump the rerun merges"
expect_quiet "$WORK/counter-rebump.out.err" "a cleared collision prints nothing"
expect_merged "$TIP2" "the re-bumped ticket lands"
expect_content "$INTEGRATION" VERSION '1.1.1' "the merge brings the re-bumped VERSION"
expect_absent "$INTEGRATION" docs/adr/0005-b.md "the merge brings no entry 0005 from the ticket"
expect_content "$INTEGRATION" docs/adr/0006-b.md 'adr five b' "the merge brings the renumbered entry"
expect_content "$INTEGRATION" docs/adr/0005-a.md 'adr five a' "the merge keeps the Integration side's entry 0005"
expect_test_ran "the rerun runs the tests"

# --- numbered directory alone, VERSION already past: only one class is listed ---
# t3 lands ADR 0007-a and VERSION 1.2.0. t4 branched from the tip before that,
# adds ADR 0007-b, merges the Integration branch back, then moves VERSION on
# to 1.3.0: the numbered directory collides, the version file does not.
HEAD_BEFORE_T3=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 3 "$HEAD_BEFORE_T3"
T3=$T
printf '%s\n' 'adr seven a' > "$T3/docs/adr/0007-a.md"
printf '%s\n' '1.2.0' > "$T3/VERSION"
commit_in "$T3" 'ticket three adds ADR 0007-a and bumps VERSION to 1.2.0'
TIP3=$(git -C "$T3" rev-parse HEAD)
SHORT3=$(git -C "$T3" rev-parse --short HEAD)
run_merge "$WORK/counter-t3.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t3 --test 'fake-test'
expect_exit 0 "the third ticket lands"
HEAD_AFTER_T3=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 4 "$HEAD_BEFORE_T3"
T4=$T
printf '%s\n' 'adr seven b' > "$T4/docs/adr/0007-b.md"
commit_in "$T4" 'ticket four adds ADR 0007-b'
SHORT4=$(git -C "$T4" rev-parse --short HEAD)
git -C "$T4" merge --quiet --no-edit spec-102
printf '%s\n' '1.3.0' > "$T4/VERSION"
commit_in "$T4" 'ticket four moves VERSION on to 1.3.0'
TIP4=$(git -C "$T4" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-adr-only.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t4 --test 'fake-test'
expect_exit 6 "a colliding ADR with VERSION already past exits 6"
expect_has 'numbered-dir docs/adr 0007' "the collision names ADR 0007" "$WORK/counter-adr-only.out.err"
expect_without 'version VERSION' "a VERSION that moved past is not listed" "$WORK/counter-adr-only.out.err"
expect_without 'numbered-dir docs/adr 0005' "an ADR number the ticket did not add is not listed" "$WORK/counter-adr-only.out.err"
expect_has $'integration\t'"$SHORT3" "the collision cites the Integration side's commit" "$WORK/counter-adr-only.out.err"
expect_has $'ticket\t'"$SHORT4" "the collision cites the ticket side's commit" "$WORK/counter-adr-only.out.err"
expect_head "$HEAD_AFTER_T3" "an ADR-only collision leaves the Integration branch where it was"
expect_clean "an ADR-only collision leaves no half-merged state"
expect_test_not_run "an ADR-only collision runs no tests"
expect_untouched "$T4" "$TIP4" "an ADR-only collision leaves the ticket branch and worktree alone"

git -C "$T4" mv docs/adr/0007-b.md docs/adr/0008-b.md
commit_in "$T4" 'ticket four re-bumps: ADR 0008-b'
TIP4=$(git -C "$T4" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-adr-rebump.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t4 --test 'fake-test'
expect_exit 0 "after the ADR re-bump the rerun merges"
expect_quiet "$WORK/counter-adr-rebump.out.err" "a cleared ADR collision prints nothing"
expect_merged "$TIP4" "the renumbered ticket lands"
expect_content "$INTEGRATION" docs/adr/0008-b.md 'adr seven b' "the merge brings the renumbered entry 0008"
expect_absent "$INTEGRATION" docs/adr/0007-b.md "the merge brings no entry 0007 from the ticket"
expect_content "$INTEGRATION" VERSION '1.3.0' "the merge brings the ticket's VERSION"
expect_test_ran "the ADR rerun runs the tests"

# --- no merge-back: still a collision; a different number is not ---
# t5 lands ADR 0010-a and VERSION 1.4.0. t6 branched from the tip before that
# adds ADR 0010-b and also sets VERSION to 1.4.0, without merging anything
# back: both collide (and git alone would have merged the ADRs silently).
HEAD_BEFORE_T5=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 5 "$HEAD_BEFORE_T5"
T5=$T
printf '%s\n' 'adr ten a' > "$T5/docs/adr/0010-a.md"
printf '%s\n' '1.4.0' > "$T5/VERSION"
commit_in "$T5" 'ticket five adds ADR 0010-a and bumps VERSION to 1.4.0'
TIP5=$(git -C "$T5" rev-parse HEAD)
SHORT5=$(git -C "$T5" rev-parse --short HEAD)
run_merge "$WORK/counter-t5.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t5 --test 'fake-test'
expect_exit 0 "the fifth ticket lands"
HEAD_AFTER_T5=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 6 "$HEAD_BEFORE_T5"
T6=$T
printf '%s\n' 'adr ten b' > "$T6/docs/adr/0010-b.md"
printf '%s\n' '1.4.0' > "$T6/VERSION"
commit_in "$T6" 'ticket six adds ADR 0010-b and bumps VERSION to 1.4.0'
TIP6=$(git -C "$T6" rev-parse HEAD)
SHORT6=$(git -C "$T6" rev-parse --short HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-nomergeback.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t6 --test 'fake-test'
expect_exit 6 "a collision without a merge-back exits 6"
expect_has 'numbered-dir docs/adr 0010' "the collision without a merge-back names ADR 0010" "$WORK/counter-nomergeback.out.err"
expect_has 'version VERSION' "the collision without a merge-back names VERSION" "$WORK/counter-nomergeback.out.err"
expect_has $'integration\t'"$SHORT5" "the collision without a merge-back cites the Integration side's commit" "$WORK/counter-nomergeback.out.err"
expect_has $'ticket\t'"$SHORT6" "the collision without a merge-back cites the ticket side's commit" "$WORK/counter-nomergeback.out.err"
expect_head "$HEAD_AFTER_T5" "a collision without a merge-back leaves the Integration branch where it was"
expect_clean "a collision without a merge-back leaves no half-merged state"
expect_test_not_run "a collision without a merge-back runs no tests"
expect_untouched "$T6" "$TIP6" "a collision without a merge-back leaves the ticket branch and worktree alone"

# t7 from the same tip adds ADR 0011-b: a different number from the Integration
# side's 0010-a, so it merges (VERSION untouched).
new_ticket 7 "$HEAD_BEFORE_T5"
T7=$T
printf '%s\n' 'adr eleven b' > "$T7/docs/adr/0011-b.md"
commit_in "$T7" 'ticket seven adds ADR 0011-b'
TIP7=$(git -C "$T7" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-other-number.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t7 --test 'fake-test'
expect_exit 0 "a different ADR number is not a collision"
expect_quiet "$WORK/counter-other-number.out.err" "a different ADR number prints nothing"
expect_merged "$TIP7" "the ticket with the other number lands"
expect_content "$INTEGRATION" docs/adr/0010-a.md 'adr ten a' "the Integration side's entry 0010 stays"
expect_content "$INTEGRATION" docs/adr/0011-b.md 'adr eleven b' "the merge brings the ticket's entry 0011"

# --- VERSION alone: merged back without touching it, or moved on after --------
# t8 adds an unrelated file and merges the Integration branch back: its VERSION
# equals the Integration tip (it came from there) and its own commits never
# touched the file, so nothing is listed.
new_ticket 8 "$HEAD_BEFORE_T5"
T8=$T
printf '%s\n' 'feature eight' > "$T8/feature8.txt"
commit_in "$T8" 'ticket eight adds a feature'
git -C "$T8" merge --quiet --no-edit spec-102
TIP8=$(git -C "$T8" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-version-untouched.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t8 --test 'fake-test'
expect_exit 0 "a ticket that merged back without touching VERSION merges"
expect_quiet "$WORK/counter-version-untouched.out.err" "an untouched VERSION prints nothing"
expect_merged "$TIP8" "the ticket that did not touch VERSION lands"
HEAD_AFTER_T8=$(git -C "$INTEGRATION" rev-parse HEAD)

# t9 set VERSION to the Integration tip's value, merged the Integration branch
# back, then moved VERSION on: touched by its own commits, but the tips differ.
new_ticket 9 "$HEAD_BEFORE_T5"
T9=$T
printf '%s\n' '1.4.0' > "$T9/VERSION"
commit_in "$T9" 'ticket nine bumps VERSION to 1.4.0'
git -C "$T9" merge --quiet --no-edit spec-102
printf '%s\n' '1.5.0' > "$T9/VERSION"
commit_in "$T9" 'ticket nine moves VERSION on to 1.5.0'
TIP9=$(git -C "$T9" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-version-moved.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t9 --test 'fake-test'
expect_exit 0 "a ticket that moved VERSION on after merging back merges"
expect_quiet "$WORK/counter-version-moved.out.err" "a VERSION that moved on prints nothing"
expect_merged "$TIP9" "the ticket that moved VERSION on lands"
expect_content "$INTEGRATION" VERSION '1.5.0' "the merge brings the ticket's VERSION 1.5.0"
expect_content "$INTEGRATION" feature8.txt 'feature eight' "the merge keeps the earlier ticket's file"

# --- not built in: CHANGELOG and pyproject.toml; --counter names them ---------
# t10 appends a line to the CHANGELOG and lands. t11 from the tip before that
# appends the same line: identical changes merge cleanly and the CHANGELOG is
# not a built-in counter, so nothing is listed.
HEAD_BEFORE_T10=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 10 "$HEAD_BEFORE_T10"
T10=$T
printf '%s\n' '- change ten' >> "$T10/CHANGELOG.md"
commit_in "$T10" 'ticket ten appends to the CHANGELOG'
TIP10=$(git -C "$T10" rev-parse HEAD)
run_merge "$WORK/counter-t10.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t10 --test 'fake-test'
expect_exit 0 "the tenth ticket lands"
HEAD_AFTER_T10=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 11 "$HEAD_BEFORE_T10"
T11=$T
printf '%s\n' '- change ten' >> "$T11/CHANGELOG.md"
commit_in "$T11" 'ticket eleven appends the same CHANGELOG line'
TIP11=$(git -C "$T11" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-changelog.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t11 --test 'fake-test'
expect_exit 0 "the CHANGELOG is not a built-in counter"
expect_quiet "$WORK/counter-changelog.out.err" "identical CHANGELOG changes print nothing"
expect_merged "$TIP11" "the ticket with the same CHANGELOG change lands"
HEAD_AFTER_T11=$(git -C "$INTEGRATION" rev-parse HEAD)

# pyproject.toml: t12 sets version = "2.0.0" and lands; t13 from the tip
# before that makes the identical change and merges unlisted; t14 from the
# same tip makes it again, and now --counter names the file (twice, to show
# the option repeats and takes the union with the built-ins: the CHANGELOG
# is named too but is not in the Integration side's diff since the base).
HEAD_BEFORE_T12=$HEAD_AFTER_T11
new_ticket 12 "$HEAD_BEFORE_T12"
T12=$T
printf '%s\n' '[project]' 'version = "2.0.0"' '' '[tool.x]' 'key = 1' > "$T12/pyproject.toml"
commit_in "$T12" 'ticket twelve sets the pyproject version to 2.0.0'
TIP12=$(git -C "$T12" rev-parse HEAD)
SHORT12=$(git -C "$T12" rev-parse --short HEAD)
run_merge "$WORK/counter-t12.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t12 --test 'fake-test'
expect_exit 0 "the twelfth ticket lands"
HEAD_AFTER_T12=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 13 "$HEAD_BEFORE_T12"
T13B=$T
printf '%s\n' '[project]' 'version = "2.0.0"' '' '[tool.x]' 'key = 1' > "$T13B/pyproject.toml"
commit_in "$T13B" 'ticket thirteen sets the same pyproject version'
TIP13B=$(git -C "$T13B" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-pyproject.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t13 --test 'fake-test'
expect_exit 0 "pyproject.toml is not a built-in counter"
expect_quiet "$WORK/counter-pyproject.out.err" "identical pyproject.toml changes print nothing"
expect_merged "$TIP13B" "the ticket with the same pyproject.toml change lands"
HEAD_AFTER_T13B=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 14 "$HEAD_BEFORE_T12"
T14=$T
printf '%s\n' '[project]' 'version = "2.0.0"' '' '[tool.x]' 'key = 1' > "$T14/pyproject.toml"
commit_in "$T14" 'ticket fourteen sets the same pyproject version'
TIP14=$(git -C "$T14" rev-parse HEAD)
SHORT14=$(git -C "$T14" rev-parse --short HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-named.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t14 --test 'fake-test' --counter pyproject.toml --counter CHANGELOG.md
expect_exit 6 "a named counter both sides set to the same content exits 6"
expect_has 'version pyproject.toml' "the collision names the counter the caller passed" "$WORK/counter-named.out.err"
expect_without 'version CHANGELOG.md' "a named counter outside the Integration side's diff is not listed" "$WORK/counter-named.out.err"
expect_has $'integration\t'"$SHORT12" "the named collision cites the Integration side's commit" "$WORK/counter-named.out.err"
expect_has $'ticket\t'"$SHORT14" "the named collision cites the ticket side's commit" "$WORK/counter-named.out.err"
expect_head "$HEAD_AFTER_T13B" "a named collision leaves the Integration branch where it was"
expect_clean "a named collision leaves no half-merged state"
expect_test_not_run "a named collision runs no tests"
expect_untouched "$T14" "$TIP14" "a named collision leaves the ticket branch and worktree alone"

# --- step 9.1 shape: main into the Integration branch, checked out nowhere ------
# --ticket names a remote-tracking ref with --no-ticket-worktree. origin/main is
# still the commit spec-102 branched from: nothing to merge is exit 5, not the
# gate failure a fresh Ticket branch would be.
git -C "$INTEGRATION" fetch --quiet origin
HEAD_BEFORE_91=$(git -C "$INTEGRATION" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/step91-uptodate.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket origin/main --no-ticket-worktree --test 'fake-test'
expect_exit 5 "an origin/main already in the Integration branch exits 5"
expect_has 'ticket ref origin/main is already part of spec-102: nothing to merge' "an origin/main with nothing to merge says so" "$WORK/step91-uptodate.out.err"
expect_without 'gate not met' "an origin/main with nothing to merge is not a gate failure" "$WORK/step91-uptodate.out.err"
expect_test_not_run "an origin/main with nothing to merge runs no tests"
expect_head "$HEAD_BEFORE_91" "an origin/main with nothing to merge changes nothing"

# spec-102 adds ADR 0005-d and main adds 0020-c (another Spec landed there): no
# number in common, so the merge happens as a merge commit of the previous tip
# and origin/main.
mkdir -p "$MAIN/docs/adr"
printf '%s\n' 'adr twenty c' > "$MAIN/docs/adr/0020-c.md"
commit_in "$MAIN" 'main adds ADR 0020-c'
git -C "$MAIN" push --quiet origin main
printf '%s\n' 'adr five d' > "$INTEGRATION/docs/adr/0005-d.md"
commit_in "$INTEGRATION" 'spec 102 adds ADR 0005-d'
git -C "$INTEGRATION" fetch --quiet origin
ORIGIN_MAIN=$(git -C "$INTEGRATION" rev-parse origin/main)
HEAD_91=$(git -C "$INTEGRATION" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/step91-clean.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket origin/main --no-ticket-worktree --test 'fake-test unit'
expect_exit 0 "step 9.1 with a different ADR number merges"
expect_quiet "$WORK/step91-clean.out.err" "a clean step 9.1 prints nothing"
expect_has 'merge-ticket: merged origin/main into spec-102' "a clean step 9.1 reports the merge" "$WORK/step91-clean.out"
parents=$(git -C "$INTEGRATION" log -1 --format='%P' HEAD)
if [ "$parents" = "$HEAD_91 $ORIGIN_MAIN" ]; then
  ok "a clean step 9.1 is a merge commit of the previous tip and origin/main"
else
  bad "a clean step 9.1 is a merge commit of the previous tip and origin/main" "parents=[$parents]"
fi
expect_content "$INTEGRATION" docs/adr/0020-c.md 'adr twenty c' "a clean step 9.1 brings main's entry"
expect_test_ran "a clean step 9.1 runs the tests"
expect_clean "a clean step 9.1 leaves a clean worktree"
HEAD_AFTER_91=$(git -C "$INTEGRATION" rev-parse HEAD)

# origin/main now sits behind that merge: still exit 5, still no tests.
: > "$TEST_LOG"
run_merge "$WORK/step91-landed.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket origin/main --no-ticket-worktree --test 'fake-test unit'
expect_exit 5 "an origin/main behind a merge commit exits 5"
expect_has 'nothing to merge' "an origin/main behind a merge commit says so" "$WORK/step91-landed.out.err"
expect_without 'gate not met' "an origin/main behind a merge commit is not a gate failure" "$WORK/step91-landed.out.err"
expect_test_not_run "an origin/main behind a merge commit runs no tests"
expect_head "$HEAD_AFTER_91" "an origin/main behind a merge commit changes nothing"

# main adds ADR 0005-c (another Spec landed there): the same number spec-102
# holds as 0005-a and 0005-d, and main is never merged back.
printf '%s\n' 'adr five c' > "$MAIN/docs/adr/0005-c.md"
commit_in "$MAIN" 'main adds ADR 0005-c'
git -C "$MAIN" push --quiet origin main
SHORT_MAIN_91=$(git -C "$MAIN" rev-parse --short HEAD)
git -C "$INTEGRATION" fetch --quiet origin
HEAD_91=$(git -C "$INTEGRATION" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/step91-collide.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket origin/main --no-ticket-worktree --test 'fake-test unit'
expect_exit 6 "step 9.1 with ADR 0005 added on both sides exits 6"
expect_has 'numbered-dir docs/adr 0005' "the step 9.1 collision names ADR 0005" "$WORK/step91-collide.out.err"
expect_has 'docs/adr/0005-c.md' "the step 9.1 collision names main's entry" "$WORK/step91-collide.out.err"
expect_has 'docs/adr/0005-d.md' "the step 9.1 collision names the Integration side's entry" "$WORK/step91-collide.out.err"
expect_has $'ticket\t'"$SHORT_MAIN_91" "the step 9.1 collision cites main's commit" "$WORK/step91-collide.out.err"
expect_head "$HEAD_91" "the step 9.1 collision leaves the Integration branch where it was"
expect_clean "the step 9.1 collision leaves no half-merged state"
expect_test_not_run "the step 9.1 collision runs no tests"
# Without the switch the default gate is unchanged: origin/main is not a local
# branch, so it does not exist as far as --ticket is concerned.
run_merge "$WORK/step91-default.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket origin/main --test 'fake-test unit'
expect_exit 2 "origin/main without --no-ticket-worktree exits 2"
expect_has 'ticket branch origin/main does not exist' "origin/main without the switch is not a ticket branch" "$WORK/step91-default.out.err"
expect_without 'numbered-dir' "the default gate stops before the counters" "$WORK/step91-default.out.err"

# The switch is about the check, not the kind of ref: a local Ticket branch
# with no worktree (spec-101-t9 above) passes with it and merges.
: > "$TEST_LOG"
run_merge "$WORK/no-worktree-switch.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-101-t9 --no-ticket-worktree --test 'fake-test'
expect_exit 0 "a ticket branch without a worktree merges with --no-ticket-worktree"
expect_merged "$(git -C "$MAIN" rev-parse spec-101-t9)" "the ticket branch without a worktree lands"
expect_test_ran "the ticket branch without a worktree runs the tests"

# The switch only skips the Ticket worktree checks; a local branch that has a
# clean worktree merges with it as without it.
new_ticket 21 "$(git -C "$INTEGRATION" rev-parse HEAD)"
T21=$T
printf '%s\n' 'feature twenty-one' > "$T21/feature21.txt"
commit_in "$T21" 'ticket twenty-one adds a feature'
TIP21=$(git -C "$T21" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/switch-checked-out.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t21 --no-ticket-worktree --test 'fake-test'
expect_exit 0 "a checked-out, clean local branch merges with --no-ticket-worktree"
expect_quiet "$WORK/switch-checked-out.out.err" "a checked-out local branch with the switch prints nothing"
expect_merged "$TIP21" "the checked-out local branch lands with the switch"
expect_test_ran "a checked-out local branch with the switch runs the tests"
expect_untouched "$T21" "$TIP21" "the switch leaves the ticket worktree alone"

# --- one directory per number (migrations) -------------------------------------
# A file under a numbered entry counts as that number. spec-102 adds
# migrations/0001-init/up.sql and migrations/0002-next/up.sql, so migrations is
# a numbered directory; t15 adds migrations/0003-index/up.sql and lands; t16
# from the tip before that adds migrations/0003-unique/up.sql. The files are
# different paths, so git alone would merge them; the gate goes by the parent
# entries' number.
mkdir -p "$INTEGRATION/migrations/0001-init" "$INTEGRATION/migrations/0002-next"
printf '%s\n' 'create table users' > "$INTEGRATION/migrations/0001-init/up.sql"
printf '%s\n' 'add column email' > "$INTEGRATION/migrations/0002-next/up.sql"
commit_in "$INTEGRATION" 'spec 102 adds two migrations'
HEAD_MIG_BASE=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 15 "$HEAD_MIG_BASE"
T15=$T
mkdir -p "$T15/migrations/0003-index"
printf '%s\n' 'create index users_email' > "$T15/migrations/0003-index/up.sql"
commit_in "$T15" 'ticket fifteen adds migration 0003-index'
TIP15=$(git -C "$T15" rev-parse HEAD)
SHORT15=$(git -C "$T15" rev-parse --short HEAD)
run_merge "$WORK/counter-t15.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t15 --test 'fake-test'
expect_exit 0 "a migration under a new number merges"
HEAD_AFTER_T15=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 16 "$HEAD_MIG_BASE"
T16=$T
mkdir -p "$T16/migrations/0003-unique"
printf '%s\n' 'create unique index users_email' > "$T16/migrations/0003-unique/up.sql"
commit_in "$T16" 'ticket sixteen adds migration 0003-unique'
TIP16=$(git -C "$T16" rev-parse HEAD)
SHORT16=$(git -C "$T16" rev-parse --short HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-migration.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t16 --test 'fake-test'
expect_exit 6 "two migrations under the same number, one directory each, exit 6"
expect_has 'numbered-dir migrations 0003' "the migration collision names the directory and the number" "$WORK/counter-migration.out.err"
expect_has 'migrations/0003-index/up.sql' "the migration collision names the Integration side's file" "$WORK/counter-migration.out.err"
expect_has 'migrations/0003-unique/up.sql' "the migration collision names the ticket side's file" "$WORK/counter-migration.out.err"
expect_has $'integration\t'"$SHORT15" "the migration collision cites the Integration side's commit" "$WORK/counter-migration.out.err"
expect_has $'ticket\t'"$SHORT16" "the migration collision cites the ticket side's commit" "$WORK/counter-migration.out.err"
expect_head "$HEAD_AFTER_T15" "a migration collision leaves the Integration branch where it was"
expect_clean "a migration collision leaves no half-merged state"
expect_test_not_run "a migration collision runs no tests"
expect_untouched "$T16" "$TIP16" "a migration collision leaves the ticket branch and worktree alone"

git -C "$T16" mv migrations/0003-unique migrations/0004-unique
commit_in "$T16" 'ticket sixteen re-bumps: migration 0004-unique'
TIP16=$(git -C "$T16" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-migration-rebump.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t16 --test 'fake-test'
expect_exit 0 "after the migration re-bump the rerun merges"
expect_quiet "$WORK/counter-migration-rebump.out.err" "a cleared migration collision prints nothing"
expect_content "$INTEGRATION" migrations/0004-unique/up.sql 'create unique index users_email' "the merge brings the renumbered migration"
expect_absent "$INTEGRATION" migrations/0003-unique/up.sql "the merge brings no migration 0003 from the ticket"
expect_content "$INTEGRATION" migrations/0003-index/up.sql 'create index users_email' "the merge keeps the Integration side's migration 0003"
expect_test_ran "the migration rerun runs the tests"

# --- the separator may be an underscore, the digits may be long -----------------
# spec-102 adds db/migrate/20260725000000_create_users.rb and
# 20260726000000_add_email.rb, so db/migrate is a numbered directory. t17 adds
# 20260727000000_create_index.rb and lands; t18 from the tip before that adds
# 20260727000000_add_unique_index.rb: the same timestamp, so they collide.
mkdir -p "$INTEGRATION/db/migrate"
printf '%s\n' 'create_table :users' > "$INTEGRATION/db/migrate/20260725000000_create_users.rb"
printf '%s\n' 'add_column :users, :email, :string' > "$INTEGRATION/db/migrate/20260726000000_add_email.rb"
commit_in "$INTEGRATION" 'spec 102 adds two timestamped migrations'
HEAD_BEFORE_T17=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 17 "$HEAD_BEFORE_T17"
T17=$T
printf '%s\n' 'add_index :users, :email' > "$T17/db/migrate/20260727000000_create_index.rb"
commit_in "$T17" 'ticket seventeen adds the 20260727 migration'
TIP17=$(git -C "$T17" rev-parse HEAD)
SHORT17=$(git -C "$T17" rev-parse --short HEAD)
run_merge "$WORK/counter-t17.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t17 --test 'fake-test'
expect_exit 0 "a timestamped migration under a new timestamp merges"
HEAD_AFTER_T17=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 18 "$HEAD_BEFORE_T17"
T18=$T
printf '%s\n' 'add_index :users, :email, unique: true' > "$T18/db/migrate/20260727000000_add_unique_index.rb"
commit_in "$T18" 'ticket eighteen adds a migration with the same timestamp'
TIP18=$(git -C "$T18" rev-parse HEAD)
SHORT18=$(git -C "$T18" rev-parse --short HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-underscore.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t18 --test 'fake-test'
expect_exit 6 "two migrations with the same timestamp and an underscore exit 6"
expect_has 'numbered-dir db/migrate 20260727000000' "the timestamp collision names the digits without the underscore" "$WORK/counter-underscore.out.err"
expect_has 'db/migrate/20260727000000_create_index.rb' "the timestamp collision names the Integration side's entry" "$WORK/counter-underscore.out.err"
expect_has 'db/migrate/20260727000000_add_unique_index.rb' "the timestamp collision names the ticket side's entry" "$WORK/counter-underscore.out.err"
expect_has $'integration\t'"$SHORT17" "the timestamp collision cites the Integration side's commit" "$WORK/counter-underscore.out.err"
expect_has $'ticket\t'"$SHORT18" "the timestamp collision cites the ticket side's commit" "$WORK/counter-underscore.out.err"
expect_head "$HEAD_AFTER_T17" "a timestamp collision leaves the Integration branch where it was"
expect_test_not_run "a timestamp collision runs no tests"
expect_untouched "$T18" "$TIP18" "a timestamp collision leaves the ticket branch and worktree alone"

# --- VERSION alone -------------------------------------------------------------
# t19 bumps VERSION to 1.6.0 and lands. t20 from the tip before that sets it to
# 1.6.0 too, adding no numbered entry, and merges the Integration branch back
# (as t2 does, so that its later re-bump merges without a textual conflict):
# only the version file collides, and moving that one file on lets the rerun
# merge.
HEAD_BEFORE_T19=$(git -C "$INTEGRATION" rev-parse HEAD)
new_ticket 19 "$HEAD_BEFORE_T19"
T19=$T
printf '%s\n' '1.6.0' > "$T19/VERSION"
commit_in "$T19" 'ticket nineteen bumps VERSION to 1.6.0'
TIP19=$(git -C "$T19" rev-parse HEAD)
SHORT19=$(git -C "$T19" rev-parse --short HEAD)
run_merge "$WORK/counter-t19.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t19 --test 'fake-test'
expect_exit 0 "the nineteenth ticket lands"
HEAD_AFTER_T19=$(git -C "$INTEGRATION" rev-parse HEAD)

new_ticket 20 "$HEAD_BEFORE_T19"
T20=$T
printf '%s\n' '1.6.0' > "$T20/VERSION"
commit_in "$T20" 'ticket twenty sets VERSION to 1.6.0 as well'
SHORT20=$(git -C "$T20" rev-parse --short HEAD)
git -C "$T20" merge --quiet --no-edit spec-102
TIP20=$(git -C "$T20" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-version-only.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t20 --test 'fake-test'
expect_exit 6 "VERSION set to the same value by both sides, nothing else, exits 6"
expect_has 'version VERSION' "a VERSION-only collision names the version file" "$WORK/counter-version-only.out.err"
expect_without 'numbered-dir' "a VERSION-only collision lists no numbered directory" "$WORK/counter-version-only.out.err"
expect_has $'integration\t'"$SHORT19" "a VERSION-only collision cites the Integration side's commit" "$WORK/counter-version-only.out.err"
expect_has $'ticket\t'"$SHORT20" "a VERSION-only collision cites the ticket side's commit" "$WORK/counter-version-only.out.err"
expect_head "$HEAD_AFTER_T19" "a VERSION-only collision leaves the Integration branch where it was"
expect_clean "a VERSION-only collision leaves no half-merged state"
expect_test_not_run "a VERSION-only collision runs no tests"
expect_untouched "$T20" "$TIP20" "a VERSION-only collision leaves the ticket branch and worktree alone"

printf '%s\n' '1.7.0' > "$T20/VERSION"
commit_in "$T20" 'ticket twenty re-bumps VERSION to 1.7.0'
TIP20=$(git -C "$T20" rev-parse HEAD)
: > "$TEST_LOG"
run_merge "$WORK/counter-version-only-rebump.out" --worktree "$INTEGRATION" --integration spec-102 \
  --ticket spec-102-t20 --test 'fake-test'
expect_exit 0 "after a re-bump of VERSION alone the rerun merges"
expect_quiet "$WORK/counter-version-only-rebump.out.err" "a cleared VERSION-only collision prints nothing"
expect_merged "$TIP20" "the re-bumped VERSION-only ticket lands"
expect_content "$INTEGRATION" VERSION '1.7.0' "the merge brings the re-bumped VERSION"
expect_test_ran "the VERSION-only rerun runs the tests"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
