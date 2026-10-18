#!/usr/bin/env bash
# Run one External worker: a headless codex process on GLM, inside a worktree, with a
# Brief. Terms follow GLOSSARY.md.
#
# Usage:
#   codex-worker.sh --cwd <worktree> --brief <file> --run-dir <dir>
#                    [--model glm-5.3] [--time-limit 1800] [--idle-timeout 600]
#                    [--retries 2] [--retry-wait 60]
#                    [--thinking <low|medium|high|xhigh>] [--skill <dir>]...
#                    [--add-dir <dir>]...
#                    [--read-only]
#   codex-worker.sh --resume --run-dir <dir> [--time-limit ..] [--idle-timeout ..]
#                    [--retries ..] [--retry-wait ..]
#
# Contract and semantics match pi-worker.sh. --time-limit is one segment's hard budget:
# it spans every attempt and retry wait since the segment started, and each attempt gets
# only the remainder. --idle-timeout is per attempt and counts only codex progress lines,
# meaning event types beginning thread., turn. or item.; top-level error lines such as
# "Reconnecting..." never reset it (F4). Three "waiting for network" errors since the
# last progress line mean the proxy is unreachable and are classified transient.
#
# --resume continues the same codex thread in the same worktree and run dir. It rejects
# --cwd, --brief, --model, --skill, --thinking and --add-dir, loads resume.json, and
# refuses unless the saved session_id is non-empty and a rollout filename containing it
# exists under ${CODEX_HOME:-$HOME/.codex}/sessions. A Resume gets new Time limit, Idle
# timeout and retry budgets; attempt numbering and new_commits continue from segment one.
#
# --read-only is codex-worker-only. The wrapper records a workspace fingerprint before
# segment one, prefixes every attempt prompt with a read-only instruction, and compares a
# fresh fingerprint after every segment. The fingerprint covers HEAD, the binary diff of
# every tracked change, and the hash of every untracked non-ignored file; files ignored by
# Git are intentionally not checked. Resume inherits the read-only setting and the first
# segment's baseline fingerprint, and rejects another --read-only like other fresh-run-only
# arguments.
#
# Run-dir files: brief.md; prompt-<attempt>.md (the finite stdin prompt, F8);
# attempt-<attempt>.jsonl; accumulated events.jsonl; stderr.log; resume.json; status.json;
# result.md (codex -o output, or a salvaged final agent_message); fingerprint-start.json
# and fingerprint-end.json in read-only mode (the first-segment baseline and each segment's
# final fingerprint); pid (this wrapper's Windows pid and its process start ticks, so
# progress.sh cannot mistake a recycled Windows pid for this worker); watch.json (live
# watchdog state); and sessions/ for pi-worker run-dir compatibility (codex's authoritative
# rollout stays under CODEX_HOME).
#
# Exit codes: 0 ok | 2 auth | 3 quota (documented for contract compatibility; codex
# event classification never distinguishes quota from 429) | 4 transient, retries used
# up or proxy unavailable | 5 Time limit reached (Resumable) | 6 other error | 7 stalled,
# not Resumable | 8 read-only violation | 64 bad usage. status.json's attempts and
# duration_s cover only the current segment; segments increases once per Resume;
# new_commits counts from the first segment's base_head; result_file is set for ok and for
# a stalled attempt whose final agent_message was salvaged. In read-only mode status.json
# also has read_only, read_only_violation, and sorted changed_paths (capped at 50 entries
# plus a "<+N more>" marker; "<HEAD>" when
# HEAD changed). A violation changes only ok to violation/exit 8; timeout, stalled, error,
# and other statuses keep their existing exit codes while still recording the violation.
#
# Salvage applies only when the last progress event is a completed agent_message and no
# command_execution remains in flight (#391). Otherwise an Idle timeout is a plain stall.
# The wrapper launches codex through exec with no MSYS program in between (F9-F11), uses
# event-based classification rather than codex's exit code (F1-F3), and confirms tree
# kills by Windows pid liveness rather than localized taskkill output.
#
# codex 0.163 still has a built-in command policy that can reject rm -rf and
# Remove-Item -Recurse even with --dangerously-bypass-approvals-and-sandbox; Briefs
# should avoid asking workers to issue broad recursive deletes.
#
# Never trust "ok" alone: it only means codex emitted turn.completed. The caller must
# still inspect the worktree and rerun acceptance tests.
#
# Test hooks: CODEX_WORKER_CODEX swaps the codex executable; CODEX_WORKER_BASE_URL swaps
# the provider endpoint; CODEX_WORKER_POLL overrides the watchdog interval; and
# CODEX_WORKER_SKIP_PREFLIGHT=1 bypasses the TCP preflight. TEST ONLY:
# CODEX_WORKER_TEST_BREAK_FINGERPRINT_END=1 makes the end-of-segment fingerprint fail.

