# AI Agent guide

This guide is for an AI agent that has been asked to install or run this skill. After reading it, you should be able to install the skill, verify the Codex executor, and run a spec correctly.

## What the skill does

`implement-spec-split` implements a GitHub spec and its child tickets on one integration branch. An Orchestrator in the user's Claude Code session owns scheduling, verification, review, and judgment. Cheaper executors do exploration, implementation, and fixes (merging is a script's job; a worker is dispatched only on a conflict or a colliding shared counter); two stronger reviewers always review the result.

How the implementing roles run is fixed (规格 #26): a headless read-only exploration through `scripts/codex-worker.sh` (Codex on GLM, on the 调研起草 Stage route) runs once before the Tickets, and each Ticket's implementation, fix and merge-conflict role is an Orca worker dispatched by `scripts/stage-dispatch.sh` on the 实现 Stage route. The launcher, model and reasoning effort come from the Stage route table, which only the user changes with `/grill-router`. There is no backend to choose.

## Install

Install the repository as a Claude skill:

```bash
git clone https://github.com/allanpk716/implement-spec-split \
  ~/.claude/skills/implement-spec-split
```

The user also needs Claude Code, the `mattpocock-skills` plugin, Git, and Node.js. Windows additionally needs Git Bash because the worker wrappers are Bash scripts. The target project must have the issue-tracker setup produced by `/setup-matt-pocock-skills`. Orca must be running with the 实现 route's launcher (`claude-glm` by default) on PATH, since the Ticket workers are Orca workers.

The headless Codex executor additionally needs the Codex CLI and a `custom` provider in `~/.codex/config.toml` that serves the configured GLM model. Do not put provider keys in this repository.

## Verify before a run

For Codex, run the cheapest meaningful preflight from the skill directory:

```bash
scripts/selftest-codex.sh --only L1
```

It contacts the configured provider and costs a small number of GLM tokens. A failure usually means the local GLM proxy is not running or its model configuration is wrong; show the error to the user — there is no other executor to switch to.

For a deterministic, token-free wrapper test:

```bash
scripts/selftest-codex.sh --only V1
```

The skill's normal invocation performs the Codex L1 preflight automatically before dispatching work. Run it manually here only when installing, troubleshooting, or changing the provider or route configuration.

## Run a spec

From a repository with an open spec:

```text
/implement-spec-split [spec ref]
```

Omit the spec reference and the skill tells you to run `/find-next --batch`, which gives the order and the commands (normally find-next starts the skill itself). Include `--parallel n` only when the user asks; the default limit exists because GLM rate limits can stop the whole run.

Follow `SKILL.md` in the installed skill directory. It is the complete operating procedure: write each Brief from the template with products only (the Spec issue, the exploration notes, the Ticket issue), dispatch and wait through the module with one command each, merge with the script first and one merge at a time, release every dispatch, verify worker results with the script gate, and reserve review for the configured strong model.

For the headless exploration, when it runs longer than expected, inspect its run directory (`<Spec Run root>/research`):

```bash
scripts/progress.sh <run directory>
```

This reports state, recent commands and edits, time since the last progress event, and token use. Use it on request or for diagnosis; the wrapper's watchdog already handles stuck workers, so do not poll it continuously.

## Find the next step (`find-next`)

`find-next/` is a separate, read-only skill in this repo. Install it with `ln -s <clone>/find-next ~/.claude/skills/find-next`. When the user asks what to do next with their wayfinder maps, follow `find-next/SKILL.md`: run the scanner, judge (by default on a `--read-only` codex worker), and return one next step with the command. When the user wants the whole picture ("what is left", "give me a to-do list"), use `--list`: run `scripts/pipeline-status.sh --all` yourself and print the grouped list, no worker. Never edit, claim or label tickets while doing so. When the user wants all missing specs written at once, use `--batch`: group the tickets, draft each group on a `--read-only` codex worker with `find-next/templates/brief-spec-batch.md`, review, ask the user once, and only after their confirmation publish with `find-next/scripts/publish-batch.sh --apply`. `/to-spec` and `/to-tickets` cannot be invoked by the model; tell the user to type them.

## Agent operating rules

- Never trust a worker's final report alone. Apply the verification gate in `SKILL.md`.
- Do not resume a timed-out worker unless it made progress, and resume it at most once.
- Do not automatically switch from GLM to Claude after auth, quota, or transient errors; ask the user.
- Do not ask Codex workers to delete directories recursively; their command policy may reject it.
- Ask the user before pushing, closing issues, or publishing anything.
- Exception for closing an execution Ticket as it merges (2026-11-28, 票 #78; allowed by the owner): `scripts/merge-ticket.sh --close-ticket <n>` (SKILL.md step 5) closes the Ticket without asking in every Run, with or without `--auto-land`. The Ticket has already merged, and closing it can be undone by reopening it. The rule above still holds for pushing, for closing the Spec, and for any other issue.
