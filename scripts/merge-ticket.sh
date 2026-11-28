#!/usr/bin/env bash
# Merge one Ticket branch into its Spec's Integration branch (GLOSSARY.md) and
# run the test command, all inside the Integration branch's worktree. A Spec
# session runs this in step 5 instead of a merger role: only a conflict needs a
# worker, and SKILL.md dispatches that one, never this script. Step 9.1 (main
# into the Integration branch) runs it too, with --no-ticket-worktree.
#
# Usage:
#   merge-ticket.sh --worktree <integration worktree> --integration <branch>
#                   --ticket <branch> --test '<command>'
#                   [--no-ticket-worktree]
#   merge-ticket.sh --worktree <integration worktree> --integration spec-<n>
#                   --ticket origin/<main branch> --test '<command>'
#                   --no-ticket-worktree
#
# --worktree is the worktree that has the Integration branch checked out; the
# merge and the test command both run there, and the script never checks out
# another branch in it. --integration is that branch by name. --ticket is the
# Ticket branch by name, a local branch such as spec-<n>-t<m>; with
# --no-ticket-worktree it may be anything git resolves here (a remote-tracking
# ref such as origin/main, a tag, a commit). --test is the repository's test
# command exactly as its documentation gives it (for example `bash
# scripts/test-x.sh && bash scripts/test-y.sh`); the script does not guess one.
# It runs through `bash -c` in the worktree after the merge, with stdin closed,
# and its stdout and stderr are passed through unchanged. --no-ticket-worktree
# skips the two checks about the Ticket branch's own worktree (that some
# worktree has it checked out, and that that worktree is clean): step 9.1
# merges a ref nobody has checked out. It is never inferred from --ticket.
#
# Gate (all checked before anything is merged; any miss exits 2 and merges
# nothing): the worktree is the top level of a git worktree and has
# --integration checked out; both branches exist; the Ticket branch has at
# least one commit the Integration branch does not have; some worktree has the
# Ticket branch checked out and it is clean (unless --no-ticket-worktree); the
# Integration worktree is clean too. "Clean" is an empty
# `git status --porcelain`, so untracked files count. Lean-started
# implementation workers load no hooks, so their prompt rules are backed by
# this gate and by review, not by a hook. One miss is not a gate failure: a
# Ticket branch that is already part of the Integration branch (a Recovery run
# of step 5, or a worker that merged its own branch) has landed, and that
# exits 5, apart from 2 (the implementation is not done). With
# --no-ticket-worktree there is a single exit for "nothing to merge", 5,
# whether the ref sits behind a merge commit (main was merged before) or on
# the Integration branch's first-parent line (main has not moved since the
# Spec branched); the tree did not change, so the test command does not run.
#
# The merge is `git merge --no-ff --no-edit`: every Ticket lands as a merge
# commit whatever the two branches look like. On a conflict the conflicted
# paths are listed on stderr, `git merge --abort` puts the worktree back to
# the state before the merge, the test command does not run, and the exit code
# is 3. When the merge succeeds but the test command fails, the merge commit
# stays (a fix role builds on it) and the exit code is 4.
#
# Exit codes:
#   0  merged, and the test command passed
#   1  a git command failed for none of the reasons below (stderr says which;
#      the worktree is clean unless stderr says the abort failed)
#   2  gate not met: nothing merged, tests not run, stderr says which check
#   3  merge conflict: worktree restored, conflicted paths on stderr
#   4  merged, but the test command failed (its output on stdout/stderr)
#   5  nothing to merge: the Ticket branch is already part of the Integration
#      branch (the ticket has landed; with --no-ticket-worktree also a ref
#      that brings no new commit), nothing merged, tests not run, stderr says
#      so (the caller goes on, no re-dispatch)
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --worktree <integration worktree> --integration <branch>
                   --ticket <branch> --test '<command>'
                   [--no-ticket-worktree]

Merge the Ticket branch into the Integration branch in its worktree (a merge
commit, --no-ff), then run the test command there through bash -c. Nothing is
merged unless the Ticket branch has new commits and both worktrees are clean.
A Ticket branch already part of the Integration branch exits 5 (nothing to
merge); a conflict aborts the merge and leaves the worktree as it was.
--no-ticket-worktree lets --ticket be a ref nobody has checked out (step 9.1:
origin/<main branch>) and skips the Ticket worktree checks.
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

warn() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
}

