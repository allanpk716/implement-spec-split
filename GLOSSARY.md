# implement-spec-split

A skill that implements a spec's tickets with a cheap model doing the coding and a strong model doing the review.

## Roles and where they run

**Orchestrator**:
The main agent running in the user's Claude Code session; it owns the task graph and verification. On a cheap model it executes and relays only, and hands every judgment call to a stronger model (Opus review, a Design session, or the user).
_Avoid_: coordinator, lead

**In-session subagent**:
A subagent spawned by the Orchestrator inside the Claude Code session, with its model chosen by name (sonnet, opus, haiku, fable).
_Avoid_: native subagent, Claude subagent

**External worker**:
A separate coding-agent CLI process, a Worker harness running a Worker model, that the Orchestrator launches outside the session to do one role's work; it shares no conversation with the Orchestrator.
_Avoid_: delegate, GLM subagent, headless subagent

**Worker harness**:
The coding-agent CLI program an External worker runs in (codex or pi); it decides how progress is observed, how a stopped worker is Resumed and how its processes are killed, independent of which model it talks to.
_Avoid_: codex worker / pi worker when the model matters, agent CLI

**Worker model**:
The model an External worker's harness talks to (GLM-5.4 today); chosen separately from the harness, so one harness can serve different models and one model can run under different harnesses. On the codex path it is the user's own global switch (`/worker-model`, backed by `scripts/worker-model.sh` and stored in `~/.claude/state/worker-model`; default glm-5.4, ADR 0003): every `codex-worker.sh` fresh run reads it, so a Run that is already executing changes model at its next dispatch, while a Resume keeps the model of its first segment. v1 switches the codex path only (pi and the `agent` backend are not switched). Separate from the Judgment model, which has its own switch.
_Avoid_: implement model, backend model

**Implement backend**:
Which kind of executor runs the implementing roles for a run: an In-session subagent on the agent model (`agent` backend; `sonnet` is the legacy alias for it with the model pinned to sonnet), or an External worker on GLM (`codex` / `pi`).
_Avoid_: implement model (GLM is not a model the session can select)

**Agent model**:
The model the `agent` backend passes explicitly on every Agent call, selected per run with `--agent-model <sonnet|opus|haiku|fable>`; defaults to `IMPLEMENT_MODEL` (sonnet). In a GLM proxy environment an explicit `opus` may actually run GLM-5.4.
_Avoid_: implement model (ambiguous with harness-specific settings such as `GLM_MODEL`)

**Implementing roles**:
The exploration, implementer, merger and fix roles; everything except review.

**Review roles**:
The Standards and Spec reviewers of `mattpocock-skills:code-review`; always In-session subagents on a strong model (non-flash sessions only; in Flash mode every review runs out-of-session via `opus-review.sh`).

**Design session**:
A separate Claude Code session on the official subscription (Opus) that the Orchestrator opens through Orca for a design discussion (grill-with-docs, a wayfinder grilling ticket); the user talks to it directly, and it carries the discussion through to-spec before handing control back. When the Judgment model is switched to a substitute, it is an Orca terminal running that model's launcher instead, with the same handoff.
_Avoid_: Opus session, grill session, hop

**Opus review**:
A non-interactive judgment pass run outside the Orchestrator's session that reads a diff or draft and returns findings for the Orchestrator to act on. It runs on the official subscription's Opus, or on the switched Judgment model, in which case the findings file's first line names that model.
_Avoid_: strong-model review (ambiguous in a GLM session, where "opus" maps to GLM)

