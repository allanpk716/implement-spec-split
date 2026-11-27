#!/usr/bin/env bash
# Deterministic tests for scripts/worker-model.sh, the user's global switch for the
# Worker model (ADR 0003), and for the code and documentation around it: the default
# is defined once, codex-worker.sh reads the switch only on a fresh run, the selftest
# and test-locks.sh isolate it, and every document that should mention /worker-model
# does. Everything runs against a scratch setting file, a scratch worker home and a
# fake date, so the suite never touches the user's real switch or codex home, and it
# costs no tokens.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SWITCH=$HERE/worker-model.sh
WRAPPER=$HERE/codex-worker.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/worker-model-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
STATE_FILE=$WORK/state/worker-model
WORKER_HOME=$WORK/worker-home
mkdir -p "$BIN" "$WORK/state" "$WORKER_HOME"
export CODEX_WORKER_HOME="$WORKER_HOME"

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

expect_stdout_matches() {
  pattern=$1
  name=$2
  if grep -Eq -- "$pattern" "$RUN_STDOUT" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "stdout does not match /$pattern/"
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

expect_file_lacks() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text] in $(basename "$file")"
  else
    record PASS "$name"
  fi
}

# --print must answer whatever the file holds; it is what the wrapper calls.
expect_print() {
  content=$1
  wanted=$2
  name=$3
  printf '%s' "$content" > "$STATE_FILE"
  run_switch --print
  expect_exit 0 "$name exits 0"
  expect_stdout "$wanted" "$name answers $wanted"
  case "$(cat "$RUN_STDOUT")" in
    *[[:space:]]*) record FAIL "$name prints one token" "stdout has whitespace" ;;
    *) record PASS "$name prints one token" ;;
  esac
}

