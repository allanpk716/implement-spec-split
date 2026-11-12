#!/usr/bin/env bash
# Deterministic concurrency tests for locks, claims, and worker slots.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LOCK="$HERE/lock.sh"
CLAIM="$HERE/claim.sh"
WORKER="$HERE/codex-worker.sh"
PROGRESS="$HERE/progress.sh"
FAKE="$HERE/testing/fake-codex.sh"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iss-locks-test.XXXXXX")
export ISS_STATE_DIR="$TEST_ROOT/state"
export ISS_LOCK_POLL=0.02
export ISS_WORKER_SLOT_POLL=0.02
export CODEX_WORKER_CODEX="$FAKE"
export CODEX_WORKER_SKIP_PREFLIGHT=1
export CODEX_WORKER_POLL=1
export CODEX_HOME="$TEST_ROOT/codex-home"
export FAKE_CODEX_SCENARIO=slot-hold

PASS=0
FAIL=0
BACKGROUND_PIDS=()

pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
expect_rc() {
  local description="$1" wanted="$2" got="$3"
  if [ "$wanted" = "$got" ]; then pass "$description"; else fail "$description (wanted $wanted, got $got)"; fi
}

wait_file() {
  local file="$1" timeout="${2:-5}" i
  for i in $(seq 1 $((timeout * 100))); do
    [ -e "$file" ] && return 0
    sleep 0.01
  done
  return 1
}

wait_pid_exit() {
  local pid="$1" timeout="${2:-10}" i
  for i in $(seq 1 $((timeout * 100))); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.01
  done
  return 1
}

