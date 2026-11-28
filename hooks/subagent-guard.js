#!/usr/bin/env node

// Claude Code PreToolUse hook for the Agent tool. In a flash orchestrator
// session's main thread (FLASH_ORCHESTRATOR=1, payload without a non-empty
// agent_id) it denies spawning a subagent, so that implementation and review
// go through the dispatch module (scripts/stage-dispatch.sh) on the Stage
// route table instead of an in-session subagent. Read-only subagents are
// allowed; see the whitelist below. Invalid JSON and internal failures fail
// open (a missing tool_input is neither: its subagent_type reads as empty and
// is denied, see below).

'use strict';

const fs = require('fs');

// Agent is the current subagent tool; Task is its name in older versions.
const TOOLS = new Set(['Agent', 'Task']);
// Read-only subagents stay available in a flash session: searching code and
// reading plans never writes source, so they do not bypass the route table.
const READ_ONLY_TYPES = new Set(['Explore', 'Plan', 'claude-code-guide']);
const DENY_REASON =
  'flash 会话不派会写代码的子代理：实现、fix、冲突解算经派发模块按「实现」路由派发' +
  '（`<skill dir>/scripts/stage-dispatch.sh dispatch --stage implementation --brief <file>`，见 SKILL.md），' +
  '审查走 `scripts/opus-review.sh`。只读子代理（Explore、Plan、claude-code-guide）照常可用。';

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
    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (!TOOLS.has(payload.tool_name)) return;
    if (process.env.FLASH_ORCHESTRATOR !== '1') return;

    // Subagents inherit FLASH_ORCHESTRATOR=1 but their payloads carry agent_id;
    // only the main thread is held to the dispatch module.
    const isSubagent =
      typeof payload.agent_id === 'string' && payload.agent_id !== '';
    if (isSubagent) return;

    const toolInput = payload.tool_input;
    const rawType =
      toolInput && typeof toolInput === 'object' ? toolInput.subagent_type : '';
    // A missing subagent_type defaults to general-purpose, which writes code:
    // the whitelist fails closed.
    const subagentType = typeof rawType === 'string' ? rawType : '';
    if (READ_ONLY_TYPES.has(subagentType)) return;

    deny(DENY_REASON);
  } catch (_error) {
    // Fail open so the guard can never block the session.
  }
}

main();
