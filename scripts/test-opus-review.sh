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
  rc=$?
  if [ -n "$TIMEOUT_CHILD" ] && kill -0 "$TIMEOUT_CHILD" 2>/dev/null; then
    kill -KILL "$TIMEOUT_CHILD" 2>/dev/null || true
  fi
  trap - EXIT HUP INT TERM
  if [ "$rc" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    rm -r "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -u
calls=0
if [ -n "${FAKE_CLAUDE_CALLS:-}" ]; then
  [ -f "$FAKE_CLAUDE_CALLS" ] && calls=$(cat "$FAKE_CLAUDE_CALLS" 2>/dev/null)
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$FAKE_CLAUDE_CALLS"
fi
{
  echo "===ENV==="
  env | LC_ALL=C sort
  echo "===ARGS==="
  for arg in "$@"; do printf 'ARG\t%s\n' "$arg"; done
} > "$FAKE_CLAUDE_LOG"
pwd -P > "$FAKE_CLAUDE_CWD"
scenario=${FAKE_CLAUDE_SCENARIO:-ok}
if [ "$calls" -ge 2 ] && [ -n "${FAKE_CLAUDE_SCENARIO_2:-}" ]; then
  scenario=$FAKE_CLAUDE_SCENARIO_2
fi
case "$scenario" in
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
  missingmarks)
    cat <<'MD'
## 需要人取舍
1. 是否删除旧表
   A. 删除
   B. 保留
MD
    exit 0
    ;;
  fullmarks)
    cat <<'MD'
## 需要人取舍
1. 是否删除旧表
   A. 删除
   B. 保留
   推荐：A — 旧表已无引用
   可自动采纳：是
MD
    exit 0
    ;;
  preamblemarks)
    cat <<'MD'
## 需要人取舍

以下两条需要你拍板：
1. 是否删除旧表
   推荐：A — 旧表已无引用
   可自动采纳：是
2. 是否保留旧索引
   推荐：B — 还有查询在用
   可自动采纳：是
MD
    exit 0
    ;;
  nonemarks) printf '## 需要人取舍\n无\n'; exit 0 ;;
  dropsection) printf 'repaired without the section\n'; exit 0 ;;
  *) echo "unknown fake scenario" >&2; exit 99 ;;
esac
FAKE
chmod +x "$BIN/claude"

# Stands in for the GLM launcher: the same fake model, with a log of its own,
# so a test can tell which of the two was started.
cat > "$BIN/claude-glm" <<'FAKE'
#!/usr/bin/env bash
export FAKE_CLAUDE_LOG="$FAKE_GLM_LOG" FAKE_CLAUDE_CWD="$FAKE_GLM_CWD"
exec "$FAKE_BIN_DIR/claude" "$@"
FAKE
chmod +x "$BIN/claude-glm"
ROUTE=$HERE/stage-route.sh

# A jump makes `date +%s` alternate between a base time and base + jump, so
# the two reads of opus-review.sh's timeout loop (start, now) differ by the
# jump. opus-review.sh reads the route table before the loop, and every
# stage-route.sh run reads the clock once; the number of those reads must stay
# even for the loop's own reads to land on the base and the jump.
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

ORIG_PATH=$PATH
export PATH="$BIN:$PATH"
export ANTHROPIC_BASE_URL="https://glm-proxy.invalid/v1"
export ANTHROPIC_AUTH_TOKEN="fake-glm-token"
export ANTHROPIC_API_KEY="fake-glm-key"
export ANTHROPIC_MODEL="glm-5.4"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.4"
export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.3-flash"
export ANTHROPIC_DEFAULT_AGENT_MODEL="glm-5.4"
export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.4"
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE="glm-5.4"
export FLASH_ORCHESTRATOR=1

export FAKE_CLAUDE_LOG="$WORK/code-env-args.log"
export FAKE_CLAUDE_CWD="$WORK/code-cwd.log"
export FAKE_CLAUDE_CHILD_PID="$WORK/timeout-child.pid"
export FAKE_CLAUDE_SCENARIO=ok
export FAKE_DATE_STATE="$WORK/fake-date-state"
export FAKE_CLAUDE_CALLS="$WORK/claude-calls"
export FAKE_GLM_LOG="$WORK/glm-env-args.log"
export FAKE_GLM_CWD="$WORK/glm-cwd.log"
export FAKE_BIN_DIR="$BIN"
# The Stage route table of the user running the tests must not leak in: the
# routes a test sets go to a table of its own, next to which the first run of
# stage-route.sh finds no old switch file to migrate either.
export ISS_STAGE_ROUTE_FILE="$WORK/stage-route"