cleanup() {
  local pid
  for pid in ${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in ${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

cat > "$TEST_ROOT/lock-holder-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -u
name=$1
release_marker=$2
test_root=$3
lock=$4
export ISS_OWNER_PID=$$
while [ ! -e "$test_root/race-start" ]; do sleep 0.01; done
slot=false
lock_name=$name
slot_number=1
if [[ "$name" == SLOT:* ]]; then
  slot=true
  lock_name=${name#SLOT:}
fi
if $slot; then
  slot_number=$("$lock" slot-acquire "$lock_name" --max 2 --wait 5)
else
  "$lock" acquire "$lock_name" --scope global --wait 5
fi
rc=$?
printf '%s\n' "$rc" > "$test_root/holder-$ISS_OWNER_PID-rc"
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s\n' "$ISS_OWNER_PID" > "$test_root/holder-$ISS_OWNER_PID-got"
while [ ! -e "$release_marker" ]; do sleep 0.01; done
if $slot; then
  "$lock" slot-release "$lock_name" "$slot_number"
else
  "$lock" release "$lock_name" --scope global
fi
EOF

start_lock_holder() {
  local name="$1" release_marker="$2" log="$3"
  bash "$TEST_ROOT/lock-holder-helper.sh" "$name" "$release_marker" "$TEST_ROOT" "$LOCK" >"$log" 2>&1 &
  LAST_HOLDER_PID=$!
  BACKGROUND_PIDS+=("$LAST_HOLDER_PID")
}

cat > "$TEST_ROOT/takeover-race-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -u
mode=$1
name=$2
gate=$3
events=$4
rc_file=$5
max=$6
lock=$7
export ISS_OWNER_PID=$$
while [ ! -e "$gate" ]; do sleep 0.01; done

slot=""
if [ "$mode" = slot ]; then
  slot=$("$lock" slot-acquire "$name" --max "$max" --wait 10 --owner-pid "$ISS_OWNER_PID")
else
  "$lock" acquire "$name" --scope global --wait 10 --owner-pid "$ISS_OWNER_PID"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$rc" > "$rc_file"
  exit "$rc"
fi

printf 'enter\t%s\t%s\n' "$ISS_OWNER_PID" "$slot" >> "$events"
sleep 0.03
printf 'leave\t%s\t%s\n' "$ISS_OWNER_PID" "$slot" >> "$events"
if [ "$mode" = slot ]; then
  "$lock" slot-release "$name" "$slot" --owner-pid "$ISS_OWNER_PID"
else
  "$lock" release "$name" --scope global --owner-pid "$ISS_OWNER_PID"
fi
release_rc=$?
printf '%s\n' "$release_rc" > "$rc_file"
exit "$release_rc"
EOF

echo "lock contention"
mkdir -p "$ISS_STATE_DIR"
start_lock_holder contended "$TEST_ROOT/release-contended" "$TEST_ROOT/holder1.log"; P1=$LAST_HOLDER_PID
start_lock_holder contended "$TEST_ROOT/release-contended" "$TEST_ROOT/holder2.log"; P2=$LAST_HOLDER_PID
touch "$TEST_ROOT/race-start"
for i in $(seq 1 500); do
  [ "$(find "$TEST_ROOT" -maxdepth 1 -name 'holder-*-got' | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 0.01
done
check "one holder acquires first" test "$(find "$TEST_ROOT" -maxdepth 1 -name 'holder-*-got' | wc -l | tr -d ' ')" = 1
touch "$TEST_ROOT/release-contended"
wait_pid_exit "$P1" && wait_pid_exit "$P2"
check "both sequential holders acquire" test "$(find "$TEST_ROOT" -maxdepth 1 -name 'holder-*-got' | wc -l | tr -d ' ')" = 2
check "contention lock is free" bash -c "[ \"\$($LOCK status contended --scope global)\" = free ]"

echo "stale takeover, release, and wait behavior"
ISS_OWNER_PID=$$ "$LOCK" acquire stale --scope global >/dev/null
OLD_START=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid_start)' "$ISS_STATE_DIR/locks/stale.lock/owner.json")
cat > "$TEST_ROOT/fake-ps" <<'EOF'
#!/usr/bin/env bash
if [ "${ISS_FAKE_LSTART_MODE:-old}" = new ]; then printf '%s\n' 'Thu Jan 1 00:00:00 2000'; else printf '%s\n' "$ISS_FAKE_LSTART_OLD"; fi
EOF
chmod +x "$TEST_ROOT/fake-ps"
TAKEOVER_ERR=$(ISS_PS_LSTART_CMD="$TEST_ROOT/fake-ps" ISS_FAKE_LSTART_MODE=new ISS_FAKE_LSTART_OLD="$OLD_START" \
  "$LOCK" acquire stale --scope global --owner-pid $$ 2>&1 >/dev/null)
check "dead owner is taken over" grep -q 'took over stale' <<< "$TAKEOVER_ERR"
"$LOCK" release stale --scope global --force

echo "takeover race stress"
for race_round in $(seq 1 5); do
  LOCK_NAME="race-lock-$race_round"
  ISS_OWNER_PID=$$ "$LOCK" acquire "$LOCK_NAME" --scope global >/dev/null
  OLD_RACE_START=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid_start)' \
    "$ISS_STATE_DIR/locks/$LOCK_NAME.lock/owner.json")
  GATE="$TEST_ROOT/$LOCK_NAME-gate"
  EVENTS="$TEST_ROOT/$LOCK_NAME-events"
  RC_PREFIX="$TEST_ROOT/$LOCK_NAME-rc"
  : > "$EVENTS"
  RACE_PIDS=()
  for i in $(seq 1 8); do
    ISS_PS_LSTART_CMD="$TEST_ROOT/fake-ps" ISS_FAKE_LSTART_MODE=new ISS_FAKE_LSTART_OLD="$OLD_RACE_START" \
      bash "$TEST_ROOT/takeover-race-helper.sh" lock "$LOCK_NAME" "$GATE" "$EVENTS" "$RC_PREFIX-$i" 1 "$LOCK" \
      >"$TEST_ROOT/$LOCK_NAME-$i.log" 2>&1 &
    race_pid=$!
    RACE_PIDS+=("$race_pid")
    BACKGROUND_PIDS+=("$race_pid")
  done
  touch "$GATE"
  for pid in "${RACE_PIDS[@]}"; do
    wait_pid_exit "$pid" 15 || fail "lock race process $pid did not finish (round $race_round)"
    wait "$pid" 2>/dev/null || true
  done
  LOCK_SUCCESS_COUNT=0
  for rc_file in "$RC_PREFIX"-*; do
    [ "$(cat "$rc_file")" = 0 ] && LOCK_SUCCESS_COUNT=$((LOCK_SUCCESS_COUNT + 1))
  done
  check "all lock racers acquire in round $race_round" test "$LOCK_SUCCESS_COUNT" = 8
  check "lock racers are serialized in round $race_round" \
    env RACE_EVENTS="$EVENTS" node -e '
      const fs = require("fs");
      const lines = fs.readFileSync(process.env.RACE_EVENTS, "utf8").trim().split(/\n/);
      let active = 0, max = 0;
      for (const line of lines) {
        if (line.startsWith("enter\t")) { active++; max = Math.max(max, active); }
        else if (line.startsWith("leave\t")) active--;
        if (active < 0) process.exit(1);
      }
      process.exit(active === 0 && max === 1 ? 0 : 1);
    '
  check "lock takeover mutex is removed in round $race_round" test ! -e "$ISS_STATE_DIR/locks/$LOCK_NAME.lock.takeover"
  "$LOCK" release "$LOCK_NAME" --scope global --force
done

echo "slot takeover race stress"
for race_round in $(seq 1 5); do
  SLOT_NAME="race-slots-$race_round"
  ISS_OWNER_PID=$$ "$LOCK" slot-acquire "$SLOT_NAME" --max 2 >/dev/null
  ISS_OWNER_PID=$$ "$LOCK" slot-acquire "$SLOT_NAME" --max 2 >/dev/null
  OLD_RACE_START=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid_start)' \
    "$ISS_STATE_DIR/locks/$SLOT_NAME.slots/1.lock/owner.json")
  GATE="$TEST_ROOT/$SLOT_NAME-gate"
  EVENTS="$TEST_ROOT/$SLOT_NAME-events"
  RC_PREFIX="$TEST_ROOT/$SLOT_NAME-rc"
  : > "$EVENTS"
  RACE_PIDS=()
  for i in $(seq 1 8); do
    ISS_PS_LSTART_CMD="$TEST_ROOT/fake-ps" ISS_FAKE_LSTART_MODE=new ISS_FAKE_LSTART_OLD="$OLD_RACE_START" \
      bash "$TEST_ROOT/takeover-race-helper.sh" slot "$SLOT_NAME" "$GATE" "$EVENTS" "$RC_PREFIX-$i" 2 "$LOCK" \
      >"$TEST_ROOT/$SLOT_NAME-$i.log" 2>&1 &
    race_pid=$!
    RACE_PIDS+=("$race_pid")
    BACKGROUND_PIDS+=("$race_pid")
  done
  touch "$GATE"
  for pid in "${RACE_PIDS[@]}"; do
    wait_pid_exit "$pid" 15 || fail "slot race process $pid did not finish (round $race_round)"
    wait "$pid" 2>/dev/null || true
  done
  SLOT_SUCCESS_COUNT=0
  for rc_file in "$RC_PREFIX"-*; do
    [ "$(cat "$rc_file")" = 0 ] && SLOT_SUCCESS_COUNT=$((SLOT_SUCCESS_COUNT + 1))
  done
  check "all slot racers acquire in round $race_round" test "$SLOT_SUCCESS_COUNT" = 8
  check "slot racers respect max 2 in round $race_round" \
    env RACE_EVENTS="$EVENTS" node -e '
      const fs = require("fs");
      const lines = fs.readFileSync(process.env.RACE_EVENTS, "utf8").trim().split(/\n/);
      let active = 0, max = 0;
      for (const line of lines) {
        if (line.startsWith("enter\t")) { active++; max = Math.max(max, active); }
        else if (line.startsWith("leave\t")) active--;
        if (active < 0) process.exit(1);
      }
      process.exit(active === 0 && max > 0 && max <= 2 ? 0 : 1);
    '
  check "slot takeover mutexes are removed in round $race_round" \
    bash -c "[ ! -e '$ISS_STATE_DIR/locks/$SLOT_NAME.slots/1.lock.takeover' ] && [ ! -e '$ISS_STATE_DIR/locks/$SLOT_NAME.slots/2.lock.takeover' ]"
  "$LOCK" slot-release "$SLOT_NAME" 1 --force
  "$LOCK" slot-release "$SLOT_NAME" 2 --force
done

echo "residual takeover mutex"
ISS_OWNER_PID=$$ "$LOCK" acquire mutex-stale --scope global >/dev/null
OLD_MUTEX_START=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid_start)' \
  "$ISS_STATE_DIR/locks/mutex-stale.lock/owner.json")
mkdir "$ISS_STATE_DIR/locks/mutex-stale.lock.takeover"
MUTEX_BLOCK_OUTPUT=$(ISS_LOCK_TAKEOVER_GRACE=5 ISS_PS_LSTART_CMD="$TEST_ROOT/fake-ps" \
  ISS_FAKE_LSTART_MODE=new ISS_FAKE_LSTART_OLD="$OLD_MUTEX_START" \
  "$LOCK" acquire mutex-stale --scope global --owner-pid $$ --wait 0 2>"$TEST_ROOT/mutex-fresh.err")
expect_rc "fresh takeover mutex blocks this poll" 2 $?
MUTEX_TAKEOVER_ERR=$(ISS_LOCK_TAKEOVER_GRACE=0 ISS_PS_LSTART_CMD="$TEST_ROOT/fake-ps" \
  ISS_FAKE_LSTART_MODE=new ISS_FAKE_LSTART_OLD="$OLD_MUTEX_START" \
  "$LOCK" acquire mutex-stale --scope global --owner-pid $$ 2>&1 >/dev/null)
check "old takeover mutex is cleaned and lock is taken over" grep -q 'took over stale' <<< "$MUTEX_TAKEOVER_ERR"
check "cleaned takeover mutex stays removed" test ! -e "$ISS_STATE_DIR/locks/mutex-stale.lock.takeover"
"$LOCK" release mutex-stale --scope global --force

"$LOCK" acquire reentrant --scope global --owner-pid $$ >/dev/null
"$LOCK" acquire reentrant --scope global --owner-pid $$ >/dev/null 2>"$TEST_ROOT/reentrant.err"
expect_rc "reentrant acquire succeeds" 0 $?
start_lock_holder foreign "$TEST_ROOT/release-foreign" "$TEST_ROOT/holder3.log"; P3=$LAST_HOLDER_PID
touch "$TEST_ROOT/race-start"
wait_file "$TEST_ROOT/holder-$P3-got"
"$LOCK" release foreign --scope global --owner-pid $$ >/dev/null 2>&1
expect_rc "non-owner release exits 3" 3 $?
"$LOCK" release foreign --scope global --force
touch "$TEST_ROOT/release-foreign"
wait_pid_exit "$P3"
start_lock_holder wait-expire "$TEST_ROOT/release-wait" "$TEST_ROOT/holder4.log"; P4=$LAST_HOLDER_PID
wait_file "$TEST_ROOT/holder-$P4-got"
WAIT_OUTPUT=$("$LOCK" acquire wait-expire --scope global --owner-pid $$ --wait 0 2>"$TEST_ROOT/wait.err")
expect_rc "expired acquire exits 2" 2 $?
check "expired acquire prints owner" grep -q '"pid"' <<< "$WAIT_OUTPUT"
touch "$TEST_ROOT/release-wait"
wait_pid_exit "$P4"
"$LOCK" release reentrant --scope global --owner-pid $$
"$LOCK" release wait-expire --scope global --force

echo "slot contention and takeover"
start_lock_holder SLOT:slots-q "$TEST_ROOT/release-slot-q1" "$TEST_ROOT/slot1.log"; S1=$LAST_HOLDER_PID
start_lock_holder SLOT:slots-q "$TEST_ROOT/release-slot-q2" "$TEST_ROOT/slot2.log"; S2=$LAST_HOLDER_PID
touch "$TEST_ROOT/race-start-slot"
wait_file "$TEST_ROOT/holder-$S1-got" && wait_file "$TEST_ROOT/holder-$S2-got"
(
  export ISS_OWNER_PID=$$
  while [ ! -e "$TEST_ROOT/race-start-slot" ]; do sleep 0.01; done
  "$LOCK" slot-acquire slots-q --max 2 --wait 5
) >"$TEST_ROOT/slot3.log" 2>&1 &
S3=$!
BACKGROUND_PIDS+=("$S3")
sleep 0.1
check "third slot holder waits" kill -0 "$S3"
touch "$TEST_ROOT/release-slot-q1"
wait_pid_exit "$S3"
check "released slot is acquired" test -s "$TEST_ROOT/slot3.log"
touch "$TEST_ROOT/release-slot-q2"
wait_pid_exit "$S1" && wait_pid_exit "$S2"

(
bash -c 'export ISS_OWNER_PID=$$; "$1" slot-acquire slots-dead --max 1 --wait 0' _ "$LOCK"
) >"$TEST_ROOT/dead-slot.log" 2>&1
DEAD_PID=$!
wait_pid_exit "$DEAD_PID"
wait_file "$ISS_STATE_DIR/locks/slots-dead.slots/1.lock/owner.json"
check "dead slot directory remains" test -d "$ISS_STATE_DIR/locks/slots-dead.slots/1.lock"
DEAD_SLOT_OUTPUT=$("$LOCK" slot-acquire slots-dead --max 1 --owner-pid $$ --wait 1 2>"$TEST_ROOT/dead-takeover.err")
expect_rc "dead slot is taken over" 0 $?
check "slot takeover returns slot 1" test "$DEAD_SLOT_OUTPUT" = 1
"$LOCK" slot-release slots-dead 1 --owner-pid $$
"$LOCK" slot-release slots-q 1 --force
"$LOCK" slot-release slots-q 2 --force

echo "spec claims"
REPO_PARENT="$TEST_ROOT/claim-repo"
REPO="$REPO_PARENT/locks"
mkdir -p "$REPO"
git -C "$REPO" init -q -b master
REPO=$(cd -P "$REPO" && pwd)
REPO_PARENT=$(dirname "$REPO")
git -C "$REPO" config user.email selftest@example.invalid
git -C "$REPO" config user.name Selftest
printf 'hello\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init
(
  cd "$REPO"
  export ISS_OWNER_PID=${BASHPID:-$$}
  TAKE_OUTPUT=$(ISS_OWNER_PID=$$ "$CLAIM" take 224)
  printf '%s\n' "$TAKE_OUTPUT" > "$TEST_ROOT/claim-224-path"
)
check "take creates worktree" test "$(cat "$TEST_ROOT/claim-224-path")" = "$REPO_PARENT/locks-wt/spec-224"
check "take creates integration branch" git -C "$REPO" show-ref --verify --quiet refs/heads/spec-224
CLAIM_FILE="$REPO/.git/implement-spec-split/claims/spec-224.json"
check "claim record has exact fields" env CLAIM_FILE="$CLAIM_FILE" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  const keys = Object.keys(c);
  const wanted = ["spec", "branch", "worktree", "pid", "pid_start", "claimed_at"];
  process.exit(keys.length === wanted.length && wanted.every((k, i) => k === keys[i]) ? 0 : 1);
'
TAKE_AGAIN=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" take 224 2>/dev/null)
TAKE_AGAIN_RC=$?
expect_rc "active claim blocks take" 3 "$TAKE_AGAIN_RC"
check "active status names record" grep -q '^active {"spec":224' <<< "$TAKE_AGAIN"
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 224)
TAKE_INTERRUPTED=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" take 224 2>/dev/null)
TAKE_INTERRUPTED_RC=$?
expect_rc "interrupted branch blocks take" 3 "$TAKE_INTERRUPTED_RC"
check "interrupted status without record" test "$TAKE_INTERRUPTED" = "interrupted none"