gate_fail() {
  warn "$1"
  warn "gate not met: nothing merged, tests not run"
  exit 2
}

WORKTREE=
INTEGRATION=
TICKET=
TEST_CMD=
NO_TICKET_WORKTREE=

while [ $# -gt 0 ]; do
  case "$1" in
    --worktree)
      [ $# -ge 2 ] || usage_error '--worktree requires a path'
      [ -z "$WORKTREE" ] || usage_error '--worktree may only be given once'
      WORKTREE=$2
      shift 2
      ;;
    --integration)
      [ $# -ge 2 ] || usage_error '--integration requires a branch name'
      [ -z "$INTEGRATION" ] || usage_error '--integration may only be given once'
      INTEGRATION=$2
      shift 2
      ;;
    --ticket)
      [ $# -ge 2 ] || usage_error '--ticket requires a branch name'
      [ -z "$TICKET" ] || usage_error '--ticket may only be given once'
      TICKET=$2
      shift 2
      ;;
    --test)
      [ $# -ge 2 ] || usage_error '--test requires a command'
      [ -z "$TEST_CMD" ] || usage_error '--test may only be given once'
      TEST_CMD=$2
      shift 2
      ;;
    --no-ticket-worktree)
      NO_TICKET_WORKTREE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$WORKTREE" ] || usage_error '--worktree is required'
[ -n "$INTEGRATION" ] || usage_error '--integration is required'
[ -n "$TICKET" ] || usage_error '--ticket is required'
[ -n "$TEST_CMD" ] || usage_error '--test is required'

# --- gate ---------------------------------------------------------------------

[ -d "$WORKTREE" ] || gate_fail "worktree $WORKTREE does not exist"
WORKTREE=$(cd -P -- "$WORKTREE" && pwd -P) || gate_fail "could not resolve the worktree path $WORKTREE"
# The top level only: a subdirectory would pass every check below and then run
# the test command from the wrong directory.
top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) ||
  gate_fail "$WORKTREE is not a git worktree"
top=$(cd -P -- "$top" && pwd -P)
[ "$top" = "$WORKTREE" ] ||
  gate_fail "$WORKTREE is not the top level of its git worktree ($top is)"

current=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null) ||
  gate_fail "$WORKTREE has a detached HEAD, not the integration branch $INTEGRATION"
[ "$current" = "$INTEGRATION" ] ||
  gate_fail "$WORKTREE is on branch '$current', not the integration branch $INTEGRATION"

# --ticket is a local branch first; only with --no-ticket-worktree does any
# other ref git resolves here count (step 9.1's origin/<main branch>).
TICKET_REF=refs/heads/$TICKET
if ! git -C "$WORKTREE" rev-parse --verify --quiet "$TICKET_REF" >/dev/null; then
  [ -n "$NO_TICKET_WORKTREE" ] || gate_fail "ticket branch $TICKET does not exist"
  TICKET_REF=$(git -C "$WORKTREE" rev-parse --verify --quiet --symbolic-full-name "$TICKET" 2>/dev/null) || TICKET_REF=
  if [ -z "$TICKET_REF" ]; then
    # Not a named ref: a commit, which rev-parse gives back as its sha.
    TICKET_REF=$(git -C "$WORKTREE" rev-parse --verify --quiet "$TICKET" 2>/dev/null) || TICKET_REF=
  fi
  [ -n "$TICKET_REF" ] || gate_fail "ticket ref $TICKET does not exist"
fi

new_commits=$(git -C "$WORKTREE" rev-list --count "refs/heads/$INTEGRATION..$TICKET_REF" 2>/dev/null) ||
  new_commits=0
