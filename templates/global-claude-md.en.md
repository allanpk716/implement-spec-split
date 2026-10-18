<!--
English version of the global division rules for ~/.claude/CLAUDE.md. The Chinese
version is templates/global-claude-md.md. Copy everything below the line into
your global CLAUDE.md (append it, or replace an older "delegate coding to codex/PI"
section). Adjust the two placeholders first:
  - <GLM endpoint description>: how codex reaches GLM on this machine, e.g.
    "GLM through the local Ferryman proxy on 127.0.0.1:15722"
  - the skill path, if the skill is not cloned to ~/.claude/skills/implement-spec-split
Keep the version marker line: scripts/doctor.sh compares it with this template to detect drift.
See docs/setup.md, stage 3.
-->

---

<!-- opus-codex-division: v1 -->
## Opus / codex division of labour (cost control)

The native Claude Code subscription quota is not enough. Spend Opus quota only on judgment; delegate high-volume, low-judgment execution to codex workers: `codex exec` runs over <GLM endpoint description>, which has plentiful quota, through the `codex-worker.sh` wrapper script. The wrapper can show progress and automatically detect a stalled worker.

**Decision criteria**: consider two dimensions: judgment density (how costly a mistake is and how many trade-offs are involved), and token volume (how much source code, logs, and output must be read or written). Hand-off itself has a fixed cost (writing a Brief, reading the result, review), so delegating a small task can cost more.

|  | Small volume | Large volume |
|---|---|---|
| Judgment-dense | **I do it**: design discussion, grilling, architecture trade-offs, root-cause judgment, review conclusions, approving push/PR | **Split it**: a worker gathers facts with an investigation Brief; I read the report and decide |
| Judgment-sparse | **I do it inline**: commit, push, conflict-free merge, a single command, a fix of ≤10 lines with a clear root cause | **Delegate to a worker**: writing features, fixing bugs, adding tests, refactoring, bulk file changes, running long tests until green, resolving merge conflicts |

- **Hard rule**: external or irreversible actions (push, opening a PR, remote server operations, deleting data, publishing externally) are always performed by me or confirmed with the user; never delegate them to a worker. Workers run in bypass mode and have full access to the entire machine.
- **Locating problems**: when reading through multiple files is needed to locate a problem, do not read them yourself; write an investigation Brief, hand it to a worker with `--read-only`, and read only the report. If the report is insufficient for a decision, then read a few targeted places.
- **Source edits over 10 lines** are always delegated to a worker. Do not use Edit/Write, and do not bypass them with Bash (`sed`, heredoc). Non-code files such as documentation, memory, and configuration are unrestricted. The `delegate-guard` PreToolUse hook intercepts over-limit edits.
- **Exception**: only I write large sections of code when the user explicitly says "make this change yourself", or when the problem is severe and I am required to act directly. Then create `~/.claude/state/allow-direct-edit`, with an expiry time as its content (ISO 8601, 60 minutes from now by default). Never create it without user authorization.
- **Review tiers**: for a small change, scan the diff and spot-check one acceptance command; for changes involving concurrency, security, data migration, or public interfaces, review closely. A worker's "acceptance evidence" does not replace my spot check.
- **Save context**: after finishing a task, remind the user to `/clear`; filter large output through `head`/`grep` before reading it; let workers read large files and long logs.

Invocation (all scripts are in `~/.claude/skills/implement-spec-split/scripts/`):

1. Create a run directory `~/.cache/codex-runs/<repository-name>-<YYYYmmdd-HHMM>-<short-task-name>/` and write the Brief as `brief.md` inside it. Draft the Brief from a template: use `~/.claude/skills/implement-spec-split/templates/brief-implement.md` for implementation tasks and `brief-investigate.md` for investigation tasks.
2. Run with Bash `run_in_background: true`:

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <target-repository> --brief <run-directory>/brief.md --run-dir <run-directory> \
     --time-limit 3600 --idle-timeout 600
   ```

   Add `--skill <tdd-skill-directory>` when TDD is needed. Add `--read-only` for investigation tasks: once the workspace changes, `status.json` marks `read_only_violation` with exit code 8 (`violation`); discard that report, and I inspect and handle the changes.
3. When it finishes, read `<run-directory>/status.json` and `result.md`.

**Briefs must be self-contained**: state the goal, relevant file paths and line numbers, root-cause analysis, the desired approach to changes, acceptance criteria (which tests/commands to run), and out-of-scope areas. The worker cannot read our conversation. The Brief must also include two rules:

- "Do not commit", because I perform commits;
- Do not ask it to recursively delete directories; codex rejects `rm -rf`.

**Checking progress**: when the user asks "where is it now", or when a task takes longer than expected, run `~/.claude/skills/implement-spec-split/scripts/progress.sh <run-directory>` and summarize its status (running / finished / dead), seconds since the last progress, the currently running command, and recent actions. Look once; do not poll in a loop: the wrapper itself detects stalls.

**Handle according to `status` in `status.json`**:

- `ok` (exit code 0): only means it finished, not that it is correct. Review as usual.
- `auth` / `quota` / `transient` (2/3/4): GLM or the proxy is unavailable (`proxy not listening` means the proxy is not running). Tell the user and ask whether to wait a while or for me to make the change. Do not switch approaches by yourself.
- `timeout` (5): the Time limit was reached. If there are already changes, resume once with `~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --resume --run-dir <run-directory>`; if it times out a second time, or there was no progress at all, ask the user.
- `stalled` (7) or `error` (6): read the end of `stderr.log` and `result.md`, add the failure reason to the Brief, and rerun once in a new run directory; if it fails again, ask the user.
- `stalled` but `result_file` is non-empty: codex actually finished its answer but did not clean up. Review it as `ok`.
- `violation` (8, only with `--read-only`): the workspace was changed during investigation. Inspect `changed_paths`, confirm the changes with `git diff`, tell the user, and let the user decide how to revert; do not trust the report.

**Wrap-up**:

- After a worker finishes, I review changes with `git diff` and run tests. If there are problems, I write a new Brief containing the specific comments and "modify the existing changes", hand it to a worker in a new run directory, and repeat until it passes. Finally, I report the result to the user.
- After review passes, I perform commit / push / opening the PR; I do not delegate them to a worker.
- For design rationale and known pitfalls, see `~/.claude/skills/implement-spec-split/docs/codex-backend.md`.
