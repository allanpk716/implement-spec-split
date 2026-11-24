#!/usr/bin/env bash
# Run state for find-next advance mode.
#
# One advance run writes <run-dir>/run-state.json right after its directory is
# created. `pending` lists the runs of one repository that were never finished:
# new-style runs whose owner process is dead, and legacy run directories that
# predate the state file. `abandon` marks a run as handled without deleting it.

set -u

HERE=$(cd -P -- "$(dirname "$0")" && pwd) || exit 1
SKILL_ROOT=$(cd -P -- "$HERE/../.." && pwd) || exit 1
# shellcheck source=../../scripts/lib-owner.sh
source "$SKILL_ROOT/scripts/lib-owner.sh"

DEFAULT_RUNS_ROOT=${ISS_RUNS_ROOT:-$HOME/.cache/codex-runs}
LEGACY_MAX_AGE=$((7 * 24 * 60 * 60))

usage() {
  cat <<'EOF'
usage:
  run-state.sh init <run-dir> --repo <owner/name> --repo-path <repo-root>
  run-state.sh step <run-dir> <step>
  run-state.sh finish <run-dir> [--aborted <reason>]
  run-state.sh pending --repo <owner/name> --repo-path <repo-root> [--runs-root DIR] [--json]
  run-state.sh abandon <run-dir> [--repo <owner/name>] [--repo-path <repo-root>]

init writes <run-dir>/run-state.json:
  {version:1, repo, repo_path, owner_pid, owner_pid_start, started_at, step,
   finished_at:null}
The owner pid is resolved with lib-owner.sh (ISS_OWNER_PID overrides it in tests).

step records the advance step the main session is entering (2..11).

finish sets finished_at; --aborted <reason> also records why the run stopped.

pending prints the repository's unfinished runs. A new-style run is listed only
when its owner process is dead (pid + start time); a live owner belongs to a
running session and is protected by the repository lock instead. A legacy run
(no run-state.json) is listed when its directory name contains "find-next", its
directory mtime is within 7 days, and one of its brief.md / note-*.md /
scan-*.txt files (or the directory name) mentions the repository path, owner/name
or repository directory name, unless its only outputs are fully published Spec
groups. Directories that look like a worker run (root
events.jsonl, pid or watch.json) are not advance runs and are skipped.

abandon marks a run as handled: a new-style run gets finished_at and
abandoned:"abandoned-by-later-run"; a legacy run gets a minimal run-state.json.
Nothing is deleted.

pending --json prints:
  {version:1, repo, repo_path, runs_root, generated_at, runs:[
    {path, legacy, started_at, step, finished_at,
     outputs:[{kind, ticket, group, attempts, has_result, result_mtime,
               produced_at, brief, note, artifacts, published, produced}],
     scans:[{name, mtime}]}]}
kind is research|decision|fog|task|prototype|loose|spec. Ticket-level outputs
merge retries of the same ticket (loose-373 and loose-373-retry are one #373).
published is null except for spec groups, where it reports whether
published.json exists, whether it is complete, and what is missing.
EOF
}

die() {
  printf 'run-state: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'run-state: %s\n' "$*" >&2
  usage >&2
  exit 64
}

valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

now_iso() {
  NOW_EPOCH="$(owner_epoch_now)" node -e '
    process.stdout.write(new Date(Number(process.env.NOW_EPOCH) * 1000).toISOString());
  '
}

dir_mtime() {
  local value
  value=$(stat -f %m "$1" 2>/dev/null) || value=$(stat -c %Y "$1" 2>/dev/null) || value=0
  printf '%s' "$value"
}

write_state() {
  local file=$1
  STATE_FILE="$file" STATE_JSON="$2" node -e '
    const fs = require("fs"), path = require("path");
    const file = process.env.STATE_FILE;
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${process.env.STATE_JSON}\n`);
    fs.renameSync(temporary, file);
  '
}

read_state_field() {
  local file=$1 field=$2
  STATE_FILE="$file" STATE_FIELD="$field" node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      const field = process.env.STATE_FIELD;
      const result = value[field];
      process.stdout.write(result === undefined || result === null ? "" : String(result));
    } catch {
      process.stdout.write("");
    }
  '
}

state_fields() {
  local file=$1
  STATE_FILE="$file" node -e '
    const fs = require("fs");
    const clean = (value) => String(value ?? "").replace(/[\t\n\r]+/g, " ");
    try {
      const value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      process.stdout.write([
        clean(value.repo), clean(value.finished_at), clean(value.owner_pid),
        clean(value.owner_pid_start), clean(value.started_at), clean(value.step),
      ].join("\x1f"));
    } catch {
      process.stdout.write("");
    }
  '
}

cmd_init() {
  local run_dir=${1:-} repo=${2:-} repo_path=${3:-}
  [ -n "$run_dir" ] || die_usage "init needs a run directory"
  [ -n "$repo" ] || die_usage "init needs --repo <owner/name>"
  [ -n "$repo_path" ] || die_usage "init needs --repo-path <repo-root>"
  valid_repo "$repo" || die_usage "--repo must look like owner/name"
  [ -d "$run_dir" ] || die "run directory does not exist: $run_dir"
  repo_path=$(cd -P -- "$repo_path" 2>/dev/null && pwd) || die "--repo-path is not a directory: $3"

  local pid pid_start
  pid=$(owner_resolve_pid) || die "could not resolve the owner pid"
  pid_start=$(owner_start_for "$pid")
  [ -n "$pid_start" ] || die "could not determine process start for pid $pid"

  local started
  started=$(now_iso)
  RUN_DIR="$run_dir" REPO="$repo" REPO_PATH="$repo_path" OWNER_PID="$pid" \
    PID_START="$pid_start" STARTED_AT="$started" node -e '
    const fs = require("fs"), path = require("path");
    const e = process.env;
    const value = {
      version: 1,
      repo: e.REPO,
      repo_path: e.REPO_PATH,
      owner_pid: Number(e.OWNER_PID),
      owner_pid_start: e.PID_START,
      started_at: e.STARTED_AT,
      step: "1",
      finished_at: null,
    };
    process.stdout.write(JSON.stringify(value, null, 2));
  ' > "$run_dir/.run-state.json.$$" || die "could not build the run state"
  write_state "$run_dir/run-state.json" "$(cat "$run_dir/.run-state.json.$$")"
  rm -f "$run_dir/.run-state.json.$$"
}

cmd_step() {
  local run_dir=${1:-} step=${2:-}
  [ -n "$run_dir" ] || die_usage "step needs a run directory"
  [ -n "$step" ] || die_usage "step needs a step number or name"
  local file="$run_dir/run-state.json"
  [ -f "$file" ] || die "no run-state.json in $run_dir (run init first)"
  local json
  json=$(STATE_FILE="$file" STEP="$step" node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch { process.exit(1); }
    value.step = process.env.STEP;
    process.stdout.write(JSON.stringify(value, null, 2));
  ') || die "could not update the run state in $file"
  write_state "$file" "$json"
}

cmd_finish() {
  local run_dir=${1:-} reason=${2:-}
  [ -n "$run_dir" ] || die_usage "finish needs a run directory"
  local file="$run_dir/run-state.json"
  [ -f "$file" ] || die "no run-state.json in $run_dir (run init first)"
  local now json
  now=$(now_iso)
  json=$(STATE_FILE="$file" NOW="$now" ABORTED="$reason" node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch { process.exit(1); }
    value.finished_at = process.env.NOW;
    if (process.env.ABORTED) value.aborted = process.env.ABORTED;
    process.stdout.write(JSON.stringify(value, null, 2));
  ') || die "could not finish the run state in $file"
  write_state "$file" "$json"
}

legacy_matches_repo() {
  local run_dir=$1 base=$2 ident file
  local repo_name=${REPO_PATH##*/}
  for ident in "$REPO" "$REPO_PATH" "$repo_name"; do
    [ -n "$ident" ] || continue
    case "$base" in
      *"$ident"*) return 0 ;;
    esac
    while IFS= read -r -d '' file; do
      if grep -qF -- "$ident" "$file" 2>/dev/null; then
        return 0
      fi
    done < <(find "$run_dir" -maxdepth 2 -type f \
      \( -name 'brief.md' -o -name 'note-*.md' -o -name 'scan-*.txt' \) -print0 2>/dev/null)
  done
  return 1
}

cmd_pending() {
  local repo=${1:-} repo_path=${2:-} runs_root=${3:-$DEFAULT_RUNS_ROOT} json=${4:-0}
  [ -n "$repo" ] || die_usage "pending needs --repo <owner/name>"
  [ -n "$repo_path" ] || die_usage "pending needs --repo-path <repo-root>"
  valid_repo "$repo" || die_usage "--repo must look like owner/name"
  repo_path=$(cd -P -- "$repo_path" 2>/dev/null && pwd) || die "--repo-path is not a directory: $2"
  REPO=$repo
  REPO_PATH=$repo_path

  local now_epoch candidates=() dir base state fields
  local s_repo s_finished s_pid s_pid_start s_started s_step
  now_epoch=$(owner_epoch_now)
  if [ -d "$runs_root" ]; then
    for dir in "$runs_root"/*/; do
      [ -d "$dir" ] || continue
      dir=${dir%/}
      base=$(basename "$dir")
      state="$dir/run-state.json"
      if [ -f "$state" ]; then
        fields=$(state_fields "$state")
        [ -n "$fields" ] || {
          printf 'run-state: warning: unreadable state file %s\n' "$state" >&2
          continue
        }
        # \x1f, not a tab: read collapses runs of whitespace separators, which
        # would shift fields left whenever finished_at is empty.
        IFS=$'\x1f' read -r s_repo s_finished s_pid s_pid_start s_started s_step <<< "$fields"
        [ "$s_repo" = "$repo" ] || continue
        [ -z "$s_finished" ] || continue
        if [ -n "$s_pid" ] && owner_alive "$s_pid" "$s_pid_start"; then
          continue
        fi
        candidates+=("$dir")
        continue
      fi

      case "$base" in
        *find-next*) ;;
        *) continue ;;
      esac
      if [ -e "$dir/events.jsonl" ] || [ -e "$dir/pid" ] || [ -e "$dir/watch.json" ]; then
        continue
      fi
      local age=$((now_epoch - $(dir_mtime "$dir")))
      [ "$age" -le "$LEGACY_MAX_AGE" ] || continue
      legacy_matches_repo "$dir" "$base" || continue
      candidates+=("$dir")
    done
  fi

  local dirs_text=""
  for dir in ${candidates[@]+"${candidates[@]}"}; do
    dirs_text+="$dir"$'\n'
  done
  RUN_STATE_REPO="$repo" RUN_STATE_REPO_PATH="$repo_path" \
    RUN_STATE_RUNS_ROOT="$runs_root" RUN_STATE_JSON="$json" \
    RUN_STATE_DIRS="$dirs_text" node - <<'NODE'
const fs = require('fs');
const path = require('path');

const repo = process.env.RUN_STATE_REPO;
const repoPath = process.env.RUN_STATE_REPO_PATH;
const runsRoot = process.env.RUN_STATE_RUNS_ROOT;
const jsonOutput = process.env.RUN_STATE_JSON === '1';
const runDirs = (process.env.RUN_STATE_DIRS || '').split('\n').filter(Boolean);
const KIND_ORDER = {research: 1, decision: 2, fog: 3, task: 4, prototype: 5, loose: 6, spec: 7};
const ARTIFACTS = [
  'triage.md', 'decision.md', 'fog.md', 'spec.md', 'manifest.json',
  'published.json', 'resolution.md', 'result.md', 'brief.md',
];

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function mtime(file) {
  try { return fs.statSync(file).mtimeMs; } catch { return null; }
}

function iso(value) {
  return value === null || value === undefined ? null : new Date(value).toISOString();
}

function localTime(value) {
  if (!value) return '未知';
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return '未知';
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    ` ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function ensureGroup(groups, key, kind, ticket, group) {
  if (!groups.has(key)) {
    groups.set(key, {kind, ticket, group, attempts: []});
  }
  return groups.get(key);
}

function scanAttempt(runDir, name, note) {
  const attempt = {
    name, brief: false, result: false, note: Boolean(note), artifacts: {},
  };
  for (const artifact of ARTIFACTS) {
    const file = path.join(runDir, name, artifact);
    const value = mtime(file);
    if (value !== null) {
      attempt.artifacts[artifact] = iso(value);
      if (artifact === 'brief.md') attempt.brief = true;
      if (artifact === 'result.md') attempt.result = true;
    }
  }
  if (note) {
    const value = mtime(path.join(runDir, name));
    if (value !== null) attempt.artifacts.note = iso(value);
  }
  return attempt;
}

function publishedInfo(runDir, group) {
  const specDir = path.join(runDir, group);
  const publishedFile = path.join(specDir, 'published.json');
  const manifestFile = path.join(specDir, 'manifest.json');
  if (!fs.existsSync(publishedFile)) {
    return {exists: false, complete: false, missing: []};
  }
  let published;
  try {
    published = JSON.parse(fs.readFileSync(publishedFile, 'utf8'));
  } catch {
    return {exists: true, complete: false, missing: ['published.json 无法解析']};
  }
  const manifest = readJson(manifestFile);
  const missing = [];
  if (!manifest) missing.push('manifest.json');

  const expectedKeys = [];
  if (manifest && typeof manifest.key === 'string') expectedKeys.push(manifest.key);
  const tickets = manifest && Array.isArray(manifest.tickets) ? manifest.tickets : [];
  for (const ticket of tickets) {
    if (ticket && ticket.key) expectedKeys.push(ticket.key);
  }
  const issues = published && published.issues && typeof published.issues === 'object'
    ? published.issues : {};
  for (const key of expectedKeys) {
    const issue = issues[key];
    if (!issue || !(Number(issue.number) > 0)) missing.push(key);
    else if (issue.patchPending) missing.push(`${key}（待回填）`);
  }

  const relations = Array.isArray(published && published.relations)
    ? published.relations.map(String) : [];
  for (const ticket of tickets) {
    const relation = `sub:${manifest.key}/${ticket.key}`;
    if (!relations.includes(relation)) missing.push(relation);
  }
  const expectedDependencies = tickets.reduce(
    (total, ticket) => total + (Array.isArray(ticket.blocked_by) ? ticket.blocked_by.length : 0), 0);
  const actualDependencies = relations.filter((value) => value.startsWith('dependency:')).length;
  if (actualDependencies < expectedDependencies) {
    missing.push(`依赖关系 ${actualDependencies}/${expectedDependencies}`);
  }
  const handoffs = manifest && Array.isArray(manifest.handoffs) ? manifest.handoffs : [];
  const recordedHandoffs = Array.isArray(published && published.handoffs)
    ? published.handoffs.map(String) : [];
  handoffs.forEach((handoff, index) => {
    const relation = `handoff:${handoff && handoff.index !== undefined ? handoff.index : index}:${handoff.issue}`;
    if (!recordedHandoffs.includes(relation)) missing.push(relation);
  });

  return {
    exists: true,
    complete: missing.length === 0,
    missing,
  };
}

function scanRun(runDir) {
  const state = readJson(path.join(runDir, 'run-state.json'));
  const legacy = state === null;
  const groups = new Map();
  const scans = [];
  let entries = [];
  try { entries = fs.readdirSync(runDir, {withFileTypes: true}); } catch { entries = []; }

  for (const entry of entries) {
    if (entry.isFile()) {
      if (/^scan-.*\.txt$/.test(entry.name)) {
        scans.push({name: entry.name, mtime: iso(mtime(path.join(runDir, entry.name)))});
      }
      const note = /^note-S(\d+)\.md$/.exec(entry.name);
      if (note) {
        const group = ensureGroup(groups, `spec:S${note[1]}`, 'spec', null, `S${note[1]}`);
        group.attempts.push(scanAttempt(runDir, entry.name, true));
      }
      continue;
    }
    if (!entry.isDirectory()) continue;
    const match = /^(research|decision|fog|task|prototype|loose)-(\d+)(?:-.*)?$/.exec(entry.name);
    if (match) {
      const group = ensureGroup(groups, `${match[1]}:${match[2]}`, match[1], Number(match[2]), null);
      group.attempts.push(scanAttempt(runDir, entry.name, false));
      continue;
    }
    const spec = /^S(\d+)$/.exec(entry.name);
    if (spec) {
      const group = ensureGroup(groups, `spec:S${spec[1]}`, 'spec', null, `S${spec[1]}`);
      group.attempts.push(scanAttempt(runDir, entry.name, false));
    }
  }

  const outputs = [...groups.values()].map((group) => {
    const attempts = group.attempts;
    const artifacts = {};
    for (const artifact of [...ARTIFACTS, 'note']) {
      const times = attempts
        .map((attempt) => attempt.artifacts[artifact])
        .filter(Boolean)
        .sort();
      artifacts[artifact] = times.length > 0 ? times[times.length - 1] : null;
    }
    const resultTimes = attempts
      .map((attempt) => attempt.artifacts['result.md'])
      .filter(Boolean)
      .sort();
    const producedTimes = Object.entries(artifacts)
      .filter(([name]) => name !== 'brief.md' && name !== 'note')
      .map(([, value]) => value)
      .filter(Boolean)
      .sort();
    return {
      kind: group.kind,
      ticket: group.ticket,
      group: group.group,
      attempts: attempts.map((attempt) => attempt.name),
      has_result: resultTimes.length > 0,
      result_mtime: resultTimes.length > 0 ? resultTimes[resultTimes.length - 1] : null,
      produced_at: producedTimes.length > 0 ? producedTimes[producedTimes.length - 1] : null,
      brief: attempts.some((attempt) => attempt.brief),
      note: attempts.some((attempt) => attempt.note),
      artifacts,
      published: group.kind === 'spec' ? publishedInfo(runDir, group.group) : null,
      produced: resultTimes.length > 0,
    };
  });
  outputs.sort((left, right) => {
    const order = (KIND_ORDER[left.kind] || 99) - (KIND_ORDER[right.kind] || 99);
    if (order !== 0) return order;
    if (left.ticket !== null && right.ticket !== null && left.ticket !== right.ticket) {
      return left.ticket - right.ticket;
    }
    return String(left.group || '').localeCompare(String(right.group || ''), 'en', {numeric: true});
  });
  scans.sort((left, right) => left.name.localeCompare(right.name, 'en', {numeric: true}));

  const startedAt = state && state.started_at
    ? state.started_at
    : iso(mtime(runDir));
  return {
    path: runDir,
    legacy,
    started_at: startedAt,
    step: state && state.step !== undefined && state.step !== null ? String(state.step) : '未知',
    finished_at: state && state.finished_at ? state.finished_at : null,
    outputs,
    scans,
  };
}

function artifactNames(artifacts) {
  return Object.entries(artifacts)
    .filter(([name, value]) => value && name !== 'brief.md' && name !== 'note')
    .map(([name]) => name);
}

function renderOutput(output) {
  const parts = [];
  if (output.kind === 'spec') {
    const published = output.published || {exists: false, complete: false, missing: []};
    if (!published.exists) {
      parts.push('未发布');
    } else if (published.complete) {
      parts.push('已发布');
    } else {
      parts.push(`发布到一半（缺 ${published.missing.join('、')}）`);
    }
    const names = artifactNames(output.artifacts);
    if (names.length > 0) parts.push(names.join('、'));
    if (!output.produced && !output.artifacts['spec.md']) {
      parts.push(output.note ? '未产出（只有 note）' : '未产出（只有 brief.md）');
    }
  } else if (output.produced) {
    parts.push(`result.md（${localTime(output.result_mtime)}）`);
    const names = artifactNames(output.artifacts).filter((name) => name !== 'result.md');
    if (names.length > 0) parts.push(names.join('、'));
  } else {
    parts.push(output.brief ? '未产出（只有 brief.md）' : '未产出');
  }
  if (output.attempts.length > 1 ||
      output.attempts.some((name) => name !== `${output.kind}-${output.ticket}`)) {
    parts.push(`尝试 ${output.attempts.join('、')}`);
  }
  return `${output.kind === 'spec' ? output.group : `${output.kind} #${output.ticket}`}：${parts.join(' · ')}`;
}

function renderText(data) {
  const lines = [];
  lines.push(`未收尾的推进运行 · ${data.repo}（${data.runs.length}）`);
  if (data.runs.length === 0) {
    lines.push('（无）');
    return `${lines.join('\n')}\n`;
  }
  data.runs.forEach((run, index) => {
    lines.push('');
    lines.push(`${index + 1}. ${run.path}`);
    lines.push(`   ${run.legacy ? '旧版运行（无状态文件）' : '新版运行'} · ` +
      `开始 ${localTime(run.started_at)} · 最后步骤 ${run.step}`);
    if (run.outputs.length === 0 && run.scans.length === 0) {
      lines.push('   - 无产出');
    }
    for (const output of run.outputs) {
      lines.push(`   - ${renderOutput(output)}`);
    }
    if (run.scans.length > 0) {
      lines.push(`   - 扫描：${run.scans.map((scan) => scan.name).join('、')}`);
    }
  });
  lines.push('');
  lines.push('处理：result.md 仍有效的票级产出可复用；S<k> 的 published.json 不完整就在旧目录重跑 publish-batch；处理后 run-state.sh abandon <目录>。');
  return `${lines.join('\n')}\n`;
}

// A legacy run whose only outputs are fully published Spec groups has nothing
// left to resume; without a state file this is the only "finished" signal.
const runs = runDirs.map(scanRun).filter((run) => !run.legacy || !run.outputs.every(
  (output) => output.kind === 'spec' && output.published && output.published.complete));
runs.sort((left, right) => {
  const difference = new Date(right.started_at).getTime() - new Date(left.started_at).getTime();
  if (difference !== 0) return difference;
  return left.path.localeCompare(right.path);
});
const data = {
  version: 1,
  repo,
  repo_path: repoPath,
  runs_root: runsRoot,
  generated_at: new Date().toISOString(),
  runs,
};
if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
} else {
  process.stdout.write(renderText(data));
}
NODE
}

