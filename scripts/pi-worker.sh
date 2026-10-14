#!/usr/bin/env bash
# Run one External worker: a headless pi process on GLM, inside a worktree, with a Brief.
#
# Usage:
#   pi-worker.sh --cwd <worktree> --brief <file> --run-dir <dir>
#                [--model glm/glm-5.3] [--time-limit 1800] [--idle-timeout 600]
#                [--retries 2] [--retry-wait 60] [--thinking <level>] [--skill <dir>]...
#   pi-worker.sh --resume --run-dir <dir> [--time-limit 1800] [--idle-timeout 600]
#                [--retries 2] [--retry-wait 60]
#
# Terms follow GLOSSARY.md: --time-limit is the per-role Time limit (hard cap on one
# segment, counted from the segment's start across all of its attempts and retry
# waits); --idle-timeout is the Idle timeout (pi is judged stuck when its event
# stream has not grown for that long; per attempt, since it watches the current
# attempt's event stream).
#
# --resume (GLOSSARY.md: Resume) continues the same pi session in the same worktree
# and run dir, from the state a fresh run persisted in the run dir's resume.json
# (cwd, model, skills, thinking level, session id, base head). It needs no --cwd,
# --brief, --model, --skill or --thinking, and rejects them: a Resume must not land
# in another worktree or run under a different Brief. It appends to events.jsonl and
# stderr.log, adds new attempt files (numbering continues across segments) and
# overwrites status.json. The new segment's Time limit, Idle timeout and API-error
# retry budget come from the flags of the Resume call. --resume on a missing run
# dir, one without saved state, or one whose saved pi session file is gone, exits 64
# and never starts a fresh session.
#
# Writes into --run-dir: brief.md, events.jsonl, stderr.log, sessions/, resume.json,
# attempt-<n>.jsonl, result.md, status.json. Prints status.json on stdout. Exit codes:
#   0 ok (pi finished without an API error) | 2 auth error | 3 quota exhausted | 4 transient error (retries used up)
#   5 Time limit reached (Resumable) | 6 other error | 7 stalled (Idle timeout; not Resumable) | 64 bad usage
#
# status.json: attempts and duration_s cover this segment only (the retry budget and
# the Time limit are per segment); segments is 1 for a fresh run, +1 per Resume;
# new_commits counts from the FIRST segment's base head, so the verification gate
# sees every commit across segments.
#
# Test hooks: selftest.sh uses them to exercise wrapper paths deterministically,
# without GLM. PI_WORKER_PI swaps in a fake pi executable (Idle timeout, segment
# Time limit accounting, non-watchdog kills, lost session files); PI_WORKER_API_KEY
# forces a specific API key (auth failure).
#
# Never trust "ok" alone: it only means pi finished without an API error. The caller
# still checks the worktree (new commits, clean tree) and re-runs the tests.

set -u

MODEL="glm/glm-5.3"
TIME_LIMIT=1800
IDLE_TIMEOUT=600
RETRIES=2
RETRY_WAIT=60
THINKING=""
CWD=""
BRIEF=""
RUN_DIR=""
SKILLS=()
RESUME=false
GOT_CWD=false GOT_BRIEF=false GOT_MODEL=false GOT_THINKING=false GOT_SKILL=false

die() { echo "pi-worker: $*" >&2; exit 64; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; GOT_CWD=true; shift 2 ;;
    --brief) BRIEF="$2"; GOT_BRIEF=true; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --model) MODEL="$2"; GOT_MODEL=true; shift 2 ;;
    --time-limit) TIME_LIMIT="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --retry-wait) RETRY_WAIT="$2"; shift 2 ;;
    --thinking) THINKING="$2"; GOT_THINKING=true; shift 2 ;;
    --skill) SKILLS+=("$2"); GOT_SKILL=true; shift 2 ;;
    --resume) RESUME=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

if $RESUME; then
  [ -n "$RUN_DIR" ] || die "--resume needs --run-dir"
  [ -d "$RUN_DIR" ] || die "--resume: run dir not found: $RUN_DIR"
  [ -f "$RUN_DIR/resume.json" ] || die "--resume: no saved Resume state (resume.json) in $RUN_DIR; not starting a fresh session"
  $GOT_CWD && die "--resume reuses the saved worktree; do not pass --cwd"
  $GOT_BRIEF && die "--resume continues with a Resume prompt; do not pass --brief"
  $GOT_MODEL && die "--resume reuses the saved model; do not pass --model"
  $GOT_SKILL && die "--resume reuses the saved skills; do not pass --skill"
  $GOT_THINKING && die "--resume reuses the saved thinking level; do not pass --thinking"
