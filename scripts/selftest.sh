#!/usr/bin/env bash
# Self-test for the External worker path (L1 + L2 in MAINTAINING.md).
#
#   L1  connectivity: pi can reach GLM with the configured key and model.
#   L2  pi-worker.sh: implements a tiny ticket in a git worktree with the tdd skill,
#       leaves commits and a clean tree, keeps its run artifacts; a Time-limited run is
#       Resumed from its run dir (segments = 2); a bad Resume (no saved state, or a saved
#       state whose pi session file is gone) exits 64; Time limit, Idle timeout, kills of
#       pi (only the watchdog's Time-limit kill is Resumable; killing pi also kills its
#       tool children) and auth failures are all exercised, the deterministic ones via a
#       fake pi behind the PI_WORKER_PI hook.
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
  --model "$MODEL" --time-limit 120 --idle-timeout 30 --retries 0 > /dev/null
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
  --model "$MODEL" --time-limit 900 --idle-timeout 120 ${TDD_SKILL:+--skill "$TDD_SKILL"} > /dev/null
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

# ---------- L2 Time limit ----------
echo "L2 time limit"
git -C "$REPO" worktree add -q "$ROOT/wt-timeout" -b timeout integration
printf 'Write a 3000-word essay about git into essay.md, one paragraph at a time, re-reading the file after each paragraph.\n' > "$ROOT/to.brief"
T0=$(date +%s)
"$WORKER" --cwd "$ROOT/wt-timeout" --brief "$ROOT/to.brief" --run-dir "$ROOT/to-run" \
  --model "$MODEL" --time-limit 15 --idle-timeout 60 > /dev/null
TO=$?
T1=$(date +%s)
check "time limit exit code 5 (got $TO)" test "$TO" -eq 5
check "status timeout (Time limit reached)" test "$(json "$ROOT/to-run/status.json" status)" = timeout
check "killed promptly ($((T1 - T0))s)" test "$((T1 - T0))" -lt 90

# ---------- L2 Time limit + Resume (GLOSSARY.md: Resume) ----------
echo "L2 resume"
git -C "$REPO" worktree add -q "$ROOT/wt-resume" -b ticket-2 integration
cat > "$ROOT/rs.brief" <<'EOF'
# Ticket 2: add a `str` helper module

You are an implementer working in a git worktree on branch `ticket-2`, based on `integration`.

## Requirements
`str.js` exports four helpers, each with tests in `str.test.js` (`node:test` + `node:assert`):
1. `initials(name)`: uppercase first letter of each word ("ada lovelace" -> "AL").
2. `truncate(s, n)`: at most `n` characters, with "..." appended when cut ("hello", 3 -> "hel...").
3. `slug(s)`: lowercase words joined by single hyphens, other characters dropped ("Hello, World!" -> "hello-world").
4. `pluralize(n, word)`: "1 item" / "2 items".

## How to work
- Use the tdd skill (red-green-refactor): one helper at a time, test first.
- Run the tests with `npm test`; they must pass.
- Commit your work on the current branch with a clear message. Leave no uncommitted changes.
- Do not touch any other branch and do not push.

## Report (final message)
Files changed, test command and result, anything you could not do.
EOF
RS_BASE=$(git -C "$ROOT/wt-resume" rev-parse HEAD)
"$WORKER" --cwd "$ROOT/wt-resume" --brief "$ROOT/rs.brief" --run-dir "$ROOT/rs-run" \
  --model "$MODEL" --time-limit 15 --idle-timeout 300 ${TDD_SKILL:+--skill "$TDD_SKILL"} > /dev/null
