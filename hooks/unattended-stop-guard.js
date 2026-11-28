#!/usr/bin/env node

// Claude Code 的 Stop hook。
//
// 会话最近一次 /implement-spec-split 调用带 --auto-land 时，无人值守的 Run
// 没人会来管，所以结束前必须自己收尾。这个 hook 拦住两种"没人管"的结束：
//
//   规则 A（自关）：Run 的 phase 已经是 done / waiting / parked，但 transcript
//     里没有运行过 scripts/close-self.sh（2026-11-20 至 11-25 的 19 个无人值守
//     Run 里调用过 close-self 的是 0 个，10 个以"可以 /clear 了"结尾空转着不关）。
//   规则 B（问人）：最后一条 assistant 文本在问人或等人确认（spec-18 有一次用
//     纯文本发问后停住；unattended-ask-guard 只拦得住 AskUserQuestion 工具）。
//
// 其他情况放行：phase 还在 split / implement / integrate / review / land 且最后
// 一条消息不是在问人时，会话可以正常结束一轮（包括等后台任务的通知）。
// 逃生口 UNATTENDED_STOP_GUARD_DISABLE=1；任何内部异常都 fail open。

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const {
  readLastCommandArgs,
  hasAutoLandFlag,
  readLastAssistantText,
  hasBashCommandContaining,
} = require('./lib-transcript');

const DISABLE_ENV = 'UNATTENDED_STOP_GUARD_DISABLE';
const SKILL_DIR = path.resolve(__dirname, '..');
const CLOSE_SELF_SCRIPT = 'close-self.sh';
const TERMINAL_PHASES = new Set(['done', 'waiting', 'parked']);
const QUESTION_MARKERS = [
  '请确认',
  '等你',
  '需要你',
  '要不要',
  '是否继续',
  '你来决定',
  '请选择',
  '回复我',
];
const TAIL_CHARS = 300;
// When the session is already continuing from a Stop hook (stop_hook_active),
// each rule may block at most one more time. After that the session is allowed
// to end, with a warning on stderr, so a hook bug can never trap the session.
const MAX_EXTRA_BLOCKS = 1;
const RULE_SELF_CLOSE = 'selfClose';
const RULE_ASKING = 'asking';
const GIT_TIMEOUT_MS = 5000;

function selfCloseReason(phase) {
  return (
    `Run 已结束（phase=${phase}）：先确认落地/停车报告评论已发出，` +
    `然后最后一条命令运行 \`${SKILL_DIR}/scripts/${CLOSE_SELF_SCRIPT} --run-dir <Spec Run root>\`` +
    '（落地后加 `--remove-worktree <集成 worktree>`，停车不加；`--run-dir` 两种情况都带，不带它不释放票工作区），见 SKILL.md 第 10 步。'
  );
}

const ASKING_REASON =
  '无人值守 Run 没人会回复：' +
  'Opus 审查『需要人取舍』的条目按 SKILL.md 处理、不停车：『可自动采纳：是』的按推荐做，' +
  '『可自动采纳：否』或『推荐：无』的按可逆性规则自选一个可逆选项并写理由，' +
  '都记进落地报告的『### 自动拍板（可推翻）』；' +
  '合并冲突交 merger + Opus 审查；' +
  '只有需要本人身份或凭据（停车类别 auth）、或列出的选项里没有可逆的（停车类别 error）' +
  '才写停车报告（## 停车报告，首两行 停车类别 / 可恢复时间）后停车并自关。' +
  '若你只是在等后台任务或 worker，继续等待它的通知即可，不要问人。';

function block(reason) {
  process.stdout.write(
    JSON.stringify({ decision: 'block', reason }) + '\n'
  );
}

function note(message) {
  process.stderr.write(`unattended-stop-guard: ${message}\n`);
}

function stateDir() {
  const custom = process.env.ISS_STATE_DIR;
  if (typeof custom === 'string' && custom !== '') return custom;
  return path.join(os.homedir(), '.cache', 'implement-spec-split');
}

// The Spec number is the first numeric argument of the slash command:
// `/implement-spec-split 19 --impl agent --auto-land` -> "19".
function specNumberFromArgs(args) {
  if (typeof args !== 'string') return null;
  const token = args.split(/\s+/).find(part => /^\d+$/.test(part));
  return token === undefined ? null : token;
}

