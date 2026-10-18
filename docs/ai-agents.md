# AI Agent guide

This guide is for an AI agent that has been asked to install or run this skill. After reading it, you should be able to install the skill, choose an implementation backend, verify the Codex backend, and run a spec correctly.

## What the skill does

`implement-spec-split` implements a GitHub spec and its child tickets on one integration branch. An Orchestrator in the user's Claude Code session owns scheduling, verification, review, and judgment. Cheaper executors do exploration, implementation, merging, and fixes; two stronger in-session reviewers always review the result.

Three implementation backends are available:

- `sonnet`: implementing roles run as in-session Claude subagents.
- `codex`: preferred external backend. Implementing roles run as headless Codex workers through GLM, with live progress inspection.
- `pi`: external Pi workers through GLM, retained as an alternate backend.

## Install

Install the repository as a Claude skill:

```bash
git clone https://github.com/allanpk716/implement-spec-split \
  ~/.claude/skills/implement-spec-split
```

The user also needs Claude Code, the `mattpocock-skills` plugin, Git, and Node.js. Windows additionally needs Git Bash because the external worker wrappers are Bash scripts. The target project must have the issue-tracker setup produced by `/setup-matt-pocock-skills`.

The Codex backend additionally needs the Codex CLI and a `custom` provider in `~/.codex/config.toml` that serves the configured GLM model. Do not put provider keys in this repository. The Pi backend instead needs a configured provider in `~/.pi/agent/models.json`.

## Verify before a run

For Codex, run the cheapest meaningful preflight from the skill directory:

```bash
scripts/selftest-codex.sh --only L1
```

It contacts the configured provider and costs a small number of GLM tokens. A failure usually means the local GLM proxy is not running or its model configuration is wrong; show the error to the user instead of switching backends automatically.

For a deterministic, token-free wrapper test:

```bash
scripts/selftest-codex.sh --only V1
```

The skill's normal invocation performs the Codex L1 preflight automatically before dispatching work. Run it manually here only when installing, troubleshooting, or changing backend configuration.

## Run a spec

From a repository with an open spec:

```text
/implement-spec-split [spec ref] --impl codex
```

Omit the spec reference to let the skill discover open, unfinished specs. Ask the user which spec to use when several are found. Include `--parallel n` only when the user asks; the default limit exists because GLM rate limits can stop the whole run.

Follow `SKILL.md` in the installed skill directory. It is the complete operating procedure: create per-worker briefs and run directories, obey the concurrency and time limits, verify worker results yourself, run one merger at a time, and reserve review for the configured strong in-session model.

For a worker that runs longer than expected, inspect its run directory:

```bash
scripts/progress.sh <run directory>
```

This reports state, recent commands and edits, time since the last progress event, and token use. Use it on request or for diagnosis; the wrapper's watchdog already handles stuck workers, so do not poll it continuously.

## Agent operating rules

- Never trust a worker's final report alone. Apply the verification gate in `SKILL.md`.
- Do not resume a timed-out worker unless it made progress, and resume it at most once.
- Do not automatically switch from GLM to Claude after auth, quota, or transient errors; ask the user.
- Do not ask Codex workers to delete directories recursively; their command policy may reject it.
- Ask the user before pushing, closing issues, or publishing anything.
