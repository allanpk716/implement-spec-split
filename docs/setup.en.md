# Usage and Configuration Guide

中文版：[setup.md](setup.md)

This repository provides three capabilities with dependencies between them. Configure them in stages:

| Stage | Capability | When to use it | Dependencies |
|---|---|---|---|
| 0 | Common foundation | All scenarios | None |
| 1 | `/implement-spec-split`: implement the tickets of a spec in parallel | You have a spec whose tickets are already split and want to complete it in one run | Stage 0 |
| 2 | codex backend: implementing roles use GLM instead, spending no Claude quota | You want Stage 1 implementing roles to avoid Sonnet; also a prerequisite for Stage 3 | Stage 0 |
| 3 | Global Opus / codex division of labour: in everyday sessions, Opus only makes judgment calls and delegates coding to a codex worker | Day-to-day collaboration with Claude in any project | Stages 0 and 2 |

If you only want the everyday division of labour and do not need the spec workflow: do 0 → 2 → 3. If you only want the spec workflow with Sonnet implementing: do 0 → 1. If you want everything: 0 → 1 → 2 → 3.

```
Stage 0 common foundation
 ├─ Stage 1 parallel spec implementation (Ticket workers are Orca workers on the 实现 route)
 │     └─ with Stage 2 added, the headless exploration before a Spec works too
 └─ Stage 2 codex backend
       └─ Stage 3 global division (CLAUDE.md rules + delegate-guard / unattended-ask-guard / unattended-stop-guard / land-push-guard / subagent-guard hook)
```

---

## Safety notices (read before starting)

