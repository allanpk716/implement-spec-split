#!/usr/bin/env bash
# Deterministic tests for opus-review.sh. Everything runs against a fake claude
# executable, so the suite never spends Opus quota or touches real credentials.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REVIEW="$HERE/opus-review.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opus-review-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
# The upstream skill whose Standards and Spec briefs and smell baseline the
# in-session code text carries verbatim: read from the real home, before HOME
# moves into the test's own directory.
UPSTREAM_SKILL="$HOME/.claude/plugins/marketplaces/mattpocock/skills/engineering/code-review/SKILL.md"
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
  body)
    # The findings are a file of the test's own, so that a test can feed any
    # shape of 需要人取舍 section; a second pass reads FAKE_CLAUDE_BODY_2
    # when the test set one.
    if [ "$calls" -ge 2 ] && [ -n "${FAKE_CLAUDE_BODY_2:-}" ]; then
      cat "$FAKE_CLAUDE_BODY_2"
    else
      cat "$FAKE_CLAUDE_BODY"
    fi
    exit 0 ;;
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
export FAKE_CLAUDE_BODY="" FAKE_CLAUDE_BODY_2=""
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

# A 需要人取舍 section written as a flat list (票 #84, r3): a title, then the
# options and the marks as bulleted lines at the left margin — the shape a GLM
# aggregate subagent wrote on 2026-11-28, which the wrapper refused then with
# every marked line listed as an item of its own. Eight items, each with its
# 推荐： and 可自动采纳： lines; the same section as numbered titles and as
# bold bulleted titles; and each with the third item's marks taken away, the
# one shape a check must still refuse.
cat > "$WORK/flat-bold.md" <<'MD'
## 需要人取舍

不列入（已有拍板或属动作项）：这一行是节前的说明，不是条目。

**1.【Standards 硬违规 1】第一条：词头与正文脱节**

- A：按先例把词头标退役
- B：正文回退用旧词头
- 推荐：A — 有先例、是机械操作
- 可自动采纳：是

**2.【Standards 判断项 3】第二条：自测条目没覆盖新模式**

- A：把四个 flag 补进自测
- B：维持现状
- 推荐：A
- 可自动采纳：是

**3.【Standards 判断项 4】第三条：首行写入两份**

- A：抽函数
- B：维持两份
- 推荐：A — 两段逐字相同，正是该抽函数的情形
- 可自动采纳：是

**4.【Standards 判断项 5】第四条：分派散四处**

- A：收成分派表
- B：最小改
- 推荐：B
- 可自动采纳：是

**5.【Standards 判断项 6】第五条：两个函数只差一词**

- A：改名
- B：都改名
- 推荐：A
- 可自动采纳：是

**6.【Standards 判断项 7】第六条：内嵌简报没有漂移校验**

- A：运行时抽取
- B：加一个比对测试
- 推荐：B
- 可自动采纳：是

**7.【Standards 判断项 8】第七条：测试 helper 用了一半**

- A：全补
- B：只换两处
- 推荐：B
- 可自动采纳：是

**8.【Spec (b)1–4】第八条：规格外行为**

- A：全部保留并记为取舍
- B：回退
- 推荐：A
- 可自动采纳：否 — 要写 issue 评论，是人的动作
MD
sed -E 's/^\*\*([0-9])\.【/\1. **【/' "$WORK/flat-bold.md" > "$WORK/flat-numbered.md"
sed -E 's/^\*\*([0-9])\.【/- **\1.【/' "$WORK/flat-bold.md" > "$WORK/flat-bullet.md"
for shape in bold numbered bullet; do
  awk '/^(- )?(\*\*)?[0-9]\.?( \*\*)?【Standards 判断项 4】/ { bare = 1 }
       /^(- )?(\*\*)?[0-9]\.?( \*\*)?【Standards 判断项 5】/ { bare = 0 }
       bare && /^- (推荐|可自动采纳)：/ { next } { print }' \
    "$WORK/flat-$shape.md" > "$WORK/flat-$shape-bare.md"
done

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

# --- Where a review runs (票 #84) ------------------------------------------------
# opus-review.sh --where decides, from the Stage route and the session's
# environment alone, where a review runs: the verdict on stdout, one line for
# the user on stderr, and no launcher started. The session's subagent model is
# CLAUDE_CODE_SUBAGENT_MODEL with its [1m] suffix aside, and only
# CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 counts as forced. The suite's own
# environment has the force set to a model name, which is not 1: out.
where_review() { # kind, in the environment the caller set
  rm -f "$FAKE_GLM_LOG" "$FAKE_CLAUDE_LOG"
  "$REVIEW" --where --kind "$1" >"$WORK/where.out" 2>"$WORK/where.err"
  RUN_RC=$?
}
expect_where() { # description verdict
  expect_rc "$1 exits 0" 0 "$RUN_RC"
  check "$1 prints $2 on stdout" test "$(cat "$WORK/where.out")" = "$2"
}
in_session_env() {
  export CLAUDE_CODE_SUBAGENT_MODEL='glm-5.4[1m]' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
}
no_launcher_called() {
  bash -c "test ! -e '$FAKE_CLAUDE_LOG' && test ! -e '$FAKE_GLM_LOG'"
}
export FAKE_CLAUDE_LOG="$WORK/where-claude.log" FAKE_GLM_LOG="$WORK/where-glm.log"

"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
in_session_env
where_review code
expect_where "the official review route" out-of-session
check "the official route's line names the route and says out-of-session" \
  grep -Fq '审查中（claude / opus，出会话）：审查路由 claude / opus / high 是官方模型' "$WORK/where.err"
check "the official route's line is one line" test "$(wc -l < "$WORK/where.err" | tr -d ' ')" = 1
check "--where starts no launcher" no_launcher_called

"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
where_review code
expect_where "a GLM route with the session's subagents forced onto its model" in-session
check "the in-session line names the route and says in-session" \
  grep -Fq '审查中（claude-glm / glm-5.4，会话内）：审查路由 claude-glm / glm-5.4 / medium 是 GLM' "$WORK/where.err"
