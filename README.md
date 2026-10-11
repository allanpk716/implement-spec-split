# implement-spec-split

A Claude Code skill: [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills/tree/main/skills/engineering/implement-spec) with **per-role models**.

- Exploration / implementer / merger / fix run on a cheaper model: `sonnet` subagents by default, or, with `--impl pi`, GLM-5.3 through headless [pi](https://github.com/earendil-works/pi-mono) processes, which spends no Claude quota on coding.
- The two code-review subagents (Standards and Spec, from `mattpocock-skills:code-review`) always run on a stronger model (`opus`, or `fable`).

The original skill lets every subagent inherit the session model, so you pay top-tier prices for coding or get a weaker review. This version passes `model` explicitly on every subagent call. It also auto-discovers open, unfinished specs when invoked without an argument.

> Status: not yet exercised end-to-end on a real project. Report problems via issues.

## Requirements

- Claude Code with the `mattpocock-skills` plugin installed (uses its `tdd` and `code-review` skills, and its `docs/agents/issue-tracker.md` setup via `/setup-matt-pocock-skills`).
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

Invoke manually with `/implement-spec-split [spec ref] [--impl pi|sonnet]`. Change the defaults in the "Config" section of `SKILL.md`.

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
