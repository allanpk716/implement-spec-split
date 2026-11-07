#!/usr/bin/env bash
# Isolated tests for scripts/pipeline-status.sh. Generated mktemp directories
# are deliberately retained on both pass and failure, as safe debugging aids.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/pipeline-status.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pipeline-status-test.XXXXXX")
FIXTURE=$WORK/fixture
BIN=$WORK/bin
REPO=$WORK/git-repo
NOT_REPO=$WORK/not-a-repo
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

mkdir -p "$FIXTURE" "$BIN" "$REPO" "$NOT_REPO" || exit 1

FIXTURE=$FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.FIXTURE;

function sub(total, completed = total) {
  return {total, completed, percent_completed: total ? Math.round(100 * completed / total) : 0};
}

function issue(number, title, state, labels, body, children = sub(0)) {
  return {
    number,
    title,
    state,
    labels: labels.map((name) => ({name})),
    body,
    sub_issues_summary: children,
    issue_dependencies_summary: {blocked_by: 0, total_blocked_by: 0, blocking: 0, total_blocking: 0},
  };
}

const issues = [
  issue(21, 'Exploration map', 'open', ['wayfinder:map'], '', sub(1, 0)),
  issue(22, 'Client map', 'closed', ['wayfinder:map'], '', sub(8, 6)),
  issue(31, 'Server map', 'closed', ['wayfinder:map'], '', sub(1, 0)),
  issue(23, 'Open research decision', 'open', ['wayfinder:research'], ''),
  issue(24, 'Open grilling decision', 'open', ['wayfinder:grilling'], ''),
  issue(56, 'Implement client version', 'open', ['ready-for-agent'], '', sub(3, 0)),
  issue(57, 'Missing client spec', 'open', ['ready-for-agent'], ''),
  issue(58, 'Single-ticket implementation', 'open', ['ready-for-agent'], ''),
  issue(59, 'Missing second client spec', 'open', ['ready-for-agent'], ''),
  issue(65, 'Missing server spec', 'open', ['ready-for-agent'], ''),
  issue(66, 'Implementation covered by closed spec', 'open', ['ready-for-agent'], ''),
  issue(67, 'Implementation mentioned outside spec ticket line', 'open', ['ready-for-agent'], ''),
  issue(68, 'Implementation referenced with connector', 'open', ['ready-for-agent'], ''),
  issue(69, 'Implementation mentioned before spec ticket phrase', 'open', ['ready-for-agent'], ''),
  issue(70, 'Legacy parent issue', 'open', [], 'Old parent shape', sub(2, 0)),
  issue(71, 'Legacy ticket one', 'open', [], ''),
  issue(72, 'Legacy ticket two', 'open', [], ''),
  issue(80, 'Spec with own children', 'open', [], '## Problem Statement\nOwn children.', sub(3, 1)),
  issue(81, 'Own child one', 'open', [], ''),
  issue(82, 'Own child two', 'closed', [], ''),
  issue(83, 'Own child three', 'open', [], ''),
  issue(88, 'Single-ticket spec', 'open', [], '## Problem Statement\n背景引用：#65。\n实现票：#58。'),
  issue(89, 'Independent spec', 'open', [], '## Problem Statement\n背景引用：#57。\n实现票：#56，拆为 #90、#91、#92。'),
  issue(90, 'Client ticket one', 'open', [], ''),
  issue(91, 'Client ticket two', 'closed', [], ''),
  issue(92, 'Client ticket three', 'open', [], ''),
  issue(93, 'Spec without tickets', 'open', [], '## Problem Statement\nNot split yet.'),
  issue(94, 'Closed single-ticket spec', 'closed', [], '## Problem Statement\n背景提到地图票：#67。\n同线范围外：#69。决策来源：#100。实现票：#66，父地图为 #31。', sub(1, 1)),
  issue(95, 'Spec using connector', 'open', [], '## Problem Statement\n实现票为 #68。'),
  issue(100, 'External blocker one', 'open', [], ''),
  issue(101, 'External blocker two', 'open', [], ''),
  issue(102, 'Closed external blocker', 'closed', [], ''),
];

const responses = {
  'sub-21': [
    issue(24, 'Open grilling decision', 'open', ['wayfinder:grilling'], ''),
  ],
  'sub-22': [
    issue(23, 'Open research decision', 'open', ['wayfinder:research'], ''),
    issue(56, 'Implement client version', 'open', ['ready-for-agent'], '', sub(3, 0)),
    issue(57, 'Missing client spec', 'open', ['ready-for-agent'], ''),
    issue(58, 'Single-ticket implementation', 'open', ['ready-for-agent'], ''),
    issue(59, 'Missing second client spec', 'open', ['ready-for-agent'], ''),
  ],
  'sub-31': [
    issue(65, 'Missing server spec', 'open', ['ready-for-agent'], ''),
    issue(66, 'Implementation covered by closed spec', 'open', ['ready-for-agent'], ''),
    issue(67, 'Implementation mentioned outside spec ticket line', 'open', ['ready-for-agent'], ''),
    issue(68, 'Implementation referenced with connector', 'open', ['ready-for-agent'], ''),
    issue(69, 'Implementation mentioned before spec ticket phrase', 'open', ['ready-for-agent'], ''),
  ],
  'sub-56': [
    issue(90, 'Client ticket one', 'open', [], ''),
    issue(91, 'Client ticket two', 'closed', [], ''),
    issue(92, 'Client ticket three', 'open', [], ''),
  ],
  'sub-70': [
    issue(71, 'Legacy ticket one', 'open', [], ''),
    issue(72, 'Legacy ticket two', 'open', [], ''),
  ],
  'sub-80': [
    issue(81, 'Own child one', 'open', [], ''),
    issue(82, 'Own child two', 'closed', [], ''),
    issue(83, 'Own child three', 'open', [], ''),
  ],
  'blocker-58': [
    issue(100, 'External blocker one', 'open', [], ''),
  ],
  'blocker-68': [],
  'blocker-71': [],
  'blocker-72': [],
  'blocker-81': [
    issue(101, 'External blocker two', 'open', [], ''),
  ],
  'blocker-83': [
    issue(81, 'Own child one', 'open', [], ''),
    issue(101, 'External blocker two', 'open', [], ''),
  ],
  'blocker-90': [],
  'blocker-92': [],
};

