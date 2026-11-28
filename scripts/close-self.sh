#!/usr/bin/env bash
# Close the Orca terminal (and optionally the worktree) of the unattended Spec
# session that runs this script. A Spec session calls it as its last step, so
# that it does not leave an idle tab behind.
#
# Progress tabs are not this script's business: progress-tab.sh is retired by
# 规格 #26 and is neither run nor closed here.
#
# Before its own terminal it releases the Ticket worktrees of this Spec that
# are left (规格 #26, US20: Tickets first, then the Spec), through
# scripts/stage-dispatch.sh release, which refuses anything but a worker whose
# worker_done is recorded, whose report is on disk and that Orca reports
# settled; this script adds that the Ticket branch must be merged into the
# Integration branch and the worktree clean, so nothing unlanded is removed.
# The sidecars are read from the Spec's run directory (--run-dir), outside
# every worktree, so removing the Spec worktree loses none of them. A Ticket
# worktree that stays (its worker is not done, or it holds unmerged work)
# keeps the Spec worktree it hangs under: removing a parent orphans its
# children in Orca (docs/orca-smoke-2026-11-27.md, C2).
#
# Safety: this script only ever closes the one terminal it runs in, and the
# terminals of the Ticket workers it releases. It never closes another
# terminal, never passes --all to orca, and never removes the main worktree.
#
# Usage:
#   close-self.sh [--run-dir <dir>] [--remove-worktree <path>] [--dry-run]
#
# --run-dir <dir> is the Spec's run directory, the one stage-dispatch.sh wrote
# its sidecars to; without it no Ticket worktree is released, and the Spec
# worktree is still removed only when no Ticket worktree of the Spec is left
# (git worktree list decides that).
#
# It finds its own terminal in one of two forms, and needs Orca, the program
# ISS_ORCA names (default `orca` on PATH; see lib-orca.sh):
#   - the tab form: ORCA_TAB_ID and ORCA_AGENT_PANE (<tabId>:<leafId>) name the
#     pane, and `orca terminal list` resolves it to a handle;
#   - the adopted form (规格 #26, US24: a session Orca dispatched or adopted
#     may carry neither variable): ORCA_TERMINAL_HANDLE, the handle every
#     terminal Orca opens inherits, is asked of Orca with `terminal show
#     --terminal`. The pane is tried first; a pane Orca no longer lists falls
#     through to the handle.
# Outside Orca (Orca missing, or neither form available) it prints "skip: not
# in Orca" and exits 0 without doing anything. A session that names a terminal
# (either form) which Orca does not have exits 1.
#
# Closing its own terminal: when that terminal is the agent terminal of an
# Orca dispatch -- worker-list names a worker whose terminal is this handle --
# the session is a worker, and `worker-release --dispatch` is how it ends: once
# the dispatch is settled (worker-show), Orca closes the terminal and archives
# the transcript. A dispatch not settled (no worker_done yet), a release Orca
# refuses, and a terminal Orca retains (one the caller opened itself) are
# closed with `terminal close --tab` instead, as is every terminal Orca does
# not list as a worker. This is the last thing the script does.
#
# --remove-worktree <path> also removes a worktree:
#   - when <path> is this terminal's own worktree, it must be clean, its
#     branch must be merged into origin/<default branch>, and no Ticket
#     worktree of the Spec may be left; then
#     `orca worktree rm --worktree "path:<path>" --force --delete-branch` runs
#     (this also ends the session);
#   - when <path> is another worktree of the same repository (for example the
#     session runs in a tab of the main worktree), only this terminal is closed
#     and `git worktree remove <path>` plus `git branch -d <branch>` are run
#     without --force; a failure only warns;
#   - otherwise the worktree is kept and only this terminal is closed.
#   Removing the worktree also ends the session; should the terminal survive
#   it, only this session's own close follows. A dispatch in a worktree that is
#   removed is not released by this script (the removal ends the session
#   first); Orca releases it once it sees the terminal gone.
#
# --dry-run prints every orca/git write command instead of running it. Read-only
# checks (orca terminal list / terminal show / worker-list / worker-show, git
# status, git merge-base) still run, and stage-dispatch.sh release is printed
# in its stead.
#
# Test hooks: CLOSE_SELF_STAGE_DISPATCH swaps the release script;
# CLOSE_SELF_WORKER_PAGES bounds the pages of worker-list walked while looking
# for this session's dispatch (default 10).
#
# Exit codes:
#   0  closed (or skipped because this is not an Orca session)
#   1  the terminal was not found or a command failed
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=lib-orca.sh
source "$SCRIPT_DIR/lib-orca.sh"

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--run-dir <dir>] [--remove-worktree <path>] [--dry-run]

