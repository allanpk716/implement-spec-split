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
# review of the re-bump and the conflict resolution, and every 9.1 round
# taking the next free --attempt.
#
# Usage: scripts/test-skill-docs.sh
# Exit code: the number of failed checks.
#
# Test hooks: none. Reads the repository's own files only.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL=$ROOT/SKILL.md
BRIEF=$ROOT/find-next/templates/brief-implement.md
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

for file in "$SKILL" "$BRIEF" "$HOOKS" "$GLOSSARY" "$FIND_NEXT" "$LIB_TRANSCRIPT" "$DELEGATE_GUARD"; do
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
has 'git ls-tree origin/<main branch>:docs/adr/' 'SKILL.md step 9.1 re-bump role reads main only' "$SKILL"
has 'the re-bump commits and the conflict resolution together' \
  'SKILL.md reviews the step 9.1 re-bump and the conflict resolution once' "$SKILL"
has 'shared counters collide (merger exit `6`) — dispatch a re-bump role' \
  'unattended landing dispatches a re-bump role on exit 6' "$SKILL"
has '**Step 9 conflicts and re-bumps**' 'flash mode covers the step 9 re-bump' "$SKILL"

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
  has "$text" "Brief template has [$text]" "$BRIEF"
done
without '不要 `git commit`' 'Brief template requires the worker to commit' "$BRIEF"

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
