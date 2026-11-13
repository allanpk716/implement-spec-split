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

expect_section_without() {
  heading=$1
  text=$2
  name=$3
  file=$4
  if LC_ALL=C awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    in_section && NF == 0 { exit }
    in_section { print }
  ' "$file" | grep -Fq -- "$text"; then
    record FAIL "$name" "unexpected in [$heading]: [$text]"
  else
    record PASS "$name"
  fi
}

expect_equal() {
  actual=$1
  expected=$2
  name=$3
  if cmp -s "$actual" "$expected"; then
    record PASS "$name"
  else
    record FAIL "$name" "output differs from $expected"
  fi
}

mkdir -p "$FIXTURE" "$BIN" "$REPO" "$NOT_REPO" || exit 1

FIXTURE=$FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.FIXTURE;

function sub(total, completed = total) {
  return {total, completed, percent_completed: total ? Math.round(100 * completed / total) : 0};
}

function issue(number, title, state, labels, body, children = sub(0), extras = {}) {
  return Object.assign({
    number,
    title,
    state,
    labels: labels.map((name) => ({name})),
    body,
    sub_issues_summary: children,
    issue_dependencies_summary: {blocked_by: 0, total_blocked_by: 0, blocking: 0, total_blocking: 0},
    assignees: [],
  }, extras);
}

const issues = [
  issue(21, 'Exploration map', 'open', ['wayfinder:map'], '', sub(1, 0)),
  issue(22, 'Client map', 'closed', ['wayfinder:map'], '', sub(8, 6)),
  issue(31, 'Server map', 'closed', ['wayfinder:map'], '', sub(1, 0)),
  issue(41, 'Map needing a spec', 'open', ['wayfinder:map'], '状态：进行中', sub(2, 2)),
  issue(42, 'Map covered by source-map spec', 'open', ['wayfinder:map'], '', sub(2, 2)),
  issue(43, 'Map covered by map line', 'open', ['wayfinder:map'], '', sub(2, 2)),
  issue(44, 'Map with open decision', 'open', ['wayfinder:map'], '', sub(2, 1)),
  issue(45, 'Map with open implementation', 'open', ['wayfinder:map'], '', sub(2, 1)),
  issue(46, 'Shelved map（搁置）', 'open', ['wayfinder:map'], '状态：搁置', sub(1, 1)),
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
  issue(96, 'Implementation narrated without separator', 'open', ['ready-for-agent'], ''),
  issue(97, 'Spec narrating implementation ticket', 'open', [], '## Problem Statement\n这个规格只是叙述（实现票 #96 还没拆）。'),
  issue(99, 'Closed spec with unfinished children', 'closed', [], '## Problem Statement\nClosed but execution continues.', sub(2, 1)),
  issue(100, 'External blocker one', 'open', [], ''),
  issue(101, 'External blocker two', 'open', [], ''),
  issue(102, 'Closed external blocker', 'closed', [], ''),
  issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
  issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  issue(112, 'Open map decision', 'open', ['wayfinder:research'], ''),
  issue(113, 'Map implementation', 'open', ['ready-for-agent'], ''),
  issue(114, 'Shelved map decision', 'closed', ['wayfinder:research'], ''),
  issue(140, 'Spec citing source map', 'closed', [], '## Problem Statement\n来源地图：#42（全部决策见其 Decisions so far 与 #2–#10）'),
  issue(141, 'Spec citing map line', 'closed', [], '## Problem Statement\n**地图: #43**'),
  issue(121, 'Loose bug issue', 'open', ['bug'], ''),
  issue(122, 'Loose unlabeled issue', 'open', [], ''),
];