Close the Orca terminal this script runs in (ORCA_TAB_ID + ORCA_AGENT_PANE, or
ORCA_TERMINAL_HANDLE), first releasing the Ticket worktrees of the Spec whose
sidecars are in --run-dir (merged, clean, worker done: Tickets before the Spec,
so no child is orphaned). --remove-worktree also removes a worktree when it is
clean and merged and no Ticket worktree is left; a path that is not this
terminal's worktree is removed with plain git (never --force) and only this
terminal is closed. --dry-run prints the commands instead. Outside Orca this
prints "skip: not in Orca" and exits 0.
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

RUN_DIR=
REMOVE=
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)
      [ $# -ge 2 ] || usage_error '--run-dir requires a directory'
      [ -z "$RUN_DIR" ] || usage_error '--run-dir may only be given once'
      RUN_DIR=$2
      shift 2
      ;;
    --remove-worktree)
      [ $# -ge 2 ] || usage_error '--remove-worktree requires a path'
      [ -z "$REMOVE" ] || usage_error '--remove-worktree may only be given once'
      REMOVE=$2
      shift 2
      ;;
    --dry-run)
      DRY=1
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

if ! command -v "$(orca_exe)" >/dev/null 2>&1; then
  printf 'skip: not in Orca\n'
  exit 0
fi

norm_path() {
  if [ -d "$1" ]; then
    (cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  else
    printf '%s\n' "$1"
  fi
}

main_worktree_path() {
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n 1
}

worktree_clean() {
  local out
  out=$(git -C "$1" status --porcelain 2>/dev/null) || return 1
  [ -z "$out" ]
}

worktree_merged() {
  local ref
  if git -C "$1" rev-parse --verify --quiet origin/HEAD >/dev/null 2>&1; then
    ref=origin/HEAD
  else
    ref=origin/main
  fi
  git -C "$1" merge-base --is-ancestor HEAD "$ref" >/dev/null 2>&1
}

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/close-self.XXXXXX") || exit 1
trap 'rm -f -- "$ERR_FILE" 2>/dev/null' EXIT

# --- this session's terminal ---------------------------------------------------
# HANDLE and WT_PATH come from Orca here, on every run, and are used at once;
# they are never kept. NAMED says the session claims a terminal (either form):
# one that claims one and resolves to none is an error, one that claims none
# is simply not in Orca. The pane is tried first; a pane Orca no longer lists
# falls through to the inherited handle.

FOUND=
LOOKUP=
NAMED=0

if [ -n "${ORCA_TAB_ID:-}" ] || [ -n "${ORCA_AGENT_PANE:-}" ]; then
  NAMED=1
  case "${ORCA_AGENT_PANE:-}" in
    *:*)
      TAB_ID=${ORCA_AGENT_PANE%%:*}
      LEAF_ID=${ORCA_AGENT_PANE#*:}
      ;;
    *)
      TAB_ID=
      LEAF_ID=
      ;;
  esac
  if [ -n "${ORCA_TAB_ID:-}" ] && [ -n "$TAB_ID" ] && [ -n "$LEAF_ID" ]; then
    if FOUND=$(orca_terminal_by_pane "$TAB_ID" "$LEAF_ID" 2>"$ERR_FILE"); then
      LOOKUP='orca terminal list --json'
    else
      case $? in
        3) warn "orca terminal list failed: $(head -n 1 "$ERR_FILE" 2>/dev/null)" ;;
        2) warn "could not parse orca terminal list --json output" ;;
        *) warn "no Orca terminal matches tab $TAB_ID leaf $LEAF_ID" ;;
      esac
    fi
  else
    warn "ORCA_TAB_ID and ORCA_AGENT_PANE do not name a pane, got tab '${ORCA_TAB_ID:-}' pane '${ORCA_AGENT_PANE:-}'"
  fi
