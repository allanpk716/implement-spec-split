#!/usr/bin/env node

// Claude Code 的 AskUserQuestion PreToolUse hook。
// 会话最近一次 /implement-spec-split 调用带 --auto-land 时拒绝提问：
// 无人值守的 Run 里没人会来答，提示模型改走自动拍板或停车报告。
// 判定依据是 transcript 里的斜杠命令，不依赖环境变量或模型自觉。

'use strict';

const fs = require('fs');
const { StringDecoder } = require('string_decoder');

const TOOL_NAME = 'AskUserQuestion';
const DISABLE_ENV = 'UNATTENDED_ASK_GUARD_DISABLE';
const COMMAND_NAME = '/implement-spec-split';
const COMMAND_NAME_TAG = `<command-name>${COMMAND_NAME}</command-name>`;
const COMMAND_MARKER = `${COMMAND_NAME}</command-name>`;
const AUTO_LAND_FLAG = '--auto-land';
const CHUNK_SIZE = 1024 * 1024;
const DENY_REASON =
  '无人值守 Run（--auto-land）不能问人，没人会来答。' +
  'Opus 标了『可自动采纳：是』且有推荐的取舍，按推荐做并记进落地报告的『### 自动拍板（可推翻）』；' +
  '合并冲突按 SKILL.md 交 merger 处理并经 Opus 审查；' +
  '其余真要人决定的事按 SKILL.md 写停车报告（## 停车报告 / ### 需要你决定）后停车。' +
  '不要再调用 AskUserQuestion。';

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

// 从一行 transcript 里取出 /implement-spec-split 的 <command-args>。
// 不是这类调用、或 JSON 坏掉时返回 null。
function commandArgsFromLine(line) {
  if (!line.includes(COMMAND_MARKER)) return null;

  let entry;
  try {
    entry = JSON.parse(line);
  } catch (_error) {
    return null;
  }
  if (entry === null || typeof entry !== 'object') return null;
  if (entry.type !== 'user') return null;

  const message = entry.message;
  if (message === null || typeof message !== 'object') return null;

  const content = message.content;
  let text;
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    const parts = [];
    for (const item of content) {
      if (
        item !== null &&
        typeof item === 'object' &&
        item.type === 'text' &&
        typeof item.text === 'string'
      ) {
        parts.push(item.text);
      }
    }
    text = parts.join('\n');
  } else {
    return null;
  }

  if (!text.includes(COMMAND_NAME_TAG)) return null;
  const match = text.match(/<command-args>([\s\S]*?)<\/command-args>/);
  if (match === null) return null;
  return match[1];
}

// 按块读取 JSONL，只对包含 /implement-spec-split</command-name> 的行做
// JSON 解析，返回最后一次调用的 <command-args>；没有这类调用返回 null。
function readLastCommandArgs(transcriptPath) {
  let fileDescriptor;
  try {
    fileDescriptor = fs.openSync(transcriptPath, 'r');
  } catch (_error) {
    return null;
  }

  const buffer = Buffer.alloc(CHUNK_SIZE);
  const decoder = new StringDecoder('utf8');
  let remainder = '';
  let lastArgs = null;

  const consume = data => {
    const lines = (remainder + data).split('\n');
    remainder = lines.pop();
    for (const line of lines) {
      const args = commandArgsFromLine(line);
      if (args !== null) lastArgs = args;
    }
  };

  try {
    let bytesRead;
    while ((bytesRead = fs.readSync(fileDescriptor, buffer, 0, CHUNK_SIZE, null)) > 0) {
      consume(decoder.write(buffer.subarray(0, bytesRead)));
    }
    const tail = decoder.end();
    if (tail !== '') remainder += tail;
    if (remainder !== '') {
      const args = commandArgsFromLine(remainder);
      if (args !== null) lastArgs = args;
    }
  } finally {
    fs.closeSync(fileDescriptor);
  }

  return lastArgs;
}

function hasAutoLandFlag(args) {
  if (typeof args !== 'string') return false;
  return args.split(/\s+/).some(token => token === AUTO_LAND_FLAG);
}

function main() {
  try {
    if (process.env[DISABLE_ENV] === '1') return;

    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (payload.tool_name !== TOOL_NAME) return;

    const transcriptPath = payload.transcript_path;
    if (typeof transcriptPath !== 'string' || transcriptPath === '') return;

    const args = readLastCommandArgs(transcriptPath);
    if (args === null) return;
    if (!hasAutoLandFlag(args)) return;

    deny(DENY_REASON);
  } catch (_error) {
    // Fail open so the guard can never block the session.
  }
}

main();
