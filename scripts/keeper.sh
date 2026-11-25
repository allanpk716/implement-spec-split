#!/usr/bin/env bash
# Keeper for unattended implement-spec-split Runs.
#
# One deterministic round, started by launchd every 10 minutes, that repairs the
# two kinds of unattended wait which cost the most time:
#   1. a Run parked on quota or a transient error is resumed once its
#      recoverable time has passed (at most KEEPER_MAX_RESUMES times per 24h);
#   2. a session that died (claim interrupted, no new report) is resumed;
#   3. a session that stalled (no transcript write for KEEPER_STALL_MIN) is
#      nudged once, and when it stays silent for another KEEPER_STALL_MIN its
#      terminal is closed, its claim released and the Spec resumed.
#
# It never writes to GitHub, pushes, deletes branches or worktrees, or touches a
# repository whose launch state has auto_land: false.
#
# Usage:
#   keeper.sh [--once] [--dry-run] [--repo <owner/name>] [--state <file>]
#
#   --once      run one round and exit (what launchd uses); without it the
#               keeper sleeps KEEPER_INTERVAL seconds (default 600) per round
#   --dry-run   print the actions it would take and write nothing at all
#   --repo      only this repository, given as owner/name
#   --state     state file; default ~/ops/state/spec-keeper/state.json when
#               ~/ops exists, else ~/.cache/implement-spec-split/keeper-state.json
#
# Environment:
#   KEEPER_STALL_MIN     minutes without a transcript write before a live claim
#                        counts as stalled (default 45)
#   KEEPER_MAX_RESUMES   automatic resumes per Spec per 24 hours (default 3)
#   KEEPER_NOTIFY_CMD    shell command run instead of osascript; it receives
#                        KEEPER_NOTIFY_TITLE and KEEPER_NOTIFY_MESSAGE
#   KEEPER_LOG           action log (default ~/ops/var/log/spec-keeper.actions.log)
#   KEEPER_PAUSED        pause flag (default <state dir>/paused)
#   KEEPER_LOCK, KEEPER_CLAIM, KEEPER_LAUNCH_WAVE, KEEPER_ORCA, KEEPER_GH
#                        overrides for the scripts and CLIs, used by the tests
#
# Exit codes: 0 round finished (also when paused or when another round holds the
# lock), 64 usage error, 1 unexpected failure.

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SKILL_ROOT=$(cd -P -- "$SCRIPT_DIR/.." && pwd) || exit 1

GH=${KEEPER_GH:-gh}
ORCA=${KEEPER_ORCA:-orca}
GIT=${KEEPER_GIT:-git}
CLAIM=${KEEPER_CLAIM:-$SKILL_ROOT/scripts/claim.sh}
LAUNCH_WAVE=${KEEPER_LAUNCH_WAVE:-$SKILL_ROOT/find-next/scripts/launch-wave.sh}
LOCK=${KEEPER_LOCK:-$SKILL_ROOT/scripts/lock.sh}

NUDGE_TEXT='继续。你是无人值守 Run：检查后台任务和 worker 状态，按 SKILL.md 推进；不要等人。'

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--once] [--dry-run] [--repo <owner/name>] [--state <file>]

Runs one keeper round: resumes quota/transient parking and dead sessions when
their recoverable time has passed, nudges then restarts a stalled session, and
notifies a human about parking that needs a decision. Reads GitHub, claims, run
directories, session transcripts and Orca; with --dry-run it writes nothing.

  --once     one round and exit (launchd); without it, rounds every
             KEEPER_INTERVAL seconds (default 600)
  --dry-run  print the actions it would take, execute none
  --repo     only this repository (owner/name)
  --state    state file (default ~/ops/state/spec-keeper/state.json, else
             ~/.cache/implement-spec-split/keeper-state.json)

Environment: KEEPER_STALL_MIN (45), KEEPER_MAX_RESUMES (3), KEEPER_NOTIFY_CMD,
KEEPER_LOG, KEEPER_PAUSED, KEEPER_LOCK, KEEPER_CLAIM, KEEPER_LAUNCH_WAVE,
KEEPER_ORCA, KEEPER_GH.
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

# --- arguments ---------------------------------------------------------------

ONCE=0
DRY=0
ONLY_REPO=
STATE_OPTION=

