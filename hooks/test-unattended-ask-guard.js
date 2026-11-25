'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const hookPath = path.join(__dirname, 'unattended-ask-guard.js');
let passed = 0;
let failed = 0;

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'unattended-ask-guard-'));
}

function withTempDir(test) {
  const dir = makeTempDir();
  try {
    return test(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function runHook(stdin, extraEnv = {}) {
  const env = { ...process.env };
  delete env.UNATTENDED_ASK_GUARD_DISABLE;
  Object.assign(env, extraEnv);
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env,
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function commandContent(args, asArray = false) {
  const text =
    '<command-message>implement-spec-split</command-message>\n' +
    '<command-name>/implement-spec-split</command-name>\n' +
    `<command-args>${args}</command-args>`;
  if (asArray) return [{ type: 'text', text }];
  return text;
}

function transcriptLine(content, extra = {}) {
  return JSON.stringify({
    type: 'user',
    message: { role: 'user', content },
    ...extra,
  });
}

function assistantLine(text = 'thinking') {
  return JSON.stringify({
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'text', text }] },
  });
}

function writeTranscript(dir, lines, name = 'transcript.jsonl') {
  const transcriptPath = path.join(dir, name);
  fs.writeFileSync(transcriptPath, lines.join('\n') + '\n');
  return transcriptPath;
}

function hookPayload(toolName, transcriptPath, extraPayload = {}) {
  const payload = {
    session_id: 'test-session',
    transcript_path: transcriptPath,
    cwd: process.cwd(),
    hook_event_name: 'PreToolUse',
    tool_name: toolName,
    tool_input: { questions: [] },
    ...extraPayload,
  };
  if (transcriptPath === undefined) delete payload.transcript_path;
  return JSON.stringify(payload);
}

function parseDeny(result) {
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stderr, '');
  const lines = result.stdout.split('\n');
  assert.strictEqual(lines.length, 2);
  assert.strictEqual(lines[1], '');
  const output = JSON.parse(lines[0]);
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
  assert.strictEqual(result.stderr, '');
}

function testCase(name, run) {
  try {
    withTempDir(run);
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(error && error.stack ? error.stack : error);
  }
}

testCase('--auto-land in string content denies', dir => {
  const transcriptPath = writeTranscript(dir, [
    assistantLine(),
    transcriptLine(
      commandContent(
        '19 --impl agent --agent-model sonnet --auto-land --parallel 2'
      )
    ),
    assistantLine('working'),
  ]);
  const reason = parseDeny(
    runHook(hookPayload('AskUserQuestion', transcriptPath))
  );
  assert.match(reason, /无人值守 Run（--auto-land）不能问人/);
  assert.match(reason, /### 自动拍板（可推翻）/);
  assert.match(reason, /## 停车报告 \/ ### 需要你决定/);
  assert.match(reason, /不要再调用 AskUserQuestion/);
});

testCase('--auto-land in array content denies', dir => {
  const transcriptPath = writeTranscript(dir, [
    assistantLine(),
    transcriptLine(
      commandContent('19 --impl agent --auto-land --parallel 2', true)
    ),
  ]);
  parseDeny(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('without --auto-land allows', dir => {
  const transcriptPath = writeTranscript(dir, [
    assistantLine(),
    transcriptLine(
      commandContent('19 --impl agent --agent-model sonnet --parallel 2')
    ),
  ]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('earlier --auto-land then last call without it allows', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('18 --auto-land')),
    assistantLine('done with 18'),
    transcriptLine(commandContent('19 --impl agent')),
  ]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('earlier call without it then last --auto-land denies', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('18 --impl agent')),
    assistantLine('done with 18'),
    transcriptLine(commandContent('19 --auto-land')),
  ]);
  parseDeny(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('similar flag --auto-landing does not count', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('19 --impl agent --auto-landing')),
  ]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('--auto-land in ordinary text outside command args allows', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine('下次记得带 --auto-land，这次先不用'),
    transcriptLine(commandContent('19 --impl agent')),
  ]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('missing transcript_path allows', () => {
  assertAllow(runHook(hookPayload('AskUserQuestion', undefined)));
});

testCase('nonexistent transcript file allows', dir => {
  const transcriptPath = path.join(dir, 'missing.jsonl');
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('bad JSON line is skipped and a later call decides', dir => {
  const badLine =
    '{"type":"user","message":{"role":"user","content":"<command-name>' +
    '/implement-spec-split</command-name>\\n<command-args>19 --auto-land</command-args>"}';
  const transcriptPath = writeTranscript(dir, [
    badLine,
    transcriptLine(commandContent('19 --impl agent')),
  ]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('bad JSON line with the marker alone allows', dir => {
  const badLine =
    '{"type":"user","message":{"role":"user","content":"<command-name>' +
    '/implement-spec-split</command-name>\\n<command-args>19 --auto-land';
  const transcriptPath = writeTranscript(dir, [badLine]);
  assertAllow(runHook(hookPayload('AskUserQuestion', transcriptPath)));
});

testCase('other tools are allowed even in an unattended run', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('19 --auto-land')),
  ]);
  assertAllow(runHook(hookPayload('Bash', transcriptPath)));
});

testCase('subagent payload with agent_id still denies', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('19 --auto-land')),
  ]);
  parseDeny(
    runHook(
      hookPayload('AskUserQuestion', transcriptPath, { agent_id: 'agent-1' })
    )
  );
});

testCase('UNATTENDED_ASK_GUARD_DISABLE=1 allows', dir => {
  const transcriptPath = writeTranscript(dir, [
    transcriptLine(commandContent('19 --auto-land')),
  ]);
  assertAllow(
    runHook(hookPayload('AskUserQuestion', transcriptPath), {
      UNATTENDED_ASK_GUARD_DISABLE: '1',
    })
  );
});

testCase('multi-megabyte transcript decides in under 1 second', dir => {
  const fillerLine = JSON.stringify({
    type: 'assistant',
    message: {
      role: 'assistant',
      content: [{ type: 'text', text: 'x'.repeat(2048) }],
    },
  });
  const parts = [];
  let size = 0;
  while (size < 6 * 1024 * 1024) {
    parts.push(fillerLine);
    size += fillerLine.length + 1;
  }
  parts.push(transcriptLine(commandContent('19 --auto-land')));
  const transcriptPath = path.join(dir, 'large.jsonl');
  fs.writeFileSync(transcriptPath, parts.join('\n') + '\n');

  const started = process.hrtime.bigint();
  const result = runHook(hookPayload('AskUserQuestion', transcriptPath));
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;

  parseDeny(result);
  console.log(
    `Large transcript ${(size / 1024 / 1024).toFixed(1)} MiB took ${elapsedMs.toFixed(0)}ms`
  );
  assert.ok(elapsedMs < 1000, `elapsed ${elapsedMs.toFixed(0)}ms`);
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