const responses = {
  'sub-21': [
    issue(24, 'Open grilling decision', 'open', ['wayfinder:grilling'], '', sub(0), {
      issue_dependencies_summary: {blocked_by: 1, total_blocked_by: 1, blocking: 0, total_blocking: 0},
      assignees: [{login: 'allan'}],
    }),
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
    issue(96, 'Implementation narrated without separator', 'open', ['ready-for-agent'], ''),
  ],
  'sub-41': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-42': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-43': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-44': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(112, 'Open map decision', 'open', ['wayfinder:research'], ''),
  ],
  'sub-45': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(113, 'Map implementation', 'open', ['ready-for-agent'], ''),
  ],
  'sub-46': [
    issue(114, 'Shelved map decision', 'closed', ['wayfinder:research'], ''),
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
  'sub-99': [
    issue(100, 'External blocker one', 'open', [], ''),
    issue(102, 'Closed external blocker', 'closed', [], ''),
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

ORDER_FIXTURE=$WORK/order-fixture
ORDER_REPO=$WORK/order-git-repo
mkdir -p "$ORDER_FIXTURE" "$ORDER_REPO" || exit 1

ORDER_FIXTURE=$ORDER_FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.ORDER_FIXTURE;

function sub(total, completed = total) {
  return {total, completed, percent_completed: total ? Math.round(100 * completed / total) : 0};
}

function issue(number, title, state, labels, body, children = sub(0), extras = {}) {
  return Object.assign({
    number,
    title,
    state,
    labels: labels.map((name) => ({name})),
    body,
    sub_issues_summary: children,
    issue_dependencies_summary: {blocked_by: 0, total_blocked_by: 0, blocking: 0, total_blocking: 0},
    assignees: [],
  }, extras);
}

function spec(number, title, ticketCount) {
  return issue(number, title, 'open', [], '## Problem Statement\nOrder fixture.', sub(ticketCount, 0));
}

const issues = [
  spec(300, 'Hub root', 2),
  issue(301, 'Hub ticket one', 'open', [], ''),
  issue(302, 'Hub ticket two', 'open', [], ''),
  spec(310, 'Downstream one', 1),
  issue(311, 'Downstream one ticket', 'open', [], ''),
  spec(320, 'Downstream two', 1),
  issue(321, 'Downstream two ticket', 'open', [], ''),
  spec(330, 'Partial dependency', 2),
  issue(331, 'Blocked partial ticket', 'open', [], ''),
  issue(332, 'Ready partial ticket', 'open', [], ''),
  spec(340, 'Complete dependency', 1),
  issue(341, 'Fully blocked ticket', 'open', [], ''),
  spec(350, 'Cycle one', 1),
  issue(351, 'Cycle one ticket', 'open', [], ''),
  spec(360, 'Cycle two', 1),
  issue(361, 'Cycle two ticket', 'open', [], ''),
  spec(370, 'Running spec', 1),
  issue(371, 'Running ticket', 'open', [], ''),
  spec(380, 'Interrupted spec', 1),
  issue(381, 'Interrupted ticket', 'open', [], ''),
  spec(390, 'Tie-break spec', 1),
  issue(391, 'Tie-break ticket', 'open', [], ''),
  issue(420, 'Spec-owned blocker root', 'open', [], '## Problem Statement\n实现票：#423。', sub(2, 0)),
  issue(421, 'Spec-owned ticket one', 'open', [], ''),
  issue(422, 'Spec-owned ticket two', 'open', [], ''),
  issue(423, 'Referenced implementation', 'open', [], ''),
  spec(430, 'Blocked by spec issue', 1),
  issue(431, 'Spec-issue dependency ticket', 'open', [], ''),
  spec(440, 'Blocked by implementation ref', 1),
  issue(441, 'Implementation-ref dependency ticket', 'open', [], ''),
  issue(399, 'Loose external blocker', 'open', [], ''),
  issue(400, 'Needs tickets spec', 'open', [], '## Problem Statement\n实现票：#401。'),
  issue(401, 'Unsplit implementation ticket', 'open', [], ''),
  spec(410, 'Blocked by needs tickets', 1),
  issue(411, 'Needs tickets dependency ticket', 'open', [], ''),
];

const responses = {
  'sub-300': [issue(301, 'Hub ticket one', 'open', [], ''), issue(302, 'Hub ticket two', 'open', [], '')],
  'sub-310': [issue(311, 'Downstream one ticket', 'open', [], '')],
  'sub-320': [issue(321, 'Downstream two ticket', 'open', [], '')],
  'sub-330': [
    issue(331, 'Blocked partial ticket', 'open', [], ''),
    issue(332, 'Ready partial ticket', 'open', [], ''),
  ],
  'sub-340': [issue(341, 'Fully blocked ticket', 'open', [], '')],
  'sub-350': [issue(351, 'Cycle one ticket', 'open', [], '')],
  'sub-360': [issue(361, 'Cycle two ticket', 'open', [], '')],
  'sub-370': [issue(371, 'Running ticket', 'open', [], '')],
  'sub-380': [issue(381, 'Interrupted ticket', 'open', [], '')],
  'sub-390': [issue(391, 'Tie-break ticket', 'open', [], '')],
  'sub-420': [
    issue(421, 'Spec-owned ticket one', 'open', [], ''),
    issue(422, 'Spec-owned ticket two', 'open', [], ''),
  ],
  'sub-430': [issue(431, 'Spec-issue dependency ticket', 'open', [], '')],
  'sub-440': [issue(441, 'Implementation-ref dependency ticket', 'open', [], '')],
  'sub-410': [issue(411, 'Needs tickets dependency ticket', 'open', [], '')],
  'blocker-301': [],
  'blocker-302': [],
  'blocker-311': [issue(301, 'Hub ticket one', 'open', [], '')],
  'blocker-321': [issue(302, 'Hub ticket two', 'open', [], '')],
  'blocker-331': [
    issue(381, 'Interrupted ticket', 'open', [], ''),
    issue(399, 'Loose external blocker', 'open', [], ''),
  ],
  'blocker-332': [],
  'blocker-341': [issue(371, 'Running ticket', 'open', [], '')],
  'blocker-351': [issue(361, 'Cycle two ticket', 'open', [], '')],
  'blocker-361': [issue(351, 'Cycle one ticket', 'open', [], '')],
  'blocker-371': [],
  'blocker-381': [],
  'blocker-391': [],
  'blocker-421': [],
  'blocker-422': [],
  'blocker-431': [issue(420, 'Spec-owned blocker root', 'open', [], '## Problem Statement\n实现票：#423。', sub(2, 0))],
  'blocker-441': [issue(423, 'Referenced implementation', 'open', [], '')],
  'blocker-411': [issue(401, 'Unsplit implementation ticket', 'open', [], '')],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}
NODE

EMPTY_FIXTURE=$WORK/empty-wave-fixture
EMPTY_REPO=$WORK/empty-wave-git-repo
mkdir -p "$EMPTY_FIXTURE" "$EMPTY_REPO" || exit 1

EMPTY_FIXTURE=$EMPTY_FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.EMPTY_FIXTURE;

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
    assignees: [],
  };
}