reset_calls() { : > "$FAKE_CLAUDE_CALLS"; }
call_count() { cat "$FAKE_CLAUDE_CALLS" 2>/dev/null || echo 0; }

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
Bash(gh issue view:*)
Bash(gh pr view:*)
Bash(gh pr diff:*)
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
check "the default route runs the review on official claude" test -e "$FAKE_CLAUDE_LOG"
check "the default review route is not the GLM launcher" test ! -e "$FAKE_GLM_LOG"
check "findings start with the default review route" \
  bash -c "head -n 1 '$WORK/code-findings.md' | grep -Eq '^路由：审查（review）claude / opus / high · [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\$'"
check "the route line is followed by a blank line" \
  bash -c "test \"\$(sed -n 2p '$WORK/code-findings.md')\" = ''"
check "the model output follows the route line" \
  bash -c "test \"\$(sed -n 3p '$WORK/code-findings.md')\" = 'fake Opus findings'"
check "the default route reports nothing about official Opus on stderr" \
  bash -c "! grep -Fq 'official Opus is not called' '$WORK/run.err'"

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
check "claude effort is the route's high" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--effort" && args[i + 1] == "high") exit 0; exit 1 }
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
check "code prompt pins both review axes to the route's model" bash -c "grep -Fq 'Standards' '$FAKE_CLAUDE_LOG' && grep -Fq 'Spec' '$FAKE_CLAUDE_LOG' && grep -Fq 'subagent model to \`opus\`' '$FAKE_CLAUDE_LOG'"
check "code prompt requires human-tradeoff findings" grep -Fq '需要人取舍' "$FAKE_CLAUDE_LOG"
check "code prompt requires a recommendation per tradeoff" grep -Fq '推荐：<option>' "$FAKE_CLAUDE_LOG"
check "code prompt asks whether the recommendation can be auto-applied" grep -Fq '可自动采纳：否' "$FAKE_CLAUDE_LOG"

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
check "draft prompt requires a recommendation per tradeoff" grep -Fq '推荐：<option>' "$FAKE_CLAUDE_LOG"
check "draft prompt asks whether the recommendation can be auto-applied" grep -Fq '可自动采纳：否' "$FAKE_CLAUDE_LOG"

printf 'failure content\n' > "$WORK/failure.md"
export FAKE_CLAUDE_LOG="$WORK/diagnose-env-args.log"
run_review --kind diagnose --input "$WORK/failure.md" --out "$WORK/diagnose-findings.md" --cwd "$REPO" --timeout 5
expect_rc "diagnose review succeeds" 0 "$RUN_RC"
check "diagnose prompt reads the failure record" grep -Fq "$WORK/failure.md" "$FAKE_CLAUDE_LOG"
check "diagnose prompt offers the three actions" bash -c "grep -Fq '续跑' '$FAKE_CLAUDE_LOG' && grep -Fq '改 Brief' '$FAKE_CLAUDE_LOG' && grep -Fq '停车' '$FAKE_CLAUDE_LOG'"
check "diagnose prompt requires human-tradeoff findings" grep -Fq '需要人取舍' "$FAKE_CLAUDE_LOG"
check "diagnose prompt requires a recommendation per tradeoff" grep -Fq '推荐：<option>' "$FAKE_CLAUDE_LOG"
check "diagnose prompt asks whether the recommendation can be auto-applied" grep -Fq '可自动采纳：否' "$FAKE_CLAUDE_LOG"

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

printf '%s\n' '## 需要人取舍' '1. 是否删除旧表' '   A. 删除' '   B. 保留' \
  '   推荐：A — 旧表已无引用' '   可自动采纳：是' > "$WORK/expected-fullmarks.md"
