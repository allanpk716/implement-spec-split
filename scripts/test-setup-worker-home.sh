#!/usr/bin/env bash
# Deterministic tests for setup-worker-home.sh using only fake source/target homes.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SETUP="$HERE/setup-worker-home.sh"

winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  node -e 'process.exit(process.platform === "win32" ? 0 : 1)'
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/setup-worker-home-test.XXXXXX")
export HOME="$WORK/home"
SOURCE="$HOME/.codex"
TARGET="$HOME/.codex-worker"

PASS=0
FAIL=0
RUN_RC=0

pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
expect_rc() {
  local description="$1" wanted="$2" got="$3"
  if [ "$wanted" -eq "$got" ]; then pass "$description"; else fail "$description (wanted $wanted, got $got)"; fi
}
run_setup() {
  local out="$1" err="$2"; shift 2
  env -u CODEX_WORKER_HOME bash "$SETUP" "$@" >"$out" 2>"$err"
  RUN_RC=$?
}
count_backups() {
  local item count=0
  for item in "$TARGET"/config.toml.bak-*; do
    [ -f "$item" ] && count=$((count + 1))
  done
  echo "$count"
}

mkdir -p "$SOURCE/skills/ssh-manager" "$SOURCE/sessions/2026/01/01"
cat > "$SOURCE/config.toml" <<'EOF'
model_provider = "custom"
model = "worker-model"
model_reasoning_effort = "medium"
model_catalog_json = "~/.codex/models.json"
approvals_reviewer = "DROP-APPROVALS-VALUE"
screen_reader_detection_done = true
status_line = "DROP-STATUS-VALUE"
status_line_secondary = "DROP-STATUS-VALUE"
unknown_root = "DROP-ROOT-VALUE"

[model_providers.custom]
name = "custom"
base_url = "https://api.example.invalid/v1"
experimental_bearer_token = "FAKE-SECRET-123"
wire_api = "responses"

[model_providers."other provider"]
experimental_bearer_token = "FAKE-SECRET-456"

[mcp_servers.ssh-manager]
command = "sshmgr"

[mcp_servers."web search"]
command = "websearch"

[mcp_servers."web search".env]
QUERY = "fake-query"

[agents]
max_concurrent_threads_per_session = 3

[hooks]
enabled = true

[hooks.state."ready"]
value = "DROP-HOOK-VALUE"

[projects."/tmp/path with spaces"]
trust = "DROP-PROJECT-VALUE"

[experimental_table]
value = "DROP-TABLE-VALUE"
EOF
printf '{"models":["worker-model"]}\n' > "$SOURCE/models.json"
printf 'worker instructions\n' > "$SOURCE/AGENTS.md"
printf 'skill instructions\n' > "$SOURCE/skills/ssh-manager/x.md"
printf 'interactive hooks\n' > "$SOURCE/hooks.json"
printf 'old session\n' > "$SOURCE/sessions/2026/01/01/rollout-old.jsonl"
printf 'interactive history\n' > "$SOURCE/history.jsonl"
printf 'interactive state\n' > "$SOURCE/state.sqlite"