const issues = [
  issue(500, 'Running blocker spec', 'open', [], '## Problem Statement\nEmpty-wave fixture.', sub(1, 0)),
  issue(501, 'Running blocker ticket', 'open', [], ''),
  issue(510, 'Idle blocked spec', 'open', [], '## Problem Statement\nEmpty-wave fixture.', sub(1, 0)),
  issue(511, 'Idle blocked ticket', 'open', [], ''),
];
const responses = {
  'sub-500': [issues[1]],
  'sub-510': [issues[3]],
  'blocker-501': [],
  'blocker-511': [issues[0]],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}
NODE

cat > "$BIN/order-lstart" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  777) printf '%s\n' 'fake alive' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/order-lstart"

cat > "$BIN/order-lstart-all" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  777) printf '%s\n' 'fake alive' ;;
  778) printf '%s\n' 'dead holder' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/order-lstart-all"

git -C "$ORDER_REPO" init --quiet
git -C "$ORDER_REPO" config user.name 'Pipeline Status Order Test'
git -C "$ORDER_REPO" config user.email 'pipeline-status-order-test@example.invalid'
git -C "$ORDER_REPO" config commit.gpgsign false
printf '%s\n' 'order repository' > "$ORDER_REPO/README.md"
git -C "$ORDER_REPO" add README.md
git -C "$ORDER_REPO" commit --quiet -m 'initial commit'
git -C "$ORDER_REPO" branch spec-370
git -C "$ORDER_REPO" branch spec-380
ORDER_RESUME_WORKTREE=$ORDER_REPO/spec-380-worktree
git -C "$ORDER_REPO" worktree add --quiet "$ORDER_RESUME_WORKTREE" spec-380
mkdir -p "$ORDER_REPO/.git/implement-spec-split/claims"
printf '%s\n' '{"spec":370,"branch":"spec-370","worktree":"/tmp/order-370","pid":777,"pid_start":"fake alive","claimed_at":"2026-11-12T09:00:00+08:00"}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-370.json"
printf '%s\n' '{"spec":380,"branch":"spec-380","worktree":"/tmp/order-380","pid":778,"pid_start":"dead holder","claimed_at":"2026-11-12T09:05:00+08:00"}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-380.json"

