#!/usr/bin/env bash
# Isolated fake-dependency tests for scripts/keeper.sh.
# No network, no Orca, no launchd: gh, orca, claim.sh, launch-wave.sh and lock.sh
# are fakes injected through PATH and KEEPER_* environment variables.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/keeper.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/keeper-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

BIN=$WORK/bin
REPO_PATH=$WORK/repo
WT=$WORK/wt/spec-19
PASSED=0
FAILED=0
RUN_EXIT=

record() {
  status=$1
  name=$2
  detail=${3:-}
  if [ "$status" = PASS ]; then
    printf 'PASS %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$name" "${detail:+: $detail}"
    FAILED=$((FAILED + 1))
  fi
}

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_has() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    record PASS "$2"
  else
    record FAIL "$2" "missing [$1]; $(tail -n 5 "$3" 2>/dev/null)"
  fi
}

expect_without() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    record FAIL "$2" "unexpected [$1]"
  else
    record PASS "$2"
  fi
}

expect_count() { # pattern expected name file
  actual=$(grep -Fc -- "$1" "$4" 2>/dev/null || true)
  if [ "$actual" -eq "$2" ]; then
    record PASS "$3"
  else
    record FAIL "$3" "count=$actual, expected=$2"
  fi
}

expect_file() {
  if [ -e "$1" ]; then record PASS "$2"; else record FAIL "$2" "missing [$1]"; fi
}

expect_no_file() {
  if [ -e "$1" ]; then record FAIL "$2" "unexpected [$1]"; else record PASS "$2"; fi
}

epoch_iso() { # offset seconds -> ISO 8601 with Z
  OFFSET=$1 node -e 'process.stdout.write(new Date(Date.now() + Number(process.env.OFFSET) * 1000).toISOString())'
}

epoch_at() { # offset seconds -> epoch seconds
  OFFSET=$1 node -e 'process.stdout.write(String(Math.floor(Date.now() / 1000) + Number(process.env.OFFSET)))'
}

set_mtime() { # path epoch-seconds
  MTIME_FILE=$1 MTIME_EPOCH=$2 node -e '
    const fs = require("fs");
    const when = Number(process.env.MTIME_EPOCH);
    fs.utimesSync(process.env.MTIME_FILE, when, when);
  '
}

encoded_path() { # same encoding keeper.sh uses for ~/.claude/projects
  printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g'
}

mkdir -p "$BIN" "$WORK/home" "$WORK/projects" "$WORK/runs" "$WORK/codex-runs" \
  "$WORK/launch-state" "$WT" 2>/dev/null || exit 1

git init -q "$REPO_PATH" 2>/dev/null || exit 1
git -C "$REPO_PATH" -c user.email=keeper@test -c user.name=keeper \
  commit -q --allow-empty -m init 2>/dev/null || exit 1

# --- fakes -------------------------------------------------------------------

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$GH_LOG"
case "${1:-}" in
  issue)
    cat "$FIXTURE_DIR/issues.json"
    exit 0
    ;;
  api)
    if [ -f "$FIXTURE_DIR/gh-fail" ]; then
      printf 'gh: rate limited\n' >&2
      exit 1
    fi
    n=$(printf '%s' "$2" | sed -E 's#.*/issues/([0-9]+)/comments#\1#')
    file="$FIXTURE_DIR/comments-$n.json"
    if [ -f "$file" ]; then cat "$file"; else printf '[]'; fi
    exit 0
    ;;
esac
printf 'fake gh: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF

cat >"$BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "repo list")
    cat "$FIXTURE_DIR/orca-repos.json" 2>/dev/null || printf '{"ok":true,"result":{"repos":[]}}'
    exit 0
    ;;
  "terminal list")
    if [ -f "$FIXTURE_DIR/terminals.json" ]; then
      cat "$FIXTURE_DIR/terminals.json"
    else
      printf '{"ok":true,"result":{"terminals":[]}}'
    fi
    exit 0
    ;;
  "terminal send"|"terminal close")
    printf '%s\n' "$*" >>"$ORCA_LOG"
    exit 0
    ;;
esac
printf 'fake orca: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF

