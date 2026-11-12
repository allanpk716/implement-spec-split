#!/usr/bin/env bash
# Isolated fake-dependency tests for find-next/scripts/launch-wave.sh.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/find-next/scripts/launch-wave.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/launch-wave-test.XXXXXX")
BIN=$WORK/bin
REPO=$WORK/git-repo
ORIGIN=$WORK/test/repo.git  # path ends in the --repo slug the script checks
WT222=$WORK/spec-222
WT224=$WORK/'spec-224 with spaces'
MAIN_WORKTREE_PATH=$REPO
PLAN=$WORK/plan.json
PLAN_TEXT=$WORK/plan.txt
EMPTY_PLAN=$WORK/empty-plan.json
EMPTY_PLAN_TEXT=$WORK/empty-plan.txt
ONLY_INVISIBLE_PLAN=$WORK/only-invisible-plan.json
ONLY_INVISIBLE_PLAN_TEXT=$WORK/only-invisible-plan.txt
ORCA_LIST=$WORK/orca-list.json
ORCA_LIST_NO_MAIN=$WORK/orca-list-no-main.json
ORCA_LOG=$WORK/orca.log
CLAIM_LOG=$WORK/claim.log
MAX_LOG=$WORK/max-workers.log
PIPELINE_LOG=$WORK/pipeline.log
SEQUENCE_LOG=$WORK/sequence.log
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

mkdir -p "$BIN" "$REPO" || exit 1
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

node - "$WT222" "$WT224" > "$PLAN" <<'NODE'
const [visible, invisible] = process.argv.slice(2);
const command = (n) => `/implement-spec-split ${n} --impl codex --parallel 2`;
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
 1. #237 New spec → /implement-spec-split 237 --impl codex --parallel 2
之后：
 2. #239 Later spec（等 #237）
EOF

printf '%s\n' '{"parallel_specs":2,"workers":4,"per_spec_parallel":2,"resume":[],"active":[],"wave1":[],"later":[],"cycles":[],"standalone":[]}' \
  > "$EMPTY_PLAN"
printf '%s\n' '开发顺序：没有可以实现的规格' > "$EMPTY_PLAN_TEXT"

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
    command: '/implement-spec-split 224 --impl codex --parallel 2',
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

cat > "$BIN/fake-max-workers" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'max-workers' >> "$LAUNCH_MAX_LOG"
printf '%s\n' "$1" >> "$LAUNCH_MAX_LOG"
printf '%s\n' 'MAX_WORKERS' >> "$LAUNCH_SEQUENCE_LOG"
EOF
chmod +x "$BIN/fake-max-workers"

cat > "$BIN/fake-claim" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' 'claim' >> "$LAUNCH_CLAIM_LOG"
printf '%s\n' "$PWD" >> "$LAUNCH_CLAIM_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$LAUNCH_CLAIM_LOG"; done
if [ "$1" = reserve ]; then
  spec=$2
  resume=0
  [ "${3:-}" = --resume ] && resume=1
  if [ "$resume" -eq 1 ]; then
    if [ "$spec" = "${LAUNCH_CLAIM_FAIL_RESUME:-}" ]; then
      printf '%s\n' "interrupted spec-$spec changed state"
      exit 3
    fi
    printf '%s\n' 'CLAIM_RESUME' >> "$LAUNCH_SEQUENCE_LOG"
    printf '%s\n' "${LAUNCH_RESUME_PATH:-$LAUNCH_RESUME_DEFAULT}"
    exit 0
  fi
  if [ "$spec" = "${LAUNCH_CLAIM_FAIL_FRESH:-}" ]; then
    printf '%s\n' "active spec-$spec held elsewhere"
    exit 3
  fi
  printf '%s\n' 'CLAIM_RESERVE' >> "$LAUNCH_SEQUENCE_LOG"
  exit 0
fi
printf '%s\n' 'CLAIM_RELEASE' >> "$LAUNCH_SEQUENCE_LOG"
EOF
chmod +x "$BIN/fake-claim"

