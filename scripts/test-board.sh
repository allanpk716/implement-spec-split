#!/usr/bin/env bash
# Isolated tests for scripts/board.sh.  No invocation here may touch the real
# HOME or ~/.cache: every run gets a temporary HOME, state directory and board.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/board.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/board-test.XXXXXX") || exit 125
HOME_DIR=$WORK/home
STATE=$WORK/state
BOARD=$WORK/board
BIN=$WORK/bin
GRAPHS=$WORK/graphs
REGISTRY=$WORK/registry.json
ORCA_LOG=$WORK/orca.log
PIPELINE_LOG=$WORK/pipeline.log
PASSED=0
FAILED=0
RUN_EXIT=
export REGISTRY ORCA_LOG PIPELINE_LOG GRAPHS

cleanup() {
  [ -z "${BOARD_TEST_KEEP:-}" ] || return 0
  chmod -R u+w "$WORK" 2>/dev/null || true
  # Delete leaves first, then only now-empty directories.  This deliberately
  # avoids `rm -rf` while still cleaning arbitrary test trees.
  find "$WORK" -depth \( -type f -o -type l \) -delete 2>/dev/null || true
  find "$WORK" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

ok() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

jget() {
  BOARD_JSON_FILE=$1 BOARD_JSON_EXPR=$2 node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.env.BOARD_JSON_FILE, "utf8"));
    const value = eval(process.env.BOARD_JSON_EXPR);
    process.stdout.write(String(value));
  ' 2>&1
}

check() { # name file expr expected
  got=$(jget "$2" "$3")
  if [ "$got" = "$4" ]; then
    ok "$1"
  else
    bad "$1" "want [$4], got [$got]"
  fi
}

expect_exit() {
  expected=$1 name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    ok "$name"
  else
    bad "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_has() {
  text=$1 name=$2 file=${3:-}
  file=${file:-$WORK/last.out}
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    ok "$name"
  else
    bad "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1 name=$2 file=${3:-}
  file=${file:-$WORK/last.out}
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    bad "$name" "unexpected [$text]"
  else
    ok "$name"
  fi
}

pipeline_calls() {
  grep -Fc "repo=owner/$1" "$PIPELINE_LOG" 2>/dev/null || true
}

expect_calls() {
  repo=$1 expected=$2 name=$3
  actual=$(pipeline_calls "$repo")
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "calls=$actual, expected=$expected"
  fi
}

run_board() {
  output=$1
  shift
  : > "$output"
  : > "$output.err"
  env HOME="$HOME_DIR" ISS_STATE_DIR="$STATE" BOARD_DIR="$BOARD" \
    BOARD_NOW="$NOW_ISO" BOARD_PIPELINE_STATUS="$BIN/fake-pipeline" \
    BOARD_CONCURRENCY=2 \
    PATH="$BIN:$PATH" bash "$SCRIPT" "$@" > "$output" 2> "$output.err"
  RUN_EXIT=$?
}

mkdir -p "$HOME_DIR" "$STATE/runs" "$BOARD" "$BIN" "$GRAPHS" || exit 125

# A fixed epoch keeps cache ages deterministic; run-directory names are in
# local time, so derive them from the same epoch with Node rather than duplicating
# date arithmetic in shell.
NOW_EPOCH=$(date +%s)
NOW_ISO=$(NOW_EPOCH=$NOW_EPOCH node -e 'process.stdout.write(new Date(Number(process.env.NOW_EPOCH)*1000).toISOString())')
export NOW_EPOCH NOW_ISO
stamp() {
  NOW_EPOCH=$NOW_EPOCH OFFSET_SECONDS=$1 node -e '
    const d = new Date((Number(process.env.NOW_EPOCH) - Number(process.env.OFFSET_SECONDS)) * 1000);
    const p = n => String(n).padStart(2, "0");
    process.stdout.write(`${d.getFullYear()}${p(d.getMonth()+1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`);
  '
}
iso_ago() {
  NOW_EPOCH=$NOW_EPOCH OFFSET_SECONDS=$1 node -e '
    process.stdout.write(new Date((Number(process.env.NOW_EPOCH)-Number(process.env.OFFSET_SECONDS))*1000).toISOString());
  '
}

make_repo() {
  name=$1
  dir=$WORK/repos/$name
  mkdir -p "$dir"
  git -C "$dir" init --quiet --initial-branch=main
  git -C "$dir" config user.name 'Board Test'
  git -C "$dir" config user.email board-test@example.invalid
  git -C "$dir" config commit.gpgsign false
  printf '%s\n' "$name" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit --quiet -m 'initial'
  printf '%s\n' "$dir"
}

ALPHA=$(make_repo alpha)
BETA=$(make_repo beta)
RECENT=$(make_repo recent)
OLD=$(make_repo old)
COLD=$(make_repo cold)
UNUSED=$(make_repo unused)
git -C "$ALPHA" branch spec-101
git -C "$ALPHA" branch spec-103
git -C "$ALPHA" worktree add --quiet "$WORK/alpha-wt/spec-999" -b spec-999 >/dev/null 2>&1

