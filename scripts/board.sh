#!/usr/bin/env bash
# Build and display the local implement-spec-split progress board.

set -u

usage() {
  cat <<'EOF'
Usage: board.sh snapshot [--force] [--repo <owner/name|dir|path>]
       board.sh [<owner/name|dir|path>] [--since <N>d | --all] [--force] [--repo <repo>]
       board.sh prune [--yes] | render

Build a Progress board snapshot from the Orca Repo registry, pipeline-status
relation graphs, Claim records, Run directories and External workers.  Without
a subcommand, the same refresh is followed by a Chinese terminal view.

  snapshot               Refresh caches and write board JSON snapshots
  <repo>                 Refresh, then show one repository
  --force                Refresh every repository now
  --repo <repo>          Refresh that repository now; other repos keep their TTL
  --since <N>d           Show repos with activity in the last N days
  --all                  Show every non-unused repository
  prune [--yes]          Board pruning: list (dry-run, default) or delete (--yes)
                         leftovers; see the PRUNE section below
  render                 Not implemented yet (ticket #13)

BOARD_DIR overrides the board directory (default
${ISS_STATE_DIR:-~/.cache/implement-spec-split}/board). BOARD_NOW is an ISO time
for deterministic tests. BOARD_PIPELINE_STATUS, BOARD_CONCURRENCY and
BOARD_STALL_SECS are also test/operation seams.

PRUNE
  Two kinds of leftovers, nothing else:
    1. Repos no longer in the Orca Repo registry: their Run directories,
       Launch state and board snapshots/graphs.  Skipped (with the reason
       printed) when the orca call fails or lists no repos.
    2. Repos still in the registry: Run directories whose Spec has been closed
       for more than 14 days, and Claim records whose holder process is dead
       and whose Spec is closed.
  Run directories of Specs that are not closed are always kept (Recovery needs
  them); if gh cannot tell the Spec state, it is kept.  prune only reads from
  GitHub, never writes.  Without --yes it only prints the list.
  Do NOT put prune in a scheduled job (cron/launchd): run it by hand and read
  the list first.
EOF
}

die() {
  printf 'board: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  render)
    printf '%s\n' 'board: render 尚未实现（票 #13）' >&2
    exit 2
    ;;
esac

command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

exec node - "$HERE" "$@" <<'NODE'
const fs = require("fs");
const os = require("os");
const path = require("path");
const {spawnSync, execFile} = require("child_process");

const scriptDir = process.argv[2];
const rawArgs = process.argv.slice(3);
const env = process.env;

function fail(message, code = 1) {
  process.stderr.write(`board: ${message}\n`);
  process.exit(code);
}

function usage() {
  process.stdout.write(`Usage: board.sh snapshot [--force] [--repo <owner/name|dir|path>]
       board.sh [<owner/name|dir|path>] [--since <N>d | --all] [--force] [--repo <repo>]
       board.sh prune [--yes] | render
Run board.sh --help for details.
`);
}

function parseArgs(args) {
  const value = {
    command: null, positional: null, force: false, repo: null,
    since: null, all: false, help: false, yes: false,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "-h" || arg === "--help") value.help = true;
    else if (arg === "--yes") {
      if (value.yes) fail("--yes was given more than once");
      value.yes = true;
    } else if (arg === "--force") {
      if (value.force) fail("--force was given more than once");
      value.force = true;
    } else if (arg === "--all") {
      if (value.all) fail("--all was given more than once");
      if (value.since !== null) fail("--all and --since are mutually exclusive");
      value.all = true;
    } else if (arg === "--since" || arg === "--repo") {
      const next = args[i + 1];
      if (!next || next.startsWith("--")) fail(`${arg} requires a value`);
      i += 1;
      if (arg === "--repo") {
        if (value.repo !== null) fail("--repo was given more than once");
        value.repo = next;
      } else {
        if (value.since !== null || value.all) fail("--since was given more than once");
        if (!/^[1-9][0-9]*d$/.test(next)) fail("--since requires a positive day count such as 30d");
        value.since = Number(next.slice(0, -1));
      }
    } else if (!arg.startsWith("--")) {
      if (value.command !== null || value.positional !== null) fail(`unexpected argument: ${arg}`);
      if (arg === "snapshot") value.command = "snapshot";
      else if (arg === "prune") value.command = "prune";
      else if (arg === "render") {
        fail("render 尚未实现（票 #13）", 2);
      } else value.positional = arg;
    } else {
      usage();
      fail(`unknown argument: ${arg}`);
    }
  }
  if (value.yes && value.command !== "prune") fail("--yes only applies to prune");
  if (value.command === "prune" && (value.force || value.repo !== null || value.since !== null || value.all)) {
    fail("prune only accepts --yes");
  }
  if (value.command === "snapshot" && value.positional !== null) {
    fail("snapshot does not take a repository positional argument; use --repo");
  }
  if (value.positional !== null && value.repo !== null && value.positional !== value.repo) {
    fail("give the repository either positionally or with --repo, not both");
  }
  return value;
}

function parseTime(value, name) {
  const time = new Date(value);
  if (!Number.isFinite(time.getTime())) fail(`${name} must be a valid ISO-8601 time`);
  return time;
}

const args = parseArgs(rawArgs);
if (args.help) {
  usage();
  process.exit(0);
}

const nowDate = parseTime(env.BOARD_NOW || new Date().toISOString(), "BOARD_NOW");
const nowEpoch = Math.floor(nowDate.getTime() / 1000);
const nowIso = nowDate.toISOString();
const concurrency = Number(env.BOARD_CONCURRENCY || 3);
if (!Number.isSafeInteger(concurrency) || concurrency < 1) fail("BOARD_CONCURRENCY must be a positive integer");
const stallSecs = Number(env.BOARD_STALL_SECS ?? 900);
if (!Number.isFinite(stallSecs) || stallSecs < 0) fail("BOARD_STALL_SECS must be a non-negative number");
const stateDir = env.ISS_STATE_DIR || path.join(os.homedir(), ".cache", "implement-spec-split");
const boardDir = env.BOARD_DIR || path.join(stateDir, "board");
const pipelineScript = env.BOARD_PIPELINE_STATUS || path.join(scriptDir, "pipeline-status.sh");
const progressScript = path.join(scriptDir, "progress.sh");

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(temporary, file);
}

