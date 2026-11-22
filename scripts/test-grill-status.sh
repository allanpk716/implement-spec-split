#!/usr/bin/env bash
# Isolated fake-gh tests for scripts/grill-status.sh.
# The mktemp tree is intentionally retained: this test must not recursively
# delete its scratch directory.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/grill-status.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/grill-status-test.XXXXXX")
WORK=$(cd "$WORK" && pwd)
BIN=$WORK/bin
RUN_ROOT=$WORK/design-runs
REPO=$WORK/repo
GH_LOG=$WORK/gh.log
RUN_STDERR=$WORK/stderr.txt
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

expect_file_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in $(basename "$file")"
  fi
}

expect_same_file() {
  expected=$1
  name=$2
  actual=$3
  if [ -f "$actual" ] && cmp -s "$expected" "$actual"; then
    record PASS "$name"
  else
    record FAIL "$name" "actual=$actual"
  fi
}

mkdir -p "$BIN" "$RUN_ROOT" "$REPO" || exit 1
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin https://github.com/example/Grill-Status-Demo.git

cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -u
: "${GRILL_TEST_REPO:?GRILL_TEST_REPO is required}"
: "${GRILL_TEST_GH_LOG:?GRILL_TEST_GH_LOG is required}"
[ "$#" -eq 4 ] || { printf 'fake gh: expected four arguments\n' >&2; exit 70; }
[ "$1" = api ] || { printf 'fake gh: expected api\n' >&2; exit 70; }
[ "$3" = --jq ] || { printf 'fake gh: expected --jq\n' >&2; exit 70; }
printf '%s %s\n' "$2" "$PWD" >> "$GRILL_TEST_GH_LOG"
ISSUE=${2##*/}
case "$ISSUE" in
  101) printf 'closed\tFinished spec one\t2\t2\n' ;;
  102) printf 'closed\tFinished spec without tickets\t0\t0\n' ;;
  103) printf 'open\tActive spec\t1\t3\n' ;;
  404) printf 'fake gh: issue not found\n' >&2; exit 1 ;;
  *) printf 'fake gh: unexpected issue %s\n' "$ISSUE" >&2; exit 70 ;;
esac
FAKE_GH
chmod +x "$BIN/gh"

COMPLETED_RUN=$RUN_ROOT/grill-status-demo-20260101-0900-feature
ONGOING_RUN=$RUN_ROOT/grill-status-demo-20260102-1000-feature
INTERRUPTED_RUN=$RUN_ROOT/grill-status-demo-20260102-1030-feature
UNRECORDED_RUN=$RUN_ROOT/grill-status-demo-20260102-1115-map
WRONG_PREFIX_RUN=$RUN_ROOT/grill-status-demo-foo-20260101-0800-feature
mkdir -p "$COMPLETED_RUN" "$ONGOING_RUN" "$INTERRUPTED_RUN" \
  "$UNRECORDED_RUN" "$WRONG_PREFIX_RUN"

cat > "$COMPLETED_RUN/handoff.md" <<'EOF'
# Design session handoff：完成 grill 状态

## 规格
- #101 完成规格一
- #102 无票规格

## 票
- #101 完成
EOF

cat > "$ONGOING_RUN/handoff.md" <<'EOF'
# Design session handoff：进行中的 grill

## 规格
- #103 进行中规格
- #404 查询失败规格

## 票
- #103 有一张完成
EOF

LONG_TOPIC=
EXPECTED_LONG_TOPIC=
TOPIC_INDEX=0
while [ "$TOPIC_INDEX" -lt 61 ]; do
  LONG_TOPIC="${LONG_TOPIC}A"
  if [ "$TOPIC_INDEX" -lt 60 ]; then
    EXPECTED_LONG_TOPIC="${EXPECTED_LONG_TOPIC}A"
  fi
  TOPIC_INDEX=$((TOPIC_INDEX + 1))
done
printf '%s\n' "$LONG_TOPIC" > "$INTERRUPTED_RUN/topic.md"

