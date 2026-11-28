'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const hookPath = path.join(__dirname, 'unattended-stop-guard.js');
const skillDir = path.join(__dirname, '..');
let passed = 0;
let failed = 0;

function testCase(name, run) {
  try {
    run();
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(error && error.stack ? error.stack : String(error));
  }
}

function commandLine(args) {
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
function taskLine(args) {
  return JSON.stringify({
    type: 'user',
    message: {
      role: 'user',
      content:
        'You are a dispatched worker; reply when the task is done.\n' +
        '---\n' +
        '=== TASK ===\n' +
        `/implement-spec-split ${args}`,
    },
  });
}

function assistantTextLine(text) {
  return JSON.stringify({
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'text', text }] },
  });
}

function toolUseLine(name, input, extra = {}) {
  return JSON.stringify({
    type: 'assistant',
    message: {
      role: 'assistant',
      content: [{ type: 'tool_use', id: 'toolu_1', name, input }],
    },
    ...extra,
  });
}

function bashLine(command) {
  return toolUseLine('Bash', { command });
}

function userLine(text) {
  return JSON.stringify({
    type: 'user',
    message: { role: 'user', content: text },
  });
}

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

// A scratch directory with an isolated ISS_STATE_DIR (Run state) and TMPDIR
// (loop-counter files), one Run directory and a transcript. By default cwd is
// a workspace path, so <repo> comes from .../workspaces/<repo>/spec-<n>.
function makeFixture(options = {}) {
  const {
    phase = 'implement',
    runJson = true,
    repo = 'widget',
    spec = '19',
    lines = [commandLine('19 --impl agent --auto-land')],
    cwd = null,
  } = options;

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'unattended-stop-guard-'));
  const state = path.join(root, 'state');
  const counterTmp = path.join(root, 'counter-tmp');
  fs.mkdirSync(counterTmp, { recursive: true });

  if (runJson) {
    const runDir = path.join(state, 'runs', `${repo}-${spec}-20260101-0000`);
    fs.mkdirSync(runDir, { recursive: true });
    fs.writeFileSync(
      path.join(runDir, 'run.json'),
      JSON.stringify({
        phase,
        wave: null,
        tickets: { merged: 0, in_progress: 0, todo: 0 },
        updated: '2026-11-25T00:00:00+0800',
      })
    );
  }

  const transcriptPath = path.join(root, 'transcript.jsonl');
  fs.writeFileSync(
    transcriptPath,
    lines.length === 0 ? '' : `${lines.join('\n')}\n`
  );

  return {
    root,
    state,
    counterTmp,
    transcriptPath,
    cwd:
      cwd === null
        ? path.join(root, 'workspaces', repo, `spec-${spec}`)
        : cwd,
    env: { ISS_STATE_DIR: state, TMPDIR: counterTmp },
    writePhase(nextPhase) {
      const runDir = path.join(state, 'runs', `${repo}-${spec}-20260101-0000`);
      fs.mkdirSync(runDir, { recursive: true });
      fs.writeFileSync(
        path.join(runDir, 'run.json'),
        JSON.stringify({
          phase: nextPhase,
          wave: null,
          tickets: { merged: 0, in_progress: 0, todo: 0 },
          updated: '2026-11-25T00:00:00+0800',
        })
      );
    },
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
}

function withFixture(options, test) {
  const fixture = makeFixture(options);
  try {
    return test(fixture);
  } finally {
    fixture.cleanup();
  }
}

function stopPayload(transcriptPath, cwd, extra = {}) {
  const payload = {
    session_id: 'test-session',
    transcript_path: transcriptPath,
    cwd,
    hook_event_name: 'Stop',
    stop_hook_active: false,
    ...extra,
  };
  if (transcriptPath === undefined) delete payload.transcript_path;
  return JSON.stringify(payload);
}

function runHook(stdin, extraEnv = {}) {
  const env = { ...process.env };
  delete env.UNATTENDED_STOP_GUARD_DISABLE;
  delete env.ISS_STATE_DIR;
  Object.assign(env, extraEnv);
  const result = childProcess.spawnSync('node', [hookPath], {
    input: stdin,
    encoding: 'utf8',
    env,
  });
  assert.strictEqual(result.error, undefined);
  return result;
}

function assertAllow(result, { silent = true } = {}) {
  assert.strictEqual(
    result.status,
    0,
    `exit ${result.status}, stderr: ${result.stderr}`
  );
  assert.strictEqual(
    result.stdout,
    '',
    `expected no output, got: ${result.stdout}`
  );
  if (silent) {
    assert.strictEqual(result.stderr, '', `expected empty stderr`);
  }
}