set -u

MODEL="glm-5.3"
TIME_LIMIT=1800
IDLE_TIMEOUT=600
RETRIES=2
RETRY_WAIT=60
THINKING=""
CWD=""
BRIEF=""
RUN_DIR=""
SKILLS=()
ADD_DIRS=()
RESUME=false
READ_ONLY=false
GOT_CWD=false GOT_BRIEF=false GOT_MODEL=false GOT_THINKING=false GOT_SKILL=false GOT_ADD_DIR=false
GOT_READ_ONLY=false

die() { echo "codex-worker: $*" >&2; exit 64; }

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
    --add-dir) ADD_DIRS+=("$2"); GOT_ADD_DIR=true; shift 2 ;;
    --resume) RESUME=true; shift ;;
    --read-only) READ_ONLY=true; GOT_READ_ONLY=true; shift ;;
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
  $GOT_ADD_DIR && die "--resume reuses the saved add dirs; do not pass --add-dir"
  $GOT_READ_ONLY && die "--resume reuses the saved read-only setting; do not pass --read-only"
else
  [ -n "$CWD" ] && [ -d "$CWD" ] || die "--cwd must be an existing directory"
  [ -n "$BRIEF" ] && [ -f "$BRIEF" ] || die "--brief must be an existing file"
  [ -n "$RUN_DIR" ] || die "--run-dir is required"
  if $READ_ONLY; then
    [ "$(git -C "$CWD" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || die "--read-only requires --cwd to be a Git worktree"
    git -C "$CWD" rev-parse --verify HEAD >/dev/null 2>&1 || die "--read-only requires a Git worktree with a HEAD commit"
  fi
fi

run_codex() {
  WATCHDOG=""; PROXY_DOWN=false
  local deadline=$((SEG_START + TIME_LIMIT))
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "=== segment Time limit spent before attempt $ATTEMPT $(date -Iseconds) ===" >> "$STDERR"
    : > "$ATTEMPT_EVENTS"; WATCHDOG="time-limit"; return
  fi
  ATTEMPT_START=$(date +%s); LAST_PROGRESS_AT=$ATTEMPT_START; PROGRESS_LINES=0
  local cmd_args=("${ARGS[@]}") now progress waiting thread idle_for
  if [ "$USE_THREAD" = true ] && [ -n "$SESSION_ID" ]; then cmd_args+=(resume "$SESSION_ID" -); else cmd_args+=(-); fi
  (cd "$CWD" && exec "$CODEX_BIN" exec "${cmd_args[@]}" < "$PROMPT_FILE" > "$ATTEMPT_EVENTS" 2>>"$STDERR") &
  CODEX_PID=$!
  while kill -0 "$CODEX_PID" 2>/dev/null; do
    sleep "$POLL"; now=$(date +%s)
    IFS=$'\t' read -r progress waiting thread < <(event_stats "$ATTEMPT_EVENTS")
    if [ -n "${thread:-}" ] && [ "$thread" != "$SESSION_ID" ]; then SESSION_ID="$thread"; write_state; fi
    if [ "${progress:-0}" -gt "$PROGRESS_LINES" ]; then PROGRESS_LINES=$progress; LAST_PROGRESS_AT=$now; fi
    write_watch "$now"
    if [ "$now" -ge "$deadline" ]; then WATCHDOG="time-limit"; break; fi
    idle_for=$((now - LAST_PROGRESS_AT))
    if [ "$idle_for" -ge "$IDLE_TIMEOUT" ]; then WATCHDOG="idle"; break; fi
    if [ "${waiting:-0}" -ge 3 ]; then WATCHDOG="proxy"; PROXY_DOWN=true; break; fi
  done
  if [ -n "$WATCHDOG" ]; then
    echo "=== watchdog killed codex ($WATCHDOG) $(date -Iseconds) ===" >> "$STDERR"
    kill_tree "$CODEX_PID"
  fi
  wait "$CODEX_PID"; CODEX_EXIT=$?
}

salvage_reply() {
  RUN_OUT="$(winpath "$RUN_DIR/result.md")" EVENT_FILE="$(winpath "$ATTEMPT_EVENTS")" node -e '
    const fs = require("fs"); let msg = null, lastProgress = null;
    const open = new Set();
    try {
      for (const line of fs.readFileSync(process.env.EVENT_FILE, "utf8").split("\n")) {
        if (!line) continue;
        try { const e = JSON.parse(line);
          if (/^(?:thread|turn|item)\./.test(String(e.type || ""))) lastProgress = e;
          if (e.type === "item.started" && e.item?.id && e.item.type === "command_execution") open.add(e.item.id);
          if (e.type === "item.completed" && e.item?.id) open.delete(e.item.id);
          if (e.type === "item.completed" && e.item?.type === "agent_message") msg = String(e.item.text || "");
        } catch {}
      }
    } catch {}
    const lastIsReply = lastProgress?.type === "item.completed" &&
      lastProgress.item?.type === "agent_message";
    const salvable = msg !== null && lastIsReply && open.size === 0;
    if (salvable) fs.writeFileSync(process.env.RUN_OUT, msg + "\n");
    process.stdout.write(salvable ? "yes" : "no");
  '
}

classify() {
  EVENT_FILE="$(winpath "$1")" CODEX_EXIT="$2" node -e '
    const fs = require("fs"); let lines = [];
    try { lines = fs.readFileSync(process.env.EVENT_FILE, "utf8").split("\n").filter(Boolean); } catch {}
    let failed = null, completed = false, lastError = "", thread = "";
    for (const line of lines) {
      let e; try { e = JSON.parse(line); } catch { continue; }
      if (e.type === "thread.started" && e.thread_id) thread = String(e.thread_id);
      if (e.type === "turn.completed") completed = true;
      if (e.type === "turn.failed") failed = e;
      if (e.type === "error") lastError = String(e.message || "");
    }
    if (completed) { console.log("ok\t\t" + thread); process.exit(0); }
    if (failed) {
      const msg = failed.error ? String(failed.error.message || "").replace(/\s+/g, " ") : "";
      let cls = "error";
      if (/\b40[13]\b|身份验证|unauthori[sz]ed|invalid api key/i.test(msg)) cls = "auth";
      else if (/\b429\b/.test(msg)) cls = "transient429";
      else if (/stream disconnected|idle timeout|timed out|timeout|network|connection|ECONN|\b5\d\d\b/i.test(msg)) cls = "transient";
      console.log(cls + "\t" + msg + "\t" + thread); process.exit(0);
    }
    const suffix = lastError ? " (last error: " + lastError + ")" : "";
    console.log("error\tcodex exited " + process.env.CODEX_EXIT + " without turn.completed/turn.failed" + suffix + "\t" + thread);
  '
}

RETRY_PROMPT="The previous attempt was interrupted by an API error. Continue the task from where you left off, then finish with the report the brief asks for."
RESUME_PROMPT="You were paused because you reached the time limit. First commit the work that is done and passes its tests, then continue the remaining work. If you still cannot finish, list the unfinished acceptance criteria in your final report."
READ_ONLY_PROMPT="本任务只读。不要修改、新建或删除任何文件；不要执行 git commit、git stash、git checkout 或 git reset；只运行查看、搜索和已有测试这类命令。请把结论写在最终回复里。"
READ_ONLY_RESUME_PROMPT="你因为到达时间上限被暂停。请继续完成调查，不要修改任何文件；如果仍然无法完成，请按 Brief 要求的报告格式给出目前的结论，并写明还没有确认的部分。"

winpid_alive() { PID_W="$1" node -e 'try{process.kill(+process.env.PID_W,0);process.exit(0)}catch{process.exit(1)}'; }

kill_tree() {
  local winpid=""
  [ -r "/proc/$1/winpid" ] && winpid=$(cat "/proc/$1/winpid")
  if [ -n "$winpid" ] && command -v taskkill >/dev/null 2>&1; then
    taskkill //T //F //PID "$winpid" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      if ! winpid_alive "$winpid"; then echo "kill confirmed: winpid $winpid" >> "$STDERR"; return 0; fi
    done
    taskkill //T //F //PID "$winpid" >/dev/null 2>&1 || true
    sleep 1
    if winpid_alive "$winpid"; then echo "kill FAILED: winpid $winpid still alive" >> "$STDERR"; return 1; fi
    echo "kill confirmed: winpid $winpid" >> "$STDERR"
  else
    kill "$1" 2>/dev/null || true
    local grace=0
    while kill -0 "$1" 2>/dev/null && [ "$grace" -lt 6 ]; do sleep 5; grace=$((grace + 1)); done
    kill -9 "$1" 2>/dev/null || true
  fi
}

event_stats() {
  EVENT_FILE="$(winpath "$1")" node -e '
    const fs = require("fs");
    let progress = 0, waiting = 0, thread = "";
    try {
      for (const line of fs.readFileSync(process.env.EVENT_FILE, "utf8").split("\n")) {
        if (!line) continue;
        let e; try { e = JSON.parse(line); } catch { continue; }
        const type = String(e.type || "");
        if (/^(?:thread|turn|item)\./.test(type)) { progress++; waiting = 0; }
        else if (e.type === "error" && /waiting for network/i.test(String(e.message || ""))) waiting++;
        if (e.type === "thread.started" && e.thread_id) thread = String(e.thread_id);
      }
    } catch {}
    process.stdout.write(progress + "\t" + waiting + "\t" + thread);
  '
}

write_watch() {
  WATCH_SEGMENT="$SEGMENTS" WATCH_ATTEMPT="$ATTEMPT" WATCH_FILE="$(winpath "$ATTEMPT_EVENTS")" \
  WATCH_STARTED="$ATTEMPT_START" WATCH_PROGRESS="$LAST_PROGRESS_AT" WATCH_LINES="$PROGRESS_LINES" \
  WATCH_NOW="$1" RUN_DIR_W="$(winpath "$RUN_DIR")" node -e '
    const e = process.env;
    const j = {segment:+e.WATCH_SEGMENT, attempt:+e.WATCH_ATTEMPT, attempt_file:e.WATCH_FILE,
      started_at:+e.WATCH_STARTED, last_progress_at:+e.WATCH_PROGRESS,
      progress_lines:+e.WATCH_LINES, now:+e.WATCH_NOW};
    require("fs").writeFileSync(e.RUN_DIR_W + "/watch.json", JSON.stringify(j) + "\n");
  '
}

command -v node >/dev/null || die "node not found on PATH"
CODEX_BIN="${CODEX_WORKER_CODEX:-codex}"
command -v "$CODEX_BIN" >/dev/null || die "codex not found on PATH (CODEX_WORKER_CODEX=${CODEX_WORKER_CODEX:-unset})"

winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

workspace_fingerprint() {
  local target_file="$2" target_name
  target_name=$(basename "$target_file")
  if [ "$target_name" = fingerprint-end.json ] && [ "${CODEX_WORKER_TEST_BREAK_FINGERPRINT_END:-0}" = 1 ]; then
    echo "workspace fingerprint failed: test hook requested end fingerprint failure" >&2
    return 1
  fi
  FINGERPRINT_CWD="$(winpath "$1")" FINGERPRINT_FILE="$(winpath "$target_file")" node -e '
    const {spawnSync} = require("child_process");
    const crypto = require("crypto");
    const cwd = process.env.FINGERPRINT_CWD;
    const run = (args, binary = false, input = "") => {
      const r = spawnSync("git", args, {cwd, encoding: binary ? "buffer" : "utf8", input, maxBuffer: 64 * 1024 * 1024});
      if (r.status !== 0) throw new Error("git " + args.join(" ") + ": " + String(r.stderr || "").trim());
      return r.stdout || Buffer.alloc(0);
    };
    const splitNul = b => String(b).split("\0").filter(Boolean);
    const snapshot = () => {
      const head = run(["rev-parse", "HEAD"], true).toString("utf8").trim();
      const tracked = {};
      for (const file of splitNul(run(["diff", "--name-only", "-z", "HEAD"]))) {
        const diff = run(["diff", "HEAD", "--binary", "--", file], true);
        tracked[file] = crypto.createHash("sha256").update(diff).digest("hex");
      }
      const untracked = {};
      const untrackedFiles = splitNul(run(["ls-files", "--others", "--exclude-standard", "-z"]));
      if (untrackedFiles.some(file => file.includes("\n"))) {
        for (const file of untrackedFiles) {
          untracked[file] = run(["hash-object", "--", file], true).toString("utf8").trim();
        }
      } else if (untrackedFiles.length > 0) {
        const hashes = run(["hash-object", "--stdin-paths"], false, untrackedFiles.join("\n") + "\n").trim().split(/\r?\n/);
        if (hashes.length !== untrackedFiles.length) throw new Error("git hash-object returned an unexpected hash count");
        untrackedFiles.forEach((file, i) => untracked[file] = hashes[i]);
      }
      return {version: 1, head, tracked, untracked};
    };
    let value, error;
    for (let i = 0; i < 3; i++) {
      try { value = snapshot(); break; }
      catch (err) { error = err; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50); }
    }
    if (!value) { console.error("workspace fingerprint failed: " + error.message); process.exit(1); }
    require("fs").writeFileSync(process.env.FINGERPRINT_FILE, JSON.stringify(value));
  '
}

