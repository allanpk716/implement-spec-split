#!/usr/bin/env bash
# Isolated fake-dependency tests for scripts/keeper.sh.
# No network, no Orca, no launchd: gh, claim.sh, launch-wave.sh and lock.sh are
# fakes injected through PATH and KEEPER_* environment variables; orca is a fake
# outside PATH, named by ISS_ORCA (the one Orca replacement variable). It answers
# the liveness queries keeper makes of Orca (worker-list, worker-show) from
# fixture files and records them apart from the one action it logs (terminal
# close), and refuses every other call.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/keeper.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/keeper-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

BIN=$WORK/bin
# The fake orca lives outside PATH on purpose: keeper.sh must reach Orca only
# through ISS_ORCA, never through an `orca` that happens to be on PATH.
ORCA_BIN=$WORK/orca-bin
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

expect_same() { # expected actual name
  if [ "$1" = "$2" ]; then
    record PASS "$3"
  else
    record FAIL "$3" "got [$2], expected [$1]"
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

mkdir -p "$BIN" "$ORCA_BIN" "$WORK/home" "$WORK/projects" "$WORK/runs" "$WORK/codex-runs" \
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

cat >"$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "repo list")
    cat "$FIXTURE_DIR/orca-repos.json" 2>/dev/null || printf '{"ok":true,"result":{"repos":[]}}'
    exit 0
    ;;
  "orchestration worker-list")
    # A query, not an action: recorded apart from ORCA_LOG so that the
    # "dry-run writes no orca action" assertions stay about actions alone.
    printf '%s\n' "$*" >>"$ORCA_QUERY_LOG"
    if [ -f "$FIXTURE_DIR/orca-worker-list-fail" ]; then
      printf 'orca offline\n' >&2
      exit 1
    fi
    cursor=
    while [ $# -gt 0 ]; do
      [ "$1" = --cursor ] && cursor=${2:-}
      shift
    done
    if [ -z "$cursor" ]; then
      cat "$FIXTURE_DIR/workers.json" 2>/dev/null || printf '{"ok":true,"result":{"workers":[]}}'
    elif [ -f "$FIXTURE_DIR/workers-$cursor.json" ]; then
      cat "$FIXTURE_DIR/workers-$cursor.json"
    else
      printf 'fake orca: no workers-%s.json fixture\n' "$cursor" >&2
      exit 1
    fi
    exit 0
    ;;
  "orchestration worker-show")
    printf '%s\n' "$*" >>"$ORCA_QUERY_LOG"
    if [ -f "$FIXTURE_DIR/orca-worker-show-fail" ]; then
      printf 'orca offline\n' >&2
      exit 1
    fi
    dispatch=
    while [ $# -gt 0 ]; do
      [ "$1" = --dispatch ] && dispatch=${2:-}
      shift
    done
    if [ -n "$dispatch" ] && [ -f "$FIXTURE_DIR/worker-show-$dispatch.json" ]; then
      cat "$FIXTURE_DIR/worker-show-$dispatch.json"
    else
      printf 'fake orca: no worker-show fixture for %s\n' "${dispatch:-<none>}" >&2
      exit 1
    fi
    exit 0
    ;;
  "terminal close")
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

# The sweep keeper calls once a round (规格 #26): records its arguments and
# answers with the lines sweep-worktrees.sh prints -- a kept worktree and a
# summary, plus a removal when the fixture has sweep-remove and a would-be
# removal when it has sweep-would -- or fails when asked to (sweep-fail).
cat >"$BIN/sweep-worktrees.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$SWEEP_LOG"
if [ -f "$FIXTURE_DIR/sweep-fail" ]; then
  printf 'fake sweep: orca offline\n' >&2
  exit 1
fi
printf 'test/repo\tkeep\t/w/repo\t主工作区，绝不删\n'
if [ -f "$FIXTURE_DIR/sweep-remove" ]; then
  printf 'test/repo\tremoved\t/w/wt-spec-22\t遗弃工作区：无 worker、无认领、未停车、干净且已并入 origin/main\n'
fi
if [ -f "$FIXTURE_DIR/sweep-would" ]; then
  printf 'test/repo\twould-remove\t/w/wt-spec-22\t遗弃工作区：无 worker、无认领、未停车、干净且已并入 origin/main\n'
fi
printf 'test/repo\tsummary\t-\tremoved=1 would-remove=0 keep=1 skip=0 failed=0\n'
exit 0
EOF

chmod +x "$BIN/gh" "$ORCA_BIN/orca" "$BIN/claim.sh" "$BIN/launch-wave.sh" "$BIN/lock.sh" "$BIN/sweep-worktrees.sh"

