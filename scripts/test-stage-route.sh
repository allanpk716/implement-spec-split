#!/usr/bin/env bash
# Deterministic tests for scripts/stage-route.sh, the Stage route table (ADR
# 0004). Everything runs against a scratch state file and a fake date, so the
# suite never touches the user's real table. Only outside behaviour is checked:
# stdout, stderr, the exit code, the state file a command writes, and the text
# of the /grill-router skill.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROUTER=$HERE/stage-route.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/stage-route-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
STATE_FILE=$WORK/state/stage-route
mkdir -p "$BIN" "$WORK/state"

PASSED=0
FAILED=0
RUN_EXIT=
RUN_STDOUT=$WORK/stdout.txt
RUN_STDERR=$WORK/stderr.txt

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    rm -r "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

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

expect_stdout() {
  expected=$1
  name=$2
  if [ "$(cat "$RUN_STDOUT")" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "stdout=$(tr '\n' '|' < "$RUN_STDOUT")"
  fi
}

expect_stdout_has() {
  text=$1
  name=$2
  if grep -Fq -- "$text" "$RUN_STDOUT" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in stdout"
  fi
}

expect_stderr_has() {
  text=$1
  name=$2
  if grep -Fq -- "$text" "$RUN_STDERR" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in stderr"
  fi
}

expect_stderr_empty() {
  name=$1
  if [ -s "$RUN_STDERR" ]; then
    record FAIL "$name" "stderr=$(tr '\n' '|' < "$RUN_STDERR")"
  else
    record PASS "$name"
  fi
}

expect_state() {
  expected=$1
  name=$2
  if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "state=$(tr '\n' ' ' < "$STATE_FILE" 2>/dev/null)"
  fi
}

expect_file_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in $(basename "$file")"
  fi
}

expect_stderr_lines() {
  expected=$1
  name=$2
  actual=$(wc -l < "$RUN_STDERR" | tr -d ' ')
  if [ "$actual" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "stderr has $actual lines, expected $expected: $(tr '\n' '|' < "$RUN_STDERR")"
  fi
}

# The fake date answers +%s from FAKE_DATE_NOW and passes everything else on.
cat > "$BIN/date" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ -n "${FAKE_DATE_NOW:-}" ]; then
  printf '%s\n' "$FAKE_DATE_NOW"
  exit 0
fi
/bin/date "$@"
FAKE
chmod +x "$BIN/date"

export PATH="$BIN:$PATH"
export ISS_STAGE_ROUTE_FILE=$STATE_FILE
export FAKE_DATE_NOW=1000000000

