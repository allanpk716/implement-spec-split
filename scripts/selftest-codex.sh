#!/usr/bin/env bash
# Self-test for the codex External worker backend.
#
# Usage: scripts/selftest-codex.sh [--model glm-5.3] [--only L1|V1|V2|V3]
#
# V1 uses a deterministic fake codex and costs no tokens. V2 uses real codex-cli
# against local mock Responses servers and costs no GLM tokens. L1 and V3 use real GLM
# through Ferryman and do cost tokens. Scratch dirs live under
# ~/.cache/implement-spec-split-selftest-codex/<timestamp> and are removed only after a
# successful token-free level; a failed level keeps its artifacts for diagnosis.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORKER="$HERE/codex-worker.sh"
PROGRESS="$HERE/progress.sh"
FAKE="$HERE/testing/fake-codex.sh"
MODEL="glm-5.3"
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "${ONLY:-all}" in L1|V1|V2|V3|all) ;; *) echo "--only must be L1, V1, V2, or V3" >&2; exit 64 ;; esac

ROOT="$HOME/.cache/implement-spec-split-selftest-codex/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROOT"
FAILS=0
CLEAN_PIDS=()
CLEAN_WIN=()
mkdir -p "$ROOT/v1"
printf 'Say hello.\n' > "$ROOT/brief.md"
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
json() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s[process.argv[2]])' "$(cygpath -m "$1" 2>/dev/null || echo "$1")" "$2"; }
status_is() { local run="$1" want="$2"; [ "$(json "$run/status.json" status)" = "$want" ]; }
changed_has() { local run="$1" want="$2"; CHANGED_FILE="$(cygpath -m "$run/status.json" 2>/dev/null || echo "$run/status.json")" CHANGED_WANT="$want" node -e 'const s=JSON.parse(require("fs").readFileSync(process.env.CHANGED_FILE,"utf8"));process.exit(s.changed_paths.includes(process.env.CHANGED_WANT)?0:1)'; }
alive() { PID_W="$1" node -e 'try{process.kill(+process.env.PID_W,0);process.exit(0)}catch{process.exit(1)}'; }
cleanup() {
  for p in ${CLEAN_WIN[@]+"${CLEAN_WIN[@]}"}; do taskkill //T //F //PID "$p" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

if [ -z "$ONLY" ] || [ "$ONLY" = V1 ]; then
  echo "V1 fake codex"
  CODEX_HOME="$ROOT/v1-home"; mkdir -p "$CODEX_HOME/sessions" "$ROOT/v1"
  export CODEX_HOME CODEX_WORKER_CODEX="$FAKE" CODEX_WORKER_SKIP_PREFLIGHT=1 CODEX_WORKER_POLL=1
  export FAKE_CODEX_PID_LOG="$ROOT/fake-pids.log"
  BRIEF="$ROOT/brief.md"
  run_case() {
    local name="$1" scenario="$2" run="$ROOT/$3"; shift 3
    FAKE_CODEX_SCENARIO="$scenario" "$WORKER" --cwd "$ROOT/v1" --brief "$BRIEF" --run-dir "$run" --model "$MODEL" --retries 0 --time-limit 120 --idle-timeout 20 "$@" >/dev/null
    CASE_EXIT=$?
  }

  run_case ok ok ok-run --idle-timeout 20
  check "ok exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 0
  check "ok exit artifacts" test -s "$ROOT/ok-run/result.md" -a -s "$ROOT/ok-run/status.json" -a -s "$ROOT/ok-run/resume.json"
  check "ok session id" test "$(json "$ROOT/ok-run/status.json" session_id)" != ""
  check "ok progress finished" bash -c "'$PROGRESS' '$ROOT/ok-run' | grep -q '^state: finished: ok' && '$PROGRESS' '$ROOT/ok-run' | grep -q 'npm test'"
  check "ok progress unwraps command and prints it once" bash -c "test \"\$('$PROGRESS' '$ROOT/ok-run' 20 | grep -Fc '\$ npm test  -> exit 0')\" -eq 1"

  run_case 401 401 auth-run
  check "401 exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 2
  check "401 status auth" status_is "$ROOT/auth-run" auth
  check "401 not retried" test "$(json "$ROOT/auth-run/status.json" attempts)" -eq 1
  FAKE_CODEX_SCENARIO=429-then-ok "$WORKER" --cwd "$ROOT/v1" --brief "$BRIEF" --run-dir "$ROOT/retry-run" --model "$MODEL" --retries 2 --retry-wait 1 --time-limit 120 --idle-timeout 20 >/dev/null
  R=$?; check "429 retry exit code (got $R)" test "$R" -eq 0
  check "429 retry succeeds with 3 attempts" test "$(json "$ROOT/retry-run/status.json" attempts)" -eq 3
  run_case 429-forever 429-forever quota-run
  check "429 forever exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 4
  check "429 final error names quota ambiguity" bash -c "grep -q 'quota exhausted' '$ROOT/quota-run/status.json'"
  check "429 final error keeps original message" bash -c "grep -q '429 Too Many Requests' '$ROOT/quota-run/status.json'"
  run_case network network-wait network-run
  check "network wait exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 4
  check "network wait reports proxy" bash -c "grep -q 'proxy unreachable' '$ROOT/network-run/status.json'"
  run_case reconnect reconnect-only reconnect-run
  check "reconnect exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 7
  check "reconnect errors do not reset idle" test "$(json "$ROOT/reconnect-run/status.json" status)" = stalled
  run_case silent silent silent-run
  check "silent exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 7
  check "silent run stalls" test "$(json "$ROOT/silent-run/status.json" status)" = stalled

  FAKE_CODEX_SCENARIO=busy-forever "$WORKER" --cwd "$ROOT/v1" --brief "$BRIEF" --run-dir "$ROOT/time-run" --model "$MODEL" --retries 0 --time-limit 6 --idle-timeout 20 >/dev/null
  TR=$?; check "busy run hits Time limit (exit $TR)" test "$TR" -eq 5
  OLD_SESSION=$(json "$ROOT/time-run/status.json" session_id)
  FAKE_CODEX_ARGS_LOG="$ROOT/resume-args.jsonl" FAKE_CODEX_SCENARIO=ok "$WORKER" --resume --run-dir "$ROOT/time-run" --retries 0 --time-limit 30 --idle-timeout 20 >/dev/null
  RR=$?; check "resume exit code (got $RR)" test "$RR" -eq 0
  check "resume segments = 2" test "$(json "$ROOT/time-run/status.json" segments)" -eq 2
  RESUME_ID="$OLD_SESSION" node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const id=process.env.RESUME_ID,r=a.indexOf("resume");if(r<0||a[r+1]!==id||a.slice(r+2).join(" ")!=="-")process.exit(1);for(const f of ["--json","-m","-o","-C","--dangerously-bypass-approvals-and-sandbox","--disable"])if(a.indexOf(f)>r)process.exit(1)' "$ROOT/resume-args.jsonl"
  check "resume argv order and thread are valid" test $? -eq 0

  new_readonly_repo() {
    local repo="$ROOT/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.name selftest
    git -C "$repo" config user.email selftest@example.invalid
    printf 'tracked\n' > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt
    git -C "$repo" commit -q -m init
  }
  readonly_case() {
    local scenario="$1" repo="$2" run="$3"; shift 3
    FAKE_CODEX_SCENARIO="$scenario" "$WORKER" --cwd "$ROOT/$repo" --brief "$BRIEF" --run-dir "$ROOT/$run" \
      --model "$MODEL" --retries 0 --time-limit 120 --idle-timeout 20 --read-only "$@" >/dev/null
    RO_EXIT=$?
  }

  new_readonly_repo ro-clean-repo
  readonly_case read-only-clean ro-clean-repo ro-clean-run
  check "read-only clean exit code (got $RO_EXIT)" test "$RO_EXIT" -eq 0
  check "read-only clean has no violation" test "$(json "$ROOT/ro-clean-run/status.json" read_only_violation)" = false
  check "read-only clean prompt starts with instruction" bash -c "head -1 '$ROOT/ro-clean-run/prompt-1.md' | grep -q '^本任务只读'"

  new_readonly_repo ro-large-repo
  for i in $(seq 1 2000); do
    printf 'large workspace\n' > "$ROOT/ro-large-repo/$(printf 'untracked-with-a-fairly-long-name-%04d.txt' "$i")"
  done
  readonly_case read-only-clean ro-large-repo ro-large-clean-run
  check "read-only large clean exit code (got $RO_EXIT)" test "$RO_EXIT" -eq 0
  check "read-only large clean has no violation" test "$(json "$ROOT/ro-large-clean-run/status.json" read_only_violation)" = false
  FAKE_CODEX_TARGET=created-by-fake.txt readonly_case read-only-untracked ro-large-repo ro-large-untracked-run
  check "read-only large untracked change exits 8 (got $RO_EXIT)" test "$RO_EXIT" -eq 8
  check "read-only large untracked path reported" changed_has "$ROOT/ro-large-untracked-run" created-by-fake.txt

  new_readonly_repo ro-tracked-repo
  readonly_case read-only-tracked ro-tracked-repo ro-tracked-run
  check "read-only tracked change exits 8 (got $RO_EXIT)" test "$RO_EXIT" -eq 8
  check "read-only tracked change status" status_is "$ROOT/ro-tracked-run" violation
  check "read-only tracked path reported" changed_has "$ROOT/ro-tracked-run" tracked.txt

  new_readonly_repo ro-untracked-repo
  FAKE_CODEX_TARGET=untracked.txt readonly_case read-only-untracked ro-untracked-repo ro-untracked-run
  check "read-only untracked change exits 8 (got $RO_EXIT)" test "$RO_EXIT" -eq 8
  check "read-only untracked path reported" changed_has "$ROOT/ro-untracked-run" untracked.txt

  new_readonly_repo ro-dirty-repo
  printf 'pre-dirty\n' >> "$ROOT/ro-dirty-repo/tracked.txt"
  readonly_case read-only-dirty-more ro-dirty-repo ro-dirty-run
  check "read-only dirty-file change exits 8 (got $RO_EXIT)" test "$RO_EXIT" -eq 8
  check "read-only dirty-file path reported" changed_has "$ROOT/ro-dirty-run" tracked.txt

  new_readonly_repo ro-commit-repo
  readonly_case read-only-commit ro-commit-repo ro-commit-run
  check "read-only commit exits 8 (got $RO_EXIT)" test "$RO_EXIT" -eq 8
  check "read-only commit reports HEAD" changed_has "$ROOT/ro-commit-run" "<HEAD>"

  new_readonly_repo ro-break-repo
  CODEX_WORKER_TEST_BREAK_FINGERPRINT_END=1 FAKE_CODEX_SCENARIO=read-only-clean \
    "$WORKER" --cwd "$ROOT/ro-break-repo" --brief "$BRIEF" --run-dir "$ROOT/ro-break-run" \
    --model "$MODEL" --retries 0 --time-limit 120 --idle-timeout 20 --read-only >/dev/null
  RB=$?; check "read-only broken end fingerprint exits 8 (got $RB)" test "$RB" -eq 8
  check "read-only broken end fingerprint is a violation" status_is "$ROOT/ro-break-run" violation
  check "read-only broken end fingerprint path reported" changed_has "$ROOT/ro-break-run" "<fingerprint>"
  check "read-only broken end fingerprint logs reason" bash -c "grep -q 'read-only fingerprint check failed' '$ROOT/ro-break-run/stderr.log'"

  mkdir -p "$ROOT/ro-not-git"
  "$WORKER" --cwd "$ROOT/ro-not-git" --brief "$BRIEF" --run-dir "$ROOT/ro-not-git-run" --read-only >/dev/null 2>&1
  NG=$?; check "read-only non-git cwd exits 64 (got $NG)" test "$NG" -eq 64

  new_readonly_repo ro-resume-repo
  FAKE_CODEX_SCENARIO=busy-forever "$WORKER" --cwd "$ROOT/ro-resume-repo" --brief "$BRIEF" --run-dir "$ROOT/ro-resume-run" \
    --model "$MODEL" --retries 0 --time-limit 2 --idle-timeout 20 --read-only >/dev/null
  RT=$?; check "read-only timeout keeps exit 5 (got $RT)" test "$RT" -eq 5
  check "read-only timeout records no violation" test "$(json "$ROOT/ro-resume-run/status.json" read_only_violation)" = false
  FAKE_CODEX_SCENARIO=read-only-tracked "$WORKER" --resume --run-dir "$ROOT/ro-resume-run" --retries 0 --time-limit 30 --idle-timeout 20 >/dev/null
  RR=$?; check "read-only resume violation exits 8 (got $RR)" test "$RR" -eq 8
  check "read-only resume reports path" changed_has "$ROOT/ro-resume-run" tracked.txt
  check "read-only resume prompt avoids commit instruction" bash -c "! grep -q 'commit the work' '$ROOT/ro-resume-run/prompt-2.md' && grep -q '继续完成调查，不要修改任何文件' '$ROOT/ro-resume-run/prompt-2.md'"
  "$WORKER" --resume --run-dir "$ROOT/ro-resume-run" --read-only >/dev/null 2>&1
  RRO=$?; check "resume rejects repeated read-only (got $RRO)" test "$RRO" -eq 64

  new_readonly_repo ro-missing-baseline-repo
  FAKE_CODEX_SCENARIO=busy-forever "$WORKER" --cwd "$ROOT/ro-missing-baseline-repo" --brief "$BRIEF" --run-dir "$ROOT/ro-missing-baseline-run" \
    --model "$MODEL" --retries 0 --time-limit 2 --idle-timeout 20 --read-only >/dev/null
  MB=$?; check "read-only missing-baseline timeout exits 5 (got $MB)" test "$MB" -eq 5
  rm "$ROOT/ro-missing-baseline-run/fingerprint-start.json"
  "$WORKER" --resume --run-dir "$ROOT/ro-missing-baseline-run" --retries 0 --time-limit 30 --idle-timeout 20 >/dev/null 2>&1
  MR=$?; check "read-only resume without baseline exits 64 (got $MR)" test "$MR" -eq 64

  check "non-read-only status omits fields" bash -c "node -e 'const s=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit([\"read_only\",\"read_only_violation\",\"changed_paths\"].some(k=>Object.hasOwn(s,k))?1:0)' \"\$(cygpath -m '$ROOT/ok-run/status.json')\""

  "$WORKER" --resume --run-dir "$ROOT/no-state" >/dev/null 2>&1; check "resume without state exits 64" test $? -eq 64
  "$WORKER" --resume --run-dir "$ROOT/no-such-run" >/dev/null 2>&1; check "resume missing run exits 64" test $? -eq 64
  "$WORKER" --resume --run-dir "$ROOT/ok-run" --cwd "$ROOT/v1" >/dev/null 2>&1; check "resume rejects cwd" test $? -eq 64
  LOST="$ROOT/lost-run"; mkdir -p "$LOST"
  node -e 'const p=process.argv[1],f=require("fs");const id="11111111-2222-3333-4444-555555555555";f.writeFileSync(p+"/resume.json",JSON.stringify({cwd:p,model:"glm-5.3",skills:[],thinking:"",add_dirs:[],session_id:id,base_head:"",segments:1,attempts:1}))' "$LOST"
  FAKE_CODEX_ARGS_LOG="$ROOT/lost-args.jsonl" "$WORKER" --resume --run-dir "$LOST" >/dev/null 2>&1
  BR=$?; check "missing rollout exits 64 without codex" bash -c "test $BR -eq 64 && ! test -s '$ROOT/lost-args.jsonl'"
  node -e 'const p=process.argv[1],f=require("fs");const s=JSON.parse(f.readFileSync(p+"/resume.json"));s.session_id="11111111-2222-3333-4444-555555555555";f.writeFileSync(p+"/resume.json",JSON.stringify(s,null,2))' "$ROOT/ok-run"
  "$WORKER" --resume --run-dir "$ROOT/ok-run" >/dev/null 2>&1
  sleep 1
  check "bad resume keeps finished progress state" bash -c "'$PROGRESS' '$ROOT/ok-run' | grep -q '^state: finished: ok'"

  GRAND_PID_FILE="$ROOT/grandchild.pid"
  FAKE_CODEX_GRANDCHILD_MARKER="$GRAND_PID_FILE" FAKE_CODEX_SCENARIO=grandchild "$WORKER" --cwd "$ROOT/v1" --brief "$BRIEF" --run-dir "$ROOT/grand-run" --retries 0 --time-limit 60 --idle-timeout 6 >/dev/null
  GR=$?; check "grandchild case exit code (got $GR)" test "$GR" -eq 7
  GP=$(cat "$GRAND_PID_FILE" 2>/dev/null); sleep 2
  if alive "$GP"; then fail "grandchild survived tree kill"; else pass "grandchild killed with tree"; fi
  check "kill confirmation logged" bash -c "grep -q '^kill confirmed:' '$ROOT/grand-run/stderr.log'"

  run_case stdin stdin-echo stdin-run
  check "stdin echo exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 0
  check "prompt reached codex through finite stdin" grep -q "Say hello" "$ROOT/stdin-run/result.md"
  run_case salvage answered-not-completed salvage-run
  check "salvage exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 7
  check "idle salvage saved final reply" bash -c "grep -q 'final answer' '$ROOT/salvage-run/result.md' && grep -q 'already gave a final reply' '$ROOT/salvage-run/status.json'"
  run_case commentary commentary-then-hang commentary-run
  check "commentary case exit code (got $CASE_EXIT)" test "$CASE_EXIT" -eq 7
  check "commentary has no salvage error" bash -c "! grep -q 'final reply' '$ROOT/commentary-run/status.json'"
  check "commentary result_file is null" test "$(json "$ROOT/commentary-run/status.json" result_file)" = null

  FAKE_CODEX_SCENARIO=busy-forever "$WORKER" --cwd "$ROOT/v1" --brief "$BRIEF" --run-dir "$ROOT/dead-run" --retries 0 --time-limit 120 --idle-timeout 20 >/dev/null &
  WPID=$!
  for _ in 1 2 3 4 5; do [ -s "$ROOT/dead-run/pid" ] && break; sleep 1; done
  WWIN=$(awk '{print $1}' "$ROOT/dead-run/pid" 2>/dev/null || echo 0)
  taskkill //T //F //PID "$WWIN" >/dev/null 2>&1 || true
  wait $WPID >/dev/null 2>&1
  FWIN=$(tail -1 "$ROOT/fake-pids.log" 2>/dev/null || echo 0); taskkill //T //F //PID "$FWIN" >/dev/null 2>&1 || true
  sleep 1
  check "progress reports dead wrapper" bash -c "'$PROGRESS' '$ROOT/dead-run' | grep -q '^state: dead'"

  node -e "setTimeout(()=>{},60000)" &
  REUSE_PID=$!
  for _ in 1 2 3 4 5; do [ -r /proc/$REUSE_PID/winpid ] && break; sleep 1; done
  REUSE_WIN=$(cat "/proc/$REUSE_PID/winpid" 2>/dev/null || echo 0)
  [ -n "$REUSE_WIN" ] && CLEAN_WIN+=("$REUSE_WIN")
  REUSE_TICKS=$(powershell.exe -NoProfile -Command "(Get-Process -Id $REUSE_WIN).StartTime.ToUniversalTime().Ticks" 2>/dev/null | tr -d '\r')
  printf '%s %s\n' "$REUSE_WIN" "$REUSE_TICKS" > "$ROOT/stdin-run/pid"
  touch "$ROOT/stdin-run/status.json"
  check "recycled live pid cannot override finished state" bash -c "'$PROGRESS' '$ROOT/stdin-run' | grep -q '^state: finished: ok'"

  mkdir -p "$ROOT/pid-reuse-run"
  printf '%s 1\n' "$REUSE_WIN" > "$ROOT/pid-reuse-run/pid"
  check "live pid with wrong start ticks is dead" bash -c "'$PROGRESS' '$ROOT/pid-reuse-run' | grep -q '^state: dead'"
  printf '%s %s\n' "$REUSE_WIN" "$REUSE_TICKS" > "$ROOT/pid-reuse-run/pid"
  check "live pid with matching start ticks is running" bash -c "'$PROGRESS' '$ROOT/pid-reuse-run' | grep -q '^state: running'"
  taskkill //T //F //PID "$REUSE_WIN" >/dev/null 2>&1 || true
fi

if [ -z "$ONLY" ] || [ "$ONLY" = V2 ]; then
  echo "V2 real codex + mock provider"
  PORT=$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  MOCK="$ROOT/mock"; mkdir -p "$MOCK"
  start_mock() {
    local mode="$1" port="$2"; shift 2
    node "$HERE/testing/mock-responses.js" "$port" "$mode" "$@" > "$MOCK/$mode-$port.log" 2>&1 &
    CLEAN_PIDS+=($!)
    [ -r /proc/$!/winpid ] && CLEAN_WIN+=("$(cat /proc/$!/winpid)")
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q listening "$MOCK/$mode-$port.log" && return 0; sleep 1; done
    return 1
  }
  v2() { local name="$1" run="$ROOT/$2"; shift 2; "$@" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$run" --model "$MODEL" --retries 0 >/dev/null; }
  start_mock status "$PORT" 429 '{"error":{"code":"1302","message":"rate limit"}}'
  CODEX_WORKER_BASE_URL="http://127.0.0.1:$PORT/v1" CODEX_WORKER_SKIP_PREFLIGHT=0 "$WORKER" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$ROOT/v2-429" --model "$MODEL" --retries 0 --time-limit 120 --idle-timeout 60 >/dev/null
  R=$?; check "mock 429 exits transient (got $R)" test "$R" -eq 4; check "mock 429 names quota" bash -c "grep -q 'quota exhausted' '$ROOT/v2-429/status.json'"
  PORT2=$((PORT + 1)); start_mock status "$PORT2" 401 '{"error":{"message":"unauthorized"}}'
  CODEX_WORKER_BASE_URL="http://127.0.0.1:$PORT2/v1" "$WORKER" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$ROOT/v2-401" --model "$MODEL" --retries 0 --time-limit 120 --idle-timeout 60 >/dev/null
  R=$?; check "mock 401 exits auth (got $R)" test "$R" -eq 2
  CLOSED=$((PORT + 20)); T0=$(date +%s)
  CODEX_WORKER_BASE_URL="http://127.0.0.1:$CLOSED/v1" CODEX_WORKER_SKIP_PREFLIGHT=1 "$WORKER" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$ROOT/v2-closed" --model "$MODEL" --retries 0 --time-limit 150 --idle-timeout 150 >/dev/null
  R=$?; T1=$(date +%s); check "closed proxy detected within 150s ($((T1-T0))s)" bash -c "test $R -eq 4 && test $((T1-T0)) -le 150"
  PORT3=$((PORT + 2)); start_mock sse-hang "$PORT3"
  T2=$(date +%s)
  CODEX_WORKER_BASE_URL="http://127.0.0.1:$PORT3/v1" "$WORKER" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$ROOT/v2-sse" --model "$MODEL" --retries 0 --time-limit 600 --idle-timeout 600 >/dev/null
  R=$?; T3=$(date +%s); SSE=$((T3-T2))
  check "sse hang exits codex transient (got $R)" test "$R" -eq 4
  check "sse hang mentions stream idle/disconnection" bash -c "grep -Eiq 'stream|idle|disconnect' '$ROOT/v2-sse/status.json'"
  check "sse hang bounded by codex retry budget (${SSE}s)" test "$SSE" -le 480
  CODEX_WORKER_BASE_URL="http://127.0.0.1:$CLOSED/v1" CODEX_WORKER_SKIP_PREFLIGHT=0 "$WORKER" --cwd "$ROOT/v1" --brief "$ROOT/brief.md" --run-dir "$ROOT/v2-preflight" --model "$MODEL" --retries 0 >/dev/null
  R=$?; check "preflight failure is immediate transient (got $R)" test "$R" -eq 4
fi

if [ -z "$ONLY" ] || [ "$ONLY" = L1 ]; then
  echo "L1 real GLM (not run by agent)"
  mkdir -p "$ROOT/l1"; printf 'Reply with exactly the word: ok. Do not use any tools.\n' > "$ROOT/l1.brief"
  "$WORKER" --cwd "$ROOT/l1" --brief "$ROOT/l1.brief" --run-dir "$ROOT/l1-run" --model "$MODEL" --time-limit 120 --idle-timeout 30 --retries 0 >/dev/null
  [ $? -eq 0 ] && pass "codex answered on $MODEL" || fail "codex L1 failed"
fi

if [ -z "$ONLY" ] || [ "$ONLY" = V3 ]; then
  echo "V3 real GLM integration (not run by agent)"
  TDD_SKILL=$(ls -d "$HOME"/.claude/plugins/cache/mattpocock/mattpocock-skills/*/skills/*/tdd 2>/dev/null | sort -V | tail -1)
  [ -n "$TDD_SKILL" ] || TDD_SKILL="$HOME/.agents/skills/tdd"
  [ -d "$TDD_SKILL" ] || fail "tdd skill not found"
  REPO="$ROOT/v3-repo"; mkdir -p "$REPO"
  (
    cd "$REPO" && git init -q -b main
    printf '{"name":"codex-selftest","private":true,"scripts":{"test":"node --test"}}\n' > package.json
    printf 'node_modules/\n' > .gitignore
    printf '# selftest\n\nEvery commit message must start with `[selftest]`.\n' > CLAUDE.md
    git add -A && git commit -q -m "init" && git branch integration
    git worktree add -q "$ROOT/v3-clamp" -b clamp integration
    git worktree add -q "$ROOT/v3-resume" -b resume integration
    git worktree add -q "$ROOT/v3-parallel-1" -b parallel-1 integration
    git worktree add -q "$ROOT/v3-parallel-2" -b parallel-2 integration
  )
  cat > "$ROOT/clamp.brief" <<'EOF'
# Add `clamp`
Create `clamp.js` exporting `clamp(value, min, max)`, throwing RangeError when min > max.
Use node:test/node:assert in `clamp.test.js`, run `npm test`, and leave one clean commit.
EOF
  "$WORKER" --cwd "$ROOT/v3-clamp" --brief "$ROOT/clamp.brief" --run-dir "$ROOT/v3-clamp-run" --skill "$TDD_SKILL" --model "$MODEL" --time-limit 900 --idle-timeout 180 >/dev/null
  V3=$?
  check "V3 clamp exit 0 (got $V3)" test "$V3" -eq 0
  check "V3 clamp has new commits" test "$(json "$ROOT/v3-clamp-run/status.json" new_commits)" -ge 1
  check "V3 clamp clean and tested" bash -c "cd '$ROOT/v3-clamp' && test -z \"\$(git status --porcelain)\" && node --test"
  check "V3 SKILL.md was read" bash -c "grep -Eiq 'tdd.{0,80}SKILL.md|SKILL.md.{0,80}tdd' '$ROOT/v3-clamp-run/events.jsonl'"
  check "V3 CLAUDE commit rule obeyed" bash -c "git -C '$ROOT/v3-clamp' log --format=%s -1 | grep -q '^\[selftest\]'"

  cat > "$ROOT/str.brief" <<'EOF'
# Add string helpers
In `str.js`, implement and test `initials`, `truncate`, `slug`, and `pluralize` with
node:test/node:assert. Work test-first and leave one clean commit.
EOF
  "$WORKER" --cwd "$ROOT/v3-resume" --brief "$ROOT/str.brief" --run-dir "$ROOT/v3-resume-run" --skill "$TDD_SKILL" --model "$MODEL" --time-limit 10 --idle-timeout 180 >/dev/null
  check "V3 resume segment 1 timed out" test "$(json "$ROOT/v3-resume-run/status.json" status)" = timeout
  "$WORKER" --resume --run-dir "$ROOT/v3-resume-run" --time-limit 900 --idle-timeout 180 >/dev/null
  check "V3 resume finishes with two segments" test "$(json "$ROOT/v3-resume-run/status.json" segments)" -eq 2
  check "V3 resume has new commits" test "$(json "$ROOT/v3-resume-run/status.json" new_commits)" -ge 1
  check "V3 resume work tested" bash -c "cd '$ROOT/v3-resume' && node --test"

  for n in 1 2; do
    "$WORKER" --cwd "$ROOT/v3-parallel-$n" --brief "$ROOT/clamp.brief" --run-dir "$ROOT/v3-parallel-$n-run" --skill "$TDD_SKILL" --model "$MODEL" --time-limit 900 --idle-timeout 180 >/dev/null &
    eval "PAR_PID_$n=$!"
  done
  PROGRESS_SAW_RUNNING=false
  while kill -0 "$PAR_PID_1" 2>/dev/null || kill -0 "$PAR_PID_2" 2>/dev/null; do
    if [ -s "$ROOT/v3-parallel-1-run/pid" ] && "$PROGRESS" "$ROOT/v3-parallel-1-run" 3 2>/dev/null | grep -q '^state: running'; then PROGRESS_SAW_RUNNING=true; break; fi
    sleep 2
  done
  wait "$PAR_PID_1"; P1=$?; wait "$PAR_PID_2"; P2=$?
  check "V3 parallel workers both pass ($P1/$P2)" test "$P1" -eq 0 -a "$P2" -eq 0
  for n in 1 2; do
    check "V3 parallel run $n has commits" test "$(json "$ROOT/v3-parallel-$n-run/status.json" new_commits)" -ge 1
    check "V3 parallel run $n is clean" test -z "$(git -C "$ROOT/v3-parallel-$n" status --porcelain)"
  done
  check "V3 progress showed running worker" test "$PROGRESS_SAW_RUNNING" = true
  check "V3 no codex storage lock errors" bash -c "! grep -Eiq 'sqlite|database is locked' '$ROOT'/v3-parallel-*-run/stderr.log"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  if [ -z "$ONLY" ] || [ "$ONLY" = V1 ] || [ "$ONLY" = V2 ]; then rm -rf "$ROOT"; fi
  echo "OK: all checks passed"
else
  echo "FAILED: $FAILS check(s). Scratch kept: $ROOT"; exit 1
fi