cat > "$TEST_ROOT/claim-holder-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -u
action=$1 number=$2 ready=$3 done=$4 start=$5 prefix=$6 repo=$7 claim=$8
cd "$repo"
export ISS_OWNER_PID=$$
if [ "$start" != - ]; then
  while [ ! -e "$start" ]; do sleep 0.01; done
fi
if [ "$action" = take ]; then
  output=$("$claim" take "$number" 2>/dev/null); rc=$?
  printf '%s\n' "$rc" > "$prefix-$ISS_OWNER_PID-rc"
  printf '%s\n' "$output" > "$prefix-$ISS_OWNER_PID-out"
  if [ "$rc" -eq 0 ]; then
    while [ ! -e "$done" ]; do sleep 0.01; done
    "$claim" release "$number"
  fi
  exit "$rc"
fi
"$claim" resume "$number"
: > "$ready"
while [ ! -e "$done" ]; do sleep 0.01; done
EOF

bash "$TEST_ROOT/claim-holder-helper.sh" resume 224 "$TEST_ROOT/claim-holder-ready" \
  "$TEST_ROOT/claim-holder-done" - "$TEST_ROOT/claim-prefix" "$REPO" "$CLAIM" \
  >"$TEST_ROOT/claim-holder.log" 2>&1 &
