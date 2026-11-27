#!/usr/bin/env bash
# Isolated fake-Orca tests for scripts/design-session.sh.
# The Stage route table is the real scripts/stage-route.sh reading a table of
# this test's own (ISS_STAGE_ROUTE_FILE), so the user's real table is never read
# and the first run's migration never reaches the real ~/.claude/state.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/design-session.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/design-session-test.XXXXXX")
WORK=$(cd "$WORK" && pwd)
BIN=$WORK/bin
ORCA_LOG=$WORK/orca.log
PROMPT_LOG=$WORK/prompt.txt
CHECK_LOG=$WORK/check.log
CHECK_ATTEMPTS=$WORK/check-attempts
REPORT=$WORK/reported-handoff.md
REPORT_LOG=$WORK/reported-path.txt
TOPIC_FILE=$WORK/topic-with-shell-characters.md
EMPTY_TOPIC_FILE=$WORK/empty-topic.md
STAGE_ROUTE_FILE=$WORK/stage-route
FAKE_STAGE_ROUTE=$WORK/fake-stage-route.sh
PASSED=0
FAILED=0
RUN_EXIT=
RUN_STDOUT=$WORK/stdout.txt
RUN_STDERR=$WORK/stderr.txt

# The table and HOME of this test alone: design-session.sh and stage-route.sh
# never look at the user's real ~/.claude/state.
: > "$STAGE_ROUTE_FILE"
mkdir -p "$WORK/home"
export ISS_STAGE_ROUTE_FILE=$STAGE_ROUTE_FILE
export HOME=$WORK/home

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    # Keep mktemp scratch in place; the tests must not recursively delete it.
    :
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

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

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_file_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in $(basename "$file")"
  fi
}

expect_file_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text] in $(basename "$file")"
  else
    record PASS "$name"
  fi
}

expect_same_file() {
  expected=$1
  name=$2
  actual=$3
  if [ -f "$actual" ] && cmp -s "$expected" "$actual"; then
    record PASS "$name"
  else
    record FAIL "$name" "actual=$actual"
  fi
}

# Prints the Orca subcommands the fake received, in order, space separated.
# (The fake writes the command, then every argument, then the subcommand.)
orca_sequence() {
  grep -v '^ARG ' "$ORCA_LOG" | grep -vxE 'orchestration|terminal|agent|status|repo|worktree' | tr '\n' ' '
}

# Sets the design route through the real table script, the way /grill-router does.
set_design_route() { # <profile>/<model>/<effort>
  "$ROOT/scripts/stage-route.sh" use "design=$1" >/dev/null 2>&1
}

mkdir -p "$BIN" || exit 1
printf '%s\n' 'Spec #15, tickets #18.' > "$REPORT"

cat > "$BIN/orca" <<EOF
#!/usr/bin/env bash
set -u
command=\$1
shift
printf '%s\\n' "\$command" >> "\$ORCA_LOG"
for argument in "\$@"; do
  printf 'ARG %s\\n' "\$argument" >> "\$ORCA_LOG"
done
case "\$command" in
  orchestration)
    subcommand=\$1
    shift
    printf '%s\\n' "\$subcommand" >> "\$ORCA_LOG"
    case "\$subcommand" in
      run-create)
        if [ "\${DESIGN_TEST_RUN_CREATE_FAIL:-0}" = 1 ]; then
          printf '%s\\n' 'fake orca run-create failed' >&2
          exit 70
        fi
        printf '%s\\n' '{"ok":true,"result":{"id":"run_test_design"}}'
        ;;
      worker-start)
        previous=
        for argument in "\$@"; do
          if [ "\$previous" = --spec-file ]; then
            cat "\$argument" > "\$PROMPT_LOG"
          fi
          previous=\$argument
        done
        if [ "\${DESIGN_TEST_START_FAIL:-0}" = 1 ]; then
          printf '%s\\n' 'fake orca worker-start failed' >&2
          exit 70
        fi
        printf '%s\\n' '{"ok":true,"result":{"dispatchId":"ctx_test_design","taskId":"task_test_design","runId":"run_test_design","state":"ready","mode":"terminal","terminal":"term_glm"}}'
        ;;
      check)
        if [ "\${DESIGN_TEST_SESSION_EXIT:-0}" = 1 ]; then
          sleep 2
        fi
        sleep "\${DESIGN_TEST_CHECK_SLEEP:-0}"
        for argument in "\$@"; do
          printf '%s\\n' "\$argument" >> "\$CHECK_LOG"
        done
        if [ "\${DESIGN_TEST_TIMEOUT:-0}" = 1 ]; then
          printf '%s\\n' '{"ok":true,"result":{"timedOut":true,"messages":[]}}'
          exit 0
        fi
        if [ "\${DESIGN_TEST_CHECK_FAIL:-0}" = 1 ]; then
          printf '%s\\n' 'fake orca check failed' >&2
          exit 70
        fi
        attempts=0
        if [ -f "\$CHECK_ATTEMPTS" ]; then
          attempts=\$(cat "\$CHECK_ATTEMPTS")
        fi
        attempts=\$((attempts + 1))
        printf '%s\\n' "\$attempts" > "\$CHECK_ATTEMPTS"
        if [ "\${DESIGN_TEST_UNRELATED_FIRST:-0}" = 1 ] &&
           [ "\$attempts" = 1 ]; then
          printf '%s\\n' '{"ok":true,"result":{"messages":[{"id":"noise","payload":{"body":"not a handoff"}}]}}'
          exit 0
        fi
        if [ -n "\${DESIGN_TEST_REPORT_PATH:-}" ]; then
          REPORT_PATH=\$DESIGN_TEST_REPORT_PATH
        else
          REPORT_DIR=\$(sed -n 's/^运行目录：//p' "\$PROMPT_LOG" | head -1)
          REPORT_PATH="\$REPORT_DIR/handoff.md"
        fi
        if [ "\${DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT:-0}" = 1 ]; then
          if [ "\$attempts" = 1 ]; then
            printf '%s\\n' '{"ok":true,"result":{"messages":[{"id":"wrong","payload":{"reportPath":"'$WORK'/wrong-handoff.md"}}]}}'
          else
            printf '%s\\n' '{"ok":true,"result":{"timedOut":true,"messages":[]}}'
          fi
          exit 0
        fi
        if [ "\${DESIGN_TEST_MISSING_HANDOFF:-0}" = 1 ]; then
          printf '%s\\n' "{\"ok\":true,\"result\":{\"messages\":[{\"id\":\"msg-1\",\"payload\":{\"reportPath\":\"\$REPORT_PATH\"}}]}}"
          exit 0
        fi
        if [ -n "\${DESIGN_TEST_HANDOFF_FILE:-}" ]; then
          cp "\$DESIGN_TEST_HANDOFF_FILE" "\$REPORT_PATH"
        else
          printf 'Spec #15, tickets #18.\\n' > "\$REPORT_PATH"
        fi
        printf '%s\\n' "\$REPORT_PATH" > "\$REPORT_LOG"
        printf '%s\\n' "{\"ok\":true,\"result\":{\"messages\":[{\"id\":\"msg-1\",\"payload\":{\"reportPath\":\"\$REPORT_PATH\"}}]}}"
        ;;
      *)
        printf 'fake orca: unsupported orchestration subcommand %s\\n' "\$subcommand" >&2
        exit 70
        ;;
    esac
    ;;
  terminal)
    subcommand=\$1
    shift
    printf '%s\\n' "\$subcommand" >> "\$ORCA_LOG"
    case "\$subcommand" in
      create)
        # The terminal Orca opens runs the route's launcher; the fake never runs
        # it. Orca's terminal outlives the command typed into it, so the fake
        # writes the exit code the typed command would write, and never reports
        # the exit itself.
        run_dir=
        previous=
        for argument in "\$@"; do
          if [ "\$previous" = --command ]; then
            rest=\${argument##*> }
            run_dir=\$(dirname "\$rest")
          fi
          previous=\$argument
        done
        (
          if [ "\${DESIGN_TEST_SESSION_EXIT:-0}" = 1 ]; then sleep 0.3; else sleep 1.5; fi
          printf '0\\n' > "\$run_dir/exit-code"
        ) >/dev/null 2>&1 &
        if [ "\${DESIGN_TEST_CREATE_FAIL:-0}" = 1 ]; then
          printf '%s\\n' 'fake orca terminal create failed' >&2
          exit 70
        fi
        if [ "\${DESIGN_TEST_CREATE_NO_HANDLE:-0}" = 1 ]; then
          printf '%s\\n' '{"ok":true,"result":{"terminal":{"tabId":"tab_glm"}}}'
          exit 0
        fi
        printf '%s\\n' '{"ok":true,"result":{"terminal":{"handle":"term_glm","tabId":"tab_glm","worktreeId":"wt-test"}}}'
        ;;
      wait)
        if [ "\${DESIGN_TEST_WAIT_EXIT:-0}" = 1 ]; then
          sleep 0.3
          printf '%s\\n' '{"ok":true,"result":{"exited":true}}'
          exit 0
        fi
        # The session outlives every test: the wrapper cuts this wait short.
        sleep 6
        printf '%s\\n' '{"ok":false,"error":{"code":"timeout","message":"timeout"}}'
        exit 1
        ;;
      close|switch) printf '%s\\n' '{"ok":true}' ;;
      *) exit 70 ;;
    esac
    ;;
  *)
    printf 'fake orca: unsupported command %s\\n' "\$command" >&2
    exit 70
    ;;
