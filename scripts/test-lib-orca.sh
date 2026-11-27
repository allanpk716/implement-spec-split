#!/usr/bin/env bash
# Isolated fake-Orca tests for scripts/lib-orca.sh, the Orca public library.
# Each test sources the library in a child shell, calls one library function
# and checks what the fake orca received: its command and every argument. The
# fake sits on PATH the way test-design-session.sh does it; a second fake off
# PATH is reachable only through ISS_ORCA. No real Orca, no network.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=$ROOT/scripts/lib-orca.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lib-orca-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN=$WORK/bin
OTHER=$WORK/other
ORCA_LOG=$WORK/orca.log
OTHER_LOG=$WORK/other.log
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

expect_has() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    ok "$2"
  else
    bad "$2" "missing [$1]; $(tail -n 5 "$3" 2>/dev/null)"
  fi
}

expect_without() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    bad "$2" "unexpected [$1]"
  else
    ok "$2"
  fi
}

expect_same() { # expected actual name
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    bad "$3" "got [$2], expected [$1]"
  fi
}

expect_empty_log() { # name file
  if [ -s "$2" ]; then
    bad "$1" "$(cat "$2")"
  else
    ok "$1"
  fi
}

expect_count() { # text expected name file
  actual=$(grep -Fc -- "$1" "$4" 2>/dev/null || true)
  if [ "$actual" -eq "$2" ]; then
    ok "$3"
  else
    bad "$3" "count=$actual, expected=$2"
  fi
}

# call OUT [NAME=value...] function [arguments...]
#   Runs one library function in a child shell that sources the library.
#   ISS_ORCA is unset unless a NAME=value names it.
call() {
  out=$1
  shift
  assigns=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do
    assigns+=("$1")
    shift
  done
  env -u ISS_ORCA ${assigns[@]+"${assigns[@]}"} \
      ORCA_LOG="$ORCA_LOG" OTHER_LOG="$OTHER_LOG" PATH="$BIN:$PATH" \
      bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@" >"$out" 2>"$out.err" </dev/null
  RUN_EXIT=$?
}

# call_code OUT [NAME=value...] <bash code>
#   Sources the library in a child shell, then runs the code there, so several
#   library calls can be made in one process.
call_code() {
  out=$1
  shift
  assigns=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do
    assigns+=("$1")
    shift
  done
  env -u ISS_ORCA ${assigns[@]+"${assigns[@]}"} \
      ORCA_LOG="$ORCA_LOG" OTHER_LOG="$OTHER_LOG" PATH="$BIN:$PATH" \
      bash -c 'source "$1"; eval "$2"' _ "$LIB" "$1" >"$out" 2>"$out.err" </dev/null
  RUN_EXIT=$?
}

reset_logs() { : >"$ORCA_LOG"; : >"$OTHER_LOG"; }

mkdir -p "$BIN" "$OTHER" || exit 1

# The fake on PATH records every call. `terminal list` answers with the file
# ORCA_TERMINALS names, or with the n-th file of ORCA_LIST_SEQUENCE on the n-th
# call (the last one from then on), so a handle can drift between two calls.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
command=$1
shift
printf '%s\n' "$command" >> "$ORCA_LOG"
for argument in "$@"; do
  printf 'ARG %s\n' "$argument" >> "$ORCA_LOG"
