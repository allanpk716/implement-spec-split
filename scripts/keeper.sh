#!/usr/bin/env bash
# Keeper for unattended implement-spec-split Runs.
#
# One deterministic round, started by launchd every 10 minutes, that repairs the
# two kinds of unattended wait which cost the most time:
#   1. a Run parked on quota or a transient error is resumed once its
#      recoverable time has passed (at most KEEPER_MAX_RESUMES times per 24h);
#   2. a session that died (claim interrupted, no new report) is asked of Orca
#      first, by the rule of 3 (an interrupted claim only says the claiming
#      pid is gone: a Spec parked with its reservation kept is found so once
#      the reservation lapses, while its session still works): resumed when
#      every worker in its Spec worktree exited or none is listed there (the
#      terminals Orca still lists are closed first), left alone and reported
#      once when a worker is live or Orca cannot vouch for it;
#   3. a session whose files went silent for KEEPER_STALL_MIN is asked of
#      Orca, which manages it as a worker (the first evidence; the file times
#      are the second): a live worker is left alone, however old the files
#      are; an exited worker is a confirmed failure — its terminal is closed,
#      its claim released and the Spec resumed; a worker Orca cannot vouch
#      for (unverifiable, or none listed in the Spec worktree) is reported
#      to a human once per Spec and evidence, and left alone: Orca forbids
#      a stop, a retry or a release on anything but an exited worker;
#   4. once a round, after the repositories, scripts/sweep-worktrees.sh sweeps
#      the abandoned Spec and Ticket worktrees of the machine (规格 #26), in
#      keeper's own mode: --dry-run passes --dry-run on, --repo is passed on,
#      every removal (or would-be removal) and failure is logged, and a sweep
#      that fails is reported and never fatal.
#
# It never writes to GitHub or pushes, never deletes a branch or worktree of a
# Spec itself (the sweep does, by its own rules), and never touches a
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
#                        counts as stalled and is asked of Orca (default 45)
#   KEEPER_MAX_RESUMES   automatic resumes per Spec per 24 hours (default 3)
#   KEEPER_WORKER_PAGES  pages of the worker list walked at most while looking
#                        for the worker of a Spec worktree (default 10)
#   KEEPER_NOTIFY_CMD    shell command run instead of osascript; it receives
#                        KEEPER_NOTIFY_TITLE and KEEPER_NOTIFY_MESSAGE
#   KEEPER_LOG           action log (default ~/ops/var/log/spec-keeper.actions.log)
#   KEEPER_PAUSED        pause flag (default <state dir>/paused)
#   KEEPER_LOCK, KEEPER_CLAIM, KEEPER_LAUNCH_WAVE, KEEPER_GH, KEEPER_SWEEP
#                        overrides for the scripts and CLIs, used by the tests
#   ISS_ORCA             the Orca executable (default `orca`), read by
#                        scripts/lib-orca.sh; every Orca call goes through it
#
# Exit codes: 0 round finished (also when paused or when another round holds the
# lock), 64 usage error, 1 unexpected failure.

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SKILL_ROOT=$(cd -P -- "$SCRIPT_DIR/.." && pwd) || exit 1
# shellcheck source=lib-orca.sh
source "$SCRIPT_DIR/lib-orca.sh"

GH=${KEEPER_GH:-gh}
GIT=${KEEPER_GIT:-git}
CLAIM=${KEEPER_CLAIM:-$SKILL_ROOT/scripts/claim.sh}
LAUNCH_WAVE=${KEEPER_LAUNCH_WAVE:-$SKILL_ROOT/find-next/scripts/launch-wave.sh}
LOCK=${KEEPER_LOCK:-$SKILL_ROOT/scripts/lock.sh}
SWEEP=${KEEPER_SWEEP:-$SKILL_ROOT/scripts/sweep-worktrees.sh}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--once] [--dry-run] [--repo <owner/name>] [--state <file>]

