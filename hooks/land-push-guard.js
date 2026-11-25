#!/usr/bin/env node

// Claude Code PreToolUse hook for Bash.
//
// In a session whose transcript contains an /implement-spec-split command call,
// any `git push` whose destination is the repository's default branch is denied
// unless this session owns the repo-scoped `land` lock. The lock is the same
// mkdir lock scripts/lock.sh uses. Ownership is the pid of the nearest `claude`
// ancestor process (plus its recorded start time), so a lock held by another
// Run does not satisfy the check.
//
// Fail open: a missing transcript, a missing claude ancestor, or any internal
// error allows the push. LAND_PUSH_GUARD_DISABLE=1 disables the hook entirely.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const {
  tokenizeShell,
  withoutHeredocBody,
  isCommandSeparator,
  isRedirectionToken,
  baseNameOf,
  forEachCommandPosition,
} = require('./lib-shell');
const { hasCommandInvocation } = require('./lib-transcript');

const TOOL_NAME = 'Bash';
const DISABLE_ENV = 'LAND_PUSH_GUARD_DISABLE';
// Test-only injection of the session's claude pid, mirroring ISS_OWNER_PID in
// scripts/lib-owner.sh. Production walks the parent chain to find the nearest
// process whose basename is `claude`; tests set this to control the answer.
const OWNER_PID_ENV = 'LAND_PUSH_GUARD_OWNER_PID';
const SKILL_DIR = path.resolve(__dirname, '..');
const LOCK_NAME = 'land';
const FALLBACK_DEFAULT_BRANCHES = ['main', 'master'];
const MAX_PARENT_VISITS = 1000;

const DENY_REASON =
  '落地 push 必须先持有本仓库的 land 锁：先单独运行 `' +
  `${SKILL_DIR}/scripts/lock.sh acquire land --scope repo` +
  '`（不要包 echo 或 `|| true`），确认退出码 0 后再 push；' +
  '退出码 2 表示别的 Run 正持锁，按 SKILL.md 继续等，不要绕过。';

const GIT_GLOBAL_VALUE_OPTIONS = new Set([
  '-c',
  '--git-dir',
  '--work-tree',
  '--namespace',
  '--exec-path',
  '--super-prefix',
  '--config-env',
]);

const PUSH_VALUE_OPTIONS = new Set([
  '--repo',
  '--push-option',
  '-o',
  '--receive-pack',
  '--exec',
  '--url',
  '--remote',
]);

const PUSH_ALL_FLAGS = new Set(['--all', '--branches', '--mirror']);

const defaultBranchCache = new Map();
const currentBranchCache = new Map();
const remoteNamesCache = new Map();

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    }) + '\n'
  );
}

function note(message) {
  process.stderr.write(`land-push-guard: ${message}\n`);
}

function run(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    ...options,
  });
  if (result.error || result.status !== 0) return null;
  return result.stdout;
}

function psValue(args) {
  const output = run('ps', args);
  return output === null ? null : output.trim();
}

function gitValue(dir, args) {
  const output = run('git', ['-C', dir, ...args]);
  return output === null ? null : output.trim();
}

function cached(cache, key, produce) {
  if (!cache.has(key)) cache.set(key, produce(key));
  return cache.get(key);
}