CLAIM_HOLDER=$!
BACKGROUND_PIDS+=("$CLAIM_HOLDER")
wait_file "$TEST_ROOT/claim-holder-ready"
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" resume 224) >/dev/null 2>&1
expect_rc "live foreign resume exits 3" 3 $?
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" resume 224 --force)
expect_rc "forced resume succeeds" 0 $?
kill "$CLAIM_HOLDER" 2>/dev/null || true
wait "$CLAIM_HOLDER" 2>/dev/null || true
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 224)
(
bash "$TEST_ROOT/claim-holder-helper.sh" resume 224 "$TEST_ROOT/claim-release-holder-ready" \
  "$TEST_ROOT/claim-release-done" - "$TEST_ROOT/claim-release-prefix" "$REPO" "$CLAIM"
) >"$TEST_ROOT/claim-release-holder.log" 2>&1 &
CLAIM_RELEASE_HOLDER=$!
BACKGROUND_PIDS+=("$CLAIM_RELEASE_HOLDER")
wait_file "$TEST_ROOT/claim-release-holder-ready"
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 224) >/dev/null 2>&1
expect_rc "foreign release exits 3" 3 $?
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 224 --force)
expect_rc "forced release succeeds" 0 $?
touch "$TEST_ROOT/claim-release-done"
wait_pid_exit "$CLAIM_RELEASE_HOLDER"