**Judgment model**:
The model that stands in for Opus in each of two roles: `review` (every Opus review) and `grill` (Design sessions). Each role is Opus, or the substitute the user names with its own global switch (`/judgment-model`, backed by `scripts/judgment-model.sh` and stored in `~/.claude/state/judgment-model`), today only glm-5.4; one command sets both roles. Both wrappers read their own role on every call, so a session that is already executing changes model at its next review or new Design session. Separate from the Worker model, which has its own switch (`/worker-model`).
_Avoid_: strong model, fallback model (the switch is the user's decision, never an automatic downgrade)

**Stage**:
One of the six kinds of work the pipeline routes to an executor: orchestration, design (grilling), research and drafting, implementation, review, and diagnosis. Each Stage has its own executor choice, which the user switches globally; a switch takes effect at the Stage's next dispatch or new session, never mid-call.
_Avoid_: phase, step (Steps are the numbered instructions inside a skill)

**Stage route**:
The executor assigned to one Stage: a Launcher profile, a model and a reasoning effort, optionally with an expiry after which the Stage returns to its default. Only combinations that have passed a smoke test may be routed. The user sets all routes with one command (`/grill-router`); it replaces the Judgment model and Worker model switches.
_Avoid_: model switch, model mapping

**Launcher profile**:
A named way to start an executor that this project maintains (for example the official Claude launcher, the GLM launcher, the flash launcher, codex on GLM): how it starts, how a model and reasoning effort are passed to it, and whether it has a headless form. Stage routes name Launcher profiles rather than Orca agents, because Orca cannot register custom launchers.
_Avoid_: harness (when meaning the route entry), agent slot

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

**Map fog**:
The in-scope questions a map can see coming but cannot yet phrase sharply enough to ticket, written in its `## Not yet specified` section; a map is fully discussed only when its decisions are all closed and its fog is empty.
_Avoid_: open questions, backlog

**Fog graduation**:
Turning part of a map's fog into new Decision tickets (or ruling it out of scope) once a resolution has made it specifiable; in Advance mode a worker proposes it and the user approves it in the combined round.
_Avoid_: re-charting (that is drawing a new map)

**Loose ticket triage**:
Classifying an open, unshelved ticket that belongs to no map or Spec as waiting on timing, needing a new map, needing one decision, or duplicate/stale; in Advance mode a read-only worker proposes the classification and tracker writes happen only after user approval.
_Avoid_: treating every loose ticket as grilling work

**Waiting on timing**:
A loose ticket whose named precondition has not been confirmed by the user; find-next reports the condition without asking or deciding that it is met, and starts work only when the user says to open that ticket.
_Avoid_: blocked ticket, agent-judged timing satisfaction

**Next step**:
The single action find-next recommends: a stage (to-tickets, to-spec, or a Decision ticket), its target, and the command to type.

**Advance mode**:
find-next's default GitHub-tracker behaviour: repeatedly scan, auto-resolve clear research tickets, prepare decision questions, propose Fog graduation, triage loose tickets, work task and prototype tickets, draft Specs/Tickets, ask one combined round for real trade-offs, publish, and launch the first wave. `--suggest` requests the old read-only Next-step behaviour.
_Avoid_: batch mode as a different mode (`--batch` is only an alias)

**Unfinished advance run**:
An Advance mode run directory whose `run-state.json` has no `finished_at` and whose owner process is dead, or a recent legacy run directory without the file that still points at this repository; the next Advance mode run lists it, reuses its still-valid worker outputs, resumes its half-done publishing, and then abandons it.
_Avoid_: Recovery (that is continuing a Spec's implementation Run)

**Orphan claim**:
A wayfinder Map ticket that has an Assignee and was updated within 3 days, while no live Orca agent terminal in this repository's worktrees names it (`#N` in title or preview); Advance mode asks whether to unclaim it instead of waiting for the 3-day stale rule.
_Avoid_: stale claim (older than 3 days, decided by update time alone)

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

**Unattended landing**:
A Run landing its Spec without asking the user first, because find-next's `launch-wave.sh` started it with `--auto-land` (the default; `--no-auto-land` opts a batch out). Review trade-offs that carry a recommendation marked auto-applicable are applied as recommended and listed as auto-decisions (自动拍板（可推翻）); only what really needs a human parks the Run. The session closes itself when the Run ends.
_Avoid_: auto-push, auto-merge, permanent authorisation (it covers one batch only)

**Parking report**:
The comment an unattended Run leaves on its Spec issue when a human must act before the Spec can go on; its first section `### 需要你决定` lists exactly that, in question-round form. The Run then releases its claim and ends, so the Spec shows as interrupted until the Supervisor writes the user's answers back as a `## 拍板` comment and resumes it. Tickets merely waiting for another Spec are a Partial landing, never a Parking report.
_Avoid_: failure report, blocking question, 停车 for "waiting on another Spec"

**Partial landing**:
A Run landing every ticket it can while the rest wait for another Spec: the landed tickets close, the Spec stays open, the integration branch is deleted, and the Spec becomes free again, so `--next-wave` starts it afresh once its blockers land. Its landing report lists `剩余：#<t> 等 #<spec>`.
_Avoid_: parked, interrupted

**Supervisor**:
The find-next session after it launched a wave (or `/find-next --watch`): holding the repo lock `find-next-supervise`, it waits on `find-next/scripts/watch-specs.sh` in the background and, only when a Spec lands, parks, or its session dies, tells the user one line of progress, asks the parked decisions in one round, resumes Specs, and gives the final summary. It is the one place the user reads; Spec sessions close themselves.
_Avoid_: dashboard (that is the Progress board), find-next advance

**Handoff reservation**:
A Claim record that `find-next/scripts/launch-wave.sh` writes with `claim.sh reserve` before it starts a session in Orca; it counts as active until `handoff_until_epoch` even though no live process holds it, and `claim.sh take` run inside that Spec's worktree adopts it (exit 4 when it was a resume).
_Avoid_: pre-claim, lease

**Launch state**:
The file `~/.cache/implement-spec-split/launch/<owner>__<name>.json` where `launch-wave.sh --apply` records the chosen worker count, wave size, apart pairs, whether the batch lands unattended (`auto_land`), and (when the `agent` backend was chosen) backend and agent model for a repository; `--next-wave` reuses those judgments while recalculating the order. State files from before the agent backend have no backend field and keep behaving like `--impl codex`; state files from before unattended landing became the default have no `auto_land` field and keep landing unattended.
_Avoid_: order cache (the order itself is recalculated)

**Repo registry**:
The repositories registered in Orca that have a GitHub remote; the Progress board reads it from Orca instead of keeping its own list, and a repository that leaves it is eligible for Board pruning.
_Avoid_: project list, Launch state (that only covers find-next launches)

**Progress board**:
The read-only, this-machine-only view, mainly read on a phone, of every repository in the Repo registry that uses this pipeline: its maps, Specs and Tickets with their parent-child links and counts, where the next implement-spec-split wave would start, and the progress of Runs and External workers; it shows progress and never acts.
_Avoid_: dashboard with controls, Orca status

**Board pruning**:
Deleting this machine's leftovers (Run directories, Launch state, board snapshots) of a repository that has left the Repo registry, or of Specs closed long ago; always listed first and done only on explicit confirmation.
_Avoid_: cleanup of GitHub issues (pruning never touches GitHub)

**Worker slot**:
One of the machine-wide places an External worker wrapper must hold while its agent runs; wrappers beyond that queue instead of failing, because all Runs share one GLM quota. The count is `ISS_MAX_WORKERS` if set, else the file `~/.cache/implement-spec-split/max-workers` (written by `scripts/max-workers.sh`, which find-next calls with its `--workers`), else 4.

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
