#!/usr/bin/env bash
# Isolated fake-dependency tests for find-next/scripts/launch-wave.sh.
# orca is a fake outside PATH, named by ISS_ORCA (the one Orca replacement
# variable, read by scripts/lib-orca.sh); the `orca` on the tests' PATH refuses
# every call. The Stage route table is the real scripts/stage-route.sh reading
# a table of this test's own (ISS_STAGE_ROUTE_FILE), so the user's real table
# is never read; where the real table cannot produce a fault, a fake stands in
# (LAUNCH_WAVE_STAGE_ROUTE).

set -u

# A flash orchestrator session exports FLASH_ORCHESTRATOR=1, which has
# launch-wave.sh record that a flash orchestrator launched the batch. Only the
# flash block below sets the variable; every other case runs as an ordinary
# session, whatever session started this test.
unset FLASH_ORCHESTRATOR

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/find-next/scripts/launch-wave.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/launch-wave-test.XXXXXX")
OLD_SCRIPT=$WORK/old-launch-wave.sh
BIN=$WORK/bin
ORCA_BIN=$WORK/orca-bin
REPO=$WORK/git-repo
ORIGIN=$WORK/test/repo.git  # path ends in the --repo slug the script checks
WT222=$WORK/spec-222
WT224=$WORK/'spec-224 with spaces'
MAIN_WORKTREE_PATH=$REPO
PLAN=$WORK/plan.json
PLAN_TEXT=$WORK/plan.txt
EMPTY_PLAN=$WORK/empty-plan.json
EMPTY_PLAN_TEXT=$WORK/empty-plan.txt
SHELVED_ONLY_PLAN=$WORK/shelved-only-plan.json
SHELVED_ONLY_PLAN_TEXT=$WORK/shelved-only-plan.txt
ONLY_INVISIBLE_PLAN=$WORK/only-invisible-plan.json
ONLY_INVISIBLE_PLAN_TEXT=$WORK/only-invisible-plan.txt
FLASH_ONLY_INVISIBLE_PLAN=$WORK/flash-only-invisible-plan.json
FLASH_ONLY_INVISIBLE_PLAN_TEXT=$WORK/flash-only-invisible-plan.txt
CYCLE_PLAN=$WORK/cycle-plan.json
CYCLE_PLAN_TEXT=$WORK/cycle-plan.txt
RESUME_ONLY_PLAN=$WORK/resume-only-plan.json
RESUME_ONLY_PLAN_TEXT=$WORK/resume-only-plan.txt
ORCA_LIST=$WORK/orca-list.json
ORCA_LIST_NO_MAIN=$WORK/orca-list-no-main.json
ORCA_LIST_LARGE=$WORK/orca-list-large.json
ORCA_LOG=$WORK/orca.log
ORCA_GUARD_LOG=$WORK/orca-guard.log
CLAIM_LOG=$WORK/claim.log
MAX_LOG=$WORK/max-workers.log
PIPELINE_LOG=$WORK/pipeline.log
SEQUENCE_LOG=$WORK/sequence.log
WORKER_STATE_DIR=$WORK/worker-state
LAUNCH_STATE_DIR=$WORK/launch-state
LAUNCH_STATE_FILE=$LAUNCH_STATE_DIR/test__repo.json
LOCK_DIR=$REPO/.git/implement-spec-split/locks/launch-wave.lock
STAGE_ROUTE_FILE=$WORK/stage-route
FAKE_STAGE_ROUTE=$WORK/fake-stage-route.sh
CLAIM_MARK_DIR=$WORK/claim-marks
SPEC_COPY_DIR=$WORK/spec-copies
SCREEN_WORKING=$WORK/screen-working.json
SCREEN_EXITED=$WORK/screen-exited.json
SHOW_EXITED=$WORK/show-exited.json
SCREEN_IDLE=$WORK/screen-idle.json
SCREEN_SUBMITTED=$WORK/screen-submitted.json
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

expect_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text]"
  else
    record PASS "$name"
  fi
}

# No line of the file is exactly this text: for an argument of the fake orca's
# log, where a word like launch or rm also occurs inside the temp paths.
expect_line_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fxq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected line [$text]"
  else
    record PASS "$name"
  fi
}

expect_file() {
  file=$1
  name=$2
  if [ -e "$file" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$file]"
  fi
}

expect_count() {
  pattern=$1
  expected=$2
  name=$3
  file=$4
  actual=$(grep -Fc -- "$pattern" "$file" 2>/dev/null || true)
  if [ "$actual" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "count=$actual, expected=$expected"
  fi
}

expect_arg_after() {
  marker=$1
  value=$2
  name=$3
  file=$4
  if grep -A1 -F -- "$marker" "$file" 2>/dev/null | grep -Fqx -- "$value"; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$marker $value]"
  fi
}

expect_sequence() {
  first=$1
  second=$2
  name=$3
  first_line=$(grep -Fn -- "$first" "$SEQUENCE_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  second_line=$(grep -Fn -- "$second" "$SEQUENCE_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$first_line" ] && [ -n "$second_line" ] &&
     [ "$first_line" -lt "$second_line" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "lines=${first_line:-none},${second_line:-none}"
  fi
}

# The fake orca logs its command and then one line per argument, so a whole
# log (or a tail of one) can be compared with the calls a test expects.
expect_log() {
  expected=$1
  name=$2
  file=$3
  if [ "$(cat "$file" 2>/dev/null)" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "$(diff <(printf '%s\n' "$expected") "$file" 2>/dev/null | tail -n 6 | tr '\n' ' ')"
  fi
}

# The same for the whole Orca log of a run, with the paths of the run's
# temporary dispatch directory (where the spec files live) folded to
# <dispatch>, since that directory's name changes from run to run. The
# expected text writes <dispatch>/spec-<n>.md.
expect_orca_log() {
  expected=$1
  name=$2
  normalized=$WORK/orca.normalized.log
  sed -E 's#^.*/launch-wave-dispatch\.[^/]+/#<dispatch>/#' "$ORCA_LOG" > "$normalized"
  expect_log "$expected" "$name" "$normalized"
}

mkdir -p "$BIN" "$ORCA_BIN" "$REPO" "$WORKER_STATE_DIR" "$LAUNCH_STATE_DIR" "$CLAIM_MARK_DIR" \
  "$SPEC_COPY_DIR" || exit 1
git show pre-flash-orchestrator:find-next/scripts/launch-wave.sh > "$OLD_SCRIPT"
chmod +x "$OLD_SCRIPT"
# The Stage route table of this test alone, empty: every stage on its default,
# so the 编排 route is claude-flash, Orca's openclaude slot.
: > "$STAGE_ROUTE_FILE"
cat > "$BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ "${2:-}" = +%Y-%m-%dT%H:%M:%SZ ]; then
  printf '%s\n' '2026-11-21T00:00:00Z'
else
  /bin/date "$@"
fi
EOF
chmod +x "$BIN/date"
mkdir -p "$WORK/test" && git init --quiet --bare --initial-branch=master "$ORIGIN"
git -C "$REPO" init --quiet --initial-branch=master
git -C "$REPO" config user.name 'Launch Wave Test'
git -C "$REPO" config user.email 'launch-wave-test@example.invalid'
git -C "$REPO" config commit.gpgsign false
printf '%s\n' 'launch wave fixture' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push --quiet origin master
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$REPO" fetch --quiet origin
git -C "$REPO" worktree add --quiet "$WT222" -b spec-222
git -C "$REPO" worktree add --quiet "$WT224" -b spec-224
MAIN_WORKTREE_PATH=$(git -C "$REPO" worktree list --porcelain |
  sed -n 's/^worktree //p' | sed -n '1p')

# The plan pipeline-status would print: every command ends with --auto-land and
# names no implementation backend (that is the route table's business now).
node - "$WT222" "$WT224" > "$PLAN" <<'NODE'
const [visible, invisible] = process.argv.slice(2);
const command = (n) => `/implement-spec-split ${n} --auto-land --parallel 2`;
process.stdout.write(JSON.stringify({
  parallel_specs: 2,
  workers: 4,
  per_spec_parallel: 2,
  resume: [
    {spec: 222, title: 'Visible resume', branch: 'spec-222', worktree: visible, command: command(222)},
    {spec: 224, title: 'Invisible resume', branch: 'spec-224', worktree: invisible, command: command(224)},
    {spec: 238, title: 'Missing resume', branch: 'spec-238', worktree: null, command: command(238)},
  ],
  active: [],
  wave1: [
    {spec: 237, title: 'New spec', command: command(237), note: ''},
  ],
  later: [{index: 2, spec: 239, title: 'Later spec', note: '等 #237'}],
  cycles: [],
  standalone: [],
}, null, 2) + '\n');
NODE

cat > "$PLAN_TEXT" <<EOF
开发顺序（同时 2 份，共 4 个 worker）
先恢复：#222 #224 #238
第 1 波：
 1. #237 New spec → /implement-spec-split 237 --auto-land --parallel 2
之后：
 2. #239 Later spec（等 #237）
EOF

printf '%s\n' '{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[],"later":[],"cycles":[],"standalone":[]}' \
  > "$EMPTY_PLAN"
printf '%s\n' '开发顺序：没有可以实现的规格' > "$EMPTY_PLAN_TEXT"

# #240 is a fixture for a Spec whose only open execution ticket is shelved;
# pipeline-status must omit it from every ordered entry before launch-wave sees it.
printf '%s\n' '{"parallel_specs":1,"workers":4,"per_spec_parallel":4,"resume":[],"active":[],"wave1":[{"spec":237,"title":"New spec","command":"/implement-spec-split 237 --auto-land --parallel 4","note":""}],"later":[],"cycles":[],"standalone":[]}' \
  > "$SHELVED_ONLY_PLAN"
cat > "$SHELVED_ONLY_PLAN_TEXT" <<'EOF'
开发顺序（同时 1 份，共 4 个 worker）
第 1 波：
 1. #237 New spec → /implement-spec-split 237 --auto-land --parallel 4
EOF

node - "$WT224" > "$ONLY_INVISIBLE_PLAN" <<'NODE'
const worktree = process.argv[2];
process.stdout.write(JSON.stringify({
  parallel_specs: 1,
  workers: 4,
  per_spec_parallel: 2,
  resume: [{
    spec: 224,
    title: 'Invisible resume',
    branch: 'spec-224',
    worktree,
    command: '/implement-spec-split 224 --auto-land --parallel 2',
  }],
  active: [],
  wave1: [],
  later: [],
  cycles: [],
  standalone: [],
}, null, 2) + '\n');
NODE
cat > "$ONLY_INVISIBLE_PLAN_TEXT" <<'EOF'
开发顺序（同时 1 份，共 4 个 worker）
先恢复：#224
EOF

cp "$ONLY_INVISIBLE_PLAN" "$FLASH_ONLY_INVISIBLE_PLAN"
cp "$ONLY_INVISIBLE_PLAN_TEXT" "$FLASH_ONLY_INVISIBLE_PLAN_TEXT"

printf '%s\n' '{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[{"spec":237,"title":"New spec","command":"/implement-spec-split 237 --auto-land --parallel 2","note":""}],"later":[],"cycles":[222,237],"standalone":[]}' \
  > "$CYCLE_PLAN"
cat > "$CYCLE_PLAN_TEXT" <<'EOF'
开发顺序（同时 2 份，共 4 个 worker）
循环依赖：#222 #237，需要人工决定
EOF

printf '%s\n' '{"parallel_specs":1,"workers":4,"per_spec_parallel":4,"resume":[{"spec":222,"title":"Visible resume","branch":"spec-222","worktree":"'"$WT222"'","command":"/implement-spec-split 222 --auto-land --parallel 4"}],"active":[],"wave1":[],"later":[],"cycles":[],"standalone":[]}' \
  > "$RESUME_ONLY_PLAN"
cat > "$RESUME_ONLY_PLAN_TEXT" <<'EOF'
开发顺序（同时 1 份，共 4 个 worker）
先恢复：#222
第 1 波：（无，先恢复上面的规格）
EOF

node - "$WT222" "$MAIN_WORKTREE_PATH" > "$ORCA_LIST" <<'NODE'
const [visible, main] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  result: {worktrees: [{path: visible}, {path: main}]},
}) + '\n');
NODE

