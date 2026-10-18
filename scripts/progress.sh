#!/usr/bin/env bash
# Read-only progress for a codex-worker run directory.
#
# Usage: progress.sh <run dir> [N=10]
#
# state: finished is authoritative whenever status.json is at least as new as pid.
# Otherwise running requires a live wrapper pid from the same process instance (the pid
# file records its Windows start ticks); a merely recycled pid reports dead.
# Reads pid, status.json, watch.json, events.jsonl, and the latest/current attempt file.

set -u
RUN_DIR="${1:-}"
N="${2:-10}"
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  echo "usage: progress.sh <run dir> [N=10]" >&2
  exit 64
fi

exec node - "$RUN_DIR" "$N" <<'NODE'
const fs = require("fs");
const path = require("path");
const {spawnSync} = require("child_process");
const run = process.argv[2], count = Math.max(1, +process.argv[3] || 10);
const read = p => { try { return fs.readFileSync(p, "utf8"); } catch { return ""; } };
const json = p => { try { return JSON.parse(read(p)); } catch { return null; } };
const statusPath = path.join(run, "status.json");
const status = json(statusPath);
const newer = (a, b) => fs.statSync(a).mtimeMs >= fs.statSync(b).mtimeMs;
const pidFile = path.join(run, "pid");
const pidParts = read(pidFile).trim().split(/\s+/).filter(Boolean);
const pid = +pidParts[0] || 0;
const recordedTicks = pidParts[1] || "";
const pidAlive = pid > 0 && (() => { try { process.kill(pid, 0); return true; } catch { return false; } })();
let state = "dead";
if (status && pidParts.length && fs.existsSync(pidFile) && newer(statusPath, pidFile)) {
  state = `finished: ${status.status} (exit-equivalent)`;
} else if (pidAlive) {
  if (!recordedTicks) state = "running";
  else {
    const query = spawnSync("powershell.exe", ["-NoProfile", "-Command",
      `(Get-Process -Id ${pid}).StartTime.ToUniversalTime().Ticks`], {encoding: "utf8"});
    state = String(query.stdout || "").trim() === recordedTicks ? "running" : "dead";
  }
}
console.log("state: " + state);

const watch = json(path.join(run, "watch.json"));
let current = watch ? watch.attempt_file : "";
if (!current || !fs.existsSync(current)) {
  let best = 0;
  try { for (const f of fs.readdirSync(run)) { const m = f.match(/^attempt-(\d+)\.jsonl$/); if (m) best = Math.max(best, +m[1]); } } catch {}
  current = best ? path.join(run, `attempt-${best}.jsonl`) : "";
}
const events = read(path.join(run, "events.jsonl"));
const attempt = read(current);
const parse = text => text.split("\n").filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const attemptAppended = attempt && events.endsWith(attempt);
const allEvents = [...parse(events), ...(attemptAppended ? [] : parse(attempt))];
const currentEvents = parse(attempt);
const cwd = status?.cwd || json(path.join(run, "resume.json"))?.cwd || "";
const unquote = s => {
  const q = s[0];
  if ((q === "'" || q === '"') && s.endsWith(q) && s.length > 1) return s.slice(1, -1);
  return s;
};
const displayCommand = raw => {
  let s = String(raw || "").trim();
  const wrapper = s.match(/^"(.*?(?:pwsh|powershell|cmd|bash)\.exe)"\s+(.*)$/i);
  if (wrapper) s = wrapper[2].trim();
  else if (/^(?:.*(?:pwsh|powershell|cmd|bash)\.exe)\s+/i.test(s)) s = s.replace(/^(?:.*(?:pwsh|powershell|cmd|bash)\.exe)\s+/i, "");
  for (;;) {
    const m = s.match(/^(?:-NoProfile\s+|-NonInteractive\s+|-ExecutionPolicy\s+\S+\s+|-Command\s+|-lc\s+|-c\s+)/i);
    if (!m) break;
    s = unquote(s.slice(m[0].length).trim());
  }
  return unquote(s);
};

const displayPath = file => {
  const p = String(file || "");
  if (!cwd) return p;
  const rel = path.relative(cwd, p);
  return rel && !rel.startsWith("..") && !path.isAbsolute(rel) ? rel : p;
};

if (watch) {
  const now = Math.floor(Date.now() / 1000);
  console.log(`segment: ${watch.segment}  attempt: ${watch.attempt}`);
  console.log(`elapsed: ${Math.max(0, now - watch.started_at)}s  last progress: ${Math.max(0, now - watch.last_progress_at)}s ago`);
}

if (state === "running") {
  const open = new Map(), closed = new Set();
  for (const e of currentEvents) {
    if (e.type === "item.started" && e.item?.id) open.set(e.item.id, e.item);
    if (e.type === "item.completed" && e.item?.id) closed.add(e.item.id);
  }
  const running = [...open.values()].filter(i => !closed.has(i.id) && i.type === "command_execution").pop();
  if (running) console.log(`command: ${displayCommand(running.command)} (since last progress)`);
}

let actions = [];
for (const e of allEvents) {
  if (e.type === "item.completed" && e.item?.type === "command_execution") actions.push(`$ ${displayCommand(e.item.command)}  -> exit ${e.item.exit_code}`);
  else if (e.type === "item.completed" && e.item?.type === "file_change") actions.push(`edit ${(e.item.changes || []).map(c => displayPath(c.path)).join(", ")}`);
  else if (e.type === "item.completed" && e.item?.type === "agent_message") actions.push(`say: ${e.item.text}`);
}
for (const action of actions.slice(-count)) console.log(action.slice(0, 100));

let input = 0, output = 0;
for (const e of allEvents) if (e.type === "turn.completed" && e.usage) {
  input += +e.usage.input_tokens || 0; output += +e.usage.output_tokens || 0;
}
console.log(`tokens: input ${input}, output ${output}`);
if (status && state.startsWith("finished")) {
  console.log(`status: ${status.status}`);
  console.log(`error: ${(status.error || "").slice(0, 100)}`);
}
NODE
