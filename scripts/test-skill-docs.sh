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
# section the three root Brief templates share verbatim with find-next's.
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
# an option that needs the owner's own hands (Spec 7, trade-off 3 = A).
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

count_at_least() { # text n name file -- a rule several places must each carry
  local n
  n=$(grep -Fo -- "$1" "$4" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge "$2" ]; then ok "$3"; else bad "$3" "expected at least $2 occurrences of [$1] in ${4#$ROOT/}, found $n"; fi
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
has '等人工票 #<t>' 'GLOSSARY: the landing report names the tickets left to a human' "$GLOSSARY"

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
# an item that needs the owner's identity (auth) or lists no reversible option
# (error) parks; an option that loosens a safety boundary is recorded under
# 未执行的放宽项 and never taken. The two marks stay the reviewer's wording, so
# the pins name the outcomes, not the marks.
has 'never parks the Run for being a trade-off' 'SKILL.md step 8 never parks on a trade-off' "$SKILL"
has 'pick a reversible option by 「可逆性高 > 改动面小 > 与现有 ADR 一致」' \
  'SKILL.md step 8 decides an item without a usable recommendation by the reversibility rule' "$SKILL"
has 'preferring the reviewer' 'SKILL.md step 8 prefers a recommendation that is reversible and not outward-facing' "$SKILL"
has 'parks with category `auth`' 'SKILL.md step 8 parks an item that needs the owner identity as auth' "$SKILL"
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
# action that needs the owner's identity; the two cases that had no category
# now have one (the landing lock after 2 hours → transient, opus-review exits
# other than 2 / 3 / 4 → error), and every non-zero opus-review exit names its
# category (test-opus-review.sh pins the whole sentence in SKILL.md and in
# find-next/SKILL.md alike).
has '停车类别：quota|transient|auth|error' 'the parking category line names the four categories left' "$SKILL"
without '停车类别：quota|transient|decision|error|other' 'the parking category line no longer names decision or other' "$SKILL"
has '| `auth` | 需要本人身份或凭据的操作：首次登录授权、付款、验证码 | `无` |' 'the parking category table has the auth row' "$SKILL"
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
# The hooks' reasons and the hooks README say the same (MAINTAINING 第 39 条).
has '`可自动采纳：否` 或 `推荐：无` 的按可逆性规则自选一个可逆选项并写理由' 'hooks README rule B names the reversibility rule' "$HOOKS"
has '（停车类别 `auth`）、或列出的选项里没有可逆的（停车类别 `error`）' 'hooks README rule B names the two categories that still park' "$HOOKS"

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
has '要本人身份或凭据的不选；放宽安全边界的选项一律不选，推荐是它的也不采纳；除它之外没有可选项的写『推荐：无』' \
  'flash mode writes the rule into the input of the selecting Opus review' "$FIND_NEXT"
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

# find-next's step 6 became a decision round (票 #69, MAINTAINING 第 54 条): the
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
  has "$text" "Brief template has [$text]" "$BRIEF"
done
without '不要 `git commit`' 'Brief template requires the worker to commit' "$BRIEF"

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
  has "$text" "Brief template names [$text]" "$BRIEF"
done
has '冒烟票例外：agent 驱动冒烟票的操作序列里，要开的 Orca 终端或会话是被测的操作本身，不算派发' \
  'Brief template rule 3 excepts the session a smoke ticket opens' "$BRIEF"
has '护栏点名了 `orca orchestration worker-start` 才能用，没点名仍禁止' \
  'Brief template keeps worker-start forbidden unless the guardrails name it' "$BRIEF"
has '删掉上面 ssh-manager 那一行' 'Brief template tells a local ops ticket to drop the ssh-manager line' "$BRIEF"
has '某一步只有放宽安全边界（护栏、hook、权限这类）才能做时不执行：把该项记进报告的「未执行的放宽项」，该条验收按「已记录」算过' \
  'Brief template records a loosening instead of taking the step' "$BRIEF"
has '5. **未执行的放宽项**：' 'Brief template report has the fifth item' "$BRIEF"

# --- the three root Brief templates carry the 环境约束 section verbatim (票 #60, 规格 #58)

# find-next/scripts/test-make-batch-briefs.sh checks that section over
# find-next/templates/*.md only, so nothing caught a root template (the Design
# session's Briefs) drifting from it. The section runs from its heading up to
# the next `## ` and is compared byte for byte, the blank lines included.
env_section() { # file
  awk '/^## 环境约束（找文件与子进程）$/ { section = 1; next }
       section && /^## / { section = 0 }
       section' "$1"
}
for template in templates/brief-implement.md templates/brief-investigate.md templates/brief-mock.md; do
  if ! grep -Fq -- '## 环境约束（找文件与子进程）' "$ROOT/$template"; then
    bad "$template has the 环境约束 section verbatim" "missing [## 环境约束（找文件与子进程）] in $template"
  elif cmp -s <(env_section "$ROOT/$template") <(env_section "$BRIEF"); then
    ok "$template has the 环境约束 section verbatim"
  else
    bad "$template has the 环境约束 section verbatim" "differs from find-next/templates/brief-implement.md in $template"
  fi
done

# --- hooks README ----------------------------------------------------------------

has '## 精简启动的 worker' 'hooks README documents the lean start' "$HOOKS"
has 'merge-ticket.sh' 'hooks README names the script gate' "$HOOKS"
has '--bare' 'hooks README says --bare loads no hooks' "$HOOKS"
has 'unattended-stop-guard' 'hooks README names the hooks a lean worker lacks' "$HOOKS"
# Rule A's reminder is step 10's sentence again: it carries the run directory too.
has 'close-self.sh --run-dir <Spec Run root>' 'hooks README rule A closes with the run directory' "$HOOKS"

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
has 'Opus 审查里的取舍不因是取舍而停车' 'find-next usage says a review trade-off never parks' "$FIND_NEXT"
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
# role's report parked the Run. Such an option is now listed under 要你做 and
# never picked, the same exception as find-next's step 6; the parking categories
# are not touched.
has "An option that needs the owner's own hands — a physical action the Run cannot carry out — is never picked either, whatever the rule above would pick: list it under 要你做 in the landing report and decide among the remaining options as above; when no option is left, the item parks by the two parking rules above." \
  "SKILL.md step 8 never picks an option that needs the owner's own hands" "$SKILL"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
