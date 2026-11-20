#!/usr/bin/env bash
# Isolated fake-Orca tests for scripts/design-session.sh.

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
PASSED=0
FAILED=0
RUN_EXIT=
RUN_STDOUT=$WORK/stdout.txt
RUN_STDERR=$WORK/stderr.txt

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
  agent)
    subcommand=\$1
    shift
    printf '%s\\n' "\$subcommand" >> "\$ORCA_LOG"
    case "\$subcommand" in
      launch)
        while [ \$# -gt 0 ]; do
          if [ "\$1" = --prompt ]; then
            printf '%s\\n' "\$2" > "\$PROMPT_LOG"
            shift 2
          else
            shift
          fi
        done
        if [ "\${DESIGN_TEST_LAUNCH_FAIL:-0}" = 1 ]; then
          printf '%s\\n' 'fake orca launch failed' >&2
          exit 70
        fi
        if [ "\${DESIGN_TEST_TERMINAL:-0}" = 1 ]; then
          printf '%s\\n' '{"ok":true,"result":{"outcome":{"kind":"terminal","handle":"term_test"},"worktreeId":"wt-test"}}'
        else
          printf '%s\\n' '{"ok":true,"result":{"outcome":{"kind":"structured","sessionId":"orca_session_id:test-design","handle":"term_test"},"worktreeId":"wt-test"}}'
        fi
        ;;
      show)
        if [ "\${DESIGN_TEST_SESSION_EXIT:-0}" = 1 ] ||
           [ "\${DESIGN_TEST_CLOSED_AFTER_HANDOFF:-0}" = 1 ]; then
          printf '%s\\n' '{"ok":true,"result":{"places":[]}}'
        else
          printf '%s\\n' '{"ok":true,"result":{"places":[{"workspace":"Test"}]}}'
        fi
        ;;
      *)
        printf 'fake orca: unsupported agent subcommand %s\\n' "\$subcommand" >&2
        exit 70
        ;;
    esac
    ;;
  orchestration)
    subcommand=\$1
    shift
    printf '%s\\n' "\$subcommand" >> "\$ORCA_LOG"
    case "\$subcommand" in
      run-create)
        printf '%s\\n' '{"ok":true,"result":{"id":"run_test_design"}}'
        ;;
      check)
        if [ "\${DESIGN_TEST_SESSION_EXIT:-0}" = 1 ]; then
          sleep 2
        fi
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
        REPORT_DIR=\$(sed -n 's/^运行目录：//p' "\$PROMPT_LOG" | head -1)
        REPORT_PATH="\$REPORT_DIR/handoff.md"
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
        printf 'Spec #15, tickets #18.\\n' > "\$REPORT_PATH"
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
      wait)
        if [ "\${DESIGN_TEST_SESSION_EXIT:-0}" != 1 ]; then
          sleep 2
        fi
        printf '%s\\n' '{"ok":true,"result":{"exited":true}}'
        ;;
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

