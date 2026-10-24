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
 ├─ Stage 1 parallel spec implementation (works with --impl sonnet)
 │     └─ with Stage 2 added, --impl codex works too
 └─ Stage 2 codex backend
       └─ Stage 3 global division (CLAUDE.md rules + delegate-guard hook)
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
| Platform | Windows 11 + Git Bash: fully verified, including real GLM end to end. Ubuntu 24.04: all model-free self-tests pass (`selftest-codex.sh --only V1`, hook tests, doctor tests), but it has not been run with a real codex and GLM. macOS 27 (stock bash 3.2): fully verified with codex-cli 0.164.0, including real GLM end to end (V3, 2026-10-24). Known limitation: the alternate pi backend (`pi-worker.sh`) only kills the root process on Linux/macOS; use the codex backend on those platforms |
| codex-cli | 0.163.0, 0.164.0. Other versions are unverified; after changing versions, first run `scripts/selftest-codex.sh --only V1` |
| Model | GLM-5.3, through a local proxy |
| Stage 1 | `--impl codex` and `--impl pi` verified end-to-end in a scratch repo; `--impl sonnet` unverified |
| Stage 3 | Hook unit tests and a local smoke test pass; rule adherence in real sessions is still being validated |
| Install commands | Plugin install commands are given using the marketplace name installed locally (`mattpocock`); `npm i -g @openai/codex` is codex's official installation method. Neither has been re-run on a fresh machine |

---

## Stage 0: common foundation

**Install**

1. Claude Code, Git, and Node.js (the scripts use node for JSON and processes).
2. Windows: Git Bash (the wrappers are all Bash scripts).
3. Clone this repository into Claude's skills directory, **without changing the path**. The Stage 3 rules and hook both reference this path:

   ```bash
   git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
   ```

**Verify**

```bash
ls ~/.claude/skills/implement-spec-split/{SKILL.md,scripts,templates,hooks}
```

After installing any stage, you can run `scripts/doctor.sh` to check it.

---

## Stage 1: parallel implementation by spec (`/implement-spec-split`)

This is a modified version of [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills): the orchestration logic is the same, but each role specifies its model separately. The implementing roles (exploration / implementer / merger / fix) use a cheaper model, while the two code-review subagents are fixed to Opus.

**Install**

1. Install the `mattpocock-skills` plugin (this skill uses its `tdd` and `code-review` skills). In Claude Code:

   ```text
   /plugin marketplace add mattpocock/skills
   /plugin install mattpocock-skills@mattpocock
   ```

2. Run `/setup-matt-pocock-skills` once in the **target project**. It generates `docs/agents/issue-tracker.md` (which tells the skill where issues live and how to query them).

**Prepare a spec**

A spec is a parent GitHub issue. Its child issues are tickets, and dependencies between tickets determine which can run in parallel. You can generate it with one of Matt Pocock's planning skills or create it manually.

**Use**

```text
/implement-spec-split                      # No argument: automatically list unfinished specs for you to choose
/implement-spec-split #12                  # Specify a spec
/implement-spec-split #12 --impl sonnet    # Implementing roles use Sonnet subagents (default)
/implement-spec-split #12 --impl codex     # Implementing roles use codex workers (requires Stage 2)
/implement-spec-split #12 --impl codex --parallel 3
```

**How parallelism happens**

- The skill first reads the spec and tickets, then builds a task graph. Tickets whose dependencies are all satisfied form the "frontier"; each ticket in the frontier gets its own worktree and is implemented in parallel.
- Merges happen serially: at any one time, only one merger merges completed tickets into the integration branch.
- Concurrency limit: with `--impl sonnet`, it is governed by Claude subagent concurrency; with `--impl codex/pi`, it is governed by `GLM_MAX_PARALLEL` (default 2), and `--parallel n` overrides it for the current run only. A value of 2-3 is recommended, with 4 at most during quiet hours: Zhipu rate-limits at peak times, and any worker that hits a 429 stops the whole run to ask you.
- After each ticket is complete, it must pass the verification gate and two Opus reviews (Standards and Spec) before it counts as done.

Change defaults in the "Config" section of `SKILL.md`.

**Verify**

Run `/implement-spec-split <spec> --impl sonnet` once in a scratch repository that has a spec, and observe: tickets in the frontier start in parallel, merges are serial, and two review reports are produced at the end.

---

## Stage 2: codex backend (GLM)

This makes `codex exec` do work with GLM. Both Stage 1's `--impl codex` and Stage 3's everyday division of labour depend on it.

**Install**

