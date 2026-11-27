#!/usr/bin/env bash
# Isolated tests for scripts/pipeline-status.sh. Generated mktemp directories
# are deliberately retained on both pass and failure, as safe debugging aids.
# orca is a fake outside PATH, named by ISS_ORCA (the one Orca replacement
# variable, read by scripts/lib-orca.sh); the `orca` on the tests' PATH refuses
# every call.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/pipeline-status.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pipeline-status-test.XXXXXX")
FIXTURE=$WORK/fixture
BIN=$WORK/bin
ORCA_BIN=$WORK/orca-bin
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

mkdir -p "$FIXTURE" "$BIN" "$ORCA_BIN" "$REPO" "$NOT_REPO" || exit 1

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
    updated_at: '2026-11-15T12:00:00Z',
  }, extras);
}

const issues = [
  issue(21, 'Exploration map', 'open', ['wayfinder:map'], '', sub(4, 0)),
  issue(22, 'Client map', 'closed', ['wayfinder:map'], '', sub(8, 6)),
  issue(31, 'Server map', 'closed', ['wayfinder:map'], '', sub(1, 0)),
  issue(41, 'Map needing a spec', 'open', ['wayfinder:map'], '状态：进行中', sub(2, 2)),
  issue(42, 'Map covered by source-map spec', 'open', ['wayfinder:map'], '', sub(2, 2)),
  issue(43, 'Map covered by map line', 'open', ['wayfinder:map'], '', sub(2, 2)),
  issue(44, 'Map with open decision', 'open', ['wayfinder:map'], '', sub(2, 1)),
  issue(45, 'Map with open implementation', 'open', ['wayfinder:map'], '', sub(2, 1)),
  issue(46, 'Shelved map（搁置）', 'open', ['wayfinder:map'], '状态：搁置', sub(1, 1)),
  issue(47, 'Fog map with comments only', 'open', ['wayfinder:map'], '## Not yet specified\n\n<!-- multi\nline comment -->\n\n## Out of scope\n\n<!-- comment -->', sub(2, 2)),
  issue(48, 'Fog map saying none', 'open', ['wayfinder:map'], '## Not yet specified\n\n无\n', sub(2, 2)),
  issue(49, 'Fog map saying listed none', 'open', ['wayfinder:map'], '## Not yet specified\n\n- 无\n', sub(2, 2)),
  issue(50, 'Fog map without section', 'open', ['wayfinder:map'], '## Destination\n\nDone.', sub(2, 2)),
  issue(51, 'Map with real fog', 'open', ['wayfinder:map'], '## Not yet specified\n\n数据导出后的归档策略还会受 #110 影响。\n', sub(2, 2)),
  issue(52, 'Map with fog beside comments', 'open', ['wayfinder:map'], '## Not yet specified\n\n<!-- old note -->\n迁移期间的双写回滚策略还没法提问。\n\n## Out of scope\n\n<!-- excluded -->', sub(2, 2)),
  issue(53, 'Empty map', 'open', ['wayfinder:map'], ''),
  issue(54, 'Closed empty map', 'closed', ['wayfinder:map'], ''),
  issue(55, 'Shelved empty map', 'open', ['wayfinder:map'], '状态：搁置'),
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
  issue(83, '【搁置】Own child three', 'open', [], ''),
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
  issue(115, 'Claim exactly at cutoff', 'open', ['wayfinder:grilling'], ''),
  issue(116, 'Stale claimed decision', 'open', ['wayfinder:research'], ''),
  issue(117, 'Fresh unclaimed decision', 'open', ['wayfinder:grilling'], ''),
  issue(118, 'Fresh claim with live session', 'open', ['wayfinder:grilling'], ''),
  issue(119, 'Fresh claim watched elsewhere', 'open', ['wayfinder:task'], ''),
  issue(140, 'Spec citing source map', 'closed', [], '## Problem Statement\n来源地图：#42（全部决策见其 Decisions so far 与 #2–#10）'),
  issue(141, 'Spec citing map line', 'closed', [], '## Problem Statement\n**地图: #43**'),
  issue(121, 'Loose bug issue', 'open', ['bug'], ''),
  issue(122, 'Loose unlabeled issue', 'open', [], ''),
  issue(123, 'Graduated fog ticket', 'open', ['needs-triage'], '来自已收尾的地图「Client map」(#22) 的迷雾区。\n\n时机：Claude Code 适配器跑通、真实使用一段时间后再开。'),
  issue(160, 'Spec with only a shelved ticket', 'open', [], '## Problem Statement\nOnly one open ticket remains, and it is shelved.', sub(3, 2)),
  issue(161, 'Closed shelved-spec ticket one', 'closed', [], ''),
  issue(162, 'Closed shelved-spec ticket two', 'closed', [], ''),
  issue(163, '【搁置】Only remaining ticket', 'open', [], ''),
  issue(195, 'Spec of a shelved map', 'open', [], '## Problem Statement\n地图: #46'),
];