function warn(message) {
  process.stderr.write(`board: ${message}\n`);
}

function commandText(result, command) {
  if (result.error) return `${result.error.message}`;
  const stderr = String(result.stderr || "").trim();
  const stdout = String(result.stdout || "").trim();
  return [stderr, stdout].filter(Boolean).join(": ") || `${command} failed`;
}

function loadRegistry() {
  const cache = path.join(boardDir, "registry.json");
  const result = spawnSync("orca", ["repo", "list", "--json"], {
    encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status === 0) {
    let value = null;
    try { value = JSON.parse(result.stdout || "null"); } catch {}
    const repos = Array.isArray(value?.result?.repos) ? value.result.repos : null;
    if (!repos) {
      const cachedInvalid = readJson(cache);
      if (!Array.isArray(cachedInvalid?.repos)) {
        throw new Error("orca repo list returned invalid JSON and no cached registry exists");
      }
      warn("orca repo list returned invalid JSON; using cached registry");
      return {source: "cache", fetched_at: cachedInvalid.fetched_at || null, repos: cachedInvalid.repos};
    }
    const filtered = [];
    for (const item of repos) {
      const remote = String(item?.gitRemoteIdentity?.canonicalKey || "");
      const repoPath = String(item?.path || "");
      if (!remote.startsWith("github.com/") || !repoPath) continue;
      const name = remote.slice("github.com/".length);
      if (!name.includes("/")) continue;
      filtered.push({
        repo: name,
        path: path.resolve(repoPath),
        dir: path.basename(path.resolve(repoPath)),
      });
    }
    const cached = {fetched_at: nowIso, repos: filtered};
    atomicWriteJson(cache, cached);
    return {source: "orca", fetched_at: nowIso, repos: filtered};
  }
  const cached = readJson(cache);
  if (!Array.isArray(cached?.repos)) {
    throw new Error(`orca repo list failed and no cached registry exists (${commandText(result, "orca repo list")})`);
  }
  warn(`orca repo list failed; using cached registry from ${cached.fetched_at || "unknown time"}`);
  return {source: "cache", fetched_at: cached.fetched_at || null, repos: cached.repos};
}

function absoluteReal(file) {
  try {
    return fs.realpathSync(path.resolve(file));
  } catch {
    return path.resolve(file);
  }
}

function resolveGitCommon(repoPath) {
  const result = spawnSync("git", ["-C", repoPath, "rev-parse", "--git-common-dir"], {
    encoding: "utf8",
  });
  if (result.status !== 0) return null;
  const value = String(result.stdout || "").trim();
  if (!value) return null;
  return absoluteReal(path.isAbsolute(value) ? value : path.resolve(repoPath, value));
}

function branchExists(repoPath, spec) {
  const result = spawnSync("git", ["-C", repoPath, "show-ref", "--verify", "--quiet", `refs/heads/spec-${spec}`]);
  return result.status === 0;
}

function localTimestamp(name) {
  const match = name.match(/-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})$/);
  if (!match) return null;
  const date = new Date(0);
  date.setFullYear(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  date.setHours(Number(match[4]), Number(match[5]), 0, 0);
  const time = date.getTime();
  return Number.isFinite(time) ? Math.floor(time / 1000) : null;
}

function epochFromIso(value) {
  const time = Date.parse(value);
  return Number.isFinite(time) ? Math.floor(time / 1000) : null;
}

function readClaims(repo) {
  const common = resolveGitCommon(repo.path);
  const claims = new Map();
  if (!common) return {common, claims};
  const dir = path.join(common, "implement-spec-split", "claims");
  let names = [];
  try { names = fs.readdirSync(dir); } catch {}
  for (const name of names) {
    const match = name.match(/^spec-(\d+)\.json$/);
    if (!match) continue;
    const file = path.join(dir, name);
    const value = readJson(file);
    if (!value) continue;
    claims.set(Number(match[1]), {record: value, file});
  }
  return {common, claims};
}