claim_dir() { git -C "$1" rev-parse --git-common-dir; }
ALPHA_COMMON=$(claim_dir "$ALPHA")
case "$ALPHA_COMMON" in
  /*) ;;
  *) ALPHA_COMMON="$ALPHA/$ALPHA_COMMON" ;;
esac
mkdir -p "$ALPHA_COMMON/implement-spec-split/claims"
cat > "$ALPHA_COMMON/implement-spec-split/claims/spec-101.json" <<EOF
{"spec":101,"branch":"spec-101","worktree":"$WORK/alpha-wt/spec-101","pid":123,"pid_start":"old","claimed_at":"$(iso_ago 600)"}
EOF
cat > "$ALPHA_COMMON/implement-spec-split/claims/spec-102.json" <<EOF
{"spec":102,"branch":"spec-102","worktree":"$WORK/alpha-wt/spec-102","pid":null,"pid_start":"","claimed_at":"$(iso_ago 1200)","handoff":"fresh","handoff_until_epoch":0}
EOF
cat > "$ALPHA_COMMON/implement-spec-split/claims/spec-103.json" <<EOF
{"spec":103,"branch":"spec-103","worktree":"$WORK/alpha-wt/spec-103","pid":123,"pid_start":"old","claimed_at":"$(iso_ago 864000)"}
EOF

spec_json() { # number status claimState map
  number=$1 status=$2 claim=$3 map=${4:-null}
  node - "$number" "$status" "$claim" "$map" <<'NODE'
const [number, status, claim, map] = process.argv.slice(2);
const claimState = claim === 'none' ? null : {state: claim, branch: `spec-${number}`, worktree: ''};
process.stdout.write(JSON.stringify({
  number: +number, title: `Spec ${number}`, kind: 'spec', state: status === 'landed' ? 'closed' : 'open',
  status, map: map === 'null' ? null : +map, has_tickets: true,
  tickets: [{number: +number + 100, title: `Ticket ${number}`, state: 'open', shelved: false}],
  tickets_total: 1, tickets_closed: 0, claim: claimState, depends_on: [], extra_blockers: []
}));
NODE
}

# Build graph fixtures directly.  Keeping these small and structurally identical
# to pipeline-status --graph is clearer than replaying the large fake gh dataset.
cat > "$GRAPHS/alpha.json" <<EOF
{
  "repo": "owner/alpha", "counts": {"maps": {"total":2,"closed":1,"shelved":0,"empty":0,"exploring":0,"fog_pending":0,"unconverted":0}, "specs": {"total":6,"landed":1,"needs_tickets":0,"ready":2,"running":2,"interrupted":1,"shelved":0}, "tickets": {"total":7,"closed":2}},
  "maps": [
    {"number":10,"title":"Alpha map","state":"open","shelved":false,"has_fog":false,"status":"converted","decisions_total":1,"decisions_open":0,"spec_numbers":[101,102,103,107],"tickets":[]},
    {"number":11,"title":"Closed map","state":"closed","shelved":false,"has_fog":false,"status":"closed","decisions_total":1,"decisions_open":0,"spec_numbers":[105],"tickets":[{"number":206,"title":"Old map ticket","state":"closed","shelved":false},{"number":208,"title":"Open map ticket","state":"open","shelved":false}]}
  ],
  "specs": [
    $(spec_json 101 running active 10),
    $(spec_json 102 ready idle 10),
    $(spec_json 103 interrupted interrupted 10),
    $(spec_json 104 ready reserved),
    $(spec_json 107 running active 10),
    {"number":105,"title":"Landed spec","kind":"spec","state":"closed","status":"landed","map":11,"has_tickets":true,"tickets":[{"number":205,"title":"Old ticket","state":"closed","shelved":false}],"tickets_total":1,"tickets_closed":1,"claim":null,"depends_on":[],"extra_blockers":[]}
  ],
  "loose_specs": [104],
  "next_wave": {"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[{"spec":104,"title":"Spec 104","command":"/implement-spec-split 104","note":""}],"later":[],"cycles":[],"standalone":[]}
}
EOF
cat > "$GRAPHS/beta.json" <<EOF
{"repo":"owner/beta","counts":{"maps":{"total":0,"closed":0,"shelved":0,"empty":0,"exploring":0,"fog_pending":0,"unconverted":0},"specs":{"total":1,"landed":0,"needs_tickets":0,"ready":1,"running":0,"interrupted":0,"shelved":0},"tickets":{"total":1,"closed":0}},"maps":[],"specs":[$(spec_json 201 ready none)],"loose_specs":[201],"next_wave":{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[{"spec":201,"title":"Spec 201","command":"/implement-spec-split 201","note":""}],"later":[],"cycles":[],"standalone":[]}}
EOF
sed 's/owner\/alpha/owner\/recent/; s/Alpha map/Recent map/; s/owner\/alpha/owner\/recent/' "$GRAPHS/alpha.json" > "$GRAPHS/recent.json"
node - "$GRAPHS/recent.json" <<'NODE'
const fs = require('fs'); const f = process.argv[2]; const g = JSON.parse(fs.readFileSync(f, 'utf8'));
g.specs = g.specs.filter(s => s.number === 104); g.loose_specs = [104]; g.maps = []; g.next_wave.wave1 = [];
fs.writeFileSync(f, JSON.stringify(g, null, 2) + '\n');
NODE
cat > "$GRAPHS/old.json" <<EOF
{"repo":"owner/old","counts":{"maps":{"total":0,"closed":0,"shelved":0,"empty":0,"exploring":0,"fog_pending":0,"unconverted":0},"specs":{"total":1,"landed":0,"needs_tickets":0,"ready":1,"running":0,"interrupted":0,"shelved":0},"tickets":{"total":1,"closed":0}},"maps":[],"specs":[$(spec_json 301 ready none)],"loose_specs":[301],"next_wave":{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[{"spec":301,"title":"Spec 301","command":"/implement-spec-split 301","note":""}],"later":[],"cycles":[],"standalone":[]}}
EOF
cat > "$GRAPHS/cold.json" <<EOF
{"repo":"owner/cold","counts":{"maps":{"total":0,"closed":0,"shelved":0,"empty":0,"exploring":0,"fog_pending":0,"unconverted":0},"specs":{"total":1,"landed":0,"needs_tickets":0,"ready":1,"running":0,"interrupted":0,"shelved":0},"tickets":{"total":1,"closed":0}},"maps":[],"specs":[$(spec_json 401 ready none)],"loose_specs":[401],"next_wave":{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[{"spec":401,"title":"Spec 401","command":"/implement-spec-split 401","note":""}],"later":[],"cycles":[],"standalone":[]}}
EOF
cat > "$GRAPHS/unused.json" <<'EOF'
{"repo":"owner/unused","counts":{"maps":{"total":0,"closed":0,"shelved":0,"empty":0,"exploring":0,"fog_pending":0,"unconverted":0},"specs":{"total":0,"landed":0,"needs_tickets":0,"ready":0,"running":0,"interrupted":0,"shelved":0},"tickets":{"total":0,"closed":0},"other":0},"maps":[],"specs":[],"loose_specs":[],"next_wave":{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[],"later":[],"cycles":[],"standalone":[]}}
EOF

node - "$REGISTRY" "$ALPHA" "$BETA" "$RECENT" "$OLD" "$COLD" "$UNUSED" <<'NODE'
const fs = require('fs');
const out = process.argv[2], paths = process.argv.slice(3);
const one = p => ({path: p, gitRemoteIdentity: {canonicalKey: `github.com/owner/${p.split('/').pop()}`}});
fs.writeFileSync(out, JSON.stringify({result: {repos: paths.map(one).concat([{path: '/tmp/non-github', gitRemoteIdentity: {canonicalKey: 'gitlab.com/owner/other'}}])}}, null, 2) + '\n');
NODE

cat > "$BIN/orca" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$(pwd) \$*" >> "$ORCA_LOG"
[ "\${BOARD_ORCA_FAIL:-0}" = 0 ] || exit 23
if [ "\${BOARD_ORCA_INVALID:-0}" = 1 ]; then
  printf '%s\n' '{not valid json'
  exit 0
fi
cat "$REGISTRY"
EOF
chmod +x "$BIN/orca"

cat > "$BIN/fake-pipeline" <<'EOF'
#!/usr/bin/env bash
set -u
repo=
previous=
for arg in "$@"; do
  [ "$previous" = --repo ] && repo=$arg
  previous=$arg
done
printf 'cwd=%s repo=%s args=' "$PWD" "$repo" >> "$PIPELINE_LOG"
printf '%s ' "$@" >> "$PIPELINE_LOG"
printf '\n' >> "$PIPELINE_LOG"
if [ "${BOARD_PIPELINE_FAIL_REPO:-}" = "$repo" ]; then
  printf 'fake pipeline failed for %s\n' "$repo" >&2
  exit 41
fi
file="$GRAPHS/${repo#*/}.json"
[ -f "$file" ] || file="$GRAPHS/alpha.json"
cat "$file"
EOF
chmod +x "$BIN/fake-pipeline"