# Guard rail: this machine has a real `orca` on PATH. The one on the tests' PATH
# refuses every call, so a keeper.sh that stops going through ISS_ORCA fails
# here instead of quietly reading the real Orca.
cat >"$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf 'PATH orca called: %s\n' "$*" >>"$ORCA_LOG"
printf 'test-keeper: orca on PATH was called instead of ISS_ORCA\n' >&2
exit 99
EOF
chmod +x "$BIN/orca"

# --- fixtures ----------------------------------------------------------------

FIXTURE=$WORK/fixture
STATE=$WORK/state.json
NOTIFY_LOG=$WORK/notify.log
SWEEP_LOG=$WORK/sweep.log
SWEEP_SCRIPT=$BIN/sweep-worktrees.sh

new_fixture() {
  FIXTURE=$WORK/fx-$1
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE"
  : >"$WORK/gh.log"
  : >"$WORK/orca.log"
  : >"$WORK/orca-query.log"
  : >"$WORK/claim.log"
  : >"$WORK/launch.log"
  : >"$NOTIFY_LOG"
  : >"$SWEEP_LOG"
  SWEEP_SCRIPT=$BIN/sweep-worktrees.sh
  rm -f "$STATE" "$(dirname -- "$STATE")/paused"
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
      ORCA_QUERY_LOG="$WORK/orca-query.log" \
      CLAIM_LOG="$WORK/claim.log" LAUNCH_LOG="$WORK/launch.log" \
      NOTIFY_LOG="$NOTIFY_LOG" SWEEP_LOG="$SWEEP_LOG" \
      KEEPER_SWEEP="$SWEEP_SCRIPT" \
      KEEPER_CLAUDE_PROJECTS="$WORK/projects" \
      KEEPER_RUNS_DIR="$WORK/runs" \
      KEEPER_CODEX_RUNS="$WORK/codex-runs" \
      KEEPER_LAUNCH_STATE_DIR="$WORK/launch-state" \
      KEEPER_CLAIM="$BIN/claim.sh" \
      KEEPER_LAUNCH_WAVE="$BIN/launch-wave.sh" \
      KEEPER_LOCK="$BIN/lock.sh" \
      ISS_ORCA="$ORCA_BIN/orca" \
      KEEPER_GH="$BIN/gh" \
      KEEPER_NOTIFY_CMD='printf "%s\n" "$KEEPER_NOTIFY_MESSAGE" >>"$NOTIFY_LOG"' \
      KEEPER_STALL_MIN="${STALL_MIN:-45}" \
      KEEPER_WORKER_PAGES="${WORKER_PAGES:-10}" \
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

stall_spec_19() { # an active claim whose transcript and Run directory went silent two hours ago
  printf '19\tactive\t{"spec":19,"branch":"spec-19","worktree":"%s","pid":1}\n' "$WT" >>"$FIXTURE/claims.txt"
  write_run implement "$(epoch_at -7200)"
  write_transcript "$(epoch_at -7200)"
}

# --- Orca worker fixtures: what the fake orca answers about the Spec 19 worker --
# A worker-list page holds worker_record objects and names the page after it in
# nextCursor (workers-<cursor>.json; empty for the last page). worker_show is the
# worker-show receipt of one dispatch; keeper acts on its liveness, terminal and
# terminalState. The workspace is <repo-id>::<path>, the path as Orca writes it.

worker_record() { # dispatchId liveness [terminal] [terminalState] [workspace]
  printf '{"dispatchId": "%s", "taskId": "task_x", "state": "running", "liveness": "%s", "terminal": "%s", "terminalState": "%s", "workspace": "%s"}' \
    "$1" "$2" "${3:-term_$1}" "${4:-active}" "${5:-repo_test::$WT}"
}

worker_show() { # dispatchId liveness [terminal] [terminalState] -> a worker-show receipt
  # A terminal left out is given a name; an empty one ('') stays empty, as Orca
  # reports a terminal it has already released.
  printf '{"ok": true, "result": {"dispatchId": "%s", "taskId": "task_x", "runId": "run_x", "state": "running", "stage": "running", "liveness": "%s", "terminal": "%s", "terminalState": "%s", "workspace": "repo_test::%s", "waitingOnHuman": "unknown"}}\n' \
    "$1" "$2" "${3-term_$1}" "${4-active}" "$WT"
}

write_worker_show() { # dispatchId liveness [terminal] [terminalState]
  worker_show "$@" >"$FIXTURE/worker-show-$1.json"
}

write_workers_page() { # file nextCursor worker records... (nextCursor empty: last page)
  local file=$1 next=$2 sep=
  shift 2
  {
    printf '{"ok": true, "result": {"workers": ['
    for record in "$@"; do printf '%s%s' "$sep" "$record"; sep=,; done
    printf '], "scope": {"source": "all"}, "nextCursor": '
    if [ -n "$next" ]; then printf '"%s"' "$next"; else printf 'null'; fi
    printf '}}\n'
  } >"$file"
}

write_workers() { # nextCursor worker records... -> the first page worker-list answers
  write_workers_page "$FIXTURE/workers.json" "$@"
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
    notified: {}
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

# --- stalled session: Orca's liveness decides (ticket #43) ---------------------
# The second evidence (no write for KEEPER_STALL_MIN) only starts the question;
# the first evidence, the liveness Orca reports for the worker in the Spec
# worktree, decides: live is left alone, exited is a confirmed failure and
# unverifiable (or no worker at all) is reported once and left alone too.

new_fixture stalled-live
stall_spec_19
write_workers '' "$(worker_record ctx_19 live)"
write_worker_show ctx_19 live
STALL_MIN=0 run_keeper "$WORK/live.out"
expect_exit 0 "live: exits 0"
expect_has $'\tLIVE\t' "live: logs the conclusion" "$WORK/live.out"
expect_has "liveness=live dispatch=ctx_19" "live: the log line carries the evidence" "$WORK/live.out"
expect_count "" 0 "live: sends 继续 to nothing" "$WORK/orca.log"
expect_count "" 0 "live: closes nothing" "$WORK/orca.log"
expect_count "release 19 --force" 0 "live: releases nothing" "$WORK/claim.log"
expect_without "launched" "live: launches nothing" "$WORK/launch.log"
expect_count "" 0 "live: no notification" "$NOTIFY_LOG"
expect_no_file "$STATE" "live: writes no state"
expect_has "orchestration worker-list --json" "live: asks Orca for the worker list" "$WORK/orca-query.log"
expect_has "orchestration worker-show --dispatch ctx_19 --json" "live: asks Orca about that dispatch" "$WORK/orca-query.log"

# exited is the one conclusion keeper acts on: the terminal Orca has not
# released is closed, the claim released, the Spec resumed — at once, with no
# 「继续」 first, since there is nothing left to read it.
new_fixture stalled-exited
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited)"
write_worker_show ctx_19 exited term_19 active
STALL_MIN=0 run_keeper "$WORK/exited.out"
expect_exit 0 "exited: exits 0"
expect_has $'\tEXITED\t' "exited: logs the conclusion" "$WORK/exited.out"
expect_has "liveness=exited dispatch=ctx_19" "exited: the log line carries the evidence" "$WORK/exited.out"
expect_has "terminal close --terminal term_19 --tab" "exited: closes the terminal Orca still lists" "$WORK/orca.log"
expect_count "terminal close" 1 "exited: closes it once" "$WORK/orca.log"
expect_count "terminal send" 0 "exited: sends 继续 to nothing" "$WORK/orca.log"
expect_count "release 19 --force" 1 "exited: releases the claim once" "$WORK/claim.log"
expect_has "--repo test/repo --only 19 --apply" "exited: launch-wave resumes the spec" "$WORK/launch.log"
expect_has $'\tRESUME\tOrca 报告会话已退出（liveness=exited dispatch=ctx_19）' "exited: the resume says why, with the evidence" "$WORK/exited.out"
expect_file "$STATE" "exited: records the resume"
expect_count "" 0 "exited: no notification" "$NOTIFY_LOG"

# A terminal Orca released itself is gone: nothing is closed, the rest is the same.
new_fixture stalled-exited-released
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited term_19 released)"
write_worker_show ctx_19 exited term_19 released
STALL_MIN=0 run_keeper "$WORK/exited-released.out"
expect_exit 0 "exited, terminal released: exits 0"
expect_has $'\tEXITED\t' "exited, terminal released: logs the conclusion" "$WORK/exited-released.out"
expect_count "" 0 "exited, terminal released: closes nothing" "$WORK/orca.log"
expect_count "release 19 --force" 1 "exited, terminal released: releases the claim" "$WORK/claim.log"
expect_has "--only 19 --apply" "exited, terminal released: resumes the spec" "$WORK/launch.log"