esac
EOF
chmod +x "$BIN/orca"

# Started only by the (fake) Orca terminal, never by the wrapper under test.
cat > "$BIN/claude-glm" <<'FAKE'
#!/usr/bin/env bash
echo "fake claude-glm must only be started by Orca, never by the wrapper" >&2
exit 99
FAKE
chmod +x "$BIN/claude-glm"

# Stands in for stage-route.sh where the real table cannot produce the fault:
# --launch names a launcher that is not installed, or the read itself fails.
cat > "$FAKE_STAGE_ROUTE" <<'FAKE'
#!/usr/bin/env bash
set -u
if [ "${DESIGN_TEST_FAKE_ROUTE_EXIT:-0}" != 0 ]; then
  echo "fake stage-route: cannot read the design route" >&2
  exit "$DESIGN_TEST_FAKE_ROUTE_EXIT"
fi
case "$1" in
  --launch) printf '%s\n' "${DESIGN_TEST_FAKE_LAUNCHER:-claude}" --model opus --effort high ;;
  --print)
    case "$3" in
      profile) printf 'claude-glm\n' ;;
      model) printf 'glm-5.4\n' ;;
      effort) printf 'high\n' ;;
    esac
    ;;
esac
FAKE
chmod +x "$FAKE_STAGE_ROUTE"