run_json() { # name run-dir phase wave merged inprog todo age
  name=$1 phase=$2 wave=$3 merged=$4 inprog=$5 todo=$6 age=$7 spec=$8 repo=$9
  dir=$STATE/runs/$repo-$spec-$(stamp "$age")
  mkdir -p "$dir"
  cat > "$dir/run.json" <<EOF
{"phase":"$phase","wave":$wave,"tickets":{"merged":$merged,"in_progress":$inprog,"todo":$todo},"updated":"$(iso_ago "$age")"}
EOF
  printf '%s\n' "$dir"
}

RUN104=$(run_json run104 parked 1 0 1 1 600 104 alpha)
RUN101=$(run_json run101 implement 1 1 1 1 300 101 alpha)
RUN103=$(run_json run103 review 1 0 0 1 864000 103 alpha)
RUN201=$(run_json run201 review 2 1 0 0 3600 201 recent)
RUN301=$(run_json run301 parked 1 0 1 0 864000 301 old)
RUN401=$(run_json run401 review 1 0 0 1 1728000 401 cold)
RUN107_OLD=$(run_json run107old review 1 1 0 0 864000 107 alpha)
RUN107_NEW=$STATE/runs/alpha-107-$(stamp 400)
mkdir -p "$RUN107_NEW"

worker() { # run name pid status watchIdle
  run=$1 name=$2 pid=$3 status=${4:-} idle=${5:-0}
  dir=$run/$name
  mkdir -p "$dir"
  [ "$pid" = none ] || printf '%s\n' "$pid" > "$dir/pid"
  node - "$dir/watch.json" "$NOW_EPOCH" "$idle" <<'NODE'
const fs = require('fs'), [file, now, idle] = process.argv.slice(2);
const n = Number(now), i = Number(idle);
fs.writeFileSync(file, JSON.stringify({started_at:n-i-30, last_progress_at:n-i, attempt_file:null}) + '\n');
NODE
  case $status in
    '') ;;
    ok|error|stalled|quota|auth|transient|timeout|violation)
      printf '{"status":"%s","error":%s}\n' "$status" "$([ "$status" = ok ] && echo null || echo '"failed"')" > "$dir/status.json"
      sleep 0.02
      touch "$dir/status.json"
      ;;
  esac
}

DEAD_PID=""
start_worker_pid() {
  sleep 30 >/dev/null 2>&1 &
  printf '%s' $!
}
DEAD_PID=$(start_worker_pid)
kill "$DEAD_PID" 2>/dev/null || true
wait "$DEAD_PID" 2>/dev/null || true
LIVE_PID=$(start_worker_pid)
worker "$RUN101" impl-401 "$DEAD_PID" '' 0
worker "$RUN101" impl-402 "$LIVE_PID" '' 0
worker "$RUN101" impl-403 "$LIVE_PID" '' 2
worker "$RUN101" merge-1 "$LIVE_PID" ok 0
worker "$RUN101" fix-404 "$LIVE_PID" error 0
worker "$RUN101" impl-405 "$LIVE_PID" '' 3600
worker "$RUN101" fix-406 "$LIVE_PID" quota 0
worker "$RUN103" impl-303 "$DEAD_PID" '' 0

# The first command is the normal snapshot fixture.  During test-first
# development this invocation was added before board.sh and failed with 127.
run_board "$WORK/initial-actual.out" snapshot
expect_exit 0 "snapshot succeeds"
[ -f "$BOARD/repos/owner__alpha.json" ] && ok "per-repo snapshot written" || bad "per-repo snapshot written" "missing alpha"
[ -f "$BOARD/snapshot.json" ] && ok "machine snapshot written" || bad "machine snapshot written" "missing snapshot"

check "github registry cache written" "$BOARD/registry.json" 'j.repos.some(r => r.repo === "owner/alpha")' true
if git -C "$ALPHA" show-ref --verify --quiet refs/heads/spec-102; then
  bad "reserved fixture has no integration branch" "branch unexpectedly exists"
else
  ok "reserved fixture has no integration branch"
fi

# Registry filtering and unused marking.
check "non-github registry entry filtered" "$BOARD/snapshot.json" 'j.repos.some(r => r.repo === "owner/other")' false
check "unused repo retained in machine snapshot" "$BOARD/snapshot.json" 'j.repos.find(r => r.repo === "owner/unused").unused' true
check "used repo is not unused" "$BOARD/repos/owner__alpha.json" 'j.unused' false
check "graph counts copied" "$BOARD/repos/owner__alpha.json" 'j.counts.specs.total' 6
check "next wave copied" "$BOARD/repos/owner__alpha.json" 'j.next_wave.wave1[0].spec' 104
check "map embeds spec objects" "$BOARD/repos/owner__alpha.json" 'j.maps[0].specs[0].number' 101
check "closed map embeds spec objects" "$BOARD/repos/owner__alpha.json" 'j.maps.find(m=>m.number===11).specs[0].number' 105
check "loose spec embeds object" "$BOARD/repos/owner__alpha.json" 'j.loose_specs[0].number' 104

# Orca failure falls back to cache; failure with no cache is fatal.
: > "$ORCA_LOG"
export BOARD_ORCA_FAIL=1
run_board "$WORK/orca-cache.out" snapshot
unset BOARD_ORCA_FAIL
expect_exit 0 "orca failure uses cached registry"
check "cached registry source recorded" "$BOARD/snapshot.json" 'j.registry.source' cache
check "cached registry still contains alpha" "$BOARD/snapshot.json" 'j.repos.some(r => r.repo === "owner/alpha")' true
export BOARD_ORCA_INVALID=1
run_board "$WORK/orca-invalid-cache.out" snapshot
unset BOARD_ORCA_INVALID
expect_exit 0 "invalid orca JSON uses cached registry"
check "invalid orca cache source recorded" "$BOARD/snapshot.json" 'j.registry.source' cache
mv "$BOARD/registry.json" "$WORK/registry.json.saved"
export BOARD_ORCA_FAIL=1
run_board "$WORK/orca-no-cache.out" snapshot
unset BOARD_ORCA_FAIL
expect_exit 1 "orca failure without cache exits one"
expect_has 'registry' "orca no-cache failure explains registry" "$WORK/orca-no-cache.out.err"
mv "$WORK/registry.json.saved" "$BOARD/registry.json"