else
  [ -n "$CWD" ] && [ -d "$CWD" ] || die "--cwd must be an existing directory"
  [ -n "$BRIEF" ] && [ -f "$BRIEF" ] || die "--brief must be an existing file"
  [ -n "$RUN_DIR" ] || die "--run-dir is required"
fi
command -v node >/dev/null || die "node not found on PATH"
PI_BIN="${PI_WORKER_PI:-pi}"
command -v "$PI_BIN" >/dev/null || die "pi not found on PATH (PI_WORKER_PI=${PI_WORKER_PI:-unset})"

# pi and node are native Windows programs under Git Bash: hand them Windows-style paths.
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

mkdir -p "$RUN_DIR/sessions"
RUN_DIR=$(cd "$RUN_DIR" && pwd)
EVENTS="$RUN_DIR/events.jsonl"
STDERR="$RUN_DIR/stderr.log"
STATE_FILE="$RUN_DIR/resume.json"

# Persist what a later Resume (GLOSSARY.md) needs. A fresh run writes it once with
# segments=1; every completed attempt refreshes it (attempt numbering continues
# across segments); each --resume bumps segments before running pi.
write_state() {
  local skills_nl="" s
  for s in ${SKILLS[@]+"${SKILLS[@]}"}; do skills_nl+="$(winpath "$s")"$'\n'; done
  RUN_DIR_W="$(winpath "$RUN_DIR")" CWD_W="$(winpath "$CWD")" MODEL="$MODEL" THINKING="$THINKING" \
  SESSION_ID="$SESSION_ID" BASE_HEAD="$BASE_HEAD" SEGMENTS="$SEGMENTS" ATTEMPTS="$ATTEMPT" \
  SKILLS_NL="$skills_nl" \
  node -e '
    const e = process.env;
    const s = {
      cwd: e.CWD_W, model: e.MODEL,
      skills: (e.SKILLS_NL || "").split("\n").filter(Boolean),
      thinking: e.THINKING || "", session_id: e.SESSION_ID,
      base_head: e.BASE_HEAD || "", segments: +e.SEGMENTS, attempts: +e.ATTEMPTS,
    };
    require("fs").writeFileSync(e.RUN_DIR_W + "/resume.json", JSON.stringify(s, null, 2) + "\n");
  '
}

if $RESUME; then
  STATE_OUT=$(node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (err) { console.error("bad resume.json: " + err.message); process.exit(1); }
    for (const k of ["cwd", "model", "skills", "thinking", "session_id", "base_head", "segments", "attempts"]) {
      if (!(k in s)) { console.error("resume.json: missing " + k); process.exit(1); }
    }
    const clean = v => String(v).replace(/[\t\n\r]+/g, " ");
    const str = (v, k) => {
      if (typeof v !== "string") { console.error("resume.json: " + k + " must be a string"); process.exit(1); }
      return clean(v);
    };
    const int = (v, k, min) => {
      if (!Number.isInteger(v) || v < min) { console.error("resume.json: " + k + " must be an integer >= " + min); process.exit(1); }
      return String(v);
    };
    if (!Array.isArray(s.skills)) { console.error("resume.json: skills must be an array"); process.exit(1); }
    const out = [
      "cwd\t" + str(s.cwd, "cwd"),
      "model\t" + str(s.model, "model"),
      "thinking\t" + str(s.thinking, "thinking"),
      "session_id\t" + str(s.session_id, "session_id"),
      "base_head\t" + str(s.base_head, "base_head"),
      "segments\t" + int(s.segments, "segments", 1),
      "attempts\t" + int(s.attempts, "attempts", 0),
    ];
    for (const sk of s.skills) out.push("skill\t" + str(sk, "skills[]"));
    console.log(out.join("\n"));
  ' "$(winpath "$STATE_FILE")") || die "--resume: $STATE_FILE is not valid Resume state"
  SKILLS=()
  while IFS=$'\t' read -r k v; do
    case "$k" in
      cwd) CWD="$v" ;;
      model) MODEL="$v" ;;
      thinking) THINKING="$v" ;;
      session_id) SESSION_ID="$v" ;;
      base_head) BASE_HEAD="$v" ;;
      segments) SEGMENTS="$v" ;;
      attempts) ATTEMPT="$v" ;;
      skill) [ -n "$v" ] && SKILLS+=("$v") ;;
    esac
  done <<< "$STATE_OUT"
  [ -d "$CWD" ] || die "--resume: saved worktree does not exist: $CWD"
  # pi itself would only warn on stderr and then start a FRESH session with the same
  # id when --session-id matches no file; the wrapper must refuse instead. pi stores
  # each session as <timestamp>_<session id>.jsonl under --session-dir, with a
  # {"type":"session","id":...} header as its first line.
  SESSION_FILE_FOUND=$(node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.argv[1], id = process.argv[2];
    let found = false;
    try {
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".jsonl")) continue;
        try {
          const h = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8").split("\n", 1)[0]);
          if (h && h.type === "session" && h.id === id) { found = true; break; }
        } catch {}
      }
    } catch {}
    process.stdout.write(found ? "yes" : "no");
  ' "$(winpath "$RUN_DIR/sessions")" "$SESSION_ID")
  [ "$SESSION_FILE_FOUND" = yes ] || die "--resume: no pi session file for session $SESSION_ID in $RUN_DIR/sessions; not starting a fresh session"
  SEGMENTS=$((SEGMENTS + 1))
  write_state
