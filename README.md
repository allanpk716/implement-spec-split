# implement-spec-split

A Claude Code skill: [Matt Pocock's `implement-spec`](https://github.com/mattpocock/skills/tree/main/skills/engineering/implement-spec) with **per-role models**.

- Exploration / implementer / merger / fix subagents run on a cheaper model (`sonnet`).
- The two code-review subagents (Standards and Spec, from `mattpocock-skills:code-review`) run on a stronger model (`opus`, or `fable`).

The original skill lets every subagent inherit the session model, so you pay top-tier prices for coding or get a weaker review. This version passes `model` explicitly on every subagent call. It also auto-discovers open, unfinished specs when invoked without an argument.

> Status: not yet exercised end-to-end on a real project. Report problems via issues.

## Requirements

- Claude Code with the `mattpocock-skills` plugin installed (uses its `tdd` and `code-review` skills, and its `docs/agents/issue-tracker.md` setup via `/setup-matt-pocock-skills`).

## Install

```bash
git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
```

Invoke manually with `/implement-spec-split [spec ref]`. Change the models in the "Model config" section of `SKILL.md`.

## Keeping up with upstream

Read [MAINTAINING.md](MAINTAINING.md) (中文) before syncing or editing: it records the design decisions and pitfalls.

`upstream/` holds a snapshot of the original `implement-spec/SKILL.md` and the upstream commit it came from.

```bash
./check-upstream.sh            # diff snapshot vs. ~/.claude/plugins/marketplaces/mattpocock (update the plugin first)
# port any changes into SKILL.md, then:
./check-upstream.sh --accept   # refresh the snapshot and commit hash
```

## License

MIT. Derived from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT, © 2026 Matt Pocock); see `upstream/LICENSE-mattpocock`.