check "the in-session line is one line" test "$(wc -l < "$WORK/where.err" | tr -d ' ')" = 1
check "--where starts no launcher on a GLM route" no_launcher_called
check "--where names no official Opus on a GLM route" bash -c "! grep -Fq 'Opus' '$WORK/where.err'"

# The [1m] suffix is the launcher's marker, not part of the model: the same
# model named without it compares equal.
export CLAUDE_CODE_SUBAGENT_MODEL='glm-5.4'
where_review draft
expect_where "a GLM route with the same model named without [1m]" in-session
check "draft reads the review stage" bash -c "head -n 1 '$WORK/where.err' | grep -q '^审查中（claude-glm'"

export CLAUDE_CODE_SUBAGENT_MODEL='glm-5.4[1m]' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=glm-5.4
where_review code
expect_where "a GLM route without CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1" out-of-session
check "the unforced line names the force variable" grep -Fq 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE 不是 1' "$WORK/where.err"
check "the unforced line still names the GLM route" grep -Fq '审查中（claude-glm / glm-5.4，出会话）' "$WORK/where.err"
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE=true
where_review code
expect_where "a GLM route with the force set to true rather than 1" out-of-session
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE
where_review code
expect_where "a GLM route with the force unset" out-of-session

export CLAUDE_CODE_SUBAGENT_MODEL='glm-5.3-flash[1m]' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
where_review code
expect_where "a GLM route with the subagents forced onto another model" out-of-session
check "the mismatch line names the subagent model and the route's" bash -c \
  "grep -Fq '被强制跑 glm-5.3-flash（CLAUDE_CODE_SUBAGENT_MODEL=glm-5.3-flash[1m]）' '$WORK/where.err' && grep -Fq '与路由模型不一致' '$WORK/where.err'"
check "the mismatch line says the route is never switched quietly" grep -Fq '路由不能被悄悄换掉' "$WORK/where.err"

unset CLAUDE_CODE_SUBAGENT_MODEL
where_review code
expect_where "a GLM route with no CLAUDE_CODE_SUBAGENT_MODEL at all" out-of-session
check "the no-model line names the variable" grep -Fq '没有设 CLAUDE_CODE_SUBAGENT_MODEL' "$WORK/where.err"
in_session_env

# diagnose reads the diagnosis stage, and says 诊断中.
"$ROUTE" use diagnosis=claude/opus/high >/dev/null 2>&1
where_review diagnose
expect_where "diagnose on the official diagnosis route" out-of-session
check "diagnose's line says 诊断中 and names the official route" \
  grep -Fq '诊断中（claude / opus，出会话）：诊断路由 claude / opus / high' "$WORK/where.err"
"$ROUTE" use diagnosis=claude-glm/glm-5.4/low >/dev/null 2>&1
where_review diagnose
expect_where "diagnose on a GLM diagnosis route with forced subagents" in-session
check "diagnose's in-session line names the diagnosis route" \
  grep -Fq '诊断中（claude-glm / glm-5.4，会话内）：诊断路由 claude-glm / glm-5.4 / low' "$WORK/where.err"
"$ROUTE" use diagnosis=claude/opus/high >/dev/null 2>&1

where_review nonsense
expect_rc "--where with an unknown kind is a usage error" 64 "$RUN_RC"
"$REVIEW" --where --kind code --input main >"$WORK/where.out" 2>"$WORK/where.err"
expect_rc "--where takes --kind alone (--input)" 64 "$?"
"$REVIEW" --where --kind code --out "$WORK/where-findings.md" >"$WORK/where.out" 2>"$WORK/where.err"
expect_rc "--where takes --kind alone (--out)" 64 "$?"
check "--where with --out writes no findings" test ! -e "$WORK/where-findings.md"
"$REVIEW" --where --stamp --kind code >"$WORK/where.out" 2>"$WORK/where.err"
expect_rc "--where cannot be combined with --stamp" 64 "$?"
"$NO_ROUTE/opus-review.sh" --where --kind draft >"$WORK/where.out" 2>"$WORK/where.err"
expect_rc "--where on a route that cannot be read is a usage error" 64 "$?"
check "an unreadable route prints no verdict" test ! -s "$WORK/where.out"
check "an unreadable route is reported" grep -Fq 'printed nothing' "$WORK/where.err"

# --- The in-session form: --prompt and --stamp (票 #84) -------------------------
# Both exist only where --where says in-session; on any other verdict they
# refuse with 64 and write nothing. --prompt prints the review's text, --stamp
# writes the findings from stdin under the route line with its two marks.
prompt_review() { # kind input out
  "$REVIEW" --prompt --kind "$1" --input "$2" --out "$3" --cwd "$REPO" >"$WORK/prompt.out" 2>"$WORK/prompt.err"
  RUN_RC=$?
}
stamp_review() { # kind stdin-file out. A redirection, never a pipe: a function
  # in a pipeline runs in a subshell under bash 3.2, and RUN_RC would not
  # reach the caller.
  "$REVIEW" --stamp --kind "$1" --out "$3" <"$2" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
  RUN_RC=$?
}
# The last argument the fake claude got: the prompt of an out-of-session pass.
last_prompt() {
  awk '/^ARG\t/ { start = NR } { line[NR] = $0 } END { for (i = start; i <= NR; i++) print line[i] }' "$1" |
    sed "1s/^ARG\t//"
}
missing_items_block() { # the <missing-items> block of a repair brief or prompt, without its tags
  awk '/^<missing-items>$/ { on = 1; next } /^<\/missing-items>$/ { exit } on { print }' "$1"
}
no_temp_left() { # the findings path --stamp was given
  bash -c "! ls '$1'.* >/dev/null 2>&1"
}
only_rejected_left() { # the findings path --stamp was given: the refused findings are the one file left
  bash -c "[ \"\$(ls '$1'.* 2>/dev/null)\" = '$1.rejected' ]"
}
repair_prompt_review() { # kind out
  "$REVIEW" --repair-prompt --kind "$1" --out "$2" --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
  RUN_RC=$?
}

