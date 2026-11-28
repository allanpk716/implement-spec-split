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
# fail-open wording. So is the merger's exit 6 wiring (规格 #61 票 #74 and the
# review fixes after it): the step 5 / 9.1 re-bump dispatch forms, the one
# review of the re-bump and the conflict resolution, every 9.1 round taking
# the next free --attempt, a failed-gate re-dispatch counting as a 9.1 round,
# the re-bump Brief named after its dispatch, the step 5 rerun reading exits 4
# and 1 from their own lines (one positive and one negative check), where a
# 9.1 rerun's 3 / 4 / 5 go, the 9.1 review trigger stated once and pointed to
# from Unattended landing and Flash mode, and the --attempt of a step 5
# re-dispatch and of 9.1's fix roles taken as the next free one. So are the two
# rules of ticket #79: tests and verification finish in the foreground before
# the final report (the Brief templates and the dispatch texts of steps 5, 8
# and 9.1), and a main session verifies a worker gone idle without a report
# itself (ps, git) instead of waiting again. Its review settled where each is
# written and pointed to, and that is pinned too: the rule once in step 5's
# `3` line and once in the section every find-next Brief template shares,
# Recovery's never-stop rule with that worker as its one exception, Orca's
# mail read by its body, and the evidence of such a worker in a file of its own.
# The re-review after that (r3) is pinned the same way: GLOSSARY defines the
# rule and the worker gone idle without a report; the Watchdog's `3` report on
# a live worker, and a `wait` that timed out, read the worker's last line first
# and hand item 6's case to item 6; item 6's evidence is written once, Recovery
# and the wait's mail only pointing to it; the PR path's fix role carries the
# rule; a conclusion's sources name session-verify.md in Flash mode and in the
# two setup documents; and the ticket number stays in the title of item 6 only.
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
has '停车类别：decision' 'the parking report keeps its category line' "$SKILL"
has '可恢复时间：无' 'the parking report keeps its recovery-time line' "$SKILL"
has '### 需要你决定' 'the parking report keeps its decision section' "$SKILL"
has '### 现状' 'the parking report keeps its status section' "$SKILL"
# A mismatch is a warning that holds nothing back.
has 'never held back' 'SKILL.md says a model mismatch never holds back the landing' "$SKILL"

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
# day the number of templates changes.
templates_with_rule=0
templates_total=0
templates_first=
for template in "$ROOT"/find-next/templates/*.md; do
  [ -f "${template}" ] || continue
  templates_total=$((templates_total + 1))
  [ -n "${templates_first}" ] || templates_first=${template}
  grep -Fq -- "${FOREGROUND_RULE_COMMON}" "$template" && templates_with_rule=$((templates_with_rule + 1))
done
if [ -n "${templates_first}" ] && [ "${templates_with_rule}" -eq "${templates_total}" ]; then
  ok "every find-next Brief template (${templates_total}) carries the rule in the section they share"
else
  bad "every find-next Brief template carries the rule in the section they share" \
    "${templates_with_rule} of ${templates_total} templates have [${FOREGROUND_RULE_COMMON}]"
fi
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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