WAVE_REPO=$WORK/workers-git-repo
mkdir -p "$WAVE_REPO"
git -C "$WAVE_REPO" init --quiet
git -C "$WAVE_REPO" config user.name 'Pipeline Status Workers Test'
git -C "$WAVE_REPO" config user.email 'pipeline-status-workers-test@example.invalid'
git -C "$WAVE_REPO" config commit.gpgsign false
printf '%s\n' 'workers repository' > "$WAVE_REPO/README.md"
git -C "$WAVE_REPO" add README.md
git -C "$WAVE_REPO" commit --quiet -m 'initial commit'

git -C "$EMPTY_REPO" init --quiet
git -C "$EMPTY_REPO" config user.name 'Pipeline Status Empty Wave Test'
git -C "$EMPTY_REPO" config user.email 'pipeline-status-empty-wave-test@example.invalid'
git -C "$EMPTY_REPO" config commit.gpgsign false
printf '%s\n' 'empty wave repository' > "$EMPTY_REPO/README.md"
git -C "$EMPTY_REPO" add README.md
git -C "$EMPTY_REPO" commit --quiet -m 'initial commit'
git -C "$EMPTY_REPO" branch spec-500
mkdir -p "$EMPTY_REPO/.git/implement-spec-split/claims"
printf '%s\n' '{"spec":500,"branch":"spec-500","worktree":"/tmp/order-500","pid":777,"pid_start":"fake alive","claimed_at":"2026-11-12T09:10:00+08:00"}' \
  > "$EMPTY_REPO/.git/implement-spec-split/claims/spec-500.json"

