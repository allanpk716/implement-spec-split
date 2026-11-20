#!/usr/bin/env bash
# Deterministic tests for opus-review.sh. Everything runs against a fake claude
# executable, so the suite never spends Opus quota or touches real credentials.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REVIEW="$HERE/opus-review.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opus-review-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
export HOME="$WORK/home"
BIN="$WORK/bin"
REPO=$(mkdir -p "$WORK/repo" && cd "$WORK/repo" && pwd -P)
mkdir -p "$HOME" "$BIN"

PASS=0
FAIL=0
RUN_RC=0
TIMEOUT_CHILD=""

pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
expect_rc() {
  local description="$1" wanted="$2" got="$3"
  if [ "$wanted" -eq "$got" ]; then pass "$description"
  else fail "$description (wanted $wanted, got $got)"; fi
}

cleanup() {
  if [ -n "$TIMEOUT_CHILD" ] && kill -0 "$TIMEOUT_CHILD" 2>/dev/null; then
    kill -KILL "$TIMEOUT_CHILD" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -u
{
  echo "===ENV==="
  env | LC_ALL=C sort
  echo "===ARGS==="
  for arg in "$@"; do printf 'ARG\t%s\n' "$arg"; done
} > "$FAKE_CLAUDE_LOG"
pwd -P > "$FAKE_CLAUDE_CWD"
case "${FAKE_CLAUDE_SCENARIO:-ok}" in
  ok) printf 'fake Opus findings\n'; exit 0 ;;
  auth) echo 'Invalid API key: 401 Unauthorized'; exit 1 ;;
  quota) echo '429 Too Many Requests: usage limit reached'; exit 1 ;;
  overloaded) echo 'The server is overloaded'; exit 1 ;;
  service529) echo 'HTTP 529 server overloaded'; exit 1 ;;
  service503) echo '503 Service Unavailable'; exit 1 ;;
  connection) echo 'fetch failed: connection error'; exit 1 ;;
  blank) exit 0 ;;
  whitespace) printf ' \t\n'; exit 0 ;;
  other) echo 'claude exploded' >&2; exit 17 ;;
  sleep)
    sleep 30 &
    echo $! > "$FAKE_CLAUDE_CHILD_PID"
    wait $!
    printf 'late output\n'
    ;;
  *) echo "unknown fake scenario" >&2; exit 99 ;;
esac
FAKE
chmod +x "$BIN/claude"

cat > "$BIN/date" <<'FAKE'
#!/usr/bin/env bash
if [ "${FAKE_DATE_JUMP_SECONDS:-0}" -eq 0 ]; then
  /bin/date "$@"
  exit $?
fi
if [ "${1:-}" = +%s ]; then
  if [ ! -f "$FAKE_DATE_STATE" ]; then
    printf '%s\n' '1000000000' > "$FAKE_DATE_STATE"
    printf '%s\n' '1000000000'
  else
    rm -f "$FAKE_DATE_STATE"
    printf '%s\n' "$((1000000000 + FAKE_DATE_JUMP_SECONDS))"
  fi
  exit 0
fi
/bin/date "$@"
FAKE
chmod +x "$BIN/date"

reset_fake_date() {
  rm -f "$FAKE_DATE_STATE"
  FAKE_DATE_JUMP_SECONDS=$1
  export FAKE_DATE_JUMP_SECONDS
}

export PATH="$BIN:$PATH"
export ANTHROPIC_BASE_URL="https://glm-proxy.invalid/v1"
export ANTHROPIC_AUTH_TOKEN="fake-glm-token"
export ANTHROPIC_API_KEY="fake-glm-key"
export ANTHROPIC_MODEL="glm-5.3"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.3"
export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.3-flash"
export ANTHROPIC_DEFAULT_AGENT_MODEL="glm-5.3"
export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.3"
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE="glm-5.3"
export FLASH_ORCHESTRATOR=1

