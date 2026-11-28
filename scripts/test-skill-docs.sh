#!/usr/bin/env bash
# Checks that the skill's prose says what spec #26 decided about dispatching the
# implementing roles (ticket #45), and no longer names what it retired. The
# other test-*.sh scripts check scripts; this one checks SKILL.md, the Ticket
# Brief template, the hooks README and (ticket #48) the user documents, so that
# a later edit cannot quietly bring the backend switch, the progress tabs or
# the retired wrappers back, or drop the one-command dispatch / wait / release /
# merge-ticket path, the takeover steps or the worktree tree, without a test
# going red. The cumulative review's settled points (MAINTAINING 第 51 条) are
# pinned the same way: find-next's flash default, delegate-guard's flash
# reason, the === TASK === form the guards read and the hooks README's
# fail-open wording. Ticket #60 (规格 #58) adds the partial-landing wording
# (tickets left to a human), the Brief-hygiene sentence and the 环境约束
# section the three root Brief templates share with find-next's (every bullet
# of it but the two process rules of 票 #79 and 票 #80, which the find-next
# templates alone carry — the merge note at the end of this header says why).
# Ticket #69 (规格 #58) pins find-next's decision round: step 6 decides each
# item by the recommendation instead of asking, the wrap-up and the supervisor
# list every auto-decision with its reversal recipe, and the three-round cap is
# gone.
# Ticket #70 (规格 #58) pins the narrowed parking of the spec session: a
# trade-off is never parked on (a recommendation is applied, anything else takes
# the reversibility rule), the category table is down to quota / transient /
# auth / error, and the hooks README's rule B says the same.
# The review fix of 规格 #58 pins what it changed, group by group: the supervisor
# leaves an error park alone (做错 4 — relayed to the user, never decided or
# resumed); no decision point of find-next picks an option that loosens a safety
# boundary (做错 3 — step 6, the selecting Opus review of the flash mode and the
# supervisor each carry the rule); step 9's local install is for this skill's own
# repository only (越界 2 — no other repository's install.sh is run at landing);
# the Ticket Brief template carries the rules 规格 #58 wrote for every Ticket
# (Spec 缺失 1: the local ops ticket and the agent-driven smoke ticket in the ops
# section, the smoke exception of rule 3, a loosening recorded instead of taken,
# the fifth item of the report); and the user documents and the Brief templates
# describe find-next's combined round as a decision round, never as a question
# round (Standards 1); and doctor's two hints are told apart in the hooks README
# and the two setup guides (Standards 3 — stage 3's FAIL gives the manual fix,
# the install-state row is the one that says to run install.sh); and the smoke
# ticket paragraph says that a smoke test of the skill's own text loads the
# branch through CLAUDE_CONFIG_DIR, since the installed skills point at main
# until the landing (the review's 未核实与提醒).
# The second review fix of 规格 #58 (r2) pins, group by group: no document still
# says find-next stops at a question round (Standards 2 — both setup guides,
# grill-map's hand-over and find-next's usage bullet); find-next step 3's ops
# dispatch names codex-worker.sh instead of a retired "Ops tickets codex
# backend" and calls the worker it starts a worker, not an implementer
# (Standards 4 — the same wording in brief-task.md); the Unattended landing
# entry of GLOSSARY limits the install to this skill's own repository and no
# longer the loose tickets (Standards 5); the loosening bullet of step 8 is
# pinned as its whole sentence, since the bare heading appears on five lines of
# SKILL.md and a pin on it alone caught nothing (Standards 8); the three drafting
# templates justify ready-for-human by identity, credentials or physical action
# and carry a guardrail sample for a local or smoke ops ticket next to the ssh
# one, each "样例见下" naming its sample (Spec 3); step 8 of SKILL.md never picks
# an option that needs the owner's own hands (Spec 7, trade-off 3 = A); both
# setup guides state the two-clone limitation of a clone-direct install (Spec 6,
# trade-off 2 = A: one WARN at every landing, which never clears).
# The third review fix of 规格 #58 (r3) pins, group by group: auth covers a
# physical action too (trade-off 2 = A — the category table's auth row, step
# 8's auth rule, the hands-on bullet, Flash mode's Stopping, GLOSSARY's Parking
# report and the hooks README's rule B all say identity, credentials or
# physical action, and the flash paths — Stopping and the input of find-next's
# selecting Opus review — pick no option that needs the owner's hands; the
# category set itself is not touched); and four wording points (硬违规 3, 判断
# 5 / 6 / 7): the landing report's section is 要你做的 in both setup guides, the
# hands-on bullet of step 8 sits at the level of the two rules above it, the
# parking report's 现状 paragraph says like its lead-in that the supervisor
# reads the first section, and an ops step's rollback line names this machine
# next to the remote host; and two documents older than 规格 #58 that its rules
# had turned into wrong sentences (主审补记 10、11): README's find-next bullets
# on task and loose tickets, and docs/ai-agents.md's "ask first" rule.
# So is the merger's exit 6 wiring (规格 #61 票 #74 and the
# review fixes after it): the step 5 / 9.1 re-bump dispatch forms, the one
# review of the re-bump and the conflict resolution, every 9.1 round taking
# the next free --attempt, a failed-gate re-dispatch counting as a 9.1 round,
# the re-bump Brief named after its dispatch, the step 5 rerun reading exits 4
# and 1 from their own lines (one positive and one negative check), where a
# 9.1 rerun's 3 / 4 / 5 go, the 9.1 review trigger stated once and pointed to
# from Unattended landing and Flash mode, and the --attempt of a step 5
# re-dispatch and of 9.1's fix roles taken as the next free one.
# So is 票 #78:
# step 5 always passing --close-ticket (closed on exit 0 only, without asking
# in every Run, a failed close retried once), step 9 running the landing check
# and reading its five sections and report lines, exit 2 ending in a parking
# with category error rather than a loop, and step 0 telling a loose source
# ticket (never dispatched, closed with its Spec) from a map implementation
# ticket. The review fixes after it (票 #78 审查修复 r3) are pinned the same
# way: the final 结论 block at one line per item, its 结果 line counting what is
# left and 要你做的 naming a Ticket merged and left open by its number, the
# `剩余：` lines under 细节, all four forms of what a Ticket waits for in SKILL.md
# and GLOSSARY, and no umbrella "implementation ticket" on the `实现票` line.
# The merge review after that (合并复审) pinned one sentence more: step 9's `2`
# line hands a live role that went idle without a report to "Dispatching a role"
# item 6, never waited for again.
# So are the two rules of ticket #79: tests and verification finish in the
# foreground before the final report (the Brief templates and the dispatch texts
# of steps 5, 8 and 9.1), and a main session verifies a worker gone idle without
# a report itself (ps, git) instead of waiting again. Its review settled where
# each is written and pointed to, and that is pinned too: the rule once in step
# 5's `3` line and once in the section every find-next Brief template shares,
# Recovery's never-stop rule with that worker as its one exception, Orca's mail
# read by its body, and the evidence of such a worker in a file of its own.
# The re-review after that (r3) is pinned the same way: GLOSSARY defines the
# rule and the worker gone idle without a report; the Watchdog's `3` report on
# a live worker, and a `wait` that timed out, read the worker's last line first
# and hand item 6's case to item 6; item 6's evidence is written once, Recovery
# and the wait's mail only pointing to it; the PR path's fix role carries the
# rule; a conclusion's sources name session-verify.md in Flash mode and in the
# two setup documents; and the ticket number stays in the title of item 6 only.
# So is 票 #80: a multi-line script is never wrapped into one Bash command
# (`bash -c`, `sh -c`, a `$'…'` string), whatever it holds — one with an `rm`
# and one without both asked for confirmation even under
# --dangerously-skip-permissions, and an unattended session then sits at the
# prompt. SKILL.md states the rule next to its `rm` rule, with the two ways
# out (a script file in a `mktemp -d` directory that cleans up after itself,
# or separate Bash calls) and every other deletion its own `rm` with a
# literal path; find-next's SKILL.md states it for its main session; and a
# dispatched role gets it from its Brief: the section every find-next Brief
# template shares, next to the foreground-test rule, and the fixed clauses of
# the root Brief template.
# The merge of 规格 #58 with main (2026-11-28: spec-58 merging origin/main)
# kept every check of both sides — 309 of main and the 249 规格 #58 added to
# the same 144, none held twice, 558 in all — and wrote three of 规格 #58's
# checks anew where the merged documents differ from the branch: the GLOSSARY
# line that names a ticket left to a human takes the landing check's form
# (票 #78 landed first and lists the four forms of `等` side by side); the
# find-next usage sentence takes 票 #84's name for the review as its subject;
# and the three root Brief templates are compared with the find-next section
# without its two process-rule bullets, since the root dispatch template
# carries both in its fixed clauses, with the cleanup handed to the clause
# against a recursive deletion, and the Design session's Briefs were not given
# them. Each is said again where it is pinned, and in MAINTAINING's 自测 entry.
# So is 票 #86: the graph reads the `ready-for-agent` label, and an open Ticket
# without it is listed under `# decision` by frontier.sh and landing-check.sh
# alike — never dispatched, holding no landing back, under 要你做的 in the
# report, and counted like a ready-for-human Ticket wherever a step keeps the
# Spec open for a human; step 0 rule 3 releases a Spec whose Tickets all wait
# for triage; and a Spec missing from the graph is exit 3, parked on at once
# where exit 1 (a failed query) is retried once — in step 9's lines and in
# step 1's failure rule.
#
# Usage: scripts/test-skill-docs.sh
# Exit code: the number of failed checks.
#
# Test hooks: none. Reads the repository's own files only.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL=$ROOT/SKILL.md
BRIEF_FIND_NEXT=$ROOT/find-next/templates/brief-implement.md
# The root template of the Opus / codex division, a different file from BRIEF_FIND_NEXT.
BRIEF_ROOT_TEMPLATE=$ROOT/templates/brief-implement.md
HOOKS=$ROOT/hooks/README.md
GLOSSARY=$ROOT/GLOSSARY.md
FIND_NEXT=$ROOT/find-next/SKILL.md
LIB_TRANSCRIPT=$ROOT/hooks/lib-transcript.js
DELEGATE_GUARD=$ROOT/hooks/delegate-guard.js
# What a user or a session reads as current wording. MAINTAINING's numbered
# records, the ADRs and the smoke record keep the old names as history, and
# docs/codex-backend.md keeps its experiment record, so none of them is listed.
USER_DOCS="README.md docs/setup.md docs/setup.en.md GLOSSARY.md docs/ai-agents.md hooks/README.md \
  find-next/SKILL.md grill-feature/SKILL.md grill-map/SKILL.md templates/brief-implement.md \
  templates/brief-investigate.md templates/brief-mock.md templates/global-claude-md.md \
  templates/global-claude-md.en.md"

PASSED=0
FAILED=0

ok() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

has() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then ok "$2"; else bad "$2" "missing [$1] in ${3#$ROOT/}"; fi
}

without() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then bad "$2" "unexpected [$1] in ${3#$ROOT/}"; else ok "$2"; fi
}

count_at_least() { # text n name file -- a rule several places must each carry
  local n
  n=$(grep -Fo -- "$1" "$4" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge "$2" ]; then ok "$3"; else bad "$3" "expected at least $2 occurrences of [$1] in ${4#$ROOT/}, found $n"; fi
}