else
  cp "$BRIEF" "$RUN_DIR/brief.md"
  : > "$EVENTS"; : > "$STDERR"
  SESSION_ID=$(node -e 'console.log(require("crypto").randomUUID())')
  BASE_HEAD=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
  SEGMENTS=1
  ATTEMPT=0
  write_state
fi

ARGS=(-p --mode json --model "$MODEL"
      --session-dir "$(winpath "$RUN_DIR/sessions")" --session-id "$SESSION_ID"
      --no-extensions --no-skills)
[ -n "$THINKING" ] && ARGS+=(--thinking "$THINKING")
# Test hook: selftest.sh sets this to force an auth failure. Normally the key comes from ~/.pi/agent.
[ -n "${PI_WORKER_API_KEY:-}" ] && ARGS+=(--api-key "$PI_WORKER_API_KEY")
for s in "${SKILLS[@]+"${SKILLS[@]}"}"; do ARGS+=(--skill "$(winpath "$s")"); done

FIRST_PROMPT="Do the task described in the attached brief. Finish with the report it asks for."
RETRY_PROMPT="The previous attempt was interrupted by an API error. Continue the task from where you left off, then finish with the report the brief asks for."
RESUME_PROMPT="You were paused because you reached the time limit. First commit the work that is done and passes its tests, then continue the remaining work. If you still cannot finish, list the unfinished acceptance criteria in your final report."

# Kill pi and its whole process tree: pi's tool children (npm test, shells) are
# native Windows processes that an MSYS `kill` cannot reach, so on Git Bash kill the
# Windows tree via taskkill //T on the pid from /proc; elsewhere fall back to
# kill -> grace -> kill -9.
kill_tree() {
  if [ -r "/proc/$1/winpid" ] && command -v taskkill >/dev/null 2>&1; then
    taskkill //T //F //PID "$(cat "/proc/$1/winpid")" >/dev/null 2>&1
    return
  fi
  kill "$1" 2>/dev/null
  local grace=0
  while kill -0 "$1" 2>/dev/null && [ "$grace" -lt 6 ]; do sleep 5; grace=$((grace + 1)); done
  kill -9 "$1" 2>/dev/null
}