read_only_result() {
  READ_ONLY_START="$(winpath "$1")" READ_ONLY_NOW="$(winpath "$2")" node -e '
    const fs = require("fs");
    const before = JSON.parse(fs.readFileSync(process.env.READ_ONLY_START, "utf8"));
    const after = JSON.parse(fs.readFileSync(process.env.READ_ONLY_NOW, "utf8"));
    const changed = new Set();
    const tracked = new Set([...Object.keys(before.tracked || {}), ...Object.keys(after.tracked || {})]);
    for (const p of tracked) if ((before.tracked || {})[p] !== (after.tracked || {})[p]) changed.add(p);
    const untracked = new Set([...Object.keys(before.untracked || {}), ...Object.keys(after.untracked || {})]);
    for (const p of untracked) if ((before.untracked || {})[p] !== (after.untracked || {})[p]) changed.add(p);
    if (before.head !== after.head) changed.add("<HEAD>");
    const list = [...changed].sort(); // capped: the list travels through env vars to write_status
    const shown = list.length > 50 ? [...list.slice(0, 50), "<+" + (list.length - 50) + " more>"] : list;
    process.stdout.write((changed.size > 0 ? "true" : "false") + "\t" + JSON.stringify(shown));
  '
}

evaluate_read_only() {
  local result
  if ! workspace_fingerprint "$CWD" "$RUN_DIR/fingerprint-end.json"; then
    READ_ONLY_VIOLATION=true
    CHANGED_PATHS='["<fingerprint>"]'
    echo "=== read-only fingerprint check failed $(date -Iseconds) ===" >> "$STDERR"
    return
  fi
  if ! result=$(read_only_result "$RUN_DIR/fingerprint-start.json" "$RUN_DIR/fingerprint-end.json"); then
    READ_ONLY_VIOLATION=true; CHANGED_PATHS='["<fingerprint>"]'
    echo "=== read-only fingerprint comparison failed $(date -Iseconds) ===" >> "$STDERR"
    return
  fi
  IFS=$'\t' read -r READ_ONLY_VIOLATION CHANGED_PATHS <<< "$result"
  if ! RESULT_VALUE="$result" node -e '
    const parts = process.env.RESULT_VALUE.split("\t");
    if (parts.length !== 2 || !["true", "false"].includes(parts[0])) process.exit(1);
    if (!Array.isArray(JSON.parse(parts[1]))) process.exit(1);
  '; then
    READ_ONLY_VIOLATION=true; CHANGED_PATHS='["<fingerprint>"]'
    echo "=== read-only fingerprint comparison produced invalid output $(date -Iseconds) ===" >> "$STDERR"
  fi
}