guess_repo() {
  local run_dir=$1 repo_path=${2:-} slug name file candidate
  name=${repo_path##*/}
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      if [ -n "$name" ]; then
        case "$slug" in
          */"$name") printf '%s' "$slug"; return 0 ;;
        esac
      fi
    done < <(grep -Eo '[A-Za-z0-9][A-Za-z0-9._-]+/[A-Za-z0-9][A-Za-z0-9._-]+' "$file" 2>/dev/null | sort -u)
  done < <(find "$run_dir" -maxdepth 2 -type f -name 'brief.md' -print0 2>/dev/null | tr '\0' '\n')
  if [ -n "$name" ]; then
    printf '%s' "$name"
    return 0
  fi
  candidate=$(basename "$run_dir")
  candidate=${candidate%%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]*}
  printf '%s' "$candidate"
}

cmd_abandon() {
  local run_dir=${1:-} repo=${2:-} repo_path=${3:-}
  [ -n "$run_dir" ] || die_usage "abandon needs a run directory"
  [ -d "$run_dir" ] || die "run directory does not exist: $run_dir"
  local file="$run_dir/run-state.json" now
  now=$(now_iso)
  if [ -f "$file" ]; then
    local json
    json=$(STATE_FILE="$file" NOW="$now" node -e '
      const fs = require("fs");
      let value;
      try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch { process.exit(1); }
      if (!value.finished_at) value.finished_at = process.env.NOW;
      value.aborted = "abandoned-by-later-run";
      process.stdout.write(JSON.stringify(value, null, 2));
    ') || die "could not abandon the run state in $file"
    write_state "$file" "$json"
    return 0
  fi

  [ -n "$repo" ] || repo=$(guess_repo "$run_dir" "$repo_path")
  [ -n "$repo_path" ] || repo_path=$(cd -P -- "$run_dir" 2>/dev/null && pwd) || repo_path=""
  local started
  started=$(EPOCH="$(dir_mtime "$run_dir")" node -e '
    process.stdout.write(new Date(Number(process.env.EPOCH) * 1000).toISOString());
  ')
  local json
  json=$(REPO="$repo" REPO_PATH="$repo_path" STARTED="$started" FINISHED="$now" node -e '
    const e = process.env;
    process.stdout.write(JSON.stringify({
      version: 1,
      repo: e.REPO,
      repo_path: e.REPO_PATH,
      owner_pid: null,
      owner_pid_start: "",
      started_at: e.STARTED,
      step: "未知",
      finished_at: e.FINISHED,
      aborted: "abandoned-by-later-run",
    }, null, 2));
  ')
  write_state "$file" "$json"
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || die_usage "missing command"
shift

case "$COMMAND" in
  init)
    [ $# -ge 1 ] || die_usage "init needs a run directory"
    run_dir=$1
    shift
    repo=""
    repo_path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) [ $# -ge 2 ] || die_usage "--repo requires <owner/name>"; repo=$2; shift 2 ;;
        --repo-path) [ $# -ge 2 ] || die_usage "--repo-path requires a path"; repo_path=$2; shift 2 ;;
        *) die_usage "unknown or repeated argument: $1" ;;
      esac
    done
    cmd_init "$run_dir" "$repo" "$repo_path"
    ;;
  step)
    [ $# -ge 2 ] || die_usage "step needs a run directory and a step"
    cmd_step "$1" "$2"
    ;;
  finish)
    [ $# -ge 1 ] || die_usage "finish needs a run directory"
    run_dir=$1
    shift
    reason=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --aborted) [ $# -ge 2 ] || die_usage "--aborted requires a reason"; reason=$2; shift 2 ;;
        *) die_usage "unknown or repeated argument: $1" ;;
      esac
    done
    cmd_finish "$run_dir" "$reason"
    ;;
  pending)
    repo=""
    repo_path=""
    runs_root=$DEFAULT_RUNS_ROOT
    json=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) [ $# -ge 2 ] || die_usage "--repo requires <owner/name>"; repo=$2; shift 2 ;;
        --repo-path) [ $# -ge 2 ] || die_usage "--repo-path requires a path"; repo_path=$2; shift 2 ;;
        --runs-root) [ $# -ge 2 ] || die_usage "--runs-root requires a directory"; runs_root=$2; shift 2 ;;
        --json) json=1; shift ;;
        *) die_usage "unknown or repeated argument: $1" ;;
      esac
    done
    cmd_pending "$repo" "$repo_path" "$runs_root" "$json"
    ;;
  abandon)
    [ $# -ge 1 ] || die_usage "abandon needs a run directory"
    run_dir=$1
    shift
    repo=""
    repo_path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) [ $# -ge 2 ] || die_usage "--repo requires <owner/name>"; repo=$2; shift 2 ;;
        --repo-path) [ $# -ge 2 ] || die_usage "--repo-path requires a path"; repo_path=$2; shift 2 ;;
        *) die_usage "unknown or repeated argument: $1" ;;
      esac
    done
    cmd_abandon "$run_dir" "$repo" "$repo_path"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    die_usage "unknown command: $COMMAND"
    ;;
esac
