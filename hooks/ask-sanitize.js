#!/usr/bin/env node

// Claude Code 的 AskUserQuestion PreToolUse hook。
// 删除 glm-5.3-flash 生成输入中的回车符，避免终端提问框渲染错乱。

'use strict';

const fs = require('fs');

const TOOL_NAME = 'AskUserQuestion';

function sanitizeValue(value, sanitizeStrings) {
  if (typeof value === 'string') {
    const sanitized = value.replace(/\r\n/g, '\n').replace(/\r/g, '');
    if (sanitized !== value) sanitizeStrings.changed = true;
    return sanitized;
  }

  if (Array.isArray(value)) {
    return value.map(item => sanitizeValue(item, sanitizeStrings));
  }

  if (value !== null && typeof value === 'object') {
    const sanitized = {};
    for (const key of Object.keys(value)) {
      sanitized[key] = sanitizeValue(value[key], sanitizeStrings);
    }
    return sanitized;
  }

  return value;
}

function main() {
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (payload.tool_name !== TOOL_NAME) return;

    const toolInput = payload.tool_input;
    if (toolInput === null || typeof toolInput !== 'object') return;

    const sanitizeStrings = { changed: false };
    const updatedInput = sanitizeValue(toolInput, sanitizeStrings);
    if (!sanitizeStrings.changed) return;

    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'ask',
          updatedInput,
        },
      }) + '\n'
    );
  } catch (_error) {
    // Fail open so sanitization can never block the session.
  }
}

main();