"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
in_session_env
rm -f "$FAKE_CLAUDE_LOG" "$FAKE_GLM_LOG"
prompt_review draft "$WORK/draft.md" "$WORK/p-official.md"
expect_rc "--prompt on the official route is refused" 64 "$RUN_RC"
check "a refused --prompt prints no text" test ! -s "$WORK/prompt.out"
check "a refused --prompt names the route and out-of-session" grep -Fq '审查中（claude / opus，出会话）' "$WORK/prompt.err"
printf 'findings\n' > "$WORK/in-body-plain.md"
stamp_review draft "$WORK/in-body-plain.md" "$WORK/p-official.md"
expect_rc "--stamp on the official route is refused" 64 "$RUN_RC"
check "a refused --stamp names the route" grep -Fq '审查中（claude / opus，出会话）' "$WORK/stamp.err"
check "a refused --stamp writes no findings" test ! -e "$WORK/p-official.md"
check "the official route's refusals start no launcher" no_launcher_called

"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
export CLAUDE_CODE_SUBAGENT_MODEL='glm-5.4[1m]' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=glm-5.4
prompt_review draft "$WORK/draft.md" "$WORK/p-unforced.md"
expect_rc "--prompt without the force is refused" 64 "$RUN_RC"
stamp_review draft "$WORK/in-body-plain.md" "$WORK/p-unforced.md"
expect_rc "--stamp without the force is refused" 64 "$RUN_RC"
check "a refused --stamp on a GLM route writes no findings" test ! -e "$WORK/p-unforced.md"
check "a refused --stamp says nothing was written" grep -Fq 'nothing written' "$WORK/stamp.err"

in_session_env
prompt_review draft "$WORK/draft.md" "$WORK/in-draft.md"
expect_rc "--prompt for a draft in session prints the text" 0 "$RUN_RC"
check "--prompt prints nothing on stderr in session" test ! -s "$WORK/prompt.err"
check "the in-session draft text starts with the subagent's line naming the route model" bash -c \
  "head -n 1 '$WORK/prompt.out' | grep -Fq 'You are a review running as a read-only subagent of the calling session, on glm-5.4'"
check "the in-session draft text does not say the review runs outside the session" \
  bash -c "! grep -Fq 'outside the calling session' '$WORK/prompt.out'"
check "the in-session draft text is the out-of-session prompt under another first line" \
  cmp -s <(tail -n +2 "$WORK/prompt.out") <(last_prompt "$WORK/draft-env-args.log" | tail -n +2)
check "the in-session draft text requires human-tradeoff findings" grep -Fq '需要人取舍' "$WORK/prompt.out"
check "the in-session draft text asks whether the recommendation can be auto-applied" grep -Fq '可自动采纳：否' "$WORK/prompt.out"
check "--prompt starts no launcher" no_launcher_called
"$ROUTE" use diagnosis=claude-glm/glm-5.4/low >/dev/null 2>&1
prompt_review diagnose "$WORK/failure.md" "$WORK/in-diagnose-prompt.md"
expect_rc "--prompt for diagnose in session prints the text" 0 "$RUN_RC"
check "the in-session diagnose text is the out-of-session prompt under another first line" \
  cmp -s <(tail -n +2 "$WORK/prompt.out") <(last_prompt "$WORK/diagnose-env-args.log" | tail -n +2)
check "the in-session diagnose text names the diagnosis model" \
  bash -c "head -n 1 '$WORK/prompt.out' | grep -Fq \"the user's diagnosis route names\""
"$ROUTE" use diagnosis=claude/opus/high >/dev/null 2>&1

prompt_review code main "$WORK/in-code.md"
expect_rc "--prompt for code in session prints the procedure" 0 "$RUN_RC"
check "the code text names the repository and the fixed point" bash -c \
  "grep -Fq 'Repository: $REPO' '$WORK/prompt.out' && grep -Fq 'Review fixed point: main' '$WORK/prompt.out'"
check "the code text keeps the two axes apart and aggregates them" bash -c \
  "grep -Fq 'Standards axis brief' '$WORK/prompt.out' && grep -Fq 'Spec axis brief' '$WORK/prompt.out' && grep -Fq 'Aggregate brief' '$WORK/prompt.out' && grep -Fq 'do not merge or rerank' '$WORK/prompt.out'"
check "the code text spawns Explore subagents and no other type" bash -c \
  "grep -Fq 'subagent_type Explore' '$WORK/prompt.out' && ! grep -Fq 'subagent_type general-purpose' '$WORK/prompt.out'"
check "the code text passes no model" grep -Fq 'no model is passed on any Agent call' "$WORK/prompt.out"
check "the code text names the skill whose process it restates" grep -Fq 'mattpocock-skills:code-review' "$WORK/prompt.out"
check "the code text carries the smell baseline" bash -c \
  "grep -Fq 'Mysterious Name' '$WORK/prompt.out' && grep -Fq 'Refused Bequest' '$WORK/prompt.out'"
check "the aggregate brief carries the tradeoff rules" bash -c \
  "grep -Fq '推荐：<option>' '$WORK/prompt.out' && grep -Fq '可自动采纳：否' '$WORK/prompt.out'"
check "the code text pipes the findings into --stamp with the same --out" \
  grep -Fq -- "$REVIEW --stamp --kind code --out '$WORK/in-code.md'" "$WORK/prompt.out"
check "the code text does not say the review runs outside the session" \
  bash -c "! grep -Fq 'outside the calling session' '$WORK/prompt.out'"
check "--prompt for code starts no launcher" no_launcher_called

"$REVIEW" --prompt --kind draft --out "$WORK/p-usage.md" --cwd "$REPO" >"$WORK/prompt.out" 2>"$WORK/prompt.err"
expect_rc "--prompt without --input is a usage error" 64 "$?"
"$REVIEW" --prompt --kind draft --input "$WORK/draft.md" --out "$WORK/p-usage.md" --timeout 5 --cwd "$REPO" >"$WORK/prompt.out" 2>"$WORK/prompt.err"
expect_rc "--prompt takes no --timeout" 64 "$?"
"$REVIEW" --prompt --kind draft --input "$WORK/no-such-draft.md" --out "$WORK/p-usage.md" --cwd "$REPO" >"$WORK/prompt.out" 2>"$WORK/prompt.err"
expect_rc "--prompt needs an existing --input file" 64 "$?"
check "a misused --prompt writes no findings" test ! -e "$WORK/p-usage.md"