run_design_session() {
  output=$1
  shift
  DESIGN_SESSION_ROOT=$WORK/runs \
  ISS_ORCA=$BIN/orca \
  ISS_DESIGN_SESSION_POLL=0.01 \
  PATH=$BIN:$PATH \
  DESIGN_SESSION_STAGE_ROUTE=${DESIGN_SESSION_STAGE_ROUTE:-$ROOT/scripts/stage-route.sh} \
  ORCA_LOG=$ORCA_LOG \
  PROMPT_LOG=$PROMPT_LOG \
  CHECK_LOG=$CHECK_LOG \
  DESIGN_TEST_TIMEOUT=${DESIGN_TEST_TIMEOUT:-0} \
  DESIGN_TEST_SESSION_EXIT=${DESIGN_TEST_SESSION_EXIT:-0} \
  DESIGN_TEST_WAIT_EXIT=${DESIGN_TEST_WAIT_EXIT:-0} \
  DESIGN_TEST_RUN_CREATE_FAIL=${DESIGN_TEST_RUN_CREATE_FAIL:-0} \
  DESIGN_TEST_START_FAIL=${DESIGN_TEST_START_FAIL:-0} \
  DESIGN_TEST_CREATE_FAIL=${DESIGN_TEST_CREATE_FAIL:-0} \
  DESIGN_TEST_CREATE_NO_HANDLE=${DESIGN_TEST_CREATE_NO_HANDLE:-0} \
  DESIGN_TEST_CHECK_FAIL=${DESIGN_TEST_CHECK_FAIL:-0} \
  DESIGN_TEST_MISSING_HANDOFF=${DESIGN_TEST_MISSING_HANDOFF:-0} \
  DESIGN_TEST_CHECK_SLEEP=${DESIGN_TEST_CHECK_SLEEP:-0} \
  DESIGN_TEST_UNRELATED_FIRST=${DESIGN_TEST_UNRELATED_FIRST:-0} \
  DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT=${DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT:-0} \
  DESIGN_TEST_REPORT_PATH=${DESIGN_TEST_REPORT_PATH:-} \
  DESIGN_TEST_HANDOFF_FILE=${DESIGN_TEST_HANDOFF_FILE:-} \
  DESIGN_TEST_FAKE_ROUTE_EXIT=${DESIGN_TEST_FAKE_ROUTE_EXIT:-0} \
  DESIGN_TEST_FAKE_LAUNCHER=${DESIGN_TEST_FAKE_LAUNCHER:-claude} \
  ISS_DESIGN_CLOSE_DELAY=0 \
  ORCA_TERMINAL_HANDLE=term_orchestrator \
  ISS_DESIGN_KEEP_SESSION=${ISS_DESIGN_KEEP_SESSION:-} \
  CHECK_ATTEMPTS=$CHECK_ATTEMPTS \
  REPORT_LOG=$REPORT_LOG \
    bash "$SCRIPT" "$@" > "$output" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

# --- the default route: a terminal running claude, adopted by worker-start ------

: > "$ORCA_LOG"
: > "$CHECK_LOG"
run_design_session "$RUN_STDOUT" feature 'Add export button' --timeout 1
expect_exit 0 'feature design session succeeds'
if [ "$(cat "$RUN_STDOUT")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'successful run prints the handoff path'
else
  record FAIL 'successful run prints the handoff path' "stdout=$(cat "$RUN_STDOUT" 2>/dev/null) reported=$(cat "$REPORT_LOG" 2>/dev/null)"
fi
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'run-create create worker-start wait check switch close ' ]; then
  record PASS 'Orca is called once each, in order: run-create, create, worker-start, wait, check, switch, close'
else
  record FAIL 'Orca is called once each, in order: run-create, create, worker-start, wait, check, switch, close' \
    "sequence=[$SEQUENCE]"
fi
expect_file_has 'ARG --objective' 'Run creation has an objective' "$ORCA_LOG"
expect_file_has 'ARG Design session handoff for implement-spec-split' 'Run creation names the repository' "$ORCA_LOG"
expect_file_has 'ARG --json' 'Run creation emits JSON' "$ORCA_LOG"
expect_file_has 'ARG path:' 'the terminal is opened in the repository checkout' "$ORCA_LOG"
expect_file_has 'ARG --title' 'the Design session terminal gets a title' "$ORCA_LOG"
expect_file_has 'ARG Design session feature' 'the title names the kind' "$ORCA_LOG"
expect_file_has 'ARG --focus' 'the Design session tab is focused' "$ORCA_LOG"
expect_file_has 'ARG claude --model opus --effort high; echo $? > ' \
  'terminal create runs the default route: claude with --model opus and --effort high' "$ORCA_LOG"
# The official claude profile alone goes without --dangerously-skip-permissions:
# its TUI asks before push and Bash, the user being present in a Design session.
expect_file_without '--dangerously-skip-permissions' \
  'the official claude route does not skip permission prompts' "$ORCA_LOG"
expect_file_has '/exit-code' 'the typed command records the launcher exit code' "$ORCA_LOG"
expect_file_has 'ARG --terminal' 'worker-start names the terminal' "$ORCA_LOG"
expect_file_has 'ARG term_glm' 'worker-start adopts the handle terminal create returned' "$ORCA_LOG"
expect_file_has 'ARG --run' 'worker-start names its Run' "$ORCA_LOG"
expect_file_has 'ARG run_test_design' 'worker-start targets the created Run id' "$ORCA_LOG"
expect_file_has 'ARG --spec-file' 'worker-start reads the Task from a file' "$ORCA_LOG"
expect_file_has '/prompt.txt' 'the Task file is the run directory prompt' "$ORCA_LOG"
expect_file_has 'ARG --timeout-ms' 'worker-start has a timeout' "$ORCA_LOG"
if grep -qx 'launch' "$ORCA_LOG" || grep -qx 'show' "$ORCA_LOG"; then
  record FAIL 'agent launch and agent show are no longer called'
else
  record PASS 'agent launch and agent show are no longer called'
fi
expect_file_has 'Skill 工具加载上游技能 mattpocock-skills:grill-with-docs' \
  'feature prompt loads its upstream skill with the Skill tool' "$PROMPT_LOG"
expect_file_has 'Add export button' 'feature prompt carries the user topic' "$PROMPT_LOG"
expect_file_has 'to-spec' 'prompt continues to to-spec' "$PROMPT_LOG"
expect_file_has 'to-tickets' 'prompt continues to to-tickets' "$PROMPT_LOG"
expect_file_has '确认拆分' 'to-tickets still asks for confirmation' "$PROMPT_LOG"
expect_file_has '另开 Design session' 'prompt handles oversized context' "$PROMPT_LOG"
expect_file_has 'commit 并 push' 'prompt commits and pushes document changes' "$PROMPT_LOG"
expect_file_has 'handoff.md' 'prompt names the handoff file' "$PROMPT_LOG"
expect_file_has '30 行' 'prompt limits handoff length' "$PROMPT_LOG"
expect_file_has 'worker_done' 'prompt reports the handoff as worker_done' "$PROMPT_LOG"
expect_file_has '--task-id' 'worker_done carries the Task id' "$PROMPT_LOG"
expect_file_has '--report-path' 'worker_done carries the report path' "$PROMPT_LOG"
expect_file_has 'brief-mock.md' 'feature prompt includes the mock brief' "$PROMPT_LOG"
expect_file_has '交给 codex-worker.sh 出页面并自检' \
  'on the claude profile mock pages still go to a worker' "$PROMPT_LOG"
expect_file_without 'send --subject' 'prompt no longer reports with the old send command' "$PROMPT_LOG"
if [ "$(head -n 1 "$PROMPT_LOG")" = '/mattpocock-skills:grill-with-docs' ]; then
  record FAIL 'prompt no longer leads with a slash command the CLI would not expand'
else
  record PASS 'prompt no longer leads with a slash command the CLI would not expand'
fi
expect_file_has '--run' 'handoff wait targets the created Run' "$CHECK_LOG"
expect_file_has 'run_test_design' 'handoff wait names the created Run id' "$CHECK_LOG"
expect_file_has '--wait' 'handoff wait uses Orca wait' "$CHECK_LOG"
expect_file_has '--timeout-ms' 'handoff wait has a timeout' "$CHECK_LOG"
expect_file_has '1000' 'timeout is converted to milliseconds' "$CHECK_LOG"
expect_file_without '--peek' 'the coordinator takes rather than peeks' "$CHECK_LOG"
expect_file_has 'design-session: 本次讨论路由：讨论（design）：claude / opus / high' \
  'the design route is reported on stderr' "$RUN_STDERR"
expect_file_has '由 opus 经 claude 执行' 'the route line says which model runs the session' "$RUN_STDERR"
expect_file_without '全局判断模型开关' 'the old judgment-model line is gone' "$RUN_STDERR"

RUN_DIR_FOUND=
for directory in "$WORK"/runs/implement-spec-split-*-feature; do
  if [ -d "$directory" ]; then
    RUN_DIR_FOUND=$directory
    break
  fi
done
if [ -n "$RUN_DIR_FOUND" ]; then
  record PASS 'feature run creates a stamped run directory'
  expect_file_has "$RUN_DIR_FOUND" 'feature prompt carries the run directory' "$PROMPT_LOG"
  printf 'Add export button' > "$WORK/expected-feature-topic.md"
  expect_same_file "$WORK/expected-feature-topic.md" \
    'feature run persists the inline topic verbatim' \
    "$RUN_DIR_FOUND/topic.md"
  for file in run-create.json launch.json worker-start.json prompt.txt; do
    if [ -s "$RUN_DIR_FOUND/$file" ]; then
      record PASS "run directory keeps $file"
    else
      record FAIL "run directory keeps $file"
    fi
  done
  expect_same_file "$RUN_DIR_FOUND/prompt.txt" 'the Task file is the prompt itself' "$PROMPT_LOG"
else
  record FAIL 'feature run creates a stamped run directory' 'no matching directory'
fi

# --- --attach ------------------------------------------------------------------

make_attach_run() { # dir [handle]
  attach_dir=$1
  mkdir -p "$attach_dir"
  printf '%s\n' '{"ok":true,"result":{"id":"run_test_design"}}' \
    > "$attach_dir/run-create.json"
  printf '%s\n' "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"${2:-term_glm}\",\"tabId\":\"tab_glm\",\"worktreeId\":\"wt-test\"}}}" \
    > "$attach_dir/launch.json"
}

ATTACH_RUN=$WORK/attach-run
make_attach_run "$ATTACH_RUN"
printf 'Previous attach topic' > "$ATTACH_RUN/topic.md"
printf 'Previous attach topic' > "$WORK/expected-attach-topic.md"
: > "$ORCA_LOG"
: > "$CHECK_LOG"
rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_REPORT_PATH=$ATTACH_RUN/handoff.md
run_design_session "$WORK/attach.out" --attach "$ATTACH_RUN" --timeout 1
expect_exit 0 'attach succeeds when check receives the handoff'
if [ "$(cat "$WORK/attach.out")" = "$ATTACH_RUN/handoff.md" ]; then
  record PASS 'attach prints the received handoff path'
else
  record FAIL 'attach prints the received handoff path' "stdout=$(cat "$WORK/attach.out")"
fi
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'wait check switch close ' ]; then
  record PASS 'attach waits on the saved terminal once, checks once, switches and closes'
else
  record FAIL 'attach waits on the saved terminal once, checks once, switches and closes' \
    "sequence=[$SEQUENCE]"
fi
expect_file_has 'ARG term_glm' 'attach waits on and closes the saved terminal handle' "$ORCA_LOG"
expect_file_has 'run_test_design' 'attach waits on the saved Run id' "$CHECK_LOG"
expect_same_file "$WORK/expected-attach-topic.md" 'attach does not rewrite topic.md' \
  "$ATTACH_RUN/topic.md"
expect_file_without '本次讨论路由' 'attach reads no route' "$RUN_STDERR"
unset DESIGN_TEST_REPORT_PATH

ATTACH_EXISTING_RUN=$WORK/attach-existing-run
make_attach_run "$ATTACH_EXISTING_RUN"
printf '%s\n' 'Spec #15, tickets #18.' > "$ATTACH_EXISTING_RUN/handoff.md"
: > "$ORCA_LOG"
: > "$CHECK_LOG"
rm -f "$CHECK_ATTEMPTS"
run_design_session "$WORK/attach-existing.out" --attach "$ATTACH_EXISTING_RUN" --timeout 1
expect_exit 0 'attach accepts an already delivered handoff file'
if [ "$(cat "$WORK/attach-existing.out")" = "$ATTACH_EXISTING_RUN/handoff.md" ]; then
  record PASS 'existing handoff attach prints its path'
else
  record FAIL 'existing handoff attach prints its path' "stdout=$(cat "$WORK/attach-existing.out")"
fi
if [ -e "$CHECK_ATTEMPTS" ]; then
  record FAIL 'existing handoff attach avoids consuming another message' \
    "attempts=$(cat "$CHECK_ATTEMPTS")"
else
  record PASS 'existing handoff attach avoids consuming another message'
fi
expect_file_has 'close' 'existing handoff attach closes the session' "$ORCA_LOG"

# A session started before routes has an agent launch receipt (result.outcome);
# --attach still finds its terminal handle in it.
ATTACH_LEGACY_RUN=$WORK/attach-legacy-run
mkdir -p "$ATTACH_LEGACY_RUN"
printf '%s\n' '{"ok":true,"result":{"id":"run_test_design"}}' \
  > "$ATTACH_LEGACY_RUN/run-create.json"
