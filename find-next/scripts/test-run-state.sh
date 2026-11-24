#!/usr/bin/env bash
# Isolated tests for find-next/scripts/run-state.sh. Temporary directories are
# retained on pass and failure as debugging aids; nothing touches ~/.cache.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/run-state.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/run-state-test.XXXXXX")
RUNS=$WORK/runs
REPO_DIR=$WORK/my-repo
OTHER_DIR=$WORK/other-repo
PASSED=0
FAILED=0

mkdir -p "$RUNS" "$REPO_DIR" "$OTHER_DIR" || exit 1
REPO_REAL=$(cd "$REPO_DIR" && pwd -P)

record() {
  if [ "$1" = PASS ]; then
    printf 'PASS %s\n' "$2"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$2" "${3:+: $3}"
    FAILED=$((FAILED + 1))
  fi
}

expect_has() {
  if grep -Fq -- "$1" "$3"; then record PASS "$2"; else record FAIL "$2" "missing [$1]"; fi
}

expect_without() {
  if grep -Fq -- "$1" "$3"; then record FAIL "$2" "unexpected [$1]"; else record PASS "$2"; fi
}

expect_json() {
  # expect_json <name> <file> <node expression over `data` that must be true>
  if DATA_FILE="$2" EXPR="$3" node -e '
    const data = JSON.parse(require("fs").readFileSync(process.env.DATA_FILE, "utf8"));
    const ok = new Function("data", `return (${process.env.EXPR});`)(data);
    process.exit(ok ? 0 : 1);
  '; then
    record PASS "$1"
  else
    record FAIL "$1" "expression false: $3"
  fi
}

pending() {
  "$SCRIPT" pending --repo me/my-repo --repo-path "$REPO_DIR" --runs-root "$RUNS" "$@"
}

# A long-lived process stands in for a live owner; a finished one for a dead owner.
sleep 600 &
LIVE_PID=$!
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID"
trap 'kill "$LIVE_PID" 2>/dev/null' EXIT

# --- init / step / finish -------------------------------------------------
RUN_A=$RUNS/my-repo-20261124-1000-find-next-advance
mkdir -p "$RUN_A"
ISS_OWNER_PID=$LIVE_PID "$SCRIPT" init "$RUN_A" --repo me/my-repo --repo-path "$REPO_DIR"
if [ $? -eq 0 ]; then record PASS "init succeeds"; else record FAIL "init succeeds"; fi
expect_json "init writes the state fields" "$RUN_A/run-state.json" \
  "data.version === 1 && data.repo === 'me/my-repo' && data.repo_path === '$REPO_REAL' && data.owner_pid === $LIVE_PID && data.owner_pid_start !== '' && data.step === '1' && data.finished_at === null"
"$SCRIPT" step "$RUN_A" 5
expect_json "step records the step" "$RUN_A/run-state.json" "data.step === '5'"

pending > "$WORK/live.out"
expect_without "$RUN_A" "run with a live owner is not pending" "$WORK/live.out"

"$SCRIPT" finish "$RUN_A" --aborted "测试终止"
expect_json "finish records finished_at and reason" "$RUN_A/run-state.json" \
  "typeof data.finished_at === 'string' && data.aborted === '测试终止'"

# --- new-style runs: dead owner pending, finished not ------------------------
RUN_B=$RUNS/my-repo-20261124-1100-find-next-advance
mkdir -p "$RUN_B/decision-42" "$RUN_B/loose-373" "$RUN_B/loose-373-retry" "$RUN_B/research-7" "$RUN_B/S1" "$RUN_B/S2"
ISS_OWNER_PID=$DEAD_PID "$SCRIPT" init "$RUN_B" --repo me/my-repo --repo-path "$REPO_DIR" 2>/dev/null ||
  ISS_OWNER_PID=$LIVE_PID "$SCRIPT" init "$RUN_B" --repo me/my-repo --repo-path "$REPO_DIR"
