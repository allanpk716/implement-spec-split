#!/usr/bin/env bash
# Isolated tests for scripts/progress-tab.sh. A fake orca is put first on PATH;
# it records every call and answers create/list with preset JSON. The scratch
# tree is retained, so this test never recursively deletes a temporary
# directory.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/progress-tab.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/progress-tab-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
ORCA_LOG=$WORK/orca.log
RECORD=$WORK/orca-tabs.txt
PASSED=0
FAILED=0
RUN_EXIT=
RUN_OUT=
RUN_ERR=
ORCA_WORKTREE_ID=
ORCA_TAB_ID=
ORCA_CREATE_JSON=
ORCA_LIST_JSON=
ORCA_CLOSE_FAIL=0

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

run_tab() {
  RUN_OUT=$(env PATH="$BIN:$PATH" ORCA_LOG="$ORCA_LOG" \
    ORCA_WORKTREE_ID="$ORCA_WORKTREE_ID" ORCA_TAB_ID="$ORCA_TAB_ID" \
    ORCA_CREATE_JSON="$ORCA_CREATE_JSON" ORCA_LIST_JSON="$ORCA_LIST_JSON" \
    ORCA_CLOSE_FAIL="$ORCA_CLOSE_FAIL" \
    bash "$SCRIPT" "$@" 2>"$WORK/stderr.txt")
  RUN_EXIT=$?
  RUN_ERR=$(cat "$WORK/stderr.txt")
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

expect_out() {
  if printf '%s\n' "$RUN_OUT" | grep -Fq -- "$1"; then
    record PASS "$2"
  else
    record FAIL "$2" "missing in stdout [$1]"
  fi
}

expect_err() {
  if printf '%s\n' "$RUN_ERR" | grep -Fq -- "$1"; then
    record PASS "$2"
  else
    record FAIL "$2" "missing in stderr [$1]"
  fi
}

expect_no_err() {
  if printf '%s\n' "$RUN_ERR" | grep -Fq -- "$1"; then
    record FAIL "$2" "unexpected in stderr [$1]"
  else
    record PASS "$2"
  fi
}

expect_log() {
  if grep -Fq -- "$1" "$ORCA_LOG" 2>/dev/null; then
    record PASS "$2"
  else
    record FAIL "$2" "missing in orca log [$1]"
  fi
}

expect_no_log() {
  if grep -Fq -- "$1" "$ORCA_LOG" 2>/dev/null; then
    record FAIL "$2" "unexpected in orca log [$1]"
  else
    record PASS "$2"
  fi
}

expect_file() {
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    record PASS "$2"
  else
    record FAIL "$2" "missing in $3 [$1]"
  fi
}

expect_no_file_line() {
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    record FAIL "$2" "unexpected in $3 [$1]"
  else
    record PASS "$2"
  fi
}

expect_file_empty() {
  if [ -f "$1" ] && [ ! -s "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "$1 is not empty"
  fi
}

expect_file_absent() {
  if [ -e "$1" ]; then
    record FAIL "$2" "$1 exists"
  else
    record PASS "$2"
  fi
}

mkdir -p "$BIN" || exit 1

cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${ORCA_LOG:?}"
case "${1:-} ${2:-}" in
  'terminal create')
    if [ -n "${ORCA_CREATE_JSON:-}" ]; then
      cat "$ORCA_CREATE_JSON"
    else
      printf '%s\n' '{"id":"req-1","ok":true,"result":{"terminal":{"handle":"term_created","tabId":"tab-new","title":"probe","worktreeId":"wt-1"}}}'
    fi
    ;;
  'terminal list')
    if [ -n "${ORCA_LIST_JSON:-}" ]; then
      cat "$ORCA_LIST_JSON"
    else
      printf '%s\n' '{"ok":true,"result":{"terminals":[]}}'
    fi
    ;;
  'terminal close')
    [ "${ORCA_CLOSE_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$BIN/orca"

# --- open ----------------------------------------------------------------------

: > "$ORCA_LOG"
rm -f "$RECORD"
ORCA_WORKTREE_ID=wt-1
run_tab open --record "$RECORD" --title 'spec-5 t3' -- --worktree /wt/one --base spec-5
expect_exit 0 'open exits 0'
expect_log 'terminal create --worktree current --title spec-5 t3 --command' \
  'open calls orca terminal create'
expect_log "$ROOT/scripts/ticket-watch.sh --worktree /wt/one --base spec-5" \
  'open passes the ticket-watch arguments'
expect_file "$(printf 'spec-5 t3\tterm_created')" \
  'open records the title, a real tab and the handle' "$RECORD"

: > "$ORCA_LOG"
run_tab open --record "$RECORD" --title 'spec-5 t3' -- --worktree /wt/two --base spec-5
expect_exit 0 'open with a recorded title exits 0'
expect_no_log 'terminal create' 'open with a recorded title creates nothing'

: > "$ORCA_LOG"
rm -f "$RECORD"
ORCA_WORKTREE_ID=
run_tab open --record "$RECORD" --title 'spec-5 t3' -- --worktree /wt/one --base spec-5
expect_exit 0 'open without ORCA_WORKTREE_ID exits 0'
expect_no_log 'terminal create' 'open without ORCA_WORKTREE_ID calls no orca'
expect_file_absent "$RECORD" 'open without ORCA_WORKTREE_ID writes no record'
expect_err 'ORCA_WORKTREE_ID' 'open without ORCA_WORKTREE_ID warns'
ORCA_WORKTREE_ID=wt-1

printf '%s\n' '{"id":"4146f396-0000","ok":true,"result":{"terminal":{"tabId":"tab-new"}}}' \
  > "$WORK/create-no-handle.json"
ORCA_CREATE_JSON=$WORK/create-no-handle.json
rm -f "$RECORD"
run_tab open --record "$RECORD" --title 'spec-5 t4' -- --worktree /wt/one --base spec-5
expect_exit 0 'open with a create response without a handle exits 0'
expect_file_absent "$RECORD" 'open records nothing without a handle'
expect_err 'result.terminal.handle' 'open warns about the missing handle'

printf '%s\n' '{"id":"66f12aa0-0000","ok":true,"result":{"terminal":{"handle":"66f12aa0-0000","tabId":"tab-new"}}}' \
  > "$WORK/create-bad-handle.json"
ORCA_CREATE_JSON=$WORK/create-bad-handle.json
rm -f "$RECORD"
run_tab open --record "$RECORD" --title 'spec-5 t5' -- --worktree /wt/one --base spec-5
expect_exit 0 'open with a handle that is not term_ exits 0'
expect_file_absent "$RECORD" 'open records nothing for a handle that is not term_'
expect_err 'does not start with term_' 'open warns about a handle that is not term_'
ORCA_CREATE_JSON=

SPACY="$WORK/sp ace"
mkdir -p "$SPACY" || exit 1
rm -f "$RECORD"
: > "$ORCA_LOG"
run_tab open --record "$RECORD" --title 'spec-5 t6' -- --worktree "$SPACY/wt" --base spec-5
expect_exit 0 'open with a path containing a space exits 0'
expect_file "$(printf 'spec-5 t6\tterm_created')" \
  'open records the tab for a path with a space' "$RECORD"
EXPECTED_COMMAND="$(printf '%q' "$ROOT/scripts/ticket-watch.sh") --worktree $(printf '%q' "$SPACY/wt") --base spec-5"
expect_log "--command $EXPECTED_COMMAND" 'open escapes the command so spaces survive'

rm -f "$RECORD"
: > "$ORCA_LOG"
run_tab open --record "$RECORD" --title 'spec-5 t7' --dry-run -- --worktree /wt/one --base spec-5
expect_exit 0 'open --dry-run exits 0'
expect_out 'dry-run: orca terminal create --worktree current --title spec-5 t7' \
  'open --dry-run prints the create command'
expect_no_log 'terminal create' 'open --dry-run executes no create'
expect_file_absent "$RECORD" 'open --dry-run writes no record'

# --- close ---------------------------------------------------------------------

printf 'spec-5 t3\tterm_a\n' > "$RECORD"
printf 'spec-5 merge t3\tterm_b\n' >> "$RECORD"
printf 'spec-5 fix\tterm_c\n' >> "$RECORD"
: > "$ORCA_LOG"
run_tab close --record "$RECORD" --title 'spec-5 t3' --title 'spec-5 merge t3'
expect_exit 0 'close exits 0'
expect_log 'terminal close --terminal term_a --tab' 'close closes the implementer tab'
expect_log 'terminal close --terminal term_b --tab' 'close closes the merger tab'
expect_no_log 'terminal close --terminal term_c --tab' 'close leaves other titles alone'
expect_file "$(printf 'spec-5 fix\tterm_c')" 'close keeps the other lines' "$RECORD"
expect_no_file_line 'spec-5 t3' 'close removes the closed implementer line' "$RECORD"
expect_no_file_line 'spec-5 merge t3' 'close removes the closed merger line' "$RECORD"

printf 'spec-5 t3\tterm_a\n' > "$RECORD"
printf 'spec-5 t3<TAB>term_dup\n' >> "$RECORD"
: > "$ORCA_LOG"
run_tab close --record "$RECORD" --title 'spec-5 t3'
expect_exit 0 'close handles duplicate title lines'
expect_log 'terminal close --terminal term_a --tab' 'close closes the first duplicate'
expect_log 'terminal close --terminal term_dup --tab' 'close closes the second duplicate'
expect_no_file_line 'spec-5 t3' 'close removes every line of the title' "$RECORD"

printf 'spec-5 t3\tterm_a\n' > "$RECORD"
ORCA_CLOSE_FAIL=1
: > "$ORCA_LOG"
run_tab close --record "$RECORD" --title 'spec-5 t3'
expect_exit 0 'close ignores an orca failure'
expect_log 'terminal close --terminal term_a --tab' 'close still tries the handle'
expect_no_file_line 'spec-5 t3' 'close removes the line even when orca fails' "$RECORD"
ORCA_CLOSE_FAIL=0

printf 'spec-5 t3\tterm_a\n' > "$RECORD"
: > "$ORCA_LOG"
run_tab close --record "$RECORD" --title 'spec-5 t3' --dry-run
expect_exit 0 'close --dry-run exits 0'
expect_out 'dry-run: orca terminal close --terminal term_a --tab' \
  'close --dry-run prints the close'
expect_no_log 'terminal close --terminal' 'close --dry-run executes no close'
expect_file "$(printf 'spec-5 t3\tterm_a')" 'close --dry-run leaves the record' "$RECORD"

rm -f "$RECORD"
: > "$ORCA_LOG"
run_tab close --record "$RECORD" --title 'spec-5 t3'
expect_exit 0 'close with a missing record exits 0'
expect_no_log 'terminal close' 'close with a missing record closes nothing'
expect_no_err 'no recorded progress tab' 'close with a missing record stays quiet'

# --- close-all: record part ----------------------------------------------------

printf 'spec-5 t3<TAB>term_a\n' > "$RECORD"
printf 'spec-5 t4<TAB>66f12aa0-0000\n' >> "$RECORD"
printf 'spec-5 t5\tterm_b\n' >> "$RECORD"
printf 'spec-5 t9\n' >> "$RECORD"
ORCA_WORKTREE_ID=
: > "$ORCA_LOG"
run_tab close-all --record "$RECORD"
expect_exit 0 'close-all exits 0'
expect_log 'terminal close --terminal term_a --tab' 'close-all closes a literal <TAB> line'
expect_log 'terminal close --terminal term_b --tab' 'close-all closes a real-tab line'
expect_no_log '66f12aa0' 'close-all skips a handle that is not term_'
expect_no_log 'terminal close --terminal spec-5 t9 --tab' 'close-all skips a line without a handle'
expect_err 'does not start with term_' 'close-all warns about the skipped handle'
expect_file_empty "$RECORD" 'close-all empties the record'

# --- close-all: scan part ------------------------------------------------------

cat > "$WORK/list.json" <<'EOF'
{"ok":true,"result":{"terminals":[
 {"handle":"term_impl","tabId":"tab-1","worktreeId":"wt-1","title":"spec-5 t3"},
 {"handle":"term_merge","tabId":"tab-2","worktreeId":"wt-1","title":"spec-5 merge t4"},
 {"handle":"term_fix","tabId":"tab-3","worktreeId":"wt-1","title":"spec-5 fix"},
 {"handle":"term_main","tabId":"tab-4","worktreeId":"wt-1","title":"spec-5 merge main"},
 {"handle":"term_done","tabId":"tab-5","worktreeId":"wt-1","title":"spec-5 ✓"},
 {"handle":"term_claude","tabId":"tab-6","worktreeId":"wt-1","title":"Claude Code"},
 {"handle":"term_other_spec","tabId":"tab-7","worktreeId":"wt-1","title":"spec-6 t1"},
 {"handle":"term_other_wt","tabId":"tab-8","worktreeId":"wt-2","title":"spec-5 t9"},
 {"handle":"term_self","tabId":"tab-self","worktreeId":"wt-1","title":"spec-5 fix"},
 {"handle":"term_prefix","tabId":"tab-10","worktreeId":"wt-1","title":"spec-5 t3 extra"},
 {"handle":"term_55","tabId":"tab-11","worktreeId":"wt-1","title":"spec-55 t1"}
]}}
EOF
ORCA_LIST_JSON=$WORK/list.json
ORCA_WORKTREE_ID=wt-1
ORCA_TAB_ID=tab-self
printf 'spec-5 t3<TAB>term_rec\n' > "$RECORD"
: > "$ORCA_LOG"
run_tab close-all --record "$RECORD" --spec 5
expect_exit 0 'close-all with --spec exits 0'
expect_log 'terminal close --terminal term_rec --tab' 'close-all closes the recorded tab'
expect_log 'terminal list --json' 'close-all scans the terminal list'
expect_log 'terminal close --terminal term_impl --tab' 'close-all closes the implementer tab it finds'
expect_log 'terminal close --terminal term_merge --tab' 'close-all closes the merger tab it finds'
expect_log 'terminal close --terminal term_fix --tab' 'close-all closes the fix tab it finds'
expect_log 'terminal close --terminal term_main --tab' 'close-all closes the merge-main tab it finds'
expect_no_log 'terminal close --terminal term_done --tab' 'close-all leaves spec-<n> ✓ alone'
expect_no_log 'terminal close --terminal term_claude --tab' 'close-all leaves Claude Code alone'
expect_no_log 'terminal close --terminal term_other_spec --tab' 'close-all leaves another spec number alone with --spec'
expect_no_log 'terminal close --terminal term_55 --tab' 'close-all does not treat spec-55 as spec-5'
expect_no_log 'terminal close --terminal term_other_wt --tab' 'close-all leaves another worktree alone'
expect_no_log 'terminal close --terminal term_self --tab' 'close-all never closes its own tab'
expect_no_log 'terminal close --terminal term_prefix --tab' 'close-all requires a full title match'
expect_file_empty "$RECORD" 'close-all empties the record after scanning'

: > "$ORCA_LOG"
rm -f "$RECORD"
run_tab close-all --record "$RECORD"
expect_exit 0 'close-all without --spec exits 0'
expect_log 'terminal close --terminal term_impl --tab' 'close-all without --spec closes matching titles'
expect_log 'terminal close --terminal term_other_spec --tab' 'close-all without --spec closes other spec numbers'
expect_no_log 'terminal close --terminal term_other_wt --tab' 'close-all without --spec leaves another worktree alone'

printf 'spec-5 t3<TAB>term_rec\n' > "$RECORD"
: > "$ORCA_LOG"
run_tab close-all --record "$RECORD" --spec 5 --dry-run
expect_exit 0 'close-all --dry-run exits 0'
expect_out 'dry-run: orca terminal close --terminal term_rec --tab' \
  'close-all --dry-run prints the recorded close'
expect_out 'dry-run: orca terminal close --terminal term_impl --tab' \
  'close-all --dry-run prints the scanned close'
expect_log 'terminal list --json' 'close-all --dry-run still runs the read-only list'
expect_no_log 'terminal close --terminal' 'close-all --dry-run executes no close'
expect_file "$(printf 'spec-5 t3<TAB>term_rec')" 'close-all --dry-run leaves the record' "$RECORD"

rm -f "$RECORD"
: > "$ORCA_LOG"
ORCA_WORKTREE_ID=
run_tab close-all --record "$RECORD" --spec 5
expect_exit 0 'close-all without ORCA_WORKTREE_ID exits 0'
expect_no_log 'terminal list' 'close-all without ORCA_WORKTREE_ID skips the scan'

ORCA_WORKTREE_ID=wt-1
rm -f "$RECORD"
: > "$ORCA_LOG"
run_tab close-all --record "$RECORD" --spec 5
expect_exit 0 'close-all with a missing record exits 0'
expect_log 'terminal list --json' 'close-all with a missing record still scans'

ORCA_LIST_JSON=
rm -f "$RECORD"
: > "$ORCA_LOG"
run_tab close-all
expect_exit 0 'close-all without --record exits 0'
expect_no_log 'terminal close' 'close-all without a record or scan closes nothing'

# --- usage ---------------------------------------------------------------------

run_tab
expect_usage_failure 'missing command is a usage error'
run_tab bogus
expect_usage_failure 'unknown command is a usage error'
run_tab open --record "$RECORD" --title 'spec-5 t3'
expect_usage_failure 'open without -- is a usage error'
run_tab open --record "$RECORD" --title 'spec-5 t3' --
expect_usage_failure 'open without ticket-watch arguments is a usage error'
run_tab close --record "$RECORD"
expect_usage_failure 'close without --title is a usage error'
run_tab close-all --record "$RECORD" --spec abc
expect_usage_failure 'a non-numeric --spec is a usage error'
run_tab --help
expect_exit 0 '--help exits 0'
expect_out 'usage:' '--help prints usage'

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
