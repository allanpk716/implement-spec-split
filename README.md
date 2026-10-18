# implement-spec-split

A Claude Code skill: [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills/tree/main/skills/engineering/implement-spec) with **per-role models**.

- Exploration / implementer / merger / fix run on a cheaper model: `sonnet` subagents by default, or GLM-5.3 through headless External workers, which spends no Claude quota on coding: `--impl codex` ([codex](https://github.com/openai/codex) `exec --json`, with live progress via `scripts/progress.sh`) or `--impl pi` ([pi](https://github.com/earendil-works/pi-mono)).
- The two code-review subagents (Standards and Spec, from `mattpocock-skills:code-review`) always run on a stronger model (`opus`, or `fable`).

The original skill lets every subagent inherit the session model, so you pay top-tier prices for coding or get a weaker review. This version passes `model` explicitly on every subagent call. It also auto-discovers open, unfinished specs when invoked without an argument.

> Status: verified on **Windows 11 + Git Bash only** (macOS / Linux untested) with codex-cli 0.163.0. `--impl pi` exercised end-to-end on a scratch repo (2026-10-11); `--impl codex` end-to-end on the same repo (2026-10-18); `--impl sonnet` and the draft-PR flow not yet. Report problems via issues.

> **Security:** codex workers run with `--dangerously-bypass-approvals-and-sandbox` — full read/write/exec access to your machine — and everything they read is sent to your model provider. Read the security section of [docs/setup.md](docs/setup.md) before use.
>
> **Fit:** built for "Claude quota is tight, a cheaper model has plenty". Every hand-off costs Claude tokens for the Brief and the review, so it may not save money on pay-as-you-go API billing.

**Setup guide (中文): [docs/setup.md](docs/setup.md)** — staged setup for the three uses of this repo: parallel spec implementation, the codex (GLM) backend, and the global Opus / codex division of labour for everyday sessions (`templates/global-claude-md.md` + the `hooks/delegate-guard.js` PreToolUse hook).

## Requirements

- Claude Code with the `mattpocock-skills` plugin installed (uses its `tdd` and `code-review` skills, and its `docs/agents/issue-tracker.md` setup via `/setup-matt-pocock-skills`).
- For `--impl codex` only: the `codex` CLI (tested with 0.163.0), Node.js, Git Bash (on Windows), and a `custom` model provider in `~/.codex/config.toml` serving GLM; the worker's TCP preflight is derived from that `base_url` and only probes loopback endpoints (author environment: a local proxy on `127.0.0.1:15722`). Check it with `scripts/selftest-codex.sh` (`--only V1` needs no model at all). Design notes and evidence: [docs/codex-backend.md](docs/codex-backend.md) (中文).
- For `--impl pi` only: the `pi` CLI, Node.js, Git Bash (on Windows), and a GLM provider in `~/.pi/agent/models.json` with a valid Zhipu Coding Plan key, e.g.:

  ```json
  { "providers": { "glm": {
      "baseUrl": "https://open.bigmodel.cn/api/coding/paas/v4", "api": "openai-completions",
      "apiKey": "<your key>",
      "models": [{ "id": "glm-5.3", "name": "GLM-5.3", "reasoning": true, "input": ["text"],
                   "contextWindow": 1000000, "maxTokens": 131072,
                   "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } }] } } }
  ```

  Check it with `scripts/selftest.sh` (connectivity, then a tiny ticket end-to-end in a scratch repo).

## Install

```bash
git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
```
Then run scripts/doctor.sh to check your setup.

Invoke manually with `/implement-spec-split [spec ref] [--impl codex|pi|sonnet] [--parallel n]`. Change the defaults in the "Config" section of `SKILL.md`.

AI agents installing or operating the skill should read [docs/ai-agents.md](docs/ai-agents.md) first: it gives the quick start, backend requirements, preflight commands, progress inspection, and agent-specific safety rules.

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
