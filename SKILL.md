---
name: implement-spec-split
description: Implement a spec and its tickets like implement-spec, but with split models - the implementing roles (exploration/implementer/merger/fix) run on Sonnet or, with --impl codex / --impl pi, on GLM through external codex or pi workers; the code-review subagents always run on a stronger model (Opus). Use when the user wants "Sonnet/GLM 开发 + 高阶模型 review", or invokes /implement-spec-split.
disable-model-invocation: true
---

# implement-spec-split

Same goal and task-graph workflow as `mattpocock-skills:implement-spec`, with one difference: **models are chosen per role** instead of inherited from the session. The steps below are self-contained; do not invoke the original `implement-spec` (it runs its own review on the inherited model).

Terms (Orchestrator, In-session subagent, External worker, Implement backend, Brief, ...) are defined in `GLOSSARY.md` next to this file.

## Config (edit here to change the policy)

- `IMPLEMENT_BACKEND` = `sonnet` — who runs the implementing roles (exploration, implementer, merger, fix):
  - `sonnet`: In-session subagents with `model: IMPLEMENT_MODEL`.
  - `codex`: External workers, headless `codex exec` processes on `CODEX_MODEL` (see "External workers" below). The preferred External backend: its progress is visible live through `progress.sh`.
  - `pi`: External workers, headless `pi` processes on `GLM_MODEL`.
  - Override per run with an argument: `/implement-spec-split <spec> --impl codex` (or `--impl pi`, `--impl sonnet`).
- `IMPLEMENT_MODEL` = `sonnet` — model for implementing roles when the backend is `sonnet`.
- `CODEX_MODEL` = `glm-5.3` — model id for codex's `custom` provider in `~/.codex/config.toml`; the endpoint and key belong to the user's provider setup, never in this repo (author environment: Ferryman, `127.0.0.1:15722`).
- `GLM_MODEL` = `glm/glm-5.3` — pi `provider/id`; the provider, key and model list live in `~/.pi/agent/models.json`, never in this repo.
- `GLM_MAX_PARALLEL` = `2` — at most this many External workers at once. Override per run with an argument: `/implement-spec-split <spec> --impl codex --parallel 4`. The override replaces the default for that run only. Keep it small (2–3, at most 4 off-peak): Zhipu rate-limits during peak hours, and one quota/429 among the workers stops the whole run to ask the user.
- `GLM_TIME_LIMIT_IMPL` = `3600` — Time limit (seconds, GLOSSARY.md) for implementer and fix External workers.
- `GLM_TIME_LIMIT_SHORT` = `1200` — Time limit (seconds) for merger and exploration External workers.
- `GLM_IDLE_TIMEOUT` = `600` — Idle timeout (seconds, GLOSSARY.md) for every External worker: no progress events from the worker for this long means it is stuck and is killed as `stalled`.
- `REVIEW_MODEL` = `opus` — every code-review subagent (use `fable` for the strongest option). Review always runs In-session, whatever the backend.

With the `sonnet` backend, pass the `model` parameter explicitly on every Agent call. Never rely on inheritance: the session itself may be on any model.

## Principles (from implement-spec)

- The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.
- The tickets are a **task graph** with blocking relationships, not a list of steps. There is always a **frontier** of tickets ready to be grabbed.
- Communication to and from subagents should be sparse. Communicate through **context pointers** (spec, tickets, research notes, previous commits); don't duplicate information already available via pointers.
- Run implementer subagents in the background where possible for maximum concurrency.

## Step 0: pick the spec

- If the user passed a spec reference (number, URL, path), use it.
- Otherwise discover candidates yourself via the tracker doc (`docs/agents/issue-tracker.md`). For GitHub, list open parent issues that still have unfinished sub-issues:

  ```bash
  gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" \
    --jq '.[]|select(.sub_issues_summary.total>0 and .sub_issues_summary.completed<.sub_issues_summary.total)|"#\(.number) \(.sub_issues_summary.completed)/\(.sub_issues_summary.total) \(.title)"'
  ```

  Also look for open specs with no tickets yet (labelled e.g. `spec`/`prd`/`needs-triage` per the tracker doc, or a newly opened parent issue): those need ticketing first, so report them and suggest the repo's to-issues/triage skill instead of implementing.
- For non-GitHub trackers (local markdown etc.), do the equivalent per the tracker doc.
- Exactly one candidate -> state it and proceed. Several -> list them (number, progress, title) and ask which one(s); implement one spec per run. None -> say so and stop.
- For a partly-done spec, only the open tickets form the frontier; closed tickets count as already merged. If an integration branch for the spec already exists (e.g. `spec-<n>-*`), reuse it instead of creating a new one.
- If the backend is `codex` or `pi`, run the preflight from "External workers" now, before any other work.

