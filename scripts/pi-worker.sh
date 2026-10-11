#!/usr/bin/env bash
# Run one External worker: a headless pi process on GLM, inside a worktree, with a Brief.
#
# Usage:
#   pi-worker.sh --cwd <worktree> --brief <file> --run-dir <dir>
#                [--model glm/glm-5.3] [--timeout 1800] [--retries 2] [--retry-wait 60]
#                [--thinking <level>] [--skill <dir>]...
#
# Writes into --run-dir: brief.md, events.jsonl, stderr.log, sessions/, result.md, status.json.
# Prints status.json on stdout. Exit codes:
#   0 ok (pi finished without an API error) | 2 auth error | 3 quota exhausted | 4 transient error (retries used up)
#   5 timeout | 6 other error | 64 bad usage
#
# Never trust "ok" alone: it only means pi finished without an API error. The caller
# still checks the worktree (new commits, clean tree) and re-runs the tests.

set -u

MODEL="glm/glm-5.3"
TIMEOUT=1800
RETRIES=2
RETRY_WAIT=60
THINKING=""
CWD=""
BRIEF=""
RUN_DIR=""
SKILLS=()

die() { echo "pi-worker: $*" >&2; exit 64; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --retry-wait) RETRY_WAIT="$2"; shift 2 ;;
    --thinking) THINKING="$2"; shift 2 ;;
    --skill) SKILLS+=("$2"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$CWD" ] && [ -d "$CWD" ] || die "--cwd must be an existing directory"
[ -n "$BRIEF" ] && [ -f "$BRIEF" ] || die "--brief must be an existing file"
[ -n "$RUN_DIR" ] || die "--run-dir is required"
command -v pi >/dev/null || die "pi not found on PATH"
command -v node >/dev/null || die "node not found on PATH"

# pi and node are native Windows programs under Git Bash: hand them Windows-style paths.
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

mkdir -p "$RUN_DIR/sessions"
RUN_DIR=$(cd "$RUN_DIR" && pwd)
cp "$BRIEF" "$RUN_DIR/brief.md"
EVENTS="$RUN_DIR/events.jsonl"
STDERR="$RUN_DIR/stderr.log"
: > "$EVENTS"; : > "$STDERR"

SESSION_ID=$(node -e 'console.log(require("crypto").randomUUID())')
BASE_HEAD=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")

ARGS=(-p --mode json --model "$MODEL"
      --session-dir "$(winpath "$RUN_DIR/sessions")" --session-id "$SESSION_ID"
      --no-extensions --no-skills)
[ -n "$THINKING" ] && ARGS+=(--thinking "$THINKING")
# Test hook: selftest.sh sets this to force an auth failure. Normally the key comes from ~/.pi/agent.
[ -n "${PI_WORKER_API_KEY:-}" ] && ARGS+=(--api-key "$PI_WORKER_API_KEY")
for s in "${SKILLS[@]+"${SKILLS[@]}"}"; do ARGS+=(--skill "$(winpath "$s")"); done

FIRST_PROMPT="Do the task described in the attached brief. Finish with the report it asks for."
RETRY_PROMPT="The previous attempt was interrupted by an API error. Continue the task from where you left off, then finish with the report the brief asks for."

# Classify the last assistant message of one attempt: prints "<class>\t<error message>".
classify() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    let last = null;
    for (let i = lines.length - 1; i >= 0 && !last; i--) {
      try {
        const e = JSON.parse(lines[i]);
        if (e.type === "message_end" && e.message && e.message.role === "assistant") last = e.message;
      } catch {}
    }
    if (!last) { console.log("error\tno assistant message in event stream"); process.exit(0); }
    if (last.stopReason !== "error") {
      const text = (last.content || []).filter(c => c.type === "text").map(c => c.text).join("\n");
      fs.writeFileSync(process.argv[2], text);
      console.log("ok\t"); process.exit(0);
    }
    const msg = String(last.errorMessage || "unknown error").replace(/\s+/g, " ");
    let cls = "transient";
    if (/^(401|403)\b|"code":"100[0-4]"|身份验证|unauthori[sz]ed|invalid api key/i.test(msg)) cls = "auth";
    else if (/"code":"(1113|1308|1309|1310)"|余额|使用上限|额度|quota|insufficient/i.test(msg)) cls = "quota";
    else if (!/^(408|429|5\d\d)\b|"code":"(1302|1303|1305|1312)"|timeout|timed out|ECONN|ETIMEDOUT|socket|network|overloaded|rate/i.test(msg)) cls = "error";
    console.log(cls + "\t" + msg);
  ' "$(winpath "$1")" "$(winpath "$RUN_DIR/result.md")"
}

