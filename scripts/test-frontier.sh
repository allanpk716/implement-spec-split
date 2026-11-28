#!/usr/bin/env bash
# Deterministic tests for scripts/frontier.sh. They run the real
# pipeline-status.sh against a fake gh, so the Spec-to-Ticket resolution, the
# blocked_by queries, the tickets that are never in the frontier (blocked,
# `ready-for-human`, shelved, the loose source ticket of 票 #83, and the Ticket
# without `ready-for-agent` of 票 #86) and the two ways the script fails closed
# (票 #86: exit 1 for a query that failed, exit 3 for a Spec the graph does not
# hold) are covered end to end without network access.

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

expect_output() { # expected-file actual-file name — byte for byte
  if cmp -s "$1" "$2"; then
    record PASS "$3"
  else
    record FAIL "$3" "$(diff "$1" "$2")"
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

FIXTURE=$FIXTURE WORK=$WORK node > /dev/null <<'NODE'
const fs = require('fs');
const directory = process.env.FIXTURE;
const work = process.env.WORK;

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

// An execution Ticket carries `ready-for-agent` (票 #86): an open Ticket
// without that label waits for a person's triage and is never in the frontier.
const ready = ['ready-for-agent'];
const counter = ['ready-for-agent', 'shared-counter'];

const readyTickets = [
  issue(12, 'Ready ticket', 'open', ready),
  issue(13, 'Ready after closed blocker', 'open', ready),
];
const openBlocker = issue(20, 'Open blocker', 'open', []);
const closedBlocker = issue(21, 'Closed blocker', 'closed', []);

const issues = [
  issue(10, 'Test spec', 'open', [], '## Problem Statement\nTest spec.', sub(5, 0)),
  issue(11, 'Blocked ticket', 'open', ready),
  ...readyTickets,
  issue(14, '【搁置】Shelved ticket', 'open', ready),
  issue(15, 'Human ticket', 'open', ['ready-for-human']),
  openBlocker,
  closedBlocker,
];

const responses = {
  'sub-10': [
    issue(11, 'Blocked ticket', 'open', ready),
    ...readyTickets,
    issue(14, '【搁置】Shelved ticket', 'open', ready),
    issue(15, 'Human ticket', 'open', ['ready-for-human']),
  ],
  'blocker-11': [openBlocker, closedBlocker],
  'blocker-12': [],
  'blocker-13': [closedBlocker],
  'blocker-14': [openBlocker],
  'blocker-15': [],
};

fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
for (const [name, value] of Object.entries(responses)) {
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value, null, 2));
}

// One fixture directory per scenario, run by run_scenario below.
const scenarios = {
  // Three `shared-counter` tickets with no blocker: only #16 is released, #17 and #18 wait for it.
  'counter-three-open': {
    tickets: [
      issue(16, 'Counter ticket one', 'open', counter),
      issue(17, 'Counter ticket two', 'open', counter),
      issue(18, 'Counter ticket three', 'open', counter),
    ],
    blockers: {16: [], 17: [], 18: []},
  },
  // #16 merged and closed: the next `shared-counter` ticket is released on the next run.
  'counter-smaller-closed': {
    tickets: [
      issue(16, 'Counter ticket one', 'closed', counter),
      issue(17, 'Counter ticket two', 'open', counter),
    ],
    blockers: {17: []},
  },
  // A `shared-counter` ticket with an open blocker stays in `# blocked` for that reason
  // and takes no slot, so #17 is the one released.
  'counter-blocked-takes-no-slot': {
    tickets: [
      issue(16, 'Counter ticket one', 'open', counter),
      issue(17, 'Counter ticket two', 'open', counter),
    ],
    blockers: {16: [20], 17: []},
  },
  // A `shared-counter` ticket that is human or shelved takes no slot either.
  'counter-human-shelved-take-no-slot': {
    tickets: [
      issue(16, 'Human counter ticket', 'open', ['ready-for-human', 'shared-counter']),
      issue(17, '【搁置】Shelved counter ticket', 'open', ['shared-counter']),
      issue(18, 'Counter ticket three', 'open', counter),
    ],
    blockers: {16: [], 17: [], 18: []},
  },
  // 票 #86: Tickets without `ready-for-agent` are never in the frontier. They
  // are listed under `# decision`, each by what it carries instead of the
  // label; an unlabelled shelved Ticket is shelved, not one of them. They are
  // not asked for their blockers by the frontier (the graph asks once), so an
  // open blocker of theirs is not listed either.
  'decision-kinds': {
    tickets: [
      issue(16, 'Needs info ticket', 'open', ['needs-info']),
      issue(17, 'Unlabelled ticket', 'open', []),
      issue(18, 'Wontfix ticket', 'open', ['wontfix']),
      issue(19, '【搁置】Unlabelled shelved ticket', 'open', []),
    ],
    blockers: {16: [20], 17: [], 18: [], 19: []},
  },
  // Such a Ticket takes no `shared-counter` slot, like a human or shelved one.
  'decision-counter-takes-no-slot': {
    tickets: [
      issue(16, 'Untriaged counter ticket', 'open', ['shared-counter']),
      issue(17, 'Counter ticket two', 'open', counter),
      issue(18, 'Needs triage counter ticket', 'open', ['needs-triage', 'shared-counter']),
    ],
    blockers: {16: [], 17: [], 18: []},
  },
};