## Steps

"Dispatch <role>" below means: with the `sonnet` backend, an In-session subagent with `model: IMPLEMENT_MODEL`; with the `codex` or `pi` backend, an External worker (see below).

1. Read the spec and tickets; build the task graph / frontier. The issue tracker comes from the repo's `docs/agents/issue-tracker.md`; if missing, tell the user to run `/setup-matt-pocock-skills`.
2. (optional) Dispatch an exploration role. It saves its markdown notes in a directory outside the repo, accessible by all later roles, so implementers can focus on implementation. It must not modify the repo.
3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.
4. Dispatch one implementer per frontier ticket, each in its own worktree + branch, in the background. Each one:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - builds the ticket with the `mattpocock-skills:tdd` skill (In-session: via the Skill tool; External: loaded with `--skill`);
   - commits, leaves no uncommitted changes, and merges the integration branch tip into its own branch before reporting done.
5. When an implementer completes, verify it (External workers: the verification gate below), then dispatch a merger that merges its work into the integration branch and re-runs the test suite. **Run one merger at a time**; queue the rest.
   - For Go repos, the merger also cross-compiles for the other platforms CI builds (`CGO_ENABLED=0 GOOS=linux go vet ./...` and `CGO_ENABLED=0 GOOS=darwin go vet ./...`, or `GOOS=windows` when running on Linux/macOS). A local suite only proves the host platform: files named `*_windows.go` / `*_linux.go` etc. are silently excluded elsewhere, so a green local run can hide a red CI lane.
6. If this changes the frontier, dispatch implementers for the newly unblocked tickets.
7. **Review (the split point).** When all tickets are merged, call the Skill tool with `mattpocock-skills:code-review` (not the built-in `code-review`, which does not spawn the two axis sub-agents) on the integration branch, using the branch point from the main branch as the fixed point. When it spawns the Standards and Spec sub-agents, set `model: REVIEW_MODEL` on both. Do not skip this step, do not downgrade the model, and never hand review to an External worker.
8. Save the review report to a file outside the repo and dispatch a single fix role with that file as its context pointer. If an item is a design-level or subtle correctness problem rather than a mechanical fix, tell the fix role to report it back instead of guessing, then resolve it yourself or ask the user.
9. If a draft PR exists, mark it ready for review. Otherwise resolve each ticket the way the tracker closes work (e.g. merge with `Closes #n` and push) and report the integration branch. Confirm with the user before pushing/closing if they haven't already authorised it.
10. Clean up all implementer worktrees.

## External workers (backends `codex` and `pi`)