START=$(date +%s)
ATTEMPT=0
STATUS="error"; ERROR=""; EXIT_CODE=6
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  ATTEMPT_EVENTS="$RUN_DIR/attempt-$ATTEMPT.jsonl"
  if [ "$ATTEMPT" -eq 1 ]; then
    PROMPT=("@$(winpath "$RUN_DIR/brief.md")" "$FIRST_PROMPT")
  else
    PROMPT=("$RETRY_PROMPT")
  fi
  echo "=== attempt $ATTEMPT $(date -Iseconds) ===" >> "$STDERR"
  (cd "$CWD" && timeout --kill-after=30 "$TIMEOUT" pi "${ARGS[@]}" "${PROMPT[@]}" \
      </dev/null >"$ATTEMPT_EVENTS" 2>>"$STDERR")
  PI_EXIT=$?
  cat "$ATTEMPT_EVENTS" >> "$EVENTS"

  if [ "$PI_EXIT" -eq 124 ] || [ "$PI_EXIT" -eq 137 ]; then
    STATUS="timeout"; ERROR="pi did not finish within ${TIMEOUT}s"; EXIT_CODE=5; break
  fi
  IFS=$'\t' read -r CLS MSG < <(classify "$ATTEMPT_EVENTS")
  case "$CLS" in
    ok) STATUS="ok"; ERROR=""; EXIT_CODE=0; break ;;
    auth) STATUS="auth"; ERROR="$MSG"; EXIT_CODE=2; break ;;
    quota) STATUS="quota"; ERROR="$MSG"; EXIT_CODE=3; break ;;
    transient)
      STATUS="transient"; ERROR="$MSG"; EXIT_CODE=4
      [ "$ATTEMPT" -gt "$RETRIES" ] && break
      sleep "$((RETRY_WAIT * ATTEMPT))" ;;
    *) STATUS="error"; ERROR="${MSG:-pi exited with code $PI_EXIT}"; EXIT_CODE=6; break ;;
  esac
done
END=$(date +%s)

HEAD_NOW=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
COMMITS=0
[ -n "$BASE_HEAD" ] && COMMITS=$(git -C "$CWD" rev-list --count "$BASE_HEAD..HEAD" 2>/dev/null || echo 0)
DIRTY=false
[ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ] && DIRTY=true

STATUS="$STATUS" ERROR="$ERROR" ATTEMPTS="$ATTEMPT" DURATION="$((END - START))" \
MODEL="$MODEL" SESSION_ID="$SESSION_ID" BASE_HEAD="$BASE_HEAD" HEAD_NOW="$HEAD_NOW" \
COMMITS="$COMMITS" DIRTY="$DIRTY" RUN_DIR_W="$(winpath "$RUN_DIR")" CWD_W="$(winpath "$CWD")" \
node -e '
  const e = process.env;
  const s = {
    status: e.STATUS, error: e.ERROR || null, attempts: +e.ATTEMPTS, duration_s: +e.DURATION,
    model: e.MODEL, session_id: e.SESSION_ID, cwd: e.CWD_W, run_dir: e.RUN_DIR_W,
    base_head: e.BASE_HEAD, head: e.HEAD_NOW, new_commits: +e.COMMITS, dirty: e.DIRTY === "true",
    result_file: e.STATUS === "ok" ? e.RUN_DIR_W + "/result.md" : null,
  };
  const out = JSON.stringify(s, null, 2);
  require("fs").writeFileSync(e.RUN_DIR_W + "/status.json", out + "\n");
  console.log(out);
'
exit "$EXIT_CODE"
