#!/usr/bin/env node

// Claude Code PreToolUse hook for Edit, Write, and NotebookEdit. It denies
// source-code changes larger than the configured limit (default: 10), while
// allowing invalid/failing input, configured file types, small edits, disabled
// projects, and a temporary override stored at
// <home>/.claude/state/allow-direct-edit. The limit comes from the nearest
// .claude/delegate-guard.json above payload.cwd, DELEGATE_GUARD_LIMIT, or the
// default. Invalid input fails open; internal failures fail open and append an
// error to <home>/.claude/state/delegate-guard.log when that log is writable.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const LIMIT = 10;
const TOOLS = new Set(['Edit', 'Write', 'NotebookEdit']);
const TEXT_EXTENSIONS = new Set([
  '.md',
  '.txt',
  '.json',
  '.jsonc',
  '.yaml',
  '.yml',
  '.toml',
  '.ini',
  '.cfg',
  '.csv',
]);
const TEXT_FILENAMES = new Set(['.gitignore', '.gitattributes']);
const MAX_PROJECT_CONFIG_LEVELS = 20;
const LOG_MAX_BYTES = 1024 * 1024;

function countLines(value) {
  if (typeof value !== 'string' || value === '') return 0;

  const normalized = value.replace(/\r\n/g, '\n');
  const parts = normalized.split('\n');
  if (parts[parts.length - 1] === '') parts.pop();
  return parts.length;
}

function fileNameOf(filePath) {
  const normalized = String(filePath).replace(/\\/g, '/');
  const parts = normalized.split('/');
  return parts[parts.length - 1] || '';
}

function isAllowedFileName(filePath) {
  const fileName = fileNameOf(filePath);
  if (TEXT_FILENAMES.has(fileName)) return true;

  const dot = fileName.lastIndexOf('.');
  if (dot <= 0) return false;
  return TEXT_EXTENSIONS.has(fileName.slice(dot).toLowerCase());
}

function hasValidOverride(homeDir) {
  try {
    const overridePath = path.join(
      homeDir,
      '.claude',
      'state',
      'allow-direct-edit'
    );
    if (!fs.existsSync(overridePath)) return false;

    const raw = fs.readFileSync(overridePath, 'utf8').trim();
    const expiresAtMs = /^\d+$/.test(raw)
      ? Number(raw) * 1000
      : Date.parse(raw);
    return Number.isFinite(expiresAtMs) && expiresAtMs > Date.now();
  } catch (_error) {
    return false;
  }
}

function isPositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function parseLimitEnv(value) {
  if (!value || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return isPositiveInteger(parsed) ? parsed : null;
}

function readProjectConfig(cwd, log) {
  if (typeof cwd !== 'string' || cwd === '') return {};

  let current = path.resolve(cwd);
  for (let level = 0; level < MAX_PROJECT_CONFIG_LEVELS; level += 1) {
    const configPath = path.join(current, '.claude', 'delegate-guard.json');
    let exists = false;
    try {
      exists = fs.existsSync(configPath) || fs.statSync(configPath).isFile();
    } catch (_error) {
      exists = false;
    }

    if (exists) {
      try {
        const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (!config || typeof config !== 'object' || Array.isArray(config)) {
          throw new Error('invalid project config');
        }
        if (
          ('enabled' in config && typeof config.enabled !== 'boolean') ||
          ('limit' in config && !isPositiveInteger(config.limit))
        ) {
          throw new Error('invalid project config fields');
        }
        return config;
      } catch (error) {
        log(
          'warn',
          `ignore invalid project config ${configPath}: ${
            error instanceof Error ? error.message : String(error)
          }`
        );
      }
    }

    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return {};
}

function makeLogger(homeDir) {
  return (level, message) => {
    try {
      const dir = path.join(homeDir, '.claude', 'state');
      fs.mkdirSync(dir, { recursive: true });
      const logPath = path.join(dir, 'delegate-guard.log');
      try {
        if (fs.statSync(logPath).size >= LOG_MAX_BYTES) {
          fs.writeFileSync(logPath, '');
        }
      } catch (_error) {
        // A missing log is created by the append below.
      }
      fs.appendFileSync(logPath, `${new Date().toISOString()} ${level} ${message}\n`);
    } catch (_error) {
      // Logging must never change the hook's fail-open behavior.
    }
  };
}

function main() {
  let parsedInput = false;
  let input;
  let payload;
  try {
    input = fs.readFileSync(0, 'utf8');
    payload = JSON.parse(input);
    parsedInput = true;
    if (!TOOLS.has(payload.tool_name)) return;

    const toolInput = payload.tool_input;
    if (!toolInput || typeof toolInput !== 'object') return;

    const filePath =
      payload.tool_name === 'NotebookEdit'
        ? toolInput.notebook_path
        : toolInput.file_path;
    if (typeof filePath !== 'string' || filePath === '') return;

    const homeDir = process.env.DELEGATE_GUARD_HOME || os.homedir();
    const log = makeLogger(homeDir);
    if (hasValidOverride(homeDir)) return;

    const projectConfig = readProjectConfig(payload.cwd, log);
    if (projectConfig.enabled === false) return;

    if (isAllowedFileName(filePath)) return;

    let lineCount;
    if (payload.tool_name === 'Edit') {
      lineCount = Math.max(
        countLines(toolInput.old_string),
        countLines(toolInput.new_string)
      );
    } else if (payload.tool_name === 'Write') {
      lineCount = countLines(toolInput.content);
    } else {
      lineCount = countLines(toolInput.new_source);
    }

    const limit =
      typeof projectConfig.limit === 'number'
        ? projectConfig.limit
        : parseLimitEnv(process.env.DELEGATE_GUARD_LIMIT) || LIMIT;
    if (lineCount <= limit) return;

    const reason =
      process.env.DELEGATE_GUARD_LANG === 'en'
        ? `${payload.tool_name} change to source file ${fileNameOf(
            filePath
          )} counts as ${lineCount} lines, exceeding the limit of ${limit} lines; ` +
          `source changes over ${limit} lines should be written as a Brief for a codex worker ` +
          `(see the Opus / codex division in global CLAUDE.md); an exception may only be enabled with explicit user authorization.`
        : `${payload.tool_name} 对源码文件 ${fileNameOf(filePath)} 的修改计算为 ${lineCount} 行，` +
          `超过阈值 ${limit} 行；超过 ${limit} 行的源码修改按规则应写 Brief 交给 codex worker` +
          `（见全局 CLAUDE.md 的 Opus / codex 分工）；只有用户明确授权时才可开例外。`;
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: reason,
        },
      }) + '\n'
    );
  } catch (error) {
    // Fail open so the guard cannot block a Claude Code session.
    if (parsedInput) {
      makeLogger(process.env.DELEGATE_GUARD_HOME || os.homedir())(
        'error',
        `delegate-guard failed open: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }
}

main();