# Refresh cadence: active is 10 minutes, inactive is 60 minutes, strictly
# expired caches are refetched, and no-cache always fetches.
age_graph() { repo=$1 seconds=$2; node - "$BOARD/graphs/owner__$repo.json" "$seconds" <<'NODE'
const fs = require('fs'), [file, age] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.fetched_at = Math.floor(Date.now()/1000) - Number(age);
fs.writeFileSync(file, JSON.stringify(value) + '\n');
NODE
}
age_graph alpha 540
age_graph beta 3540
age_graph recent 0
age_graph old 0
age_graph cold 0
age_graph unused 0
: > "$PIPELINE_LOG"
run_board "$WORK/ttl-fresh.out" snapshot
expect_exit 0 "fresh graph snapshot succeeds"
expect_calls alpha 0 "active graph at nine minutes is not refreshed"
expect_calls beta 0 "inactive graph at fifty-nine minutes is not refreshed"

age_graph alpha 660
: > "$PIPELINE_LOG"
run_board "$WORK/ttl-active-expired.out" snapshot
expect_exit 0 "active graph expiry snapshot succeeds"
expect_calls alpha 1 "active graph at eleven minutes is refreshed"

age_graph beta 3660
: > "$PIPELINE_LOG"
run_board "$WORK/ttl-inactive-expired.out" snapshot
expect_exit 0 "inactive graph expiry snapshot succeeds"
expect_calls beta 1 "inactive graph at sixty-one minutes is refreshed"

age_graph alpha 0; age_graph beta 0
: > "$PIPELINE_LOG"
run_board "$WORK/force.out" snapshot --force
expect_exit 0 "force snapshot succeeds"
expect_calls alpha 1 "force refreshes selected active repo"
expect_calls beta 1 "force refreshes inactive repo"
expect_calls unused 1 "force refreshes unused repo"

age_graph alpha 0
: > "$PIPELINE_LOG"
run_board "$WORK/repo-refresh.out" snapshot --repo alpha
expect_exit 0 "repo-selected snapshot succeeds"
expect_calls alpha 1 "--repo forces the named repo"
expect_calls beta 0 "--repo leaves other repos on cadence"

# A failed refresh preserves the old graph and records github_error.
OLD_GRAPH_HASH=$(shasum -a 256 "$BOARD/graphs/owner__alpha.json" 2>/dev/null | awk '{print $1}')
export BOARD_PIPELINE_FAIL_REPO=owner/alpha
run_board "$WORK/refresh-fail.out" snapshot --force
unset BOARD_PIPELINE_FAIL_REPO
expect_exit 0 "graph refresh failure does not abort snapshot"
NEW_GRAPH_HASH=$(shasum -a 256 "$BOARD/graphs/owner__alpha.json" 2>/dev/null | awk '{print $1}')
if [ "$OLD_GRAPH_HASH" = "$NEW_GRAPH_HASH" ]; then
  ok "failed refresh preserves old graph cache"
else
  bad "failed refresh preserves old graph cache" "$OLD_GRAPH_HASH != $NEW_GRAPH_HASH"
fi
expect_has 'fake pipeline failed' "graph refresh failure warns on stderr" "$WORK/refresh-fail.out.err"
check "failed refresh records github error" "$BOARD/repos/owner__alpha.json" 'typeof j.github_error' string

# Claim, Run and worker semantics.
check "active claim mapped" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).claim.state' active
check "expired reservation follows graph idle" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===102).claim' null
check "graph reservation mapped without local branch check" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===104).claim.state' reserved
check "interrupted claim mapped" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===103).claim.state' interrupted
check "claim counts calculated" "$BOARD/repos/owner__alpha.json" 'j.claims.active+","+j.claims.reserved+","+j.claims.interrupted' '2,1,1'
check "run attached to claimed open spec" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).run.phase' implement
check "parked run attached without claim" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===104).run.phase' parked
check "latest run selected" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).run.dir.endsWith("/state/runs/alpha-101-'$(stamp 300)'")' true
check "latest run name wins without run.json" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===107).run.dir.endsWith("/state/runs/alpha-107-'$(stamp 400)'") && j.specs.find(s=>s.number===107).run.phase===null' true
check "worker dead state" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-401").state' dead
check "worker running state" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-402").state' running
check "worker finished ok" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="merge-1").state' finished
check "worker finished error" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="fix-404").status' error
check "worker duration fields" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-402").duration_s>=0' true
check "dead worker anomalous" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-401").anomalous' true
check "fresh running worker normal" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-402").anomalous' false
check "wrapper owns running idle judgment" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-403").anomalous' false
check "long-idle running worker stays normal" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="impl-405").anomalous' false
check "failed finish anomalous" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="fix-404").anomalous' true
check "quota finish anomalous" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===101).workers.find(w=>w.name==="fix-406").anomalous' true
check "interrupted worker listed but normal" "$BOARD/repos/owner__alpha.json" 'j.specs.find(s=>s.number===103).workers.find(w=>w.name==="impl-303").anomalous' false
check "interrupted attention" "$BOARD/repos/owner__alpha.json" 'j.attention.some(a=>a.kind==="interrupted"&&a.spec===103)' true
check "parked attention" "$BOARD/repos/owner__alpha.json" 'j.attention.some(a=>a.kind==="parked"&&a.spec===104)' true
check "worker attention" "$BOARD/repos/owner__alpha.json" 'j.attention.some(a=>a.kind==="worker"&&a.spec===101)' true
check "needs attention set" "$BOARD/repos/owner__alpha.json" 'j.needs_attention' true
check "last activity includes claim" "$BOARD/repos/owner__alpha.json" 'j.last_activity' "$(iso_ago 300)"
check "snapshot has ISO snapshot time" "$BOARD/snapshot.json" '!isNaN(Date.parse(j.snapshot_at)) && j.snapshot_at.includes("T")' true
check "machine summary includes unused" "$BOARD/snapshot.json" 'j.repos.filter(r=>r.unused).length' 1

