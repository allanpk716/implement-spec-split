---
name: implement-spec-split
description: Implement a spec and its tickets like implement-spec, but with split models - the implementing roles (exploration/implementer/merger/fix) run on GLM through external codex/pi workers (--impl codex / --impl pi) or as in-session subagents on a chosen model (--impl agent, --agent-model sonnet|opus|haiku|fable); without --impl the backend is picked per session (codex in an official-subscription session, agent in a GLM-driven one); the code-review subagents always run on a stronger model (Opus). Use when the user wants "Sonnet/GLM 开发 + 高阶模型 review", or invokes /implement-spec-split.
disable-model-invocation: true
---

# implement-spec-split

Same goal and task-graph workflow as `mattpocock-skills:implement-spec`, with one difference: **models are chosen per role** instead of inherited from the session. The steps below are self-contained; do not invoke the original `implement-spec` (it runs its own review on the inherited model).

Terms (Orchestrator, In-session subagent, External worker, Implement backend, Brief, ...) are defined in `GLOSSARY.md` next to this file.

## Usage

- `/implement-spec-split <spec ref> [backend options]`: implement or recover one Spec as described below. The spec ref is required. Backend options: `--impl agent [--agent-model sonnet|opus|haiku|fable]`, `--impl codex`, `--impl pi`, or the legacy alias `--impl sonnet` (= `--impl agent --agent-model sonnet`); `--parallel N` as before. `--auto-land` turns the Run into an **Unattended landing** (see that section). find-next's launch commands (`launch-wave.sh`, including its `--only` and `--next-wave` paths) add it by default, so those Runs land unattended; `--no-auto-land` opts a batch out. Only a Run started by typing `/implement-spec-split <n>` without it still asks before pushing.
- `/implement-spec-split [backend options]` without a spec ref: do not scan or list candidates. Say "先运行 `/find-next --batch`，它给出开发顺序和每个 worktree 要敲的命令" and stop. Choosing what to build happens in one place (find-next), so several worktrees started at once never scan and pick in parallel.
- `/implement-spec-split --status`: only run `<skill dir>/scripts/pipeline-status.sh`, relay its result, and stop. Do not take a Spec, run preflight, or dispatch a worker.

## Config (edit here to change the policy)

- `IMPLEMENT_BACKEND` = `auto` — who runs the implementing roles (exploration, implementer, merger, fix). `auto` picks by session, once in step 0, when no `--impl` is given: `agent` if the environment has `DELEGATE_GUARD_DISABLE=1` (a GLM-driven Claude Code session such as `claude-glm`, whose own subagents already run on GLM), otherwise `codex` (an official-subscription session, whose subagents would spend the Claude quota). Check with `echo "$DELEGATE_GUARD_DISABLE"` and name the chosen backend in the final report. Before 2026-11-19 the default was `sonnet`, which silently ran every manually started Run (`/implement-spec-split <n>` without `--impl`) on subscription subagents. In Flash mode, see "Flash mode".
  - `agent`: In-session subagents on the agent model (`--agent-model`, default `IMPLEMENT_MODEL`). Use this where the Agent tool's model names reach a non-Anthropic endpoint — e.g. in a GLM proxy environment, explicitly passing `model: opus` actually runs GLM-5.4.
  - `sonnet`: compatibility alias for `agent` with the model pinned to `sonnet`. Kept so old commands with `--impl sonnet` keep working; `--impl sonnet --agent-model X` is an argument conflict (see below).
  - `codex`: External workers, headless `codex exec` processes on the Stage route table's model and reasoning effort (GLOSSARY.md "Stage route"; see "External workers" below). The preferred External backend: its progress is visible live through `progress.sh`.
  - `pi`: External workers, headless `pi` processes on `GLM_MODEL`.
  - Override per run with an argument: `/implement-spec-split <spec> --impl agent --agent-model opus` (or `--impl codex`, `--impl pi`; legacy `--impl sonnet` = `--impl agent --agent-model sonnet`).