Runs one keeper round: resumes quota/transient parking and dead sessions when
their recoverable time has passed, asks Orca whether a silent or interrupted
session is still alive and restarts it only when Orca says it exited (or lists
no worker for it), notifies a human about parking that needs a decision, about
sessions Orca cannot vouch for and about an interrupted claim whose session is
still live, and sweeps abandoned Spec and Ticket worktrees
(scripts/sweep-worktrees.sh). Reads GitHub, claims, run directories, session
transcripts and Orca; with --dry-run it writes nothing.

  --once     one round and exit (launchd); without it, rounds every
             KEEPER_INTERVAL seconds (default 600)
  --dry-run  print the actions it would take, execute none
  --repo     only this repository (owner/name)
  --state    state file (default ~/ops/state/spec-keeper/state.json, else
             ~/.cache/implement-spec-split/keeper-state.json)

Environment: KEEPER_STALL_MIN (45), KEEPER_MAX_RESUMES (3), KEEPER_WORKER_PAGES
(10), KEEPER_NOTIFY_CMD, KEEPER_LOG, KEEPER_PAUSED, KEEPER_LOCK, KEEPER_CLAIM,
KEEPER_LAUNCH_WAVE, KEEPER_GH, KEEPER_SWEEP, ISS_ORCA (the Orca executable, see
lib-orca.sh).
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
WORKER_PAGES=${KEEPER_WORKER_PAGES:-10}
case "$STALL_MIN" in
  ''|*[!0-9]*) usage_error "KEEPER_STALL_MIN must be a non-negative integer, got '$STALL_MIN'" ;;
esac
case "$MAX_RESUMES" in
  ''|*[!0-9]*) usage_error "KEEPER_MAX_RESUMES must be a non-negative integer, got '$MAX_RESUMES'" ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) usage_error "KEEPER_INTERVAL must be a non-negative integer, got '$INTERVAL'" ;;
esac
case "$WORKER_PAGES" in
  ''|*[!0-9]*|0) usage_error "KEEPER_WORKER_PAGES must be a positive integer, got '$WORKER_PAGES'" ;;
esac
STALL_SEC=$(( STALL_MIN * 60 ))

LAUNCH_STATE_DIR=${KEEPER_LAUNCH_STATE_DIR:-${ISS_LAUNCH_STATE_DIR:-$HOME/.cache/implement-spec-split/launch}}
RUNS_ROOT=${KEEPER_RUNS_DIR:-${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}/runs}
CODEX_RUNS=${KEEPER_CODEX_RUNS:-${ISS_RUNS_ROOT:-$HOME/.cache/codex-runs}}
PROJECTS=${KEEPER_CLAUDE_PROJECTS:-$HOME/.claude/projects}

for tool in node "$GH" "$GIT" "$(orca_exe)"; do
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
    RESUME|CLOSE_TERMINAL|RELEASE_CLAIM|REMOVE_WORKTREE|NOTIFY|WOULD_*)
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

