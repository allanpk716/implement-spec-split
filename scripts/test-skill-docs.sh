#!/usr/bin/env bash
# Checks that the skill's prose says what spec #26 decided about dispatching the
# implementing roles (ticket #45), and no longer names what it retired. The
# other test-*.sh scripts check scripts; this one checks SKILL.md, the Ticket
# Brief template and the hooks README, so that a later edit cannot quietly
# bring the backend switch or the progress tabs back, or drop the one-command
# dispatch / wait / release / merge-ticket path, without a test going red.
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

for file in "$SKILL" "$BRIEF" "$HOOKS"; do
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
has 'find-next/templates/brief-implement.md' 'SKILL.md names the Ticket Brief template' "$SKILL"
has 'orca orchestration run-create' 'SKILL.md creates the Orca Run for Ticket workers' "$SKILL"
has 'WORKER_ALLOW_FLASH=1' 'SKILL.md lets the flash session run the headless exploration' "$SKILL"
has '--mcp-config' 'SKILL.md adds MCP through --mcp-config for ops tickets' "$SKILL"
has '## 护栏' 'SKILL.md copies the guardrails into the Brief' "$SKILL"
has 'read_only_violation' 'SKILL.md gates the exploration on the read-only check' "$SKILL"
has 'never optional' 'the exploration is no longer optional' "$SKILL"
has 'close-self.sh' 'SKILL.md still closes the session with close-self' "$SKILL"
# Step 7 in a non-flash session is unchanged: the code-review skill on REVIEW_MODEL.
has 'mattpocock-skills:code-review' 'step 7 still calls the code-review skill' "$SKILL"
has 'model: REVIEW_MODEL' 'step 7 still sets the review model' "$SKILL"
# The three script checks of the verification gate.
has 'new commits' 'the gate checks new commits' "$SKILL"
has 'a clean tree' 'the gate checks a clean tree' "$SKILL"
has "merger script's test run passes" 'the gate checks the merger script test run' "$SKILL"

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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