export FAKE_CLAUDE_LOG="$WORK/code-env-args.log"
export FAKE_CLAUDE_CWD="$WORK/code-cwd.log"
export FAKE_CLAUDE_CHILD_PID="$WORK/timeout-child.pid"
export FAKE_CLAUDE_SCENARIO=ok
export FAKE_DATE_STATE="$WORK/fake-date-state"

run_review() {
  "$REVIEW" "$@" >"$WORK/run.out" 2>"$WORK/run.err"
  RUN_RC=$?
}

tool_block() {
  local file="$1" start="$2" end="$3"
  awk -v start="ARG	$start" -v end="ARG	$end" '
    $0 == start { wanted = 1; next }
    wanted && $0 == end { exit }
    wanted && /^ARG\t/ { sub(/^ARG\t/, ""); print }
  ' "$file"
}

EXPECTED_ALLOWED='Read
Grep
Glob
Bash(git status:*)
Bash(git diff:*)
Bash(git show:*)
Bash(git log:*)
Bash(git rev-parse:*)
Bash(git merge-base:*)
Bash(git ls-files:*)
Bash(git cat-file:*)
Skill
Agent'

EXPECTED_DISALLOWED='Edit
Write
MultiEdit
NotebookEdit
WebFetch
WebSearch'

run_review --kind code --input main --out "$WORK/code-findings.md" --cwd "$REPO" --timeout 5
expect_rc "code review succeeds" 0 "$RUN_RC"
check "code findings contain claude final output" grep -Fqx 'fake Opus findings' "$WORK/code-findings.md"

for variable in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE FLASH_ORCHESTRATOR; do
  check "$variable is unset for claude" bash -c "! grep -Eq '^$variable=' '$FAKE_CLAUDE_LOG'"
done
check "all ANTHROPIC_DEFAULT_*_MODEL variables are unset" \
  bash -c "! grep -Eq '^ANTHROPIC_DEFAULT_[A-Za-z0-9_]+_MODEL=' '$FAKE_CLAUDE_LOG'"
check "claude runs headless" awk '
  /^ARG\t/ { arg = substr($0, 5); if (arg == "-p" || arg == "--print") found = 1 }
  END { exit !found }
' "$FAKE_CLAUDE_LOG"
check "claude model is opus" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--model" && args[i + 1] == "opus") exit 0; exit 1 }
' "$FAKE_CLAUDE_LOG"
check "claude cwd is the reviewed repository" test "$(cat "$FAKE_CLAUDE_CWD")" = "$REPO"
check "headless call omits permission mode" awk '
  /^ARG\t/ { arg = substr($0, 5); if (arg == "--permission-mode") found = 1 }
  END { exit !found ? 0 : 1 }
' "$FAKE_CLAUDE_LOG"
check "unprompted permissions are denied" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--permission-prompts" && args[i + 1] == "none") exit 0; exit 1 }
' "$FAKE_CLAUDE_LOG"

GOT_ALLOWED=$(tool_block "$FAKE_CLAUDE_LOG" "--allowedTools" "--disallowedTools")
if [ "$GOT_ALLOWED" = "$EXPECTED_ALLOWED" ]; then pass "allowed tool list is exactly read-only"
else fail "allowed tool list is exactly read-only"; fi
GOT_DISALLOWED=$(tool_block "$FAKE_CLAUDE_LOG" "--disallowedTools" "--permission-prompts")
if [ "$GOT_DISALLOWED" = "$EXPECTED_DISALLOWED" ]; then pass "editing and network tools are disallowed"
else fail "editing and network tools are disallowed"; fi

check "code prompt names the full code-review skill" grep -Fq 'mattpocock-skills:code-review' "$FAKE_CLAUDE_LOG"
check "code prompt gives the fixed point" grep -Fq 'fixed point: main' "$FAKE_CLAUDE_LOG"
check "code prompt pins both review axes to opus" bash -c "grep -Fq 'Standards' '$FAKE_CLAUDE_LOG' && grep -Fq 'Spec' '$FAKE_CLAUDE_LOG' && grep -Fq 'opus' '$FAKE_CLAUDE_LOG'"
check "code prompt requires human-tradeoff findings" grep -Fq '需要人取舍' "$FAKE_CLAUDE_LOG"