const extraIssues = [openBlocker, closedBlocker];
const readyBlockers = {12: [], 13: [21]};
const blockerIssues = {20: openBlocker, 21: closedBlocker};
for (const [name, scenario] of Object.entries(scenarios)) {
  const scenarioDirectory = `${work}/${name}`;
  fs.mkdirSync(scenarioDirectory, {recursive: true});
  const children = [...readyTickets, ...scenario.tickets.filter((ticket) => ticket.state === 'open')];
  const spec = issue(10, 'Test spec', 'open', [], '## Problem Statement\nTest spec.', sub(children.length, 0));
  const scenarioIssues = [spec, ...readyTickets, ...scenario.tickets, ...extraIssues];
  fs.writeFileSync(`${scenarioDirectory}/issues.json`, JSON.stringify(scenarioIssues, null, 2));
  fs.writeFileSync(`${scenarioDirectory}/sub-10.json`, JSON.stringify(children, null, 2));
  for (const [number, list] of Object.entries({...readyBlockers, ...scenario.blockers})) {
    const blockers = list.map((value) => blockerIssues[value]);
    fs.writeFileSync(`${scenarioDirectory}/blocker-${number}.json`, JSON.stringify(blockers, null, 2));
  }
}

// A Spec whose open Tickets all wait for triage (票 #86): its frontier is empty
// and `# decision` names every one of them. SKILL.md step 0 rule 3 releases
// such a Spec instead of landing it with nothing done.
{
  const directory = `${work}/decision-only`;
  fs.mkdirSync(directory, {recursive: true});
  const tickets = [issue(36, 'Needs info ticket', 'open', ['needs-info']), issue(37, 'Unlabelled ticket', 'open', [])];
  const spec = issue(35, 'Untriaged spec', 'open', [], '## Problem Statement\nNothing is triaged yet.', sub(2, 0));
  fs.writeFileSync(`${directory}/issues.json`, JSON.stringify([spec, ...tickets], null, 2));
  fs.writeFileSync(`${directory}/sub-35.json`, JSON.stringify(tickets, null, 2));
  for (const ticket of tickets) {
    fs.writeFileSync(`${directory}/blocker-${ticket.number}.json`, '[]');
  }
}

