# implement-spec-split

A Claude Code skill: [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills/tree/main/skills/engineering/implement-spec) with **per-role models**.

- Exploration / implementer / fix run on a cheaper model, as Orca workers the skill dispatches itself, which spends no Claude quota on coding: a headless read-only exploration ([codex](https://github.com/openai/codex) `exec --json` via `scripts/codex-worker.sh`, on the 调研起草 Stage route) runs once before the Tickets, and each Ticket's implementation, fix and merge-conflict role is an Orca worker on the 实现 Stage route (`scripts/stage-dispatch.sh`, Lean start by default). Merges are done by a script (`scripts/merge-ticket.sh`); a worker is dispatched only on a conflict. The Stage route table (`/grill-router`) decides the launcher, model and reasoning effort of each, and a change reaches the next dispatch.
- The two code-review subagents (Standards and Spec, from `mattpocock-skills:code-review`) always run on a stronger model (`opus`, or `fable`).

`implement-spec-split` is normally started by find-next: one Spec per session in an Orca worktree, with every Ticket worker in a child worktree of the Spec's, so the sidebar shows the whole tree collapsed and a merged Ticket's worktree disappears. `--parallel n` caps how many Ticket workers one Run dispatches at once (default `GLM_MAX_PARALLEL`, 2). The backend switch of earlier versions and the progress tabs are retired (规格 #26).

The original skill lets every subagent inherit the session model, so you pay top-tier prices for coding or get a weaker review. This version passes `model` explicitly on every review subagent call and runs the implementing roles on the Stage route table. It also auto-discovers open, unfinished specs when invoked without an argument.

> Status: fully verified on **Windows 11 + Git Bash** with codex-cli 0.163.0; Ubuntu 24.04 passes all model-free self-tests (not yet run against a real model); macOS 27 (bash 3.2) fully verified with codex-cli 0.164.0, including real GLM (V3, 2026-10-24). Those runs predate 规格 #26: the codex wrapper was exercised end-to-end on a scratch repo (2026-10-11 with pi, 2026-10-18 with codex), and the real-machine smoke test of the dispatched-worker path is a separate ticket. Report problems via issues.

> **Security:** codex workers run with `--dangerously-bypass-approvals-and-sandbox` — full read/write/exec access to your machine — and everything they read is sent to your model provider. Read the security section of [docs/setup.md](docs/setup.md) before use.
>
> **Fit:** built for "Claude quota is tight, a cheaper model has plenty". Every hand-off costs Claude tokens for the Brief and the review, so it may not save money on pay-as-you-go API billing.

**Setup guide: [English](docs/setup.en.md) · [中文](docs/setup.md)** — staged setup for the three uses of this repo: parallel spec implementation, the codex (GLM) backend, and the global Opus / codex division of labour for everyday sessions (`templates/global-claude-md.en.md` / `templates/global-claude-md.md` + the `hooks/delegate-guard.js` PreToolUse hook).

## Requirements

- Claude Code with the `mattpocock-skills` plugin installed (uses its `tdd` and `code-review` skills, and its `docs/agents/issue-tracker.md` setup via `/setup-matt-pocock-skills`).
- For the Ticket workers: Orca, and on PATH the launcher the 实现 route names (`claude-glm` on the default route; `scripts/stage-route.sh`). The Spec session creates an Orca Run per Spec and each Ticket worker is adopted into it from a terminal in a child worktree of the Spec's.
- For the headless exploration (and find-next's codex workers): the `codex` CLI (tested with 0.163.0 and 0.164.0), Node.js, Git Bash (on Windows), and a `custom` model provider in `~/.codex/config.toml` serving GLM; the worker's TCP preflight is derived from that `base_url` and only probes loopback endpoints (author environment: a local proxy on `127.0.0.1:15722`). Check it with `scripts/selftest-codex.sh` (`--only V1` needs no model at all). Design notes and evidence: [docs/codex-backend.md](docs/codex-backend.md) (中文). Workers start with every MCP server in `config.toml` disabled; pass `--mcp all` (web research) or `--mcp <name,...>` (e.g. `ssh-manager` for remote work) to `codex-worker.sh` when a task needs them. Their prompt asks codex to batch independent tool calls and to spawn explorer subagents for independent exploration; cap those with `[agents] max_concurrent_threads_per_session = 3` in `config.toml` (subagents take no worker slot).
- For the retiring `pi` wrapper only (`scripts/pi-worker.sh`; 规格 #26 retires it): the `pi` CLI, Node.js, Git Bash (on Windows), and a GLM provider in `~/.pi/agent/models.json` with a valid Zhipu Coding Plan key, e.g.:

  ```json
  { "providers": { "glm": {
      "baseUrl": "https://open.bigmodel.cn/api/coding/paas/v4", "api": "openai-completions",
      "apiKey": "<your key>",
      "models": [{ "id": "glm-5.4", "name": "GLM-5.4", "reasoning": true, "input": ["text"],
                   "contextWindow": 1000000, "maxTokens": 131072,
                   "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } }] } } }
  ```

  Check it with `scripts/selftest.sh` (connectivity, then a tiny ticket end-to-end in a scratch repo).

## Install

```bash
git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
```
Then run scripts/doctor.sh to check your setup.

Invoke manually with `/implement-spec-split [spec ref] [--parallel n]` (normally find-next starts it, see below). Change the defaults in the "Config" section of `SKILL.md`; the per-stage launcher, model and reasoning effort live in the Stage route table (`/grill-router`).

AI agents installing or operating the skill should read [docs/ai-agents.md](docs/ai-agents.md) first: it gives the quick start, backend requirements, preflight commands, progress inspection, and agent-specific safety rules.

## Companion skill: `find-next`

`find-next/` is a second skill in this repo and the **single everyday entry point**: apart from charting a brand-new map with `/wayfinder`, type `/find-next --batch` (or just `/find-next`; `--batch` is an alias of the default advance mode) and it pushes everything it can — maps, specs, tickets and development:

- **Maps not fully discussed:** auto-resolves frontier research tickets, prepares options for grilling tickets, works task tickets (AFK ones itself, a checklist for the rest) and up to two prototype tickets per run (UI via mockit, other prototypes on a throwaway `prototype/<n>` branch), and proposes **fog graduation** — new tickets or out-of-scope rulings for whatever the map's `## Not yet specified` section can now phrase. A map counts as ready for a spec only when all its decisions are closed **and** that section is empty. Maps with no tickets, and tickets claimed for more than 3 days without activity, are reported.
- **Loose tickets:** GitHub tickets outside maps and Specs are triaged into waiting on timing, a new map, one decision, or duplicate/stale closure; timing tickets are reported without nagging, and all tracker writes wait for the combined round.
- **Specs and tickets:** drafts a spec plus tickets for every implementation ticket or finished map that needs one, one worker per group in parallel.
- **One combined round:** every real trade-off or loose-ticket choice goes into a single phone-friendly message; reply "都同意", per-item changes, "展开 <item>" to grill that ticket in place, or "先到这" to stop. At most three rounds per run; the next run continues.
- **Development:** publishes the drafts, computes the order and starts the first wave of `/implement-spec-split` sessions in Orca; shelved execution tickets do not count as pending, and each merged spec starts the next wave.
- **Unattended landing:** `find-next` and the `launch-wave.sh` calls it makes (including `--only` handoffs and later `--next-wave` runs) start every Spec with `--auto-land` by default, so the whole batch, including later waves, lands without asking: specs merge into main (or their PR auto-merges once checks pass), red tests/CI get up to two automatic fix rounds, and a spec that still cannot land leaves a parking report on its issue instead of waiting. Successful landings leave a landing report there too, so after an overnight run you read GitHub rather than reopening expired sessions. Pass `--no-auto-land` to keep the push confirmation for a batch; typing `/implement-spec-split <n>` yourself also keeps it.

`/find-next --suggest` keeps the old read-only behaviour (one Next step and the command to type), and `/find-next --list` prints the full to-do list from `pipeline-status.sh --all` without a worker, led by per-grill progress from `grill-status.sh` (in-progress ticket branches and parking reports included) and ending with what needs you now, what runs on its own, and what comes later. `--worker agent --agent-model <model>` swaps find-next's own codex-worker steps for an Agent subagent on that model (the development commands it generates carry no backend: Ticket workers always go through the 实现 route). Advance mode supports GitHub trackers; local markdown trackers are scanned by `find-next/scripts/scan.py` for `--suggest` / `--list`.

Install it next to the main skill:

```bash
ln -s ~/.claude/skills/implement-spec-split/find-next ~/.claude/skills/find-next   # Windows: mklink /J, or copy
```

Install the two Design-session wrappers the same way:

```bash
ln -s ~/.claude/skills/implement-spec-split/grill-feature ~/.claude/skills/grill-feature
ln -s ~/.claude/skills/implement-spec-split/grill-map ~/.claude/skills/grill-map
```

Install the Stage route command the same way:

```bash
ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router
```

`/grill-router` shows and sets the Stage route table (ADR 0004): the Launcher profile, model and reasoning effort each of the six Stages runs on — orchestration (the flash main session, locked), design (Design sessions), research (read-only codex worker dispatches), implementation (codex workers), review and diagnosis (`scripts/opus-review.sh`). With no argument it shows the six routes; `/grill-router use review=claude-glm/glm-5.4/high design=claude-glm/glm-5.4/medium` sets several in one command (natural language works too, e.g. `审查用 glm 5.4，讨论用 opus`), an expiry (`到 <time>`, or a duration such as `5h`) makes them return to their defaults by themselves, and `/grill-router use review=claude/opus/high` is the reset (a status line that is off its default names the way back after 切回用). Only (profile, model) pairs that passed a smoke test can be routed, and a change takes effect at that Stage's next dispatch or next new Design session, never mid-call. With the old switches gone that leaves 3 + 1 entry points: the three work commands `/grill-feature`, `/grill-map` and `/find-next`, and this one setting command. The wrapper only runs `scripts/stage-route.sh` and relays its six status lines. Upgrading from a version that had the `judgment-model` and `worker-model` switches: remove their two symlinks from `~/.claude/skills/`, link `grill-router` as above, and the first `/grill-router` run carries every old setting that has not expired into the table (`/grill-router migrate` does it again on request).

`/grill-feature <idea>` opens a Design session for a small feature; `/grill-map <map or idea>` does the same for a large-module wayfinder map. Each wrapper blocks until `scripts/design-session.sh` receives `handoff.md`, then hands the session over to find-next's 推进模式 (`/grill-map` does not after an early 「先到这」 handoff, which `handoff.md` marks on its first line).
Run `scripts/grill-status.sh` from a managed repository (or pass its directory) to list each Design session topic with spec and ticket progress; it is read-only and does not spend tokens. `scripts/completion-report.sh` turns the same design-session records plus git/GitHub state into a Chinese completion conclusion — current topic progress, repository-wide status, a release recommendation with a suggested version (it never tags or pushes), tickets a release would unfreeze, and interrupted grills.

## Flash mode

For GLM-side setups there is a three-tier split (ADR 0001, [docs/setup.md 阶段 4](docs/setup.md) / [docs/setup.en.md Stage 4](docs/setup.en.md)): a cheap **flash Orchestrator** (`claude-flash`, glm-5.3-flash) runs the main and spec sessions and only executes and relays within a whitelist; glm-5.4 subagents do all source changes; every judgment call — code review, draft review, failure diagnosis — leaves the session via `scripts/opus-review.sh`, which by default runs official-subscription Opus, as do the Design sessions behind `/grill-feature` and `/grill-map`. A `FLASH_ORCHESTRATOR=1` session is hard-blocked (delegate-guard) from writing any source line, cites a findings/result path for every conclusion it reports, and parks rather than downgrades when Opus is unavailable. Which launcher, model and reasoning effort each Stage runs on — design, research, implementation, review and diagnosis; orchestration stays locked to flash — is the user's global Stage route table, shown and set with `/grill-router` (ADR 0004): when Opus quota runs out, `/grill-router use review=claude-glm/glm-5.4/high design=claude-glm/glm-5.4/high` sends reviews and Design sessions to glm-5.4 until the routes are set back, and every dispatch script reads the table when it runs, so a session that is already executing changes model at its next review or new Design session. Rolling back is one tag (`pre-flash-orchestrator`) plus a config snapshot; official sessions and `claude-glm` coexist throughout.

## Keeping up with upstream

Read [MAINTAINING.md](MAINTAINING.md) (中文) before syncing or editing: it records the design decisions and pitfalls.

`upstream/` holds a snapshot of the original `implement-spec/SKILL.md` and the upstream commit it came from.

```bash
./check-upstream.sh            # diff snapshot vs. ~/.claude/plugins/marketplaces/mattpocock (update the plugin first)
# port any changes into SKILL.md, then:
./check-upstream.sh --accept   # refresh the snapshot and commit hash
```

## Prior art

The External worker design (self-contained brief, never trust the worker's self-report, per-run log directory, timeouts, serial merges) borrows from [bradleygolden/orchestrate](https://github.com/bradleygolden/orchestrate), [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc), [dwgx/claude-codex-subagent](https://github.com/dwgx/claude-codex-subagent) and [overstory](https://github.com/jayminwest/overstory).

## License

MIT. Derived from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT, © 2026 Matt Pocock); see `upstream/LICENSE-mattpocock`.