expect_until() {
  content=$1
  wanted=$2
  name=$3
  printf '%s' "$content" > "$STATE_FILE"
  run_switch --print until
  expect_exit 0 "$name exits 0"
  expect_stdout "$wanted" "$name answers ${wanted:-an empty line}"
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
export ISS_WORKER_MODEL_FILE=$STATE_FILE
export FAKE_DATE_NOW=1000000000

run_switch() {
  "$SWITCH" "$@" > "$RUN_STDOUT" 2> "$RUN_STDERR"
  RUN_EXIT=$?
}

DEFAULT_STATE=$'worker=glm-5.4\nworker.until='
GLM53_STATE=$'worker=glm-5.3\nworker.until='

# Without a setting the Worker model is the default.
rm -f "$STATE_FILE"
run_switch --print
expect_exit 0 'a missing setting prints without error'
expect_stdout glm-5.4 'a missing setting means the default'
run_switch --print default
expect_exit 0 '--print default exits 0'
expect_stdout glm-5.4 '--print default names the default'
run_switch --print until
expect_exit 0 '--print until exits 0 without an expiry'
expect_stdout '' '--print until prints an empty line without an expiry'
run_switch
expect_exit 0 'status works without a setting'
expect_stdout 'Worker model：glm-5.4（默认）' 'status names the default'
expect_stderr_empty 'status without a catalog warns about nothing'

# use switches, and use of the default switches back.
run_switch use glm-5.3
expect_exit 0 'use switches to a substitute model'
expect_state "$GLM53_STATE" 'use records the model and an empty expiry'
expect_stdout 'Worker model：glm-5.3（默认 glm-5.4），不会自动切回；切回用 /worker-model use glm-5.4' 'use prints the status with the reset command'
run_switch --print
expect_stdout glm-5.3 'the switched model is in effect'
run_switch --print default
expect_stdout glm-5.4 '--print default still names the default'
run_switch --print until
expect_stdout '' '--print until prints an empty line when nothing expires'
run_switch use glm-5.3-flash
expect_exit 0 'use switches to the flash model'
run_switch --print
expect_stdout glm-5.3-flash 'the flash model is in effect'
run_switch use glm-5.4
expect_exit 0 'use of the default switches back'
expect_state "$DEFAULT_STATE" 'the reset records the default and an empty expiry'
run_switch --print
expect_stdout glm-5.4 'after the reset the default is in effect'
run_switch
expect_stdout 'Worker model：glm-5.4（默认）' 'status names the default after the reset'

# --until takes an ISO 8601 time and returns the switch to the default by itself.
run_switch use glm-5.3 --until 2001-09-09T01:46:40Z
expect_exit 0 'an absolute --until is accepted'
expect_state $'worker=glm-5.3\nworker.until=1000000000' 'an absolute --until is stored as epoch seconds'
FAKE_DATE_NOW=999999999
run_switch --print
expect_stdout glm-5.3 'a switch that has not expired is in effect'
run_switch --print until
expect_stdout 1000000000 '--print until answers the expiry of a switch in effect'
run_switch
expect_stdout_has 'Worker model：glm-5.3（默认 glm-5.4），到 ' 'status reports the expiry time'
expect_stdout_has '自动切回 glm-5.4' 'status says the switch reverts to the default by itself'
expect_stdout_matches '到 [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{2}:[0-9]{2} ' 'the expiry time is shown with its UTC offset'
FAKE_DATE_NOW=1000000000
run_switch --print
expect_stdout glm-5.4 'a switch whose time has arrived means the default'
run_switch --print until
expect_stdout '' '--print until prints an empty line once the switch has expired'
run_switch
expect_stdout_has 'Worker model：glm-5.4（默认；开关里的 glm-5.3 已于 ' 'status reports an expired switch'
expect_stdout_has '到期' 'status says the expired switch has lapsed'
expect_state $'worker=glm-5.3\nworker.until=1000000000' 'reading an expired switch leaves the setting alone'
FAKE_DATE_NOW=1000000000
run_switch use glm-5.3-flash --until '明天早上十点'
expect_exit 64 'an unparseable --until is a usage error'
expect_stderr_has '--until must be an ISO 8601 time' 'an unparseable --until names the format'
run_switch use glm-5.3-flash --until
expect_exit 64 'a missing --until value is a usage error'

# --for adds a duration to the clock.
run_switch use glm-5.3 --for 2d12h
expect_exit 0 '--for accepts a compound duration'
expect_state $'worker=glm-5.3\nworker.until=1000216000' '--for stores now plus the duration'
run_switch use glm-5.3 --for 90m
expect_state $'worker=glm-5.3\nworker.until=1000005400' '--for accepts minutes'
run_switch use glm-5.3 --for 45s
expect_state $'worker=glm-5.3\nworker.until=1000000045' '--for accepts seconds'
for duration in 5x h 1h30 0 ''; do
  run_switch use glm-5.3 --for "$duration"
  expect_exit 64 "--for rejects '$duration'"
  expect_stderr_has '--for must be a duration' "--for rejects '$duration' with a reason"
done
run_switch use glm-5.3 --for 0d
expect_exit 64 '--for rejects a zero duration'
expect_stderr_has 'greater than zero' '--for rejects a zero duration with a reason'

# Bad usage never changes the setting.
run_switch use gpt-x
expect_exit 64 'an unsupported model is a usage error'
expect_stderr_has 'supported: glm-5.4, glm-5.3, glm-5.3-flash' 'an unsupported model lists what is supported'
run_switch use glm-5.4 --for 2h
expect_exit 64 'an expiry on the default model is a usage error'
expect_stderr_has 'only apply to a substitute model' 'an expiry on the default names the rule'
run_switch use glm-5.4 --until 2026-11-28T10:00:00+08:00
expect_exit 64 'an absolute expiry on the default model is a usage error'
run_switch glm-5.3
expect_exit 64 'a bare model without use is a usage error'
expect_stderr_has 'use glm-5.3' 'a bare model is told the use form'
run_switch use
expect_exit 64 'use without a model is a usage error'
run_switch use --nonsense
expect_exit 64 'an unknown option after use is a usage error'
run_switch --nonsense
expect_exit 64 'an unknown argument is a usage error'
run_switch use glm-5.3 --for
expect_exit 64 'a missing --for value is a usage error'
run_switch use glm-5.3 glm-5.3-flash
expect_exit 64 'two models in one use is a usage error'
run_switch --print glm-5.3
expect_exit 64 '--print with a model is a usage error'
run_switch --print nonsense
expect_exit 64 '--print with an unknown argument is a usage error'
run_switch --print default extra
expect_exit 64 '--print default with an extra argument is a usage error'
expect_state $'worker=glm-5.3\nworker.until=1000000045' 'bad usage leaves the setting alone'

# --print answers the default or the substitute, whatever the file holds.
expect_print 'garbage
' glm-5.4 '--print with a garbage setting'
expect_print 'not key value
' glm-5.4 '--print with a line that is not key=value'
expect_print 'worker=gpt-x
' glm-5.4 '--print with an unknown model'
expect_print 'worker=glm-5.3
worker.until=1000000000
' glm-5.4 '--print with an expired switch'
expect_print 'worker=glm-5.3
worker.until=soon
' glm-5.3 '--print treats an unreadable expiry as none'
expect_print ' worker = glm-5.3
' glm-5.3 '--print tolerates spaces around the equals sign'
expect_print 'worker.model=glm-5.3
' glm-5.3 '--print reads worker.model as the model line'
expect_print 'model=glm-5.3
' glm-5.4 '--print ignores a line without the worker prefix'
expect_print '' glm-5.4 '--print with an empty setting'
expect_print 'worker=glm-5.4
worker.until=999999999
' glm-5.4 '--print keeps the default even when a hand-edited default has an expiry'
rm -f "$STATE_FILE"
mkdir "$STATE_FILE"
run_switch --print
expect_stdout glm-5.4 '--print answers the default when the setting is a directory'
run_switch
expect_stdout 'Worker model：glm-5.4（默认）' 'status names the default when the setting is a directory'
rmdir "$STATE_FILE" 2>/dev/null

# --print until answers only for a switch that is in effect.
expect_until 'garbage
' '' '--print until with a garbage setting'
expect_until 'worker=gpt-x
' '' '--print until with an unknown model'
expect_until 'worker=glm-5.4
worker.until=999999999
' '' '--print until with the default, even with a hand-edited expiry'
expect_until 'worker=glm-5.3
worker.until=soon
' '' '--print until with an unreadable expiry'

# The setting file location follows ISS_WORKER_MODEL_FILE.
OTHER_FILE=$WORK/other-worker-model
ISS_WORKER_MODEL_FILE=$OTHER_FILE "$SWITCH" use glm-5.3 > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_exit 0 'ISS_WORKER_MODEL_FILE relocates the setting'
if [ -f "$OTHER_FILE" ]; then
  record PASS 'the relocated setting file is written'
else
  record FAIL 'the relocated setting file is written'
fi
rm -f "$OTHER_FILE"

# The setting is written atomically: a failed write keeps the old file byte for byte.
printf 'worker=glm-5.3\nworker.until=\n' > "$STATE_FILE"
BEFORE_STATE=$(cat "$STATE_FILE")
chmod 555 "$WORK/state"
run_switch use glm-5.3-flash
expect_exit 65 'a write into a read-only state directory exits 65'
expect_state "$BEFORE_STATE" 'a failed write leaves the old setting alone'
chmod 755 "$WORK/state"
if grep -Eq 'mktemp "\$STATE_FILE\.XXXXXX"' "$SWITCH" && grep -Eq '^\s*mv -f "\$temporary" "\$STATE_FILE"' "$SWITCH"; then
  record PASS 'the setting is written to a temporary file next to it and moved into place'
else
  record FAIL 'the setting is written to a temporary file next to it and moved into place'
fi

# The catalog check resolves the worker home the way codex-worker.sh does.
run_switch use glm-5.3-flash
expect_stderr_empty 'a worker home without a catalog draws no warning'
run_switch --print catalog
expect_exit 0 '--print catalog exits 0 without a catalog'
expect_stdout unknown '--print catalog answers unknown without a catalog'
printf 'model_provider = "custom"\nmodel_catalog_json = "%s/models.json"\n\n[model_providers.custom]\nname = "custom"\n' "$WORKER_HOME" > "$WORKER_HOME/config.toml"
printf '{"models":[{"slug":"glm-5.4","display_name":"glm-5.4"},{"slug":"glm-5.3","display_name":"glm-5.3"}]}\n' > "$WORKER_HOME/models.json"
run_switch --print catalog
expect_stdout no '--print catalog answers no for a model the catalog does not list'
run_switch use glm-5.3-flash
expect_exit 0 'use of a model outside the catalog still succeeds'
expect_state $'worker=glm-5.3-flash\nworker.until=' 'use of a model outside the catalog still writes the setting'
expect_stderr_has 'worker-model: warning:' 'use of a model outside the catalog warns on stderr'
expect_stderr_has 'selftest-codex.sh --only L1 --model glm-5.3-flash' 'the catalog warning names the L1 check'
expect_stderr_has 'models.json' 'the catalog warning names models.json'
expect_stderr_has 'setup-worker-home.sh' 'the catalog warning names setup-worker-home.sh'
run_switch
expect_stderr_has 'worker-model: warning:' 'status repeats the catalog warning'
run_switch use glm-5.3
expect_exit 0 'use of a model inside the catalog succeeds'
expect_stderr_empty 'use of a model inside the catalog draws no warning'
run_switch --print catalog
expect_stdout yes '--print catalog answers yes for a listed model'
rm "$WORKER_HOME/models.json"
run_switch use glm-5.3-flash
expect_exit 0 'an unreadable catalog does not stop use'
expect_stderr_empty 'an unreadable catalog draws no warning'
run_switch --print catalog
expect_stdout unknown '--print catalog answers unknown when the catalog file is missing'
HOME2=$WORK/home2; mkdir -p "$HOME2/.codex-worker"
printf 'model_catalog_json = "%s/models.json"\n' "$WORKER_HOME" > "$HOME2/.codex-worker/config.toml"
printf '{"models":[{"slug":"glm-5.4"},{"slug":"glm-5.3-flash"}]}\n' > "$WORKER_HOME/models.json"
env -u CODEX_WORKER_HOME HOME="$HOME2" "$SWITCH" --print catalog > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_stdout yes 'an existing ~/.codex-worker is the worker home when CODEX_WORKER_HOME is unset'
HOME3=$WORK/home3; mkdir -p "$HOME3/codex"
printf 'model_catalog_json = "%s/models.json"\n' "$WORKER_HOME" > "$HOME3/codex/config.toml"
printf '{"models":[{"slug":"glm-5.4"},{"slug":"glm-5.3"}]}\n' > "$WORKER_HOME/models.json"
env -u CODEX_WORKER_HOME HOME="$HOME3" CODEX_HOME="$HOME3/codex" "$SWITCH" --print catalog > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_stdout no 'CODEX_HOME is the worker home when ~/.codex-worker is absent'
env CODEX_WORKER_HOME="$WORK/missing-worker-home" "$SWITCH" --print catalog > "$RUN_STDOUT" 2> "$RUN_STDERR"
RUN_EXIT=$?
expect_stdout unknown 'a CODEX_WORKER_HOME that is not a directory skips the catalog check'
run_switch use glm-5.4

run_switch --help
expect_exit 0 'help succeeds'
expect_stderr_empty 'help prints nothing on stderr'
expect_stdout_has 'worker-model.sh use <model>' 'help documents use'
expect_stdout_has -- '--print default' 'help documents --print default'
expect_stdout_has 'glm-5.3-flash' 'help lists the allowed models'

# The default is defined once, in worker-model.sh.
if grep -n 'glm-5\.4' "$SWITCH" | grep -v '^[0-9]*:#' | grep -v '^[0-9]*:DEFAULT_MODEL=glm-5\.4$' | grep -q .; then
  record FAIL 'glm-5.4 appears in worker-model.sh only as the default definition and in help'
else
  record PASS 'glm-5.4 appears in worker-model.sh only as the default definition and in help'
fi
if grep -Eq 'MODELS="\$DEFAULT_MODEL ' "$SWITCH"; then
  record PASS 'the list of allowed models is built from the default'
else
  record FAIL 'the list of allowed models is built from the default'
fi
for script in "$WRAPPER" "$HERE/selftest-codex.sh"; do
  if grep -n 'glm-5\.4' "$script" | grep -v '^[0-9]*:[[:space:]]*#' | grep -Eq 'MODEL="?glm-5\.4"?'; then
    record FAIL "$(basename "$script") never assigns glm-5.4 to MODEL"
  else
    record PASS "$(basename "$script") never assigns glm-5.4 to MODEL"
  fi
done

# codex-worker.sh reads the switch only on a fresh run: every `--print` call sits in
# resolve_worker_model, and that function's only call site is inside the else branch of
# the Resume check, before write_state. Stated by structure, not by line number.
WRAPPER_OUT=$WORK/wrapper-structure.txt
WRAPPER_PATH="$WRAPPER" node - > "$WRAPPER_OUT" 2>&1 <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.env.WRAPPER_PATH, "utf8").split("\n");
const fail = why => { console.log(why); process.exit(1); };
const isPrint = line => /worker-model\.sh"\s+--print/.test(line) && !/^\s*#/.test(line);
const prints = lines.map((line, index) => ({line, index})).filter(({line}) => isPrint(line));
const fnStart = lines.findIndex(line => /^resolve_worker_model\(\) \{\s*$/.test(line));
if (fnStart < 0) fail("no resolve_worker_model() function");
let fnEnd = -1;
for (let i = fnStart + 1; i < lines.length; i++) if (lines[i] === "}") { fnEnd = i; break; }
if (fnEnd < 0) fail("resolve_worker_model() is not closed at top level");
const outside = prints.filter(({index}) => !(index > fnStart && index < fnEnd));
if (!prints.length) fail("resolve_worker_model reads no switch value");
if (outside.length) fail("switch reads outside resolve_worker_model at lines " + outside.map(p => p.index + 1).join(","));
const calls = lines.map((line, index) => ({line, index})).filter(({line}) => /^\s*resolve_worker_model\s*$/.test(line));
if (calls.length !== 1) fail("resolve_worker_model is called " + calls.length + " times, expected 1");
const call = calls[0].index;
let start = -1;
for (let i = 0; i < lines.length; i++) if (lines[i] === "if $RESUME; then") start = i;
if (start < 0) fail("no top-level `if $RESUME; then`");
let elseAt = -1, fiAt = -1;
for (let i = start + 1; i < lines.length && fiAt < 0; i++) {
  if (elseAt < 0 && lines[i] === "else") { elseAt = i; continue; }
  if (elseAt >= 0 && lines[i] === "fi") fiAt = i;
}
if (elseAt < 0 || fiAt < 0) fail("the Resume check has no top-level else/fi");
let writeStateAt = -1;
for (let i = elseAt + 1; i < fiAt; i++) if (/^\s*write_state$/.test(lines[i])) { writeStateAt = i; break; }
if (writeStateAt < 0) fail("no write_state call in the fresh-run branch");
if (!(call > elseAt && call < writeStateAt)) fail("resolve_worker_model is called outside the fresh-run branch before write_state (call at " + (call + 1) + ")");
console.log(`${prints.length} switch read(s) in resolve_worker_model (lines ${prints.map(p => p.index + 1).join(",")}); called at line ${call + 1}, inside the fresh-run branch ${elseAt + 2}-${fiAt}, before write_state at ${writeStateAt + 1}`);
NODE
if [ $? -eq 0 ]; then
  record PASS "codex-worker.sh reads the switch only in the fresh-run branch, before write_state ($(cat "$WRAPPER_OUT"))"
else
  record FAIL "codex-worker.sh reads the switch only in the fresh-run branch, before write_state" "$(cat "$WRAPPER_OUT")"
fi
expect_file_has 'worker-model.sh" --print default' 'codex-worker.sh asks the switch for the default instead of a literal' "$WRAPPER"
if grep -Fq 'resolve_worker_home' "$WRAPPER" && grep -Eq '^\s*resolve_worker_model$' "$WRAPPER" && grep -Fq 'ISS_WORKER_MODEL' "$WRAPPER"; then
  record FAIL 'codex-worker.sh has no environment override for the switch'
else
  record PASS 'codex-worker.sh has no environment override for the switch'
fi
if grep -Fq -- '--force-model' "$WRAPPER"; then
  record FAIL 'codex-worker.sh has no --force-model'
else
  record PASS 'codex-worker.sh has no --force-model'
fi
if [ "$(grep -c 'worker-model' "$HERE/pi-worker.sh")" -eq 0 ]; then
  record PASS 'pi-worker.sh is not wired to the switch'
else
  record FAIL 'pi-worker.sh is not wired to the switch'
fi
if grep -n 'ISS_WORKER_MODEL_FILE' "$HERE/test-locks.sh" | grep -Eq '^[0-9]+:export ISS_WORKER_MODEL_FILE='; then
  record PASS 'test-locks.sh exports the switch isolation in its export block'
else
  record FAIL 'test-locks.sh exports the switch isolation in its export block'
fi
expect_file_has 'Usage: scripts/selftest-codex.sh [--model <id>]' 'the selftest usage line no longer names a default model' "$HERE/selftest-codex.sh"
expect_file_has '1. --model given: that model is tested' 'the selftest header states rule 1' "$HERE/selftest-codex.sh"
expect_file_has '2. no --model: the model is the switch' 'the selftest header states rule 2' "$HERE/selftest-codex.sh"

# The user-facing command is the worker-model skill, symlinked like the others.
SKILL=$ROOT/worker-model/SKILL.md
expect_file_has 'name: worker-model' 'the worker-model skill has its name' "$SKILL"
expect_file_has 'disable-model-invocation: true' 'only the user can invoke the switch skill' "$SKILL"
expect_file_has '输入 /worker-model 时使用' 'the skill description names the slash command' "$SKILL"
expect_file_has 'scripts/worker-model.sh use' 'the skill runs the switch script' "$SKILL"
expect_file_has '原样照抄' 'the skill relays the script status lines verbatim' "$SKILL"
expect_file_has 'selftest-codex.sh --only L1 --model' 'the skill names the L1 check next to a catalog warning' "$SKILL"

# The documents around the switch.
MAIN_SKILL=$ROOT/SKILL.md
expect_file_has 'Worker model switch' 'SKILL.md has a Worker model switch section' "$MAIN_SKILL"
expect_file_has 'has no effect on a flash Run on the default `agent` backend' 'SKILL.md says the switch does not reach a flash Run on the agent backend' "$MAIN_SKILL"
expect_file_has 'Never change the switch yourself' 'SKILL.md says only the user changes the switch' "$MAIN_SKILL"
expect_file_lacks 'CODEX_MODEL' 'SKILL.md no longer has a CODEX_MODEL config' "$MAIN_SKILL"
expect_file_lacks -- '--model <model>' 'the SKILL.md dispatch template passes no --model' "$MAIN_SKILL"
expect_file_lacks -- '--model <CODEX_MODEL>' 'the SKILL.md preflight passes no --model' "$MAIN_SKILL"
expect_file_has 'scripts/selftest-codex.sh --only L1' 'the SKILL.md preflight runs L1 on the switch value' "$MAIN_SKILL"
expect_file_has 'status.json.model' 'SKILL.md names status.json.model where a worker failure is reported' "$MAIN_SKILL"
expect_file_has '/worker-model use glm-5.4' 'SKILL.md names the reset command' "$MAIN_SKILL"
expect_file_has 'distinct `status.json.model` values' 'the SKILL.md report takes the Worker model from status.json.model' "$MAIN_SKILL"
expect_file_has '不适用' 'the SKILL.md report writes not-applicable for the agent backend' "$MAIN_SKILL"
expect_file_lacks 'CODEX_MODEL' 'GLOSSARY.md no longer mentions CODEX_MODEL' "$ROOT/GLOSSARY.md"
expect_file_has 'its own global switch' 'GLOSSARY.md gives the Judgment model its own switch' "$ROOT/GLOSSARY.md"
expect_file_has '/worker-model' 'GLOSSARY.md points the Worker model at its switch' "$ROOT/GLOSSARY.md"
expect_file_has 'codex path only' 'GLOSSARY.md says the switch covers the codex path only' "$ROOT/GLOSSARY.md"
expect_file_has '/worker-model' 'find-next/SKILL.md points at the slash command' "$ROOT/find-next/SKILL.md"
expect_file_has 'status.json.model' 'find-next/SKILL.md names status.json.model where a worker failure is reported' "$ROOT/find-next/SKILL.md"
LINK='ln -s ~/.claude/skills/implement-spec-split/worker-model ~/.claude/skills/worker-model'
for doc in README.md docs/setup.md docs/setup.en.md; do
  expect_file_has "$LINK" "$doc documents the skill symlink" "$ROOT/$doc"
  expect_file_has '/worker-model' "$doc documents the slash command" "$ROOT/$doc"
done
expect_file_has 'test-worker-model.sh' 'MAINTAINING.md lists the switch test' "$ROOT/MAINTAINING.md"
expect_file_has 'ADR 0003' 'MAINTAINING.md records the decision' "$ROOT/MAINTAINING.md"
if [ "$(grep -c '2026-11-27 修订' "$ROOT/MAINTAINING.md")" -ge 2 ]; then
  record PASS 'MAINTAINING.md revises design point 9 and point 27 with a dated note'
else
  record FAIL 'MAINTAINING.md revises design point 9 and point 27 with a dated note'
fi
expect_file_has '2026-11-27 注记' 'docs/codex-backend.md annotates constraint 5 with a date' "$ROOT/docs/codex-backend.md"
expect_file_has 'opus-codex-division: v2' 'the global CLAUDE.md template is v2' "$ROOT/templates/global-claude-md.md"
expect_file_has '不要给 wrapper 传 `--model`' 'the global CLAUDE.md template tells sessions not to pass --model' "$ROOT/templates/global-claude-md.md"
expect_file_has 'opus-codex-division: v2' 'the English global CLAUDE.md template is v2' "$ROOT/templates/global-claude-md.en.md"
expect_file_has 'opus-codex-division: v2' 'test-doctor.sh installs the template version' "$HERE/test-doctor.sh"
expect_file_has '模板是 v2' 'test-doctor.sh expects the template version in the warning' "$HERE/test-doctor.sh"

ADR=$ROOT/docs/adr/0003-worker-model-hot-switch.md
if [ -f "$ADR" ]; then record PASS 'ADR 0003 exists'; else record FAIL 'ADR 0003 exists'; fi
for text in '--model' 'judgment-model.sh' 'agent 后端' 'lib-switch.sh' '--force-model' 'ISS_WORKER_MODEL' 'pi-worker.sh' 'coder-model' '停车' \
  '照常自动落地' 'flash 容易过度自信' '软约束' '硬依赖' '未验证'; do
  expect_file_has "$text" "ADR 0003 records [$text]" "$ADR"
done

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