rm -f "$WORK/in-stamped.md"
printf '%s\n' '## 需要人取舍' '1. 是否删除旧表' '   A. 删除' '   B. 保留' \
  '   推荐：A — 旧表已无引用' '   可自动采纳：是' > "$WORK/in-body-full.md"
stamp_review draft "$WORK/in-body-full.md" "$WORK/in-stamped.md"
expect_rc "--stamp writes findings with complete marks" 0 "$RUN_RC"
check "the stamped first line is the route line with the two marks" \
  bash -c "head -n 1 '$WORK/in-stamped.md' | grep -Eq '^路由：审查（review）claude-glm / glm-5.4 / medium（强度未生效）· [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}（会话内子代理）\$'"
check "the stamped route line is followed by a blank line" \
  bash -c "test \"\$(sed -n 2p '$WORK/in-stamped.md')\" = ''"
check "the stamped findings are kept verbatim after the route line" cmp -s <(tail -n +3 "$WORK/in-stamped.md") "$WORK/expected-fullmarks.md"
check "--stamp prints nothing on stdout" test ! -s "$WORK/stamp.out"
check "--stamp starts no launcher" no_launcher_called
check "--stamp leaves no temporary file behind" no_temp_left "$WORK/in-stamped.md"

rm -f "$WORK/in-missing.md" "$WORK/in-missing.md.rejected"
printf '%s\n' '## 需要人取舍' '1. 是否删除旧表' '   A. 删除' > "$WORK/in-body-missing.md"
stamp_review draft "$WORK/in-body-missing.md" "$WORK/in-missing.md"
expect_rc "--stamp with a missing mark exits 7" 7 "$RUN_RC"
check "the missing mark is listed on stderr" grep -Fq '1. 是否删除旧表' "$WORK/stamp.err"
check "a 7 from --stamp writes no findings" test ! -e "$WORK/in-missing.md"
check "a 7 from --stamp leaves only the refused findings behind" only_rejected_left "$WORK/in-missing.md"
check "the refused findings are kept verbatim as <out>.rejected" cmp -s "$WORK/in-missing.md.rejected" "$WORK/in-body-missing.md"
check "the 7 names where the refused findings are kept" grep -Fq "kept as $WORK/in-missing.md.rejected" "$WORK/stamp.err"

# --repair-prompt: the out-of-session repair prompt under the in-session
# first line, built from the findings --stamp refused.
repair_prompt_review draft "$WORK/in-missing.md"
expect_rc "--repair-prompt after a 7 prints the brief" 0 "$RUN_RC"
check "--repair-prompt prints nothing on stderr after a 7" test ! -s "$WORK/repair.err"
check "the repair brief's first line names the repair, the session and the route model" bash -c \
  "head -n 1 '$WORK/repair.out' | grep -Fq 'the same review, asked to repair your own previous output, running as a read-only subagent of the calling session on glm-5.4'"
check "the repair brief does not call the review an Opus one" bash -c "! grep -Fq 'Opus review' '$WORK/repair.out'"
check "the repair brief carries the refused findings" grep -Fq '1. 是否删除旧表' "$WORK/repair.out"
check "the repair brief names the marks to add" grep -Fq '可自动采纳：否 — <why>' "$WORK/repair.out"
check "the repair brief asks for the complete corrected response" grep -Fq 'Output the complete corrected response.' "$WORK/repair.out"
check "--repair-prompt starts no launcher" no_launcher_called
check "--repair-prompt writes nothing next to the findings file" only_rejected_left "$WORK/in-missing.md"

# The same body out of session, for the cmp: its repair pass's prompt is the
# in-session brief under another first line.
printf '%s\n' '## 需要人取舍' '1. 是否删除旧表' '   A. 删除' '   B. 保留' > "$WORK/in-body-missingmarks.md"
"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
export FAKE_CLAUDE_LOG="$WORK/in-repair-cmp.log" FAKE_CLAUDE_SCENARIO=missingmarks FAKE_CLAUDE_SCENARIO_2=fullmarks
reset_calls
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/in-repair-cmp.md" --cwd "$REPO" --timeout 5
expect_rc "the out-of-session repair for the cmp succeeds" 0 "$RUN_RC"
check "the out-of-session repair for the cmp ran two passes" test "$(call_count)" = 2
export FAKE_CLAUDE_LOG="$WORK/where-claude.log" FAKE_CLAUDE_SCENARIO=ok FAKE_CLAUDE_SCENARIO_2=
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
rm -f "$WORK/in-cmp.md" "$WORK/in-cmp.md.rejected"
stamp_review draft "$WORK/in-body-missingmarks.md" "$WORK/in-cmp.md"
expect_rc "the cmp body is refused with 7" 7 "$RUN_RC"
repair_prompt_review draft "$WORK/in-cmp.md"
check "the in-session repair brief is the out-of-session repair prompt under another first line" \
  cmp -s <(tail -n +2 "$WORK/repair.out") <(last_prompt "$WORK/in-repair-cmp.log" | tail -n +2)
rm -f "$WORK/in-cmp.md.rejected"

# Once a repair was asked for (<out>.rejected exists), a --stamp applies the
# out-of-session repair retry's checks too: a repair may add lines, never take
# the items away.
printf 'repaired without the section\n' > "$WORK/in-body-repaired-dropped.md"
stamp_review draft "$WORK/in-body-repaired-dropped.md" "$WORK/in-missing.md"
expect_rc "a re-stamp whose repair dropped the section exits 7" 7 "$RUN_RC"
check "the dropped section is reported" grep -Fq 'dropped ## 需要人取舍' "$WORK/stamp.err"
check "a dropped-section re-stamp writes no findings" test ! -e "$WORK/in-missing.md"
check "the dropped repair is what is kept as the refused findings" cmp -s "$WORK/in-missing.md.rejected" "$WORK/in-body-repaired-dropped.md"
repair_prompt_review draft "$WORK/in-missing.md"
expect_rc "--repair-prompt after the section was dropped exits 64" 64 "$RUN_RC"
check "--repair-prompt says there is nothing left to repair" grep -Fq 'nothing to repair' "$WORK/repair.err"
check "a refused --repair-prompt prints no text" test ! -s "$WORK/repair.out"