fs.writeFileSync(path(directory, 'issues.json'), JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(path(directory, `${name}.json`), JSON.stringify(value, null, 2));
}

function path(...parts) {
  return parts.join('/');
}
NODE

if [ ! -s "$FIXTURE/issues.json" ]; then
  printf 'FAIL fixture generation\n' >&2
  exit 1
fi

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
FIXTURE_DIR=${FIXTURE_DIR:?FIXTURE_DIR is required}
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'fake gh: simulated failure' >&2
  exit 1
fi
case "$*" in
  *'issues?state=all&per_page=100'*)
    cat "$FIXTURE_DIR/issues.json"
    exit $?
    ;;
  */issues/*/sub_issues)
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/sub_issues.*#\1#p')
    cat "$FIXTURE_DIR/sub-$number.json"
    exit $?
    ;;
  */issues/*/dependencies/blocked_by)
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

git -C "$REPO" init --quiet
git -C "$REPO" config user.name 'Pipeline Status Test'
git -C "$REPO" config user.email 'pipeline-status-test@example.invalid'
git -C "$REPO" config commit.gpgsign false
printf '%s\n' 'test repository' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git -C "$REPO" branch spec-89
git -C "$REPO" branch spec-80-old

run_status() {
  cwd=$1
  output=$2
  (
    cd "$cwd" || exit 125
    env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_status "$REPO" "$WORK/main.out"
expect_exit 0 "fixture scan succeeds"
expect_has '- #89 1/3' 'independent spec uses implementation children and spec number' "$WORK/main.out"
expect_without '- #56 ' 'map implementation parent is not also a legacy spec' "$WORK/main.out"
expect_has '已接手（分支 spec-89，最后提交 ' 'exact integration branch is taken' "$WORK/main.out"
expect_has '#80 1/3' 'spec with own children has ticket progress' "$WORK/main.out"
expect_has '已接手（分支 spec-80-old，最后提交 ' 'legacy integration branch is taken' "$WORK/main.out"
expect_has '；被卡住：#101' 'external open blockers mark a spec blocked' "$WORK/main.out"
expect_has '#88 0/1' 'single-ticket spec is implementable' "$WORK/main.out"
expect_has '；被卡住：#100' 'single-ticket spec blocker is reported' "$WORK/main.out"
expect_has '#70 0/2' 'legacy parent shape is implementable' "$WORK/main.out"
expect_has '#93 Spec without tickets → to-tickets' 'spec without tickets needs to-tickets' "$WORK/main.out"
expect_without '#93 0/0' 'unticketed spec is not implementable yet' "$WORK/main.out"
expect_has '地图 #22 Client map' 'missing specs are grouped by map' "$WORK/main.out"
expect_has '#57 Missing client spec → to-spec' 'unreferenced map implementation needs to-spec' "$WORK/main.out"
expect_has '地图 #31 Server map' 'second map group is shown' "$WORK/main.out"
expect_has '#21 Exploration map' 'map with open decisions needs wayfinder' "$WORK/main.out"

expect_without '#66 Implementation covered by closed spec → to-spec' 'closed spec coverage removes implementation from missing specs' "$WORK/main.out"
expect_has '#67 Implementation mentioned outside spec ticket line → to-spec' 'incidental map reference does not cover implementation' "$WORK/main.out"
expect_has '#69 Implementation mentioned before spec ticket phrase → to-spec' 'earlier reference on implementation line does not cover implementation' "$WORK/main.out"
expect_without '#68 Implementation referenced with connector → to-spec' 'implementation ticket connector is recognized' "$WORK/main.out"
expect_has '#95 0/1' 'spec with connector reference is implementable' "$WORK/main.out"
expect_without '- #94 0/1 ' 'closed spec is not listed as implementable' "$WORK/main.out"
expect_without '#94 Closed single-ticket spec → to-tickets' 'closed spec is not listed as needing tickets' "$WORK/main.out"

run_status "$NOT_REPO" "$WORK/not-repo.out"
expect_exit 0 "outside a git repository still scans issues"
expect_has '未知（不在 git 仓库）' 'branch state is unknown outside git' "$WORK/not-repo.out"

(
  cd "$REPO" || exit 125
  env FIXTURE_DIR="$FIXTURE" FAKE_GH_FAIL=1 PATH="$BIN:$PATH" \
    bash "$SCRIPT" --repo test/repo
) > "$WORK/gh-failure.out" 2> "$WORK/gh-failure.err"
RUN_EXIT=$?
expect_exit 1 "gh failure exits nonzero"
expect_has 'gh api failed while listing issues' 'gh failure names the failing stage' "$WORK/gh-failure.err"

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