printf '## 需要人取舍\n无\n' > "$WORK/marks-none-expected.md"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-ok.log" FAKE_CLAUDE_SCENARIO=fullmarks FAKE_CLAUDE_SCENARIO_2=
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-ok.md" --cwd "$REPO" --timeout 5
expect_rc "complete 需要人取舍 marks succeed" 0 "$RUN_RC"
check "complete marks need no repair retry" test "$(call_count)" = 1
check "complete marks are kept verbatim after the route line" cmp -s <(tail -n +3 "$WORK/marks-ok.md") "$WORK/expected-fullmarks.md"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-repair.log" FAKE_CLAUDE_SCENARIO=missingmarks FAKE_CLAUDE_SCENARIO_2=fullmarks
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-repaired.md" --cwd "$REPO" --timeout 5
expect_rc "missing marks are repaired by one retry" 0 "$RUN_RC"
check "repair retry runs exactly once" test "$(call_count)" = 2
check "repaired findings keep the item" grep -Fq '1. 是否删除旧表' "$WORK/marks-repaired.md"
check "repaired findings have the recommendation" grep -Fq '推荐：A — 旧表已无引用' "$WORK/marks-repaired.md"
check "repaired findings have the auto-apply mark" grep -Fq '可自动采纳：是' "$WORK/marks-repaired.md"
check "repair prompt carries the original output" grep -Fq '是否删除旧表' "$FAKE_CLAUDE_LOG"
check "repair prompt names the missing marks" grep -Fq '可自动采纳' "$FAKE_CLAUDE_LOG"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-failed.log" FAKE_CLAUDE_SCENARIO=missingmarks FAKE_CLAUDE_SCENARIO_2=missingmarks
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-failed.md" --cwd "$REPO" --timeout 5
expect_rc "unrepaired marks exit 7" 7 "$RUN_RC"
check "unrepaired marks list the item on stderr" grep -Fq '1. 是否删除旧表' "$WORK/run.err"
check "unrepaired marks write no findings" test ! -e "$WORK/marks-failed.md"
check "unrepaired marks were retried once" test "$(call_count)" = 2

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-dropped.log" FAKE_CLAUDE_SCENARIO=missingmarks FAKE_CLAUDE_SCENARIO_2=dropsection
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-dropped.md" --cwd "$REPO" --timeout 5
expect_rc "a repair retry that drops the section exits 7" 7 "$RUN_RC"
check "dropping the section is reported" grep -Fq 'dropped ## 需要人取舍' "$WORK/run.err"
check "a dropped section writes no findings" test ! -e "$WORK/marks-dropped.md"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-none.log" FAKE_CLAUDE_SCENARIO=nonemarks FAKE_CLAUDE_SCENARIO_2=
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-none.md" --cwd "$REPO" --timeout 5
expect_rc "a 无 section needs no marks" 0 "$RUN_RC"
check "a 无 section needs no retry" test "$(call_count)" = 1
check "a 无 section is written verbatim after the route line" cmp -s <(tail -n +3 "$WORK/marks-none.md") "$WORK/marks-none-expected.md"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-preamble.log" FAKE_CLAUDE_SCENARIO=preamblemarks FAKE_CLAUDE_SCENARIO_2=
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-preamble.md" --cwd "$REPO" --timeout 5
expect_rc "a preamble before the first item is not an item" 0 "$RUN_RC"
check "a preamble needs no retry" test "$(call_count)" = 1

reset_calls
export FAKE_CLAUDE_LOG="$WORK/no-section.log" FAKE_CLAUDE_SCENARIO=ok FAKE_CLAUDE_SCENARIO_2=
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/no-section.md" --cwd "$REPO" --timeout 5
expect_rc "a findings file without the section passes" 0 "$RUN_RC"
check "a missing section needs no retry" test "$(call_count)" = 1
check "the exit-code table documents code 7" grep -Eq '^# +7 ' "$HERE/opus-review.sh"