printf '## 需要人取舍\n无\n' > "$WORK/in-body-none.md"
stamp_review draft "$WORK/in-body-none.md" "$WORK/in-missing.md"
expect_rc "a re-stamp whose repair turned the section into 无 exits 7" 7 "$RUN_RC"
check "the 无 repair is reported" grep -Fq 'turned ## 需要人取舍 into 无' "$WORK/stamp.err"
check "a 无 re-stamp writes no findings" test ! -e "$WORK/in-missing.md"

stamp_review draft "$WORK/in-body-missing.md" "$WORK/in-missing.md"
expect_rc "a re-stamp that still lacks the marks exits 7" 7 "$RUN_RC"
check "the still-missing marks are reported as such" grep -Fq 'still lack 推荐：/可自动采纳： lines after one repair' "$WORK/stamp.err"
check "the still-missing item is listed on stderr" grep -Fq '1. 是否删除旧表' "$WORK/stamp.err"
check "a still-missing re-stamp writes no findings" test ! -e "$WORK/in-missing.md"

stamp_review draft "$WORK/in-body-full.md" "$WORK/in-missing.md"
expect_rc "a re-stamp with the marks repaired writes the findings" 0 "$RUN_RC"
check "the repaired findings are written verbatim after the route line" cmp -s <(tail -n +3 "$WORK/in-missing.md") "$WORK/expected-fullmarks.md"
check "a successful re-stamp removes the refused findings" test ! -e "$WORK/in-missing.md.rejected"
check "a successful re-stamp leaves no temporary file behind" no_temp_left "$WORK/in-missing.md"
repair_prompt_review draft "$WORK/in-missing.md"
expect_rc "--repair-prompt after a successful --stamp exits 64" 64 "$RUN_RC"

# Without a repair asked for, the first --stamp checks what the out-of-session
# first pass checks: a section that is absent or says 无 passes.
rm -f "$WORK/in-nosection.md" "$WORK/in-nosection.md.rejected"
stamp_review draft "$WORK/in-body-plain.md" "$WORK/in-nosection.md"
expect_rc "a first --stamp of findings without the section writes them, as out of session" 0 "$RUN_RC"
check "findings without the section are written verbatim after the route line" cmp -s <(tail -n +3 "$WORK/in-nosection.md") "$WORK/in-body-plain.md"
"$REVIEW" --repair-prompt --kind draft --out "$WORK/in-nosection.md" --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt with no refused findings exits 64" 64 "$?"
check "it names the refused file that does not exist" grep -Fq "$WORK/in-nosection.md.rejected does not exist" "$WORK/repair.err"

stamp_review draft "$WORK/in-body-none.md" "$WORK/in-none.md"
expect_rc "--stamp with a 无 section writes the findings" 0 "$RUN_RC"
check "a 无 section is written verbatim after the route line" cmp -s <(tail -n +3 "$WORK/in-none.md") "$WORK/marks-none-expected.md"

: > "$WORK/in-body-empty.md"
stamp_review code "$WORK/in-body-empty.md" "$WORK/in-empty.md"
expect_rc "--stamp with no findings on stdin exits 6" 6 "$RUN_RC"
check "empty stdin writes no findings" test ! -e "$WORK/in-empty.md"
printf ' \t\n' > "$WORK/in-body-ws.md"
stamp_review code "$WORK/in-body-ws.md" "$WORK/in-ws.md"
expect_rc "--stamp with whitespace only on stdin exits 6" 6 "$RUN_RC"
check "whitespace stdin writes no findings" test ! -e "$WORK/in-ws.md"
check "whitespace stdin leaves no temporary file behind" no_temp_left "$WORK/in-ws.md"
stamp_review code "$WORK/in-stamped.md" "$WORK/in-double.md"
expect_rc "--stamp of findings that already carry a route line exits 64" 64 "$RUN_RC"
check "a double stamp is reported as a mistake of the caller" grep -Fq 'already start with a 路由： line, so that file was stamped already' "$WORK/stamp.err"
check "a double stamp writes nothing" no_temp_left "$WORK/in-double.md"

"$ROUTE" use diagnosis=claude-glm/glm-5.4/low >/dev/null 2>&1
stamp_review diagnose "$WORK/in-body-full.md" "$WORK/in-diagnose.md"
expect_rc "--stamp for diagnose in session writes the findings" 0 "$RUN_RC"
check "the stamped diagnose first line names the diagnosis route with the two marks" \
  bash -c "head -n 1 '$WORK/in-diagnose.md' | grep -Eq '^路由：诊断（diagnosis）claude-glm / glm-5.4 / low（强度未生效）· [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} [+-][0-9]{4}（会话内子代理）\$'"
"$ROUTE" use diagnosis=claude/opus/high >/dev/null 2>&1

"$REVIEW" --stamp --kind draft --cwd "$REPO" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
expect_rc "--stamp without --out is a usage error" 64 "$?"
"$REVIEW" --stamp --kind draft --out "$WORK/s-usage.md" --input "$WORK/draft.md" --cwd "$REPO" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
expect_rc "--stamp takes no --input" 64 "$?"
"$REVIEW" --stamp --kind draft --out "$WORK/s-usage.md" --timeout 5 --cwd "$REPO" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
expect_rc "--stamp takes no --timeout" 64 "$?"
"$REVIEW" --stamp --kind nonsense --out "$WORK/s-usage.md" --cwd "$REPO" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
expect_rc "--stamp with an unknown kind is a usage error" 64 "$?"
"$NO_ROUTE/opus-review.sh" --stamp --kind draft --out "$WORK/s-usage.md" --cwd "$REPO" <"$WORK/in-body-plain.md" >"$WORK/stamp.out" 2>"$WORK/stamp.err"
expect_rc "--stamp on a route that cannot be read is a usage error" 64 "$?"
check "a misused --stamp writes no findings" test ! -e "$WORK/s-usage.md"