# Overview filtering and ordering.  alpha and old need attention; recent is
# normal and recent; cold is normal and twenty days old; beta has no activity.
run_board "$WORK/overview.out"
expect_exit 0 "overview succeeds"
expect_has '显示 3 个仓库，隐藏' "overview reports shown and hidden counts" "$WORK/overview.out"
expect_has 'owner/alpha' "attention repo always shown" "$WORK/overview.out"
expect_has 'owner/old' "old parked repo always shown" "$WORK/overview.out"
expect_has 'owner/recent' "recent normal repo shown" "$WORK/overview.out"
expect_without 'owner/cold' "twenty-day normal repo hidden by default" "$WORK/overview.out"
expect_without 'owner/beta' "repo without activity hidden by default" "$WORK/overview.out"
expect_without 'owner/unused' "unused repo hidden from overview" "$WORK/overview.out"
if [ "$(grep -n 'owner/alpha' "$WORK/overview.out" | cut -d: -f1)" -lt "$(grep -n 'owner/recent' "$WORK/overview.out" | cut -d: -f1)" ]; then
  ok "attention sorts before normal repos"
else
  bad "attention sorts before normal repos" "alpha not before recent"
fi

run_board "$WORK/since.out" --since 30d
expect_exit 0 "overview with --since succeeds"
expect_has 'owner/cold' "--since widens activity window" "$WORK/since.out"
expect_without 'owner/beta' "--since does not invent activity" "$WORK/since.out"

run_board "$WORK/all.out" --all
expect_exit 0 "overview with --all succeeds"
expect_has 'owner/beta' "--all includes no-activity repo" "$WORK/all.out"
expect_without 'owner/unused' "--all still excludes unused repo" "$WORK/all.out"

# Single-repo rendering and all accepted selector forms.
run_board "$WORK/repo-owner.out" owner/alpha
expect_exit 0 "owner/name selector succeeds"
expect_has '地图：2' "single repo shows map count" "$WORK/repo-owner.out"
expect_has '规格：6（已落地 1，实现中 2，中断 1，待拆 0，可实现 2）｜Ticket 已关 2/7' "single repo labels counts" "$WORK/repo-owner.out"
expect_has '#10 Alpha map' "single repo shows map tree" "$WORK/repo-owner.out"
expect_has '#11 Closed map［closed］（Ticket 3 张）' "closed map tickets collapse to a total count" "$WORK/repo-owner.out"
expect_without '#105 ' "closed map hides closed specs" "$WORK/repo-owner.out"
expect_without '#206 ' "closed map hides direct tickets" "$WORK/repo-owner.out"
expect_without '#208 ' "closed map hides open direct tickets" "$WORK/repo-owner.out"
expect_has '#101 Spec 101' "single repo shows open spec" "$WORK/repo-owner.out"
expect_has '实现 implement（第 1 波）' "single repo shows run phase" "$WORK/repo-owner.out"
expect_has 'impl-401' "single repo shows abnormal worker" "$WORK/repo-owner.out"
expect_has 'fix-406' "single repo shows quota worker" "$WORK/repo-owner.out"
expect_has '另有 4 个正常 Worker' "normal workers collapse to a count" "$WORK/repo-owner.out"
expect_without 'impl-402' "normal workers are not listed individually" "$WORK/repo-owner.out"
expect_without 'impl-405' "long-idle normal worker is not listed individually" "$WORK/repo-owner.out"
expect_has '!' "single repo marks anomaly" "$WORK/repo-owner.out"

(
  env HOME="$HOME_DIR" ISS_STATE_DIR="$STATE" BOARD_DIR="$BOARD" \
    BOARD_NOW="$NOW_ISO" BOARD_PIPELINE_STATUS="$BIN/fake-pipeline" \
    BOARD_CONCURRENCY=2 PATH="$BIN:$PATH" \
    bash "$SCRIPT" owner/alpha 2> "$WORK/epipe.err" | head -n 1 > "$WORK/epipe.out"
  printf '%s\n' "${PIPESTATUS[0]}" > "$WORK/epipe.rc"
)
RUN_EXIT=$(cat "$WORK/epipe.rc")
expect_exit 0 "closed stdout pipe exits zero"
expect_without 'EPIPE' "closed stdout pipe is silent" "$WORK/epipe.err"

run_board "$WORK/repo-dir.out" alpha
expect_exit 0 "directory selector succeeds"
expect_has 'owner/alpha' "directory selector resolves alpha" "$WORK/repo-dir.out"

(
  cd "$WORK" || exit 125
  run_board "$WORK/repo-relative.out" repos/alpha
)
expect_exit 0 "relative path selector succeeds"
expect_has 'owner/alpha' "relative path resolves alpha" "$WORK/repo-relative.out"

(
  cd "$WORK/alpha-wt/spec-999" || exit 125
  run_board "$WORK/repo-cwd.out"
)
expect_exit 0 "inside worktree defaults to repository"
expect_has 'owner/alpha' "worktree default resolves repository" "$WORK/repo-cwd.out"

run_board "$WORK/repo-unknown.out" does-not-exist
expect_exit 64 "unknown repo selector exits sixty-four"
expect_has '未匹配' "unknown selector explains failure" "$WORK/repo-unknown.out.err"

node - "$REGISTRY" "$ALPHA" <<'NODE'
const fs = require('fs'), path = require('path'), [file, alpha] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.result.repos.push({path: path.join(path.dirname(alpha), path.basename(alpha)), gitRemoteIdentity: {canonicalKey: 'github.com/other/alpha'}});
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
run_board "$WORK/repo-ambiguous.out" alpha
expect_exit 64 "ambiguous directory selector exits sixty-four"
expect_has '歧义' "ambiguous selector explains matches" "$WORK/repo-ambiguous.out.err"