// A Spec without sub-issues whose `实现票：` line names a loose source ticket
// (#83): the mapless, childless ticket #40 is the Spec's single Ticket in the
// graph, flagged `source`. One directory per state of the source.
const sourceIssues = [
  issue(20, 'Open blocker', 'open', []),
  issue(21, 'Closed blocker', 'closed', []),
];
for (const [name, source] of [
  ['source-open', issue(40, 'Loose source ticket', 'open', [])],
  ['source-human', issue(40, 'Human loose source', 'open', ['ready-for-human'])],
  ['source-closed', issue(40, 'Loose source ticket', 'closed', [])],
]) {
  const directory = `${work}/${name}`;
  fs.mkdirSync(directory, {recursive: true});
  const spec = issue(31, 'Loose-source spec', 'open', [], '实现票：#40\n\n## Problem Statement\nDrafted from a loose ticket.', sub(0));
  const sourceDirectoryIssues = [spec, source, ...sourceIssues];
  fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(sourceDirectoryIssues, null, 2));
  for (const item of sourceDirectoryIssues) {
    fs.writeFileSync(`${directory}/blocker-${item.number}.json`, '[]');
  }
}
NODE

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# The fake gh of test-pipeline-status.sh, test-frontier.sh and
# test-landing-check.sh. The three tests hold one text, so that a knob means
# the same in each: change one copy, change all three.
#
# Knobs, read from the environment:
#   FAKE_GH_FAIL=1                  the issue list fails
#   FAKE_GH_FAIL_BLOCKERS=1         every dependencies/blocked_by query fails
#   FAKE_GH_FAIL_BLOCKERS_AT=<k>    blocked_by queries from the k-th on fail
#   FAKE_GH_FAIL_BLOCKERS_OF=<n>    with FAKE_GH_FAIL_BLOCKERS_NTH=<k>, the
#   FAKE_GH_FAIL_BLOCKERS_NTH=<k>   k-th blocked_by query of issue <n> fails
#
# FIXTURE_DIR holds issues.json, sub-<n>.json and blocker-<n>.json. Every
# blocked_by query, answered or failed, adds its issue number to
# FIXTURE_DIR/blocker-calls, one per line in call order.
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
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/dependencies/blocked_by.*#\1#p')
    printf '%s\n' "$number" >> "$FIXTURE_DIR/blocker-calls"
    if [ "${FAKE_GH_FAIL_BLOCKERS:-0}" = 1 ]; then
      printf '%s\n' 'fake gh: blocked_by unavailable' >&2
      exit 1
    fi
    calls=$(wc -l < "$FIXTURE_DIR/blocker-calls" | tr -d ' ')
    if [ "${FAKE_GH_FAIL_BLOCKERS_AT:-0}" -gt 0 ] && [ "$calls" -ge "${FAKE_GH_FAIL_BLOCKERS_AT}" ]; then
      printf 'fake gh: blocked_by unavailable on call %s\n' "$calls" >&2
      exit 1
    fi
    nth=$(grep -cx "$number" "$FIXTURE_DIR/blocker-calls" | tr -d ' ')
    if [ "$number" = "${FAKE_GH_FAIL_BLOCKERS_OF:-}" ] && [ "$nth" = "${FAKE_GH_FAIL_BLOCKERS_NTH:-}" ]; then
      printf 'fake gh: blocked_by unavailable for #%s on its query %s\n' "$number" "$nth" >&2
      exit 1
    fi
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

# The fake gh above is one text in three tests (this one, test-pipeline-status.sh
# and test-landing-check.sh). Before 票 #86 they were three copies that had
# drifted apart — the same failure had a knob of its own name in each — so each
# test now holds its copy against the next test's: a copy edited alone turns
# its own test red here.
fake_gh_of() { # test script: the fake gh it writes, without the heredoc's fences
  awk '/^cat > "\$BIN\/gh" <<.EOF.$/ {on = 1; next} on && /^EOF$/ {exit} on {print}' \
    "$ROOT/scripts/$1" > "$WORK/fake-gh-of-$1.txt"
}
fake_gh_of test-frontier.sh
fake_gh_of test-pipeline-status.sh
if cmp -s "$WORK/fake-gh-of-test-frontier.sh.txt" "$WORK/fake-gh-of-test-pipeline-status.sh.txt"; then
  record PASS 'the fake gh is one text with test-pipeline-status.sh'
else
  record FAIL 'the fake gh is one text with test-pipeline-status.sh' \
    "$(diff "$WORK/fake-gh-of-test-frontier.sh.txt" "$WORK/fake-gh-of-test-pipeline-status.sh.txt")"
fi

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