cat >"$BIN/claim.sh" <<'EOF'
#!/usr/bin/env bash
set -u
command=${1:-}
spec=${2:-}
case "$command" in
  status)
    line=$(awk -F'\t' -v n="$spec" '$1 == n { line = $2 " " $3 } END { if (line) print line }' "$FIXTURE_DIR/claims.txt" 2>/dev/null)
    if [ -n "$line" ]; then printf '%s\n' "$line"; else printf 'free\n'; fi
    exit 0
    ;;
  release)
    printf '%s\n' "$*" >>"$CLAIM_LOG"
    exit 0
    ;;
esac
printf 'fake claim: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF

cat >"$BIN/launch-wave.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$LAUNCH_LOG"
if [ -f "$FIXTURE_DIR/launch-fail" ]; then
  printf 'launch-wave: boom\n' >&2
  exit 1
fi
printf '#launched\n'
# a real launch reserves the claim, so status becomes active
launched_spec=$(printf '%s' "$*" | sed -E 's#.*--only ([0-9]+).*#\1#')
printf '%s\tactive\t{"spec":%s,"handoff":"fresh"}\n' "$launched_spec" "$launched_spec" >>"$FIXTURE_DIR/claims.txt"
exit 0
EOF

cat >"$BIN/lock.sh" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  acquire)
    [ -f "$FIXTURE_DIR/lock-held" ] && exit 2
    exit 0
    ;;
  release)
    exit 0
    ;;
esac
printf 'fake lock: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF

chmod +x "$BIN/gh" "$BIN/orca" "$BIN/claim.sh" "$BIN/launch-wave.sh" "$BIN/lock.sh"

# --- fixtures ----------------------------------------------------------------

FIXTURE=$WORK/fixture
STATE=$WORK/state.json
NOTIFY_LOG=$WORK/notify.log

new_fixture() {
  FIXTURE=$WORK/fx-$1
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE"
  : >"$WORK/gh.log"
  : >"$WORK/orca.log"
  : >"$WORK/claim.log"
  : >"$WORK/launch.log"
  : >"$NOTIFY_LOG"
  rm -f "$STATE"
  rm -rf "$WORK/projects" "$WORK/runs" "$WORK/codex-runs" "$WORK/launch-state"
  mkdir -p "$WORK/projects" "$WORK/runs" "$WORK/codex-runs" "$WORK/launch-state"
  cat >"$WORK/launch-state/test__repo.json" <<'JSON'
{"workers": 4, "specs": 2, "apart": [], "auto_land": true, "updated": "2026-11-26T00:00:00Z"}
JSON
  cat >"$FIXTURE/orca-repos.json" <<JSON
{"ok": true, "result": {"repos": [
  {"path": "$REPO_PATH", "gitRemoteIdentity": {"canonicalKey": "github.com/test/repo"}}
]}}
JSON
  cat >"$FIXTURE/issues.json" <<'JSON'
[
  {"number": 19, "title": "Spec nineteen", "state": "OPEN", "body": "## Problem Statement\n nineteen"},
  {"number": 20, "title": "Spec twenty", "state": "OPEN", "body": "## Problem Statement\n twenty"},
  {"number": 21, "title": "Not a spec", "state": "OPEN", "body": "plain issue"}
]
JSON
  : >"$FIXTURE/claims.txt"
  printf '[]' >"$FIXTURE/comments-20.json"
}

run_keeper() { # out [keeper arguments]
  out=$1
  shift
  env HOME="$WORK/home" \
      FIXTURE_DIR="$FIXTURE" GH_LOG="$WORK/gh.log" ORCA_LOG="$WORK/orca.log" \
      CLAIM_LOG="$WORK/claim.log" LAUNCH_LOG="$WORK/launch.log" \
      NOTIFY_LOG="$NOTIFY_LOG" \
      KEEPER_CLAUDE_PROJECTS="$WORK/projects" \
      KEEPER_RUNS_DIR="$WORK/runs" \
      KEEPER_CODEX_RUNS="$WORK/codex-runs" \
      KEEPER_LAUNCH_STATE_DIR="$WORK/launch-state" \
      KEEPER_CLAIM="$BIN/claim.sh" \
      KEEPER_LAUNCH_WAVE="$BIN/launch-wave.sh" \
      KEEPER_LOCK="$BIN/lock.sh" \
      KEEPER_ORCA="$BIN/orca" \
      KEEPER_GH="$BIN/gh" \
      KEEPER_NOTIFY_CMD='printf "%s\n" "$KEEPER_NOTIFY_MESSAGE" >>"$NOTIFY_LOG"' \
      KEEPER_STALL_MIN="${STALL_MIN:-45}" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" --once --state "$STATE" "$@" >"$out" 2>&1
  RUN_EXIT=$?
}

