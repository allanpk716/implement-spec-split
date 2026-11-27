'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const hookPath = path.join(__dirname, 'land-push-guard.js');
const skillDir = path.join(__dirname, '..');
const pidStartPath = path.join(skillDir, 'scripts', 'pid-start.sh');
const OWNER_PID = String(process.pid);
const TEST_ROOT = fs.mkdtempSync(
  path.join(os.tmpdir(), 'land-push-guard-')
);
let repoCounter = 0;
let passed = 0;
let failed = 0;

function git(args, cwd) {
  const result = childProcess.spawnSync('git', args, {
    cwd,
    encoding: 'utf8',
  });
  assert.strictEqual(result.error, undefined);
  assert.strictEqual(
    result.status,
    0,
    `git ${args.join(' ')} failed:\n${result.stderr}`
  );
  return result.stdout.trim();
}

// A local bare origin plus a clone on main, with origin/HEAD -> origin/main.
// No network is involved.
function makeRepo() {
  repoCounter += 1;
  const root = path.join(TEST_ROOT, `repo-${repoCounter}`);
  fs.mkdirSync(root, { recursive: true });
  const origin = path.join(root, 'origin.git');
  const work = path.join(root, 'work');
  git(['init', '--bare', '--initial-branch=main', origin], root);
  git(['clone', origin, work], root);
  git(['config', 'user.email', 'test@example.com'], work);
  git(['config', 'user.name', 'Test User'], work);
  fs.writeFileSync(path.join(work, 'file.txt'), 'hello\n');
  git(['add', 'file.txt'], work);
  git(['commit', '-m', 'init'], work);
  git(['push', 'origin', 'main'], work);
  git(
    ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'],
    work
  );
  return { root, origin, work };
}

function withRepo(test) {
  const repo = makeRepo();
  return test(repo);
}

function commandLine(args = '') {
  return JSON.stringify({
    type: 'user',
    message: {
      role: 'user',
      content:
        '<command-message>implement-spec-split</command-message>\n' +
        '<command-name>/implement-spec-split</command-name>\n' +
        `<command-args>${args}</command-args>`,
    },
  });
}

// What an Orca worker-start session gets for its spec: the command line in
// the `=== TASK ===` block after the worker preamble, with no <command-name>
// tags (docs/orca-smoke-2026-11-27.md, item G).
function taskLine(args = '') {
  return JSON.stringify({
    type: 'user',
    message: {
      role: 'user',
      content:
        'You are a dispatched worker; reply when the task is done.\n' +
        '---\n' +
        '=== TASK ===\n' +
        `/implement-spec-split${args === '' ? '' : ` ${args}`}`,
    },
  });
}

function plainLine(text) {
  return JSON.stringify({
    type: 'user',
    message: { role: 'user', content: text },
  });
}

function writeTranscript(dir, lines, name = 'transcript.jsonl') {
  const transcriptPath = path.join(dir, name);
  fs.writeFileSync(transcriptPath, lines.join('\n') + '\n');
  return transcriptPath;
}

function hookPayload(command, transcriptPath, cwd, extraPayload = {}) {
  const payload = {
    session_id: 'test-session',
    transcript_path: transcriptPath,
    cwd,
    hook_event_name: 'PreToolUse',
    tool_name: 'Bash',
    tool_input: { command },
    ...extraPayload,
  };
  if (transcriptPath === undefined) delete payload.transcript_path;
  return JSON.stringify(payload);
}

function runHook(stdin, extraEnv = {}) {
  const env = { ...process.env };
  delete env.LAND_PUSH_GUARD_DISABLE;
  delete env.LAND_PUSH_GUARD_OWNER_PID;
  Object.assign(env, extraEnv);
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env,
  });
  assert.strictEqual(result.error, undefined);
  return result;
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

function pidStart(pid) {
  const result = childProcess.spawnSync('bash', [pidStartPath, String(pid)], {
    encoding: 'utf8',
  });
  assert.strictEqual(result.error, undefined);
  assert.strictEqual(result.status, 0);
  return result.stdout.trim();
}

function lockDir(work) {
  const common = git(['rev-parse', '--git-common-dir'], work);
  const absolute = path.isAbsolute(common)
    ? common
    : path.resolve(work, common);
  return path.join(
    absolute,
    'implement-spec-split',
    'locks',
    'land.lock'
  );
}

function writeOwner(work, owner) {
  const dir = lockDir(work);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify(owner) + '\n');
}

testCase('git push origin HEAD:main without the lock denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [
      commandLine('19 --impl agent --auto-land'),
    ]);
    const reason = parseDeny(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
    assert.match(reason, /落地 push 必须先持有本仓库的 land 锁/);
    assert.ok(reason.includes(path.join(skillDir, 'scripts', 'lock.sh')));
    assert.match(reason, /不要包 echo 或 `\|\| true`/);
    assert.match(reason, /退出码 2 表示别的 Run 正持锁/);
  });
});