state_op() { # count|add|seen|notify key [value...]
  KEEPER_STATE_FILE=$STATE KEEPER_DRY=$DRY node -e '
    const fs = require("fs"), path = require("path");
    const file = process.env.KEEPER_STATE_FILE;
    const dry = process.env.KEEPER_DRY === "1";
    const day = 24 * 60 * 60;
    const now = Math.floor(Date.now() / 1000);
    const empty = () => ({version: 1, resumes: {}, notified: {}});
    let state = empty();
    try {
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      if (value && typeof value === "object") {
        if (value.resumes && typeof value.resumes === "object") state.resumes = value.resumes;
        if (value.notified && typeof value.notified === "object") state.notified = value.notified;
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
    }
  ' "$@"
}

list_repos() { # prints repo<US>auto_land<US>flash
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
      rows.push([repo, autoLand ? "1" : "0", flash ? "1" : "0"].join("\x1f"));
    }
    if (!rows.length && want) rows.push([want, "1", "0"].join("\x1f"));
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

# --- Orca liveness ------------------------------------------------------------
# The first evidence about a silent session (the file times are the second):
# the liveness Orca reports for the worker in the Spec worktree.

# The workers Orca lists in one worktree, out of one page of worker-list read
# from stdin: the dispatch id of each, one per line, then `cursor<TAB><nextCursor>`
# (empty on the last page). Only the ids: the liveness of each is taken from
# worker-show, never from the list. The worktree is compared by real path: Orca
# writes the canonical one, git may not.
workers_in_page() { # worktree
  WORKTREE_WANT=$1 node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const result = value && value.result && typeof value.result === "object" ? value.result : null;
    if (!result || !Array.isArray(result.workers)) process.exit(2);
    const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
    const wanted = real(process.env.WORKTREE_WANT);
    const rows = [];
    for (const worker of result.workers) {
      if (!worker || !worker.dispatchId) continue;
      const workspace = String(worker.workspace || "");
      const cut = workspace.indexOf("::");
      if (real(cut >= 0 ? workspace.slice(cut + 2) : workspace) !== wanted) continue;
      rows.push(String(worker.dispatchId));
    }
    rows.push("cursor\t" + (result.nextCursor == null ? "" : String(result.nextCursor)));
    process.stdout.write(rows.join("\n") + "\n");
  '
}

# The three fields of a worker-show receipt keeper acts on, joined with the
# unit separator: a tab would not do, since read folds runs of it and the
# terminal is empty for a terminal Orca has already released.
worker_show_fields() { # stdin: worker-show --json -> liveness<US>terminal<US>terminalState
  node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const result = value && value.result && typeof value.result === "object" ? value.result : null;
    if (!result) process.exit(2);
    process.stdout.write([String(result.liveness || ""), String(result.terminal || ""),
      String(result.terminalState || "")].join("\x1f"));
  '
}

# Asks Orca for the worker(s) of the Spec worktree and concludes one of
#   live         a worker in the worktree is live: the session is alive
#   exited       every worker in it exited: a confirmed failure
#   unverifiable anything else: a worker Orca cannot vouch for, no worker at
#                all for the worktree, an Orca that cannot answer or a page
#                that cannot be read — nothing is retried on any of these
# The list has no worktree filter (docs/orca-smoke-2026-11-27.md), so it is
# walked page by page until the worktree turns up or the list ends, at most
# KEEPER_WORKER_PAGES pages so that a list Orca keeps extending cannot loop
# the round; a list cut short by that cap still supports live, but not exited,
# which is a claim about every worker in the worktree. Each worker found is
# asked of worker-show, whose liveness decides; a live one ends the walk, since
# nothing else in the worktree can change that conclusion. Prints
# verdict<US>key<US>evidence<US>terminals: key is what the once-only
# notification is keyed on (the dispatch, or none, or orca), evidence names
# every dispatch and its liveness, and terminals are the handles of the exited
# workers Orca has not released. none means the whole list has no worker for
# the worktree; a list cut short before the worktree turned up says orca
# instead, since it is Orca that could not finish the answer.
worker_liveness() { # worktree -> verdict<US>key<US>evidence<US>terminals
  local worktree=$1 cursor= page=0 rows= next= list= args
  local dispatches=() dispatch fields liveness terminal state
  local evidence= key=none handles= unsure=0 truncated=
  while :; do
    page=$((page + 1))
    args=()
    [ -n "$cursor" ] && args+=(--cursor "$cursor")
    if ! list=$(orca_orchestration_worker_list ${args[@]+"${args[@]}"} 2>"$WORK/worker-list.err"); then
      printf 'unverifiable\x1forca\x1forca worker-list 失败：%s\x1f' "$(head -n 1 "$WORK/worker-list.err" 2>/dev/null)"
      return 0
    fi
    if ! rows=$(printf '%s' "$list" | workers_in_page "$worktree"); then
      printf 'unverifiable\x1forca\x1forca worker-list 的输出无法解析\x1f'
      return 0
    fi
    while IFS= read -r line; do
      case "$line" in
        cursor$'\t'*) next=${line#cursor$'\t'} ;;
        *) dispatches+=("$line") ;;
      esac
    done <<<"$rows"
    [ -n "$next" ] || break
    if [ "$page" -ge "$WORKER_PAGES" ]; then
      truncated="只查了前 ${page} 页"
      break
    fi
    cursor=$next
  done
  if [ "${#dispatches[@]}" -eq 0 ]; then
    [ -z "$truncated" ] || key=orca
    printf 'unverifiable\x1f%s\x1fworker-list 里没有 workspace 为 %s 的 worker%s\x1f' \
      "$key" "$worktree" "${truncated:+（${truncated}）}"
    return 0
  fi
  for dispatch in ${dispatches[@]+"${dispatches[@]}"}; do
    if ! fields=$(orca_orchestration_worker_show "$dispatch" 2>"$WORK/worker-show.err" |
        worker_show_fields); then
      unsure=1
      [ "$key" = none ] && key=$dispatch
      evidence="${evidence}liveness=unknown dispatch=${dispatch}（worker-show 失败：$(head -n 1 "$WORK/worker-show.err" 2>/dev/null)）; "
      continue
    fi
    IFS=$'\x1f' read -r liveness terminal state <<<"$fields"
    evidence="${evidence}liveness=${liveness:-unknown} dispatch=$dispatch; "
    case "$liveness" in
      live)
        printf 'live\x1f%s\x1f%s\x1f' "$dispatch" "${evidence%; }"
        return 0
        ;;
      exited)
        [ "$state" = released ] || [ -z "$terminal" ] || handles="$handles$terminal "
        ;;
      *)
        unsure=1
        [ "$key" = none ] && key=$dispatch
        ;;
    esac
  done
  if [ "$unsure" -eq 1 ] || [ -n "$truncated" ]; then
    # "Every worker exited" is a claim about the whole worktree; a list cut
    # short before its end cannot support it.
    evidence="${evidence%; }"
    [ -z "$truncated" ] || evidence="$evidence; $truncated"
    [ "$key" != none ] || key=${dispatches[0]}
    printf 'unverifiable\x1f%s\x1f%s\x1f' "$key" "$evidence"
  else
    printf 'exited\x1f%s\x1f%s\x1f%s' "${dispatches[0]}" "${evidence%; }" "$handles"
  fi
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