# The same receipt with no terminal at all: Orca leaves the field empty for a
# terminal it released. The empty column must stay where it is (the receipt's
# columns are split on the unit separator; a tab would let read fold it into
# its neighbour and hand `released` around as a handle): nothing is closed,
# so nothing fails, and the rest is as above.
new_fixture stalled-exited-terminal-empty
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited '' released)"
write_worker_show ctx_19 exited '' released
STALL_MIN=0 run_keeper "$WORK/exited-terminal-empty.out"
expect_exit 0 "exited, terminal empty: exits 0"
expect_has $'\tEXITED\t' "exited, terminal empty: logs the conclusion" "$WORK/exited-terminal-empty.out"
expect_has 'liveness=exited dispatch=ctx_19' "exited, terminal empty: the log line carries the evidence" "$WORK/exited-terminal-empty.out"
expect_count "" 0 "exited, terminal empty: closes nothing, released being a state and not a handle" "$WORK/orca.log"
expect_without $'\tCLOSE_TERMINAL\t' "exited, terminal empty: no close is logged" "$WORK/exited-terminal-empty.out"
expect_without $'\tERROR\t' "exited, terminal empty: no failed close, so no error" "$WORK/exited-terminal-empty.out"
expect_count "release 19 --force" 1 "exited, terminal empty: releases the claim" "$WORK/claim.log"
expect_has "--only 19 --apply" "exited, terminal empty: resumes the spec" "$WORK/launch.log"
new_fixture stalled-exited-terminal-empty-dry-run
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited '' released)"
write_worker_show ctx_19 exited '' released
STALL_MIN=0 run_keeper "$WORK/exited-terminal-empty-dry.out" --dry-run
expect_exit 0 "exited, terminal empty, dry-run: exits 0"
expect_has $'\tEXITED\t' "exited, terminal empty, dry-run: reaches the conclusion" "$WORK/exited-terminal-empty-dry.out"
expect_without 'WOULD_CLOSE_TERMINAL' "exited, terminal empty, dry-run: would close nothing, not even on a handle called released" "$WORK/exited-terminal-empty-dry.out"