function parseBlock(result) {
  assert.strictEqual(
    result.status,
    0,
    `exit ${result.status}, stderr: ${result.stderr}`
  );
  assert.strictEqual(result.stderr, '');
  const lines = result.stdout.split('\n');
  assert.strictEqual(lines.length, 2, `expected one JSON line: ${result.stdout}`);
  assert.strictEqual(lines[1], '');
  const output = JSON.parse(lines[0]);
  assert.deepStrictEqual(Object.keys(output).sort(), ['decision', 'reason']);
  assert.strictEqual(output.decision, 'block');
  assert.strictEqual(typeof output.reason, 'string');
  assert.ok(output.reason.length > 0);
  return output.reason;
}

// ---------------------------------------------------------------- unattended

testCase('session without --auto-land allows even when done and not closed', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('19 --impl agent'),
        assistantTextLine('可以 /clear 了'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('earlier --auto-land then last call without it allows', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('18 --auto-land'),
        assistantTextLine('done'),
        commandLine('19 --impl agent'),
        assistantTextLine('可以 /clear 了'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('similar flag --auto-landing does not count', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('19 --impl agent --auto-landing'),
        assistantTextLine('可以 /clear 了'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('session without an /implement-spec-split call allows', () => {
  withFixture(
    {
      phase: 'done',
      lines: [userLine('hello'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

// ------------------------------------------------------------- rule A: close

testCase('done without close-self blocks with the self-close reason', () => {
  withFixture(
    {
      phase: 'done',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /phase=done/);
      assert.match(reason, /close-self\.sh/);
      assert.match(reason, /--run-dir <Spec Run root>/);
      assert.match(reason, /--remove-worktree <集成 worktree>/);
      assert.match(reason, /SKILL\.md 第 10 步/);
      assert.ok(reason.includes(path.join(skillDir, 'scripts', 'close-self.sh')));
    }
  );
});

testCase('done with a close-self Bash command allows', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('收尾'),
        bashLine(
          `${skillDir}/scripts/close-self.sh --remove-worktree /tmp/wt/spec-19`
        ),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('waiting without close-self blocks', () => {
  withFixture(
    {
      phase: 'waiting',
      lines: [commandLine('19 --auto-land'), assistantTextLine('waiting')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /phase=waiting/);
    }
  );
});

testCase('parked without close-self blocks', () => {
  withFixture(
    {
      phase: 'parked',
      lines: [commandLine('19 --auto-land'), assistantTextLine('停车了')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /phase=parked/);
    }
  );
});

testCase('parked with close-self allows even when the text asks a question', () => {
  withFixture(
    {
      phase: 'parked',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('这个取舍需要你决定。'),
        bashLine(`${skillDir}/scripts/close-self.sh`),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('close-self mentioned only in assistant text still blocks', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('接下来我会运行 close-self.sh'),
      ],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('close-self in a sidechain tool_use does not count', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        commandLine('19 --auto-land'),
        toolUseLine(
          'Bash',
          { command: `${skillDir}/scripts/close-self.sh` },
          { isSidechain: true }
        ),
      ],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

// ------------------- the === TASK === form an Orca worker-start session gets

testCase('=== TASK === form: done without close-self blocks with the self-close reason', () => {
  withFixture(
    {
      phase: 'done',
      lines: [taskLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /phase=done/);
      assert.match(reason, /close-self\.sh/);
      assert.match(reason, /SKILL\.md 第 10 步/);
    }
  );
});

testCase('=== TASK === form: done with a close-self Bash command allows', () => {
  withFixture(
    {
      phase: 'done',
      lines: [
        taskLine('19 --auto-land'),
        assistantTextLine('收尾'),
        bashLine(
          `${skillDir}/scripts/close-self.sh --remove-worktree /tmp/wt/spec-19`
        ),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('=== TASK === form: implement phase ending with a question blocks', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [taskLine('19 --auto-land'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /无人值守 Run 没人会回复/);
    }
  );
});

testCase('=== TASK === form without --auto-land allows even when done and not closed', () => {
  withFixture(
    {
      phase: 'done',
      lines: [taskLine('19 --parallel 2'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

// -------------------------------------------------------------- rule B: ask

testCase('implement phase ending with a full-width question mark blocks', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [commandLine('19 --auto-land'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      const reason = parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      assert.match(reason, /无人值守 Run 没人会回复/);
      assert.match(reason, /可自动采纳：是/);
      assert.match(reason, /## 停车报告/);
      assert.match(reason, /不要问人/);
    }
  );
});

testCase('implement phase ending with an ASCII question mark blocks', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('Should I continue with option B?'),
      ],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('trailing whitespace after the question mark still blocks', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('要不要继续？  \n\n'),
      ],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('implement phase with a declarative last message allows', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('两个实现者都已完成，接下来合并 t1。'),
        bashLine('git status'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('land phase waiting for a background notification allows', () => {
  withFixture(
    {
      phase: 'land',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('后台 watcher 在跑，等它的完成通知。'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('marker 需要你 without a question mark blocks', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('这个取舍需要你决定，我先停在这里。'),
      ],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('question older than the last 300 characters is ignored', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine(
          `要不要继续？${'x'.repeat(400)} 已完成，等待后台任务通知。`
        ),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('last assistant message without a text block allows', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('要不要继续？'),
        bashLine('sleep 100'),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('sidechain assistant question does not count', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [
        commandLine('19 --auto-land'),
        assistantTextLine('继续实现。'),
        toolUseLine('Bash', { command: 'echo hi' }, { isSidechain: true }),
      ],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

// ------------------------------------------------------------ missing state

testCase('missing run.json only applies rule B: plain text allows', () => {
  withFixture(
    {
      runJson: false,
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('missing run.json only applies rule B: question blocks', () => {
  withFixture(
    {
      runJson: false,
      lines: [commandLine('19 --auto-land'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('unparseable run.json only applies rule B', () => {
  withFixture({ runJson: false }, fixture => {
    const runDir = path.join(fixture.state, 'runs', 'widget-19-20260101-0000');
    fs.mkdirSync(runDir, { recursive: true });
    fs.writeFileSync(path.join(runDir, 'run.json'), '{not json');
    fs.writeFileSync(
      fixture.transcriptPath,
      `${commandLine('19 --auto-land')}\n${assistantTextLine('要不要继续？')}\n`
    );
    parseBlock(
      runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
    );
  });
});

testCase('unknown phase only applies rule B', () => {
  withFixture(
    {
      phase: 'something-new',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以了')],
    },
    fixture => {
      assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
    }
  );
});

testCase('newest run.json wins when several match', () => {
  withFixture({ runJson: false }, fixture => {
    const runs = path.join(fixture.state, 'runs');
    const older = path.join(runs, 'widget-19-20260101-0000');
    const newer = path.join(runs, 'widget-19-20260102-0000');
    fs.mkdirSync(older, { recursive: true });
    fs.mkdirSync(newer, { recursive: true });
    const runJson = (phase, updated) =>
      JSON.stringify({ phase, wave: null, tickets: {}, updated });
    fs.writeFileSync(
      path.join(older, 'run.json'),
      runJson('done', '2026-11-25T00:00:00+0800')
    );
    fs.writeFileSync(
      path.join(newer, 'run.json'),
      runJson('implement', '2026-11-25T00:00:01+0800')
    );
    const now = Date.now() / 1000;
    fs.utimesSync(path.join(older, 'run.json'), now - 3600, now - 3600);
    fs.utimesSync(path.join(newer, 'run.json'), now, now);
    fs.writeFileSync(
      fixture.transcriptPath,
      `${commandLine('19 --auto-land')}\n${assistantTextLine('继续')}\n`
    );
    // The newer run is still implement, so the done run must not win.
    assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
  });
});

// ------------------------------------------------------------------ repo

testCase('repo from origin remote resolves the Run directory', () => {
  withFixture({ runJson: false }, fixture => {
    const repoDir = path.join(fixture.root, 'checkouts', 'widget');
    fs.mkdirSync(path.dirname(repoDir), { recursive: true });
    git(['init', repoDir], fixture.root);
    git(['remote', 'add', 'origin', 'https://github.com/acme/widget.git'], repoDir);

    const runDir = path.join(fixture.state, 'runs', 'widget-19-20260101-0000');
    fs.mkdirSync(runDir, { recursive: true });
    fs.writeFileSync(
      path.join(runDir, 'run.json'),
      JSON.stringify({ phase: 'done', wave: null, tickets: {}, updated: 'x' })
    );
    fs.writeFileSync(
      fixture.transcriptPath,
      `${commandLine('19 --auto-land')}\n${assistantTextLine('可以 /clear 了')}\n`
    );
    parseBlock(runHook(stopPayload(fixture.transcriptPath, repoDir), fixture.env));
  });
});

// --------------------------------------------------------------- escape hatch

testCase('UNATTENDED_STOP_GUARD_DISABLE=1 allows a done run without close-self', () => {
  withFixture(
    {
      phase: 'done',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      assertAllow(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), {
          ...fixture.env,
          UNATTENDED_STOP_GUARD_DISABLE: '1',
        })
      );
    }
  );
});

// ------------------------------------------------------------- broken input

testCase('missing transcript_path allows', () => {
  assertAllow(runHook(stopPayload(undefined, process.cwd())));
});

testCase('nonexistent transcript allows', () => {
  assertAllow(
    runHook(stopPayload('/nonexistent/transcript.jsonl', process.cwd()))
  );
});

testCase('garbage transcript allows', () => {
  withFixture({ runJson: false }, fixture => {
    fs.writeFileSync(fixture.transcriptPath, 'not json\n{"broken":\n');
    assertAllow(runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env));
  });
});

testCase('empty stdin allows', () => {
  assertAllow(runHook(''));
});

// ------------------------------------------------------------ loop limiter

testCase('stop_hook_active limits rule A to one extra block, then allows', () => {
  withFixture(
    {
      phase: 'done',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      parseBlock(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        )
      );
      const allowed = runHook(
        stopPayload(fixture.transcriptPath, fixture.cwd, {
          stop_hook_active: true,
        }),
        fixture.env
      );
      assertAllow(allowed, { silent: false });
      assert.match(allowed.stderr, /already blocked 1 time/);
      assert.match(allowed.stderr, /allowing the session to end/);

      const again = runHook(
        stopPayload(fixture.transcriptPath, fixture.cwd, {
          stop_hook_active: true,
        }),
        fixture.env
      );
      assertAllow(again, { silent: false });
    }
  );
});

testCase('stop_hook_active limits rule B to one extra block, then allows', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [commandLine('19 --auto-land'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      parseBlock(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        )
      );
      const allowed = runHook(
        stopPayload(fixture.transcriptPath, fixture.cwd, {
          stop_hook_active: true,
        }),
        fixture.env
      );
      assertAllow(allowed, { silent: false });
      assert.match(allowed.stderr, /already blocked 1 time/);
    }
  );
});

testCase('a fresh stop resets the loop counter', () => {
  withFixture(
    {
      phase: 'done',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      for (let call = 0; call < 2; call += 1) {
        parseBlock(
          runHook(
            stopPayload(fixture.transcriptPath, fixture.cwd, {
              stop_hook_active: call > 0,
            }),
            fixture.env
          )
        );
      }
      assertAllow(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        ),
        { silent: false }
      );

      // A new stop (not a continuation) starts a new loop.
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
    }
  );
});

testCase('unwritable loop counter fails open on stop_hook_active', () => {
  withFixture(
    {
      phase: 'done',
      lines: [commandLine('19 --auto-land'), assistantTextLine('可以 /clear 了')],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      const blocker = path.join(fixture.root, 'not-a-directory');
      fs.writeFileSync(blocker, 'x');
      const allowed = runHook(
        stopPayload(fixture.transcriptPath, fixture.cwd, {
          stop_hook_active: true,
        }),
        { ...fixture.env, TMPDIR: blocker }
      );
      assertAllow(allowed, { silent: false });
      assert.match(allowed.stderr, /cannot persist the loop counter/);
    }
  );
});

testCase('rules count separately', () => {
  withFixture(
    {
      phase: 'implement',
      lines: [commandLine('19 --auto-land'), assistantTextLine('要不要继续？')],
    },
    fixture => {
      parseBlock(
        runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env)
      );
      parseBlock(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        )
      );
      assertAllow(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        ),
        { silent: false }
      );

      // Rule A has its own counter, so a later park still blocks once.
      fixture.writePhase('parked');
      fs.writeFileSync(
        fixture.transcriptPath,
        `${commandLine('19 --auto-land')}\n${assistantTextLine('停车了')}\n`
      );
      const reason = parseBlock(
        runHook(
          stopPayload(fixture.transcriptPath, fixture.cwd, {
            stop_hook_active: true,
          }),
          fixture.env
        )
      );
      assert.match(reason, /phase=parked/);
    }
  );
});

// ------------------------------------------------------------- performance

testCase('multi-megabyte transcript decides in under 2 seconds', () => {
  const filler = JSON.stringify({
    type: 'assistant',
    message: {
      role: 'assistant',
      content: [{ type: 'text', text: 'x'.repeat(2048) }],
    },
  });
  const parts = [];
  let size = 0;
  while (size < 6 * 1024 * 1024) {
    parts.push(filler);
    size += filler.length + 1;
  }
  parts.push(commandLine('19 --auto-land'));
  parts.push(assistantTextLine('要不要继续？'));

  withFixture({ phase: 'implement', lines: parts }, fixture => {
    const started = process.hrtime.bigint();
    const result = runHook(stopPayload(fixture.transcriptPath, fixture.cwd), fixture.env);
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
    parseBlock(result);
    console.log(
      `Large transcript ${(size / 1024 / 1024).toFixed(1)} MiB took ${elapsedMs.toFixed(0)}ms`
    );
    assert.ok(elapsedMs < 2000, `elapsed ${elapsedMs.toFixed(0)}ms`);
  });
});

console.log(`Summary: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
