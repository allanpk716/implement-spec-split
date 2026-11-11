#!/usr/bin/env bash
# Isolated fake-gh tests for find-next/scripts/make-batch-briefs.sh.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/find-next/scripts/make-batch-briefs.sh
TMP_BASE=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${TMP_BASE%/}/make-batch-briefs-test.XXXXXX")
WORK=${WORK%/}
REPO=$WORK/repo
BIN=$WORK/bin
SKILLS=$WORK/skills-root
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
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text]"
  else
    record PASS "$name"
  fi
}

expect_pattern_without() {
  pattern=$1
  name=$2
  file=$3
  if grep -Eq -- "$pattern" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected pattern [$pattern]"
  else
    record PASS "$name"
  fi
}

expect_first_line() {
  text=$1
  name=$2
  file=$3
  first=$(head -n 1 "$file" 2>/dev/null)
  if [ "$first" = "$text" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "first line is [$first]"
  fi
}

expect_no_directory() {
  path=$1
  name=$2
  if [ -e "$path" ]; then
    record FAIL "$name" "unexpected path exists: $path"
  else
    record PASS "$name"
  fi
}

mkdir -p "$BIN" "$REPO" || exit 1
git -C "$REPO" init -q || exit 1
: > "$LOG"

for version in 1.3.1 1.10.0; do
  for skill in to-spec to-tickets; do
    directory=$SKILLS/$version/skills/engineering/$skill
    mkdir -p "$directory"
    printf '%s %s\n' "$version" "$skill" > "$directory/SKILL.md"
  done
done

cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
exec node "$WORK/fake-gh.js" "\$@"
EOF
chmod +x "$BIN/gh"

cat > "$WORK/fake-gh.js" <<'EOF'
const fs = require('fs');
const args = process.argv.slice(2);
const logFile = process.env.MAKE_BATCH_BRIEFS_GH_LOG;
const issues = new Map([
  [22, {number: 22, title: 'Map twenty-two'}],
  [23, {number: 23, title: 'Map twenty-three'}],
  [62, {number: 62, title: 'Ticket alpha', parent: 22}],
  [63, {number: 63, title: 'Ticket beta', parent: 22}],
  [64, {number: 64, title: 'Ticket other map', parent: 23}],
  [74, {number: 74, title: 'Ticket gamma', parent: 23}],
]);
fs.appendFileSync(logFile, `${JSON.stringify({args})}\n`);
if (args[0] === 'repo' && args[1] === 'view') {
  process.stdout.write('test/repo\n');
  process.exit(0);
}
if (args[0] !== 'issue' || args[1] !== 'view') {
  process.stderr.write(`fake gh: unexpected command: ${args.join(' ')}\n`);
  process.exit(2);
}
const number = Number(args[2]);
const issue = issues.get(number);
if (!issue) {
  process.stderr.write(`fake gh: unknown issue #${number}\n`);
  process.exit(1);
}
const fieldsArgument = args[args.indexOf('--json') + 1];
const fields = fieldsArgument.split(',');
const result = {number: issue.number};
if (fields.includes('title')) result.title = issue.title;
if (fields.includes('parent')) result.parent = issue.parent === undefined
  ? null
  : {number: issue.parent, title: `Map ${issue.parent}`};
process.stdout.write(`${JSON.stringify(result)}\n`);
EOF

run_brief() {
  output=$1
  shift
  (
    cd "$REPO" || exit 125
    env MAKE_BATCH_BRIEFS_GH_LOG="$LOG" \
      FIND_NEXT_SKILLS_ROOT="$SKILLS" PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo "$@"
  ) > "$output" 2> "${output}.err"
  RUN_EXIT=$?
}

SUCCESS=$WORK/success
NOTE=$WORK/s2-note.md
printf '%s\n' 'S2-only supplementary material.' > "$NOTE"
run_brief "$WORK/success.out" --example 205 --note "S2=$NOTE" \
  "$SUCCESS" S1=62,63 S2=74
expect_exit 0 "two groups generate successfully"
expect_has "$SUCCESS/S1/brief.md" "S1 brief path is printed" "$WORK/success.out"
expect_has "$SUCCESS/S2/brief.md" "S2 brief path is printed" "$WORK/success.out"
expect_has "--brief $SUCCESS/S1/brief.md --run-dir $SUCCESS/S1" \
  "S1 worker command is printed" "$WORK/success.out"
expect_has "--brief $SUCCESS/S2/brief.md --run-dir $SUCCESS/S2" \
  "S2 worker command is printed" "$WORK/success.out"

expect_pattern_without '@@[A-Z_]+@@' 'S1 has no variable left' "$SUCCESS/S1/brief.md"
expect_pattern_without '@@[A-Z_]+@@' 'S2 has no variable left' "$SUCCESS/S2/brief.md"
expect_first_line '# 任务：为地图实现票 #62、#63 起草一份规格和它的执行票（只写草稿，不发布）' \
  'opening HTML comment is removed' "$SUCCESS/S1/brief.md"
expect_has '地图 #22「Map twenty-two」下的实现票 #62「Ticket alpha」、#63「Ticket beta」' \
  'S1 map and tickets are substituted' "$SUCCESS/S1/brief.md"
expect_has '地图 #23「Map twenty-three」下的实现票 #74「Ticket gamma」' \
  'S2 map and tickets are substituted' "$SUCCESS/S2/brief.md"
expect_has "$SUCCESS/S1/spec.md" 'S1 group directory is absolute' "$SUCCESS/S1/brief.md"
expect_has '- S1 · 地图 #22 · 覆盖 #62「Ticket alpha」、#63「Ticket beta」' \
  'S1 appears in every groups list' "$SUCCESS/S2/brief.md"
expect_has '- S2 · 地图 #23 · 覆盖 #74「Ticket gamma」' \
  'S2 appears in every groups list' "$SUCCESS/S1/brief.md"
expect_has '本组是 S1。' 'S1 key is substituted' "$SUCCESS/S1/brief.md"
expect_has '#{{S1}}' 'original template placeholder remains' "$SUCCESS/S1/brief.md"
expect_has 'skills-root/1.10.0/skills/engineering/to-spec/SKILL.md' \
  'latest to-spec wins numeric version sort' "$SUCCESS/S1/brief.md"
expect_has 'skills-root/1.10.0/skills/engineering/to-tickets/SKILL.md' \
  'latest to-tickets wins numeric version sort' "$SUCCESS/S1/brief.md"
expect_has '## 本组补充' 'S2 note heading is inserted' "$SUCCESS/S2/brief.md"
expect_has 'S2-only supplementary material.' 'S2 note content is inserted' "$SUCCESS/S2/brief.md"
expect_without 'S2-only supplementary material.' \
  'S2 note is absent from S1' "$SUCCESS/S1/brief.md"

MISMATCH=$WORK/mismatch
run_brief "$WORK/mismatch.out" --example 205 "$MISMATCH" S1=62,64
expect_exit 1 'mixed parents are rejected'
expect_has 'different parent maps' 'mixed-parent error is explained' \
  "$WORK/mismatch.out.err"
expect_no_directory "$MISMATCH" 'mixed-parent failure writes no files'

DUPLICATE=$WORK/duplicate-key
run_brief "$WORK/duplicate-key.out" --example 205 "$DUPLICATE" S1=62 S1=63
expect_exit 1 'duplicate group keys are rejected'
expect_has 'duplicate group key: S1' 'duplicate-key error is explained' \
  "$WORK/duplicate-key.out.err"
expect_no_directory "$DUPLICATE" 'duplicate-key failure writes no files'

OVERLAP=$WORK/overlap
run_brief "$WORK/overlap.out" --example 205 "$OVERLAP" S1=62 S2=62
expect_exit 1 'a ticket in two groups is rejected'
expect_has 'ticket #62 appears in more than one group' \
  'overlapping-ticket error is explained' "$WORK/overlap.out.err"
expect_no_directory "$OVERLAP" 'overlapping-ticket failure writes no files'

EXISTING=$WORK/existing
mkdir -p "$EXISTING/S1"
printf '%s\n' 'existing brief' > "$EXISTING/S1/brief.md"
run_brief "$WORK/existing.out" --example 205 "$EXISTING" S1=62 S2=74
expect_exit 1 'an existing brief is rejected without --force'
expect_has 'brief already exists' 'existing-brief error is explained' \
  "$WORK/existing.out.err"
if [ "$(cat "$EXISTING/S1/brief.md")" = 'existing brief' ]; then
  record PASS 'existing brief is not replaced'
else
  record FAIL 'existing brief was replaced'
fi
expect_no_directory "$EXISTING/S2" 'existing-brief failure writes no later group'

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
