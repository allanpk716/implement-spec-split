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

function runHook(stdin, home, extraEnv = {}) {
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env: { ...process.env, DELEGATE_GUARD_HOME: home, ...extraEnv },
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function lines(count, lineEnding = '\n') {
  return Array.from({ length: count }, (_, index) => `line ${index + 1}`).join(
    lineEnding
  );
}

function hookPayload(toolName, toolInput, cwd = process.cwd()) {
  return JSON.stringify({
    session_id: 'test-session',
    transcript_path: 'test-transcript',
    cwd,
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

function makeProjectDir(levels = 2) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'delegate-guard-project-'));
  let current = root;
  for (let index = 0; index < levels; index += 1) {
    current = path.join(current, `level-${index}`);
  }
  fs.mkdirSync(current, { recursive: true });
  return { root, cwd: current };
}

function writeProjectConfig(directory, content) {
  const configDir = path.join(directory, '.claude');
  fs.mkdirSync(configDir, { recursive: true });
  fs.writeFileSync(
    path.join(configDir, 'delegate-guard.json'),
    typeof content === 'string' ? content : JSON.stringify(content)
  );
}

function readLog(home) {
  return fs.readFileSync(
    path.join(home, '.claude', 'state', 'delegate-guard.log'),
    'utf8'
  );
}

function writePayload(cwd, count = 50) {
  return hookPayload(
    'Write',
    { file_path: path.join(cwd, 'a.ts'), content: lines(count) },
    cwd
  );
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

testCase('DELEGATE_GUARD_LIMIT=20 allows 15 lines', home => {
  assertAllow(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(15),
      }),
      home,
      { DELEGATE_GUARD_LIMIT: '20' }
    )
  );
});

testCase('DELEGATE_GUARD_LIMIT=20 denies 21 lines with threshold 20', home => {
  const reason = parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(21),
      }),
      home,
      { DELEGATE_GUARD_LIMIT: '20' }
    )
  );
  assert.match(reason, /20/);
});

testCase('invalid DELEGATE_GUARD_LIMIT falls back to 10', home => {
  const reason = parseDeny(
    runHook(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(11),
      }),
      home,
      { DELEGATE_GUARD_LIMIT: 'abc' }
    )
  );
  assert.match(reason, /10/);
});

testCase('project enabled=false allows', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, { enabled: false });
    assertAllow(runHook(writePayload(cwd, 50), home));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('project limit=30 allows 25 lines and denies 31 lines', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, { limit: 30 });
    assertAllow(runHook(writePayload(cwd, 25), home));
    assert.match(parseDeny(runHook(writePayload(cwd, 31), home)), /30/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('project limit overrides DELEGATE_GUARD_LIMIT', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, { limit: 30 });
    assertAllow(
      runHook(writePayload(cwd, 25), home, { DELEGATE_GUARD_LIMIT: '5' })
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('nearest project config wins', home => {
  const { root, cwd } = makeProjectDir(2);
  const nearest = path.dirname(cwd);
  try {
    writeProjectConfig(root, { limit: 5 });
    writeProjectConfig(nearest, { limit: 50 });
    assertAllow(runHook(writePayload(cwd, 50), home));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('malformed project config is ignored and logged', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, 'not json');
    const reason = parseDeny(runHook(writePayload(cwd, 11), home));
    assert.match(reason, /10/);
    assert.match(readLog(home), / warn /);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('invalid project limit is ignored and logged', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, { limit: -1 });
    const reason = parseDeny(runHook(writePayload(cwd, 11), home));
    assert.match(reason, /10/);
    assert.match(readLog(home), / warn /);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('missing cwd uses default threshold', () => {
  withTempHome(home => {
    const payload = JSON.parse(
      hookPayload('Write', {
        file_path: 'C:/WorkSpace/x/src/a.ts',
        content: lines(11),
      })
    );
    delete payload.cwd;
    assert.match(
      parseDeny(runHook(JSON.stringify(payload), home)),
      /10/
    );
  });
});

testCase('DELEGATE_GUARD_LANG=en uses an English reason', home => {
  const reason = parseDeny(
    runHook(writePayload(process.cwd(), 50), home, {
      DELEGATE_GUARD_LANG: 'en',
    })
  );
  assert.match(reason, /50/);
  assert.match(reason, /10/);
  assert.match(reason, /codex worker/);
  assert.ok(!/[^\x00-\x7f]/.test(reason));
  assert.ok(!reason.includes('allow-direct-edit'));
});

testCase('override wins over project limit', home => {
  const { root, cwd } = makeProjectDir(2);
  try {
    writeProjectConfig(root, { limit: 1 });
    setOverride(home, new Date(Date.now() + 3600_000).toISOString());
    assertAllow(runHook(writePayload(cwd, 50), home));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

testCase('internal exception fails open with no output', home => {
  const fixture = path.join(home, 'throw-on-stdout.js');
  fs.writeFileSync(
    fixture,
    'process.stdout.write = () => { throw new Error("test stdout failure"); };'
  );
  assertAllow(
    runHook(writePayload(process.cwd(), 50), home, {
      NODE_OPTIONS: `--require ${fixture}`,
    })
  );
  assert.match(readLog(home), / error /);
});

testCase('invalid JSON does not write a log', home => {
  const logPath = path.join(home, '.claude', 'state', 'delegate-guard.log');
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  fs.writeFileSync(logPath, '');
  assertAllow(runHook('{invalid', home));
  assert.strictEqual(fs.readFileSync(logPath, 'utf8'), '');
});

testCase('oversized log is truncated before appending', home => {
  const { root, cwd } = makeProjectDir(2);
  const logPath = path.join(home, '.claude', 'state', 'delegate-guard.log');
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  fs.writeFileSync(logPath, 'x'.repeat(1024 * 1024));
  try {
    writeProjectConfig(root, 'not json');
    parseDeny(runHook(writePayload(cwd, 11), home));
    assert.ok(fs.statSync(logPath).size < 1024 * 1024);
    assert.match(fs.readFileSync(logPath, 'utf8'), / warn /);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
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

testCase('median with five-level cwd and no config is under 200ms', () => {
  const { root, cwd } = makeProjectDir(5);
  const input = writePayload(cwd, 50);
  const durations = [];
  try {
    withTempHome(home => {
      for (let index = 0; index < 20; index += 1) {
        const started = process.hrtime.bigint();
        const result = runHook(input, home);
        const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
        assert.strictEqual(result.status, 0);
        durations.push(elapsedMs);
      }
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
  durations.sort((a, b) => a - b);
  const median = (durations[9] + durations[10]) / 2;
  assert.ok(median < 200, `median was ${median.toFixed(2)}ms`);
  console.log(`Median execution time: ${median.toFixed(2)}ms`);
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