# Without a `shared-counter` ticket and without a Ticket under `# decision` the
# whole output is fixed, byte for byte: the one-at-a-time rule and the label
# rule must not add, move or reword anything. The human Ticket carries no
# `ready-for-agent` either, and is under # human alone.
cat > "$WORK/main.expected" <<'EOF'
#12
#13
# blocked
#11 Blocked ticket（阻塞：#20）
#14 【搁置】Shelved ticket（阻塞：#20）
# human
#15 Human ticket（人工）
# decision
（无）
# shelved
#14 【搁置】Shelved ticket（搁置）
# source
（无）
EOF
if cmp -s "$WORK/main.out" "$WORK/main.expected"; then
  record PASS 'no shared-counter ticket and no Ticket under # decision: output is byte-identical'
else
  record FAIL 'no shared-counter ticket and no Ticket under # decision: output is byte-identical' "$(diff "$WORK/main.expected" "$WORK/main.out")"
fi

# A `shared-counter` ticket bumps a shared counter (GLOSSARY.md). Among such
# tickets that pass the other frontier conditions frontier.sh releases only the
# lowest-numbered one; the rest wait in `# blocked`, naming it. A `shared-counter`
# ticket that is blocked, human or shelved is not eligible and takes no slot.
# Each scenario is the Spec's own fixture directory, swapped in by overriding
# FIXTURE_DIR on the run_frontier call. Expected outputs are hand-written, not
# recomputed.
run_scenario() {
  scenario=$1
  output=$2
  rm -f "$WORK/$scenario/blocker-calls"
  run_frontier "$output" FIXTURE_DIR="$WORK/$scenario"
  awk '/^# /{exit} {print}' "$output" > "${output%.out}-frontier.out"
}

run_scenario counter-three-open "$WORK/three-open.out"
expect_exit 0 'three shared-counter tickets: scan succeeds'
check_frontier=$(head -n 4 "$WORK/three-open.out" | tr '\n' ' ')
if [ "$check_frontier" = '#12 #13 #16 # blocked ' ]; then
  record PASS 'three shared-counter tickets: exactly the lowest-numbered one is released, unmarked tickets unaffected'
else
  record FAIL 'three shared-counter tickets: exactly the lowest-numbered one is released, unmarked tickets unaffected' "got [$check_frontier]"
fi
expect_has '#17 Counter ticket two（等共享计数器：#16）' 'waiting shared-counter ticket names the one it waits for' "$WORK/three-open.out"
expect_has '#18 Counter ticket three（等共享计数器：#16）' 'every other shared-counter ticket waits for the same released one' "$WORK/three-open.out"
expect_without '#17' 'waiting shared-counter ticket is not in the frontier' "$WORK/three-open-frontier.out"
expect_without '#18' 'third shared-counter ticket is not in the frontier' "$WORK/three-open-frontier.out"
check_blocked=$(sed -n '4,6p' "$WORK/three-open.out" | tr '\n' ' ')
if [ "$check_blocked" = \
  '# blocked #17 Counter ticket two（等共享计数器：#16） #18 Counter ticket three（等共享计数器：#16） ' ]; then
  record PASS 'waiting shared-counter tickets sit in the blocked section, ascending'
else
  record FAIL 'waiting shared-counter tickets sit in the blocked section, ascending' "got [$check_blocked]"
fi

run_scenario counter-smaller-closed "$WORK/smaller-closed.out"
expect_exit 0 'smaller shared-counter ticket closed: scan succeeds'
expect_has '#17' 'smaller shared-counter ticket closed: the next one is released' "$WORK/smaller-closed-frontier.out"
expect_without '等共享计数器' 'smaller shared-counter ticket closed: nobody waits any more' "$WORK/smaller-closed.out"

run_scenario counter-blocked-takes-no-slot "$WORK/blocked-slot.out"
expect_exit 0 'blocked shared-counter ticket: scan succeeds'
expect_has '#16 Counter ticket one（阻塞：#20）' 'blocked shared-counter ticket keeps its blocker reason' "$WORK/blocked-slot.out"
expect_has '#17' 'blocked shared-counter ticket takes no slot: the free one is released' "$WORK/blocked-slot-frontier.out"
expect_without '等共享计数器：#16' 'blocked shared-counter ticket is not waited for' "$WORK/blocked-slot.out"