# unverifiable: Orca's own rule is that nothing is stopped, retried or released
# on it. The human is told once, with the evidence, and keeper stays out.
new_fixture stalled-unverifiable
stall_spec_19
write_workers '' "$(worker_record ctx_19 unverifiable)"
write_worker_show ctx_19 unverifiable term_19 active
STALL_MIN=0 run_keeper "$WORK/unverifiable-1.out"
expect_exit 0 "unverifiable: exits 0"
expect_has $'\tUNVERIFIABLE\t' "unverifiable: logs the conclusion" "$WORK/unverifiable-1.out"
expect_has "liveness=unverifiable dispatch=ctx_19" "unverifiable: the log line carries the evidence" "$WORK/unverifiable-1.out"
expect_has "无法确认会话是否已退出，未自动恢复" "unverifiable: notifies" "$NOTIFY_LOG"
expect_has "liveness=unverifiable dispatch=ctx_19" "unverifiable: the notification carries the evidence" "$NOTIFY_LOG"
expect_count "release 19 --force" 0 "unverifiable: releases nothing" "$WORK/claim.log"
expect_without "launched" "unverifiable: launches nothing" "$WORK/launch.log"
expect_count "" 0 "unverifiable: closes nothing" "$WORK/orca.log"
expect_file "$STATE" "unverifiable: records the notification"
STALL_MIN=0 run_keeper "$WORK/unverifiable-2.out"
expect_exit 0 "unverifiable second round: exits 0"
expect_count "" 1 "unverifiable: notifies only once" "$NOTIFY_LOG"
expect_has $'\tSKIP\t无法确认会话状态，已通知过' "unverifiable second round: says it already told" "$WORK/unverifiable-2.out"
expect_count "release 19 --force" 0 "unverifiable second round: still releases nothing" "$WORK/claim.log"
expect_without "launched" "unverifiable second round: still launches nothing" "$WORK/launch.log"

# A liveness keeper has never heard of is not a confirmation of anything.
new_fixture stalled-unknown-liveness
stall_spec_19
write_workers '' "$(worker_record ctx_19 starting)"
write_worker_show ctx_19 starting
STALL_MIN=0 run_keeper "$WORK/unknown-liveness.out"
expect_exit 0 "unknown liveness: exits 0"
expect_has $'\tUNVERIFIABLE\t' "unknown liveness: is unverifiable" "$WORK/unknown-liveness.out"
expect_has "liveness=starting dispatch=ctx_19" "unknown liveness: the evidence names the value Orca gave" "$WORK/unknown-liveness.out"
expect_count "release 19 --force" 0 "unknown liveness: releases nothing" "$WORK/claim.log"
expect_without "launched" "unknown liveness: launches nothing" "$WORK/launch.log"
expect_count "" 1 "unknown liveness: notifies once" "$NOTIFY_LOG"