node - "$WT222" > "$ORCA_LIST_NO_MAIN" <<'NODE'
const visible = process.argv[2];
process.stdout.write(JSON.stringify({
  result: {worktrees: [{path: visible}]},
}) + '\n');
NODE

LARGE_TMPDIR=$WORK/launch-wave-tmp
mkdir -p "$LARGE_TMPDIR"
node - "$WT222" "$MAIN_WORKTREE_PATH" > "$ORCA_LIST_LARGE" <<'NODE'
const [visible, main] = process.argv.slice(2);
const filler = 'x'.repeat(900);
const worktrees = [{path: visible}, {path: main}];
for (let index = 0; index < 2000; index += 1) {
  worktrees.push({
    path: `/definitely/not/an/orca/worktree/${String(index).padStart(4, '0')}/${filler}`,
  });
}
process.stdout.write(JSON.stringify({result: {worktrees}}, null, 2) + '\n');
NODE

# What a terminal shows. The rendered screen of a session at work carries the
# assistant's bullets; one that exited leaves the read empty and only the
# preview of terminal show; a TUI that never got the spec typed shows its empty
# input box; a submitted prompt without any answer yet shows the spec and
# nothing else.
printf '%s\n' '{"result":{"terminal":{"status":"running","source":"screen","tail":["❯ /implement-spec-split 237 --auto-land --parallel 2","⏺ Skill(implement-spec-split)","  ⎿  Successfully loaded skill","✳ Reading SKILL.md…"]}}}' \
  > "$SCREEN_WORKING"
printf '%s\n' '{"result":{"terminal":{"status":"exited","source":"screen","tail":[]}}}' > "$SCREEN_EXITED"
printf '%s\n' '{"result":{"terminal":{"status":"exited","preview":"Claude Code v2.1.309\nInvalid API key · please run /login\nallan716@mini6 spec-237 %"}}}' \
  > "$SHOW_EXITED"
printf '%s\n' '{"result":{"terminal":{"status":"running","source":"screen","tail":["▐▛████▛█   Claude Code v2.1.309","▝▜██████─  glm-5.3-flash[1m] · API Usage Billing","╭──────────────────────────────╮","│ >                            │","╰──────────────────────────────╯"]}}}' \
  > "$SCREEN_IDLE"
printf '%s\n' '{"result":{"terminal":{"status":"running","source":"screen","tail":["▐▛████▛█   Claude Code v2.1.309","> === TASK ===","> /implement-spec-split 237 --auto-land --parallel 2","╭──────────────────────────────╮","│ >                            │","╰──────────────────────────────╯"]}}}' \
  > "$SCREEN_SUBMITTED"

cat > "$BIN/fake-pipeline" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' 'pipeline' >> "$LAUNCH_PIPELINE_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$LAUNCH_PIPELINE_LOG"; done
json=0
for arg in "$@"; do [ "$arg" = --json ] && json=1; done
if [ "$json" -eq 1 ]; then cat "$LAUNCH_PLAN_FILE"; else cat "$LAUNCH_PLAN_TEXT_FILE"; fi
EOF
chmod +x "$BIN/fake-pipeline"

cat > "$BIN/fake-pipeline-dynamic" <<'EOF'
#!/usr/bin/env bash
# Builds the plan from the received flags, the way pipeline-status --order does,
# so tests can verify which command suffix launch-wave.sh hands over.
set -u
printf '%s\n' 'pipeline' >> "$LAUNCH_PIPELINE_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$LAUNCH_PIPELINE_LOG"; done
cmd_suffix='--auto-land'
parallel=2
workers=4
json=0
previous=
for arg in "$@"; do
  case "$previous" in
    --cmd-suffix) cmd_suffix=$arg ;;
    --parallel) parallel=$arg ;;
    --workers) workers=$arg ;;
  esac
  [ "$arg" = --json ] && json=1
  previous=$arg
done
CMD_SUFFIX=$cmd_suffix PARALLEL=$parallel WORKERS=$workers \
RESUME_PATH="${LAUNCH_RESUME_DEFAULT:-}" JSON_MODE=$json node <<'NODE'
const suffix = process.env.CMD_SUFFIX;
const parallel = Number(process.env.PARALLEL);
const workers = Number(process.env.WORKERS);
const per = Math.max(1, Math.floor(workers / parallel));
const command = (n) => `/implement-spec-split ${n}${suffix === '' ? '' : ` ${suffix}`} --parallel ${per}`;
const plan = {
  parallel_specs: parallel,
  workers,
  per_spec_parallel: per,
  resume: [{
    spec: 222,
    title: 'Visible resume',
    branch: 'spec-222',
    worktree: process.env.RESUME_PATH,
    command: command(222),
  }],
  active: [],
  wave1: [{spec: 237, title: 'New spec', command: command(237), note: ''}],
  later: [],
  cycles: [],
  standalone: [],
};
if (process.env.JSON_MODE === '1') {
  process.stdout.write(JSON.stringify(plan, null, 2) + '\n');
} else {
  process.stdout.write([
    `开发顺序（同时 ${parallel} 份，共 ${workers} 个 worker）`,
    '先恢复：#222',
    '第 1 波：',
    ` 1. #237 New spec → ${command(237)}`,
  ].join('\n') + '\n');
}
NODE
EOF
chmod +x "$BIN/fake-pipeline-dynamic"

cat > "$BIN/fake-max-workers" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'max-workers' >> "$LAUNCH_MAX_LOG"
printf '%s\n' "$1" >> "$LAUNCH_MAX_LOG"
printf '%s\n' 'MAX_WORKERS' >> "$LAUNCH_SEQUENCE_LOG"
EOF
chmod +x "$BIN/fake-max-workers"

# claim.sh: reserve and release as before; status answers what a Spec's claim
# record holds. A record carries a pid once the session ran claim.sh take; by
# default every reserved Spec is claimed at once. LAUNCH_CLAIM_UNCLAIMED lists
# Specs whose session never claims; a mark file $LAUNCH_CLAIM_MARK_DIR/spec-<n>
# claims that Spec from then on (the fake orca writes one on a terminal read
# when LAUNCH_ORCA_READ_MARKS_CLAIM=1, so a test can make the claim land after
# launch-wave looked at the terminal). LAUNCH_CLAIM_HANDOFF_LEFT is how far
# the reservation's expiry is (seconds).
cat > "$BIN/fake-claim" <<'EOF'
#!/usr/bin/env bash
set -u
# One write per call: reserves of different Specs run at the same time, and
# their lines must not interleave in the log.
record=$(printf '%s\n' claim "$PWD" "$@")
printf '%s\n' "$record" >> "$LAUNCH_CLAIM_LOG"
case "${1:-}" in
  status)
    spec=$2
    printf '%s\n' 'CLAIM_STATUS' >> "$LAUNCH_SEQUENCE_LOG"
    pid=null
    case " ${LAUNCH_CLAIM_UNCLAIMED:-} " in
      *" $spec "*) ;;
      *) pid=4242 ;;
    esac
    [ -e "${LAUNCH_CLAIM_MARK_DIR:-/nonexistent}/spec-$spec" ] && pid=4242
    until=$(( $(date +%s) + ${LAUNCH_CLAIM_HANDOFF_LEFT:-1800} ))
    printf 'active {"spec":%s,"branch":"spec-%s","worktree":null,"pid":%s,"pid_start":"","claimed_at":"2026-11-21T00:00:00+0000","handoff":"fresh","handoff_until_epoch":%s}\n' \
      "$spec" "$spec" "$pid" "$until"
    exit 0
    ;;
  reserve)
    spec=$2
    resume=0
    [ "${3:-}" = --resume ] && resume=1
    if [ "$resume" -eq 1 ]; then
      if [ "$spec" = "${LAUNCH_CLAIM_FAIL_RESUME:-}" ]; then
        printf '%s\n' "interrupted spec-$spec changed state"
        exit 3
      fi
      printf '%s\n' 'CLAIM_RESUME' >> "$LAUNCH_SEQUENCE_LOG"
      # The branch's worktree, as claim.sh finds it: #224's is the one with
      # spaces, every other Spec's the default.
      case "$spec" in
        224) printf '%s\n' "${LAUNCH_RESUME_224:-$LAUNCH_RESUME_DEFAULT}" ;;
        *) printf '%s\n' "${LAUNCH_RESUME_PATH:-$LAUNCH_RESUME_DEFAULT}" ;;
      esac
      exit 0
    fi
    if [ "$spec" = "${LAUNCH_CLAIM_FAIL_FRESH:-}" ]; then
      printf '%s\n' "active spec-$spec held elsewhere"
      exit 3
    fi
    printf '%s\n' 'CLAIM_RESERVE' >> "$LAUNCH_SEQUENCE_LOG"
    exit 0
    ;;
esac
printf '%s\n' 'CLAIM_RELEASE' >> "$LAUNCH_SEQUENCE_LOG"
EOF
chmod +x "$BIN/fake-claim"