# --- Stage route ------------------------------------------------------------
# The table is set through its own command. The review stage switched to
# claude-glm / glm-5.4 / medium: the review runs through that launcher with the
# route's model and effort, official Opus is not called, and the findings say
# so on their first line.
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
export FAKE_GLM_LOG="$WORK/switch-on-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-on-claude.log"
export FAKE_CLAUDE_SCENARIO=ok
run_review --kind code --input main --out "$WORK/switch-on-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a switched code review succeeds" 0 "$RUN_RC"
check "a switched review does not call claude" test ! -e "$FAKE_CLAUDE_LOG"
check "a switched review calls the GLM launcher" test -e "$FAKE_GLM_LOG"
check "switched findings start with the route line" \
  bash -c "head -n 1 '$WORK/switch-on-findings.md' | grep -Eq '^路由：审查（review）claude-glm / glm-5.4 / medium · [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\$'"
check "the route line is followed by a blank line" \
  bash -c "test \"\$(sed -n 2p '$WORK/switch-on-findings.md')\" = ''"
check "switched findings keep the model output" grep -Fqx 'fake Opus findings' "$WORK/switch-on-findings.md"
check "the route is reported on stderr" grep -Fq 'the review route is claude-glm / glm-5.4 / medium' "$WORK/run.err"
check "the report names the command that sets the route" grep -Fq '/grill-router' "$WORK/run.err"
check "the report says official Opus is not called" grep -Fq 'official Opus is not called' "$WORK/run.err"
check "GLM launcher runs headless" awk '
  /^ARG\t/ { arg = substr($0, 5); if (arg == "-p" || arg == "--print") found = 1 }
  END { exit !found }
' "$FAKE_GLM_LOG"
check "GLM launcher is asked for the route's model in its own form" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--model" && args[i + 1] == "glm-5.4[1m]") exit 0; exit 1 }
' "$FAKE_GLM_LOG"
check "GLM launcher is asked for the route's effort" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--effort" && args[i + 1] == "medium") exit 0; exit 1 }
' "$FAKE_GLM_LOG"
check "GLM launcher cwd is the reviewed repository" test "$(cat "$FAKE_GLM_CWD")" = "$REPO"
check "GLM launcher cwd is the reviewed repository" test "$(cat "$FAKE_GLM_CWD")" = "$REPO"
for variable in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE FLASH_ORCHESTRATOR; do
  check "$variable is unset for the GLM launcher" bash -c "! grep -Eq '^$variable=' '$FAKE_GLM_LOG'"
done
check "all ANTHROPIC_DEFAULT_*_MODEL variables are unset for the GLM launcher" \
  bash -c "! grep -Eq '^ANTHROPIC_DEFAULT_[A-Za-z0-9_]+_MODEL=' '$FAKE_GLM_LOG'"
GOT_ALLOWED=$(tool_block "$FAKE_GLM_LOG" "--allowedTools" "--disallowedTools")
if [ "$GOT_ALLOWED" = "$EXPECTED_ALLOWED" ]; then pass "the switched allowed tool list is exactly read-only"
else fail "the switched allowed tool list is exactly read-only"; fi
GOT_DISALLOWED=$(tool_block "$FAKE_GLM_LOG" "--disallowedTools" "--permission-prompts")
if [ "$GOT_DISALLOWED" = "$EXPECTED_DISALLOWED" ]; then pass "the switched review still disallows editing and network tools"
else fail "the switched review still disallows editing and network tools"; fi
check "the switched review still denies unprompted permissions" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--permission-prompts" && args[i + 1] == "none") exit 0; exit 1 }
' "$FAKE_GLM_LOG"
check "the switched prompt names the executing model" grep -Fq 'executed by glm-5.4' "$FAKE_GLM_LOG"
# The Agent tool takes only the aliases sonnet|opus|haiku|fable: the axes are
# pinned to opus on this profile too, never to the route's own model name.
check "the switched prompt pins both review axes to opus, the Agent tool's alias" \
  grep -Fq 'subagent model to `opus`' "$FAKE_GLM_LOG"
check "the switched prompt does not pin the review axes to the route's model name" \
  bash -c "! grep -Fq 'subagent model to \`glm-5.4\`' '$FAKE_GLM_LOG'"
check "the switched prompt still names the full code-review skill" \
  grep -Fq 'mattpocock-skills:code-review' "$FAKE_GLM_LOG"

# draft reads the review stage too.
export FAKE_GLM_LOG="$WORK/switch-draft-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-draft-claude.log"
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/switch-draft-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a switched draft review succeeds" 0 "$RUN_RC"
check "a switched draft review does not call claude" test ! -e "$FAKE_CLAUDE_LOG"
check "switched draft findings start with the review route line" \
  bash -c "head -n 1 '$WORK/switch-draft-findings.md' | grep -Fq '路由：审查（review）claude-glm / glm-5.4 / medium · '"

