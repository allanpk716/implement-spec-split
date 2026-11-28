#!/usr/bin/env bash
# Merge one Ticket branch into its Spec's Integration branch (GLOSSARY.md) and
# run the test command, all inside the Integration branch's worktree. A Spec
# session runs this in step 5 instead of a merger role: only a conflict or a
# colliding counter needs a worker, and SKILL.md dispatches that one, never
# this script. Step 9.1 (main into the Integration branch) runs it too, with
# --no-ticket-worktree.
#
# Usage:
#   merge-ticket.sh --worktree <integration worktree> --integration <branch>
#                   --ticket <branch> --test '<command>'
#                   [--counter <path>]... [--no-ticket-worktree]
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
# and its stdout and stderr are passed through unchanged. --counter names a
# shared counter file the built-in list does not know (repeatable; the union
# with the built-ins is judged by the version-file rule below). --no-ticket-
# worktree skips the two checks about the Ticket branch's own worktree (that
# some worktree has it checked out, and that that worktree is clean): step 9.1
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
# Shared counters come after every other check and before the merge. Two
# kinds collide without git noticing, and each is judged on its own:
#   numbered directory: a directory holding two or more entries named
#     `<digits>-...` or `<digits>_...` at the Integration tip (ADRs,
#     migrations). When both sides added an entry with the same number in
#     that directory -- different names, same prefix -- they collide. A file
#     under such an entry (one directory per number) counts as that number.
#   version file: VERSION, version.py, version.go, _version.py, plus every
#     --counter path. It collides when the Ticket side's own commits (the
#     non-merge commits the Integration branch does not have) touched it, the
#     Integration side's changes since the base include it, and the two tips
#     hold the same content (the whole file compared, no version parsed).
# CHANGELOG files and manifests such as pyproject.toml are not built in: the
# first needs its entries parsed, the second changes for dependencies too.
# A numbered directory is measured as what each side added since the base, not
# as what it touched; a version file as what the two tips hold. The base is
# the first commit on the Ticket tip's first-parent chain that the Integration
# branch already has (the Integration tip at dispatch time; a merge-back does
# not move it, a rebase does), or the merge-base of the two tips when there is
# none. For a numbered directory the Integration side is the net diff from
# there to its tip, the Ticket side the net diff from
# merge-base(Integration tip, Ticket tip) to the Ticket tip, so the check is
# whether the merged result would hold the same number twice. Both clear once
# the Ticket side re-bumps: the old entry is gone from its net additions, and
# its version file no longer holds the Integration tip's content.
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
#   6  shared counters collide: nothing merged, tests not run, worktree
#      untouched; stderr lists each colliding counter with both sides' commits
#      (`<counter>\t<side>\t<commit> <subject>\t<paths>`, one line per side; a
#      tab in a subject comes out as a space, and the paths field is empty for
#      a version file) for the Brief of the worker that re-bumps the Ticket
#      side. Under --no-ticket-worktree (step 9.1) the ref is read only and the
#      first line names the integration branch as the side to re-bump instead;
#      the lines keep their `integration` / `ticket` labels either way. Rerun
#      after the re-bump; a rerun that still exits 6 means the re-bump did not
#      clear it; the round cap is the caller's (SKILL.md steps 5 / 9.1)
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --worktree <integration worktree> --integration <branch>
                   --ticket <branch> --test '<command>'
                   [--counter <path>]... [--no-ticket-worktree]

