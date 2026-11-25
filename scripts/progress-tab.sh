#!/usr/bin/env bash
# Open and close the read-only Orca progress tabs of a Spec Run.
#
# The Orchestrator calls one command per dispatch and one per role end; this
# script runs orca, parses its JSON and keeps the record file
# (<Spec Run root>/orca-tabs.txt) in sync. It is display only: except for usage
# errors it always exits 0, and anything that goes wrong is a warning on stderr.
#
# Usage:
#   progress-tab.sh open --record <file> --title <title> [--dry-run] -- <ticket-watch.sh args...>
#   progress-tab.sh close --record <file> --title <title> [--title <title>...] [--dry-run]
#   progress-tab.sh close-all [--record <file>] [--spec <n>] [--dry-run]
#
# open: without ORCA_WORKTREE_ID or orca on PATH it does nothing; a title that
#   is already in the record opens nothing; otherwise it runs
#   `orca terminal create --json`, requires result.terminal.handle to start
#   with term_, and appends <title><TAB><handle> to the record.
# close: closes the recorded handles of the given titles (failures are ignored)
#   and removes their lines from the record.
# close-all: closes every recorded handle (a record written with a literal
#   <TAB> separator still works; a handle that does not start with term_ is
#   skipped), then scans `orca terminal list --json` for terminals of this
#   worktree whose title matches ^spec-<n> (t[0-9]+|merge t[0-9]+|merge main|fix)$
#   (any <n> without --spec), never closing the tab in ORCA_TAB_ID, and finally
#   empties the record.
#
# --dry-run prints every orca write command instead of running it. Read-only
# `orca terminal list` still runs, and the record file is left untouched.
#
# Exit codes:
#   0  done (or nothing to do)
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

DRY=0
RECORD=
SPEC=
SPEC_RE=

usage() {
  cat <<EOF
usage: $SCRIPT_NAME open --record <file> --title <title> [--dry-run] -- <ticket-watch.sh args...>
       $SCRIPT_NAME close --record <file> --title <title> [--title <title>...] [--dry-run]
       $SCRIPT_NAME close-all [--record <file>] [--spec <n>] [--dry-run]

open creates one read-only progress tab and records <title><TAB><handle>.
close closes the recorded tabs of the given titles and drops their lines.
close-all closes every recorded tab, then scans this worktree's terminals for
spec-<n> progress tabs and closes them too. --dry-run prints the orca write
commands instead of running them.
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

# A record line is <title><TAB><handle>. Records written before 2026-11-25 may
# contain a literal "<TAB>" instead of the tab character.
record_title() {
  case "$1" in
    *'<TAB>'*) printf '%s' "${1%%<TAB>*}" ;;
    *) printf '%s' "${1%%$'\t'*}" ;;
  esac
}

record_handle() {
  case "$1" in
    *'<TAB>'*) printf '%s' "${1#*<TAB>}" ;;
    *) printf '%s' "${1#*$'\t'}" ;;
  esac
}

record_find_handle() { # file title
  local file=$1 title=$2 line=
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "$(record_title "$line")" = "$title" ]; then
      printf '%s\n' "$(record_handle "$line")"
      return 0
    fi
  done < "$file"
  return 1
}

close_handle() { # handle [warn-on-failure]
  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca terminal close --terminal %s --tab\n' "$1"
    return 0
  fi
  if ! orca terminal close --terminal "$1" --tab >/dev/null 2>&1 </dev/null; then
    if [ "${2:-0}" -eq 1 ]; then
      warn "orca terminal close failed for $1"
    fi
  fi
  return 0
}