if [ "$new_commits" -lt 1 ]; then
  if [ -n "$NO_TICKET_WORKTREE" ]; then
    # One exit for "nothing to merge" either way; see the header.
    warn "ticket ref $TICKET is already part of $INTEGRATION: nothing to merge"
    warn "the tree did not change and no tests were run; go on, do not merge it again"
    exit 5
  fi
  # No new commit. Two things look alike here: a ticket that has landed (its
  # branch sits behind a merge commit on the Integration branch -- a Recovery
  # run of step 5, or a worker that merged its own branch) and one whose
  # implementation is not done (a branch just created off the Integration
  # branch, or with nothing of its own). Every landing is a --no-ff merge, so
  # a landed branch is on no first-parent line of the Integration branch; a
  # branch just created sits on it. The first is not a failure of the ticket:
  # exit 5, and the caller releases the Ticket worktree and goes on instead of
  # dispatching the ticket again. The second stays a gate failure, exit 2.
  tip=$(git -C "$WORKTREE" rev-parse --verify --quiet "$TICKET_REF") || tip=
  first_parents=$(git -C "$WORKTREE" rev-list --first-parent "refs/heads/$INTEGRATION" 2>/dev/null) || first_parents=
  if [ -n "$tip" ] && [ -n "$first_parents" ] && ! printf '%s\n' "$first_parents" | grep -qx "$tip"; then
    warn "ticket branch $TICKET is already part of $INTEGRATION (behind a merge commit): the ticket has landed, nothing to merge"
    warn "release the Ticket worktree and go on; do not dispatch the ticket again"
    exit 5
  fi
  gate_fail "ticket branch $TICKET has no commits that $INTEGRATION does not have"
fi

if [ -z "$NO_TICKET_WORKTREE" ]; then
  # The worktree that has the Ticket branch checked out (the main worktree
  # counts; a branch is checked out in at most one worktree).
  TICKET_WORKTREE=$(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null |
    awk -v ref="refs/heads/$TICKET" '
      /^worktree / { path = substr($0, 10) }
      $1 == "branch" && $2 == ref { print path }')
  [ -n "$TICKET_WORKTREE" ] ||
    gate_fail "no worktree has the ticket branch $TICKET checked out"

  dirty=$(git -C "$TICKET_WORKTREE" status --porcelain 2>/dev/null) ||
    gate_fail "could not read the status of the ticket worktree $TICKET_WORKTREE"
  [ -z "$dirty" ] || gate_fail "ticket worktree $TICKET_WORKTREE has uncommitted or untracked changes"
fi

dirty=$(git -C "$WORKTREE" status --porcelain 2>/dev/null) ||
  gate_fail "could not read the status of the integration worktree $WORKTREE"
[ -z "$dirty" ] || gate_fail "integration worktree $WORKTREE has uncommitted or untracked changes"

BEFORE=$(git -C "$WORKTREE" rev-parse HEAD)

# --- merge --------------------------------------------------------------------

if ! git -C "$WORKTREE" merge --no-ff --no-edit "$TICKET"; then
  outcome=1
  if git -C "$WORKTREE" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    # The merge stopped halfway: conflicts, or a hook or signing failed at the
    # commit. Either way the merge is undone, so the caller starts from the
    # Integration branch as it was.
    conflicts=$(git -C "$WORKTREE" diff --name-only --diff-filter=U)
    if [ -n "$conflicts" ]; then
      warn "conflict merging $TICKET into $INTEGRATION; conflicted files:"
      printf '%s\n' "$conflicts" >&2
      outcome=3
    else
      warn "git merge stopped without conflicted files (a hook or commit signing failed?)"
    fi
    git -C "$WORKTREE" merge --abort ||
      { warn "git merge --abort failed; $WORKTREE may be left half merged"; exit 1; }
  else
    warn "git merge failed for a reason other than a conflict; nothing was merged"
  fi
  now=$(git -C "$WORKTREE" rev-parse HEAD)
  dirty=$(git -C "$WORKTREE" status --porcelain 2>/dev/null)
  if [ "$now" != "$BEFORE" ] || [ -n "$dirty" ]; then
    warn "$WORKTREE is not back to the state before the merge (HEAD $now); resolve by hand"
    exit 1
  fi
  if [ "$outcome" -eq 3 ]; then
    warn "merge aborted; $WORKTREE is back to the state before the merge"
  fi
  exit "$outcome"
fi
AFTER=$(git -C "$WORKTREE" rev-parse HEAD)
printf 'merge-ticket: merged %s into %s (%s)\n' "$TICKET" "$INTEGRATION" "$AFTER"

# --- tests --------------------------------------------------------------------

printf 'merge-ticket: running tests in %s: %s\n' "$WORKTREE" "$TEST_CMD"
( cd -P -- "$WORKTREE" && bash -c "$TEST_CMD" ) < /dev/null
test_rc=$?
if [ "$test_rc" -eq 0 ]; then
  printf 'merge-ticket: tests passed\n'
  exit 0
fi
warn "tests failed (exit $test_rc) after merging $TICKET into $INTEGRATION; the merge commit $AFTER stays"
exit 4
