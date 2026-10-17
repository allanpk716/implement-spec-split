# implement-spec-split

A skill that implements a spec's tickets with a cheap model doing the coding and a strong model doing the review.

## Roles and where they run

**Orchestrator**:
The main agent running in the user's Claude Code session; it owns the task graph, verification and all judgment calls.
_Avoid_: coordinator, lead

**In-session subagent**:
A subagent spawned by the Orchestrator inside the Claude Code session, with its model chosen by name (sonnet, opus, fable).
_Avoid_: native subagent, Claude subagent

**External worker**:
A separate coding-agent CLI process (codex or pi, running GLM) that the Orchestrator launches outside the session to do one role's work; it shares no conversation with the Orchestrator.
_Avoid_: delegate, GLM subagent, headless subagent

**Implement backend**:
Which kind of executor runs the implementing roles for a run: an In-session subagent on sonnet, or an External worker on GLM.
_Avoid_: implement model (GLM is not a model the session can select)

**Implementing roles**:
The exploration, implementer, merger and fix roles; everything except review.

**Review roles**:
The Standards and Spec reviewers of `mattpocock-skills:code-review`; always In-session subagents on a strong model.

## Work

**Spec**:
The parent issue describing the whole feature; implemented in one run.
_Avoid_: PRD, epic

**Ticket**:
One child issue of a Spec; the unit an implementer works on.
_Avoid_: task, sub-issue

**Integration branch**:
The single branch where every Ticket of a Spec is merged before review.

**Frontier**:
The Tickets whose blockers are all merged, so they can be started now.

**Time limit**:
The longest an External worker may run in one go, set per role; reaching it stops the worker but keeps its conversation so it can be Resumed.
_Avoid_: timeout (ambiguous with Idle timeout and with a worker's own command timeouts)

**Idle timeout**:
How long an External worker may go without any visible activity before it is judged stuck and killed; a stuck worker is not Resumed.
_Avoid_: hang timeout

**Resume**:
Continuing a stopped External worker's own conversation, in the same worktree, instead of starting a new worker with a new Brief; decided by the Orchestrator.
_Avoid_: retry (that is the wrapper re-sending after an API error), re-brief

**Brief**:
The self-contained task description handed to an External worker, made of context pointers rather than copied content.
_Avoid_: prompt