function scanRuns(repo, runsBase) {
  let names = [];
  try { names = fs.readdirSync(runsBase, {withFileTypes: true}); } catch {}
  const runs = new Map();
  let activity = [];
  const escaped = repo.dir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const anyRun = new RegExp(`^${escaped}-\\d+-\\d{8}-\\d{4}$`);
  const bySpec = new RegExp(`^${escaped}-(\\d+)-(\\d{8}-\\d{4})$`);
  for (const entry of names) {
    if (!entry.isDirectory() || !anyRun.test(entry.name)) continue;
    const timestamp = localTimestamp(entry.name);
    if (timestamp !== null) activity.push(timestamp);
    const match = entry.name.match(bySpec);
    if (!match) continue;
    const spec = Number(match[1]);
    const dir = path.join(runsBase, entry.name);
    const run = readJson(path.join(dir, "run.json")) || null;
    const updatedEpoch = epochFromIso(run?.updated);
    if (updatedEpoch !== null) activity.push(updatedEpoch);
    const previous = runs.get(spec);
    const key = match[2];
    if (!previous || key > previous.key) runs.set(spec, {...previous, key, dir, run, name: entry.name});
    else {
      // Keep any useful artifacts from an older name only if the newest name
      // unexpectedly lacks run.json; name order itself is authoritative.
      const current = runs.get(spec);
      if (!current.run && run) current.run = run;
    }
  }
  return {runs, activity};
}

function scanLocal(repo, runsBase) {
  const claimInfo = readClaims(repo);
  const runInfo = scanRuns(repo, runsBase);
  const activity = [...runInfo.activity];
  for (const {record, file} of claimInfo.claims.values()) {
    const claimed = epochFromIso(record.claimed_at);
    if (claimed !== null) activity.push(claimed);
    else {
      try { activity.push(Math.floor(fs.statSync(file).mtimeMs / 1000)); } catch {}
    }
  }
  const latest = activity.length ? Math.max(...activity) : null;
  return {
    common: claimInfo.common,
    claims: claimInfo.claims,
    runs: runInfo.runs,
    lastActivityEpoch: latest,
    lastActivityIso: latest === null ? null : new Date(latest * 1000).toISOString(),
  };
}

function graphAgeSeconds(cache) {
  if (!cache || !Number.isFinite(cache.fetched_at)) return Infinity;
  return Math.max(0, nowEpoch - cache.fetched_at);
}

function mappedClaimStates(repo, graph, local) {
  if (!graph) return [];
  const states = [];
  for (const spec of Array.isArray(graph.specs) ? graph.specs : []) {
    if (spec.state !== "open") continue;
    const number = Number(spec.number);
    if (!Number.isSafeInteger(number)) continue;
    const raw = local.claims.get(number)?.record || null;
    const graphState = spec.claim?.state;
    let state = null;
    if (spec.status === "running" || graphState === "running") state = "active";
    if (spec.status === "interrupted" || graphState === "interrupted") state = "interrupted";
    if (raw?.handoff && !branchExists(repo.path, number)) state = "reserved";
    if (state) states.push({spec: number, state});
  }
  return states;
}

function isRepoActive(repo, graph, local) {
  if (local.lastActivityEpoch !== null && nowEpoch - local.lastActivityEpoch <= 7 * 86400) return true;
  return mappedClaimStates(repo, graph, local).some((item) => item.state !== null);
}