testCase('git push origin main without the lock denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    parseDeny(
      runHook(hookPayload('git push origin main', transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('git -C <dir> push origin HEAD:refs/heads/main denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    const command = `git -C ${work} push origin HEAD:refs/heads/main`;
    parseDeny(
      runHook(hookPayload(command, transcriptPath, root), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('cd <dir> && git push on main denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    const command = `cd ${work} && git push`;
    parseDeny(
      runHook(hookPayload(command, transcriptPath, root), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('a lock owned by another pid denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    writeOwner(work, {
      pid: process.ppid,
      pid_start: '',
      cwd: work,
      acquired_at: '2026-11-25T00:00:00+0800',
    });
    parseDeny(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('a lock owned by this session allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    writeOwner(work, {
      pid: process.pid,
      pid_start: pidStart(process.pid),
      cwd: work,
      acquired_at: '2026-11-25T00:00:00+0800',
    });
    assertAllow(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('a matching pid with a stale pid_start denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    writeOwner(work, {
      pid: process.pid,
      pid_start: 'Wed Nov 25 00:00:00 2026',
      cwd: work,
      acquired_at: '2026-11-25T00:00:00+0800',
    });
    parseDeny(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('an empty pid_start only checks the pid', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    writeOwner(work, {
      pid: process.pid,
      pid_start: '',
      cwd: work,
      acquired_at: '2026-11-25T00:00:00+0800',
    });
    assertAllow(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('pushing spec-7 allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    assertAllow(
      runHook(
        hookPayload('git push origin spec-7', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('pushing --tags allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    assertAllow(
      runHook(
        hookPayload('git push origin --tags', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('deleting spec-7 allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    assertAllow(
      runHook(
        hookPayload(
          'git push origin --delete spec-7',
          transcriptPath,
          work
        ),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('pushing HEAD on main denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    parseDeny(
      runHook(
        hookPayload('git push origin HEAD', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('pushing to a repository path without a refspec denies', () => {
  withRepo(({ work, root, origin }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    parseDeny(
      runHook(hookPayload(`git push ${origin}`, transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('redirected push output still denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    for (const command of [
      'git push 2>&1',
      'git push origin HEAD:main 2>&1',
      'git push 2>&1 origin HEAD:main',
      'git push > /tmp/land-push-guard-test.log 2>&1',
      'git 2>&1 push origin HEAD:main',
    ]) {
      parseDeny(
        runHook(hookPayload(command, transcriptPath, work), {
          LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
        })
      );
    }
  });
});

testCase('without --auto-land still denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [
      commandLine('19 --impl agent --parallel 2'),
    ]);
    parseDeny(
      runHook(
        hookPayload('git push origin main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('a session that never called the skill allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [
      plainLine('just a normal session'),
    ]);
    assertAllow(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

// ---- the === TASK === form an Orca worker-start session gets (US18) ----

testCase('=== TASK === form: git push origin HEAD:main without the lock denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [
      taskLine('26 --auto-land --parallel 2'),
    ]);
    const reason = parseDeny(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
    assert.match(reason, /落地 push 必须先持有本仓库的 land 锁/);
  });
});

testCase('=== TASK === form: a lock owned by this session allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [taskLine('26 --auto-land')]);
    writeOwner(work, {
      pid: process.pid,
      pid_start: pidStart(process.pid),
      cwd: work,
      acquired_at: '2026-11-25T00:00:00+0800',
    });
    assertAllow(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('=== TASK === without a command line allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [
      plainLine('You are a dispatched worker.\n=== TASK ===\nFinish spec 26.'),
    ]);
    assertAllow(
      runHook(
        hookPayload('git push origin HEAD:main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('echo of a push allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    assertAllow(
      runHook(
        hookPayload(
          'echo "git push origin main"',
          transcriptPath,
          work
        ),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('git push inside a heredoc body allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    const command = "cat <<'EOF'\ngit push origin main\nEOF";
    assertAllow(
      runHook(hookPayload(command, transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('LAND_PUSH_GUARD_DISABLE=1 allows', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    assertAllow(
      runHook(
        hookPayload('git push origin main', transcriptPath, work),
        {
          LAND_PUSH_GUARD_DISABLE: '1',
          LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
        }
      )
    );
  });
});

testCase('a missing transcript allows', () => {
  withRepo(({ work }) => {
    const transcriptPath = path.join(work, 'missing.jsonl');
    assertAllow(
      runHook(
        hookPayload('git push origin main', transcriptPath, work),
        { LAND_PUSH_GUARD_OWNER_PID: OWNER_PID }
      )
    );
  });
});

testCase('an invalid injected owner pid allows with a stderr note', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    const result = runHook(
      hookPayload('git push origin main', transcriptPath, work),
      { LAND_PUSH_GUARD_OWNER_PID: '0' }
    );
    assert.strictEqual(result.status, 0);
    assert.strictEqual(result.stdout, '');
    assert.match(result.stderr, /no claude ancestor process found/);
  });
});

testCase('a missing origin/HEAD falls back to main and master', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    git(['symbolic-ref', '--delete', 'refs/remotes/origin/HEAD'], work);
    parseDeny(
      runHook(hookPayload('git push origin master', transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
    assertAllow(
      runHook(hookPayload('git push origin spec-7', transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('pushing --all denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    parseDeny(
      runHook(hookPayload('git push origin --all', transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

testCase('pushing a matching refspec denies', () => {
  withRepo(({ work, root }) => {
    const transcriptPath = writeTranscript(root, [commandLine('19')]);
    parseDeny(
      runHook(hookPayload('git push origin :', transcriptPath, work), {
        LAND_PUSH_GUARD_OWNER_PID: OWNER_PID,
      })
    );
  });
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
console.log(
  `TEST_ROOT=${TEST_ROOT} (left in place: the Brief forbids recursive cleanup)`
);
if (failed > 0) process.exitCode = 1;