remove_titles() { # file title...
  local file=$1
  shift
  [ -f "$file" ] || return 0
  local tmp line title keep t
  tmp=$(mktemp "$file.XXXXXX") || {
    warn "could not create a temporary file next to $file"
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    title=$(record_title "$line")
    keep=1
    for t in "$@"; do
      if [ "$title" = "$t" ]; then
        keep=0
        break
      fi
    done
    if [ "$keep" -eq 1 ]; then
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp"
  if ! mv -f "$tmp" "$file"; then
    warn "could not update $file"
    rm -f -- "$tmp"
  fi
  return 0
}

cmd_open() {
  RECORD=
  TITLE=
  DRY=0
  local saw_dash_dash=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        saw_dash_dash=1
        break
        ;;
      --record)
        [ $# -ge 2 ] || usage_error '--record requires a path'
        [ -z "$RECORD" ] || usage_error '--record may only be given once'
        RECORD=$2
        shift 2
        ;;
      --title)
        [ $# -ge 2 ] || usage_error '--title requires a title'
        [ -z "$TITLE" ] || usage_error '--title may only be given once'
        TITLE=$2
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
  [ "$saw_dash_dash" -eq 1 ] ||
    usage_error 'open needs -- followed by the ticket-watch.sh arguments'
  [ "$#" -gt 0 ] ||
    usage_error 'open needs at least one ticket-watch.sh argument after --'
  [ -n "$RECORD" ] || usage_error '--record is required'
  [ -n "$TITLE" ] || usage_error '--title is required'

  if [ -z "${ORCA_WORKTREE_ID:-}" ]; then
    warn 'ORCA_WORKTREE_ID is not set; not opening a progress tab'
    return 0
  fi
  if ! command -v orca >/dev/null 2>&1; then
    warn 'orca is not on PATH; not opening a progress tab'
    return 0
  fi

  # One tab per title: a later dispatch of the same role reuses the tab.
  if record_find_handle "$RECORD" "$TITLE" >/dev/null; then
    return 0
  fi

  local watch=$SCRIPT_DIR/ticket-watch.sh arg command=
  command=$(printf '%q' "$watch")
  for arg in "$@"; do
    command="$command $(printf '%q' "$arg")"
  done

  if [ "$DRY" -eq 1 ]; then
    printf 'dry-run: orca terminal create --worktree current --title %s --command %s --json\n' \
      "$TITLE" "$command"
    return 0
  fi

  local err out handle=
  err=$(mktemp "${TMPDIR:-/tmp}/progress-tab.XXXXXX") || {
    warn 'could not create a temporary file'
    return 0
  }
  if ! out=$(orca terminal create --worktree current --title "$TITLE" \
      --command "$command" --json 2>"$err" </dev/null); then
    warn "orca terminal create failed: $(head -n 1 "$err" 2>/dev/null)"
    rm -f -- "$err"
    return 0
  fi
  rm -f -- "$err"

  handle=$(printf '%s' "$out" | node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const terminal = value && value.result && value.result.terminal;
    if (!terminal || !terminal.handle) process.exit(1);
    process.stdout.write(String(terminal.handle));
  ') || {
    warn 'could not read result.terminal.handle from the orca terminal create output'
    return 0
  }
  case "$handle" in
    term_?*) ;;
    *)
      warn "orca returned terminal handle '$handle', which does not start with term_; not recording it"
      return 0
      ;;
  esac
  printf '%s\t%s\n' "$TITLE" "$handle" >> "$RECORD" || {
    warn "could not append to $RECORD"
    return 0
  }
  return 0
}

cmd_close() {
  RECORD=
  TITLES=()
  DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --record)
        [ $# -ge 2 ] || usage_error '--record requires a path'
        [ -z "$RECORD" ] || usage_error '--record may only be given once'
        RECORD=$2
        shift 2
        ;;
      --title)
        [ $# -ge 2 ] || usage_error '--title requires a title'
        TITLES+=("$2")
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
  [ -n "$RECORD" ] || usage_error '--record is required'
  [ "${#TITLES[@]}" -gt 0 ] || usage_error '--title is required'
  [ -f "$RECORD" ] || return 0

  local title line handle found
  for title in "${TITLES[@]}"; do
    found=0
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      [ "$(record_title "$line")" = "$title" ] || continue
      found=1
      handle=$(record_handle "$line")
      close_handle "$handle" 1
    done < "$RECORD"
    if [ "$found" -eq 0 ]; then
      warn "no recorded progress tab for '$title'"
    fi
  done
  if [ "$DRY" -eq 0 ]; then
    remove_titles "$RECORD" "${TITLES[@]}"
  fi
  return 0
}