run_router() {
  "$ROUTER" "$@" > "$RUN_STDOUT" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

# The default table, as the spec fixes it (issue #25, Implementation Decisions).
ORCH_LOCKED='编排（orchestration）：claude-flash / glm-5.3-flash / 启动器默认（锁定，不可改）'
DESIGN_DEFAULT='讨论（design）：claude / opus / high（默认）'
RESEARCH_DEFAULT='调研起草（research）：codex-glm / glm-5.4 / high（默认）'
IMPLEMENTATION_DEFAULT='实现（implementation）：claude-glm / glm-5.4 / high（默认）'
REVIEW_DEFAULT='审查（review）：claude / opus / high（默认）'
DIAGNOSIS_DEFAULT='诊断（diagnosis）：claude / opus / high（默认）'
DEFAULT_TABLE="$ORCH_LOCKED
$DESIGN_DEFAULT
$RESEARCH_DEFAULT
$IMPLEMENTATION_DEFAULT
$REVIEW_DEFAULT
$DIAGNOSIS_DEFAULT"

# Without a state file the table is the default, in stage order.
rm -f "$STATE_FILE"
run_router
expect_exit 0 'status works without a state file'
expect_stdout "$DEFAULT_TABLE" 'status shows the six default routes'
expect_stderr_empty 'status with no state file prints nothing on stderr'

# --print answers one field of a stage.
run_router --print design model
expect_exit 0 '--print exits 0 without a state file'
expect_stdout opus 'design defaults to opus'
run_router --print design profile
expect_stdout claude 'design defaults to the claude profile'
run_router --print design effort
expect_stdout high 'design defaults to effort high'
run_router --print research profile
expect_stdout codex-glm 'research defaults to the codex-glm profile'
run_router --print research model
expect_stdout glm-5.4 'research defaults to glm-5.4'
run_router --print implementation profile
expect_stdout claude-glm 'implementation defaults to the claude-glm profile'
run_router --print implementation effort
expect_stdout high 'implementation defaults to effort high'
run_router --print review model
expect_stdout opus 'review defaults to opus'
run_router --print diagnosis model
expect_stdout opus 'diagnosis defaults to opus, the same as review'
run_router --print orchestration profile
expect_stdout claude-flash 'orchestration is on the claude-flash profile'
run_router --print orchestration model
expect_stdout glm-5.3-flash 'orchestration is on glm-5.3-flash'

# A stage without --print's field prints its status line; until prints nothing.
run_router --print design
expect_exit 0 '--print with a stage alone exits 0'
expect_stdout "$DESIGN_DEFAULT" '--print with a stage alone prints its status line'
run_router --print design until
expect_exit 0 '--print until exits 0 when the stage has no expiry'
expect_stdout '' '--print until prints no line when the stage has no expiry'

# use sets the stage it names and leaves every other stage alone.
run_router use design=claude-glm/glm-5.4/high
expect_exit 0 'use with one stage is accepted'
expect_state 'design=claude-glm/glm-5.4/high' 'use records only the stage it sets'
expect_stdout "$ORCH_LOCKED
讨论（design）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use design=claude/opus/high
$RESEARCH_DEFAULT
$IMPLEMENTATION_DEFAULT
$REVIEW_DEFAULT
$DIAGNOSIS_DEFAULT" 'use prints the status of all six stages'
run_router --print design profile
expect_stdout claude-glm 'the stage use set prints its profile'
run_router --print design effort
expect_stdout high 'the stage use set prints its effort'
run_router --print review model
expect_stdout opus 'a stage the command does not name keeps its route'
run_router
expect_stdout_has "$REVIEW_DEFAULT" 'status still shows the unnamed stage on its default'

# One command sets several stages; the file stays in stage order.
run_router use research=codex-glm/glm-5.3/xhigh diagnosis=claude-glm/glm-5.4/low
expect_exit 0 'one command sets two stages'
expect_state 'design=claude-glm/glm-5.4/high
research=codex-glm/glm-5.3/xhigh
diagnosis=claude-glm/glm-5.4/low' 'one command records every stage it sets'
expect_stdout "$ORCH_LOCKED
讨论（design）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use design=claude/opus/high
调研起草（research）：codex-glm / glm-5.3 / xhigh，不会自动切回；切回用 /grill-router use research=codex-glm/glm-5.4/high
$IMPLEMENTATION_DEFAULT
$REVIEW_DEFAULT
诊断（diagnosis）：claude-glm / glm-5.4 / low，不会自动切回；切回用 /grill-router use diagnosis=claude/opus/high" 'a multi-stage command prints all six status lines'
run_router --print research effort
expect_stdout xhigh 'a stage set in a multi-stage command prints its effort'
run_router --print diagnosis profile
expect_stdout claude-glm 'another stage of the same command prints its profile'

# Setting a stage back to its default drops its line and leaves the rest.
run_router use design=claude/opus/high
expect_exit 0 'a stage can be set back to its default'
expect_state 'research=codex-glm/glm-5.3/xhigh
diagnosis=claude-glm/glm-5.4/low' 'a stage back on its default leaves the table'

# The file is written even when nothing is left in it.
run_router use research=codex-glm/glm-5.4/high diagnosis=claude/opus/high
expect_exit 0 'the last two stages go back to their defaults'
if [ -f "$STATE_FILE" ]; then
  record PASS 'the table file exists when every stage is on its default'
else
  record FAIL 'the table file exists when every stage is on its default'
fi
expect_state '' 'an all-default table is an empty file'
run_router
expect_stdout "$DEFAULT_TABLE" 'an empty table shows the defaults'

# --until takes an ISO 8601 time with its offset and stores it as epoch seconds.
rm -f "$STATE_FILE"
run_router use review=claude/opus/medium --until 2026-11-28T10:00:00+08:00
expect_exit 0 'an absolute --until is accepted'
expect_state 'review=claude/opus/medium@1795831200' '--until is stored as epoch seconds on the stage it sets'
FAKE_DATE_NOW=1000000000
run_router --print review effort
expect_stdout medium 'a route that has not expired is in effect'
run_router --print review until
expect_exit 0 '--print until exits 0 for a route with an expiry'
expect_stdout 1795831200 '--print until gives the epoch seconds of a route in effect'
run_router
expect_stdout_has '审查（review）：claude / opus / medium，到 ' 'status reports the expiry time'
expect_stdout_has '自动切回默认' 'status says the route reverts by itself'
if grep -Eq '到 [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{2}:[0-9]{2} 自动切回默认' "$RUN_STDOUT"; then
  record PASS 'the expiry time is shown with its UTC offset'
else
  record FAIL 'the expiry time is shown with its UTC offset' "stdout=$(tr '\n' '|' < "$RUN_STDOUT")"
fi
FAKE_DATE_NOW=1795831200
run_router --print review effort
expect_stdout high 'a route whose time has arrived is back on its default'
run_router --print review until
expect_exit 0 '--print until exits 0 once the route has expired'
expect_stdout '' '--print until prints nothing once the route has expired'
run_router
expect_stdout_has '审查（review）：claude / opus / high（默认；表里的 claude / opus / medium 已于 ' 'status reports an expired route'
expect_stdout_has '到期）' 'status says the route has expired'
expect_state 'review=claude/opus/medium@1795831200' 'reading an expired route leaves the table alone'
FAKE_DATE_NOW=1000000000
run_router --print review effort
expect_stdout medium 'a route is in effect again before its time'

# Expiry is per stage: an unnamed stage keeps its own expiry.
run_router use design=claude-glm/glm-5.4/high --until 2001-09-09T01:46:40Z
expect_exit 0 '--until accepts a time in Z'
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude/opus/medium@1795831200' 'each stage keeps its own expiry'
run_router --print design profile
expect_stdout claude 'the expired stage is on its default profile'
run_router --print review effort
expect_stdout medium 'the stage still in effect keeps its effort'
run_router
if grep -Fq '已于' "$RUN_STDOUT" && grep -Fq '自动切回默认' "$RUN_STDOUT"; then
  record PASS 'status tells an expired stage from one still switched'
else
  record FAIL 'status tells an expired stage from one still switched' "stdout=$(tr '\n' '|' < "$RUN_STDOUT")"
fi

# --for adds a duration to the clock.
run_router use diagnosis=claude-glm/glm-5.4/low --for 2d12h
expect_exit 0 '--for accepts a compound duration'
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude/opus/medium@1795831200
diagnosis=claude-glm/glm-5.4/low@1000216000' '--for stores now plus the duration for the stages it sets'
run_router use diagnosis=claude-glm/glm-5.4/low --for 90m
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude/opus/medium@1795831200
diagnosis=claude-glm/glm-5.4/low@1000005400' '--for accepts minutes'
run_router use diagnosis=claude-glm/glm-5.4/low --for 45s
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude/opus/medium@1795831200
diagnosis=claude-glm/glm-5.4/low@1000000045' '--for accepts seconds'
for duration in 5x h 1h30 0 ''; do
  run_router use diagnosis=claude-glm/glm-5.4/low --for "$duration"
  expect_exit 64 "--for rejects '$duration'"
  expect_stderr_has '--for must be a duration' "--for rejects '$duration' with a reason"
done
run_router use diagnosis=claude-glm/glm-5.4/low --for 0d
expect_exit 64 '--for rejects a zero duration'
expect_stderr_has 'greater than zero' '--for rejects a zero duration with a reason'
run_router use diagnosis=claude-glm/glm-5.4/low --until
expect_exit 64 'a missing --until value is a usage error'
run_router use diagnosis=claude-glm/glm-5.4/low --until '明天早上十点'
expect_exit 64 'an unparseable --until is a usage error'
expect_stderr_has '--until must be an ISO 8601 time' 'an unparseable --until names the format'
run_router use diagnosis=claude-glm/glm-5.4/low --until 2026-11-28T10:00:00
expect_exit 64 '--until without a UTC offset is a usage error'
expect_stderr_has 'UTC offset' '--until without a UTC offset says what is missing'
run_router use diagnosis=claude-glm/glm-5.4/low --until 2026-11-28
expect_exit 64 'a date alone is not a time for --until'
run_router use diagnosis=claude-glm/glm-5.4/low --for 1h --until 2026-11-28T10:00:00+08:00
expect_exit 64 '--until and --for cannot share one command'
run_router use --for 1h
expect_exit 64 'an expiry without a route is a usage error'
run_router use diagnosis=claude/opus/high --for 1h
expect_exit 64 'an expiry on a route equal to the default is a usage error'
expect_stderr_has 'default' 'an expiry on a default route names the default'
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude/opus/medium@1795831200
diagnosis=claude-glm/glm-5.4/low@1000000045' 'bad usage leaves the table alone'

# In a command with an expiry, a stage set to its default gets no expiry.
run_router use research=codex-glm/glm-5.4/high review=claude-glm/glm-5.4/medium --for 1h
expect_exit 0 'a command can mix a default route and a timed one'
expect_state 'design=claude-glm/glm-5.4/high@1000000000
review=claude-glm/glm-5.4/medium@1000003600
diagnosis=claude-glm/glm-5.4/low@1000000045' 'only the stage off its default carries the expiry'
rm -f "$STATE_FILE"
FAKE_DATE_NOW=1000000000

# Bad usage never changes the table.
rm -f "$STATE_FILE"
run_router use design=claude-glm/glm-5.4/high
expect_exit 0 'a baseline route is set before the refusals'
BEFORE_STATE=$(cat "$STATE_FILE")

# A combination outside the verified catalog is refused and the catalog named.
run_router use implementation=claude/opus/high
expect_exit 64 'claude/opus is not accepted for implementation'
expect_stderr_has 'not in the verified catalog for implementation' 'the refusal names the stage'
expect_stderr_has 'verified for implementation: claude-glm/glm-5.4, codex-glm/glm-5.4, codex-glm/glm-5.3' \
  'the refusal lists what is verified for the stage, its default first'
run_router use design=codex-glm/glm-5.4/high
expect_exit 64 'codex-glm is not accepted for design'
expect_stderr_has 'verified for design: claude/opus, claude-glm/glm-5.4, claude-flash/glm-5.4' \
  'the refusal lists what is verified for design'
run_router use research=claude-glm/glm-5.4/high
expect_exit 64 'claude-glm is not accepted for research'
expect_stderr_has 'verified for research: codex-glm/glm-5.4, codex-glm/glm-5.3' \
  'the refusal lists what is verified for research'
run_router use review=claude-flash/glm-5.4/high
expect_exit 64 'claude-flash is not accepted for review'
run_router use diagnosis=claude-flash/glm-5.4/high
expect_exit 64 'claude-flash is not accepted for diagnosis'
run_router use research=codex-glm/glm-5.3-flash/high
expect_exit 64 'an unverified model is refused even on the right profile'
expect_stderr_has 'codex-glm/glm-5.3-flash' 'the refusal repeats the combination asked for'

# The locked stage cannot be set, not even to its own default.
run_router use orchestration=claude-flash/glm-5.3-flash/high
expect_exit 64 'orchestration cannot be set'
expect_stderr_has 'locked' 'the refusal says the stage is locked'
run_router use orchestration=claude-glm/glm-5.4/high
expect_exit 64 'orchestration cannot be switched either'

# An effort the profile does not take is refused; claude profiles take max.
run_router use implementation=codex-glm/glm-5.4/max
expect_exit 64 'codex-glm does not take max'
expect_stderr_has "codex-glm does not accept effort 'max'" 'the refusal names the effort'
expect_stderr_has 'accepts: low, medium, high, xhigh' 'the refusal lists the efforts codex-glm takes'
run_router use implementation=claude-glm/glm-5.4/max
expect_exit 0 'claude-glm takes max'
expect_state 'design=claude-glm/glm-5.4/high
implementation=claude-glm/glm-5.4/max' 'a claude-glm route with effort max is recorded'
run_router use implementation=claude-glm/glm-5.4/high
expect_exit 0 'the baseline route is restored'
expect_state "$BEFORE_STATE" 'the table is back to the baseline'

# One bad setting in a command refuses the whole command.
run_router use design=claude/opus/high implementation=claude/opus/high
expect_exit 64 'a command with one refused setting exits 64'
expect_stderr_has 'implementation' 'the refusal names the offending stage'
expect_state "$BEFORE_STATE" 'a refused command changes nothing, not even its valid setting'

# Unknown names and malformed routes.
run_router use grill=claude/opus/high
expect_exit 64 'an unknown stage is a usage error'
expect_stderr_has 'stages: orchestration, design, research, implementation, review, diagnosis' \
  'an unknown stage lists the stages'
run_router use design=gpt/x/high
expect_exit 64 'an unknown profile is a usage error'
expect_stderr_has 'profiles: claude, claude-glm, claude-flash, codex-glm' 'an unknown profile lists the profiles'
run_router use design=claude-glm
expect_exit 64 'a route without model and effort is a usage error'
expect_stderr_has '<profile>/<model>/<effort>' 'a malformed route names the shape'
run_router use design=claude-glm/glm-5.4
expect_exit 64 'a route without effort is a usage error'
run_router use design=claude-glm/glm-5.4/high design=claude/opus/high
expect_exit 64 'a stage named twice is a usage error'
run_router use design=claude-glm/glm-5.4/high --nonsense
expect_exit 64 'an unknown option after use is a usage error'
run_router use
expect_exit 64 'use without a route is a usage error'
run_router design=claude-glm/glm-5.4/high
expect_exit 64 'a route without use is a usage error'
expect_stderr_has 'stage-route.sh use design=' 'a route without use shows the command to run'
run_router --nonsense
expect_exit 64 'an unknown argument is a usage error'
run_router nonsense
expect_exit 64 'an unknown command is a usage error'
expect_state "$BEFORE_STATE" 'none of the bad usage reached the table'

# --print misuse.
run_router --print
expect_exit 64 '--print without a stage is a usage error'
run_router --print code
expect_exit 64 '--print with an unknown stage is a usage error'
run_router --print design speed
expect_exit 64 '--print with an unknown field is a usage error'
expect_stderr_has 'profile, model, effort, until' '--print with an unknown field lists the fields'
run_router --print design model effort
expect_exit 64 '--print with two fields is a usage error'
run_router --print design model
expect_stdout glm-5.4 '--print still answers after the refusals'

# A review on the same model as implementation warns once and is not refused.
rm -f "$STATE_FILE"
run_router use review=claude-glm/glm-5.4/medium
expect_exit 0 'review on glm-5.4 is accepted although implementation is on glm-5.4'
expect_stderr_lines 1 'the same-model warning is one line'
expect_stderr_has '警告' 'the same-model warning says it is a warning'
expect_stderr_has 'glm-5.4' 'the same-model warning names the model'
expect_state 'review=claude-glm/glm-5.4/medium' 'the warning does not refuse the route'
run_router
expect_exit 0 'status works while review and implementation share a model'
expect_stderr_empty 'status does not repeat the warning'
run_router use design=claude-glm/glm-5.4/low
expect_stderr_lines 1 'a later command warns once again while the two stages share a model'
run_router use review=claude-glm/glm-5.4/medium implementation=claude-glm/glm-5.4/high
expect_stderr_lines 1 'a command that sets both stages warns once, not twice'
run_router use implementation=codex-glm/glm-5.4/high
expect_exit 0 'implementation on codex-glm glm-5.4 is accepted'
expect_stderr_lines 1 'the warning compares models across profiles'
run_router use implementation=codex-glm/glm-5.3/high
expect_exit 0 'implementation on glm-5.3 is accepted'
expect_stderr_empty 'different models do not warn'
run_router use review=claude/opus/medium implementation=claude-glm/glm-5.4/high
expect_stderr_empty 'the default review model does not warn'
run_router use research=codex-glm/glm-5.3-flash/high --for 1h
expect_exit 64 'a refused command warns about nothing'
expect_stderr_lines 1 'a refused command prints only its refusal'
run_router use review=claude-glm/glm-5.4/medium --until 2001-09-09T01:46:40Z
expect_exit 0 'a review route that is already expired is accepted'
expect_stderr_empty 'an expired route counts as its default and does not warn'
rm -f "$STATE_FILE"

# A line outside the catalog puts that stage on its default; the rest still read.
printf 'design=claude-glm/glm-5.4/high\nresearch=claude-glm/glm-5.4/high\n' > "$STATE_FILE"
run_router --print research model
expect_exit 0 '--print exits 0 on a combination outside the catalog'
expect_stdout glm-5.4 'the stage outside the catalog reads its default model, which happens to be the same'
run_router --print research profile
expect_stdout codex-glm 'the stage outside the catalog reads its default profile'
run_router --print design model
expect_stdout glm-5.4 'a valid line next to an unknown one still reads'
run_router
expect_stdout_has '调研起草（research）：codex-glm / glm-5.4 / high（默认；表里的 claude-glm / glm-5.4 / high 不在已验证目录）' 'status names the combination outside the catalog'
expect_stderr_has 'research=claude-glm/glm-5.4/high' 'the hint names the line outside the catalog'
expect_stderr_has '不在已验证目录' 'the hint says why'
expect_stderr_lines 1 'one line outside the catalog gives one hint'
expect_state 'design=claude-glm/glm-5.4/high
research=claude-glm/glm-5.4/high' 'reading a line outside the catalog leaves the table alone'

printf 'design=claude-glm/glm-5.4/max\nimplementation=codex-glm/glm-5.4/max\n' > "$STATE_FILE"
run_router --print implementation effort
expect_stdout high 'an effort the profile does not take reads as the default'
run_router --print design effort
expect_stdout max 'an effort the profile takes still reads'
expect_stderr_has 'implementation=codex-glm/glm-5.4/max' 'the hint names the line with the bad effort'

printf 'orchestration=claude-glm/glm-5.4/high\n' > "$STATE_FILE"
run_router --print orchestration profile
expect_stdout claude-flash 'a line for the locked stage is ignored'
run_router
expect_stdout_has "$ORCH_LOCKED" 'the locked stage shows its locked default whatever the file says'
expect_stderr_has 'orchestration=claude-glm/glm-5.4/high' 'a line for the locked stage is reported'

# A table that does not parse puts all six stages on their defaults, said once on stderr.
for content in garbage 'design=claude-glm' 'design=claude-glm/glm-5.4' 'design=claude-glm/glm-5.4/high/soon' \
  'design=claude-glm/glm-5.4/high@soon' 'grill=claude/opus/high' 'design claude-glm/glm-5.4/high' \
  '# a comment' '=claude/opus/high'; do
  printf '%s\n' "$content" > "$STATE_FILE"
  run_router --print design model
  expect_exit 0 "--print exits 0 on a table that does not parse ($content)"
  expect_stdout opus "a table that does not parse reads as the default ($content)"
  run_router --print implementation model
  expect_stdout glm-5.4 "every stage reads as its default ($content)"
  expect_stderr_has '无法解析' "a table that does not parse is reported ($content)"
done
printf 'design=claude-glm/glm-5.4/high\nreview=claude-glm/glm-5.4/low\nnonsense\n' > "$STATE_FILE"
run_router
expect_exit 0 'status exits 0 on a malformed table'
expect_stdout "$DEFAULT_TABLE" 'one malformed line puts all six stages on their defaults'
expect_stderr_lines 1 'a malformed table gives one line on stderr'
expect_stderr_has '第 3 行：nonsense' 'the hint names the offending line'
expect_state 'design=claude-glm/glm-5.4/high
review=claude-glm/glm-5.4/low
nonsense' 'reading a malformed table leaves it alone'

# Missing or unreadable is not corruption: defaults, nothing on stderr.
rm -f "$STATE_FILE"
mkdir "$STATE_FILE"
run_router --print design model
expect_stdout opus 'a directory in place of the table reads as the default'
expect_stderr_empty 'a directory in place of the table is not reported'
rmdir "$STATE_FILE"

# Blank lines, spaces and CRLF endings are tolerated.
printf '\n\ndesign=claude-glm/glm-5.4/high\n\n' > "$STATE_FILE"
run_router --print design model
expect_stdout glm-5.4 'blank lines are not corruption'
expect_stderr_empty 'blank lines are not reported'
printf ' design = claude-glm / glm-5.4 / high \n' > "$STATE_FILE"
run_router --print design profile
expect_stdout claude-glm 'spaces inside a line are tolerated'
printf 'design=claude-glm/glm-5.4/high\r\n' > "$STATE_FILE"
run_router --print design effort
expect_stdout high 'a CRLF line ending is tolerated'

# use repairs a malformed table and says so once.
printf 'garbage\n' > "$STATE_FILE"
run_router use design=claude-glm/glm-5.4/high
expect_exit 0 'use works on a malformed table'
expect_stderr_lines 1 'use on a malformed table reports it once'
expect_stderr_has '无法解析' 'use on a malformed table reports what was wrong'
expect_state 'design=claude-glm/glm-5.4/high' 'use replaces a malformed table'
rm -f "$STATE_FILE"

# --print never answers with an empty line: with no value it exits 66.
run_router --print orchestration effort
expect_exit 66 'the locked stage has no effort to print and exits 66'
expect_stdout '' 'a missing value prints no line'
expect_stderr_has 'orchestration' 'a missing value says which stage'

# --launch prints the launcher and its arguments, one per line.
rm -f "$STATE_FILE"
run_router --launch design interactive
expect_exit 0 '--launch works without a state file'
expect_stdout 'claude
--model
opus
--effort
high' 'the default design route starts the official launcher with model and effort'
run_router --launch review headless
expect_stdout 'claude
-p
--model
opus
--effort
high' 'the headless form of a claude profile adds -p'
run_router use design=claude-glm/glm-5.4/medium
run_router --launch design interactive
expect_stdout 'claude-glm
--model
glm-5.4[1m]
--effort
medium' 'claude-glm passes its model with the 1M suffix'
run_router --launch design headless
expect_stdout 'claude-glm
-p
--model
glm-5.4[1m]
--effort
medium' 'claude-glm has a headless form'
run_router use design=claude-flash/glm-5.4/high
run_router --launch design interactive
expect_stdout 'claude-flash
--model
glm-5.4[1m]
--effort
high' 'claude-flash passes its model with the 1M suffix'
run_router --launch design headless
expect_stdout 'claude-flash
-p
--model
glm-5.4[1m]
--effort
high' 'claude-flash has a headless form'
run_router --launch research headless
expect_stdout 'codex
exec
-m
glm-5.4
-c
model_reasoning_effort=high' 'codex-glm starts codex exec with -m and model_reasoning_effort'
run_router --launch research interactive
expect_stdout 'codex
-m
glm-5.4
-c
model_reasoning_effort=high' 'codex-glm has an interactive form'
run_router use implementation=codex-glm/glm-5.3/xhigh
run_router --launch implementation headless
expect_stdout 'codex
exec
-m
glm-5.3
-c
model_reasoning_effort=xhigh' '--launch follows a switched stage'

# --launch follows the effective route: expired and broken tables give the default.
run_router use design=claude-glm/glm-5.4/low --until 2001-09-09T01:46:40Z
run_router --launch design interactive
expect_stdout 'claude
--model
opus
--effort
high' '--launch follows an expired route back to its default'
printf 'garbage\n' > "$STATE_FILE"
run_router --launch review headless
expect_exit 0 '--launch exits 0 on a malformed table'
expect_stdout 'claude
-p
--model
opus
--effort
high' '--launch answers the default on a malformed table'
expect_stderr_has '无法解析' '--launch reports a malformed table on stderr'

# --launch misuse prints nothing.
rm -f "$STATE_FILE"
run_router --launch
expect_exit 64 '--launch without a stage is a usage error'
run_router --launch design
expect_exit 64 '--launch without a form is a usage error'
expect_stderr_has 'interactive' '--launch without a form names the forms'
run_router --launch design sideways
expect_exit 64 '--launch with an unknown form is a usage error'
run_router --launch orchestration interactive
expect_exit 64 'the locked stage has no launch command'
expect_stderr_has 'locked' 'the locked stage says it is locked'
run_router --launch code interactive
expect_exit 64 '--launch with an unknown stage is a usage error'
run_router --launch design interactive extra
expect_exit 64 '--launch with too many arguments is a usage error'
expect_stdout '' 'a refused --launch prints nothing'

# The table location follows ISS_STAGE_ROUTE_FILE.
OTHER_FILE=$WORK/other/stage-route
ISS_STAGE_ROUTE_FILE=$OTHER_FILE "$ROUTER" use design=claude-glm/glm-5.4/low > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_exit 0 'ISS_STAGE_ROUTE_FILE relocates the table and creates its directory'
if [ -f "$OTHER_FILE" ]; then
  record PASS 'the relocated table is written'
else
  record FAIL 'the relocated table is written'
fi
rm -f "$STATE_FILE"
run_router --print design model
expect_stdout opus 'the default location ignores the relocated table'
rm -f "$OTHER_FILE"

# Help is the header.
run_router --help
expect_exit 0 'help succeeds'
expect_stderr_empty 'help prints nothing on stderr'
expect_stdout_has 'stage-route.sh use <stage>=<profile>/<model>/<effort>' 'help documents use'
expect_stdout_has -- '--print <stage> [profile|model|effort|until]' 'help documents --print with its fields'
expect_stdout_has -- '--launch <stage> <interactive|headless>' 'help documents --launch'
expect_stdout_has 'orchestration   编排' 'help lists the stages with their Chinese names'
expect_stdout_has 'diagnosis       诊断' 'help lists the last stage'
expect_stdout_has 'ISS_STAGE_ROUTE_FILE' 'help names the replacement variable'
expect_stdout_has 'claude-glm' 'help names the profiles'
expect_stdout_has 'claude-flash / glm-5.4      design' 'help lists the catalog'

# migrate is reserved for #29.
run_router migrate
expect_exit 64 'migrate exits 64 until #29 implements it'
expect_stderr_has 'migrate' 'migrate says it is not available yet'

# The user-facing command is the grill-router skill.
# The skill text checks all read the same file.
expect_skill_has() {
  expect_file_has "$1" "$2" "$SKILL"
}

ROOT=$(cd "$HERE/.." && pwd)
SKILL=$ROOT/grill-router/SKILL.md
expect_skill_has 'name: grill-router' 'the grill-router skill has its name'
expect_skill_has 'disable-model-invocation: true' 'only the user can invoke the router skill'
expect_skill_has '输入 /grill-router 时使用' 'the skill description names the slash command'
expect_skill_has 'scripts/stage-route.sh' 'the skill runs the router script'
expect_skill_has '原样照抄' 'the skill relays the script status lines verbatim'
expect_skill_has 'stage-route.sh use' 'the skill shows the use command'
expect_skill_has '--until' 'the skill knows --until'
expect_skill_has '--for' 'the skill knows --for'
expect_skill_has 'date ' 'the skill looks at the date and time zone before converting a time'
expect_skill_has '不替用户决定' 'the skill does not decide for the user'
expect_skill_has '认不出' 'the skill has a rule for words it cannot recognise'
expect_skill_has '退出码 64' 'the skill relays usage errors'
expect_skill_has '正在跑的会话' 'the skill says running sessions are not affected'
expect_skill_has '不会自动切回' 'the skill reminds how to switch back'
if sed -n '1p' "$SKILL" 2>/dev/null | grep -qx -- '---' &&
  sed -n '2p' "$SKILL" 2>/dev/null | grep -qx 'name: grill-router' &&
  sed -n '4p' "$SKILL" 2>/dev/null | grep -qx 'disable-model-invocation: true' &&
  sed -n '5p' "$SKILL" 2>/dev/null | grep -qx -- '---'; then
  record PASS 'the skill frontmatter is name, description, disable-model-invocation in that order'
else
  record FAIL 'the skill frontmatter is name, description, disable-model-invocation in that order' "head=$(head -5 "$SKILL" 2>/dev/null | tr '\n' '|')"
fi
expect_file_has 'bash scripts/test-stage-route.sh' 'MAINTAINING registers the test in its self-test list' "$ROOT/MAINTAINING.md"

# --- summary ---

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