# The fake orca lives outside PATH on purpose: launch-wave.sh must reach Orca
# only through ISS_ORCA, never through an `orca` that happens to be on PATH.
# worker-start answers with a receipt whose dispatch, Task and terminal are
# keyed by the Spec, so a test can tell a first dispatch (ctx_<n>, term_<n>)
# from a retry (ctx_<n>_r, term_<n>_r). It copies every spec file it is given
# to $LAUNCH_SPEC_COPY_DIR, since the real one is deleted when the run ends.
cat > "$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
# One write per call, so that the calls of Specs dispatched at the same time
# never interleave their lines in the log.
record=$(printf '%s\n' orca "$@")
printf '%s\n' "$record" >> "$LAUNCH_ORCA_LOG"
offline() { [ "${LAUNCH_ORCA_OFFLINE:-0}" = 1 ]; }
case "$1" in
  status)
    printf '%s\n' 'ORCA_STATUS' >> "$LAUNCH_SEQUENCE_LOG"
    if offline; then exit 1; fi
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  worktree)
    case "$2" in
      list)
        printf '%s\n' 'ORCA_LIST' >> "$LAUNCH_SEQUENCE_LOG"
        if offline; then exit 1; fi
        cat "$LAUNCH_ORCA_LIST_FILE"
        ;;
      create)
        printf '%s\n' 'ORCA_CREATE' >> "$LAUNCH_SEQUENCE_LOG"
        name=
        previous=
        for arg in "$@"; do
          if [ "$previous" = --name ]; then name=$arg; fi
          previous=$arg
        done
        printf '%s\n' "$name" > "$LAUNCH_GIT_REPO/.fake-orca-last-created"
        if [ "${LAUNCH_ORCA_CREATE_BRANCH:-0}" = 1 ]; then
          git -C "$LAUNCH_GIT_REPO" branch "$name"
        fi
        if [ "${LAUNCH_ORCA_FAIL_CREATE:-0}" = 1 ]; then
          printf '%s\n' 'orca create failed' >&2
          exit 1
        fi
        printf '{"result":{"worktree":{"path":"%s"}}}\n' "${LAUNCH_CREATE_PATH:-$LAUNCH_GIT_REPO/created/$name}"
        ;;
      rm)
        printf '%s\n' 'ORCA_RM' >> "$LAUNCH_SEQUENCE_LOG"
        branch=$(cat "$LAUNCH_GIT_REPO/.fake-orca-last-created" 2>/dev/null || true)
        [ -z "$branch" ] || git -C "$LAUNCH_GIT_REPO" branch -D "$branch" >/dev/null 2>&1
        printf '%s\n' '{"result":{"removed":true}}'
        ;;
      *) exit 2 ;;
    esac
    ;;
  agent)
    # Only the pre-flash script (compared below) still starts sessions this way.
    printf '%s\n' 'ORCA_LAUNCH' >> "$LAUNCH_SEQUENCE_LOG"
    printf '%s\n' '{"result":{"agent":{"id":"fake"}}}'
    ;;
  orchestration)
    case "$2" in
      run-create)
        printf '%s\n' 'ORCA_RUN_CREATE' >> "$LAUNCH_SEQUENCE_LOG"
        if [ "${LAUNCH_ORCA_FAIL_RUN_CREATE:-0}" = 1 ]; then
          printf '%s\n' 'orca run-create failed' >&2
          exit 1
        fi
        printf '{"result":{"runId":"%s","objective":"wave"}}\n' "${LAUNCH_ORCA_RUN_ID:-run_wave}"
        ;;
      worker-start)
        retry=0
        spec=
        spec_file=
        previous=
        for arg in "$@"; do
          case "$previous" in
            --spec-file) spec_file=$arg ;;
            --retry-of) retry=1; spec=${arg#ctx_} ;;
          esac
          previous=$arg
        done
        if [ -z "$spec" ]; then
          spec=$(printf '%s' "$spec_file" | sed -E 's#^.*/spec-([0-9]+)\.md$#\1#')
        fi
        if [ "$retry" -eq 1 ]; then
          printf '%s\n' 'ORCA_RETRY' >> "$LAUNCH_SEQUENCE_LOG"
          if [ "${LAUNCH_ORCA_FAIL_RETRY:-0}" = 1 ]; then
            printf '%s\n' 'orca retry failed' >&2
            exit 1
          fi
          suffix=_r
        else
          printf '%s\n' 'ORCA_DISPATCH' >> "$LAUNCH_SEQUENCE_LOG"
          if [ "${LAUNCH_ORCA_FAIL_START:-0}" = 1 ]; then
            printf '%s\n' 'orca worker-start failed' >&2
            exit 1
          fi
          suffix=
        fi
        [ -z "$spec_file" ] || cp "$spec_file" "$LAUNCH_SPEC_COPY_DIR/spec-$spec$suffix.md"
        printf '{"result":{"dispatchId":"ctx_%s%s","taskId":"task_%s","runId":"%s","state":"ready","agent":"openclaude","mode":"terminal","terminal":"term_%s%s"}}\n' \
          "$spec" "$suffix" "$spec" "${LAUNCH_ORCA_RUN_ID:-run_wave}" "$spec" "$suffix"
        ;;
      worker-stop)
        printf '%s\n' 'ORCA_STOP' >> "$LAUNCH_SEQUENCE_LOG"
        if [ "${LAUNCH_ORCA_STOP_FAIL:-0}" = 1 ]; then
          # Orca reports a refusal as JSON on stdout, like every other answer.
          printf '%s\n' '{"ok":false,"error":{"code":"stop_unknown","message":"cannot prove the agent stopped"}}'
          exit 1
        fi
        printf '%s\n' '{"result":{"state":"stopped","processAction":"closed_agent_terminal"}}'
        ;;
      *) exit 2 ;;
    esac
    ;;
  terminal)
    case "$2" in
      read)
        printf '%s\n' 'ORCA_READ' >> "$LAUNCH_SEQUENCE_LOG"
        if [ "${LAUNCH_ORCA_READ_FAIL:-0}" = 1 ]; then
          printf '%s\n' 'orca terminal read failed' >&2
          exit 1
        fi
        if [ "${LAUNCH_ORCA_READ_MARKS_CLAIM:-0}" = 1 ]; then
          spec=${4#term_}; spec=${spec%_r}
          : > "$LAUNCH_CLAIM_MARK_DIR/spec-$spec"
        fi
        if [ -n "${LAUNCH_ORCA_SCREEN_FILE:-}" ]; then cat "$LAUNCH_ORCA_SCREEN_FILE"; else
          printf '%s\n' '{"result":{"terminal":{"status":"running","source":"screen","tail":[]}}}'
        fi
        ;;
      show)
        printf '%s\n' 'ORCA_SHOW' >> "$LAUNCH_SEQUENCE_LOG"
        if [ -n "${LAUNCH_ORCA_SHOW_FILE:-}" ]; then cat "$LAUNCH_ORCA_SHOW_FILE"; else
          printf '%s\n' '{"result":{"terminal":{"status":"running","preview":""}}}'
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$ORCA_BIN/orca"

# Guard rail: this machine has a real `orca` on PATH. The one on the tests' PATH
# refuses every call, so a launch-wave.sh that stops going through ISS_ORCA
# fails here instead of quietly reading the real Orca.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCH_ORCA_GUARD_LOG"
printf 'test-launch-wave: orca on PATH was called instead of ISS_ORCA\n' >&2
exit 99
EOF
chmod +x "$BIN/orca"