echo "atomic claim race"
bash "$TEST_ROOT/claim-holder-helper.sh" take 301 - "$TEST_ROOT/claim-race-done" \
  "$TEST_ROOT/claim-race-start" "$TEST_ROOT/claim-race-301" "$REPO" "$CLAIM" \
  >/dev/null 2>&1 &
R1=$!
BACKGROUND_PIDS+=("$R1")
bash "$TEST_ROOT/claim-holder-helper.sh" take 301 - "$TEST_ROOT/claim-race-done" \
  "$TEST_ROOT/claim-race-start" "$TEST_ROOT/claim-race-301" "$REPO" "$CLAIM" \
  >/dev/null 2>&1 &
R2=$!
BACKGROUND_PIDS+=("$R2")
touch "$TEST_ROOT/claim-race-start"
wait_file "$TEST_ROOT/claim-race-301-$R1-rc" 5
wait_file "$TEST_ROOT/claim-race-301-$R2-rc" 5
SUCCESS_COUNT=0
for rc_file in "$TEST_ROOT"/claim-race-301-*-rc; do
  [ "$(cat "$rc_file")" = 0 ] && SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done
check "exactly one atomic claim succeeds" test "$SUCCESS_COUNT" = 1
touch "$TEST_ROOT/claim-race-done"
wait_pid_exit "$R1" && wait_pid_exit "$R2"

echo "legacy claim branches"
git -C "$REPO" branch spec-302-explorer master
LEGACY_OUTPUT=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" status 302)
check "legacy integration branch is interrupted" test "$LEGACY_OUTPUT" = "interrupted none"
(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" take 302) >/dev/null 2>&1
expect_rc "legacy integration branch blocks take" 3 $?
git -C "$REPO" branch spec-303-t1 master
git -C "$REPO" branch spec-303-fix1 master
TICKET_FIX_OUTPUT=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" status 303)
check "ticket and fix branches do not claim spec" test "$TICKET_FIX_OUTPUT" = free

echo "handoff reservations"
RESERVE_OUTPUT=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 304 --ttl 600)
RESERVE_RC=$?
expect_rc "fresh reserve succeeds" 0 "$RESERVE_RC"
check "fresh reserve is silent" test -z "$RESERVE_OUTPUT"
check "fresh reserve does not create a branch" bash -c '! git -C "$1" show-ref --verify refs/heads/spec-304' _ "$REPO"
check "fresh reserve does not create a worktree" test ! -e "$REPO_PARENT/locks-wt/spec-304"
HANDOFF_CLAIM="$REPO/.git/implement-spec-split/claims/spec-304.json"
cp "$HANDOFF_CLAIM" "$TEST_ROOT/fresh-handoff-record.json"
check "fresh reserve record has handoff fields" env CLAIM_FILE="$HANDOFF_CLAIM" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  const wanted = ["spec", "branch", "worktree", "pid", "pid_start", "claimed_at", "handoff", "handoff_until_epoch"];
  process.exit(
    JSON.stringify(Object.keys(c)) === JSON.stringify(wanted) &&
    c.spec === 304 && c.branch === "spec-304" && c.worktree === null &&
    c.handoff === "fresh" && Number.isSafeInteger(c.handoff_until_epoch) ? 0 : 1
  );
'
HANDOFF_STATUS=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" status 304)
check "live handoff status is active" grep -q '^active {"spec":304' <<< "$HANDOFF_STATUS"
RESERVE_AGAIN=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 304 --ttl 600 2>/dev/null)
RESERVE_AGAIN_RC=$?
expect_rc "occupied reserve exits 3" 3 "$RESERVE_AGAIN_RC"
check "occupied reserve prints active state" grep -q '^active {"spec":304' <<< "$RESERVE_AGAIN"
TAKE_OTHER_BRANCH=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" take 304 2>/dev/null)
TAKE_OTHER_BRANCH_RC=$?
expect_rc "live handoff blocks take outside its worktree" 3 "$TAKE_OTHER_BRANCH_RC"
check "live handoff take prints active state" grep -q '^active {"spec":304' <<< "$TAKE_OTHER_BRANCH"
RESUME_HANDOFF=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" resume 304 2>/dev/null)
RESUME_HANDOFF_RC=$?
expect_rc "live handoff blocks resume" 3 "$RESUME_HANDOFF_RC"
RELEASE_HANDOFF=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 304 2>/dev/null)
RELEASE_HANDOFF_RC=$?
expect_rc "live handoff blocks release" 3 "$RELEASE_HANDOFF_RC"

# Make the recorded process identity dead so expiry, rather than the test process,
# controls the rest of this handoff's liveness.
env CLAIM_FILE="$HANDOFF_CLAIM" node -e '
  const fs = require("fs");
  const file = process.env.CLAIM_FILE;
  const c = JSON.parse(fs.readFileSync(file, "utf8"));
  c.pid_start = "dead-for-test";
  fs.writeFileSync(file, JSON.stringify(c) + "\n");
