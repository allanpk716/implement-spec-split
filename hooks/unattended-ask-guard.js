#!/usr/bin/env node

// Claude Code 的 AskUserQuestion PreToolUse hook。
// 会话最近一次 /implement-spec-split 调用带 --auto-land 时拒绝提问：
// 无人值守的 Run 里没人会来答，提示模型改走自动拍板或停车报告。
// 判定依据是 transcript 里的斜杠命令，不依赖环境变量或模型自觉。

'use strict';

const fs = require('fs');
const { readLastCommandArgs } = require('./lib-transcript');

const TOOL_NAME = 'AskUserQuestion';
const DISABLE_ENV = 'UNATTENDED_ASK_GUARD_DISABLE';
const AUTO_LAND_FLAG = '--auto-land';
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