# Every run waits no time at all for a claim: the claim is read once and, when
# it is not there, the terminal is read at once. A test that wants a wait sets
# ISS_CLAIM_WAIT_OVERRIDE.
run_launch() {
  output=$1
  shift
  if [ "${LAUNCH_OMIT_WORKERS:-0}" != 1 ]; then
    set -- --workers 4 "$@"
  fi
  # A claim the fake orca marked during an earlier run does not carry over,
  # and neither does the order of an earlier run's Orca calls.
  rm -f "$CLAIM_MARK_DIR"/spec-*
  : > "$SEQUENCE_LOG"
  (
    cd "$REPO" || exit 125
    env LAUNCH_PLAN_FILE="${LAUNCH_PLAN_FILE_OVERRIDE:-$PLAN}" \
      LAUNCH_PLAN_TEXT_FILE="${LAUNCH_PLAN_TEXT_FILE_OVERRIDE:-$PLAN_TEXT}" \
      LAUNCH_ORCA_LIST_FILE="${LAUNCH_ORCA_LIST_FILE_OVERRIDE:-$ORCA_LIST}" \
      LAUNCH_CLAIM_MARK_DIR="$CLAIM_MARK_DIR" \
      LAUNCH_SPEC_COPY_DIR="$SPEC_COPY_DIR" \
      TMPDIR="${LAUNCH_TMPDIR_OVERRIDE:-${TMPDIR:-/tmp}}" \
      LAUNCH_GIT_REPO="$REPO" \
      LAUNCH_RESUME_DEFAULT="$WT222" \
      LAUNCH_RESUME_224="$WT224" \
      LAUNCH_PIPELINE_LOG="$PIPELINE_LOG" LAUNCH_CLAIM_LOG="$CLAIM_LOG" \
      LAUNCH_MAX_LOG="$MAX_LOG" LAUNCH_ORCA_LOG="$ORCA_LOG" \
      LAUNCH_ORCA_GUARD_LOG="$ORCA_GUARD_LOG" \
      LAUNCH_SEQUENCE_LOG="$SEQUENCE_LOG" \
      ISS_STAGE_ROUTE_FILE="$STAGE_ROUTE_FILE" \
      ISS_CLAIM_WAIT="${ISS_CLAIM_WAIT_OVERRIDE:-0}" \
      ISS_CLAIM_POLL="${ISS_CLAIM_POLL_OVERRIDE:-0}" \
      ISS_PIPELINE_STATUS="${ISS_PIPELINE_STATUS_OVERRIDE:-$BIN/fake-pipeline}" \
      ISS_CLAIM="$BIN/fake-claim" \
      ISS_MAX_WORKERS_CMD="$BIN/fake-max-workers" \
      ISS_ORCA="${ISS_ORCA_OVERRIDE:-$ORCA_BIN/orca}" \
      ISS_LOCK="$ROOT/scripts/lock.sh" \
      ISS_LAUNCH_STATE_DIR="${LAUNCH_STATE_DIR_OVERRIDE:-$LAUNCH_STATE_DIR}" \
      ISS_STATE_DIR="${LAUNCH_WORKER_STATE_DIR_OVERRIDE:-$WORKER_STATE_DIR}" \
      ISS_LAUNCH_WAVE_LOCK_WAIT="${ISS_LAUNCH_WAVE_LOCK_WAIT_OVERRIDE:-0}" \
      LAUNCH_WAVE_STAGE_ROUTE="${LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE:-$ROOT/scripts/stage-route.sh}" \
      PATH="$BIN:$PATH" \
      bash "${LAUNCH_SCRIPT_OVERRIDE:-$SCRIPT}" --repo "${LAUNCH_REPO_OVERRIDE:-test/repo}" "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

# Every --apply creates the wave's Run before it dispatches anything; the
# Orca log of a new Spec then continues with the child worktree's creation.
RUN_CREATE_LOG=$(printf 'orca\norchestration\nrun-create\n--objective\nSpec sessions of the development wave for test/repo\n--json')
CREATE_237_LOG=$(printf 'orca\nworktree\ncreate\n--repo\npath:%s\n--parent-worktree\npath:%s\n--name\nspec-237\n--branch\nspec-237\n--base-branch\norigin/master\n--issue\n237\n--json' "$MAIN_WORKTREE_PATH" "$MAIN_WORKTREE_PATH")
RUN_AND_CREATE_LOG=$(printf '%s\n%s' "$RUN_CREATE_LOG" "$CREATE_237_LOG")
CREATED_237=$REPO/created/spec-237

: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/dry.out"
expect_exit 0 "dry run succeeds"
expect_has '开发顺序（同时 2 份，共 4 个 worker）' 'dry run shows pipeline text' "$WORK/dry.out"
expect_has '现在启动吗？会在 Orca 里自动运行：' 'dry run uses Orca heading' "$WORK/dry.out"
expect_has " #222（恢复，原 worktree）→ /implement-spec-split 222 --auto-land --parallel 2" \
  'visible resume is automatic' "$WORK/dry.out"
expect_has " #224（恢复，Orca 列表外的 worktree）→ /implement-spec-split 224 --auto-land --parallel 2" \
  'invisible resume is dispatched into its worktree like any other' "$WORK/dry.out"
expect_has ' #238（恢复，找不到 worktree，需手动）' 'missing resume has no command' "$WORK/dry.out"
expect_has ' #237（新 worktree）→ /implement-spec-split 237 --auto-land --parallel 2' \
  'new spec gets a worktree command' "$WORK/dry.out"
expect_has '--cmd-suffix' 'dry run passes the command suffix' "$PIPELINE_LOG"
expect_has '--auto-land' 'dry run suffix authorizes unattended landing' "$PIPELINE_LOG"
expect_without '--impl' 'dry run suffix names no backend' "$PIPELINE_LOG"
expect_has --workers 'pipeline receives worker total' "$PIPELINE_LOG"
expect_has --json 'dry run asks pipeline for JSON' "$PIPELINE_LOG"
expect_without 'reserve' 'dry run makes no claim' "$CLAIM_LOG"
expect_without 'create' 'dry run creates no Orca worktree' "$ORCA_LOG"
expect_without 'run-create' 'dry run creates no Orca Run' "$ORCA_LOG"
expect_log "$(printf 'orca\nstatus\n--json\norca\nworktree\nlist\n--json')" \
  'dry run asks Orca for its status and the worktree list, nothing else' "$ORCA_LOG"
cat > "$WORK/dry.expected" <<EOF
开发顺序（同时 2 份，共 4 个 worker）
先恢复：#222 #224 #238
第 1 波：
 1. #237 New spec → /implement-spec-split 237 --auto-land --parallel 2
之后：
 2. #239 Later spec（等 #237）

现在启动吗？会在 Orca 里自动运行：
 #222（恢复，原 worktree）→ /implement-spec-split 222 --auto-land --parallel 2
 #224（恢复，Orca 列表外的 worktree）→ /implement-spec-split 224 --auto-land --parallel 2
 #238（恢复，找不到 worktree，需手动）
 #237（新 worktree）→ /implement-spec-split 237 --auto-land --parallel 2
EOF
if cmp -s "$WORK/dry.out" "$WORK/dry.expected"; then
  record PASS 'dry run output is exactly the order and the commands'
else
  record FAIL 'dry run output is exactly the order and the commands' \
    "$(diff -u "$WORK/dry.expected" "$WORK/dry.out" | tail -n 5)"
fi

# --- ISS_ORCA is the only way to reach orca -----------------------------------
# An `orca` on PATH must not be used when ISS_ORCA names a program that does
# not exist: then this is not an Orca session and the run is manual.
: > "$ORCA_LOG"; : > "$ORCA_GUARD_LOG"
ISS_ORCA_OVERRIDE=$WORK/no-such-orca run_launch "$WORK/no-orca.out"
unset ISS_ORCA_OVERRIDE
expect_exit 0 "a missing ISS_ORCA program exits 0 in a dry run"
expect_has '不在 Orca 里，请在各 worktree 手动运行：' \
  "a missing ISS_ORCA program prints the manual heading" "$WORK/no-orca.out"
if [ -s "$ORCA_GUARD_LOG" ]; then
  record FAIL 'a missing ISS_ORCA program never falls back to the orca on PATH' \
    "$(cat "$ORCA_GUARD_LOG")"
else
  record PASS 'a missing ISS_ORCA program never falls back to the orca on PATH'
fi

LARGE_ORCA_LIST_BYTES=$(wc -c < "$ORCA_LIST_LARGE" | tr -d '[:space:]')
if [ "$LARGE_ORCA_LIST_BYTES" -ge 1500000 ]; then
  record PASS 'large Orca list fixture exceeds argument limits'
else
  record FAIL 'large Orca list fixture exceeds argument limits' "bytes=$LARGE_ORCA_LIST_BYTES, expected>=1500000"
fi
LAUNCH_ORCA_LIST_FILE_OVERRIDE=$ORCA_LIST_LARGE
LAUNCH_TMPDIR_OVERRIDE=$LARGE_TMPDIR
export LAUNCH_ORCA_LIST_FILE_OVERRIDE LAUNCH_TMPDIR_OVERRIDE
: > "$ORCA_LOG"
run_launch "$WORK/large-orca-list-dry.out"
expect_exit 0 'dry run with a large Orca list succeeds'
expect_has '现在启动吗？会在 Orca 里自动运行：' \
  'large Orca list keeps Orca detection' "$WORK/large-orca-list-dry.out"
expect_has " #222（恢复，原 worktree）→ /implement-spec-split 222 --auto-land --parallel 2" \
  'large Orca list still matches the resume worktree' "$WORK/large-orca-list-dry.out"
ORCA_TEMP_RESIDUE=$(find "$LARGE_TMPDIR" -maxdepth 1 -type f -name 'launch-wave-orca.*' -print)
if [ -z "$ORCA_TEMP_RESIDUE" ]; then
  record PASS 'large Orca list temp file is cleaned up'
else
  record FAIL 'large Orca list temp file is cleaned up' "$ORCA_TEMP_RESIDUE"
fi
unset LAUNCH_ORCA_LIST_FILE_OVERRIDE LAUNCH_TMPDIR_OVERRIDE

LAUNCH_PLAN_FILE_OVERRIDE=$EMPTY_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$EMPTY_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$PIPELINE_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/empty-dry.out"
expect_exit 0 "empty dry run succeeds"
expect_has '没有可以启动的规格。' 'empty dry run says no specs' "$WORK/empty-dry.out"
expect_without '现在启动吗' 'empty dry run has no launch heading' "$WORK/empty-dry.out"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

LAUNCH_PLAN_FILE_OVERRIDE=$SHELVED_ONLY_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$SHELVED_ONLY_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/shelved-only-dry.out"
expect_exit 0 "shelved-only dry run succeeds"
expect_has ' #237（新 worktree）→ /implement-spec-split 237 --auto-land --parallel 4' \
  'normal spec remains in wave after shelved-only exclusion' "$WORK/shelved-only-dry.out"
expect_without '#240' 'shelved-only spec is not in wave output' "$WORK/shelved-only-dry.out"

run_launch "$WORK/shelved-only-apply.out" --apply --only 237,240
expect_exit 0 "shelved-only apply succeeds"
expect_has '#237 已启动' 'normal spec in filtered apply still launches' "$WORK/shelved-only-apply.out"
expect_has '#240 已不可启动，跳过' 'shelved-only spec is unavailable to launch-wave' "$WORK/shelved-only-apply.out"
expect_without '#240 已启动' 'shelved-only spec is not launched' "$WORK/shelved-only-apply.out"
expect_without '240' 'apply does not claim shelved-only spec' "$CLAIM_LOG"
expect_without 'spec-240' 'apply creates no worktree for shelved-only spec' "$ORCA_LOG"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

LAUNCH_ORCA_OFFLINE=1
export LAUNCH_ORCA_OFFLINE
: > "$ORCA_LOG"; : > "$MAX_LOG"
run_launch "$WORK/offline-dry.out"
expect_exit 0 "offline dry run succeeds"
expect_has '不在 Orca 里，请在各 worktree 手动运行：' 'offline dry run uses manual heading' "$WORK/offline-dry.out"
expect_has " #222（恢复，需手动）→ cd $WT222 后运行 /implement-spec-split 222 --auto-land --parallel 2" \
  'offline visible resume is manual' "$WORK/offline-dry.out"
expect_has " #224（恢复，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --auto-land --parallel 2" \
  'offline invisible resume remains manual' "$WORK/offline-dry.out"
expect_has ' #237 → /implement-spec-split 237 --auto-land --parallel 2' \
  'offline new spec is direct' "$WORK/offline-dry.out"
expect_without '（新 worktree）' 'offline dry run omits Orca label' "$WORK/offline-dry.out"
expect_without 'max-workers' 'offline dry run does not set worker limit' "$MAX_LOG"

: > "$MAX_LOG"
run_launch "$WORK/offline-apply.out" --apply
expect_exit 2 "offline apply exits two"
expect_has '不在 Orca 里，无法自动启动。' 'offline apply explains failure' "$WORK/offline-apply.out.err"
expect_without 'max-workers' 'offline apply does not set worker limit' "$MAX_LOG"
unset LAUNCH_ORCA_OFFLINE

# --- --apply: every Spec is handed to Orca orchestration ----------------------
# A resumed Spec is dispatched into its existing worktree, a new Spec into a
# child worktree of the main one; both go through the public library with the
# wave's Run and the 编排 route's agent slot, and are reported started only
# once their claim carries a pid.
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/apply.out" --apply --apart 237:239 --only 222,237,999
expect_exit 0 "filtered apply succeeds"
expect_has '#999 已不可启动，跳过' 'unavailable only spec is skipped' "$WORK/apply.out"
expect_has '#222 已启动' 'visible resume is launched' "$WORK/apply.out"
expect_has "#237 已启动：${CREATED_237}（Run run_wave，dispatch ctx_237）" \
  'new spec is launched and the line names worktree, Run and dispatch' "$WORK/apply.out"
expect_has '已启动 2 份，跳过 1 份，失败 0 份。' 'apply summary is complete' "$WORK/apply.out"
expect_has 'Orca Run：run_wave' 'apply prints the wave Run' "$WORK/apply.out"
expect_has 'orca orchestration run-use --id run_wave' 'apply tells how to take the Run over' "$WORK/apply.out"
expect_has '4' 'max-workers receives worker total' "$MAX_LOG"
expect_has "$MAIN_WORKTREE_PATH" 'claim commands run in the main worktree' "$CLAIM_LOG"
expect_sequence MAX_WORKERS ORCA_RUN_CREATE 'max-workers runs before the wave Run is created'
expect_sequence ORCA_RUN_CREATE ORCA_CREATE 'the wave Run exists before the first worktree is created'
expect_sequence ORCA_RUN_CREATE ORCA_DISPATCH 'the wave Run exists before the first dispatch'
expect_count 'ORCA_DISPATCH' 2 'both Specs are dispatched' "$SEQUENCE_LOG"
expect_arg_after '--parent-worktree' "path:$MAIN_WORKTREE_PATH" \
  'apply hangs the Spec worktree under the main worktree' "$ORCA_LOG"
expect_arg_after '--worktree' "path:$WT222" 'the resumed Spec is dispatched into its own worktree' "$ORCA_LOG"
expect_arg_after '--worktree' "path:$CREATED_237" 'the new Spec is dispatched into the worktree just created' "$ORCA_LOG"
expect_arg_after '--agent' openclaude 'every dispatch names the 编排 route'"'"'s agent slot' "$ORCA_LOG"
expect_arg_after '--run' run_wave 'every dispatch names the wave Run' "$ORCA_LOG"
expect_without '--no-parent' 'apply never detaches the Spec worktree from its parent' "$ORCA_LOG"
expect_without '--prompt' 'apply passes no prompt: the spec is a file' "$ORCA_LOG"
expect_line_without 'launch' 'apply no longer starts sessions with agent launch' "$ORCA_LOG"
expect_without '--model' 'the agent slot gets no model' "$ORCA_LOG"
expect_without 'ORCA_RM' 'nothing is removed when every launch succeeds' "$SEQUENCE_LOG"
if [ "$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)" = '/implement-spec-split 237 --auto-land --parallel 2' ]; then
  record PASS 'the spec file is exactly the generated command, /implement-spec-split first'
else
  record FAIL 'the spec file is exactly the generated command, /implement-spec-split first' \
    "got [$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)]"
fi
if [ "$(cat "$SPEC_COPY_DIR/spec-222.md" 2>/dev/null)" = '/implement-spec-split 222 --auto-land --parallel 2' ]; then
  record PASS 'the resumed Spec gets the same kind of spec'
else
  record FAIL 'the resumed Spec gets the same kind of spec' "got [$(cat "$SPEC_COPY_DIR/spec-222.md" 2>/dev/null)]"
fi

if [ ! -e "$LOCK_DIR" ]; then
  record PASS 'apply releases the launch-wave repository lock'
else
  record FAIL 'apply releases the launch-wave repository lock'
fi
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.workers !== 4 || value.specs !== 2 || !Array.isArray(value.apart) ||
      value.apart.length !== 1 || value.apart[0] !== "237:239" ||
      value.run !== "run_wave" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value.updated)) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'apply writes launch state with the wave Run'
else
  record FAIL 'apply writes launch state with the wave Run' "$(cat "$LAUNCH_STATE_FILE")"
fi

# Unattended landing is on by default (a), and the state knows no backend.
expect_has '--cmd-suffix' 'default apply passes a command suffix' "$PIPELINE_LOG"
expect_has '--auto-land' 'default apply suffix authorizes unattended landing' "$PIPELINE_LOG"
expect_without '--impl' 'default apply suffix names no backend' "$PIPELINE_LOG"
expect_without '"impl"' 'default apply state has no backend field' "$LAUNCH_STATE_FILE"
expect_without '"agent_model"' 'default apply state has no model field' "$LAUNCH_STATE_FILE"
cp "$LAUNCH_STATE_FILE" "$WORK/current-default-state.json"
OLD_LAUNCH_STATE_DIR=$WORK/old-launch-state
OLD_WORKER_STATE_DIR=$WORK/old-worker-state
mkdir -p "$OLD_LAUNCH_STATE_DIR" "$OLD_WORKER_STATE_DIR"
LAUNCH_SCRIPT_OVERRIDE=$OLD_SCRIPT
LAUNCH_STATE_DIR_OVERRIDE=$OLD_LAUNCH_STATE_DIR
LAUNCH_WORKER_STATE_DIR_OVERRIDE=$OLD_WORKER_STATE_DIR
export LAUNCH_SCRIPT_OVERRIDE LAUNCH_STATE_DIR_OVERRIDE LAUNCH_WORKER_STATE_DIR_OVERRIDE
run_launch "$WORK/old-default-apply.out" --apply --apart 237:239 \
  --only 222,237,999
unset LAUNCH_SCRIPT_OVERRIDE LAUNCH_STATE_DIR_OVERRIDE LAUNCH_WORKER_STATE_DIR_OVERRIDE
expect_exit 0 "pre-flash launch apply succeeds"
if node -e '
  const fs = require("fs");
  const read = (file) => {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    delete value.auto_land;
    delete value.run;
    return JSON.stringify(value);
  };
  process.exit(
    read(process.argv[1]) === read(process.argv[2]) ? 0 : 1
  );
' "$WORK/current-default-state.json" "$OLD_LAUNCH_STATE_DIR/test__repo.json"; then
  record PASS 'default apply state matches pre-flash apart from auto_land and the Run'