# The third conclusion of stall_check: Orca cannot vouch for the session. The
# human is told once per Spec and evidence — the key is what the evidence was
# (the dispatch, or none, or orca), so a session dispatched again by hand is
# reported again when its new worker cannot be vouched for either — and told
# what the evidence was. Nothing is retried: Orca forbids a stop, a retry or a
# release on anything but an exited worker.
notify_unverifiable_once() { # spec key evidence age
  local spec=$1 key="unverifiable:$REPO#$1:$2" evidence=$3 age=$4
  if [ "$(state_op seen "$key")" = 1 ]; then
    log_line "$REPO" "#$spec" SKIP "无法确认会话状态，已通知过（${evidence}），不自动恢复"
    return 0
  fi
  log_line "$REPO" "#$spec" UNVERIFIABLE "卡住 ${age}s 无写入，Orca 无法确认会话状态（${evidence}），不自动恢复"
  if notify "$REPO" "#$spec" "$REPO #$spec 无法确认会话是否已退出，未自动恢复（卡住 ${age}s 无写入）：$evidence"; then
    [ "$DRY" -eq 0 ] && state_op notify "$key" "$(date +%s)"
  fi
}

# The two conclusions of interrupted_check that leave the Spec alone, told once
# by the same mechanism: per Spec for a live session (which dispatch it is does
# not change what there is to look at), per Spec and evidence for one Orca
# cannot vouch for (the key, as in notify_unverifiable_once). The conclusion
# is logged the first time, SKIP after.
notify_interrupted_once() { # spec live|unverifiable [evidence key] message
  local spec=$1 word=$2 key="interrupted-$2:$REPO#$1${3:+:$3}" message=$4
  if [ "$(state_op seen "$key")" = 1 ]; then
    log_line "$REPO" "#$spec" SKIP "claim interrupted，${message}，已通知过，不自动恢复"
    return 0
  fi
  case "$word" in live) word=LIVE ;; *) word=UNVERIFIABLE ;; esac
  log_line "$REPO" "#$spec" "$word" "claim interrupted，${message}，不自动恢复"
  if notify "$REPO" "#$spec" "$REPO #$spec 认领已断（claim interrupted）：${message}，未自动恢复"; then
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
    return 0
  fi

  # Silent for KEEPER_STALL_MIN (the second evidence). What that means is
  # Orca's to say (the first evidence): nothing below runs on a guess.
  local verdict key evidence handles
  IFS=$'\x1f' read -r verdict key evidence handles <<<"$(worker_liveness "$worktree")"
  case "$verdict" in
    live)
      log_line "$REPO" "#$spec" LIVE "卡住 ${age}s 无写入，但 Orca 报告会话仍在运行（${evidence}），不动"
      return 0
      ;;
    exited) ;;
    *)
      notify_unverifiable_once "$spec" "${key:-none}" "${evidence:-判活没有结论}" "$age"
      return 0
      ;;
  esac
  log_line "$REPO" "#$spec" EXITED "卡住 ${age}s 无写入，Orca 报告会话已退出（${evidence}）"
  if ! can_resume "$spec"; then
    return 0
  fi
  local handle
  if [ "$DRY" -eq 1 ]; then
    for handle in $handles; do log_line "$REPO" "#$spec" WOULD_CLOSE_TERMINAL "$handle"; done
    log_line "$REPO" "#$spec" WOULD_RELEASE_CLAIM "claim.sh release $spec --force"
    log_line "$REPO" "#$spec" WOULD_RESUME "Orca 报告会话已退出（${evidence}）"
    return 0
  fi
  # A terminal Orca has not released is closed here; one it released is gone.
  for handle in $handles; do
    if orca_terminal_close "$handle" >/dev/null 2>&1; then
      log_line "$REPO" "#$spec" CLOSE_TERMINAL "$handle"
    else
      log_line "$REPO" "#$spec" ERROR "orca terminal close 失败：$handle"
    fi
  done
  if ( cd "$REPO_PATH" && "$CLAIM" release "$spec" --force ) >/dev/null 2>&1; then
    log_line "$REPO" "#$spec" RELEASE_CLAIM "claim.sh release $spec --force"
  else
    log_line "$REPO" "#$spec" ERROR "claim.sh release $spec --force 失败"
  fi
  do_resume "$spec" "Orca 报告会话已退出（${evidence}）"
}

