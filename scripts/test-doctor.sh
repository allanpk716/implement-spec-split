#!/usr/bin/env bash
# Isolated integration tests for scripts/doctor.sh.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCTOR=$ROOT/scripts/doctor.sh
NODE_DIR=$(cd "$(dirname "$(command -v node)")" && pwd)
WORK=$(mktemp -d)
CASE_INDEX=0
FAILED=0
PASSED=0

record() {
  local status=$1 name=$2 detail=${3:-}
  if [ "$status" = PASS ]; then
    printf 'PASS %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$name" "${detail:+: $detail}"
    FAILED=$((FAILED + 1))
  fi
}

new_case() {
  CASE_INDEX=$((CASE_INDEX + 1))
  CASE_DIR=$WORK/case-$CASE_INDEX
  CASE_HOME=$CASE_DIR/home
  CASE_CLAUDE=$CASE_HOME/.claude
  CASE_CODEX=$CASE_HOME/.codex
  CASE_BIN=$CASE_DIR/bin
  mkdir -p "$CASE_CLAUDE/state" "$CASE_CLAUDE/plugins" "$CASE_CODEX" "$CASE_BIN"
  cat > "$CASE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "${FAKE_CODEX_VERSION:-0.163.0}"
  exit 0
fi
exit 1
EOF
  chmod +x "$CASE_BIN/codex"
  printf '%s\n' '{"version":1,"plugins":{"mattpocock-skills@mattpocock":[]}}' > "$CASE_CLAUDE/plugins/installed_plugins.json"
  printf '%s\n' 'model_provider = "custom"' > "$CASE_CODEX/config.toml"
  printf '\n%s\n' '[model_providers.custom]' >> "$CASE_CODEX/config.toml"
  printf '%s\n' 'base_url = "https://api.example.invalid/v1"' >> "$CASE_CODEX/config.toml"
  printf '%s\n' 'wire_api = "responses"' >> "$CASE_CODEX/config.toml"
  printf '<!-- opus-codex-division: v1 -->\n' > "$CASE_CLAUDE/CLAUDE.md"
  hook_settings "$ROOT/hooks/delegate-guard.js" 'Edit|Write|NotebookEdit' > "$CASE_CLAUDE/settings.json"
}