function runPrune() {
  const launchDir = env.ISS_LAUNCH_STATE_DIR || path.join(os.homedir(), ".cache", "implement-spec-split", "launch");
  const graphsDir = path.join(boardDir, "graphs");
  const snapsDir = path.join(boardDir, "repos");
  const runsDir = path.join(stateDir, "runs");
  const closedDays = 14;
  const plan = [];   // {kind, path, base, reason}
  const kept = [];
  const notes = [];

  // Registry: raw Orca list (all repos, for directory names) plus GitHub names.
  let orcaOk = false;
  let allDirs = new Set();
  let ghRepos = [];
  const result = spawnSync("orca", ["repo", "list", "--json"], {encoding: "utf8", maxBuffer: 64 * 1024 * 1024});
  if (result.status === 0) {
    let value = null;
    try { value = JSON.parse(result.stdout || "null"); } catch {}
    const list = Array.isArray(value?.result?.repos) ? value.result.repos : null;
    if (!list) notes.push("orca repo list 返回了无法解析的内容，已跳过第 1 类（已不在 Orca 的仓库）");
    else if (list.length === 0) notes.push("orca repo list 返回 0 个仓库，疑似 Orca 未就绪，已跳过第 1 类（已不在 Orca 的仓库）");
    else {
      orcaOk = true;
      for (const item of list) {
        const p = String(item?.path || "");
        if (p) allDirs.add(path.basename(path.resolve(p)));
        const remote = String(item?.gitRemoteIdentity?.canonicalKey || "");
        if (remote.startsWith("github.com/") && p && remote.slice(11).includes("/")) {
          ghRepos.push({repo: remote.slice(11), path: path.resolve(p), dir: path.basename(path.resolve(p))});
        }
      }
    }
  } else {
    notes.push(`orca repo list 失败（${commandText(result, "orca repo list")}），已跳过第 1 类（已不在 Orca 的仓库）`);
  }
  if (!orcaOk) {
    // Class 2 can still use the last cached registry; without it, nothing to do.
    const cached = readJson(path.join(boardDir, "registry.json"));
    if (Array.isArray(cached?.repos)) {
      ghRepos = cached.repos.filter((r) => r && r.repo && r.path).map((r) => ({repo: r.repo, path: r.path, dir: path.basename(r.path)}));
      notes.push("第 2 类使用上次缓存的仓库登记");
    } else notes.push("没有缓存的仓库登记，第 2 类也跳过");
  }

  const within = (base, file) => {
    const rel = path.relative(base, file);
    return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
  };
  const add = (kind, base, file, reason) => {
    if (!within(base, file)) return;
    plan.push({kind, base, path: file, reason});
  };
  const listDir = (dir) => { try { return fs.readdirSync(dir, {withFileTypes: true}); } catch { return []; } };

  const ghCache = new Map();
  function specState(repo, spec) { // {state, closedEpoch} or null when unknown
    const key = `${repo}#${spec}`;
    if (ghCache.has(key)) return ghCache.get(key);
    let info = null;
    const r = spawnSync("gh", ["issue", "view", String(spec), "--repo", repo, "--json", "state,closedAt"], {encoding: "utf8"});
    if (r.status === 0) {
      let v = null;
      try { v = JSON.parse(r.stdout || "null"); } catch {}
      if (v && v.state === "CLOSED") {
        const e = v.closedAt ? epochFromIso(v.closedAt) : null;
        info = {state: "closed", closedEpoch: e};
      } else if (v && v.state === "OPEN") info = {state: "open", closedEpoch: null};
    }
    ghCache.set(key, info);
    return info;
  }

  const runRe = /^(.+)-(\d+)-(\d{8}-\d{4})$/;
  const dirCount = new Map();
  for (const r of ghRepos) dirCount.set(r.dir, (dirCount.get(r.dir) || 0) + 1);
  const ambiguous = (r) => dirCount.get(r.dir) > 1;
  const byDir = new Map(ghRepos.map((r) => [r.dir, r]));
  const registryKeys = new Set(ghRepos.map((r) => r.repo.replace("/", "__")));

  // Class 1: repos gone from Orca.
  if (orcaOk) {
    for (const e of listDir(runsDir)) {
      const m = e.name.match(runRe);
      if (!m || !e.isDirectory() || e.isSymbolicLink()) continue;
      if (!allDirs.has(m[1])) add("1 已移出 Orca 的 Run 目录", runsDir, path.join(runsDir, e.name), `仓库 ${m[1]} 不在 Orca`);
    }
    for (const e of listDir(launchDir)) {
      const m = e.name.match(/^([^/]+__[^/]+)\.json$/);
      if (m && e.isFile() && !registryKeys.has(m[1])) add("1 已移出 Orca 的 Launch state", launchDir, path.join(launchDir, e.name), `仓库 ${m[1]} 不在 Orca`);
    }
    for (const [dir, label] of [[snapsDir, "看板快照"], [graphsDir, "看板 graph"]]) {
      for (const e of listDir(dir)) {
        const m = e.name.match(/^([^/]+__[^/]+)\.json$/);
        if (m && e.isFile() && !registryKeys.has(m[1])) add(`1 已移出 Orca 的${label}`, dir, path.join(dir, e.name), `仓库 ${m[1]} 不在 Orca`);
      }
    }
  }

  // Class 2: repos still registered.
  for (const e of listDir(runsDir)) {
    const m = e.name.match(runRe);
    if (!m || !e.isDirectory() || e.isSymbolicLink()) continue;
    const repo = byDir.get(m[1]);
    if (!repo) continue;
    if (ambiguous(repo)) { kept.push(`${e.name}（目录名对应多个仓库，保留）`); continue; }
    const info = specState(repo.repo, Number(m[2]));
    if (!info) { kept.push(`${e.name}（${repo.repo}#${m[2]} 状态查不到，保留）`); continue; }
    if (info.state !== "closed") { kept.push(`${e.name}（Spec 未关闭，保留）`); continue; }
    if (info.closedEpoch === null) { kept.push(`${e.name}（关闭时间未知，保留）`); continue; }
    if (nowEpoch - info.closedEpoch > closedDays * 86400) {
      add("2 Spec 已关闭超过 14 天的 Run 目录", runsDir, path.join(runsDir, e.name), `${repo.repo}#${m[2]} 关闭于 ${new Date(info.closedEpoch * 1000).toISOString()}`);
    } else kept.push(`${e.name}（Spec 关闭不足 14 天，保留）`);
  }
  const aliveCheck = (file) => spawnSync("bash", ["-c", 'source "$1/lib-owner.sh" && claim_record_alive "$2"', "_", scriptDir, file], {stdio: "ignore"}).status === 0;
  for (const repo of ghRepos) {
    if (ambiguous(repo)) continue;
    const common = resolveGitCommon(repo.path);
    if (!common) continue;
    const dir = path.join(common, "implement-spec-split", "claims");
    for (const e of listDir(dir)) {
      const m = e.name.match(/^spec-(\d+)\.json$/);
      if (!m || !e.isFile()) continue;
      const file = path.join(dir, e.name);
      if (aliveCheck(file)) { kept.push(`${repo.repo} ${e.name}（持有进程仍存活，保留）`); continue; }
      const info = specState(repo.repo, Number(m[1]));
      if (!info) { kept.push(`${repo.repo} ${e.name}（Spec 状态查不到，保留）`); continue; }
      if (info.state !== "closed") { kept.push(`${repo.repo} ${e.name}（Spec 未关闭，保留）`); continue; }
      add("2 持有进程已死且 Spec 已关闭的 Claim record", dir, file, `${repo.repo}#${m[1]} 已关闭`);
    }
  }

  process.stdout.write(args.yes ? "== board prune --yes（真正删除）==\n" : "== board prune（dry-run，只列清单；加 --yes 才删除）==\n");
  for (const n of notes) process.stdout.write(`注意：${n}\n`);
  if (plan.length === 0) process.stdout.write("没有可清理的内容。\n");
  let failed = 0;
  for (const item of plan) {
    if (!args.yes) { process.stdout.write(`将删除 [${item.kind}] ${item.path}（${item.reason}）\n`); continue; }
    try {
      const st = fs.lstatSync(item.path);
      if (st.isSymbolicLink()) throw new Error("是符号链接，拒绝删除");
      if (!within(fs.realpathSync(item.base), fs.realpathSync(item.path))) throw new Error("不在预期目录下");
      if (st.isDirectory()) fs.rmSync(item.path, {recursive: true});
      else fs.unlinkSync(item.path);
      process.stdout.write(`已删除 [${item.kind}] ${item.path}\n`);
    } catch (error) {
      failed += 1;
      process.stdout.write(`删除失败 [${item.kind}] ${item.path}：${error.message}\n`);
    }
  }
  process.stdout.write(`${args.yes ? "已处理" : "待清理"} ${plan.length} 项，保留 ${kept.length} 项受保护的候选。\n`);
  for (const k of kept) process.stdout.write(`保留：${k}\n`);
  process.exit(failed ? 1 : 0);
}
if (args.command === "prune") runPrune();