cat > "$BIN/fake-orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' 'orca' >> "$LAUNCH_ORCA_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$LAUNCH_ORCA_LOG"; done
case "$1" in
  status)
    printf '%s\n' 'ORCA_STATUS' >> "$LAUNCH_SEQUENCE_LOG"
    if [ "${LAUNCH_ORCA_OFFLINE:-0}" = 1 ]; then exit 1; fi
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  worktree)
    case "$2" in
      list)
        printf '%s\n' 'ORCA_LIST' >> "$LAUNCH_SEQUENCE_LOG"
        if [ "${LAUNCH_ORCA_OFFLINE:-0}" = 1 ]; then exit 1; fi
        cat "$LAUNCH_ORCA_LIST_FILE"
        ;;
      create)
        printf '%s\n' 'ORCA_CREATE' >> "$LAUNCH_SEQUENCE_LOG"
        spec=
        previous=
        for arg in "$@"; do
          if [ "$previous" = --issue ]; then spec=$arg; fi
          previous=$arg
        done
        if [ "${LAUNCH_ORCA_CREATE_BRANCH:-0}" = 1 ]; then
          git -C "$LAUNCH_GIT_REPO" branch "spec-$spec"
        fi
        if [ "${LAUNCH_ORCA_FAIL_CREATE:-0}" = 1 ]; then
          printf '%s\n' 'orca create failed' >&2
          exit 1
        fi
        printf '{"result":{"worktree":{"path":"%s"}}}\n' "${LAUNCH_CREATE_PATH:-$LAUNCH_GIT_REPO/created}"
        ;;
      *) exit 2 ;;
    esac
    ;;
  agent)
    printf '%s\n' 'ORCA_LAUNCH' >> "$LAUNCH_SEQUENCE_LOG"
    if [ "${LAUNCH_ORCA_FAIL_LAUNCH:-0}" = 1 ]; then
      printf '%s\n' 'orca launch failed' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"id":"fake"}}}'
    ;;
  terminal)
    case "$2" in
      create)
        printf '%s\n' 'ORCA_TERMINAL_CREATE' >> "$LAUNCH_SEQUENCE_LOG"
        if [ "${LAUNCH_ORCA_FAIL_TERMINAL:-0}" = 1 ]; then
          printf '%s\n' 'orca terminal create failed' >&2
          exit 1
        fi
        printf '%s\n' '{"result":{"terminal":{"id":"fake"}}}'
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/fake-orca"