fi

if [ -z "$FOUND" ] && [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
  NAMED=1
  if FOUND=$(orca_terminal_by_handle "$ORCA_TERMINAL_HANDLE" 2>"$ERR_FILE"); then
    LOOKUP="orca terminal show --terminal $ORCA_TERMINAL_HANDLE --json"
  else
    warn "orca terminal show found no terminal for the inherited handle $ORCA_TERMINAL_HANDLE: $(head -n 1 "$ERR_FILE" 2>/dev/null)"
  fi
fi

if [ -z "$FOUND" ]; then
  [ "$NAMED" -eq 1 ] && exit 1
  printf 'skip: not in Orca\n'
  exit 0
fi

IFS=$'\t' read -r HANDLE WT_PATH <<< "$FOUND"

if [ "$DRY" -eq 1 ]; then
  printf 'dry-run: %s\n' "$LOOKUP"
fi

REMOVE_NORM=
if [ -n "$REMOVE" ]; then
  REMOVE_NORM=$(norm_path "$REMOVE") || {
    warn "could not resolve the worktree path: $REMOVE"
    exit 1
  }
fi

# --- the Ticket worktrees of this Spec first -----------------------------------
# (规格 #26, US20) The sidecars stage-dispatch.sh left in the run directory
# name the Ticket worktrees that are still there. Each one goes through
# stage-dispatch.sh release, which refuses anything but a worker whose
# worker_done is recorded, whose report is on disk and that Orca reports
# settled, and then releases it, closes its terminal and removes the worktree
# with its branch; on top of that a Ticket branch must be merged into the
# Integration branch and the worktree clean, or it is kept: nothing unlanded
# is ever removed. A Ticket worktree that stays keeps the Spec worktree it
# hangs under, since removing a parent orphans its children in Orca
# (docs/orca-smoke-2026-11-27.md, C2).

STAGE_DISPATCH=${CLOSE_SELF_STAGE_DISPATCH:-$SCRIPT_DIR/stage-dispatch.sh}
SEEN=' '
WOULD_RELEASE=' '

spec_number() { # worktree -> n when its branch is spec-<n>, else nothing
  local branch
  branch=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  printf '%s\n' "$branch" | sed -n 's/^spec-\([1-9][0-9]*\)$/\1/p'
}

# The Ticket worktrees git still registers under a Spec worktree: the ones on
# a branch spec-<n>-t<m>, one path per line.
ticket_worktrees_of() { # spec worktree
  local n
  n=$(spec_number "$1")
  [ -n "$n" ] || return 0
  git -C "$1" worktree list --porcelain 2>/dev/null |
    awk -v pattern="^branch refs/heads/spec-${n}-t[1-9][0-9]*\$" '
      /^worktree / { path = substr($0, 10); next }
      $0 ~ pattern { print path }
    '
}

# The Ticket dispatches left in the run directory: for every interactive
# sidecar whose worktree the dispatch made and that was not released,
# sidecar<US>worktree<US>branch<US>base branch (US is the unit separator, \x1f:
# branch and base may be empty, and a tab would let read fold them together
# and hand base's place to branch).
ticket_sidecars() {
  [ -n "$RUN_DIR" ] || return 0
  if [ ! -d "$RUN_DIR" ]; then
    warn "run directory not found: $RUN_DIR; no Ticket worktree is released through it"
    return 0
  fi
  node -e '
    const fs = require("fs"), path = require("path");
    const runDir = process.argv[1];
    let names = [];
    try { names = fs.readdirSync(runDir).sort(); } catch { process.exit(0); }
    for (const name of names) {
      if (!/^dispatch-.*\.json$/.test(name)) continue;
      let value;
      try { value = JSON.parse(fs.readFileSync(path.join(runDir, name), "utf8")); } catch { continue; }
      if (!value || value.form !== "interactive" || value.worktree_created !== true) continue;
      if (typeof value.worktree !== "string" || value.worktree === "" || value.released_at) continue;
      process.stdout.write([path.join(runDir, name), value.worktree,
        String(value.branch || ""), String(value.base_branch || "")].join("\x1f") + "\n");
    }
  ' "$RUN_DIR"
}

release_tickets() {
  local sidecar worktree branch base reason
  while IFS=$'\x1f' read -r sidecar worktree branch base; do
    [ -n "$sidecar" ] || continue
    case "$SEEN" in *" $worktree "*) continue ;; esac
    SEEN="$SEEN$worktree "
    if [ ! -d "$worktree" ]; then
      printf 'close-self: Ticket worktree %s is already gone (%s)\n' "$worktree" "${sidecar##*/}"
      continue
    fi
    [ -n "$base" ] || base=${branch%-t*}
    reason=
    if ! worktree_clean "$worktree"; then
      reason="worktree $worktree has uncommitted or untracked changes"
    elif ! git -C "$worktree" merge-base --is-ancestor "$branch" "$base" >/dev/null 2>&1; then
      reason="branch $branch is not merged into $base"
    fi
    if [ -n "$reason" ]; then
      warn "keeping Ticket worktree $worktree: $reason"
      continue
    fi
    if [ "$DRY" -eq 1 ]; then
      WOULD_RELEASE="$WOULD_RELEASE$worktree "
      printf 'dry-run: stage-dispatch.sh release --sidecar %s (worker-release, terminal close, orca worktree rm --worktree path:%s --force --delete-branch)\n' \
        "$sidecar" "$worktree"
      continue
    fi
    "$STAGE_DISPATCH" release --sidecar "$sidecar" ||
      warn "keeping Ticket worktree $worktree: stage-dispatch.sh release exited $?"
  done < <(ticket_sidecars)
}