An External worker is a wrapper script (in this skill's directory) running one headless coding-agent process. It sees none of this conversation: everything it needs must be in its Brief or reachable from it. Both wrappers share one contract (flags, run dir, `status.json`, exit codes, Resume); only these differ:

| | `codex` | `pi` |
|---|---|---|
| `<worker>` | `scripts/codex-worker.sh` | `scripts/pi-worker.sh` |
| `<model>` | `CODEX_MODEL` | `GLM_MODEL` |
| preflight | `scripts/selftest-codex.sh --only L1 --model <CODEX_MODEL>` | `scripts/selftest.sh --only L1 --model <GLM_MODEL>` |
| usual preflight failure | local proxy not running (preflight address derived from the `base_url` in `config.toml`; author environment: Ferryman, `127.0.0.1:15722`), or its key/model | bad key or model id in `~/.pi/agent/models.json` |

**Preflight** (once per run, step 0): run the backend's preflight command from the table (prefixed with `<skill dir>/`). If it fails, stop and show the user the error. Also note the local time: weekdays 14:00–18:00 Beijing time are GLM peak hours (GLM-5.x quota is charged 3x and 429s are more likely). Proceed anyway; just mention it in the final report.

**Dispatching a role:**

1. Make a run directory per worker: `~/.cache/implement-spec-split/runs/<spec>-<YYYYmmdd-HHMM>/<role>-<ticket>/`.
2. Write the Brief to a file, fresh for every worker: do not derive one Brief from another with `sed` or search-and-replace (ticket numbers and branch names get left behind). Keep it to pointers and rules:
   - who it is (role, ticket number, how to read the spec and ticket, e.g. `gh issue view <n>`), worktree path, branch, integration branch;
   - exploration notes dir and, for fix, the review report path;
   - the rules for its role from the Steps above (for implementers: tdd, commit, clean tree, merge the integration tip; for exploration: do not modify the repo);
   - the repo's real test command if you know it;
   - "Final message: files changed, test command and result, anything you could not do or are unsure about."
   - (`codex`) never ask it to delete directories recursively: codex refuses `rm -rf` / `Remove-Item -Recurse` even without a sandbox. Do such cleanup yourself.
3. Run it with Bash, `run_in_background: true`, never more than `GLM_MAX_PARALLEL` at once (or the run's `--parallel` override, which replaces it for that run):

   ```bash
   <skill dir>/<worker> --cwd <worktree> --brief <brief file> --run-dir <run dir> \
     --model <model> --time-limit <role Time limit> --idle-timeout <GLM_IDLE_TIMEOUT> --skill <tdd skill dir>
   ```

   The role's Time limit: `GLM_TIME_LIMIT_IMPL` for implementers and fix, `GLM_TIME_LIMIT_SHORT` for merger and exploration.

   The tdd skill dir is the newest `~/.claude/plugins/cache/mattpocock/mattpocock-skills/*/skills/*/tdd`; pass it to implementers and fix only. Mergers run in the checkout that has the integration branch.
4. When it exits, read `<run dir>/status.json` and `result.md`. Do not read `events.jsonl` unless debugging a failure.
5. (`codex`) To see what a running worker is doing — when the user asks, or a worker runs long — run `<skill dir>/scripts/progress.sh <run dir>`: state (`running` / `finished` / `dead`), seconds since its last progress, the command in flight, recent commands, edits and messages, tokens. Look when needed; do not poll it in a loop (the wrapper's own watchdog handles stuck workers). `dead` means the wrapper is gone without writing `status.json` (e.g. the session that launched it ended): treat it like `error`.

**Exit codes / `status`:**

- `0` / `ok`: the worker finished without an API error. This is not success yet: apply the verification gate.
- `8` / `violation` (codex only): a `--read-only` investigation changed the workspace. Do not trust its report; hand the run directory and `changed_paths` to the orchestrator so the changes can be inspected and reverted or handled deliberately.
- `2` / `auth`, `3` / `quota`, `4` / `transient` (already retried by the agent and by the wrapper): the GLM side is unusable right now. Stop dispatching new External workers, let running ones finish, and ask the user: wait and retry, switch the remaining work to `sonnet`, or pause. Never switch to `sonnet` on your own: saving Claude quota is the point of this backend.
- `5` / `timeout`: the worker reached its Time limit; the agent's session (pi session / codex thread) is kept and can be **Resumed** (GLOSSARY.md). Read the tail of `stderr.log` and `result.md` if any, then check `status.json` for progress. With progress (`new_commits` ≥ 1 or `dirty` is `true`), Resume it once — same worktree, same run dir, same session, no new Brief:

  ```bash
  <skill dir>/<worker> --resume --run-dir <run dir> \
    --time-limit <role Time limit> --idle-timeout <GLM_IDLE_TIMEOUT>
  ```

  The wrapper reads the worktree, model, skills, thinking level and session from the run dir; never pass `--cwd`, `--brief`, `--model`, `--skill`, `--thinking` or `--add-dir` to a Resume. Afterwards apply the verification gate as usual: `segments` is now 2 and `new_commits` still counts from the first segment's base head, so the gate sees every commit across segments. On a second `timeout`, or a first `timeout` with no progress (`new_commits` = 0 and a clean tree), do not Resume again — ask the user.
- `6` / `error`, `7` / `stalled`: the worker failed (`stalled` = the Idle timeout fired: no progress events for `GLM_IDLE_TIMEOUT`, so the session is stuck — do not continue that session). Read the tail of `stderr.log` and `result.md` if any. Re-brief once in a fresh run dir with the failure appended; if it fails again, ask the user.
  - (`codex`) Exception: a `stalled` whose `status.json` has a non-null `result_file` means codex already gave its final reply but never closed the turn (the wrapper saved that reply to `result.md`). Apply the verification gate, accepting `stalled` in place of `ok`; if every other check holds, treat the worker as done.

**Verification gate** (implementers and fix). Never trust the worker's report alone. All must hold:

- `status.json`: `status` is `ok`, `new_commits` ≥ 1, `dirty` is `false`;
- `git merge-base --is-ancestor <integration branch> <ticket branch>` succeeds (it merged the integration tip);
- the merger's test run on the integration branch passes (step 5).

If any check fails, re-brief once with what is missing; if it still fails, ask the user. For exploration, the gate is: notes exist, `new_commits` is 0 and `dirty` is `false`.

## Report at the end

- Which backend and model ran each role (implement / merge / fix / review), and any role that ran on a different backend than configured, and why.
- For External workers: one line per run with ticket, status, segments (`status.json`; more than 1 means it was Resumed), duration and run directory; whether the run overlapped GLM peak hours.
- The review findings per axis, and how they were resolved.