# ---- render (static mobile pages from fixed snapshots) ----
RB=$WORK/render-board
mkdir -p "$RB/repos" "$RB/r/gone/stale"
printf 'old\n' > "$RB/r/gone/stale/index.html"
RB_NOW=2026-11-19T02:20:00.000Z
RB_SNAP=2026-11-19T02:17:58.527Z
RB_BOARD=$RB RB_SNAP=$RB_SNAP node -e '
  const fs = require("fs"), dir = process.env.RB_BOARD, at = process.env.RB_SNAP;
  const c = (mt, mc, st, sl, tt, tc) => ({
    maps: {total: mt, closed: mc, shelved: 0, empty: 0, exploring: 1, fog_pending: 0, unconverted: 0},
    specs: {total: st, landed: sl, needs_tickets: 0, ready: 0, running: 1, interrupted: 0, shelved: 0},
    tickets: {total: tt, closed: tc}});
  const base = (repo, o) => Object.assign({repo, path: "/x/" + repo, dir: repo.split("/")[1],
    snapshot_at: at, github_fetched_at: at, github_error: null, error: null, unused: false,
    needs_attention: false, attention: [], last_activity: null, next_wave: null,
    claims: {active: 0, reserved: 0, interrupted: 0}, maps: [], specs: [], loose_specs: []}, o);
  const t = (n, title, state) => ({number: n, title, state, shelved: false});
  const run = spec => ({dir: "/r", phase: "integrate", wave: 2, tickets: {merged: 3, in_progress: 1, todo: 2}, updated: at});
  const spec65 = {number: 65, title: "<b>Evil</b> & \"quote\"", kind: "spec", state: "open", status: "running",
    claim: {state: "active", branch: "spec-65", worktree: "/w", claimed_at: at}, depends_on: [],
    tickets_total: 3, tickets_closed: 1,
    tickets: [t(66, "已做票CLOSEDTICKET", "closed"), t(67, "进行中票<script>alert(1)</script>", "open"), t(68, "待做票OPENTICKET", "open")],
    run: run(), workers: [
      {name: "impl-67", role: "impl", ticket: 67, state: "finished", status: "error", started_at: 1, duration_s: 4000, idle_s: 3800, anomalous: true, anomaly_reason: "worker 结束状态为 error"},
      {name: "impl-68", role: "impl", ticket: 68, state: "running", status: null, started_at: 1, duration_s: 100, idle_s: 5, anomalous: false, anomaly_reason: null}]};
  const spec11 = {number: 11, title: "老规格", kind: "spec", state: "closed", status: "landed", claim: null, depends_on: [],
    tickets_total: 2, tickets_closed: 2, tickets: [t(12, "老票", "closed"), t(13, "老票二", "closed")], run: null, workers: []};
  const loose = {number: 80, title: "散规格LOOSESPEC", kind: "spec", state: "open", status: "needs_tickets", claim: null, depends_on: [], tickets_total: 0, tickets_closed: 0, tickets: [], run: null, workers: []};
  const alpha = base("owner/alpha", {
    needs_attention: true, attention: [{kind: "worker", spec: 65, detail: "impl-67: worker 结束状态为 error"}],
    last_activity: "2026-11-19T01:20:00.000Z", counts: c(3, 1, 4, 2, 10, 4),
    claims: {active: 1, reserved: 0, interrupted: 0},
    next_wave: {parallel_specs: 2, resume: [], active: [{spec: 65, title: "<b>Evil</b> & \"quote\"", branch: "spec-65"}], wave1: [], later: [], cycles: [], standalone: []},
    maps: [
      {number: 1, title: "老地图OLDMAP", state: "closed", status: "closed", shelved: false, decisions_total: 1, decisions_open: 0, specs: [spec11], tickets: []},
      {number: 58, title: "新地图NEWMAP", state: "open", status: "converted", shelved: false, decisions_total: 1, decisions_open: 0, specs: [spec65], tickets: []}],
    specs: [spec11, spec65, loose], loose_specs: [loose]});
  const beta = base("owner/beta", {last_activity: "2026-11-17T02:20:00.000Z", counts: c(0, 0, 1, 1, 4, 4),
    next_wave: {resume: [], active: [], wave1: [{spec: 3, title: "待启动规格WAVEONE"}], later: []}});
  const gamma = base("owner/gamma", {last_activity: "2026-10-01T00:00:00.000Z", counts: c(1, 1, 1, 1, 2, 2),
    next_wave: {resume: [], active: [], wave1: [], later: []}});
  const delta = base("owner/delta", {unused: true, counts: c(0, 0, 0, 0, 0, 0)});
  const all = [alpha, beta, gamma, delta];
  for (const r of all) fs.writeFileSync(`${dir}/repos/${r.repo.replace("/", "__")}.json`, JSON.stringify(r));
  const slim = r => ({repo: r.repo, path: r.path, dir: r.dir, unused: r.unused, needs_attention: r.needs_attention,
    attention: r.attention, last_activity: r.last_activity, github_fetched_at: r.github_fetched_at, counts: r.counts, claims: r.claims, error: r.error});
  fs.writeFileSync(`${dir}/snapshot.json`, JSON.stringify({snapshot_at: at, registry: {source: "orca", fetched_at: at}, repos: [gamma, delta, beta, alpha].map(slim)}));
'
render_board() {
  output=$1; shift
  env HOME="$HOME_DIR" ISS_STATE_DIR="$STATE" BOARD_DIR="$RB" BOARD_NOW="$RB_NOW" TZ=UTC \
    PATH="$BIN:$PATH" bash "$SCRIPT" "$@" > "$output" 2> "$output.err"
  RUN_EXIT=$?
}
render_board "$WORK/render.out" render
expect_exit 0 "render exits zero"
HOME_HTML=$RB/index.html
ALPHA_HTML=$RB/r/owner/alpha/index.html
for f in "$HOME_HTML" "$ALPHA_HTML" "$RB/r/owner/beta/index.html" "$RB/r/owner/gamma/index.html"; do
  [ -s "$f" ] && ok "page written $(basename "$(dirname "$f")")" || bad "page written $f" "missing"