else
  record FAIL 'default apply state matches pre-flash apart from auto_land and the Run' \
    "$(diff -u "$OLD_LAUNCH_STATE_DIR/test__repo.json" "$WORK/current-default-state.json" | tail -n 8)"
fi
expect_without '"flash"' 'default apply state omits flash fields' "$LAUNCH_STATE_FILE"
expect_without '"launch_agent"' 'default apply state omits session agent field' "$LAUNCH_STATE_FILE"

# The whole Orca log of a single-Spec apply, verbatim: status and the worktree
# list once, the wave Run, the child worktree, then the one dispatch with the
# spec file and Orca's wait for the session to take it.
rm -f "$LAUNCH_STATE_FILE"
: > "$ORCA_LOG"
run_launch "$WORK/apply-237.out" --apply --only 237
expect_exit 0 "single-spec apply succeeds"
expect_orca_log "$(printf 'orca\nstatus\n--json\norca\nworktree\nlist\n--json\n%s\norca\norchestration\nworker-start\n--run\nrun_wave\n--worktree\npath:%s\n--agent\nopenclaude\n--spec-file\n<dispatch>/spec-237.md\n--json\n--timeout-ms\n900000' "$RUN_AND_CREATE_LOG" "$CREATED_237")" \
  'a single-Spec apply makes exactly these Orca calls with these arguments'

rm -f "$LAUNCH_STATE_FILE"
: > "$PIPELINE_LOG"; : > "$ORCA_LOG"
ISS_PIPELINE_STATUS_OVERRIDE=$BIN/fake-pipeline-dynamic
export ISS_PIPELINE_STATUS_OVERRIDE
run_launch "$WORK/default-dry.out"
expect_exit 0 "default dry run succeeds"
expect_has '--auto-land' \
  'default dry run authorizes unattended landing' "$PIPELINE_LOG"
expect_has " #222（恢复，原 worktree）→ /implement-spec-split 222 --auto-land --parallel 2" \
  'default dry run shows an authorized resume command' "$WORK/default-dry.out"
expect_has ' #237（新 worktree）→ /implement-spec-split 237 --auto-land --parallel 2' \
  'default dry run shows an authorized wave command' "$WORK/default-dry.out"

# The backend flags are gone: how a Spec is implemented is the route table's.
run_launch "$WORK/impl-rejected.out" --apply --impl agent --only 237
expect_exit 1 "--impl is refused"
expect_has '--impl was removed' '--impl refusal names the flag and the reason' \
  "$WORK/impl-rejected.out.err"
run_launch "$WORK/impl-codex-rejected.out" --impl codex
expect_exit 1 "--impl codex is refused too"
expect_has '--impl was removed' '--impl codex refusal names the flag' "$WORK/impl-codex-rejected.out.err"
run_launch "$WORK/agent-model-rejected.out" --apply --agent-model opus --only 237
expect_exit 1 "--agent-model is refused"
expect_has '--agent-model was removed' '--agent-model refusal names the flag and the reason' \
  "$WORK/agent-model-rejected.out.err"

# A state file from before 规格 #26 that names a backend is followed on
# everything else; its impl and agent_model are ignored, and --apply drops them.
rm -f "$LAUNCH_STATE_FILE"
cat > "$LAUNCH_STATE_FILE" <<'EOF'
{"workers":4,"specs":2,"apart":[],"impl":"agent","agent_model":"opus","auto_land":true,"updated":"2000-01-01T00:00:00Z"}
EOF
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/legacy-backend-next-wave.out" --next-wave --apply --only 237
expect_exit 0 "next wave from a state with impl and agent_model succeeds"
expect_has '#237 已启动' 'next wave from an old state launches the spec' "$WORK/legacy-backend-next-wave.out"
expect_has '--auto-land' 'old backend fields do not reach the command suffix' "$PIPELINE_LOG"
expect_without '--impl' 'old backend fields do not put a backend in the suffix' "$PIPELINE_LOG"
expect_without 'agent-model' 'old model field does not put a model in the suffix' "$PIPELINE_LOG"
expect_arg_after '--agent' openclaude 'old backend fields do not pick the agent: the 编排 route does' "$ORCA_LOG"
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if ("impl" in value || "agent_model" in value || value.auto_land !== true) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'apply rewrites the state without the old backend fields'
else
  record FAIL 'apply rewrites the state without the old backend fields' "$(cat "$LAUNCH_STATE_FILE")"
fi
unset LAUNCH_OMIT_WORKERS

# FLASH_ORCHESTRATOR records that a flash orchestrator launched the batch; the
# session it starts is the same openclaude worker the 编排 route names.
rm -f "$LAUNCH_STATE_FILE"
: > "$PIPELINE_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
FLASH_ORCHESTRATOR=1
export FLASH_ORCHESTRATOR
run_launch "$WORK/flash-apply.out" --apply --only 237
expect_exit 0 "flash apply succeeds"
expect_arg_after '--agent' openclaude 'flash apply uses OpenClaude' "$ORCA_LOG"
expect_has '#237 已启动' 'flash apply launches the spec' "$WORK/flash-apply.out"
expect_orca_log "$(printf 'orca\nstatus\n--json\norca\nworktree\nlist\n--json\n%s\norca\norchestration\nworker-start\n--run\nrun_wave\n--worktree\npath:%s\n--agent\nopenclaude\n--spec-file\n<dispatch>/spec-237.md\n--json\n--timeout-ms\n900000' "$RUN_AND_CREATE_LOG" "$CREATED_237")" \
  'flash apply makes exactly these Orca calls with these arguments'
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.flash !== true || value.launch_agent !== "openclaude" ||
      "impl" in value || "agent_model" in value ||
      value.auto_land !== true || value.run !== "run_wave") process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'flash apply records the session choice and the Run, no backend'
else
  record FAIL 'flash apply records the session choice and the Run, no backend' "$(cat "$LAUNCH_STATE_FILE")"
fi

: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/flash-resume.out" --apply --only 222
expect_exit 0 "flash resume succeeds"
expect_arg_after '--agent' openclaude 'flash resume uses OpenClaude' "$ORCA_LOG"
expect_has "#222 已启动：${WT222}（Run run_wave，dispatch ctx_222）" \
  'flash resume dispatches into the reserve stdout path' "$WORK/flash-resume.out"
expect_orca_log "$(printf 'orca\nstatus\n--json\norca\nworktree\nlist\n--json\n%s\norca\norchestration\nworker-start\n--run\nrun_wave\n--worktree\npath:%s\n--agent\nopenclaude\n--spec-file\n<dispatch>/spec-222.md\n--json\n--timeout-ms\n900000' "$RUN_CREATE_LOG" "$WT222")" \
  'flash resume makes exactly these Orca calls with these arguments'

# A resumed Spec whose worktree Orca does not list is dispatched into it the
# same way: no terminal tab in the main worktree, no claude-flash command line.
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
LAUNCH_PLAN_FILE_OVERRIDE=$FLASH_ONLY_INVISIBLE_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$FLASH_ONLY_INVISIBLE_PLAN_TEXT
ISS_PIPELINE_STATUS_OVERRIDE=$BIN/fake-pipeline
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
export ISS_PIPELINE_STATUS_OVERRIDE
run_launch "$WORK/flash-terminal.out" --apply --only 224
expect_exit 0 "flash invisible resume succeeds"
expect_has "#224 已启动：${WT224}（Run run_wave，dispatch ctx_224）" \
  'invisible resume is dispatched into its own worktree' "$WORK/flash-terminal.out"
expect_arg_after "--worktree" "path:$WT224" 'invisible resume names its worktree' "$ORCA_LOG"
expect_arg_after '--agent' openclaude 'invisible resume uses OpenClaude' "$ORCA_LOG"
expect_without 'terminal' 'invisible resume opens no terminal' "$ORCA_LOG"
expect_without 'claude-flash' 'invisible resume builds no launcher command' "$ORCA_LOG"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
ISS_PIPELINE_STATUS_OVERRIDE=$BIN/fake-pipeline-dynamic
export ISS_PIPELINE_STATUS_OVERRIDE

# A non-flash session continues a flash batch from the recorded launch state.
unset FLASH_ORCHESTRATOR
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/flash-next-wave.out" --next-wave --apply --only 237
expect_exit 0 "flash next wave succeeds"
expect_has '#237 已启动' 'flash next wave starts a free spec' "$WORK/flash-next-wave.out"
expect_arg_after '--agent' openclaude 'flash next wave uses OpenClaude' "$ORCA_LOG"
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.flash !== true || value.launch_agent !== "openclaude") process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'flash next wave preserves the session choice'
else
  record FAIL 'flash next wave preserves the session choice' "$(cat "$LAUNCH_STATE_FILE")"
fi
unset LAUNCH_OMIT_WORKERS

# The 编排 route is read where the real table can be made to fail: no table
# script at all, a script that cannot answer, and a profile with no Orca slot
# are usage errors, and nothing is reserved or dispatched.
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$MAX_LOG"
LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE=$WORK/no-such-stage-route
export LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE
run_launch "$WORK/route-missing.out" --apply --only 237
expect_exit 64 "a missing Stage route script exits 64"
expect_has 'could not read the 编排 route' 'a missing route script names the route' "$WORK/route-missing.out.err"
expect_without 'reserve' 'a missing route script claims nothing' "$CLAIM_LOG"
expect_without 'run-create' 'a missing route script creates no Run' "$ORCA_LOG"
expect_without 'max-workers' 'a missing route script changes no worker limit' "$MAX_LOG"

cat > "$FAKE_STAGE_ROUTE" <<'EOF'
#!/usr/bin/env bash
case "${LAUNCH_FAKE_ROUTE_MODE:-}" in
  fail) echo "fake stage-route: cannot read the table" >&2; exit 65 ;;
  *) printf '%s\n' "${LAUNCH_FAKE_ROUTE_PROFILE:-claude-flash}" ;;
esac
EOF
chmod +x "$FAKE_STAGE_ROUTE"
LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE=$FAKE_STAGE_ROUTE
LAUNCH_FAKE_ROUTE_MODE=fail
export LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE LAUNCH_FAKE_ROUTE_MODE
run_launch "$WORK/route-fail.out" --apply --only 237
expect_exit 64 "a route table that cannot be read exits 64"
expect_has 'could not read the 编排 route' 'an unreadable table names the route' "$WORK/route-fail.out.err"
expect_has 'fake stage-route: cannot read the table' 'an unreadable table passes the table'"'"'s own message' \
  "$WORK/route-fail.out.err"
expect_without 'reserve' 'an unreadable table claims nothing' "$CLAIM_LOG"
expect_without 'worker-start' 'an unreadable table dispatches nothing' "$ORCA_LOG"

unset LAUNCH_FAKE_ROUTE_MODE
LAUNCH_FAKE_ROUTE_PROFILE=codex-glm
export LAUNCH_FAKE_ROUTE_PROFILE
run_launch "$WORK/route-no-slot.out" --apply --only 237
expect_exit 64 "a route profile without an Orca agent slot exits 64"
expect_has 'codex-glm' 'a profile without a slot is named' "$WORK/route-no-slot.out.err"
expect_has 'no Orca agent slot' 'a profile without a slot says what is missing' "$WORK/route-no-slot.out.err"
expect_without 'reserve' 'a profile without a slot claims nothing' "$CLAIM_LOG"
expect_without 'worker-start' 'a profile without a slot dispatches nothing' "$ORCA_LOG"

# With the real table (empty, so every stage on its default) the slot is
# openclaude: the 编排 route is locked to claude-flash.
unset LAUNCH_FAKE_ROUTE_PROFILE LAUNCH_WAVE_STAGE_ROUTE_OVERRIDE
LAUNCH_ORCA_RUN_ID=run_route
export LAUNCH_ORCA_RUN_ID
: > "$ORCA_LOG"
run_launch "$WORK/route-real.out" --apply --only 237
expect_exit 0 "apply reads the real table's 编排 route"
expect_arg_after '--agent' openclaude "the real table's default 编排 route is openclaude" "$ORCA_LOG"
expect_has 'Orca Run：run_route' 'the Run id comes from run-create' "$WORK/route-real.out"
unset LAUNCH_ORCA_RUN_ID