# Force a dead owner regardless of how init resolved the start time.
node -e '
  const fs = require("fs"); const f = process.argv[1];
  const v = JSON.parse(fs.readFileSync(f, "utf8"));
  v.owner_pid = Number(process.argv[2]); v.owner_pid_start = "Mon Jan  1 00:00:00 2001";
  fs.writeFileSync(f, JSON.stringify(v));
' "$RUN_B/run-state.json" "$DEAD_PID"
printf 'brief\n' > "$RUN_B/decision-42/brief.md"
printf 'result\n' > "$RUN_B/decision-42/result.md"
printf 'decision\n' > "$RUN_B/decision-42/decision.md"
printf 'brief\n' > "$RUN_B/loose-373/brief.md"
printf 'result\n' > "$RUN_B/loose-373/result.md"
printf 'triage\n' > "$RUN_B/loose-373/triage.md"
printf 'brief\n' > "$RUN_B/loose-373-retry/brief.md"
printf 'brief\n' > "$RUN_B/research-7/brief.md"
# S1: published halfway (ticket T2 and its dependency missing).
printf '{"key":"S1","tickets":[{"key":"T1","blocked_by":[]},{"key":"T2","blocked_by":["T1"]}],"handoffs":[]}\n' \
  > "$RUN_B/S1/manifest.json"
printf 'spec\n' > "$RUN_B/S1/spec.md"
printf '{"issues":{"S1":{"number":10},"T1":{"number":11}},"relations":["sub:S1/T1"],"handoffs":[]}\n' \
  > "$RUN_B/S1/published.json"
# S2: fully published.
printf '{"key":"S2","tickets":[{"key":"T1","blocked_by":[]}],"handoffs":[]}\n' > "$RUN_B/S2/manifest.json"
printf '{"issues":{"S2":{"number":20},"T1":{"number":21}},"relations":["sub:S2/T1"],"handoffs":[]}\n' \
  > "$RUN_B/S2/published.json"

RUN_C=$RUNS/my-repo-20261124-1200-find-next-advance
mkdir -p "$RUN_C"
ISS_OWNER_PID=$LIVE_PID "$SCRIPT" init "$RUN_C" --repo me/my-repo --repo-path "$REPO_DIR"
"$SCRIPT" finish "$RUN_C"

RUN_OTHER=$RUNS/other-20261124-1200-find-next-advance
mkdir -p "$RUN_OTHER"
ISS_OWNER_PID=$LIVE_PID "$SCRIPT" init "$RUN_OTHER" --repo me/other-repo --repo-path "$OTHER_DIR"
node -e '
  const fs = require("fs"); const f = process.argv[1];
  const v = JSON.parse(fs.readFileSync(f, "utf8")); v.owner_pid_start = "dead"; fs.writeFileSync(f, JSON.stringify(v));
' "$RUN_OTHER/run-state.json"

# --- legacy runs -------------------------------------------------------------
LEGACY=$RUNS/worktree-name-20261124-1049-find-next-advance
mkdir -p "$LEGACY/loose-9"
printf 'repo: %s\n' "$REPO_REAL" > "$LEGACY/loose-9/brief.md"
printf 'scan\n' > "$LEGACY/scan-1.txt"
printf 'note for S1\n' > "$LEGACY/note-S1.md"

LEGACY_OLD=$RUNS/my-repo-20261101-0900-find-next-advance
mkdir -p "$LEGACY_OLD/loose-5"
printf 'me/my-repo\n' > "$LEGACY_OLD/loose-5/brief.md"
touch -t 202611010900 "$LEGACY_OLD"

LEGACY_OTHER=$RUNS/other-repo-20261124-1000-find-next-advance
mkdir -p "$LEGACY_OTHER/loose-6"
printf 'me/other-repo\n' > "$LEGACY_OTHER/loose-6/brief.md"

LEGACY_DONE=$RUNS/my-repo-20261123-0900-find-next-advance
mkdir -p "$LEGACY_DONE/S1"
printf '{"key":"S1","tickets":[{"key":"T1","blocked_by":[]}],"handoffs":[]}\n' > "$LEGACY_DONE/S1/manifest.json"
printf '{"issues":{"S1":{"number":30},"T1":{"number":31}},"relations":["sub:S1/T1"],"handoffs":[]}\n' \
  > "$LEGACY_DONE/S1/published.json"