- **Workers have full machine access**: codex workers run with `--dangerously-bypass-approvals-and-sandbox`. They can read and write any file on the machine and execute any command, without sandbox restrictions (on Windows, codex's read-only and writable sandboxes are both unavailable; see [codex-backend.md](codex-backend.md) E8). "Forbidden areas" in a Brief are instructions to the model, not enforced isolation. Do not use this on a machine that stores sensitive data and cannot tolerate a mistake; for important repositories, first make sure there is a remote backup.
- **Code is sent to a third-party model service**: Brief contents, along with source code, logs, and command output read by a worker, are sent to the model service you configure (for example, Zhipu GLM). Confirm compliance requirements before using this with company or client projects.
- **External actions are not delegated to workers**: push, opening PRs, remote server operations, and data deletion should be performed by Claude or confirmed by you. The global division rules in Stage 3 state exactly this, but they are a rule constraint rather than a technical isolation boundary.
- **The hook fails open**: if delegate-guard encounters any exception, it allows the operation so the session is not blocked. Run `scripts/doctor.sh` periodically to confirm that it is actually working.

## Applicable use case and costs

This division of labour is optimized for one specific situation: **Claude quota is tight (for example, a subscription usage limit) while another cheap or plentiful model is available (for example, a GLM coding plan)**. Before starting, confirm that this condition applies:

- **Hand-offs have a fixed cost**: every time a task is delegated, Claude must write a Brief, read the result, review the diff, and, if it does not pass, write a rework Brief. Delegating a small task can cost more, so the rules include a "change it yourself if ≤10 lines" threshold. If you pay for the Claude API by usage, or Claude quota is generous, this workflow may not save money.
- **Quality depends on review**: the worker's model is usually weaker than Opus. In the author's actual use, a worker once had all tests passing and an accurate report, but a defect fell outside test coverage and was found only by closely reviewing the diff. If review is lax, problems will slip into the code.
- **It can be slower**: each worker round takes minutes to tens of minutes, so interactive rapid iteration becomes less pleasant.
- **Cost data**: there is no systematic comparison data yet; the author is collecting it.

## Verification status

| Item | Status |
|---|---|
| Platform | Windows 11 + Git Bash: fully verified, including real GLM end to end. Ubuntu 24.04: all model-free self-tests pass (`selftest-codex.sh --only V1`, hook tests, doctor tests), but it has not been run with a real codex and GLM. macOS 27 (stock bash 3.2): fully verified with codex-cli 0.164.0, including real GLM end to end (V3, 2026-10-24) |
| codex-cli | 0.163.0, 0.164.0. Other versions are unverified; after changing versions, first run `scripts/selftest-codex.sh --only V1` |
| Model | GLM-5.4, through a local proxy |
| Stage 1 | The former `codex` wrapper backend was verified end-to-end in a scratch repo; since 规格 #26 Ticket workers are dispatched as Orca workers, and that path awaits the real-machine smoke ticket |
| find-next | Local markdown tracker: script unit tests pass, `--worker codex` run once on a real repo (2026-11-01). The GitHub path not yet run |
| Stage 3 | Hook unit tests and a local smoke test pass; rule adherence in real sessions is still being validated |
| Install commands | Plugin install commands are given using the marketplace name installed locally (`mattpocock`); `npm i -g @openai/codex` is codex's official installation method. Neither has been re-run on a fresh machine |

---

## Stage 0: common foundation

**Install**

1. Claude Code, Git, and Node.js (the scripts use node for JSON and processes).
2. Windows: Git Bash (the wrappers are all Bash scripts).
3. Clone this repository, then run the install script — since 规格 #58 that is the one install step, and it is idempotent: re-running it changes nothing once everything is in place:

   ```bash
   git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
   cd ~/.claude/skills/implement-spec-split && ./install.sh
   ```

   Both install shapes are supported: **clone-direct** (above — `~/.claude/skills/implement-spec-split` *is* the repository; the root skill's place is the main checkout's real directory, which counts as in place, so the script only links the sub-skills) and **symlink** (a clone anywhere else, for example `~/orca/implement-spec-split`, with `./install.sh` run from that clone, so all five skill links point at it). `install.sh` takes the checkout it runs in as the main checkout, and the links point there. The path `~/.claude/skills/implement-spec-split` holds in both shapes (clone-direct: it is the repository; symlink: it resolves through the link to the clone), so the Stage 3 rules and hook may reference it as it is.

   `./install.sh` does two things:

   - **Skill symlinks**: for every directory git tracks that holds a `SKILL.md` (the root skill and the sub-skills `find-next`, `grill-feature`, `grill-map`, `grill-router`) it makes `~/.claude/skills/<name>` a symlink to that directory in the main checkout — a missing link is created, a link pointing elsewhere is re-pointed, a dangling link left by a skill the checkout no longer has is removed; a real directory of the same name is never touched, only warned about. "Points correctly" is judged by the physical directory the link resolves to, so a link written by hand as `ln -s ~/.claude/skills/implement-spec-split/<name> …` (below) resolves to the same directory and counts as in place.
   - **Local configuration expectations**: a list of what the checkout expects of this machine's configuration (data built into `install.sh`), each item marked tighten or loosen. A tighten item not met (v1 has one: the `delegate-guard` PreToolUse matcher must cover `Edit`, `Write` and `Bash`) is applied after `settings.json` is backed up to `<its directory>/backups/install-<timestamp>/`; the edit is made in place with node, and the written file is validated as JSON — otherwise the backup is restored and the row is FAIL. A loosen item is never applied: it is only listed under 「未执行的放宽项」 (a section of its own in the human output, `unexecutedLoosenings` in `--json`) as a WARN, and the exit code is 1. An expectation whose hook is not registered is not drift: it is neither handled nor reported (Stage 3 is opt-in; until a hook is registered, `install.sh` only links).

   `./install.sh --check` reports and changes nothing (no link, no `settings.json`, no backup): exit 0 when everything is in place, 1 on any drift. `./install.sh --json` prints one JSON object only (the shape of `scripts/doctor.sh`: a `checks` array plus `summary`) for scripts. On Windows (Git Bash) nothing is linked or removed: each skill not in place prints one manual step (`mklink /J`, or copy) as a WARN; the expectations half only reads and writes the file through node, the same on every platform.

   To link by hand instead, the manual equivalent on macOS / Linux is these four links (on Windows use `mklink /J`, or copy; keep up yourself when a skill is added, renamed or retired):

   ```bash
   ln -s ~/.claude/skills/implement-spec-split/find-next ~/.claude/skills/find-next
   ln -s ~/.claude/skills/implement-spec-split/grill-feature ~/.claude/skills/grill-feature
   ln -s ~/.claude/skills/implement-spec-split/grill-map ~/.claude/skills/grill-map
   ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router
   ```

**Verify**

```bash
ls ~/.claude/skills/implement-spec-split/{SKILL.md,scripts,templates,hooks}
~/.claude/skills/implement-spec-split/install.sh --check      # exit 0 when all in place; exit 1 on drift, listing each one
```

After installing any stage, you can run `scripts/doctor.sh` to check it; when its "local install state" check reports drift, run `./install.sh` as its hint says.

---

## Stage 1: parallel implementation by spec (`/implement-spec-split`)

This is a modified version of [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills): the orchestration logic is the same, but each role specifies its model separately. The implementing roles (exploration / implementer / fix; merges are done by a script first and a worker only on a conflict) use a cheaper model, all dispatched by the Spec session as Orca workers through `scripts/stage-dispatch.sh`, with the launcher, model and reasoning effort taken from the Stage route table; the two code-review subagents are fixed to Opus.

**Install**

1. Install the `mattpocock-skills` plugin (this skill uses its `tdd` and `code-review` skills). In Claude Code:

   ```text
   /plugin marketplace add mattpocock/skills
   /plugin install mattpocock-skills@mattpocock
   ```

2. Run `/setup-matt-pocock-skills` once in the **target project**. It generates `docs/agents/issue-tracker.md` (which tells the skill where issues live and how to query them).

3. Orca, and on PATH the launcher the 实现 route names (`claude-glm` by default, see `scripts/stage-route.sh`; change routes with `/grill-router`): a Ticket's implementing worker is an Orca worker, and without Orca none can be dispatched. The headless exploration before a Spec starts runs `codex-worker.sh` and needs Stage 2.

**Prepare a spec**

A spec is a parent GitHub issue. Its child issues are tickets, and dependencies between tickets determine which can run in parallel. You can generate it with one of Matt Pocock's planning skills or create it manually.

**Use**

```text
/implement-spec-split                      # No argument: tells you to run /find-next --batch, which gives the order and the commands
/implement-spec-split #12                  # Specify a spec
/implement-spec-split #12 --parallel 3     # At most 3 Ticket workers of this Run at once
```

**How parallelism happens**

- The skill first reads the spec and tickets, then builds a task graph. Tickets whose dependencies are all satisfied form the "frontier"; each ticket in the frontier gets its own child worktree (under the Spec's) and is implemented in parallel.
- Merges happen serially, and a script goes first: `scripts/merge-ticket.sh` merges a ticket into the integration branch and runs the tests when there is no conflict; a worker is dispatched only to resolve a conflict.
- Concurrency limit: governed by `GLM_MAX_PARALLEL` (default 2), and `--parallel n` overrides it for the current run only. A value of 2-3 is recommended, with 4 at most during quiet hours: Zhipu rate-limits at peak times, and any worker that hits a 429 stops the whole run to ask you.
- After each ticket is complete, it must pass the verification gate and two Opus reviews (Standards and Spec) before it counts as done.
- Several specs at once: open one session per Orca worktree of the same clone and run the skill in each. Without a spec number the skill does not scan or list candidates: it says "run `/find-next --batch` first; it gives the build order and the command to type in each worktree" and stops, since what to build is decided in one place (find-next) and several worktrees started at once never scan and pick in parallel. With a number, it links the session's worktree to that issue and retitles the tab `spec-<n> …`. An in-progress or interrupted spec is listed under "resume first" in find-next's build order with its command; running that continues the unfinished work (Recovery). `--parallel` counts per run: the workers of parallel runs add up and share one GLM quota.

**The worktree tree and taking over**

- **The sidebar is one collapsible tree**, with no progress tabs (规格 #26): main session → Spec worktree `spec-<n>` (branch `spec-<n>` off `origin/main`; find-next's launch-wave creates it as a child of the main session's worktree) → Ticket worktree `spec-<n>-t<m>` (branch `spec-<n>-t<m>` off the integration branch `spec-<n>`; the dispatch module creates it as a child of the Spec worktree), each Ticket's worker in a terminal titled `spec-<n> t<m>`. The fix and conflict roles run in the Spec worktree itself. Which Spec a Ticket belongs to and how far it has got is what the sidebar shows.
- **Scripts remove worktrees**: once a Ticket is merged, `scripts/stage-dispatch.sh release` removes its worktree with its branch; once the Spec has landed, `scripts/close-self.sh` removes the remaining Ticket worktrees first and then the Spec worktree; a parked Spec keeps its worktree; the keeper sweeps abandoned ones every round (`scripts/sweep-worktrees.sh`: only those clean and merged into origin; a worktree with commits that never landed is never swept and takes a person). Do not remove a Spec worktree by hand while its Ticket worktrees exist: Orca neither refuses nor cascades, it orphans them.
- **One Orca Run per Spec**: the Spec session creates its own at step 0 with `orca orchestration run-create` (its Ticket workers report into it), and the `launch-wave.sh --apply` that started the wave created another one for that wave's Spec sessions. Closing the main session, the Spec session or any coordinating terminal stops nothing below: the workers keep running and their `worker_done` mail keeps landing in the Run. To take over in a new terminal:

  ```bash
  cat ~/.cache/implement-spec-split/runs/<repo>-<n>-<time>/orca-run-id        # one Spec's Run (that Spec's newest run directory)
  grep '"run"' ~/.cache/implement-spec-split/launch/<owner>__<repo>.json       # one wave's Run (the launch state)
  orca orchestration run-use --id <run id> --json
  ```

  After `run-use` that terminal is the Run's coordinator again (`orca orchestration run-current` names it) and `stage-dispatch.sh` `dispatch` / `wait` / `release` work from it; a Spec session that was replaced continues under the skill's Recovery. A takeover re-dispatches nothing: the workers never stopped.

Change defaults in the "Config" section of `SKILL.md`.

**Verify**

Run `/implement-spec-split <spec>` once in a scratch repository that has a spec, and observe: tickets in the frontier start in parallel, each in its own child worktree; merges are serial and go through the script first; two review reports are produced at the end. (The dispatched-worker path of 规格 #26 is verified by that spec's real-machine smoke ticket.)

---

## Finding the next step (`/find-next`)

After a wayfinder discussion leaves you with a pile of tickets and no idea which one to take to to-spec, to-tickets or grilling, use `find-next` (the second skill in this repo, under `find-next/`). It scans the current repo's maps and tickets and recommends **one** next step with the command to type, plus up to 3 alternatives:

| Priority | Situation | Command |
|---|---|---|
| 1 | A Spec with no execution tickets yet | `/to-tickets <Spec>` |
| 2 | A map whose decisions are all made but not written up as a Spec | `/to-spec` |
| 3 | A Decision ticket on a Map frontier (most downstream unblocked first) | `/wayfinder <map> <ticket>`; a ticket outside any map gets `/grill-with-docs` |

Maps and tickets marked shelved (搁置) are skipped. The implementation stage is not scanned; that is `/implement-spec-split --status`.

**Install**: Stage 0's `./install.sh` has already symlinked it into the skills directory together with the two Design-session wrapper skills and the Stage route command `/grill-router` (described in Stage 4); after the repository changes, run it again (`git pull && ./install.sh`; the landing flow runs it by itself). The manual equivalent (on Windows use `mklink /J`, or copy):

```bash
ln -s ~/.claude/skills/implement-spec-split/find-next ~/.claude/skills/find-next
ln -s ~/.claude/skills/implement-spec-split/grill-feature ~/.claude/skills/grill-feature
ln -s ~/.claude/skills/implement-spec-split/grill-map ~/.claude/skills/grill-map
ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router
```

**Use**: `/find-next [--worker codex|self]`, or just ask "what's next". For the whole picture use `/find-next --list` (or ask "what is left"): it lists every to-do (in progress, needs tickets, needs a spec, open decisions, unfinished bookkeeping, loose issues) without a worker. To write every missing spec at once use `/find-next --batch`: codex workers draft a spec plus its tickets per group, you confirm once, then they are published and you get a start order for `/implement-spec-split`.

- Default `codex`: a script does the mechanical scan (`find-next/scripts/scan.py` for local markdown trackers, `scripts/pipeline-status.sh` for GitHub), and a read-only codex worker does the judgment; the session reads only its conclusion of at most 15 lines. Needs Stage 2.
- `self`: the session judges on its own, no codex needed.
- When the answer is to-spec or to-tickets, the material is first loaded into the session, because those skills synthesize only the current conversation; then you are told which command to type.

Read-only throughout: no ticket edits, no claims. Design rationale: `MAINTAINING.md`, "find-next 设计要点".

## Stage 2: codex backend (GLM)

This makes `codex exec` do work with GLM. Both Stage 1's headless exploration and Stage 3's everyday division of labour depend on it.

**Install**

1. Install the codex CLI (tested with 0.163.0 and 0.164.0): `npm i -g @openai/codex`, then confirm with `codex --version`.
2. **Prepare an endpoint compatible with the OpenAI Responses API**. codex uses `wire_api = "responses"` to communicate with the model, so the endpoint must handle Responses API requests (`POST /v1/responses`, streaming SSE). A service that only exposes Chat Completions (`/v1/chat/completions`) cannot be used directly. Options:
   - **Local proxy**: run a proxy on your machine that exposes the Responses API externally and forwards to the model service internally while injecting the key. The author uses the proxy feature in [Ferryman](https://github.com/allanpk716/ferryman), listening on `127.0.0.1:15722`. Note that this feature is not currently documented as a public Ferryman feature.
   - **Model service with native Responses API support**: if your model provider directly offers the Responses API, point `base_url` at it.
   - **Self-hosted compatible gateway**: some open-source LLM gateways can convert the Responses API to Chat Completions. Verify codex compatibility yourself; you can test with `--only L1` below.

3. Configure a provider named `custom` in `~/.codex/config.toml`, pointing to this endpoint. The author's environment uses this form (local proxy `127.0.0.1:15722`; the proxy talks to Zhipu and injects the real key):

   ```toml
   model_provider = "custom"
   model = "glm-5.4"

   [model_providers.custom]
   name = "zhipu_glm"
   base_url = "http://127.0.0.1:15722/v1"
   wire_api = "responses"
   requires_openai_auth = true
   ```

   The provider name must be `custom`: the wrappers pin the provider with `-c model_provider=custom` and pass the model with `-m`; the model and reasoning effort come from the Stage route table (`scripts/stage-route.sh`, default `glm-5.4` / `high`). If the model is not `glm-5.4`, set the `implementation` and `research` stages to a combination in the verified catalog with `/grill-router` (for example `/grill-router use implementation=codex-glm/glm-5.3/high research=codex-glm/glm-5.3/high`) instead of passing `--model` to `codex-worker.sh`. Do not put the key in this repository.

   If you follow Zhipu's official Codex recipe (direct to `open.bigmodel.cn`), its provider is named `ZAI`: rename both `model_provider = "ZAI"` and `[model_providers.ZAI]` to `custom`; `name = "ZAI"` can stay (codex 0.164+ requires a non-empty `name`). Otherwise the worker fails with `model_providers.custom: provider name must not be empty`. Support for other provider names is tracked in issue #6.

4. **Preflight before startup**: before each worker starts, `codex-worker.sh` first confirms that the endpoint is reachable. The preflight address is determined in this priority order:
   1. Environment variable `CODEX_WORKER_PREFLIGHT=off`: do no preflight.
   2. Environment variable `CODEX_WORKER_PREFLIGHT=<host>:<port>`: probe this address.
   3. Otherwise, read `base_url` from `[model_providers.custom]` in `config.toml`. Only loopback addresses (`127.0.0.1`, `localhost`, `::1`) get a TCP probe; remote addresses skip preflight and let codex report its own error.

   If the local proxy is not running, the worker immediately exits as `transient` with the error `local proxy at <host>:<port> is not listening`.

5. **MCP is off by default, opt in per task**: a worker starts with every MCP server in `config.toml` disabled (faster startup, no tool schemas in context). Add `--mcp all` to `codex-worker.sh` for research that needs web search, `--mcp ssh-manager` for remote-server work (several names may be comma-separated); omit it for coding tasks. A Resume reuses the first segment's selection.
6. **Subagent concurrency cap**: the worker's fixed preamble asks codex to batch independent commands and to spawn explorer subagents for exploration. Subagents take no worker slot, so cap them in `config.toml`:

   ```toml
   [agents]
   max_concurrent_threads_per_session = 3
   ```

7. **Generate a separate worker home (recommended)**: once `~/.codex/config.toml` is set up as above, run `scripts/setup-worker-home.sh`. It creates `~/.codex-worker/` with only the provider, MCP, and `[agents]` settings, without hooks, projects, or interactive settings. From then on the worker reads only that directory, so you can change your interactive codex freely (for example, switch it to an OpenAI subscription) without affecting the worker. Re-run it after changing worker-relevant parts of `~/.codex/config.toml` (idempotent; it backs up a changed config first). Set `CODEX_WORKER_HOME` to use a different location. Without a worker home the wrapper falls back to `~/.codex` with a warning.

**Verify**

```bash
cd ~/.claude/skills/implement-spec-split
scripts/selftest-codex.sh --only V1   # Test the wrapper itself with a fake codex; costs no tokens; should print OK: all checks passed
scripts/selftest-codex.sh --only L1   # Make one real GLM call; costs a few tokens; failure is usually the proxy not running or wrong provider configuration
```

**Design rationale**

For why this uses `exec --json` with a wrapper, why it uses bypass mode, and Windows pitfalls, see [codex-backend.md](codex-backend.md).

---

## Stage 3: global Opus / codex division of labour

This makes everyday sessions in **all projects** follow this division: Opus handles discussion, decisions, root-cause judgment, review, and approval, while coding and bulk code reading go to codex workers. It has five parts:

| Part | Location | Purpose |
|---|---|---|
| Division rules | `~/.claude/CLAUDE.md` | Tell Claude what to do itself, what to delegate, how to call workers, and how to handle results |
| delegate-guard hook | `~/.claude/settings.json` | Mechanically block direct source edits larger than 10 lines, without relying on the model remembering the rules |
| unattended-ask-guard hook | `~/.claude/settings.json` | Deny `AskUserQuestion` in unattended `--auto-land` runs, without relying on the model remembering not to ask |
| unattended-stop-guard hook | `~/.claude/settings.json` | Before an unattended `--auto-land` run ends, deny ending without self-closing and deny ending on a question to the user |
| land-push-guard hook | `~/.claude/settings.json` | After a session has run `/implement-spec-split`, deny a push to the default branch unless this session holds the repo's land lock |
| subagent-guard hook | `~/.claude/settings.json` | In the main thread of a flash session, deny opening a code-writing subagent with the Agent tool (implementation, fix and conflict resolution are dispatched through the dispatch module) |

**Install**

1. **Write the division rules**: open [templates/global-claude-md.en.md](../templates/global-claude-md.en.md) and append everything below the divider to `~/.claude/CLAUDE.md`. If an older "delegate coding to codex/PI" section already exists, replace it. First adjust two placeholders:
   - `<GLM endpoint description>`: how codex reaches GLM on this machine, for example "GLM through the local Ferryman proxy on `127.0.0.1:15722`";
   - The skill path: if it was not cloned to `~/.claude/skills/implement-spec-split`, replace every occurrence with the actual path.

   Keep the `<!-- opus-codex-division: vN -->` version-marker line. When the template is updated later, `scripts/doctor.sh` compares the marker in your CLAUDE.md with the template marker and reminds you to synchronize if they differ.

2. **Register the hook**: in the `hooks.PreToolUse` array of `~/.claude/settings.json`, **append** one item (do not overwrite existing hooks):

   ```json
   {
     "matcher": "Edit|Write|NotebookEdit|Bash",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/delegate-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   On macOS / Linux, replace the path with the absolute path of `node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js`. The `Bash` in the matcher needs no manual check or backup: later, run `./install.sh` in the repository. It lists "the delegate-guard matcher covers `Edit`, `Write` and `Bash`" as an expectation (tighten), and when the registered entry lacks `Bash` it first backs `settings.json` up to `~/.claude/backups/install-<timestamp>/`, then appends the missing tools to the matcher (an existing `NotebookEdit` stays as it is) and validates the written file as JSON. Registered as above, `Bash` already included, nothing is appended. `install.sh` does not register a hook for you — an unregistered hook is not drift — so the hooks below are still added by hand.

   **Also register unattended-ask-guard**: nobody answers questions in an unattended `/implement-spec-split --auto-land` session, so this hook denies `AskUserQuestion` and tells the model to use automatic decisions or a parking report instead. Append one more item to the same `hooks.PreToolUse` array:

   ```json
   {
     "matcher": "AskUserQuestion",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-ask-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   On macOS / Linux, use the absolute path as well. The hook decides from whether the last `/implement-spec-split` invocation in the transcript carries `--auto-land`; set `UNATTENDED_ASK_GUARD_DISABLE=1` to turn it off temporarily. See [hooks/README.md](../hooks/README.md).

   **Also register land-push-guard**: after a session has run `/implement-spec-split`, a push to the default branch (`main` / `master`, or the branch `origin/HEAD` points to) must first hold this repository's land lock. The hook reads the lock directory directly, so it does not depend on the model remembering to take the lock or on it interpreting `lock.sh`'s exit code. Append one more item to the same `hooks.PreToolUse` array:

   ```json
   {
     "matcher": "Bash",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/land-push-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   On macOS / Linux, use the absolute path as well. It only applies to sessions whose transcript contains an `/implement-spec-split` command invocation; set `LAND_PUSH_GUARD_DISABLE=1` to turn it off temporarily. See [hooks/README.md](../hooks/README.md).

   **Also register unattended-stop-guard**: before an unattended `--auto-land` run ends, this hook blocks two cases: the run is `done` / `waiting` / `parked` but `scripts/close-self.sh` was never run (the session sits idle instead of closing), and the last reply asks the user something (a plain-text question, the path `unattended-ask-guard` cannot catch). It is registered on the `Stop` event, not `PreToolUse`, so add (or append to) the `hooks.Stop` array in `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-stop-guard.js",
               "timeout": 10
             }
           ]
         }
       ]
     }
   }
   ```

   On macOS / Linux, use the absolute path as well. Like `unattended-ask-guard`, it decides from whether the last `/implement-spec-split` invocation in the transcript carries `--auto-land`; set `UNATTENDED_STOP_GUARD_DISABLE=1` to turn it off temporarily. See [hooks/README.md](../hooks/README.md).

   **Register subagent-guard as well** (since 规格 #26): in the main thread of a flash session (`FLASH_ORCHESTRATOR=1`) this hook denies opening a code-writing subagent with the Agent tool — a Ticket's implementation, fix and conflict resolution are dispatched to Orca workers through `scripts/stage-dispatch.sh` on the 实现 route, and review goes through `scripts/opus-review.sh`; the prompt alone does not stop flash from opening a `general-purpose` subagent, so, like "not one line of source itself", it is enforced by a hook. Read-only subagents (`Explore`, `Plan`, `claude-code-guide`) are allowed as before; non-flash sessions are not affected. In `~/.claude/settings.json`, **append** one entry to the `hooks.PreToolUse` array (do not replace the entries delegate-guard, unattended-ask-guard and land-push-guard already have):

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Agent|Task",
           "hooks": [
             {
               "type": "command",
               "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/subagent-guard.js",
               "timeout": 5
             }
           ]
         }
       ]
     }
   }
   ```

   On macOS / Linux, use the absolute path as well. It acts only when `FLASH_ORCHESTRATOR=1` is set, so registering it at the user level affects neither the official session nor claude-glm. See [hooks/README.md](../hooks/README.md).