release_tickets

# Whether a Spec worktree may go: no Ticket worktree of that Spec may be
# registered any more (one --dry-run would have released does not count).
keep_for_tickets() { # spec worktree -> 0 when it must be kept, and says why
  local path left=
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$WOULD_RELEASE" in *" $path "*) continue ;; esac
    left="$left $path"
  done < <(ticket_worktrees_of "$1")
  [ -n "$left" ] || return 1
  warn "keeping Spec worktree $1: Ticket worktree(s) left, not merged, or a worker not done (${left# }); removing the parent would orphan them"
  return 0
}

# --- this session's own close ---------------------------------------------------
# A session Orca dispatched or adopted is a worker: its terminal is the agent
# terminal of a dispatch. That dispatch is found in worker-list, by its
# terminal being this session's handle; the list is walked page by page until
# it turns up or the list ends, at most CLOSE_SELF_WORKER_PAGES pages. An Orca
# that cannot answer, or a list cut short, leaves it empty, and the terminal is
# closed as a plain one, which works either way. A worker Orca has already
# released is not this session.

WORKER_PAGES=${CLOSE_SELF_WORKER_PAGES:-10}

self_dispatch() { # prints the dispatch whose agent terminal is this session's
  local cursor= page=0 list rows next line
  while :; do
    page=$((page + 1))
    list=$(orca_orchestration_worker_list ${cursor:+--cursor "$cursor"} 2>"$ERR_FILE") || {
      warn "orca orchestration worker-list failed: $(head -n 1 "$ERR_FILE" 2>/dev/null); closing this terminal as a plain one"
      return 0
    }
    rows=$(printf '%s' "$list" | HANDLE=$HANDLE node -e '
      const fs = require("fs");
      let value;
      try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
      const result = value && value.result;
      if (!result || !Array.isArray(result.workers)) process.exit(2);
      const mine = result.workers.find((worker) =>
        worker && worker.terminal === process.env.HANDLE && worker.terminalState !== "released");
      if (mine && mine.dispatchId) { process.stdout.write("dispatch\t" + mine.dispatchId + "\n"); process.exit(0); }
      process.stdout.write("cursor\t" + (result.nextCursor == null ? "" : String(result.nextCursor)) + "\n");
    ') || {
      warn 'could not parse orca orchestration worker-list --json output; closing this terminal as a plain one'
      return 0
    }
    next=
    while IFS= read -r line; do
      case "$line" in
        dispatch$'\t'*) printf '%s' "${line#dispatch$'\t'}"; return 0 ;;
        cursor$'\t'*) next=${line#cursor$'\t'} ;;
      esac
    done <<< "$rows"
    [ -n "$next" ] || return 0
    [ "$page" -ge "$WORKER_PAGES" ] && return 0
    cursor=$next
  done
}