- `IMPLEMENT_MODEL` = `sonnet` — default model for implementing roles when the backend is `agent`.
- `--agent-model <sonnet|opus|haiku|fable>` — per-run model override for the `agent` backend only. It is an argument, not a Config value. Given without `--impl`, it selects the `agent` backend (overriding `auto`). Combined with `--impl codex` or `--impl pi` (including `--impl sonnet`, which already pins the model) it is an argument conflict: report the error and ask the user to either drop `--agent-model` or switch to `--impl agent`; do not silently ignore the flag.
- Codex model and reasoning effort: not a Config value (2026-11-27, ADR 0004). `codex` External workers take both from the Stage route table (`scripts/stage-route.sh`, the user's `/grill-router`): the `research` stage for a `--read-only` dispatch, the `implementation` stage for every other; see "Stage route" under "External workers". Do not pass `--model` or `--thinking` to the wrapper. The endpoint and key belong to the user's provider setup, never in this repo (author environment: Ferryman, `127.0.0.1:15722`).
- `GLM_MODEL` = `glm/glm-5.4` — pi `provider/id`; the provider, key and model list live in `~/.pi/agent/models.json`, never in this repo.
- `GLM_MAX_PARALLEL` = `2` — at most this many External workers at once. Override per run with an argument: `/implement-spec-split <spec> --impl codex --parallel 4`. The override replaces the default for that run only. It is per Run: parallel Runs on different Specs add up. Keep it small (2–3, at most 4 off-peak): Zhipu rate-limits during peak hours, and one quota/429 among the workers stops the whole run to ask the user.
- `GLM_TIME_LIMIT_IMPL` = `3600` — Time limit (seconds, GLOSSARY.md) for implementer and fix External workers.
- `GLM_TIME_LIMIT_SHORT` = `1200` — Time limit (seconds) for merger and exploration External workers.
- `GLM_IDLE_TIMEOUT` = `600` — Idle timeout (seconds, GLOSSARY.md) for every External worker: no progress events from the worker for this long means it is stuck and is killed as `stalled`.
- `REVIEW_MODEL` = `opus` — every code-review subagent (use `fable` for the strongest option). Review always runs In-session, whatever the backend (non-flash sessions only; in Flash mode every review runs out-of-session via `opus-review.sh`).

With the `agent` backend (including the `sonnet` alias), pass the `model` parameter explicitly on every Agent call, using the agent model (`--agent-model`, default `IMPLEMENT_MODEL`). Never rely on inheritance: the session itself may be on any model.

## Principles (from implement-spec)

- The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.
- The tickets are a **task graph** with blocking relationships, not a list of steps. There is always a **frontier** of tickets ready to be grabbed.
- Start every subagent with a fresh context window, never a fork (a fork ignores the `model` override, so the per-role models would not apply).
- Communication to and from subagents should be sparse. Communicate through **context pointers** (spec, tickets, research notes, previous commits); don't duplicate information already available via pointers.
- Run implementer subagents in the background where possible for maximum concurrency.

## Step 0: pick the spec and take it

Several Runs may work at once, one Spec each, typically one Claude Code session per worktree, all started from the order that `/find-next --batch` printed (it can also start those sessions in Orca itself). Here `<n>` is always the **Spec issue number**, not the number of a wayfinder map or map implementation ticket.

A Spec is taken when its integration branch `spec-<n>` exists. Whether the Run holding it is still alive is recorded in its **claim record** (GLOSSARY.md): `$(git rev-parse --git-common-dir)/implement-spec-split/claims/spec-<n>.json`, written and read only through `<skill dir>/scripts/claim.sh`. It stores the PID and start time of the Claude Code process that took the Spec, so liveness does not depend on Orca. `claim.sh status <n>` prints `free`, `active <record>` (the holder process is alive) or `interrupted <record|none>` (branch exists, holder gone or no record).

On GitHub, identify Specs structurally, not by a “规格：” title prefix:

- A current Spec is an open issue whose body contains the to-spec template heading `## Problem Statement`.
- A legacy Spec is an open parent issue without the `wayfinder:map` label and without that heading, but with unfinished sub-issues.

Resolve a Spec to its Tickets in this order:

1. If the Spec issue has its own sub-issues, those sub-issues are the Tickets.
2. Otherwise, take the open wayfinder map implementation tickets referenced on an `实现票：#<n>` (also `实现票为 #<n>`) or `Implementation ticket(s): #<n>` line in the Spec body (only that line counts: specs also mention other map tickets as out of scope, and those must not be collected). to-spec does not write this line by itself, so the repo's tracker doc should require it. Such an implementation ticket has no `wayfinder:*` label and belongs to a `wayfinder:map` issue. If it has sub-issues, those sub-issues are the Tickets; if it has none, that implementation ticket is itself the one Ticket (a single-ticket Spec). Multiple referenced implementation tickets are all collected.

1. **Verify the ref.** It must meet one of the Spec rules above; otherwise say so and stop.
2. **Take it atomically**, from any directory inside the repo:

   ```bash
   <skill dir>/scripts/claim.sh take <n>
   ```

   It creates branch `spec-<n>` with its worktree at `<repo parent>/<repo>-wt/spec-<n>` from the main branch and writes the claim record, under a short repo-wide lock so two sessions cannot both pass the check. Exit 0 prints the worktree path: that is the integration worktree. Exit 3 means the Spec is already taken; the output says whether it is `active` or `interrupted`:
   - `active`: another live Run holds it, or find-next has reserved it for a session it is starting. Tell the user which worktree, and stop. Never work on it in parallel.
   - `interrupted`: this is **Recovery** (GLOSSARY.md). Ask the user to confirm, then `claim.sh resume <n>` (rewrites the record with this session as holder) and continue under "Recovery" below.

   When find-next started this session (`launch-wave.sh`), it reserved the Spec first (a **handoff reservation**, GLOSSARY.md) and this session already runs inside the Spec's worktree on branch `spec-<n>`. `take` then adopts the reservation instead of creating anything: exit 0 prints the current directory, which is the integration worktree (a fresh Spec); exit 4 prints it too and means Recovery that find-next already decided on, so continue under "Recovery" without asking again.
3. **Blocked Spec.** If every open ticket is blocked by tickets outside this Spec that are not merged into the main branch yet (its frontier is empty), say what blocks it, `claim.sh release <n>`, remove the just-created worktree and branch if they have no commits, and stop.
4. In Orca (`ORCA_WORKTREE_ID` set and `orca` on PATH), also mark the session for the user: `orca worktree set --worktree current --issue <n> --workspace-status in-progress` and `orca terminal rename --title "spec-<n> <short title>"`. This is display only; the claim record is what other Runs and find-next read.
5. Exactly one Spec per Run. With the `codex`/`pi` backends, `--parallel` / `GLM_MAX_PARALLEL` counts this Run's External workers only; on top of that, every External worker on the machine queues for one of the shared worker slots (see "External workers"). With the `agent` backend, `--parallel` instead caps this Run's concurrently running implementing subagents (implementer, fix, merger, exploration); without it the agent backend stays unlimited, the historical `sonnet` behaviour. Agent subagents do not take machine-wide worker slots — with the agent backend the total is governed by find-next's workers ÷ specs split, not by the slot file.
6. If the backend is `codex` or `pi`, run the preflight from "External workers" now, before any other work.

### Tickets blocked by another Spec

Some open tickets may be blocked by tickets that belong to another Spec (or a standalone issue) not yet merged into the main branch. Build only the rest. Never implement the other Spec's scope inside this one, not even a "small shared helper": that is how one judgement got written twice in #222 and #223. Leave those tickets open, finish and land the rest, keep this Spec open, and say in the final report which tickets wait for which Spec. This is a **partial landing** (step 10): it ends the Run cleanly and is never a reason to park.

If you need to know whether the blocking Spec is being worked on, check it fresh at that moment with `claim.sh status <m>` together with the issue state. Never conclude "nobody is working on it" from the issue being open, and never reuse what you saw in step 0.

### Recovery

**Clock first.** When resuming this Run, continuing after `/clear`, or judging how long a role or process has run and whether it is still alive, run `date` first for the current time, then `ps -o pid,etime,time,command -p <pid>` for the process's elapsed time (`etime`) and CPU time (`time`); never derive a duration from clock times found in logs. A process whose elapsed time is long while its CPU time is near zero is stalled — treat it as stuck, not as working.

Never read `run.json`: it is display-only and may be stale or missing. GitHub and the worktrees are the only source of truth. Continue the Spec on its existing integration branch and integration worktree (`git worktree list` shows where `spec-<n>` is checked out). Closed tickets count as already merged; only the open ones form the frontier. Then, for each leftover ticket worktree of this Spec (`spec-<n>-t<m>` in `git worktree list`), with its newest run dir under `~/.cache/implement-spec-split/runs/<repo>-<n>-*/`:

- its wrapper still running (`pgrep -f <run dir>`, or `progress.sh` says `running` / `queued`): wait for it, never kill it;
- `status.json` present: handle it by the exit-code rules under "External workers", as if this Run had launched it;
- no `status.json` (the wrapper died with the old session): treat as `error`. If the ticket branch has commits, keep the worktree and re-brief in it with a fresh run dir; otherwise remove the worktree and dispatch the ticket afresh.
- With the `agent` backend there are no run dirs: a ticket worktree with commits goes through the verification gate, one without is removed and redispatched.

## Steps

**Phase marks.** At each phase change run `<skill dir>/scripts/run-phase.sh <phase> --repo <repo> --spec <n> --wave <w> --merged <a> --in-progress <b> --todo <c>` (`<w>` from the launch state if known; counts from the frontier). It writes `run.json` in the Spec's Run directory for the Progress board only; a failed write just warns, so never act on its output. Phases: `split`, `implement`, `integrate`, `review`, `land`, `waiting`, `parked`, `done`.

"Dispatch <role>" below means: with the `agent` backend, an In-session subagent with `model:` the agent model (`--agent-model`, default `IMPLEMENT_MODEL`); with the `codex` or `pi` backend, an External worker (see below).

**Implementing roles do not re-delegate.** With the `agent` backend, the implementer, merger, and fix roles write the code and make the commits themselves in their assigned worktree. They never start another worker (`codex`, `pi`, `claude`, `claude-glm`, or `orca orchestration worker-start`); if a hook blocks them, they stop and state that in their report. Deterministic formatting commands (`gofmt -w`, `goimports -w`, `go fmt`) do not count as writing source: any role runs them directly instead of dispatching a worker for them. No role starts a background process and then ends its turn to wait for a notification; if it must wait, it waits in the foreground with a sufficient timeout. External workers are started only through their wrapper scripts (`scripts/codex-worker.sh` / `scripts/pi-worker.sh`).

**No unresolvable `rm`.** Claude Code asks for confirmation, even under `--dangerously-skip-permissions`, when a Bash command contains an `rm` it cannot resolve statically; an unattended Run then sits at that prompt until a human answers (on 2026-11-24 a spec-18 implementer blocked 45+ minutes on `rm -rf "$S/stage"` inside a compound command that also passed `rm -f` to a wrapper script). Copy this rule verbatim into every implementer, merger, fix, and exploration prompt with the `agent` backend: “Run any `rm` as its own Bash command with literal paths: no variables, globs, `$(...)`, or `sh -c` strings, and never chained with `&&`, `;` or pipes. Do not pass `rm` as an argument to a wrapper script; call `docker rm <name>` directly. Prefer fresh directory names over deleting and recreating one.”

**Progress tabs.** After dispatching an implementing role (implementer, merger, or fix), when `ORCA_WORKTREE_ID` is set and `orca` is on the `PATH`, open one read-only Orca terminal tab for that dispatch with the script below; never run `orca terminal create` or parse its JSON yourself. Use the worktree being implemented (the integration worktree for merger and fix), the integration branch as `--base`, and these titles: `spec-<n> t<m>` for an implementer, `spec-<n> merge t<m>` for a merger, `spec-<n> merge main` for the merger dispatched for a main-merge conflict (step 9.1), and `spec-<n> fix` for a fix role:

```bash
<skill dir>/scripts/progress-tab.sh open --record <Spec Run root>/orca-tabs.txt \
  --title "<title>" -- --worktree <watched worktree> --base spec-<n> [--run-dir <worker run dir>]
```

Pass `--run-dir` only for the `codex` and `pi` backends. The script creates the tab, takes the handle from the JSON and appends the title and handle to the record; when the record already has the title it opens nothing. **Close a tab as soon as its role ends**, with one command:

```bash
<skill dir>/scripts/progress-tab.sh close --record <Spec Run root>/orca-tabs.txt \
  --title "<title>" [--title "<title>"]
```

A ticket's merger that merged and passed its tests closes both the implementer's and the merger's tab (`spec-<n> t<m>` and `spec-<n> merge t<m>`, step 5); `spec-<n> fix` closes when the fix role ends, successful or not (step 8); `spec-<n> merge main` closes when the main-merge merger ends (step 9.1). Dispatching the same role again opens a fresh tab because its record line is gone. This is display only: a failed create, JSON parse, record write or close is a warning and must not affect the flow.

**Watchdog.** After dispatching any implementing role (implementer, merger, or fix — every backend), if no watchdog is running for this Run, start one with Bash `run_in_background: true`:

```bash
<skill dir>/scripts/run-watchdog.sh --watch <worktree>[=<worker run dir>] [--watch ...] \
  [--stall 2700] [--interval 300] [--max 7200]
```

Pass one `--watch` per currently running role: the worktree it changes (the integration worktree for merger and fix), with `=<run dir>` appended for `codex`/`pi` workers. Set the Bash `timeout` to `(--max + 600) × 1000` ms. When new roles are dispatched, stop the old watchdog and start a fresh one over the new set. When its completion notification arrives, read the exit code and the lines it printed:

- `0` (every watched worktree is gone) or `2` (still progressing at `--max`): if any role is still running, start another watchdog.
- `3` (no fingerprint progress for `--stall`): for an External worker, first run `progress.sh <run dir>` — the wrapper has its own Idle timeout; while the wrapper is alive, just re-arm the watchdog. For an In-session subagent, SendMessage it for status and tell it to finish in the foreground, and check with `ps` for processes it started (the Clock-first rules in Recovery apply). If the next watchdog report flags the same role again, treat it as `stalled`: stop that role; re-dispatch in place if its worktree has commits, otherwise dispatch fresh; count it toward the consecutive-failure rules (the Unattended-landing and Flash-mode second-failure rules below still apply).

1. Mark `split` (run-phase.sh), then read the spec and tickets and compute the frontier. The issue tracker comes from the repo's `docs/agents/issue-tracker.md`; if missing, tell the user to run `/setup-matt-pocock-skills`. **The frontier comes only from `scripts/frontier.sh`**, never from your own reading:

   ```bash
   <skill dir>/scripts/frontier.sh --repo <owner/name> --spec <n>
   ```

   The ticket numbers printed before the first `# ` heading are the frontier, one per line; `# blocked` lists blocked tickets with their open blockers; `# human` lists `ready-for-human` tickets (never dispatch those); `# shelved` lists shelved ones. The script applies the Spec-to-Ticket resolution rules in step 0 (including a single-ticket Spec whose only Ticket is the referenced map implementation ticket) and reads the tracker's blocking relationships (`dependencies/blocked_by`). A ticket with any open blocker is not in the frontier, whatever the code or ticket text seems to say; never build the graph from your own reading of which code a ticket needs, and do not query `blocked_by` yourself to second-guess the script. **If the script fails** (non-zero exit), wait 30 seconds and run it once more; if it fails again, park with category `transient` (see the Park section). If you believe an edge is wrong or missing, say so in the final report and leave the edge as it is; do not implement around it (on 2026-11-25 a flash Run on proxy-hub Spec #21 drew its own dependency table from the code, judged #44 "only needs Spec ①", and landed it while its blockers #40 and #42 were still open).
2. (optional) Dispatch an exploration role. It saves its markdown notes in a directory outside the repo, accessible by all later roles, so implementers can focus on implementation. It must not modify the repo.
3. The integration branch `spec-<n>` and its worktree were created in step 0; mergers and the final steps run in that worktree, never in the session's own directory. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.
4. Mark `implement`, then dispatch one implementer per frontier ticket, each in its own worktree + branch named `spec-<n>-t<m>` (worktree at `<repo parent>/<repo>-wt/spec-<n>-t<m>`), in the background; open the implementer's progress tab after each dispatch. If a git command fails on an existing `.lock` file (parallel Runs share one repository), wait a few seconds and retry, at most 3 times; never delete `.lock` files. An **ops ticket** (see [Ops tickets](#ops-tickets)) is the exception: no TDD and no commit required, and its verification gate is the ticket's acceptance criteria. Each one:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - builds the ticket with the `mattpocock-skills:tdd` skill (In-session: via the Skill tool; External: loaded with `--skill`);
   - commits, leaves no uncommitted changes, and merges the integration branch tip into its own branch before reporting done.
5. When an implementer completes, mark `integrate` (re-mark `implement` if tickets remain), verify it (External workers: the verification gate below), then dispatch a merger that merges its work into the integration branch and re-runs the test suite, and open that merger's progress tab. When that merger has merged the ticket and its test run passes, close both progress tabs with `progress-tab.sh close --record <Spec Run root>/orca-tabs.txt --title "spec-<n> t<m>" --title "spec-<n> merge t<m>"` (see Progress tabs). **Run one merger at a time**; queue the rest.
   - For Go repos, the merger also cross-compiles for the other platforms CI builds (`CGO_ENABLED=0 GOOS=linux go vet ./...` and `CGO_ENABLED=0 GOOS=darwin go vet ./...`, or `GOOS=windows` when running on Linux/macOS). A local suite only proves the host platform: files named `*_windows.go` / `*_linux.go` etc. are silently excluded elsewhere, so a green local run can hide a red CI lane.
6. If this changes the frontier, recompute it with `frontier.sh --repo <owner/name> --spec <n>` (step 1; the same retry-once rule applies) and dispatch implementers for the newly unblocked tickets it lists, and for nothing else. Never promote a ticket because the code or the ticket text suggests its blockers are done.
7. **Review (the split point).** Mark `review`. When all tickets are merged (except those waiting for another Spec, see "Tickets blocked by another Spec"), call the Skill tool with `mattpocock-skills:code-review` (not the built-in `code-review`, which does not spawn the two axis sub-agents) on the integration branch, using the branch point from the main branch as the fixed point. When it spawns the Standards and Spec sub-agents, set `model: REVIEW_MODEL` on both. Do not skip this step, do not downgrade the model, and never hand review to an External worker. In Flash mode, see "Flash mode".
8. Save the review report to a file outside the repo and dispatch a single fix role with that file as its context pointer, then open the fix progress tab and close it when the fix role ends, whatever the outcome (see Progress tabs). If an item is a design-level or subtle correctness problem rather than a mechanical fix, tell the fix role to report it back instead of guessing, then resolve it yourself or ask the user. In Flash mode, see "Flash mode". **The review → fix → re-review loop is capped at 3 rounds per Run**: the full-Spec review and each conflict review count separately (a conflict review starts its own counter, so one Run can run at most 3 full-Spec rounds and 3 conflict rounds). After the third re-review, when findings remain: only mechanical items or items marked "可以不改" → land anyway and list them as known leftovers in the landing report; any correctness problem → park with category `error`. On 2026-11-25 spec-19 ran four rounds (fix-review → fix-conflict → fix-conflict2 → fix-conflict3) and every re-review produced new findings, so the loop had no floor.
9. **Land, holding the repo's landing lock.** Mark `land` first. In Flash mode, see "Flash mode". Several Runs land into the same main branch; without the lock one Run's tested result is no longer what it merges (on 2026-11-12 three Specs landed within five minutes and a merge lost content). Confirm with the user before pushing/closing if they haven't already authorised it (with `--auto-land` they have: do not ask), then:

   ```bash
   <skill dir>/scripts/lock.sh acquire land --scope repo     # run in the background; it returns when the lock is yours
   ```

   Exit 2 means it waited `--wait` seconds and another live Run still holds it: if that Run has held it for over 30 minutes, ask the user whether to take it over (`lock.sh release land --force`) or keep waiting; otherwise acquire again. Holding the lock, in this order:
   1. `git fetch origin`, then in the integration worktree merge `origin/<main branch>` into `spec-<n>` and re-run the test suite (and the cross-compile vets for Go). On conflicts dispatch a merger to resolve them, open its progress tab (title `spec-<n> merge main`; close it when that merger ends — see Progress tabs), and tell the user, who decides whether conflicts in this Spec's core changes need another review.
   2. Merge in a temporary worktree, never in the main checkout (the user or another session may be working there): `git worktree add --detach <repo parent>/<repo>-wt/land-<n> origin/<main branch>`, `git merge --no-ff spec-<n>` there with the repo's usual merge message (e.g. `Closes #n`), then `git push origin HEAD:<main branch>`. If the push is rejected because origin moved, go back to step 1; do not force-push.
   3. Update the local main branch only if that is safe: if the main checkout is on the main branch and clean, `git -C <main checkout> merge --ff-only origin/<main branch>`; otherwise leave it and say so. Remove the temporary worktree.
   4. `lock.sh release land --scope repo`. Release it on every exit path, including failures and the user saying stop.

   If the tracker closes work through PRs instead (a draft PR exists), skip 2–3: mark the PR ready for review and release the lock. Then resolve each ticket the way the tracker closes work. Close the Spec too, and every map implementation ticket on its `实现票` line, even when that implementation ticket has its own sub-issues: an implementation ticket left open after its Spec closes looks unfinished to the tracker, and `find-next` / `pipeline-status.sh` may list it as needing a spec again. When tickets still wait for another Spec, land what is done but keep the Spec, those tickets and the implementation ticket open.
   **Completion conclusion (after a completed landing only).** Once the tickets and Spec have been closed as above — after a direct landing, or after an unattended PR merge — run:

   ```bash
   <skill dir>/scripts/completion-report.sh <主 checkout> --spec <n> --notify
   ```

   and save the output verbatim to `<Spec Run root>/completion.txt`. Do not run it after parking, a user-declined landing, or a PR that has not merged. The script is read-only and deterministic (it never tags and never pushes, so Flash mode needs no special handling); if it exits nonzero, relay stderr and continue without `completion.txt` — the landing itself is already done.

   5. **Start the next wave only after a completed direct landing.** If and only if step 2's `git push` succeeded, step 3 has handled the local main branch (including the safe case where it had to be left untouched and reported), and the landed tickets — and the Spec, unless tickets still wait for another Spec (a partial landing also runs this substep) — have been closed as described above (check with `gh issue view <n> --json state`; `Closes #n` closes asynchronously, and a Spec or ticket still open makes its dependents look blocked, so the script would report “无可启动”), run exactly this one launch script:

      ```bash
      <skill dir>/find-next/scripts/launch-wave.sh --repo <owner/name> --next-wave --apply
      ```

      `find-next/` is deliberately relative to this skill's root: the symlink installation points at the same repository checkout, so this works without another configuration variable.
      Relay its result lines verbatim, then finish this Run: do the step-10 cleanup and final report, and **do not pick up another Spec in this session**. The report must name the Specs it started, or say “无可启动”. The script recalculates the order, reuses only the cached workers/specs/apart choices (plus the backend and unattended-landing choice find-next recorded — agent runs keep generating `--impl agent --agent-model <model>` commands, state files without the backend field keep `--impl codex`, and state files without the `auto_land` field keep landing unattended), holds a repository-wide `launch-wave` lock while reserving and starting Specs, and starts each newly free first-wave Spec in a fresh Orca session. Starting fresh is deliberate: by landing time this session is full, while the next Spec's facts are all in its issue and main, so a new session saves tokens and avoids dragging in this Spec's context. Do not run this substep for the PR path (except an Unattended landing that merged its PR, see below), a rejected push, a user-declined landing, or an unfinished merge; if the script exits nonzero (for example a dependency cycle), relay its message and stop—do not launch anything else here.

   **Follow-up tickets opened while landing** (leftovers, cleanup items): every one must, at the same time, (a) be attached to this Spec with `gh api -X POST repos/{o}/{r}/issues/<spec>/sub_issues -F sub_issue_id=<id>`, (b) have every ticket it depends on registered with `gh api -X POST repos/{o}/{r}/issues/<t>/dependencies/blocked_by -F issue_id=<id>`, and (c) leave the Spec open as a **partial landing** (step 10). `<id>` is the issue's `id` field (`gh issue view <n> --json id --jq .id`), not its number. Writing "依赖规格②" in a title or body is **not** a dependency: the tracker's graph is the only thing `pipeline-status.sh`, `frontier.sh` and find-next read. On 2026-11-25 spec-22 opened #50/#51/#52 this way, wrote the dependencies only into their titles, never attached them, and then closed the Spec; the three became loose issues that the tracker's blocking graph still called ready.

10. Run `<skill dir>/scripts/progress-tab.sh close-all --record <Spec Run root>/orca-tabs.txt --spec <n>`: it closes every recorded tab and scans the Orca terminal list for this worktree's `spec-<n> …` progress tabs, ignoring failures. Then clean up all implementer worktrees, run `claim.sh release <n>`, and mark `done` (`waiting` when the Spec stays open with tickets waiting for another Spec; `parked` only when the Run parked). In Orca, set the session's worktree to `--workspace-status in-review` (PR open) or `completed`, and retitle the tab `spec-<n> ✓`. A Spec left open for follow-up tickets opened in step 9 is a partial landing: mark `waiting`, keep the Spec open, and list those tickets in the final report.
    - **Partial landing** (the Spec stays open only because tickets wait for another Spec): this is not parking and needs nobody. Everything on `spec-<n>` is now in main, so delete the integration branch once `git merge-base --is-ancestor spec-<n> origin/<main branch>` holds (the worktree removal below does it, or `git branch -d spec-<n>` outside Orca), and delete every merged ticket branch `spec-<n>-t*` with `git branch -d` (any leftover `spec-<n>-*` branch still makes the Spec look interrupted). Without the branch the Spec counts as free again, so a later `--next-wave` (from another Spec's landing or from find-next's supervisor) starts it afresh as soon as its blockers land and its frontier is non-empty. Never keep the branch "for resuming": a kept branch shows as interrupted, holds a wave slot, and `--next-wave` never resumes it.
    - **Close this session (Unattended landing only).** A Run started without `--auto-land` keeps its session: the user is in it. With `--auto-land`, after the issue comment (landing or parking report) is posted and every other step is done, the very last command of the Run is `<skill dir>/scripts/close-self.sh`, with `--remove-worktree <integration worktree>` after a full or partial landing (it removes the worktree and branch only when clean and merged, else just closes the tab), and without it after parking (the worktree keeps unlanded work for Recovery). Print nothing important after it: the session ends there. Progress and decisions are relayed by find-next's supervisor, not by this session. The Stop hook `hooks/unattended-stop-guard.js` enforces this: an unattended session whose Run is `done` / `waiting` / `parked` cannot end before running `close-self.sh`, and one whose last message asks a person cannot end at all.

## Ops tickets

An execution ticket is an **ops ticket** when its body says it is carried out through ssh-manager, it has a `## 护栏` section, or it carries the `ops` label. Ops tickets are still dispatched to an implementer, with these differences:

- **Agent backend**: the prompt says it may use the `mcp__ssh-manager__*` tools — call `mcp__ssh-manager__list_servers` first for the real `server_id` and read that server's `caveats` / `role` / `services` before acting — and copies the ticket's `## 护栏` section verbatim.
- **Codex backend**: add `--mcp ssh-manager` to the worker command (see "External workers"), and copy the same `## 护栏` section verbatim into the Brief.
- **Guardrails and acceptance**: when the implementer would have to break a guardrail, or the ticket's acceptance criteria cannot be met, it only reports — it never pushes through. The main session parks with category `error`, and the parking report includes the rollback steps (what was changed on the remote host and how to undo it).
- **No TDD, no commit required**: an ops ticket is not built with the `tdd` skill and does not need a commit. When it changes no code, the implementer's verification gate becomes "every acceptance criterion on the ticket has evidence" (command output, service status, a screenshot), not the `new_commits` / clean-tree checks.

`ready-for-human` tickets are never dispatched, ops or not: `frontier.sh` keeps them out of the frontier and lists them under `# human`, and `pipeline-status.sh --all` reports them as `人工票待做：#n`.

## Unattended landing (`--auto-land`)

This batch lands without the user, typically to run overnight: `launch-wave.sh` starts every Run with `--auto-land` by default (`--no-auto-land` opts a batch out), so nobody will answer a question, and by morning this session's cache has expired, so waiting costs tokens and gains nothing. A Run started by typing `/implement-spec-split <n>` without `--auto-land` is not unattended and keeps its confirmations. Two rules decide everything here: save tokens, and never sit waiting for a person. Wherever this file says "ask the user", "tell the user" or "confirm", apply the matching rule below instead; anything not listed means **park** (see below).

- **Watchdog**: the Watchdog rule in Steps is mandatory here — keep one running after every dispatch of an implementing role; an unattended session must never sit waiting only for notifications.
- **Landing (step 9)**: no confirmation.
- **Design-level review items (step 8)**: resolve them yourself when the Spec, its tickets or an ADR already answer them, and record each decision in the landing report. A real trade-off with a recommendation is **auto-decided**: apply the recommended option (one fix role for all of them, after the mechanical fixes), and list each under `### 自动拍板（可推翻）` in the landing report: the question in one line, the option taken, the rejected options, and the commit. Park only for an item that is marked `可自动采纳：否`, has `推荐：无`, or (in a non-flash session writing its own items) would be irreversible or outward-facing, or needs a human action or knowledge only a human has. Owner decision 2026-11-25: in the proxy-hub Runs the user picked the recommended option in 10 of 11 such items, and the one exception had no recommendation, so parking for them only cost a night. Open and close that fix role's progress tab as Progress tabs says. The step-8 review-round cap applies unchanged: at most 3 review → fix → re-review rounds per review stream; after the third, mechanical-only leftovers land and are reported, and any correctness leftover parks with category `error`.
- **Follow-up tickets (step 9)**: a leftover or cleanup ticket opened while landing is attached to the Spec, has each of its dependencies registered with `blocked_by`, and leaves the Spec open as a partial landing. Never write dependencies only into a title, and never close the Spec on top of such tickets (on 2026-11-25 spec-22 left #50/#51/#52 as loose issues that the tracker still called ready).
- **Main merge (step 9.1)**: conflicts — dispatch a merger, then run one `REVIEW_MODEL` review of the conflict resolution only (`mattpocock-skills:code-review` with the pre-merge `spec-<n>` tip as fixed point); clean → continue, findings → one fix role, then continue if green. Failing tests after the merge — dispatch a fix role with the failure output, at most 2 rounds, then park. Open and close these roles' progress tabs as Progress tabs says.
- **PR path**: instead of only marking the PR ready, mark it ready, wait for its checks (`gh pr checks <pr> --watch`, in the background), then `gh pr merge <pr> --merge`. Red CI — read the failing logs (`gh run view <id> --log-failed | tail`), dispatch a fix role, push, watch again; at most 2 fix rounds, then park. After the merge, close tickets/Spec as for a direct landing and run step 9.5 as if step 2's push had succeeded. Open and close the fix role's progress tab as Progress tabs says.
- **Landing lock held over 30 minutes by another live Run**: keep waiting, do not take it over; after 2 hours, park.
- **External worker exit codes**: `transient` — wait 10 minutes (`sleep 600` in the background) and re-brief once; a second failure parks. `quota` — stop dispatching, let running workers finish, then every 30 minutes run the backend preflight in the background (`sleep 1800 && <preflight>`); when it passes, continue where you were; after 5 hours, park. `auth` — park. Second `timeout`, second `error`/`stalled`, or a second failed verification gate — park (no third attempt).

**Park** = post a **Parking report** (GLOSSARY.md) on the Spec issue with `gh issue comment`. Parking means this Run stops here: for categories `quota` and `transient` the keeper daemon resumes it automatically after the stated 可恢复时间, for the others a human must act first. Tickets waiting for another Spec are a partial landing (step 10), never parking. The report has a fixed shape, because find-next's supervisor relays its first section to the user verbatim and keeper reads the two machine-readable lines:

```
## 停车报告
停车类别：decision
可恢复时间：无

### 需要你决定
1. <question in one or two lines>
   A. <option> — <cost>
   B. <option> — <cost>
   建议：<option> — <reason>（或「无建议：<why>」）
（an error stop instead lists the one human action needed, e.g. "GLM 额度用完，可恢复时间 2026-11-26T07:00:00+08:00，keeper 会自动恢复，无需回『继续』"）

### 现状
<what is already merged into spec-<n>, tests, branch, run dirs>
```

The two lines right after `## 停车报告` are mandatory and come before `### 需要你决定`:

- `停车类别：quota|transient|decision|error|other`
- `可恢复时间：<ISO 8601 含时区>|无`

| 类别 | 场景 | 可恢复时间 |
|---|---|---|
| `quota` | 额度用尽或 429 | 额度重置时刻；不知道就填当前时间 + 5 小时 |
| `transient` | 网络或端点临时错误 | 当前时间 + 30 分钟 |
| `decision` | 要人拍板 | `无` |
| `error` | 重复失败或验收不过 | `无` |
| `other` | 其他 | `无` |

keeper (`scripts/keeper.sh`) reads these two lines and resumes `quota` and `transient` parks automatically once 可恢复时间 has passed, so "额度用尽" is never written as "等人恢复" any more. `decision`, `error` and `other` still need a human.

No other wording for the next step ("回 find-next 选『先恢复』" and the like): the supervisor writes the user's answers back as a `## 拍板` comment and restarts the Run. Mark `parked`, then release the landing lock if held, let running workers finish or leave them (Recovery handles them), do step 10 except that the Orca status is `in-review` and the tab `spec-<n> ⏸`, and end the Run. Do not run step 9.5. Other Specs of the batch carry on independently.

**Resuming after parking**: in Recovery, read the Spec issue's comments; the newest `## 拍板` comment after the newest `## 停车报告` holds the user's answers. Apply them (one fix role for all answers, then step 7's review only of that fix; open and close its progress tab as Progress tabs says) and continue to landing. The `## 拍板` answers count as authorised for this Run: do not park on the same items again.

**Landing report**: after a successful unattended landing, post the final report (below) on the Spec issue as `## 落地报告`, condensed but in the same order as "Report at the end" (completion.txt verbatim, then the `## 结论` block with 要你做的, then details): tickets landed, review findings and how each was resolved, `### 自动拍板（可推翻）` (omit when empty), tickets left waiting for another Spec (`剩余：#<t> 等 #<spec>`, one line each), and the Specs step 9.5 started. The user reads it through find-next's supervisor or GitHub, not by reopening this session.


### spec-keeper (the daemon that resumes unattended Runs)

launchd runs `scripts/keeper.sh` every 10 minutes (service in `~/ops/services/spec-keeper/`) for repositories whose launch state does not set `auto_land` to false:

- a parking report with `停车类别：quota|transient` whose `可恢复时间` has passed → `launch-wave --only <n> --apply`;
- a claim that turned `interrupted` with no newer report → resumed the same way;
- a claim still `active` with no write to the session transcript (subagents included), the Run directory or the worker run directories for 45 minutes → it types one line into the session terminal: 「继续。你是无人值守 Run：检查后台任务和 worker 状态，按 SKILL.md 推进；不要等人。」; after another 45 minutes with no write it closes the terminal, force-releases the claim and resumes;
- `decision` / `error` / `other` parks are only notified, once per report.

At most 3 automatic resumes per Spec per 24 hours, then it only notifies. **When that 「继续」 line arrives, treat it as a wake-up, not as a user decision**: check background tasks and workers as in Recovery and carry on. So write the two machine-readable lines of every Parking report correctly: they decide whether the Run comes back by itself.

## Flash mode (`FLASH_ORCHESTRATOR=1`)

This mode is for a flash Orchestrator: the session itself is GLM, so a subagent named `opus` is not an Opus review. The rules below replace the matching Config, step 7–9, External-worker retry, and Unattended-landing rules when both apply; behavior not listed here is unchanged.

- **Backend**: with `IMPLEMENT_BACKEND=auto` and no `--impl`, choose `agent`. The flash environment maps both `sonnet` and `opus` agent-model names to glm-5.4, so every implementing subagent is a glm-5.4 subagent. delegate-guard permits source writes from dispatched subagents whose hook payload carries a non-empty `agent_id`, so agent-backend implementers, mergers, and fix roles write source directly in their assigned worktrees. Copy this rule verbatim into every implementer, merger, and fix prompt: “If a source-write hook blocks you, stop and state that in your report. Do not work around it: do not use `env -u FLASH_ORCHESTRATOR`, do not start another `claude`, `claude-glm`, or `codex` process, do not use `orca orchestration worker-start`, and do not write source through Bash to bypass the hook.” Normal `--impl` and `--agent-model` precedence is unchanged. The worker wrappers refuse to start when `FLASH_ORCHESTRATOR=1`; only with an explicit `--impl codex` / `--impl pi`, prefix every wrapper call with `WORKER_ALLOW_FLASH=1`. Never set it otherwise, and never start a worker outside this skill.
- **Step 7 review**: do not call `mattpocock-skills:code-review` in the session and do not spawn an `opus` subagent. Compute the integration branch's fork point from the main branch (`git merge-base <main branch> spec-<n>`) and run:

  ```bash
  <skill dir>/scripts/opus-review.sh --kind code \
    --input <fork-point commit> --out <run dir>/opus-code-review.md \
    --cwd <integration worktree>
  ```

  Save and use that findings file for step 8.
- **Step 8 findings**: mechanical findings go to the fix role as usual; open and close its progress tab as Progress tabs says. If deciding whether a design-level or subtle correctness finding agrees with the Spec, its tickets, or an ADR would require a judgment, run another Opus review (`--kind code` against the same fixed point, or `--kind diagnose` when presented as a failure record) and follow its findings rather than deciding in the flash session. The step-8 round cap applies here too: at most 3 review → fix → re-review rounds per review stream; after the third, mechanical-only leftovers land and are reported, and any correctness leftover parks with category `error`.
- **Step 9 conflicts**: dispatch a merger to resolve conflicts, but do not ask the user whether the resolution needs review and do not review it in-session. Record the pre-merge `spec-<n>` tip, then run `opus-review.sh --kind code --input <pre-merge spec-<n> tip> --out <run dir>/opus-conflict-review.md --cwd <integration worktree>`. Follow its findings: clean → continue; findings → one fix role, tests, and another code review of the conflict resolution. Open and close the merger's and the fix role's progress tabs as Progress tabs says.
- **Two consecutive failures**: count failures per role and ticket across both backends. On the second consecutive failure, before re-briefing again or asking the user, write a failure record outside the repo containing the role, ticket, both result/status paths, the relevant error tails, and what the verification gate observed; then run `opus-review.sh --kind diagnose --input <failure-record> --out <run dir>/opus-diagnosis.md`. Continue, change the Brief, or stop exactly as the findings direct.
- **Stopping**: the flash session decides nothing itself; it must not invent its own trade-off or parking decision, and must not settle an item by its own reading, not even one that looks answered by the Spec (on 2026-11-21 a flash session "ruled by the Spec" on two of five such items, one of which asked a human to check the Spec text Opus could not read). It acts only on Opus's own marks under `## 需要人取舍`: with `--auto-land`, an item with `可自动采纳：是` is applied as recommended and recorded under `### 自动拍板（可推翻）` (see Unattended landing); an item with `可自动采纳：否`, `推荐：无`, or no `可自动采纳` line parks the Run, and its parking report's `### 需要你决定` copies those items as written. Without `--auto-land`, relay every item to the user as written. This does not limit error stops below.
- **Opus review errors**: 退出码为 3（额度或 429）时按 quota 停车，其余非 0 退出码仍按原规则停车并说明（退出码含义见 scripts/opus-review.sh 头注释）。Do not retry automatically, downgrade to GLM, or review in-session; the judgment model switch below is applied by `opus-review.sh` on every call, never by you. A quota park carries 停车类别 `quota` and the reset time as 可恢复时间, so keeper resumes it automatically.
- **Judgment model switch**: `scripts/judgment-model.sh`, which only the user runs (as `/judgment-model`), holds the global switch (GLOSSARY.md) with two roles, `grill` for Design sessions and `review` for every Opus review, each on `opus` (the default) or `glm-5.4`. `opus-review.sh` reads the `review` role on every call, so a Run that is already executing changes model at its next review. When its stderr says the switch is glm-5.4, the findings file starts with a `判断模型：glm-5.4…` line: act on the findings exactly as on any other, and say in the landing report and the final report that the reviews ran on glm-5.4 in place of Opus. Never change the switch yourself.
- **Stage route**: the route table (see "Stage route" under "External workers") applies to every `codex-worker.sh` dispatch, including an explicit `--impl codex` Run started with `WORKER_ALLOW_FLASH=1`. It has no effect on a flash Run on the default `agent` backend, whose subagent models the launcher fixes. Never change the table yourself: only the user runs `/grill-router`.
- **Reports**: in both the final report and an Unattended-landing report, give every conclusion the path of the findings or role result that supports it (for example `<run dir>/opus-code-review.md`, `<run dir>/opus-diagnosis.md`, or a role's `result.md`). Require in-session roles to write their final reports to durable result files. Omit a conclusion for which no such path exists.

## External workers (backends `codex` and `pi`)

An External worker is a wrapper script (in this skill's directory) running one headless coding-agent process. It sees none of this conversation: everything it needs must be in its Brief or reachable from it. Both wrappers share one contract (flags, run dir, `status.json`, exit codes, Resume); only these differ:

| | `codex` | `pi` |
|---|---|---|
| `<worker>` | `scripts/codex-worker.sh` | `scripts/pi-worker.sh` |
| `<model>` | the Stage route table (`/grill-router`; default `glm-5.4`, effort `high`); never passed as `--model` | `GLM_MODEL` |
| preflight | `scripts/selftest-codex.sh --only L1` (dispatches on the implementation stage's effective route) | `scripts/selftest.sh --only L1 --model <GLM_MODEL>` |
| usual preflight failure | local proxy not running (preflight address derived from the `base_url` in `config.toml`; author environment: Ferryman, `127.0.0.1:15722`), its key, or the routed model not being served | bad key or model id in `~/.pi/agent/models.json` |

**Stage route** (ADR 0004; GLOSSARY.md "Stage route"). The model and reasoning effort of every `codex` External worker — the implementing roles, find-next's research, decision and drafting workers, and the everyday hand-offs of the global Opus / codex division alike — come from the user's Stage route table, `scripts/stage-route.sh` (`~/.claude/state/stage-route`): the `research` stage for a dispatch with `--read-only`, the `implementation` stage for every other. Both default to `glm-5.4` with effort `high`. `codex-worker.sh` reads the table on every fresh run, so a Run that is already executing changes model at its next dispatch; a Resume keeps the model, effort and profile of its first segment. Priority: the stage's route when it is off its default, then an explicit `--model` / `--thinking`, then the default route. Do not pass `--model` or `--thinking` (an older version of this file did): while the stage is off its default they are overridden, and the wrapper says so with one line on stderr, also appended to the run dir's `stderr.log` — every dispatch names its stage and route there; off the default the line also names any overridden `--model` / `--thinking`, the expiry and the reset command, and it notes a model the worker home's catalog does not list. `status.json` and `resume.json` record the model, `thinking` (the effort) and `profile` actually used. When that line says a route is in effect, read `status.json`'s `model` and `thinking` to know what a worker really ran on, and say so in the landing report and the final report. A route whose model or effort codex-glm does not take (an effort of `max`, for example) is a usage error: the wrapper exits 64 without starting codex and names the route and its reset command. Never change the table yourself: only the user runs `/grill-router`.

**Preflight** (once per run, step 0): run the backend's preflight command from the table (prefixed with `<skill dir>/`). If it fails, stop and show the user the error, and name the route's current value and the reset command (the value is what `scripts/stage-route.sh` prints; the reset is that stage's line after 切回用, e.g. `/grill-router use implementation=claude-glm/glm-5.4/high`): the preflight dispatches on the implementation stage's effective route, so a failure may mean the routed model is not served, and this is the only stop before the first dispatch that can say so. Also note the local time: weekdays 14:00–18:00 Beijing time are GLM peak hours (GLM-5.x quota is charged 3x and 429s are more likely). Proceed anyway; just mention it in the final report.

**Dispatching a role:**

1. Make a run directory per worker: `~/.cache/implement-spec-split/runs/<repo>-<n>-<YYYYmmdd-HHMM>/<role>-<ticket>/` (`<repo>` = the main checkout's directory name, `<n>` = the Spec number, so Recovery finds them; the repo name keeps Specs with the same number in different repos apart).
2. Write the Brief to a file, fresh for every worker: do not derive one Brief from another with `sed` or search-and-replace (ticket numbers and branch names get left behind). Keep it to pointers and rules:
   - who it is (role, ticket number, how to read the spec and ticket, e.g. `gh issue view <n>`), worktree path, branch, integration branch;
   - exploration notes dir and, for fix, the review report path;
   - the rules for its role from the Steps above (for implementers: tdd, commit, clean tree, merge the integration tip; for exploration: do not modify the repo);
   - the repo's real test command if you know it;
   - "Final message: files changed, test command and result, anything you could not do or are unsure about."
   - (`codex`) never ask it to delete directories recursively: codex refuses `rm -rf` / `Remove-Item -Recurse` even without a sandbox. Do such cleanup yourself.
3. Run it with Bash, `run_in_background: true`, never more than `GLM_MAX_PARALLEL` at once (or the run's `--parallel` override, which replaces it for that run):

   Independently of that per-Run limit, every wrapper first takes one of the machine-wide worker slots (`ISS_MAX_WORKERS`, default 4, shared by all Runs and all repos, since they share one GLM quota). While it waits, its run dir has a `queued` file and `progress.sh` shows `queued`; the wait does not count against the Time limit. Do not treat a queued worker as stuck.

   ```bash
   <skill dir>/<worker> --cwd <worktree> --brief <brief file> --run-dir <run dir> \
     --time-limit <role Time limit> --idle-timeout <GLM_IDLE_TIMEOUT> --skill <tdd skill dir>
   ```

   (`codex`) No `--model` or `--thinking`: the Stage route decides both (see "Stage route").

   (`codex`) MCP is disabled by default: research/exploration that needs internet search adds `--mcp all`, remote-server work adds `--mcp ssh-manager`, and implementation commands omit `--mcp`.
   The role's Time limit: `GLM_TIME_LIMIT_IMPL` for implementers and fix, `GLM_TIME_LIMIT_SHORT` for merger and exploration.

   The tdd skill dir is the newest `~/.claude/plugins/cache/mattpocock/mattpocock-skills/*/skills/*/tdd`; pass it to implementers and fix only. Mergers run in the checkout that has the integration branch.
4. When it exits, read `<run dir>/status.json` and `result.md`. Do not read `events.jsonl` unless debugging a failure.
5. (`codex`) To see what a running worker is doing — when the user asks, or a worker runs long — run `<skill dir>/scripts/progress.sh <run dir>`: state (`running` / `finished` / `dead`), seconds since its last progress, the command in flight, recent commands, edits and messages, tokens. Look when needed; do not poll it in a loop (the wrapper's own watchdog handles stuck workers). `dead` means the wrapper is gone without writing `status.json` (e.g. the session that launched it ended): treat it like `error`.

**Exit codes / `status`:**

- `0` / `ok`: the worker finished without an API error. This is not success yet: apply the verification gate.
- `8` / `violation` (codex only): a `--read-only` investigation changed the workspace. Do not trust its report; hand the run directory and `changed_paths` to the orchestrator so the changes can be inspected and reverted or handled deliberately.
- `2` / `auth`, `3` / `quota`, `4` / `transient` (already retried by the agent and by the wrapper): the GLM side is unusable right now. Stop dispatching new External workers, let running ones finish, and ask the user: wait and retry, switch the remaining work to the `agent` backend, or pause. Never switch backends on your own: saving Claude quota is the point of the External backends, and the `agent` backend is a deliberate user choice, not a fallback.
- `5` / `timeout`: the worker reached its Time limit; the agent's session (pi session / codex thread) is kept and can be **Resumed** (GLOSSARY.md). Read the tail of `stderr.log` and `result.md` if any, then check `status.json` for progress. With progress (`new_commits` ≥ 1 or `dirty` is `true`), Resume it once — same worktree, same run dir, same session, no new Brief:

  ```bash
  <skill dir>/<worker> --resume --run-dir <run dir> \
    --time-limit <role Time limit> --idle-timeout <GLM_IDLE_TIMEOUT>
  ```

  The wrapper reads the worktree, model, skills, thinking level, MCP selection and session from the run dir; never pass `--cwd`, `--brief`, `--model`, `--skill`, `--thinking`, `--add-dir` or `--mcp` to a Resume. Afterwards apply the verification gate as usual: `segments` is now 2 and `new_commits` still counts from the first segment's base head, so the gate sees every commit across segments. On a second `timeout`, or a first `timeout` with no progress (`new_commits` = 0 and a clean tree), do not Resume again — ask the user.
- `6` / `error`, `7` / `stalled`: the worker failed (`stalled` = the Idle timeout fired: no progress events for `GLM_IDLE_TIMEOUT`, so the session is stuck — do not continue that session). Read the tail of `stderr.log` and `result.md` if any. Re-brief once in a fresh run dir with the failure appended; if it fails again, ask the user. In Flash mode, see "Flash mode".
  - (`codex`) Exception: a `stalled` whose `status.json` has a non-null `result_file` means codex already gave its final reply but never closed the turn (the wrapper saved that reply to `result.md`). Apply the verification gate, accepting `stalled` in place of `ok`; if every other check holds, treat the worker as done.

**Verification gate** (implementers and fix). Never trust the worker's report alone. All must hold:

- `status.json`: `status` is `ok`, `new_commits` ≥ 1, `dirty` is `false`;
- `git merge-base --is-ancestor <integration branch> <ticket branch>` succeeds (it merged the integration tip);
- the merger's test run on the integration branch passes (step 5).

If any check fails, re-brief once with what is missing; if it still fails, ask the user. For exploration, the gate is: notes exist, `new_commits` is 0 and `dirty` is `false`.

## Report at the end

The reader is the user, who did not watch the Run and reads Chinese. Write the report, and the `## 落地报告` / `## 停车报告` comments, in plain Chinese, **conclusion first**: on 2026-11-25 a spec-22 report opened with a 22-item issue list and buried the only human action (a deploy ticket) mid-way, so the user could not tell what happened.

1. If `<Spec Run root>/completion.txt` exists, put its contents verbatim at the very top.
2. Then a `## 结论` block of at most 5 lines, in this order: 结果 (landed / partially landed with `剩余：#<t> 等 #<spec>` / parked and why, one line); **要你做的** — every action only a human can take (e.g. a deploy or ops ticket left open, a parking decision), with the issue number and one line on what to do, or `无`; 自动拍板 count with a pointer to `### 自动拍板（可推翻）` (omit when none); 下一步 — what happens next without the user (Specs step 9.5 started, or `无可启动：#<n> 等 #<m>`); and any 事故 that broke a rule (e.g. pushing without the landing lock), one line each.
3. Only after that, under `## 细节`, the technical part below. Do not use internal terms in the `## 结论` block (fixed point, smell, role tables, run dirs); say it in user terms.

`## 细节`:
- Which backend and model ran each role (implement / merge / fix / review), and any role that ran on a different backend than configured, and why.
- For External workers: one line per run with ticket, status, segments (`status.json`; more than 1 means it was Resumed), duration and run directory; whether the run overlapped GLM peak hours.
- The review findings per axis, and how they were resolved.