run_scenario counter-human-shelved-take-no-slot "$WORK/human-shelved-slot.out"
expect_exit 0 'human and shelved shared-counter tickets: scan succeeds'
expect_has '#16 Human counter ticket（人工）' 'human shared-counter ticket is still listed under human' "$WORK/human-shelved-slot.out"
expect_has '#17 【搁置】Shelved counter ticket（搁置）' 'shelved shared-counter ticket is still listed under shelved' "$WORK/human-shelved-slot.out"
expect_has '#18' 'human and shelved shared-counter tickets take no slot: the free one is released' "$WORK/human-shelved-slot-frontier.out"
expect_without '等共享计数器' 'human and shelved shared-counter tickets are not waited for' "$WORK/human-shelved-slot.out"

# --- 票 #86: an open Ticket without `ready-for-agent` waits for a person ----------
# Nothing is dispatched for it until a person triages it, so it is never in the
# frontier. It is listed under `# decision`, is in no other section unless it is
# shelved (which is what it then is), takes no `shared-counter` slot, and is
# asked for no blockers by the frontier: the graph asks once, as for every open
# Ticket, and an open blocker of its own is not listed.
run_scenario decision-kinds "$WORK/decision-kinds.out"
expect_exit 0 'Tickets without ready-for-agent: scan succeeds'
cat > "$WORK/decision-kinds.expected" <<'EOF'
#12
#13
# blocked
（无）
# human
（无）
# decision
#16 Needs info ticket（待定）
#17 Unlabelled ticket（待定）
#18 Wontfix ticket（待定）
# shelved
#19 【搁置】Unlabelled shelved ticket（搁置）
# source
（无）
EOF
expect_output "$WORK/decision-kinds.expected" "$WORK/decision-kinds.out" \
  'Tickets without ready-for-agent are listed under # decision by what they carry instead, and an unlabelled shelved Ticket under # shelved'
decision_calls=$(sort "$WORK/decision-kinds/blocker-calls" | uniq -c | tr -s ' ' | tr '\n' ';')
if [ "$decision_calls" = ' 2 12; 2 13; 1 16; 1 17; 1 18; 1 19;' ]; then
  record PASS 'Tickets without ready-for-agent are asked for their blockers once: by the graph, not by the frontier'
else
  record FAIL 'Tickets without ready-for-agent are asked for their blockers once: by the graph, not by the frontier' "blocked_by calls: $decision_calls"
fi

run_scenario decision-counter-takes-no-slot "$WORK/decision-slot.out"
expect_exit 0 'a shared-counter Ticket without ready-for-agent: scan succeeds'
expect_has '#17' 'a shared-counter Ticket without ready-for-agent takes no slot: the triaged one is released' "$WORK/decision-slot-frontier.out"
expect_has '#16 Untriaged counter ticket（待定）' 'an untriaged shared-counter Ticket is under # decision' "$WORK/decision-slot.out"
expect_has '#18 Needs triage counter ticket（待定）' 'a needs-triage shared-counter Ticket is under # decision' "$WORK/decision-slot.out"
expect_without '等共享计数器' 'Tickets under # decision are not waited for as shared-counter tickets' "$WORK/decision-slot.out"

# A Spec whose open Tickets all wait for triage has an empty frontier: every
# line of its output belongs to a section, and `# decision` names them all.
SPEC_ARG=35
run_frontier "$WORK/decision-only.out" FIXTURE_DIR="$WORK/decision-only"
expect_exit 0 'a Spec whose Tickets all wait for triage: scan succeeds'
cat > "$WORK/decision-only.expected" <<'EOF'
# blocked
（无）
# human
（无）
# decision
#36 Needs info ticket（待定）
#37 Unlabelled ticket（待定）
# shelved
（无）
# source
（无）
EOF
expect_output "$WORK/decision-only.expected" "$WORK/decision-only.out" \
  'a Spec whose Tickets all wait for triage has an empty frontier and names them under # decision'

# A Spec without sub-issues whose `实现票：` line names a loose source ticket
# (#83): the graph flags that ticket `source`. It is not an execution ticket,
# so it is never in the frontier and the script asks for no blockers of its
# own for it (the one query is the graph's); it is listed under `# source`.
# Each state of the source is the Spec's own fixture directory. The open source
# carries no label at all and is still under # source alone.
SPEC_ARG=31
rm -f "$WORK/source-open/blocker-calls"
run_frontier "$WORK/source-open.out" FIXTURE_DIR="$WORK/source-open"
expect_exit 0 'an open loose source ticket: scan succeeds'
cat > "$WORK/source-open.expected" <<'EOF'
# blocked
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
#40 Loose source ticket（源票）
EOF
expect_output "$WORK/source-open.expected" "$WORK/source-open.out" \
  'an open loose source ticket is listed under # source, and is in no frontier'
