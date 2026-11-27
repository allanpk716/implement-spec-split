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

# The fake date answers +%s from FAKE_DATE_NOW, fails on it when FAKE_DATE_FAIL
# is set, and passes everything else on.
cat > "$BIN/date" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ -n "${FAKE_DATE_NOW:-}" ]; then
  [ -z "${FAKE_DATE_FAIL:-}" ] || exit 1
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

# --- The two old switches migrate into the table (#29) ---
# The old settings are read from next to the table, as judgment-model and
# worker-model, in the format the old scripts wrote. The migration reads those
# files itself: the old scripts are never run.

expect_file_missing() {
  file=$2
  name=$1
  if [ ! -e "$file" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "$(basename "$file") still exists"
  fi
}

expect_file_content() {
  expected=$1
  name=$2
  file=$3
  if [ -f "$file" ] && [ "$(cat "$file")" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "file=$(tr '\n' ' ' < "$file" 2>/dev/null)"
  fi
}

# Exactly one line of stdout matches the extended regex $1 in full.
expect_stdout_line_matches() {
  pattern="^($1)\$"
  name=$2
  if grep -Eq -- "$pattern" "$RUN_STDOUT" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "no stdout line matches [$1]: $(tr '\n' '|' < "$RUN_STDOUT")"
  fi
}

# Exactly $2 lines of stderr match the extended regex $1.
expect_stderr_matching() {
  pattern=$1
  count=$2
  name=$3
  actual=$(grep -Ec -- "$pattern" "$RUN_STDERR" 2>/dev/null)
  if [ "$actual" -eq "$count" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "$actual lines match, expected $count: $(tr '\n' '|' < "$RUN_STDERR")"
  fi
}

# A stage reads back as the route <profile>/<model>/<effort>[@<until>] through
# --print; an empty until is a stage without an expiry.
expect_route() {
  local stage=$1 profile=$2 model=$3 effort=$4 until=$5
  run_router --print "$stage" profile
  expect_stdout "$profile" "$stage reads its profile $profile"
  run_router --print "$stage" model
  expect_stdout "$model" "$stage reads its model $model"
  run_router --print "$stage" effort
  expect_stdout "$effort" "$stage reads its effort $effort"
  run_router --print "$stage" until
  expect_stdout "$until" "$stage reads its expiry '${until:-none}'"
}

OLD_JUDGMENT=$WORK/state/judgment-model
OLD_WORKER=$WORK/state/worker-model
rm -f "$OLD_JUDGMENT" "$OLD_WORKER"

# Both old files hold settings that are in effect: the first run carries the
# five stages over with their expiry and deletes both old files.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=1795831200\nreview=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
printf 'worker=glm-5.3\nworker.until=1000003600\n' > "$OLD_WORKER"
FAKE_DATE_NOW=1000000000
run_router
expect_exit 0 'the first run migrates the old switches and shows the table'
expect_state 'design=claude-glm/glm-5.4/high@1795831200
research=codex-glm/glm-5.3/high@1000003600
implementation=codex-glm/glm-5.3/high@1000003600
review=claude-glm/glm-5.4/high
diagnosis=claude-glm/glm-5.4/high' 'the first run carries the five stages over with their expiry'
expect_stdout_line_matches '讨论（design）：claude-glm / glm-5.4 / high，到 .* 自动切回默认' 'the first run shows the migrated design route with its expiry'
expect_stdout_line_matches '调研起草（research）：codex-glm / glm-5.3 / high，到 .* 自动切回默认' 'the first run shows the migrated research route with its expiry'
expect_stdout_line_matches '实现（implementation）：codex-glm / glm-5.3 / high，到 .* 自动切回默认' 'the first run shows the migrated implementation route with its expiry'
expect_stdout_line_matches '审查（review）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use review=claude/opus/high' 'the first run shows the migrated review route without an expiry'
expect_stdout_line_matches '诊断（diagnosis）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use diagnosis=claude/opus/high' 'the first run shows the migrated diagnosis route without an expiry'
expect_stderr_has 'judgment-model' 'the first run names the old file it migrated'
expect_stderr_has 'worker-model' 'the first run names the other old file it migrated'
expect_stderr_has 'grill=glm-5.4' 'the migration note names the old setting'
expect_stderr_has 'worker=glm-5.3' 'the migration note names the worker setting'
expect_stderr_has '已删除' 'the notes say the old files were deleted'
expect_route design claude-glm glm-5.4 high 1795831200
expect_route research codex-glm glm-5.3 high 1000003600
expect_route implementation codex-glm glm-5.3 high 1000003600
expect_route review claude-glm glm-5.4 high ''
expect_route diagnosis claude-glm glm-5.4 high ''
expect_file_missing "$OLD_JUDGMENT" 'the old judgment-model file is deleted once migrated'
expect_file_missing "$OLD_WORKER" 'the old worker-model file is deleted once migrated'

# An old setting that has expired is ignored. The other setting of the same
# file is carried all the same, and the file goes once both are dealt with.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=1000000000\nreview=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
run_router
expect_exit 0 'a first run with an expired old setting still shows the table'
expect_state 'review=claude-glm/glm-5.4/high
diagnosis=claude-glm/glm-5.4/high' 'an expired old setting does not reach the table; the other one does'
expect_stderr_has 'grill=glm-5.4 已到期' 'the expired setting is named on stderr'
expect_stderr_has '不迁入' 'the note says the expired setting was not carried'
expect_stderr_has 'review=glm-5.4' 'the setting still in effect is reported as carried'
expect_file_missing "$OLD_JUDGMENT" 'an old file whose settings were all dealt with is deleted, expired ones included'
expect_route design claude opus high ''
expect_route review claude-glm glm-5.4 high ''

# A file in which every setting has expired carries nothing; the table is
# written all the same, so that this was the first run.
rm -f "$STATE_FILE"
printf 'worker=glm-5.3\nworker.until=999\n' > "$OLD_WORKER"
run_router --print research model
expect_exit 0 'a first --print with only an expired old setting exits 0'
expect_stdout glm-5.4 'an expired worker setting leaves research on its default'
expect_state '' 'nothing is written into the table for an expired old setting'
expect_stderr_has 'worker=glm-5.3 已到期' 'the expired worker setting is named on stderr'
expect_stderr_has '已删除' 'the old file with only an expired setting is deleted'
expect_file_missing "$OLD_WORKER" 'the old worker-model file is deleted once expired'

# A model outside the catalog cannot be carried: its file stays as it was, one
# line says so, and the other file is carried all the same.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
printf 'worker=glm-5.3-flash\nworker.until=\n' > "$OLD_WORKER"
run_router
expect_exit 0 'a first run with a setting that cannot be carried exits 0'
expect_state 'design=claude-glm/glm-5.4/high' 'only the setting inside the catalog reaches the table'
expect_file_content 'worker=glm-5.3-flash
worker.until=' 'the old file that could not be carried stays as it was' "$OLD_WORKER"
expect_file_missing "$OLD_JUDGMENT" 'the other old file is migrated and deleted all the same'
expect_stderr_has 'worker=glm-5.3-flash' 'the note names the setting that could not be carried'
expect_stderr_has 'codex-glm/glm-5.3-flash 不在已验证目录' 'the note says the pair is outside the catalog'
expect_stderr_has "$OLD_WORKER" 'the note names the file that stays'
expect_stderr_matching 'glm-5.3-flash' 1 'one line on stderr says what could not be carried'
expect_stderr_has 'grill=glm-5.4' 'the setting that could be carried is still reported'
expect_route research codex-glm glm-5.4 high ''
expect_route implementation claude-glm glm-5.4 high ''

# A model the old switch never wrote cannot be carried either.
rm -f "$STATE_FILE"
printf 'review=gpt\nreview.until=\n' > "$OLD_JUDGMENT"
run_router --print review model
expect_stdout opus 'a setting with a model the old switch never wrote leaves the stage on its default'
expect_state '' 'a model the old switch never wrote reaches nothing'
expect_stderr_matching 'review=gpt' 1 'one line on stderr names the unknown model'
expect_stderr_has '反推不出档案' 'the note says the profile cannot be read back off the model'
expect_file_content 'review=gpt
review.until=' 'the old file with the unknown model stays as it was' "$OLD_JUDGMENT"

# --- migrate on request ---

expect_stderr_lacks() {
  text=$1
  name=$2
  if grep -Fq -- "$text" "$RUN_STDERR" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text] in stderr"
  else
    record PASS "$name"
  fi
}

# $1 is a copy taken before the command ran.
expect_file_unchanged() {
  copy=$1
  name=$2
  file=$3
  if cmp -s "$file" "$copy"; then
    record PASS "$name"
  else
    record FAIL "$name" "file=$(tr '\n' ' ' < "$file" 2>/dev/null)"
  fi
}

# With no old file and no table, migrate says so, writes the table (this is
# the first run) and shows it.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
run_router migrate
expect_exit 0 'migrate with nothing to migrate exits 0'
expect_stdout "$DEFAULT_TABLE" 'migrate prints the table as use does'
expect_stderr_lines 1 'migrate with nothing to migrate says so in one line'
expect_stderr_has '没有旧开关的状态文件可迁移' 'migrate says there is no old file to migrate'
expect_state '' 'migrate on the first run writes the table'

# With a table and nothing to carry, migrate leaves the file byte for byte.
printf '\ndesign = claude-glm / glm-5.4 / low \n\n' > "$STATE_FILE"
cp "$STATE_FILE" "$WORK/table-before.txt"
run_router migrate
expect_exit 0 'migrate with a table and nothing to carry exits 0'
expect_stderr_lines 1 'migrate with a table and nothing to carry says only that there is nothing'
expect_stdout_has '讨论（design）：claude-glm / glm-5.4 / low，不会自动切回' 'migrate shows the table it found'
expect_file_unchanged "$WORK/table-before.txt" 'migrate with nothing to carry does not rewrite the table' "$STATE_FILE"

# migrate carries what the first run carries, expiry included.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=\nreview=glm-5.4\nreview.until=1795831200\n' > "$OLD_JUDGMENT"
printf 'worker=glm-5.3\nworker.until=\n' > "$OLD_WORKER"
run_router migrate
expect_exit 0 'migrate carries the old switches over'
expect_state 'design=claude-glm/glm-5.4/high
research=codex-glm/glm-5.3/high
implementation=codex-glm/glm-5.3/high
review=claude-glm/glm-5.4/high@1795831200
diagnosis=claude-glm/glm-5.4/high@1795831200' 'migrate writes the five stages as the first run does'
expect_stdout_line_matches '审查（review）：claude-glm / glm-5.4 / high，到 .* 自动切回默认' 'migrate shows the table it wrote'
expect_stderr_has '已迁移' 'migrate reports what it carried'
expect_file_missing "$OLD_JUDGMENT" 'migrate deletes the old judgment-model file once migrated'
expect_file_missing "$OLD_WORKER" 'migrate deletes the old worker-model file once migrated'

# A stage the table already has in effect keeps its route: the old setting for
# it is not carried, one line says so, and the rest is carried.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
run_router use design=claude-flash/glm-5.4/medium review=claude/opus/medium
printf 'grill=glm-5.4\ngrill.until=\nreview=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
run_router migrate
expect_exit 0 'migrate onto a table that already sets stages exits 0'
expect_state 'design=claude-flash/glm-5.4/medium
review=claude/opus/medium
diagnosis=claude-glm/glm-5.4/high' 'migrate leaves the stages the table has in effect alone and carries the rest'
expect_stderr_has '不迁入 design=claude-flash/glm-5.4/medium' 'the note names a stage kept and its route'
expect_stderr_has '不迁入 review=claude/opus/medium' 'the note names the other stage kept'
expect_stderr_has '路由表里已设过' 'the note says the stage was already set'
expect_stderr_has 'diagnosis=claude-glm/glm-5.4/high' 'the stage that was free is carried'
expect_stderr_lacks '警告' 'migrate does not warn when review and implementation stay on different models'
expect_file_missing "$OLD_JUDGMENT" 'the old file goes once its settings were dealt with, skipped ones included'

# An expired line is not in effect: the old setting takes that stage.
rm -f "$STATE_FILE" "$OLD_JUDGMENT"
run_router use design=claude-flash/glm-5.4/medium --until 2001-09-09T01:46:40Z
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
run_router migrate
expect_exit 0 'migrate onto a table with an expired line exits 0'
expect_state 'design=claude-glm/glm-5.4/high' 'migrate carries onto a stage whose line has expired'
expect_stderr_lacks '不迁入' 'an expired line does not count as set'

# A first run is the only run that migrates by itself: an old file that turns
# up later waits for migrate.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
run_router --print design model
expect_stdout opus 'the first run answers --print with the value alone'
expect_state '' 'the first run writes the table although there was nothing to carry'
expect_stderr_empty 'the first run says nothing when there is no old file'
printf 'grill=glm-5.4\ngrill.until=\nreview=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
run_router --print design model
expect_stdout opus 'a later run does not carry an old file that turned up after the first run'
expect_stderr_empty 'a later run says nothing about the old file'
expect_file_content 'grill=glm-5.4
grill.until=
review=glm-5.4
review.until=' 'the old file that turned up later is left alone until migrate' "$OLD_JUDGMENT"
run_router migrate
expect_stdout_has '讨论（design）：claude-glm / glm-5.4 / high，不会自动切回' 'migrate carries the old file that turned up later'
expect_file_missing "$OLD_JUDGMENT" 'migrate then deletes it'
expect_stderr_has '警告' 'migrate warns once when review and implementation land on the same model'
expect_stderr_matching '警告' 1 'the same-model warning is one line after migrate'

# A file kept for a setting that cannot be carried stays through later runs,
# quietly, and migrate says again what it cannot carry.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
printf 'worker=glm-5.3-flash\nworker.until=\n' > "$OLD_WORKER"
run_router --print research model
expect_stdout glm-5.4 'a first run answers the default for a stage whose old setting cannot be carried'
expect_stderr_matching 'glm-5.3-flash' 1 'the first run says once what it cannot carry'
run_router --print research model
expect_stderr_empty 'a later run does not repeat what cannot be carried'
expect_file_content 'worker=glm-5.3-flash
worker.until=' 'the file that cannot be carried is still there' "$OLD_WORKER"
run_router migrate
expect_exit 0 'migrate with only a setting it cannot carry exits 0'
expect_stderr_matching 'glm-5.3-flash' 1 'migrate says again what it cannot carry'
expect_file_content 'worker=glm-5.3-flash
worker.until=' 'the file that cannot be carried survives migrate' "$OLD_WORKER"
expect_state '' 'nothing was written for it'

# migrate takes no argument.
run_router migrate extra
expect_exit 64 'migrate with an argument is a usage error'
expect_stderr_has 'migrate takes no argument' 'the refusal says migrate takes no argument'

# --- The first run is whichever command comes first ---

# use on the first run migrates first and then sets its own stages.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
printf 'grill=glm-5.4\ngrill.until=\nreview=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
run_router use review=claude/opus/medium
expect_exit 0 'use works on the first run'
expect_state 'design=claude-glm/glm-5.4/high
review=claude/opus/medium
diagnosis=claude-glm/glm-5.4/high' 'use on the first run migrates first and then sets its own stage'
expect_stdout_has '审查（review）：claude / opus / medium，不会自动切回' 'use prints the status of the table it left'
expect_file_missing "$OLD_JUDGMENT" 'the old file is migrated and deleted before use sets its stage'

# --launch on the first run starts the migrated route.
rm -f "$STATE_FILE"
printf 'worker=glm-5.3\nworker.until=\n' > "$OLD_WORKER"
run_router --launch research headless
expect_exit 0 '--launch works on the first run'
expect_stdout 'codex
exec
-m
glm-5.3
-c
model_reasoning_effort=high' '--launch on the first run starts the migrated route'
expect_file_missing "$OLD_WORKER" 'the old worker-model file is migrated and deleted before --launch'

# --help reads nothing and migrates nothing.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
run_router --help
expect_exit 0 'help works on the first run'
expect_stderr_empty 'help says nothing about migration'
expect_file_missing "$STATE_FILE" 'help does not migrate: no table is written'
expect_file_content 'grill=glm-5.4
grill.until=
review=opus
review.until=' 'help leaves the old file alone' "$OLD_JUDGMENT"
expect_stdout_has 'stage-route.sh migrate' 'help documents migrate'
expect_stdout_has 'judgment-model' 'help names the old files it migrates'
expect_stdout_has 'glm-5.3-flash' 'help names the setting that cannot be carried'

# Settings on the old switches' default were no setting: nothing is carried,
# and the files go like any other.
rm -f "$STATE_FILE"
printf 'grill=opus\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
printf 'worker=glm-5.4\nworker.until=\n' > "$OLD_WORKER"
run_router
expect_stdout "$DEFAULT_TABLE" 'old settings on the old default carry nothing'
expect_state '' 'a table migrated from old defaults is empty'
expect_stderr_lacks '已迁移' 'nothing is reported as carried from old defaults'
expect_stderr_has '已删除' 'the old files on their defaults are deleted all the same'

# An old file is read as the old scripts read it: the <role>.model key, spaces
# inside a line, CRLF endings and a line that is not a setting are all fine,
# and a non-numeric until never expires.
rm -f "$STATE_FILE" "$OLD_WORKER"
printf '# a comment\r\n grill.model = glm-5.4 \r\ngrill.until=soon\r\nreview.model=glm-5.4\r\nreview.until=1795831200\r\n' > "$OLD_JUDGMENT"
run_router --print design until
expect_exit 0 'a first --print on an old file in the old format exits 0'
expect_stdout '' 'a non-numeric old until carries no expiry'
expect_state 'design=claude-glm/glm-5.4/high
review=claude-glm/glm-5.4/high@1795831200
diagnosis=claude-glm/glm-5.4/high@1795831200' 'the old format is read: .model key, spaces, CRLF, other lines ignored'

# An unreadable clock never expires an old setting, as under the old switches.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=1000000000\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
export FAKE_DATE_FAIL=1
run_router --print design model
export FAKE_DATE_FAIL=
expect_stdout glm-5.4 'an old setting whose expiry cannot be judged is carried'
expect_state 'design=claude-glm/glm-5.4/high@1000000000' 'an old setting whose expiry cannot be judged keeps its expiry'

# An old file that is not a readable regular file is left alone.
rm -f "$STATE_FILE" "$OLD_JUDGMENT" "$OLD_WORKER"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
chmod 000 "$OLD_JUDGMENT"
mkdir "$OLD_WORKER"
run_router --print design model
expect_stdout opus 'an unreadable old file carries nothing'
expect_stderr_empty 'an unreadable old file and one that is a directory are not reported'
expect_state '' 'nothing is written for old files that cannot be read'
chmod 644 "$OLD_JUDGMENT"
expect_file_content 'grill=glm-5.4
grill.until=
review=opus
review.until=' 'an unreadable old file is not deleted' "$OLD_JUDGMENT"
if [ -d "$OLD_WORKER" ]; then
  record PASS 'an old path that is a directory is not deleted'
else
  record FAIL 'an old path that is a directory is not deleted'
fi
rmdir "$OLD_WORKER"
rm -f "$OLD_JUDGMENT"

# When the table cannot be written, nothing is lost: a read still answers, the
# old files stay, and migrate exits 65.
rm -f "$STATE_FILE"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
chmod 555 "$WORK/state"
run_router --print design model
expect_exit 0 'a first --print still answers when the table cannot be written'
expect_stdout opus 'a first --print answers from the table on disk, which is none, when it cannot be written'
expect_stderr_has '迁移没有写入' 'the failed migration is reported'
expect_file_content 'grill=glm-5.4
grill.until=
review=opus
review.until=' 'the old file stays when the table cannot be written' "$OLD_JUDGMENT"
run_router migrate
expect_exit 65 'migrate exits 65 when the table cannot be written'
expect_stderr_has '迁移没有写入' 'migrate reports the table it could not write'
expect_file_content 'grill=glm-5.4
grill.until=
review=opus
review.until=' 'the old file stays when migrate cannot write the table' "$OLD_JUDGMENT"
chmod 755 "$WORK/state"
run_router --print design model
expect_stdout glm-5.4 'the next run migrates once the table can be written'
expect_file_missing "$OLD_JUDGMENT" 'the old file goes once the migration is written'

# A directory where the table should be is not a first run, and migrate cannot
# write into it: it exits 65 and the old files stay.
rm -f "$STATE_FILE" "$OLD_JUDGMENT"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$OLD_JUDGMENT"
mkdir "$STATE_FILE"
run_router --print design model
expect_stdout opus 'a directory where the table should be still reads as the default, with no first run'
expect_stderr_empty 'a directory where the table should be triggers no migration'
run_router migrate
expect_exit 65 'migrate exits 65 when a directory sits where the table should be'
expect_stderr_has '迁移没有写入' 'migrate reports that it could not write the table'
expect_file_content 'grill=glm-5.4
grill.until=
review=opus
review.until=' 'the old file stays when a directory sits where the table should be' "$OLD_JUDGMENT"
if [ -z "$(ls -A "$STATE_FILE")" ]; then
  record PASS 'nothing is moved into the directory'
else
  record FAIL 'nothing is moved into the directory' "inside=$(ls -A "$STATE_FILE")"
fi
rmdir "$STATE_FILE"

# The old files are looked up next to the table, so a relocated table never
# reaches the files next to the default one.
mkdir -p "$WORK/other"
printf 'grill=glm-5.4\ngrill.until=\nreview=opus\nreview.until=\n' > "$WORK/other/judgment-model"
printf 'review=glm-5.4\nreview.until=\n' > "$OLD_JUDGMENT"
rm -f "$STATE_FILE" "$OTHER_FILE"
ISS_STAGE_ROUTE_FILE=$OTHER_FILE "$ROUTER" --print design model > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_stdout glm-5.4 'a relocated table migrates from the old files next to it'
expect_file_missing "$WORK/other/judgment-model" 'the old file next to the relocated table is migrated and deleted'
expect_file_content 'review=glm-5.4
review.until=' 'the old file next to the default table is not touched' "$OLD_JUDGMENT"
expect_stderr_has 'judgment-model' 'the note names the old file that was migrated'
rm -f "$OLD_JUDGMENT" "$OTHER_FILE"

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
expect_skill_has 'stage-route.sh migrate' 'the skill shows the migrate command'
expect_skill_has '迁移旧开关' 'the skill has the words for migrating the old switches'
expect_skill_has 'judgment-model' 'the skill names the old switch whose settings migrate'
expect_skill_has 'worker-model' 'the skill names the other old switch'
expect_skill_has 'glm-5.3-flash' 'the skill names the setting that cannot be carried'
expect_skill_has '不覆盖' 'the skill says a stage already set in the table is not overwritten'
expect_skill_has '不要自己' 'the skill forbids touching the old files itself'
expect_skill_has '第一次运行' 'the skill says the first run migrates by itself'
expect_skill_has '迁移' 'the skill relays the migration notes'
expect_skill_has '退出码 65' 'the skill relays the exit code of a migrate that could not write'
if sed -n '1p' "$SKILL" 2>/dev/null | grep -qx -- '---' &&
  sed -n '2p' "$SKILL" 2>/dev/null | grep -qx 'name: grill-router' &&
  sed -n '4p' "$SKILL" 2>/dev/null | grep -qx 'disable-model-invocation: true' &&
  sed -n '5p' "$SKILL" 2>/dev/null | grep -qx -- '---'; then
  record PASS 'the skill frontmatter is name, description, disable-model-invocation in that order'
else
  record FAIL 'the skill frontmatter is name, description, disable-model-invocation in that order' "head=$(head -5 "$SKILL" 2>/dev/null | tr '\n' '|')"
fi
expect_file_has 'bash scripts/test-stage-route.sh' 'MAINTAINING registers the test in its self-test list' "$ROOT/MAINTAINING.md"

# The user documents describe the Stage route table, not the two old switches
# (#37). scripts/judgment-model.sh, its skill and its test stay until #38 deletes
# them, and MAINTAINING's numbered decision records keep the old names as history,
# so none of those is in this list.
LINK='ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router'
for doc in README.md docs/setup.md docs/setup.en.md; do
  expect_file_has "$LINK" "$doc documents the router skill symlink" "$ROOT/$doc"
  expect_file_has '/grill-router' "$doc documents the slash command" "$ROOT/$doc"
  expect_file_has 'scripts/stage-route.sh' "$doc documents the router script" "$ROOT/$doc"
  expect_file_has 'migrate' "$doc documents carrying the old switches over" "$ROOT/$doc"
done
expect_file_has '/grill-router' 'MAINTAINING points at the slash command' "$ROOT/MAINTAINING.md"
for doc in README.md docs/setup.md docs/setup.en.md GLOSSARY.md hooks/README.md \
  templates/global-claude-md.md templates/global-claude-md.en.md docs/codex-backend.md; do
  if grep -Fq '/judgment-model' "$ROOT/$doc" || grep -Fq '/worker-model' "$ROOT/$doc"; then
    record FAIL "$doc no longer names the old switch commands"
  else
    record PASS "$doc no longer names the old switch commands"
  fi
done
# The glossary entries that used to name the switch point at the Stage route.
for term in 'Judgment model' 'Worker model' 'Design session' 'Opus review'; do
  definition=$(grep -F -A1 -- "**$term**:" "$ROOT/GLOSSARY.md" | sed -n '2p')
  if [ -n "$definition" ] && printf '%s\n' "$definition" | grep -Fq 'Stage route'; then
    record PASS "the glossary's $term entry points at the Stage route"
  else
    record FAIL "the glossary's $term entry points at the Stage route" "$definition"
  fi
done

# --- summary ---

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