RS1=$?
S_RS="$ROOT/rs-run/status.json"
check "resume: segment 1 stops at the Time limit (exit 5, got $RS1)" test "$RS1" -eq 5
check "resume: segment 1 status timeout (Time limit reached)" test "$(json "$S_RS" status)" = timeout
check "resume: segment 1 saved Resume state" test -s "$ROOT/rs-run/resume.json"
check "resume: segment 1 segments = 1" test "$(json "$S_RS" segments)" = 1
EV1=$(wc -l < "$ROOT/rs-run/events.jsonl" | tr -d ' ')
"$WORKER" --resume --run-dir "$ROOT/rs-run" --time-limit 1200 --idle-timeout 120 > /dev/null
RS2=$?
check "resume: segment 2 finishes without --cwd/--brief/--model/--skill (exit 0, got $RS2)" test "$RS2" -eq 0
check "resume: status ok" test "$(json "$S_RS" status)" = ok
check "resume: segments = 2" test "$(json "$S_RS" segments)" = 2
check "resume: same pi session across segments" test "$(json "$S_RS" session_id)" = "$(json "$ROOT/rs-run/resume.json" session_id)"
RS_NEW=$(git -C "$ROOT/wt-resume" rev-list --count "$RS_BASE..HEAD")
check "resume: new_commits counted from the first segment's base head ($RS_NEW)" test "$(json "$S_RS" new_commits)" = "$RS_NEW"
check "resume: at least one new commit" test "$RS_NEW" -ge 1
check "resume: worktree clean" test "$(json "$S_RS" dirty)" = false
check "resume: str.js exists" test -f "$ROOT/wt-resume/str.js"
check "resume: tests pass when re-run by us" bash -c "cd '$ROOT/wt-resume' && node --test"
check "resume: result.md non-empty" test -s "$ROOT/rs-run/result.md"
check "resume: events accumulated across segments" bash -c "[ \$(wc -l < '$ROOT/rs-run/events.jsonl' | tr -d ' ') -gt $EV1 ]"
check "resume: segment 2 added a new attempt file" test -f "$ROOT/rs-run/attempt-2.jsonl"

# ---------- L2 bad Resume: usage error, never a fresh session (no pi needed) ----------
echo "L2 bad resume"
mkdir -p "$ROOT/bad-run"
"$WORKER" --resume --run-dir "$ROOT/bad-run" > /dev/null 2>&1
BR1=$?
check "bad resume: no saved state exits 64 (got $BR1)" test "$BR1" -eq 64
check "bad resume: no run artifacts created" bash -c "! ls '$ROOT/bad-run/events.jsonl' '$ROOT/bad-run/status.json' >/dev/null 2>&1"
"$WORKER" --resume --run-dir "$ROOT/no-such-run" > /dev/null 2>&1
BR2=$?
check "bad resume: missing run dir exits 64 (got $BR2)" test "$BR2" -eq 64
"$WORKER" --resume --run-dir "$ROOT/l2-run" --cwd "$ROOT/l1" > /dev/null 2>&1
BR3=$?
check "bad resume: --cwd rejected on a Resume (got $BR3)" test "$BR3" -eq 64
# Saved state whose pi session file is gone: exit 64, never a fresh session (no pi needed).
# pi itself would only warn and then start a FRESH session with the same id, so the
# wrapper must refuse; the fake pi proves it was never launched (no marker file).
LOST="$ROOT/lost-run"
mkdir -p "$LOST/sessions"
cat > "$LOST/resume.json" <<EOF
{
  "cwd": "$(cygpath -m "$ROOT/l1")",
  "model": "$MODEL",
  "skills": [],
  "thinking": "",
  "session_id": "11111111-2222-3333-4444-555555555555",
  "base_head": "",
  "segments": 1,
  "attempts": 1
}
EOF
FAKE_PI_MARKER="$ROOT/fake-pi-marker.sh"
printf '#!/usr/bin/env bash\n# Fake pi: leaves a marker so the test can see it ran.\necho started > "%s"\n' "$ROOT/pi-ran.marker" > "$FAKE_PI_MARKER"
chmod +x "$FAKE_PI_MARKER"
PI_WORKER_PI="$FAKE_PI_MARKER" "$WORKER" --resume --run-dir "$LOST" --time-limit 60 --idle-timeout 30 > /dev/null 2>&1
BR4=$?
check "bad resume: session file gone exits 64 (got $BR4)" test "$BR4" -eq 64
check "bad resume: no pi started for the lost session" bash -c "! test -f '$ROOT/pi-ran.marker'"

# ---------- L2 non-watchdog kill: `error`, not Resumable (PI_WORKER_PI hook) ----------
echo "L2 external kill"
FAKE_PI_KILL="$ROOT/fake-pi-kill.sh"
printf '#!/usr/bin/env bash\n# Fake pi: dies by SIGKILL, like an external OOM killer (exit 137), no events.\nkill -9 $$\n' > "$FAKE_PI_KILL"
chmod +x "$FAKE_PI_KILL"
PI_WORKER_PI="$FAKE_PI_KILL" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/kill-run" \
  --time-limit 60 --idle-timeout 30 --retries 0 > /dev/null