for file in "$SKILL" "$BRIEF_FIND_NEXT" "$BRIEF_ROOT_TEMPLATE" "$HOOKS" "$GLOSSARY" "$FIND_NEXT" "$LIB_TRANSCRIPT" "$DELEGATE_GUARD"; do
  [ -f "$file" ] || { bad "file exists" "$file"; printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"; exit "$FAILED"; }
done

# --- SKILL.md: what 规格 #26 retired --------------------------------------------

for gone in '--impl' '--agent-model' 'IMPLEMENT_BACKEND' 'IMPLEMENT_MODEL' 'GLM_MODEL' \
  'progress-tab' 'orca-tabs.txt' '**Progress tabs.**' 'GLM_TIME_LIMIT' 'GLM_IDLE_TIMEOUT' \
  'pi-worker.sh' 'both backends' 'agent backend' 'External workers (backends'; do
  without "$gone" "SKILL.md no longer names $gone" "$SKILL"
done

# --- SKILL.md: the dispatch module is the only way ------------------------------

has 'stage-dispatch.sh dispatch --stage implementation' 'SKILL.md dispatches an implementing role through the module' "$SKILL"
has 'stage-dispatch.sh dispatch --stage research' 'SKILL.md dispatches the exploration through the module' "$SKILL"
has 'stage-dispatch.sh wait --sidecar' 'SKILL.md waits with the module' "$SKILL"
has 'stage-dispatch.sh release --sidecar' 'SKILL.md releases through the module' "$SKILL"
has 'merge-ticket.sh --worktree <integration worktree>' 'SKILL.md merges with the script first' "$SKILL"
has 'merge-ticket.sh' 'SKILL.md names the merger script' "$SKILL"
# Step 5 tells a landed ticket (exit 5) from an incomplete one (exit 2): the
# first is released and gone on with, never dispatched again.
has '- `5` (the Ticket branch is already part of the integration branch' 'SKILL.md step 5 knows merge-ticket exit 5' "$SKILL"
has 'Do not dispatch the ticket again' 'SKILL.md step 5 does not re-dispatch a landed ticket' "$SKILL"
has 'find-next/templates/brief-implement.md' 'SKILL.md names the Ticket Brief template' "$SKILL"
has 'orca orchestration run-create' 'SKILL.md creates the Orca Run for Ticket workers' "$SKILL"
has 'WORKER_ALLOW_FLASH=1' 'SKILL.md lets the flash session run the headless exploration' "$SKILL"
has '--mcp-config' 'SKILL.md adds MCP through --mcp-config for ops tickets' "$SKILL"
has '## 护栏' 'SKILL.md copies the guardrails into the Brief' "$SKILL"
# Local ops tickets, agent-driven smoke tickets and the loosening rule of 规格 #58
# (MAINTAINING 第 56 条), next to the two ssh ops ticket sentences of 第 36 条
# above: the Ops tickets section names the local kind by its trigger, says that
# a smoke ticket's terminal is part of the sequence rather than a dispatch, and
# states the loosening rule for every ticket, with the order to write it into
# every Brief.
has 'says 「在本机执行」 and has a `## 护栏` section' 'SKILL.md names the local ops ticket by its trigger' "$SKILL"
has '- **Local ops tickets**: the implementer carries the ticket out on this machine itself' \
  'SKILL.md says a local ops ticket is carried out on this machine' "$SKILL"
has '- **Agent-driven smoke tickets**' 'SKILL.md has the agent-driven smoke ticket paragraph' "$SKILL"
has 'opening an Orca terminal or a session is part of the operation sequence, not the dispatching of an implementing worker' \
  'SKILL.md: a smoke ticket opening a terminal is not a re-delegation' "$SKILL"
has '- **Loosenings, on every ticket**' 'SKILL.md states the loosening rule for every ticket' "$SKILL"
has 'the implementer does not take it. It records the item under 「未执行的放宽项」 of its result report' \
  'SKILL.md: a loosening is recorded, never taken' "$SKILL"
has 'Write the rule into every Brief' 'SKILL.md: the loosening rule goes into every Brief' "$SKILL"
# A smoke ticket that tests the skill's own text must load the branch: installed
# skills point at the main checkout's main until the landing, so the session
# under test gets a CLAUDE_CONFIG_DIR of its own (the review of 规格 #58, and
# ticket #71's second and third rounds).
has "A smoke ticket that tests the skill's own text loads the branch's version, not the installed one" \
  "SKILL.md: a smoke ticket testing the skill's text loads the branch, not the installed main" "$SKILL"
has 'so the session under test is started with `CLAUDE_CONFIG_DIR` pointing at a temporary config directory whose `skills/` links to a clone of the branch' \
  'SKILL.md: the session under test gets a CLAUDE_CONFIG_DIR linked to a clone of the branch' "$SKILL"
has 'read_only_violation' 'SKILL.md gates the exploration on the read-only check' "$SKILL"
has 'never optional' 'the exploration is no longer optional' "$SKILL"
has 'close-self.sh' 'SKILL.md still closes the session with close-self' "$SKILL"
# Step 10 carries the run directory in both forms (MAINTAINING 第 52 条, 做错 3):
# close-self.sh releases no Ticket worktree without --run-dir, so a landing or
# a parking that drops it leaves them behind for Recovery. Each code span is
# pinned as a whole, so neither form can lose the flag on its own.
has '`<skill dir>/scripts/close-self.sh --run-dir <Spec Run root> --remove-worktree <integration worktree>`' \
  'SKILL.md step 10 closes a landed Run with the run directory' "$SKILL"
has '`<skill dir>/scripts/close-self.sh --run-dir <Spec Run root>`' \
  'SKILL.md step 10 closes a parked Run with the run directory' "$SKILL"
# Step 7 in a non-flash session is unchanged: the code-review skill on REVIEW_MODEL.
has 'mattpocock-skills:code-review' 'step 7 still calls the code-review skill' "$SKILL"
has 'model: REVIEW_MODEL' 'step 7 still sets the review model' "$SKILL"
# The three script checks of the verification gate.
has 'new commits' 'the gate checks new commits' "$SKILL"
has 'a clean tree' 'the gate checks a clean tree' "$SKILL"
has "merger script's test run passes" 'the gate checks the merger script test run' "$SKILL"

# --- SKILL.md: the merger's exit 6 is wired in (规格 #61 票 #74) -------------------

# Step 5 dispatches a re-bump role at the conflict role's hook: the fix role
# with the ticket number (named fix-<m>), sent to the ticket worktree by its
# Brief because the module opens a fix role's terminal in the integration
# worktree. The role reads the other side and merges nothing back; at most 2
# rounds, then a park; the implementer is released before the re-bump role.
has 'a worker is dispatched only on a conflict or a colliding shared counter' \
  'SKILL.md step 5 dispatches a worker on a conflict or a colliding counter' "$SKILL"
has "--ticket spec-<n>-t<m> --test '<the repo's test command>' [--counter <path>]..." \
  'SKILL.md step 5 passes --counter to the merger' "$SKILL"
has '`--role fix --ticket <m>`, one command as above, which the module names `fix-<m>`' \
  'SKILL.md step 5 dispatches the re-bump role as fix with the ticket number' "$SKILL"
has 'it works in the ticket worktree `<ticket worktree>` on branch `spec-<n>-t<m>` and changes nothing in the integration worktree' \
  'SKILL.md step 5 re-bump Brief overrides the Task with the ticket worktree' "$SKILL"
has 'the other side is read only (`git ls-tree spec-<n>:docs/adr/`, `git show spec-<n>:VERSION`)' \
  'SKILL.md step 5 re-bump role reads the other side and merges nothing back' "$SKILL"
has 'At most 2 re-bump rounds per ticket' 'SKILL.md step 5 caps the re-bump at 2 rounds' "$SKILL"
# On a rerun, exits 4 and 1 are read as their own lines say: those lines sit
# below the `6` line, so "as above" pointed at nothing (规格 #61 review r2,
# Standards 4).
has '`4` and `1` read as in their own lines below' 'SKILL.md step 5 rerun reads exits 4 and 1 from their own lines' "$SKILL"
without '`4` and `1` read as above' 'SKILL.md step 5 rerun no longer points 4 and 1 upward' "$SKILL"
has 'a third `6` parks with category `error`' 'SKILL.md step 5 parks on a third re-bump miss' "$SKILL"
has 'release in this order: the implementer first' \
  'SKILL.md step 5 releases the implementer before the re-bump role' "$SKILL"
has '--watch <ticket worktree>=<its dispatch dir>' \
  'SKILL.md step 5 watches the ticket worktree for the re-bump role' "$SKILL"
has '`fix-<m>` for step 5' 'SKILL.md names the re-bump role fix-<m> in the run directory' "$SKILL"
# Its Brief follows the general rule, briefs/<name>.md with <name> the dispatch
# name: it gets no naming scheme of its own (规格 #61 review r2, 取舍 3).
has '<Spec Run root>/briefs/fix-<m>.md' 'SKILL.md step 5 names the re-bump Brief after the dispatch name' "$SKILL"
without 'briefs/rebump-<m>.md' 'SKILL.md no longer gives the re-bump Brief a name of its own' "$SKILL"
has "step 5's re-bump takes \`--ticket <m>\` and is named \`fix-<m>\`" \
  'SKILL.md dispatch section lets fix take --ticket for a re-bump' "$SKILL"
# Step 9.1 merges main through the merger (ticket #73's --no-ticket-worktree
# shape) and reads its exits: 5 is nothing to do, not a test pass; 6 is a
# re-bump role without a ticket number that reads main only; one review covers
# the re-bump commits and the conflict resolution, in Unattended landing and
# Flash mode alike.
has "--ticket origin/<main branch> --no-ticket-worktree --test '<the repo's test command>'" \
  'SKILL.md step 9.1 merges main through the merger' "$SKILL"
without 'the main merge is the plain git merge' 'SKILL.md step 9.1 no longer merges main by hand' "$SKILL"
has 'this is not a test pass' 'SKILL.md step 9.1 reads exit 5 as nothing to do, not a test pass' "$SKILL"
has '`--role fix` without `--ticket`' 'SKILL.md step 9.1 dispatches the re-bump role as fix without a ticket' "$SKILL"
# Every round of that re-bump takes the next free --attempt: step 8's fix role
# may already hold the bare name `fix`, and the module refuses a second
# dispatch under a name that has a sidecar (exit 64), so a first round sent
# as `--role fix` alone would never start (规格 #61 review, Standards 1).
has 'every round takes the next free `--attempt <n>`' \
  'SKILL.md step 9.1 re-bump rounds each take the next free attempt' "$SKILL"
without 'each later round as `--attempt <n>`' \
  'SKILL.md step 9.1 no longer leaves the first re-bump round without an attempt' "$SKILL"
# The cap counts what step 5 counts: a re-dispatch after the re-bump role's
# failed gate is a round too, so 9.1 cannot be read as three dispatches
# (规格 #61 review r2, Spec a-1).
has 'at most 2 rounds, a re-dispatch after a failed gate counting as a round (every round takes the next free `--attempt <n>`' \
  'SKILL.md step 9.1 counts a re-dispatch after a failed gate as a round' "$SKILL"
has 'git ls-tree origin/<main branch>:docs/adr/' 'SKILL.md step 9.1 re-bump role reads main only' "$SKILL"
has 'the re-bump commits and the conflict resolution together' \
  'SKILL.md reviews the step 9.1 re-bump and the conflict resolution once' "$SKILL"
has 'shared counters collide (merger exit `6`) — dispatch a re-bump role' \
  'unattended landing dispatches a re-bump role on exit 6' "$SKILL"
has '**Step 9 conflicts and re-bumps**' 'flash mode covers the step 9 re-bump' "$SKILL"
# A rerun of the 9.1 merger has a destination for every exit, as step 5's rerun
# has: 3 / 4 go to their own lines, a 4 the fix role turned green is reviewed
# like a committed conflict resolution, and a 5 means the re-bump role merged
# main itself -- that role's failed gate, and never step 2 without tests and
# review (规格 #61 review r3, 取舍 2A). The review trigger is written once, in
# 9.1's `6` line, and Unattended landing and Flash mode point back to it (r3,
# Standards 6). A step 5 re-dispatch and 9.1's fix roles take the next free
# --attempt, never a bare `--attempt 2` a re-bump round may already hold (r3,
# 主审补充 2).
has "a rerun's \`3\` / \`4\` go to their own lines below" \
  'SKILL.md step 9.1 rerun sends exits 3 and 4 to their own lines' "$SKILL"
has 'or the fix role has turned the tests green after a `4`' \
  'SKILL.md step 9.1 reviews the re-bump once a 4 is turned green' "$SKILL"
has "a rerun \`5\` means the re-bump role merged main itself" \
  'SKILL.md step 9.1 reads a rerun 5 as the re-bump role having merged main' "$SKILL"
has 'never to step 2 without tests and review' \
  'SKILL.md step 9.1 does not go on after a rerun 5 without tests and review' "$SKILL"
has "Once step 9.1's merge has landed (step 9.1's \`6\` line says when: after a re-bump, a committed conflict resolution, or a \`4\` turned green)" \
  'unattended landing points the 9.1 review trigger back to step 9.1' "$SKILL"
has "then once step 9.1's merge has landed (step 9.1's \`6\` line says when) run" \
  'flash mode points the 9.1 review trigger back to step 9.1' "$SKILL"
without 'has landed after either' \
  'SKILL.md no longer repeats the two-case 9.1 review trigger verbatim' "$SKILL"
has 're-dispatch it once with the next free `--attempt <n>`, within the 2-round cap' \
  'SKILL.md step 5 re-dispatches a failed re-bump gate with the next free attempt' "$SKILL"
has "step 8's form, with the next free \`--attempt <n>\` since step 8's fix role and the re-bump rounds already hold names" \
  'SKILL.md step 9.1 conflict fix role takes the next free attempt' "$SKILL"
has "step 8's form, each round with the next free \`--attempt <n>\`" \
  'SKILL.md step 9.1 test-fix rounds take the next free attempt' "$SKILL"
without 're-dispatch it once with `--attempt 2`' \
  'SKILL.md step 5 no longer names a fixed attempt for a re-bump re-dispatch' "$SKILL"

# --- SKILL.md: the merger closes Tickets and step 9 checks the landing (票 #78) ---

# Step 5 always passes --close-ticket, and the merger closes a Ticket on its
# exit 0 only: a merged Ticket left open keeps the Tickets it blocks out of the
# frontier (票 #26 merged four Tickets without closing them). Closing a merged
# Ticket is the one closing allowed for every Run, --auto-land or not.
has '     --close-ticket <m>' 'SKILL.md step 5 passes --close-ticket to the merger' "$SKILL"
has '`--close-ticket <m>` names the Ticket being merged, and this step always passes it: on its exit `0`, and only there, the merger closes the Ticket' \
  'SKILL.md step 5 always passes --close-ticket and closes the Ticket on exit 0 only' "$SKILL"
has 'Never skip the flag: the frontier reads `blocked_by` and nothing else' \
  'SKILL.md step 5 says never to skip --close-ticket' "$SKILL"
has 'It does so in every Run, with or without `--auto-land`, without asking: this is the one closing of an issue allowed for all Runs (2026-11-28, 票 #78)' \
  'SKILL.md step 5 states the exception: a merged Ticket is closed without asking in every Run' "$SKILL"
has 'A close that fails is tried once more by the merger' \
  'SKILL.md step 5 says the merger retries a failed close once' "$SKILL"
has 'and names on stderr one it could not close — close that by hand, the merge stands' \
  'SKILL.md step 5 exit 0 line keeps the hand action for a Ticket not closed' "$SKILL"
has '**The merger closes a Ticket only on its own exit `0`.**' \
  'SKILL.md step 5 says the merger is the only one that closes on a merge' "$SKILL"
has "Step 9's landing check refuses to land while such a Ticket is open." \
  'SKILL.md step 5 points the Tickets left open to the landing check' "$SKILL"

# Step 9 runs the landing check before the lock and reads its sections: the
# six it lists (five until 票 #86 added `# decision`) and the report lines it
# ends with. Exit 2 leads back to step 1,
# and an empty frontier with no implementing role alive leads back to the check
# and then to a parking with category error, never to a loop (the parking
# report names every Ticket under # open). A Ticket that waits is reported with
# the check's own line: what it waits for may be another Spec, a standalone
# issue, a human Ticket or a shelved one, and the line says which.
has '<skill dir>/scripts/landing-check.sh --repo <owner/name> --spec <n>' \
  'SKILL.md step 9 runs the landing check' "$SKILL"
has "lists the Spec's open Tickets in six sections — \`# open\`, \`# waiting\`, \`# human\`, \`# decision\`, \`# shelved\`, \`# source\`" \
  'SKILL.md step 9 names the six sections of the landing check' "$SKILL"
without 'open Tickets in five sections' 'SKILL.md step 9 no longer names five sections' "$SKILL"
without 'open Tickets in four sections' 'SKILL.md step 9 no longer names four sections' "$SKILL"
has "ends with \`# report\`, one \`剩余：\` line per open execution Ticket, ready for a report as it is" \
  'SKILL.md step 9 takes the report lines of the landing check as they are' "$SKILL"
has "exits \`0\` only when every execution Ticket of the Spec is closed (a loose source ticket does not count: it is closed with the Spec below; a Spec without Tickets passes)" \
  'SKILL.md step 9 passes the check without counting the loose source ticket' "$SKILL"
has '**The way out is parking, never a loop:** back at step 1, when the frontier is empty and no implementing role is alive' \
  'SKILL.md step 9 parks on an empty frontier with no implementing role alive' "$SKILL"
has '`2` again parks with category `error`, the parking report listing every line of `# open` and `# report`' \
  'SKILL.md step 9 parks with category error and lists every open Ticket' "$SKILL"
has 'answers `exited` for every dispatch of this Run that is not released, and each of those has been handled as step 5 and Recovery say' \
  'SKILL.md step 9 asks Orca which implementing roles are alive, after the ended ones are handled' "$SKILL"
has 'one that is `unverifiable` is never parked over (the Watchdog rule)' \
  'SKILL.md step 9 never parks over an unverifiable role' "$SKILL"
# A role Orca calls `live` may be one that ended its turn without a report:
# that one is "Dispatching a role" item 6's case, so the `2` line says so where
# it calls a live role still working. It is verified and wrapped up by item 6's
# evidence before exit 2 is judged, never waited for again; the pointer names
# the item, not the ticket (合并复审, 取舍 1).
has 'one that is `live` is still working (the Run waits for it as step 5 says) — unless it went idle without a report, which is "Dispatching a role" item 6'"'"'s case: that one is verified and wrapped up as item 6 says before this is judged, never waited for again' \
  'SKILL.md step 9 hands a live role gone idle without a report to item 6, never waiting for it again' "$SKILL"
has 'a Ticket under `# waiting` waits for another Spec, a standalone issue, or a human' \
  'SKILL.md step 9 names everything a waiting Ticket can wait for' "$SKILL"
has 'the `# report` lines go in the report as they are (`剩余：#<t> 等 #<spec>` for another Spec, `剩余：#<t> 等 #<issue>` for a standalone issue, `剩余：#<t> 等人工 #<t>` behind a human Ticket, `剩余：#<t> 等搁置 #<t>` behind a shelved one)' \
  'SKILL.md step 9 reports a waiting Ticket by what it waits for, in all four forms' "$SKILL"
without '`# waiting` goes in the report as `剩余：#<t> 等 #<spec>`' \
  'SKILL.md step 9 no longer reports a waiting Ticket as waiting for a Spec only' "$SKILL"
has '`# human` and `# shelved` go in the report too, a human Ticket under 要你做的' \
  'SKILL.md step 9 sends a human Ticket to 要你做的' "$SKILL"
has 'the Tickets the merger closed as they merged (step 5) were never asked about' \
  'SKILL.md step 9 keeps its confirmation for the Spec and the Tickets merged without being closed' "$SKILL"
# Step 0 rule 2 and step 9 name the tickets of the `实现票` line without the
# umbrella "implementation ticket" (审查 r3, 判断项 3: GLOSSARY has no such word,
# and a loose source ticket is never one). A map implementation ticket is still
# named as such, and every ticket on the line is closed with its Spec.
has 'take the open tickets referenced on an `实现票：#<n>`' \
  'SKILL.md step 0 rule 2 takes the tickets on the 实现票 line, whatever kind each is' "$SKILL"
without 'Multiple referenced implementation tickets' \
  'SKILL.md step 0 rule 2 no longer calls every ticket on the line an implementation ticket' "$SKILL"
without 'every implementation ticket on its `实现票` line' \
  'SKILL.md step 9 no longer closes "implementation tickets" as an umbrella' "$SKILL"
has 'Close the Spec too, and every ticket on its `实现票` line: a map implementation ticket, even when that map implementation ticket has its own sub-issues, and a loose source ticket (step 0, rule 2b), which no merger ever closed, since nothing is dispatched for it' \
  'SKILL.md step 9 closes every ticket on the 实现票 line with the Spec, the loose source ticket included' "$SKILL"

# Step 0 rule 2 tells a map implementation ticket (an execution ticket) from a
# loose source ticket (never one): nothing is dispatched for the source, and a
# Spec whose line gives nothing else has no execution ticket yet, so it is
# released and stopped like a blocked Spec instead of landing with nothing done.
has '**(b) A loose source ticket** (GLOSSARY.md; 票 #83) belongs to no map' \
  'SKILL.md step 0 rule 2 names the loose source ticket' "$SKILL"
has 'It is **not an execution ticket**: nothing is ever dispatched for it (`frontier.sh` keeps it out of the frontier and lists it under `# source`)' \
  'SKILL.md step 0 rule 2b keeps the loose source ticket out of the frontier' "$SKILL"
has 'and it is closed together with the Spec when the Spec lands (step 9), not as anything merges' \
  'SKILL.md step 0 rule 2b closes the loose source ticket with its Spec' "$SKILL"
has 'one whose line gives nothing but a source ticket has no execution ticket yet (rule 3)' \
  'SKILL.md step 0 rule 2b sends a Spec without an execution ticket to rule 3' "$SKILL"
has '3. **Blocked Spec, or one without an execution ticket.**' \
  'SKILL.md step 0 rule 3 covers a Spec without an execution ticket' "$SKILL"
has 'a Spec whose frontier is empty while `# source` names its loose source ticket (rule 2b)' \
  'SKILL.md step 0 rule 3 names the empty frontier of a source-only Spec' "$SKILL"
has 'a Run that went on would land it with nothing done and close the source ticket with it' \
  'SKILL.md step 0 rule 3 says why a source-only Spec is not landed' "$SKILL"
has '`# source` lists the loose source ticket (step 0, rule 2b), which is never dispatched either' \
  'SKILL.md step 1 names the source section of the frontier' "$SKILL"

# --- 票 #86: a Ticket without `ready-for-agent` waits for triage; a Spec missing from the graph parks at once ---

# The graph reads the `ready-for-agent` label and both scripts act on it alike
# (scripts/lib-graph.sh): an open Ticket without the label is listed under
# `# decision`, is never dispatched and holds no landing back, while it is
# neither `ready-for-human`, shelved nor the loose source. And the two scripts
# tell a Spec the graph does not hold (exit 3) from a query that failed (exit
# 1): the first is parked on at once, the second is retried once.
#
# Step 9, the landing check: its decision section is among those that block
# nothing, its Tickets go under 要你做的 and count like a `ready-for-human`
# Ticket wherever a step keeps the Spec open for a human.
has 'a Ticket under `# decision` is no execution Ticket while it is there: it carries no `ready-for-agent` label, so nothing is dispatched for it and it is in no `# report` line' \
  'SKILL.md step 9 passes the check without counting a Ticket under # decision' "$SKILL"
has 'The other five sections block nothing: a Ticket under `# waiting` waits for another Spec, a standalone issue, or a human' \
  'SKILL.md step 9 counts the decision section among those that block nothing' "$SKILL"
without 'The other four sections block nothing' 'SKILL.md step 9 no longer names four sections that block nothing' "$SKILL"
has "A Ticket blocked by one under \`# decision\` reports \`等人工\` as well — the same form, since it waits for that Ticket's triage" \
  'SKILL.md step 9 reports a Ticket behind one under # decision as waiting for a human' "$SKILL"
has 'the lines of `# decision` go in the report the same way, each under 要你做的' \
  'SKILL.md step 9 sends a Ticket under # decision to 要你做的' "$SKILL"
has 'it waits for a human the way a `ready-for-human` Ticket does, so every step that keeps the Spec open for a human Ticket (step 7, step 9.5, step 10) keeps it open for this one too' \
  'SKILL.md step 9 keeps the Spec open for a Ticket under # decision as for a human Ticket' "$SKILL"
# Exit 1 is retried, exit 3 is not: a Spec missing from the graph does not come
# back by waiting, and a keeper that resumed the Run would only find it missing.
has '- `1` (a query failed): step 1'"'"'s failure rule — wait 30 seconds and run it once more; if it fails again, park with category `transient`.' \
  'SKILL.md step 9 keeps the retry for a failed query' "$SKILL"
without '`1` (a query failed, or the graph has no such Spec)' \
  'SKILL.md step 9 no longer folds a missing Spec into the retried exit' "$SKILL"
has '- `3` (the graph has no such Spec: its issue is gone, or no longer carries the `## Problem Statement` heading)' \
  'SKILL.md step 9 has a line of its own for a Spec missing from the graph' "$SKILL"
has 'so run the check no second time and write no `transient`' \
  'SKILL.md step 9 runs the check no second time on exit 3' "$SKILL"
has 'Park with category `error` at once, the parking report' \
  'SKILL.md step 9 parks on exit 3 at once, with category error' "$SKILL"
# The frontier lists the same Tickets under the same heading; step 0 rule 3
# releases a Spec whose Tickets all wait for triage instead of landing it with
# nothing done; and the failure rule of step 1, where frontier.sh is run, keeps
# the two exits apart the same way.
has '`# decision` lists the tickets that carry no `ready-for-agent` label (never dispatch those either' \
  'SKILL.md step 1 names the decision section of the frontier' "$SKILL"
has 'a frontier that is empty while `# source` or `# decision` names a ticket is step 0'"'"'s rule 3' \
  'SKILL.md step 1 sends an empty frontier with a Ticket under # decision to rule 3' "$SKILL"
has 'The same for a Spec whose frontier is empty while `# decision` names a Ticket' \
  'SKILL.md step 0 rule 3 releases a Spec whose Tickets all wait for triage' "$SKILL"
has "Exit \`3\` alone is not retried: the graph has no such Spec, which waiting does not change — park with category \`error\` at once, as step 9's \`3\` line says" \
  'SKILL.md step 1 does not retry a missing Spec either' "$SKILL"

# The reports take the check's lines, in all four forms of what a Ticket waits
# for (审查 r3, 判断项 2: the fourth, 等搁置, was in the script's header and in
# MAINTAINING alone): the parking report's 现状 pastes # open and # report, and
# the landing report and the final report's 细节 carry the `剩余：` lines
# whatever the Ticket waits for, after a partial landing and after a parking
# alike. The final 结论 block stays at one line per item (审查 r3, 取舍 1 选 B):
# its 结果 line counts what is left, and a Ticket merged and left open — the
# one kind a person can act on — stays on the first screen, by its number,
# under 要你做的.
has '<when the Run parks on the landing check (step 9): every line of its `# open` and `# report` sections, as they are>' \
  'the parking report carries the lines of the landing check' "$SKILL"
has 'the `# report` lines of the landing check, as they are (`剩余：#<t> 等 #<spec>`, `剩余：#<t> 等 #<issue>`, `剩余：#<t> 等人工 #<t>` or `剩余：#<t> 等搁置 #<t>`, one line each; omit when it printed none)' \
  'the landing report carries the lines of the landing check, in all four forms' "$SKILL"
has 'Then a `## 结论` block of at most 5 lines, one per item' \
  'the final report keeps its 结论 block to one line per item' "$SKILL"
has "when the landing check's \`# report\` names Tickets, the line ends with \`剩余 N 张\`" \
  'the final report counts what is left on its 结果 line' "$SKILL"
has 'a Ticket that merged without being closed and is still open is one of them, named one by one (`#<t>`, close it) and never only counted' \
  'the final report names a Ticket merged and left open under 要你做的, one by one' "$SKILL"
has 'The `剩余：` lines themselves are never lines of this block' \
  'the final report keeps the report lines out of its 结论 block' "$SKILL"
has "under \`## 细节\`, the technical part below, which starts with the landing check's \`# report\` lines, as they are" \
  'the final report opens 细节 with the lines of the landing check' "$SKILL"
has "- **What is left**: the landing check's \`# report\` lines, as they are" \
  'the final report lists what is left under 细节' "$SKILL"
without "then the landing check's \`# report\` lines whenever a Ticket is still open" \
  'the final report no longer puts the report lines into its 结论 block' "$SKILL"
without 'partially landed with `剩余：#<t> 等 #<spec>`' \
  'the final report no longer names one form for what is left' "$SKILL"

# The vocabulary and the operating rules follow.
has '**Loose source ticket**:' 'GLOSSARY defines Loose source ticket' "$GLOSSARY"
has 'every Run does that without asking, `--auto-land` or not (2026-11-28, 票 #78)' \
  'GLOSSARY excludes the merger closing a merged Ticket from Unattended landing' "$GLOSSARY"
# A partial landing's lines are the script's four forms, here as in SKILL.md:
# the glossary is the vocabulary, so it may not list three of them.
has '`剩余：#<t> 等 #<spec>` for another Spec, `剩余：#<t> 等 #<issue>` for a standalone issue, `剩余：#<t> 等人工 #<t>` behind a human ticket, `剩余：#<t> 等搁置 #<t>` behind a shelved one' \
  'GLOSSARY lists all four forms of what is left after a partial landing' "$GLOSSARY"
without 'behind a human ticket.' \
  'GLOSSARY no longer ends the forms of a partial landing at the human Ticket' "$GLOSSARY"
has 'closing an execution Ticket as it merges (2026-11-28, 票 #78; allowed by the owner)' \
  'ai-agents guide states the exception for closing a merged Ticket' "$ROOT/docs/ai-agents.md"

# --- SKILL.md: the three reports carry the route table and the check lines (票 #47)

# The landing report: completion-report.sh with the run directory ends with
# what stage-dispatch.sh verify prints.
has 'completion-report.sh <主 checkout> --spec <n> --notify --run-dir <Spec Run root>' \
  'SKILL.md runs completion-report.sh with the run directory' "$SKILL"
has 'stage-dispatch.sh verify --run-dir <Spec Run root>' 'SKILL.md names the verify command for the reports' "$SKILL"
# The parking report's 现状 and the final report's 细节 paste that output instead
# of the two route lines of the old switches.
without '<the two route lines of "Report at the end">' 'the parking report no longer asks for the two route lines' "$SKILL"
without '**Route**, two lines written every time' 'the final report no longer asks for the two route lines' "$SKILL"
without 'names it in `projection.provider`' 'the session no longer reads the model off worker-show by hand' "$SKILL"
# What stays: the two machine-readable lines and the section keeper and the
# supervisor read.
has '停车类别：error' 'the parking report keeps its category line' "$SKILL"
has '可恢复时间：无' 'the parking report keeps its recovery-time line' "$SKILL"
has '### 需要你决定' 'the parking report keeps its decision section' "$SKILL"
has '### 现状' 'the parking report keeps its status section' "$SKILL"
# A mismatch is a warning that holds nothing back.
has 'never held back' 'SKILL.md says a model mismatch never holds back the landing' "$SKILL"

# --- a partial landing also covers tickets left to a human (票 #60, 规格 #58) ----

# A ready-for-human ticket is never dispatched (MAINTAINING 第 36 条), so a Spec
# whose open tickets are only those lands as a partial landing: the Spec stays
# open, nothing parks, and the report names them. The exception is stated once
# and echoed at each step that decides on it; each site is pinned so none can
# fall back to the Spec-only wording on its own.
has 'or may be `ready-for-human` tickets, which are never dispatched' \
  'SKILL.md: a partial landing also covers ready-for-human tickets' "$SKILL"
has 'which wait for a human (`等人工票 #<t>`)' 'SKILL.md: the final report names the tickets left to a human' "$SKILL"
has '(except those waiting for another Spec or a `ready-for-human` ticket, see "Tickets blocked by another Spec")' \
  'SKILL.md step 7 excepts the tickets left to a human' "$SKILL"
has 'When tickets still wait for another Spec or for a human, land what is done but keep the Spec' \
  'SKILL.md step 9 keeps the Spec open for the tickets left to a human' "$SKILL"
has 'unless tickets still wait for another Spec or for a human (a partial landing also runs this substep)' \
  'SKILL.md step 9.5 excepts the tickets left to a human' "$SKILL"
has '`waiting` when the Spec stays open with tickets waiting for another Spec or for a human' \
  'SKILL.md step 10 marks waiting for the tickets left to a human' "$SKILL"
has '**Partial landing** (the Spec stays open only because tickets wait for another Spec or for a human)' \
  'SKILL.md step 10 defines a partial landing for the tickets left to a human' "$SKILL"
has 'while the rest wait for another Spec or are `ready-for-human` tickets' \
  'GLOSSARY: partial landing covers ready-for-human tickets' "$GLOSSARY"
# The form of that line is the landing check's (票 #78, which landed on main
# first): its `# report` lines say 等人工 #<t> behind a human ticket, and the
# entry lists all four forms, so the pin names the form the script prints.
has '`剩余：#<t> 等人工 #<t>` behind a human ticket' 'GLOSSARY: the landing report names the tickets left to a human' "$GLOSSARY"

# --- Brief hygiene (票 #60, 规格 #58; MAINTAINING 第 22 条) -----------------------

# The sentence find-next/SKILL.md's 推进模式导言 carries, now in the rule that
# writes a Brief: no vague path to a file outside the repo, and the templates'
# 环境约束 section is the worker-side half of it.
has '**Brief 卫生**：往 Brief 里引用仓库外的文件' 'SKILL.md: Brief hygiene before naming a file outside the repo' "$SKILL"
has '「环境约束（找文件与子进程）」一节是 worker 侧的对应约束' 'SKILL.md: the templates 环境约束 section is the worker-side rule' "$SKILL"

# --- the spec session parks only when it truly cannot go on (票 #70, 规格 #58) ---

# Step 8: an item under 需要人取舍 is decided, never parked on. A usable
# recommendation is applied; 可自动采纳：否 and 推荐：无 take the reversibility
# rule, a recommendation that is reversible and not outward-facing first; only
# an item that needs the owner's identity, credentials or physical action (auth)
# or lists no reversible option (error) parks; an option that loosens a safety
# boundary is recorded under 未执行的放宽项 and never taken. The two marks stay
# the reviewer's wording, so the pins name the outcomes, not the marks.
has 'never parks the Run for being a trade-off' 'SKILL.md step 8 never parks on a trade-off' "$SKILL"
has 'pick a reversible option by 「可逆性高 > 改动面小 > 与现有 ADR 一致」' \
  'SKILL.md step 8 decides an item without a usable recommendation by the reversibility rule' "$SKILL"
has 'preferring the reviewer' 'SKILL.md step 8 prefers a recommendation that is reversible and not outward-facing' "$SKILL"
has 'an action that needs the owner'\''s identity, credentials or physical action (a first login, a payment, a verification code) parks with category `auth`' \
  'SKILL.md step 8 parks an item that needs the owner identity, credentials or physical action as auth' "$SKILL"
has 'never invent an option' 'SKILL.md step 8 parks an item with no reversible option instead of inventing one' "$SKILL"
# The loosening bullet of step 8 is pinned as its whole sentence: the string
# 「未执行的放宽项」 alone appears on five lines of SKILL.md (eight times), so a
# pin on it alone stayed green with this bullet gone (规格 #58 复审 Standards
# 判断项 8).
has 'An option that loosens a safety boundary is never taken, whatever the rule above would pick: record it under 「未执行的放宽项」 in the landing report and decide among the remaining options as above.' \
  'SKILL.md records a loosening option as not executed' "$SKILL"
without 'Park only for an item that is marked `可自动采纳：否`' 'SKILL.md step 8 no longer parks on 可自动采纳：否' "$SKILL"
# The category table is down to quota / transient / auth / error, the same four
# in the machine-readable line, the table and the keeper bullet; auth covers an
# action that needs the owner's identity, credentials or physical action (r3:
# an item whose options all need the owner's hands parks as auth); the two
# cases that had no category now have one (the landing lock after 2 hours →
# transient, opus-review exits other than 2 / 3 / 4 → error), and every
# non-zero opus-review exit names its category (test-opus-review.sh pins the
# whole sentence in SKILL.md and in find-next/SKILL.md alike).
has '停车类别：quota|transient|auth|error' 'the parking category line names the four categories left' "$SKILL"
without '停车类别：quota|transient|decision|error|other' 'the parking category line no longer names decision or other' "$SKILL"
has '| `auth` | 需要本人身份、凭据或物理动作的操作：首次登录授权、付款、验证码；真机插拔这类只有本人动手才做得出的物理动作 | `无` |' \
  'the parking category table has the auth row' "$SKILL"
without '需要本人身份或凭据的操作' 'the auth row no longer leaves out a physical action' "$SKILL"
has '三轮审查后仍有正确性问题、护栏违反' 'the error row names a correctness problem left after three rounds and a guardrail violation' "$SKILL"
has '`opus-review.sh` 非 0 退出且不是 2 / 3 / 4' 'the error row names the opus-review exits' "$SKILL"
has '`auth` and `error` still need a human' 'keeper resumes only quota and transient' "$SKILL"
without '`decision`, `error` and `other` still need a human' 'the keeper sentence no longer names decision or other' "$SKILL"
has '- `auth` / `error` parks are only notified, once per report' 'the keeper section lists auth among the notified-only parks' "$SKILL"
has 'after 2 hours, park with category `transient`' 'the landing lock wait parks as transient' "$SKILL"
OPUS_REVIEW_EXIT_SENTENCE='退出码为 3（额度或 429）时按 quota 停车，2（认证失败）按 auth 停车，4 按 transient 停车，其余非 0 退出码按 error 停车并说明'
has "$OPUS_REVIEW_EXIT_SENTENCE" 'SKILL.md names the category of every non-zero opus-review exit' "$SKILL"
# Flash mode: the flash session still picks nothing itself; an item without a
# usable mark goes to one more Opus review instead of parking the Run.
without 'parks the Run, and its parking report' 'flash Stopping no longer parks on 可自动采纳：否' "$SKILL"
has 'only an item that review marks as needing the owner' 'flash Stopping parks only what the Opus review marks as auth' "$SKILL"
# 规格 #58 review fix r3 (trade-off 2 = A): auth covers a physical action, and
# Flash mode's Stopping picks no option that needs the owner's own hands — the
# second fix had written that exclusion into Unattended landing only, so under
# flash an option the Run could not carry out could still be picked.
has 'only an item that review marks as needing the owner'\''s identity, credentials or physical action parks, with category `auth`' \
  'flash Stopping parks what needs identity, credentials or physical action as auth' "$SKILL"
has 'an option that needs the owner'\''s own hands (a physical action the Run cannot carry out) is not picked here either, whatever that review recommends' \
  'flash Stopping picks no option that needs the owner'\''s own hands' "$SKILL"
# The hooks' reasons and the hooks README say the same (MAINTAINING 第 39 条).
has '`可自动采纳：否` 或 `推荐：无` 的按可逆性规则自选一个可逆选项并写理由' 'hooks README rule B names the reversibility rule' "$HOOKS"
has '（停车类别 `auth`）、或列出的选项里没有可逆的（停车类别 `error`）' 'hooks README rule B names the two categories that still park' "$HOOKS"
# r3: rule B says what parks as auth with the category table's wording; the
# hooks' own reason sentences are pinned by their two test files.
has '只有需要本人身份、凭据或物理动作（停车类别 `auth`）、或列出的选项里没有可逆的（停车类别 `error`）' \
  'hooks README rule B names identity, credentials or physical action as what parks as auth' "$HOOKS"
has '(`auth`: an operation that needs the owner'\''s identity, credentials or physical action;' \
  'GLOSSARY: the Parking report entry defines auth with a physical action' "$GLOSSARY"

# --- find-next 推进模式：the question round became a decision round (票 #69, 规格 #58) ---

# Step 6 no longer asks: each item is decided by the worker's recommendation, a
# missing one by the reversibility rule, and the two kinds of item left to the
# human (a personal identity, credential or physical action; a subjective
# reaction) go to the wrap-up's 要你做. The message is a report with a reversal
# recipe, the reply prompt is gone, and the three-round cap — a protection for
# the human being asked — went with it. The user's own entries (都同意 / 展开 /
# 先到这) stay.
has '6. **一轮拍板（自动、可推翻；没有要拍的就跳过）**' 'find-next step 6 is a decision round' "$FIND_NEXT"
has '**每条按 worker 给出的推荐答案自动采纳，不等用户回答**' 'find-next step 6 adopts each recommendation without waiting' "$FIND_NEXT"
has '按「可逆性高 > 改动面小 > 与现有 ADR 一致」自选一个' 'find-next step 6 settles a missing recommendation by reversibility' "$FIND_NEXT"
has '**要本人身份、凭据或物理动作**（task 票 `## 需要本人做的`），做不了；**要主观反应**（prototype 的反应题），agent 替不了' \
  'find-next step 6 names the two reasons for not deciding' "$FIND_NEXT"
has '列出的选项里没有可逆的，那一条不拍板' 'find-next step 6 invents no option when none is reversible' "$FIND_NEXT"
has '`可自动采纳：是` 且有推荐的按推荐；`可自动采纳：否` 或 `推荐：无` 的按上面的可逆性规则自选' \
  'find-next step 6 routes draft-review items the way the Spec session does' "$FIND_NEXT"
has '推进器 · <仓库名> · 已自动拍板 <N> 条（可推翻）' 'find-next step 6 titles the message as decisions taken' "$FIND_NEXT"
has '要推翻就回「推翻 #<票号> <条目> 改选 <X>」' 'find-next step 6 ends with the reversal recipe' "$FIND_NEXT"
has '用户没说就不等' 'find-next step 6 does not wait for a reply' "$FIND_NEXT"
has '对某条回「展开」时，当前会话就地对那张票调用 grilling 和 domain-modeling 技能' 'find-next step 6 keeps 展开 as the in-place grilling entry' "$FIND_NEXT"
has '回「先到这」时按第 7 步立即收尾' 'find-next step 6 keeps 先到这 as the early hand-off' "$FIND_NEXT"
has '拍完不等回复，直接做第 7 步' 'find-next step 6 goes straight on to the write-back' "$FIND_NEXT"
without '单次运行累计最多问用户 3 轮' 'find-next step 6 no longer caps the rounds' "$FIND_NEXT"
without '请回复「都同意」' 'find-next step 6 no longer asks for a reply' "$FIND_NEXT"
without '需要拍板 <N> 条' 'find-next step 6 no longer titles the message as questions' "$FIND_NEXT"
without '有问题就一轮问用户' 'find-next usage no longer describes a question round' "$FIND_NEXT"
without '并入本轮最后一个问题问用户' 'find-next usage no longer asks for the worker cap' "$FIND_NEXT"

# Step 7 writes the decisions back the way a human's answers used to be written,
# marked as an auto-decision; stale and orphan claims are released on the
# recommendation, a loose ticket's map is built on the draft, and the 再想想
# branch is gone. Step 8's re-scan decides new items the same way, with no cap.
has '7. **应用拍板、迷雾毕业与散票分流**' 'find-next step 7 applies the decisions' "$FIND_NEXT"
has '出处标「（推进器自动拍板 <日期>，可推翻）」' 'find-next step 7 marks the write-back as an auto-decision' "$FIND_NEXT"
has '`staleClaims`、`orphanClaims` 按推荐自动取消认领' 'find-next step 7 releases stale and orphan claims on the recommendation' "$FIND_NEXT"
has '散票分流「该开地图」按草案自动拍板后' 'find-next step 7 builds a loose ticket map on the draft' "$FIND_NEXT"
has '没有可逆选项、没拍板的组不发布' 'find-next step 7 does not publish a group with no reversible option' "$FIND_NEXT"
has '`unresolved` 已在拍板轮处理并写回的组随后发布' 'find-next step 9 publishes a group after its decisions are written back' "$FIND_NEXT"
has '脚本按第 6 步拍板的全机 worker 上限传入' 'find-next step 10 passes the decided worker cap' "$FIND_NEXT"
without '只有用户同意才取消认领' 'find-next step 7 no longer waits for consent to release a claim' "$FIND_NEXT"
without '（owner <日期> 推进器确认）' 'find-next step 7 no longer cites a human confirmation' "$FIND_NEXT"
without '再想想' 'find-next no longer has the 再想想 branch' "$FIND_NEXT"
without '并继续遵守单次 3 轮上限' 'find-next step 8 no longer names the three-round cap' "$FIND_NEXT"

# Steps 3 and 4: a decision ticket with a recommendation goes to the round instead
# of waiting for the human. A task ticket's human-checklist.md is read by its two
# #68 sections: 需要本人做的 is left to the human, 运维步骤 is find-next's first
# writable dispatch and follows the Ops tickets codex backend — no --read-only,
# --mcp ssh-manager for a remote server, the guardrails copied verbatim, only the
# Brief's scope, the result written back to the task ticket's Resolution. A
# prototype's reaction is not decided. A loosening ticket is triaged as a single
# decision whose outcome is never the loosening itself. (2026-11-28, the second
# review fix of 规格 #58: that dispatch follows codex-worker.sh's own writable
# form, since the root SKILL.md's Ops tickets section names no codex backend any
# more — 规格 #26 left only the dispatch module's --mcp-config there — and the
# worker it starts is a worker, not an "implementer": GLOSSARY's implementing
# roles are Orca workers only. Same wording in brief-task.md.)
has '3. **决策、迷雾、task 与 prototype 票（worker 准备，一轮拍板）**' 'find-next step 3 feeds the decision round' "$FIND_NEXT"
has '决策题带推荐就进第 6 步拍板轮：按推荐写 Resolution 评论、关票、更新地图，标「自动拍板（可推翻）」' \
  'find-next step 3 sends a decision ticket with a recommendation to the round' "$FIND_NEXT"
has '我按它的固定两节读：`## 需要本人做的`' 'find-next step 3 reads the human-only section by name' "$FIND_NEXT"
has '`## 运维步骤（带护栏，主会话派实现者执行）`（每步含执行方式' 'find-next step 3 reads the ops-steps section by name' "$FIND_NEXT"
has '**运维步骤的非只读派发**（find-next 的第一种非只读派发' 'find-next step 3 names the ops dispatch as its first writable one' "$FIND_NEXT"
has '沿用 `codex-worker.sh` 的写法' 'find-next step 3 follows the codex-worker.sh convention' "$FIND_NEXT"
has '--run-dir <运行目录>/task-<票号>/ops --time-limit 2400 --idle-timeout 600' 'find-next step 3 dispatches the ops worker without --read-only' "$FIND_NEXT"
has '的步骤必传 `--mcp ssh-manager`' 'find-next step 3 passes ssh-manager MCP for remote steps' "$FIND_NEXT"
has '以及**原文照抄**的护栏，只允许改 Brief 写明的范围' 'find-next step 3 copies the guardrails verbatim into the Brief' "$FIND_NEXT"
has '实现者要越出护栏或验收达不到时只报告、不硬推' 'find-next step 3 keeps the ops worker inside the guardrails' "$FIND_NEXT"
has '该步标了放宽项的不执行、只记录（写进该 task 票的 Resolution 与收尾的「未执行的放宽项」），不替用户决定放宽' \
  'find-next step 3 records a loosening item instead of loosening' "$FIND_NEXT"
has 'prototype 的反应题要的是用户的主观反应，agent 替不了：不拍板' 'find-next step 3 does not decide a prototype reaction' "$FIND_NEXT"
has '决策题带推荐就进拍板轮，没有推荐或推荐不明确的按第 6 步的可逆性规则自选' \
  'find-next step 4 sends a loose ticket decision to the round' "$FIND_NEXT"
has '同样分流为「单个决策」进拍板轮，结论不得是直接放宽，最多是「改写方案避免放宽」' \
  'find-next step 4 routes a loosening ticket as a single decision' "$FIND_NEXT"
without 'worker 准备，一轮问用户' 'find-next step 3 no longer names a question round' "$FIND_NEXT"
without '决策题仍是 HITL' 'find-next step 4 no longer holds a decision for the user' "$FIND_NEXT"
without 'grilling 是 HITL' 'find-next step 3 no longer holds grilling for the user' "$FIND_NEXT"
without '人工清单放进第 6 步那一轮' 'find-next step 3 no longer puts the human list in a question round' "$FIND_NEXT"
without '其他三类仍按第 6 步问用户后处理' 'find-next step 4 no longer asks about the other three classes' "$FIND_NEXT"

# The wrap-up lists every auto-decision of the round with its reversal recipe and
# the items left to the human; the supervisor decides a parked Spec's recommended
# items itself (a 拍板 comment marked 总控自动拍板, then --only) for every park but
# one kind, asks only for auth, and ALL_DONE lists every auto-decision of the
# supervision. The error handling no longer asks the user to choose between
# waiting and stopping, and no longer names the three-round cap.
has '完成度结论之下列「**本轮自动拍板**」' 'find-next step 11 lists the round auto-decisions' "$FIND_NEXT"
has '逐条带推翻回法「推翻 #<票号> <条目> 改选 <X>」' 'find-next step 11 gives each auto-decision its reversal recipe' "$FIND_NEXT"
has '再列「**要你做**」：没拍板的本人事项' 'find-next step 11 lists the undecided human items' "$FIND_NEXT"
has '「<条目>：选 <X>（总控自动拍板 <日期>，可推翻）」' 'the supervisor writes its own 拍板 comment for recommended items' "$FIND_NEXT"

# --- the supervisor leaves an error park alone (规格 #58 审查做错 4，取舍 1 选 A) ---

# The category table says a human must act first on auth and error; the
# supervisor's rule did not limit itself by category, so an error park that
# carried recommendations (three review rounds, a guardrail violation) was
# decided and resumed, and the three-round cap became park → decide → resume →
# re-review → park again. An error park is now relayed item by item and never
# resumed by the supervisor; the quota / transient parks and the legacy reports
# (a retired category, or no category line) keep the rule; auth stays the only
# category asked of the user. The old sentence read as if auth were the only
# park that reached the user at all.
has '停车类别是 `error` 的不由总控拍板，带推荐也不拍' 'the supervisor never decides an error park' "$FIND_NEXT"
has '只汇报，不写 `## 拍板`、不运行 `--only`' 'the supervisor relays an error park without a 拍板 comment or a resume' "$FIND_NEXT"
has '`quota` / `transient` 和旧格式报告（类别行写的是已退役的 `decision` / `other`，或没有类别行）' \
  'the supervisor still decides quota, transient and legacy parks' "$FIND_NEXT"
has '问用户的只有停车类别 `auth`' 'the supervisor asks the user only for auth' "$FIND_NEXT"
without '只有条目需要本人身份或凭据（停车类别 `auth`）才问用户' \
  'the supervisor rule no longer reads as if auth were the only park left to the user' "$FIND_NEXT"
has '`error` 停车的待决条目' 'the SUMMARY line counts an error park among the human to-dos' "$FIND_NEXT"
has '`auth` 停车和 `error` 停车的规格' 'ALL_DONE still lists the error-parked Specs' "$FIND_NEXT"
has 'An `error` park is never decided or restarted by the supervisor' \
  'SKILL.md: parking hands an error park to the user, not to the supervisor' "$SKILL"
has 'it never decides or resumes an `error` park' 'GLOSSARY: the Parking report entry keeps the supervisor off error parks' "$GLOSSARY"
has 'never for a parking category of `error`' 'GLOSSARY: the Supervisor entry keeps off error parks' "$GLOSSARY"
has '已自动拍板 w · 要你做 v' 'the SUMMARY line counts auto-decisions and human to-dos' "$FIND_NEXT"
has '集中列出本次总控期间的全部自动拍板' 'ALL_DONE lists every auto-decision of the supervision' "$FIND_NEXT"
has '或拍的是决策票、地图条目（迷雾毕业、散票建地图）和散票分流时' 'the reversal recipe reaches decision tickets, map entries and loose tickets' "$FIND_NEXT"
without '待你拍板 w' 'the SUMMARY line no longer counts items waiting for the user' "$FIND_NEXT"
without '按推进模式第 6 步的问题轮格式问用户' 'the supervisor no longer asks the parked items' "$FIND_NEXT"
without '因 3 轮问询上限' 'the wrap-up no longer names the three-round cap' "$FIND_NEXT"
without '已问满 3 轮' 'the error handling no longer names the three-round cap' "$FIND_NEXT"
without '问是等还是停止' 'the error handling no longer asks the user to choose' "$FIND_NEXT"

# In a flash session the reversibility choice is a judgement, so the items without
# a recommendation go to one more Opus review and flash copies the result; a
# 推荐 stays 推荐无 as written. The exit-code sentence and the three worker
# backend sentences above are unchanged (test-opus-review.sh pins the former).
has 'flash 不自己选' 'flash mode does not choose itself' "$FIND_NEXT"
has '再交给**一次** Opus review' 'flash mode hands the reversibility choice to one more Opus review' "$FIND_NEXT"
has '拍板轮与「展开」' 'flash mode names the decision round' "$FIND_NEXT"
without '本步只直接转述选择题' 'flash mode no longer describes step 6 as relaying questions' "$FIND_NEXT"

# --- no decision point of find-next picks a loosening option (规格 #58 审查做错 3) ---

# The root SKILL.md's step 8 never takes an option that loosens a safety
# boundary (the pins under 票 #70 above); find-next's three decision points did
# not say so. So an item the draft review had marked 可自动采纳：否 went to the
# reversibility choice with "loosen the guardrail" as its smallest option, and a
# worker's recommendation to loosen was adopted as it stood. Each of the three
# carries the rule now: such an option is never picked, recommendation or not,
# and an item that offers nothing else is not decided — it goes to 要你做 and is
# recorded under 未执行的放宽项. The three sites are pinned one by one and the
# rule's wording is counted, so no site can lose it on its own.
LOOSENING_RULE='放宽安全边界的选项一律不选，推荐是它的也不采纳'
has '时优先用它。放宽安全边界的选项一律不选，推荐是它的也不采纳；除它之外没有可选项的条目不拍板、列入「要你做」并记进「未执行的放宽项」' \
  'find-next step 6 picks no loosening option' "$FIND_NEXT"
# r3 (trade-off 2 = A): the input also rules out an option that needs the
# owner's hands, so an item whose options are all hands-on ends as 推荐无 (not
# decided, listed for the user) instead of being picked for the Run.
has '要本人身份或凭据的不选；需要本人动手（物理动作）的选项不选；放宽安全边界的选项一律不选，推荐是它的也不采纳；除它们之外没有可选项的写『推荐：无』' \
  'flash mode writes the rule into the input of the selecting Opus review, hands-on options included' "$FIND_NEXT"
has '口径同第 6 步，放宽安全边界的选项 flash 也不选' 'flash mode adopts no loosening recommendation either' "$FIND_NEXT"
has '这条不拍板，列为「要你做」。放宽安全边界的选项一律不选，推荐是它的也不采纳；除它之外没有可选项的条目不拍板' \
  'the supervisor picks no loosening option' "$FIND_NEXT"
count_at_least "$LOOSENING_RULE" 3 'the rule stands at all three decision points of find-next' "$FIND_NEXT"
has '和拍板轮里因选项全是放宽安全边界而没拍板的条目，单列「未执行的放宽项」' \
  'find-next step 11 records the refused loosenings of the round' "$FIND_NEXT"
has '因选项全是放宽安全边界而没拍板的条目另列「未执行的放宽项」' \
  'ALL_DONE records the refused loosenings of the supervision' "$FIND_NEXT"
has 'no decision round ever picks such an option' 'GLOSSARY: the Loosening entry covers every decision round' "$GLOSSARY"
has "not find-next's decision round or its Supervisor" 'GLOSSARY: the Loosening entry names find-next and the Supervisor' "$GLOSSARY"

# --- step 9's local install is for this skill's own repository only (规格 #58
# 审查 Spec 越界 2，取舍 2 选 A) ---

# The spec's 落地流程接入 names the install.sh it adds: the one that keeps this
# skill's links and configuration in step with what landed. The condition read
# "the repository root has an install.sh", so a Spec on any other repository ran
# that repository's own installer after every landing, unconfirmed in an
# unattended one. Only this skill's own repository is installed now; another
# repository's install.sh is never run and the section is omitted.
has "For a Spec on this skill's own repository only" "SKILL.md: the local install is for this skill's own repository only" "$SKILL"
has 'A Spec on any other repository never gets an `install.sh` run here, whatever script its root may hold' \
  "SKILL.md: no other repository's install.sh is run at landing" "$SKILL"
without 'A repository without `install.sh` has nothing to install: skip this and omit the section' \
  'SKILL.md: the install is no longer conditioned on the repository root having an install.sh' "$SKILL"
has '「下次落地会补上」; omit for a Spec on any other repository)' \
  'SKILL.md: the landing report omits the install section for another repository' "$SKILL"
has "Omit for a Spec on any other repository: step 9 installs this skill's own repository only." \
  'SKILL.md: the final report omits the install section for another repository' "$SKILL"

# --- the user documents no longer describe the decision round as a question round
# (规格 #58 审查 Standards 硬违规 1) ---

# find-next's step 6 became a decision round (票 #69, MAINTAINING 第 59 条): the
# combined message reports what was decided, gives the reversal recipe and waits
# for nobody, and the three-round cap is gone. The user documents and the Brief
# templates still described the old question round there — "reply 都同意", "you
# confirm once, then they are published", a draft "to be confirmed by the user" —
# and GLOSSARY's Advance mode lists question round under _Avoid_. Each old
# sentence is gone and its replacement is pinned, document by document.
without 'At most three rounds per run' 'README no longer caps the decision rounds' "$ROOT/README.md"
without 'reply "都同意"' 'README no longer asks the user to answer the combined message' "$ROOT/README.md"
has 'One combined decision round' 'README calls the combined round a decision round' "$ROOT/README.md"
has 'It is a report, not a question: nothing waits for a reply' 'README says the combined message waits for nobody' "$ROOT/README.md"
has '推翻 #<n> <条目> 改选 <X>' 'README gives the reversal recipe' "$ROOT/README.md"
without '你确认一轮后统一发布' 'docs/setup.md no longer has the user confirm the drafts' "$ROOT/docs/setup.md"
without '你确认后它在 Orca 里自动开 worktree' 'docs/setup.md no longer has the user confirm the launch' "$ROOT/docs/setup.md"
has '审稿后每个待定条目按 worker 的推荐自动拍板（可推翻，不等回答）再统一发布' \
  'docs/setup.md says the drafts are decided by recommendation and published' "$ROOT/docs/setup.md"
has '要改某条拍板就回「推翻 #<n> <条目> 改选 <X>」' 'docs/setup.md gives the reversal recipe' "$ROOT/docs/setup.md"
without 'you confirm once' 'docs/setup.en.md no longer has the user confirm the drafts' "$ROOT/docs/setup.en.md"
has "each open item is decided by the worker's recommendation (auto-decided, 可推翻" \
  'docs/setup.en.md says the drafts are decided by recommendation' "$ROOT/docs/setup.en.md"
without 'ask the user once' 'docs/ai-agents.md no longer asks the user about the drafts' "$ROOT/docs/ai-agents.md"
without 'only after their confirmation publish' 'docs/ai-agents.md no longer publishes after a confirmation' "$ROOT/docs/ai-agents.md"
has "decide every open item by the worker's recommendation (auto-decided, 可推翻" \
  'docs/ai-agents.md says the drafts are decided by recommendation' "$ROOT/docs/ai-agents.md"
FOG=$ROOT/find-next/templates/brief-fog.md
without '合成到一轮里问用户' 'brief-fog no longer has the fog proposal asked of the user' "$FOG"
without '用户同意后才由主会话建票' 'brief-fog no longer waits for the user before the map changes' "$FOG"
has '合成一轮按推荐自动拍板（可推翻）；拍板后才由主会话建票、接线、改地图' \
  'brief-fog says the fog proposal is decided by recommendation' "$FOG"
# The three drafting templates: the caller decides the open items after the
# review instead of asking, and the seams field is review material, not
# something put to the user.
for template in brief-spec-batch brief-map-spec-batch brief-tickets-batch; do
  file=$ROOT/find-next/templates/$template.md
  [ -f "$file" ] || { bad "$template exists" "$file"; continue; }
  without '由调用方审稿、问用户、再用脚本发布' "$template: the caller no longer asks the user" "$file"
  has '由调用方审稿、按推荐自动拍板（可推翻）、再用脚本发布' "$template: the caller decides by recommendation" "$file"
  without '由调用方统一问' "$template: the open items are no longer put to the user" "$file"
  has '由调用方合成一轮按推荐自动拍板（可推翻）' "$template: the open items are decided in one round" "$file"
  without '给用户确认用' "$template: seams are no longer for the user to confirm" "$file"
  has '给调用方审稿用' "$template: seams are review material" "$file"
  # 规格 #58 复审 Spec 3: ready-for-human is for identity, credentials or a
  # physical action only — not for "what an external worker cannot do", the
  # criterion 规格 #58 retires; each guardrail sample pointer names its sample,
  # and the templates carry the local (and smoke) sample next to the ssh one.
  without '不能交给外部实现 worker（codex 等）的票' \
    "$template: ready-for-human is not justified by what an external worker cannot do" "$file"
  has '需要本人身份 / 凭据 / 物理动作的票（正文写了「本票由 Opus 执行」的）在该票写 `"labels": ["ready-for-human"]`' \
    "$template: ready-for-human is for identity, credentials or a physical action" "$file"
  without '带一节 `## 护栏`（样例见下）' \
    "$template: a guardrail sample pointer no longer points at the ssh sample alone" "$file"
  has '带一节 `## 护栏`（本机版样例见下）' "$template: the local ops ticket points at the local guardrail sample" "$file"
  has '预期证据、护栏（本机版样例见下）' "$template: the smoke ticket points at the local guardrail sample" "$file"
  has '带一节 `## 护栏`（ssh 版样例见下）' "$template: the ssh ops ticket points at the ssh guardrail sample" "$file"
  has '- 只操作本机的 `<目录或文件>`（测试工作区 `~/orca/<测试仓库>`、`<临时状态文件>`），不碰其他仓库和本机配置' \
    "$template: carries the local guardrail sample" "$file"
done

# --- what doctor's hints say (规格 #58 审查 Standards 硬违规 3) ---

# Two different hints were described as one. Stage 3's own FAIL for a matcher
# without Bash gives the manual fix (test-doctor.sh pins the hint naming
# hooks/README.md and docs/setup.md); the foundation group's install-state row
# is the one that says to run install.sh, and whatever install.sh leaves to a
# person (a real directory, the Windows link step, a loosening) says so.
without 'matcher 缺 `Bash` 时在阶段 3 报 FAIL，提示运行 `install.sh`' \
  'hooks README no longer says the stage-3 FAIL hints at install.sh' "$HOOKS"
has '阶段 3 自己那条给手工改法' 'hooks README: the stage-3 FAIL gives the manual fix' "$HOOKS"
has '基础组「本机安装状态」那条（调 `install.sh --check --json` 得来）提示「运行 install.sh（落地时会自动运行）」' \
  'hooks README: the install-state row is the one that hints at install.sh' "$HOOKS"
without '提示都是「运行 install.sh（落地时会自动运行）」' \
  'docs/setup.md no longer says every hint is the install.sh one' "$ROOT/docs/setup.md"
has '阶段 3 自己的检查（如 matcher 缺 `Bash`）报 FAIL 时给的也是手工改法，不是「运行 install.sh」' \
  'docs/setup.md: stage 3 FAILs give the manual fix' "$ROOT/docs/setup.md"
without 'every hint says to run install.sh' \
  'docs/setup.en.md no longer says every hint says to run install.sh' "$ROOT/docs/setup.en.md"
has "Stage 3's own checks (a matcher without \`Bash\`, for example) fail with the manual fix" \
  'docs/setup.en.md: stage 3 FAILs give the manual fix' "$ROOT/docs/setup.en.md"
has "never for a Spec on another repository, whatever \`install.sh\` its root may hold" \
  "GLOSSARY: the Unattended landing entry keeps the install to this skill's own repository" "$GLOSSARY"

# --- the Ticket Brief template --------------------------------------------------

for text in 'worker_done' '--task-id' '## 护栏' '探索笔记' '规格内容' '票内容' \
  '不带规格会话的过程' '不写在工作区里' 'If a source-write hook blocks you' \
  'Run any `rm` as its own Bash command' 'mcp__ssh-manager__list_servers' \
  'templates/lean-rules.md' '调用关系' '--report-path'; do
  has "$text" "Brief template has [$text]" "$BRIEF_FIND_NEXT"
done
without '不要 `git commit`' 'Brief template requires the worker to commit' "$BRIEF_FIND_NEXT"

# --- tests finish in the foreground; an idle worker is verified, not waited for (票 #79)

# On 2026-11-28 two workers (spec-62 fix-r2, spec-26 merger-tmain) left their
# tests running in the background, wrote that they would report when those had
# finished, and ended their turn. Nothing wakes an idle worker: the report never
# came and each session waited. So the Brief templates say that tests and
# verification finish in the foreground before the final report, the dispatch
# texts of steps 5, 8 and 9.1 for the merge, re-bump and fix roles carry the
# same rule, and a main session that meets a worker gone idle without a report
# verifies it itself (ps, git) instead of waiting again. Each place is pinned
# where the rule is written; what the review of #79 changed is pinned below.

# The Ticket Brief template every dispatched role's Brief is written from gives
# the reason; its rule sentence is pinned below, joined to item 3 of its 要求 (a
# check of the sentence alone in this file was that check's substring, never
# red by itself). The root template of the Opus / codex division carries the
# same sentence, with the reason as its tail.
has 'worker 空闲后不会被唤醒，后台收尾等于失联' \
  'Ticket Brief template says why: nothing wakes an idle worker' "$BRIEF_FIND_NEXT"
has '测试与验证一律前台跑完再交最终报告；不得把测试放到后台然后结束回合' \
  'root Brief template runs its tests in the foreground before the final report' "$BRIEF_ROOT_TEMPLATE"
# The root template carries the rule of 票 #80 next to that sentence too: the
# wrapping is forbidden, and a multi-line script goes to a file under
# `mktemp -d` or into separate Bash calls. Its fixed clauses forbid a
# recursive deletion outright, so its sentence does not hand the cleanup to a
# `trap` (a `trap` removing its `mktemp -d` directory is one) and leaves the
# temporary directory to that clause: said in the report. The second check
# pins that hand-over, so the shared section's sentence cannot be copied in
# whole, `trap` included, to contradict the clause it would sit next to.
has '不得用 `bash -c`、`sh -c`、`$'"'"'…'"'"'` 内联包裹多行脚本（含 `rm` / `del` 等删除类命令时尤其如此）：多行脚本写进 `mktemp -d` 目录下的脚本文件执行，或拆成多次独立调用' \
  'root Brief template keeps a worker from wrapping a multi-line script inline' "$BRIEF_ROOT_TEMPLATE"
has '临时目录的清理照上面「不要递归删除目录」那条，在报告里说明' \
  'root Brief template leaves the cleanup of the script directory to its rule against recursive deletion' "$BRIEF_ROOT_TEMPLATE"
# Step 5: the merge role's Brief and each fix role's Brief carry the rule.
has 'carrying the foreground-test rule (its tests and verification finish in the foreground before its final report' \
  'SKILL.md step 5 merge-role Brief carries the foreground-test rule' "$SKILL"
has 'runs the test command in the foreground before its final report (the foreground-test rule of the `3` line' \
  'SKILL.md step 5 re-bump Brief carries the foreground-test rule' "$SKILL"
has 'a Brief that carries the foreground-test rule of the `3` line' \
  'SKILL.md step 5 test-failure fix Brief carries the foreground-test rule' "$SKILL"
# The main session verifies a worker gone idle without a report itself and
# never waits again for it; the two wait exits that can meet one, and the
# Worker failures rules, point to it.
has 'A worker that went idle without a final report (票 #79)' \
  'SKILL.md has the rule for a worker gone idle without a final report' "$SKILL"
has 'never wait again for such a worker' \
  'SKILL.md never waits again for a worker gone idle without a report' "$SKILL"
has 'Verify yourself, in the foreground: `ps` for the test it left running' \
  'SKILL.md verifies an idle worker by the process it left' "$SKILL"
has "for the branch's last commit time and \`git status --porcelain\` in its worktree for its state" \
  'SKILL.md verifies an idle worker by the branch and the worktree' "$SKILL"
has "What it left goes through the gate's three script checks below" \
  'SKILL.md judges a worker gone idle by the gate, as if it had reported' "$SKILL"
has 'a worker that went idle without a report (item 6) is never waited for again' \
  'SKILL.md wait timeout points an idle worker to the rule' "$SKILL"
has "that worker is item 6's, never one to wait for again" \
  'SKILL.md wait mail points a worker stopped without reporting to the rule' "$SKILL"
has 'a worker that went idle without a report and left a gate that is not met (verify it first, as "Dispatching a role" item 6 says' \
  'unattended landing verifies an idle worker before it counts as a failure' "$SKILL"
# find-next: an --worker agent subagent gone idle without a final report.
has '**子代理空闲却没交最终报告**（票 #79）' \
  'find-next SKILL.md has the rule for a subagent gone idle without a final report' "$FIND_NEXT"
has '自己核实，按证据判定完成或失败并收尾，不无限等待' \
  'find-next SKILL.md verifies itself instead of waiting' "$FIND_NEXT"
has '按「推进模式」开头的核实规则自己核实' \
  'find-next error handling points an idle subagent to the rule' "$FIND_NEXT"

# --- #79 review r2: each rule written once, and pointed to from everywhere else ----

# The Ticket Brief template states the rule once, in item 3 of its 要求 next to
# the rule against re-delegation that it repeats; the separate item 8 is gone.
has '不要起后台进程后就结束。测试与验证一律前台跑完再交最终报告；不得把测试放到后台然后结束回合' \
  'Ticket Brief template joins the foreground-test rule to item 3' "$BRIEF_FIND_NEXT"
without '8. 测试与验证一律前台跑完再交最终报告' \
  'Ticket Brief template no longer has a separate item 8 for the rule' "$BRIEF_FIND_NEXT"
# The worker-side process rules live in the environment section that every
# find-next Brief template shares, so the rule reaches every worker a template
# is written for — the task and prototype subagents too, which find-next's
# SKILL.md names as leaving background tests behind as well. It is worded for
# a test or a long command. test-make-batch-briefs.sh checks that the section
# is identical in every template; this checks that it holds the rule.
FOREGROUND_RULE_COMMON='测试或长命令要在前台等它跑完再收尾：不得把它放到后台然后结束回合'
has "${FOREGROUND_RULE_COMMON}" \
  'Ticket Brief template keeps a worker from leaving a test or a long command in the background' \
  "$BRIEF_FIND_NEXT"
# The count is over the templates that exist, so one added or removed changes
# it and nothing else. What is guarded is the empty case, with the first
# template found, as test-make-batch-briefs.sh guards its section check with
# the first section it read: a check against a fixed number would go red the
# day the number of templates changes. The rule of 票 #80 (below) is counted
# the same way over the same templates, so the count is a function: <what>
# names the rule on the check's line, and a template counts when it holds
# every text given. Its failure detail is `has`'s shape — missing […] in
# <file> — once per template that lacks a text, naming only the texts that
# template lacks (the review of 票 #80: "11 of 12 templates have […]" said
# neither which template nor where one text ended and the next began).
in_every_template() { # what text...
  local what=$1 total=0 holding=0 first= lacking= missing= template holds text
  shift
  for template in "$ROOT"/find-next/templates/*.md; do
    [ -f "${template}" ] || continue
    total=$((total + 1))
    [ -n "${first}" ] || first=${template}
    holds=1 missing=
    for text in "$@"; do
      if ! grep -Fq -- "${text}" "${template}"; then holds=0; missing="${missing}${missing:+ | }[${text}]"; fi
    done
    if [ "${holds}" -eq 1 ]; then holding=$((holding + 1)); else lacking="${lacking:+${lacking}; }missing ${missing} in ${template#$ROOT/}"; fi
  done
  if [ -n "${first}" ] && [ "${holding}" -eq "${total}" ]; then
    ok "every find-next Brief template (${total}) carries ${what} in the section they share"
  else
    bad "every find-next Brief template carries ${what} in the section they share" \
      "${lacking:-find-next/templates/ holds no Brief template}"
  fi
}
in_every_template 'the rule' "${FOREGROUND_RULE_COMMON}"
# Step 5's `3` line keeps the rule and leaves the reason to "Dispatching a role"
# item 6, which writes it once; its `6` and `4` lines already point back to it.
has 'and then ends its turn; the reason is "Dispatching a role" item 6' \
  'SKILL.md step 5 `3` line points the reason to item 6' "$SKILL"
without 'a worker never puts a test in the background and then ends its turn: nothing wakes an idle worker' \
  'SKILL.md step 5 `3` line no longer repeats the reason' "$SKILL"
# Steps 8 and 9.1 dispatch fix, re-bump and conflict roles too: their Briefs
# carry the same rule.
has "dispatch a single fix role with that file as its context pointer and a Brief that carries the foreground-test rule of step 5's \`3\` line" \
  'SKILL.md step 8 fix-role Brief carries the foreground-test rule' "$SKILL"
has "step 5's re-bump rules and the foreground-test rule of step 5's \`3\` line, main in place of the integration branch" \
  'SKILL.md step 9.1 re-bump Brief carries the foreground-test rule' "$SKILL"
has "re-increments on \`spec-<n>\`, runs the test command in the foreground before its final report and commits" \
  'SKILL.md step 9.1 re-bump role runs the test command in the foreground' "$SKILL"
has "those paths with both sides' intent and carries the foreground-test rule of step 5's \`3\` line" \
  'SKILL.md step 9.1 conflict fix-role Brief carries the foreground-test rule' "$SKILL"
has "each round with the next free \`--attempt <n>\`) and a Brief that carries the foreground-test rule of step 5's \`3\` line" \
  'SKILL.md step 9.1 test-failure fix Brief carries the foreground-test rule' "$SKILL"
# Recovery said "never stop it" of a live worker and item 6 said "never wait for
# it again" of the same one. A live worker is still waited for and never
# stopped, with item 6's case as the one exception, judged by Orca's evidence.
has "never stop it — unless Orca's evidence says it went idle without a report (\"Dispatching a role\" item 6's evidence)" \
  'SKILL.md Recovery makes a worker gone idle without a report the exception to never stopping a live one' "$SKILL"
has "such a worker is never waited for again — verify it in the foreground as item 6 says, then \`orca orchestration worker-stop --dispatch <id>\`" \
  'SKILL.md Recovery verifies a worker gone idle in the foreground and stops it' "$SKILL"
has "that exception is judged by Orca's evidence, never by the clock" \
  'SKILL.md Recovery judges the exception by evidence, never by the clock' "$SKILL"
# Orca's mail is known by its body. The first version named an escalation with
# a `stopReason` field; no field of that name could be verified (`orca
# orchestration send --help` lists escalation among its mail types and names no
# field), so nothing is pinned on a mail type or a field name.
without '`stopReason`' 'SKILL.md names no stopReason field' "$SKILL"
has "a mail of the Run's that is no \`worker_done\` — one \`wait\` hands such mail over with exit 8 — says in its body that the worker stopped without reporting" \
  'SKILL.md knows a worker gone idle from the body of a mail that is no worker_done' "$SKILL"
has "unless the mail says a worker stopped without reporting: that is item 6's evidence, and that worker is item 6's, never one to wait for again" \
  "SKILL.md wait mail hands a worker stopped without reporting to item 6's evidence" "$SKILL"
has "stopped without reporting (read by its body: no mail type or field name of Orca's is relied on), or the last thing the worker wrote" \
  'SKILL.md item 6 mail is read by its body' "$SKILL"
# A worker gone idle never reports, so the evidence gets a file of its own that
# the final report cites; its line there says 主会话核实 where another's says
# the outcome, and the gate's three script checks stand in for its fourth.
has "Put the evidence either way in \`<dispatch dir>/session-verify.md\`" \
  'SKILL.md puts the evidence of a worker gone idle in session-verify.md' "$SKILL"
has "and cite that file in the Run's final report, the one \"Report at the end\" describes after step 10" \
  "SKILL.md cites session-verify.md in the Run's final report" "$SKILL"
has "this dispatch's line there says 主会话核实 where another's says \`worker_done.outcome\`" \
  "SKILL.md item 6 puts 主会话核实 in place of worker_done.outcome on that dispatch's line" "$SKILL"
has "it never reported, so the gate's fourth check is not its to meet: the three script checks stand in for it" \
  "SKILL.md item 6 lets the gate's three script checks stand in for its fourth" "$SKILL"
has "item 6 says, 主会话核实 in its place, with \`<dispatch dir>/session-verify.md\` as the report path" \
  "the final report's per-dispatch line takes 主会话核实 and session-verify.md for such a worker" "$SKILL"
# The test a worker gone idle left running is ended by the pid from that same
# `ps`: the next step re-runs the test in the foreground, and a leftover run of
# it would interfere with that.
has "end it, \`kill <pid>\`)" 'SKILL.md ends the test a worker gone idle left running' "$SKILL"

# --- #79 review r3: the Watchdog reads first; item 6's evidence is written once ------

# The incident shape — a worker that leaves a message and goes idle, sending
# no mail — is met first by the Watchdog. Its `3` report on a role Orca calls
# `live` used to re-arm at once, and the next report with no progress stopped
# the role as stalled and dispatched it again, so what the worker left never
# reached the gate. Now the live branch reads the worker's last line first and
# hands item 6's case to item 6; only a role whose last line is not item 6's
# message can be called stalled. A wait that timed out reads the same line.
has "\`liveness: live\` → read what it wrote last first (\`orca orchestration worker-read\`): is its last line \"Dispatching a role\" item 6's message?" \
  'SKILL.md Watchdog reads the last line of a live worker before re-arming' "$SKILL"
has 'a worker gone idle without a report, never a stalled one — so go there instead of re-arming: it is verified in the foreground and wrapped up by that evidence, never waited for again' \
  'SKILL.md Watchdog hands the worker of item 6 to item 6 instead of re-arming' "$SKILL"
has 'Otherwise re-arm the watchdog: a worker may think long before it touches a file' \
  'SKILL.md Watchdog still re-arms for a live worker that is not the case of item 6' "$SKILL"
has "A role Orca calls \`live\`, whose last line is not item 6's message, that the next report flags again with no progress is stalled" \
  'SKILL.md Watchdog calls a role stalled only when its last line is not the message of item 6' "$SKILL"
has "read what the worker wrote last (\`worker-read\`, item 6's evidence) and ask the Watchdog" \
  'SKILL.md wait timeout reads the last line of the worker' "$SKILL"
# Item 6's evidence — the mail read by its body, the `worker-read` command — is
# written once, in item 6; Recovery and the wait's exit 8 only point to it.
without 'is the message that it would report when its background tests finished): such a worker is never waited for again' \
  'SKILL.md Recovery no longer spells out the evidence of item 6' "$SKILL"
without "stopped without reporting (read by its body: no mail type or field name of Orca's is relied on): that worker is item 6's" \
  'SKILL.md wait exit 8 no longer spells out the evidence of item 6' "$SKILL"
# The PR path of an Unattended landing dispatches a fix role too: its Brief
# carries the rule like every other dispatch, not by the template's say-so only.
has "dispatch a fix role (step 8's form: a Brief with the failure output that carries the foreground-test rule of step 5's \`3\` line), push, watch again" \
  'SKILL.md PR path fix-role Brief carries the foreground-test rule' "$SKILL"
# A conclusion's sources include the file the session wrote itself for a worker
# gone idle without a report: Flash mode's enumeration, which the two setup
# documents repeat, names it next to the worker's own report.
has "its sidecar's \`worker_done.report_path\`, or, for a worker gone idle without a report, the session's own \`<dispatch dir>/session-verify.md\`" \
  'SKILL.md flash mode names session-verify.md among the sources of a conclusion' "$SKILL"
for doc in docs/setup.md docs/setup.en.md; do
  has 'session-verify.md' "$doc names session-verify.md among the sources of a conclusion" "$ROOT/$doc"
done
# The ticket number of a rule is provenance, not instruction: it stays in the
# title of "Dispatching a role" item 6, and no other sentence of SKILL.md
# carries it (the record is MAINTAINING's, as with the wiring of 规格 #61).
ticket_refs=$(grep -Fo -- '票 #79' "$SKILL" | wc -l | tr -d ' ')
if [ "${ticket_refs}" -eq 1 ]; then
  ok 'SKILL.md names 票 #79 in the title of item 6 only'
else
  bad 'SKILL.md names 票 #79 in the title of item 6 only' "${ticket_refs} occurrences in SKILL.md"
fi
# GLOSSARY names what the two rules introduced: the rule itself; a worker gone
# idle without a report — idle as a turn that ended, which is Orca's evidence
# and not the clock an External worker's Idle timeout is; and, in the Sidecar
# entry, the file and the outcome value the final report uses for such a worker.
has '**foreground-test rule (前台测试规则)**:' 'GLOSSARY defines the foreground-test rule' "$GLOSSARY"
has '**Idle without a report (空闲未报)**:' 'GLOSSARY defines Idle without a report' "$GLOSSARY"
has 'It is a clock, and only an External worker has one: an Orca worker has none' \
  'GLOSSARY keeps the Idle timeout a clock on an External worker only' "$GLOSSARY"
has "An Orca worker that ended its turn without sending its \`worker_done\`" \
  'GLOSSARY defines a worker gone idle without a report as one whose turn ended' "$GLOSSARY"
has 'It is known from Orca'"'"'s evidence, never from the clock' \
  'GLOSSARY knows a worker gone idle without a report from Orca evidence, never the clock' "$GLOSSARY"
has 'that copy `report-from-worktree.md`, and, for a worker gone Idle without a report (which leaves the sidecar no `worker_done` to record), `session-verify.md`' \
  'GLOSSARY Sidecar entry lists session-verify.md in the dispatch directory' "$GLOSSARY"
has "the Run's final report names that file as the dispatch's report path and says 主会话核实 where another dispatch's line says \`worker_done.outcome\`" \
  'GLOSSARY Sidecar entry names 主会话核实 in place of the outcome' "$GLOSSARY"

# --- no inline script, in SKILL.md and in every Brief template (票 #80) ----------

# On 2026-11-28 two unattended sessions sat at a confirmation nobody answered,
# both on a multi-line script wrapped into one Bash command — `bash -c '…'`,
# `sh -c '…'` or a `$'…'` string: spec-25's diagnostic cleanup, whose script
# held an `rm`, and spec-26's fix-26-r2, whose script held nothing but `read`,
# `printf` and `grep` — no `rm`; the permission layer misjudged it. So the
# rule is on the wrapping, not on the `rm`: a script that deletes nothing is
# not exempt. The first review of 票 #80 found both written the other way
# round — "fix-26-r2 and its rm script", and the rule made conditional on an
# `rm` — so the fact and the unconditional statement are each pinned, and the
# conditional phrase is pinned out. The rule is written where a reader looks
# for the rule about an `rm`: in SKILL.md, next to "No unresolvable `rm`"; in
# find-next's SKILL.md for its main session, next to the rule of 票 #79; and
# in the Briefs a dispatched role reads — the section every find-next Brief
# template shares, next to the foreground-test rule, and the fixed clauses of
# the root Brief template. The way out through a script file takes the `rm`
# out of the one place the permission layer reads, the Bash command line, so
# the script may delete only in the `trap` that cleans up its own `mktemp -d`
# directory and every other deletion is its own `rm` with a literal path.
# Each place is pinned as a whole — the rule with its three forms, then the
# two ways out — so neither can be dropped on its own. A hook that let such
# a script through would loosen a guard: it is recorded in MAINTAINING and
# was not built.
has "**No inline script.** Never wrap a multi-line script into one Bash command — \`bash -c '…'\`, \`sh -c '…'\` or a \`$'…'\` string — whoever runs it. The ban is on the wrapping itself, not on an \`rm\` inside it: a script wrapped that way meets the same confirmation even under \`--dangerously-skip-permissions\`, and holding no deleting command is no protection" \
  'SKILL.md forbids wrapping a multi-line script into one Bash command, deleting command or not' "$SKILL"
has "whose \`bash -c \$'…'\` held nothing but \`read\`, \`printf\` and \`grep\` — no \`rm\` at all; the permission layer misjudged it" \
  'SKILL.md records the fix-26-r2 script as holding no rm, stopped by a misjudgment' "$SKILL"
without 'when it holds an `rm`' 'SKILL.md no longer makes an rm in the script the condition of the rule' "$SKILL"
has 'written to a file in a `mktemp -d` directory and run from there, with a `trap` of its own to clean up, or the work is split into separate Bash calls' \
  'SKILL.md gives the two ways out of an inline script' "$SKILL"
has 'Inside such a script file the only deletion is its `trap` cleaning up its own `mktemp -d` directory: every other deletion is its own `rm` command with a literal path' \
  'SKILL.md keeps every deletion but the trap its own rm with a literal path' "$SKILL"
has 'and the 固定条款 section of the root template, `templates/brief-implement.md`, states it next to that rule too' \
  'SKILL.md names the root Brief template as a second source of the rule for a dispatched role' "$SKILL"
# find-next's main session keeps the rule too, next to the rule of 票 #79.
has "**主会话不内联包裹多行脚本**（票 #80）：不得用 \`bash -c\`、\`sh -c\`、\`\$'…'\` 把多行脚本包进一条 Bash 命令，脚本里有没有 \`rm\` 都一样" \
  'find-next SKILL.md has the rule against wrapping a multi-line script, rm or not' "$FIND_NEXT"
has '脚本里配 `trap` 清理它自己的 `mktemp -d` 目录；除此之外的删除一律单独 `rm` 带字面路径；或把活拆成多次独立的 Bash 调用' \
  'find-next SKILL.md gives the ways out of a multi-line script' "$FIND_NEXT"
# The Ticket Brief template is where the check of the section's sentence is
# read, as for the foreground-test rule; the count over the templates that
# exist is the other check, with the two ways out and the deletion rule
# counted in.
INLINE_RULE_COMMON="不得用 \`bash -c\`、\`sh -c\`、\`\$'…'\` 内联包裹多行脚本（含 \`rm\` / \`del\` 等删除类命令时尤其如此）"
INLINE_WAYS_OUT_COMMON='多行脚本写进 `mktemp -d` 目录下的脚本文件执行，脚本里配 `trap` 清理；或拆成多次独立调用'
INLINE_DELETION_COMMON='脚本自身 `trap` 清理它的 `mktemp -d` 目录除外，其他删除一律单独 `rm` 带字面路径'
has "${INLINE_RULE_COMMON}" \
  'Ticket Brief template keeps a worker from wrapping a multi-line script inline' \
  "$BRIEF_FIND_NEXT"
in_every_template 'the rule, its two ways out and its deletion rule' "${INLINE_RULE_COMMON}" "${INLINE_WAYS_OUT_COMMON}" "${INLINE_DELETION_COMMON}"
# GLOSSARY names the rule, as it names the foreground-test rule, and the two
# entries that describe the section every find-next Brief template shares
# point at it.
has '**No inline script (禁内联脚本)**:' 'GLOSSARY defines the No inline script rule' "$GLOSSARY"
has 'The ban is on the wrapping itself, not on an `rm` inside it: a script wrapped that way meets a confirmation even under `--dangerously-skip-permissions`, and holding no deleting command is no protection' \
  'GLOSSARY states the No inline script rule as unconditional' "$GLOSSARY"
has 'inside that file only the `trap` deletes anything, its own `mktemp -d` directory, and every other deletion is its own `rm` command with a literal path' \
  'GLOSSARY states the deletion rule inside the script file' "$GLOSSARY"
has 'the section every find-next Brief template shares, next to the foreground-test rule, and the 固定条款 section of the root Brief template' \
  'GLOSSARY names where a dispatched role gets the No inline script rule' "$GLOSSARY"
has 'the foreground-test rule, in its general form, and the No inline script rule' \
  'GLOSSARY Brief entry points at the shared section for both process rules' "$GLOSSARY"
has 'for a test or a long command, next to the No inline script rule' \
  'GLOSSARY foreground-test rule entry points at the rule next to it in the shared section' "$GLOSSARY"

# The Ticket Brief template carries the rules 规格 #58 wrote for every Ticket,
# not only for an ssh ops ticket (审查 Spec 缺失 1). A Lean start loads no
# skills, so a worker knows only its Brief: one written from the template as it
# stood had nowhere to record a loosening, and a smoke ticket's worker read
# rule 3 as forbidding the very terminal the ticket is about. The ops section
# now names the local ops ticket and the agent-driven smoke ticket, rule 3
# carries the smoke exception (rule 4, the hook rule, is copied verbatim and
# stays as it is), a step that would need a loosened boundary is recorded
# instead of taken, and the report has a fifth item for those items.
for text in '本机运维票' 'agent 驱动冒烟票' '未执行的放宽项' 'Orca 操作序列'; do
  has "$text" "Brief template names [$text]" "$BRIEF_FIND_NEXT"
done
has '冒烟票例外：agent 驱动冒烟票的操作序列里，要开的 Orca 终端或会话是被测的操作本身，不算派发' \
  'Brief template rule 3 excepts the session a smoke ticket opens' "$BRIEF_FIND_NEXT"
has '护栏点名了 `orca orchestration worker-start` 才能用，没点名仍禁止' \
  'Brief template keeps worker-start forbidden unless the guardrails name it' "$BRIEF_FIND_NEXT"
has '删掉上面 ssh-manager 那一行' 'Brief template tells a local ops ticket to drop the ssh-manager line' "$BRIEF_FIND_NEXT"
has '某一步只有放宽安全边界（护栏、hook、权限这类）才能做时不执行：把该项记进报告的「未执行的放宽项」，该条验收按「已记录」算过' \
  'Brief template records a loosening instead of taking the step' "$BRIEF_FIND_NEXT"
has '5. **未执行的放宽项**：' 'Brief template report has the fifth item' "$BRIEF_FIND_NEXT"

# --- the three root Brief templates carry the 环境约束 section verbatim (票 #60, 规格 #58)

# find-next/scripts/test-make-batch-briefs.sh checks that section over
# find-next/templates/*.md only, so nothing caught a root template (the Design
# session's Briefs) drifting from it. The section runs from its heading up to
# the next `## ` and is compared byte for byte, the blank lines included.
# Two bullets are left out of that comparison: the process rules 票 #79 and
# 票 #80 added to the find-next templates only, which landed on main while
# 规格 #58 was in flight. The root dispatch template carries both in its
# 固定条款, where the cleanup is handed to the clause against a recursive
# deletion, so the shared sentence must not be copied next to it (票 #80 审查
# r2), and the Design session's Briefs were not given them. Every other
# bullet of the find-next section is still required of a root template: add
# it there, or name it here with its reason. Exactly those two lines are left
# out; another count means the section changed and this is to be read again.
env_section() { # file
  awk '/^## 环境约束（找文件与子进程）$/ { section = 1; next }
       section && /^## / { section = 0 }
       section' "$1"
}
root_reference_section() { # the find-next section without its two process-rule bullets
  env_section "$BRIEF_FIND_NEXT" | grep -v -F -e "- ${FOREGROUND_RULE_COMMON}" -e "- ${INLINE_RULE_COMMON}"
}
ROOT_SECTION_LEFT_OUT=$(( $(env_section "$BRIEF_FIND_NEXT" | wc -l) - $(root_reference_section | wc -l) ))
for template in templates/brief-implement.md templates/brief-investigate.md templates/brief-mock.md; do
  if ! grep -Fq -- '## 环境约束（找文件与子进程）' "$ROOT/$template"; then
    bad "$template has the 环境约束 section verbatim" "missing [## 环境约束（找文件与子进程）] in $template"
  elif [ "$ROOT_SECTION_LEFT_OUT" -ne 2 ]; then
    bad "$template has the 环境约束 section verbatim" \
      "expected exactly the two process-rule bullets to be left out of find-next/templates/brief-implement.md, found ${ROOT_SECTION_LEFT_OUT}"
  elif cmp -s <(env_section "$ROOT/$template") <(root_reference_section); then
    ok "$template has the 环境约束 section verbatim"
  else
    bad "$template has the 环境约束 section verbatim" \
      "differs from find-next/templates/brief-implement.md (without its two process-rule bullets) in $template"
  fi
done
unset ROOT_SECTION_LEFT_OUT

# --- hooks README ----------------------------------------------------------------

has '## 精简启动的 worker' 'hooks README documents the lean start' "$HOOKS"
has 'merge-ticket.sh' 'hooks README names the script gate' "$HOOKS"
has '--bare' 'hooks README says --bare loads no hooks' "$HOOKS"
has 'unattended-stop-guard' 'hooks README names the hooks a lean worker lacks' "$HOOKS"
# Rule A's reminder is step 10's sentence again: it carries the run directory too.
has 'close-self.sh --run-dir <Spec Run root>' 'hooks README rule A closes with the run directory' "$HOOKS"
# The script gate counts the shared-counter gate in (规格 #61 票 #74): a
# collision exits 6 and merges nothing, as a gate miss exits 2.
has '以「需 re-bump」退出 6' 'hooks README counts the counter gate in' "$HOOKS"

# --- what the cumulative review of 规格 #26 settled (MAINTAINING 第 51 条) -------

# The three guards key on the command an Orca worker-start session gets: the
# line after `=== TASK ===`, with no <command-name> tag (User Story 18).
has '=== TASK ===' 'lib-transcript.js knows the Orca worker-start form of the command' "$LIB_TRANSCRIPT"
# delegate-guard's flash reason points where subagent-guard's does: a subagent
# and a bare codex worker are each denied a second time in a flash session.
without '派 glm-5.4 子代理（或 codex worker）' 'delegate-guard flash reason no longer names a subagent or codex worker' "$DELEGATE_GUARD"
has 'stage-dispatch.sh dispatch --stage implementation --brief <file>' 'delegate-guard flash reason names the dispatch module' "$DELEGATE_GUARD"
has 'scripts/opus-review.sh' 'delegate-guard flash reason names opus-review.sh' "$DELEGATE_GUARD"
without '`tool_input` 缺失或 hook 内部异常都 fail open' 'hooks README no longer calls a missing tool_input fail-open' "$HOOKS"
# find-next in a flash session dispatches codex workers like every other
# session: its in-session subagents are what subagent-guard denies.
without '没给 `--worker` 时按 `--worker agent` 处理' 'find-next SKILL.md no longer defaults a flash session to --worker agent' "$FIND_NEXT"
has '没给 `--worker` 时按 `--worker codex` 处理' 'find-next SKILL.md keeps codex as the flash default' "$FIND_NEXT"
has '`--worker agent` 只留给非 flash 会话' 'find-next SKILL.md keeps --worker agent for non-flash sessions' "$FIND_NEXT"
without '路由对那些运行无效' 'find-next SKILL.md no longer says the route table skips a flash run' "$FIND_NEXT"
# A Run does not report into its wave's Orca Run.
without "a Run reports into its wave's Orca Run" 'GLOSSARY no longer says a Run reports into the wave Orca Run' "$GLOSSARY"

# --- what ticket #48 retired (规格 #26): the current wording no longer names it -----

# progress-tab.sh, ticket-watch.sh, pi-worker.sh and the pi selftest.sh are gone;
# `selftest.sh` as a fixed string does not match selftest-codex.sh, which stays.
for doc in $USER_DOCS; do
  for gone in 'pi-worker' 'progress-tab' 'ticket-watch' 'selftest.sh'; do
    without "$gone" "${doc} no longer names $gone" "$ROOT/$doc"
  done
done

# --- takeover and the worktree tree (规格 #26 「接管」, User Stories 1–2) -----------

for doc in README.md docs/setup.md docs/setup.en.md; do
  has 'orca orchestration run-use --id <run id>' "$doc documents the takeover command" "$ROOT/$doc"
  has 'orca-run-id' "$doc says where a Spec's Orca Run id lives" "$ROOT/$doc"
  has 'spec-<n>-t<m>' "$doc documents the Ticket worktree under the Spec worktree" "$ROOT/$doc"
done
has '**Orca worker**:' 'GLOSSARY defines Orca worker' "$GLOSSARY"
has '**Takeover**:' 'GLOSSARY defines Takeover' "$GLOSSARY"

# --- no document still says find-next stops at a question round (规格 #58 复审 Standards 硬违规 2) ---

# The first review fix pinned the documents it had touched. Four sentences it
# did not touch still described the old stop: both setup guides and grill-map's
# hand-over said find-next stops at its synthesized question round, and
# find-next's usage bullet still parked on "what truly needs a human decision" —
# the parking rule of before 票 #70. Each old sentence is gone and its
# replacement, which says the round is decided by recommendation and waits for
# nobody, is pinned. The ADRs are not listed: ADR 0004 keeps the old sentence as
# history, with a 2026-11-28 note.
SETUP=$ROOT/docs/setup.md
SETUP_EN=$ROOT/docs/setup.en.md
GRILL_MAP=$ROOT/grill-map/SKILL.md
without 'find-next 停在合成提问那一步等你' 'docs/setup.md no longer says find-next stops at a question round' "$SETUP"
has '接上后 find-next 把要拍板的取舍合成一轮按推荐自动拍板（可推翻）、不等回复' \
  'docs/setup.md says the grill-map hand-over goes on through a decision round' "$SETUP"
without 'synthesized question round' 'docs/setup.en.md no longer says find-next stops at a question round' "$SETUP_EN"
has 'find-next settles the trade-offs in one decision round by the worker' \
  'docs/setup.en.md says the grill-map hand-over goes on through a decision round' "$SETUP_EN"
without 'stopping at its synthesized question round' 'grill-map no longer says find-next stops at a question round' "$GRILL_MAP"
has 'settling every trade-off in one decision round by the worker' \
  'grill-map says find-next decides the round by recommendation' "$GRILL_MAP"
without '只有真要人决定的事才停车' 'find-next usage no longer parks on what needs a human decision' "$FIND_NEXT"
# The subject of that sentence is 票 #84's name for the review (审查（按「审查」路由跑）,
# which landed on main first); the rule after it is 规格 #58's.
has '审查（按「审查」路由跑）的 findings 里的取舍不因是取舍而停车' 'find-next usage says a review trade-off never parks' "$FIND_NEXT"
has '只有要本人身份或凭据的事（停车类别 `auth`）、或列出的选项里没有可逆的（`error`）才停车' \
  'find-next usage names the two reasons that still park' "$FIND_NEXT"

# --- the ops dispatch of find-next step 3 names codex-worker.sh, and a worker is a worker (规格 #58 复审 Standards 判断项 4) ---

# The sentence was copied from ticket #69's body: "the Ops tickets codex backend
# of implement-spec-split" is a pointer to something the root SKILL.md no longer
# has (规格 #26 left only the dispatch module's --mcp-config in its Ops tickets
# section; the codex backend lives on in MAINTAINING 第 36 条 as history), and it
# called the External worker codex-worker.sh starts an "implementer", which
# GLOSSARY reserves for Orca workers. The dash after it already said what is
# done, so nobody got lost; the pointer and the term are corrected anyway.
TASK_TEMPLATE=$ROOT/find-next/templates/brief-task.md
without 'Ops tickets 的 codex 后端写法' 'find-next step 3 no longer points at a retired Ops tickets codex backend' "$FIND_NEXT"
without '各派一个实现者 worker 执行它的整节步骤' 'find-next step 3 does not call the codex-worker.sh worker an implementer' "$FIND_NEXT"
has '每张 task 票各派一个 worker 执行它的整节步骤' 'find-next step 3 dispatches one worker per task ticket' "$FIND_NEXT"
without '运维步骤由主会话派实现者执行' 'brief-task does not call the codex-worker.sh worker an implementer' "$TASK_TEMPLATE"
has '运维步骤由主会话派 worker 执行：`codex-worker.sh` 不带 `--read-only`' 'brief-task names codex-worker.sh as the worker of the ops steps' "$TASK_TEMPLATE"

# --- the Unattended landing entry limits the install only, not the loose tickets (规格 #58 复审 Standards 判断项 5) ---

# The entry read "runs install.sh and turns each unexecuted loosening into a
# loose ticket — for a Spec on this skill's own repository only", so the dash
# clause seemed to limit the loose tickets too; step 9 opens one of those for a
# Spec on any repository, and only the install is this skill's own repository's.
# The limitation now sits on install.sh alone (the pin under "what doctor's hints
# say" above still holds the tail of the sentence).
without "turns each unexecuted loosening into a loose ticket — for a Spec on this skill's own repository only" \
  "GLOSSARY: the loose tickets are no longer read as limited to this skill's own repository" "$GLOSSARY"
has 'turns each unexecuted loosening into a loose ticket, whatever repository the Spec is on' \
  'GLOSSARY: the Unattended landing entry opens a loose ticket for a Spec on any repository' "$GLOSSARY"

# --- step 8 never picks an option that needs the owner's own hands (规格 #58 复审 Spec 7, 取舍 3 选 A) ---

# The parking triggers of step 8 were two: an item that needs the owner's
# identity or credentials, and an item with nothing reversible. find-next's
# step 6 also leaves a physical action to the human. Read literally, an item
# like "可自动采纳：否 — someone has to plug it into the real device and test"
# went to the reversibility rule, which picked an option the Run cannot carry
# out (it changes nothing, so it is the most "reversible" one), and only the fix
# role's report parked the Run. Such an option is now listed under 要你做的 of
# the landing report and never picked, the same exception as find-next's step 6;
# the parking categories are not touched. The third review fix (r3, trade-off
# 2 = A) names the category for the case that sentence left to "the two parking
# rules above": an item whose options are all hands-on, which neither rule hit
# when read literally, now parks as auth — the category's cases are identity,
# credentials or physical action — while the set of categories stays the same.
has "An option that needs the owner's own hands — a physical action the Run cannot carry out — is never picked either, whatever the rule above would pick: list it under 要你做的 in the landing report and decide among the remaining options as above; when no option is left, the item parks by the two parking rules above: with category \`auth\` when its options all need the owner's identity, credentials or physical action, with \`error\` when none of them is reversible." \
  "SKILL.md step 8 never picks an option that needs the owner's own hands, and parks an all-hands-on item as auth" "$SKILL"

# --- the two-clone shape of the clone-direct install is a known limitation (规格 #58 复审 Spec 6, 取舍 2 选 A) ---

# With ~/.claude/skills/implement-spec-split a clone of its own and a second,
# main checkout elsewhere, the landing runs install.sh from the main checkout,
# which sees the root skill's place as the real directory of another clone: one
# WARN it never clears (test-install.sh case 9 pins that on purpose), so every
# landing exits 1 and lists that manual step. Nothing changes in the script; the
# limitation is recorded in MAINTAINING 第 60 条 and in both setup guides.
has '已知限制：clone 直装形态下如果别处还有一份主 checkout' \
  'docs/setup.md states the two-clone limitation of the clone-direct install' "$SETUP"
has 'Known limitation: with the clone-direct shape and a second, main checkout elsewhere' \
  'docs/setup.en.md states the two-clone limitation of the clone-direct install' "$SETUP_EN"

# --- four wording points of the third review fix of 规格 #58 (r3: Standards 硬违规 3, 判断 5 / 6 / 7) ---

# The landing report and its ## 结论 block name their section 要你做的 (step
# 9.3, the local install paragraph, the report format); 要你做 is the name of
# find-next's wrap-up list and of its supervisor. The two-clone limitation the
# second fix added to both setup guides got the name wrong twice in each.
without '落地报告的「要你做」' 'docs/setup.md names the landing report section 要你做的' "$SETUP"
has '落地报告的「要你做的」会写一句 `git pull`' 'docs/setup.md says the git pull goes under 要你做的' "$SETUP"
has '落地报告的「要你做的」每次挂这一条' 'docs/setup.md says the two-clone manual step goes under 要你做的' "$SETUP"
without "landing report's 要你做 " 'docs/setup.en.md names the landing report section 要你做的' "$SETUP_EN"
has "the landing report's 要你做的 says \`git pull\`" 'docs/setup.en.md says the git pull goes under 要你做的' "$SETUP_EN"
has 'under 要你做的 each time' 'docs/setup.en.md says the two-clone manual step goes under 要你做的' "$SETUP_EN"
# The hands-on bullet of step 8 is a sibling of the loosening bullet and of the
# two parking rules above it, so the Release sentence after the blank line
# stays a paragraph of Design-level review items. As a top-level bullet it took
# that paragraph away from them. The pin is anchored at the line start, since
# the whole-sentence pin under "step 8 never picks an option" cannot see the
# indentation.
if grep -Eq '^  - An option that needs the owner'\''s own hands' "$SKILL" 2>/dev/null; then
  ok 'SKILL.md step 8: the hands-on bullet sits at the level of the two rules above it'
else
  bad 'SKILL.md step 8: the hands-on bullet sits at the level of the two rules above it' \
    "no line starts with two spaces and the hands-on bullet in ${SKILL#$ROOT/}"
fi
# The lead-in of the parking report says the supervisor reads its first
# section; the 现状 paragraph said it relays it verbatim, which is also what
# the rule below the table no longer says (only an error park's items are
# relayed one by one). Both now say the same thing.
without 'the first section the supervisor relays verbatim' \
  'SKILL.md no longer says the supervisor relays every first section verbatim' "$SKILL"
has 'because find-next'\''s supervisor reads its first section and keeper reads the two machine-readable lines' \
  'SKILL.md: the parking report lead-in says the supervisor reads its first section' "$SKILL"
has 'so the first section the supervisor reads and the two machine-readable lines keeper reads are untouched' \
  'SKILL.md: the 现状 paragraph says the supervisor reads the first section, as its lead-in does' "$SKILL"
# An ops step's rollback line names this machine next to the remote host, as
# the Ops tickets section of SKILL.md does: a local ops ticket never leaves
# this machine, which the Brief template's own new entry says.
without '远端改了什么、怎么回滚' 'find-next: the rollback line of an ops step no longer names the remote host alone' "$FIND_NEXT"
count_at_least '远端或本机改了什么、怎么回滚' 2 'find-next: both sentences on an ops step result name this machine too' "$FIND_NEXT"
without '远端改了什么、怎么回滚' 'Brief template: the rollback line no longer names the remote host alone' "$BRIEF_FIND_NEXT"
has '报告里写清远端或本机改了什么、怎么回滚' 'Brief template: the rollback line of the ops section names this machine too' "$BRIEF_FIND_NEXT"

# --- README's find-next bullets and docs/ai-agents.md's last rule follow the rules of 规格 #58 (r3: 主审补记 10、11) ---

# Two README sentences, older than 规格 #58, had been turned into wrong ones by
# its rules: the rest of a task ticket is no longer a checklist for the user —
# its steps go to a worker, the ops ones behind guardrails, and only identity,
# credentials or a physical action stay with the user — and the combined round
# is a decision round that reports and waits for no reply, after which the
# tracker is written. The intent is the same as the group above that keeps the
# user documents from calling the decision round a question round.
without 'a checklist for the rest' 'README no longer makes the rest of a task ticket a checklist for the user' "$ROOT/README.md"
has 'its steps go to a worker, the ops ones behind guardrails; only what needs your own identity, credentials or physical action becomes a checklist for you' \
  'README: the steps of a task ticket go to a worker, only identity, credentials or a physical action to the user' "$ROOT/README.md"
without 'all tracker writes wait for the combined round' 'README no longer says the tracker writes wait for the combined round' "$ROOT/README.md"
has 'decided in the combined decision round — a report that waits for no reply — and written to the tracker only after it has decided them' \
  'README: loose-ticket choices are decided by the round, which reports and waits for no reply' "$ROOT/README.md"
# docs/ai-agents.md still told every agent to ask before pushing, closing or
# publishing, while unattended landing — which asks nobody — has been the
# default since 规格 #58. The rule now names the Runs that keep their
# confirmations.
without '- Ask the user before pushing, closing issues, or publishing anything.' \
  'docs/ai-agents.md no longer tells every Run to ask before pushing' "$ROOT/docs/ai-agents.md"
has 'one started by typing `/implement-spec-split <n>` without `--auto-land`, or a Run of a batch started with `--no-auto-land`' \
  'docs/ai-agents.md keeps the confirmations to a typed Run and a --no-auto-land batch' "$ROOT/docs/ai-agents.md"
has 'An unattended Run that `launch-wave.sh` started — the default, with `--auto-land` — does not ask' \
  'docs/ai-agents.md says an unattended Run started by launch-wave does not ask' "$ROOT/docs/ai-agents.md"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
