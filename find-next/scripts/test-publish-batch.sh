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
const write = ['POST', 'PATCH', 'PUT', 'DELETE'].includes(method);
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
if (args[0] === 'repo' && args[1] === 'view') {
  process.stdout.write('test/repo\n');
} else if (method === 'GET' && /^repos\/[^/]+\/[^/]+\/issues\/212$/.test(endpoint)) {
  process.stdout.write(JSON.stringify({number: 212, id: 10000212, title: 'Existing blocker'}));
} else if (method === 'POST' && endpoint.endsWith('/issues')) {
  const number = state.nextNumber++;
  const issue = {
    number,
    id: 10000000 + number,
    title: field('title'),
    body: field('body'),
    labels: args.filter((arg) => arg.startsWith('labels[]=')).map((arg) => arg.slice(9)),
  };
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.stdout.write(JSON.stringify(issue));
} else if (method === 'POST' && endpoint.endsWith('/sub_issues')) {
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.stdout.write(JSON.stringify({number: field('sub_issue_id')}));
} else if (method === 'POST' && endpoint.endsWith('/dependencies/blocked_by')) {
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.stdout.write(JSON.stringify({number: field('issue_id')}));
} else if (method === 'PATCH' && endpoint.includes('/issues/')) {
  fs.writeFileSync(stateFile, JSON.stringify(state));
  const number = Number(endpoint.split('/')[4]);
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
expect_has 'fake gh: unexpected arguments' 'gh error is surfaced' \
  "$WORK/missing-existing.out.err"
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

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
