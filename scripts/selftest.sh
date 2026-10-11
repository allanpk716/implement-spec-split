#!/usr/bin/env bash
# Self-test for the External worker path (L1 + L2 in MAINTAINING.md).
#
#   L1  connectivity: pi can reach GLM with the configured key and model.
#   L2  pi-worker.sh: implements a tiny ticket in a git worktree with the tdd skill,
#       leaves commits and a clean tree, keeps its run artifacts; timeouts and auth
#       failures are classified correctly.
#
# Usage: scripts/selftest.sh [--model glm/glm-5.3] [--only L1]
# Scratch dir: ~/.cache/implement-spec-split-selftest/<timestamp>, deleted on success.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORKER="$HERE/pi-worker.sh"
MODEL="glm/glm-5.3"
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

TDD_SKILL=$(ls -d "$HOME"/.claude/plugins/cache/mattpocock/mattpocock-skills/*/skills/*/tdd 2>/dev/null | sort -V | tail -1)
ROOT="$HOME/.cache/implement-spec-split-selftest/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROOT"
FAILS=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
json() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s[process.argv[2]])' "$(cygpath -m "$1" 2>/dev/null || echo "$1")" "$2"; }

echo "scratch: $ROOT"
echo "model:   $MODEL"

# ---------- L1 ----------
echo "L1 connectivity"
mkdir -p "$ROOT/l1"
echo "Reply with exactly the word: ok. Do not use any tools." > "$ROOT/l1.brief"
"$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/l1-run" \
  --model "$MODEL" --timeout 120 --retries 0 > /dev/null
L1=$?
if [ "$L1" -eq 0 ]; then
  pass "pi answered on $MODEL"
else
  fail "pi on $MODEL: status=$(json "$ROOT/l1-run/status.json" status) error=$(json "$ROOT/l1-run/status.json" error)"
  echo "L1 failed; fix the key/model in ~/.pi/agent/models.json before L2. Scratch kept: $ROOT"
  exit 1
fi
if [ "$ONLY" = "L1" ]; then rm -rf "$ROOT"; echo "OK"; exit 0; fi

# ---------- L2 setup: a repo plus a ticket worktree, like the skill makes ----------
echo "L2 worker"
[ -n "$TDD_SKILL" ] || fail "mattpocock-skills tdd skill not found under ~/.claude/plugins/cache"
REPO="$ROOT/repo"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b main
  printf '{\n  "name": "selftest",\n  "private": true,\n  "scripts": { "test": "node --test" }\n}\n' > package.json
  printf 'node_modules/\n' > .gitignore
  printf '# selftest\n\nRun tests with `npm test` (node --test). Plain CommonJS, no dependencies.\n' > CLAUDE.md
  git add -A && git commit -q -m "init"
  git branch integration
  git worktree add -q ../wt-ticket-1 -b ticket-1 integration
)
WT="$ROOT/wt-ticket-1"
cat > "$ROOT/l2.brief" <<'EOF'
# Ticket 1: add a `clamp` helper

You are an implementer working in a git worktree on branch `ticket-1`, based on `integration`.

## Requirements
1. Create `clamp.js` exporting `clamp(value, min, max)`: returns `value` limited to the range [min, max].
2. Throw a `RangeError` when `min > max`.
3. Tests live in `clamp.test.js` and use `node:test` and `node:assert`.

## How to work
- Use the tdd skill (red-green-refactor).
- Run the tests with `npm test`; they must pass.
- Commit your work on the current branch with a clear message. Leave no uncommitted changes.
- Do not touch any other branch and do not push.

## Report (final message)
Files changed, test command and result, anything you could not do.
EOF

"$WORKER" --cwd "$WT" --brief "$ROOT/l2.brief" --run-dir "$ROOT/l2-run" \
  --model "$MODEL" --timeout 900 ${TDD_SKILL:+--skill "$TDD_SKILL"} > /dev/null
L2=$?
S="$ROOT/l2-run/status.json"
check "worker exit code 0 (got $L2)" test "$L2" -eq 0
check "status ok" test "$(json "$S" status)" = ok
check "new commits on ticket branch" test "$(json "$S" new_commits)" -ge 1
check "worktree clean" test "$(json "$S" dirty)" = false
check "commits landed on ticket-1, not main" test "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse integration)"
check "clamp.js exists" test -f "$WT/clamp.js"
check "tests pass when re-run by us" bash -c "cd '$WT' && node --test"
check "brief.md kept" test -s "$ROOT/l2-run/brief.md"
check "events.jsonl non-empty" test -s "$ROOT/l2-run/events.jsonl"
check "result.md non-empty" test -s "$ROOT/l2-run/result.md"
check "session file kept" bash -c "ls '$ROOT/l2-run/sessions/'*.jsonl"
check "tdd skill was read by the worker" node -e '
  const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const hit = lines.some(l => { try { const e = JSON.parse(l);
    return e.type === "tool_execution_start" && /tdd[\\/]+SKILL\.md/i.test(JSON.stringify(e.args)); } catch { return false; } });
  process.exit(hit ? 0 : 1);' "$(cygpath -m "$ROOT/l2-run/events.jsonl")"

# ---------- L2 timeout ----------
echo "L2 timeout"
git -C "$REPO" worktree add -q "$ROOT/wt-timeout" -b timeout integration
printf 'Write a 3000-word essay about git into essay.md, one paragraph at a time, re-reading the file after each paragraph.\n' > "$ROOT/to.brief"
T0=$(date +%s)
"$WORKER" --cwd "$ROOT/wt-timeout" --brief "$ROOT/to.brief" --run-dir "$ROOT/to-run" \
  --model "$MODEL" --timeout 15 > /dev/null
TO=$?
T1=$(date +%s)
check "timeout exit code 5 (got $TO)" test "$TO" -eq 5
check "status timeout" test "$(json "$ROOT/to-run/status.json" status)" = timeout
check "killed promptly ($((T1 - T0))s)" test "$((T1 - T0))" -lt 90

# ---------- L2 auth failure ----------
echo "L2 auth"
PI_WORKER_API_KEY="invalid-selftest-key" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" \
  --run-dir "$ROOT/auth-run" --model "$MODEL" --timeout 120 > /dev/null
AU=$?
check "auth exit code 2 (got $AU)" test "$AU" -eq 2
check "auth not retried" test "$(json "$ROOT/auth-run/status.json" attempts)" -eq 1

echo
if [ "$FAILS" -eq 0 ]; then
  git -C "$REPO" worktree prune
  rm -rf "$ROOT"
  echo "OK: all checks passed"
else
  echo "FAILED: $FAILS check(s). Scratch kept: $ROOT"
  exit 1
fi