# diagnose reads the diagnosis stage, which is still on its default.
export FAKE_GLM_LOG="$WORK/switch-diagnose-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-diagnose-claude.log"
run_review --kind diagnose --input "$WORK/failure.md" --out "$WORK/switch-diagnose-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a diagnose under a switched review stage succeeds" 0 "$RUN_RC"
check "diagnose reads the diagnosis stage, so claude is called" test -e "$FAKE_CLAUDE_LOG"
check "diagnose does not follow a switched review stage" test ! -e "$FAKE_GLM_LOG"
check "diagnose findings start with the default diagnosis route line" \
  bash -c "head -n 1 '$WORK/switch-diagnose-findings.md' | grep -Fq '路由：诊断（diagnosis）claude / opus / high · '"
check "the default diagnosis route is not reported as a switch" \
  bash -c "! grep -Fq 'official Opus is not called' '$WORK/run.err'"

"$ROUTE" use diagnosis=claude-glm/glm-5.4/low >/dev/null 2>&1
export FAKE_GLM_LOG="$WORK/switch-diagnose2-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-diagnose2-claude.log"
run_review --kind diagnose --input "$WORK/failure.md" --out "$WORK/switch-diagnose2-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a switched diagnose review succeeds" 0 "$RUN_RC"
check "a switched diagnose review does not call claude" test ! -e "$FAKE_CLAUDE_LOG"
check "a switched diagnose review calls the GLM launcher" test -e "$FAKE_GLM_LOG"
check "switched diagnose findings start with the diagnosis route line" \
  bash -c "head -n 1 '$WORK/switch-diagnose2-findings.md' | grep -Fq '路由：诊断（diagnosis）claude-glm / glm-5.4 / low · '"
check "the switched diagnosis route is reported on stderr" \
  grep -Fq 'the diagnosis route is claude-glm / glm-5.4 / low' "$WORK/run.err"
check "GLM launcher is asked for the diagnosis route's effort" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--effort" && args[i + 1] == "low") exit 0; exit 1 }
' "$FAKE_GLM_LOG"
"$ROUTE" use diagnosis=claude/opus/high >/dev/null 2>&1

reset_calls
export FAKE_GLM_LOG="$WORK/switch-repair-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-repair-claude.log"
export FAKE_CLAUDE_SCENARIO=missingmarks FAKE_CLAUDE_SCENARIO_2=fullmarks
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/switch-repaired.md" --cwd "$REPO" --timeout 5
expect_rc "a switched review repairs missing marks" 0 "$RUN_RC"
REPAIR_CALLS=$(call_count)
check "both passes of a switched repair go through the GLM launcher" \
  bash -c "test '$REPAIR_CALLS' = 2 && test ! -e '$FAKE_CLAUDE_LOG'"
# The fake overwrites its log on each call, so this is the repair pass alone.
check "the repair retry asks for the same model and effort" awk '
  /^ARG\t/ { arg = substr($0, 5); args[++count] = arg }
  END { for (i = 1; i < count; i++) if (args[i] == "--model" && args[i + 1] == "glm-5.4[1m]") model = 1
        for (i = 1; i < count; i++) if (args[i] == "--effort" && args[i + 1] == "medium") effort = 1
        exit !(model && effort) }
' "$FAKE_GLM_LOG"
check "repaired switched findings keep the route line first" \
  bash -c "head -n 1 '$WORK/switch-repaired.md' | grep -Fq '路由：审查（review）claude-glm / glm-5.4 / medium · '"
check "repaired switched findings have the marks" grep -Fq '可自动采纳：是' "$WORK/switch-repaired.md"
export FAKE_CLAUDE_SCENARIO=ok FAKE_CLAUDE_SCENARIO_2=

export FAKE_GLM_LOG="$WORK/switch-quota-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-quota-claude.log"
export FAKE_CLAUDE_SCENARIO=quota
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/switch-quota-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a quota failure under the switch still exits 3" 3 "$RUN_RC"
check "a quota failure under the switch does not fall back to claude" test ! -e "$FAKE_CLAUDE_LOG"
check "a quota failure under the switch writes no findings" test ! -e "$WORK/switch-quota-findings.md"
export FAKE_CLAUDE_SCENARIO=ok

