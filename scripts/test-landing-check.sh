#!/usr/bin/env bash
# Deterministic tests for scripts/landing-check.sh. They run the real
# pipeline-status.sh against a fake gh, so the Spec-to-Ticket resolution, the
# blocked_by queries and the three kinds of open Ticket that do not block a
# landing are covered end to end without network access.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/landing-check.sh
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

// The Tickets of Spec #10, and the issues outside it.
const t11 = (state = 'closed', labels = []) => issue(11, 'Ticket eleven', state, labels);
const t12 = (state = 'closed', labels = [], title = 'Ticket twelve') => issue(12, title, state, labels);
const t13 = (state = 'closed', labels = []) => issue(13, 'Ticket thirteen', state, labels);
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
spec10('shelved-open', [t11(), t12('open', [], '【搁置】Ticket twelve'), t13()]);
spec10('waiting-outside', [t11(), t12('open'), t13()], {12: [outside[0]]});
spec10('waiting-chain', [t11('open'), t12('open'), t13()], {11: [outside[0]], 12: [t11('open')]});
spec10('waiting-human-chain', [t11('open', ['ready-for-human']), t12('open'), t13()], {12: [t11('open', ['ready-for-human'])]});
spec10('mixed', [t11(), t12('open'), t13('open')], {12: [outside[0]]});
spec10('closed-blocker', [t11(), t12('open'), t13()], {12: [outside[1]]});
spec10('blocked-ascending', [t11(), t12('open'), t13('open')], {12: [outside22, outside[1], outside[0]]}, [outside22]);