mkdir -p "$RUN_DIR"
RUN_DIR=$(cd "$RUN_DIR" && pwd)
EVENTS="$RUN_DIR/events.jsonl"
STDERR="$RUN_DIR/stderr.log"
STATE_FILE="$RUN_DIR/resume.json"
POLL="${CODEX_WORKER_POLL:-5}"
[[ "$POLL" =~ ^[1-9][0-9]*$ ]] || die "CODEX_WORKER_POLL must be a positive integer"

write_state() {
  local skills_nl="" add_nl="" s
  for s in ${SKILLS[@]+"${SKILLS[@]}"}; do skills_nl+="$(winpath "$s")"$'\n'; done
  for s in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do add_nl+="$(winpath "$s")"$'\n'; done
  RUN_DIR_W="$(winpath "$RUN_DIR")" CWD_W="$(winpath "$CWD")" MODEL="$MODEL" THINKING="$THINKING" \
  SESSION_ID="$SESSION_ID" BASE_HEAD="$BASE_HEAD" SEGMENTS="$SEGMENTS" ATTEMPTS="$ATTEMPT" \
  READ_ONLY="$READ_ONLY" \
  SKILLS_NL="$skills_nl" ADD_NL="$add_nl" \
  node -e '
    const e = process.env;
    const s = {
      cwd: e.CWD_W, model: e.MODEL,
      skills: (e.SKILLS_NL || "").split("\n").filter(Boolean),
      thinking: e.THINKING || "", add_dirs: (e.ADD_NL || "").split("\n").filter(Boolean),
      session_id: e.SESSION_ID, base_head: e.BASE_HEAD || "", segments: +e.SEGMENTS,
      attempts: +e.ATTEMPTS,
      read_only: e.READ_ONLY === "true",
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
    for (const k of ["cwd", "model", "skills", "thinking", "add_dirs", "session_id", "base_head", "segments", "attempts"]) {
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
    if (!Array.isArray(s.skills) || !Array.isArray(s.add_dirs)) { console.error("resume.json: skills/add_dirs must be arrays"); process.exit(1); }
    let readOnly = false;
    if ("read_only" in s) {
      if (typeof s.read_only !== "boolean") { console.error("resume.json: read_only must be a boolean"); process.exit(1); }
      readOnly = s.read_only;
    }
    const out = [
      "cwd\t" + str(s.cwd, "cwd"), "model\t" + str(s.model, "model"),
      "thinking\t" + str(s.thinking, "thinking"), "session_id\t" + str(s.session_id, "session_id"),
      "base_head\t" + str(s.base_head, "base_head"), "segments\t" + int(s.segments, "segments", 1),
      "attempts\t" + int(s.attempts, "attempts", 0),
      "read_only\t" + (readOnly ? "true" : "false"),
    ];
    for (const sk of s.skills) out.push("skill\t" + str(sk, "skills[]"));
    for (const ad of s.add_dirs) out.push("add\t" + str(ad, "add_dirs[]"));
    console.log(out.join("\n"));
  ' "$(winpath "$STATE_FILE")") || die "--resume: $STATE_FILE is not valid Resume state"
  SKILLS=(); ADD_DIRS=()
  while IFS=$'\t' read -r k v; do
    case "$k" in
      cwd) CWD="$v" ;; model) MODEL="$v" ;; thinking) THINKING="$v" ;;
      session_id) SESSION_ID="$v" ;; base_head) BASE_HEAD="$v" ;;
      segments) SEGMENTS="$v" ;; attempts) ATTEMPT="$v" ;;
      read_only) READ_ONLY="$v" ;;
      skill) [ -n "$v" ] && SKILLS+=("$v") ;; add) [ -n "$v" ] && ADD_DIRS+=("$v") ;;
    esac
  done <<< "$STATE_OUT"
  [ -d "$CWD" ] || die "--resume: saved worktree does not exist: $CWD"
  [ -n "$SESSION_ID" ] || die "--resume: saved session_id is empty"
  if $READ_ONLY; then
    FINGERPRINT_START="$(winpath "$RUN_DIR/fingerprint-start.json")" node -e '
      const fs = require("fs");
      const object = v => v && typeof v === "object" && !Array.isArray(v);
      let value;
      try { value = JSON.parse(fs.readFileSync(process.env.FINGERPRINT_START, "utf8")); }
      catch { process.exit(1); }
      if (!object(value) || typeof value.head !== "string" || !object(value.tracked) || !object(value.untracked)) process.exit(1);
    ' || die "read-only baseline fingerprint missing or invalid"
  fi
  SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"
  ROLLOUT_FOUND=$(node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1], id = process.argv[2];
    let found = false;
    const walk = d => {
      if (found) return;
      let entries;
      try { entries = fs.readdirSync(d, {withFileTypes: true}); } catch { return; }
      for (const ent of entries) {
        const p = path.join(d, ent.name);
        if (ent.isDirectory()) walk(p);
        else if (ent.isFile() && ent.name.includes(id)) { found = true; return; }
      }
    };
    walk(root); process.stdout.write(found ? "yes" : "no");
  ' "$(winpath "$SESSIONS_DIR")" "$SESSION_ID")
  [ "$ROLLOUT_FOUND" = yes ] || die "--resume: no codex rollout file for session $SESSION_ID under $SESSIONS_DIR; not starting a fresh session"