done
if [ "$command" = terminal ] && [ "${1:-}" = list ]; then
  if [ "${ORCA_LIST_FAIL:-0}" = 1 ]; then
    printf '%s\n' 'orca offline' >&2
    exit 1
  fi
  if [ -n "${ORCA_LIST_SEQUENCE:-}" ]; then
    count=0
    [ -f "$ORCA_LIST_SEQUENCE/count" ] && count=$(cat "$ORCA_LIST_SEQUENCE/count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$ORCA_LIST_SEQUENCE/count"
    file=$(sed -n "${count}p" "$ORCA_LIST_SEQUENCE/order")
    [ -n "$file" ] || file=$(tail -n 1 "$ORCA_LIST_SEQUENCE/order")
    cat "$ORCA_LIST_SEQUENCE/$file"
    exit 0
  fi
  if [ -n "${ORCA_TERMINALS:-}" ]; then
    cat "$ORCA_TERMINALS"
    exit 0
  fi
fi
exit 0
EOF
chmod +x "$BIN/orca"

# A second fake, off PATH, reached only through ISS_ORCA.
cat > "$OTHER/orca" <<'EOF'
#!/usr/bin/env bash
set -u
command=$1
shift
printf '%s\n' "$command" >> "$OTHER_LOG"
for argument in "$@"; do
  printf 'ARG %s\n' "$argument" >> "$OTHER_LOG"
done
exit 0
EOF
chmod +x "$OTHER/orca"

write_terminals() { # file handle-of-tab-1
  node -e '
    const fs = require("fs");
    const [file, handle] = process.argv.slice(1);
    const value = {ok: true, result: {terminals: [
      {handle, tabId: "tab-1", leafId: "leaf-1", worktreePath: "/w/repo", title: "/repo 7"},
      {handle: "term_other", tabId: "tab-2", leafId: "leaf-2", worktreePath: "/elsewhere", title: "#9"}
    ]}};
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$@"
}

# --- the one replacement variable ---------------------------------------------

reset_logs
call "$WORK/default.out" orca_terminal_list
expect_exit 0 "ISS_ORCA unset: exits 0"
expect_has 'terminal' "ISS_ORCA unset: reaches the orca on PATH" "$ORCA_LOG"
expect_has 'ARG list' "ISS_ORCA unset: passes the subcommand" "$ORCA_LOG"
expect_empty_log "ISS_ORCA unset: no other orca is involved" "$OTHER_LOG"

reset_logs
call "$WORK/replaced.out" ISS_ORCA="$OTHER/orca" orca_terminal_list
expect_exit 0 "ISS_ORCA set: exits 0"
expect_has 'ARG list' "ISS_ORCA set: reaches the program ISS_ORCA names" "$OTHER_LOG"
expect_empty_log "ISS_ORCA set: the orca on PATH is not called" "$ORCA_LOG"

exe=$(env -u ISS_ORCA PATH="$BIN:$PATH" bash -c 'source "$1"; orca_exe' _ "$LIB")
expect_same orca "$exe" "orca_exe: names orca when ISS_ORCA is unset"
exe=$(ISS_ORCA="$OTHER/orca" PATH="$BIN:$PATH" bash -c 'source "$1"; orca_exe' _ "$LIB")
expect_same "$OTHER/orca" "$exe" "orca_exe: names the program ISS_ORCA names"

# --- orchestration send: the Run is a required argument -------------------------

reset_logs
call "$WORK/send.out" orca_orchestration_send run_abc \
    --subject 'handoff ready' --to run:run_abc --report-path "$WORK/handoff.md"
expect_exit 0 "send: exits 0"
expect_has 'orchestration' "send: runs the orchestration command" "$ORCA_LOG"
expect_same "$(printf 'ARG send\nARG --run\nARG run_abc')" "$(sed -n '2,4p' "$ORCA_LOG")" \
  "send: --run <id> comes first, right after the subcommand"
expect_has 'ARG --subject' "send: passes --subject through" "$ORCA_LOG"
expect_has 'ARG handoff ready' "send: passes the subject through" "$ORCA_LOG"
expect_has 'ARG --to' "send: passes --to through" "$ORCA_LOG"
expect_has 'ARG run:run_abc' "send: passes the recipient through" "$ORCA_LOG"
expect_has 'ARG --report-path' "send: passes --report-path through" "$ORCA_LOG"

reset_logs
call "$WORK/send-empty.out" orca_orchestration_send '' --subject hi
expect_exit 64 "send with an empty Run id exits 64"
expect_has 'lib-orca' "send with an empty Run id names the library" "$WORK/send-empty.out.err"
expect_has 'Run id' "send with an empty Run id says what is missing" "$WORK/send-empty.out.err"
expect_empty_log "send with an empty Run id never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/send-option.out" orca_orchestration_send --subject hi
expect_exit 64 "send whose first argument is an option exits 64"
expect_empty_log "send whose first argument is an option never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/send-none.out" orca_orchestration_send
expect_exit 64 "send without arguments exits 64"
expect_empty_log "send without arguments never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/send-twice.out" orca_orchestration_send run_abc --run run_other --subject hi
expect_exit 64 "send with a second --run exits 64"
expect_empty_log "send with a second --run never starts Orca" "$ORCA_LOG"

# --- orchestration run-create: the Run a coordinator waits on --------------------

reset_logs
call "$WORK/run-create.out" orca_orchestration_run_create 'Design session handoff for repo'
expect_exit 0 "run-create: exits 0"
expect_same "$(printf 'orchestration\nARG run-create\nARG --objective\nARG Design session handoff for repo\nARG --json')" \
  "$(cat "$ORCA_LOG")" "run-create: creates a Run with that objective, as JSON"

reset_logs
call "$WORK/run-create-empty.out" orca_orchestration_run_create ''
expect_exit 64 "run-create without an objective exits 64"
expect_has 'objective' "run-create without an objective says what is missing" "$WORK/run-create-empty.out.err"
expect_empty_log "run-create without an objective never starts Orca" "$ORCA_LOG"

# --- orchestration check: look by default, take only on request -----------------

reset_logs
call "$WORK/check.out" orca_orchestration_check run_abc
expect_exit 0 "check: exits 0"
expect_same "$(printf 'orchestration\nARG check\nARG --run\nARG run_abc\nARG --json\nARG --peek')" \
  "$(cat "$ORCA_LOG")" "check: names the Run and peeks, nothing else"

reset_logs
call "$WORK/check-take.out" orca_orchestration_check run_abc --take
expect_exit 0 "check --take: exits 0"
expect_same "$(printf 'orchestration\nARG check\nARG --run\nARG run_abc\nARG --json')" \
  "$(cat "$ORCA_LOG")" "check --take: names the Run and takes, with no --peek"

reset_logs
call "$WORK/check-empty.out" orca_orchestration_check ''
expect_exit 64 "check with an empty Run id exits 64"
expect_has 'Run id' "check with an empty Run id says what is missing" "$WORK/check-empty.out.err"
expect_empty_log "check with an empty Run id never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/check-option.out" orca_orchestration_check --take
expect_exit 64 "check whose first argument is an option exits 64"
expect_empty_log "check whose first argument is an option never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/check-unknown.out" orca_orchestration_check run_abc --unread
expect_exit 64 "check with an option it does not offer exits 64"
expect_has '--unread' "check with an unknown option names it" "$WORK/check-unknown.out.err"
expect_empty_log "check with an unknown option never starts Orca" "$ORCA_LOG"

# --- orchestration check: one blocking wait, no polling -------------------------

reset_logs
call "$WORK/check-wait.out" orca_orchestration_check run_abc --timeout-ms 1500
expect_exit 0 "check --timeout-ms: exits 0"
expect_same "$(printf 'orchestration\nARG check\nARG --run\nARG run_abc\nARG --json\nARG --peek\nARG --wait\nARG --timeout-ms\nARG 1500')" \
  "$(cat "$ORCA_LOG")" "check --timeout-ms: one blocking call that still peeks"

reset_logs
call "$WORK/check-wait-take.out" orca_orchestration_check run_abc --timeout-ms 1500 --take
expect_exit 0 "check --timeout-ms --take: exits 0"
expect_same "$(printf 'orchestration\nARG check\nARG --run\nARG run_abc\nARG --json\nARG --wait\nARG --timeout-ms\nARG 1500')" \
  "$(cat "$ORCA_LOG")" "check --timeout-ms --take: one blocking call that takes"

reset_logs
call "$WORK/check-wait-flag.out" orca_orchestration_check run_abc --wait
expect_exit 64 "check --wait on its own exits 64: waiting always carries a timeout"
expect_empty_log "check --wait on its own never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/check-timeout-zero.out" orca_orchestration_check run_abc --timeout-ms 0
expect_exit 64 "check --timeout-ms 0 exits 64"
expect_empty_log "check --timeout-ms 0 never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/check-timeout-word.out" orca_orchestration_check run_abc --timeout-ms soon
expect_exit 64 "check --timeout-ms with a word exits 64"
expect_has 'soon' "check --timeout-ms with a word names it" "$WORK/check-timeout-word.out.err"
expect_empty_log "check --timeout-ms with a word never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/check-timeout-missing.out" orca_orchestration_check run_abc --timeout-ms
expect_exit 64 "check --timeout-ms without a value exits 64"
expect_empty_log "check --timeout-ms without a value never starts Orca" "$ORCA_LOG"

# --- orchestration worker-start: adopting a terminal the caller opened ------------

reset_logs
call "$WORK/start.out" orca_orchestration_worker_start run_abc --terminal term_glm \
    --spec-file "$WORK/prompt.txt" --timeout-ms 180000
expect_exit 0 "worker-start: exits 0"
expect_same "$(printf 'orchestration\nARG worker-start\nARG --run\nARG run_abc\nARG --terminal\nARG term_glm\nARG --spec-file\nARG %s\nARG --json\nARG --timeout-ms\nARG 180000' "$WORK/prompt.txt")" \
  "$(cat "$ORCA_LOG")" \
  "worker-start: names the Run, adopts the terminal and reads the spec from the file, as JSON"

reset_logs
call "$WORK/start-no-timeout.out" orca_orchestration_worker_start run_abc \
    --terminal term_glm --spec-file "$WORK/prompt.txt"
expect_exit 0 "worker-start without --timeout-ms: exits 0"
expect_same "$(printf 'orchestration\nARG worker-start\nARG --run\nARG run_abc\nARG --terminal\nARG term_glm\nARG --spec-file\nARG %s\nARG --json' "$WORK/prompt.txt")" \
  "$(cat "$ORCA_LOG")" "worker-start without --timeout-ms: no timeout argument at all"

reset_logs
call "$WORK/start-empty.out" orca_orchestration_worker_start '' --terminal term_glm \
    --spec-file "$WORK/prompt.txt"
expect_exit 64 "worker-start with an empty Run id exits 64"
expect_has 'Run id' "worker-start with an empty Run id says what is missing" "$WORK/start-empty.out.err"
expect_empty_log "worker-start with an empty Run id never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/start-twice.out" orca_orchestration_worker_start run_abc --run run_other \
    --terminal term_glm --spec-file "$WORK/prompt.txt"
expect_exit 64 "worker-start with a second --run exits 64"
expect_empty_log "worker-start with a second --run never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/start-no-terminal.out" orca_orchestration_worker_start run_abc --spec-file "$WORK/prompt.txt"
expect_exit 64 "worker-start without --terminal exits 64"
expect_has 'terminal' "worker-start without --terminal says what is missing" "$WORK/start-no-terminal.out.err"
expect_empty_log "worker-start without --terminal never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/start-no-spec.out" orca_orchestration_worker_start run_abc --terminal term_glm
expect_exit 64 "worker-start without --spec-file exits 64"
expect_has 'spec' "worker-start without --spec-file says what is missing" "$WORK/start-no-spec.out.err"
expect_empty_log "worker-start without --spec-file never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/start-unknown.out" orca_orchestration_worker_start run_abc --terminal term_glm \
    --spec-file "$WORK/prompt.txt" --model glm-5.4
expect_exit 64 "worker-start with --model exits 64: the launcher already got the model on its command line"
expect_has '--model' "worker-start with an option it does not offer names it" "$WORK/start-unknown.out.err"
expect_empty_log "worker-start with an option it does not offer never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/start-timeout-word.out" orca_orchestration_worker_start run_abc --terminal term_glm \
    --spec-file "$WORK/prompt.txt" --timeout-ms soon
expect_exit 64 "worker-start with a word for --timeout-ms exits 64"
expect_has 'soon' "worker-start with a word for a timeout names it" "$WORK/start-timeout-word.out.err"
expect_empty_log "worker-start with a word for a timeout never starts Orca" "$ORCA_LOG"

# --- terminal handle: resolved again on every call -----------------------------

write_terminals "$WORK/terminals-before.json" term_self
write_terminals "$WORK/terminals-after.json" term_self_moved

reset_logs
call "$WORK/pane.out" ORCA_TERMINALS="$WORK/terminals-before.json" \
    orca_terminal_by_pane tab-1 leaf-1
expect_exit 0 "by_pane: exits 0"
expect_same "$(printf 'term_self\t/w/repo')" "$(cat "$WORK/pane.out")" \
  "by_pane: prints the handle and the worktree path of that pane"
expect_has 'ARG list' "by_pane: asks Orca for the terminal list" "$ORCA_LOG"

# Two calls in one process while Orca's handle for the pane drifts in between.
mkdir -p "$WORK/drift"
printf '%s\n' before after > "$WORK/drift/order"
cp "$WORK/terminals-before.json" "$WORK/drift/before"
cp "$WORK/terminals-after.json" "$WORK/drift/after"
reset_logs
call_code "$WORK/pane-drift.out" ORCA_LIST_SEQUENCE="$WORK/drift" '
  orca_terminal_by_pane tab-1 leaf-1
  orca_terminal_by_pane tab-1 leaf-1
'
expect_exit 0 "by_pane twice: exits 0"
expect_same "$(printf 'term_self\t/w/repo\nterm_self_moved\t/w/repo')" "$(cat "$WORK/pane-drift.out")" \
  "by_pane twice: the second call sees the drifted handle"
expect_count 'ARG list' 2 "by_pane twice: Orca is asked twice, nothing is reused" "$ORCA_LOG"

reset_logs
call "$WORK/pane-missing.out" ORCA_TERMINALS="$WORK/terminals-before.json" \
    orca_terminal_by_pane tab-9 leaf-9
expect_exit 1 "by_pane: a pane Orca does not list exits 1"
expect_same '' "$(cat "$WORK/pane-missing.out")" "by_pane: prints nothing for an unknown pane"

printf '%s\n' 'not json' > "$WORK/terminals-broken.json"
reset_logs
call "$WORK/pane-broken.out" ORCA_TERMINALS="$WORK/terminals-broken.json" \
    orca_terminal_by_pane tab-1 leaf-1
expect_exit 2 "by_pane: output that is not JSON exits 2"

reset_logs
call "$WORK/pane-orca-down.out" ORCA_LIST_FAIL=1 \
    ORCA_TERMINALS="$WORK/terminals-before.json" orca_terminal_by_pane tab-1 leaf-1
expect_exit 3 "by_pane: a failing orca exits 3"
expect_has 'orca offline' "by_pane: passes Orca's stderr through" "$WORK/pane-orca-down.out.err"
expect_same '' "$(cat "$WORK/pane-orca-down.out")" "by_pane: prints nothing when Orca fails"

# --- terminal and worktree: the calls close-self and keeper make ---------------

reset_logs
call "$WORK/close.out" orca_terminal_close term_self
expect_exit 0 "terminal close: exits 0"
expect_same "$(printf 'terminal\nARG close\nARG --terminal\nARG term_self\nARG --tab')" "$(cat "$ORCA_LOG")" \
  "terminal close: closes the whole tab of that one terminal"

reset_logs
call "$WORK/close-empty.out" orca_terminal_close ''
expect_exit 64 "terminal close without a handle exits 64"
expect_has 'handle' "terminal close without a handle says what is missing" "$WORK/close-empty.out.err"
expect_empty_log "terminal close without a handle never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/send-text.out" orca_terminal_send term_self '继续。'
expect_exit 0 "terminal send: exits 0"
expect_same "$(printf 'terminal\nARG send\nARG --terminal\nARG term_self\nARG --text\nARG 继续。\nARG --enter')" \
  "$(cat "$ORCA_LOG")" "terminal send: types the text into that terminal and presses Enter"

reset_logs
call "$WORK/send-text-empty.out" orca_terminal_send term_self ''
expect_exit 64 "terminal send without text exits 64"
expect_empty_log "terminal send without text never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/rm.out" orca_worktree_rm '/w/repo wt'
expect_exit 0 "worktree rm: exits 0"
expect_same "$(printf 'worktree\nARG rm\nARG --worktree\nARG path:/w/repo wt\nARG --force\nARG --delete-branch')" \
  "$(cat "$ORCA_LOG")" "worktree rm: removes that path, forced, together with its branch"

reset_logs
call "$WORK/rm-empty.out" orca_worktree_rm ''
expect_exit 64 "worktree rm without a path exits 64"
expect_empty_log "worktree rm without a path never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/repos.out" orca_repo_list
expect_exit 0 "repo list: exits 0"
expect_same "$(printf 'repo\nARG list\nARG --json')" "$(cat "$ORCA_LOG")" \
  "repo list: asks for the registry as JSON"

# --- status: the call launch-wave starts with -----------------------------------

reset_logs
call "$WORK/status.out" orca_status
expect_exit 0 "status: exits 0"
expect_same "$(printf 'status\nARG --json')" "$(cat "$ORCA_LOG")" \
  "status: asks whether Orca is up, as JSON"

# --- worktree list and create: the calls launch-wave makes ----------------------

reset_logs
call "$WORK/worktrees.out" orca_worktree_list
expect_exit 0 "worktree list: exits 0"
expect_same "$(printf 'worktree\nARG list\nARG --json')" "$(cat "$ORCA_LOG")" \
  "worktree list: asks for the worktrees as JSON"

reset_logs
call "$WORK/create.out" orca_worktree_create '/w/repo main' spec-7 spec-7 origin/master 7 claude \
    '/implement-spec-split 7 --parallel 2'
expect_exit 0 "worktree create: exits 0"
expect_same "$(printf 'worktree\nARG create\nARG --repo\nARG path:/w/repo main\nARG --name\nARG spec-7\nARG --branch\nARG spec-7\nARG --base-branch\nARG origin/master\nARG --issue\nARG 7\nARG --no-parent\nARG --agent\nARG claude\nARG --prompt\nARG /implement-spec-split 7 --parallel 2\nARG --json')" \
  "$(cat "$ORCA_LOG")" \
  "worktree create: creates the branch off the base and starts the agent in it, as JSON"

reset_logs
call "$WORK/create-empty.out" orca_worktree_create '/w/repo main' spec-7 spec-7 origin/master 7 claude ''
expect_exit 64 "worktree create without a prompt exits 64"
expect_has 'prompt' "worktree create without a prompt says what is missing" "$WORK/create-empty.out.err"
expect_empty_log "worktree create without a prompt never starts Orca" "$ORCA_LOG"

# --- agent launch and terminal create: how launch-wave resumes a Spec ----------

reset_logs
call "$WORK/launch.out" orca_agent_launch openclaude '/w/spec-7' '/implement-spec-split 7 --resume'
expect_exit 0 "agent launch: exits 0"
expect_same "$(printf 'agent\nARG launch\nARG --agent\nARG openclaude\nARG --worktree\nARG path:/w/spec-7\nARG --prompt\nARG /implement-spec-split 7 --resume\nARG --json')" \
  "$(cat "$ORCA_LOG")" "agent launch: starts that agent in the existing worktree with the prompt, as JSON"

reset_logs
call "$WORK/launch-empty.out" orca_agent_launch openclaude '' '/implement-spec-split 7'
expect_exit 64 "agent launch without a worktree exits 64"
expect_has 'worktree path' "agent launch without a worktree says what is missing" "$WORK/launch-empty.out.err"
expect_empty_log "agent launch without a worktree never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/terminal-create.out" orca_terminal_create '/w/repo main' spec-7 \
    "cd /w/spec-7 && claude /implement-spec-split 7"
expect_exit 0 "terminal create: exits 0"
expect_same "$(printf 'terminal\nARG create\nARG --worktree\nARG path:/w/repo main\nARG --title\nARG spec-7\nARG --command\nARG cd /w/spec-7 && claude /implement-spec-split 7\nARG --json')" \
  "$(cat "$ORCA_LOG")" \
  "terminal create: opens a titled terminal in that worktree running the command, as JSON"

reset_logs
call "$WORK/terminal-create-empty.out" orca_terminal_create '/w/repo main' '' 'claude'
expect_exit 64 "terminal create without a title exits 64"
expect_has 'title' "terminal create without a title says what is missing" "$WORK/terminal-create-empty.out.err"
expect_empty_log "terminal create without a title never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/terminal-create-focus.out" orca_terminal_create '/w/repo main' 'Design session feature' \
    'claude --dangerously-skip-permissions --model opus --effort high' --focus
expect_exit 0 "terminal create --focus: exits 0"
expect_same "$(printf 'terminal\nARG create\nARG --worktree\nARG path:/w/repo main\nARG --title\nARG Design session feature\nARG --command\nARG claude --dangerously-skip-permissions --model opus --effort high\nARG --focus\nARG --json')" \
  "$(cat "$ORCA_LOG")" \
  "terminal create --focus: opens the terminal and switches to it, as JSON"

reset_logs
call "$WORK/terminal-create-other.out" orca_terminal_create '/w/repo main' t 'claude' --keep-open
expect_exit 64 "terminal create with an option it does not offer exits 64"
expect_has '--keep-open' "terminal create with an unknown option names it" "$WORK/terminal-create-other.out.err"
expect_empty_log "terminal create with an unknown option never starts Orca" "$ORCA_LOG"

# --- terminal switch and wait: how design-session.sh follows a Design session ----

reset_logs
call "$WORK/switch.out" orca_terminal_switch term_orchestrator
expect_exit 0 "terminal switch: exits 0"
expect_same "$(printf 'terminal\nARG switch\nARG --terminal\nARG term_orchestrator')" "$(cat "$ORCA_LOG")" \
  "terminal switch: brings that terminal's tab to the front"

reset_logs
call "$WORK/switch-empty.out" orca_terminal_switch ''
expect_exit 64 "terminal switch without a handle exits 64"
expect_has 'handle' "terminal switch without a handle says what is missing" "$WORK/switch-empty.out.err"
expect_empty_log "terminal switch without a handle never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/wait.out" orca_terminal_wait term_glm exit 7200000
expect_exit 0 "terminal wait: exits 0"
expect_same "$(printf 'terminal\nARG wait\nARG --terminal\nARG term_glm\nARG --for\nARG exit\nARG --timeout-ms\nARG 7200000\nARG --json')" \
  "$(cat "$ORCA_LOG")" "terminal wait: one blocking wait for the condition, with its timeout, as JSON"

reset_logs
call "$WORK/wait-empty.out" orca_terminal_wait '' exit 1000
expect_exit 64 "terminal wait without a handle exits 64"
expect_has 'handle' "terminal wait without a handle says what is missing" "$WORK/wait-empty.out.err"
expect_empty_log "terminal wait without a handle never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/wait-condition.out" orca_terminal_wait term_glm idle 1000
expect_exit 64 "terminal wait with a condition it does not offer exits 64"
expect_has 'idle' "terminal wait with an unknown condition names it" "$WORK/wait-condition.out.err"
expect_empty_log "terminal wait with an unknown condition never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/wait-timeout-word.out" orca_terminal_wait term_glm exit soon
expect_exit 64 "terminal wait with a word for a timeout exits 64"
expect_has 'soon' "terminal wait with a word for a timeout names it" "$WORK/wait-timeout-word.out.err"
expect_empty_log "terminal wait with a word for a timeout never starts Orca" "$ORCA_LOG"

reset_logs
call "$WORK/wait-timeout-none.out" orca_terminal_wait term_glm exit
expect_exit 64 "terminal wait without a timeout exits 64: a wait always carries one"
expect_empty_log "terminal wait without a timeout never starts Orca" "$ORCA_LOG"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