# A --apply that finds nothing to launch (the keeper asking for a Spec that is
# not launchable) creates no empty Run and keeps the recorded one.
: > "$ORCA_LOG"; : > "$CLAIM_LOG"
run_launch "$WORK/only-nothing.out" --apply --only 999
expect_exit 0 "apply with nothing to launch succeeds"
expect_has '#999 已不可启动，跳过' 'the unavailable Spec is reported' "$WORK/only-nothing.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' 'nothing launched is summarised' "$WORK/only-nothing.out"
expect_without 'Orca Run：' 'no Run is announced for nothing' "$WORK/only-nothing.out"
expect_without 'run-create' 'no Run is created for nothing' "$ORCA_LOG"
expect_without 'reserve' 'nothing is reserved for nothing' "$CLAIM_LOG"
expect_has '"run": "run_route"' 'the recorded Run is kept' "$LAUNCH_STATE_FILE"

# Without the wave Run nothing is dispatched.
LAUNCH_ORCA_FAIL_RUN_CREATE=1
export LAUNCH_ORCA_FAIL_RUN_CREATE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/run-create-failure.out" --apply --only 237
expect_exit 1 "a failing run-create exits one"
expect_has 'could not create the Orca Run' 'a failing run-create names the problem' \
  "$WORK/run-create-failure.out.err"
expect_has 'orca run-create failed' 'a failing run-create surfaces Orca'"'"'s message' \
  "$WORK/run-create-failure.out.err"
expect_without 'reserve' 'a failing run-create claims nothing' "$CLAIM_LOG"
expect_without 'worker-start' 'a failing run-create dispatches nothing' "$ORCA_LOG"
unset LAUNCH_ORCA_FAIL_RUN_CREATE

# --auto-land is accepted as the default; --no-auto-land opts out (c).
rm -f "$LAUNCH_STATE_FILE"
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/auto-land-apply.out" --apply --auto-land --only 237
expect_exit 0 "auto-land apply succeeds"
expect_has '#237 已启动' 'auto-land apply starts the spec' \
  "$WORK/auto-land-apply.out"
expect_has '--auto-land' 'auto-land apply passes the suffix' \
  "$PIPELINE_LOG"
if [ "$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)" = '/implement-spec-split 237 --auto-land --parallel 2' ]; then
  record PASS 'auto-land apply launches an authorized command'
else
  record FAIL 'auto-land apply launches an authorized command' "got [$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)]"
fi
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.auto_land !== true) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'auto-land apply records authorization'
else
  record FAIL 'auto-land apply records authorization'
fi

: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/auto-land-next-wave.out" --next-wave --apply --only 237
expect_exit 0 "authorized next wave succeeds"
expect_has '#237 已启动' 'authorized next wave starts a free spec' \
  "$WORK/auto-land-next-wave.out"
expect_has '--auto-land' \
  'authorized next wave reuses the auto-land suffix' "$PIPELINE_LOG"
unset LAUNCH_OMIT_WORKERS

# The default --apply (no flag) also lands unattended.
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/auto-land-default-apply.out" --apply --only 237
expect_exit 0 "default apply succeeds"
expect_has '#237 已启动' 'default apply starts the spec' \
  "$WORK/auto-land-default-apply.out"
expect_has '--auto-land' 'default apply passes the auto-land suffix' \
  "$PIPELINE_LOG"
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.auto_land !== true) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'default apply records authorization'
else
  record FAIL 'default apply records authorization'
fi

# --no-auto-land opts this batch out, and the state records false.
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/no-auto-land-apply.out" --apply --no-auto-land --only 237
expect_exit 0 "no-auto-land apply succeeds"
expect_has '#237 已启动' 'no-auto-land apply starts the spec' \
  "$WORK/no-auto-land-apply.out"
expect_has '--cmd-suffix' 'no-auto-land apply still passes a suffix' "$PIPELINE_LOG"
expect_without '--auto-land' 'no-auto-land suffix omits auto-land' \
  "$PIPELINE_LOG"
if [ "$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)" = '/implement-spec-split 237 --parallel 2' ]; then
  record PASS 'no-auto-land apply launches a plain command'
else
  record FAIL 'no-auto-land apply launches a plain command' "got [$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)]"
fi
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.auto_land !== false) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'no-auto-land apply records false'
else
  record FAIL 'no-auto-land apply records false'
fi

: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/no-auto-land-next-wave.out" --next-wave --apply --only 237
expect_exit 0 "no-auto-land next wave succeeds"
expect_without '--auto-land' 'no-auto-land next wave omits auto-land' "$PIPELINE_LOG"
if [ "$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)" = '/implement-spec-split 237 --parallel 2' ]; then
  record PASS 'no-auto-land next wave keeps the plain command'
else
  record FAIL 'no-auto-land next wave keeps the plain command' "got [$(cat "$SPEC_COPY_DIR/spec-237.md" 2>/dev/null)]"
fi
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.auto_land !== false) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'no-auto-land next wave keeps false'
else
  record FAIL 'no-auto-land next wave keeps false'
fi
unset LAUNCH_OMIT_WORKERS
unset ISS_PIPELINE_STATUS_OVERRIDE

# Old state files without the auto_land field are treated as authorized (d).
rm -f "$LAUNCH_STATE_FILE"
cat > "$LAUNCH_STATE_FILE" <<'EOF'
{"workers":4,"specs":2,"apart":[],"updated":"2000-01-01T00:00:00Z"}
EOF
: > "$PIPELINE_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/legacy-next-wave.out" --next-wave --apply
expect_exit 0 "legacy next wave succeeds"
expect_has '--auto-land' \
  'legacy state defaults to unattended landing' "$PIPELINE_LOG"
expect_has '#237 已启动' 'legacy state launches a spec' "$WORK/legacy-next-wave.out"
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.auto_land !== true) process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'legacy next wave records authorization'
else
  record FAIL 'legacy next wave records authorization'
fi
unset LAUNCH_OMIT_WORKERS

# Invalid flags are rejected (e).
run_launch "$WORK/next-wave-auto-land-conflict.out" --next-wave --auto-land
expect_exit 1 "next-wave auto-land flag is rejected"
expect_has '--auto-land and --no-auto-land are not valid with --next-wave' \
  'next-wave auto-land conflict explains the authorization path' \
  "$WORK/next-wave-auto-land-conflict.out.err"

run_launch "$WORK/next-wave-no-auto-land-conflict.out" --next-wave --no-auto-land
expect_exit 1 "next-wave no-auto-land flag is rejected"
expect_has '--auto-land and --no-auto-land are not valid with --next-wave' \
  'next-wave no-auto-land conflict explains the authorization path' \
  "$WORK/next-wave-no-auto-land-conflict.out.err"

ISS_CLAIM_WAIT_OVERRIDE=soon
export ISS_CLAIM_WAIT_OVERRIDE
run_launch "$WORK/claim-wait-word.out" --apply --only 237
expect_exit 1 "a word for ISS_CLAIM_WAIT is rejected"
expect_has 'ISS_CLAIM_WAIT must be a non-negative integer' 'a bad wait names the variable' \
  "$WORK/claim-wait-word.out.err"
unset ISS_CLAIM_WAIT_OVERRIDE

rm -f "$LAUNCH_STATE_FILE"
cat > "$LAUNCH_STATE_FILE" <<'EOF'
{"workers":7,"specs":3,"apart":["237:239"],"updated":"2000-01-01T00:00:00Z"}
EOF
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/next-wave-state.out" --next-wave --apply
expect_exit 0 "next wave reads launch state successfully"
expect_has ' #222（中断，先恢复；--next-wave 不自动恢复）' \
  'next wave hints an interrupted spec' "$WORK/next-wave-state.out"
expect_has '#237 已启动' 'next wave starts a free first-wave spec' "$WORK/next-wave-state.out"
expect_has '已启动 1 份，跳过 0 份，失败 0 份。' \
  'next wave ignores interrupted specs in its summary' "$WORK/next-wave-state.out"
expect_without '--resume' 'next wave does not reserve interrupted specs' "$CLAIM_LOG"
expect_has '7' 'next wave uses workers from launch state' "$PIPELINE_LOG"
expect_has '3' 'next wave uses spec count from launch state' "$PIPELINE_LOG"
expect_has '237:239' 'next wave uses apart pairs from launch state' "$PIPELINE_LOG"
expect_has '7' 'next wave writes workers from launch state to max-workers' "$MAX_LOG"
if node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.workers !== 7 || value.specs !== 3 || value.apart[0] !== "237:239" ||
      value.updated === "2000-01-01T00:00:00Z") process.exit(1);
' "$LAUNCH_STATE_FILE"; then
  record PASS 'next wave refreshes launch state timestamp'
else
  record FAIL 'next wave refreshes launch state timestamp'
fi
unset LAUNCH_OMIT_WORKERS

rm -f "$LAUNCH_STATE_FILE" "$WORKER_STATE_DIR/max-workers"
printf '%s\n' 6 > "$WORKER_STATE_DIR/max-workers"
: > "$PIPELINE_LOG"; : > "$MAX_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/next-wave-max-workers.out" --next-wave --apply --only 237
expect_exit 0 "next wave falls back to the max-workers file"
expect_has '6' 'max-workers fallback is passed to pipeline' "$PIPELINE_LOG"
expect_has '6' 'max-workers fallback is persisted globally' "$MAX_LOG"
expect_has '"workers": 6' 'max-workers fallback is written to launch state' "$LAUNCH_STATE_FILE"
expect_has '--auto-land' \
  'missing state file defaults to unattended landing' "$PIPELINE_LOG"
unset LAUNCH_OMIT_WORKERS
rm -f "$WORKER_STATE_DIR/max-workers"

EMPTY_LAUNCH_STATE=$WORK/empty-launch-state
EMPTY_WORKER_STATE=$WORK/empty-worker-state
mkdir -p "$EMPTY_LAUNCH_STATE" "$EMPTY_WORKER_STATE"
LAUNCH_STATE_DIR_OVERRIDE=$EMPTY_LAUNCH_STATE
LAUNCH_WORKER_STATE_DIR_OVERRIDE=$EMPTY_WORKER_STATE
export LAUNCH_STATE_DIR_OVERRIDE LAUNCH_WORKER_STATE_DIR_OVERRIDE
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/next-wave-no-workers.out" --next-wave --apply
expect_exit 1 "next wave without worker configuration fails"
expect_has 'no launch state or max-workers file' \
  'missing worker configuration asks for --workers' "$WORK/next-wave-no-workers.out.err"
unset LAUNCH_STATE_DIR_OVERRIDE LAUNCH_WORKER_STATE_DIR_OVERRIDE LAUNCH_OMIT_WORKERS

LAUNCH_PLAN_FILE_OVERRIDE=$RESUME_ONLY_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$RESUME_ONLY_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
cat > "$LAUNCH_STATE_FILE" <<'EOF'
{"workers":7,"specs":1,"apart":[],"updated":"2000-01-01T00:00:00Z"}
EOF
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"; : > "$ORCA_LOG"
LAUNCH_OMIT_WORKERS=1
export LAUNCH_OMIT_WORKERS
run_launch "$WORK/next-wave-empty.out" --next-wave --apply
expect_exit 0 "next wave with nothing free exits zero"
expect_has '无可启动' 'next wave with nothing free says so' "$WORK/next-wave-empty.out"
expect_has ' #222（中断，先恢复；--next-wave 不自动恢复）' \
  'next wave with nothing free only hints interrupted work' "$WORK/next-wave-empty.out"
expect_without 'reserve' 'next wave with nothing free claims nothing' "$CLAIM_LOG"
expect_without 'orca' 'next wave with nothing free launches nothing' "$ORCA_LOG"
expect_without 'max-workers' 'next wave with nothing free does not set worker limit' "$MAX_LOG"
unset LAUNCH_OMIT_WORKERS

LAUNCH_PLAN_FILE_OVERRIDE=$CYCLE_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$CYCLE_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/next-wave-cycle.out" --next-wave --apply
expect_exit 2 "next wave refuses a dependency cycle"
expect_has '循环依赖：#222、#237，不自动启动。请运行 /find-next。' \
  'next wave cycle report names specs and next action' "$WORK/next-wave-cycle.out"