// `<repo>` as the Run directories use it: the origin repository's <name>.
function repoNameFromUrl(url) {
  if (typeof url !== 'string') return null;
  let value = url.trim();
  if (value === '') return null;
  value = value.replace(/[?#].*$/, '').replace(/\.git\/?$/, '');
  const colon = value.lastIndexOf(':');
  if (colon !== -1 && !value.slice(0, colon).includes('/')) {
    value = value.slice(colon + 1);
  }
  const parts = value.split('/').filter(part => part !== '');
  const name = parts.length > 0 ? parts[parts.length - 1] : value;
  return name === '' ? null : name.toLowerCase();
}

function gitOutput(cwd, args) {
  const result = childProcess.spawnSync('git', ['-C', cwd, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: GIT_TIMEOUT_MS,
  });
  if (result.error || result.status !== 0) return null;
  const output = String(result.stdout || '').trim();
  return output === '' ? null : output;
}

// Candidate <repo> names, in order: the origin repository's <name>, the
// workspace directory in `.../workspaces/<repo>/spec-<n>`, and the directory
// name of the main checkout (what SKILL.md tells run-phase.sh to use).
function repoNames(cwd) {
  if (typeof cwd !== 'string' || cwd === '') return [];
  const candidates = [];

  const origin = gitOutput(cwd, ['remote', 'get-url', 'origin']);
  const fromOrigin = repoNameFromUrl(origin);
  if (fromOrigin !== null) candidates.push(fromOrigin);

  const normalized = cwd.replace(/\\/g, '/');
  const workspaces = normalized.match(/\/workspaces\/([^/]+)\/spec-\d+(?:\/|$)/);
  if (workspaces !== null) candidates.push(workspaces[1].toLowerCase());

  const toplevel = gitOutput(cwd, ['rev-parse', '--show-toplevel']);
  if (toplevel !== null) {
    const name = path.basename(toplevel).toLowerCase();
    if (name !== '') candidates.push(name);
  }

  return [...new Set(candidates)];
}

function runDirsFor(repo, specNumber) {
  const runsDir = path.join(stateDir(), 'runs');
  let entries;
  try {
    entries = fs.readdirSync(runsDir, { withFileTypes: true });
  } catch (_error) {
    return [];
  }
  const prefix = `${repo}-${specNumber}-`;
  const matches = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith(prefix)) continue;
    const runJson = path.join(runsDir, entry.name, 'run.json');
    let stat;
    try {
      stat = fs.statSync(runJson);
    } catch (_error) {
      continue;
    }
    matches.push({ runJson, mtimeMs: stat.mtimeMs });
  }
  return matches;
}

// Phase of the newest Run directory that matches <repo>-<spec>-*, or null when
// there is none. The newest run.json (by mtime) wins, across every candidate.
function readPhase(cwd, specNumber) {
  if (specNumber === null) return null;
  let best = null;
  for (const repo of repoNames(cwd)) {
    for (const match of runDirsFor(repo, specNumber)) {
      if (best === null || match.mtimeMs > best.mtimeMs) best = match;
    }
  }
  if (best === null) return null;
  try {
    const value = JSON.parse(fs.readFileSync(best.runJson, 'utf8'));
    if (value === null || typeof value !== 'object') return null;
    if (typeof value.phase !== 'string') return null;
    const phase = value.phase.trim().toLowerCase();
    return phase === '' ? null : phase;
  } catch (_error) {
    return null;
  }
}

// True when the text is asking a person something. Only the last 300
// characters count, because that is the part the person would answer.
function isAsking(text) {
  const tail = text.length > TAIL_CHARS ? text.slice(-TAIL_CHARS) : text;
  if (tail.trim() === '') return false;
  if (/[？?]\s*$/.test(tail)) return true;
  return QUESTION_MARKERS.some(marker => tail.includes(marker));
}

function counterFilePath(transcriptPath) {
  const hash = crypto
    .createHash('sha256')
    .update(transcriptPath)
    .digest('hex')
    .slice(0, 32);
  return path.join(os.tmpdir(), 'unattended-stop-guard', `${hash}.json`);
}

function emptyCounts() {
  return { [RULE_SELF_CLOSE]: 0, [RULE_ASKING]: 0 };
}

function readCounts(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (value === null || typeof value !== 'object') return emptyCounts();
    return {
      [RULE_SELF_CLOSE]: Number(value[RULE_SELF_CLOSE]) || 0,
      [RULE_ASKING]: Number(value[RULE_ASKING]) || 0,
    };
  } catch (_error) {
    return emptyCounts();
  }
}

function writeCounts(file, counts) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(counts) + '\n');
    return true;
  } catch (_error) {
    // The counter is a loop guard only; failing to persist it must not block.
    return false;
  }
}

function main() {
  try {
    if (process.env[DISABLE_ENV] === '1') return;

    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (payload === null || typeof payload !== 'object') return;

    const transcriptPath = payload.transcript_path;
    if (typeof transcriptPath !== 'string' || transcriptPath === '') return;

    const args = readLastCommandArgs(transcriptPath);
    if (args === null || !hasAutoLandFlag(args)) return;

    const stopHookActive = Boolean(payload.stop_hook_active);
    const counterFile = counterFilePath(transcriptPath);
    // A fresh stop (not a continuation) starts a new loop, so stale counts from
    // an earlier incident must not disable the guard for the rest of the session.
    const counts = stopHookActive ? readCounts(counterFile) : emptyCounts();
    if (!stopHookActive) writeCounts(counterFile, emptyCounts());

    const blockOrWarn = (rule, reason) => {
      if (!stopHookActive) {
        block(reason);
        return;
      }
      if (counts[rule] >= MAX_EXTRA_BLOCKS) {
        note(
          `rule ${rule} already blocked ${MAX_EXTRA_BLOCKS} time(s) in this ` +
            'stop loop; allowing the session to end'
        );
        return;
      }
      counts[rule] += 1;
      if (!writeCounts(counterFile, counts)) {
        note('cannot persist the loop counter; allowing the session to end');
        return;
      }
      block(reason);
    };

    const phase = readPhase(payload.cwd, specNumberFromArgs(args));
    if (phase !== null && TERMINAL_PHASES.has(phase)) {
      if (!hasBashCommandContaining(transcriptPath, CLOSE_SELF_SCRIPT)) {
        blockOrWarn(RULE_SELF_CLOSE, selfCloseReason(phase));
      }
      return;
    }

    const lastText = readLastAssistantText(transcriptPath);
    if (lastText !== null && isAsking(lastText)) {
      blockOrWarn(RULE_ASKING, ASKING_REASON);
    }
  } catch (_error) {
    // Fail open so the guard can never trap the session.
  }
}

main();