while [ $# -gt 0 ]; do
  case "$1" in
    --once)
      ONCE=1
      shift
      ;;
    --dry-run)
      DRY=1
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || usage_error '--repo requires <owner/name>'
      ONLY_REPO=$2
      shift 2
      ;;
    --state)
      [ $# -ge 2 ] || usage_error '--state requires a file'
      STATE_OPTION=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

case "${ONLY_REPO:-}" in
  '') ;;
  */*) ;;
  *) usage_error "--repo must be <owner/name>, got '$ONLY_REPO'" ;;
esac

# --- configuration -----------------------------------------------------------

OPS_DIR=${HOME}/ops
if [ -d "$OPS_DIR" ]; then
  STATE_DEFAULT=$OPS_DIR/state/spec-keeper/state.json
  LOG_DEFAULT=$OPS_DIR/var/log/spec-keeper.actions.log
else
  STATE_DEFAULT=${HOME}/.cache/implement-spec-split/keeper-state.json
  LOG_DEFAULT=${HOME}/.cache/implement-spec-split/keeper.log
fi

STATE=${STATE_OPTION:-${KEEPER_STATE:-$STATE_DEFAULT}}
LOG_FILE=${KEEPER_LOG:-$LOG_DEFAULT}
PAUSED_FILE=${KEEPER_PAUSED:-$(dirname -- "$STATE")/paused}

STALL_MIN=${KEEPER_STALL_MIN:-45}
MAX_RESUMES=${KEEPER_MAX_RESUMES:-3}
INTERVAL=${KEEPER_INTERVAL:-600}
case "$STALL_MIN" in
  ''|*[!0-9]*) usage_error "KEEPER_STALL_MIN must be a non-negative integer, got '$STALL_MIN'" ;;
esac
case "$MAX_RESUMES" in
  ''|*[!0-9]*) usage_error "KEEPER_MAX_RESUMES must be a non-negative integer, got '$MAX_RESUMES'" ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) usage_error "KEEPER_INTERVAL must be a non-negative integer, got '$INTERVAL'" ;;
esac
STALL_SEC=$(( STALL_MIN * 60 ))

LAUNCH_STATE_DIR=${KEEPER_LAUNCH_STATE_DIR:-${ISS_LAUNCH_STATE_DIR:-$HOME/.cache/implement-spec-split/launch}}
RUNS_ROOT=${KEEPER_RUNS_DIR:-${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}/runs}
CODEX_RUNS=${KEEPER_CODEX_RUNS:-${ISS_RUNS_ROOT:-$HOME/.cache/codex-runs}}
PROJECTS=${KEEPER_CLAUDE_PROJECTS:-$HOME/.claude/projects}

for tool in node "$GH" "$GIT" "$ORCA"; do
  command -v "$tool" >/dev/null 2>&1 ||
    { printf '%s: %s is required but was not found on PATH\n' "$SCRIPT_NAME" "$tool" >&2; exit 1; }
done
[ -x "$CLAIM" ] || [ -f "$CLAIM" ] ||
  { printf '%s: claim.sh not found: %s\n' "$SCRIPT_NAME" "$CLAIM" >&2; exit 1; }
[ -f "$LAUNCH_WAVE" ] ||
  { printf '%s: launch-wave.sh not found: %s\n' "$SCRIPT_NAME" "$LAUNCH_WAVE" >&2; exit 1; }
[ -f "$LOCK" ] ||
  { printf '%s: lock.sh not found: %s\n' "$SCRIPT_NAME" "$LOCK" >&2; exit 1; }

# --- logging -----------------------------------------------------------------

log_line() { # repo spec action reason
  local repo=${1:--} spec=${2:--} action=$3 reason=$4 line
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo" "$spec" "$action" "$reason")
  printf '%s\n' "$line"
  case "$action" in
    RESUME|NUDGE|CLOSE_TERMINAL|RELEASE_CLAIM|NOTIFY|WOULD_*)
      [ -n "${WORK:-}" ] && printf 'x\n' >>"$WORK/actions" 2>/dev/null
      ;;
  esac
  if [ "$DRY" -eq 0 ] && [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

iso_time() { # epoch seconds -> ISO 8601 with the local offset
  date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null ||
    date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null ||
    printf '%s' "$1"
}

# --- node helpers ------------------------------------------------------------

state_op() { # count|add|seen|notify|nudge-get|nudge-set|nudge-clear key [value...]
  KEEPER_STATE_FILE=$STATE KEEPER_DRY=$DRY node -e '
    const fs = require("fs"), path = require("path");
    const file = process.env.KEEPER_STATE_FILE;
    const dry = process.env.KEEPER_DRY === "1";
    const day = 24 * 60 * 60;
    const now = Math.floor(Date.now() / 1000);
    const empty = () => ({version: 1, resumes: {}, notified: {}, nudges: {}});
    let state = empty();
    try {
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      if (value && typeof value === "object") {
        if (value.resumes && typeof value.resumes === "object") state.resumes = value.resumes;
        if (value.notified && typeof value.notified === "object") state.notified = value.notified;
        if (value.nudges && typeof value.nudges === "object") state.nudges = value.nudges;
      }
    } catch (_) {}
    const save = () => {
      if (dry) return;
      const tmp = file + "." + process.pid + ".tmp";
      fs.mkdirSync(path.dirname(file), {recursive: true});
      fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n");
      fs.renameSync(tmp, file);
    };
    const prune = (key) => {
      const list = Array.isArray(state.resumes[key]) ? state.resumes[key] : [];
      const kept = list.map(Number).filter((t) => Number.isFinite(t) && now - t < day);
      if (kept.length) state.resumes[key] = kept; else delete state.resumes[key];
      return kept;
    };
    const op = process.argv[1], key = process.argv[2];
    if (op === "count") {
      process.stdout.write(String(prune(key).length));
    } else if (op === "add") {
      const list = prune(key);
      list.push(Number(process.argv[3]) || now);
      state.resumes[key] = list;
      save();
    } else if (op === "seen") {
      process.stdout.write(state.notified[key] ? "1" : "0");
    } else if (op === "notify") {
      state.notified[key] = process.argv[3] || String(now);
      save();
    } else if (op === "nudge-get") {
      const nudge = state.nudges[key];
      if (nudge && nudge.at) process.stdout.write(String(nudge.at) + "\x1f" + String(nudge.terminal || ""));
    } else if (op === "nudge-set") {
      state.nudges[key] = {at: Number(process.argv[3]) || now, terminal: process.argv[4] || ""};
      save();
    } else if (op === "nudge-clear") {
      if (state.nudges[key]) { delete state.nudges[key]; save(); }
    }
  ' "$@"
}

list_repos() { # prints repo<US>auto_land<US>flash<US>launch_agent
  LAUNCH_STATE_DIR=$LAUNCH_STATE_DIR ONLY_REPO=${ONLY_REPO:-} node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.env.LAUNCH_STATE_DIR;
    const want = process.env.ONLY_REPO.toLowerCase();
    const rows = [];
    let files = [];
    try { files = fs.readdirSync(dir); } catch (_) {}
    for (const name of files.sort()) {
      const match = name.match(/^([^_]+)__(.+)\.json$/);
      if (!match) continue;
      const repo = match[1] + "/" + match[2];
      if (want && repo.toLowerCase() !== want) continue;
      let value = null;
      try { value = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8")); } catch (_) {}
      const autoLand = !(value && value.auto_land === false);
      const flash = Boolean(value && value.flash === true);
      const agent = value && typeof value.launch_agent === "string" && value.launch_agent
        ? value.launch_agent : "claude";
      rows.push([repo, autoLand ? "1" : "0", flash ? "1" : "0", agent].join("\x1f"));
    }
    if (!rows.length && want) rows.push([want, "1", "0", "claude"].join("\x1f"));
    process.stdout.write(rows.join("\n") + (rows.length ? "\n" : ""));
  '
}

# The Orca repo registry maps owner/name to the local checkout.
repo_path() { # repo -> path, or nothing
  REPO_WANT=$1 node -e '
    const fs = require("fs");
    const want = process.env.REPO_WANT.toLowerCase();
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
    const repos = value && value.result && Array.isArray(value.result.repos)
      ? value.result.repos : [];
    for (const repo of repos) {
      const key = String((repo.gitRemoteIdentity && repo.gitRemoteIdentity.canonicalKey) || "")
        .toLowerCase().replace(/^github\.com\//, "");
      if (key !== want) continue;
      const candidate = String(repo.path || "");
      if (candidate && fs.existsSync(candidate)) { process.stdout.write(candidate); process.exit(0); }
    }
  ' "$ORCA_REPOS_FILE"
}

origin_slug() { # path -> owner/name of origin, or nothing
  "$GIT" -C "$1" remote get-url origin 2>/dev/null |
    sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | tr '[:upper:]' '[:lower:]'
}

spec_list() { # open Spec issues: number<US>title
  node -e '
    const fs = require("fs");
    let issues = [];
    try { issues = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
    const rows = [];
    for (const issue of Array.isArray(issues) ? issues : []) {
      if (!issue || typeof issue.number !== "number") continue;
      if (String(issue.state || "").toLowerCase() === "closed") continue;
      const body = String(issue.body || "");
      if (!body.split(/\r?\n/).some((line) => line.trim() === "## Problem Statement")) continue;
      const title = String(issue.title || "").replace(/[\t\r\n]+/g, " ").trim();
      rows.push([issue.number, title]);
    }
    rows.sort((a, b) => a[0] - b[0]);
    process.stdout.write(rows.map((row) => row.join("\x1f")).join("\n") + (rows.length ? "\n" : ""));
  ' "$WORK/issues.json"
}

worktree_for() { # spec number -> worktree path of branch spec-<n>, or nothing
  node -e '
    const fs = require("fs");
    const wanted = "branch refs/heads/spec-" + process.argv[2];
    let text = "";
    try { text = fs.readFileSync(process.argv[1], "utf8"); } catch (_) {}
    let worktree = null;
    for (const line of text.split(/\r?\n/)) {
      if (line.startsWith("worktree ")) worktree = line.slice("worktree ".length);
      else if (line === wanted && worktree) { process.stdout.write(worktree); process.exit(0); }
      else if (line === "") worktree = null;
    }
  ' "$WORK/worktrees.txt" "$1"
}

claim_worktree() { # claim record -> worktree, or nothing
  CLAIM_RECORD=$1 node -e '
    let value = {};
    try { value = JSON.parse(process.env.CLAIM_RECORD || "{}"); } catch (_) {}
    if (typeof value.worktree === "string") process.stdout.write(value.worktree);
  '
}

claim_is_reserved() { # claim record -> 1 while a handoff reservation is live
  CLAIM_RECORD=$1 node -e '
    let value = {};
    try { value = JSON.parse(process.env.CLAIM_RECORD || "{}"); } catch (_) {}
    const until = Number(value.handoff_until_epoch || 0) * 1000;
    process.stdout.write(value.handoff && until > Date.now() ? "1" : "0");
  '
}

run_state() { # repo name, spec -> phase<US>updated<US>run mtime<US>worker mtime
  RUNS_ROOT=$RUNS_ROOT CODEX_RUNS=$CODEX_RUNS node -e '
    const fs = require("fs"), path = require("path");
    const runs = process.env.RUNS_ROOT, codex = process.env.CODEX_RUNS;
    const name = process.argv[1], spec = process.argv[2];
    const prefix = name + "-" + spec + "-";
    const newest = (root) => {
      let latest = 0;
      const walk = (dir) => {
        let entries;
        try { entries = fs.readdirSync(dir, {withFileTypes: true}); } catch (_) { return; }
        for (const entry of entries) {
          if (entry.name === ".git") continue;
          const full = path.join(dir, entry.name);
          if (entry.isDirectory()) walk(full);
          else if (entry.isFile()) {
            try {
              const modified = fs.statSync(full).mtimeMs;
              if (modified > latest) latest = modified;
            } catch (_) {}
          }
        }
      };
      try { walk(root); } catch (_) {}
      return Math.floor(latest / 1000);
    };
    let phase = "", updated = "", runMtime = 0;
    let entries = [];
    try { entries = fs.readdirSync(runs, {withFileTypes: true}); } catch (_) {}
    const dirs = entries.filter((e) => e.isDirectory() && e.name.startsWith(prefix))
      .map((e) => e.name).sort();
    for (const dir of dirs) runMtime = Math.max(runMtime, newest(path.join(runs, dir)));
    for (let i = dirs.length - 1; i >= 0; i--) {
      try {
        const value = JSON.parse(fs.readFileSync(path.join(runs, dirs[i], "run.json"), "utf8"));
        phase = String(value.phase || "");
        updated = String(value.updated || "");
        break;
      } catch (_) {}
    }
    // Worker run dirs belong to this Spec when their name mentions the repository
    // and the Spec number (for example proxy-hub-20261125-1343 or ...-fix48).
    let workerMtime = 0;
    const lowerName = name.toLowerCase();
    const specToken = new RegExp("(^|[^0-9])" + spec + "($|[^0-9])");
    let workers = [];
    try { workers = fs.readdirSync(codex, {withFileTypes: true}); } catch (_) {}
    for (const entry of workers) {
      if (!entry.isDirectory()) continue;
      const label = entry.name.toLowerCase();
      if (!label.includes(lowerName)) continue;
      if (!label.includes("spec-" + spec) && !specToken.test(label)) continue;
      workerMtime = Math.max(workerMtime, newest(path.join(codex, entry.name)));
    }
    process.stdout.write([phase, updated, String(runMtime), String(workerMtime)].join("\x1f"));
  ' "$1" "$2"
}

newest_jsonl() { # directory -> newest *.jsonl mtime in seconds, or 0
  node -e '
    const fs = require("fs"), path = require("path");
    // Subagents (agent implementers, review axes) write under
    // <session>/subagents/, so walk a few levels down, not just the top.
    let latest = 0;
    const walk = (dir, depth) => {
      let entries;
      try { entries = fs.readdirSync(dir, {withFileTypes: true}); } catch (_) { return; }
      for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) { if (depth < 3) walk(full, depth + 1); continue; }
        if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
        try { latest = Math.max(latest, fs.statSync(full).mtimeMs); } catch (_) {}
      }
    };
    walk(process.argv[1], 0);
    process.stdout.write(String(Math.floor(latest / 1000)));
  ' "$1"
}

# The machine-readable block of a parking report, with the keyword fallback for
# reports written before the two lines existed.
report_info() { # spec number -> kind<US>id<US>url<US>category<US>recover_at<US>source<US>created_at
  local comments=$WORK/comments.json
  if ! "$GH" api "repos/$REPO/issues/$1/comments" --paginate --slurp >"$comments" 2>"$WORK/gh.err" </dev/null; then
    printf 'error\x1f\x1f\x1f\x1f\x1f\x1f%s\n' "$(head -n 1 "$WORK/gh.err" 2>/dev/null)"
    return 0
  fi
  node -e '
    const fs = require("fs");
    let pages = [];
    try { pages = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
    const comments = Array.isArray(pages) && pages.length && Array.isArray(pages[0])
      ? pages.flat() : [pages].flat();

    const parseClock = (text) => {
      const value = Date.parse(text);
      return Number.isFinite(value) ? value : NaN;
    };
    const localDate = (year, month, day, hour, minute) =>
      new Date(year, month - 1, day, hour, minute).getTime();

    // Every time a report body mentions, in ms since the epoch (NaN-free).
    const parseTimes = (body, createdMs) => {
      const found = [];
      let match;
      const iso = /20\d{2}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}(:\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/g;
      while ((match = iso.exec(body))) {
        const value = parseClock(match[0].replace(" ", "T"));
        if (Number.isFinite(value)) found.push(value);
      }
      const created = Number.isFinite(createdMs) ? new Date(createdMs) : new Date();
      const monthDay = /(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]\s*(\d{1,2})\s*[:：时]\s*(\d{2})?/g;
      while ((match = monthDay.exec(body))) {
        found.push(localDate(created.getFullYear(), Number(match[1]), Number(match[2]),
          Number(match[3]), Number(match[4] || 0)));
      }
      const shortDate = /\b(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})\b/g;
      while ((match = shortDate.exec(body))) {
        found.push(localDate(created.getFullYear(), Number(match[1]), Number(match[2]),
          Number(match[3]), Number(match[4])));
      }
      // "resets 1am" names a time of day, not a date: keep the current and the
      // next occurrence, but never one long before the report was written (then
      // the reset it means is the one that already passed).
      const amPm = /\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)/gi;
      while ((match = amPm.exec(body))) {
        let hour = Number(match[1]) % 12;
        if (/p/i.test(match[3])) hour += 12;
        const minute = Number(match[2] || 0);
        const today = localDate(created.getFullYear(), created.getMonth() + 1,
          created.getDate(), hour, minute);
        for (const value of [today, today + 24 * 60 * 60 * 1000]) {
          if (value >= createdMs - 6 * 60 * 60 * 1000) found.push(value);
        }
      }
      return found.filter(Number.isFinite);
    };

    let last = null;
    for (const comment of comments) {
      if (!comment) continue;
      const body = String(comment.body || "").trim();
      let kind = null;
      if (/^##\s*落地报告/.test(body)) kind = "landing";
      else if (/^##\s*停车报告/.test(body)) kind = "parking";
      if (!kind) continue;
      last = {
        id: comment.id == null ? "" : String(comment.id),
        kind,
        url: String(comment.html_url || ""),
        body,
        created_at: String(comment.created_at || ""),
      };
    }
    if (!last) { process.stdout.write("none\x1f\x1f\x1f\x1f\x1f\x1f"); process.exit(0); }
    if (last.kind !== "parking") {
      process.stdout.write([last.kind, last.id, last.url, "", "", "", last.created_at].join("\x1f"));
      process.exit(0);
    }

    const createdMs = parseClock(last.created_at);
    const lines = last.body.split(/\r?\n/);
    let start = -1;
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*##\s*停车报告/.test(lines[i])) { start = i; break; }
    }
    let category = "";
    let recoverRaw = "";
    if (start >= 0) {
      for (let i = start + 1; i < Math.min(lines.length, start + 16); i++) {
        if (/^\s*#/.test(lines[i])) break;
        const line = lines[i].replace(/\*/g, "").trim();
        let match = line.match(/^停车类别\s*[：:]\s*(.*)$/);
        if (match && !category) {
          const word = String(match[1]).match(/quota|transient|decision|error|other/i);
          category = word ? word[0].toLowerCase() : "";
        }
        match = line.match(/^可恢复时间\s*[：:]\s*(.*)$/);
        if (match && !recoverRaw) recoverRaw = match[1].trim();
      }
    }

    let source = "machine";
    let recover = NaN;
    if (category) {
      if (!recoverRaw || /^(无|none|null|-)$/i.test(recoverRaw)) recover = "";
      else {
        recover = parseClock(recoverRaw);
        if (!Number.isFinite(recover)) {
          const piece = recoverRaw.match(/20\d{2}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}(:\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/);
          if (piece) recover = parseClock(piece[0].replace(" ", "T"));
        }
      }
    } else {
      source = "legacy";
      const low = last.body.toLowerCase();
      if (/额度|429|quota|rate\s*limit|resets/.test(low)) {
        category = "quota";
        // A report may quote the time it was written; ignore that one, but keep
        // a reset time that already passed (the quota is back, so resume now).
        const future = parseTimes(last.body, createdMs)
          .filter((value) => Math.abs(value - createdMs) > 15 * 60 * 1000);
        const fiveHours = createdMs + 5 * 60 * 60 * 1000;
        let best = fiveHours;
        for (const value of future) if (value < best) best = value;
        recover = best;
      } else {
        category = "decision";
        recover = "";
      }
    }

    const recoverText = recover === "" ? "" : (Number.isFinite(recover) ? String(Math.floor(recover / 1000)) : "");
    process.stdout.write([last.kind, last.id, last.url, category, recoverText, source, last.created_at].join("\x1f"));
  ' "$comments"
}

