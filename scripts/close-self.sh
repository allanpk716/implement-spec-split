#!/usr/bin/env bash
# Close the Orca terminal (and optionally the worktree) of the unattended Spec
# session that runs this script. A Spec session calls it as its last step, so
# that it does not leave an idle tab behind.
#
# Before its own terminal it closes this Run's read-only progress tabs through
# progress-tab.sh close-all (no record: the title scan is the safety net).
#
# Safety: apart from those progress tabs, this script only ever closes the one
# terminal named by ORCA_TAB_ID/ORCA_AGENT_PANE. It never closes another
# terminal, never passes --all to orca, and never removes the main worktree.
#
# Usage:
#   close-self.sh [--remove-worktree <path>] [--dry-run]
#
# It needs ORCA_TAB_ID, ORCA_AGENT_PANE (<tabId>:<leafId>) and orca on PATH.
# Outside Orca (any of them missing) it prints "skip: not in Orca" and exits 0
# without doing anything.
#
# --remove-worktree <path> also removes a worktree:
#   - when <path> is this terminal's own worktree, it must be clean and its
#     branch must be merged into origin/<default branch>; then
#     `orca worktree rm --worktree "path:<path>" --force --delete-branch` runs
#     (this also ends the session, so it is the last command);
#   - when <path> is another worktree of the same repository (for example the
#     session runs in a tab of the main worktree), only this terminal is closed
#     and `git worktree remove <path>` plus `git branch -d <branch>` are run
#     without --force; a failure only warns;
#   - otherwise the worktree is kept and only this terminal is closed.
#
# --dry-run prints every orca/git write command instead of running it. Read-only
# checks (orca terminal list, git status, git merge-base) still run.
#
# Exit codes:
#   0  closed (or skipped because this is not an Orca session)
#   1  the terminal was not found or a command failed
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--remove-worktree <path>] [--dry-run]

Close the Orca terminal this script runs in (ORCA_TAB_ID + ORCA_AGENT_PANE).
--remove-worktree also removes a worktree when it is clean and merged; a path
that is not this terminal's worktree is removed with plain git (never --force)
and only this terminal is closed. --dry-run prints the commands instead.
Outside Orca this prints "skip: not in Orca" and exits 0.
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

REMOVE=
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
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

if [ -z "${ORCA_TAB_ID:-}" ] || [ -z "${ORCA_AGENT_PANE:-}" ] ||
   ! command -v orca >/dev/null 2>&1; then
  printf 'skip: not in Orca\n'
  exit 0
fi

# Close the progress tabs of this Run before this session's own tab. A failure
# here is a warning only and never changes this script's exit code.
if [ "$DRY" -eq 1 ]; then
  "$SCRIPT_DIR/progress-tab.sh" close-all --dry-run ||
    warn "progress-tab.sh close-all failed"
else
  "$SCRIPT_DIR/progress-tab.sh" close-all ||
    warn "progress-tab.sh close-all failed"
fi

case "$ORCA_AGENT_PANE" in
  *:*)
    TAB_ID=${ORCA_AGENT_PANE%%:*}
    LEAF_ID=${ORCA_AGENT_PANE#*:}
    ;;
  *)
    warn "ORCA_AGENT_PANE must be <tabId>:<leafId>, got '$ORCA_AGENT_PANE'"
    exit 1
    ;;
esac
[ -n "$TAB_ID" ] && [ -n "$LEAF_ID" ] || {
  warn "ORCA_AGENT_PANE must be <tabId>:<leafId>, got '$ORCA_AGENT_PANE'"
  exit 1
}

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

if ! LIST=$(orca terminal list --json 2>"$ERR_FILE"); then
  warn "orca terminal list failed: $(head -n 1 "$ERR_FILE" 2>/dev/null)"
  exit 1
fi

FOUND=$(printf '%s' "$LIST" | TAB_ID="$TAB_ID" LEAF_ID="$LEAF_ID" node -e '
  const fs = require("fs");
  let value;
  try { value = JSON.parse(fs.readFileSync(0, "utf8")); }
  catch { process.exit(2); }
  const terminals = value && value.result && Array.isArray(value.result.terminals)
    ? value.result.terminals
    : (value && Array.isArray(value.terminals) ? value.terminals : null);
  if (!terminals) process.exit(2);
  const terminal = terminals.find((item) =>
    String(item.tabId || "") === process.env.TAB_ID &&
    String(item.leafId || "") === process.env.LEAF_ID);
  if (!terminal || !terminal.handle) process.exit(1);
  process.stdout.write(String(terminal.handle) + "\t" + String(terminal.worktreePath || ""));
') || {
  case $? in
    2) warn "could not parse orca terminal list --json output" ;;
    *) warn "no Orca terminal matches tab $TAB_ID leaf $LEAF_ID" ;;
  esac
  exit 1
}

IFS=$'\t' read -r HANDLE WT_PATH <<< "$FOUND"

if [ "$DRY" -eq 1 ]; then
  printf 'dry-run: orca terminal list --json\n'
fi

REMOVE_NORM=
if [ -n "$REMOVE" ]; then
  REMOVE_NORM=$(norm_path "$REMOVE") || {
    warn "could not resolve the worktree path: $REMOVE"
    exit 1
  }
fi

close_terminal() {
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca terminal close --terminal %s --tab\n' "$HANDLE"
    return 0
  fi
  orca terminal close --terminal "$HANDLE" --tab
}

if [ -z "$REMOVE" ]; then
  close_terminal || { warn "orca terminal close failed"; exit 1; }
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
      close_terminal || { warn "orca terminal close failed"; exit 1; }
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
    close_terminal || { warn "orca terminal close failed"; exit 1; }
    exit 0
  fi
  printf 'close-self: removing worktree %s (clean and merged)\n' "$REMOVE_NORM"
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca worktree rm --worktree path:%s --force --delete-branch\n' "$REMOVE_NORM"
    exit 0
  fi
  # This ends the session, so nothing may follow it.
  orca worktree rm --worktree "path:$REMOVE_NORM" --force --delete-branch
  exit $?
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
      close_terminal || { warn "orca terminal close failed"; exit 1; }
      exit 0
    fi
  fi
  BRANCH=$(git -C "$REMOVE_NORM" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  printf 'close-self: removing worktree %s with git and closing this terminal\n' "$REMOVE_NORM"
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: git -C %s worktree remove %s\n' "$REMOVE_NORM" "$REMOVE_NORM"
    if [ -n "$BRANCH" ]; then
      printf 'dry-run: git -C %s branch -d %s\n' "${MAIN_WT:-$REMOVE_NORM}" "$BRANCH"
    fi
    close_terminal
    exit 0
  fi
  git -C "$REMOVE_NORM" worktree remove "$REMOVE_NORM" ||
    warn "git worktree remove $REMOVE_NORM failed; it may still exist"
  if [ -n "$BRANCH" ]; then
    git -C "${MAIN_WT:-$REMOVE_NORM}" branch -d "$BRANCH" ||
      warn "git branch -d $BRANCH failed; the branch is kept"
  fi
  close_terminal || { warn "orca terminal close failed"; exit 1; }
  exit 0
fi

warn "could not compare $REMOVE_NORM with this terminal's worktree ($WT_NORM); only closing this terminal"
close_terminal || { warn "orca terminal close failed"; exit 1; }
exit 0