done
[ ! -e "$RB/r/owner/delta" ] && ok "unused repo has no page" || bad "unused repo has no page" "exists"
[ ! -e "$RB/r/gone/stale" ] && [ ! -e "$RB/r/gone" ] && ok "stale repo page removed" || bad "stale repo page removed" "still there"
ls -A "$RB" "$RB/r/owner/alpha" | grep -q '\.tmp' && bad "no temp files left" "tmp present" || ok "no temp files left"
expect_has 'data-snapshot-at="2026-11-19T02:17:58.527Z"' "home carries snapshot time" "$HOME_HTML"
expect_has '更新于 2026-11-19 02:17' "home shows absolute time without js" "$HOME_HTML"
expect_has 'id="refresh"' "home has refresh button" "$HOME_HTML"
expect_has "fetch('/refresh', {method: 'POST'})" "refresh posts to /refresh" "$HOME_HTML"
expect_has '已触发刷新' "refresh success message" "$HOME_HTML"
expect_has '刷新服务不可用' "refresh failure message" "$HOME_HTML"
expect_has 'href="r/owner/alpha/index.html"' "home links to repo page relatively" "$HOME_HTML"
expect_has 'href="../../../index.html"' "repo page links back relatively" "$ALPHA_HTML"
expect_has '显示全部（另有 1 个）' "home show-all counts hidden repos" "$HOME_HTML"
expect_has '<details class="more">' "show-all works without js" "$HOME_HTML"
# order: alpha (attention) before beta (recent) before gamma (hidden)
ORDER=$(grep -o 'aria-label="查看 owner/[a-z]*"' "$HOME_HTML" | sed 's/.*owner\///; s/"//' | tr '\n' ' ')
[ "$ORDER" = "alpha beta gamma " ] && ok "home order matches terminal rule" || bad "home order" "[$ORDER]"
HIDDEN_AT=$(grep -n 'class="more"' "$HOME_HTML" | head -1 | cut -d: -f1)
GAMMA_AT=$(grep -n '查看 owner/gamma' "$HOME_HTML" | head -1 | cut -d: -f1)
[ -n "$HIDDEN_AT" ] && [ "$GAMMA_AT" -gt "$HIDDEN_AT" ] && ok "quiet repo is inside show-all" || bad "quiet repo hidden" "at=$GAMMA_AT more=$HIDDEN_AT"
expect_without 'owner/delta' "unused repo not on home" "$HOME_HTML"
expect_has '需处理' "attention badge" "$HOME_HTML"
expect_has 'impl-67: worker 结束状态为 error' "attention reason on home" "$HOME_HTML"
expect_has '地图 已关 1/3' "home map count is labelled" "$HOME_HTML"
expect_has 'Spec 已落 2/4' "home spec count is labelled" "$HOME_HTML"
expect_has 'Ticket 已关 4/10' "home ticket count is labelled" "$HOME_HTML"
expect_has '地图完成比例</span><b>33%</b>' "home map percent" "$HOME_HTML"
expect_has 'Spec完成比例</span><b>50%</b>' "home spec percent" "$HOME_HTML"
expect_has 'Ticket完成比例</span><b>40%</b>' "home ticket percent" "$HOME_HTML"
expect_has '地图完成比例</span><b>—</b>' "home zero total shows dash" "$HOME_HTML"
expect_has '待启动规格WAVEONE' "home next-step start point" "$HOME_HTML"
expect_has '下一步' "home next label" "$HOME_HTML"
# repo page
expect_has '<h2>地图</h2><strong>3<small> 张</small>' "repo map count" "$ALPHA_HTML"
expect_has '<h2>Spec</h2><strong>4<small> 份</small>' "repo spec count" "$ALPHA_HTML"
expect_has '<h2>Ticket</h2><strong>10<small> 张</small>' "repo ticket count" "$ALPHA_HTML"
expect_has '<b class="pct">33%</b>' "repo map percent" "$ALPHA_HTML"
expect_has '<b class="pct">50%</b>' "repo spec percent" "$ALPHA_HTML"
expect_has '<b class="pct">40%</b>' "repo ticket percent" "$ALPHA_HTML"
expect_has '下一波起点' "repo next wave section" "$ALPHA_HTML"
expect_has '#65 &lt;b&gt;Evil&lt;/b&gt; &amp; &quot;quote&quot;' "repo next wave start point" "$ALPHA_HTML"
expect_has '地图 #58 · 新地图NEWMAP' "repo open map node" "$ALPHA_HTML"
expect_has '已关闭 · 1 Spec · 2 Ticket' "closed map collapsed to counts" "$ALPHA_HTML"
expect_without '老票二' "closed map hides children" "$ALPHA_HTML"
expect_has '待做票OPENTICKET' "open ticket listed" "$ALPHA_HTML"
expect_without '已做票CLOSEDTICKET' "closed ticket collapsed" "$ALPHA_HTML"
expect_has '已关 Ticket 1 张' "closed tickets show count" "$ALPHA_HTML"
expect_has 'Run 阶段 <b>integrate</b> · 第 2 波' "run phase and wave" "$ALPHA_HTML"
expect_has 'Run：已合 3 · 进行中 1 · 待做 2' "run ticket counts are labelled" "$ALPHA_HTML"
expect_has 'Run 已合 3/6' "run summary distinguishes merged count" "$ALPHA_HTML"
expect_has 'claim <b>active</b>' "claim state" "$ALPHA_HTML"
expect_has '散 Spec（不属于地图）' "loose spec group" "$ALPHA_HTML"
expect_has '散规格LOOSESPEC' "loose spec listed" "$ALPHA_HTML"
expect_has '<details class="worker worker-error" open>' "anomalous worker expanded" "$ALPHA_HTML"
if grep -Eq '<details class="worker ?"[^>]*open' "$ALPHA_HTML"; then bad "normal worker collapsed" "open"; else ok "normal worker collapsed"; fi
expect_has 'data-snapshot-at="2026-11-19T02:17:58.527Z"' "repo carries snapshot time" "$ALPHA_HTML"
expect_has 'id="refresh"' "repo has refresh button" "$ALPHA_HTML"
# escaping and no external resources
for f in "$HOME_HTML" "$ALPHA_HTML"; do
  expect_without '<script>alert(1)' "no raw script injection $(basename "$(dirname "$f")")" "$f"
  expect_without '<b>Evil</b>' "titles escaped $(basename "$(dirname "$f")")" "$f"
  if grep -Eq 'https?://|src=|@import|<link' "$f"; then bad "no external resources $f" "$(grep -Eo 'https?://[^" ]*' "$f" | head -3)"; else ok "no external resources $(basename "$(dirname "$f")")"; fi
done
expect_has '&lt;script&gt;alert(1)&lt;/script&gt;' "script text escaped" "$ALPHA_HTML"
# render is idempotent and does not refresh
cp "$HOME_HTML" "$WORK/home.first"
render_board "$WORK/render2.out" render
cmp -s "$HOME_HTML" "$WORK/home.first" && ok "render is deterministic" || bad "render is deterministic" "differs"
render_board "$WORK/render-bad.out" render --force
expect_exit 1 "render rejects refresh options"
RB_SAVE=$RB; RB=$WORK/nonexistent-board
render_board "$WORK/render-none.out" render
expect_exit 1 "render without snapshot fails"
RB=$RB_SAVE

# ---- prune (Board pruning) ----
norm() { node -e 'process.stdout.write(require("path").normalize(process.argv[1]))' "$1"; }
# Restore an unambiguous registry (an earlier test added a same-named repo).
node - "$REGISTRY" <<'NODE'
const fs = require('fs'), f = process.argv[2];
const v = JSON.parse(fs.readFileSync(f, 'utf8'));
v.result.repos = v.result.repos.filter(r => r.gitRemoteIdentity.canonicalKey !== 'github.com/other/alpha');
fs.writeFileSync(f, JSON.stringify(v));
NODE
GH_LOG=$WORK/gh.log
GH_STATE=$WORK/gh-state
export GH_LOG GH_STATE
mkdir -p "$GH_STATE"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "issue view") ;;
  *) echo "fake gh: write/unknown call refused: $*" >&2; exit 99 ;;