SELF_DISPATCH=$(self_dispatch)

# The settled test stage-dispatch.sh release makes too: Orca releases a worker
# only once it is settled. Prints 1 when Orca reports it so (stage or state
# settled, succeeded or failed), else 0.
dispatch_settled() { # dispatch -> prints 1 when Orca reports it settled
  orca_orchestration_worker_show "$1" 2>"$ERR_FILE" | node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
    const result = (value && value.result) || {};
    const words = String(result.stage || "") + " " + String(result.state || "") + " " + String(result.liveness || "");
    process.stdout.write(/settled|succeeded|failed/.test(words) ? "1" : "0");
  ' || printf 0
}

# The last thing this script does. A dispatch's agent terminal is released:
# with the dispatch settled, worker-release makes Orca close the terminal and
# archive the transcript. A dispatch not settled, a release Orca refuses, and
# a terminal Orca retains are closed with terminal close --tab instead, as is
# every terminal Orca does not list as a worker.
close_self() {
  local settled=1 receipt state
  if [ -n "$SELF_DISPATCH" ]; then
    settled=$(dispatch_settled "$SELF_DISPATCH")
    if [ "$settled" = 1 ]; then
      if [ "$DRY" -eq 1 ]; then
        printf 'dry-run: orca orchestration worker-release --dispatch %s --json\n' "$SELF_DISPATCH"
        return 0
      fi
      receipt=$(orca_orchestration_worker_release "$SELF_DISPATCH" 2>"$ERR_FILE") &&
        state=$(printf '%s' "$receipt" | node -e '
          const fs = require("fs");
          let value;
          try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
          process.stdout.write(String(((value && value.result) || {}).state || ""));
        ') && case "$state" in
          released|already_released) return 0 ;;
        esac
      warn "orca orchestration worker-release did not release $SELF_DISPATCH (state=${state:-none}: $(head -n 1 "$ERR_FILE" 2>/dev/null)); closing the terminal instead"
    else
      warn "dispatch $SELF_DISPATCH is not settled; closing the terminal, and Orca releases the dispatch once its terminal is gone"
    fi
  fi
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca terminal close --terminal %s --tab\n' "$HANDLE"
    return 0
  fi
  orca_terminal_close "$HANDLE"
}

if [ -z "$REMOVE" ]; then
  close_self || { warn "orca terminal close failed"; exit 1; }
  exit 0
fi

WT_NORM=
if [ -n "$WT_PATH" ]; then
  WT_NORM=$(norm_path "$WT_PATH") || WT_NORM=$WT_PATH