expect_without 'reserve' 'next wave cycle claims nothing' "$CLAIM_LOG"
expect_without 'orca' 'next wave cycle launches nothing' "$ORCA_LOG"
expect_without 'max-workers' 'next wave cycle does not set worker limit' "$MAX_LOG"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

LOCK_READY=$WORK/occupied-lock.ready
(
  cd "$REPO" || exit 125
  bash "$ROOT/scripts/lock.sh" acquire launch-wave --scope repo --wait 0 --owner-pid "$$" &&
    : > "$LOCK_READY"
  while [ -e "$LOCK_DIR" ]; do sleep 1; done
) &
LOCK_HOLDER=$!
LOCK_WAIT_ROUNDS=0
while [ ! -e "$LOCK_READY" ] && [ "$LOCK_WAIT_ROUNDS" -lt 50 ]; do
  sleep 0.1
  LOCK_WAIT_ROUNDS=$((LOCK_WAIT_ROUNDS + 1))
done
[ -e "$LOCK_READY" ] || {
  printf '%s\n' 'could not occupy launch-wave lock' >&2
  exit 125
}
: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/occupied-launch.out" --apply --only 237
expect_exit 1 "occupied launch-wave lock fails"
expect_has 'could not acquire the launch-wave repository lock' \
  'occupied lock failure names launch-wave lock' "$WORK/occupied-launch.out.err"
expect_without '--json' 'occupied lock never calculates an order' "$PIPELINE_LOG"
expect_without 'reserve' 'occupied lock claims nothing' "$CLAIM_LOG"
expect_without 'orca' 'occupied lock reaches no Orca' "$ORCA_LOG"
(
  cd "$REPO" && bash "$ROOT/scripts/lock.sh" release launch-wave --scope repo --force
) >/dev/null 2>&1 || record FAIL 'test releases occupied launch-wave lock'
kill "$LOCK_HOLDER" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER" 2>/dev/null || true
if [ ! -e "$LOCK_DIR" ]; then
  record PASS 'occupied lock test leaves no lock behind'
else
  record FAIL 'occupied lock test leaves no lock behind'
fi

: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/only-invisible.out" --apply --only 224
expect_exit 0 "apply with only an invisible resume succeeds"
expect_without '#224 已不可启动，跳过' \
  'invisible only resume is available with main worktree' "$WORK/only-invisible.out"
expect_has "#224 已启动：${WT224}（Run run_wave，dispatch ctx_224）" \
  'invisible resume is dispatched into its worktree' "$WORK/only-invisible.out"
expect_has '已启动 1 份，跳过 0 份，失败 0 份。' \
  'invisible only resume summary counts launch' "$WORK/only-invisible.out"
expect_has 'reserve' 'invisible resume is reserved' "$CLAIM_LOG"
expect_has '--resume' 'invisible resume reservation is resumed' "$CLAIM_LOG"
expect_arg_after "--worktree" "path:$WT224" 'the worktree path with spaces is one argument' "$ORCA_LOG"
expect_sequence CLAIM_RESUME ORCA_DISPATCH 'invisible resume claim runs before the dispatch'

# A dispatch Orca refuses is a failed launch: the reservation goes and the
# worktree this run created goes with its branch, so --only can be run again.
LAUNCH_ORCA_FAIL_START=1
export LAUNCH_ORCA_FAIL_START
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/dispatch-failure.out" --apply --only 237
expect_exit 1 "Orca dispatch failure exits one"
expect_has '#237 启动失败：orca worker-start failed' \
  'dispatch failure surfaces first error line' "$WORK/dispatch-failure.out"
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' \
  'dispatch failure summary counts failure' "$WORK/dispatch-failure.out"
expect_has 'release' 'dispatch failure releases claim' "$CLAIM_LOG"
expect_has '--force' 'dispatch failure forces claim release' "$CLAIM_LOG"
expect_arg_after '--worktree' "path:$CREATED_237" 'dispatch failure removes the worktree it created' \
  "$ORCA_LOG"
expect_count 'ORCA_RM' 1 'dispatch failure removes the worktree it created' "$SEQUENCE_LOG"
expect_sequence ORCA_DISPATCH CLAIM_RELEASE 'dispatch failure releases the claim after the refusal'
unset LAUNCH_ORCA_FAIL_START

# The same for a resumed Spec, except that its worktree holds earlier work
# and stays.
LAUNCH_ORCA_FAIL_START=1
export LAUNCH_ORCA_FAIL_START
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/resume-dispatch-failure.out" --apply --only 222
expect_exit 1 "Orca dispatch failure on a resume exits one"
expect_has '#222 启动失败：orca worker-start failed' \
  'resume dispatch failure surfaces first error line' "$WORK/resume-dispatch-failure.out"
expect_has 'release' 'resume dispatch failure releases claim' "$CLAIM_LOG"
expect_without 'ORCA_RM' 'resume dispatch failure keeps the worktree' "$SEQUENCE_LOG"
unset LAUNCH_ORCA_FAIL_START

LAUNCH_ORCA_LIST_FILE_OVERRIDE=$ORCA_LIST_NO_MAIN
export LAUNCH_ORCA_LIST_FILE_OVERRIDE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_PLAN_FILE_OVERRIDE=$ONLY_INVISIBLE_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$ONLY_INVISIBLE_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/invisible-without-main-dry.out"
expect_exit 0 "invisible resume without main worktree dry run succeeds"
expect_has " #224（恢复，worktree 不在 Orca 列表里，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --auto-land --parallel 2" \
  'invisible resume without main worktree dry run stays manual' "$WORK/invisible-without-main-dry.out"
expect_without 'reserve' 'dry run without main worktree makes no claim' "$CLAIM_LOG"
expect_without 'worker-start' 'dry run without main worktree dispatches nothing' "$ORCA_LOG"

: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/invisible-without-main.out" --apply
expect_exit 0 "invisible resume without main worktree remains manual"
expect_has " #224（恢复，worktree 不在 Orca 列表里，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --auto-land --parallel 2" \
  'invisible resume without main worktree stays manual' "$WORK/invisible-without-main.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'manual invisible resume summary counts skip' "$WORK/invisible-without-main.out"
expect_without 'reserve' 'manual invisible resume is not claimed' "$CLAIM_LOG"
expect_without 'worker-start' 'manual invisible resume is not dispatched' "$ORCA_LOG"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/only-invisible.out" --apply --only 224
expect_exit 0 "invisible resume without main worktree succeeds as a skip"
expect_count '#224 已不可启动，跳过' 1 \
  'invisible resume without main worktree is reported once' "$WORK/only-invisible.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'invisible resume without main worktree is skipped once' "$WORK/only-invisible.out"
expect_without 'reserve' 'invisible resume without main worktree is not claimed' "$CLAIM_LOG"
expect_without 'worker-start' 'invisible resume without main worktree is not dispatched' "$ORCA_LOG"
unset LAUNCH_ORCA_LIST_FILE_OVERRIDE

LAUNCH_CLAIM_FAIL_FRESH=237
export LAUNCH_CLAIM_FAIL_FRESH
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/reserve-conflict.out" --apply --only 237
expect_exit 0 "reserve conflict skips without failure"
expect_has '#237 已被其他会话领取：active spec-237 held elsewhere' \
  'reserve conflict prints claim status' "$WORK/reserve-conflict.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'reserve conflict summary counts skip' "$WORK/reserve-conflict.out"
expect_without 'worker-start' 'reserve conflict does not dispatch' "$ORCA_LOG"
unset LAUNCH_CLAIM_FAIL_FRESH

LAUNCH_ORCA_FAIL_CREATE=1
LAUNCH_ORCA_CREATE_BRANCH=1
export LAUNCH_ORCA_FAIL_CREATE LAUNCH_ORCA_CREATE_BRANCH
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/create-failure.out" --apply --only 237
expect_exit 1 "Orca create failure exits one"
expect_has '#237 启动失败：orca create failed' 'create failure surfaces first error line' "$WORK/create-failure.out"
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' 'create failure summary counts failure' "$WORK/create-failure.out"
expect_has 'release' 'create failure releases claim' "$CLAIM_LOG"
expect_without 'worker-start' 'create failure dispatches nothing' "$ORCA_LOG"
if git -C "$REPO" show-ref --verify --quiet refs/heads/spec-237; then
  record FAIL 'unused empty branch is deleted'
else
  record PASS 'unused empty branch is deleted'
fi
unset LAUNCH_ORCA_FAIL_CREATE LAUNCH_ORCA_CREATE_BRANCH

LAUNCH_CLAIM_FAIL_RESUME=222
export LAUNCH_CLAIM_FAIL_RESUME
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/resume-conflict.out" --apply --only 222
expect_exit 0 "resume conflict skips without failure"
expect_has '#222 恢复领取失败：interrupted spec-222 changed state' \
  'resume conflict explains claim status' "$WORK/resume-conflict.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'resume conflict summary counts skip' "$WORK/resume-conflict.out"
expect_without 'worker-start' 'resume conflict does not dispatch' "$ORCA_LOG"
unset LAUNCH_CLAIM_FAIL_RESUME

: > "$ORCA_LOG"
LAUNCH_REPO_OVERRIDE=other/repo run_launch "$WORK/mismatch.out" --apply
expect_exit 1 "repo that is not this checkout's origin is refused"
expect_has 'does not match' 'mismatch names the problem' "$WORK/mismatch.out.err"
expect_without 'orca' 'mismatch never calls Orca' "$ORCA_LOG"
unset LAUNCH_REPO_OVERRIDE

# --- waiting for the claim ------------------------------------------------------
# The reservation launch-wave writes is not a claim: a Spec is 已启动 only once
# its claim record carries a pid. With none, the wait runs out and the terminal
# decides. Here the terminal says nothing (running, empty screen and preview),
# which cannot be read as "not started": the Spec parks, nothing is stopped or
# redispatched, the reservation is left to expire, and the line says how to
# restart.
LAUNCH_CLAIM_UNCLAIMED=237
export LAUNCH_CLAIM_UNCLAIMED
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/unclaimed-parks.out" --apply --only 237
expect_exit 1 "an unclaimed Spec whose terminal says nothing parks"
expect_without '#237 已启动' 'a Spec with only a reservation is not reported started' "$WORK/unclaimed-parks.out"
expect_has '#237 停车：判断不了（终端 screen/running：无内容）；Run run_wave，dispatch ctx_237。' \
  'the park line carries the verdict, the Run and the dispatch' "$WORK/unclaimed-parks.out"
expect_has "重新启动：确认该终端已停后 cd $CREATED_237 运行 claude-flash '/implement-spec-split 237 --auto-land --parallel 2'，或等预留到期后运行 launch-wave.sh --repo test/repo --only 237 --apply" \
  'the park tells how to restart, with the command' "$WORK/unclaimed-parks.out"
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' 'a parked Spec counts as failed' "$WORK/unclaimed-parks.out"
expect_sequence ORCA_DISPATCH ORCA_READ 'the terminal is read only after the dispatch, when the wait runs out'
expect_sequence ORCA_READ ORCA_SHOW 'an empty screen is followed by the preview'
expect_without 'worker-stop' '判断不了 does not stop the session' "$ORCA_LOG"
expect_without '--retry-of' '判断不了 does not redispatch' "$ORCA_LOG"
expect_without 'release' '判断不了 leaves the reservation to expire' "$CLAIM_LOG"
expect_has 'status' 'the claim is read while waiting' "$CLAIM_LOG"

# The claim appearing during the wait (pid non-empty) is what reports 已启动.
ISS_CLAIM_WAIT_OVERRIDE=1
export ISS_CLAIM_WAIT_OVERRIDE
LAUNCH_CLAIM_UNCLAIMED='237'
LAUNCH_ORCA_READ_MARKS_CLAIM=1
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_WORKING
export LAUNCH_CLAIM_UNCLAIMED LAUNCH_ORCA_READ_MARKS_CLAIM LAUNCH_ORCA_SCREEN_FILE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/claim-later.out" --apply --only 237
expect_exit 0 "a Spec that claims during the extended wait starts"
expect_has '#237 尚未认领但终端在动' 'a working terminal extends the wait' "$WORK/claim-later.out"
expect_has "#237 已启动：${CREATED_237}（Run run_wave，dispatch ctx_237）" \
  'the Spec is started once its pid is there' "$WORK/claim-later.out"