# An expired line is the table's own format (`@<epoch seconds>`): the stage is
# back on its default, and the findings name the default.
printf 'review=claude-glm/glm-5.4/medium@1000000000\n' > "$ISS_STAGE_ROUTE_FILE"
export FAKE_GLM_LOG="$WORK/switch-expired-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-expired-claude.log"
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/switch-expired-findings.md" --cwd "$REPO" --timeout 5
expect_rc "an expired route runs the review on claude" 0 "$RUN_RC"
check "an expired route calls claude" test -e "$FAKE_CLAUDE_LOG"
check "an expired route does not call the GLM launcher" test ! -e "$FAKE_GLM_LOG"
check "an expired route's findings name the default route" \
  bash -c "head -n 1 '$WORK/switch-expired-findings.md' | grep -Fq '路由：审查（review）claude / opus / high · '"

# Only its own stage is consulted: switching another stage alone changes nothing.
printf 'design=claude-glm/glm-5.4/high\n' > "$ISS_STAGE_ROUTE_FILE"
export FAKE_GLM_LOG="$WORK/switch-design-only-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-design-only-claude.log"
run_review --kind code --input main --out "$WORK/switch-design-only-findings.md" --cwd "$REPO" --timeout 5
expect_rc "a switched design stage alone keeps the review on claude" 0 "$RUN_RC"
check "a switched design stage alone calls claude" test -e "$FAKE_CLAUDE_LOG"
check "a switched design stage alone does not call the GLM launcher" test ! -e "$FAKE_GLM_LOG"

# A route whose launcher is not installed never reaches a model. The PATH of
# these two calls is closed: it holds the fake claude alone, so neither the
# fake nor the real claude-glm can be found.
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
mkdir -p "$BIN/only-claude"
ln -sf "$BIN/claude" "$BIN/only-claude/claude"
ln -sf "$BIN/date" "$BIN/only-claude/date"
export FAKE_GLM_LOG="$WORK/switch-no-launcher-glm.log" FAKE_CLAUDE_LOG="$WORK/switch-no-launcher-claude.log"
(
  export PATH="$BIN/only-claude:/usr/bin:/bin"
  "$REVIEW" --kind draft --input "$WORK/draft.md" --out "$WORK/switch-no-launcher.md" --cwd "$REPO" --timeout 5 \
    >"$WORK/run.out" 2>"$WORK/run.err"
)
RUN_RC=$?
expect_rc "a route without its launcher exits 6" 6 "$RUN_RC"
check "the missing launcher is named" grep -Fq "'claude-glm'" "$WORK/run.err"
check "the missing launcher's route is named" grep -Fq 'claude-glm / glm-5.4 / medium' "$WORK/run.err"
check "a missing launcher calls neither model" bash -c "test ! -e '$FAKE_CLAUDE_LOG' && test ! -e '$FAKE_GLM_LOG'"
check "a missing launcher writes no findings" test ! -e "$WORK/switch-no-launcher.md"

"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
export FAKE_GLM_LOG="$WORK/no-claude-glm.log" FAKE_CLAUDE_LOG="$WORK/no-claude-claude.log"
(
  export PATH="/usr/bin:/bin"
  "$REVIEW" --kind draft --input "$WORK/draft.md" --out "$WORK/no-claude.md" --cwd "$REPO" --timeout 5 \
    >"$WORK/run.out" 2>"$WORK/run.err"
)
RUN_RC=$?
expect_rc "the default route without claude exits 6" 6 "$RUN_RC"
check "the missing claude is named" grep -Fq "'claude' was not found in PATH" "$WORK/run.err"
check "the missing claude's route is named" grep -Fq 'claude / opus / high' "$WORK/run.err"
check "a missing claude calls neither model" bash -c "test ! -e '$FAKE_CLAUDE_LOG' && test ! -e '$FAKE_GLM_LOG'"

