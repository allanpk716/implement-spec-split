---
name: implement-spec-split
description: Implement a spec and its tickets like implement-spec, but with split models - implementer/merger/fix subagents run on Sonnet, the code-review subagents run on a stronger model (Opus). Use when the user wants "Sonnet 开发 + 高阶模型 review", or invokes /implement-spec-split.
disable-model-invocation: true
---

# implement-spec-split

Same goal and task-graph workflow as `mattpocock-skills:implement-spec`, with one difference: **models are chosen per role** instead of inherited from the session. The steps below are self-contained; do not invoke the original `implement-spec` (it runs its own review on the inherited model).

## Model config (edit here to change the policy)

- `IMPLEMENT_MODEL` = `sonnet` — implementer, merger, exploration and fix subagents
- `REVIEW_MODEL` = `opus` — every code-review subagent (use `fable` for the strongest option)

Always pass the `model` parameter explicitly on every Agent call below. Never rely on inheritance: the session itself may be on any model.

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

## Steps

1. Read the spec and tickets; build the task graph / frontier. The issue tracker comes from the repo's `docs/agents/issue-tracker.md`; if missing, tell the user to run `/setup-matt-pocock-skills`.
2. (optional) Exploration subagent, `model: IMPLEMENT_MODEL`. It saves its markdown notes in a directory outside the repo, accessible by all later subagents, so implementers can focus on implementation.
3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.
4. Implementer subagents, one worktree + branch per ticket, `model: IMPLEMENT_MODEL`, run in background. Each one:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `mattpocock-skills:tdd` to build the ticket;
   - merges the integration branch tip into its own branch before reporting done.
5. When an implementer completes, a merger subagent (`model: IMPLEMENT_MODEL`) merges its work into the integration branch and re-runs the test suite.
6. If this changes the frontier, kick off more implementer subagents for the newly unblocked tickets.
7. **Review (the split point).** When all tickets are merged, call the Skill tool with `mattpocock-skills:code-review` (not the built-in `code-review`, which does not spawn the two axis sub-agents) on the integration branch, using the branch point from the main branch as the fixed point. When it spawns the Standards and Spec sub-agents, set `model: REVIEW_MODEL` on both. Do not skip this step and do not downgrade the model.
8. Fix every issue the review raises in a single subagent (`model: IMPLEMENT_MODEL`), giving it the review report as a context pointer. If an item is a design-level or subtle correctness problem rather than a mechanical fix, tell the fix subagent to report it back instead of guessing, then resolve it yourself or ask the user.
9. If a draft PR exists, mark it ready for review. Otherwise resolve each ticket the way the tracker closes work (e.g. merge with `Closes #n` and push) and report the integration branch. Confirm with the user before pushing/closing if they haven't already authorised it.
10. Clean up all implementer worktrees.

## Report at the end

State which model ran each role (implement / review / fix), the review findings per axis, and how they were resolved.