fi

if [ -n "$WT_NORM" ] && [ "$REMOVE_NORM" = "$WT_NORM" ]; then
  # The worktree belongs to this terminal.
  MAIN_WT=$(main_worktree_path "$REMOVE_NORM")
  if [ -n "$MAIN_WT" ]; then
    MAIN_NORM=$(norm_path "$MAIN_WT") || MAIN_NORM=$MAIN_WT
    if [ "$REMOVE_NORM" = "$MAIN_NORM" ]; then
      warn "$REMOVE_NORM is the main worktree; keeping it and only closing this terminal"
      close_self || { warn "orca terminal close failed"; exit 1; }
      exit 0
    fi
  fi
  reason=
  if ! worktree_clean "$REMOVE_NORM"; then
    reason="worktree $REMOVE_NORM has uncommitted or untracked changes"
  elif ! worktree_merged "$REMOVE_NORM"; then
    reason="branch of $REMOVE_NORM is not merged into origin's default branch"
  fi
  if [ -n "$reason" ]; then
    warn "$reason; keeping the worktree and only closing this terminal"
    close_self || { warn "orca terminal close failed"; exit 1; }
    exit 0
  fi
  if keep_for_tickets "$REMOVE_NORM"; then
    close_self || { warn "orca terminal close failed"; exit 1; }
    exit 0
  fi
  printf 'close-self: removing worktree %s (clean and merged)\n' "$REMOVE_NORM"
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca worktree rm --worktree path:%s --force --delete-branch\n' "$REMOVE_NORM"
    exit 0
  fi
  # This ends the session; should the terminal survive it, only this
  # session's own close follows.
  orca_worktree_rm "$REMOVE_NORM"
  status=$?
  close_self
  exit "$status"
fi

# The path is not this terminal's worktree: never remove the main worktree and
# never close a whole workspace. Remove just that worktree with plain git, then
# close this terminal.
if [ -n "$REMOVE_NORM" ] && [ -n "$WT_NORM" ] && [ "$REMOVE_NORM" != "$WT_NORM" ]; then
  MAIN_WT=$(main_worktree_path "$REMOVE_NORM")
  if [ -n "$MAIN_WT" ]; then
    MAIN_NORM=$(norm_path "$MAIN_WT") || MAIN_NORM=$MAIN_WT
    if [ "$REMOVE_NORM" = "$MAIN_NORM" ]; then
      warn "$REMOVE_NORM is the main worktree; keeping it and only closing this terminal"
      close_self || { warn "orca terminal close failed"; exit 1; }
      exit 0
    fi
  fi
  BRANCH=$(git -C "$REMOVE_NORM" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if keep_for_tickets "$REMOVE_NORM"; then
    close_self || { warn "orca terminal close failed"; exit 1; }
    exit 0
  fi
  printf 'close-self: removing worktree %s with git and closing this terminal\n' "$REMOVE_NORM"
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: git -C %s worktree remove %s\n' "$REMOVE_NORM" "$REMOVE_NORM"
    if [ -n "$BRANCH" ]; then
      printf 'dry-run: git -C %s branch -d %s\n' "${MAIN_WT:-$REMOVE_NORM}" "$BRANCH"
    fi
    close_self
    exit 0
  fi
  git -C "$REMOVE_NORM" worktree remove "$REMOVE_NORM" ||
    warn "git worktree remove $REMOVE_NORM failed; it may still exist"
  if [ -n "$BRANCH" ]; then
    git -C "${MAIN_WT:-$REMOVE_NORM}" branch -d "$BRANCH" ||
      warn "git branch -d $BRANCH failed; the branch is kept"
  fi
  close_self || { warn "orca terminal close failed"; exit 1; }
  exit 0
fi

warn "could not compare $REMOVE_NORM with this terminal's worktree ($WT_NORM); only closing this terminal"
close_self || { warn "orca terminal close failed"; exit 1; }
exit 0