# One agent terminal in the Spec worktree: no progress tab, preferring the agent
# the launch state names and otherwise the most recently active one.
terminal_pick() { # worktree spec launch_agent -> handle<US>title<US>agent
  node -e '
    const fs = require("fs");
    const wanted = process.argv[2];
    const spec = process.argv[3];
    const agent = String(process.argv[4] || "claude").toLowerCase();
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
    const terminals = value && value.result && Array.isArray(value.result.terminals)
      ? value.result.terminals : [];
    const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
    const progress = new RegExp("^spec-" + spec + " (t[0-9]+|merge t[0-9]+|merge main|fix)$");
    let best = null;
    for (const terminal of terminals) {
      if (!terminal) continue;
      const worktree = String(terminal.worktreePath || "");
      if (!worktree || real(worktree) !== real(wanted)) continue;
      const title = String(terminal.title || "");
      if (progress.test(title)) continue;
      const identity = String(terminal.agentIdentity || "").toLowerCase();
      if (!identity) continue;
      const score = identity === agent ? 2 : 1;
      const at = Number(terminal.lastOutputAt || 0);
      if (!best || score > best.score || (score === best.score && at > best.at)) {
        best = {score, at, handle: String(terminal.handle || ""), title, identity};
      }
    }
    if (best) process.stdout.write([best.handle, best.title, best.identity].join("\x1f"));
  ' "$WORK/terminals.json" "$1" "$2" "$3"
}

