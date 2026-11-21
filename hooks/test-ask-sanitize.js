'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const path = require('path');

const hookPath = path.join(__dirname, 'ask-sanitize.js');
let passed = 0;
let failed = 0;

function runHook(stdin) {
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function hookPayload(toolName, toolInput) {
  return JSON.stringify({
    session_id: 'test-session',
    transcript_path: 'test-transcript',
    cwd: process.cwd(),
    hook_event_name: 'PreToolUse',
    tool_name: toolName,
    tool_input: toolInput,
  });
}

function parseAsk(result) {
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stderr, '');
  const lines = result.stdout.split('\n');
  assert.strictEqual(lines.length, 2);
  assert.strictEqual(lines[1], '');
  const output = JSON.parse(lines[0]);
  assert.strictEqual(output.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(
    output.hookSpecificOutput.permissionDecision,
    'ask'
  );
  return output.hookSpecificOutput.updatedInput;
}

function assertNoOutput(result) {
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stdout, '');
  assert.strictEqual(result.stderr, '');
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

testCase('multi-question input is sanitized without other changes', () => {
  const input = {
    questions: [
      {
        question: '要继续实现 spec split\r 吗？',
        header: '确认\r范围',
        multiSelect: false,
        options: [
          {
            label: '继续\r实现',
            description: '按当前 spec\r 继续处理中文 and English',
          },
          {
            label: '暂停\r',
            description: '先检查\r\n现有结果',
          },
        ],
      },
      {
        question: '需要\r更新文档吗？',
        header: '文档\r',
        multiSelect: true,
        options: [
          {
            label: '更新\r',
            description: '同步 README\r 和测试',
          },
        ],
      },
    ],
  };
  const expected = {
    questions: [
      {
        question: '要继续实现 spec split 吗？',
        header: '确认范围',
        multiSelect: false,
        options: [
          {
            label: '继续实现',
            description: '按当前 spec 继续处理中文 and English',
          },
          {
            label: '暂停',
            description: '先检查\n现有结果',
          },
        ],
      },
      {
        question: '需要更新文档吗？',
        header: '文档',
        multiSelect: true,
        options: [
          {
            label: '更新',
            description: '同步 README 和测试',
          },
        ],
      },
    ],
  };
  const updatedInput = parseAsk(runHook(hookPayload('AskUserQuestion', input)));
  assert.deepStrictEqual(updatedInput, expected);
});

testCase('carriage-return line endings become line feeds', () => {
  const updatedInput = parseAsk(
    runHook(
      hookPayload('AskUserQuestion', {
        questions: [
          {
            question: '第一行\r\n第二行',
            options: [{ label: '选项\r\nA', description: '说明\r\nB' }],
          },
        ],
      })
    )
  );
  assert.strictEqual(updatedInput.questions[0].question, '第一行\n第二行');
  assert.strictEqual(updatedInput.questions[0].options[0].label, '选项\nA');
  assert.strictEqual(updatedInput.questions[0].options[0].description, '说明\nB');
});

testCase('a literal backslash followed by r is preserved', () => {
  const literal = 'literal \\r stays';
  const updatedInput = parseAsk(
    runHook(
      hookPayload('AskUserQuestion', {
        questions: [
          {
            question: 'change\r me',
            options: [{ label: literal, description: 'keep \\r' }],
          },
        ],
      })
    )
  );
  assert.strictEqual(
    updatedInput.questions[0].options[0].label,
    'literal \\r stays'
  );
  assert.strictEqual(updatedInput.questions[0].options[0].description, 'keep \\r');
  assert.strictEqual(updatedInput.questions[0].question, 'change me');
});

testCase('AskUserQuestion without carriage returns has no output', () => {
  assertNoOutput(
    runHook(
      hookPayload('AskUserQuestion', {
        questions: [
          {
            question: '没有回车',
            header: '正常',
            options: [{ label: '确定', description: '直接显示' }],
          },
        ],
      })
    )
  );
});

testCase('other tools are not sanitized', () => {
  assertNoOutput(
    runHook(
      hookPayload('Bash', {
        command: 'printf "before\rafter"\n',
      })
    )
  );
});

testCase('invalid JSON fails open with no output', () => {
  assertNoOutput(runHook('{invalid'));
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