# No worker for the Spec worktree at all (a session Orca does not manage, or
# one whose dispatch is gone): the same restraint, said in so many words.
new_fixture stalled-no-worker
stall_spec_19
write_workers '' "$(worker_record ctx_other live '' active "repo_test::$WORK/elsewhere")"
STALL_MIN=0 run_keeper "$WORK/no-worker-1.out"
expect_exit 0 "no worker: exits 0"
expect_has $'\tUNVERIFIABLE\t' "no worker: logs the conclusion" "$WORK/no-worker-1.out"
expect_has "没有 workspace 为 $WT 的 worker" "no worker: the evidence names the worktree it looked for" "$WORK/no-worker-1.out"
expect_has "没有 workspace 为 $WT 的 worker" "no worker: the notification carries the evidence" "$NOTIFY_LOG"
expect_without "（）" "no worker: no empty note where the page count would go" "$WORK/no-worker-1.out"
expect_without "worker-show" "no worker: asks Orca about no dispatch" "$WORK/orca-query.log"
expect_count "release 19 --force" 0 "no worker: releases nothing" "$WORK/claim.log"
expect_without "launched" "no worker: launches nothing" "$WORK/launch.log"
STALL_MIN=0 run_keeper "$WORK/no-worker-2.out"
expect_count "" 1 "no worker: notifies only once" "$NOTIFY_LOG"

new_fixture stalled-empty-list
stall_spec_19
write_workers ''
STALL_MIN=0 run_keeper "$WORK/empty-list.out"
expect_has $'\tUNVERIFIABLE\t' "empty worker list: is unverifiable" "$WORK/empty-list.out"
expect_count "release 19 --force" 0 "empty worker list: releases nothing" "$WORK/claim.log"
expect_without "launched" "empty worker list: launches nothing" "$WORK/launch.log"

# Orca writes the canonical path in workspace (macOS /var is /private/var);
# git may have given keeper the other one. Both name the same worktree.
new_fixture stalled-canonical-path
stall_spec_19
write_workers '' "$(worker_record ctx_19 live '' active "repo_test::$(cd "$WT" && pwd -P)")"
write_worker_show ctx_19 live
STALL_MIN=0 run_keeper "$WORK/canonical.out"
expect_has $'\tLIVE\t' "canonical workspace path: matches the worktree git named" "$WORK/canonical.out"
expect_has "liveness=live dispatch=ctx_19" "canonical workspace path: asks Orca about that dispatch" "$WORK/canonical.out"

# An Orca that cannot answer is not a closed terminal (the #55 rule, kept):
# it is one more thing keeper cannot conclude from, reported once like the rest.
new_fixture orca-worker-list-down
stall_spec_19
touch "$FIXTURE/orca-worker-list-fail"
STALL_MIN=0 run_keeper "$WORK/list-down-1.out"
expect_exit 0 "orca worker-list down: exits 0"
expect_has $'\tUNVERIFIABLE\t' "orca worker-list down: is unverifiable, not exited" "$WORK/list-down-1.out"
expect_has "orca worker-list 失败：orca offline" "orca worker-list down: carries Orca's message" "$WORK/list-down-1.out"
expect_has "orca worker-list 失败：orca offline" "orca worker-list down: the notification carries Orca's message" "$NOTIFY_LOG"
expect_count "release 19 --force" 0 "orca worker-list down: releases nothing" "$WORK/claim.log"
expect_without "launched" "orca worker-list down: resumes nothing" "$WORK/launch.log"
expect_count "" 0 "orca worker-list down: closes nothing" "$WORK/orca.log"
STALL_MIN=0 run_keeper "$WORK/list-down-2.out"
expect_count "" 1 "orca worker-list down: notifies only once" "$NOTIFY_LOG"

new_fixture orca-worker-show-down
stall_spec_19
write_workers '' "$(worker_record ctx_19 live)"
touch "$FIXTURE/orca-worker-show-fail"
STALL_MIN=0 run_keeper "$WORK/show-down.out"
expect_exit 0 "orca worker-show down: exits 0"
expect_has $'\tUNVERIFIABLE\t' "orca worker-show down: is unverifiable, not live and not exited" "$WORK/show-down.out"
expect_has "worker-show 失败：orca offline" "orca worker-show down: carries Orca's message" "$WORK/show-down.out"
expect_count "release 19 --force" 0 "orca worker-show down: releases nothing" "$WORK/claim.log"
expect_without "launched" "orca worker-show down: resumes nothing" "$WORK/launch.log"
expect_count "" 1 "orca worker-show down: notifies once" "$NOTIFY_LOG"

new_fixture orca-worker-list-garbage
stall_spec_19
printf 'not json\n' >"$FIXTURE/workers.json"
STALL_MIN=0 run_keeper "$WORK/list-garbage.out"
expect_has $'\tUNVERIFIABLE\t' "worker-list not JSON: is unverifiable" "$WORK/list-garbage.out"
expect_has "无法解析" "worker-list not JSON: says the page could not be read" "$WORK/list-garbage.out"
expect_count "release 19 --force" 0 "worker-list not JSON: releases nothing" "$WORK/claim.log"