# Run one pi attempt in the background under a watchdog that enforces both limits:
#   - Time limit: the whole segment (every attempt plus the retry waits between
#     them) must end within $TIME_LIMIT seconds of the segment's start ($SEG_START);
#     each attempt only gets the remaining budget;
#   - Idle timeout: per attempt, pi's event stream must grow at least every
#     $IDLE_TIMEOUT seconds (pi streams events densely; the largest observed gap
#     between messages is ~114s).
# Sets WATCHDOG to "time-limit" or "idle" when we killed pi, "" when it exited on
# its own. When the segment budget is already spent before an attempt would start,
# it flags "time-limit" without launching pi.
run_pi() {
  WATCHDOG=""
  local deadline=$((SEG_START + TIME_LIMIT))
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "=== segment Time limit spent before attempt $ATTEMPT $(date -Iseconds) ===" >> "$STDERR"
    : > "$ATTEMPT_EVENTS"
    WATCHDOG="time-limit"
    return
  fi
  (cd "$CWD" && exec "$PI_BIN" "${ARGS[@]}" "${PROMPT[@]}" \
      </dev/null >"$ATTEMPT_EVENTS" 2>>"$STDERR") &
  PI_PID=$!
  local last_change last_size now size
  last_change=$(date +%s); last_size=0
  while kill -0 "$PI_PID" 2>/dev/null; do
    sleep 5
    now=$(date +%s)
    if [ -f "$ATTEMPT_EVENTS" ]; then size=$(( $(wc -c < "$ATTEMPT_EVENTS") )); else size=0; fi
    if [ "$size" -gt "$last_size" ]; then last_size=$size; last_change=$now; fi
    if [ "$now" -ge "$deadline" ]; then WATCHDOG="time-limit"; break; fi
    if [ $((now - last_change)) -ge "$IDLE_TIMEOUT" ]; then WATCHDOG="idle"; break; fi
  done
  if [ -n "$WATCHDOG" ]; then
    echo "=== watchdog killed pi ($WATCHDOG) $(date -Iseconds) ===" >> "$STDERR"
    kill_tree "$PI_PID"
  fi
  wait "$PI_PID"
  PI_EXIT=$?
}

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
SEG_START=$START   # the Time limit budget is anchored at the segment's first attempt
SEG_ATTEMPT=0
STATUS="error"; ERROR=""; EXIT_CODE=6
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  SEG_ATTEMPT=$((SEG_ATTEMPT + 1))
  ATTEMPT_EVENTS="$RUN_DIR/attempt-$ATTEMPT.jsonl"
  if [ "$SEG_ATTEMPT" -eq 1 ]; then
    if $RESUME; then
      PROMPT=("$RESUME_PROMPT")
    else
      PROMPT=("@$(winpath "$RUN_DIR/brief.md")" "$FIRST_PROMPT")
    fi
  else
    PROMPT=("$RETRY_PROMPT")
  fi
  echo "=== attempt $ATTEMPT (segment $SEGMENTS) $(date -Iseconds) ===" >> "$STDERR"
  run_pi
  cat "$ATTEMPT_EVENTS" >> "$EVENTS"
  write_state

  if [ "$WATCHDOG" = "time-limit" ]; then
    STATUS="timeout"; ERROR="Time limit reached: pi did not finish within ${TIME_LIMIT}s"; EXIT_CODE=5; break
  fi
  if [ "$WATCHDOG" = "idle" ]; then
    STATUS="stalled"; ERROR="Idle timeout: no pi events for ${IDLE_TIMEOUT}s"; EXIT_CODE=7; break
  fi
  # Only the watchdog's kill means the Time limit fired. A pi that exits 124/137 on
  # its own (OOM, external SIGKILL, ...) is NOT Resumable: it falls through to the
  # normal classification below (`error`, unless the API-error classifier says
  # otherwise).
  IFS=$'\t' read -r CLS MSG < <(classify "$ATTEMPT_EVENTS")
  case "$CLS" in
    ok) STATUS="ok"; ERROR=""; EXIT_CODE=0; break ;;
    auth) STATUS="auth"; ERROR="$MSG"; EXIT_CODE=2; break ;;
    quota) STATUS="quota"; ERROR="$MSG"; EXIT_CODE=3; break ;;
    transient)
      STATUS="transient"; ERROR="$MSG"; EXIT_CODE=4
      [ "$SEG_ATTEMPT" -gt "$RETRIES" ] && break
      sleep "$((RETRY_WAIT * SEG_ATTEMPT))" ;;
    *) STATUS="error"; ERROR="${MSG:-pi exited with code $PI_EXIT}"; EXIT_CODE=6; break ;;
  esac
done
END=$(date +%s)

HEAD_NOW=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
COMMITS=0
[ -n "$BASE_HEAD" ] && COMMITS=$(git -C "$CWD" rev-list --count "$BASE_HEAD..HEAD" 2>/dev/null || echo 0)
DIRTY=false
[ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ] && DIRTY=true

STATUS="$STATUS" ERROR="$ERROR" ATTEMPTS="$SEG_ATTEMPT" SEGMENTS="$SEGMENTS" DURATION="$((END - START))" \
MODEL="$MODEL" SESSION_ID="$SESSION_ID" BASE_HEAD="$BASE_HEAD" HEAD_NOW="$HEAD_NOW" \
COMMITS="$COMMITS" DIRTY="$DIRTY" RUN_DIR_W="$(winpath "$RUN_DIR")" CWD_W="$(winpath "$CWD")" \
node -e '
  const e = process.env;
  const s = {
    status: e.STATUS, error: e.ERROR || null, attempts: +e.ATTEMPTS, segments: +e.SEGMENTS,
    duration_s: +e.DURATION,
    model: e.MODEL, session_id: e.SESSION_ID, cwd: e.CWD_W, run_dir: e.RUN_DIR_W,
    base_head: e.BASE_HEAD, head: e.HEAD_NOW, new_commits: +e.COMMITS, dirty: e.DIRTY === "true",
    result_file: e.STATUS === "ok" ? e.RUN_DIR_W + "/result.md" : null,
  };
  const out = JSON.stringify(s, null, 2);
  require("fs").writeFileSync(e.RUN_DIR_W + "/status.json", out + "\n");
  console.log(out);
'
exit "$EXIT_CODE"