function defaultBranches(dir) {
  const value = gitValue(dir, [
    'symbolic-ref',
    '--short',
    'refs/remotes/origin/HEAD',
  ]);
  if (value !== null && value !== '') {
    const name = value
      .replace(/^refs\/remotes\/origin\//, '')
      .replace(/^origin\//, '');
    if (name !== '') return new Set([name]);
  }
  return new Set(FALLBACK_DEFAULT_BRANCHES);
}

function cachedDefaultBranches(dir) {
  return cached(defaultBranchCache, dir, defaultBranches);
}

function currentBranch(dir) {
  const value = gitValue(dir, ['symbolic-ref', '--short', 'HEAD']);
  if (value === null || value === '') return null;
  return value.replace(/^refs\/heads\//, '');
}

function cachedCurrentBranch(dir) {
  return cached(currentBranchCache, dir, currentBranch);
}

function remoteNames(dir) {
  const output = gitValue(dir, ['remote']);
  if (output === null) return new Set();
  return new Set(
    output
      .split('\n')
      .map(name => name.trim())
      .filter(name => name !== '')
  );
}

function isRemote(dir, name) {
  return cached(remoteNamesCache, dir, remoteNames).has(name);
}

function gitCommonDir(dir) {
  const value = gitValue(dir, ['rev-parse', '--git-common-dir']);
  if (value === null || value === '') return null;
  return path.isAbsolute(value) ? value : path.resolve(dir, value);
}

function pidStartFor(pid) {
  const custom = process.env.ISS_PS_LSTART_CMD;
  try {
    if (typeof custom === 'string' && custom !== '') {
      const output = run(custom, [String(pid)]);
      return output === null ? '' : output.trim();
    }
    const script = path.join(SKILL_DIR, 'scripts', 'pid-start.sh');
    const output = run('bash', [script, String(pid)]);
    return output === null ? '' : output.trim();
  } catch (_error) {
    return '';
  }
}

function resolveOwnerPid() {
  const injected = process.env[OWNER_PID_ENV];
  if (typeof injected === 'string' && injected !== '') {
    return /^[1-9][0-9]*$/.test(injected) ? Number(injected) : null;
  }

  let pid = process.pid;
  for (let visited = 0; visited < MAX_PARENT_VISITS; visited += 1) {
    const comm = psValue(['-o', 'comm=', '-p', String(pid)]);
    if (comm !== null && baseNameOf(comm) === 'claude') return pid;

    const parentValue = psValue(['-o', 'ppid=', '-p', String(pid)]);
    if (parentValue === null) break;
    const parent = Number(parentValue);
    if (!Number.isSafeInteger(parent) || parent <= 0 || parent === pid) break;
    pid = parent;
  }
  return null;
}

function ownsLandLock(dir, ownerPid) {
  const commonDir = gitCommonDir(dir);
  if (commonDir === null) return false;

  const ownerPath = path.join(
    commonDir,
    'implement-spec-split',
    'locks',
    `${LOCK_NAME}.lock`,
    'owner.json'
  );

  let owner;
  try {
    owner = JSON.parse(fs.readFileSync(ownerPath, 'utf8'));
  } catch (_error) {
    return false;
  }
  if (owner === null || typeof owner !== 'object' || Array.isArray(owner)) {
    return false;
  }

  const recordedPid = Number(owner.pid);
  if (!Number.isSafeInteger(recordedPid) || recordedPid !== ownerPid) {
    return false;
  }

  const recordedStart =
    typeof owner.pid_start === 'string' ? owner.pid_start.trim() : '';
  if (recordedStart === '') return true;

  const currentStart = pidStartFor(ownerPid);
  if (currentStart === '') {
    note(`cannot read the start time of pid ${ownerPid}; allowing the push`);
    return true;
  }
  return currentStart === recordedStart;
}

function splitOption(text) {
  const equals = text.indexOf('=');
  if (equals === -1) return { name: text, inline: false };
  return { name: text.slice(0, equals), inline: true };
}

// Return the index just after a redirection construct starting at `index`.
// Handles `> target`, `>> target`, `< target`, `<< target`, `2> target`, and
// the combined `>&1` / `2>&1` forms, which the tokenizer splits into `>` `&` `1`.
function redirectionEnd(tokens, index, argsEnd) {
  let next = index + 1;
  if (
    next + 1 < argsEnd &&
    !tokens[next].quoted &&
    tokens[next].text === '&' &&
    /^(?:-|\d+)$/.test(tokens[next + 1].text)
  ) {
    return next + 2;
  }
  if (next < argsEnd) {
    const target = tokens[next];
    if (
      !isCommandSeparator(target) &&
      !isRedirectionToken(target) &&
      !target.text.startsWith('&')
    ) {
      return next + 1;
    }
  }
  return next;
}

// True for a digit that is the file-descriptor prefix of an adjacent
// redirection, e.g. the `2` in `2>log` or `2>&1`.
function isFdPrefix(tokens, index, argsEnd) {
  const token = tokens[index];
  return (
    !token.quoted &&
    /^\d+$/.test(token.text) &&
    index + 1 < argsEnd &&
    isRedirectionToken(tokens[index + 1]) &&
    tokens[index + 1].startsAt === token.endsAt + 1
  );
}

// Remove redirection constructs from a token list so they cannot hide a
// command or end a command segment early (the tokenizer splits `2>&1` into
// `2` `>` `&` `1`, and the `&` would otherwise look like a separator).
function stripRedirections(tokens) {
  const result = [];
  let index = 0;
  while (index < tokens.length) {
    if (isRedirectionToken(tokens[index])) {
      index = redirectionEnd(tokens, index, tokens.length);
      continue;
    }
    if (isFdPrefix(tokens, index, tokens.length)) {
      index = redirectionEnd(tokens, index + 1, tokens.length);
      continue;
    }
    result.push(tokens[index]);
    index += 1;
  }
  return result;
}

function expandTilde(text, token) {
  if (token && token.quoted) return text;
  if (text === '~') return os.homedir();
  if (text.startsWith('~/')) {
    return path.join(os.homedir(), text.slice(2));
  }
  return text;
}

// The tokenizer does not expand shell variables. When a path contains `$` or a
// backtick, resolving it would produce a bogus directory, so treat it as
// unknown and fall back to the payload cwd (as the Brief allows).
function isDynamicPath(value) {
  return value.includes('$') || value.includes('`');
}

// Parse `git [global options] push [push options] [repository] [refspec...]`.
// Returns null when the command is not a git push.
function parseGitInvocation(tokens, argsStart, argsEnd) {
  let index = argsStart;
  let repoDirOption = null;
  let subcommand = null;
  let sawDoubleDash = false;

  while (index < argsEnd) {
    const token = tokens[index];
    if (isCommandSeparator(token)) return null;

    if (isRedirectionToken(token)) {
      index = redirectionEnd(tokens, index, argsEnd);
      continue;
    }
    if (isFdPrefix(tokens, index, argsEnd)) {
      index = redirectionEnd(tokens, index + 1, argsEnd);
      continue;
    }

    if (!token.quoted && token.text === '--' && !sawDoubleDash) {
      sawDoubleDash = true;
      index += 1;
      continue;
    }

    if (!sawDoubleDash && !token.quoted && token.text.startsWith('-')) {
      if (token.text === '-C' || token.text.startsWith('-C')) {
        if (token.text.length > 2) {
          const value = expandTilde(token.text.slice(2), token);
          repoDirOption = isDynamicPath(value) ? null : value;
        } else if (
          index + 1 < argsEnd &&
          !isCommandSeparator(tokens[index + 1])
        ) {
          const value = expandTilde(
            tokens[index + 1].text,
            tokens[index + 1]
          );
          repoDirOption = isDynamicPath(value) ? null : value;
          index += 1;
        }
        index += 1;
        continue;
      }

      const { name, inline } = splitOption(token.text);
      if (!inline && GIT_GLOBAL_VALUE_OPTIONS.has(name)) {
        index += 1;
        if (index < argsEnd && !isCommandSeparator(tokens[index])) {
          index += 1;
        }
        continue;
      }
      index += 1;
      continue;
    }

    subcommand = token.text;
    index += 1;
    break;
  }

  if (subcommand !== 'push') return null;
  return parsePush(tokens, index, argsEnd, repoDirOption);
}

function parsePush(tokens, argsStart, argsEnd, repoDirOption) {
  let index = argsStart;
  let sawDoubleDash = false;
  let tags = false;
  let all = false;
  const operands = [];

  while (index < argsEnd) {
    const token = tokens[index];
    if (isCommandSeparator(token)) break;

    if (isRedirectionToken(token)) {
      index = redirectionEnd(tokens, index, argsEnd);
      continue;
    }
    if (isFdPrefix(tokens, index, argsEnd)) {
      index = redirectionEnd(tokens, index + 1, argsEnd);
      continue;
    }

    if (!token.quoted && token.text === '--' && !sawDoubleDash) {
      sawDoubleDash = true;
      index += 1;
      continue;
    }

    if (!sawDoubleDash && !token.quoted && token.text.startsWith('-')) {
      const { name, inline } = splitOption(token.text);
      if (name === '--tags') {
        tags = true;
        index += 1;
        continue;
      }
      if (PUSH_ALL_FLAGS.has(name)) {
        all = true;
        index += 1;
        continue;
      }
      if (!inline && PUSH_VALUE_OPTIONS.has(name)) {
        index += 1;
        if (index < argsEnd && !isCommandSeparator(tokens[index])) {
          index += 1;
        }
        continue;
      }
      index += 1;
      continue;
    }

    operands.push(token.text);
    index += 1;
  }

  return { repoDirOption, tags, all, operands };
}

function stripBranchPrefix(name) {
  return name.replace(/^refs\/heads\//, '');
}

function refspecTargetsDefault(refspec, dir, defaults) {
  const cleaned = refspec.startsWith('+') ? refspec.slice(1) : refspec;
  // A lone ":" is a matching push and may include the default branch.
  if (cleaned === ':') return true;

  const colon = cleaned.indexOf(':');
  const dst = colon === -1 ? cleaned : cleaned.slice(colon + 1);
  if (dst === '') return false;
  if (dst === 'HEAD' || dst === '@') {
    const branch = cachedCurrentBranch(dir);
    return branch !== null && defaults.has(branch);
  }
  return defaults.has(stripBranchPrefix(dst));
}

function refspecsOf(push, dir) {
  const operands = push.operands;
  if (operands.length === 0) return [];
  if (operands.length === 1 && isRemote(dir, operands[0])) return [];
  if (operands.length === 1 && looksLikeRepository(operands[0])) {
    return [];
  }
  if (operands.length === 1) return operands;
  return operands.slice(1);
}

// A single push operand can be a repository (URL or path) rather than a
// refspec. Git decides by remote configuration first; these shapes are the
// unambiguous remainder.
function looksLikeRepository(value) {
  return (
    value.includes('://') ||
    value.endsWith('.git') ||
    value.startsWith('/') ||
    value.startsWith('./') ||
    value.startsWith('../') ||
    value.startsWith('~/')
  );
}

function pushTargetsDefault(push) {
  if (push.all) return true;

  const dir = push.dir;
  const refspecs = refspecsOf(push, dir);
  if (refspecs.length === 0) {
    // `git push --tags` (with or without a repository) pushes tags only.
    if (push.tags) return false;
    const branch = cachedCurrentBranch(dir);
    const defaults = cachedDefaultBranches(dir);
    return branch !== null && defaults.has(branch);
  }

  const defaults = cachedDefaultBranches(dir);
  for (const refspec of refspecs) {
    if (refspecTargetsDefault(refspec, dir, defaults)) return true;
  }
  return false;
}

function commandNameOf(value) {
  const base = baseNameOf(value).toLowerCase();
  return base.endsWith('.exe') ? base.slice(0, -4) : base;
}

function cdTarget(tokens, argsStart, argsEnd) {
  let sawDoubleDash = false;
  for (let index = argsStart; index < argsEnd; index += 1) {
    const token = tokens[index];
    if (isCommandSeparator(token)) return null;
    if (isRedirectionToken(token)) {
      index += 1;
      continue;
    }
    if (!token.quoted && token.text === '--' && !sawDoubleDash) {
      sawDoubleDash = true;
      continue;
    }
    if (
      !sawDoubleDash &&
      !token.quoted &&
      token.text.startsWith('-') &&
      token.text !== '-'
    ) {
      continue;
    }
    // `cd -` goes to the previous directory, which we cannot know.
    if (!token.quoted && token.text === '-') return null;
    if (isDynamicPath(token.text)) return null;
    return expandTilde(token.text, token);
  }
  return os.homedir();
}

function resolveDir(base, target) {
  const root = typeof base === 'string' && base !== '' ? base : process.cwd();
  if (typeof target !== 'string' || target === '') return root;
  return path.resolve(root, target);
}

function findPushes(command, payloadCwd) {
  const tokens = stripRedirections(
    withoutHeredocBody(tokenizeShell(command))
  );
  const pushes = [];
  let cwd =
    typeof payloadCwd === 'string' && payloadCwd !== ''
      ? payloadCwd
      : process.cwd();

  forEachCommandPosition(tokens, (commandToken, argsStart, argsEnd) => {
    const name = commandNameOf(commandToken.text);

    if (name === 'git') {
      const push = parseGitInvocation(tokens, argsStart, argsEnd);
      if (push !== null) {
        push.dir = resolveDir(cwd, push.repoDirOption);
        pushes.push(push);
      }
      return true;
    }

    if (name === 'cd') {
      const separator = tokens[argsEnd];
      const applies =
        separator === undefined ||
        (!separator.quoted &&
          (separator.text === '&&' ||
            separator.text === ';' ||
            separator.text === '\n'));
      if (applies) {
        const target = cdTarget(tokens, argsStart, argsEnd);
        if (target !== null) cwd = resolveDir(cwd, target);
      }
      return true;
    }

    return true;
  });

  return pushes;
}

function main() {
  try {
    if (process.env[DISABLE_ENV] === '1') return;

    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (payload.tool_name !== TOOL_NAME) return;

    const toolInput = payload.tool_input;
    if (toolInput === null || typeof toolInput !== 'object') return;
    const command = toolInput.command;
    if (typeof command !== 'string' || command === '') return;

    const transcriptPath = payload.transcript_path;
    if (typeof transcriptPath !== 'string' || transcriptPath === '') return;
    if (!hasCommandInvocation(transcriptPath)) return;

    const pushes = findPushes(command, payload.cwd);
    if (pushes.length === 0) return;

    const targets = pushes.filter(push => pushTargetsDefault(push));
    if (targets.length === 0) return;

    const ownerPid = resolveOwnerPid();
    if (ownerPid === null) {
      note('no claude ancestor process found; allowing the push');
      return;
    }

    for (const push of targets) {
      if (!ownsLandLock(push.dir, ownerPid)) {
        deny(DENY_REASON);
        return;
      }
    }
  } catch (_error) {
    // Fail open so the guard can never block the session.
  }
}

main();