# The Spec worktree holds more than the session: fix and merge roles open their
# terminals in it too (stage-dispatch.sh). Any live worker there means the
# worktree is in use; only when every one exited is the failure confirmed; one
# Orca cannot vouch for keeps it from being confirmed.
new_fixture stalled-mixed-live
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited term_19 released)" "$(worker_record ctx_fix live term_fix retained)"
write_worker_show ctx_19 exited term_19 released
write_worker_show ctx_fix live term_fix retained
STALL_MIN=0 run_keeper "$WORK/mixed-live.out"
expect_has $'\tLIVE\t' "exited session, live fix worker: the worktree is live" "$WORK/mixed-live.out"
expect_has "liveness=exited dispatch=ctx_19; liveness=live dispatch=ctx_fix" "exited session, live fix worker: the evidence names both" "$WORK/mixed-live.out"
expect_count "release 19 --force" 0 "exited session, live fix worker: releases nothing" "$WORK/claim.log"
expect_without "launched" "exited session, live fix worker: launches nothing" "$WORK/launch.log"
expect_count "" 0 "exited session, live fix worker: closes nothing" "$WORK/orca.log"

new_fixture stalled-all-exited
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited term_19 released)" "$(worker_record ctx_fix exited term_fix retained)"
write_worker_show ctx_19 exited term_19 released
write_worker_show ctx_fix exited term_fix retained
STALL_MIN=0 run_keeper "$WORK/all-exited.out"
expect_has $'\tEXITED\t' "all exited: the failure is confirmed" "$WORK/all-exited.out"
expect_has "liveness=exited dispatch=ctx_19; liveness=exited dispatch=ctx_fix" "all exited: the evidence names both" "$WORK/all-exited.out"
expect_has "terminal close --terminal term_fix --tab" "all exited: closes the terminal Orca kept" "$WORK/orca.log"
expect_without "terminal close --terminal term_19 --tab" "all exited: does not close the terminal Orca already released" "$WORK/orca.log"
expect_count "release 19 --force" 1 "all exited: releases once" "$WORK/claim.log"
expect_count "only 19 --apply" 1 "all exited: resumes once" "$WORK/launch.log"

new_fixture stalled-mixed-unsure
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited)" "$(worker_record ctx_fix unverifiable)"
write_worker_show ctx_19 exited
write_worker_show ctx_fix unverifiable
STALL_MIN=0 run_keeper "$WORK/mixed-unsure.out"
expect_has $'\tUNVERIFIABLE\t' "exited and unverifiable: not confirmed" "$WORK/mixed-unsure.out"
expect_count "release 19 --force" 0 "exited and unverifiable: releases nothing" "$WORK/claim.log"
expect_without "launched" "exited and unverifiable: launches nothing" "$WORK/launch.log"

# worker-list has no worktree filter and pages of 100: the Spec's worker may
# sit behind newer dispatches. The list is walked until it turns up.
new_fixture stalled-second-page
stall_spec_19
write_workers c2 "$(worker_record ctx_new live '' active "repo_test::$WORK/elsewhere")"
write_workers_page "$FIXTURE/workers-c2.json" '' "$(worker_record ctx_19 live)"
write_worker_show ctx_19 live
STALL_MIN=0 run_keeper "$WORK/second-page.out"
expect_has $'\tLIVE\t' "worker on the second page: found" "$WORK/second-page.out"
expect_has "liveness=live dispatch=ctx_19" "worker on the second page: asked about that dispatch" "$WORK/second-page.out"
expect_same "orchestration worker-list --json
orchestration worker-list --json --cursor c2
orchestration worker-show --dispatch ctx_19 --json" "$(cat "$WORK/orca-query.log")" \
  "worker on the second page: the walk is list, list --cursor, then the one worker-show"

# A list that never ends (Orca keeps a nextCursor) cannot loop the round: the
# walk stops after KEEPER_WORKER_PAGES pages and says so.
new_fixture stalled-endless-list
stall_spec_19
write_workers c2 "$(worker_record ctx_new live '' active "repo_test::$WORK/elsewhere")"
write_workers_page "$FIXTURE/workers-c2.json" c2 "$(worker_record ctx_new live '' active "repo_test::$WORK/elsewhere")"
WORKER_PAGES=2 STALL_MIN=0 run_keeper "$WORK/endless-list.out"
expect_has $'\tUNVERIFIABLE\t' "endless list: is unverifiable" "$WORK/endless-list.out"
expect_has "（只查了前 2 页）" "endless list: the evidence says how far it looked" "$WORK/endless-list.out"
expect_count "orchestration worker-list" 2 "endless list: two pages, no more" "$WORK/orca-query.log"
expect_count "release 19 --force" 0 "endless list: releases nothing" "$WORK/claim.log"