expect_has '已启动 1 份，跳过 0 份，失败 0 份。' 'a late claim counts as started' "$WORK/claim-later.out"
expect_without 'worker-stop' 'a working session is not stopped' "$ORCA_LOG"
expect_without '--retry-of' 'a working session is not redispatched' "$ORCA_LOG"
unset ISS_CLAIM_WAIT_OVERRIDE LAUNCH_ORCA_READ_MARKS_CLAIM LAUNCH_ORCA_SCREEN_FILE

# --- the wait runs out: not started -> stop, retry once -------------------------
# The process exited (the read is empty and only the preview is left): the
# dispatch is stopped and retried with --task and --retry-of into the same
# worktree; when the retry claims, the Spec is started.
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_EXITED
LAUNCH_ORCA_SHOW_FILE=$SHOW_EXITED
LAUNCH_ORCA_READ_MARKS_CLAIM=1
export LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_SHOW_FILE LAUNCH_ORCA_READ_MARKS_CLAIM
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/not-started-retry.out" --apply --only 237
expect_exit 0 "a session that exited is stopped and retried"
expect_has '#237 没开始（preview/exited：Claude Code v2.1.309 / Invalid API key · please run /login / allan716@mini6 spec-237 %），已停掉并重派一次（dispatch ctx_237_r）。' \
  'the retry line carries what the terminal showed and the new dispatch' "$WORK/not-started-retry.out"
expect_has "#237 已启动：${CREATED_237}（Run run_wave，dispatch ctx_237_r）" \
  'the retry claiming starts the Spec under the new dispatch' "$WORK/not-started-retry.out"
expect_has '已启动 1 份，跳过 0 份，失败 0 份。' 'a successful retry counts as started' "$WORK/not-started-retry.out"
expect_sequence ORCA_DISPATCH ORCA_STOP 'the first dispatch is stopped before the retry'
expect_sequence ORCA_STOP ORCA_RETRY 'the retry follows the stop'
expect_arg_after '--dispatch' ctx_237 'the stop names the first dispatch' "$ORCA_LOG"
expect_orca_log "$(printf 'orca\nstatus\n--json\norca\nworktree\nlist\n--json\n%s\norca\norchestration\nworker-start\n--run\nrun_wave\n--worktree\npath:%s\n--agent\nopenclaude\n--spec-file\n<dispatch>/spec-237.md\n--json\n--timeout-ms\n900000\norca\nterminal\nread\n--terminal\nterm_237\n--screen\n--json\norca\nterminal\nshow\n--terminal\nterm_237\n--json\norca\norchestration\nworker-stop\n--dispatch\nctx_237\n--json\norca\norchestration\nworker-start\n--run\nrun_wave\n--worktree\npath:%s\n--agent\nopenclaude\n--task\ntask_237\n--retry-of\nctx_237\n--json\n--timeout-ms\n900000' "$RUN_AND_CREATE_LOG" "$CREATED_237" "$CREATED_237")" \
  'a retry makes exactly these Orca calls'
expect_without 'release' 'a retry keeps the reservation' "$CLAIM_LOG"
unset LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_SHOW_FILE LAUNCH_ORCA_READ_MARKS_CLAIM

# A TUI that is up without the spec typed into it is "not started" too: stop,
# then retry.
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_IDLE
LAUNCH_ORCA_READ_MARKS_CLAIM=1
export LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_READ_MARKS_CLAIM
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/idle-retry.out" --apply --only 237
expect_exit 0 "an idle TUI without the spec is stopped and retried"
expect_has '#237 没开始（screen/running' 'the retry line says the screen was read' "$WORK/idle-retry.out"
expect_has '#237 已启动' 'the retry claims and starts' "$WORK/idle-retry.out"
expect_sequence ORCA_STOP ORCA_RETRY 'the idle session is stopped before the retry'
unset LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_READ_MARKS_CLAIM

# Stopping is only done when Orca can prove the agent stopped: a stop that
# cannot (stop_unknown) parks instead of retrying.
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_IDLE
LAUNCH_ORCA_STOP_FAIL=1
export LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_STOP_FAIL
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/stop-unknown.out" --apply --only 237
expect_exit 1 "a stop Orca cannot confirm parks"
expect_has '#237 停车：要重派但无法确认原会话已停（worker-stop：cannot prove the agent stopped；终端 screen/running' \
  'the park line carries the stop failure' "$WORK/stop-unknown.out"
expect_without '--retry-of' 'no retry without a confirmed stop' "$ORCA_LOG"
expect_without 'release' 'the reservation is left alone' "$CLAIM_LOG"
unset LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_STOP_FAIL

# The retry failing to dispatch at all parks too: the first session was
# stopped, so the reservation is released and --only can be run again at once.
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_IDLE
LAUNCH_ORCA_FAIL_RETRY=1
export LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_FAIL_RETRY
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/retry-fails.out" --apply --only 237
expect_exit 1 "a retry Orca refuses parks"
expect_has '#237 停车：确认没开始（终端 screen/running' 'the park line says what was seen' "$WORK/retry-fails.out"
expect_has '停掉后重派失败：orca retry failed' 'the park line carries the retry failure' "$WORK/retry-fails.out"
expect_has '重新启动：launch-wave.sh --repo test/repo --only 237 --apply' \
  'a parked retry failure says to run --only again' "$WORK/retry-fails.out"
expect_has 'release' 'a parked retry failure releases the reservation' "$CLAIM_LOG"
expect_sequence ORCA_STOP ORCA_RETRY 'the retry came after the stop'
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' 'the retry failure counts as failed' "$WORK/retry-fails.out"
unset LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_FAIL_RETRY

# --- the retry does not claim either -> parked -----------------------------------
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_EXITED
LAUNCH_ORCA_SHOW_FILE=$SHOW_EXITED
export LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_SHOW_FILE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/retry-unclaimed.out" --apply --only 237
expect_exit 1 "a retry that does not claim parks"
expect_has '#237 停车：重派后仍未认领（终端 preview/exited：Claude Code v2.1.309 / Invalid API key · please run /login / allan716@mini6 spec-237 %）；Run run_wave，dispatch ctx_237_r。' \
  'the park line names the retry dispatch and what it showed' "$WORK/retry-unclaimed.out"
expect_has '重新启动：launch-wave.sh --repo test/repo --only 237 --apply' \
  'a parked exited retry says to run --only again' "$WORK/retry-unclaimed.out"
expect_has 'release' 'a parked exited retry releases the reservation' "$CLAIM_LOG"
expect_count 'ORCA_RETRY' 1 'the retry happens once only' "$SEQUENCE_LOG"
expect_count 'ORCA_STOP' 1 'only the first dispatch is stopped' "$SEQUENCE_LOG"
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' 'the parked retry counts as failed' "$WORK/retry-unclaimed.out"
unset LAUNCH_ORCA_SCREEN_FILE LAUNCH_ORCA_SHOW_FILE

# --- the wait runs out: working -> extend, never redispatch ---------------------
# A working terminal whose reservation has already expired is at the cap: the
# Spec is reported, not redispatched, and the run does not fail on it.
LAUNCH_CLAIM_HANDOFF_LEFT=0
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_WORKING
export LAUNCH_CLAIM_HANDOFF_LEFT LAUNCH_ORCA_SCREEN_FILE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/moving-at-cap.out" --apply --only 237
expect_exit 0 "a working terminal at the reservation's cap is reported, not failed"
expect_has '#237 仍未认领（终端在动，已等到预留到期）：screen/running：⏺ Skill(implement-spec-split) / ⎿  Successfully loaded skill / ✳ Reading SKILL.md…；Run run_wave，dispatch ctx_237。不重派。' \
  'the report carries what the terminal showed and says 不重派' "$WORK/moving-at-cap.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' 'a Spec still starting at the cap counts as skipped' "$WORK/moving-at-cap.out"
expect_without '#237 已启动' 'a working but unclaimed Spec is not 已启动' "$WORK/moving-at-cap.out"
expect_without 'worker-stop' 'a working session is not stopped' "$ORCA_LOG"
expect_without '--retry-of' 'a working session is not redispatched' "$ORCA_LOG"
expect_without 'release' 'a working session keeps its reservation' "$CLAIM_LOG"
unset LAUNCH_CLAIM_HANDOFF_LEFT LAUNCH_ORCA_SCREEN_FILE

# A submitted prompt without any answer yet is neither working nor provably
# not started: it parks.
LAUNCH_ORCA_SCREEN_FILE=$SCREEN_SUBMITTED
export LAUNCH_ORCA_SCREEN_FILE
: > "$ORCA_LOG"
run_launch "$WORK/submitted-parks.out" --apply --only 237
expect_exit 1 "a submitted prompt without output parks"
expect_has '#237 停车：判断不了（终端 screen/running' 'the park line says it could not tell' "$WORK/submitted-parks.out"
expect_without 'worker-stop' 'an unanswered prompt is not stopped' "$ORCA_LOG"
unset LAUNCH_ORCA_SCREEN_FILE

# A terminal Orca cannot read is not read as "not started" either.
LAUNCH_ORCA_READ_FAIL=1
export LAUNCH_ORCA_READ_FAIL
: > "$ORCA_LOG"
run_launch "$WORK/read-fails.out" --apply --only 237
expect_exit 1 "a terminal Orca cannot read parks"
expect_has '#237 停车：判断不了（终端 screen/running：无内容）' 'the park line says what it could read' "$WORK/read-fails.out"
expect_without 'worker-stop' 'an unreadable terminal is not stopped' "$ORCA_LOG"
unset LAUNCH_ORCA_READ_FAIL
unset LAUNCH_CLAIM_UNCLAIMED

# --- one Spec's wait does not hold up another -----------------------------------
# #222 never claims; #237 is dispatched all the same, claims, and is started,
# while #222 parks. Both dispatches come before the first terminal read.
LAUNCH_CLAIM_UNCLAIMED=222
export LAUNCH_CLAIM_UNCLAIMED
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/nonblocking.out" --apply --only 222,237
expect_exit 1 "one parked Spec does not stop the other from starting"
expect_has "#237 已启动：${CREATED_237}（Run run_wave，dispatch ctx_237）" \
  'the claiming Spec is started while the other waits' "$WORK/nonblocking.out"
expect_has '#222 停车：判断不了' 'the unclaimed Spec parks in the same run' "$WORK/nonblocking.out"
expect_has '已启动 1 份，跳过 0 份，失败 1 份。' 'each Spec is counted on its own' "$WORK/nonblocking.out"
expect_count 'ORCA_DISPATCH' 2 'both Specs are dispatched' "$SEQUENCE_LOG"
first_read_line=$(grep -Fn 'ORCA_READ' "$SEQUENCE_LOG" | head -1 | cut -d: -f1)
second_dispatch_line=$(grep -Fn 'ORCA_DISPATCH' "$SEQUENCE_LOG" | sed -n '2p' | cut -d: -f1)
if [ -n "$first_read_line" ] && [ -n "$second_dispatch_line" ] && [ "$second_dispatch_line" -lt "$first_read_line" ]; then
  record PASS 'every dispatch happens before any claim wait runs out'
else
  record FAIL 'every dispatch happens before any claim wait runs out' "dispatch=${second_dispatch_line:-none}, read=${first_read_line:-none}"
fi
unset LAUNCH_CLAIM_UNCLAIMED

# Every run above put the refusing `orca` on PATH; none may have reached it.
if [ -s "$ORCA_GUARD_LOG" ]; then
  record FAIL 'no run calls the orca on PATH instead of ISS_ORCA' "$(cat "$ORCA_GUARD_LOG")"
else
  record PASS 'no run calls the orca on PATH instead of ISS_ORCA'
fi

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