"$REVIEW" --repair-prompt --kind draft --out "$WORK/r-usage.md" --input "$WORK/draft.md" --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt takes no --input" 64 "$?"
"$REVIEW" --repair-prompt --kind draft --out "$WORK/r-usage.md" --timeout 5 --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt takes no --timeout" 64 "$?"
"$REVIEW" --repair-prompt --kind draft --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt without --out is a usage error" 64 "$?"
"$REVIEW" --repair-prompt --where --kind draft --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt cannot be combined with --where" 64 "$?"
"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
"$REVIEW" --repair-prompt --kind draft --out "$WORK/in-missing.md" --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt on the official route is refused" 64 "$?"
check "a refused --repair-prompt names the route and out-of-session" grep -Fq '审查中（claude / opus，出会话）' "$WORK/repair.err"
check "a refused --repair-prompt prints no text" test ! -s "$WORK/repair.out"
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
"$NO_ROUTE/opus-review.sh" --repair-prompt --kind draft --out "$WORK/r-usage.md" --cwd "$REPO" >"$WORK/repair.out" 2>"$WORK/repair.err"
expect_rc "--repair-prompt on a route that cannot be read is a usage error" 64 "$?"
check "a misused --repair-prompt writes nothing" no_temp_left "$WORK/r-usage.md"

# The plain command never decides on its own: with everything that makes a
# review in-session, it still runs the headless launcher, as before.
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
export FAKE_CLAUDE_SCENARIO=ok FAKE_CLAUDE_LOG="$WORK/plain-claude.log" FAKE_GLM_LOG="$WORK/plain-glm.log"
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/plain-findings.md" --cwd "$REPO" --timeout 5
expect_rc "the plain command still runs out of session when --where would say in-session" 0 "$RUN_RC"
check "the plain command called the GLM launcher" test -e "$FAKE_GLM_LOG"
check "the plain command's findings carry no in-session mark" bash -c "! grep -Fq '会话内子代理' '$WORK/plain-findings.md'"
check "the plain command's findings carry no effort mark" bash -c "! grep -Fq '强度未生效' '$WORK/plain-findings.md'"
check "the plain command's first line is the unchanged route line" \
  bash -c "head -n 1 '$WORK/plain-findings.md' | grep -Eq '^路由：审查（review）claude-glm / glm-5.4 / medium · [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} [+-][0-9]{4}\$'"
"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.4" CLAUDE_CODE_SUBAGENT_MODEL_FORCE="glm-5.4"
export FAKE_CLAUDE_LOG="$WORK/doc-claude.log" FAKE_GLM_LOG="$WORK/doc-glm.log"

EXIT_CODE_SENTENCE='退出码为 3（额度或 429）时按 quota 停车，2（认证失败）按 auth 停车，4 按 transient 停车，其余非 0 退出码按 error 停车并说明（退出码含义见 scripts/opus-review.sh 头注释）'
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
check "SKILL tells the reports to paste verify's route table and check lines (票 #47)" \
  bash -c "grep -Fq 'stage-dispatch.sh verify --run-dir <Spec Run root>' '$HERE/../SKILL.md' && grep -Fq '不适用' '$HERE/../SKILL.md'"
for doc in SKILL.md find-next/SKILL.md; do
  check "$doc no longer names the /judgment-model command" \
    bash -c "! grep -Fq '/judgment-model' '$HERE/../$doc'"
  check "$doc no longer names judgment-model.sh" \
    bash -c "! grep -Fq 'judgment-model.sh' '$HERE/../$doc'"
  check "$doc no longer names the 判断模型： first line" \
    bash -c "! grep -Fq '判断模型：' '$HERE/../$doc'"
done

# --- the route decides where a review runs, and names it (票 #84) ---------------

check "the wrapper header documents the three forms" bash -c \
  "grep -Fq -- '--where --kind code|draft|diagnose' '$HERE/opus-review.sh' && grep -Fq -- '--prompt --kind code' '$HERE/opus-review.sh' && grep -Fq -- '--stamp --kind code|draft|diagnose' '$HERE/opus-review.sh'"
check "the wrapper header documents the in-session first line" \
  grep -Fq '（强度未生效）· 2026-11-28 16:30:00 +0800（会话内子代理）' "$HERE/opus-review.sh"
check "the wrapper header documents that only the force set to 1 counts" \
  grep -Fq 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE is not exactly 1' "$HERE/opus-review.sh"
check "the wrapper header names the subagent type the hook allows" \
  grep -Fq 'hooks/subagent-guard.js' "$HERE/opus-review.sh"
for doc in SKILL.md find-next/SKILL.md; do
  check "$doc asks --where before a flash-mode review" bash -c "grep -Fq 'opus-review.sh --where --kind' '$HERE/../$doc'"
  check "$doc names --prompt and --stamp" \
    bash -c "grep -Fq 'opus-review.sh --prompt' '$HERE/../$doc' && grep -Fq 'opus-review.sh --stamp' '$HERE/../$doc'"
  check "$doc relays the route-named status line" grep -Fq '审查中（' "$HERE/../$doc"
  check "$doc names the in-session marks of the findings' first line" \
    bash -c "grep -Fq '（会话内子代理）' '$HERE/../$doc' && grep -Fq '强度未生效' '$HERE/../$doc'"
  check "$doc no longer calls the route-run review an Opus review" bash -c \
    "! grep -Eq 'Opus review (errors|不可用)|another Opus review|当轮 Opus review|合成 Opus review|Opus 审核中|Opus 的标记' '$HERE/../$doc'"
done
check "SKILL.md keeps the rule that an official route is never reviewed in session" \
  bash -c "grep -Fq 'mattpocock-skills:code-review' '$HERE/../SKILL.md' && grep -Fq 'model: REVIEW_MODEL' '$HERE/../SKILL.md'"
check "MAINTAINING 第 24 条 carries the 2026-11-28 note on GLM routes" \
  grep -Fq '2026-11-28 注，票 #84：用户把审查路由设为 GLM' "$HERE/../MAINTAINING.md"
check "ADR 0004 carries the 2026-11-28 note on where a review runs" \
  grep -Fq '2026-11-28 注，票 #84' "$HERE/../docs/adr/0004-stage-routes-on-orca.md"
check "GLOSSARY's Stage route says the route also decides where a review runs" \
  grep -Fq 'opus-review.sh --where' "$HERE/../GLOSSARY.md"