# "Every worker exited" is a claim about the whole worktree: a list cut short
# before its end cannot support it, even when the worker seen did exit.
new_fixture stalled-exited-but-truncated
stall_spec_19
write_workers c2 "$(worker_record ctx_19 exited)"
write_worker_show ctx_19 exited
WORKER_PAGES=1 STALL_MIN=0 run_keeper "$WORK/exited-truncated.out"
expect_has $'\tUNVERIFIABLE\t' "exited on a truncated list: is unverifiable" "$WORK/exited-truncated.out"
expect_has "liveness=exited dispatch=ctx_19; 只查了前 1 页" "exited on a truncated list: the evidence says both" "$WORK/exited-truncated.out"
expect_count "release 19 --force" 0 "exited on a truncated list: releases nothing" "$WORK/claim.log"
expect_without "launched" "exited on a truncated list: launches nothing" "$WORK/launch.log"

# --dry-run reaches the same conclusion from the same queries and only prints
# what it would do; whatever the conclusion, nothing is written.
new_fixture stalled-live-dry-run
stall_spec_19
write_workers '' "$(worker_record ctx_19 live)"
write_worker_show ctx_19 live
STALL_MIN=0 run_keeper "$WORK/live-dry.out" --dry-run
expect_exit 0 "live dry-run: exits 0"
expect_has $'\tLIVE\t' "live dry-run: reaches the conclusion" "$WORK/live-dry.out"
expect_without "WOULD_" "live dry-run: would do nothing" "$WORK/live-dry.out"
expect_count "orchestration" 2 "live dry-run: Orca is still asked (list, then show)" "$WORK/orca-query.log"
expect_no_file "$STATE" "live dry-run: writes no state"

new_fixture stalled-exited-dry-run
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited)"
write_worker_show ctx_19 exited term_19
STALL_MIN=0 run_keeper "$WORK/exited-dry.out" --dry-run
expect_exit 0 "exited dry-run: exits 0"
expect_has $'\tEXITED\t' "exited dry-run: reaches the conclusion" "$WORK/exited-dry.out"
expect_has $'\tWOULD_CLOSE_TERMINAL\tterm_19' "exited dry-run: would close the terminal" "$WORK/exited-dry.out"
expect_has $'\tWOULD_RELEASE_CLAIM\t' "exited dry-run: would release the claim" "$WORK/exited-dry.out"
expect_has $'\tWOULD_RESUME\tOrca 报告会话已退出（liveness=exited dispatch=ctx_19）' "exited dry-run: would resume, and says why" "$WORK/exited-dry.out"
expect_count "" 0 "exited dry-run: closes nothing" "$WORK/orca.log"
expect_count "release 19 --force" 0 "exited dry-run: releases nothing" "$WORK/claim.log"
expect_without "launched" "exited dry-run: launches nothing" "$WORK/launch.log"
expect_no_file "$STATE" "exited dry-run: writes no state"

new_fixture stalled-unverifiable-dry-run
stall_spec_19
write_workers '' "$(worker_record ctx_19 unverifiable)"
write_worker_show ctx_19 unverifiable
STALL_MIN=0 run_keeper "$WORK/unverifiable-dry.out" --dry-run
expect_exit 0 "unverifiable dry-run: exits 0"
expect_has $'\tUNVERIFIABLE\t' "unverifiable dry-run: reaches the conclusion" "$WORK/unverifiable-dry.out"
expect_has $'\tWOULD_NOTIFY\t' "unverifiable dry-run: would notify" "$WORK/unverifiable-dry.out"
expect_has "liveness=unverifiable dispatch=ctx_19" "unverifiable dry-run: the notification it would send carries the evidence" "$WORK/unverifiable-dry.out"
expect_count "" 0 "unverifiable dry-run: sends no notification" "$NOTIFY_LOG"
expect_no_file "$STATE" "unverifiable dry-run: writes no state"

# Over the resume limit, an exited worker is still not touched: there is no
# point closing a terminal for a resume that will not happen.
new_fixture stalled-exited-over-limit
stall_spec_19
write_workers '' "$(worker_record ctx_19 exited)"
write_worker_show ctx_19 exited
node -e '
  const fs = require("fs");
  const now = Math.floor(Date.now() / 1000);
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    resumes: {"test/repo#19": [now - 3600, now - 3600, now - 3600]},
    notified: {}
  }, null, 2));
' "$STATE"
STALL_MIN=0 run_keeper "$WORK/exited-over-limit.out"
expect_exit 0 "exited over the limit: exits 0"
expect_has $'\tEXITED\t' "exited over the limit: still reaches the conclusion" "$WORK/exited-over-limit.out"
expect_has "今日自动恢复已达 3 次" "exited over the limit: notifies instead" "$NOTIFY_LOG"
expect_count "" 0 "exited over the limit: closes nothing" "$WORK/orca.log"
expect_count "release 19 --force" 0 "exited over the limit: releases nothing" "$WORK/claim.log"
expect_without "launched" "exited over the limit: launches nothing" "$WORK/launch.log"