run_launch() {
  output=$1
  shift
  (
    cd "$REPO" || exit 125
    env LAUNCH_PLAN_FILE="${LAUNCH_PLAN_FILE_OVERRIDE:-$PLAN}" \
      LAUNCH_PLAN_TEXT_FILE="${LAUNCH_PLAN_TEXT_FILE_OVERRIDE:-$PLAN_TEXT}" \
      LAUNCH_ORCA_LIST_FILE="${LAUNCH_ORCA_LIST_FILE_OVERRIDE:-$ORCA_LIST}" \
      LAUNCH_GIT_REPO="$REPO" \
      LAUNCH_RESUME_DEFAULT="$WT222" \
      LAUNCH_PIPELINE_LOG="$PIPELINE_LOG" LAUNCH_CLAIM_LOG="$CLAIM_LOG" \
      LAUNCH_MAX_LOG="$MAX_LOG" LAUNCH_ORCA_LOG="$ORCA_LOG" \
      LAUNCH_SEQUENCE_LOG="$SEQUENCE_LOG" \
      ISS_PIPELINE_STATUS="$BIN/fake-pipeline" ISS_CLAIM="$BIN/fake-claim" \
      ISS_MAX_WORKERS_CMD="$BIN/fake-max-workers" ISS_ORCA="$BIN/fake-orca" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo "${LAUNCH_REPO_OVERRIDE:-test/repo}" --workers 4 "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/dry.out"
expect_exit 0 "dry run succeeds"
expect_has '开发顺序（同时 2 份，共 4 个 worker）' 'dry run shows pipeline text' "$WORK/dry.out"
expect_has '现在启动吗？会在 Orca 里自动运行：' 'dry run uses Orca heading' "$WORK/dry.out"
expect_has " #222（恢复，原 worktree）→ /implement-spec-split 222 --impl codex --parallel 2" \
  'visible resume is automatic' "$WORK/dry.out"
expect_has " #224（恢复，在主工作树开终端标签）→ cd $WT224 后运行 /implement-spec-split 224 --impl codex --parallel 2" \
  'invisible resume uses a main-worktree terminal tab' "$WORK/dry.out"
expect_has ' #238（恢复，找不到 worktree，需手动）' 'missing resume has no command' "$WORK/dry.out"
expect_has ' #237（新 worktree）→ /implement-spec-split 237 --impl codex --parallel 2' \
  'new spec gets a worktree command' "$WORK/dry.out"
expect_has --workers 'pipeline receives worker total' "$PIPELINE_LOG"
expect_has --json 'dry run asks pipeline for JSON' "$PIPELINE_LOG"
expect_without 'reserve' 'dry run makes no claim' "$CLAIM_LOG"
expect_without 'create' 'dry run creates no Orca worktree' "$ORCA_LOG"

LAUNCH_PLAN_FILE_OVERRIDE=$EMPTY_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$EMPTY_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$PIPELINE_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/empty-dry.out"
expect_exit 0 "empty dry run succeeds"
expect_has '没有可以启动的规格。' 'empty dry run says no specs' "$WORK/empty-dry.out"
expect_without '现在启动吗' 'empty dry run has no launch heading' "$WORK/empty-dry.out"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

LAUNCH_ORCA_OFFLINE=1
export LAUNCH_ORCA_OFFLINE
: > "$ORCA_LOG"; : > "$MAX_LOG"
run_launch "$WORK/offline-dry.out"
expect_exit 0 "offline dry run succeeds"
expect_has '不在 Orca 里，请在各 worktree 手动运行：' 'offline dry run uses manual heading' "$WORK/offline-dry.out"
expect_has " #222（恢复，需手动）→ cd $WT222 后运行 /implement-spec-split 222 --impl codex --parallel 2" \
  'offline visible resume is manual' "$WORK/offline-dry.out"
expect_has " #224（恢复，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --impl codex --parallel 2" \
  'offline invisible resume remains manual' "$WORK/offline-dry.out"
expect_has ' #237 → /implement-spec-split 237 --impl codex --parallel 2' \
  'offline new spec is direct' "$WORK/offline-dry.out"
expect_without '（新 worktree）' 'offline dry run omits Orca label' "$WORK/offline-dry.out"
expect_without 'max-workers' 'offline dry run does not set worker limit' "$MAX_LOG"

: > "$MAX_LOG"
run_launch "$WORK/offline-apply.out" --apply
expect_exit 2 "offline apply exits two"
expect_has '不在 Orca 里，无法自动启动。' 'offline apply explains failure' "$WORK/offline-apply.out.err"
expect_without 'max-workers' 'offline apply does not set worker limit' "$MAX_LOG"
unset LAUNCH_ORCA_OFFLINE

: > "$PIPELINE_LOG"; : > "$CLAIM_LOG"; : > "$MAX_LOG"
: > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/apply.out" --apply --only 222,237,999
expect_exit 0 "filtered apply succeeds"
expect_has '#999 已不可启动，跳过' 'unavailable only spec is skipped' "$WORK/apply.out"
expect_has '#222 已启动' 'visible resume is launched' "$WORK/apply.out"
expect_has '#237 已启动' 'new spec is launched' "$WORK/apply.out"
expect_has '已启动 2 份，跳过 1 份，失败 0 份。' 'apply summary is complete' "$WORK/apply.out"
expect_has '4' 'max-workers receives worker total' "$MAX_LOG"
expect_has "$MAIN_WORKTREE_PATH" 'claim commands run in the main worktree' "$CLAIM_LOG"
expect_sequence MAX_WORKERS CLAIM_RESUME 'max-workers runs before resume claim'
expect_sequence CLAIM_RESUME ORCA_LAUNCH 'resume claim runs before agent launch'
expect_sequence MAX_WORKERS CLAIM_RESERVE 'max-workers runs before fresh claim'
expect_sequence CLAIM_RESERVE ORCA_CREATE 'fresh claim runs before Orca create'
expect_has 'worktree' 'apply uses Orca worktree create' "$ORCA_LOG"
expect_has 'agent' 'apply uses Orca agent launch' "$ORCA_LOG"
expect_has 'path:' 'Orca calls use path selectors' "$ORCA_LOG"
expect_has '/implement-spec-split 222 --impl codex --parallel 2' \
  'prompt remains one logged argument' "$ORCA_LOG"
expect_has '/implement-spec-split 237 --impl codex --parallel 2' \
  'new-spec prompt remains one logged argument' "$ORCA_LOG"
expect_has "--repo" 'Orca create targets main worktree' "$ORCA_LOG"
expect_has "path:$MAIN_WORKTREE_PATH" 'Orca create uses absolute main worktree' "$ORCA_LOG"
expect_has '--base-branch' 'Orca create uses base branch' "$ORCA_LOG"
expect_has 'origin/master' 'main branch comes from origin HEAD' "$ORCA_LOG"
expect_has "$WT222" 'resume launch uses reserve stdout path' "$ORCA_LOG"
expect_has '--prompt' 'Orca calls pass prompt explicitly' "$ORCA_LOG"

: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/only-invisible.out" --apply --only 224
expect_exit 0 "apply with only an invisible resume succeeds"
expect_without '#224 已不可启动，跳过' \
  'invisible only resume is available with main worktree' "$WORK/only-invisible.out"
expect_has "#224 已启动：${WT224}（挂在主工作树的终端标签 spec-224）" \
  'invisible resume is launched in a terminal tab' "$WORK/only-invisible.out"
expect_has '已启动 1 份，跳过 0 份，失败 0 份。' \
  'invisible only resume summary counts launch' "$WORK/only-invisible.out"
expect_has 'reserve' 'invisible resume is reserved' "$CLAIM_LOG"
expect_has '--resume' 'invisible resume reservation is resumed' "$CLAIM_LOG"
expect_has 'terminal' 'invisible resume uses Orca terminal' "$ORCA_LOG"
expect_has 'create' 'invisible resume creates a terminal' "$ORCA_LOG"
expect_has "path:$MAIN_WORKTREE_PATH" \
  'terminal is attached to the main worktree' "$ORCA_LOG"
expect_has 'spec-224' 'terminal title names the spec' "$ORCA_LOG"
ESCAPED_WT224=$(printf '%q' "$WT224")
ESCAPED_IMPL_COMMAND=$(printf '%q' '/implement-spec-split 224 --impl codex --parallel 2')
expect_has "cd $ESCAPED_WT224 && claude $ESCAPED_IMPL_COMMAND" \
  'terminal command shell-escapes path and prompt' "$ORCA_LOG"
expect_sequence CLAIM_RESUME ORCA_TERMINAL_CREATE \
  'invisible resume claim runs before terminal create'

LAUNCH_ORCA_FAIL_TERMINAL=1
export LAUNCH_ORCA_FAIL_TERMINAL
: > "$CLAIM_LOG"; : > "$ORCA_LOG"; : > "$SEQUENCE_LOG"
run_launch "$WORK/terminal-failure.out" --apply --only 224
expect_exit 1 "Orca terminal failure exits one"
expect_has '#224 启动失败：orca terminal create failed' \
  'terminal failure surfaces first error line' "$WORK/terminal-failure.out"
expect_has '已启动 0 份，跳过 0 份，失败 1 份。' \
  'terminal failure summary counts failure' "$WORK/terminal-failure.out"
expect_has 'release' 'terminal failure releases claim' "$CLAIM_LOG"
expect_has '--force' 'terminal failure forces claim release' "$CLAIM_LOG"
unset LAUNCH_ORCA_FAIL_TERMINAL

LAUNCH_ORCA_LIST_FILE_OVERRIDE=$ORCA_LIST_NO_MAIN
export LAUNCH_ORCA_LIST_FILE_OVERRIDE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
LAUNCH_PLAN_FILE_OVERRIDE=$ONLY_INVISIBLE_PLAN
LAUNCH_PLAN_TEXT_FILE_OVERRIDE=$ONLY_INVISIBLE_PLAN_TEXT
export LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE
: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/invisible-without-main-dry.out"
expect_exit 0 "invisible resume without main worktree dry run succeeds"
expect_has " #224（恢复，worktree 不在 Orca 列表里，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --impl codex --parallel 2" \
  'invisible resume without main worktree dry run stays manual' "$WORK/invisible-without-main-dry.out"
expect_without 'reserve' 'dry run without main worktree makes no claim' "$CLAIM_LOG"
expect_without 'terminal' 'dry run without main worktree has no terminal' "$ORCA_LOG"

: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/invisible-without-main.out" --apply
expect_exit 0 "invisible resume without main worktree remains manual"
expect_has " #224（恢复，worktree 不在 Orca 列表里，需手动）→ cd $WT224 后运行 /implement-spec-split 224 --impl codex --parallel 2" \
  'invisible resume without main worktree stays manual' "$WORK/invisible-without-main.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'manual invisible resume summary counts skip' "$WORK/invisible-without-main.out"
expect_without 'reserve' 'manual invisible resume is not claimed' "$CLAIM_LOG"
expect_without 'terminal' 'manual invisible resume has no terminal' "$ORCA_LOG"
unset LAUNCH_PLAN_FILE_OVERRIDE LAUNCH_PLAN_TEXT_FILE_OVERRIDE

: > "$CLAIM_LOG"; : > "$ORCA_LOG"
run_launch "$WORK/only-invisible.out" --apply --only 224
expect_exit 0 "invisible resume without main worktree succeeds as a skip"
expect_count '#224 已不可启动，跳过' 1 \
  'invisible resume without main worktree is reported once' "$WORK/only-invisible.out"
expect_has '已启动 0 份，跳过 1 份，失败 0 份。' \
  'invisible resume without main worktree is skipped once' "$WORK/only-invisible.out"
expect_without 'reserve' 'invisible resume without main worktree is not claimed' "$CLAIM_LOG"
expect_without 'terminal' 'invisible resume without main worktree has no terminal' "$ORCA_LOG"
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
expect_without 'create' 'reserve conflict does not call Orca create' "$ORCA_LOG"
unset LAUNCH_ORCA_FAIL_CREATE
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
expect_without 'launch' 'resume conflict does not call agent launch' "$ORCA_LOG"
unset LAUNCH_CLAIM_FAIL_RESUME

: > "$ORCA_LOG"
LAUNCH_REPO_OVERRIDE=other/repo run_launch "$WORK/mismatch.out" --apply
expect_exit 1 "repo that is not this checkout's origin is refused"
expect_has 'does not match' 'mismatch names the problem' "$WORK/mismatch.out.err"
expect_without 'create' 'mismatch never calls Orca' "$ORCA_LOG"

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