KILL=$?
check "external kill: exit 6, not Resumable timeout (got $KILL)" test "$KILL" -eq 6
check "external kill: status error" test "$(json "$ROOT/kill-run/status.json" status)" = error

# ---------- L2 Time limit spans a segment's retries (PI_WORKER_PI hook) ----------
echo "L2 segment time limit"
FAKE_PI_429="$ROOT/fake-pi-429.sh"
cat > "$FAKE_PI_429" <<'EOF'
#!/usr/bin/env bash
# Fake pi: always fails fast with a transient (429) API error.
echo '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"429 rate limit exceeded"}}'
EOF
chmod +x "$FAKE_PI_429"
# With retries=2, retry-wait=4 and time-limit=8: attempt 1 and its 4s wait, attempt 2 and
# its 8s wait burn the segment budget; the third attempt must not run. A per-attempt
# Time limit would let attempt 3 run and end as transient (exit 4).
PI_WORKER_PI="$FAKE_PI_429" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/seg-run" \
  --time-limit 8 --idle-timeout 60 --retries 2 --retry-wait 4 > /dev/null
SEG=$?
check "segment time limit: exit 5 (got $SEG)" test "$SEG" -eq 5
check "segment time limit: status timeout" test "$(json "$ROOT/seg-run/status.json" status)" = timeout
check "segment time limit: two attempts only" test "$(json "$ROOT/seg-run/status.json" attempts)" -eq 2
check "segment time limit: third attempt never ran" bash -c "! test -s '$ROOT/seg-run/attempt-3.jsonl'"

# ---------- L2 Idle timeout: deterministic, no GLM involvement (PI_WORKER_PI hook) ----------
echo "L2 idle"
FAKE_PI="$ROOT/fake-pi.sh"
printf '#!/usr/bin/env bash\n# Fake pi: accepts any arguments, produces no events, just sleeps far past the Time limit.\nsleep 300\n' > "$FAKE_PI"
chmod +x "$FAKE_PI"
T0=$(date +%s)
PI_WORKER_PI="$FAKE_PI" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/idle-run" \
  --model "$MODEL" --time-limit 120 --idle-timeout 6 > /dev/null
IDLE=$?
T1=$(date +%s)
check "idle exit code 7 (got $IDLE)" test "$IDLE" -eq 7
check "status stalled" test "$(json "$ROOT/idle-run/status.json" status)" = stalled
check "stopped well before the Time limit ($((T1 - T0))s < 120s)" test "$((T1 - T0))" -lt 120

# ---------- L2 killing pi kills its tool children (tree kill) ----------
echo "L2 kill tree"
FAKE_PI_TREE="$ROOT/fake-pi-tree.sh"
# The fake pi is an MSYS bash (like pi's bash tool) whose child is a native node (like
# `npm test`): an MSYS `kill` of pi orphans it; the wrapper must kill the whole tree.
printf '#!/usr/bin/env bash\n# Fake pi: runs a native tool child, produces no events.\nnode -e "setTimeout(()=>{},300000)" &\n[ -r /proc/$!/winpid ] && cat /proc/$!/winpid > "%s"\nsleep 300\n' "$ROOT/tree-child.pid" > "$FAKE_PI_TREE"
chmod +x "$FAKE_PI_TREE"
PI_WORKER_PI="$FAKE_PI_TREE" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/tree-run" \
  --time-limit 120 --idle-timeout 6 > /dev/null
TREE=$?
check "kill tree: exit 7 (got $TREE)" test "$TREE" -eq 7
TREE_CHILD=$(cat "$ROOT/tree-child.pid" 2>/dev/null)
if command -v taskkill >/dev/null 2>&1 && [ -n "$TREE_CHILD" ]; then
  TREE_ALIVE=1
  for _ in 1 2 3 4 5; do
    tasklist //FI "PID eq $TREE_CHILD" 2>/dev/null | grep -qi "node.exe" || { TREE_ALIVE=0; break; }
    sleep 2
  done
  check "kill tree: tool child killed with pi (winpid $TREE_CHILD)" test "$TREE_ALIVE" -eq 0
else
  echo "  SKIP kill tree: tool child (no taskkill on this platform; fallback kill path)"
fi

# ---------- L2 auth failure ----------
echo "L2 auth"
PI_WORKER_API_KEY="invalid-selftest-key" "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" \
  --run-dir "$ROOT/auth-run" --model "$MODEL" --time-limit 120 --idle-timeout 30 > /dev/null
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