hook_settings() {
  HOOK_PATH=$1 MATCHER=$2 node - <<'NODE'
const path = require('path');
const hookPath = process.env.HOOK_PATH;
const normalized = process.platform === 'win32' && /^\/[A-Za-z]\//.test(hookPath)
  ? hookPath.replace(/^\/([A-Za-z])\//, '$1:/')
  : hookPath;
process.stdout.write(JSON.stringify({
  hooks: {
    PreToolUse: [{
      matcher: process.env.MATCHER,
      hooks: [{type: 'command', command: `node "${normalized}"`, timeout: 5}],
    }],
  },
}, null, 2) + '\n');
NODE
}

run_doctor() {
  local args=("$@")
  env HOME="$CASE_HOME" CLAUDE_CONFIG_DIR="$CASE_CLAUDE" CODEX_HOME="$CASE_CODEX" PATH="$CASE_BIN:$PATH" \
    bash "$DOCTOR" "${args[@]}" > "$CASE_DIR/doctor.out" 2> "$CASE_DIR/doctor.err"
  RUN_EXIT=$?
}

run_doctor_without_codex() {
  local args=("$@")
  env HOME="$CASE_HOME" CLAUDE_CONFIG_DIR="$CASE_CLAUDE" CODEX_HOME="$CASE_CODEX" \
    PATH="$CASE_BIN:$NODE_DIR:/mingw64/bin:/usr/bin:/bin" \
    bash "$DOCTOR" "${args[@]}" > "$CASE_DIR/doctor.out" 2> "$CASE_DIR/doctor.err"
  RUN_EXIT=$?
}

expect_exit() {
  local expected=$1 name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected; $(tail -n 2 "$CASE_DIR/doctor.err" 2>/dev/null)"
  fi
}

expect_has() {
  local level=$1 text=$2 name=$3
  OUT_FILE=$CASE_DIR/doctor.out LEVEL=$level TEXT=$text node - <<'NODE' && record PASS "$name" || record FAIL "$name" "missing [$level] $text"
const out = JSON.parse(require('fs').readFileSync(process.env.OUT_FILE, 'utf8'));
process.exit(out.checks.some(c => c.level === process.env.LEVEL && c.message.includes(process.env.TEXT)) ? 0 : 1);
NODE
}

expect_none() {
  local level=$1 name=$2
  OUT_FILE=$CASE_DIR/doctor.out LEVEL=$level node - <<'NODE' && record PASS "$name" || record FAIL "$name" "unexpected [$level]"
const out = JSON.parse(require('fs').readFileSync(process.env.OUT_FILE, 'utf8'));
process.exit(out.checks.some(c => c.level === process.env.LEVEL) ? 1 : 0);
NODE
}

free_port() {
  node -e 'const n=require("net"),s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

start_listener() {
  LISTEN_PORT=$1
  LISTEN_PID_FILE=$CASE_DIR/listener.pid
  PORT=$LISTEN_PORT node - > "$CASE_DIR/listener.ready" <<'NODE' &
const net = require('net');
const server = net.createServer();
server.listen(Number(process.env.PORT), '127.0.0.1', () => console.log('ready'));
NODE
  LISTENER_PID=$!
  printf '%s\n' "$LISTENER_PID" > "$LISTEN_PID_FILE"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$CASE_DIR/listener.ready" ] && break
    sleep 0.1
  done
}

stop_listener() {
  if [ -f "$LISTEN_PID_FILE" ]; then
    kill "$(cat "$LISTEN_PID_FILE")" 2>/dev/null || true
    wait "$(cat "$LISTEN_PID_FILE")" 2>/dev/null || true
  fi
}

# 1. Correct full configuration.
new_case
run_doctor --json
expect_exit 0 "full configuration has no FAIL exit"
expect_none FAIL "full configuration has no FAIL"
expect_has PASS "delegate-guard 冒烟测试" "full configuration smoke hook"

# 2. Stage 3 entirely absent.
new_case
rm -f "$CASE_CLAUDE/settings.json" "$CASE_CLAUDE/CLAUDE.md"
run_doctor --json
expect_exit 0 "unconfigured stage 3 has no FAIL exit"
expect_none FAIL "unconfigured stage 3 has no FAIL"
expect_has INFO "阶段 3 未配置" "unconfigured stage 3 reports INFO"

# 3. Hook only.
new_case
rm -f "$CASE_CLAUDE/CLAUDE.md"
run_doctor --json
expect_exit 1 "half-configured stage 3 exits 1"
expect_has FAIL "只配置了一半" "half-configured stage 3 reports FAIL"

# 4. Hook path does not exist.
new_case
hook_settings "$CASE_DIR/missing/delegate-guard.js" 'Edit|Write|NotebookEdit' > "$CASE_CLAUDE/settings.json"
run_doctor --json
expect_exit 1 "missing hook path exits 1"
expect_has FAIL "delegate-guard.js 不存在" "missing hook path reports FAIL"

# 5. Matcher only covers Bash.
new_case
hook_settings "$ROOT/hooks/delegate-guard.js" 'Bash' > "$CASE_CLAUDE/settings.json"
run_doctor --json
expect_exit 1 "Bash-only matcher exits 1"
expect_has FAIL "未同时覆盖 Edit 和 Write" "Bash-only matcher reports FAIL"

# 6. Installed rule version is v0.
new_case
printf '<!-- opus-codex-division: v0 -->\n' > "$CASE_CLAUDE/CLAUDE.md"
run_doctor --json
expect_exit 0 "stale rule version exits 0"
expect_has WARN "模板是 v1" "stale rule version reports WARN"

# 7. Unverified codex version.
new_case
run_doctor --json
FAKE_CODEX_VERSION=0.170.0 run_doctor --json
expect_exit 0 "codex 0.170.0 exits 0"
expect_has WARN "未经验证" "codex 0.170.0 reports WARN"

# 8. codex absent while stage 3 configured.
new_case
rm -f "$CASE_BIN/codex"
run_doctor_without_codex --json
expect_exit 1 "missing codex with stage 3 exits 1"
expect_has FAIL "codex 未安装" "missing codex with stage 3 reports FAIL"

# 9. codex absent without stage 3.
new_case
rm -f "$CASE_BIN/codex" "$CASE_CLAUDE/settings.json" "$CASE_CLAUDE/CLAUDE.md"
run_doctor_without_codex --json
expect_exit 0 "missing codex without stage 3 exits 0"
expect_none FAIL "missing codex without stage 3 has no FAIL"
expect_has WARN "codex 未安装" "missing codex without stage 3 reports WARN"

# 10. Loopback URL on an idle port.
new_case
IDLE_PORT=$(free_port)
printf '%s\n' "base_url = 'http://127.0.0.1:$IDLE_PORT/v1'" > "$CASE_CODEX/config.toml"
printf '\n%s\n' '[model_providers.custom]' >> "$CASE_CODEX/config.toml"
printf '%s\n' "base_url = 'http://127.0.0.1:$IDLE_PORT/v1'" >> "$CASE_CODEX/config.toml"
run_doctor --json
expect_exit 1 "idle local proxy exits 1"
expect_has FAIL "本地代理" "idle local proxy reports FAIL"

# 11. Loopback URL on a listening port.
new_case
LIVE_PORT=$(free_port)
start_listener "$LIVE_PORT"
printf '\n%s\n' '[model_providers.custom]' > "$CASE_CODEX/config.toml"
printf '%s\n' "base_url = 'http://127.0.0.1:$LIVE_PORT/v1'" >> "$CASE_CODEX/config.toml"
run_doctor --json
expect_exit 0 "listening local proxy exits 0"
expect_has PASS "可达" "listening local proxy reports PASS"
stop_listener

# 12. Preflight disabled.
new_case
CODEX_WORKER_PREFLIGHT=off run_doctor --json
expect_exit 0 "disabled preflight exits 0"
expect_has INFO "预检已通过环境变量关闭" "disabled preflight reports INFO"

# 13. Unexpired override.
new_case
date -u -d '+60 minutes' +%s > "$CASE_CLAUDE/state/allow-direct-edit"
run_doctor --json
expect_exit 0 "active override exits 0"
expect_has WARN "例外开关绕过" "active override reports WARN"

# 14. Today's hook error log.
new_case
date -u '+%Y-%m-%dT%H:%M:%SZ error delegate-guard failed open: test' > "$CASE_CLAUDE/state/delegate-guard.log"
run_doctor --json
expect_exit 0 "recent hook error exits 0"
expect_has WARN "有 error" "recent hook error reports WARN"

# 15. Plugin file absent.
new_case
rm -f "$CASE_CLAUDE/plugins/installed_plugins.json"
run_doctor --json
expect_exit 0 "missing plugin file exits 0"
expect_has WARN "未找到 mattpocock-skills" "missing plugin file reports WARN"

# 16. English output contains no CJK characters.
new_case
run_doctor --json --lang en
expect_exit 0 "English output exits 0"
OUT_FILE=$CASE_DIR/doctor.out node - <<'NODE' && record PASS "English output has no Chinese" || record FAIL "English output has no Chinese" "CJK character found"
const out = require('fs').readFileSync(process.env.OUT_FILE, 'utf8');
process.exit(/[\u3400-\u9fff]/.test(out) ? 1 : 0);
NODE

# 17. Unknown argument.
new_case
run_doctor --unknown
expect_exit 64 "unknown argument exits 64"

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi

WORK=$WORK node - <<'NODE'
const fs = require('fs');
fs.rmSync(process.env.WORK, {recursive: true, force: true});
NODE
exit "$FAILED"