else
  [ "$BRIEF" -ef "$RUN_DIR/brief.md" ] || cp "$BRIEF" "$RUN_DIR/brief.md"
  mkdir -p "$RUN_DIR/sessions"; : > "$EVENTS"; : > "$STDERR"
  SESSION_ID=""
  BASE_HEAD=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
  if $READ_ONLY; then workspace_fingerprint "$CWD" "$RUN_DIR/fingerprint-start.json" || die "--read-only: could not fingerprint $CWD"; fi
  SEGMENTS=1; ATTEMPT=0
  write_state
fi

# Publish liveness only after usage, Resume state and rollout validation have passed.
# The optional second field identifies this process instance; Windows reuses pids.
if [ -r /proc/$$/winpid ]; then
  WORKER_WINPID=$(cat /proc/$$/winpid)
  WORKER_START_TICKS=$(powershell.exe -NoProfile -Command "(Get-Process -Id $WORKER_WINPID).StartTime.ToUniversalTime().Ticks" 2>/dev/null | tr -d '\r')
  if [[ "$WORKER_START_TICKS" =~ ^[0-9]+$ ]]; then echo "$WORKER_WINPID $WORKER_START_TICKS" > "$RUN_DIR/pid"
  else echo "$WORKER_WINPID" > "$RUN_DIR/pid"; fi
