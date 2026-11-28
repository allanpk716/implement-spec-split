# implement-spec-split

A skill that implements a spec's tickets with a cheap model doing the coding and a strong model doing the review.

## Roles and where they run

**Orchestrator**:
The main agent running in the user's Claude Code session; it owns the task graph and verification. On a cheap model it executes and relays only, and hands every judgment call to a stronger model (a 审查（review）, a Design session, or the user).
_Avoid_: coordinator, lead

**In-session subagent**:
A subagent spawned by the Orchestrator inside the Claude Code session, with its model chosen by name (sonnet, opus, haiku, fable) or pinned by the session's settings. Since 规格 #26 the implementing roles are never In-session subagents: they are always Orca workers dispatched by `scripts/stage-dispatch.sh`. The review subagents are: the code-review subagents of a non-flash session, and since 票 #84 the read-only (`Explore`) review subagents of a flash session whose review Stage route is GLM and whose subagents are pinned to the route's model — the only case `scripts/opus-review.sh --where` says in-session.
_Avoid_: native subagent, Claude subagent

**External worker**:
A separate coding-agent CLI process, a Worker harness running a Worker model, that the Orchestrator launches outside the session to do one role's work; it shares no conversation with the Orchestrator. Since 规格 #26 that is the headless executor (`scripts/codex-worker.sh`: the step-2 exploration and find-next's research, decision and drafting workers); the implementing roles are not External workers but Orca workers the dispatch module starts on the 实现 route.
_Avoid_: delegate, GLM subagent, headless subagent

**Orca worker**:
An executor that Orca orchestration runs for one dispatch of a Stage and keeps track of: a terminal started on a Launcher profile in a worktree and adopted into an Orca Run (`worker-start --terminal`), so that its liveness, its completion report (`worker_done`) and its release are Orca's. Since 规格 #26 the implementing roles are Orca workers the dispatch module starts on the 实现 Stage route; unlike an External worker they have no Time limit or Idle timeout of their own, and nothing wraps them.
_Avoid_: External worker (that is the headless executor outside Orca), subagent, backend

**Worker harness**:
The coding-agent CLI program an External worker runs in (codex); it decides how progress is observed, how a stopped worker is Resumed and how its processes are killed, independent of which model it talks to.
_Avoid_: codex worker when the model matters, agent CLI

**Worker model**:
The model an External worker's harness talks to (GLM-5.4 today); chosen separately from the harness, so one harness can serve different models and one model can run under different harnesses. On the codex path the Stage routes decide it: a dispatch with `--read-only` runs the research route, any other dispatch the implementation route, both set by the user with `/grill-router`. Every fresh `codex-worker.sh` run reads the table, so a Run that is already executing changes model at its next dispatch, while a Resume keeps the model and effort of its first segment. An Orca worker's model is the 实现 route the dispatch module read when it started, recorded in its Sidecar.
_Avoid_: implement model, backend model