run_design_session() {
  output=$1
  shift
  DESIGN_SESSION_ROOT=$WORK/runs \
  ISS_ORCA=$BIN/orca \
  ISS_DESIGN_SESSION_POLL=0.01 \
  ORCA_LOG=$ORCA_LOG \
  PROMPT_LOG=$PROMPT_LOG \
  CHECK_LOG=$CHECK_LOG \
  DESIGN_TEST_TIMEOUT=${DESIGN_TEST_TIMEOUT:-0} \
  DESIGN_TEST_SESSION_EXIT=${DESIGN_TEST_SESSION_EXIT:-0} \
  DESIGN_TEST_LAUNCH_FAIL=${DESIGN_TEST_LAUNCH_FAIL:-0} \
  DESIGN_TEST_CHECK_FAIL=${DESIGN_TEST_CHECK_FAIL:-0} \
  DESIGN_TEST_MISSING_HANDOFF=${DESIGN_TEST_MISSING_HANDOFF:-0} \
  DESIGN_TEST_CLOSED_AFTER_HANDOFF=${DESIGN_TEST_CLOSED_AFTER_HANDOFF:-0} \
  DESIGN_TEST_TERMINAL=${DESIGN_TEST_TERMINAL:-0} \
  DESIGN_TEST_UNRELATED_FIRST=${DESIGN_TEST_UNRELATED_FIRST:-0} \
  DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT=${DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT:-0} \
  CHECK_ATTEMPTS=$CHECK_ATTEMPTS \
  REPORT_LOG=$REPORT_LOG \
    bash "$SCRIPT" "$@" > "$output" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

: > "$ORCA_LOG"
: > "$CHECK_LOG"
run_design_session "$RUN_STDOUT" feature 'Add export button' --timeout 1
expect_exit 0 'feature design session succeeds'
if [ "$(cat "$RUN_STDOUT")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'successful run prints the handoff path'
else
  record FAIL 'successful run prints the handoff path' "stdout=$(cat "$RUN_STDOUT" 2>/dev/null)"
fi
expect_file_has 'claude' 'feature launch uses the official Claude agent' "$ORCA_LOG"
expect_file_has 'run-create' 'design wait uses its own Run' "$ORCA_LOG"
expect_file_has '--objective' 'Run creation has an objective' "$ORCA_LOG"
expect_file_has '--json' 'Run creation emits JSON' "$ORCA_LOG"
expect_file_has 'mattpocock-skills:grill-with-docs' 'feature prompt names its upstream skill' "$PROMPT_LOG"
expect_file_has 'Add export button' 'feature prompt carries the user topic' "$PROMPT_LOG"
expect_file_has 'to-spec' 'prompt continues to to-spec' "$PROMPT_LOG"
expect_file_has 'to-tickets' 'prompt continues to to-tickets' "$PROMPT_LOG"
expect_file_has '确认拆分' 'to-tickets still asks for confirmation' "$PROMPT_LOG"
expect_file_has '另开 Design session' 'prompt handles oversized context' "$PROMPT_LOG"
expect_file_has 'commit 并 push' 'prompt commits and pushes document changes' "$PROMPT_LOG"
expect_file_has 'handoff.md' 'prompt names the handoff file' "$PROMPT_LOG"
expect_file_has '30 行' 'prompt limits handoff length' "$PROMPT_LOG"
expect_file_has 'orca orchestration send --subject "Design session handoff" --to run:run_test_design --report-path' \
  'prompt names the complete notification command' "$PROMPT_LOG"
expect_file_has --wait 'handoff wait uses Orca wait' "$CHECK_LOG"
expect_file_has --run 'handoff wait targets the created Run' "$CHECK_LOG"
expect_file_has 'run_test_design' 'handoff wait names the created Run id' "$CHECK_LOG"
expect_file_has --timeout-ms 'handoff wait has a timeout' "$CHECK_LOG"
expect_file_has '1000' 'timeout is converted to milliseconds' "$CHECK_LOG"

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
else
  record FAIL 'feature run creates a stamped run directory' 'no matching directory'
fi

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

DESIGN_SESSION_ROOT=$WORK/runs ISS_ORCA=$BIN/orca \
  ISS_DESIGN_SESSION_POLL=0.01 ORCA_LOG=$ORCA_LOG PROMPT_LOG=$PROMPT_LOG \
  CHECK_LOG=$CHECK_LOG DESIGN_TEST_TIMEOUT=0 DESIGN_TEST_SESSION_EXIT=0 \
  DESIGN_TEST_LAUNCH_FAIL=0 DESIGN_TEST_CHECK_FAIL=0 \
  DESIGN_TEST_MISSING_HANDOFF=0 DESIGN_TEST_CLOSED_AFTER_HANDOFF=0 \
  DESIGN_TEST_TERMINAL=0 \
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

: > "$ORCA_LOG"
: > "$PROMPT_LOG"
: > "$CHECK_LOG"
run_design_session "$WORK/map.out" map 'Refactor authentication module' --timeout 1
expect_exit 0 'map design session succeeds'
expect_file_has 'mattpocock-skills:wayfinder' 'map prompt names wayfinder' "$PROMPT_LOG"
expect_file_has 'Refactor authentication module' 'map prompt carries the user topic' "$PROMPT_LOG"
expect_file_has '先到这' 'map prompt allows an early handoff' "$PROMPT_LOG"
expect_file_has '地图状态和下一步' 'early handoff describes map state' "$PROMPT_LOG"
if grep -Fq 'mattpocock-skills:grill-with-docs' "$PROMPT_LOG"; then
  record FAIL 'map prompt does not use the feature skill'
else
  record PASS 'map prompt does not use the feature skill'
fi

: > "$ORCA_LOG"
: > "$CHECK_LOG"
rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_UNRELATED_FIRST=1
run_design_session "$WORK/unrelated-message.out" feature 'Noisy feature' --timeout 1
expect_exit 0 'unrelated message is ignored while waiting'
if [ "$(cat "$CHECK_ATTEMPTS" 2>/dev/null)" -ge 2 ]; then
  record PASS 'unrelated message was consumed by check'
else
  record FAIL 'unrelated message was consumed by check' "attempts=$(cat "$CHECK_ATTEMPTS" 2>/dev/null)"
fi
unset DESIGN_TEST_UNRELATED_FIRST

rm -f "$CHECK_ATTEMPTS"
DESIGN_TEST_WRONG_REPORT_THEN_TIMEOUT=1
run_design_session "$WORK/wrong-report-timeout.out" feature 'Wrong report' --timeout 1
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
unset DESIGN_TEST_TIMEOUT

DESIGN_TEST_SESSION_EXIT=1
run_design_session "$WORK/session-exit.out" feature 'Closed session' --timeout 5
expect_exit 7 'session exit returns exit code seven'
expect_file_has 'show' 'session exit is detected through agent show' "$ORCA_LOG"
if grep -Fq 'Design session 已结束' "$RUN_STDERR"; then
  record PASS 'session exit message is reported'
else
  record FAIL 'session exit message is reported' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_SESSION_EXIT

DESIGN_TEST_CLOSED_AFTER_HANDOFF=1
run_design_session "$WORK/closed-after-handoff.out" feature 'Closed after report' --timeout 5
expect_exit 0 'handoff wins when the session closes immediately after sending'
if [ "$(cat "$WORK/closed-after-handoff.out")" = "$(cat "$REPORT_LOG")" ]; then
  record PASS 'closed-after-handoff run still prints the report path'
else
  record FAIL 'closed-after-handoff run still prints the report path' \
    "stdout=$(cat "$WORK/closed-after-handoff.out")"
fi
unset DESIGN_TEST_CLOSED_AFTER_HANDOFF

DESIGN_TEST_TERMINAL=1
run_design_session "$WORK/terminal.out" feature 'Terminal session' --timeout 5
expect_exit 0 'terminal-backed design session succeeds'

DESIGN_TEST_SESSION_EXIT=1
run_design_session "$WORK/terminal-exit.out" feature 'Closed terminal session' --timeout 5
expect_exit 7 'terminal-backed session exit returns exit code seven'
if grep -Fq 'Design session 已结束' "$RUN_STDERR"; then
  record PASS 'terminal-backed session exit message is reported'
else
  record FAIL 'terminal-backed session exit message is reported' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_SESSION_EXIT DESIGN_TEST_TERMINAL

DESIGN_TEST_LAUNCH_FAIL=1
run_design_session "$WORK/launch-fail.out" feature x --timeout 1
expect_exit 6 'launch failure returns exit code six'
if grep -Fq 'fake orca launch failed' "$RUN_STDERR"; then
  record PASS 'launch failure is surfaced'
else
  record FAIL 'launch failure is surfaced' "stderr=$(cat "$RUN_STDERR")"
fi
unset DESIGN_TEST_LAUNCH_FAIL

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

FEATURE_SKILL=$ROOT/grill-feature/SKILL.md
MAP_SKILL=$ROOT/grill-map/SKILL.md
expect_file_has 'name: grill-feature' 'feature skill has its name' "$FEATURE_SKILL"
expect_file_has '小功能' 'feature description mentions small features' "$FEATURE_SKILL"
expect_file_has 'grill 一下这个功能' 'feature description carries its trigger phrase' "$FEATURE_SKILL"
expect_file_has 'design-session.sh feature' 'feature skill calls the feature wrapper' "$FEATURE_SKILL"
expect_file_has 'handoff.md' 'feature skill returns through the handoff' "$FEATURE_SKILL"
expect_file_has 'name: grill-map' 'map skill has its name' "$MAP_SKILL"
expect_file_has '大模块' 'map description mentions large modules' "$MAP_SKILL"
expect_file_has 'wayfinder' 'map description carries wayfinder trigger' "$MAP_SKILL"
expect_file_has '先到这' 'map description carries its early-stop trigger' "$MAP_SKILL"
expect_file_has 'design-session.sh map' 'map skill calls the map wrapper' "$MAP_SKILL"
expect_file_has 'handoff.md' 'map skill returns through the handoff' "$MAP_SKILL"
expect_file_has 'grill-feature' 'README documents the feature skill symlink' "$ROOT/README.md"
expect_file_has 'grill-map' 'README documents the map skill symlink' "$ROOT/README.md"
expect_file_has 'grill-feature' 'setup documents the feature skill symlink' "$ROOT/docs/setup.md"
expect_file_has 'grill-map' 'setup documents the map skill symlink' "$ROOT/docs/setup.md"
expect_file_has 'bash scripts/test-design-session.sh' 'MAINTAINING registers the new test' "$ROOT/MAINTAINING.md"

printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
