#!/usr/bin/env bash
# Isolated fake-gh tests for find-next/scripts/publish-batch.sh.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/find-next/scripts/publish-batch.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/publish-batch-test.XXXXXX")
BIN=$WORK/bin
STATE=$WORK/state.json
LOG=$WORK/gh.log
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

expect_order() {
  first=$1
  second=$2
  name=$3
  file=$4
  first_line=$(grep -Fn -- "$first" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  second_line=$(grep -Fn -- "$second" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$first_line" ] && [ -n "$second_line" ] &&
     [ "$first_line" -lt "$second_line" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "lines=${first_line:-none},${second_line:-none}"
  fi
}

mutate_manifest() {
  file=$1
  script=$2
  FILE="$file" node -e '
    const fs = require("fs");
    const file = process.env.FILE;
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    '"$script"'
    fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
  '
}

make_case() {
  directory=$1
  mkdir -p "$directory/S1/tickets" "$directory/S2/tickets"
  printf '%s\n' 'Spec one depends on #{{S2}}.' > "$directory/S1/spec.md"
  printf '%s\n' $'## Parent\n#{{S1}}\nDo first.' > "$directory/S1/tickets/T1.md"
  printf '%s\n' 'Spec two.' > "$directory/S2/spec.md"
  printf '%s\n' $'## Parent\n#{{S1}}\nAfter #{{S1/T1}} and #{{#212}}.' \
    > "$directory/S2/tickets/T1.md"
  printf '%s\n' '{"key":"S1","title":"Spec one","body":"spec.md","tickets":[{"key":"T1","title":"Ticket one","body":"tickets/T1.md","blocked_by":[]}]}' \
    > "$directory/S1/manifest.json"
  printf '%s\n' '{"key":"S2","title":"Spec two","body":"spec.md","labels":["needs-triage"],"tickets":[{"key":"T1","title":"Ticket two","body":"tickets/T1.md","blocked_by":["S1/T1","#212"]}]}' \
    > "$directory/S2/manifest.json"
}

mkdir -p "$BIN" || exit 1
printf '%s\n' '{"nextNumber":300}' > "$STATE"
: > "$LOG"

cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
exec node "$WORK/fake-gh.js" "\$@"
EOF
chmod +x "$BIN/gh"

cat > "$WORK/fake-gh.js" <<'EOF'
const fs = require('fs');
const args = process.argv.slice(2);
const stateFile = process.env.PUBLISH_TEST_STATE;
const logFile = process.env.PUBLISH_GH_LOG;
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const method = args.includes('-X') ? args[args.indexOf('-X') + 1] : 'GET';
const endpoint = args.find((value) => value.startsWith('repos/'));
const path = endpoint ? endpoint.split('?')[0] : endpoint;
const write = ['POST', 'PATCH', 'PUT', 'DELETE'].includes(method);
state.issues = state.issues || {
  212: {number: 212, id: 10000212, title: 'Existing blocker', state: 'open', body: ''},
  47: {number: 47, id: 10000047, title: 'Standalone blocker', state: 'open', body: ''},
  48: {number: 48, id: 10000048, title: 'Existing spec', state: 'open', body: '## Problem Statement'},
  49: {number: 49, id: 10000049, title: 'Closed blocker', state: 'closed', body: ''},
  84: {number: 84, id: 10000084, title: 'Existing handoff', state: 'open', body: ''},
};
state.subIssues = state.subIssues || {};
state.blockedBy = state.blockedBy || {};
state.comments = state.comments || {};
fs.appendFileSync(logFile, `${JSON.stringify({method, endpoint, args, write})}\n`);
state.writeCount = (state.writeCount || 0) + (write ? 1 : 0);
if (write && process.env.FAKE_GH_FAIL_WRITE &&
    Number(process.env.FAKE_GH_FAIL_WRITE) === state.writeCount) {
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.stderr.write('fake gh: simulated write failure\n');
  process.exit(1);
}
function field(name) {
  const prefix = `${name}=`;
  const value = args.find((arg) => arg.startsWith(prefix));
  return value === undefined ? undefined : value.slice(prefix.length);
}
function issueByDatabase(id) {
  return Object.values(state.issues).find((issue) => issue.id === Number(id));
}
function numberFromIssueId(id) {
  const issue = issueByDatabase(id);
  return issue ? issue.number : Number(id) - 10000000;
}
function save() {
  fs.writeFileSync(stateFile, JSON.stringify(state));
}
if (args[0] === 'repo' && args[1] === 'view') {
  process.stdout.write('test/repo\n');
} else if (method === 'GET' && /^repos\/[^/]+\/[^/]+\/issues\/[0-9]+$/.test(path)) {
  const number = Number(path.split('/')[4]);
  if (!state.issues[number]) process.exit(2);
  process.stdout.write(JSON.stringify(state.issues[number]));
} else if (method === 'POST' && endpoint.endsWith('/issues')) {
  const number = state.nextNumber++;
  const issue = {
    number,
    id: 10000000 + number,
    title: field('title'),
    body: field('body'),
    labels: args.filter((arg) => arg.startsWith('labels[]=')).map((arg) => arg.slice(9)),
  };
  issue.state = 'open';
  state.issues[number] = issue;
  save();
  process.stdout.write(JSON.stringify(issue));
} else if (method === 'POST' && endpoint.endsWith('/sub_issues')) {
  const parent = Number(path.split('/')[4]);
  const childNumber = numberFromIssueId(field('sub_issue_id'));
  state.subIssues[parent] = state.subIssues[parent] || [];
  if (childNumber > 0) state.subIssues[parent].push(childNumber);
  save();
  process.stdout.write(JSON.stringify(state.issues[childNumber] || {number: childNumber}));
} else if (method === 'POST' && endpoint.endsWith('/dependencies/blocked_by')) {
  const dependent = Number(path.split('/')[4]);
  const blockerNumber = numberFromIssueId(field('issue_id'));
  state.blockedBy[dependent] = state.blockedBy[dependent] || [];
  if (blockerNumber > 0) state.blockedBy[dependent].push(blockerNumber);
  save();
  process.stdout.write(JSON.stringify(state.issues[blockerNumber] || {number: blockerNumber}));
} else if (method === 'POST' && endpoint.endsWith('/comments')) {
  const number = Number(path.split('/')[4]);
  state.comments[number] = state.comments[number] || [];
  state.comments[number].push(field('body'));
  save();
  process.stdout.write(JSON.stringify({id: 20000000 + state.comments[number].length}));
} else if (method === 'GET' && endpoint.includes('/sub_issues?')) {
  const parent = Number(path.split('/')[4]);
  const numbers = state.subIssues[parent] || [];
  const dropped = Number(process.env.FAKE_GH_DROP_SUB_ISSUE);
  const shown = numbers.filter((number) => number !== dropped);
  process.stdout.write(JSON.stringify(numbers.map((number) =>
    shown.includes(number) ? (state.issues[number] || {number}) : null
  )));
} else if (method === 'GET' && endpoint.includes('/dependencies/blocked_by?')) {
  const dependent = Number(path.split('/')[4]);
  const numbers = state.blockedBy[dependent] || [];
  process.stdout.write(JSON.stringify(numbers.map((number) =>
    state.issues[number] || {number}
  )));
} else if (method === 'PATCH' && endpoint.includes('/issues/')) {
  const number = Number(path.split('/')[4]);
  state.issues[number].body = field('body');
  save();
  process.stdout.write(JSON.stringify({number, id: 10000000 + number, body: field('body')}));
} else {
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.stderr.write(`fake gh: unexpected arguments: ${args.join(' ')}\n`);
  process.exit(2);
}
EOF

run_publish() {
  output=$1
  shift
  (
    cd "$WORK" || exit 125
    env PUBLISH_TEST_STATE="$STATE" PUBLISH_GH_LOG="$LOG" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_publish_auto_repo() {
  output=$1
  shift
  (
    cd "$WORK" || exit 125
    env PUBLISH_TEST_STATE="$STATE" PUBLISH_GH_LOG="$LOG" PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

run_publish "$WORK/help.out" --help
expect_exit 0 "help succeeds"
expect_has 'Usage: publish-batch.sh' 'help shows usage' "$WORK/help.out"

make_case "$WORK/base"
: > "$LOG"
run_publish "$WORK/base-dry.out" "$WORK/base/S1/manifest.json" "$WORK/base/S2/manifest.json"
expect_exit 0 "base dry run succeeds"
expect_has '将新建规格 S1「Spec one」 标签：ready-for-agent' \
  'dry run shows default spec label' "$WORK/base-dry.out"
expect_has '将新建规格 S2「Spec two」 标签：needs-triage' \
  'dry run shows custom spec label' "$WORK/base-dry.out"
expect_has '将新建执行票 S1/T1「Ticket one」 → 挂到 S1 下' \
  'dry run shows unblocked ticket' "$WORK/base-dry.out"
expect_has '将新建执行票 S2/T1「Ticket two」 → 挂到 S2 下，被 S1/T1、#212 挡住' \
  'dry run shows blocker order' "$WORK/base-dry.out"
expect_has '将回填正文 S1「Spec one」' \
  'dry run shows deferred body patch' "$WORK/base-dry.out"
expect_has '试运行：将发布 2 张规格、2 张执行票，加 --apply 执行' \
  'dry run summary' "$WORK/base-dry.out"
expect_has '"endpoint":"repos/test/repo/issues/212"' \
  'dry run verifies existing issue' "$LOG"
expect_without '"write":true' 'dry run sends no write request' "$LOG"

run_publish "$WORK/base-apply.out" --apply "$WORK/base/S1/manifest.json" \
  "$WORK/base/S2/manifest.json"
expect_exit 0 "base apply succeeds"
expect_has '核对：子票与阻塞关系都对上了' \
  'successful apply verifies relations' "$WORK/base-apply.out"
expect_has '已发布 2 张规格、2 张执行票' 'apply summary' "$WORK/base-apply.out"
expect_has 'S1 #300 Spec one' 'published spec number is listed' "$WORK/base-apply.out"
expect_has 'S2/T1 #303 Ticket two' 'published ticket number is listed' "$WORK/base-apply.out"
expect_order 'title=Spec one' 'title=Spec two' 'specs are created before tickets' "$LOG"
expect_order 'title=Spec two' 'title=Ticket one' 'first ticket follows all specs' "$LOG"
expect_order 'title=Ticket one' 'title=Ticket two' 'blocker is created first' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/300/sub_issues","args":["api","-X","POST","repos/test/repo/issues/300/sub_issues","-F","sub_issue_id=10000302"]' \
  'sub-issue uses spec number and ticket database id' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/301/sub_issues","args":["api","-X","POST","repos/test/repo/issues/301/sub_issues","-F","sub_issue_id=10000303"]' \
  'second sub-issue uses database id' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/303/dependencies/blocked_by","args":["api","-X","POST","repos/test/repo/issues/303/dependencies/blocked_by","-F","issue_id=10000302"]' \
  'ticket dependency uses database id' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/303/dependencies/blocked_by","args":["api","-X","POST","repos/test/repo/issues/303/dependencies/blocked_by","-F","issue_id=10000212"]' \
  'existing dependency uses database id' "$LOG"
expect_has 'After #302 and #212.' \
  'ticket placeholders resolve before creation' "$LOG"
expect_count '"method":"PATCH"' 1 'only bodies with unresolved placeholders are patched' "$LOG"
grep '"method":"PATCH"' "$LOG" > "$WORK/base-patches.log"
expect_has 'body=Spec one depends on #301.' \
  'spec placeholder is backfilled' "$WORK/base-patches.log"
expect_without '{{' 'patched body has no placeholder' "$WORK/base-patches.log"
expect_count 'labels[]=ready-for-agent' 3 'default labels are passed' "$LOG"
expect_count 'labels[]=needs-triage' 1 'custom labels are passed' "$LOG"

: > "$LOG"
run_publish "$WORK/base-rerun.out" --apply "$WORK/base/S1/manifest.json" \
  "$WORK/base/S2/manifest.json"
expect_exit 0 "completed apply reruns successfully"
expect_without '"write":true' 'completed rerun writes nothing' "$LOG"
expect_has '已发布 2 张规格、2 张执行票' 'rerun summary remains stable' "$WORK/base-rerun.out"

: > "$LOG"
run_publish_auto_repo "$WORK/auto-repo.out" "$WORK/base/S1/manifest.json" \
  "$WORK/base/S2/manifest.json"
expect_exit 0 "repository is inferred with gh repo view"
expect_has '试运行：将发布 0 张规格、0 张执行票，加 --apply 执行' \
  'inferred repository dry run is complete' "$WORK/auto-repo.out"
expect_without '"write":true' 'repository inference sends no write' "$LOG"

make_case "$WORK/unknown-ref"
mutate_manifest "$WORK/unknown-ref/S2/manifest.json" \
  'value.tickets[0].blocked_by = ["S9"];'
: > "$LOG"
run_publish "$WORK/unknown-ref.out" --apply "$WORK/unknown-ref/S1/manifest.json" \
  "$WORK/unknown-ref/S2/manifest.json"
expect_exit 1 "unknown reference fails validation"
expect_has 'unknown spec reference S9' 'unknown reference is named' \
  "$WORK/unknown-ref.out.err"
expect_without '"write":true' 'unknown reference sends no write' "$LOG"

make_case "$WORK/cycle"
mutate_manifest "$WORK/cycle/S1/manifest.json" \
  'value.tickets[0].blocked_by = ["S2/T1"];'
: > "$LOG"
run_publish "$WORK/cycle.out" --apply "$WORK/cycle/S1/manifest.json" \
  "$WORK/cycle/S2/manifest.json"
expect_exit 1 "ticket cycle fails validation"
expect_has 'execution ticket dependency cycle' 'cycle is named' "$WORK/cycle.out.err"
expect_without '"write":true' 'cycle sends no write' "$LOG"

make_case "$WORK/missing-body"
mutate_manifest "$WORK/missing-body/S1/manifest.json" 'value.body = "missing.md";'
: > "$LOG"
run_publish "$WORK/missing-body.out" --apply "$WORK/missing-body/S1/manifest.json" \
  "$WORK/missing-body/S2/manifest.json"
expect_exit 1 "missing body fails validation"
expect_has 'body file not found: missing.md' 'missing body is named' \
  "$WORK/missing-body.out.err"
expect_without '"write":true' 'missing body sends no write' "$LOG"

make_case "$WORK/missing-existing"
mutate_manifest "$WORK/missing-existing/S2/manifest.json" \
  'value.tickets[0].blocked_by = ["#999"];'
: > "$LOG"
run_publish "$WORK/missing-existing.out" --apply \
  "$WORK/missing-existing/S1/manifest.json" \
  "$WORK/missing-existing/S2/manifest.json"
expect_exit 1 "missing existing issue fails validation"
expect_has 'issues/999' 'missing existing issue is named' \
  "$WORK/missing-existing.out.err"
expect_has 'GitHub request failed at GET repos/test/repo/issues/999' \
  'gh error is surfaced' "$WORK/missing-existing.out.err"
expect_without '"write":true' 'missing existing issue sends no write' "$LOG"

make_case "$WORK/unresolved"
mutate_manifest "$WORK/unresolved/S2/manifest.json" \
  'value.unresolved = ["one question"];'
: > "$LOG"
run_publish "$WORK/unresolved.out" --apply "$WORK/unresolved/S1/manifest.json" \
  "$WORK/unresolved/S2/manifest.json"
expect_exit 1 "unresolved manifest fails validation"
expect_has 'S2 has unresolved items: one question' 'unresolved items are named' \
  "$WORK/unresolved.out.err"
expect_without '"write":true' 'unresolved manifest sends no write' "$LOG"

make_case "$WORK/unresolved-format"
mutate_manifest "$WORK/unresolved-format/S2/manifest.json" '
  value.unresolved = [
    "legacy question",
    {question: "object question", proposal: "proposed answer", affects: "spec.md scope"}
  ];
'
: > "$LOG"
run_publish "$WORK/unresolved-format.out" \
  "$WORK/unresolved-format/S1/manifest.json" \
  "$WORK/unresolved-format/S2/manifest.json"
expect_exit 0 "unresolved items do not fail dry run"
expect_has 'S2 有 2 条未决（--apply 会拒绝这份）：' \
  'unresolved section has header' "$WORK/unresolved-format.out"
expect_has '- legacy question' 'legacy unresolved item is printed' \
  "$WORK/unresolved-format.out"
expect_has '- object question → 推荐：proposed answer（影响：spec.md scope）' \
  'object unresolved item shows proposal' "$WORK/unresolved-format.out"
expect_has '将新建规格 S2「Spec two」' \
  'unresolved dry run still prints plan' "$WORK/unresolved-format.out"
expect_without '"write":true' 'unresolved dry run sends no write' "$LOG"

make_case "$WORK/unresolved-bad-object"
mutate_manifest "$WORK/unresolved-bad-object/S2/manifest.json" '
  value.unresolved = [{question: "object question", affects: "spec.md scope"}];
'
: > "$LOG"
run_publish "$WORK/unresolved-bad-object.out" \
  "$WORK/unresolved-bad-object/S1/manifest.json" \
  "$WORK/unresolved-bad-object/S2/manifest.json"
expect_exit 1 "malformed unresolved object fails validation"
expect_has 'object items require non-empty string question, proposal, and affects' \
  'missing unresolved proposal is named' "$WORK/unresolved-bad-object.out.err"
expect_without '"write":true' 'malformed unresolved object sends no write' "$LOG"

make_case "$WORK/bad-only"
: > "$LOG"
run_publish "$WORK/bad-only.out" --apply --only S9 \
  "$WORK/bad-only/S1/manifest.json" "$WORK/bad-only/S2/manifest.json"
expect_exit 1 "unknown only key fails validation"
expect_has '--only references unknown spec key: S9' 'unknown only key is named' \
  "$WORK/bad-only.out.err"
expect_without '"write":true' 'unknown only key sends no write' "$LOG"

make_case "$WORK/only"
mutate_manifest "$WORK/only/S1/manifest.json" \
  'value.unresolved = ["not selected here"];'
: > "$LOG"
run_publish "$WORK/only-no-record.out" --apply --only S2 \
  "$WORK/only/S1/manifest.json" "$WORK/only/S2/manifest.json"
expect_exit 1 "only without required record fails"
expect_has 'S1/T1 has no publish record and is outside --only' \
  'missing cross-manifest record is named' "$WORK/only-no-record.out.err"
expect_without '"write":true' 'only without record sends no write' "$LOG"

cat > "$WORK/only/S1/published.json" <<'EOF'
{
  "repo": "test/repo",
  "issues": {
    "S1": {"key": "S1", "type": "spec", "number": 250, "databaseId": 10000250, "title": "Old spec one"},
    "T1": {"key": "T1", "type": "ticket", "number": 251, "databaseId": 10000251, "title": "Old ticket one"}
  },
  "relations": ["sub:S1/T1"]
}
EOF
: > "$LOG"
run_publish "$WORK/only-record.out" --apply --only S2 \
  "$WORK/only/S1/manifest.json" "$WORK/only/S2/manifest.json"
expect_exit 0 "only uses existing publish record"
expect_has '已发布 1 张规格、1 张执行票' 'only summary counts selection' \
  "$WORK/only-record.out"
expect_without 'Spec one' 'excluded spec is not published' "$WORK/only-record.out"
expect_without 'Ticket one' 'excluded ticket is not published' "$WORK/only-record.out"
expect_count 'title=Spec two' 1 'only creates selected spec once' "$LOG"
expect_count 'title=Ticket two' 1 'only creates selected ticket once' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/304/sub_issues","args":["api","-X","POST","repos/test/repo/issues/304/sub_issues","-F","sub_issue_id=10000305"]' \
  'only sub-issue uses database ids' "$LOG"
expect_has '"endpoint":"repos/test/repo/issues/305/dependencies/blocked_by","args":["api","-X","POST","repos/test/repo/issues/305/dependencies/blocked_by","-F","issue_id=10000251"]' \
  'only dependency uses record database id' "$LOG"
expect_has 'After #251 and #212.' 'only placeholders use record number' "$LOG"

make_case "$WORK/retry"
: > "$LOG"
STATE="$STATE" node -e '
  const fs = require("fs");
  const file = process.env.STATE;
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  state.writeCount = 0;
  fs.writeFileSync(file, JSON.stringify(state));
'
FAKE_GH_FAIL_WRITE=4
export FAKE_GH_FAIL_WRITE
run_publish "$WORK/retry-failed.out" --apply \
  "$WORK/retry/S1/manifest.json" "$WORK/retry/S2/manifest.json"
unset FAKE_GH_FAIL_WRITE
expect_exit 1 "write failure stops publication"
expect_has 'fake gh: simulated write failure' 'write failure is surfaced' \
  "$WORK/retry-failed.out.err"
expect_has '"endpoint":"repos/test/repo/issues/306/sub_issues"' \
  'failure happens after ticket creation' "$LOG"
expect_has '已新建执行票 S1/T1' 'issue created before failure is recorded in output' \
  "$WORK/retry-failed.out"
expect_has '"number": 308' 'failed run has durable issue record' \
  "$WORK/retry/S1/published.json"

FAILED_LOG=$LOG
LOG=$WORK/retry-resumed.log
: > "$LOG"
run_publish "$WORK/retry-resumed.out" --apply \
  "$WORK/retry/S1/manifest.json" "$WORK/retry/S2/manifest.json"
cat "$FAILED_LOG" "$LOG" > "$WORK/retry-all.log"
LOG=$WORK/retry-all.log
expect_exit 0 "retry after write failure succeeds"
expect_has '已发布 2 张规格、2 张执行票' 'retry summary is stable' \
  "$WORK/retry-resumed.out"
expect_count 'title=Spec one' 1 'retry does not duplicate first spec' "$LOG"
expect_count 'title=Spec two' 1 'retry does not duplicate second spec' "$LOG"
expect_count 'title=Ticket one' 1 'retry does not duplicate first ticket' "$LOG"
expect_count 'title=Ticket two' 1 'retry does not duplicate second ticket' "$LOG"
expect_count '"endpoint":"repos/test/repo/issues/306/sub_issues"' 2 \
  'failed sub-issue is retried exactly once more' "$LOG"
expect_count '"endpoint":"repos/test/repo/issues/306/sub_issues"' 1 \
  'incomplete sub-issue is retried once' "$WORK/retry-resumed.log"
expect_count '"endpoint":"repos/test/repo/issues/307/sub_issues"' 1 \
  'retry creates remaining sub-issue relation once' "$WORK/retry-resumed.log"
expect_count '"endpoint":"repos/test/repo/issues/309/dependencies/blocked_by"' 2 \
  'retry creates each dependency once' "$LOG"
expect_count '"method":"PATCH"' 1 'retry patches only pending body once' "$LOG"
expect_has '"sub:S1/T1"' 'sub relation is recorded' "$WORK/retry/S1/published.json"
expect_has '"dependency:S2/T1<-S1/T1"' 'ticket dependency is recorded' \
  "$WORK/retry/S2/published.json"
expect_has '"dependency:S2/T1<-#212"' 'existing dependency is recorded' \
  "$WORK/retry/S2/published.json"

make_case "$WORK/handoffs"
mutate_manifest "$WORK/handoffs/S2/manifest.json" '
  value.handoffs = [{issue: 84, note: "Please include #{{S2}} when writing #84."}];
'
: > "$LOG"
run_publish "$WORK/handoffs-dry.out" \
  "$WORK/handoffs/S1/manifest.json" "$WORK/handoffs/S2/manifest.json"
expect_exit 0 "handoffs pass dry run"
expect_has '将在 #84 留言（来自 S2）：Please include #{{S2}} when writing #84.…' \
  'dry run previews handoff note' "$WORK/handoffs-dry.out"
expect_without '"write":true' 'handoff dry run sends no write' "$LOG"

: > "$LOG"
run_publish "$WORK/handoffs-apply.out" --apply \
  "$WORK/handoffs/S1/manifest.json" "$WORK/handoffs/S2/manifest.json"
expect_exit 0 "handoffs apply succeeds"
HANDOFF_SPEC=$(node -e '
  const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(value.issues.S2.number));
' "$WORK/handoffs/S2/published.json")
grep '"endpoint":"repos/test/repo/issues/84/comments"' "$LOG" \
  > "$WORK/handoff-comments.log"
expect_has "body=Please include #${HANDOFF_SPEC} when" \
  'handoff note renders spec number' "$WORK/handoff-comments.log"
expect_has "（规格 #${HANDOFF_SPEC} 批量发布时留下）" \
  'handoff note has source suffix' "$WORK/handoff-comments.log"
expect_has '"handoff:0:84"' 'handoff is recorded' \
  "$WORK/handoffs/S2/published.json"

: > "$LOG"
run_publish "$WORK/handoffs-rerun.out" --apply \
  "$WORK/handoffs/S1/manifest.json" "$WORK/handoffs/S2/manifest.json"
expect_exit 0 "handoff rerun succeeds"
expect_without '"write":true' 'handoff rerun does not comment twice' "$LOG"

make_case "$WORK/handoff-missing"
mutate_manifest "$WORK/handoff-missing/S2/manifest.json" '
  value.handoffs = [{issue: 999, note: "Missing target."}];
'
: > "$LOG"
run_publish "$WORK/handoff-missing.out" --apply \
  "$WORK/handoff-missing/S1/manifest.json" \
  "$WORK/handoff-missing/S2/manifest.json"
expect_exit 1 "missing handoff issue fails validation"
expect_has 'GitHub request failed at GET repos/test/repo/issues/999' \
  'missing handoff issue is named' "$WORK/handoff-missing.out.err"
expect_without '"write":true' 'missing handoff issue sends no write' "$LOG"

make_case "$WORK/start-order"
mkdir -p "$WORK/start-order/S3/tickets"
printf '%s\n' '{"key":"S1","title":"Ready spec","body":"spec.md","tickets":[{"key":"T1","title":"Ready ticket","body":"tickets/T1.md","blocked_by":[]}]}' \
  > "$WORK/start-order/S1/manifest.json"
printf '%s\n' '## Parent
#{{S1}}
Ready.' > "$WORK/start-order/S1/tickets/T1.md"
printf '%s\n' '{"key":"S2","title":"Partial spec","body":"spec.md","tickets":[{"key":"T1","title":"Local ready","body":"tickets/T1.md","blocked_by":[]},{"key":"T2","title":"Other spec blocker","body":"tickets/T2.md","blocked_by":["S1"]},{"key":"T3","title":"Standalone blocker","body":"tickets/T3.md","blocked_by":["#47"]},{"key":"T4","title":"Indirect blocker","body":"tickets/T4.md","blocked_by":["T3"]},{"key":"T5","title":"Closed blocker ignored","body":"tickets/T5.md","blocked_by":["#49"]}]}' \
  > "$WORK/start-order/S2/manifest.json"
for ticket in T1 T2 T3 T4 T5; do
  printf '## Parent\n#{{S2}}\nTicket %s.\n' "$ticket" \
    > "$WORK/start-order/S2/tickets/$ticket.md"
done
printf '%s\n' '{"key":"S3","title":"Waiting spec","body":"spec.md","tickets":[{"key":"T1","title":"Other ticket blocker","body":"tickets/T1.md","blocked_by":["S2/T2"]},{"key":"T2","title":"Internal indirect","body":"tickets/T2.md","blocked_by":["T1"]},{"key":"T3","title":"Existing spec blocker","body":"tickets/T3.md","blocked_by":["#48"]}]}' \
  > "$WORK/start-order/S3/manifest.json"
for ticket in T1 T2 T3; do
  printf '## Parent\n#{{S3}}\nTicket %s.\n' "$ticket" \
    > "$WORK/start-order/S3/tickets/$ticket.md"
done
printf '%s\n' 'Ready spec body.' > "$WORK/start-order/S1/spec.md"
printf '%s\n' 'Partial spec body.' > "$WORK/start-order/S2/spec.md"
printf '%s\n' 'Waiting spec body.' > "$WORK/start-order/S3/spec.md"

: > "$LOG"
run_publish "$WORK/start-order-dry.out" \
  "$WORK/start-order/S1/manifest.json" \
  "$WORK/start-order/S2/manifest.json" \
  "$WORK/start-order/S3/manifest.json"
expect_exit 0 "start-order dry run succeeds"
expect_has '- 现在可开：S1 Ready spec' \
  'dry start order shows ready spec' "$WORK/start-order-dry.out"
expect_has '- 部分可开：S2 Partial spec：可先做 S2/T1、S2/T5；S2/T2 要等 S1（同批规格）、S2/T3 要等 #47（单独的票，implement-spec-split 不会处理，需另行安排）、S2/T4 要等 #47（单独的票，implement-spec-split 不会处理，需另行安排）' \
  'dry start order explains partial blockers' "$WORK/start-order-dry.out"
expect_has '- 要等：S3 Waiting spec：全部执行票要等 S2（同批规格）、#48（已有规格）' \
  'dry start order shows fully blocked spec' "$WORK/start-order-dry.out"
expect_without 'S2/T5 要等' 'closed existing blocker is ignored' \
  "$WORK/start-order-dry.out"

: > "$LOG"
run_publish "$WORK/start-order-apply.out" --apply \
  "$WORK/start-order/S1/manifest.json" \
  "$WORK/start-order/S2/manifest.json" \
  "$WORK/start-order/S3/manifest.json"
expect_exit 0 "start-order apply succeeds"
ORDER_NUMBERS=$(node -e '
  const fs = require("fs");
  const root = process.argv[1];
  const issue = (spec, key) => JSON.parse(
    fs.readFileSync(`${root}/${spec}/published.json`, "utf8")
  ).issues[key].number;
  process.stdout.write([
    issue("S1", "S1"), issue("S2", "S2"), issue("S2", "T1"),
    issue("S2", "T2"), issue("S2", "T3"), issue("S2", "T4"),
    issue("S2", "T5"), issue("S3", "S3"),
  ].join(" "));
' "$WORK/start-order")
read S1_NUM S2_NUM S2T1_NUM S2T2_NUM S2T3_NUM S2T4_NUM S2T5_NUM S3_NUM <<EOF
$ORDER_NUMBERS
EOF
expect_has "- 现在可开：#${S1_NUM} Ready spec" \
  'apply start order uses ready spec number' "$WORK/start-order-apply.out"
expect_has "- 部分可开：#${S2_NUM} Partial spec：可先做 #${S2T1_NUM}、#${S2T5_NUM}；#${S2T2_NUM} 要等 #${S1_NUM}（同批规格）、#${S2T3_NUM} 要等 #47（单独的票，implement-spec-split 不会处理，需另行安排）、#${S2T4_NUM} 要等 #47（单独的票，implement-spec-split 不会处理，需另行安排）" \
  'apply start order explains real ticket numbers' "$WORK/start-order-apply.out"
expect_has "- 要等：#${S3_NUM} Waiting spec：全部执行票要等 #${S2_NUM}（同批规格）、#48（已有规格）" \
  'apply start order shows real waiting spec' "$WORK/start-order-apply.out"

make_case "$WORK/unresolved-only"
mutate_manifest "$WORK/unresolved-only/S2/manifest.json" \
  'value.unresolved = [{question: "wait", proposal: "yes", affects: "scope"}];'
printf '%s\n' 'Spec one.' > "$WORK/unresolved-only/S1/spec.md"
: > "$LOG"
run_publish "$WORK/unresolved-only.out" --apply --only S1 \
  "$WORK/unresolved-only/S1/manifest.json" \
  "$WORK/unresolved-only/S2/manifest.json"
expect_exit 0 "only excludes manifest with unresolved items"
expect_has '已发布 1 张规格、1 张执行票' \
  'only publishes clean unresolved-free manifest' "$WORK/unresolved-only.out"

make_case "$WORK/non-placeholder-braces"
printf '%s\n' $'Literal secret {{sshmgr-secret:DB_PASSWORD}} and #{{S1}}.' \
  > "$WORK/non-placeholder-braces/S1/spec.md"
printf '%s\n' $'Ticket secret {{sshmgr-secret:DB_PASSWORD}} and #{{T1}}.' \
  > "$WORK/non-placeholder-braces/S1/tickets/T1.md"
: > "$LOG"
run_publish "$WORK/non-placeholder-braces-dry.out" \
  "$WORK/non-placeholder-braces/S1/manifest.json"
expect_exit 0 "non-placeholder braces pass dry-run validation"
expect_without 'invalid reference' \
  'non-placeholder braces are not validated as references' \
  "$WORK/non-placeholder-braces-dry.out.err"
expect_without '"write":true' 'non-placeholder dry run sends no write' "$LOG"

literal_spec=$(STATE="$STATE" node -e '
  const fs = require("fs");
  const state = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
  process.stdout.write(String(state.nextNumber));
')
literal_ticket=$((literal_spec + 1))
: > "$LOG"
run_publish "$WORK/non-placeholder-braces-apply.out" --apply \
  "$WORK/non-placeholder-braces/S1/manifest.json"
expect_exit 0 "non-placeholder braces pass apply validation"

grep '"method":"POST"' "$LOG" | grep 'title=Spec one' \
  > "$WORK/non-placeholder-spec-post.log"
grep '"method":"POST"' "$LOG" | grep 'title=Ticket one' \
  > "$WORK/non-placeholder-ticket-post.log"
grep '"method":"PATCH"' "$LOG" > "$WORK/non-placeholder-patches.log"
expect_has 'body=Literal secret {{sshmgr-secret:DB_PASSWORD}} and #{{S1}}.' \
  'spec literal braces survive initial POST' "$WORK/non-placeholder-spec-post.log"
expect_has 'body=Ticket secret {{sshmgr-secret:DB_PASSWORD}} and #' \
  'ticket literal braces survive POST' "$WORK/non-placeholder-ticket-post.log"
expect_has "body=Literal secret {{sshmgr-secret:DB_PASSWORD}} and #${literal_spec}." \
  'spec literal braces and ticket number survive PATCH' \
  "$WORK/non-placeholder-patches.log"
expect_has "body=Ticket secret {{sshmgr-secret:DB_PASSWORD}} and #${literal_ticket}." \
  'ticket literal braces and ticket number survive PATCH' \
  "$WORK/non-placeholder-patches.log"
expect_without '#{{S1}}' 'spec placeholder is replaced in PATCH' \
  "$WORK/non-placeholder-patches.log"
expect_without '#{{T1}}' 'ticket placeholder is replaced in PATCH' \
  "$WORK/non-placeholder-patches.log"
expect_count '"method":"PATCH"' 2 \
  'bodies with real placeholders are patched once each' "$LOG"

make_case "$WORK/only-non-placeholder-braces"
printf '%s\n' 'Literal secret {{sshmgr-secret:X}}.' \
  > "$WORK/only-non-placeholder-braces/S1/spec.md"
printf '%s\n' 'Ticket literal secret {{sshmgr-secret:X}}.' \
  > "$WORK/only-non-placeholder-braces/S1/tickets/T1.md"
: > "$LOG"
run_publish "$WORK/only-non-placeholder-braces.out" --apply \
  "$WORK/only-non-placeholder-braces/S1/manifest.json"
expect_exit 0 "literal-only bodies publish successfully"
expect_count '"method":"PATCH"' 0 \
  'literal-only bodies do not create backfill patches' "$LOG"
expect_without '将回填正文' 'literal-only patch notice is absent' \
  "$WORK/only-non-placeholder-braces.out"
expect_without '"patchPending": true' \
  'literal-only publish record has no pending patch' \
  "$WORK/only-non-placeholder-braces/S1/published.json"

make_case "$WORK/verify-missing-sub"
VERIFY_SPEC=$(STATE="$STATE" node -e '
  const state = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
  process.stdout.write(String(state.nextNumber));
')
VERIFY_SPEC=$((VERIFY_SPEC + 1))
VERIFY_TICKET=$((VERIFY_SPEC + 2))
FAKE_GH_DROP_SUB_ISSUE=$VERIFY_TICKET
export FAKE_GH_DROP_SUB_ISSUE
: > "$LOG"
run_publish "$WORK/verify-missing-sub.out" --apply \
  "$WORK/verify-missing-sub/S1/manifest.json" \
  "$WORK/verify-missing-sub/S2/manifest.json"
unset FAKE_GH_DROP_SUB_ISSUE
expect_exit 1 "missing read-back sub-issue fails apply"
expect_has "规格 #${VERIFY_SPEC} 缺子票 #${VERIFY_TICKET}" \
  'missing read-back sub-issue is named' "$WORK/verify-missing-sub.out"
expect_has 'publish-batch: publication verification failed' \
  'read-back failure is surfaced' "$WORK/verify-missing-sub.out.err"
expect_has '"write":true' 'read-back failure happens after writes' "$LOG"

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