# --- notifications -----------------------------------------------------------

notify() { # repo spec message -> 0 when delivered (or would be), 1 on failure
  local repo=$1 spec=$2 message=$3
  if [ "$DRY" -eq 1 ]; then
    log_line "$repo" "$spec" WOULD_NOTIFY "$message"
    return 0
  fi
  if [ -n "${KEEPER_NOTIFY_CMD:-}" ]; then
    if KEEPER_NOTIFY_TITLE=spec-keeper KEEPER_NOTIFY_MESSAGE=$message \
         /bin/bash -c "$KEEPER_NOTIFY_CMD" >/dev/null 2>&1; then
      log_line "$repo" "$spec" NOTIFY "$message"
      return 0
    fi
    log_line "$repo" "$spec" ERROR "通知命令失败：$message"
    return 1
  fi
  local escaped=${message//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  if command -v osascript >/dev/null 2>&1 &&
     osascript -e "display notification \"$escaped\" with title \"spec-keeper\"" >/dev/null 2>&1; then
    log_line "$repo" "$spec" NOTIFY "$message"
    return 0
  fi
  log_line "$repo" "$spec" ERROR "osascript 通知失败：$message"
  return 1
}

# --- decisions ---------------------------------------------------------------

can_resume() { # spec -> 0 while under the 24h limit, else 1 after notifying once
  local spec=$1 count
  count=$(state_op count "$REPO#$spec")
  if [ "$count" -lt "$MAX_RESUMES" ]; then
    return 0
  fi
  local key="limit:$REPO#$spec:$(date +%F)"
  if [ "$(state_op seen "$key")" = 1 ]; then
    log_line "$REPO" "#$spec" SKIP "24 小时内已自动恢复 $count 次，停止自动恢复"
    return 1
  fi
  if notify "$REPO" "#$spec" "#$spec 今日自动恢复已达 $MAX_RESUMES 次，停止自动恢复"; then
    [ "$DRY" -eq 0 ] && state_op notify "$key" "$(date +%s)"
    log_line "$REPO" "#$spec" LIMIT "24 小时内已自动恢复 $count 次，停止自动恢复"
  fi
  return 1
}

do_resume() { # spec reason
  local spec=$1 reason=$2 out status=0 word
  if ! can_resume "$spec"; then
    return 0
  fi
  if [ "$DRY" -eq 1 ]; then
    log_line "$REPO" "#$spec" WOULD_RESUME "$reason"
    return 0
  fi
  out=$WORK/launch-$spec.out
  if [ "$FLASH" -eq 1 ]; then
    ( cd "$REPO_PATH" && FLASH_ORCHESTRATOR=1 "$LAUNCH_WAVE" --repo "$REPO" --only "$spec" --apply ) \
      >"$out" 2>&1 || status=$?
  else
    ( cd "$REPO_PATH" && "$LAUNCH_WAVE" --repo "$REPO" --only "$spec" --apply ) \
      >"$out" 2>&1 || status=$?
  fi
  cat "$out" 2>/dev/null || true
  # launch-wave exits 0 even when --only names a Spec it cannot start; a real
  # resume leaves the claim active (a fresh launch reserves it).
  word=$("$CLAIM" status "$spec" </dev/null 2>/dev/null | awk '{print $1}')
  if [ "$status" -eq 0 ] && [ "$word" = active ]; then
    state_op add "$REPO#$spec" "$(date +%s)"
    state_op nudge-clear "$REPO#$spec"
    log_line "$REPO" "#$spec" RESUME "$reason"
  elif [ "$status" -eq 0 ]; then
    log_line "$REPO" "#$spec" ERROR "launch-wave 没有启动 #${spec}（claim=${word}）：$(tail -n 1 "$out" 2>/dev/null)"
  else
    log_line "$REPO" "#$spec" ERROR "launch-wave 退出码 ${status}：$(tail -n 1 "$out" 2>/dev/null)"
  fi
}

notify_park_once() { # spec comment id url category
  local spec=$1 id=$2 url=$3 category=$4 key
  key="park:$REPO#$spec:$id"
  if [ "$(state_op seen "$key")" = 1 ]; then
    log_line "$REPO" "#$spec" SKIP "停车报告 $id 已通知过（${category}）"
    return 0
  fi
  if notify "$REPO" "#$spec" "$REPO #$spec 停车待你决定：$url"; then
    [ "$DRY" -eq 0 ] && state_op notify "$key" "$(date +%s)"
  fi
}

stall_check() { # spec worktree
  local spec=$1 worktree=$2 state phase updated run_mtime worker_mtime
  state=$(run_state "$REPO_NAME" "$spec")
  IFS=$'\x1f' read -r phase updated run_mtime worker_mtime <<EOF
$state
EOF
  [ -n "${run_mtime:-}" ] || run_mtime=0
  [ -n "${worker_mtime:-}" ] || worker_mtime=0
  if [ -z "$phase" ]; then
    log_line "$REPO" "#$spec" SKIP "找不到 run.json，无法判断 phase"
    return 0
  fi
  if [ "$phase" = done ] || [ "$phase" = parked ]; then
    state_op nudge-clear "$REPO#$spec"
    return 0
  fi
  local encoded transcript now activity age
  encoded=$(printf '%s' "$worktree" | sed 's#[^A-Za-z0-9]#-#g')
  transcript=$(newest_jsonl "$PROJECTS/$encoded")
  if [ "$transcript" = 0 ]; then
    log_line "$REPO" "#$spec" SKIP "找不到会话 transcript：$PROJECTS/$encoded"
    return 0
  fi
  now=$(date +%s)
  activity=$transcript
  [ "$run_mtime" -gt "$activity" ] && activity=$run_mtime
  [ "$worker_mtime" -gt "$activity" ] && activity=$worker_mtime
  age=$(( now - activity ))
  if [ "$age" -lt "$STALL_SEC" ]; then
    state_op nudge-clear "$REPO#$spec"
    return 0
  fi

  local nudge handle at
  nudge=$(state_op nudge-get "$REPO#$spec")
  if [ -z "$nudge" ]; then
    handle=$(terminal_pick "$worktree" "$spec" "$LAUNCH_AGENT")
    handle=${handle%%$'\x1f'*}
    if [ -z "$handle" ]; then
      log_line "$REPO" "#$spec" SKIP "卡住 ${age}s 无写入，但找不到会话终端：$worktree"
      return 0
    fi
    if [ "$DRY" -eq 1 ]; then
      log_line "$REPO" "#$spec" WOULD_NUDGE "卡住 ${age}s 无写入；发送继续到 $handle"
      return 0
    fi
    if "$ORCA" terminal send --terminal "$handle" --text "$NUDGE_TEXT" --enter >/dev/null 2>&1; then
      state_op nudge-set "$REPO#$spec" "$(date +%s)" "$handle"
      log_line "$REPO" "#$spec" NUDGE "卡住 ${age}s 无写入；已发送继续到 $handle"
    else
      log_line "$REPO" "#$spec" ERROR "orca terminal send 失败：$handle"
    fi
    return 0
  fi

  at=${nudge%%$'\x1f'*}
  handle=${nudge#*$'\x1f'}
  if [ $(( now - at )) -lt "$STALL_SEC" ]; then
    log_line "$REPO" "#$spec" WAIT "已发送继续，仍在等待（$(( now - at ))s）"
    return 0
  fi
  if ! can_resume "$spec"; then
    return 0
  fi
  if [ "$DRY" -eq 1 ]; then
    [ -n "$handle" ] && log_line "$REPO" "#$spec" WOULD_CLOSE_TERMINAL "$handle"
    log_line "$REPO" "#$spec" WOULD_RELEASE_CLAIM "claim.sh release $spec --force"
    log_line "$REPO" "#$spec" WOULD_RESUME "卡住超过 $STALL_MIN 分钟且发送继续后仍无写入"
    return 0
  fi
  if [ -n "$handle" ]; then
    if "$ORCA" terminal close --terminal "$handle" --tab >/dev/null 2>&1; then
      log_line "$REPO" "#$spec" CLOSE_TERMINAL "$handle"
    else
      log_line "$REPO" "#$spec" ERROR "orca terminal close 失败：$handle"
    fi
  fi
  if ( cd "$REPO_PATH" && "$CLAIM" release "$spec" --force ) >/dev/null 2>&1; then
    log_line "$REPO" "#$spec" RELEASE_CLAIM "claim.sh release $spec --force"
  else
    log_line "$REPO" "#$spec" ERROR "claim.sh release $spec --force 失败"
  fi
  do_resume "$spec" "卡住超过 $STALL_MIN 分钟，发送继续后仍无写入"
}

process_spec() { # spec title
  local spec=$1 title=$2
  local claim_line claim_word claim_record worktree report
  claim_line=$("$CLAIM" status "$spec" </dev/null 2>"$WORK/claim.err" | sed -n '1p')
  claim_word=$(printf '%s' "$claim_line" | awk '{print $1}')
  claim_record=$(printf '%s' "$claim_line" | cut -d' ' -f2-)
  [ -n "$claim_word" ] || claim_word=free
  worktree=$(worktree_for "$spec")
  [ -n "$worktree" ] || worktree=$(claim_worktree "$claim_record")

  if [ "$claim_word" = active ]; then
    if [ "$(claim_is_reserved "$claim_record")" = 1 ]; then
      log_line "$REPO" "#$spec" SKIP "claim 处于交接预留期，等待会话接管"
      return 0
    fi
    if [ -z "$worktree" ]; then
      log_line "$REPO" "#$spec" SKIP "claim active 但找不到 spec-$spec 的 worktree"
      return 0
    fi
    stall_check "$spec" "$worktree"
    return 0
  fi

  report=$(report_info "$spec")
  local kind id url category recover_at source created_at
  IFS=$'\x1f' read -r kind id url category recover_at source created_at <<EOF
$report
EOF
  if [ "$kind" = error ]; then
    log_line "$REPO" "#$spec" ERROR "gh comments 失败：$created_at"
    return 0
  fi
  if [ "$kind" = parking ]; then
    case "$category" in
      quota|transient)
        if [ -z "$recover_at" ] || [ "$recover_at" -le "$(date +%s)" ]; then
          do_resume "$spec" "$category 停车，已过可恢复时间"
        else
          log_line "$REPO" "#$spec" WAIT "等待可恢复时间 $(iso_time "$recover_at")（$category 停车：${title}，报告 ${id}）"
        fi
        ;;
      *)
        notify_park_once "$spec" "$id" "$url" "$category"
        ;;
    esac
    return 0
  fi
  if [ "$claim_word" = interrupted ]; then
    do_resume "$spec" "会话已死（claim interrupted），没有新的报告"
  fi
}