write_transcript() { # mtime-epoch
  local dir=$WORK/projects/$(encoded_path "$WT")
  mkdir -p "$dir"
  printf '{"type":"x"}\n' >"$dir/session.jsonl"
  set_mtime "$dir/session.jsonl" "$1"
}

write_run() { # phase mtime-epoch
  local dir=$WORK/runs/repo-19-20260101-0000
  mkdir -p "$dir"
  printf '{"phase":"%s","updated":"2026-11-25T00:00:00+0800"}\n' "$1" >"$dir/run.json"
  set_mtime "$dir/run.json" "$2"
}

write_parking() { # body [created_at]
  cat >"$FIXTURE/comments-19.json" <<JSON
[{"id": 9001, "created_at": "${2:-$(epoch_iso 0)}", "html_url": "https://example.test/issues/19#comment-9001", "body": $(printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')}]
JSON
}

# --- quota parking, not yet recoverable --------------------------------------

new_fixture quota-wait
write_parking '## 停车报告

停车类别：quota
可恢复时间：'"$(epoch_iso 7200)"'

### 需要你决定
1. 等额度重置。'
run_keeper "$WORK/quota-wait.out"
expect_exit 0 "quota not due: exits 0"
expect_has "WAIT" "quota not due: reports a wait" "$WORK/quota-wait.out"
expect_without $'\tRESUME\t' "quota not due: does not resume" "$WORK/quota-wait.out"
expect_without "launched" "quota not due: launch-wave not called" "$WORK/launch.log"
expect_count "" 0 "quota not due: no notification" "$NOTIFY_LOG"
expect_no_file "$STATE" "quota not due: writes no state"

# --- quota parking, recoverable ----------------------------------------------

new_fixture quota-due
write_parking '## 停车报告

**停车类别：quota**
**可恢复时间：** '"$(epoch_iso -60)"'

### 需要你决定
1. 等额度重置。'
run_keeper "$WORK/quota-due.out"
expect_exit 0 "quota due: exits 0"
expect_has $'\tRESUME\t' "quota due: resumes" "$WORK/quota-due.out"
expect_has "--repo test/repo --only 19 --apply" "quota due: launch-wave resumes spec 19" "$WORK/launch.log"
expect_count "" 0 "quota due: no notification for a quota resume" "$NOTIFY_LOG"
expect_file "$STATE" "quota due: records the resume"

# --- decision parking notifies once ------------------------------------------

new_fixture decision
write_parking '## 停车报告

停车类别：decision
可恢复时间：无

### 需要你决定
1. 保留还是撤回？'
run_keeper "$WORK/decision-1.out"
expect_exit 0 "decision: exits 0"
expect_has "停车待你决定" "decision: notifies with the report url" "$NOTIFY_LOG"
expect_has "https://example.test/issues/19#comment-9001" "decision: notification carries the url" "$NOTIFY_LOG"
expect_without "launched" "decision: never resumes" "$WORK/launch.log"
run_keeper "$WORK/decision-2.out"
expect_exit 0 "decision second round: exits 0"
expect_count "" 1 "decision: notifies only once" "$NOTIFY_LOG"

# --- fourth resume in 24h turns into a notification --------------------------

new_fixture limit
write_parking '## 停车报告

停车类别：quota
可恢复时间：'"$(epoch_iso -60)"'

### 需要你决定
1. 等额度重置。'
node -e '
  const fs = require("fs");
  const now = Math.floor(Date.now() / 1000);
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    resumes: {"test/repo#19": [now - 3600, now - 3600, now - 3600]},
    notified: {}, nudges: {}
  }, null, 2));
' "$STATE"
run_keeper "$WORK/limit.out"
expect_exit 0 "limit: exits 0"
expect_has "今日自动恢复已达 3 次" "limit: notifies instead of resuming" "$NOTIFY_LOG"
expect_without "launched" "limit: does not launch" "$WORK/launch.log"
run_keeper "$WORK/limit-2.out"
expect_count "" 1 "limit: notifies only once" "$NOTIFY_LOG"

# --- interrupted claim -------------------------------------------------------

