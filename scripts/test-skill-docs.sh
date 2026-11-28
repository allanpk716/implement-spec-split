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
# re-dispatch and of 9.1's fix roles taken as the next free one. So is 票 #78:
# step 5 always passing --close-ticket (closed on exit 0 only, without asking
# in every Run, a failed close retried once), step 9 running the landing check
# and reading its five sections and report lines, exit 2 ending in a parking
# with category error rather than a loop, and step 0 telling a loose source
# ticket (never dispatched, closed with its Spec) from a map implementation
# ticket.
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
# five it lists and the report lines it ends with. Exit 2 leads back to step 1,
# and an empty frontier with no implementing role alive leads back to the check
# and then to a parking with category error, never to a loop (the parking
# report names every Ticket under # open). A Ticket that waits is reported with
# the check's own line: the blocker may be a Spec, a standalone issue or a
# human Ticket.
has '<skill dir>/scripts/landing-check.sh --repo <owner/name> --spec <n>' \
  'SKILL.md step 9 runs the landing check' "$SKILL"
has "lists the Spec's open Tickets in five sections — \`# open\`, \`# waiting\`, \`# human\`, \`# shelved\`, \`# source\`" \
  'SKILL.md step 9 names the five sections of the landing check' "$SKILL"
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
has 'the `# report` lines go in the report as they are (`剩余：#<t> 等 #<spec>` for another Spec, `剩余：#<t> 等 #<issue>` for a standalone issue, `剩余：#<t> 等人工 #<t>` behind a human Ticket)' \
  'SKILL.md step 9 reports a waiting Ticket by what it waits for' "$SKILL"
without '`# waiting` goes in the report as `剩余：#<t> 等 #<spec>`' \
  'SKILL.md step 9 no longer reports a waiting Ticket as waiting for a Spec only' "$SKILL"
has '`# human` and `# shelved` go in the report too, a human Ticket under 要你做的' \
  'SKILL.md step 9 sends a human Ticket to 要你做的' "$SKILL"
has 'the Tickets the merger closed as they merged (step 5) were never asked about' \
  'SKILL.md step 9 keeps its confirmation for the Spec and the Tickets merged without being closed' "$SKILL"
has 'and a loose source ticket (step 0, rule 2b), which no merger ever closed, since nothing is dispatched for it' \
  'SKILL.md step 9 closes the loose source ticket with the Spec' "$SKILL"

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

# Both reports take the check's lines: the parking report's 现状 pastes # open
# and # report, and the landing report and the final 结论 carry the `剩余：`
# lines whatever the Ticket waits for, after a partial landing and after a
# parking alike.
has '<when the Run parks on the landing check (step 9): every line of its `# open` and `# report` sections, as they are>' \
  'the parking report carries the lines of the landing check' "$SKILL"
has 'the `# report` lines of the landing check, as they are (`剩余：#<t> 等 #<spec>`, `剩余：#<t> 等 #<issue>` or `剩余：#<t> 等人工 #<t>`, one line each; omit when it printed none)' \
  'the landing report carries the lines of the landing check' "$SKILL"
has "then the landing check's \`# report\` lines whenever a Ticket is still open" \
  'the final report carries the lines of the landing check' "$SKILL"
without 'partially landed with `剩余：#<t> 等 #<spec>`' \
  'the final report no longer names one form for what is left' "$SKILL"

# The vocabulary and the operating rules follow.
has '**Loose source ticket**:' 'GLOSSARY defines Loose source ticket' "$GLOSSARY"
has 'every Run does that without asking, `--auto-land` or not (2026-11-28, 票 #78)' \
  'GLOSSARY excludes the merger closing a merged Ticket from Unattended landing' "$GLOSSARY"
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