Merge the Ticket branch into the Integration branch in its worktree (a merge
commit, --no-ff), then run the test command there through bash -c. Nothing is
merged unless the Ticket branch has new commits, both worktrees are clean and
no shared counter collides (both sides adding the same number of a numbered
directory, or leaving a version file with the same content): that exits 6 and
lists them. A Ticket branch already part of the
Integration branch exits 5 (nothing to merge); a conflict aborts the merge and
leaves the worktree as it was. --no-ticket-worktree lets --ticket be a ref
nobody has checked out (step 9.1: origin/<main branch>) and skips the Ticket
worktree checks; --counter adds a version-like file to the built-ins.
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
EXTRA_COUNTERS=
NO_TICKET_WORKTREE=
NL=$'\n'

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
    --counter)
      [ $# -ge 2 ] || usage_error '--counter requires a path'
      [ -n "$2" ] || usage_error '--counter requires a path'
      # Repeatable: newline-separated, read back one path per line.
      EXTRA_COUNTERS=${EXTRA_COUNTERS:+$EXTRA_COUNTERS$NL}$2
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

# --- shared counters -----------------------------------------------------------
# Helpers of the gate that runs after every other check and before the merge.
# Each one only reads; none touches a worktree or a ref.

# An entry of a numbered directory is named <digits> followed by - or _. The
# awk helpers below all match against this one pattern (their `re` variable).
NUMBERED_RE='^[0-9]+[-_]'

# The base: the first commit on <ticket_ref>'s first-parent chain that the
# Integration branch already has. The last commit of that chain the Integration
# branch lacks is followed by it (ancestors of ancestors, so everything below
# it is on the Integration branch too). Prints nothing when there is none.
first_parent_base() { # ticket_ref integration_ref
  local last
  last=$(git -C "$WORKTREE" rev-list --first-parent "$1" "^$2" 2>/dev/null | tail -n 1)
  [ -n "$last" ] || return 1
  git -C "$WORKTREE" rev-parse --verify --quiet "$last^1" 2>/dev/null
}

# How many entries of <dir> at <tip> are named <digits>-... or <digits>_...
# (a directory needs two to count as numbered). "." is the top level.
numbered_entry_count() { # dir tip
  local list
  if [ "$1" = . ]; then
    list=$(git -C "$WORKTREE" ls-tree --name-only "$2" 2>/dev/null) || return 1
  else
    list=$(git -C "$WORKTREE" ls-tree --name-only "$2" -- "$1/" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$list" | awk -v re="$NUMBERED_RE" '{ n = split($0, c, "/"); if (c[n] ~ re) count++ } END { print count + 0 }'
}

# Prints `<side>\t<dir>\t<digits>\t<path>` for every path added from..to that
# is an entry of a numbered directory, or a file under such an entry (one
# directory per number, as migrations do).
numbered_additions() { # side from to
  git -C "$WORKTREE" diff --name-only --diff-filter=A --no-renames "$2" "$3" 2>/dev/null |
    awk -F/ -v side="$1" -v re="$NUMBERED_RE" '
      function digits(s) { match(s, re); return substr(s, 1, RLENGTH - 1) }
      function emit(path, depth, entry, c, d, k) {
        split(path, c, "/")
        d = "."
        if (depth >= 1) { d = c[1]; for (k = 2; k <= depth; k++) d = d "/" c[k] }
        printf "%s\t%s\t%s\t%s\n", side, d, digits(entry), path
      }
      {
        if ($NF ~ re) { emit($0, NF - 1, $NF); next }
        if (NF >= 2 && $(NF - 1) ~ re) emit($0, NF - 2, $(NF - 1))
      }'
}

# Prints one line per directory and number both sides added an entry for:
# `<dir>\t<digits>\t<integration paths>\t<ticket paths>` (paths comma-separated).
numbered_pairs() { # base integration_tip merge_base ticket_tip
  {
    numbered_additions integration "$1" "$2"
    numbered_additions ticket "$3" "$4"
  } | awk -F'\t' '
    function joined(a, b) { return a == "" ? b : a ", " b }
    $1 == "integration" { k = $2 SUBSEP $3; i[k] = 1; ip[k] = joined(ip[k], $4); next }
    $1 == "ticket" { k = $2 SUBSEP $3; t[k] = 1; tp[k] = joined(tp[k], $4) }
    END {
      for (k in i)
        if (k in t) { split(k, d, SUBSEP); printf "%s\t%s\t%s\t%s\n", d[1], d[2], ip[k], tp[k] }
    }' | sort
}

# The newest commit of <side> that touched <path>, `<hash> <subject>`, for the
# lines of a collision: the Integration side from the base to its tip (with
# no `--no-merges`: a conflict-resolving merge can be the commit that touched
# the path; a plain landing merge is TREESAME to its Ticket parent and git
# names the Ticket's own commit instead), the Ticket side from the Integration
# tip to the Ticket tip (its own commits only). A tab in the subject becomes a
# space, so the line keeps its four fields (git already joins a multi-line
# subject with spaces). Prints nothing when no commit of that side did.
side_commit() { # side from to path
  if [ "$1" = ticket ]; then
    git -C "$WORKTREE" log --no-merges -1 --format='%h %s' "$2..$3" -- "$4" 2>/dev/null | tr '\t' ' '
  else
    git -C "$WORKTREE" log -1 --format='%h %s' "$2..$3" -- "$4" 2>/dev/null | tr '\t' ' '
  fi
}

# The lines of a collision in numbered directories: every pair whose directory
# is numbered at the Integration tip, each side with the newest commit that
# touched one of its entries.
numbered_hits() { # base integration_tip merge_base ticket_tip
  numbered_pairs "$@" | while IFS=$'\t' read -r dir digits integration_paths ticket_paths; do
    [ "$(numbered_entry_count "$dir" "$2")" -ge 2 ] 2>/dev/null || continue
    printf 'numbered-dir %s %s\tintegration\t%s\t%s\n' "$dir" "$digits" \
      "$(side_commit integration "$1" "$2" "${integration_paths%%, *}")" "$integration_paths"
    printf 'numbered-dir %s %s\tticket\t%s\t%s\n' "$dir" "$digits" \
      "$(side_commit ticket "$2" "$4" "${ticket_paths%%, *}")" "$ticket_paths"
  done
}

# Is <path> a version counter both sides moved to the same content? The three
# conditions of the header, cheapest and most often false first.
version_hit() { # path base integration_tip ticket_tip
  local n integration_side integration_blob ticket_blob
  n=$(git -C "$WORKTREE" rev-list --no-merges --count "$3..$4" -- "$1" 2>/dev/null)
  case $n in '' | *[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  integration_side=$(git -C "$WORKTREE" diff --name-only --no-renames "$2" "$3" -- "$1" 2>/dev/null)
  [ -n "$integration_side" ] || return 1
  integration_blob=$(git -C "$WORKTREE" rev-parse --verify --quiet "$3:$1" 2>/dev/null) || return 1
  ticket_blob=$(git -C "$WORKTREE" rev-parse --verify --quiet "$4:$1" 2>/dev/null) || return 1
  [ "$integration_blob" = "$ticket_blob" ]
}

# The lines of a collision in version files, one path per line of <version_files>.
version_hits() { # base integration_tip ticket_tip version_files
  printf '%s\n' "$4" | while IFS= read -r path; do
    version_hit "$path" "$1" "$2" "$3" || continue
    printf 'version %s\tintegration\t%s\t\n' "$path" "$(side_commit integration "$1" "$2" "$path")"
    printf 'version %s\tticket\t%s\t\n' "$path" "$(side_commit ticket "$2" "$3" "$path")"
  done
}

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

# --- gate: shared counters ------------------------------------------------------

INTEGRATION_TIP=$(git -C "$WORKTREE" rev-parse --verify --quiet "refs/heads/$INTEGRATION") ||
  gate_fail "could not read the tip of $INTEGRATION"
TICKET_TIP=$(git -C "$WORKTREE" rev-parse --verify --quiet "$TICKET_REF") ||
  gate_fail "could not read the tip of $TICKET"
counter_base=$(first_parent_base "$TICKET_REF" "refs/heads/$INTEGRATION") || counter_base=
# Computed once: the merge-base is the Ticket side's own base below, and the
# fallback for the Integration side's when there is no first-parent base.
counter_merge_base=$(git -C "$WORKTREE" merge-base "$INTEGRATION_TIP" "$TICKET_TIP" 2>/dev/null) || counter_merge_base=
if [ -z "$counter_base" ]; then
  # No commit of the Ticket's first-parent chain is on the Integration branch
  # (rebased onto something else, or unrelated histories): the merge-base is
  # the best remaining guess at the fork point.
  counter_base=$counter_merge_base
fi
if [ -n "$counter_base" ]; then
  if [ -n "$counter_merge_base" ]; then
    version_files=$(printf '%s\n' VERSION version.py version.go _version.py ${EXTRA_COUNTERS:+"$EXTRA_COUNTERS"} |
      awk 'NF && !seen[$0]++')
    counter_hits=$(numbered_hits "$counter_base" "$INTEGRATION_TIP" "$counter_merge_base" "$TICKET_TIP"
      version_hits "$counter_base" "$INTEGRATION_TIP" "$TICKET_TIP" "$version_files")
    if [ -n "$counter_hits" ]; then
      if [ -n "$NO_TICKET_WORKTREE" ]; then
        # Step 9.1: --ticket names main, which is read only, so the re-bump
        # goes on the integration branch. The lines below keep their side
        # labels: they are the machine format the header gives.
        warn "shared counters collide: re-bump them on the integration branch ($INTEGRATION; the ref $TICKET is read only), then run again; nothing merged, tests not run"
      else
        warn "shared counters collide: re-bump them on the ticket side ($TICKET), then run again; nothing merged, tests not run"
      fi
      printf '%s\n' "$counter_hits" >&2
      exit 6
    fi
  fi
fi

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