'
HANDOFF_UNTIL=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).handoff_until_epoch)' "$HANDOFF_CLAIM")
HANDOFF_STATUS=$(cd "$REPO" && ISS_NOW_EPOCH="$HANDOFF_UNTIL" "$CLAIM" status 304)
check "handoff at its expiry boundary is free" test "$HANDOFF_STATUS" = free
EXPIRED_TAKE=$(cd "$REPO" && ISS_NOW_EPOCH="$HANDOFF_UNTIL" ISS_OWNER_PID=$$ "$CLAIM" take 304)
EXPIRED_TAKE_RC=$?
expect_rc "expired handoff can be taken normally" 0 "$EXPIRED_TAKE_RC"
check "expired handoff take creates worktree" test "$EXPIRED_TAKE" = "$REPO_PARENT/locks-wt/spec-304"
check "normal take removes handoff fields" env CLAIM_FILE="$HANDOFF_CLAIM" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  const wanted = ["spec", "branch", "worktree", "pid", "pid_start", "claimed_at"];
  process.exit(JSON.stringify(Object.keys(c)) === JSON.stringify(wanted) ? 0 : 1);
'

cat > "$TEST_ROOT/reserve-race-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -u
number=$1 gate=$2 done=$3 prefix=$4 repo=$5 claim=$6
cd "$repo"
export ISS_OWNER_PID=$$
while [ ! -e "$gate" ]; do sleep 0.01; done
output=$("$claim" reserve "$number" --ttl 600 2>/dev/null); rc=$?
printf '%s\n' "$rc" > "$prefix-$ISS_OWNER_PID-rc"
printf '%s\n' "$output" > "$prefix-$ISS_OWNER_PID-out"
if [ "$rc" -eq 0 ]; then
  while [ ! -e "$done" ]; do sleep 0.01; done
  "$claim" release "$number" --force
fi
exit "$rc"
EOF

RESERVE_RACE_DONE="$TEST_ROOT/reserve-race-done"
RESERVE_RACE_PREFIX="$TEST_ROOT/reserve-race-307"
bash "$TEST_ROOT/reserve-race-helper.sh" 307 "$TEST_ROOT/reserve-race-start" "$RESERVE_RACE_DONE" \
  "$RESERVE_RACE_PREFIX" "$REPO" "$CLAIM" >/dev/null 2>&1 &
RR1=$!
BACKGROUND_PIDS+=("$RR1")
bash "$TEST_ROOT/reserve-race-helper.sh" 307 "$TEST_ROOT/reserve-race-start" "$RESERVE_RACE_DONE" \
  "$RESERVE_RACE_PREFIX" "$REPO" "$CLAIM" >/dev/null 2>&1 &
RR2=$!
BACKGROUND_PIDS+=("$RR2")
touch "$TEST_ROOT/reserve-race-start"
wait_file "$RESERVE_RACE_PREFIX-$RR1-rc" 5
wait_file "$RESERVE_RACE_PREFIX-$RR2-rc" 5
RESERVE_SUCCESS_COUNT=0
RESERVE_BLOCKED_COUNT=0
for rc_file in "$RESERVE_RACE_PREFIX"-*-rc; do
  [ "$(cat "$rc_file")" = 0 ] && RESERVE_SUCCESS_COUNT=$((RESERVE_SUCCESS_COUNT + 1))
  [ "$(cat "$rc_file")" = 3 ] && RESERVE_BLOCKED_COUNT=$((RESERVE_BLOCKED_COUNT + 1))
done
check "exactly one concurrent reserve succeeds" test "$RESERVE_SUCCESS_COUNT" = 1
check "the other concurrent reserve is blocked" test "$RESERVE_BLOCKED_COUNT" = 1
touch "$RESERVE_RACE_DONE"
wait_pid_exit "$RR1" && wait_pid_exit "$RR2"
check "released concurrent reserve leaves no record" test ! -e "$REPO/.git/implement-spec-split/claims/spec-307.json"

git -C "$REPO" branch spec-308 master
git -C "$REPO" worktree add -q "$REPO_PARENT/locks-wt/spec-308" spec-308
RESUME_RESERVE=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 308 --resume --ttl 600)
RESUME_RESERVE_RC=$?
expect_rc "resume reserve succeeds for interrupted spec" 0 "$RESUME_RESERVE_RC"
check "resume reserve finds the branch worktree" test "$RESUME_RESERVE" = "$REPO_PARENT/locks-wt/spec-308"
RESUME_CLAIM="$REPO/.git/implement-spec-split/claims/spec-308.json"
cp "$RESUME_CLAIM" "$TEST_ROOT/resume-handoff-record.json"
check "resume reserve record has handoff fields" env CLAIM_FILE="$RESUME_CLAIM" EXPECTED_WORKTREE="$REPO_PARENT/locks-wt/spec-308" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  const wanted = ["spec", "branch", "worktree", "pid", "pid_start", "claimed_at", "handoff", "handoff_until_epoch"];
  process.exit(
    JSON.stringify(Object.keys(c)) === JSON.stringify(wanted) &&
    c.spec === 308 && c.worktree === process.env.EXPECTED_WORKTREE &&
    c.handoff === "resume" && Number.isSafeInteger(c.handoff_until_epoch) ? 0 : 1
  );