const repositories = (() => {
  try { return loadRegistry(); } catch (error) { fail(error.message); }
})();

function resolveRepository(selector, {allowCurrentDirectory = false} = {}) {
  if (!selector && allowCurrentDirectory) {
    const cwd = process.cwd();
    const exact = repositories.repos.filter((repo) => absoluteReal(repo.path) === absoluteReal(cwd));
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) {
      fail(`仓库参数有歧义：${exact.map((repo) => repo.repo).join("、")}`, 64);
    }
    const commonRaw = spawnSync("git", ["-C", cwd, "rev-parse", "--git-common-dir"], {encoding: "utf8"});
    if (commonRaw.status === 0) {
      const commonText = String(commonRaw.stdout || "").trim();
      const common = absoluteReal(path.isAbsolute(commonText) ? commonText : path.resolve(cwd, commonText));
      const main = path.dirname(common);
      const owner = repositories.repos.filter((repo) => absoluteReal(repo.path) === main);
      if (owner.length === 1) return owner[0];
      if (owner.length > 1) {
        fail(`仓库参数有歧义：${owner.map((repo) => repo.repo).join("、")}`, 64);
      }
      return null;
    }
    return null;
  }
  if (!selector) return null;
  const resolved = absoluteReal(selector);
  const matches = repositories.repos.filter((repo) => (
    repo.repo === selector || repo.dir === selector || absoluteReal(repo.path) === resolved
  ));
  const unique = [...new Map(matches.map((repo) => [repo.repo, repo])).values()];
  if (unique.length === 1) return unique[0];
  if (unique.length > 1) {
    fail(`仓库参数有歧义：${unique.map((repo) => repo.repo).join("、")}`, 64);
  }
  fail(`未匹配的仓库：${selector}`, 64);
}

const positionalRepo = args.positional ? resolveRepository(args.positional) : null;
const optionRepo = args.repo ? resolveRepository(args.repo) : null;
  let noArgCurrent = null;
  if (args.command === null && !args.positional && !args.repo) {
    noArgCurrent = resolveRepository(null, {allowCurrentDirectory: true});
  }
  const selectedRepo = positionalRepo || optionRepo || noArgCurrent || null;

const graphDir = path.join(boardDir, "graphs");
const repoSnapshotDir = path.join(boardDir, "repos");
const runsBase = path.join(stateDir, "runs");
const locals = new Map(repositories.repos.map((repo) => [repo.repo, scanLocal(repo, runsBase)]));
const oldGraphs = new Map(repositories.repos.map((repo) => {
  const file = path.join(graphDir, `${repo.repo.replace("/", "__")}.json`);
  return [repo.repo, {file, cache: readJson(file)}];
}));

function shouldRefresh(repo, graphInfo) {
  if (args.force) return true;
  if (selectedRepo && repo.repo === selectedRepo.repo) return true;
  if (!graphInfo.cache?.graph) return true;
  const active = isRepoActive(repo, graphInfo.cache.graph, locals.get(repo.repo));
  return graphAgeSeconds(graphInfo.cache) > (active ? 600 : 3600);
}

const refreshJobs = repositories.repos
  .filter((repo) => shouldRefresh(repo, oldGraphs.get(repo.repo)))
  .map((repo) => ({repo, graphInfo: oldGraphs.get(repo.repo)}));

