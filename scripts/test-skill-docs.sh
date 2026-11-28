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

# --- the Ticket Brief template --------------------------------------------------

for text in 'worker_done' '--task-id' '## 护栏' '探索笔记' '规格内容' '票内容' \
  '不带规格会话的过程' '不写在工作区里' 'If a source-write hook blocks you' \
  'Run any `rm` as its own Bash command' 'mcp__ssh-manager__list_servers' \
  'templates/lean-rules.md' '调用关系' '--report-path'; do
  has "$text" "Brief template has [$text]" "$BRIEF"
done
without '不要 `git commit`' 'Brief template requires the worker to commit' "$BRIEF"

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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