esac
number=$3
[ -f "$GH_STATE/$number" ] || { echo "fake gh: no such issue" >&2; exit 1; }
read -r state closed < "$GH_STATE/$number"
printf '{"state":"%s","closedAt":"%s"}\n' "$state" "${closed:-}"
GHEOF
chmod +x "$BIN/gh"
printf 'OPEN\n' > "$GH_STATE/101"
printf 'CLOSED %s\n' "$(iso_ago 2592000)" > "$GH_STATE/105"
printf 'CLOSED %s\n' "$(iso_ago 259200)" > "$GH_STATE/106"
printf 'CLOSED %s\n' "$(iso_ago 2592000)" > "$GH_STATE/108"
# 107: no state file, so gh fails.
PR105=$(run_json pr105 review 1 0 0 0 2600000 105 alpha)
PR106=$(run_json pr106 review 1 0 0 0 3600 106 alpha)
PR107=$(run_json pr107 review 1 0 0 0 2600000 107 alpha)
PR108=$(run_json pr108 review 1 0 0 0 2600000 108 alpha)
GHOST_RUN=$(run_json ghost review 1 0 0 0 3600 9 ghost)
GHOST_RUN2=$(run_json ghost2 review 1 0 0 0 3600 9 ghost)
LAUNCH=$HOME_DIR/.cache/implement-spec-split/launch
mkdir -p "$LAUNCH" "$BOARD/repos" "$BOARD/graphs"
printf '{}\n' > "$LAUNCH/gone__ghost.json"
printf '{}\n' > "$LAUNCH/owner__alpha.json"
printf '{}\n' > "$BOARD/repos/gone__ghost.json"
printf '{}\n' > "$BOARD/repos/owner__alpha.json"
printf '{}\n' > "$BOARD/graphs/gone__ghost.json"
CL=$ALPHA_COMMON/implement-spec-split/claims
for n in 105 106; do
  printf '{"spec":%s,"pid":123,"pid_start":"old","claimed_at":"%s"}\n' "$n" "$(iso_ago 99)" > "$CL/spec-$n.json"
done
printf '{"spec":108,"pid":null,"pid_start":"","handoff":"fresh","handoff_until_epoch":9999999999}\n' > "$CL/spec-108.json"
printf '{"spec":107,"pid":123,"pid_start":"old"}\n' > "$CL/spec-107.json"

run_board "$WORK/prune-dry.out" prune
expect_exit 0 "prune dry-run exits zero"
expect_has "dry-run" "prune dry-run says so" "$WORK/prune-dry.out"
expect_has "$(norm "$PR105")" "dry-run lists old closed run" "$WORK/prune-dry.out"
expect_has "$(norm "$GHOST_RUN")" "dry-run lists removed-repo run" "$WORK/prune-dry.out"
expect_has "gone__ghost.json" "dry-run lists removed-repo files" "$WORK/prune-dry.out"
expect_has "spec-105.json" "dry-run lists dead claim for closed spec" "$WORK/prune-dry.out"
for f in "$PR105" "$PR106" "$PR107" "$PR108" "$GHOST_RUN" "$GHOST_RUN2" "$LAUNCH/gone__ghost.json" \
  "$BOARD/repos/gone__ghost.json" "$BOARD/graphs/gone__ghost.json" "$CL/spec-105.json" "$CL/spec-106.json"; do
  [ -e "$f" ] && ok "dry-run keeps $(basename "$f")" || bad "dry-run keeps $(basename "$f")" "deleted"
done

run_board "$WORK/prune-refresh.out" snapshot --force  # refresh the cached registry
BOARD_ORCA_FAIL=1 run_board "$WORK/prune-orca-fail.out" prune --yes
expect_exit 0 "prune with orca down exits zero"
expect_has "orca repo list 失败" "orca failure reason printed" "$WORK/prune-orca-fail.out"
[ -e "$GHOST_RUN" ] && [ -e "$LAUNCH/gone__ghost.json" ] && [ -e "$BOARD/repos/gone__ghost.json" ] \
  && ok "orca failure skips class 1" || bad "orca failure skips class 1" "removed-repo leftovers deleted"
[ ! -e "$PR105" ] && ok "orca failure still runs class 2 from cached registry" || bad "orca failure still runs class 2" "still there"
printf 'CLOSED %s\n' "$(iso_ago 2592000)" > "$GH_STATE/105"
PR105=$(run_json pr105 review 1 0 0 0 2600000 105 alpha)
printf '{"spec":105,"pid":123,"pid_start":"old"}\n' > "$CL/spec-105.json"

run_board "$WORK/prune-yes.out" prune --yes
expect_exit 0 "prune --yes exits zero"
for f in "$PR105" "$PR108" "$GHOST_RUN" "$GHOST_RUN2" "$LAUNCH/gone__ghost.json" "$BOARD/repos/gone__ghost.json" \
  "$BOARD/graphs/gone__ghost.json" "$CL/spec-105.json" "$CL/spec-106.json"; do
  [ ! -e "$f" ] && ok "--yes deleted $(basename "$f")" || bad "--yes deleted $(basename "$f")" "still exists"
done
for f in "$PR106" "$PR107" "$RUN101" "$RUN104" "$LAUNCH/owner__alpha.json" "$BOARD/repos/owner__alpha.json" \
  "$CL/spec-101.json" "$CL/spec-107.json" "$CL/spec-108.json"; do
  [ -e "$f" ] && ok "--yes kept $(basename "$f")" || bad "--yes kept $(basename "$f")" "deleted"
done
expect_has "状态查不到" "gh failure keep reason printed" "$WORK/prune-yes.out"
if grep -Eq '^(issue (create|edit|close|comment)|api)' "$GH_LOG" || ! grep -q '^issue view' "$GH_LOG"; then
  bad "prune only reads from gh" "$(cat "$GH_LOG")"
else
  ok "prune only reads from gh"
fi
run_board "$WORK/prune-help.out" --help
expect_has "Do NOT put prune in a scheduled job" "help warns against scheduling" "$WORK/prune-help.out"
expect_has "先按刷新节奏刷新（过期才调 gh）再显示" "help explains terminal refresh cadence" "$WORK/prune-help.out"
expect_has "Orca 返回空列表时也跳过第 1 类" "help explains conservative empty registry" "$WORK/prune-help.out"
run_board "$WORK/prune-bad.out" --yes
expect_exit 1 "--yes without prune is rejected"

run_board "$WORK/help.out" --help
expect_exit 0 "help succeeds"
expect_has 'Usage: board.sh' "help shows usage" "$WORK/help.out"

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