**Implement backend**:
Retired (规格 #26): which kind of executor ran the implementing roles for a run — an In-session subagent or an External worker — chosen in the Config. The implementing roles are now always Orca workers dispatched by `scripts/stage-dispatch.sh` on the 实现 Stage route, whatever the session.
_Avoid_: using it for the Stage route (the route chooses the launcher, model and effort, never whether a role is dispatched)

**Agent model**:
Retired (规格 #26): the model the former in-session implementing subagents were passed on every Agent call. The model an implementing role runs on is its Stage route, read by the dispatch module at each dispatch.
_Avoid_: implement model (ambiguous with harness-specific settings such as `GLM_MODEL`)

**Implementing roles**:
The four roles a Run dispatches through the dispatch module (`scripts/stage-dispatch.sh`), each on its Stage route (规格 #26): the step-2 exploration — headless, a `--read-only` dispatch whose executor is `codex-worker.sh`, on the 调研起草 route — and, on the 实现 route as Orca workers, a Ticket's implementer, the fix role and the conflict role. The fix role has one dispatch form of its own, the Re-bump role (规格 #61); it is not a fifth role. Not review, and not a merger: merging is `scripts/merge-ticket.sh`, a script, and only a conflict dispatches the conflict role.

**Re-bump role**:
The fix role in the form the Spec session dispatches after `scripts/merge-ticket.sh` exits 6 because both sides added the same number of a numbered directory, or left a version file with the same content (规格 #61): `--role fix --ticket <m>` in step 5 (named `fix-<m>`; it works in the Ticket worktree on `spec-<n>-t<m>`) and `--role fix` without a ticket in step 9.1 (it works in the integration worktree on `spec-<n>`; main is the other side). Its Brief's first sentence overrides the dispatch module's Task, since a fix role's terminal opens in the integration worktree either way; the Brief carries the merger's collision list verbatim, and the role reads the other side only (`git ls-tree`, `git show`), lists every number that side holds before choosing, re-increments, runs the test command and commits — it merges nothing back: the merger is rerun instead, and only its exit `0` gets through — a numbered directory clears to a merge, while a version file clears the gate but, both sides having changed the same line to different values, meets a textual conflict at the merge (exit `3`, for the merge role in step 5 or the fix role in step 9.1, with both sides' intent). At most 2 rounds per ticket in step 5, per main merge in step 9.1; each round's role is released when it ends. In step 9.1 the re-bump's commits get one review only; in step 5 they are reviewed with step 7's review.
_Avoid_: re-bump worker, counter role (it is the fix role; a re-bump is its work)

**Review roles**:
The Standards and Spec reviewers of `mattpocock-skills:code-review`; In-session subagents on a strong model in a non-flash session, and in a flash session wherever the review Stage route puts them (票 #84): out of session, as the two subagents of the headless process `opus-review.sh` starts (an official route, or a session whose subagents are not pinned to the route's model), or read-only In-session subagents (`Explore`) of the flash session itself, on a GLM route with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`. On either side of a flash session the subagent model is the review route's model, never one the session picks.

**Design session**:
A separate Claude Code session that the Orchestrator opens through Orca for a design discussion (grill-with-docs, a wayfinder grilling ticket); the user talks to it directly, and it carries the discussion through to-spec before handing control back. It runs the design Stage route: an Orca terminal started on the routed Launcher profile with its model and effort (the official subscription's Opus by default), with the same handoff whatever the route.
_Avoid_: Opus session, grill session, hop

**审查（review）**:
A judgment pass that reads a diff or draft and returns findings for the Orchestrator to act on; in English prose, a review. Named Opus review until 票 #84 (2026-11-28), from the time it was always Opus. It runs on the review or diagnosis Stage route (the official subscription's Opus by default, otherwise the routed Launcher profile, model and effort), and the findings file's first line names the route. Where it runs is the route's decision too (票 #84): out of session, non-interactive, through `scripts/opus-review.sh`, unless `opus-review.sh --where` says in-session for this session (a GLM route and subagents pinned to its model), in which case it runs as read-only In-session subagents of the flash session and `opus-review.sh --stamp` writes the findings under the same first line, marked `（会话内子代理）` and `（强度未生效）`.
_Avoid_: Opus review (retired 票 #84; the review runs on whatever the route names, Opus only by default), strong-model review (ambiguous in a GLM session, where "opus" maps to GLM); calling it "Opus 审核中" when the route is not Opus

**Opus review**:
Retired (票 #84, 2026-11-28): the judgment pass now called 审查（review）, which runs on the review or diagnosis Stage route whatever the model; the name stayed from when the review was always Opus.
_Avoid_: using it for a review on a route that is not Opus; say 审查（review）

**Judgment model**:
The model that stands in for Opus wherever a judgment is made: every 审查（review）, and each Design session. It is Opus, or the substitute the user routes the review, diagnosis and design Stages to with `/grill-router` (today glm-5.4). The Stage routes replaced the two-role switch that used to set it: each dispatch reads its Stage's route, so a session that is already executing changes model at its next review or new Design session.
_Avoid_: strong model, fallback model (the route is the user's decision, never an automatic downgrade)

**Stage**:
One of the six kinds of work the pipeline routes to an executor: orchestration, design (grilling), research and drafting, implementation, review, and diagnosis. Each Stage has its own executor choice, which the user switches globally; a switch takes effect at the Stage's next dispatch or new session, never mid-call.
_Avoid_: phase, step (Steps are the numbered instructions inside a skill)

**Stage route**:
The executor assigned to one Stage: a Launcher profile, a model and a reasoning effort, optionally with an expiry after which the Stage returns to its default. Only combinations that have passed a smoke test may be routed. The user sets all routes with one command (`/grill-router`); it replaces the Judgment model and Worker model switches. Since 票 #84 a review or diagnosis route also decides where that review runs: an official `claude` route always out of session; a GLM route in session when the session pins its subagents to the route's model (`CLAUDE_CODE_SUBAGENT_MODEL` with its `[1m]` suffix aside equal to the route's model, and `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` — the flash session's settings), otherwise out of session. `scripts/opus-review.sh --where` decides from the table and the session's environment and prints the verdict with one line of reason; a session never decides it itself.
_Avoid_: model switch, model mapping

**Launcher profile**:
A named way to start an executor that this project maintains (for example the official Claude launcher, the GLM launcher, the flash launcher, codex on GLM): how it starts, how a model and reasoning effort are passed to it, and whether it has a headless form. Stage routes name Launcher profiles rather than Orca agents, because Orca cannot register custom launchers.
_Avoid_: harness (when meaning the route entry), agent slot

## Work

**Spec**:
The issue describing the whole feature; implemented in one run. On GitHub this is an open issue using the to-spec template heading `## Problem Statement`; a legacy open parent issue with unfinished children is also treated as a Spec. On a local-markdown tracker it is a ticket whose body uses `## Problem Statement`, or a closed Closing ticket. The Spec number is the number of that issue, and the integration branch is `spec-<Spec number>`. A Hand-written Spec (手写规格) is an existing Spec whose body has neither a `实现票：#N` line nor a `地图：#N` / `来源地图：#N` line, so it hangs under no map; find-next still drafts its Tickets (`S<k>=spec:<n>`) with a Brief that points to neither a map nor an implementation ticket.
_Avoid_: PRD, epic

**Spec Run root**:
The directory one Run of a Spec keeps its files in: `~/.cache/implement-spec-split/runs/<repo>-<n>-<YYYYmmdd-HHMM>/` (`<repo>` = the main checkout's directory name), outside every worktree. `run-phase.sh` writes `run.json` there, which is how Recovery finds the Run; it is the `--run-dir` of every dispatch the Run makes — the `<run dir>` a Sidecar lives in, with each dispatch's own files under `<Spec Run root>/<name>/` — and it holds the Briefs (`briefs/`), the review findings and the parking and final reports. The dispatch module refuses a run directory inside the Spec worktree, since release removes that worktree.
_Avoid_: run dir / run directory / `<run dir>` on their own (once a Sidecar is involved they name this directory, but say Spec Run root), state dir, dispatch dir (that is one dispatch's `<Spec Run root>/<name>/`)

**Ticket**:
One child issue of a Spec, or — for a single-ticket Spec — the referenced map implementation issue itself; the unit an implementer works on. A loose source ticket (see below) is never one: nobody implements it.
_Avoid_: task, sub-issue

**Map ticket**:
An implementation child issue under a wayfinder map, without a `wayfinder:*` label; to-spec may turn it into an independent Spec.
_Avoid_: map decision

**Loose source ticket**:
The mapless ticket a Spec was drafted from directly (find-next's `直接起草规格`), named on the Spec's `实现票：#<n>` line the way a map ticket is. Not an execution ticket: no implementer is dispatched for it (`frontier.sh` lists it under `# source`; `pipeline-status.sh --graph` flags it `source`), and it is closed together with its Spec when that lands (SKILL.md step 9).
_Avoid_: execution ticket, map ticket

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
Turning part of a map's fog into new Decision tickets (or ruling it out of scope) once a resolution has made it specifiable; in Advance mode a worker proposes it and the proposal is auto-decided by its recommendation in the decision round (自动拍板，可推翻), and only then does the map's boundary change.
_Avoid_: re-charting (that is drawing a new map), asking the user to approve the graduation

**Loose ticket triage**:
Classifying an open, unshelved ticket that belongs to no map or Spec as waiting on timing, needing a new map, needing one decision, or duplicate/stale; in Advance mode a read-only worker proposes the classification and the three actionable classes are auto-decided by that recommendation (可推翻) before anything is written to the tracker; waiting on timing is the user's call and is only reported.
_Avoid_: treating every loose ticket as grilling work, waiting for the user's approval of a triage

**Waiting on timing**:
A loose ticket whose named precondition has not been confirmed by the user; find-next reports the condition without asking or deciding that it is met, and starts work only when the user says to open that ticket.
_Avoid_: blocked ticket, agent-judged timing satisfaction

**Next step**:
The single action find-next recommends: a stage (to-tickets, to-spec, or a Decision ticket), its target, and the command to type.

**Advance mode**:
find-next's default GitHub-tracker behaviour: repeatedly scan, auto-resolve clear research tickets, prepare decision questions, propose Fog graduation, triage loose tickets, work task and prototype tickets, draft Specs/Tickets, settle every real trade-off in one combined decision round by the worker's recommendation (auto-decided, 可推翻; no round cap, nothing waits for a reply), publish, and launch the first wave. `--suggest` requests the old read-only Next-step behaviour.
_Avoid_: batch mode as a different mode (`--batch` is only an alias), question round (the combined round is a decision round that reports, it does not ask)

**Unfinished advance run**:
An Advance mode run directory whose `run-state.json` has no `finished_at` and whose owner process is dead, or a recent legacy run directory without the file that still points at this repository; the next Advance mode run lists it, reuses its still-valid worker outputs, resumes its half-done publishing, and then abandons it.
_Avoid_: Recovery (that is continuing a Spec's implementation Run)

**Orphan claim**:
A wayfinder Map ticket that has an Assignee and was updated within 3 days, while no live Orca agent terminal in this repository's worktrees names it (`#N` in title or preview); Advance mode asks whether to unclaim it instead of waiting for the 3-day stale rule.
_Avoid_: stale claim (older than 3 days, decided by update time alone)

**Run**:
One invocation of the skill, implementing one Spec from start to finish; several Runs may work on different Specs at the same time. Not an Orca Run: its wave's Orca Run only starts a Run (and serves as the handle for taking a wave over); a Run does not report into it — whether a Run is done is read from `pipeline-status.sh` and the keeper — and it creates one Orca Run of its own for its Ticket workers. The dispatch a Run's start left in the wave's Orca Run never reports `worker_done`; Orca releases it once the terminal closes.

**Orca Run**:
An Orca orchestration Run, named by its id on every Orca orchestration call that acts on a Run and never inherited from the terminal (the calls that name none are the two kinds `lib-orca.sh` Rule 2 excepts: the ones addressing one dispatch by its id, `worker-stop` / `worker-show` / `worker-release`, and `worker-list`, which the keeper calls without a Run of its own): the one `launch-wave.sh` creates per wave for the Spec sessions it dispatches (kept in the Launch state as `run`), and the one each Spec session creates for the Ticket workers it dispatches.
_Avoid_: Run without "Orca" (that is one invocation of the skill), wave (that is the batch, not Orca's object)

**Takeover**:
Binding a new terminal to an existing Orca Run with `orca orchestration run-use --id <run id>` after the terminal that coordinated it closed or was replaced, so that dispatching, waiting and releasing can go on. The workers never stopped and nothing is re-dispatched: a worker's `worker_done` mail keeps landing in the Run while no terminal coordinates it.
_Avoid_: Recovery (that is continuing a Spec's implementation in a new Run), adopt, bind

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
A Run landing its Spec without asking the user first, because find-next's `launch-wave.sh` started it with `--auto-land` (the default; `--no-auto-land` opts a batch out). Closing an execution Ticket as it merges (SKILL.md step 5, `merge-ticket.sh --close-ticket`) is not part of it: every Run does that without asking, `--auto-land` or not (2026-11-28, 票 #78). Review trade-offs are never parked on: an item with a usable recommendation is applied as recommended, one without takes the reversibility rule (可逆性高 > 改动面小 > 与现有 ADR 一致), and each is listed as an auto-decision (自动拍板（可推翻）); only a parking category of `quota`, `transient`, `auth` or `error` parks the Run. After a completed landing the Run turns each unexecuted loosening into a loose ticket, whatever repository the Spec is on, and also runs `install.sh` — for a Spec on this skill's own repository only (skill links and tighten items; loosenings are only listed), never for a Spec on another repository, whatever `install.sh` its root may hold. The session closes itself when the Run ends.
_Avoid_: auto-push, auto-merge, permanent authorisation (it covers one batch only)

**Parking report**:
The comment an unattended Run leaves on its Spec issue when the Run cannot go on by itself; two machine-readable lines under the `## 停车报告` heading name the category — one of `quota`, `transient`, `auth`, `error` — and the resumable time, and the first section `### 需要你决定` lists what a human must act on, in question-round form (`auth`: an operation that needs the owner's identity, credentials or physical action; `error`: repeated failures, a correctness problem left after three review rounds, a guardrail violation, or trade-off options none of which is reversible). `quota` and `transient` are resumed by the keeper after the stated time; `auth` and `error` are only notified. The Run then releases its claim and ends, so the Spec shows as interrupted until it is resumed. The Supervisor decides an item that carries a recommendation itself and writes the answer back as a `## 拍板` comment (marked 总控自动拍板，可推翻) for a `quota` / `transient` park and for a legacy report (a retired category such as `decision` or `other`, or no category line); it never decides or resumes an `error` park, whose items it lists for the user instead; only `auth` asks the user. Tickets merely waiting for another Spec are a Partial landing, never a Parking report.
_Avoid_: failure report, blocking question, 停车 for "waiting on another Spec", a trade-off without a recommendation as a reason to park (that takes the reversibility rule)

**Partial landing**:
A Run landing every ticket it can while the rest wait for another Spec or are `ready-for-human` tickets (never dispatched): the landed tickets close, the Spec stays open, the integration branch is deleted, and the Spec becomes free again, so `--next-wave` starts it afresh once its blockers land. Its landing report lists what is left with the landing check's `# report` lines: `剩余：#<t> 等 #<spec>` for another Spec, `剩余：#<t> 等 #<issue>` for a standalone issue, `剩余：#<t> 等人工 #<t>` behind a human ticket, `剩余：#<t> 等搁置 #<t>` behind a shelved one.
_Avoid_: parked, interrupted

**Supervisor**:
The find-next session after it launched a wave (or `/find-next --watch`): holding the repo lock `find-next-supervise`, it waits on `find-next/scripts/watch-specs.sh` in the background and, only when a Spec lands, parks, or its session dies, tells the user one line of progress, settles the parked items itself where they carry a recommendation (a `## 拍板` comment marked 总控自动拍板，可推翻) — never for a parking category of `error`, whose items it lists for the user without resuming the Spec — asks the user only for a parking category of `auth`, resumes Specs, and gives the final summary, which lists every auto-decision with its reversal recipe (`推翻 #<n> <条目> 改选 <X>`). It is the one place the user reads; Spec sessions close themselves.
_Avoid_: dashboard (that is the Progress board), find-next advance

**Handoff reservation**:
A Claim record that `find-next/scripts/launch-wave.sh` writes with `claim.sh reserve` before it starts a session in Orca; it counts as active until `handoff_until_epoch` even though no live process holds it, and `claim.sh take` run inside that Spec's worktree adopts it (exit 4 when it was a resume).
_Avoid_: pre-claim, lease

**Launch state**:
The file `~/.cache/implement-spec-split/launch/<owner>__<name>.json` where `launch-wave.sh --apply` records the chosen worker count, wave size, apart pairs, whether the batch lands unattended (`auto_land`) and the Orca Run of the latest wave (`run`) for a repository; for a batch a flash orchestrator launched it also records `flash: true` with `launch_agent`, the Orca slot the 编排 route named for that wave. `--next-wave` reuses those judgments while recalculating the order. How a Spec's tickets are implemented is not in it: that is the Stage route table's 实现 route, read at each dispatch, and the `impl`/`agent_model` fields state files carried before 规格 #26 are ignored. State files from before unattended landing became the default have no `auto_land` field and keep landing unattended.
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

**Shared counter**:
A file or sequence that exists in one place and is incremented by every change that touches it (a version number, a CHANGELOG, a migration number). Two Tickets that each bump the same shared counter can be edited in parallel worktrees without git seeing a conflict, so the second to merge carries a duplicate number; drafting chains such Tickets with `blocked_by` inside one Spec, and across Specs reports them in the drafting worker's `result.md` so that find-next keeps the two Specs `--apart`. Drafting also labels every such Ticket `shared-counter` (through the manifest's ticket `labels`); that label is what `pipeline-status.sh --graph` reports as `shared_counter` and what makes the Frontier release one such Ticket at a time.
_Avoid_: version conflict, counter conflict (git's textual conflict is exactly what this is not)

**Frontier**:
The Tickets whose blockers are all merged, so they can be started now; of the Tickets labelled `shared-counter` (see Shared counter) only one is released at a time, the lowest-numbered, and the rest wait for it.
_Avoid_: using it for a map's open decisions (that is the Map frontier)

**Time limit**:
The longest an External worker may run in one go, set per role; reaching it stops the worker but keeps its conversation so it can be Resumed. An Orca worker (a dispatched implementing role) has none: nothing wraps it, and its liveness is Orca's.
_Avoid_: timeout (ambiguous with Idle timeout and with a worker's own command timeouts)

**Idle timeout**:
How long an External worker may go without any visible activity before it is judged stuck and killed; a stuck worker is not Resumed. It is a clock, and only an External worker has one: an Orca worker has none, and its being idle means something else — its turn ended (Idle without a report), which is read from Orca's evidence, never from the time passed.
_Avoid_: hang timeout, reading "idle" as time passing for an Orca worker (a live Orca worker is judged by Orca's evidence, never by the clock)

**Idle without a report (空闲未报)**:
An Orca worker that ended its turn without sending its `worker_done` — it left its tests running in the background, wrote that it would report when they finished, and sat idle (票 #79). Its idle is Orca's `tui-idle`, a turn that is over, not the Idle timeout, which is a clock on an External worker. It is known from Orca's evidence, never from the clock: a mail of the Run's that is no `worker_done` (one `wait` hands such mail over with exit 8) whose body says the worker stopped without reporting, or the last thing the worker wrote (`orca orchestration worker-read --dispatch <id>`) being that message, with nothing after it. A worker still in its turn is not this case, however long its test runs: that one is the Watchdog's. Nothing wakes such a worker, so its report never comes and it is never waited for again: the Orchestrator verifies what it left itself, in the foreground, judges it by the verification gate's three script checks as if it had reported, and puts the evidence in the Sidecar's dispatch directory (`session-verify.md`); the Run's final report says 主会话核实 in place of the outcome. The rule is written once, in SKILL.md's "Dispatching a role" item 6; Recovery, the Watchdog's `3` report and a `wait` that timed out (exit `5`) or took such a mail (exit `8`) point to it. find-next's `--worker agent` subagent gets the same rule in `find-next/SKILL.md`.
_Avoid_: stalled (a live worker that is still in its turn and has stopped touching files: the Watchdog's case, which stops it and dispatches the role again), ended without reporting (that is a dispatch Orca calls `exited`: Recovery's case), Idle timeout (a clock's verdict on an External worker)

**Resume**:
Continuing a stopped External worker's own conversation, in the same worktree, instead of starting a new worker with a new Brief; decided by the Orchestrator.
_Avoid_: retry (that is the wrapper re-sending after an API error), re-brief

**Brief**:
The self-contained task description handed to a worker (an Orca worker the dispatch module started, or the headless executor), made of products rather than of process: a Ticket's Brief carries the Spec issue's content, the exploration notes that concern it and the Ticket issue's content, never the Spec session's reasoning; for a fix role, the review report; for a conflict role, the conflicted paths; for a Re-bump role, the merger's collision list (its stderr lines, verbatim), behind the first sentence that overrides the dispatch module's Task by naming the worktree and branch the role works in. A Ticket's Brief is drafted from `find-next/templates/brief-implement.md`. The section every find-next Brief template shares states the rules a worker keeps about processes: the foreground-test rule, in its general form, and the No inline script rule.
_Avoid_: prompt

**foreground-test rule (前台测试规则)**:
The rule every Brief of an implementing role carries since 票 #79: the role's tests and verification finish in the foreground before its final report — it never puts a test in the background and then ends its turn, and a command that does end up in the background is waited for in the foreground until it ends. The reason is that nothing wakes a worker whose turn has ended, so a report promised for when a background test finishes never comes (Idle without a report). SKILL.md writes the rule once, in step 5's `3` line; the dispatch texts of the merge, re-bump and fix roles — steps 5, 8 and 9.1, and the PR path of an Unattended landing — point back to it, and a dispatched role's Brief has it from its template: the Ticket Brief template in item 3 of its 要求, the section every find-next Brief template shares in its general form, for a test or a long command, next to the No inline script rule.
_Avoid_: background tests, finishing the turn to wait for a notification (that is what the rule forbids: the worker that did it is Idle without a report)

**No inline script (禁内联脚本)**:
The rule every Brief of a dispatched role carries since 票 #80: a multi-line script is never wrapped into one Bash command — `bash -c '…'`, `sh -c '…'` or a `$'…'` string — whoever runs it. The ban is on the wrapping itself, not on an `rm` inside it: a script wrapped that way meets a confirmation even under `--dangerously-skip-permissions`, and holding no deleting command is no protection — on 2026-11-28 one that held nothing but `read`, `printf` and `grep` was stopped as if it did, a misjudgment of the permission layer — and an unattended session then sits at the prompt. A script that has to be multi-line is written to a file in a `mktemp -d` directory and run from there, with a `trap` of its own to clean up, or the work is split into separate Bash calls; inside that file only the `trap` deletes anything, its own `mktemp -d` directory, and every other deletion is its own `rm` command with a literal path. SKILL.md writes the rule once, next to "No unresolvable `rm`", and the session keeps to it in its own commands, as find-next's SKILL.md tells its main session too; a dispatched role gets it from its Brief: the section every find-next Brief template shares, next to the foreground-test rule, and the 固定条款 section of the root Brief template (`templates/brief-implement.md`).
_Avoid_: inline script for a script file kept under `mktemp -d` (that file is the rule's way out; "inline" is the wrapping into one Bash command), "the `rm` rule" (that is a single `rm` a Bash command holds and the permission layer cannot resolve — "No unresolvable `rm`" in SKILL.md; this rule is about the wrapping, and holds with no `rm` at all)

**Lean start (精简启动)**:
Starting an implementation worker (a Ticket's implementation or fix role, dispatched by `scripts/stage-dispatch.sh` on the implementation Stage route; the merge role starts normally, since it resolves conflicts on the Integration branch and needs the CLAUDE.md and hooks `--bare` drops) with the Launcher profile's `--bare`: no CLAUDE.md, skills, plugins or hooks are loaded; the rules it must follow come from a rules file injected as a system prompt (`--append-system-prompt-file`, the file named by `ISS_DISPATCH_LEAN_RULES`, default `templates/lean-rules.md`) and the MCP servers it needs from `--mcp-config`, which takes a trivial task from 18.6K to 1.2K input tokens (ADR 0004). It is the default; without the rules file the start is a normal one, `ISS_DISPATCH_BARE` (0, off, no or false) turns it off, and the dispatch's Sidecar records which it was (`bare`, `bare_note`).
_Avoid_: 精简开关 as the name of the start (the switch is only the opt-out), bare mode

**Sidecar**:
The JSON file `<run dir>/dispatch-<name>.json` (`<run dir>` is the Spec Run root) that `scripts/stage-dispatch.sh` writes for one dispatch and keeps current as the dispatch lives: the Stage route it took, the worktree, terminal and Orca dispatch id it got, whether the start was a Lean start and why not when it was not, the worker_done once `wait` recorded it (with the report path), the model read off the worker's terminal while it still existed (`actual_model`, taken by `release` or `verify`: Orca records none for an adopted terminal), and the release time. It lives in the Spec's run directory, outside every worktree, so that `release` removing the child worktree loses none of it; a report the worker wrote inside that worktree is copied out next to the sidecar first (`report-from-worktree.md`). The files of one dispatch are in its dispatch directory, `<Spec Run root>/<name>/` — among them the report the worker was told to write, that copy `report-from-worktree.md`, and, for a worker gone Idle without a report (which leaves the sidecar no `worker_done` to record), `session-verify.md`, where the Orchestrator puts the evidence of the verification it did itself; the Run's final report names that file as the dispatch's report path and says 主会话核实 where another dispatch's line says `worker_done.outcome`.
_Avoid_: dispatch record, dispatch state (that is Orca's), status.json (a headless executor's own file, which the sidecar's report_path may name)

**Local ops ticket (本机运维票)**:
An execution Ticket whose body says 「在本机执行」 and has a `## 护栏` section: an ops ticket the dispatched implementer carries out on this machine itself — files, services, local state — inside the guardrails, as opposed to an ssh ops ticket, which runs through ssh-manager. Like every ops ticket it goes through the dispatch module but needs no TDD and no commit, and when it changes no code its evidence gate (every acceptance criterion with evidence) replaces the new-commits / clean-tree checks. An agent-driven smoke ticket is a Local ops ticket whose body states the Orca operation sequence to drive (the `orca` CLI calls in order), the expected evidence and the guardrails; opening an Orca terminal or a session is then part of the sequence, not a re-delegation, and `worker-start` is allowed only where the guardrails name it. It is not a `ready-for-human` ticket: that label is only for what needs the user's own identity, credentials or physical action.
_Avoid_: human ticket, `ready-for-human` ticket (that is for the user's own identity, credentials or physical action), ssh ops ticket (that one runs through ssh-manager)

**Loosening (放宽项)**:
A change that would only be possible by loosening a safety boundary: an expectation item of the repository's local configuration marked loosen (the list `install.sh` carries), an option a review offered that loosens one, or a step of a Ticket that would need one. No agent ever executes a loosening: `install.sh` only lists it under 「未执行的放宽项」 (a WARN that counts as drift, so an install with one exits 1 — a report, not a failed install; `--json`: `unexecutedLoosenings`), an implementer does not take the step and records it under the same heading of its result report (that acceptance criterion counts as met by the record), and no decision round ever picks such an option — not the Spec session's step 8, and not find-next's decision round or its Supervisor: a recommended loosening is not adopted either, and an item that offers nothing else is not decided but listed for the user and recorded under 「未执行的放宽项」. After a landing the Spec session turns each item into one loose ticket — labelled `needs-triage`, first line `来源规格：#<n>（未执行的放宽项，独立跟踪、不卡规格收尾）`, body in the decision-ticket format with `推荐：改写方案避免放宽。` and a line saying no agent may loosen directly — never a follow-up under the Spec, and the next find-next round triages it as a single decision whose outcome is never the loosening itself, at most a rewrite that avoids it.
_Avoid_: manual step, follow-up ticket (it would make the Spec a Partial landing), asking the user whether to loosen