'
check "resume reserve status is active" grep -q '^active {"spec":308' < <(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" status 308)
RESUME_RESERVE_AGAIN=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 308 --resume 2>/dev/null)
RESUME_RESERVE_AGAIN_RC=$?
expect_rc "active resume reserve exits 3" 3 "$RESUME_RESERVE_AGAIN_RC"
check "active resume reserve prints state" grep -q '^active {"spec":308' <<< "$RESUME_RESERVE_AGAIN"
ACTIVE_HANDOFF_RESUME=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" resume 308 2>/dev/null)
ACTIVE_HANDOFF_RESUME_RC=$?
expect_rc "active resume handoff blocks resume" 3 "$ACTIVE_HANDOFF_RESUME_RC"
ACTIVE_HANDOFF_RELEASE=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 308 2>/dev/null)
ACTIVE_HANDOFF_RELEASE_RC=$?
expect_rc "active resume handoff blocks release" 3 "$ACTIVE_HANDOFF_RELEASE_RC"

RESUME_TAKE=$(cd "$REPO_PARENT/locks-wt/spec-308" && ISS_OWNER_PID=$$ "$CLAIM" take 308)
RESUME_TAKE_RC=$?
expect_rc "taking over resume handoff exits 4" 4 "$RESUME_TAKE_RC"
check "taking over resume handoff prints worktree" test "$RESUME_TAKE" = "$REPO_PARENT/locks-wt/spec-308"
check "resume takeover clears handoff fields" env CLAIM_FILE="$RESUME_CLAIM" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  const wanted = ["spec", "branch", "worktree", "pid", "pid_start", "claimed_at"];
  process.exit(JSON.stringify(Object.keys(c)) === JSON.stringify(wanted) ? 0 : 1);
'

(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 309 --ttl 600)
git -C "$REPO" branch spec-309 master
git -C "$REPO" worktree add -q "$REPO_PARENT/locks-wt/spec-309" spec-309
FRESH_TAKE=$(cd "$REPO_PARENT/locks-wt/spec-309" && ISS_OWNER_PID=$$ "$CLAIM" take 309)
FRESH_TAKE_RC=$?
expect_rc "taking over fresh handoff succeeds" 0 "$FRESH_TAKE_RC"
check "taking over fresh handoff prints worktree" test "$FRESH_TAKE" = "$REPO_PARENT/locks-wt/spec-309"
check "fresh takeover clears handoff fields" env CLAIM_FILE="$REPO/.git/implement-spec-split/claims/spec-309.json" node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.exit(!("handoff" in c) && !("handoff_until_epoch" in c) ? 0 : 1);
'

FREE_RESUME=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 310 --resume 2>/dev/null)
FREE_RESUME_RC=$?
expect_rc "free resume reserve exits 3" 3 "$FREE_RESUME_RC"
check "free resume reserve prints free" test "$FREE_RESUME" = free
git -C "$REPO" branch spec-311 master
NO_WORKTREE_RESUME=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 311 --resume 2>"$TEST_ROOT/no-worktree-reserve.err")
NO_WORKTREE_RESUME_RC=$?
expect_rc "resume reserve without worktree exits 4" 4 "$NO_WORKTREE_RESUME_RC"
check "resume reserve without worktree explains error" grep -q "no worktree found for branch spec-311" "$TEST_ROOT/no-worktree-reserve.err"