run_status() {
  cwd=$1
  output=$2
  shift 2
  (
    cd "$cwd" || exit 125
    env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_status "$REPO" "$WORK/main.out"
expect_exit 0 "fixture scan succeeds"
expect_without '开发顺序' 'without --order keeps pipeline output' "$WORK/main.out"
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
expect_has '地图缺规格' 'map specs section is shown by default' "$WORK/main.out"
expect_has '- #41 Map needing a spec → to-spec' 'map with only closed decisions needs a spec' "$WORK/main.out"
expect_section_without '地图缺规格' '#42 ' 'source-map reference covers whole map' "$WORK/main.out"
expect_section_without '地图缺规格' '#43 ' 'map reference covers whole map' "$WORK/main.out"
expect_has '#44 Map with open decision' 'map with an open decision stays in exploring' "$WORK/main.out"
expect_section_without '地图缺规格' '#44 ' 'open decision prevents a map-level spec' "$WORK/main.out"
expect_has '地图 #45 Map with open implementation' 'map with open implementation still uses missing' "$WORK/main.out"
expect_section_without '地图缺规格' '#45 ' 'open implementation prevents a map-level spec' "$WORK/main.out"
expect_section_without '地图缺规格' '#46 ' 'shelved map is not a spec candidate' "$WORK/main.out"

expect_without '#66 Implementation covered by closed spec → to-spec' 'closed spec coverage removes implementation from missing specs' "$WORK/main.out"
expect_has '#67 Implementation mentioned outside spec ticket line → to-spec' 'incidental map reference does not cover implementation' "$WORK/main.out"
expect_has '#69 Implementation mentioned before spec ticket phrase → to-spec' 'earlier reference on implementation line does not cover implementation' "$WORK/main.out"
expect_has '#96 Implementation narrated without separator → to-spec' 'implementation separator is required' "$WORK/main.out"
expect_without '#68 Implementation referenced with connector → to-spec' 'implementation ticket connector is recognized' "$WORK/main.out"
expect_has '#95 0/1' 'spec with connector reference is implementable' "$WORK/main.out"
expect_without '- #94 0/1 ' 'closed spec is not listed as implementable' "$WORK/main.out"
expect_without '#94 Closed single-ticket spec → to-tickets' 'closed spec is not listed as needing tickets' "$WORK/main.out"

expect_without '状态没收尾' 'default output omits hygiene section' "$WORK/main.out"
expect_without '散票' 'default output omits loose-issue section' "$WORK/main.out"
expect_without '  - #24 [wayfinder:grilling]' 'default output omits decision tickets' "$WORK/main.out"

run_status "$REPO" "$WORK/all.out" --all
expect_exit 0 "all fixture scan succeeds"
expect_has '- 规格 #99 Closed spec with unfinished children 已关闭，执行票还开着：#100 → 核对后关票' 'closed spec lists only open execution tickets' "$WORK/all.out"
expect_without '#102' 'closed execution ticket is not listed as unfinished' "$WORK/all.out"
expect_has '- 实现票 #66 Implementation covered by closed spec 的规格 #94 已关闭，票还开着 → 核对后关票' 'open implementation covered only by closed spec needs cleanup' "$WORK/all.out"
expect_has '- #121 [bug] Loose bug issue' 'labeled loose issue is formatted' "$WORK/all.out"
expect_has '- #122 Loose unlabeled issue' 'unlabeled loose issue is formatted' "$WORK/all.out"
expect_section_without '散票' '#57 ' 'map child is not loose' "$WORK/all.out"
expect_section_without '散票' '#81 ' 'spec child is not loose' "$WORK/all.out"
expect_section_without '散票' '#80 ' 'spec itself is not loose' "$WORK/all.out"
expect_section_without '散票' '#70 ' 'legacy parent is not loose' "$WORK/all.out"
expect_section_without '散票' '#71 ' 'legacy child is not loose' "$WORK/all.out"
expect_has '  - #24 [wayfinder:grilling] Open grilling decision（有未关阻塞）（已认领：allan）' 'decision ticket state is rendered' "$WORK/all.out"
expect_has '- #41 Map needing a spec → to-spec' 'all output includes map-level spec candidate' "$WORK/all.out"

run_order() {
  output=$1
  shift
  order_env=(
    FIXTURE_DIR="$ORDER_FIXTURE"
    PATH="$BIN:$PATH"
    ISS_PS_LSTART_CMD="$BIN/order-lstart"
  )
  if [ -n "${ORDER_NOW_EPOCH:-}" ]; then
    order_env+=("ISS_NOW_EPOCH=$ORDER_NOW_EPOCH")
  fi
  (
    cd "$ORDER_REPO" || exit 125
    env "${order_env[@]}" \
      bash "$SCRIPT" --repo test/repo --order "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_workers_order() {
  output=$1
  shift
  (
    cd "$WAVE_REPO" || exit 125
    env FIXTURE_DIR="$ORDER_FIXTURE" PATH="$BIN:$PATH" \
      ISS_PS_LSTART_CMD="$BIN/order-lstart" \
      bash "$SCRIPT" --repo test/repo --order "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_order "$WORK/order-apart.out" --parallel 5 --apart 300:390 --cmd-suffix ''
expect_exit 0 "order mode succeeds"
expect_has '开发顺序（同时 5 份）' 'order heading includes requested concurrency' "$WORK/order-apart.out"
expect_has '先恢复：#380' 'dead claim is marked for recovery' "$WORK/order-apart.out"
expect_has '进行中：#370（spec-370）' 'live claim is running and names its branch' "$WORK/order-apart.out"
expect_has ' 1. #300 Hub root → /implement-spec-split 300' 'spec with more idle downstream is first' "$WORK/order-apart.out"
expect_has ' 2. #420 Spec-owned blocker root → /implement-spec-split 420' 'spec-issue source with downstream specs is ordered early' "$WORK/order-apart.out"
expect_has ' 3. #330 Partial dependency → /implement-spec-split 330（部分等 #380；另需 #399）' 'partially blocked idle spec enters wave with annotations' "$WORK/order-apart.out"
expect_has ' 7. #390 Tie-break spec' 'apart conflict is deferred after wave' "$WORK/order-apart.out"
expect_has ' 6. #340 Complete dependency（等 #370）' 'fully blocked spec is numbered after wave' "$WORK/order-apart.out"
expect_has ' 8. #410 Blocked by needs tickets（等 #400）' 'needs-tickets dependency annotates but does not delay ordering' "$WORK/order-apart.out"
expect_has ' 4. #310 Downstream one（等 #300）' 'lower number breaks downstream tie' "$WORK/order-apart.out"
expect_has ' 9. #430 Blocked by spec issue（等 #420）' 'blocker by another spec issue number is a spec dependency' "$WORK/order-apart.out"
expect_has ' 10. #440 Blocked by implementation ref（等 #420）' 'blocker by a referenced implementation ticket is a spec dependency' "$WORK/order-apart.out"
expect_without '（另需 #420）' 'spec-owned blockers are not labeled as loose tickets' "$WORK/order-apart.out"
expect_section_without '之后' ' → /implement-spec-split' 'later entries omit commands' "$WORK/order-apart.out"
expect_has '循环依赖：#350 #360，需要人工决定' 'cyclic specs are listed separately' "$WORK/order-apart.out"
expect_without ' 6. #350' 'cyclic specs are not numbered' "$WORK/order-apart.out"
expect_without ' 1. #340 ' 'fully blocked spec does not enter first wave' "$WORK/order-apart.out"
expect_without ' 1. #430 ' 'spec-issue dependency does not enter first wave' "$WORK/order-apart.out"
expect_without ' 1. #440 ' 'implementation-ref dependency does not enter first wave' "$WORK/order-apart.out"

cat > "$WORK/order-apart.expected" <<'EOF'
开发顺序（同时 5 份）
先恢复：#380
进行中：#370（spec-370）
第 1 波：
 1. #300 Hub root → /implement-spec-split 300
 2. #420 Spec-owned blocker root → /implement-spec-split 420
 3. #330 Partial dependency → /implement-spec-split 330（部分等 #380；另需 #399）
之后：
 4. #310 Downstream one（等 #300）
 5. #320 Downstream two（等 #300）
 6. #340 Complete dependency（等 #370）
 7. #390 Tie-break spec
 8. #410 Blocked by needs tickets（等 #400）
 9. #430 Blocked by spec issue（等 #420）
 10. #440 Blocked by implementation ref（等 #420）
循环依赖：#350 #360，需要人工决定
EOF
expect_equal "$WORK/order-apart.out" "$WORK/order-apart.expected" 'order output exact and deterministic'

run_order "$WORK/order-apart-repeat.out" --parallel 5 --apart 300:390 --cmd-suffix ''
expect_equal "$WORK/order-apart-repeat.out" "$WORK/order-apart.out" 'same order inputs produce identical output'

run_order "$WORK/order-no-apart.out" --parallel 5
expect_exit 0 "order mode without apart succeeds"
expect_has ' 1. #300 Hub root → /implement-spec-split 300 --impl codex' 'default command suffix is appended' "$WORK/order-no-apart.out"
expect_without ' 2. #390 ' 'tie-break spec follows equal-score lower specs' "$WORK/order-no-apart.out"

run_workers_order "$WORK/order-workers-4.out" --parallel 2 --workers 4
expect_exit 0 "worker-aware order succeeds"
expect_has '开发顺序（同时 2 份，共 4 个 worker）' \
  'worker order heading includes total workers' "$WORK/order-workers-4.out"
expect_has ' 1. #300 Hub root → /implement-spec-split 300 --impl codex --parallel 2' \
  'worker order appends per-spec parallel' "$WORK/order-workers-4.out"

run_workers_order "$WORK/order-workers-4.json" --parallel 2 --workers 4 --json
expect_exit 0 "worker-aware JSON plan succeeds"

run_workers_order "$WORK/order-workers-5.out" --parallel 2 --workers 5
expect_exit 0 "worker total rounds down to per-spec parallel"
expect_has ' 1. #300 Hub root → /implement-spec-split 300 --impl codex --parallel 2' \
  'five workers still use parallel two' "$WORK/order-workers-5.out"

run_workers_order "$WORK/order-workers-1.out" --parallel 2 --workers 1
expect_exit 0 "worker total uses minimum per-spec parallel"
expect_has ' 1. #300 Hub root → /implement-spec-split 300 --impl codex --parallel 1' \
  'one worker uses parallel one' "$WORK/order-workers-1.out"

run_order "$WORK/order-capacity.out" --parallel 5 --apart 300:390
expect_exit 0 "order mode subtracts active and interrupted specs"
expect_has ' 1. #300 Hub root' 'first capacity slot selects hub root' "$WORK/order-capacity.out"
expect_has ' 2. #420 Spec-owned blocker root' 'second capacity slot selects another ready root' "$WORK/order-capacity.out"
expect_has ' 3. #330 Partial dependency' 'third capacity slot selects partial dependency' "$WORK/order-capacity.out"
expect_without ' 4. #390 Tie-break spec' 'capacity subtracts running and interrupted specs' "$WORK/order-capacity.out"
expect_has '之后：' 'remaining specs continue numbering after wave' "$WORK/order-capacity.out"

run_order "$WORK/order-default-capacity.out"
expect_exit 0 "default parallel is two"
expect_has '第 1 波：（无，先恢复上面的规格）' 'interrupted specs occupying capacity ask for recovery first' "$WORK/order-default-capacity.out"

run_order "$WORK/order-json-text.out" --parallel 5 --workers 4
expect_exit 0 "worker-aware text plan succeeds"
cat > "$WORK/order-json-text.expected" <<EOF
开发顺序（同时 5 份，共 4 个 worker）
先恢复：#380
进行中：#370（spec-370）
第 1 波：
 1. #300 Hub root → /implement-spec-split 300 --impl codex --parallel 1
 2. #420 Spec-owned blocker root → /implement-spec-split 420 --impl codex --parallel 1
 3. #330 Partial dependency → /implement-spec-split 330 --impl codex --parallel 1（部分等 #380；另需 #399）
之后：
 4. #310 Downstream one（等 #300）
 5. #320 Downstream two（等 #300）
 6. #340 Complete dependency（等 #370）
 7. #390 Tie-break spec
 8. #410 Blocked by needs tickets（等 #400）
 9. #430 Blocked by spec issue（等 #420）
 10. #440 Blocked by implementation ref（等 #420）
循环依赖：#350 #360，需要人工决定
EOF
expect_equal "$WORK/order-json-text.out" "$WORK/order-json-text.expected" \
  'worker-aware text order is deterministic'

run_order "$WORK/order-json.out" --parallel 5 --workers 4 --json
expect_exit 0 "order JSON mode succeeds"
ORDER_RESUME_WORKTREE="$ORDER_RESUME_WORKTREE" node - \
  "$WORK/order-json.out" > "$WORK/order-json-check.txt" <<'NODE'
const fs = require('fs');
const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expectedWorktree = fs.realpathSync(process.env.ORDER_RESUME_WORKTREE);
const assertions = [
  [plan.parallel_specs === 5, 'parallel_specs'],
  [plan.workers === 4, 'workers'],
  [plan.per_spec_parallel === 1, 'per_spec_parallel'],
  [plan.resume.length === 1 && plan.resume[0].spec === 380, 'resume spec'],
  [plan.resume[0].worktree === expectedWorktree, 'resume worktree from git metadata'],
  [plan.resume[0].command.endsWith('--parallel 1'), 'resume command'],
  [plan.active.length === 1 && plan.active[0].spec === 370 && plan.active[0].branch === 'spec-370', 'active spec'],
  [plan.wave1.map((item) => item.spec).join(',') === '300,420,330', 'wave order'],
  [plan.wave1.every((item) => item.command.endsWith('--parallel 1')), 'wave commands'],
  [plan.wave1[2].note === '部分等 #380；另需 #399', 'wave note'],
  [plan.later[0].index === 4 && plan.later[0].spec === 310 && plan.later[0].note === '等 #300', 'later order'],
  [plan.cycles.join(',') === '350,360', 'cycles'],
  [plan.standalone.join(',') === '399', 'standalone blockers'],
];
const failed = assertions.filter(([ok]) => !ok);
if (failed.length > 0) throw new Error(failed.map(([, name]) => name).join(','));
NODE
RUN_EXIT=$?
expect_exit 0 "order JSON matches text plan and worktree metadata"

run_order "$WORK/order-json-no-workers.out" --parallel 5 --json
expect_exit 0 "order JSON without workers succeeds"
node - "$WORK/order-json-no-workers.out" > "$WORK/order-json-no-workers-check.txt" <<'NODE'
const fs = require('fs');
const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (plan.workers !== null || plan.per_spec_parallel !== null) {
  throw new Error('workers must be null without --workers');
}
if (plan.wave1.some((item) => item.command.includes('--parallel'))) {
  throw new Error('commands must omit --parallel without --workers');
}
NODE
RUN_EXIT=$?
expect_exit 0 "order JSON without workers omits parallel command suffix"

printf '%s\n' '{"spec":370,"branch":"spec-370","worktree":"/tmp/order-370","pid":999,"pid_start":"dead holder","handoff":"fresh","handoff_until_epoch":2000}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-370.json"
printf '%s\n' '{"spec":390,"worktree":null,"handoff":"resume","handoff_until_epoch":2000}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-390.json"
printf '%s\n' '{"spec":420,"worktree":null,"handoff":"fresh","handoff_until_epoch":999}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-420.json"
ORDER_NOW_EPOCH=1000
run_order "$WORK/order-handoff.out" --parallel 5
expect_exit 0 "handoff reservation order succeeds"
expect_has '进行中：#370（spec-370） #390（spec-390）' \
  'live handoffs keep branch and reservation specs active' "$WORK/order-handoff.out"
expect_has ' 2. #420 Spec-owned blocker root' \
  'expired handoff reservation remains idle' "$WORK/order-handoff.out"
expect_without ' #390 Tie-break spec' 'live no-branch reservation is not launched' \
  "$WORK/order-handoff.out"
ORDER_NOW_EPOCH=
printf '%s\n' '{"spec":370,"branch":"spec-370","worktree":"/tmp/order-370","pid":777,"pid_start":"fake alive","claimed_at":"2026-11-12T09:00:00+08:00"}' \
  > "$ORDER_REPO/.git/implement-spec-split/claims/spec-370.json"
rm -f "$ORDER_REPO/.git/implement-spec-split/claims/spec-390.json" \
  "$ORDER_REPO/.git/implement-spec-split/claims/spec-420.json"

(
  cd "$ORDER_REPO" || exit 125
  env FIXTURE_DIR="$ORDER_FIXTURE" PATH="$BIN:$PATH" \
    ISS_PS_LSTART_CMD="$BIN/order-lstart-all" \
    bash "$SCRIPT" --repo test/repo --order --parallel 2
) > "$WORK/order-running-capacity.out" 2> "$WORK/order-running-capacity.err"
RUN_EXIT=$?
expect_exit 0 "all order holders alive succeeds"
expect_has '进行中：#370（spec-370） #380（spec-380）' 'both branch-holding specs are running with alive holders' "$WORK/order-running-capacity.out"
expect_has '第 1 波：（无，等进行中的规格合入）' 'running specs filling capacity ask user to wait' "$WORK/order-running-capacity.out"

(
  cd "$EMPTY_REPO" || exit 125
  env FIXTURE_DIR="$EMPTY_FIXTURE" PATH="$BIN:$PATH" \
    ISS_PS_LSTART_CMD="$BIN/order-lstart" \
    bash "$SCRIPT" --repo test/repo --order --parallel 2
) > "$WORK/order-blocked-capacity.out" 2> "$WORK/order-blocked-capacity.err"
RUN_EXIT=$?
expect_exit 0 "blocked-capacity order succeeds"
expect_has '第 1 波：（无，都在等前置规格合入）' 'available capacity with fully blocked candidates reports dependencies' "$WORK/order-blocked-capacity.out"
expect_has ' 1. #510 Idle blocked spec（等 #500）' 'direct spec blocker remains a dependency after source starts' "$WORK/order-blocked-capacity.out"

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