# A route that cannot be read is a usage error: nothing starts with an empty
# model. opus-review.sh finds stage-route.sh next to itself, so a copy of it
# is run next to a fake one.
NO_ROUTE="$WORK/no-route"
mkdir -p "$NO_ROUTE"
cp "$REVIEW" "$NO_ROUTE/opus-review.sh"
export FAKE_GLM_LOG="$WORK/no-route-glm.log" FAKE_CLAUDE_LOG="$WORK/no-route-claude.log"
cat > "$NO_ROUTE/stage-route.sh" <<'FAKE'
#!/usr/bin/env bash
echo "stage-route: broken for the test" >&2
exit 64
FAKE
chmod +x "$NO_ROUTE/stage-route.sh"
run_review_copy() {
  "$NO_ROUTE/opus-review.sh" "$@" >"$WORK/run.out" 2>"$WORK/run.err"
  RUN_RC=$?
}
run_review_copy --kind draft --input "$WORK/draft.md" --out "$WORK/no-route.md" --cwd "$REPO" --timeout 5
expect_rc "a route table that cannot be read is a usage error" 64 "$RUN_RC"
check "the failed route read is reported" grep -Fq 'Stage route table' "$WORK/run.err"
check "the failed route read names the stage" grep -Fq 'review route' "$WORK/run.err"
check "an unreadable route calls neither model" bash -c "test ! -e '$FAKE_CLAUDE_LOG' && test ! -e '$FAKE_GLM_LOG'"
check "an unreadable route writes no findings" test ! -e "$WORK/no-route.md"

cat > "$NO_ROUTE/stage-route.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
run_review_copy --kind code --input main --out "$WORK/no-route.md" --cwd "$REPO" --timeout 5
expect_rc "a route that prints nothing is a usage error" 64 "$RUN_RC"
check "the empty route read is reported" grep -Fq 'printed nothing' "$WORK/run.err"
check "an empty route calls neither model" bash -c "test ! -e '$FAKE_CLAUDE_LOG' && test ! -e '$FAKE_GLM_LOG'"

EXIT_CODE_SENTENCE='退出码为 3（额度或 429）时按 quota 停车，其余非 0 退出码仍按原规则停车并说明（退出码含义见 scripts/opus-review.sh 头注释）'
check "SKILL delegates exit codes to the wrapper header" \
  grep -Fq "$EXIT_CODE_SENTENCE" "$HERE/../SKILL.md"
check "find-next delegates exit codes to the wrapper header" \
  grep -Fq "$EXIT_CODE_SENTENCE" "$HERE/../find-next/SKILL.md"
check "SKILL does not duplicate the exit-code table" \
  bash -c "! grep -Fq 'authentication failed' '$HERE/../SKILL.md'"
check "find-next does not duplicate the exit-code table" \
  bash -c "! grep -Fq '认证失败（2）' '$HERE/../find-next/SKILL.md'"
check "the wrapper header documents the Stage route" \
  grep -Fq 'stage-route.sh' "$HERE/opus-review.sh"
check "the wrapper header no longer reads the old switch" \
  bash -c "! grep -Fq 'judgment-model' '$HERE/opus-review.sh'"
check "SKILL documents the Stage route" \
  bash -c "grep -Fq '/grill-router' '$HERE/../SKILL.md' && grep -Fq 'stage-route.sh' '$HERE/../SKILL.md'"
check "find-next documents the Stage route" \
  bash -c "grep -Fq '/grill-router' '$HERE/../find-next/SKILL.md' && grep -Fq 'stage-route.sh' '$HERE/../find-next/SKILL.md'"
check "SKILL tells the route lines of the reports" \
  bash -c "grep -Fq 'two route lines' '$HERE/../SKILL.md' && grep -Fq '不适用' '$HERE/../SKILL.md'"
for doc in SKILL.md find-next/SKILL.md; do
  check "$doc no longer names the /judgment-model command" \
    bash -c "! grep -Fq '/judgment-model' '$HERE/../$doc'"
  check "$doc no longer names judgment-model.sh" \
    bash -c "! grep -Fq 'judgment-model.sh' '$HERE/../$doc'"
  check "$doc no longer names the 判断模型： first line" \
    bash -c "! grep -Fq '判断模型：' '$HERE/../$doc'"
done

if [ "$FAIL" -gt 0 ]; then
  echo "Artifacts: $WORK"
fi
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