# --- what a refused --stamp leaves behind, and the repair brief (票 #84, r2) ---

check "the wrapper header documents where refused findings are kept" grep -Fq '<out>.rejected' "$HERE/opus-review.sh"
check "the wrapper header documents --repair-prompt" \
  grep -Fq -- '--repair-prompt --kind code|draft|diagnose' "$HERE/opus-review.sh"
check "the exit-code table documents 64 for findings already stamped" \
  grep -Fq 'call given findings that already start with a 路由： line' "$HERE/opus-review.sh"
check "the exit-code table documents the re-stamp checks under code 7" \
  grep -Fq 'repair that dropped the section or turned it into' "$HERE/opus-review.sh"
for doc in SKILL.md find-next/SKILL.md; do
  check "$doc names --repair-prompt" grep -Fq 'opus-review.sh --repair-prompt' "$HERE/../$doc"
  check "$doc names where the refused findings are kept" grep -Fq '.rejected' "$HERE/../$doc"
done
check "SKILL.md's in-session step 4 asks the wrapper for the repair brief" \
  grep -Fq 'opus-review.sh --repair-prompt --kind <kind> --out <findings file>' "$HERE/../SKILL.md"
check "find-next's flash section asks the wrapper for the repair brief" \
  grep -Fq 'opus-review.sh --repair-prompt --kind draft --out <同一个 findings 文件>' "$HERE/../find-next/SKILL.md"
check "MAINTAINING's flash design point carries the 2026-11-28 note on GLM routes" \
  grep -Fq '（2026-11-28 注，票 #84：用户把审查路由明确设为 GLM 时' "$HERE/../MAINTAINING.md"
check "MAINTAINING 第 29 条 no longer says flash follows only Opus's marks" \
  bash -c "! grep -Fq '只照 Opus 的标记执行' '$HERE/../MAINTAINING.md' && grep -Fq '只照审查 findings 的标记执行' '$HERE/../MAINTAINING.md'"
check "ADR 0001 carries the 2026-11-28 note on a GLM review route" \
  grep -Fq '2026-11-28 注，票 #84' "$HERE/../docs/adr/0001-cheap-orchestrator-default-deny.md"
check "GLOSSARY's Review roles say the subagent model is the review route's" \
  grep -Fq 'the subagent model is the review route' "$HERE/../GLOSSARY.md"

# --- a 需要人取舍 section written as a flat list (票 #84, r3) --------------------
# The check reads items, not lines: a title with the options and marks as
# bulleted lines at the left margin is one item with its marks, as it is with
# them indented. Out of session, on the official route: all marked passes in
# one pass; an item without any mark line is repaired once, and what the
# repair prompt lists is that item's title alone.
"$ROUTE" use review=claude/opus/high >/dev/null 2>&1
export FAKE_CLAUDE_SCENARIO=body FAKE_CLAUDE_BODY="$WORK/flat-bold.md" FAKE_CLAUDE_BODY_2=
export FAKE_CLAUDE_LOG="$WORK/marks-flat.log"
reset_calls
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-flat.md" --cwd "$REPO" --timeout 5
expect_rc "a flat list whose items all carry their marks succeeds" 0 "$RUN_RC"
check "a flat list needs no repair retry" test "$(call_count)" = 1
check "flat list findings are kept verbatim after the route line" cmp -s <(tail -n +3 "$WORK/marks-flat.md") "$WORK/flat-bold.md"
check "each bare flat body lacks exactly the third item's marks" bash -c \
  "test \"\$(grep -c '^- 可自动采纳：' '$WORK/flat-bold-bare.md')\" = 7 && test \"\$(grep -c '^- 可自动采纳：' '$WORK/flat-numbered-bare.md')\" = 7 && test \"\$(grep -c '^- 可自动采纳：' '$WORK/flat-bullet-bare.md')\" = 7"

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-flat-repair.log" FAKE_CLAUDE_BODY="$WORK/flat-bold-bare.md" FAKE_CLAUDE_BODY_2="$WORK/flat-bold.md"
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-flat-repaired.md" --cwd "$REPO" --timeout 5
expect_rc "a flat list with a bare item is repaired by one retry" 0 "$RUN_RC"
check "the flat list repair retry runs exactly once" test "$(call_count)" = 2
last_prompt "$FAKE_CLAUDE_LOG" > "$WORK/flat-repair-prompt.txt"
check "the repair prompt lists the bare item by its title alone" \
  test "$(missing_items_block "$WORK/flat-repair-prompt.txt")" = '**3.【Standards 判断项 4】第三条：首行写入两份**'

reset_calls
export FAKE_CLAUDE_LOG="$WORK/marks-flat-failed.log" FAKE_CLAUDE_BODY="$WORK/flat-bold-bare.md" FAKE_CLAUDE_BODY_2=
run_review --kind draft --input "$WORK/draft.md" --out "$WORK/marks-flat-failed.md" --cwd "$REPO" --timeout 5
expect_rc "a flat list whose bare item stays bare exits 7" 7 "$RUN_RC"
check "the bare item's title is what the unrepaired retry reports" \
  grep -Fq '**3.【Standards 判断项 4】第三条：首行写入两份**' "$WORK/run.err"
check "no marked line is reported as missing" bash -c \
  "! grep -Fq -- '- 推荐：' '$WORK/run.err' && ! grep -Fq -- '- 可自动采纳：' '$WORK/run.err'"
check "the flat list failure writes no findings" test ! -e "$WORK/marks-flat-failed.md"
export FAKE_CLAUDE_SCENARIO=ok FAKE_CLAUDE_BODY="" FAKE_CLAUDE_BODY_2=""