process_repo() { # repo path flash launch_agent
  REPO=$1
  REPO_PATH=$2
  REPO_NAME=${1#*/}
  FLASH=$3
  LAUNCH_AGENT=$4
  (
    cd "$REPO_PATH" || exit 1
    if ! "$GH" issue list --repo "$REPO" --state all --limit 200 \
         --json number,title,state,body >"$WORK/issues.json" 2>"$WORK/gh.err"; then
      log_line "$REPO" - ERROR "gh issue list 失败：$(head -n 1 "$WORK/gh.err" 2>/dev/null)"
      exit 0
    fi
    "$GIT" worktree list --porcelain >"$WORK/worktrees.txt" 2>/dev/null || : >"$WORK/worktrees.txt"
    spec_list >"$WORK/specs.txt"
    local spec title
    while IFS=$'\x1f' read -r spec title; do
      [ -n "$spec" ] || continue
      process_spec "$spec" "$title"
    done <"$WORK/specs.txt"
  )
}

run_round() {
  local repo auto_land flash agent path started
  started=$(date +%s)
  log_line - - ROUND "start dry_run=$DRY"
  if [ -e "$PAUSED_FILE" ]; then
    log_line - - PAUSED "$PAUSED_FILE 存在，本轮跳过"
    return 0
  fi
  if [ "$DRY" -eq 0 ]; then
    if ! "$LOCK" acquire keeper --scope global --wait 0 >/dev/null 2>&1; then
      log_line - - LOCK "另一轮 keeper 正在运行，本轮退出"
      return 0
    fi
    LOCK_HELD=1
  fi

  : >"$WORK/orca-repos.json"
  "$ORCA" repo list --json >"$WORK/orca-repos.json" 2>/dev/null </dev/null || : >"$WORK/orca-repos.json"
  ORCA_REPOS_FILE=$WORK/orca-repos.json
  : >"$WORK/terminals.json"
  "$ORCA" terminal list --json >"$WORK/terminals.json" 2>/dev/null </dev/null || : >"$WORK/terminals.json"
  : >"$WORK/actions"

  list_repos >"$WORK/repos.txt"
  while IFS=$'\x1f' read -r repo auto_land flash agent; do
    [ -n "$repo" ] || continue
    if [ "$auto_land" = 0 ]; then
      log_line "$repo" - SKIP "auto_land=false，不处理"
      continue
    fi
    path=$(repo_path "$repo")
    if [ -z "$path" ]; then
      for candidate in "$HOME/orca/${repo#*/}" "$HOME/orca/workspaces/${repo#*/}"; do
        [ -d "$candidate" ] || continue
        [ "$(origin_slug "$candidate")" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ] || continue
        path=$candidate
        break
      done
    fi
    if [ -z "$path" ]; then
      log_line "$repo" - SKIP "找不到本地 checkout，跳过"
      continue
    fi
    process_repo "$repo" "$path" "$flash" "$agent"
  done <"$WORK/repos.txt"
  log_line - - ROUND "end actions=$(wc -l <"$WORK/actions" 2>/dev/null | tr -d ' ') seconds=$(( $(date +%s) - started ))"
}

# --- main --------------------------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/keeper.XXXXXX") || {
  printf '%s: could not create a temporary directory\n' "$SCRIPT_NAME" >&2
  exit 1
}
LOCK_HELD=0
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$LOCK_HELD" -eq 1 ]; then
    "$LOCK" release keeper --scope global >/dev/null 2>&1 || true
  fi
  rm -f "$WORK"/* 2>/dev/null
  rmdir "$WORK" 2>/dev/null
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ "$DRY" -eq 0 ] && [ -n "$LOG_FILE" ]; then
  mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
fi

if [ "$ONCE" -eq 1 ]; then
  run_round
  exit 0
fi

printf '%s: loop mode, one round every %s seconds (Ctrl-C to stop)\n' "$SCRIPT_NAME" "$INTERVAL" >&2
while :; do
  run_round
  sleep "$INTERVAL"
done