# A state file written by the keeper that still nudged carries a nudges map
# and no harm: it is read like any other, and nothing is nudged.
new_fixture legacy-nudge-state
stall_spec_19
write_workers '' "$(worker_record ctx_19 live)"
write_worker_show ctx_19 live
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1, resumes: {}, notified: {},
    nudges: {"test/repo#19": {at: Math.floor(Date.now() / 1000) - 3600, tabId: "tab1", leafId: "leaf1"}}
  }, null, 2));
' "$STATE"
STALL_MIN=0 run_keeper "$WORK/legacy-nudge.out"
expect_exit 0 "legacy nudge state: exits 0"
expect_has $'\tLIVE\t' "legacy nudge state: judged on Orca alone" "$WORK/legacy-nudge.out"
expect_without $'\tERROR\t' "legacy nudge state: nothing is sent to the old pane (the fake orca refuses a send)" "$WORK/legacy-nudge.out"

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
expect_count "" 0 "fresh: Orca is not asked about any worker (the file times already say all is well)" "$WORK/orca-query.log"
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
expect_count "" 0 "paused: the sweep is not called" "$SWEEP_LOG"

# --- the sweep of abandoned worktrees (规格 #26) ------------------------------
# Once a round, after the repositories, in keeper's own mode: a real round
# logs every removal, --dry-run passes --dry-run on and logs what would go,
# --repo is passed through, and a sweep that fails is reported, never fatal.

new_fixture sweep
touch "$FIXTURE/sweep-remove"
run_keeper "$WORK/sweep.out"
expect_exit 0 "sweep: exits 0"
expect_count "" 1 "sweep: called once, with no argument" "$SWEEP_LOG"
expect_same "" "$(cat "$SWEEP_LOG")" "sweep: a plain round passes no argument"
expect_has $'\tSWEEP\t' "sweep: the summary is logged" "$WORK/sweep.out"
expect_has "removed=1" "sweep: the summary carries the counts" "$WORK/sweep.out"
expect_has $'\tREMOVE_WORKTREE\t' "sweep: a removal is logged" "$WORK/sweep.out"
expect_has "/w/wt-spec-22" "sweep: the removal names the worktree" "$WORK/sweep.out"
expect_without "/w/repo" "sweep: a kept worktree is not logged one by one" "$WORK/sweep.out"
expect_count "" 0 "sweep: the round asks no orca action for it" "$WORK/orca.log"

new_fixture sweep-dry
touch "$FIXTURE/sweep-would"
run_keeper "$WORK/sweep-dry.out" --dry-run
expect_exit 0 "sweep --dry-run: exits 0"
expect_same "--dry-run" "$(cat "$SWEEP_LOG")" "sweep --dry-run: --dry-run is passed on"
expect_has $'\tWOULD_REMOVE_WORKTREE\t' "sweep --dry-run: logs what would go" "$WORK/sweep-dry.out"
expect_without $'\tREMOVE_WORKTREE\t' "sweep --dry-run: logs no removal" "$WORK/sweep-dry.out"

new_fixture sweep-repo
run_keeper "$WORK/sweep-repo.out" --repo test/repo
expect_exit 0 "sweep --repo: exits 0"
expect_has "--repo test/repo" "sweep --repo: --repo is passed on" "$SWEEP_LOG"

new_fixture sweep-fail
touch "$FIXTURE/sweep-fail"
run_keeper "$WORK/sweep-fail.out"
expect_exit 0 "sweep failure: exits 0"
expect_has "sweep-worktrees.sh" "sweep failure: is reported with the script's name" "$WORK/sweep-fail.out"
expect_has "orca offline" "sweep failure: carries the sweep's message" "$WORK/sweep-fail.out"
expect_has $'\tERROR\t' "sweep failure: is logged as an error" "$WORK/sweep-fail.out"
expect_has $'\tROUND\tend' "sweep failure: the round still ends" "$WORK/sweep-fail.out"

new_fixture sweep-missing
SWEEP_SCRIPT=$BIN/no-such-sweep.sh
run_keeper "$WORK/sweep-missing.out"
SWEEP_SCRIPT=$BIN/sweep-worktrees.sh
expect_exit 0 "sweep missing: exits 0"
expect_has "sweep-worktrees.sh" "sweep missing: is reported" "$WORK/sweep-missing.out"
expect_has $'\tSKIP\t' "sweep missing: is a skip" "$WORK/sweep-missing.out"

printf '\n%s\n' "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