3. Start a new Claude Code session so both the hook and the rules take full effect.

**Hook decision rules**

- Ordinary sessions apply the line limit only to `Edit`, `Write`, and `NotebookEdit`; Bash input is allowed.
- In a flash session (`FLASH_ORCHESTRATOR=1`), the source-edit threshold is 0, and common Bash source writes such as `sed -i`, heredoc redirection, `>` / `>>`, and `tee` are denied.
- Ordinary sessions allow files with extensions `.md .txt .json .jsonc .yaml .yml .toml .ini .cfg .csv`, plus `.gitignore` and `.gitattributes`, and source edits of no more than 10 lines. Flash sessions also allow those non-source files.
- Ordinary sessions deny source edits over 10 lines (for Edit, the larger of the old/new line counts; for Write, the whole file's line count).
- Exception switch: `~/.claude/state/allow-direct-edit`, whose content is an expiry time (ISO 8601 or epoch seconds); ordinary sessions allow everything before it expires, while flash sessions do not use it. The rules require Claude to create it only after explicit user authorization. You can also create it yourself:

  ```bash
  mkdir -p ~/.claude/state && date -d '+60 min' -Iseconds > ~/.claude/state/allow-direct-edit
  ```

- Any exception allows the operation (fail-open), so a broken hook never blocks the session, but it also stops intercepting. Exceptions are recorded in `~/.claude/state/delegate-guard.log`, and `scripts/doctor.sh` reports errors from the last 7 days.

**Tuning the hook**

- **Global threshold**: environment variable `DELEGATE_GUARD_LIMIT` (a positive integer; default 10).
- **English messages**: environment variable `DELEGATE_GUARD_LANG=en`.
- Both environment variables can be written to the `env` field of `~/.claude/settings.json` and will apply to all sessions.
- **Per-project adjustment**: put `.claude/delegate-guard.json` in a project, containing `{"limit": 30}` (change that project's threshold to 30) or `{"enabled": false}` (do not intercept in that project). The hook searches upward from the session's current directory and uses the nearest file; project configuration takes priority over environment variables.
- Note: any repository can ship this file and turn the hook off. The hook is a self-discipline aid that helps Claude follow the rules, not a security boundary.

**Verify**

```bash
# 1. Hook unit tests: should print Summary: 60 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-delegate-guard.js

# 2. land-push-guard unit tests: should print Summary: 27 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-land-push-guard.js

# 3. unattended-stop-guard unit tests: should print Summary: 41 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-unattended-stop-guard.js

# 4. subagent-guard unit tests: should print Summary: 14 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-subagent-guard.js

# 5. Smoke test: should print a JSON object whose permissionDecision is deny
node -e 'console.log(JSON.stringify({tool_name:"Write",tool_input:{file_path:"C:/x/a.py",content:"l\n".repeat(15)}}))' \
  | node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js
```

3. In a new session, ask Claude to directly write a 15-line `.py` file. It should be blocked and show the Chinese reason `按规则应写 Brief 交给 codex worker` ("per the rules, write a Brief and hand it to a codex worker"). Set `DELEGATE_GUARD_LANG=en` to get English output.
4. Triage quiz: in a new session, ask Claude "who does it, plus one sentence of reasoning" for each item below (do not execute). Expected answers are in parentheses:
   - Discuss architecture trade-offs for a new feature (Opus)
   - Add an interface with tests, about 200 lines (codex)
   - An intermittently failing test involving 3 modules (an investigation Brief to codex; Opus judges)
   - Commit already-reviewed changes (Opus)
   - Fix a one-line misspelled constant name (Opus changes it directly)
   - Six file conflicts during a merge (codex resolves conflicts, Opus reviews)
   - Push and open a PR (Opus, confirming before push)
   - Restart a service on a remote server (Opus, not delegated to a worker)

**Everyday use**

You do not need to remember commands; just tell Claude what you need as usual. Once the rules take effect, it works like this:

- Discussion, planning, and decisions: Claude (Opus) does them itself.
- Code needs writing: Claude writes a Brief using [templates/brief-implement.md](../templates/brief-implement.md), starts a codex worker in the background, then reviews the diff and spot-checks acceptance commands after completion; if it fails, it writes a rework Brief and runs again.
- A problem needs locating: Claude writes an investigation Brief using [templates/brief-investigate.md](../templates/brief-investigate.md), hands it to a worker with `--read-only`, and reads only the report.
- commit, push, opening PRs, and operating servers: Claude does these itself and asks you first for external actions.
- To see worker progress: just ask "where is it now", and Claude will run `scripts/progress.sh` and summarize it.
- To have Claude write a piece of code itself: say explicitly "make this change yourself", and it will enable the exception switch for 60 minutes.

Run records are stored in `~/.cache/codex-runs/<repository>-<time>-<task>/`, containing `brief.md`, `status.json`, `result.md`, the event stream, and logs.

---

## Stage 4: flash mode (cheap Orchestrator)

Everyday scheduling spends no subscription quota: the main session (Orchestrator) runs on Zhipu `glm-5.3-flash` and only executes and relays within a whitelist; source changes and bulk reading are dispatched by the Spec session through `scripts/stage-dispatch.sh` on the Stage route table (实现 / 调研起草) to glm-5.4 workers that work in their own worktrees (since 规格 #26 there are no in-session subagents for this: the hook denies them); every judgment call (review, root cause, trade-offs, landability, stop-or-go) leaves the session for the official-subscription Opus ([ADR 0001](adr/0001-cheap-orchestrator-default-deny.md)). This stage targets mini6 (macOS) only.

**Prerequisites**

- Stage 0 (`./install.sh` has run, so the `/grill-feature`, `/grill-map` and `/grill-router` symlinks are in place) and Stage 3 (the delegate-guard hook) are in place.
- `claude-glm` is set up (the Stage 2 GLM endpoint and API key): `claude-flash` reuses its endpoint and `~/ops/state/claude-glm/apikey` and never copies the key.
- Install the launcher (the four-piece set lives in `~/ops/services/claude-flash/`; see its README.md):

  ```bash
  cd ~/ops/services/claude-flash && ./install.sh   # creates the /opt/homebrew/bin/claude-flash symlink
  ```

**Starting a flash main session**

- Run `claude-flash` in a terminal (it sets `FLASH_ORCHESTRATOR=1` and injects flash-only settings and a system prompt: the whitelist, judgments go to Opus, source changes go to workers through the dispatch module; the official sessions' Opus/codex division rules are excluded and the codex plugin is disabled).
- Permission mode: the launcher appends `--dangerously-skip-permissions` to ordinary sessions (never twice), so flash sessions always run in bypass. Orca's OpenClaude slot does not add the flag itself; without it a session falls into auto mode, where the classifier can stall an unattended spec session and, through the Zhipu gateway, triggers a billing notice.
- To take over the Orca slot: repoint the `/opt/homebrew/bin/openclaude` symlink at `~/ops/services/claude-flash/claude-flash` (or fill Orca Settings → Agents → OpenClaude's command override with the absolute path of `claude-flash`). The OpenClaude slot then opens flash main sessions; the original `claude-glm` stays available side by side.
- Smoke test:

  ```bash
  claude-flash -p 'Which model are you? Answer with the model name only' --output-format json
  claude-flash -p 'Use Bash to print $FLASH_ORCHESTRATOR' --allowedTools Bash   # should print 1
  ```

**The two design entry points (Design session)**

- `/grill-feature <idea>`: small features. The flash main session calls `scripts/design-session.sh` to open a Design session (started on the design Stage route, official Opus by default), then blocks and burns no tokens; Orca switches to that session automatically and you discuss with Opus directly. When the discussion ends it does to-spec, to-tickets, commit and push on the spot, writes a handoff summary and notifies flash to continue, switching back to the main session automatically; flash reads the summary and goes on to run `/find-next` 推进模式 in the main session (drafting, publishing, the first wave and 总控 all happen there).
- `/grill-map <map or idea>`: large modules (wayfinder maps). Same flow; once connected, find-next stops at its synthesized question round for you. Saying "先到这" ends it early: find-next is not connected then, and flash only relays the map state and next step from the handoff summary.
- A Design session's run directory is `~/.cache/implement-spec-split/design/<repo>-<time>-<kind>/`; the handoff summary is its `handoff.md`.

**Spec sessions and Opus review**

- In a flash main session, `/find-next` has launch-wave open spec sessions through the OpenClaude slot (i.e. flash); the Spec session dispatches each Ticket's implementation as an Orca worker through `scripts/stage-dispatch.sh` on the 实现 route (claude-glm / glm-5.4 by default), so a spec runs start to finish without subscription quota.
- Code review, draft review and consecutive-failure diagnosis inside a flash spec session never run in-session (an "opus" subagent in a GLM session is actually GLM — a fake review); they always call `scripts/opus-review.sh`, which runs outside the session on the review or diagnosis Stage route (official Opus by default): `--kind code` (a branch/fixed point), `--kind draft` (a spec/ticket draft), `--kind diagnose` (a failure; recommends continue / re-brief / stop). Any non-zero exit parks the run with an explanation (meanings in the script's header comment); no automatic retry, no GLM downgrade, no in-session self-review.

**The Stage route table: which launcher, model and effort each Stage runs on (`/grill-router`)**

Which Launcher profile, model and reasoning effort the design, research, implementation, review and diagnosis Stages run on is one global table (the thin `grill-router/` skill, symlinked as above; ADR 0004). The orchestration Stage is locked to flash and cannot be changed. When Opus quota runs out, one slash command in any Claude Code session sends review and design to glm-5.4, and one command can set several Stages:

```text
/grill-router                                      # show the six routes
/grill-router review on glm 5.4, grill on glm 5.4    # one command sets both
/grill-router review on glm-5.4 until 7:00 tomorrow   # only review, back to the default by itself then
/grill-router grill on glm, effort medium, for 5 hours  # only design, effort included
/grill-router review back to default                  # put review back on its default route
```

Outside a session the script does the same. `use` takes one or more `stage=profile/model/effort` settings and leaves the other Stages alone; setting a Stage back to its default route takes it out of the table:

```bash
S=~/.claude/skills/implement-spec-split/scripts/stage-route.sh
$S use review=claude-glm/glm-5.4/high design=claude-glm/glm-5.4/medium   # both in one command
$S use review=claude-glm/glm-5.4/medium --until 2026-11-28T07:00:00+08:00  # back to the default at that time
$S use review=claude-glm/glm-5.4/medium --for 5h                          # or: for the next 5 hours (30m, 2d12h also work)
$S use review=claude/opus/high                                           # back on the default route
$S                                                                      # show the current routes
$S migrate                                                              # carry the old switches' unexpired settings over
```

- The six Stages and their defaults: orchestration `claude-flash` / glm-5.3-flash (locked); design `claude` / opus / high; research `codex-glm` / glm-5.4 / high; implementation `claude-glm` / glm-5.4 / high; review and diagnosis `claude` / opus / high. The `claude` profile is the official subscription's bare `claude`, `claude-glm` and `claude-flash` are the two GLM launchers, and `codex-glm` is codex run through `codex-worker.sh`. A status line that is off its default names the way back after 切回用.
- Which script reads which line: `design-session.sh` reads design; `opus-review.sh --kind code|draft` reads review and `--kind diagnose` reads diagnosis; `codex-worker.sh` reads research with `--read-only` and implementation otherwise. Each reads the table once per dispatch, so **flash spec sessions and find-next sessions that are already running need no restart**: a change does not touch the dispatch in progress; the next one runs on the new route.
- The table is `~/.claude/state/stage-route` and applies to every repository and session on this machine. Only (profile, model) pairs that passed a smoke test are accepted; anything else is exit code 64 and leaves the table unchanged. Efforts are low, medium, high, xhigh and max (codex has no max). An expired line, a combination outside the catalog or a damaged file falls back to the default and says so on stderr. When review and implementation are set to the same model there is one warning (no change of model for review), never a block.
- A review still leaves the session through `opus-review.sh`, never an in-session subagent; on glm-5.4 it runs through `claude-glm`, and stderr and the findings file's first line both name the route (stage, profile, model, effort). glm-5.4 reviewing code written by glm-5.4 is weaker than Opus: watch for that line when you read a landing report.
- Design sessions read the design route only when they are **opened**: after the switch, `/grill-feature` and `/grill-map` open a glm-5.4 session (an Orca terminal running that launcher, which makes the mock pages itself instead of handing them to a worker); the handoff and the wait are unchanged.
- A Design session that is already open on Opus cannot change model. To carry on in the same conversation, run `claude-glm --resume` in a terminal of that repository and pick it from the list; the handoff contract is still in that conversation, and the run directory and the wait are unchanged. If the wait timed out, continue it with the `design-session.sh --attach <run dir>` command printed on stderr.
- Nothing switches by itself: an Opus review that fails on quota (exit code 3) still parks as `quota`, and a parked spec is still resumed by keeper after its 可恢复时间. Switching is your decision.
- **Upgrading from the old switches**: if the version you had installed the `judgment-model` and `worker-model` switches, remove their two symlinks from `~/.claude/skills/` and symlink `grill-router` as above. The first `/grill-router` run (or the first time any dispatch script reads the table) carries every old setting that has not expired into the table: effort high, expiry as it was; what cannot be carried (a model outside the verified catalog, e.g. the old worker switch's glm-5.3-flash) keeps its old file and says so. After that only `/grill-router migrate` carries anything over again.

**The flash boundary**

- Whitelisted: run scripts and branch on exit codes, read short structured output, write tickets from prepared text, relay questions with prepared options, start and finish workers through the dispatch module (`stage-dispatch.sh dispatch` / `wait` / `release`), start sessions, run Opus reviews, conflict-free merges and commits, and follow findings item by item.
- It writes no source line, ever: the Stage 3 delegate-guard hard-blocks source writes in flash sessions (threshold 0; `~/.claude/state/allow-direct-edit` does not apply).
- Every conclusion cites its source (a dispatched role's report path, the sidecar's `worker_done.report_path`, or an Opus findings path); when unsure who to hand to, default to Opus; push, tagging and releases ask you first (Design-session doc pushes excepted).

**Rollback**

Both repositories carry the bookmark tag `pre-flash-orchestrator`, and the global-config snapshot sits in `~/.claude/backups/pre-flash-orchestrator-20261120/`: follow the four steps in its ROLLBACK.md (check out the tag in the skill repo, restore ~/ops and uninstall claude-flash, copy the `~/.claude/` config back, repoint the Orca slot at claude-glm). The new behaviour only exists in flash sessions; official sessions and the original `claude-glm` coexist throughout.

---

## Updating and rollback

- **Update**: `cd ~/.claude/skills/implement-spec-split && git pull && ./install.sh` (clone-direct shape; with the symlink shape run the same in the clone). `install.sh` links a skill the repository gained, removes the dangling links of a retired one and applies a new tighten item of the expectation list (after a backup); re-running it changes nothing. Templates and scripts take effect immediately; the hook takes effect on its next call. An unattended landing runs it by itself after every landing (step 9 of the root `SKILL.md`), and fast-forwards the clone-direct copy to the new main first, so no manual update is normally needed; when it cannot (not on `main`, or not clean) the landing report's 要你做 says `git pull`.
- **Update the division rules**: after `templates/global-claude-md.md` changes in this repository, manually synchronize it to `~/.claude/CLAUDE.md` (the global file is outside repository management).
- **Upgrade to the Stage route table**: if the version you had installed the `judgment-model` and `worker-model` switches, `./install.sh` removes their two dangling symlinks from `~/.claude/skills/` and symlinks `grill-router`; the first `/grill-router` run carries the old settings over (see Stage 4).
- **Pause the division of labour**: remove the delegate-guard entry from `settings.json` and remove the division section from CLAUDE.md. `install.sh` then expects nothing of it (an unregistered hook is not drift); only Stage 4 is unavailable.
- **Change machines**: three things must move: the cloned repository with `./install.sh` run (Stage 0), `~/.codex/config.toml` and the proxy (Stage 2), and the CLAUDE.md division section plus the hook registration in `settings.json` (Stage 3). Cloning the repository alone is not enough.

## Self-check

The checks in `scripts/doctor.sh` only read local configuration and do not modify configuration files. It reports current status by "foundation, Stage 1, Stage 2, Stage 3"; the foundation group's "local install state" check calls `install.sh --check --json` (read-only as well): a missing, mis-pointed or dangling skill link is a WARN, an unmet tighten expectation a FAIL, and every hint says to run install.sh (which the landing flow runs by itself). Its default output is Chinese; use `--lang en` or `DOCTOR_LANG=en` to get English output:

- `PASS`: the check passed.
- `WARN`: the item may affect the corresponding stage but does not block other stages; fix it according to the message.
- `FAIL`: configuration required by that stage is missing or has been verified as invalid; fix it according to the message.
- `INFO`: the stage is not configured, or the check was skipped according to the rules.

Parameters:

- `--lang zh|en`: output Chinese or English; `DOCTOR_LANG=en` also works.
- `--json`: output only one JSON object for easier script processing.
- `--with-glm`: additionally run `scripts/selftest-codex.sh --only L1`, which makes a real model request and consumes a small number of tokens.
- `--help`: view help.

The script exits with code 1 if there is any `FAIL`; otherwise it exits with 0.

## Troubleshooting

| Symptom | Cause and handling |
|---|---|
| Worker status is `transient`, error is `local proxy at <host>:<port> is not listening` | The local proxy is not running, or the port in `base_url` in `config.toml` is wrong. Start it and ask Claude to rerun; if preflight is genuinely unnecessary, set `CODEX_WORKER_PREFLIGHT=off` |
| Worker status is `transient`, error is `endpoint unreachable` | codex cannot reach the model endpoint (a network or remote service issue). First test connectivity separately with `scripts/selftest-codex.sh --only L1` |
| `auth` / `quota` | The GLM key is invalid or quota is exhausted. Claude stops and asks you; it does not switch plans by itself |
| The hook does not intercept | Check the path in `settings.json`; open a new session; use the smoke command above to test the hook itself; check whether `allow-direct-edit` is unexpired |
| Claude does not follow the division in a project | Project-level CLAUDE.md may contain conflicting rules; check project rules first |
| An investigation task returns `violation` (exit code 8) | The worker modified files during a read-only investigation. Inspect `changed_paths` in `status.json` and `git diff`, then decide how to revert |
| A spec parks mid-run on quota / 429 | A worker hit a rate limit. Lower `--parallel`, or move to a quieter time |