run_setup "$WORK/run1.out" "$WORK/run1.err" --from "$SOURCE" --to "$TARGET"
expect_rc "first setup succeeds" 0 "$RUN_RC"
check "provider config is preserved" grep -Fq "experimental_bearer_token = \"FAKE-SECRET-123\"" "$TARGET/config.toml"
check "second provider is preserved" grep -Fq "[model_providers.\"other provider\"]" "$TARGET/config.toml"
check "quoted MCP table is preserved" grep -Fq "[mcp_servers.\"web search\"]" "$TARGET/config.toml"
check "MCP env subtable is preserved" grep -Fq "[mcp_servers.\"web search\".env]" "$TARGET/config.toml"
check "agents table is preserved" grep -Fq "[agents]" "$TARGET/config.toml"
check "interactive root keys are dropped" bash -c "! grep -Eq '^(approvals_reviewer|screen_reader_detection_done|status_line|status_line_secondary|unknown_root)[[:space:]]*=' '$TARGET/config.toml'"
check "interactive tables are dropped" bash -c "! grep -Eq '^\[+\\s*(hooks|projects|experimental_table)(\\.|\\]|\\s)' '$TARGET/config.toml'"
check "dropped values are absent" bash -c "! grep -q 'DROP-' '$TARGET/config.toml'"
EXPECTED_CATALOG=$(TARGET="$(winpath "$(cd "$TARGET" && pwd -P)")/models.json" node -e 'console.log(`model_catalog_json = ${JSON.stringify(process.env.TARGET)}`)')
check "model catalog points into worker home" grep -Fq "$EXPECTED_CATALOG" "$TARGET/config.toml"
check "models.json is copied" cmp -s "$SOURCE/models.json" "$TARGET/models.json"
check "AGENTS.md is copied" cmp -s "$SOURCE/AGENTS.md" "$TARGET/AGENTS.md"
check "ssh-manager skill is copied" cmp -s "$SOURCE/skills/ssh-manager/x.md" "$TARGET/skills/ssh-manager/x.md"
check "sessions directory is created" test -d "$TARGET/sessions"
check "source sessions are not copied" test ! -e "$TARGET/sessions/2026"
check "hooks.json is not copied" test ! -e "$TARGET/hooks.json"
check "history is not copied" test ! -e "$TARGET/history.jsonl"
check "sqlite state is not copied" test ! -e "$TARGET/state.sqlite"
if is_windows; then
  echo "SKIP config permission is 600 (Windows chmod semantics)"
else
  CONFIG="$TARGET/config.toml" check "config permission is 600" node -e 'const fs=require("fs");process.exit((fs.statSync(process.env.CONFIG).mode & 0o777) === 0o600 ? 0 : 1)'
fi
check "stdout lists dropped key names" bash -c "grep -Fq 'approvals_reviewer' '$WORK/run1.out' && grep -Fq 'status_line_secondary' '$WORK/run1.out'"
check "stdout lists dropped table names" bash -c "grep -Fq 'hooks' '$WORK/run1.out' && grep -Fq 'projects' '$WORK/run1.out'"
check "stdout does not expose config values" bash -c "! grep -Eq 'FAKE-SECRET|DROP-' '$WORK/run1.out'"
check "stderr does not expose config values" bash -c "! grep -Eq 'FAKE-SECRET|DROP-' '$WORK/run1.err'"

cp "$TARGET/config.toml" "$WORK/config-first.toml"
BEFORE=$(count_backups)
run_setup "$WORK/run2.out" "$WORK/run2.err" --from "$SOURCE" --to "$TARGET"
expect_rc "second setup succeeds" 0 "$RUN_RC"
check "identical second run creates no backup" test "$(count_backups)" -eq "$BEFORE"
check "identical second run keeps config content" cmp -s "$WORK/config-first.toml" "$TARGET/config.toml"
check "second run output does not expose config values" bash -c "! grep -Eq 'FAKE-SECRET|DROP-' '$WORK/run2.out' '$WORK/run2.err'"

printf '# local mutation for backup test\n' >> "$TARGET/config.toml"
run_setup "$WORK/run3.out" "$WORK/run3.err" --from "$SOURCE" --to "$TARGET"
expect_rc "setup after mutation succeeds" 0 "$RUN_RC"
check "changed config is restored" cmp -s "$WORK/config-first.toml" "$TARGET/config.toml"
check "changed config is backed up" bash -c "grep -Fq '# local mutation for backup test' '$TARGET'/config.toml.bak-*"
check "third run output does not expose config values" bash -c "! grep -Eq 'FAKE-SECRET|DROP-' '$WORK/run3.out' '$WORK/run3.err'"
if is_windows; then
  echo "SKIP restored config permission is 600 (Windows chmod semantics)"
else
  CONFIG="$TARGET/config.toml" check "restored config permission is 600" node -e 'const fs=require("fs");process.exit((fs.statSync(process.env.CONFIG).mode & 0o777) === 0o600 ? 0 : 1)'
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
echo "WORK=$WORK (left in place: the Brief forbids recursive cleanup)"
[ "$FAIL" -eq 0 ]