printf '%s\n' \
  '{"ok":true,"result":{"outcome":{"kind":"structured","sessionId":"orca_session_id:test-design","handle":"term_legacy"},"worktreeId":"wt-test"}}' \
  > "$ATTACH_LEGACY_RUN/launch.json"
: > "$ORCA_LOG"
: > "$CHECK_LOG"
rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_REPORT_PATH=$ATTACH_LEGACY_RUN/handoff.md
run_design_session "$WORK/attach-legacy.out" --attach "$ATTACH_LEGACY_RUN" --timeout 1
expect_exit 0 'attaching to a session started before routes succeeds'
expect_file_has 'ARG term_legacy' 'attach finds the terminal handle in an agent launch receipt' "$ORCA_LOG"
expect_file_has 'close' 'attach closes a pre-routes session too' "$ORCA_LOG"
unset DESIGN_TEST_REPORT_PATH

ATTACH_MISSING_RUN=$WORK/attach-missing-run
make_attach_run "$ATTACH_MISSING_RUN"
rm -f "$ATTACH_MISSING_RUN/launch.json"
run_design_session "$WORK/attach-missing.out" --attach "$ATTACH_MISSING_RUN" --timeout 1
expect_exit 64 'attach with missing metadata returns exit code sixty-four'
expect_file_has 'missing launch.json' 'attach missing metadata names the file' "$RUN_STDERR"

ATTACH_MISSING_CREATE_RUN=$WORK/attach-missing-create-run
make_attach_run "$ATTACH_MISSING_CREATE_RUN"
rm -f "$ATTACH_MISSING_CREATE_RUN/run-create.json"
run_design_session "$WORK/attach-missing-create.out" --attach "$ATTACH_MISSING_CREATE_RUN" --timeout 1
expect_exit 64 'attach without run-create metadata returns exit code sixty-four'
expect_file_has 'missing run-create.json' 'attach missing Run metadata names the file' "$RUN_STDERR"

run_design_session "$WORK/attach-not-found.out" --attach "$WORK/attach-not-found" --timeout 1
expect_exit 64 'attach with a missing run directory returns exit code sixty-four'
expect_file_has 'run directory does not exist' 'attach missing run names the directory' "$RUN_STDERR"

ATTACH_TIMEOUT_RUN=$WORK/attach-timeout-run
make_attach_run "$ATTACH_TIMEOUT_RUN"
rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_TIMEOUT=1
run_design_session "$WORK/attach-timeout.out" --attach "$ATTACH_TIMEOUT_RUN" --timeout 1
expect_exit 5 'attach timeout returns exit code five'
if grep -Fq "design-session.sh --attach $ATTACH_TIMEOUT_RUN --timeout 1" "$RUN_STDERR"; then
  record PASS 'attach timeout prints the resume command'
else
  record FAIL 'attach timeout prints the resume command' "stderr=$(cat "$RUN_STDERR")"
fi
TIMEOUT_ATTACH_DIR=$(sed -n 's/^bash .*design-session\.sh --attach \(.*\) --timeout 1$/\1/p' "$RUN_STDERR")
if [ -n "$TIMEOUT_ATTACH_DIR" ] && [ -d "$TIMEOUT_ATTACH_DIR" ]; then
  record PASS 'timeout stderr includes a usable attach command'
else
  record FAIL 'timeout stderr includes a usable attach command' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_TIMEOUT

# --- topic files ----------------------------------------------------------------

cat > "$TOPIC_FILE" <<'TOPIC'
Topic with "quotes", `backticks`, and $(pwd)
second line
TOPIC
: > "$ORCA_LOG"
: > "$PROMPT_LOG"
run_design_session "$WORK/topic-file.out" feature --topic-file "$TOPIC_FILE" \
  --timeout 1
expect_exit 0 'topic file design session succeeds'
expect_file_has 'Topic with "quotes", `backticks`, and $(pwd)' \
  'topic file preserves shell characters' "$PROMPT_LOG"
expect_file_has 'second line' 'topic file preserves newlines' "$PROMPT_LOG"
TOPIC_FILE_RUN_DIR=$(dirname "$(cat "$REPORT_LOG")")
expect_same_file "$TOPIC_FILE" 'topic file run preserves the topic verbatim' \
  "$TOPIC_FILE_RUN_DIR/topic.md"

# --- pending session reminder ---------------------------------------------------