else
  echo $$ > "$RUN_DIR/pid"
fi

write_status() {
  HEAD_NOW=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
  COMMITS=0
  [ -n "$BASE_HEAD" ] && COMMITS=$(git -C "$CWD" rev-list --count "$BASE_HEAD..HEAD" 2>/dev/null || echo 0)
  DIRTY=false
  [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ] && DIRTY=true
  STATUS="$STATUS" ERROR="$ERROR" ATTEMPTS="${SEG_ATTEMPT:-0}" SEGMENTS="$SEGMENTS" \
  DURATION="$((END - START))" MODEL="$MODEL" SESSION_ID="$SESSION_ID" BASE_HEAD="$BASE_HEAD" \
  HEAD_NOW="$HEAD_NOW" COMMITS="$COMMITS" DIRTY="$DIRTY" SALVAGED="${SALVAGED:-false}" \
  READ_ONLY="$READ_ONLY" READ_ONLY_VIOLATION="${READ_ONLY_VIOLATION:-false}" CHANGED_PATHS="${CHANGED_PATHS:-[]}" \
  RUN_DIR_W="$(winpath "$RUN_DIR")" CWD_W="$(winpath "$CWD")" \
  node -e '
    const e = process.env;
    const s = {
      status: e.STATUS, error: e.ERROR || null, attempts: +e.ATTEMPTS, segments: +e.SEGMENTS,
      duration_s: +e.DURATION, model: e.MODEL, session_id: e.SESSION_ID, cwd: e.CWD_W,
      run_dir: e.RUN_DIR_W, base_head: e.BASE_HEAD, head: e.HEAD_NOW,
      new_commits: +e.COMMITS, dirty: e.DIRTY === "true",
      result_file: (e.STATUS === "ok" || e.SALVAGED === "true") ? e.RUN_DIR_W + "/result.md" : null,
    };
    if (e.READ_ONLY === "true") {
      s.read_only = true;
      s.read_only_violation = e.READ_ONLY_VIOLATION === "true";
      s.changed_paths = JSON.parse(e.CHANGED_PATHS || "[]");
    }
    const out = JSON.stringify(s, null, 2);
    require("fs").writeFileSync(e.RUN_DIR_W + "/status.json", out + "\n");
    console.log(out);
  '
}