# An interrupted claim (the claiming pid is gone, no new report) is asked of
# Orca before anything is resumed, by the liveness rule of stall_check: the
# session may well be alive in the worktree (a Spec parked with its reservation
# kept is found interrupted once the reservation lapses while its session still
# works), and launch-wave would resume into that same worktree. What Orca says
# decides:
#   live          left alone; a human is told once per Spec
#   exited        a confirmed death: the terminals Orca still lists are closed
#                 and the Spec is resumed (the claim record stays: launch-wave
#                 resumes through it)
#   no worker     nothing is alive in the worktree; resumed the same way
#   unverifiable  left alone; a human is told once per Spec and evidence
interrupted_check() { # spec worktree
  local spec=$1 worktree=$2 verdict key evidence handles
  if [ -z "$worktree" ]; then
    # No worktree, so no session to be live in one: nothing to ask Orca.
    do_resume "$spec" "会话已死（claim interrupted，找不到 spec-$spec 的 worktree），没有新的报告"
    return 0
  fi
  IFS=$'\x1f' read -r verdict key evidence handles <<<"$(worker_liveness "$worktree")"
  case "$verdict:$key" in
    live:*)
      notify_interrupted_once "$spec" live '' "Orca 报告会话仍在运行（${evidence}）"
      return 0
      ;;
    exited:*|unverifiable:none) ;;
    *)
      notify_interrupted_once "$spec" unverifiable "$key" "Orca 无法确认会话是否已退出（${evidence:-判活没有结论}）"
      return 0
      ;;
  esac
  log_line "$REPO" "#$spec" EXITED "claim interrupted，会话已死（${evidence}）"
  if ! can_resume "$spec"; then
    return 0
  fi
  local handle
  if [ "$DRY" -eq 1 ]; then
    for handle in $handles; do log_line "$REPO" "#$spec" WOULD_CLOSE_TERMINAL "$handle"; done
    log_line "$REPO" "#$spec" WOULD_RESUME "会话已死（claim interrupted，${evidence}），没有新的报告"
    return 0
  fi
  # A terminal Orca has not released is closed here; one it released is gone.
  for handle in $handles; do
    if orca_terminal_close "$handle" >/dev/null 2>&1; then
      log_line "$REPO" "#$spec" CLOSE_TERMINAL "$handle"
    else
      log_line "$REPO" "#$spec" ERROR "orca terminal close 失败：$handle"
    fi
  done
  do_resume "$spec" "会话已死（claim interrupted，${evidence}），没有新的报告"
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
    interrupted_check "$spec" "$worktree"
  fi
}