run_grill_status() {
  output=$1
  shift
  (
    cd "$REPO"
    PATH="$BIN:$PATH" \
      DESIGN_SESSION_ROOT=$RUN_ROOT \
      GRILL_TEST_REPO=$REPO \
      GRILL_TEST_GH_LOG=$GH_LOG \
      bash "$SCRIPT" "$@"
  ) > "$output" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

: > "$GH_LOG"
run_grill_status "$WORK/status.out" "$REPO"
expect_exit 0 'repository argument lists all matching runs'
expect_file_has "$REPO" 'gh queries run inside the repository' "$GH_LOG"

cat > "$WORK/expected-status.out" <<EOF
■ 完成 grill 状态  (2026-01-01 09:00 feature)  已完成
  #101 [CLOSED] Finished spec one  票 2/2
  #102 [CLOSED] Finished spec without tickets  票 -
■ 进行中的 grill  (2026-01-02 10:00 feature)  进行中
  #103 [OPEN] Active spec  票 1/3
  #404 （查询失败）
■ ${EXPECTED_LONG_TOPIC}…  (2026-01-02 10:30 feature)  中断（无 handoff）
■ （题目未记录）  (2026-01-02 11:15 map)  中断（无 handoff）
共 4 次 grill：已完成 1，进行中 1，中断 2
EOF
expect_same_file "$WORK/expected-status.out" 'status output covers all required states' \
  "$WORK/status.out"

: > "$GH_LOG"
run_grill_status "$WORK/default-dir.out"
expect_exit 0 'current directory is the default repository'
expect_same_file "$WORK/expected-status.out" 'default directory gives the same output' \
  "$WORK/default-dir.out"

EMPTY_ROOT=$WORK/empty-design-runs
mkdir -p "$EMPTY_ROOT"
: > "$GH_LOG"
(
  cd "$REPO"
  PATH="$BIN:$PATH" \
    DESIGN_SESSION_ROOT=$EMPTY_ROOT \
    GRILL_TEST_REPO=$REPO \
    GRILL_TEST_GH_LOG=$GH_LOG \
    bash "$SCRIPT"
) > "$WORK/no-runs.out" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_exit 0 'no records is successful'
if [ "$(cat "$WORK/no-runs.out")" = '（本仓库没有 Design session 记录）' ]; then
  record PASS 'no records has dedicated output'
else
  record FAIL 'no records has dedicated output' "output=$(cat "$WORK/no-runs.out")"
fi
if [ -s "$GH_LOG" ]; then
  record FAIL 'no records avoids gh calls'
else
  record PASS 'no records avoids gh calls'
fi

: > "$GH_LOG"
run_grill_status "$WORK/tsv.out" --tsv "$REPO"
expect_exit 0 'tsv mode succeeds'
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    grill-status-demo-20260101-0900-feature feature '2026-01-01 09:00' done \
    '完成 grill 状态' 101,102 ''
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    grill-status-demo-20260102-1000-feature feature '2026-01-02 10:00' ongoing \
    '进行中的 grill' 103,404 103,404
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    grill-status-demo-20260102-1030-feature feature '2026-01-02 10:30' interrupted \
    "${EXPECTED_LONG_TOPIC}…" '' ''
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    grill-status-demo-20260102-1115-map map '2026-01-02 11:15' interrupted \
    '（题目未记录）' '' ''
} > "$WORK/expected-tsv.out"
expect_same_file "$WORK/expected-tsv.out" 'tsv mode covers states and spec lists' \
  "$WORK/tsv.out"

: > "$GH_LOG"
(
  cd "$REPO"
  PATH="$BIN:$PATH" \
    DESIGN_SESSION_ROOT=$EMPTY_ROOT \
    GRILL_TEST_REPO=$REPO \
    GRILL_TEST_GH_LOG=$GH_LOG \
    bash "$SCRIPT" --tsv
) > "$WORK/no-runs-tsv.out" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_exit 0 'no records in tsv mode is successful'
if [ -s "$WORK/no-runs-tsv.out" ]; then
  record FAIL 'no records in tsv mode is empty' "output=$(cat "$WORK/no-runs-tsv.out")"
else
  record PASS 'no records in tsv mode is empty'
fi

run_grill_status "$WORK/help.out" --help
expect_exit 0 'help succeeds'
expect_file_has 'Usage: grill-status.sh' 'help prints usage' "$WORK/help.out"

printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
printf 'Scratch retained: %s\n' "$WORK"
[ "$FAILED" -eq 0 ]