function refreshGraph(job) {
  return new Promise((resolve) => {
    execFile(pipelineScript, ["--graph", "--repo", job.repo.repo], {
      cwd: job.repo.path,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    }, (error, stdout) => {
      if (error) {
        const stderr = String(error.stderr || "").trim();
        job.error = stderr || error.message;
        warn(`刷新 ${job.repo.repo} 的 GitHub 关系图失败：${job.error}；沿用旧缓存`);
        return resolve();
      }
      let graph = null;
      try { graph = JSON.parse(stdout); } catch {}
      if (!graph || typeof graph !== "object" || Array.isArray(graph)) {
        job.error = "pipeline-status --graph 输出不是合法 JSON 对象";
        warn(`刷新 ${job.repo.repo} 的 GitHub 关系图失败：输出不是合法 JSON；沿用旧缓存`);
        return resolve();
      }
      atomicWriteJson(job.graphInfo.file, {fetched_at: nowEpoch, graph});
      resolve();
    });
  });
}

(async () => {
  let cursor = 0;
  const workers = Array.from({length: Math.min(concurrency, refreshJobs.length)}, async () => {
    for (;;) {
      const index = cursor;
      cursor += 1;
      if (index >= refreshJobs.length) break;
      await refreshGraph(refreshJobs[index]);
    }
  });
  await Promise.all(workers);

  const errors = new Map(refreshJobs.filter((job) => job.error).map((job) => [job.repo.repo, job.error]));
  const snapshots = [];
  const repoSnapshots = new Map();

  function enrichSpec(spec, repo, local) {
    const number = Number(spec.number);
    let claim = null;
    if (spec.state === "open") {
      const raw = local.claims.get(number)?.record || null;
      let state = null;
      if (spec.status === "running" || spec.claim?.state === "running") state = "active";
      if (spec.status === "interrupted" || spec.claim?.state === "interrupted") state = "interrupted";
      if (raw?.handoff && !branchExists(repo.path, number)) state = "reserved";
      if (state) {
        claim = {
          state,
          branch: raw?.branch || spec.claim?.branch || `spec-${number}`,
          worktree: raw?.worktree || spec.claim?.worktree || "",
          claimed_at: raw?.claimed_at || null,
        };
      }
    }
    const runRecord = local.runs.get(number) || null;
    const includeRun = spec.state === "open" && (claim !== null || (runRecord?.run?.phase && runRecord.run.phase !== "done"));
    const run = includeRun && runRecord ? {
      dir: runRecord.dir,
      phase: runRecord.run?.phase || null,
      wave: runRecord.run?.wave ?? null,
      tickets: runRecord.run?.tickets || null,
      updated: runRecord.run?.updated || null,
    } : null;

    const workers = [];
    if (claim && runRecord) {
      let names = [];
      try { names = fs.readdirSync(runRecord.dir, {withFileTypes: true}); } catch {}
      for (const entry of names) {
        if (!entry.isDirectory()) continue;
        const workerDir = path.join(runRecord.dir, entry.name);
        if (!fs.existsSync(path.join(workerDir, "pid")) && !fs.existsSync(path.join(workerDir, "status.json"))) continue;
        const progress = spawnSync(progressScript, [workerDir, "1"], {encoding: "utf8"});
        const stateLine = String(progress.stdout || "").split(/\r?\n/, 1)[0];
        const stateMatch = stateLine.match(/^state:\s*(.*)$/);
        const progressState = stateMatch ? stateMatch[1].trim() : "unknown";
        let state = progressState;
        let status = null;
        if (progressState.startsWith("finished:")) state = "finished";
        const statusJson = readJson(path.join(workerDir, "status.json"));
        status = statusJson?.status || null;
        const watch = readJson(path.join(workerDir, "watch.json"));
        const fallbackFile = fs.existsSync(path.join(workerDir, "pid"))
          ? path.join(workerDir, "pid") : path.join(workerDir, "status.json");
        let fallback = null;
        try { fallback = Math.floor(fs.statSync(fallbackFile).mtimeMs / 1000); } catch {}
        const startedAt = Number.isFinite(watch?.started_at) ? watch.started_at : fallback;
        const lastProgressAt = Number.isFinite(watch?.last_progress_at) ? watch.last_progress_at : fallback;
        const duration = Number.isFinite(startedAt) ? Math.max(0, nowEpoch - startedAt) : null;
        const idle = Number.isFinite(lastProgressAt) ? Math.max(0, nowEpoch - lastProgressAt) : null;
        let anomalous = false;
        let anomalyReason = null;
        if (claim.state === "active" || claim.state === "reserved") {
          if (state === "dead") {
            anomalous = true; anomalyReason = "worker 已退出且没有结果";
          } else if (state === "finished" && status !== "ok") {
            anomalous = true; anomalyReason = `worker 结束状态为 ${status || "unknown"}`;
          } else if (state === "running" && idle !== null && idle > stallSecs) {
            anomalous = true; anomalyReason = `超过 ${stallSecs} 秒无进展`;
          }
        }
        const roleMatch = entry.name.match(/^(.*)-(\d+)[a-z]*(?:-.*)?$/);
        workers.push({
          name: entry.name,
          role: roleMatch ? roleMatch[1] : entry.name,
          ticket: roleMatch ? Number(roleMatch[2]) : null,
          state,
          status,
          started_at: Number.isFinite(startedAt) ? startedAt : null,
          duration_s: duration,
          idle_s: idle,
          anomalous,
          anomaly_reason: anomalyReason,
        });
      }
      workers.sort((a, b) => a.name.localeCompare(b.name, "en", {numeric: true}));
    }

    return {
      number,
      title: spec.title,
      kind: spec.kind,
      state: spec.state,
      status: spec.status,
      claim,
      depends_on: Array.isArray(spec.depends_on) ? spec.depends_on : [],
      tickets_total: spec.tickets_total,
      tickets_closed: spec.tickets_closed,
      tickets: Array.isArray(spec.tickets) ? spec.tickets : [],
      run,
      workers,
    };
  }

  for (const repo of repositories.repos) {
    const local = locals.get(repo.repo);
    const graphInfo = oldGraphs.get(repo.repo);
    const cache = readJson(graphInfo.file);
    const graph = cache?.graph || null;
    const githubError = errors.get(repo.repo) || null;
    const specs = (Array.isArray(graph?.specs) ? graph.specs : []).map((spec) => enrichSpec(spec, repo, local));
    const specByNumber = new Map(specs.map((spec) => [Number(spec.number), spec]));
    const maps = (Array.isArray(graph?.maps) ? graph.maps : []).map((map) => ({
      number: map.number,
      title: map.title,
      state: map.state,
      status: map.status,
      shelved: Boolean(map.shelved),
      decisions_total: map.decisions_total,
      decisions_open: map.decisions_open,
      specs: (Array.isArray(map.spec_numbers) ? map.spec_numbers : [])
        .map((number) => specByNumber.get(Number(number))).filter(Boolean),
      tickets: Array.isArray(map.tickets) ? map.tickets : [],
    }));
    const looseSpecs = (Array.isArray(graph?.loose_specs) ? graph.loose_specs : [])
      .map((number) => specByNumber.get(Number(number))).filter(Boolean);
    const claims = {
      active: specs.filter((spec) => spec.claim?.state === "active").length,
      reserved: specs.filter((spec) => spec.claim?.state === "reserved").length,
      interrupted: specs.filter((spec) => spec.claim?.state === "interrupted").length,
    };
    const attention = [];
    for (const spec of specs) {
      if (spec.claim?.state === "interrupted") attention.push({kind: "interrupted", spec: spec.number, detail: "中断的 Spec 需要恢复"});
      if (spec.state === "open" && spec.run?.phase === "parked") attention.push({kind: "parked", spec: spec.number, detail: spec.run.updated || "最新 Run 停车"});
      for (const worker of spec.workers) {
        if (worker.anomalous) attention.push({kind: "worker", spec: spec.number, detail: `${worker.name}: ${worker.anomaly_reason}`});
      }
    }
    const totals = graph?.counts;
    const unused = Boolean(totals && Number(totals.maps?.total) === 0 && Number(totals.specs?.total) === 0 && Number(totals.tickets?.total) === 0);
    const value = {
      repo: repo.repo,
      path: repo.path,
      dir: repo.dir,
      snapshot_at: nowIso,
      github_fetched_at: Number.isFinite(cache?.fetched_at) ? new Date(cache.fetched_at * 1000).toISOString() : null,
      github_error: githubError,
      error: graph ? null : (githubError || "没有可用的 GitHub 关系图数据"),
      unused,
      needs_attention: attention.length > 0,
      attention,
      last_activity: local.lastActivityIso,
      counts: graph?.counts || null,
      next_wave: graph?.next_wave || null,
      claims,
      maps,
      specs,
      loose_specs: looseSpecs,
    };
    atomicWriteJson(path.join(repoSnapshotDir, `${repo.repo.replace("/", "__")}.json`), value);
    repoSnapshots.set(repo.repo, value);
    snapshots.push({
      repo: value.repo,
      path: value.path,
      dir: value.dir,
      unused: value.unused,
      needs_attention: value.needs_attention,
      attention: value.attention,
      last_activity: value.last_activity,
      github_fetched_at: value.github_fetched_at,
      counts: value.counts,
      claims: value.claims,
      error: value.error,
    });
  }

  const machine = {
    snapshot_at: nowIso,
    registry: {source: repositories.source, fetched_at: repositories.fetched_at},
    repos: snapshots,
  };
  atomicWriteJson(path.join(boardDir, "snapshot.json"), machine);

  if (args.command === "snapshot") {
    process.stdout.write(`已更新 ${repositories.repos.length} 个仓库快照：${path.join(boardDir, "snapshot.json")}\n`);
    return;
  }

  function relativeTime(iso) {
    const epoch = epochFromIso(iso);
    if (epoch === null) return "无活动";
    const seconds = Math.max(0, nowEpoch - epoch);
    if (seconds < 60) return `${seconds}秒前`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}分钟前`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}小时前`;
    return `${Math.floor(seconds / 86400)}天前`;
  }

  function countLine(value) {
    const c = value.counts;
    if (!c) return "  计数：不可用（GitHub 关系图缺失）";
    return `  地图：${c.maps.total}｜规格：${c.specs.total}（已落地 ${c.specs.landed}，待拆 ${c.specs.needs_tickets}，可实现 ${c.specs.ready}）｜Ticket：${c.tickets.closed}/${c.tickets.total}`;
  }

  if (!selectedRepo) {
    const eligible = snapshots.filter((value) => !value.unused);
    const days = args.all ? Infinity : (args.since || 7);
    const visible = eligible.filter((value) => (
      value.needs_attention ||
      value.claims.active + value.claims.reserved + value.claims.interrupted > 0 ||
      days === Infinity ||
      (value.last_activity !== null && nowEpoch - epochFromIso(value.last_activity) <= days * 86400)
    ));
    const sorted = [...visible].sort((a, b) => {
      if (a.needs_attention !== b.needs_attention) return a.needs_attention ? -1 : 1;
      const aa = a.last_activity ? epochFromIso(a.last_activity) : -Infinity;
      const bb = b.last_activity ? epochFromIso(b.last_activity) : -Infinity;
      return bb - aa || a.repo.localeCompare(b.repo);
    });
    const hidden = eligible.length - visible.length;
    const unusedCount = snapshots.length - eligible.length;
    process.stdout.write(`Progress board｜显示 ${sorted.length} 个仓库，隐藏 ${hidden} 个（另有未使用 ${unusedCount} 个）\n\n`);
    for (const value of sorted) {
      process.stdout.write(`${value.needs_attention ? "!" : " "}${value.repo}｜最近活动 ${relativeTime(value.last_activity)}｜实现中 ${value.claims.active + value.claims.reserved}｜中断 ${value.claims.interrupted}\n`);
      process.stdout.write(`${countLine(value)}\n`);
      for (const item of value.attention) {
        process.stdout.write(`  ！${item.kind} #${item.spec}：${item.detail}\n`);
      }
    }
    if (!sorted.length) process.stdout.write("没有符合条件的仓库。\n");
    return;
  }

  const value = repoSnapshots.get(selectedRepo.repo);
  process.stdout.write(`${value.repo}｜快照 ${value.snapshot_at}｜最近活动 ${relativeTime(value.last_activity)}\n`);
  process.stdout.write(`${countLine(value)}\n`);
  if (value.github_error) process.stdout.write(`GitHub 刷新失败：${value.github_error}\n`);
  const wave = value.next_wave;
  if (!wave) process.stdout.write("下一波：不可用\n");
  else if (wave.resume?.length) process.stdout.write(`下一波：先恢复 ${wave.resume.map((item) => `#${item.spec}`).join(" ")}\n`);
  else if (wave.active?.length) process.stdout.write(`下一波：进行中 ${wave.active.map((item) => `#${item.spec}`).join(" ")}\n`);
  else if (wave.wave1?.length) process.stdout.write(`下一波：${wave.wave1.map((item) => `#${item.spec} ${item.title}`).join("；")}\n`);
  else process.stdout.write("下一波：没有可启动的规格\n");

  process.stdout.write("\n结构树\n");
  for (const map of value.maps) {
    process.stdout.write(`#${map.number} ${map.title}［${map.status}］\n`);
    for (const spec of map.specs) {
      if (spec.state === "closed") {
        process.stdout.write(`  #${spec.number} ${spec.title}（已落地；${spec.tickets_closed}/${spec.tickets_total} Ticket 已关）\n`);
      } else {
        process.stdout.write(`  #${spec.number} ${spec.title}［${spec.status}${spec.claim ? `／${spec.claim.state}` : ""}］\n`);
        for (const ticket of spec.tickets) {
          process.stdout.write(`    ${ticket.state === "closed" ? "x" : "o"} #${ticket.number} ${ticket.title}${ticket.shelved ? "（搁置）" : ""}\n`);
        }
      }
    }
    for (const ticket of map.tickets) process.stdout.write(`  ${ticket.state === "closed" ? "x" : "o"} #${ticket.number} ${ticket.title}\n`);
  }
  if (value.loose_specs.length) {
    process.stdout.write("散 Spec\n");
    for (const spec of value.loose_specs) {
      process.stdout.write(`#${spec.number} ${spec.title}［${spec.status}${spec.claim ? `／${spec.claim.state}` : ""}］\n`);
      for (const ticket of spec.tickets) {
        process.stdout.write(`  ${ticket.state === "closed" ? "x" : "o"} #${ticket.number} ${ticket.title}${ticket.shelved ? "（搁置）" : ""}\n`);
      }
    }
  }

  const running = value.specs.filter((spec) => spec.claim?.state === "active" || spec.claim?.state === "reserved" || spec.status === "running" || spec.run);
  if (running.length) {
    process.stdout.write("\nRun 与 Worker\n");
    for (const spec of running) {
      if (!spec.run && !spec.claim) continue;
      const state = spec.claim ? spec.claim.state : spec.status;
      const runText = spec.run ? `实现 ${spec.run.phase}${spec.run.wave ? `（第 ${spec.run.wave} 波）` : ""}｜Ticket ${spec.run.tickets?.merged ?? "?"}/${spec.run.tickets ? (spec.run.tickets.merged + spec.run.tickets.in_progress + spec.run.tickets.todo) : "?"}` : "没有 Run 目录";
      process.stdout.write(`#${spec.number} ${spec.title}［${state}｜${runText}］\n`);
      for (const worker of spec.workers) {
        process.stdout.write(`  ${worker.anomalous ? "!" : " "}${worker.name}｜${worker.state}${worker.status ? `/${worker.status}` : ""}｜运行 ${worker.duration_s ?? "?" }s｜距活动 ${worker.idle_s ?? "?"}s${worker.anomalous ? `｜${worker.anomaly_reason}` : ""}\n`);
      }
    }
  }
})();
NODE
