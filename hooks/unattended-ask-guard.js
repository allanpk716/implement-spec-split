#!/usr/bin/env node

// Claude Code 的 AskUserQuestion PreToolUse hook。
// 会话最近一次 /implement-spec-split 调用带 --auto-land 时拒绝提问：
// 无人值守的 Run 里没人会来答，提示模型改走自动拍板或停车报告。
// 判定依据是 transcript 里的斜杠命令，不依赖环境变量或模型自觉。

'use strict';

const fs = require('fs');
const { readLastCommandArgs, hasAutoLandFlag } = require('./lib-transcript');

const TOOL_NAME = 'AskUserQuestion';
const DISABLE_ENV = 'UNATTENDED_ASK_GUARD_DISABLE';
const DENY_REASON =
  '无人值守 Run（--auto-land）不能问人，没人会来答。' +
  'Opus 审查『需要人取舍』的条目按 SKILL.md 处理、不停车：『可自动采纳：是』且有推荐的按推荐做；' +
  '『可自动采纳：否』或『推荐：无』的按可逆性规则自选一个可逆选项并写理由；' +
  '两者都记进落地报告的『### 自动拍板（可推翻）』；' +
  '合并冲突按 SKILL.md 交 merger 处理并经 Opus 审查；' +
  '只有需要本人身份或凭据（停车类别 auth）、或列出的选项里没有可逆的（停车类别 error）' +
  '才按 SKILL.md 写停车报告（## 停车报告 / ### 需要你决定）后停车。' +
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