# In session, through --stamp, for the three shapes of title: all marked
# passes at the first stamp; the third item without any mark line is still
# refused, and it is the title --stamp and --repair-prompt name, never an
# option or a marked line.
"$ROUTE" use review=claude-glm/glm-5.4/medium >/dev/null 2>&1
in_session_env
rm -f "$FAKE_CLAUDE_LOG" "$FAKE_GLM_LOG"
for shape in bold numbered bullet; do
  case "$shape" in
    bold) title='**3.【Standards 判断项 4】第三条：首行写入两份**' ;;
    numbered) title='3. **【Standards 判断项 4】第三条：首行写入两份**' ;;
    bullet) title='- **3.【Standards 判断项 4】第三条：首行写入两份**' ;;
  esac
  rm -f "$WORK/in-flat-$shape.md" "$WORK/in-flat-$shape.md.rejected"
  stamp_review draft "$WORK/flat-$shape.md" "$WORK/in-flat-$shape.md"
  expect_rc "a flat list with $shape titles and every mark passes --stamp at once" 0 "$RUN_RC"
  check "the flat list with $shape titles is written verbatim after the route line" \
    cmp -s <(tail -n +3 "$WORK/in-flat-$shape.md") "$WORK/flat-$shape.md"

  rm -f "$WORK/in-flat-$shape-bare.md" "$WORK/in-flat-$shape-bare.md.rejected"
  stamp_review draft "$WORK/flat-$shape-bare.md" "$WORK/in-flat-$shape-bare.md"
  expect_rc "a flat list with $shape titles and a bare item still exits 7" 7 "$RUN_RC"
  check "the bare item is named by its title ($shape titles)" grep -Fq -- "$title" "$WORK/stamp.err"
  check "no option or mark line is listed as missing ($shape titles)" bash -c \
    "! grep -Fq -- '- 推荐：' '$WORK/stamp.err' && ! grep -Fq -- '- 可自动采纳：' '$WORK/stamp.err' && ! grep -Fq -- '- A：' '$WORK/stamp.err'"
  check "a 7 on a flat list writes no findings ($shape titles)" test ! -e "$WORK/in-flat-$shape-bare.md"
done
repair_prompt_review draft "$WORK/in-flat-bold-bare.md"
expect_rc "--repair-prompt after a flat list 7 prints the brief" 0 "$RUN_RC"
check "the repair brief's <missing-items> holds the bare item's title alone" \
  test "$(missing_items_block "$WORK/repair.out")" = '**3.【Standards 判断项 4】第三条：首行写入两份**'
check "the repair brief still carries every refused line, the marked ones too" \
  grep -Fq -- '- 可自动采纳：否 — 要写 issue 评论，是人的动作' "$WORK/repair.out"
rm -f "$WORK"/in-flat-*.rejected
check "the flat list checks start no launcher" no_launcher_called

# --- the in-session briefs against the upstream skill (票 #84, r3) ---------------
# The Standards and Spec briefs and the smell baseline that --prompt --kind code
# carries are the upstream skill's own words. Where that skill is installed
# every passage is compared verbatim: a difference fails, and so does an
# upstream that no longer yields two briefs and twelve smells.
if [ -f "$UPSTREAM_SKILL" ]; then
  awk '
    /^- The brief: "Report, per file/ || /^- The brief: "Report: \(a\) requirements/ {
      sub(/^- The brief: "/, ""); sub(/"$/, ""); print; next
    }
    /^- \*\*[A-Z][A-Za-z ]+\*\*: .* → / { print }
  ' "$UPSTREAM_SKILL" > "$WORK/upstream-passages.txt"
  prompt_review code main "$WORK/drift.md"
  expect_rc "--prompt for the upstream comparison prints the code text" 0 "$RUN_RC"
  check "the upstream skill yields two briefs and twelve smells" \
    test "$(wc -l < "$WORK/upstream-passages.txt" | tr -d ' ')" = 14
  DRIFT=0
  while IFS= read -r passage; do
    grep -Fq -- "$passage" "$WORK/prompt.out" || { DRIFT=$((DRIFT + 1)); echo "  drifts from the upstream: ${passage:0:80}"; }
  done < "$WORK/upstream-passages.txt"
  check "the in-session briefs and smell baseline match the upstream skill verbatim" test "$DRIFT" = 0
  rm -f "$WORK/upstream-passages.txt"
else
  echo "SKIP the in-session briefs against the upstream skill: $UPSTREAM_SKILL is not installed here"
fi
"$ROUTE" use review=claude/opus/high >/dev/null 2>&1

# --- the wording the in-session form settled (票 #84, r3) ------------------------
check "SKILL.md keeps REVIEW_MODEL explicit and names the in-session exception" bash -c \
  "grep -Fq 'model: REVIEW_MODEL' '$HERE/../SKILL.md' && grep -Fq 'its subagents are spawned with no \`model\` on purpose' '$HERE/../SKILL.md'"
check "MAINTAINING 设计要点 1 carries the 2026-11-28 note on the in-session exception" \
  grep -Fq '（2026-11-28 注，票 #84：唯一的例外是 flash 会话的会话内审查子代理——它们有意不传 `model`、继承会话模型' "$HERE/../MAINTAINING.md"
check "MAINTAINING 设计要点 3 carries the 2026-11-28 note on the in-session form" \
  grep -Fq '（2026-11-28 注，票 #84：会话内形态是有意的例外——flash 会话在会话内审查时不按全名调这个技能' "$HERE/../MAINTAINING.md"
check "GLOSSARY defines 审查（review） and retires Opus review" bash -c \
  "grep -Fq '**审查（review）**:' '$HERE/../GLOSSARY.md' && grep -Fq 'Retired (票 #84, 2026-11-28)' '$HERE/../GLOSSARY.md'"
grep -F -- '- **审查（review）入口**：' "$HERE/../MAINTAINING.md" > "$WORK/review-entry.txt"
check "MAINTAINING's self-test entry for the review is renamed after the term" \
  grep -Fq -- '- **审查（review）入口**：`bash scripts/test-opus-review.sh`' "$HERE/../MAINTAINING.md"
check "MAINTAINING's self-test entry for the review covers the four in-session forms" bash -c \
  "grep -Fq -- '\`--where\`' '$WORK/review-entry.txt' && grep -Fq -- '\`--prompt\`' '$WORK/review-entry.txt' && grep -Fq -- '\`--stamp\`' '$WORK/review-entry.txt' && grep -Fq -- '\`--repair-prompt\`' '$WORK/review-entry.txt'"

if [ "$FAIL" -gt 0 ]; then
  echo "Artifacts: $WORK"
fi
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