reset_fake_date 3600
export FAKE_CLAUDE_LOG="$WORK/code-default-timeout.log" FAKE_CLAUDE_SCENARIO=sleep
run_review --kind code --input main --out "$WORK/code-default-findings.md" --cwd "$REPO"
expect_rc "code default timeout is 3600 seconds" 5 "$RUN_RC"
check "code default timeout is reported" grep -Fq 'after 3600s' "$WORK/run.err"
check "code default timeout writes no findings" test ! -e "$WORK/code-default-findings.md"
reset_fake_date 0
export FAKE_CLAUDE_SCENARIO=ok

printf 'draft content\n' > "$WORK/draft.md"
export FAKE_CLAUDE_LOG="$WORK/draft-env-args.log"
(
  cd "$WORK"
  "$REVIEW" --kind draft --input draft.md --out "$WORK/draft-findings.md" --timeout 5 \
    >"$WORK/run.out" 2>"$WORK/run.err"
)
RUN_RC=$?
expect_rc "draft review succeeds" 0 "$RUN_RC"
check "draft findings are written" grep -Fqx 'fake Opus findings' "$WORK/draft-findings.md"
check "draft prompt reviews the draft" bash -c "grep -Fqi 'draft' '$FAKE_CLAUDE_LOG' && grep -Fq '$WORK/draft.md' '$FAKE_CLAUDE_LOG'"
check "draft prompt requires human-tradeoff findings" grep -Fq '需要人取舍' "$FAKE_CLAUDE_LOG"

printf 'failure content\n' > "$WORK/failure.md"
export FAKE_CLAUDE_LOG="$WORK/diagnose-env-args.log"
run_review --kind diagnose --input "$WORK/failure.md" --out "$WORK/diagnose-findings.md" --cwd "$REPO" --timeout 5
expect_rc "diagnose review succeeds" 0 "$RUN_RC"
check "diagnose prompt reads the failure record" grep -Fq "$WORK/failure.md" "$FAKE_CLAUDE_LOG"
check "diagnose prompt offers the three actions" bash -c "grep -Fq '续跑' '$FAKE_CLAUDE_LOG' && grep -Fq '改 Brief' '$FAKE_CLAUDE_LOG' && grep -Fq '停车' '$FAKE_CLAUDE_LOG'"
check "diagnose prompt requires human-tradeoff findings" grep -Fq '需要人取舍' "$FAKE_CLAUDE_LOG"

reset_fake_date 1200
export FAKE_CLAUDE_LOG="$WORK/draft-default-timeout.log" FAKE_CLAUDE_SCENARIO=sleep
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/draft-default-findings.md" --cwd "$REPO"
expect_rc "draft default timeout is 1200 seconds" 5 "$RUN_RC"
check "draft default timeout is reported" grep -Fq 'after 1200s' "$WORK/run.err"
check "draft default timeout writes no findings" test ! -e "$WORK/draft-default-findings.md"
reset_fake_date 0

reset_fake_date 1200
export FAKE_CLAUDE_LOG="$WORK/diagnose-default-timeout.log" FAKE_CLAUDE_SCENARIO=sleep
run_review --kind diagnose --input "$WORK/failure.md" --out "$WORK/diagnose-default-findings.md" --cwd "$REPO"
expect_rc "diagnose default timeout is 1200 seconds" 5 "$RUN_RC"
check "diagnose default timeout is reported" grep -Fq 'after 1200s' "$WORK/run.err"
check "diagnose default timeout writes no findings" test ! -e "$WORK/diagnose-default-findings.md"
reset_fake_date 0

