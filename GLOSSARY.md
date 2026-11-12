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
The issue describing the whole feature; implemented in one run. On GitHub this is an open issue using the to-spec template heading `## Problem Statement`; a legacy open parent issue with unfinished children is also treated as a Spec. On a local-markdown tracker it is a ticket whose body uses `## Problem Statement`, or a closed Closing ticket. The Spec number is the number of that issue, and the integration branch is `spec-<Spec number>`.
_Avoid_: PRD, epic

**Ticket**:
One child issue of a Spec, or — for a single-ticket Spec — the referenced map implementation issue itself; the unit an implementer works on.
_Avoid_: task, sub-issue

**Map ticket**:
An implementation child issue under a wayfinder map, without a `wayfinder:*` label; to-spec may turn it into an independent Spec.
_Avoid_: map decision

**Decision ticket**:
A child issue of a wayfinder map whose resolution is a decision, typed research, prototype, grilling or task (a `wayfinder:<type>` label on GitHub, a `Type:` header line on a local tracker).
_Avoid_: map ticket (that is an implementation child)

**Closing ticket**:
On a local-markdown tracker, the map's last task ticket, which writes the map's decisions into a chapter of `SPEC.md`; once closed it serves as the map's Spec.
_Avoid_: spec ticket

**Map frontier**:
The open Decision tickets of a map whose blockers are all closed and that nobody has claimed.
_Avoid_: Frontier (that is implementation Tickets)

**Next step**:
The single action find-next recommends: a stage (to-tickets, to-spec, or a Decision ticket), its target, and the command to type.

**Run**:
One invocation of the skill, implementing one Spec from start to finish; several Runs may work on different Specs at the same time.

**Recovery**:
Continuing, in a new Run, a Spec that an earlier Run started but did not finish; triggered only by the user choosing that Spec.
_Avoid_: takeover, Resume (that is continuing one External worker's own conversation)

**Claim record**:
The file `<git common dir>/implement-spec-split/claims/spec-<n>.json` written by `scripts/claim.sh` when a Run takes a Spec; it names the Claude Code process (PID and start time) holding the Spec, so any Run or find-next can tell an active Spec from an interrupted one without Orca.
_Avoid_: lock file, Orca status

**Landing lock**:
The repo-wide lock (`scripts/lock.sh acquire land --scope repo`) a Run holds from merging the latest main branch into its integration branch until it has pushed the merged main branch, so that what it tested is what lands.
_Avoid_: merge lock (mergers inside one Run are already serialised)

**Worker slot**:
One of the machine-wide places (`ISS_MAX_WORKERS`, default 4) an External worker wrapper must hold while its agent runs; wrappers beyond that queue instead of failing, because all Runs share one GLM quota.

**Integration branch**:
The single branch where every Ticket of a Spec is merged before review.

**Frontier**:
The Tickets whose blockers are all merged, so they can be started now.
_Avoid_: using it for a map's open decisions (that is the Map frontier)

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
