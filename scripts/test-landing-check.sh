#!/usr/bin/env bash
# Deterministic tests for scripts/landing-check.sh. They run the real
# pipeline-status.sh against a fake gh, so the Spec-to-Ticket resolution, the
# blocked_by queries, the five kinds of open Ticket that do not block a landing
# (waiting, human, the Pending ticket of 票 #86 — without `ready-for-agent`, or
# held by a triage label beside it —, shelved, and the loose source ticket of
# 票 #83), the report lines for the waiting ones and the two ways the check
# fails closed (票 #86: exit 1 for a query that failed, exit 3 for a Spec the
# graph does not hold) are covered end to end without network access.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/landing-check.sh
FRONTIER=$ROOT/scripts/frontier.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/landing-check-test.XXXXXX")
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

expect_empty() { # file name — the file is empty (a run's stdout, on a failure)
  if [ -s "$1" ]; then
    record FAIL "$2" "$(cat "$1")"
  else
    record PASS "$2"
  fi
}

expect_output() { # expected-file actual-file name — byte for byte
  if cmp -s "$1" "$2"; then
    record PASS "$3"
  else
    record FAIL "$3" "$(diff "$1" "$2")"
  fi
}

expect_section_empty() { # file title name — the section holds nothing but `（无）`
  body=$(sed -n "/^# $2\$/{n;p;}" "$1")
  if [ "$body" = '（无）' ]; then
    record PASS "$3"
  else
    record FAIL "$3" "under # $2: [$body]"
  fi
}

SPEC_ARG=10