export FAKE_CLAUDE_SCENARIO=ok
export FAKE_CLAUDE_LOG="$WORK/auth.log" FAKE_CLAUDE_SCENARIO=auth
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/auth-findings.md" --cwd "$REPO" --timeout 5
expect_rc "authentication failure exits 2" 2 "$RUN_RC"
check "authentication failure writes no findings" test ! -e "$WORK/auth-findings.md"

export FAKE_CLAUDE_LOG="$WORK/quota.log" FAKE_CLAUDE_SCENARIO=quota
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/quota-findings.md" --cwd "$REPO" --timeout 5
expect_rc "quota or rate-limit failure exits 3" 3 "$RUN_RC"
check "quota failure writes no findings" test ! -e "$WORK/quota-findings.md"

for scenario in overloaded service529 service503 connection; do
  export FAKE_CLAUDE_LOG="$WORK/$scenario.log" FAKE_CLAUDE_SCENARIO="$scenario"
  run_review --kind draft --input "$WORK/draft.md" --out "$WORK/$scenario-findings.md" --cwd "$REPO" --timeout 5
  expect_rc "$scenario failure exits 4" 4 "$RUN_RC"
  check "$scenario writes no findings" test ! -e "$WORK/$scenario-findings.md"
done

for scenario in blank whitespace; do
  export FAKE_CLAUDE_LOG="$WORK/$scenario.log" FAKE_CLAUDE_SCENARIO="$scenario"
  run_review --kind draft --input "$WORK/draft.md" --out "$WORK/$scenario-findings.md" --cwd "$REPO" --timeout 5
  expect_rc "$scenario claude output exits 6" 6 "$RUN_RC"
  check "$scenario writes no findings" test ! -e "$WORK/$scenario-findings.md"
done

export FAKE_CLAUDE_LOG="$WORK/other.log" FAKE_CLAUDE_SCENARIO=other
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/other-findings.md" --cwd "$REPO" --timeout 5
expect_rc "other claude failure exits 6" 6 "$RUN_RC"
check "other failure writes no findings" test ! -e "$WORK/other-findings.md"

export FAKE_CLAUDE_LOG="$WORK/timeout.log" FAKE_CLAUDE_SCENARIO=sleep
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/timeout-findings.md" --cwd "$REPO" --timeout 1
expect_rc "timeout exits 5" 5 "$RUN_RC"
check "timeout writes no findings" test ! -e "$WORK/timeout-findings.md"
TIMEOUT_CHILD=$(cat "$FAKE_CLAUDE_CHILD_PID" 2>/dev/null || true)
check "timeout kills claude descendants" bash -c "! kill -0 '${TIMEOUT_CHILD:-0}' 2>/dev/null"

run_review --kind nonsense --input "$WORK/draft.md" --out "$WORK/bad-kind.md" --cwd "$REPO"
expect_rc "invalid kind is a usage error" 64 "$RUN_RC"
run_review --kind code --out "$WORK/missing-input.md" --cwd "$REPO"
expect_rc "missing input is a usage error" 64 "$RUN_RC"
run_review --kind code --input main --out "$WORK/bad-timeout.md" --cwd "$REPO" --timeout zero
expect_rc "invalid timeout is a usage error" 64 "$RUN_RC"

EXIT_CODE_SENTENCE='任何非 0 退出码都停车并说明（退出码含义见 scripts/opus-review.sh 头注释）'
check "SKILL delegates exit codes to the wrapper header" \
  grep -Fq "$EXIT_CODE_SENTENCE" "$HERE/../SKILL.md"
check "find-next delegates exit codes to the wrapper header" \
  grep -Fq "$EXIT_CODE_SENTENCE" "$HERE/../find-next/SKILL.md"
check "SKILL does not duplicate the exit-code table" \
  bash -c "! grep -Fq 'authentication failed' '$HERE/../SKILL.md'"
check "find-next does not duplicate the exit-code table" \
  bash -c "! grep -Fq '认证失败（2）' '$HERE/../find-next/SKILL.md'"

echo
echo "passed=$PASS failed=$FAIL artifacts=$WORK"
[ "$FAIL" -eq 0 ]