const responses = {
  'sub-21': [
    issue(24, 'Open grilling decision', 'open', ['wayfinder:grilling'], '', sub(0), {
      issue_dependencies_summary: {blocked_by: 1, total_blocked_by: 1, blocking: 0, total_blocking: 0},
      assignees: [{login: 'allan'}],
      updated_at: '2026-11-12T11:59:59Z',
    }),
    issue(115, 'Claim exactly at cutoff', 'open', ['wayfinder:grilling'], '', sub(0), {
      assignees: [{login: 'allan'}],
      updated_at: '2026-11-12T12:00:00Z',
    }),
    issue(116, 'Stale claimed decision', 'open', ['wayfinder:research'], '', sub(0), {
      assignees: [{login: 'codex'}],
      updated_at: '2026-11-10T12:00:00Z',
    }),
    issue(117, 'Fresh unclaimed decision', 'open', ['wayfinder:grilling'], '', sub(0), {
      updated_at: '2026-11-15T12:00:00Z',
    }),
    issue(118, 'Fresh claim with live session', 'open', ['wayfinder:grilling'], '', sub(0), {
      assignees: [{login: 'allan'}],
      updated_at: '2026-11-15T10:00:00Z',
    }),
    issue(119, 'Fresh claim watched elsewhere', 'open', ['wayfinder:task'], '', sub(0), {
      assignees: [{login: 'allan'}],
      updated_at: '2026-11-15T10:00:00Z',
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
  'sub-47': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-48': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-49': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-50': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-51': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-52': [
    issue(110, 'Closed map decision A', 'closed', ['wayfinder:research'], ''),
    issue(111, 'Closed map decision B', 'closed', ['wayfinder:grilling'], ''),
  ],
  'sub-53': [],
  'sub-54': [],
  'sub-55': [],
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
    issue(83, '【搁置】Own child three', 'open', [], ''),
  ],
  'sub-160': [
    issue(161, 'Closed shelved-spec ticket one', 'closed', [], ''),
    issue(162, 'Closed shelved-spec ticket two', 'closed', [], ''),
    issue(163, '【搁置】Only remaining ticket', 'open', [], ''),
  ],
  'sub-94': [
    issue(190, 'Closed spec ticket', 'closed', [], ''),
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

# The fake orca lives outside PATH on purpose: pipeline-status.sh must reach
# Orca only through ISS_ORCA, never through an `orca` that happens to be on
# PATH. `terminal list` answers with the file FAKE_ORCA_TERMINALS names, or
# fails when FAKE_ORCA_FAIL is 1.
cat > "$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$ORCA_LOG"
case "${1:-} ${2:-}" in
  "terminal list")
    if [ "${FAKE_ORCA_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'fake orca: offline' >&2
      exit 1
    fi
    cat "$FAKE_ORCA_TERMINALS"
    exit $?
    ;;
esac
printf 'fake orca: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$ORCA_BIN/orca"

# Guard rail: this machine has a real `orca` on PATH. The one on the tests' PATH
# refuses every call, so a pipeline-status.sh that spawns orca itself fails here
# instead of quietly reading the real Orca.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_GUARD_LOG"
printf 'test-pipeline-status: orca on PATH was called instead of ISS_ORCA\n' >&2
exit 99
EOF
chmod +x "$BIN/orca"

git -C "$REPO" init --quiet
git -C "$REPO" config user.name 'Pipeline Status Test'
git -C "$REPO" config user.email 'pipeline-status-test@example.invalid'
git -C "$REPO" config commit.gpgsign false
printf '%s\n' 'test repository' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git -C "$REPO" branch spec-89
# A legacy spec-<n>-<suffix> branch only counts as taken while the main branch
# lacks its commits, so this one carries unlanded work of its own.
git -C "$REPO" checkout --quiet -b spec-80-old
printf '%s\n' 'legacy integration work' > "$REPO/legacy.txt"
git -C "$REPO" add legacy.txt
git -C "$REPO" commit --quiet -m 'legacy integration work'
git -C "$REPO" checkout --quiet -

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

LEFTOVER_FIXTURE=$WORK/leftover-fixture
LEFTOVER_REPO=$WORK/leftover-git-repo
mkdir -p "$LEFTOVER_FIXTURE" "$LEFTOVER_REPO" || exit 1

LEFTOVER_FIXTURE=$LEFTOVER_FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.LEFTOVER_FIXTURE;

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

function spec(number, title) {
  return issue(number, title, 'open', [], '## Problem Statement\nLeftover fixture.', sub(1, 0));
}

const issues = [
  spec(600, 'Merged leftover spec'),
  issue(601, 'Merged leftover ticket', 'open', [], ''),
  spec(610, 'Unmerged leftover spec'),
  issue(611, 'Unmerged leftover ticket', 'open', [], ''),
  spec(620, 'Mixed leftover spec'),
  issue(621, 'Mixed leftover ticket', 'open', [], ''),
  spec(630, 'Landed exact branch spec'),
  issue(631, 'Landed exact branch ticket', 'open', [], ''),
];

const responses = {
  'sub-600': [issues[1]],
  'sub-610': [issues[3]],
  'sub-620': [issues[5]],
  'sub-630': [issues[7]],
  'blocker-601': [issues[3]],
  'blocker-611': [],
  'blocker-621': [],
  'blocker-631': [],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}
NODE

git -C "$LEFTOVER_REPO" init --quiet -b main
git -C "$LEFTOVER_REPO" config user.name 'Pipeline Status Leftover Test'
git -C "$LEFTOVER_REPO" config user.email 'pipeline-status-leftover-test@example.invalid'
git -C "$LEFTOVER_REPO" config commit.gpgsign false
printf '%s\n' 'leftover repository' > "$LEFTOVER_REPO/README.md"
git -C "$LEFTOVER_REPO" add README.md
git -C "$LEFTOVER_REPO" commit --quiet -m 'initial commit'
leftover_branch() {
  git -C "$LEFTOVER_REPO" checkout --quiet -b "$1" main
  printf '%s\n' "$1 work" > "$LEFTOVER_REPO/$1.txt"
  git -C "$LEFTOVER_REPO" add "$1.txt"
  git -C "$LEFTOVER_REPO" commit --quiet -m "$1 work"
  git -C "$LEFTOVER_REPO" checkout --quiet main
}
leftover_land() {
  git -C "$LEFTOVER_REPO" merge --quiet --no-ff -m "merge $1" "$1"
}
# Ticket branches stay behind after their work lands. #600 has only landed ones,
# no spec-600 and no claim, so nothing is in flight; #610 and #620 hold unlanded
# ticket work (#620's landed branch sorts first) and #630 the landed exact
# integration branch.
leftover_branch spec-600-t1
leftover_land spec-600-t1
leftover_branch spec-600-t2
leftover_land spec-600-t2
leftover_branch spec-610-t1
leftover_branch spec-620-t1
leftover_land spec-620-t1
leftover_branch spec-620-t2
leftover_branch spec-630
leftover_land spec-630

# Live Orca terminals for orphan-claim checks: #118 is named by an agent in this
# repository; #119 only by an agent in another repository; "#1150" must not
# count as #115; a plain shell and a disconnected agent naming #115 do not count.
REPO_REAL=$(cd "$REPO" && pwd -P)
cat > "$WORK/orca-terminals.json" <<JSON
{"ok": true, "result": {"terminals": [
  {"worktreePath": "$REPO_REAL", "title": "/wayfinder 21 #118", "preview": "", "connected": true, "orphaned": false, "agentIdentity": "claude"},
  {"worktreePath": "/elsewhere/other-repo", "title": "#119 task", "preview": "", "connected": true, "orphaned": false, "agentIdentity": "claude"},
  {"worktreePath": "$REPO_REAL", "title": "spec #1150", "preview": "", "connected": true, "orphaned": false, "agentIdentity": "codex"},
  {"worktreePath": "$REPO_REAL", "title": "#115 shell", "preview": "", "connected": true, "orphaned": false},
  {"worktreePath": "$REPO_REAL", "title": "#115 gone", "preview": "", "connected": false, "orphaned": false, "agentIdentity": "claude"}
]}}
JSON
printf '%s\n' 'not json' > "$WORK/orca-broken.json"
ORCA_TERMINALS=$WORK/orca-terminals.json

ORCA_LOG=$WORK/orca.log
ORCA_GUARD_LOG=$WORK/orca-guard.log
: > "$ORCA_GUARD_LOG"

run_status() {
  cwd=$1
  output=$2
  shift 2
  status_env=(
    FIXTURE_DIR="$FIXTURE"
    PATH="$BIN:$PATH"
    PIPELINE_STATUS_NOW=2026-11-15T12:00:00Z
    ISS_ORCA="$ORCA_BIN/orca"
    ORCA_LOG="$ORCA_LOG" ORCA_GUARD_LOG="$ORCA_GUARD_LOG"
    FAKE_ORCA_TERMINALS="$ORCA_TERMINALS"
  )
  # By default the script reads the terminal list from the fixture file. A case
  # that sets ORCA_FIXTURE_UNSET=1 leaves that seam alone, so the script asks
  # Orca itself, through the library, and the fake answers with the same file.
  if [ "${ORCA_FIXTURE_UNSET:-0}" != 1 ]; then
    status_env+=("PIPELINE_STATUS_ORCA_TERMINALS_JSON=$ORCA_TERMINALS")
  fi
  (
    cd "$cwd" || exit 125
    env "${status_env[@]}" \
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
expect_has '地图迷雾待毕业' 'map fog section is shown by default' "$WORK/main.out"
expect_has '- #47 Fog map with comments only → to-spec' 'comment-only map fog is empty' "$WORK/main.out"
expect_has '- #48 Fog map saying none → to-spec' 'none placeholder map fog is empty' "$WORK/main.out"
expect_has '- #49 Fog map saying listed none → to-spec' 'listed none placeholder map fog is empty' "$WORK/main.out"
expect_has '- #50 Fog map without section → to-spec' 'missing fog section is empty' "$WORK/main.out"
expect_has '- #51 Map with real fog → /find-next --batch 51' 'map with real fog needs graduation' "$WORK/main.out"
expect_has '- #52 Map with fog beside comments → /find-next --batch 52' 'mixed comments and fog count as fog' "$WORK/main.out"
expect_section_without '地图缺规格' '#51 ' 'foggy map does not become a map-level spec' "$WORK/main.out"
expect_section_without '地图迷雾待毕业' '#47 ' 'comment-only fog map is not a fog candidate' "$WORK/main.out"
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
expect_has '[票：#81 #82 #83(搁置)]' 'mixed spec marks shelved execution ticket' "$WORK/main.out"
expect_without '- #160 ' 'spec with only shelved open tickets is not implementable' "$WORK/main.out"

expect_without '状态没收尾' 'default output omits hygiene section' "$WORK/main.out"
expect_without '散票' 'default output omits loose-issue section' "$WORK/main.out"
expect_without '  - #24 [wayfinder:grilling]' 'default output omits decision tickets' "$WORK/main.out"
expect_without '空地图（待 /wayfinder 画图）' 'default output omits empty maps' "$WORK/main.out"
expect_without '认领后不动（>3 天）' 'default output omits stale claims' "$WORK/main.out"

run_status "$REPO" "$WORK/all.out" --all
expect_exit 0 "all fixture scan succeeds"
expect_has '- 规格 #99 Closed spec with unfinished children 已关闭，执行票还开着：#100 → 核对后关票' 'closed spec lists only open execution tickets' "$WORK/all.out"
expect_without '#102' 'closed execution ticket is not listed as unfinished' "$WORK/all.out"
expect_has '- 实现票 #66 Implementation covered by closed spec 的规格 #94 已关闭，票还开着 → 核对后关票' 'open implementation covered only by closed spec needs cleanup' "$WORK/all.out"
expect_has '- #121 [bug] Loose bug issue' 'labeled loose issue is formatted' "$WORK/all.out"
expect_has '- #122 Loose unlabeled issue' 'unlabeled loose issue is formatted' "$WORK/all.out"
expect_has '- #123 [needs-triage] Graduated fog ticket（来自地图 #22；时机：Claude Code 适配器跑通、真实使用一段时间后再开。）' \
  'loose issue includes source map and timing' "$WORK/all.out"
expect_has '- 规格 #160 Spec with only a shelved ticket：未关执行票只剩搁置票 #163，可关闭规格（核对后由用户确认）' \
  'shelved-only spec is hygiene rather than implementable' "$WORK/all.out"
expect_section_without '散票' '#57 ' 'map child is not loose' "$WORK/all.out"
expect_section_without '散票' '#81 ' 'spec child is not loose' "$WORK/all.out"
expect_section_without '散票' '#80 ' 'spec itself is not loose' "$WORK/all.out"
expect_section_without '散票' '#70 ' 'legacy parent is not loose' "$WORK/all.out"
expect_section_without '散票' '#71 ' 'legacy child is not loose' "$WORK/all.out"
expect_has '  - #24 [wayfinder:grilling] Open grilling decision（有未关阻塞）（已认领：allan）' 'decision ticket state is rendered' "$WORK/all.out"
expect_has '- #41 Map needing a spec → to-spec' 'all output includes map-level spec candidate' "$WORK/all.out"
expect_has '空地图（待 /wayfinder 画图）' 'all output includes empty-map heading' "$WORK/all.out"
expect_has '- #53 Empty map → /wayfinder 53' 'open childless map needs charting' "$WORK/all.out"
expect_section_without '空地图（待 /wayfinder 画图）' '#54 ' 'closed empty map is not listed' "$WORK/all.out"
expect_section_without '空地图（待 /wayfinder 画图）' '#55 ' 'shelved empty map is not listed' "$WORK/all.out"
expect_has '认领后不动（>3 天）' 'all output includes stale-claim heading' "$WORK/all.out"
expect_has '- #24 [wayfinder:grilling] Open grilling decision（地图 #21，已认领：allan，更新于 2026-11-12T11:59:59Z）' 'older claimed decision is stale' "$WORK/all.out"
expect_has '- #116 [wayfinder:research] Stale claimed decision（地图 #21，已认领：codex，更新于 2026-11-10T12:00:00Z）' 'multi-day claimed decision is stale' "$WORK/all.out"
expect_section_without '认领后不动（>3 天）' '#115 ' 'claim at exact three-day cutoff is not stale' "$WORK/all.out"
expect_section_without '认领后不动（>3 天）' '#117 ' 'unclaimed decision is not stale' "$WORK/all.out"
expect_has '认领但没有活会话' 'all output includes orphan-claim heading' "$WORK/all.out"
expect_has '- #115 [wayfinder:grilling] Claim exactly at cutoff（地图 #21，已认领：allan，更新于 2026-11-12T12:00:00Z，Orca 里没有提到它的活会话）' \
  'fresh claim named only by #1150, a shell and a disconnected agent is orphaned' "$WORK/all.out"
expect_has '- #119 [wayfinder:task] Fresh claim watched elsewhere（地图 #21' 'claim named only in another repository is orphaned' "$WORK/all.out"
expect_section_without '认领但没有活会话' '#118 ' 'claim named by a live local agent is not orphaned' "$WORK/all.out"
expect_section_without '认领但没有活会话' '#116 ' 'stale claim is not repeated as orphaned' "$WORK/all.out"
expect_section_without '认领但没有活会话' '#117 ' 'unclaimed decision is not orphaned' "$WORK/all.out"
expect_without '认领但没有活会话' 'default output omits orphan claims' "$WORK/main.out"

ORCA_TERMINALS=$WORK/orca-broken.json
run_status "$REPO" "$WORK/all-no-orca.out" --all
ORCA_TERMINALS=$WORK/orca-terminals.json
expect_exit 0 "scan succeeds when Orca output is unusable"
expect_has '（Orca 不可用，未判断）' 'unusable Orca leaves orphan claims unchecked' "$WORK/all-no-orca.out"
expect_has '- #116 [wayfinder:research] Stale claimed decision' 'stale claims still listed without Orca' "$WORK/all-no-orca.out"

# Without the fixture file the script asks Orca itself. Orca is reached through
# scripts/lib-orca.sh: the program ISS_ORCA names gets `terminal list --json`
# and nothing else, and the orca on PATH is never touched.
ORCA_FIXTURE_UNSET=1
export ORCA_FIXTURE_UNSET
: > "$ORCA_LOG"
run_status "$REPO" "$WORK/all-orca.out" --all
expect_exit 0 "all fixture scan succeeds with Orca asked for the terminals"
expect_has '- #115 [wayfinder:grilling] Claim exactly at cutoff（地图 #21，已认领：allan，更新于 2026-11-12T12:00:00Z，Orca 里没有提到它的活会话）' \
  'terminals from Orca orphan a claim no live agent names' "$WORK/all-orca.out"
expect_has '- #119 [wayfinder:task] Fresh claim watched elsewhere（地图 #21' \
  'terminals from Orca orphan a claim named only in another repository' "$WORK/all-orca.out"
expect_section_without '认领但没有活会话' '#118 ' \
  'terminals from Orca keep a claim named by a live local agent' "$WORK/all-orca.out"
expect_section_without '认领但没有活会话' '（Orca 不可用' \
  'an Orca asked through the library counts as available' "$WORK/all-orca.out"
if [ "$(cat "$ORCA_LOG")" = 'terminal list --json' ]; then
  record PASS 'the program ISS_ORCA names gets terminal list --json, once'
else
  record FAIL 'the program ISS_ORCA names gets terminal list --json, once' \
    "got [$(tr '\n' '|' < "$ORCA_LOG")]"
fi
if [ -s "$ORCA_GUARD_LOG" ]; then
  record FAIL 'Orca is never the orca on PATH' "$(cat "$ORCA_GUARD_LOG")"
else
  record PASS 'Orca is never the orca on PATH'
fi

FAKE_ORCA_FAIL=1
export FAKE_ORCA_FAIL
: > "$ORCA_LOG"
run_status "$REPO" "$WORK/all-orca-down.out" --all
unset FAKE_ORCA_FAIL
expect_exit 0 "scan succeeds when the Orca call fails"
expect_has '（Orca 不可用，未判断）' 'a failing Orca leaves orphan claims unchecked' "$WORK/all-orca-down.out"
expect_has '- #116 [wayfinder:research] Stale claimed decision' \
  'stale claims still listed when the Orca call fails' "$WORK/all-orca-down.out"
expect_has 'terminal list --json' 'the failing Orca was asked' "$ORCA_LOG"

ORCA_TERMINALS=$WORK/orca-broken.json
run_status "$REPO" "$WORK/all-orca-broken.out" --all
ORCA_TERMINALS=$WORK/orca-terminals.json
expect_exit 0 "scan succeeds when what Orca prints is unusable"
expect_has '（Orca 不可用，未判断）' 'unusable Orca output leaves orphan claims unchecked' \
  "$WORK/all-orca-broken.out"

# The default output has no orphan-claim section, so Orca is not asked at all.
: > "$ORCA_LOG"
run_status "$REPO" "$WORK/main-orca.out"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'without --all Orca is not asked for terminals' "$(cat "$ORCA_LOG")"
else
  record PASS 'without --all Orca is not asked for terminals'
fi
unset ORCA_FIXTURE_UNSET

run_status "$REPO" "$WORK/order-shelved.out" --order --parallel 20 --cmd-suffix ''
expect_exit 0 "development order excludes shelved-only spec"
expect_without '#160' 'shelved-only spec is absent from order' "$WORK/order-shelved.out"

run_status "$REPO" "$WORK/order-shelved.json" --order --parallel 20 --json
expect_exit 0 "development-order JSON excludes shelved-only spec"
node - "$WORK/order-shelved.json" > "$WORK/order-shelved-check.txt" <<'NODE'
const fs = require('fs');
const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const numbers = [
  ...plan.resume.map((item) => item.spec),
  ...plan.active.map((item) => item.spec),
  ...plan.wave1.map((item) => item.spec),
  ...plan.later.map((item) => item.spec),
];
if (numbers.includes(160)) throw new Error('shelved-only spec entered the order');
NODE
RUN_EXIT=$?
expect_exit 0 "order JSON has no shelved-only spec entries"

mkdir -p "$REPO/.git/implement-spec-split/claims"
printf '%s\n' '{"spec":88,"worktree":null,"handoff":"fresh","handoff_until_epoch":9999999999}' \
  > "$REPO/.git/implement-spec-split/claims/spec-88.json"
printf '%s\n' '{"spec":95,"worktree":null,"handoff":"fresh","handoff_until_epoch":1794743900}' \
  > "$REPO/.git/implement-spec-split/claims/spec-95.json"

run_status "$REPO" "$WORK/graph.json" --graph
expect_exit 0 "graph scan succeeds"
run_status "$REPO" "$WORK/graph-order.json" --order --json
expect_exit 0 "order JSON for graph comparison succeeds"
expect_without 'next_wave' 'plain order JSON is unchanged by --graph' "$WORK/graph-order.json"
node - "$WORK/graph.json" "$WORK/graph-order.json" > "$WORK/graph-check.txt" 2>&1 <<'NODE'
const fs = require('fs');
const assert = require('assert');
const graph = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const order = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
// Expected values are hand-counted from the fixture, not recomputed.
assert.deepStrictEqual(graph.counts.maps, {
  total: 18, closed: 3, shelved: 2, empty: 1, exploring: 2, fog_pending: 2, unconverted: 5,
});
assert.deepStrictEqual(graph.counts.specs, {
  total: 13, landed: 4, needs_tickets: 3, ready: 2, running: 1, interrupted: 2, shelved: 1,
});
assert.deepStrictEqual(graph.counts.tickets, {total: 24, closed: 6});
const map = (n) => graph.maps.find((item) => item.number === n);
const spec = (n) => graph.specs.find((item) => item.number === n);
assert.strictEqual(map(22).status, 'closed');
assert.strictEqual(map(46).status, 'shelved');
assert.strictEqual(map(51).status, 'fog_pending');
assert.strictEqual(map(51).has_fog, true);
assert.strictEqual(map(44).status, 'exploring');
assert.strictEqual(map(41).status, 'unconverted');
assert.strictEqual(map(42).status, 'converted');
assert.deepStrictEqual(map(42).spec_numbers, [140]);
assert.deepStrictEqual(map(46).spec_numbers, [195]);
assert.deepStrictEqual(map(22).tickets.map((t) => t.number), [57, 58, 59]);
assert.strictEqual(map(21).decisions_open, 6);
assert.strictEqual(spec(140).map, 42);
assert.strictEqual(spec(140).status, 'landed');
assert.strictEqual(spec(195).map, 46);
assert.strictEqual(spec(89).map, null);
assert.strictEqual(spec(89).status, 'interrupted');
assert.strictEqual(spec(89).claim.branch, 'spec-89');
assert.strictEqual(spec(88).status, 'running');
assert.strictEqual(spec(88).claim.state, 'reserved');
assert.strictEqual(spec(93).status, 'needs_tickets');
assert.strictEqual(spec(93).has_tickets, false);
assert.strictEqual(spec(93).claim, null);
assert.strictEqual(spec(88).claim.branch, 'spec-88');
assert.strictEqual(spec(95).status, 'ready');
assert.strictEqual(spec(95).claim.state, 'idle');
assert.notStrictEqual(spec(95).claim.state, 'reserved');
assert.strictEqual(spec(160).status, 'shelved');
assert.strictEqual(spec(94).status, 'landed');
assert.deepStrictEqual(spec(94).tickets.map((t) => [t.number, t.state]), [[190, 'closed']]);
assert.deepStrictEqual(spec(99).tickets.map((t) => t.number), [100, 102]);
assert.deepStrictEqual(spec(89).tickets.map((t) => t.number), [90, 91, 92]);
assert.strictEqual(spec(89).tickets_closed, 1);
assert.strictEqual(spec(70).kind, 'legacy');
assert.deepStrictEqual(graph.loose_specs, [70, 80, 88, 89, 93, 94, 95, 97, 99, 160]);
assert.deepStrictEqual(graph.next_wave, order);
NODE
RUN_EXIT=$?
expect_exit 0 "graph counts, relations and wave 1 match hand-counted fixture"
[ "$RUN_EXIT" -eq 0 ] || cat "$WORK/graph-check.txt"
rm -f "$REPO/.git/implement-spec-split/claims/spec-88.json" \
  "$REPO/.git/implement-spec-split/claims/spec-95.json"
run_status "$REPO" "$WORK/help.out" --help
expect_has '--graph' 'help documents --graph' "$WORK/help.out"
expect_has 'PIPELINE_STATUS_ORCA_TERMINALS_JSON' 'help documents the terminal-list fixture file' "$WORK/help.out"
expect_without 'PIPELINE_STATUS_ORCA may' 'help no longer documents a per-script Orca executable' "$WORK/help.out"
run_status "$REPO" "$WORK/graph-order.out" --order --parallel 20 --cmd-suffix ''
expect_exit 0 "order text output still works with graph fixtures"

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

# An --apart pair whose other side is in flight (running, or interrupted and
# resumed first) holds its idle side out of the new wave: a running or resumed
# Spec runs beside the new wave, so "not in the same wave" alone would not keep
# the two apart. #370 is running and #380 is to be resumed first in this fixture.
run_order "$WORK/order-apart-control.out" --parallel 8 --cmd-suffix ''
expect_has ' 4. #390 Tie-break spec → /implement-spec-split 390' \
  'without a pair the tie-break spec fits wave 1 at parallel eight' "$WORK/order-apart-control.out"

run_order "$WORK/order-apart-inflight.out" --parallel 8 --apart 370:390 --cmd-suffix ''
expect_exit 0 "order mode with an in-flight apart pair succeeds"
expect_without '#390 Tie-break spec →' \
  'apart pair with a running spec keeps the other side out of wave 1' "$WORK/order-apart-inflight.out"
expect_has ' 7. #390 Tie-break spec' 'spec held by a running apart side is listed under 之后' \
  "$WORK/order-apart-inflight.out"

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
  // Windows realpath uses backslashes, git metadata uses forward slashes.
  [String(plan.resume[0].worktree).replace(/\\/g, '/') === expectedWorktree.replace(/\\/g, '/'), 'resume worktree from git metadata'],
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

run_leftover_status() {
  output=$1
  shift
  (
    cd "$LEFTOVER_REPO" || exit 125
    env FIXTURE_DIR="$LEFTOVER_FIXTURE" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_leftover_status "$WORK/leftover.out" --all
expect_exit 0 "leftover branch scan succeeds"
expect_has '- #600 0/1 空闲；被卡住：#611 Merged leftover spec' \
  'merged leftover ticket branches leave the spec idle' "$WORK/leftover.out"
expect_has '- #610 0/1 已接手（分支 spec-610-t1，最后提交 ' \
  'unmerged leftover ticket branch keeps the spec taken' "$WORK/leftover.out"
expect_has '- #620 0/1 已接手（分支 spec-620-t2，最后提交 ' \
  'merged leftover branch is skipped for the unmerged one' "$WORK/leftover.out"
expect_has '- #630 0/1 已接手（分支 spec-630，最后提交 ' \
  'landed exact integration branch still counts as taken' "$WORK/leftover.out"

run_leftover_status "$WORK/leftover-order.out" --order --parallel 20
expect_exit 0 "leftover branch order succeeds"
expect_has '先恢复：#610 #620 #630' \
  'only specs holding unlanded work are listed for recovery' "$WORK/leftover-order.out"
expect_has ' 1. #600 Merged leftover spec（等 #610）' \
  'merged leftover spec is ordered as idle instead of resumed' "$WORK/leftover-order.out"

git -C "$LEFTOVER_REPO" update-ref refs/remotes/origin/main main
git -C "$LEFTOVER_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run_leftover_status "$WORK/leftover-origin.out" --all
expect_exit 0 "leftover branch scan succeeds through origin/HEAD"
expect_has '- #600 0/1 空闲；被卡住：#611 Merged leftover spec' \
  'merged leftovers are judged against origin/HEAD' "$WORK/leftover-origin.out"

# Without a main branch to compare against the old rule stands: a leftover
# branch keeps the Spec taken.
git -C "$LEFTOVER_REPO" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$LEFTOVER_REPO" update-ref -d refs/remotes/origin/main
git -C "$LEFTOVER_REPO" branch --quiet -m main master
run_leftover_status "$WORK/leftover-no-main.out" --all
expect_exit 0 "leftover branch scan succeeds without a main branch"
expect_has '- #600 0/1 已接手（分支 spec-600-t1，最后提交 ' \
  'leftover branch keeps the spec taken without a main branch' "$WORK/leftover-no-main.out"

run_status "$NOT_REPO" "$WORK/not-repo.out"
expect_exit 0 "outside a git repository still scans issues"
expect_has '未知（不在 git 仓库）' 'branch state is unknown outside git' "$WORK/not-repo.out"

# A `ready-for-human` execution ticket is never waiting for an implementer:
# like a shelved ticket it stays out of 可以实现, the order and the waves, but
# unlike a shelved one --all must say a human still has to do it.
HUMAN_FIXTURE=$WORK/human-fixture
mkdir -p "$HUMAN_FIXTURE" || exit 1

HUMAN_FIXTURE=$HUMAN_FIXTURE node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.HUMAN_FIXTURE;

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
  issue(600, 'Mixed human spec', 'open', [], '## Problem Statement\nMixed.', sub(2, 0)),
  issue(601, 'Ready ticket', 'open', []),
  issue(602, 'Human ticket', 'open', ['ready-for-human']),
  issue(610, 'Human-only spec', 'open', [], '## Problem Statement\nHuman only.', sub(1, 0)),
  issue(611, 'Only human ticket', 'open', ['ready-for-human']),
  issue(620, 'Closed plus human spec', 'open', [], '## Problem Statement\nClosed plus human.', sub(2, 1)),
  issue(621, 'Done ticket', 'closed', []),
  issue(622, 'Remaining human ticket', 'open', ['ready-for-human']),
  issue(630, 'Legacy human spec', 'open', [], 'Old parent shape', sub(1, 0)),
  issue(631, 'Legacy human ticket', 'open', ['ready-for-human']),
];

const responses = {
  'sub-600': [issues[1], issues[2]],
  'sub-610': [issues[4]],
  'sub-620': [issues[6], issues[7]],
  'sub-630': [issues[9]],
  'blocker-601': [],
  'blocker-602': [],
  'blocker-611': [],
  'blocker-622': [],
  'blocker-631': [],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}
NODE

run_human_status() {
  output=$1
  shift
  (
    cd "$REPO" || exit 125
    env FIXTURE_DIR="$HUMAN_FIXTURE" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_human_status "$WORK/human.out" --all
expect_exit 0 "human-ticket scan succeeds"
expect_has '- #600 0/2' 'mixed spec with a human ticket is still implementable' "$WORK/human.out"
expect_has '[票：#601 #602(人工)]' 'human execution ticket is marked (人工)' "$WORK/human.out"
expect_section_without '可以实现' '#610' 'human-only spec is not implementable' "$WORK/human.out"
expect_section_without '可以实现' '#620' 'spec with only a human ticket left is not implementable' "$WORK/human.out"
expect_has '- 规格 #610 Human-only spec：人工票待做：#611' \
  'human-only spec is reported under 状态没收尾' "$WORK/human.out"
expect_has '- 规格 #620 Closed plus human spec：人工票待做：#622' \
  'spec whose last open ticket is human is reported under 状态没收尾' "$WORK/human.out"
expect_has '- 规格 #630 Legacy human spec：人工票待做：#631' \
  'legacy spec with only a human ticket is reported under 状态没收尾' "$WORK/human.out"

run_human_status "$WORK/human-order.out" --order --parallel 20
expect_exit 0 "human-ticket order succeeds"
expect_without '#610' 'human-only spec is absent from the order' "$WORK/human-order.out"
expect_without '#620' 'spec with only a human ticket left is absent from the order' "$WORK/human-order.out"

run_human_status "$WORK/human-order.json" --order --parallel 20 --json
expect_exit 0 "human-ticket order JSON succeeds"
node - "$WORK/human-order.json" > "$WORK/human-order-check.txt" 2>&1 <<'NODE'
const fs = require('fs');
const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const numbers = [
  ...plan.resume.map((item) => item.spec),
  ...plan.active.map((item) => item.spec),
  ...plan.wave1.map((item) => item.spec),
  ...plan.later.map((item) => item.spec),
];
if (!numbers.includes(600)) throw new Error('mixed spec with a human ticket left the order');
for (const number of [610, 620]) {
  if (numbers.includes(number)) throw new Error(`human-only spec ${number} entered the order`);
}
NODE
RUN_EXIT=$?
expect_exit 0 "order JSON keeps the mixed spec and drops the human-only specs"

run_human_status "$WORK/human-graph.json" --graph
expect_exit 0 "human-ticket graph succeeds"
node - "$WORK/human-graph.json" > "$WORK/human-graph-check.txt" 2>&1 <<'NODE'
const fs = require('fs');
const assert = require('assert');
const graph = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const spec = (n) => graph.specs.find((item) => item.number === n);
assert.strictEqual(spec(600).status, 'ready');
assert.strictEqual(spec(610).status, 'human');
assert.strictEqual(spec(620).status, 'human');
assert.strictEqual(spec(610).human_only, true);
assert.strictEqual(spec(600).human_only, false);
assert.strictEqual(spec(630).status, 'human');
assert.strictEqual(spec(630).kind, 'legacy');
assert.strictEqual(spec(600).tickets.find((t) => t.number === 602).human, true);
assert.strictEqual(spec(600).tickets.find((t) => t.number === 601).human, false);
assert.deepStrictEqual(spec(610).tickets.map((t) => [t.number, t.human]), [[611, true]]);
NODE
RUN_EXIT=$?
expect_exit 0 "graph marks human-only specs and human tickets"

(
  cd "$REPO" || exit 125
  env FIXTURE_DIR="$FIXTURE" FAKE_GH_FAIL=1 PATH="$BIN:$PATH" \
    bash "$SCRIPT" --repo test/repo
) > "$WORK/gh-failure.out" 2> "$WORK/gh-failure.err"
RUN_EXIT=$?
expect_exit 1 "gh failure exits nonzero"
expect_has 'gh api failed while listing issues' 'gh failure names the failing stage' "$WORK/gh-failure.err"

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
