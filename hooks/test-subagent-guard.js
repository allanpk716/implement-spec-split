'use strict';

// A flash orchestrator session exports FLASH_ORCHESTRATOR=1, which switches
// subagent-guard.js into flash mode. Only the flash mode cases below set the
// variable; every other case runs as an ordinary session, whatever session
// started this test.
delete process.env.FLASH_ORCHESTRATOR;

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const hookPath = path.join(__dirname, 'subagent-guard.js');
let passed = 0;
let failed = 0;

function runHook(stdin, extraEnv = {}) {
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env: { ...process.env, ...extraEnv },
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function hookPayload(toolName, toolInput, extraPayload = {}) {
  return JSON.stringify({
    session_id: 'test-session',
    transcript_path: 'test-transcript',
    cwd: process.cwd(),
    hook_event_name: 'PreToolUse',
    tool_name: toolName,
    tool_input: toolInput,
    ...extraPayload,
  });
}

function agentToolInput(subagentType) {
  return {
    description: 'Implement ticket #1',
    prompt: 'Implement ticket #1 in this worktree.',
    subagent_type: subagentType,
  };
}

function agentPayload(subagentType, extraPayload = {}) {
  return hookPayload('Agent', agentToolInput(subagentType), extraPayload);
}

function parseDeny(result) {
  assert.strictEqual(result.status, 0);
  assert.notStrictEqual(result.stdout, '');
  const output = JSON.parse(result.stdout);
  assert.strictEqual(output.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(
    output.hookSpecificOutput.permissionDecision,
    'deny'
  );
  return output.hookSpecificOutput.permissionDecisionReason;
}

function assertAllow(result) {
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stdout, '');
}

function testCase(name, run) {
  try {
    run();
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(error && error.stack ? error.stack : error);
  }
}

testCase('flash mode main thread spawning general-purpose denies', () => {
  const reason = parseDeny(
    runHook(agentPayload('general-purpose'), { FLASH_ORCHESTRATOR: '1' })
  );
  assert.match(reason, /flash 会话不派会写代码的子代理/);
  assert.match(reason, /stage-dispatch\.sh dispatch --stage implementation/);
  assert.match(reason, /opus-review\.sh/);
  assert.match(reason, /Explore、Plan、claude-code-guide/);
});

testCase('flash mode main thread spawning read-only subagents allows', () => {
  for (const subagentType of ['Explore', 'Plan', 'claude-code-guide']) {
    assertAllow(runHook(agentPayload(subagentType), { FLASH_ORCHESTRATOR: '1' }));
  }
});

testCase('flash mode main thread whitelist is exact and case-sensitive', () => {
  // A custom agent named like a built-in read-only one is not that agent.
  for (const subagentType of [
    'explore',
    'Explore ',
    'general-purpose',
    'statusline-setup:setup',
  ]) {
    parseDeny(runHook(agentPayload(subagentType), { FLASH_ORCHESTRATOR: '1' }));
  }
});

testCase('flash mode main thread without subagent_type denies', () => {
  // Claude Code defaults a missing subagent_type to general-purpose, which
  // can write code; a whitelist must fail closed.
  parseDeny(
    runHook(
      hookPayload('Agent', {
        description: 'Implement ticket #1',
        prompt: 'Implement ticket #1 in this worktree.',
      }),
      { FLASH_ORCHESTRATOR: '1' }
    )
  );
  parseDeny(
    runHook(hookPayload('Agent', agentToolInput('')), {
      FLASH_ORCHESTRATOR: '1',
    })
  );
});

testCase('flash mode main thread without tool_input denies', () => {
  // A payload with no tool_input (or a null one) is the missing subagent_type
  // case again: it reads as the general-purpose default, not as fail-open.
  parseDeny(
    runHook(hookPayload('Agent', undefined), { FLASH_ORCHESTRATOR: '1' })
  );
  parseDeny(runHook(hookPayload('Agent', null), { FLASH_ORCHESTRATOR: '1' }));
});

testCase('flash mode empty agent_id still denies', () => {
  // An empty agent_id is not a subagent; same rule as delegate-guard.
  parseDeny(
    runHook(agentPayload('general-purpose', { agent_id: '' }), {
      FLASH_ORCHESTRATOR: '1',
    })
  );
});

testCase('flash mode ignores other tools', () => {
  for (const [toolName, toolInput] of [
    ['Bash', { command: 'node -v' }],
    ['Write', { file_path: 'C:/WorkSpace/x/docs/a.md', content: 'x' }],
    ['AskUserQuestion', { questions: [] }],
  ]) {
    assertAllow(
      runHook(hookPayload(toolName, toolInput), { FLASH_ORCHESTRATOR: '1' })
    );
  }
});

testCase('FLASH_ORCHESTRATOR other than 1 allows', () => {
  assertAllow(
    runHook(agentPayload('general-purpose'), { FLASH_ORCHESTRATOR: 'true' })
  );
  assertAllow(
    runHook(agentPayload('general-purpose'), { FLASH_ORCHESTRATOR: '0' })
  );
});

testCase('invalid JSON allows with no output', () => {
  assertAllow(runHook('{invalid', { FLASH_ORCHESTRATOR: '1' }));
});

testCase('internal exception fails open with no output', () => {
  // Make stdout.write throw inside the deny path: the hook must still exit 0
  // without a decision rather than crash the tool call.
  const fixture = path.join(os.tmpdir(), `subagent-guard-throw-${process.pid}.js`);
  fs.writeFileSync(
    fixture,
    'process.stdout.write = () => { throw new Error("test stdout failure"); };'
  );
  try {
    assertAllow(
      runHook(agentPayload('general-purpose'), {
        FLASH_ORCHESTRATOR: '1',
        NODE_OPTIONS: `--require ${fixture}`,
      })
    );
  } finally {
    fs.rmSync(fixture, { force: true });
  }
});

testCase('flash mode subagent spawning a subagent allows', () => {
  // A subagent inherits FLASH_ORCHESTRATOR=1 but its payloads carry agent_id;
  // only the main thread is held to the dispatch module.
  assertAllow(
    runHook(
      agentPayload('general-purpose', {
        agent_id: 'impl-t1',
        agent_type: 'general-purpose',
      }),
      { FLASH_ORCHESTRATOR: '1' }
    )
  );
});

testCase('non-flash session spawning general-purpose allows', () => {
  // Official subscription and other ordinary sessions keep in-session subagents.
  assertAllow(runHook(agentPayload('general-purpose')));
});

testCase('claude-glm session spawning general-purpose allows', () => {
  // The claude-glm launcher marks the session with DELEGATE_GUARD_DISABLE=1 and
  // never sets FLASH_ORCHESTRATOR.
  assertAllow(
    runHook(agentPayload('general-purpose'), { DELEGATE_GUARD_DISABLE: '1' })
  );
});

testCase('flash mode main thread spawning via the Task tool name denies', () => {
  // Older Claude Code versions name the subagent tool Task; the payload shape
  // is the same.
  const reason = parseDeny(
    runHook(hookPayload('Task', agentToolInput('general-purpose')), {
      FLASH_ORCHESTRATOR: '1',
    })
  );
  assert.match(reason, /flash 会话不派会写代码的子代理/);
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