1. Install the codex CLI (tested with 0.163.0 and 0.164.0): `npm i -g @openai/codex`, then confirm with `codex --version`.
2. **Prepare an endpoint compatible with the OpenAI Responses API**. codex uses `wire_api = "responses"` to communicate with the model, so the endpoint must handle Responses API requests (`POST /v1/responses`, streaming SSE). A service that only exposes Chat Completions (`/v1/chat/completions`) cannot be used directly. Options:
   - **Local proxy**: run a proxy on your machine that exposes the Responses API externally and forwards to the model service internally while injecting the key. The author uses the proxy feature in [Ferryman](https://github.com/allanpk716/ferryman), listening on `127.0.0.1:15722`. Note that this feature is not currently documented as a public Ferryman feature.
   - **Model service with native Responses API support**: if your model provider directly offers the Responses API, point `base_url` at it.
   - **Self-hosted compatible gateway**: some open-source LLM gateways can convert the Responses API to Chat Completions. Verify codex compatibility yourself; you can test with `--only L1` below.

3. Configure a provider named `custom` in `~/.codex/config.toml`, pointing to this endpoint. The author's environment uses this form (local proxy `127.0.0.1:15722`; the proxy talks to Zhipu and injects the real key):

   ```toml
   model_provider = "custom"
   model = "glm-5.3"

   [model_providers.custom]
   name = "zhipu_glm"
   base_url = "http://127.0.0.1:15722/v1"
   wire_api = "responses"
   requires_openai_auth = true
   ```

   The provider name must be `custom`: the wrappers pin the provider and model with `-c model_provider=custom -m glm-5.3`. If the model is not `glm-5.3`, add `--model <id>` when calling `codex-worker.sh`; in Stage 1, change `CODEX_MODEL` in the Config section of `SKILL.md`. Do not put the key in this repository.

   If you follow Zhipu's official Codex recipe (direct to `open.bigmodel.cn`), its provider is named `ZAI`: rename both `model_provider = "ZAI"` and `[model_providers.ZAI]` to `custom`; `name = "ZAI"` can stay (codex 0.164+ requires a non-empty `name`). Otherwise the worker fails with `model_providers.custom: provider name must not be empty`. Support for other provider names is tracked in issue #6.

4. **Preflight before startup**: before each worker starts, `codex-worker.sh` first confirms that the endpoint is reachable. The preflight address is determined in this priority order:
   1. Environment variable `CODEX_WORKER_PREFLIGHT=off`: do no preflight.
   2. Environment variable `CODEX_WORKER_PREFLIGHT=<host>:<port>`: probe this address.
   3. Otherwise, read `base_url` from `[model_providers.custom]` in `config.toml`. Only loopback addresses (`127.0.0.1`, `localhost`, `::1`) get a TCP probe; remote addresses skip preflight and let codex report its own error.

   If the local proxy is not running, the worker immediately exits as `transient` with the error `local proxy at <host>:<port> is not listening`.

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

This makes everyday sessions in **all projects** follow this division: Opus handles discussion, decisions, root-cause judgment, review, and approval, while coding and bulk code reading go to codex workers. It has two parts:

| Part | Location | Purpose |
|---|---|---|
| Division rules | `~/.claude/CLAUDE.md` | Tell Claude what to do itself, what to delegate, how to call workers, and how to handle results |
| delegate-guard hook | `~/.claude/settings.json` | Mechanically block direct source edits larger than 10 lines, without relying on the model remembering the rules |

**Install**

1. **Write the division rules**: open [templates/global-claude-md.en.md](../templates/global-claude-md.en.md) and append everything below the divider to `~/.claude/CLAUDE.md`. If an older "delegate coding to codex/PI" section already exists, replace it. First adjust two placeholders:
   - `<GLM endpoint description>`: how codex reaches GLM on this machine, for example "GLM through the local Ferryman proxy on `127.0.0.1:15722`";
   - The skill path: if it was not cloned to `~/.claude/skills/implement-spec-split`, replace every occurrence with the actual path.

   Keep the `<!-- opus-codex-division: vN -->` version-marker line. When the template is updated later, `scripts/doctor.sh` compares the marker in your CLAUDE.md with the template marker and reminds you to synchronize if they differ.

2. **Register the hook**: in the `hooks.PreToolUse` array of `~/.claude/settings.json`, **append** one item (do not overwrite existing hooks):

   ```json
   {
     "matcher": "Edit|Write|NotebookEdit",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/delegate-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   On macOS / Linux, replace the path with the absolute path of `node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js`. Back up `settings.json` before changing it.

3. Start a new Claude Code session so both the hook and the rules take full effect.

**Hook decision rules**

- Only `Edit`, `Write`, and `NotebookEdit` are handled; Bash is not (writing files through Bash relies on the rules).
- Allowed: files with extensions `.md .txt .json .jsonc .yaml .yml .toml .ini .cfg .csv`, plus `.gitignore` and `.gitattributes`; and source edits of no more than 10 lines.
- Denied: source edits over 10 lines (for Edit, the larger of the old/new line counts; for Write, the whole file's line count).
- Exception switch: `~/.claude/state/allow-direct-edit`, whose content is an expiry time (ISO 8601 or epoch seconds); everything is allowed before it expires. The rules require Claude to create it only after explicit user authorization. You can also create it yourself:

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
# 1. Hook unit tests: should print Summary: 35 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-delegate-guard.js

# 2. Smoke test: should print a JSON object whose permissionDecision is deny
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

## Updating and rollback

- **Update**: `cd ~/.claude/skills/implement-spec-split && git pull`. Templates and scripts take effect immediately; the hook takes effect on its next call.
- **Update the division rules**: after `templates/global-claude-md.md` changes in this repository, manually synchronize it to `~/.claude/CLAUDE.md` (the global file is outside repository management).
- **Pause the division of labour**: remove the delegate-guard entry from `settings.json` and remove the division section from CLAUDE.md.
- **Change machines**: three things must move: the cloned repository (Stage 0), `~/.codex/config.toml` and the proxy (Stage 2), and the CLAUDE.md division section plus the hook registration in `settings.json` (Stage 3). Cloning the repository alone is not enough.

## Self-check

The checks in `scripts/doctor.sh` only read local configuration and do not modify configuration files. It reports current status by "foundation, Stage 1, Stage 2, Stage 3". Its default output is Chinese; use `--lang en` or `DOCTOR_LANG=en` to get English output:

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
| `--impl codex` stops mid-run to ask you | A worker hit a rate limit. Lower `--parallel`, or move to a quieter time |
