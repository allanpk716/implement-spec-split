#!/usr/bin/env bash
# Deterministic tests for scripts/judgment-model.sh, the per-role switch for
# the judgment model. Everything runs against a scratch setting file and a fake
# date, so the suite never touches the user's real switch.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SWITCH=$HERE/judgment-model.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/judgment-model-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
STATE_FILE=$WORK/state/judgment-model
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

# --print must answer whatever the file holds; it is what the wrappers call.
expect_print() {
  role=$1
  content=$2
  wanted=$3
  name=$4
  printf '%s' "$content" > "$STATE_FILE"
  run_switch --print "$role"
  expect_exit 0 "$name exits 0"
  expect_stdout "$wanted" "$name answers $wanted"
}

GRILL_OPUS='grill（Design session 讨论）：opus（默认）'
REVIEW_OPUS='review（全部 Opus review）：opus（默认）'

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
export ISS_JUDGMENT_MODEL_FILE=$STATE_FILE
export FAKE_DATE_NOW=1000000000

run_switch() {
  "$SWITCH" "$@" > "$RUN_STDOUT" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

# Without a setting both roles are opus.
rm -f "$STATE_FILE"
run_switch --print grill
expect_exit 0 'a missing setting prints without error'
expect_stdout opus 'a missing setting means opus for grill'
run_switch --print review
expect_stdout opus 'a missing setting means opus for review'
run_switch
expect_exit 0 'status works without a setting'
expect_stdout "$GRILL_OPUS
$REVIEW_OPUS" 'status names the default for both roles'

# One command sets both roles.
run_switch grill=opus review=glm-5.4
expect_exit 0 'one command sets both roles'
expect_state 'grill=opus
grill.until=
review=glm-5.4
review.until=' 'one command records both roles'
expect_stdout "$GRILL_OPUS
review（全部 Opus review）：glm-5.4（代替 Opus），不会自动切回；切回用 judgment-model.sh review=opus" \
  'switching prints the status of both roles'
run_switch --print grill
expect_stdout opus 'a role set to opus prints opus'
run_switch --print review
expect_stdout glm-5.4 'a role set to glm-5.4 prints glm-5.4'

run_switch review=opus grill=glm-5.4
expect_exit 0 'the roles can be set the other way round'
run_switch --print grill
expect_stdout glm-5.4 'grill can be switched alone in a two-role command'
run_switch --print review
expect_stdout opus 'review can be kept on opus in a two-role command'

# A bare model sets every role the command does not name.
run_switch glm-5.4
expect_exit 0 'a bare model is accepted'
expect_state 'grill=glm-5.4
grill.until=
review=glm-5.4
review.until=' 'a bare model sets both roles'
run_switch --print grill
expect_stdout glm-5.4 'a bare model switches grill'
run_switch --print review
expect_stdout glm-5.4 'a bare model switches review'
run_switch use glm-5.4
expect_stdout_has 'grill（Design session 讨论）：glm-5.4（代替 Opus）' 'use with a bare model reports grill'
run_switch opus
expect_exit 0 'a bare opus switches both roles back'
expect_state 'grill=opus
grill.until=
review=opus
review.until=' 'a bare opus records both roles'

# A bare model is the base; a role named in the same command overrides it.
run_switch glm-5.4 grill=opus
expect_exit 0 'a bare model and a named role can share one command'
run_switch --print grill
expect_stdout opus 'a named role overrides the bare model'
run_switch --print review
expect_stdout glm-5.4 'an unnamed role takes the bare model'
run_switch opus review=glm-5.4
run_switch --print grill
expect_stdout opus 'a named role wins over a later bare model'
run_switch --print review
expect_stdout glm-5.4 'the named role keeps its own model'

# --until takes an ISO 8601 time and reverts that role by itself.
run_switch review=opus grill=glm-5.4 --until 2001-09-09T01:46:40Z
expect_exit 0 'an absolute --until is accepted'
expect_state 'grill=glm-5.4
grill.until=1000000000
review=opus
review.until=' 'an absolute --until is stored as epoch seconds for that role'
FAKE_DATE_NOW=999999999
run_switch --print grill
expect_stdout glm-5.4 'a switch that has not expired is in effect'
run_switch
expect_stdout_has 'grill（Design session 讨论）：glm-5.4（代替 Opus），到 ' 'status reports the expiry time'
expect_stdout_has '自动切回 opus' 'status says the switch reverts by itself'
if grep -Eq '到 [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{2}:[0-9]{2} ' "$RUN_STDOUT"; then
  record PASS 'the expiry time is shown with its UTC offset'
else
  record FAIL 'the expiry time is shown with its UTC offset' "stdout=$(tr '\n' '|' < "$RUN_STDOUT")"
fi
FAKE_DATE_NOW=1000000000
run_switch --print grill
expect_stdout opus 'a switch whose time has arrived means opus'
run_switch
expect_stdout_has 'grill（Design session 讨论）：opus（开关里的 glm-5.4 已于 ' 'status reports an expired switch'
expect_stdout_has '到期' 'status says the expired switch has lapsed'
expect_state 'grill=glm-5.4
grill.until=1000000000
review=opus
review.until=' 'reading an expired switch leaves the setting alone'
FAKE_DATE_NOW=1000000000

# Expiry is per role.
run_switch review=glm-5.4 --until 2001-09-09T01:46:40Z
run_switch grill=glm-5.4 --until 2026-11-28T10:00:00+08:00
expect_state 'grill=glm-5.4
grill.until=1795831200
review=glm-5.4
review.until=1000000000' 'an offset in --until is honoured and each role keeps its own expiry'
run_switch --print grill
expect_stdout glm-5.4 'the role that has not expired is in effect'
run_switch --print review
expect_stdout opus 'the role that has expired means opus'
run_switch
if grep -Fq '到期' "$RUN_STDOUT" && grep -Fq '自动切回 opus' "$RUN_STDOUT"; then
  record PASS 'status tells an expired role from one still switched'
else
  record FAIL 'status tells an expired role from one still switched' "stdout=$(tr '\n' '|' < "$RUN_STDOUT")"
fi

run_switch use grill=glm-5.4 --until '明天早上十点'
expect_exit 64 'an unparseable --until is a usage error'
expect_stderr_has '--until must be an ISO 8601 time' 'an unparseable --until names the format'
run_switch use grill=glm-5.4 --until
expect_exit 64 'a missing --until value is a usage error'

# --for adds a duration to the clock.
run_switch review=glm-5.4 --for 2d12h
expect_exit 0 '--for accepts a compound duration'
expect_state 'grill=glm-5.4
grill.until=1795831200
review=glm-5.4
review.until=1000216000' '--for stores now plus the duration for the roles it sets'
run_switch review=glm-5.4 --for 90m
expect_state 'grill=glm-5.4
grill.until=1795831200
review=glm-5.4
review.until=1000005400' '--for accepts minutes'
run_switch review=glm-5.4 --for 45s
expect_state 'grill=glm-5.4
grill.until=1795831200
review=glm-5.4
review.until=1000000045' '--for accepts seconds'
for duration in 5x h 1h30 0 ''; do
  run_switch use review=glm-5.4 --for "$duration"
  expect_exit 64 "--for rejects '$duration'"
  expect_stderr_has '--for must be a duration' "--for rejects '$duration' with a reason"
done
run_switch use review=glm-5.4 --for 0d
expect_exit 64 '--for rejects a zero duration'
expect_stderr_has 'greater than zero' '--for rejects a zero duration with a reason'
run_switch use grill=opus
expect_state 'grill=opus
grill.until=
review=glm-5.4
review.until=1000000045' 'a role set back to opus drops its expiry and leaves the other alone'

# A role the command does not name keeps its model and its expiry.
run_switch use grill=glm-5.4
expect_state 'grill=glm-5.4
grill.until=
review=glm-5.4
review.until=1000000045' 'a role set without a time never reverts, and its neighbour is untouched'

# Bad usage never changes the setting.
run_switch use gpt-5
expect_exit 64 'an unsupported model is a usage error'
expect_stderr_has 'supported: opus, glm-5.4' 'an unsupported model lists what is supported'
run_switch use other=glm-5.4
expect_exit 64 'an unknown role is a usage error'
expect_stderr_has 'roles: grill, review' 'an unknown role lists the roles'
run_switch use grill=gpt-5
expect_exit 64 'an unsupported model for a role is a usage error'
expect_stderr_has "for grill" 'an unsupported model for a role names the role'
run_switch use
expect_exit 64 'use without a setting is a usage error'
run_switch use --nonsense
expect_exit 64 'an unknown option after use is a usage error'
run_switch --nonsense
expect_exit 64 'an unknown argument is a usage error'
run_switch review=opus --for 1h
expect_exit 64 'an expiry without a substitute in the command is a usage error'
run_switch grill=opus --until 2026-11-28T10:00:00+08:00
expect_exit 64 'an absolute expiry on opus alone is a usage error'
run_switch glm-5.4 --for
expect_exit 64 'a missing --for value is a usage error'
expect_state 'grill=glm-5.4
grill.until=
review=glm-5.4
review.until=1000000045' 'bad usage leaves the setting alone'

# --print answers opus or the substitute for the role asked about.
rm -f "$STATE_FILE"
expect_print grill 'garbage
' opus '--print with a garbage setting'
expect_print review 'grill=glm-9
' opus '--print ignores another role and an unknown model'
expect_print review 'review=glm-5.4
' glm-5.4 '--print reads its own role'
expect_print grill 'review=glm-5.4
' opus '--print leaves the other role on opus'
expect_print review 'model=glm-5.4
' opus '--print ignores a line without a role'
expect_print grill '' opus '--print with an empty setting'
expect_print review ' review = glm-5.4
' glm-5.4 '--print tolerates spaces around the equals sign'
expect_print review 'review=glm-5.4
review.until=soon
' glm-5.4 '--print treats an unreadable expiry as none'
expect_print review 'review=glm-5.4
review.until=999999999
' opus '--print with an expired substitute'
rm -f "$STATE_FILE"
mkdir "$STATE_FILE"
run_switch --print review
expect_stdout opus '--print answers opus when the setting is a directory'
run_switch
expect_stdout "$GRILL_OPUS
$REVIEW_OPUS" 'status names the default for both roles when the setting is a directory'
rmdir "$STATE_FILE" 2>/dev/null

run_switch --print
expect_exit 64 '--print without a role is a usage error'
run_switch --print code
expect_exit 64 '--print with an unknown role is a usage error'
run_switch --print grill review
expect_exit 64 '--print with two roles is a usage error'

# The setting file location follows ISS_JUDGMENT_MODEL_FILE.
OTHER_FILE=$WORK/other-judgment-model
ISS_JUDGMENT_MODEL_FILE=$OTHER_FILE "$SWITCH" grill=glm-5.4 > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_exit 0 'ISS_JUDGMENT_MODEL_FILE relocates the setting'
if [ -f "$OTHER_FILE" ]; then
  record PASS 'the relocated setting file is written'
else
  record FAIL 'the relocated setting file is written'
fi
rm -f "$STATE_FILE"
run_switch --print grill
expect_stdout opus 'the default location ignores the relocated setting'
rm -f "$OTHER_FILE"

run_switch --help
expect_exit 0 'help succeeds'
if [ -s "$RUN_STDERR" ]; then
  record FAIL 'help prints nothing on stderr' "stderr=$(cat "$RUN_STDERR")"
else
  record PASS 'help prints nothing on stderr'
fi
expect_stdout_has 'judgment-model.sh use <setting>' 'help documents use'
expect_stdout_has -- '--print <role>' 'help documents --print with a role'
expect_stdout_has 'grill=opus review=glm-5.4' 'help shows setting both roles in one command'

# A wrapper that still reads its role here does so on every call. opus-review.sh
# has moved to the Stage route table (scripts/stage-route.sh, issue #33).
expect_file_has 'judgment-model.sh" --print grill' 'design-session reads the grill role' "$HERE/design-session.sh"

# The user-facing command is the judgment-model skill, symlinked like the others.
ROOT=$(cd "$HERE/.." && pwd)
SKILL=$ROOT/judgment-model/SKILL.md
expect_file_has 'name: judgment-model' 'the judgment-model skill has its name' "$SKILL"
expect_file_has 'disable-model-invocation: true' 'only the user can invoke the switch skill' "$SKILL"
expect_file_has '输入 /judgment-model 时使用' 'the skill description names the slash command' "$SKILL"
expect_file_has 'scripts/judgment-model.sh use' 'the skill runs the switch script' "$SKILL"
expect_file_has '原样照抄' 'the skill relays the script status lines verbatim' "$SKILL"
expect_file_has 'claude-glm --resume' 'the skill tells how an open Design session carries on' "$SKILL"
expect_file_has 'grill=opus review=glm-5.4' 'the skill shows setting both roles in one command' "$SKILL"
LINK='ln -s ~/.claude/skills/implement-spec-split/judgment-model ~/.claude/skills/judgment-model'
for doc in README.md docs/setup.md docs/setup.en.md; do
  expect_file_has "$LINK" "$doc documents the skill symlink" "$ROOT/$doc"
  expect_file_has '/judgment-model' "$doc documents the slash command" "$ROOT/$doc"
done
# SKILL.md and find-next/SKILL.md describe the Stage route table instead (#33).
for doc in grill-feature/SKILL.md grill-map/SKILL.md MAINTAINING.md; do
  expect_file_has '/judgment-model' "$doc points at the slash command" "$ROOT/$doc"
done

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