BASE_URL="${CODEX_WORKER_BASE_URL:-}"
PROXY_HOST=127.0.0.1; PROXY_PORT=15722
if [ -n "$BASE_URL" ]; then
  PROXY_ADDR=$(node -e 'let u;try{u=new URL(process.argv[1])}catch{process.exit(1)};console.log(u.hostname+":"+(u.port||80))' "$BASE_URL") || die "CODEX_WORKER_BASE_URL is not a valid URL"
  PROXY_HOST=${PROXY_ADDR%%:*}; PROXY_PORT=${PROXY_ADDR##*:}
fi
if [ "${CODEX_WORKER_SKIP_PREFLIGHT:-0}" != 1 ]; then
  PROXY_HOST="$PROXY_HOST" PROXY_PORT="$PROXY_PORT" node -e '
    const net = require("net"), s = net.connect({host: process.env.PROXY_HOST, port: +process.env.PROXY_PORT});
    const done = ok => { s.destroy(); process.exit(ok ? 0 : 1); };
    s.once("connect", () => done(true)); s.once("error", () => done(false));
    setTimeout(() => done(false), 3000).unref();
  ' || {
    STATUS=transient; ERROR="proxy not listening on $PROXY_HOST:$PROXY_PORT (is Ferryman running?)"; EXIT_CODE=4; SALVAGED=false
    END=$(date +%s); START=$END; write_status; exit "$EXIT_CODE"
  }
fi

if $RESUME; then SEGMENTS=$((SEGMENTS + 1)); write_state; fi

ARGS=(--json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
      -m "$MODEL" -c model_provider=custom
      -c 'project_doc_fallback_filenames=["CLAUDE.md"]' --disable hooks
      -c model_providers.custom.stream_idle_timeout_ms=120000
      -c model_providers.custom.stream_max_retries=2
      -o "$(winpath "$RUN_DIR/result.md")" -C "$(winpath "$CWD")")
[ -n "$THINKING" ] && ARGS+=(-c "model_reasoning_effort=$THINKING")
for d in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do ARGS+=(--add-dir "$(winpath "$d")"); done
if [ -n "$BASE_URL" ]; then ARGS+=(-c "model_providers.custom.base_url=\"$BASE_URL\""); fi