source_queries=$(tr '\n' ' ' < "$WORK/source-open/blocker-calls")
if [ "$source_queries" = '40 ' ]; then
  record PASS "a loose source ticket's blockers are asked for once: by the graph, not by the frontier"
else
  record FAIL "a loose source ticket's blockers are asked for once: by the graph, not by the frontier" "queries [$source_queries]"
fi

# A source that is ready-for-human is under both headings, in neither frontier.
run_frontier "$WORK/source-human.out" FIXTURE_DIR="$WORK/source-human"
expect_exit 0 'a ready-for-human loose source ticket: scan succeeds'
cat > "$WORK/source-human.expected" <<'EOF'
# blocked
（无）
# human
#40 Human loose source（人工）
# decision
（无）
# shelved
（无）
# source
#40 Human loose source（源票）
EOF
expect_output "$WORK/source-human.expected" "$WORK/source-human.out" \
  'a ready-for-human loose source ticket is under # human and # source'

# A closed source is nobody's implementation: the Spec has no Ticket at all.
run_frontier "$WORK/source-closed.out" FIXTURE_DIR="$WORK/source-closed"
expect_exit 0 'a closed loose source ticket: scan succeeds'
cat > "$WORK/source-closed.expected" <<'EOF'
# blocked
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
EOF
expect_output "$WORK/source-closed.expected" "$WORK/source-closed.out" \
  'a closed loose source ticket is listed nowhere'

# --- fail closed ------------------------------------------------------------------
# Two ways, told apart by the exit code (票 #86). A Spec the graph does not
# hold will not appear by waiting: exit 3, so that step 1 parks at once instead
# of running the script again and waiting for the keeper to resume the Run. A
# query that failed may pass: exit 1 keeps the retry. Neither prints on stdout.
SPEC_ARG=99
run_frontier "$WORK/missing.out"
expect_exit 3 "unknown spec fails closed for good: exit 3, apart from a failed query"
expect_has 'not found' "unknown spec names the problem on stderr" "$WORK/missing.out.err"
expect_has 'frontier: spec #99 not found in the test/repo graph' 'unknown spec is named by its number and repository on stderr' "$WORK/missing.out.err"
if [ ! -s "$WORK/missing.out" ]; then
  record PASS "unknown spec prints nothing on stdout"
else
  record FAIL "unknown spec prints nothing on stdout"
fi

SPEC_ARG=10
run_frontier "$WORK/gh-fail.out" FAKE_GH_FAIL=1
expect_exit 1 "pipeline-status failure fails closed with the retried exit 1"
expect_has 'pipeline-status.sh --graph failed' "pipeline-status failure is explained" "$WORK/gh-fail.out.err"
if [ ! -s "$WORK/gh-fail.out" ]; then
  record PASS "pipeline-status failure prints nothing on stdout"
else
  record FAIL "pipeline-status failure prints nothing on stdout"
fi

rm -f "$FIXTURE/blocker-calls"
run_frontier "$WORK/blocker-fail.out" FAKE_GH_FAIL_BLOCKERS_AT=5
expect_exit 1 "blocked_by failure fails closed with the retried exit 1"
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
expect_has 'frontier: --spec is required' 'a usage error names the script and the argument' "${WORK}/usage.out.err"

SPEC_ARG=abc
run_frontier "$WORK/usage2.out"
expect_exit 64 "non-numeric --spec is a usage error"

env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" bash "$SCRIPT" --help > "$WORK/help.out" 2> "${WORK}/help.out.err"
RUN_EXIT=$?
expect_exit 0 '--help exits 0'
expect_has '# decision' '--help documents the decision section' "$WORK/help.out"
expect_has '3  fail closed for good: the graph has no such Spec' '--help lists exit 3 apart from exit 1' "$WORK/help.out"

echo "Artifacts: $WORK"
echo "Summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