printf 'me/my-repo\n' > "$LEGACY_DONE/S1/brief.md"

WORKER_RUN=$RUNS/my-repo-20261124-0900-find-next-worker
mkdir -p "$WORKER_RUN"
printf 'me/my-repo\n' > "$WORKER_RUN/brief.md"
printf '{}\n' > "$WORKER_RUN/events.jsonl"

pending > "$WORK/pending.out"
pending --json > "$WORK/pending.json"
cat "$WORK/pending.out"

expect_has "$RUN_B" "new-style run with a dead owner is pending" "$WORK/pending.out"
expect_without "$RUN_A" "aborted run is not pending" "$WORK/pending.out"
expect_without "$RUN_C" "finished run is not pending" "$WORK/pending.out"
expect_without "$RUN_OTHER" "another repository's run is not pending" "$WORK/pending.out"
expect_has "$LEGACY" "legacy run matched by repository path is pending" "$WORK/pending.out"
expect_has "旧版运行（无状态文件）" "legacy run is labelled" "$WORK/pending.out"
expect_without "$LEGACY_OLD" "legacy run older than 7 days is not pending" "$WORK/pending.out"
expect_without "$LEGACY_OTHER" "another repository's legacy run is not pending" "$WORK/pending.out"
expect_without "$LEGACY_DONE" "legacy run with only fully published specs is not pending" "$WORK/pending.out"
expect_without "$WORKER_RUN" "worker run directory is not an advance run" "$WORK/pending.out"

expect_has "loose #373：result.md" "ticket output with result is reported" "$WORK/pending.out"
expect_has "尝试 loose-373、loose-373-retry" "retry directory merges into the same ticket" "$WORK/pending.out"
expect_has "research #7：未产出（只有 brief.md）" "brief-only output is not produced" "$WORK/pending.out"
expect_has "S1：发布到一半" "half-published spec group is detected" "$WORK/pending.out"
expect_has "S2：已发布" "fully published spec group is detected" "$WORK/pending.out"
expect_has "S1：未发布 · 未产出（只有 note）" "legacy note-only spec group is reported" "$WORK/pending.out"

expect_json "JSON lists the expected runs" "$WORK/pending.json" \
  "data.repo === 'me/my-repo' && data.runs.length === 2"
expect_json "JSON merges retries and reports result mtime" "$WORK/pending.json" \
  "(() => { const run = data.runs.find((r) => !r.legacy); const o = run.outputs.find((x) => x.kind === 'loose' && x.ticket === 373); return o && o.has_result && o.result_mtime && o.attempts.length === 2; })()"
expect_json "JSON reports what a half-published group misses" "$WORK/pending.json" \
  "(() => { const run = data.runs.find((r) => !r.legacy); const o = run.outputs.find((x) => x.group === 'S1'); return o.published.exists && !o.published.complete && o.published.missing.includes('T2') && o.published.missing.some((m) => m.startsWith('sub:S1/T2')); })()"

# --- abandon ---------------------------------------------------------------
"$SCRIPT" abandon "$RUN_B"
"$SCRIPT" abandon "$LEGACY" --repo me/my-repo --repo-path "$REPO_DIR"
expect_json "abandon finishes a new-style run" "$RUN_B/run-state.json" \
  "typeof data.finished_at === 'string' && data.aborted === 'abandoned-by-later-run'"
expect_json "abandon writes a minimal state for a legacy run" "$LEGACY/run-state.json" \
  "data.repo === 'me/my-repo' && typeof data.finished_at === 'string' && data.aborted === 'abandoned-by-later-run'"
pending > "$WORK/after.out"
expect_has "（无）" "abandoned runs are no longer pending" "$WORK/after.out"

printf 'Summary: %s passed, %s failed (work dir %s)\n' "$PASSED" "$FAILED" "$WORK"
[ "$FAILED" -eq 0 ]