START=$(date +%s); SEG_START=$START; SEG_ATTEMPT=0
STATUS="error"; ERROR=""; EXIT_CODE=6; SALVAGED=false
READ_ONLY_VIOLATION=false; CHANGED_PATHS="[]"
while :; do
  ATTEMPT=$((ATTEMPT + 1)); SEG_ATTEMPT=$((SEG_ATTEMPT + 1))
  ATTEMPT_EVENTS="$RUN_DIR/attempt-$ATTEMPT.jsonl"; PROMPT_FILE="$RUN_DIR/prompt-$ATTEMPT.md"
  if [ "$SEG_ATTEMPT" -eq 1 ]; then
    USE_THREAD=$RESUME
    if $RESUME; then
      : > "$PROMPT_FILE"
      if $READ_ONLY; then printf '%s\n\n' "$READ_ONLY_PROMPT" >> "$PROMPT_FILE"; fi
      if $READ_ONLY; then printf '%s\n' "$READ_ONLY_RESUME_PROMPT" >> "$PROMPT_FILE"
      else printf '%s\n' "$RESUME_PROMPT" >> "$PROMPT_FILE"; fi
    else
      : > "$PROMPT_FILE"
      if $READ_ONLY; then printf '%s\n\n' "$READ_ONLY_PROMPT" >> "$PROMPT_FILE"; fi
      for s in ${SKILLS[@]+"${SKILLS[@]}"}; do printf 'Before starting, read %s/SKILL.md and follow it.\n\n' "$(winpath "$s")" >> "$PROMPT_FILE"; done
      cat "$RUN_DIR/brief.md" >> "$PROMPT_FILE"
      printf '\nDo the task described above. Finish with the report it asks for.\n' >> "$PROMPT_FILE"
    fi
  else
    if [ -n "$SESSION_ID" ]; then USE_THREAD=true; else USE_THREAD=false; fi
    : > "$PROMPT_FILE"
    if $READ_ONLY; then printf '%s\n\n' "$READ_ONLY_PROMPT" >> "$PROMPT_FILE"; fi
    printf '%s\n' "$RETRY_PROMPT" >> "$PROMPT_FILE"
  fi
  echo "=== attempt $ATTEMPT (segment $SEGMENTS) $(date -Iseconds) ===" >> "$STDERR"
  run_codex
  cat "$ATTEMPT_EVENTS" >> "$EVENTS"; write_state
  if [ "$WATCHDOG" = time-limit ]; then STATUS=timeout; ERROR="Time limit reached: codex did not finish within ${TIME_LIMIT}s"; EXIT_CODE=5; break; fi
  if [ "$WATCHDOG" = idle ]; then
    if [ "$(salvage_reply)" = yes ]; then
      SALVAGED=true
      ERROR="Idle timeout: no codex progress for ${IDLE_TIMEOUT}s; codex already gave a final reply (saved to result.md) but never completed the turn"
    else ERROR="Idle timeout: no codex progress for ${IDLE_TIMEOUT}s"; fi
    STATUS=stalled; EXIT_CODE=7; break
  fi
  if [ "$WATCHDOG" = proxy ]; then
    STATUS=transient; ERROR="proxy unreachable ($PROXY_HOST:$PROXY_PORT Ferryman): codex keeps waiting for network"; EXIT_CODE=4
    if [ "$SEG_ATTEMPT" -le "$RETRIES" ]; then sleep "$((RETRY_WAIT * SEG_ATTEMPT))"; continue; fi
    break
  fi
  IFS=$'\t' read -r CLS MSG NEW_THREAD < <(classify "$ATTEMPT_EVENTS" "$CODEX_EXIT")
  [ -n "${NEW_THREAD:-}" ] && SESSION_ID="$NEW_THREAD"; write_state
  case "$CLS" in
    ok) STATUS=ok; ERROR=""; EXIT_CODE=0; break ;;
    auth) STATUS=auth; ERROR="$MSG"; EXIT_CODE=2; break ;;
    transient429)
      STATUS=transient; ERROR="429: rate limit or quota exhausted — codex drops the response body, so they cannot be told apart ($MSG)"; EXIT_CODE=4
      [ "$SEG_ATTEMPT" -gt "$RETRIES" ] && break; sleep "$((RETRY_WAIT * SEG_ATTEMPT))" ;;
    transient)
      STATUS=transient; ERROR="$MSG"; EXIT_CODE=4
      [ "$SEG_ATTEMPT" -gt "$RETRIES" ] && break; sleep "$((RETRY_WAIT * SEG_ATTEMPT))" ;;
    *) STATUS=error; ERROR="$MSG"; EXIT_CODE=6; break ;;
  esac
done
END=$(date +%s)
if $READ_ONLY; then
  evaluate_read_only
  if [ "$READ_ONLY_VIOLATION" = true ] && [ "$STATUS" = ok ]; then STATUS=violation; EXIT_CODE=8; fi
fi
write_status
exit "$EXIT_CODE"
