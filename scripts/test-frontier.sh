#!/usr/bin/env bash
# Deterministic tests for scripts/frontier.sh. They run the real
# pipeline-status.sh against a fake gh, so the Spec-to-Ticket resolution and
# the blocked_by queries are covered end to end without network access.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/frontier.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/frontier-test.XXXXXX")
FIXTURE=$WORK/fixture
BIN=$WORK/bin
mkdir -p "$FIXTURE" "$BIN" || exit 1

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
  if grep -Fq -- "$text" "$file"; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file"; then
    record FAIL "$name" "unexpected [$text]"
  else
    record PASS "$name"
  fi
}

SPEC_ARG=10

run_frontier() {
  output=$1
  shift
  env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" "$@" \
    bash "$SCRIPT" --repo test/repo --spec "$SPEC_ARG" > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

FIXTURE=$FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.FIXTURE;

function sub(total, completed = total) {
  return {total, completed, percent_completed: total ? Math.round(100 * completed / total) : 0};
}

function issue(number, title, state, labels, body = '', children = sub(0)) {
  return {
    number,
    title,
    state,
    labels: labels.map((name) => ({name})),
    body,
    sub_issues_summary: children,
    issue_dependencies_summary: {blocked_by: 0, total_blocked_by: 0, blocking: 0, total_blocking: 0},
    assignees: [],
  };
}

const issues = [
  issue(10, 'Test spec', 'open', [], '## Problem Statement\nTest spec.', sub(5, 0)),
  issue(11, 'Blocked ticket', 'open', []),
  issue(12, 'Ready ticket', 'open', []),
  issue(13, 'Ready after closed blocker', 'open', []),
  issue(14, '【搁置】Shelved ticket', 'open', []),
  issue(15, 'Human ticket', 'open', ['ready-for-human']),
  issue(20, 'Open blocker', 'open', []),
  issue(21, 'Closed blocker', 'closed', []),
];

const responses = {
  'sub-10': [
    issue(11, 'Blocked ticket', 'open', []),
    issue(12, 'Ready ticket', 'open', []),
    issue(13, 'Ready after closed blocker', 'open', []),
    issue(14, '【搁置】Shelved ticket', 'open', []),
    issue(15, 'Human ticket', 'open', ['ready-for-human']),
  ],
  'blocker-11': [issue(20, 'Open blocker', 'open', []), issue(21, 'Closed blocker', 'closed', [])],
  'blocker-12': [],
  'blocker-13': [issue(21, 'Closed blocker', 'closed', [])],
  'blocker-14': [issue(20, 'Open blocker', 'open', [])],
  'blocker-15': [],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}
NODE

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
FIXTURE_DIR=${FIXTURE_DIR:?FIXTURE_DIR is required}
case "$*" in
  *'issues?state=all&per_page=100'*)
    if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'fake gh: simulated failure' >&2
      exit 1
    fi
    cat "$FIXTURE_DIR/issues.json"
    exit $?
    ;;
  */issues/*/sub_issues)
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/sub_issues.*#\1#p')
    cat "$FIXTURE_DIR/sub-$number.json"
    exit $?
    ;;
  */issues/*/dependencies/blocked_by)
    count=0
    [ -f "$FIXTURE_DIR/blocker-calls" ] && count=$(cat "$FIXTURE_DIR/blocker-calls")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FIXTURE_DIR/blocker-calls"
    if [ "${FAKE_GH_FAIL_BLOCKERS:-0}" = 1 ]; then
      printf '%s\n' 'fake gh: blocked_by unavailable' >&2
      exit 1
    fi
    if [ "${FAKE_GH_FAIL_BLOCKERS_AT:-0}" -gt 0 ] && [ "$count" -ge "${FAKE_GH_FAIL_BLOCKERS_AT}" ]; then
      printf '%s\n' "fake gh: blocked_by unavailable on call $count" >&2
      exit 1
    fi
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/dependencies/blocked_by.*#\1#p')
    cat "$FIXTURE_DIR/blocker-$number.json"
    exit $?
    ;;
  *)
    printf 'fake gh: unexpected arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$BIN/gh"

cd "$WORK" || exit 1

run_frontier "$WORK/main.out"
expect_exit 0 "frontier scan succeeds"
awk '/^# /{exit} {print}' "$WORK/main.out" > "$WORK/frontier-only.out"
expect_has '#12' 'unblocked ticket is in the frontier' "$WORK/main.out"
expect_has '#13' 'ticket with only closed blockers is in the frontier' "$WORK/main.out"
expect_without '#11' 'blocked ticket is not in the frontier' "$WORK/frontier-only.out"
expect_without '#14' 'shelved ticket is not in the frontier' "$WORK/frontier-only.out"
expect_without '#15' 'human ticket is not in the frontier' "$WORK/frontier-only.out"
expect_has '# blocked' 'blocked section is printed' "$WORK/main.out"
expect_has '#11 Blocked ticket（阻塞：#20）' 'blocked ticket names its open blockers' "$WORK/main.out"
expect_has '#14 【搁置】Shelved ticket（阻塞：#20）' 'blocked section includes a shelved blocked ticket' "$WORK/main.out"
expect_has '# human' 'human section is printed' "$WORK/main.out"
expect_has '#15 Human ticket（人工）' 'human section lists the ready-for-human ticket' "$WORK/main.out"
expect_has '# shelved' 'shelved section is printed' "$WORK/main.out"
expect_has '#14 【搁置】Shelved ticket（搁置）' 'shelved section lists the shelved ticket' "$WORK/main.out"
check_first_two=$(head -n 2 "$WORK/main.out" | tr '\n' ' ')
if [ "$check_first_two" = '#12 #13 ' ]; then
  record PASS "frontier lines come first, ascending"
else
  record FAIL "frontier lines come first, ascending" "got [$check_first_two]"
fi

SPEC_ARG=99
run_frontier "$WORK/missing.out"
expect_exit 1 "unknown spec fails closed"
expect_has 'not found' "unknown spec names the problem on stderr" "$WORK/missing.out.err"
if [ ! -s "$WORK/missing.out" ]; then
  record PASS "unknown spec prints nothing on stdout"
else
  record FAIL "unknown spec prints nothing on stdout"
fi

SPEC_ARG=10
run_frontier "$WORK/gh-fail.out" FAKE_GH_FAIL=1
expect_exit 1 "pipeline-status failure fails closed"
expect_has 'pipeline-status.sh --graph failed' "pipeline-status failure is explained" "$WORK/gh-fail.out.err"
if [ ! -s "$WORK/gh-fail.out" ]; then
  record PASS "pipeline-status failure prints nothing on stdout"
else
  record FAIL "pipeline-status failure prints nothing on stdout"
fi

rm -f "$FIXTURE/blocker-calls"
run_frontier "$WORK/blocker-fail.out" FAKE_GH_FAIL_BLOCKERS_AT=5
expect_exit 1 "blocked_by failure fails closed"
expect_has 'gh api failed for issue #11' "blocked_by failure names the issue" "$WORK/blocker-fail.out.err"
if [ ! -s "$WORK/blocker-fail.out" ]; then
  record PASS "blocked_by failure prints nothing on stdout"
else
  record FAIL "blocked_by failure prints nothing on stdout"
fi

env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo test/repo > "$WORK/usage.out" 2> "${WORK}/usage.out.err"
RUN_EXIT=$?
expect_exit 64 "missing --spec is a usage error"

SPEC_ARG=abc
run_frontier "$WORK/usage2.out"
expect_exit 64 "non-numeric --spec is a usage error"

echo "Artifacts: $WORK"
echo "Summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