new_fixture interrupted
printf '[]' >"$FIXTURE/comments-19.json"
printf '19\tinterrupted\t{"spec":19,"branch":"spec-19","worktree":"%s"}\n' "$WT" >>"$FIXTURE/claims.txt"
run_keeper "$WORK/interrupted.out"
expect_exit 0 "interrupted: exits 0"
expect_has $'\tRESUME\t' "interrupted: resumes" "$WORK/interrupted.out"
expect_has "--only 19 --apply" "interrupted: launch-wave resumes spec 19" "$WORK/launch.log"
expect_count "" 0 "interrupted: no notification" "$NOTIFY_LOG"

# --- stalled session: nudge, then close, release and resume ------------------

new_fixture stalled
printf '19\tactive\t{"spec":19,"branch":"spec-19","worktree":"%s","pid":1}\n' "$WT" >>"$FIXTURE/claims.txt"
write_run implement "$(epoch_at -7200)"
write_transcript "$(epoch_at -7200)"
cat >"$FIXTURE/terminals.json" <<JSON
{"ok": true, "result": {"terminals": [
  {"handle": "term_19", "title": "Claude Code", "worktreePath": "$WT",
   "tabId": "tab1", "agentIdentity": "claude", "lastOutputAt": 1},
  {"handle": "term_progress", "title": "spec-19 t28", "worktreePath": "$WT",
   "tabId": "tab2", "agentIdentity": "claude", "lastOutputAt": 2},
  {"handle": "term_other", "title": "Claude Code", "worktreePath": "$WORK/elsewhere",
   "tabId": "tab3", "agentIdentity": "claude", "lastOutputAt": 3}
]}}
JSON
STALL_MIN=0 run_keeper "$WORK/stall-1.out" --dry-run
expect_exit 0 "stalled dry-run: exits 0"
expect_has $'\tWOULD_NUDGE\t' "stalled dry-run: would nudge" "$WORK/stall-1.out"
expect_has "term_19" "stalled dry-run: picks the agent terminal, not the progress tab" "$WORK/stall-1.out"
expect_without "term_progress" "stalled dry-run: skips the progress tab" "$WORK/stall-1.out"
expect_without $'\tWOULD_CLOSE_TERMINAL\t' "stalled dry-run: does not escalate on the first round" "$WORK/stall-1.out"
expect_count "" 0 "stalled dry-run: orca send not called" "$WORK/orca.log"

STALL_MIN=0 run_keeper "$WORK/stall-2.out"
expect_exit 0 "stalled round 1: exits 0"
expect_has "terminal send --terminal term_19" "stalled round 1: sends 继续 to the agent terminal" "$WORK/orca.log"
expect_has "继续。你是无人值守 Run" "stalled round 1: sends the required text" "$WORK/orca.log"
expect_has $'\tNUDGE\t' "stalled round 1: logs the nudge" "$WORK/stall-2.out"
expect_without "terminal close" "stalled round 1: closes nothing" "$WORK/orca.log"
expect_without "launched" "stalled round 1: launches nothing" "$WORK/launch.log"

STALL_MIN=0 run_keeper "$WORK/stall-3.out"
expect_exit 0 "stalled round 2: exits 0"
expect_has "terminal close --terminal term_19 --tab" "stalled round 2: closes the terminal" "$WORK/orca.log"
expect_has "release 19 --force" "stalled round 2: releases the claim" "$WORK/claim.log"
expect_has "--only 19 --apply" "stalled round 2: resumes the spec" "$WORK/launch.log"
expect_has $'\tRESUME\t' "stalled round 2: logs the resume" "$WORK/stall-3.out"
expect_count "release 19 --force" 1 "stalled round 2: releases once" "$WORK/claim.log"

# --- fresh writes: no action -------------------------------------------------

new_fixture fresh
printf '19\tactive\t{"spec":19,"branch":"spec-19","worktree":"%s","pid":1}\n' "$WT" >>"$FIXTURE/claims.txt"
write_run implement "$(epoch_at 0)"
write_transcript "$(epoch_at 0)"
run_keeper "$WORK/fresh.out"
expect_exit 0 "fresh: exits 0"
expect_without $'\tNUDGE\t' "fresh: no nudge" "$WORK/fresh.out"
expect_without "WOULD_" "fresh: no action" "$WORK/fresh.out"
expect_count "" 0 "fresh: orca send not called" "$WORK/orca.log"
expect_without "launched" "fresh: launch-wave not called" "$WORK/launch.log"