// A Spec whose Tickets come from its `实现票：` line: #31 names the
// implementation ticket #40, which has no sub-issues and is the single Ticket.
for (const [name, state] of [['impl-open', 'open'], ['impl-closed', 'closed']]) {
  const spec31 = issue(31, 'Single-ticket spec', 'open', [], '实现票：#40\n\n## Problem Statement\nOne ticket.', sub(0));
  const impl = issue(40, 'Implementation forty', state);
  write(name, [spec31, impl, ...outside], {}, {});
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
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/dependencies/blocked_by.*#\1#p')
    printf '%s\n' "$number" >> "$FIXTURE_DIR/blocker-calls"
    # FAKE_GH_FAIL_BLOCKER_NUMBER / _NTH fail the Nth query of that one issue.
    nth=$(grep -cx "$number" "$FIXTURE_DIR/blocker-calls" | tr -d ' ')
    if [ "$number" = "${FAKE_GH_FAIL_BLOCKER_NUMBER:-}" ] && [ "$nth" = "${FAKE_GH_FAIL_BLOCKER_NTH:-}" ]; then
      printf '%s\n' "fake gh: blocked_by unavailable for #$number on its query $nth" >&2
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
# shelved
（无）
EOF
expect_output "$WORK/all-closed.expected" "$WORK/all-closed.out" 'every Ticket closed: the four sections are printed as empty'
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
# shelved
（无）
EOF
expect_output "$WORK/one-open.expected" "$WORK/one-open.out" 'an open Ticket is listed under # open with the other sections empty'
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
# shelved
（无）
EOF
expect_output "$WORK/chain-open.expected" "$WORK/chain-open.out" 'the chain behind an open Ticket is # open too, each naming its open blockers'

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

run_check "$WORK/shelved-open.out" FIXTURE_DIR="$WORK/shelved-open"
expect_exit 0 'an open shelved Ticket does not hold the landing back'
expect_has '#12 【搁置】Ticket twelve（搁置）' 'an open shelved Ticket is listed under # shelved' "$WORK/shelved-open.out"
if [ "$(sed -n '2p' "$WORK/shelved-open.out")" = '（无）' ]; then
  record PASS 'a shelved Ticket is not under # open'
else
  record FAIL 'a shelved Ticket is not under # open' "$(sed -n 2p "$WORK/shelved-open.out")"
fi

# --- a Ticket that waits for another Spec: listed under # waiting, exit 0 -------
# A partial landing lands what is done, so a Ticket blocked by an open issue
# outside the Spec must not hold the landing back.
run_check "$WORK/waiting-outside.out" FIXTURE_DIR="$WORK/waiting-outside"
expect_exit 0 'a Ticket blocked by an issue outside the Spec does not hold the landing back'
expect_has '#12 Ticket twelve（阻塞：#20）' 'a waiting Ticket is listed under # waiting with its blocker' "$WORK/waiting-outside.out"
expect_has '# waiting' 'the # waiting section is printed' "$WORK/waiting-outside.out"
if [ "$(sed -n '2p' "$WORK/waiting-outside.out")" = '（无）' ]; then
  record PASS 'a waiting Ticket is not under # open'
else
  record FAIL 'a waiting Ticket is not under # open' "$(sed -n 2p "$WORK/waiting-outside.out")"
fi

# A chain behind such a Ticket waits too.
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
# shelved
（无）
EOF
expect_output "$WORK/waiting-chain.expected" "$WORK/waiting-chain.out" 'the chain behind a waiting Ticket is listed under # waiting, ascending'

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
# shelved
（无）
EOF
expect_output "$WORK/waiting-human-chain.expected" "$WORK/waiting-human-chain.out" 'the chain behind a human Ticket is under # waiting, the Ticket itself under # human'

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
# shelved
（无）
EOF
expect_output "$WORK/mixed.expected" "$WORK/mixed.out" 'a waiting Ticket and an open Ticket are sorted into their sections'

# A closed blocker leaves nothing open: the Ticket is # open, without blockers.
run_check "$WORK/closed-blocker.out" FIXTURE_DIR="$WORK/closed-blocker"
expect_exit 2 'a Ticket whose blockers are all closed is not waiting'
expect_has '#12 Ticket twelve' 'a Ticket with closed blockers only is listed under # open' "$WORK/closed-blocker.out"
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
# shelved
（无）
EOF
expect_output "$WORK/blocked-ascending.expected" "$WORK/blocked-ascending.out" 'several open blockers are listed ascending under # waiting'

# --- a Spec without Tickets passes ----------------------------------------------
SPEC_ARG=30
run_check "$WORK/empty.out" FIXTURE_DIR="$WORK/one-open"
expect_exit 0 'a Spec without Tickets passes'
expect_output "$WORK/all-closed.expected" "$WORK/empty.out" 'a Spec without Tickets prints the four empty sections'

# --- a Spec whose Ticket is the implementation ticket its 实现票 line names ------
SPEC_ARG=31
run_check "$WORK/impl-open.out" FIXTURE_DIR="$WORK/impl-open"
expect_exit 2 'an open implementation ticket named on the 实现票 line fails the check'
expect_has '#40 Implementation forty' 'the implementation ticket is listed under # open' "$WORK/impl-open.out"
run_check "$WORK/impl-closed.out" FIXTURE_DIR="$WORK/impl-closed"
expect_exit 0 'a closed implementation ticket named on the 实现票 line passes'

# --- fail closed ------------------------------------------------------------------
SPEC_ARG=404
run_check "$WORK/missing.out" FIXTURE_DIR="$WORK/all-closed"
expect_exit 1 'an unknown Spec fails closed'
expect_has 'not found' 'an unknown Spec names the problem on stderr' "$WORK/missing.out.err"
expect_empty "$WORK/missing.out" 'an unknown Spec prints nothing on stdout'

SPEC_ARG=10
run_check "$WORK/gh-fail.out" FIXTURE_DIR="$WORK/all-closed" FAKE_GH_FAIL=1
expect_exit 1 'a pipeline-status failure fails closed'
expect_has 'pipeline-status.sh --graph failed' 'a pipeline-status failure is explained' "$WORK/gh-fail.out.err"
expect_empty "$WORK/gh-fail.out" 'a pipeline-status failure prints nothing on stdout'

# pipeline-status.sh asks for #12's blockers once; the check's own query is
# #12's second, and that is the one made to fail here.
run_check "$WORK/blocker-fail.out" FIXTURE_DIR="$WORK/one-open" \
  FAKE_GH_FAIL_BLOCKER_NUMBER=12 FAKE_GH_FAIL_BLOCKER_NTH=2
expect_exit 1 'a blocked_by failure of the check itself fails closed'
expect_has 'gh api failed for issue #12 dependencies/blocked_by' 'a blocked_by failure names the issue' "$WORK/blocker-fail.out.err"
expect_empty "$WORK/blocker-fail.out" 'a blocked_by failure prints nothing on stdout'

# --- usage -----------------------------------------------------------------------
env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo test/repo > "$WORK/usage.out" 2> "$WORK/usage.out.err"
RUN_EXIT=$?
expect_exit 64 'missing --spec is a usage error'

SPEC_ARG=abc
run_check "$WORK/usage2.out" FIXTURE_DIR="$WORK/all-closed"
expect_exit 64 'non-numeric --spec is a usage error'

env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --repo test/repo --spec 10 --bogus > "$WORK/usage3.out" 2> "$WORK/usage3.out.err"
RUN_EXIT=$?
expect_exit 64 'an unknown argument is a usage error'

env FIXTURE_DIR="$WORK/all-closed" PATH="$BIN:$PATH" \
  bash "$SCRIPT" --help > "$WORK/help.out" 2> "$WORK/help.out.err"
RUN_EXIT=$?
expect_exit 0 '--help exits 0'
expect_has 'landing-check.sh --repo <owner/name> --spec <n>' '--help prints the usage' "$WORK/help.out"

echo "Artifacts: $WORK"
echo "Summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