run_check() { # OUT [VARIABLE=value ...] — the fake gh reads FIXTURE_DIR; the log of its blocked_by calls starts empty
  output=$1
  shift
  rm -f "$WORK"/*/blocker-calls
  env FIXTURE_DIR="$FIXTURE" PATH="$BIN:$PATH" "$@" \
    bash "$SCRIPT" --repo test/repo --spec "$SPEC_ARG" > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

# Every issue of a scenario gets a blocker file, `[]` unless the scenario says
# otherwise, so a missing file is a missing issue, not a quiet "no blockers".
WORK=$WORK node > /dev/null <<'NODE'
const fs = require('fs');
const work = process.env.WORK;

function sub(total, completed = total) {
  return {total, completed, percent_completed: total ? Math.round(100 * completed / total) : 0};
}

function issue(number, title, state, labels = [], body = '', children = sub(0)) {
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

// The Tickets of Spec #10, and the issues outside it. An execution Ticket
// carries `ready-for-agent` and none of `needs-info` / `needs-triage` /
// `wontfix` (票 #86): an open Ticket without the label, or with one of those
// three beside it, waits for a person's triage and holds no landing back.
const ready = ['ready-for-agent'];
const t11 = (state = 'closed', labels = ready) => issue(11, 'Ticket eleven', state, labels);
const t12 = (state = 'closed', labels = ready, title = 'Ticket twelve') => issue(12, title, state, labels);
const t13 = (state = 'closed', labels = ready) => issue(13, 'Ticket thirteen', state, labels);
const outside = [issue(20, 'Standalone issue', 'open'), issue(21, 'Closed issue', 'closed')];

function write(name, issues, subs, blockers) {
  const directory = `${work}/${name}`;
  fs.mkdirSync(directory, {recursive: true});
  fs.writeFileSync(`${directory}/issues.json`, JSON.stringify(issues, null, 2));
  for (const [number, children] of Object.entries(subs)) {
    fs.writeFileSync(`${directory}/sub-${number}.json`, JSON.stringify(children, null, 2));
  }
  for (const item of issues) {
    fs.writeFileSync(`${directory}/blocker-${item.number}.json`, JSON.stringify((blockers || {})[item.number] || [], null, 2));
  }
}

// Spec #10 with its three Tickets; #30 is a Spec without Tickets.
function spec10(name, tickets, blockers, extra = []) {
  const closed = tickets.filter((ticket) => ticket.state === 'closed').length;
  const spec = issue(10, 'Test spec', 'open', [], '## Problem Statement\nTest spec.', sub(tickets.length, closed));
  const empty = issue(30, 'Empty spec', 'open', [], '## Problem Statement\nNo tickets.', sub(0));
  write(name, [spec, ...tickets, ...outside, ...extra, empty], {10: tickets}, blockers);
}

const outside22 = issue(22, 'Standalone issue twenty-two', 'open');

spec10('all-closed', [t11(), t12(), t13()]);
spec10('one-open', [t11(), t12('open'), t13()]);
// 票 #78's shape: a Ticket merged but left open, and the chain behind it still
// blocked by it.
spec10('chain-open', [t11('open'), t12('open'), t13('open')], {12: [t11('open')], 13: [t12('open')]});
spec10('human-open', [t11(), t12(), t13('open', ['ready-for-human'])]);
// The shelved Ticket carries no label at all: shelved is what it is, not a
// Ticket waiting for triage.
spec10('shelved-open', [t11(), t12('open', [], '【搁置】Ticket twelve'), t13()]);
spec10('waiting-outside', [t11(), t12('open'), t13()], {12: [outside[0]]});
spec10('waiting-chain', [t11('open'), t12('open'), t13()], {11: [outside[0]], 12: [t11('open')]});
spec10('waiting-human-chain', [t11('open', ['ready-for-human']), t12('open'), t13()], {12: [t11('open', ['ready-for-human'])]});
spec10('mixed', [t11(), t12('open'), t13('open')], {12: [outside[0]]});
spec10('closed-blocker', [t11(), t12('open'), t13()], {12: [outside[1]]});
spec10('blocked-ascending', [t11(), t12('open'), t13('open')], {12: [outside22, outside[1], outside[0]]}, [outside22]);
// A chain behind a shelved Ticket waits as one behind a human Ticket does.
const shelved11 = issue(11, '【搁置】Ticket eleven', 'open');
spec10('waiting-shelved-chain', [shelved11, t12('open'), t13()], {12: [shelved11]});
// The blocker is another Spec: the report line is the same shape.
const spec25 = issue(25, 'Other spec', 'open', [], '## Problem Statement\nNot split yet.', sub(0));
spec10('waiting-spec', [t11(), t12('open'), t13()], {12: [spec25]}, [spec25]);
// Several reasons of two kinds: the numbers ascending, then the human one.
spec10('waiting-kinds', [t11('open', ['ready-for-human']), t12('open'), t13()],
  {12: [t11('open', ['ready-for-human']), outside[0], outside22]});

// 票 #86: an open Ticket without `ready-for-agent` waits for a person's
// triage. It is listed under `# decision` and holds no landing back, whatever
// it carries instead of the label — nothing, needs-info, needs-triage or
// wontfix — and whatever blocks it: the check asks for no blockers of its own.
spec10('decision-unlabelled', [t11(), t12('open', []), t13()]);
spec10('decision-needs-info', [t11(), t12('open', ['needs-info']), t13()], {12: [outside[0]]});
spec10('decision-needs-triage', [t11(), t12('open', ['needs-triage']), t13()]);
spec10('decision-wontfix', [t11(), t12('open', ['wontfix']), t13()]);
// Every kind at once, ascending, beside an execution Ticket the Spec owes.
spec10('decision-kinds', [t11('open', ['needs-info']), t12('open', ['wontfix']), t13('open')]);
// A chain behind such a Ticket waits for that person, as one behind a human
// Ticket does.
spec10('decision-chain', [t11('open', ['needs-info']), t12('open'), t13()], {12: [t11('open', ['needs-info'])]});
// The triage labels win over `ready-for-agent` (票 #86, review r2): a Ticket
// that carries one of them beside the label is under # decision all the same —
// its labels contradict each other, which is a person's to put right. Each of
// the three, with an open issue blocking it: not asked for, so not listed. A
// chain behind such a Ticket waits for that person. A human Ticket stays under
// # human whatever it carries beside, and a closed Ticket is listed nowhere.
for (const label of ['needs-info', 'needs-triage', 'wontfix']) {
  spec10(`decision-labelled-${label}`, [t11(), t12('open', ['ready-for-agent', label]), t13()], {12: [outside[0]]});
}
spec10('decision-labelled-chain',
  [t11('open', ['ready-for-agent', 'wontfix']), t12('open'), t13()], {12: [t11('open', ['ready-for-agent', 'wontfix'])]});
spec10('human-needs-info', [t11(), t12(), t13('open', ['ready-for-human', 'needs-info'])]);
spec10('decision-labelled-closed', [t11(), t12('closed', ['ready-for-agent', 'needs-info']), t13()]);
// A labelled and an unlabelled one together, ascending, beside an execution
// Ticket the Spec owes.
spec10('decision-labelled-kinds',
  [t11('open', ['ready-for-agent', 'needs-info']), t12('open', ['needs-triage']), t13('open')]);

// A Spec whose Tickets come from its `实现票：` line. Two kinds of ticket go
// on that line, and only the first is an execution Ticket (SKILL.md step 0,
// rule 2). #40 is the implementation ticket of map #50 and the single Ticket:
// open, it holds the landing back. #60 is the loose source ticket a Spec was
// drafted from (票 #83 kind b): not an execution ticket, closed together with the
// Spec, so open it holds nothing back.
const map50 = issue(50, 'Source map', 'open', ['wayfinder:map'], 'Destination.');
const lineSpec = (number, title, ref, mapLine) => issue(number, title, 'open', [],
  `实现票：#${ref}\n${mapLine}\n\n## Problem Statement\nOne ticket.`, sub(0));
for (const [name, state] of [['impl-open', 'open'], ['impl-closed', 'closed']]) {
  const impl = issue(40, 'Implementation forty', state, ['ready-for-agent']);
  write(name, [lineSpec(31, 'Single-ticket spec', 40, '地图：#50'), impl, map50, ...outside], {50: [impl]}, {});
}
for (const [name, labels] of [['source-open', []], ['source-human', ['ready-for-human']]]) {
  write(name, [lineSpec(32, 'Loose-source spec', 60, ''), issue(60, 'Loose source sixty', 'open', labels), ...outside], {}, {});
}
write('source-closed', [lineSpec(32, 'Loose-source spec', 60, ''), issue(60, 'Loose source sixty', 'closed'), ...outside], {}, {});
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

# The fake gh above is one text in three tests (this one, test-frontier.sh and
# test-pipeline-status.sh). Before 票 #86 they were three copies that had
# drifted apart — the same failure had a knob of its own name in each — so each
# test now holds its copy against the next test's: a copy edited alone turns
# its own test red here.
fake_gh_of() { # test script: the fake gh it writes, without the heredoc's fences
  awk '/^cat > "\$BIN\/gh" <<.EOF.$/ {on = 1; next} on && /^EOF$/ {exit} on {print}' \
    "$ROOT/scripts/$1" > "$WORK/fake-gh-of-$1.txt"
}
fake_gh_of test-landing-check.sh
fake_gh_of test-frontier.sh
if cmp -s "$WORK/fake-gh-of-test-landing-check.sh.txt" "$WORK/fake-gh-of-test-frontier.sh.txt"; then
  record PASS 'the fake gh is one text with test-frontier.sh'
else
  record FAIL 'the fake gh is one text with test-frontier.sh' \
    "$(diff "$WORK/fake-gh-of-test-landing-check.sh.txt" "$WORK/fake-gh-of-test-frontier.sh.txt")"
fi

cd "$WORK" || exit 1

# --- every Ticket closed: the check passes, byte for byte ------------------------
run_check "$WORK/all-closed.out" FIXTURE_DIR="$WORK/all-closed"
expect_exit 0 'every Ticket closed passes'
cat > "$WORK/all-closed.expected" <<'EOF'
# open
（无）
# waiting
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
（无）
EOF
expect_output "$WORK/all-closed.expected" "$WORK/all-closed.out" 'every Ticket closed: the seven sections are printed as empty'
expect_empty "$WORK/all-closed.out.err" 'every Ticket closed prints nothing on stderr'

# --- one open Ticket: listed under # open, exit 2 --------------------------------
run_check "$WORK/one-open.out" FIXTURE_DIR="$WORK/one-open"
expect_exit 2 'an open Ticket fails the check'
cat > "$WORK/one-open.expected" <<'EOF'
# open
#12 Ticket twelve
# waiting
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12
EOF
expect_output "$WORK/one-open.expected" "$WORK/one-open.out" 'an open Ticket is listed under # open and on the report line, with the other sections empty'
expect_without 'not found' 'an open Ticket is not a missing Spec' "$WORK/one-open.out.err"
if [ "$(sort "$WORK/one-open/blocker-calls" | uniq | tr '\n' ' ')" = '12 ' ]; then
  record PASS 'only the open Ticket is asked for its blockers, by the graph and by the check'
else
  record FAIL 'only the open Ticket is asked for its blockers, by the graph and by the check' "blocked_by calls: $(tr '\n' ' ' < "$WORK/one-open/blocker-calls")"
fi

# --- 票 #78: a merged Ticket left open and the chain behind it -------------------
# Nothing here waits for another Spec, so all three hold the landing back,
# each behind the one before it.
run_check "$WORK/chain-open.out" FIXTURE_DIR="$WORK/chain-open"
expect_exit 2 'a merged Ticket left open, with the chain it blocks, fails the check'
cat > "$WORK/chain-open.expected" <<'EOF'
# open
#11 Ticket eleven
#12 Ticket twelve（阻塞：#11）
#13 Ticket thirteen（阻塞：#12）
# waiting
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#11
剩余：#12（阻塞：#11）
剩余：#13（阻塞：#12）
EOF
expect_output "$WORK/chain-open.expected" "$WORK/chain-open.out" 'the chain behind an open Ticket is # open too, each naming its open blockers, and the report lines say which Tickets are still owed'

# --- human and shelved Tickets: listed, never blocking ---------------------------
run_check "$WORK/human-open.out" FIXTURE_DIR="$WORK/human-open"
expect_exit 0 'an open ready-for-human Ticket does not hold the landing back'
expect_has '#13 Ticket thirteen（人工）' 'an open ready-for-human Ticket is listed under # human' "$WORK/human-open.out"
expect_has '# open' 'a human Ticket still prints # open' "$WORK/human-open.out"
if [ "$(sed -n '2p' "$WORK/human-open.out")" = '（无）' ]; then
  record PASS 'a human Ticket is not under # open'
else
  record FAIL 'a human Ticket is not under # open' "$(sed -n 2p "$WORK/human-open.out")"
fi
# It carries no `ready-for-agent` either, but it is accounted for under # human:
# it is not a Ticket waiting for triage.
expect_section_empty "$WORK/human-open.out" decision 'a human Ticket is not under # decision'

run_check "$WORK/shelved-open.out" FIXTURE_DIR="$WORK/shelved-open"
expect_exit 0 'an open shelved Ticket does not hold the landing back'
expect_has '#12 【搁置】Ticket twelve（搁置）' 'an open shelved Ticket is listed under # shelved' "$WORK/shelved-open.out"
if [ "$(sed -n '2p' "$WORK/shelved-open.out")" = '（无）' ]; then
  record PASS 'a shelved Ticket is not under # open'
else
  record FAIL 'a shelved Ticket is not under # open' "$(sed -n 2p "$WORK/shelved-open.out")"
fi
# Shelved without any label at all: shelved is what it is.
expect_section_empty "$WORK/shelved-open.out" decision 'an unlabelled shelved Ticket is not under # decision'

# --- a Ticket that waits for another Spec: listed under # waiting, exit 0 -------
# A partial landing lands what is done, so a Ticket blocked by an open issue
# outside the Spec must not hold the landing back.
run_check "$WORK/waiting-outside.out" FIXTURE_DIR="$WORK/waiting-outside"
expect_exit 0 'a Ticket blocked by an issue outside the Spec does not hold the landing back'
expect_has '#12 Ticket twelve（阻塞：#20）' 'a waiting Ticket is listed under # waiting with its blocker' "$WORK/waiting-outside.out"
expect_has '# waiting' 'the # waiting section is printed' "$WORK/waiting-outside.out"
expect_has '剩余：#12 等 #20' 'the report line names the Ticket and the issue it waits for' "$WORK/waiting-outside.out"
if [ "$(sed -n '2p' "$WORK/waiting-outside.out")" = '（无）' ]; then
  record PASS 'a waiting Ticket is not under # open'
else
  record FAIL 'a waiting Ticket is not under # open' "$(sed -n 2p "$WORK/waiting-outside.out")"
fi

# A chain behind such a Ticket waits too, and reports what the first one waits for.
run_check "$WORK/waiting-chain.out" FIXTURE_DIR="$WORK/waiting-chain"
expect_exit 0 'the chain behind a waiting Ticket waits too'
cat > "$WORK/waiting-chain.expected" <<'EOF'
# open
（无）
# waiting
#11 Ticket eleven（阻塞：#20）
#12 Ticket twelve（阻塞：#11）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#11 等 #20
剩余：#12 等 #20
EOF
expect_output "$WORK/waiting-chain.expected" "$WORK/waiting-chain.out" 'the chain behind a waiting Ticket is listed under # waiting, ascending, and reports the same blocker'

# A chain behind a human Ticket waits for that person the same way.
run_check "$WORK/waiting-human-chain.out" FIXTURE_DIR="$WORK/waiting-human-chain"
expect_exit 0 'the chain behind a human Ticket does not hold the landing back'
cat > "$WORK/waiting-human-chain.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#11）
# human
#11 Ticket eleven（人工）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12 等人工 #11
EOF
expect_output "$WORK/waiting-human-chain.expected" "$WORK/waiting-human-chain.out" 'the chain behind a human Ticket is under # waiting, the Ticket itself under # human, the report line says 人工'

# A chain behind a shelved Ticket waits the same way.
run_check "$WORK/waiting-shelved-chain.out" FIXTURE_DIR="$WORK/waiting-shelved-chain"
expect_exit 0 'the chain behind a shelved Ticket does not hold the landing back'
cat > "$WORK/waiting-shelved-chain.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#11）
# human
（无）
# decision
（无）
# shelved
#11 【搁置】Ticket eleven（搁置）
# source
（无）
# report
剩余：#12 等搁置 #11
EOF
expect_output "$WORK/waiting-shelved-chain.expected" "$WORK/waiting-shelved-chain.out" 'the chain behind a shelved Ticket is under # waiting, the report line says 搁置'

# A blocker that is another Spec reads the same as a standalone issue does.
run_check "$WORK/waiting-spec.out" FIXTURE_DIR="$WORK/waiting-spec"
expect_exit 0 'a Ticket blocked by another Spec does not hold the landing back'
cat > "$WORK/waiting-spec.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#25）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12 等 #25
EOF
expect_output "$WORK/waiting-spec.expected" "$WORK/waiting-spec.out" 'a Ticket blocked by another Spec reports 等 #<spec>'

# Several reasons of two kinds: the numbers ascending, then the human Ticket.
run_check "$WORK/waiting-kinds.out" FIXTURE_DIR="$WORK/waiting-kinds"
expect_exit 0 'a Ticket waiting for issues and a human Ticket does not hold the landing back'
cat > "$WORK/waiting-kinds.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#11 #20 #22）
# human
#11 Ticket eleven（人工）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12 等 #20 #22、人工 #11
EOF
expect_output "$WORK/waiting-kinds.expected" "$WORK/waiting-kinds.out" 'a Ticket with several reasons reports the numbers ascending, then the human Ticket'

# Both at once: the waiting one is listed, the other one holds the landing.
run_check "$WORK/mixed.out" FIXTURE_DIR="$WORK/mixed"
expect_exit 2 'an open Ticket next to a waiting one still fails the check'
cat > "$WORK/mixed.expected" <<'EOF'
# open
#13 Ticket thirteen
# waiting
#12 Ticket twelve（阻塞：#20）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12 等 #20
剩余：#13
EOF
expect_output "$WORK/mixed.expected" "$WORK/mixed.out" 'a waiting Ticket and an open Ticket are sorted into their sections'

# A closed blocker leaves nothing open: the Ticket is # open, without blockers.
run_check "$WORK/closed-blocker.out" FIXTURE_DIR="$WORK/closed-blocker"
expect_exit 2 'a Ticket whose blockers are all closed is not waiting'
expect_has '#12 Ticket twelve' 'a Ticket with closed blockers only is listed under # open' "$WORK/closed-blocker.out"
expect_has '剩余：#12' 'a Ticket with closed blockers only is on the report line' "$WORK/closed-blocker.out"
expect_without '阻塞' 'closed blockers are not listed' "$WORK/closed-blocker.out"

# Several open blockers are listed ascending, whatever order the tracker
# returns them in, and a closed one among them is not listed.
run_check "$WORK/blocked-ascending.out" FIXTURE_DIR="$WORK/blocked-ascending"
expect_exit 2 'an open Ticket next to one with several blockers fails the check'
cat > "$WORK/blocked-ascending.expected" <<'EOF'
# open
#13 Ticket thirteen
# waiting
#12 Ticket twelve（阻塞：#20 #22）
# human
（无）
# decision
（无）
# shelved
（无）
# source
（无）
# report
剩余：#12 等 #20 #22
剩余：#13
EOF
expect_output "$WORK/blocked-ascending.expected" "$WORK/blocked-ascending.out" 'several open blockers are listed ascending under # waiting and on the report line'

# --- 票 #86: an open Ticket without `ready-for-agent` waits for a person ----------
# Such a Ticket is no debt of the Spec's while nobody has triaged it: it holds
# no landing back, is listed under `# decision`, is in no other section, and
# gets no `# report` line — it is no execution Ticket yet. The check asks for
# no blockers of its own for it (the graph asks once, as for every open Ticket).
run_check "$WORK/decision-unlabelled.out" FIXTURE_DIR="$WORK/decision-unlabelled"
expect_exit 0 'an unlabelled open Ticket does not hold the landing back'
cat > "$WORK/decision-unlabelled.expected" <<'EOF'
# open
（无）
# waiting
（无）
# human
（无）
# decision
#12 Ticket twelve（待定）
# shelved
（无）
# source
（无）
# report
（无）
EOF
expect_output "$WORK/decision-unlabelled.expected" "$WORK/decision-unlabelled.out" \
  'an unlabelled open Ticket is listed under # decision and nowhere else'
if [ "$(sort "$WORK/decision-unlabelled/blocker-calls" | uniq -c | tr -s ' ' | tr '\n' ';')" = ' 1 12;' ]; then
  record PASS 'a Ticket under # decision is asked for its blockers once: by the graph, not by the check'
else
  record FAIL 'a Ticket under # decision is asked for its blockers once: by the graph, not by the check' \
    "blocked_by calls: $(tr '\n' ' ' < "$WORK/decision-unlabelled/blocker-calls")"
fi

# The triage labels that are not `ready-for-agent` all read the same. The
# needs-info one is blocked by an open issue: that is not asked and not listed.
for pending_case in needs-info needs-triage wontfix; do
  run_check "$WORK/decision-$pending_case.out" FIXTURE_DIR="$WORK/decision-$pending_case"
  expect_exit 0 "a $pending_case Ticket does not hold the landing back"
  expect_has '#12 Ticket twelve（待定）' "a $pending_case Ticket is listed under # decision" "$WORK/decision-$pending_case.out"
  if [ "$(sed -n '2p' "$WORK/decision-$pending_case.out")" = '（无）' ]; then
    record PASS "a $pending_case Ticket is not under # open"
  else
    record FAIL "a $pending_case Ticket is not under # open" "$(sed -n 2p "$WORK/decision-$pending_case.out")"
  fi
done
expect_without '阻塞' 'an issue blocking a Ticket under # decision is not asked for, so not listed' "$WORK/decision-needs-info.out"

# Several such Tickets are listed ascending, and the execution Ticket beside
# them still fails the check: the Spec owes that one.
run_check "$WORK/decision-kinds.out" FIXTURE_DIR="$WORK/decision-kinds"
expect_exit 2 'Tickets under # decision beside an execution Ticket: only the execution Ticket fails the check'
cat > "$WORK/decision-kinds.expected" <<'EOF'
# open
#13 Ticket thirteen
# waiting
（无）
# human
（无）
# decision
#11 Ticket eleven（待定）
#12 Ticket twelve（待定）
# shelved
（无）
# source
（无）
# report
剩余：#13
EOF
expect_output "$WORK/decision-kinds.expected" "$WORK/decision-kinds.out" \
  'Tickets under # decision are listed ascending, and the report names only the execution Ticket'

# The frontier reads the same Tickets through the same library
# (scripts/lib-graph.sh): what is under # decision here is under # decision
# there, and in neither frontier.
rm -f "$WORK"/*/blocker-calls
env FIXTURE_DIR="$WORK/decision-kinds" PATH="$BIN:$PATH" \
  bash "$FRONTIER" --repo test/repo --spec 10 > "$WORK/decision-frontier.out" 2> "$WORK/decision-frontier.out.err"
sed -n '/^# decision$/,/^# shelved$/p' "$WORK/decision-frontier.out" | sed '$d' > "$WORK/decision-frontier.section"
sed -n '/^# decision$/,/^# shelved$/p' "$WORK/decision-kinds.out" | sed '$d' > "$WORK/decision-check.section"
expect_output "$WORK/decision-check.section" "$WORK/decision-frontier.section" \
  'the frontier lists under # decision the same Tickets the landing check does'
if [ "$(awk '/^# /{exit} {print}' "$WORK/decision-frontier.out" | tr '\n' ' ')" = '#13 ' ]; then
  record PASS 'the frontier releases the execution Ticket and nothing under # decision'
else
  record FAIL 'the frontier releases the execution Ticket and nothing under # decision' \
    "frontier [$(awk '/^# /{exit} {print}' "$WORK/decision-frontier.out" | tr '\n' ' ')]"
fi

# A chain behind such a Ticket waits for that person, as one behind a human
# Ticket does, and the report line says 人工.
run_check "$WORK/decision-chain.out" FIXTURE_DIR="$WORK/decision-chain"
expect_exit 0 'the chain behind a Ticket under # decision does not hold the landing back'
cat > "$WORK/decision-chain.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#11）
# human
（无）
# decision
#11 Ticket eleven（待定）
# shelved
（无）
# source
（无）
# report
剩余：#12 等人工 #11
EOF
expect_output "$WORK/decision-chain.expected" "$WORK/decision-chain.out" \
  'the chain behind a Ticket under # decision is under # waiting, and reports 等人工'
if [ "$(sort "$WORK/decision-chain/blocker-calls" | uniq -c | tr -s ' ' | tr '\n' ';')" = ' 1 11; 2 12;' ]; then
  record PASS 'only the waiting Ticket of the chain is asked for its blockers by the check'
else
  record FAIL 'only the waiting Ticket of the chain is asked for its blockers by the check' \
    "blocked_by calls: $(tr '\n' ' ' < "$WORK/decision-chain/blocker-calls")"
fi

# The triage labels win over `ready-for-agent` (票 #86, review r2: the ticket
# says so without condition). A Ticket that carries one of them beside the
# label is under # decision all the same — its labels contradict each other,
# which is a person's to put right, not a debt of the Spec's — for each of the
# three: listed with （待定）, in no other section, with no report line, and
# asked for no blockers of its own although an open issue blocks it.
for pending_label in needs-info needs-triage wontfix; do
  run_check "$WORK/decision-labelled-$pending_label.out" FIXTURE_DIR="$WORK/decision-labelled-$pending_label"
  expect_exit 0 "a Ticket with ready-for-agent beside $pending_label does not hold the landing back"
  expect_has '#12 Ticket twelve（待定）' \
    "a Ticket with ready-for-agent beside $pending_label is listed under # decision" "$WORK/decision-labelled-$pending_label.out"
  if [ "$(sed -n '2p' "$WORK/decision-labelled-$pending_label.out")" = '（无）' ]; then
    record PASS "a Ticket with ready-for-agent beside $pending_label is not under # open"
  else
    record FAIL "a Ticket with ready-for-agent beside $pending_label is not under # open" \
      "$(sed -n 2p "$WORK/decision-labelled-$pending_label.out")"
  fi
  expect_section_empty "$WORK/decision-labelled-$pending_label.out" report \
    "a Ticket with ready-for-agent beside $pending_label gets no # report line"
  expect_without '阻塞' "an issue blocking a Ticket held by $pending_label beside ready-for-agent is not asked for, so not listed" \
    "$WORK/decision-labelled-$pending_label.out"
  if [ "$(sort "$WORK/decision-labelled-$pending_label/blocker-calls" | uniq -c | tr -s ' ' | tr '\n' ';')" = ' 1 12;' ]; then
    record PASS "a Ticket with ready-for-agent beside $pending_label is asked for its blockers once: by the graph, not by the check"
  else
    record FAIL "a Ticket with ready-for-agent beside $pending_label is asked for its blockers once: by the graph, not by the check" \
      "blocked_by calls: $(tr '\n' ' ' < "$WORK/decision-labelled-$pending_label/blocker-calls")"
  fi
done

# Both kinds together, ascending, beside an execution Ticket the Spec owes: a
# labelled and an unlabelled Ticket are told apart by nothing in the output,
# and the report still names only the execution Ticket.
run_check "$WORK/decision-labelled-kinds.out" FIXTURE_DIR="$WORK/decision-labelled-kinds"
expect_exit 2 'labelled and unlabelled Tickets under # decision beside an execution Ticket: only the execution Ticket fails the check'
cat > "$WORK/decision-labelled-kinds.expected" <<'EOF'
# open
#13 Ticket thirteen
# waiting
（无）
# human
（无）
# decision
#11 Ticket eleven（待定）
#12 Ticket twelve（待定）
# shelved
（无）
# source
（无）
# report
剩余：#13
EOF
expect_output "$WORK/decision-labelled-kinds.expected" "$WORK/decision-labelled-kinds.out" \
  'a Ticket held by a triage label beside ready-for-agent and an unlabelled one are listed together under # decision, ascending'

# The frontier agrees on the labelled ones too, and releases nothing held by a
# triage label beside ready-for-agent.
rm -f "$WORK"/*/blocker-calls
env FIXTURE_DIR="$WORK/decision-labelled-kinds" PATH="$BIN:$PATH" \
  bash "$FRONTIER" --repo test/repo --spec 10 > "$WORK/decision-labelled-frontier.out" 2> "$WORK/decision-labelled-frontier.out.err"
sed -n '/^# decision$/,/^# shelved$/p' "$WORK/decision-labelled-frontier.out" | sed '$d' > "$WORK/decision-labelled-frontier.section"
sed -n '/^# decision$/,/^# shelved$/p' "$WORK/decision-labelled-kinds.out" | sed '$d' > "$WORK/decision-labelled-check.section"
expect_output "$WORK/decision-labelled-check.section" "$WORK/decision-labelled-frontier.section" \
  'the frontier lists under # decision the same labelled Tickets the landing check does'
if [ "$(awk '/^# /{exit} {print}' "$WORK/decision-labelled-frontier.out" | tr '\n' ' ')" = '#13 ' ]; then
  record PASS 'the frontier releases the execution Ticket and no Ticket held by a triage label beside ready-for-agent'
else
  record FAIL 'the frontier releases the execution Ticket and no Ticket held by a triage label beside ready-for-agent' \
    "frontier [$(awk '/^# /{exit} {print}' "$WORK/decision-labelled-frontier.out" | tr '\n' ' ')]"
fi

# A chain behind such a labelled Ticket waits for that person, as one behind an
# unlabelled Ticket or a human Ticket does.
run_check "$WORK/decision-labelled-chain.out" FIXTURE_DIR="$WORK/decision-labelled-chain"
expect_exit 0 'the chain behind a Ticket held by a triage label beside ready-for-agent does not hold the landing back'
cat > "$WORK/decision-labelled-chain.expected" <<'EOF'
# open
（无）
# waiting
#12 Ticket twelve（阻塞：#11）
# human
（无）
# decision
#11 Ticket eleven（待定）
# shelved
（无）
# source
（无）
# report
剩余：#12 等人工 #11
EOF
expect_output "$WORK/decision-labelled-chain.expected" "$WORK/decision-labelled-chain.out" \
  'the chain behind a labelled Ticket is under # waiting and reports 等人工, the Ticket itself under # decision'

# `ready-for-human` is accounted for under # human whatever the Ticket carries
# beside: the hold label does not move it to # decision.
run_check "$WORK/human-needs-info.out" FIXTURE_DIR="$WORK/human-needs-info"
expect_exit 0 'a ready-for-human Ticket that needs info does not hold the landing back'
expect_has '#13 Ticket thirteen（人工）' 'a ready-for-human Ticket that needs info is listed under # human' "$WORK/human-needs-info.out"
expect_section_empty "$WORK/human-needs-info.out" decision 'a ready-for-human Ticket that needs info is not under # decision'

# A closed Ticket with contradictory labels is nobody's debt: only open Tickets
# are sorted into sections.
run_check "$WORK/decision-labelled-closed.out" FIXTURE_DIR="$WORK/decision-labelled-closed"
expect_exit 0 'a closed Ticket with contradictory labels passes'
expect_output "$WORK/all-closed.expected" "$WORK/decision-labelled-closed.out" 'a closed Ticket with contradictory labels is listed nowhere'

# --- a Spec without Tickets passes ----------------------------------------------
SPEC_ARG=30
run_check "$WORK/empty.out" FIXTURE_DIR="$WORK/one-open"
expect_exit 0 'a Spec without Tickets passes'
expect_output "$WORK/all-closed.expected" "$WORK/empty.out" 'a Spec without Tickets prints the seven empty sections'

# --- a Spec whose Ticket is the one its 实现票 line names ------------------------
# Kind a: a map implementation ticket without sub-issues is the single Ticket,
# an execution Ticket like any other.
SPEC_ARG=31
run_check "$WORK/impl-open.out" FIXTURE_DIR="$WORK/impl-open"
expect_exit 2 'an open map implementation ticket named on the 实现票 line fails the check'
expect_has '#40 Implementation forty' 'the implementation ticket is listed under # open' "$WORK/impl-open.out"
expect_has '剩余：#40' 'the implementation ticket is on the report line' "$WORK/impl-open.out"
expect_has '# source' 'an implementation ticket still prints # source' "$WORK/impl-open.out"
if [ "$(sed -n '/^# source$/{n;p;}' "$WORK/impl-open.out")" = '（无）' ]; then
  record PASS 'a map implementation ticket is not under # source'
else
  record FAIL 'a map implementation ticket is not under # source' "$(sed -n '/^# source$/{n;p;}' "$WORK/impl-open.out")"
fi
run_check "$WORK/impl-closed.out" FIXTURE_DIR="$WORK/impl-closed"
expect_exit 0 'a closed implementation ticket named on the 实现票 line passes'

# Kind b (票 #83): the loose source ticket a Spec was drafted from is not an
# execution Ticket. It is closed together with the Spec (step 9), so while it
# is open the check passes: counted under # open it would hold every such
# Spec back for good. It carries no label here and is still no Ticket under
# # decision: the source is accounted for under # source.
SPEC_ARG=32
run_check "$WORK/source-open.out" FIXTURE_DIR="$WORK/source-open"
expect_exit 0 'an open loose source ticket does not hold the landing back'
cat > "$WORK/source-open.expected" <<'EOF'
# open
（无）
# waiting
（无）
# human
（无）
# decision
（无）
# shelved
（无）
# source
#60 Loose source sixty（源票）
# report
（无）
EOF
expect_output "$WORK/source-open.expected" "$WORK/source-open.out" 'an open loose source ticket is listed under # source and nowhere else'
# pipeline-status.sh asks for #60's blockers once, as for every open Ticket;
# the check adds no query of its own for a source ticket.
if [ "$(sort "$WORK/source-open/blocker-calls" | uniq -c | tr -s ' ' | tr '\n' ';')" = ' 1 60;' ]; then
  record PASS 'a loose source ticket is asked for its blockers once: by the graph, not by the check'
else
  record FAIL 'a loose source ticket is asked for its blockers once: by the graph, not by the check' "blocked_by calls: $(tr '\n' ' ' < "$WORK/source-open/blocker-calls")"
fi

run_check "$WORK/source-human.out" FIXTURE_DIR="$WORK/source-human"
expect_exit 0 'a ready-for-human loose source ticket does not hold the landing back'
cat > "$WORK/source-human.expected" <<'EOF'
# open
（无）
# waiting
（无）
# human
#60 Loose source sixty（人工）
# decision
（无）
# shelved
（无）
# source
#60 Loose source sixty（源票）
# report
（无）
EOF
expect_output "$WORK/source-human.expected" "$WORK/source-human.out" 'a ready-for-human loose source ticket is under # human and # source'

run_check "$WORK/source-closed.out" FIXTURE_DIR="$WORK/source-closed"
expect_exit 0 'a closed loose source ticket passes'
expect_output "$WORK/all-closed.expected" "$WORK/source-closed.out" 'a closed loose source ticket is listed nowhere'

# --- fail closed ------------------------------------------------------------------
# Two ways, told apart by the exit code (票 #86). A Spec the graph does not
# hold will not appear by waiting: exit 3, so that step 9 parks at once instead
# of running the check again and waiting for the keeper to resume it. A query
# that failed may pass: exit 1 keeps the retry.
SPEC_ARG=404
run_check "$WORK/missing.out" FIXTURE_DIR="$WORK/all-closed"
expect_exit 3 'an unknown Spec fails closed for good: exit 3, apart from a failed query'
expect_has 'not found' 'an unknown Spec names the problem on stderr' "$WORK/missing.out.err"
expect_empty "$WORK/missing.out" 'an unknown Spec prints nothing on stdout'
expect_has 'landing-check: spec #404 not found in the test/repo graph' 'an unknown Spec is named by its number and repository on stderr' "$WORK/missing.out.err"

SPEC_ARG=10
run_check "$WORK/gh-fail.out" FIXTURE_DIR="$WORK/all-closed" FAKE_GH_FAIL=1
expect_exit 1 'a pipeline-status failure fails closed with the retried exit 1'
expect_has 'pipeline-status.sh --graph failed' 'a pipeline-status failure is explained' "$WORK/gh-fail.out.err"
expect_empty "$WORK/gh-fail.out" 'a pipeline-status failure prints nothing on stdout'

# pipeline-status.sh asks for #12's blockers once; the check's own query is
# #12's second, and that is the one made to fail here.
run_check "$WORK/blocker-fail.out" FIXTURE_DIR="$WORK/one-open" \
  FAKE_GH_FAIL_BLOCKERS_OF=12 FAKE_GH_FAIL_BLOCKERS_NTH=2
expect_exit 1 'a blocked_by failure of the check itself fails closed with the retried exit 1'
expect_has 'gh api failed for issue #12 dependencies/blocked_by' 'a blocked_by failure names the issue' "$WORK/blocker-fail.out.err"
expect_empty "$WORK/blocker-fail.out" 'a blocked_by failure prints nothing on stdout'

# --- the graph's temporary files leave with every exit ----------------------------
# scripts/lib-graph.sh, the reading layer landing-check.sh and frontier.sh
# share, keeps the graph in two temporary files and removes them on exit,
# whichever exit the check takes: 0, 2, 3 and the retried 1.
check_leaves_no_temp_file() { # NAME SPEC FIXTURE-DIR EXPECTED-EXIT [VARIABLE=value ...]
  tmp_name=$1
  SPEC_ARG=$2
  tmp_fixture=$3
  tmp_exit=$4
  shift 4
  run_check "$WORK/tmp-$tmp_name.out" FIXTURE_DIR="$tmp_fixture" TMPDIR="$WORK/tmp" "$@"
  expect_exit "$tmp_exit" "$tmp_name: the check ends with exit $tmp_exit under a private TMPDIR"
  if [ -z "$(ls -A "$WORK/tmp")" ]; then
    record PASS "$tmp_name: the graph's temporary files are removed on exit $tmp_exit"
  else
    record FAIL "$tmp_name: the graph's temporary files are removed on exit $tmp_exit" \
      "left behind: $(ls -A "$WORK/tmp" | tr '\n' ' ')"
  fi
}
mkdir -p "$WORK/tmp"
check_leaves_no_temp_file passed 10 "$WORK/all-closed" 0
check_leaves_no_temp_file open-tickets 10 "$WORK/one-open" 2
check_leaves_no_temp_file unknown-spec 404 "$WORK/all-closed" 3
check_leaves_no_temp_file failed-query 10 "$WORK/all-closed" 1 FAKE_GH_FAIL=1
SPEC_ARG=10
rmdir "$WORK/tmp"

# --- the reading layer on its own ------------------------------------------------
# scripts/lib-graph.sh keeps the tool checks of both scripts. Without gh, or
# without node, a script fails closed with the retried exit 1, and the message
# starts with the caller's name — which the library takes from GRAPH_NAME when
# the caller set it (off the caller's own file name otherwise).
mkdir -p "$BIN/only-node" "$BIN/only-gh"
ln -s "$(command -v node)" "$BIN/only-node/node" 2>/dev/null || cp "$(command -v node)" "$BIN/only-node/node"
cp "$BIN/gh" "$BIN/only-gh/gh"
lib_without() { # PATH of the run, name — what graph_require_tools does with one tool missing
  (
    export PATH="$1"
    GRAPH_NAME=landing-check
    source "$ROOT/scripts/lib-graph.sh"
    graph_require_tools
  ) > "$WORK/lib-$2.out" 2>&1
  RUN_EXIT=$?
}
lib_without "$BIN/only-node" no-gh
expect_exit 1 'without gh on PATH the reading layer fails closed with the retried exit 1'
expect_has 'landing-check: gh is required but was not found on PATH' 'without gh the message starts with the caller and names the tool' "$WORK/lib-no-gh.out"
lib_without "$BIN/only-gh" no-node
expect_exit 1 'without node on PATH the reading layer fails closed with the retried exit 1'
expect_has 'landing-check: node is required but was not found on PATH' 'without node the message starts with the caller and names the tool' "$WORK/lib-no-node.out"

# --- usage -----------------------------------------------------------------------
env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo test/repo > "$WORK/usage.out" 2> "${WORK}/usage.out.err"
RUN_EXIT=$?
expect_exit 64 'missing --spec is a usage error'
expect_has 'landing-check: --spec is required' 'a usage error names the check and the argument' "${WORK}/usage.out.err"

SPEC_ARG=abc
run_check "$WORK/usage2.out" FIXTURE_DIR="$WORK/all-closed"
expect_exit 64 'non-numeric --spec is a usage error'

env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo > "$WORK/usage4.out" 2> "${WORK}/usage4.out.err"
RUN_EXIT=$?
expect_exit 64 'a --repo without a value is a usage error'
expect_has 'landing-check: --repo requires <owner/name>' 'a --repo without a value names the option and what it needs' "${WORK}/usage4.out.err"

env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo test/repo --spec 10 --bogus > "$WORK/usage3.out" 2> "${WORK}/usage3.out.err"
RUN_EXIT=$?
expect_exit 64 'an unknown argument is a usage error'

env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --help > "$WORK/help.out" 2> "${WORK}/help.out.err"
RUN_EXIT=$?
expect_exit 0 '--help exits 0'
expect_has 'landing-check.sh --repo <owner/name> --spec <n>' '--help prints the usage' "$WORK/help.out"
expect_has '# decision' '--help documents the decision section' "$WORK/help.out"
expect_has '3  fail closed for good: the graph has no such Spec' '--help lists exit 3 apart from exit 1' "$WORK/help.out"

echo "Artifacts: $WORK"
echo "Summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