scan_and_close() {
  [ -n "${ORCA_WORKTREE_ID:-}" ] || return 0
  if ! command -v orca >/dev/null 2>&1; then
    warn 'orca is not on PATH; skipping the progress-tab scan'
    return 0
  fi

  local err list handles handle
  err=$(mktemp "${TMPDIR:-/tmp}/progress-tab.XXXXXX") || {
    warn 'could not create a temporary file'
    return 0
  }
  if ! list=$(orca terminal list --json 2>"$err" </dev/null); then
    warn "orca terminal list failed: $(head -n 1 "$err" 2>/dev/null)"
    rm -f -- "$err"
    return 0
  fi
  rm -f -- "$err"

  handles=$(printf '%s' "$list" | WT_ID="$ORCA_WORKTREE_ID" \
    SELF_TAB_ID="${ORCA_TAB_ID:-}" SPEC_RE="$SPEC_RE" node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const terminals = value && value.result && Array.isArray(value.result.terminals)
      ? value.result.terminals
      : (value && Array.isArray(value.terminals) ? value.terminals : null);
    if (!terminals) process.exit(2);
    const worktree = process.env.WT_ID;
    const self = process.env.SELF_TAB_ID || "";
    const re = new RegExp(process.env.SPEC_RE);
    for (const item of terminals) {
      if (!item || !item.handle) continue;
      if (String(item.worktreeId || "") !== worktree) continue;
      if (!re.test(String(item.title || ""))) continue;
      if (self && String(item.tabId || "") === self) continue;
      process.stdout.write(String(item.handle) + "\n");
    }
  ') || {
    warn 'could not parse the orca terminal list --json output'
    return 0
  }
  [ -n "$handles" ] || return 0

  while IFS= read -r handle; do
    [ -n "$handle" ] || continue
    close_handle "$handle" 0
  done <<< "$handles"
  return 0
}

cmd_close_all() {
  RECORD=
  SPEC=
  DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --record)
        [ $# -ge 2 ] || usage_error '--record requires a path'
        [ -z "$RECORD" ] || usage_error '--record may only be given once'
        RECORD=$2
        shift 2
        ;;
      --spec)
        [ $# -ge 2 ] || usage_error '--spec requires a number'
        [ -z "$SPEC" ] || usage_error '--spec may only be given once'
        SPEC=$2
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
  if [ -n "$SPEC" ]; then
    case "$SPEC" in
      ''|*[!0-9]*) usage_error '--spec must be a number' ;;
    esac
    SPEC_RE="^spec-$SPEC (t[0-9]+|merge t[0-9]+|merge main|fix)\$"
  else
    SPEC_RE='^spec-[0-9]+ (t[0-9]+|merge t[0-9]+|merge main|fix)$'
  fi

  local line handle
  if [ -n "$RECORD" ] && [ -f "$RECORD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      handle=$(record_handle "$line")
      case "$handle" in
        term_?*) close_handle "$handle" 0 ;;
        *)
          if [ "$DRY" -eq 0 ]; then
            warn "skipping '$RECORD' line with handle '$handle'; it does not start with term_"
          fi
          ;;
      esac
    done < "$RECORD"
  fi

  scan_and_close

  if [ -n "$RECORD" ] && [ -f "$RECORD" ] && [ "$DRY" -eq 0 ]; then
    : > "$RECORD" || warn "could not clear $RECORD"
  fi
  return 0
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || usage_error 'missing command'
shift
case "$COMMAND" in
  open) cmd_open "$@" ;;
  close) cmd_close "$@" ;;
  close-all) cmd_close_all "$@" ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) usage_error "unknown command: $COMMAND" ;;
esac