process_repo() { # repo path flash
  REPO=$1
  REPO_PATH=$2
  REPO_NAME=${1#*/}
  FLASH=$3
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
  local repo auto_land flash path started
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
  orca_repo_list >"$WORK/orca-repos.json" 2>/dev/null </dev/null || : >"$WORK/orca-repos.json"
  ORCA_REPOS_FILE=$WORK/orca-repos.json
  : >"$WORK/actions"

  list_repos >"$WORK/repos.txt"
  while IFS=$'\x1f' read -r repo auto_land flash; do
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
    process_repo "$repo" "$path" "$flash"
  done <"$WORK/repos.txt"
  sweep_round
  log_line - - ROUND "end actions=$(wc -l <"$WORK/actions" 2>/dev/null | tr -d ' ') seconds=$(( $(date +%s) - started ))"
}

# The sweep of abandoned worktrees (规格 #26, US17): once a round, after the
# repositories, in keeper's own mode (--dry-run passes --dry-run on, --repo is
# passed on). Every line sweep-worktrees.sh prints is logged except the kept
# worktrees, which only count in its summary: a removal (or, in --dry-run, what
# would go) is an action, a failure an error. The sweep reads the same claim.sh,
# Launch state directory and run directories keeper does. A sweep that fails is
# reported and never fatal: the round's own work is done by then.
sweep_round() {
  local out=$WORK/sweep.out err=$WORK/sweep.err status=0
  local s_repo s_action s_path s_reason
  local args=()
  if [ ! -f "$SWEEP" ]; then
    log_line - - SKIP "sweep-worktrees.sh not found: $SWEEP"
    return 0
  fi
  [ "$DRY" -eq 1 ] && args+=(--dry-run)
  [ -n "$ONLY_REPO" ] && args+=(--repo "$ONLY_REPO")
  SWEEP_CLAIM="$CLAIM" SWEEP_LAUNCH_STATE_DIR="$LAUNCH_STATE_DIR" SWEEP_RUNS_DIR="$RUNS_ROOT" \
    "$SWEEP" ${args[@]+"${args[@]}"} >"$out" 2>"$err" || status=$?
  # The sweep's lines are tab-separated; read folds runs of tabs, so the four
  # fields are re-joined with the unit separator first.
  while IFS=$'\x1f' read -r s_repo s_action s_path s_reason; do
    case "$s_action" in
      summary) log_line "${s_repo:--}" - SWEEP "${s_reason:-}" ;;
      would-remove) log_line "${s_repo:--}" - WOULD_REMOVE_WORKTREE "${s_path}: ${s_reason}" ;;
      removed) log_line "${s_repo:--}" - REMOVE_WORKTREE "${s_path}: ${s_reason}" ;;
      failed) log_line "${s_repo:--}" - ERROR "sweep: ${s_path}: ${s_reason}" ;;
      skip) log_line "${s_repo:--}" - SKIP "sweep: ${s_reason}" ;;
    esac
  done < <(awk -F'\t' '{ print $1 "\x1f" $2 "\x1f" $3 "\x1f" $4 }' "$out" 2>/dev/null)
  if [ "$status" -ne 0 ]; then
    log_line - - ERROR "sweep-worktrees.sh 退出码 ${status}：$(head -n 1 "$err" 2>/dev/null)"
  fi
  return 0
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
