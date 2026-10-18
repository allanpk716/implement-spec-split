#!/usr/bin/env node

// Claude Code PreToolUse hook for Edit, Write, and NotebookEdit. It denies
// source-code changes larger than 10 lines, while allowing invalid/failing
// input, configured file types, small edits, and a temporary override stored
// at <home>/.claude/state/allow-direct-edit. Input is hook JSON on stdin; a
// denial outputs hookSpecificOutput JSON and exit code 0, while permission
// output is omitted when the tool call is allowed.

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

function main() {
  let input;
  let payload;
  try {
    input = fs.readFileSync(0, 'utf8');
    payload = JSON.parse(input);
    if (!TOOLS.has(payload.tool_name)) return;

    const toolInput = payload.tool_input;
    if (!toolInput || typeof toolInput !== 'object') return;

    const filePath =
      payload.tool_name === 'NotebookEdit'
        ? toolInput.notebook_path
        : toolInput.file_path;
    if (typeof filePath !== 'string' || filePath === '') return;

    const homeDir = process.env.DELEGATE_GUARD_HOME || os.homedir();
    if (hasValidOverride(homeDir)) return;
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

    if (lineCount <= LIMIT) return;

    const reason =
      `${payload.tool_name} 对源码文件 ${fileNameOf(filePath)} 的修改计算为 ${lineCount} 行，` +
      `超过阈值 10 行；超过 10 行的源码修改按规则应写 Brief 交给 codex worker` +
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
  } catch (_error) {
    // Fail open so the guard cannot block a Claude Code session.
  }
}

main();