# A recent un-handed session for this repository warns before a new launch.
RECENT_DATE=$(date +%Y%m%d)
RECENT_DISPLAY="${RECENT_DATE:0:4}-${RECENT_DATE:4:2}-${RECENT_DATE:6:2}"
PENDING_DIR=$WORK/runs/implement-spec-split-$RECENT_DATE-0901-feature
mkdir -p "$PENDING_DIR"
printf '%s\n' 'Old feature topic' > "$PENDING_DIR/topic.md"
run_design_session "$WORK/pending-reminder.out" feature 'Fresh feature' --timeout 1
expect_exit 0 'pending session reminder still launches successfully'
if [ "$(cat "$WORK/pending-reminder.out")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'pending session reminder run still prints the handoff path'
else
  record FAIL 'pending session reminder run still prints the handoff path' \
    "stdout=$(cat "$WORK/pending-reminder.out")"
fi
expect_file_has '提醒：本仓库还有 1 个 Design session 没交接：' \
  'pending session reminder header is printed' "$RUN_STDERR"
expect_file_has "- $RECENT_DISPLAY 09:01 feature Old feature topic" \
  'pending session reminder lists the session' "$RUN_STDERR"
expect_file_has "续等：design-session.sh --attach $PENDING_DIR" \
  'pending session reminder shows the attach command' "$RUN_STDERR"
# Mark this scratch session handled so later launches stay quiet.
printf '%s\n' 'Spec #15, tickets #18.' > "$PENDING_DIR/handoff.md"

# Old, already-handed and other-repository sessions do not warn.
OLD_DATE=$(date -v-8d +%Y%m%d 2>/dev/null || date -d '8 days ago' +%Y%m%d)
OLD_DIR=$WORK/runs/implement-spec-split-$OLD_DATE-0902-feature
mkdir -p "$OLD_DIR"
printf '%s\n' 'Ancient topic' > "$OLD_DIR/topic.md"
OTHER_REPO_DIR=$WORK/runs/spec-999-$RECENT_DATE-0903-map
mkdir -p "$OTHER_REPO_DIR"
printf '%s\n' 'Other repo topic' > "$OTHER_REPO_DIR/topic.md"
run_design_session "$WORK/no-reminder.out" feature 'Clean feature' --timeout 1
expect_exit 0 'quiet launch succeeds'
if grep -Fq '提醒：' "$RUN_STDERR"; then
  record FAIL 'old, handed-over and other-repo sessions do not remind' \
    "stderr=$(cat "$RUN_STDERR")"
else
  record PASS 'old, handed-over and other-repo sessions do not remind'
fi

# --- usage ----------------------------------------------------------------------

run_design_session "$WORK/missing-topic-file-value.out" feature --topic-file \
  --timeout 1
expect_exit 64 'missing topic-file value is a usage error'
expect_file_has '--topic-file needs a value' \
  'missing topic-file value names the option' "$RUN_STDERR"

: > "$EMPTY_TOPIC_FILE"
run_design_session "$WORK/empty-topic-file.out" feature \
  --topic-file "$EMPTY_TOPIC_FILE" --timeout 1
expect_exit 64 'empty topic file is a usage error'

bash "$SCRIPT" --help > "$WORK/help.out" 2> "$WORK/help.err"
RUN_EXIT=$?
expect_exit 0 'help succeeds without a kind and topic'
expect_file_has 'Usage: design-session.sh' 'help prints the usage' "$WORK/help.out"
expect_file_has '--topic-file <path>' 'help documents topic files' "$WORK/help.out"
expect_file_has '--attach <run-dir>' 'help documents attach mode' "$WORK/help.out"

DESIGN_SESSION_ROOT=$WORK/runs ISS_ORCA=$BIN/orca \
  ISS_DESIGN_SESSION_POLL=0.01 ORCA_LOG=$ORCA_LOG PROMPT_LOG=$PROMPT_LOG \
  CHECK_LOG=$CHECK_LOG DESIGN_TEST_TIMEOUT=0 DESIGN_TEST_SESSION_EXIT=0 \
  DESIGN_TEST_CREATE_FAIL=0 DESIGN_TEST_CHECK_FAIL=0 \
  DESIGN_TEST_MISSING_HANDOFF=0 \
  bash "$SCRIPT" feature x --timeout > "$WORK/missing-timeout-value.out" \
  2> "$RUN_STDERR" &
BOUNDED_PID=$!
BOUNDED_EXITED=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ! kill -0 "$BOUNDED_PID" 2>/dev/null; then
    BOUNDED_EXITED=1
    break
  fi
  sleep 0.05
done
if [ "$BOUNDED_EXITED" = 1 ]; then
  wait "$BOUNDED_PID"
  RUN_EXIT=$?
else
  kill "$BOUNDED_PID" 2>/dev/null || true
  wait "$BOUNDED_PID" 2>/dev/null || true
  RUN_EXIT=124
fi
expect_exit 64 'missing timeout value is a usage error'
expect_file_has '--timeout needs a value' \
  'missing timeout value names the option' "$RUN_STDERR"

# --- map ------------------------------------------------------------------------

: > "$ORCA_LOG"
: > "$PROMPT_LOG"
: > "$CHECK_LOG"
run_design_session "$WORK/map.out" map 'Refactor authentication module' --timeout 1
expect_exit 0 'map design session succeeds'
expect_file_has 'Skill 工具加载上游技能 mattpocock-skills:wayfinder' \
  'map prompt loads wayfinder with the Skill tool' "$PROMPT_LOG"
expect_file_has 'ARG Design session map' 'the map terminal title names the kind' "$ORCA_LOG"
expect_file_has 'Refactor authentication module' 'map prompt carries the user topic' "$PROMPT_LOG"
expect_file_has '先到这' 'map prompt allows an early handoff' "$PROMPT_LOG"
expect_file_has '地图状态和下一步' 'early handoff describes map state' "$PROMPT_LOG"
expect_file_has '首行必须原样写「提前交接：先到这」' \
  'map prompt makes an early handoff open with the marker' "$PROMPT_LOG"
if grep -Fq 'mattpocock-skills:grill-with-docs' "$PROMPT_LOG"; then
  record FAIL 'map prompt does not use the feature skill'
else
  record PASS 'map prompt does not use the feature skill'
fi
if grep -Fq '提前交接' "$RUN_STDERR"; then
  record FAIL 'a complete map handoff is not reported as early' \
    "stderr=$(cat "$RUN_STDERR")"
else
  record PASS 'a complete map handoff is not reported as early'
fi

# An early map handoff (the user said 先到这) opens with a fixed marker line;
# the wrapper reports it on stderr so /grill-map can leave find-next alone.
EARLY_HANDOFF_FILE=$WORK/early-handoff.md
printf '%s\n' '提前交接：先到这' '地图状态：地图 #12 的前沿还剩 3 张决策票。' \
  '下一步：继续 /grill-map 12。' > "$EARLY_HANDOFF_FILE"
DESIGN_TEST_HANDOFF_FILE=$EARLY_HANDOFF_FILE
run_design_session "$WORK/map-early.out" map 'Early map' --timeout 1
expect_exit 0 'early map handoff succeeds'
if [ "$(cat "$WORK/map-early.out")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'early map handoff still prints the handoff path'
else
  record FAIL 'early map handoff still prints the handoff path' \
    "stdout=$(cat "$WORK/map-early.out")"
fi
expect_file_has 'design-session: 提前交接：handoff.md 首行是「提前交接：先到这」' \
  'early map handoff is reported on stderr' "$RUN_STDERR"
unset DESIGN_TEST_HANDOFF_FILE

# A heading marker, a half-width colon or a closing period must not hide the
# marker: a missed early handoff would start find-next against the user's wish.
DECORATED_HANDOFF_FILE=$WORK/decorated-handoff.md
printf '%s\n' '### 提前交接:先到这。' '地图状态：刚画完 Destination。' \
  '下一步：继续讨论 Map frontier。' > "$DECORATED_HANDOFF_FILE"
DESIGN_TEST_HANDOFF_FILE=$DECORATED_HANDOFF_FILE
run_design_session "$WORK/map-decorated.out" map 'Decorated early map' --timeout 1
expect_exit 0 'decorated early map handoff succeeds'
expect_file_has 'design-session: 提前交接：' \
  'a decorated marker line still counts as an early handoff' "$RUN_STDERR"
unset DESIGN_TEST_HANDOFF_FILE

# Only the first line counts: a marker further down leaves the call to the
# Orchestrator, which then has to say it cannot tell.
SECOND_LINE_FILE=$WORK/second-line-handoff.md
printf '%s\n' '规格：#15' '提前交接：先到这' > "$SECOND_LINE_FILE"
DESIGN_TEST_HANDOFF_FILE=$SECOND_LINE_FILE
run_design_session "$WORK/map-second-line.out" map 'Second line map' --timeout 1
expect_exit 0 'a handoff with the marker on its second line succeeds'
if grep -Fq '提前交接' "$RUN_STDERR"; then
  record FAIL 'the marker counts only on the first line' \
    "stderr=$(cat "$RUN_STDERR")"
else
  record PASS 'the marker counts only on the first line'
fi
unset DESIGN_TEST_HANDOFF_FILE

# --attach reads a handoff that was already delivered; it reports the same.
ATTACH_EARLY_RUN=$WORK/attach-early-run
make_attach_run "$ATTACH_EARLY_RUN"
cp "$EARLY_HANDOFF_FILE" "$ATTACH_EARLY_RUN/handoff.md"
rm -f "$CHECK_ATTEMPTS"
run_design_session "$WORK/attach-early.out" --attach "$ATTACH_EARLY_RUN" --timeout 1
expect_exit 0 'attaching to an early handoff succeeds'
expect_file_has 'design-session: 提前交接：' \
  'attaching reports the early handoff too' "$RUN_STDERR"
if [ -e "$CHECK_ATTEMPTS" ]; then
  record FAIL 'attaching to an early handoff consumes no message'
else
  record PASS 'attaching to an early handoff consumes no message'
fi

# --- the wait -------------------------------------------------------------------

: > "$ORCA_LOG"
: > "$CHECK_LOG"
rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_UNRELATED_FIRST=1
run_design_session "$WORK/unrelated-message.out" feature 'Noisy feature' --timeout 2
expect_exit 0 'unrelated message is ignored while waiting'
if [ "$(cat "$CHECK_ATTEMPTS" 2>/dev/null)" -ge 2 ]; then
  record PASS 'unrelated message was consumed by check'
else
  record FAIL 'unrelated message was consumed by check' "attempts=$(cat "$CHECK_ATTEMPTS" 2>/dev/null)"
fi
WAIT_CALLS=$(grep -c '^wait$' "$ORCA_LOG")
if [ "$WAIT_CALLS" = 1 ]; then
  record PASS 'a second check does not start a second terminal wait'
else
  record FAIL 'a second check does not start a second terminal wait' "wait calls=$WAIT_CALLS"
fi
unset DESIGN_TEST_UNRELATED_FIRST

rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT=1
run_design_session "$WORK/wrong-report-timeout.out" feature 'Wrong report' --timeout 2
expect_exit 5 'wrong reportPath waits until timeout'
if grep -Fq '超时' "$RUN_STDERR"; then
  record PASS 'wrong reportPath timeout is reported as timeout'
else
  record FAIL 'wrong reportPath timeout is reported as timeout' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT

DESIGN_TEST_TIMEOUT=1
run_design_session "$WORK/timeout.out" feature 'Slow feature' --timeout 1
expect_exit 5 'wait timeout returns exit code five'
if grep -Fq '超时' "$RUN_STDERR"; then
  record PASS 'timeout message is reported'
else
  record FAIL 'timeout message is reported' "stderr=$(cat "$RUN_STDERR")"
fi
INITIAL_TIMEOUT_ATTACH_DIR=$(sed -n 's/^bash .*design-session\.sh --attach \(.*\) --timeout 1$/\1/p' "$RUN_STDERR")
if [ -n "$INITIAL_TIMEOUT_ATTACH_DIR" ] && [ -d "$INITIAL_TIMEOUT_ATTACH_DIR" ]; then
  record PASS 'initial timeout stderr includes a usable attach command'
else
  record FAIL 'initial timeout stderr includes a usable attach command' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_TIMEOUT

# The typed command's exit code is how an ended session is noticed.
DESIGN_TEST_SESSION_EXIT=1
: > "$ORCA_LOG"
run_design_session "$WORK/session-exit.out" feature 'Closed session' --timeout 5
expect_exit 7 'session exit returns exit code seven'
expect_file_has '启动命令已退出，退出码 0' 'the launcher exit code is reported' "$RUN_STDERR"
if grep -Fq 'Design session 已结束' "$RUN_STDERR"; then
  record PASS 'session exit message is reported'
else
  record FAIL 'session exit message is reported' "stderr=$(cat "$RUN_STDERR")"
fi
if grep -qx 'show' "$ORCA_LOG"; then
  record FAIL 'a session exit is not watched through agent show' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a session exit is not watched through agent show'
fi
unset DESIGN_TEST_SESSION_EXIT

# So is the one terminal wait, when the launcher leaves no exit code behind.
# The fake check is held back past the wait so that no handoff arrives first.
DESIGN_TEST_WAIT_EXIT=1
DESIGN_TEST_CHECK_SLEEP=1
run_design_session "$WORK/terminal-exit.out" feature 'Exited terminal' --timeout 5
expect_exit 7 'a session whose terminal exits without a handoff returns exit code seven'
if grep -Fq 'Design session 已结束' "$RUN_STDERR"; then
  record PASS 'terminal exit message is reported'
else
  record FAIL 'terminal exit message is reported' "stderr=$(cat "$RUN_STDERR")"
fi
if grep -Fq '启动命令已退出' "$RUN_STDERR"; then
  record FAIL 'a terminal exit without an exit code file does not claim one'
else
  record PASS 'a terminal exit without an exit code file does not claim one'
fi
unset DESIGN_TEST_CHECK_SLEEP

# The handoff wins when the session closes right after sending it.
run_design_session "$WORK/closed-after-handoff.out" feature 'Closed after report' --timeout 5
expect_exit 0 'handoff wins when the session closes immediately after sending'
if [ "$(cat "$WORK/closed-after-handoff.out")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'closed-after-handoff run still prints the report path'
else
  record FAIL 'closed-after-handoff run still prints the report path' \
    "stdout=$(cat "$WORK/closed-after-handoff.out")"
fi
unset DESIGN_TEST_WAIT_EXIT

# Keep the session alive across several polls: the monitor must not mistake
# anything for an exit while the launcher is still running.
DESIGN_TEST_CHECK_SLEEP=0.5
: > "$ORCA_LOG"
run_design_session "$WORK/terminal.out" feature 'Terminal session' --timeout 5
expect_exit 0 'design session succeeds while the launcher keeps running'
expect_file_has 'close' 'handoff closes the Design session terminal' "$ORCA_LOG"
expect_file_has 'term_orchestrator' 'handoff switches back to the Orchestrator terminal' "$ORCA_LOG"
: > "$ORCA_LOG"
ISS_DESIGN_KEEP_SESSION=1
run_design_session "$WORK/terminal-keep.out" feature 'Keep session' --timeout 5
expect_exit 0 'design session with keep succeeds'
if grep -qx 'close' "$ORCA_LOG"; then
  record FAIL 'ISS_DESIGN_KEEP_SESSION=1 leaves the Design session open' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'ISS_DESIGN_KEEP_SESSION=1 leaves the Design session open'
fi
unset ISS_DESIGN_KEEP_SESSION
unset DESIGN_TEST_CHECK_SLEEP

# --- Orca failures --------------------------------------------------------------

DESIGN_TEST_RUN_CREATE_FAIL=1
: > "$ORCA_LOG"
run_design_session "$WORK/run-create-fail.out" feature x --timeout 1
expect_exit 6 'run-create failure returns exit code six'
if grep -Fq 'fake orca run-create failed' "$RUN_STDERR"; then
  record PASS 'run-create failure is surfaced'
else
  record FAIL 'run-create failure is surfaced' "stderr=$(cat "$RUN_STDERR")"
fi
if grep -qx 'create' "$ORCA_LOG"; then
  record FAIL 'a failed run-create opens no terminal'
else
  record PASS 'a failed run-create opens no terminal'
fi
unset DESIGN_TEST_RUN_CREATE_FAIL

DESIGN_TEST_CREATE_FAIL=1
: > "$ORCA_LOG"
run_design_session "$WORK/create-fail.out" feature x --timeout 1
expect_exit 6 'terminal create failure returns exit code six'
if grep -Fq 'orca terminal create failed' "$RUN_STDERR"; then
  record PASS 'terminal create failure is surfaced'
else
  record FAIL 'terminal create failure is surfaced' "stderr=$(cat "$RUN_STDERR")"
fi
if grep -qx 'worker-start' "$ORCA_LOG"; then
  record FAIL 'a failed terminal create adopts nothing'
else
  record PASS 'a failed terminal create adopts nothing'
fi
unset DESIGN_TEST_CREATE_FAIL

DESIGN_TEST_CREATE_NO_HANDLE=1
: > "$ORCA_LOG"
run_design_session "$WORK/create-no-handle.out" feature x --timeout 1
expect_exit 6 'terminal create without a handle returns exit code six'
expect_file_has 'no terminal handle' 'the missing terminal handle is reported' "$RUN_STDERR"
if grep -qx 'worker-start' "$ORCA_LOG"; then
  record FAIL 'a terminal without a handle is not adopted'
else
  record PASS 'a terminal without a handle is not adopted'
fi
unset DESIGN_TEST_CREATE_NO_HANDLE

DESIGN_TEST_START_FAIL=1
: > "$ORCA_LOG"
run_design_session "$WORK/start-fail.out" feature x --timeout 1
expect_exit 6 'worker-start failure returns exit code six'
if grep -Fq 'orca orchestration worker-start failed' "$RUN_STDERR"; then
  record PASS 'worker-start failure is surfaced'
else
  record FAIL 'worker-start failure is surfaced' "stderr=$(cat "$RUN_STDERR")"
fi
expect_file_has 'term_glm' 'a failed worker-start names the terminal it left open' "$RUN_STDERR"
unset DESIGN_TEST_START_FAIL

DESIGN_TEST_CHECK_FAIL=1
run_design_session "$WORK/check-fail.out" feature x --timeout 1
expect_exit 6 'check failure returns exit code six'
if grep -Fq 'fake orca check failed' "$RUN_STDERR"; then
  record PASS 'check failure is surfaced'
else
  record FAIL 'check failure is surfaced' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_CHECK_FAIL

DESIGN_TEST_MISSING_HANDOFF=1
run_design_session "$WORK/missing-handoff.out" feature x --timeout 1
expect_exit 6 'missing handoff returns exit code six'
if grep -Fq 'handoff report is missing' "$RUN_STDERR"; then
  record PASS 'missing handoff names the report'
else
  record FAIL 'missing handoff names the report' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_MISSING_HANDOFF

# --- the design route ------------------------------------------------------------

# Switched to claude-glm / glm-5.4 / high, the terminal runs that launcher with
# that model (in the GLM launchers' own [1m] form) and effort, and the session
# makes mock pages itself.
set_design_route claude-glm/glm-5.4/high
rm -f "$CHECK_ATTEMPTS"
: > "$ORCA_LOG"
: > "$PROMPT_LOG"
run_design_session "$WORK/switch-on.out" map 'Switched map' --timeout 5
expect_exit 0 'a claude-glm design route opens a Design session'
expect_file_has 'ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high; echo $? > ' \
  'the typed command runs the switched launcher with --dangerously-skip-permissions, its model, quoted for the terminal shell, and effort' \
  "$ORCA_LOG"
expect_file_has 'design-session: 本次讨论路由：讨论（design）：claude-glm / glm-5.4 / high' \
  'the switched route is reported on stderr' "$RUN_STDERR"
expect_file_has '由 glm-5.4 经 claude-glm 执行' 'the route line names the switched model and launcher' "$RUN_STDERR"
expect_file_has 'mattpocock-skills:wayfinder' 'switched prompt names wayfinder' "$PROMPT_LOG"
expect_file_has 'mockit_submit' 'switched prompt still submits mocks' "$PROMPT_LOG"
expect_file_has '自己做候选页面和自检脚本' \
  'a non-claude profile has the session make mock pages itself' "$PROMPT_LOG"
expect_file_has '/mock/check.mjs' \
  'a non-claude prompt names its self-check script' "$PROMPT_LOG"
if grep -Fq 'codex-worker.sh' "$PROMPT_LOG"; then
  record FAIL 'a non-claude profile does not hand mock pages to a worker'
else
  record PASS 'a non-claude profile does not hand mock pages to a worker'
fi
expect_file_has 'term_orchestrator' 'a switched handoff switches back to the Orchestrator' "$ORCA_LOG"
SWITCHED_RUN_DIR=$(dirname "$(awk '$0 == "ARG --spec-file" { getline; sub(/^ARG /, ""); print; exit }' "$ORCA_LOG")")
if [ "$(cat "$WORK/switch-on.out")" = "$SWITCHED_RUN_DIR/handoff.md" ]; then
  record PASS 'a switched route prints the handoff path'
else
  record FAIL 'a switched route prints the handoff path' "stdout=$(cat "$WORK/switch-on.out")"
fi

# Any effort travels the same way.
set_design_route claude-flash/glm-5.4/medium
: > "$ORCA_LOG"
run_design_session "$WORK/switch-flash.out" feature 'Flash session' --timeout 3
expect_exit 0 'a claude-flash design route opens a Design session'
expect_file_has 'ARG claude-flash --dangerously-skip-permissions --model glm-5.4\[1m\] --effort medium; echo $? > ' \
  'the switched launcher, model and effort are all on the typed command' "$ORCA_LOG"
expect_file_has '本次讨论路由：讨论（design）：claude-flash / glm-5.4 / medium' \
  'the claude-flash route is reported on stderr' "$RUN_STDERR"
expect_file_has '自己做候选页面和自检脚本' \
  'claude-flash, like every non-claude profile, makes mock pages itself' "$PROMPT_LOG"

# Back on the default, so is the typed command, without the flag again.
set_design_route claude/opus/high
: > "$ORCA_LOG"
run_design_session "$WORK/switch-back.out" feature 'Back on opus' --timeout 3
expect_exit 0 'the default design route opens a Design session again'
expect_file_has 'ARG claude --model opus --effort high; echo $? > ' \
  'switching back restores claude with --model opus and --effort high' "$ORCA_LOG"
expect_file_without '--dangerously-skip-permissions' \
  'switching back to the claude profile drops --dangerously-skip-permissions' "$ORCA_LOG"
expect_file_has '交给 codex-worker.sh 出页面并自检' \
  'the claude profile hands mock pages to a worker again' "$PROMPT_LOG"

# Only the design stage is consulted: a switched review leaves the Design
# session on its own route.
"$ROOT/scripts/stage-route.sh" use review=claude-glm/glm-5.4/high >/dev/null 2>&1
: > "$ORCA_LOG"
run_design_session "$WORK/switch-review-only.out" feature 'Review only' --timeout 3
expect_exit 0 'a switched review alone launches a Design session'
expect_file_has 'ARG claude --model opus --effort high; echo $? > ' \
  'a switched review alone leaves the design route alone' "$ORCA_LOG"
"$ROOT/scripts/stage-route.sh" use review=claude/opus/high >/dev/null 2>&1

# A route change reaches the next new session only: --attach keeps waiting for
# the session it was given and reads no route.
DESIGN_TEST_TIMEOUT=1
run_design_session "$WORK/before-switch.out" feature 'Before switch' --timeout 1
expect_exit 5 'the session before a route change times out first'
BEFORE_SWITCH_DIR=$(sed -n 's/^bash .*design-session\.sh --attach \(.*\) --timeout 1$/\1/p' "$RUN_STDERR")
unset DESIGN_TEST_TIMEOUT
if [ -n "$BEFORE_SWITCH_DIR" ] && [ -d "$BEFORE_SWITCH_DIR" ]; then
  rm -f "$BEFORE_SWITCH_DIR/exit-code"
  set_design_route claude-glm/glm-5.4/high
  : > "$ORCA_LOG"
  run_design_session "$WORK/after-switch-attach.out" --attach "$BEFORE_SWITCH_DIR" --timeout 5
  expect_exit 0 'attaching after a route change succeeds'
  SEQUENCE=$(orca_sequence)
  if [ "$SEQUENCE" = 'wait check switch close ' ]; then
    record PASS 'attaching after a route change launches nothing on the new route'
  else
    record FAIL 'attaching after a route change launches nothing on the new route' "sequence=[$SEQUENCE]"
  fi
  expect_file_has 'ARG term_glm' 'attaching after a route change follows the session it was given' "$ORCA_LOG"
  expect_file_without '本次讨论路由' 'attaching after a route change reports no route' "$RUN_STDERR"
else
  record FAIL 'the timed-out run before a route change is found' "stderr=$(cat "$RUN_STDERR")"
fi
set_design_route claude/opus/high

# The route's launcher is not installed: nothing opens, exit 6.
: > "$ORCA_LOG"
DESIGN_SESSION_STAGE_ROUTE=$FAKE_STAGE_ROUTE
DESIGN_TEST_FAKE_LAUNCHER=iss-missing-launcher
run_design_session "$WORK/switch-no-launcher.out" feature x --timeout 3
expect_exit 6 'a route whose launcher is not installed returns exit code six'
expect_file_has 'iss-missing-launcher' 'the missing launcher is named' "$RUN_STDERR"
expect_file_has 'claude-glm / glm-5.4 / high' 'the missing launcher is reported against its route' "$RUN_STDERR"
unset DESIGN_TEST_FAKE_LAUNCHER
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'a missing launcher calls Orca not at all' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a missing launcher calls Orca not at all'
fi

# The route cannot be read: a usage error, and no session starts with an empty
# model.
DESIGN_TEST_FAKE_ROUTE_EXIT=66
run_design_session "$WORK/route-unreadable.out" feature x --timeout 3
expect_exit 64 'an unreadable design route is a usage error'
expect_file_has 'design route' 'the unreadable route is named' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'an unreadable route calls Orca not at all' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'an unreadable route calls Orca not at all'
fi
unset DESIGN_TEST_FAKE_ROUTE_EXIT DESIGN_SESSION_STAGE_ROUTE

# --- the two thin skills and the docs --------------------------------------------

FEATURE_SKILL=$ROOT/grill-feature/SKILL.md
MAP_SKILL=$ROOT/grill-map/SKILL.md
expect_file_has 'name: grill-feature' 'feature skill has its name' "$FEATURE_SKILL"
expect_file_has '小功能' 'feature description mentions small features' "$FEATURE_SKILL"
expect_file_has 'grill 一下这个功能' 'feature description carries its trigger phrase' "$FEATURE_SKILL"
expect_file_has 'design-session.sh feature' 'feature skill calls the feature wrapper' "$FEATURE_SKILL"
expect_file_has 'Use the Write tool' 'feature skill writes topic files safely' "$FEATURE_SKILL"
expect_file_has '--topic-file' 'feature skill passes topic files' "$FEATURE_SKILL"
expect_file_has 'run_in_background: true' 'feature skill waits in the background' "$FEATURE_SKILL"
expect_file_has 'timeout: 7500000ms' 'feature skill timeout exceeds the script cap' "$FEATURE_SKILL"
expect_file_has '7200000ms' 'feature skill documents the script cap' "$FEATURE_SKILL"
expect_file_has '--attach' 'feature skill can resume a timed-out wait' "$FEATURE_SKILL"
expect_file_has 'completion notification' 'feature skill waits for completion notification' "$FEATURE_SKILL"
expect_file_has 'handoff.md' 'feature skill returns through the handoff' "$FEATURE_SKILL"
expect_file_has '提醒：本仓库还有' \
  'feature skill relays pending session reminders' "$FEATURE_SKILL"
expect_file_has 'invoke the `find-next` skill' 'feature skill hands over to find-next' "$FEATURE_SKILL"
expect_file_has '推进模式' 'feature skill hands over in find-next advance mode' "$FEATURE_SKILL"
expect_file_has 'find-next-supervise' 'feature skill keeps the supervise lock rule' "$FEATURE_SKILL"
if grep -Fq 'Orchestrator todo items in this session' "$FEATURE_SKILL" ||
   grep -Fq 'launch-wave.sh --repo' "$FEATURE_SKILL"; then
  record FAIL 'feature skill no longer runs the handoff todos or launch-wave itself'
else
  record PASS 'feature skill no longer runs the handoff todos or launch-wave itself'
fi
expect_file_has 'name: grill-map' 'map skill has its name' "$MAP_SKILL"
expect_file_has '大模块' 'map description mentions large modules' "$MAP_SKILL"
expect_file_has 'wayfinder' 'map description carries wayfinder trigger' "$MAP_SKILL"
expect_file_has '先到这' 'map description carries its early-stop trigger' "$MAP_SKILL"
expect_file_has 'design-session.sh map' 'map skill calls the map wrapper' "$MAP_SKILL"
expect_file_has 'Use the Write tool' 'map skill writes topic files safely' "$MAP_SKILL"
expect_file_has '--topic-file' 'map skill passes topic files' "$MAP_SKILL"
expect_file_has 'run_in_background: true' 'map skill waits in the background' "$MAP_SKILL"
expect_file_has 'timeout: 7500000ms' 'map skill timeout exceeds the script cap' "$MAP_SKILL"
expect_file_has '7200000ms' 'map skill documents the script cap' "$MAP_SKILL"
expect_file_has '--attach' 'map skill can resume a timed-out wait' "$MAP_SKILL"
expect_file_has 'completion notification' 'map skill waits for completion notification' "$MAP_SKILL"
expect_file_has 'handoff.md' 'map skill returns through the handoff' "$MAP_SKILL"
expect_file_has '提醒：本仓库还有' \
  'map skill relays pending session reminders' "$MAP_SKILL"
expect_file_has 'invoke the `find-next` skill' 'map skill hands over to find-next' "$MAP_SKILL"
expect_file_has '推进模式' 'map skill hands over in find-next advance mode' "$MAP_SKILL"
expect_file_has 'find-next-supervise' 'map skill keeps the supervise lock rule' "$MAP_SKILL"
if grep -Fq 'Orchestrator todo items in this session' "$MAP_SKILL" ||
   grep -Fq 'launch-wave.sh --repo' "$MAP_SKILL"; then
  record FAIL 'map skill no longer runs the handoff todos or launch-wave itself'
else
  record PASS 'map skill no longer runs the handoff todos or launch-wave itself'
fi
expect_file_has '提前交接' 'map skill recognises the reported early handoff' "$MAP_SKILL"
expect_file_has 'Do not hand off to find-next' \
  'map skill does not hand off after an early handoff' "$MAP_SKILL"
expect_file_has 'map state and next step' \
  'map skill relays map state and next step on an early handoff' "$MAP_SKILL"
expect_file_has 'you cannot tell' \
  'map skill treats an undecidable handoff as early' "$MAP_SKILL"

# Step 4 relays the design route line; step 7 routes through /grill-router.
for skill in "$FEATURE_SKILL" "$MAP_SKILL"; do
  label=$(basename "$(dirname "$skill")")
  expect_file_has '本次讨论路由：' "$label step 4 watches for the route line" "$skill"
  expect_file_has 'say so, once' "$label step 4 relays the route once" "$skill"
  if grep -Fq '全局判断模型开关' "$skill"; then
    record FAIL "$label no longer watches the judgment-model switch"
  else
    record PASS "$label no longer watches the judgment-model switch"
  fi
  if grep -Fq '官方订阅上的 Design session' "$skill"; then
    record FAIL "$label description no longer promises an official-subscription session"
  else
    record PASS "$label description no longer promises an official-subscription session"
  fi
  expect_file_has '/grill-router use design=claude-glm/glm-5.4/high' \
    "$label step 7 offers the /grill-router way on" "$skill"
  if grep -Fq '/judgment-model' "$skill" || grep -Fq 'judgment-model.sh' "$skill"; then
    record FAIL "$label no longer names the judgment-model switch"
  else
    record PASS "$label no longer names the judgment-model switch"
  fi
done

expect_file_has 'grill-feature' 'README documents the feature skill symlink' "$ROOT/README.md"
expect_file_has 'grill-map' 'README documents the map skill symlink' "$ROOT/README.md"
expect_file_has 'grill-feature' 'setup documents the feature skill symlink' "$ROOT/docs/setup.md"
expect_file_has 'grill-map' 'setup documents the map skill symlink' "$ROOT/docs/setup.md"
expect_file_has 'bash scripts/test-design-session.sh' 'MAINTAINING registers the new test' "$ROOT/MAINTAINING.md"
if grep -Fq 'bash scripts/test-judgment-model.sh' "$ROOT/MAINTAINING.md"; then
  record FAIL 'MAINTAINING no longer registers the deleted switch test'
else
  record PASS 'MAINTAINING no longer registers the deleted switch test'
fi
expect_file_has 'grill-feature / grill-map 收到 handoff 后自动接 find-next 推进模式' \
  'MAINTAINING records the find-next hand-over decision' "$ROOT/MAINTAINING.md"
expect_file_has 'scripts/stage-route.sh' 'README documents the Stage route table' "$ROOT/README.md"
expect_file_has 'opens a Design session' 'README uses the Design session term' "$ROOT/README.md"
if grep -RInE 'official-Opus session|Opus session' \
  "$ROOT/README.md" "$ROOT/grill-feature/SKILL.md" "$ROOT/grill-map/SKILL.md" \
  "$ROOT/scripts/design-session.sh"; then
  record FAIL 'Design session docs avoid the Opus session term'
else
  record PASS 'Design session docs avoid the Opus session term'
fi
# MAINTAINING's self-test entry describes the launch as it now happens.
MAINTAINING_DESIGN_LINE=$(grep -F -- '- **Design session**：' "$ROOT/MAINTAINING.md")
if [ -n "$MAINTAINING_DESIGN_LINE" ]; then
  record PASS 'MAINTAINING has a Design session self-test entry'
  expect_file_has 'worker-start' 'MAINTAINING self-test entry names the adoption' "$ROOT/MAINTAINING.md"
  if grep -Fq -- '--agent claude' <<< "$MAINTAINING_DESIGN_LINE"; then
    record FAIL 'MAINTAINING self-test entry no longer names --agent claude'
  else
    record PASS 'MAINTAINING self-test entry no longer names --agent claude'
  fi
  if grep -Fq 'ISS_JUDGMENT_MODEL_FILE' <<< "$MAINTAINING_DESIGN_LINE"; then
    record FAIL 'MAINTAINING self-test entry no longer names the old switch file'
  else
    record PASS 'MAINTAINING self-test entry no longer names the old switch file'
  fi
else
  record FAIL 'MAINTAINING has a Design session self-test entry'
fi
# The script leaves the Orca executable to the library and keeps none of its own.
if grep -Fq 'ISS_ORCA' "$ROOT/scripts/design-session.sh"; then
  record FAIL 'design-session.sh leaves ISS_ORCA to the library'
else
  record PASS 'design-session.sh leaves ISS_ORCA to the library'
fi
if grep -Eq '"\$ORCA"|\$\{ORCA\}|\$ORCA ' "$ROOT/scripts/design-session.sh"; then
  record FAIL 'design-session.sh keeps no Orca executable of its own'
else
  record PASS 'design-session.sh keeps no Orca executable of its own'
fi
if grep -Fq 'ISS_JUDGMENT_MODEL_FILE' "$ROOT/scripts/design-session.sh" ||
   grep -Fq 'ISS_GLM_LAUNCHER' "$ROOT/scripts/design-session.sh" ||
   grep -Fq 'judgment-model.sh' "$ROOT/scripts/design-session.sh"; then
  record FAIL 'design-session.sh no longer reads the old judgment-model switch'
else
  record PASS 'design-session.sh no longer reads the old judgment-model switch'
fi

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
