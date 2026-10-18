'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const hookPath = path.join(__dirname, 'delegate-guard.js');
let passed = 0;
let failed = 0;

function makeTempHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'delegate-guard-'));
}

function withTempHome(test) {
  const home = makeTempHome();
  try {
    return test(home);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function runHook(stdin, home) {
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env: { ...process.env, DELEGATE_GUARD_HOME: home },
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function lines(count, lineEnding = '\n') {
  return Array.from({ length: count }, (_, index) => `line ${index + 1}`).join(
    lineEnding
  );
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

function setOverride(home, content) {
  const stateDir = path.join(home, '.claude', 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'allow-direct-edit'), content);
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
    withTempHome(run);
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(error && error.stack ? error.stack : error);
  }
}

testCase('.ts Write 50 lines denies', home => {
  const result = runHook(
    hookPayload('Write', {
      file_path: 'C:/WorkSpace/x/src/a.ts',
      content: lines(50),
    }),
    home
  );
  const reason = parseDeny(result);
  assert.match(reason, /50/);
  assert.match(reason, /10/);
  assert.ok(!reason.includes('allow-direct-edit'));
});

testCase('.ts Edit 3 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Edit', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        old_string: lines(2),
        new_string: lines(3),
      }),
      home
    )
  );
});

testCase('.py Edit with 11-line new string denies', home => {
  const reason = parseDeny(
    runHook(
      hookPayload('Edit', {
        file_path: 'C:/WorkSpace/x/src/a.py',
        old_string: lines(2),
        new_string: lines(11),
      }),
      home
    )
  );
  assert.match(reason, /11/);
});

testCase('.py Edit exactly 10 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Edit', {
        file_path: 'C:/WorkSpace/x/src/a.py',
        old_string: lines(2),
        new_string: lines(10),
      }),
      home
    )
  );
});

testCase('.md Write 500 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/docs/a.md',
        content: lines(500),
      }),
      home
    )
  );
});

testCase('uppercase .JSON Write 500 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/config/a.JSON',
        content: lines(500),
      }),
      home
    )
  );
});

testCase('.gitignore Write 50 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/.gitignore',
        content: lines(50),
      }),
      home
    )
  );
});

testCase('.bat Write 20 lines denies', home => {
  const reason = parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/scripts/a.bat',
        content: lines(20),
      }),
      home
    )
  );
  assert.match(reason, /20/);
});

testCase('memory .md Write 300 lines allows', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path:
          'C:/Users/x/.claude/projects/y/memory/a.md',
        content: lines(300),
      }),
      home
    )
  );
});

testCase('future ISO override allows', home => {
  setOverride(home, new Date(Date.now() + 3600_000).toISOString());
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(50),
      }),
      home
    )
  );
});

testCase('future epoch override allows', home => {
  setOverride(home, String(Math.ceil(Date.now() / 1000) + 3600));
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(50),
      }),
      home
    )
  );
});

testCase('expired override denies', home => {
  setOverride(home, new Date(Date.now() - 3600_000).toISOString());
  parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(50),
      }),
      home
    )
  );
});

testCase('invalid override content denies', home => {
  setOverride(home, 'not a timestamp');
  parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(50),
      }),
      home
    )
  );
});

testCase('invalid JSON allows with no output', home => {
  assertAllow(runHook('{invalid', home));
});

testCase('missing file_path allows with no output', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        content: lines(50),
      }),
      home
    )
  );
});

testCase('Bash tool allows with no output', home => {
  assertAllow(runHook(hookPayload('Bash', { command: 'node -v' }), home));
});

testCase('NotebookEdit 20 lines denies', home => {
  const reason = parseDeny(
    runHook(
      hookPayload('NotebookEdit', {
        notebook_path: 'C:/WorkSpace/x/notebooks/a.ipynb',
        new_source: lines(20),
      }),
      home
    )
  );
  assert.match(reason, /20/);
});

testCase('CRLF newline counting', home => {
  parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(11, '\r\n'),
      }),
      home
    )
  );
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: 'a\nb\n',
      }),
      home
    )
  );
});

testCase('median of 20 runs is under 200ms', () => {
  const input = hookPayload('Write', {
    file_path: 'C:/WorkSpace/x/src/a.ts',
    content: lines(50),
  });
  const durations = [];
  withTempHome(home => {
    for (let index = 0; index < 20; index += 1) {
      const started = process.hrtime.bigint();
      const result = runHook(input, home);
      const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
      assert.strictEqual(result.status, 0);
      durations.push(elapsedMs);
    }
  });
  durations.sort((a, b) => a - b);
  const median = (durations[9] + durations[10]) / 2;
  assert.ok(median < 200, `median was ${median.toFixed(2)}ms`);
  console.log(`Median execution time: ${median.toFixed(2)}ms`);
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