# --- legacy reports: keyword fallback ----------------------------------------

new_fixture legacy-am
write_parking '## 停车报告

### 需要你决定
1. GLM 额度用尽（resets 1am Asia/Shanghai），等重置。' "2020-01-01T23:23:00+08:00"
run_keeper "$WORK/legacy-am.out"
expect_exit 0 "legacy am: exits 0"
expect_has $'\tRESUME\t' "legacy am: 1am resolves to the reset that already passed" "$WORK/legacy-am.out"

new_fixture legacy-quota
write_parking '## 停车报告

### 需要你决定
1. GLM 额度用尽，等待重置。

### 现状
重置时间 2026-11-25T00:00:00+0800'
run_keeper "$WORK/legacy-quota.out"
expect_exit 0 "legacy quota: exits 0"
expect_has $'\tRESUME\t' "legacy quota: classifies as quota and resumes" "$WORK/legacy-quota.out"
expect_count "" 0 "legacy quota: no decision notification" "$NOTIFY_LOG"
expect_has "--only 19 --apply" "legacy quota: launch-wave resumes" "$WORK/launch.log"

new_fixture legacy-decision
write_parking '## 停车报告

### 需要你决定
1. 这里的取舍需要你拍板。

### 现状
分支 spec-19 已合并三张票。'
run_keeper "$WORK/legacy-decision.out"
expect_exit 0 "legacy decision: exits 0"
expect_has "停车待你决定" "legacy decision: notifies once" "$NOTIFY_LOG"
expect_without "launched" "legacy decision: never resumes" "$WORK/launch.log"

# --- dry-run writes nothing --------------------------------------------------

new_fixture dry-run
write_parking '## 停车报告

停车类别：transient
可恢复时间：无'
run_keeper "$WORK/dry-run.out" --dry-run
expect_exit 0 "dry-run: exits 0"
expect_has $'\tWOULD_RESUME\t' "dry-run: prints the resume it would do" "$WORK/dry-run.out"
expect_no_file "$STATE" "dry-run: writes no state"
expect_count "" 0 "dry-run: sends no notification" "$NOTIFY_LOG"
expect_without "launched" "dry-run: calls no launch-wave" "$WORK/launch.log"
expect_count "" 0 "dry-run: writes no orca action" "$WORK/orca.log"

# --- non-auto_land repository ------------------------------------------------

new_fixture no-auto-land
cat >"$WORK/launch-state/test__repo.json" <<'JSON'
{"workers": 4, "specs": 2, "apart": [], "auto_land": false, "updated": "2026-11-26T00:00:00Z"}
JSON
run_keeper "$WORK/no-auto-land.out"
expect_exit 0 "auto_land false: exits 0"
expect_has "auto_land=false" "auto_land false: logs the skip" "$WORK/no-auto-land.out"
expect_count "" 0 "auto_land false: gh is not called" "$WORK/gh.log"
expect_without "launched" "auto_land false: launches nothing" "$WORK/launch.log"

# --- lock conflict -----------------------------------------------------------

new_fixture lock
touch "$FIXTURE/lock-held"
run_keeper "$WORK/lock.out"
expect_exit 0 "lock conflict: exits 0"
expect_has "LOCK" "lock conflict: logs the lock" "$WORK/lock.out"
expect_count "" 0 "lock conflict: gh is not called" "$WORK/gh.log"

# --- gh failure is reported, not fatal ---------------------------------------

new_fixture gh-error
touch "$FIXTURE/gh-fail"
run_keeper "$WORK/gh-error.out"
expect_exit 0 "gh error: exits 0"
expect_has "ERROR" "gh error: logs the failure" "$WORK/gh-error.out"
expect_has "gh: rate limited" "gh error: carries the gh message" "$WORK/gh-error.out"
expect_without "launched" "gh error: launches nothing" "$WORK/launch.log"

# --- pause flag --------------------------------------------------------------

new_fixture paused
touch "$(dirname "$STATE")/paused"
run_keeper "$WORK/paused.out"
expect_exit 0 "paused: exits 0"
expect_has "PAUSED" "paused: logs the pause" "$WORK/paused.out"
expect_count "" 0 "paused: gh is not called" "$WORK/gh.log"

printf '\n%s\n' "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