(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" reserve 312 --ttl 600)
RELEASE_FORCE_OUTPUT=$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" release 312 --force)
RELEASE_FORCE_RC=$?
expect_rc "forced release removes a handoff reservation" 0 "$RELEASE_FORCE_RC"
check "forced release leaves spec free" test "$(cd "$REPO" && ISS_OWNER_PID=$$ "$CLAIM" status 312)" = free

echo "worker slot queue"
WORK_REPO="$TEST_ROOT/worker-repo"
mkdir -p "$WORK_REPO"
git -C "$WORK_REPO" init -q -b master
git -C "$WORK_REPO" config user.email selftest@example.invalid
git -C "$WORK_REPO" config user.name Selftest
printf 'hello\n' > "$WORK_REPO/a.txt"
git -C "$WORK_REPO" add a.txt
git -C "$WORK_REPO" commit -qm init
printf 'Say hello.\n' > "$TEST_ROOT/worker-brief.md"
mkdir -p "$CODEX_HOME/sessions"

echo "worker limit configuration"
unset ISS_MAX_WORKERS
rm -f "$ISS_STATE_DIR/max-workers"
DEFAULT_MAX=$(source "$HERE/lib-workers.sh"; iss_max_workers)
check "worker default limit is four" test "$DEFAULT_MAX" = 4
DEFAULT_MAX_OUTPUT=$(bash "$HERE/max-workers.sh")
check "worker limit CLI reports default" test "$DEFAULT_MAX_OUTPUT" = "4 (default)"
printf '6\n' > "$ISS_STATE_DIR/max-workers"
FILE_MAX=$(source "$HERE/lib-workers.sh"; iss_max_workers)
check "worker file limit is read" test "$FILE_MAX" = 6
FILE_MAX_OUTPUT=$(bash "$HERE/max-workers.sh")
check "worker limit CLI reports file" test "$FILE_MAX_OUTPUT" = "6 (file)"
ENV_MAX=$(ISS_MAX_WORKERS=3 bash -c 'source "$1"; iss_max_workers' _ "$HERE/lib-workers.sh")
check "worker environment limit wins" test "$ENV_MAX" = 3
ENV_MAX_OUTPUT=$(ISS_MAX_WORKERS=3 bash "$HERE/max-workers.sh")
check "worker limit CLI reports environment" test "$ENV_MAX_OUTPUT" = "3 (ISS_MAX_WORKERS)"
INVALID_ENV_MAX=$(ISS_MAX_WORKERS=bad bash -c 'source "$1"; iss_max_workers' _ "$HERE/lib-workers.sh" \
  2>"$TEST_ROOT/invalid-env-max.err")
INVALID_ENV_MAX_RC=$?
expect_rc "invalid worker environment limit exits 64" 64 "$INVALID_ENV_MAX_RC"
printf 'not-a-number\n' > "$ISS_STATE_DIR/max-workers"
INVALID_FILE_MAX=$(source "$HERE/lib-workers.sh"; iss_max_workers 2>"$TEST_ROOT/invalid-file-max.err")
check "invalid worker file falls back to four" test "$INVALID_FILE_MAX" = 4
check "invalid worker file warns" grep -q 'invalid integer' "$TEST_ROOT/invalid-file-max.err"
MAX_WORKERS_WRITE_OUTPUT=$(bash "$HERE/max-workers.sh" 7)
check "worker limit CLI writes value" test "$MAX_WORKERS_WRITE_OUTPUT" = "max-workers = 7"
check "worker limit CLI persists value" test "$(cat "$ISS_STATE_DIR/max-workers")" = 7

bash "$HERE/max-workers.sh" 1
FAKE_CODEX_SLOT_READY="$TEST_ROOT/worker1-ready" FAKE_CODEX_SLOT_MARKER="$TEST_ROOT/worker1-release" "$WORKER" \
  --cwd "$WORK_REPO" --brief "$TEST_ROOT/worker-brief.md" --run-dir "$TEST_ROOT/worker1" \
  --time-limit 10 --idle-timeout 5 >"$TEST_ROOT/worker1.stdout" 2>"$TEST_ROOT/worker1.stderr" &
W1=$!
BACKGROUND_PIDS+=("$W1")
wait_file "$TEST_ROOT/worker1-ready" 10
FAKE_CODEX_SLOT_READY="$TEST_ROOT/worker2-ready" FAKE_CODEX_SLOT_MARKER="$TEST_ROOT/worker2-release" "$WORKER" \
  --cwd "$WORK_REPO" --brief "$TEST_ROOT/worker-brief.md" --run-dir "$TEST_ROOT/worker2" \
  --time-limit 10 --idle-timeout 5 >"$TEST_ROOT/worker2.stdout" 2>"$TEST_ROOT/worker2.stderr" &
W2=$!
BACKGROUND_PIDS+=("$W2")
wait_file "$TEST_ROOT/worker2/queued" 10
PROGRESS_OUTPUT=$("$PROGRESS" "$TEST_ROOT/worker2")
check "progress reports queued" grep -q '^state: queued$' <<< "$PROGRESS_OUTPUT"
check "progress reports queue duration" grep -q '^queued: [0-9][0-9]*s$' <<< "$PROGRESS_OUTPUT"
check "second worker waits while first owns slot" kill -0 "$W2"
touch "$TEST_ROOT/worker1-release"
wait_pid_exit "$W1" 15
touch "$TEST_ROOT/worker2-release"
wait_pid_exit "$W2" 15
check "first worker records slot" env WORKER_STATUS="$TEST_ROOT/worker1/status.json" node -e 'const s=JSON.parse(require("fs").readFileSync(process.env.WORKER_STATUS,"utf8"));process.exit(Number.isInteger(s.slot) ? 0 : 1)'
check "second worker records slot" env WORKER_STATUS="$TEST_ROOT/worker2/status.json" node -e 'const s=JSON.parse(require("fs").readFileSync(process.env.WORKER_STATUS,"utf8"));process.exit(Number.isInteger(s.slot) ? 0 : 1)'
check "second worker records queue seconds" env WORKER_STATUS="$TEST_ROOT/worker2/status.json" node -e 'const s=JSON.parse(require("fs").readFileSync(process.env.WORKER_STATUS,"utf8"));process.exit(Number.isInteger(s.queued_seconds) ? 0 : 1)'
check "queued marker is removed" test ! -e "$TEST_ROOT/worker2/queued"
check "slot acquisition logged" grep -q '拿到 worker 槽位' "$TEST_ROOT/worker2/stderr.log"
check "worker slot directories are released" test ! -e "$ISS_STATE_DIR/locks/glm-workers.slots/1.lock"

echo "worker slot acquisition failure"
cat > "$TEST_ROOT/empty-lstart" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/empty-lstart"
FAKE_CODEX_SCENARIO=ok ISS_PS_LSTART_CMD="$TEST_ROOT/empty-lstart" "$WORKER" \
  --cwd "$WORK_REPO" --brief "$TEST_ROOT/worker-brief.md" --run-dir "$TEST_ROOT/worker-slot-error" \
  --time-limit 10 --idle-timeout 5 >"$TEST_ROOT/worker-slot-error.stdout" 2>"$TEST_ROOT/worker-slot-error.stderr"
expect_rc "worker continues after slot acquisition error" 0 $?
check "failed slot acquisition records null slot" \
  env WORKER_STATUS="$TEST_ROOT/worker-slot-error/status.json" node -e 'const s=JSON.parse(require("fs").readFileSync(process.env.WORKER_STATUS,"utf8"));process.exit(s.slot === null ? 0 : 1)'
check "failed slot acquisition logs warning" \
  grep -q 'worker 槽位不可用（退出码 64），本次不占槽位继续运行' "$TEST_ROOT/worker-slot-error/stderr.log"
check "failed slot acquisition removes queued marker" test ! -e "$TEST_ROOT/worker-slot-error/queued"

echo
echo "PASS=$PASS FAIL=$FAIL"
echo "TEST_ROOT=$TEST_ROOT (left in place: the Brief forbids recursive cleanup)"
[ "$FAIL" -eq 0 ]
