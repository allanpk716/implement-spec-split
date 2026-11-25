#!/usr/bin/env bash
# Tests for find-next/scripts/watch-specs.sh (fake gh and fake claim.sh, no network).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/find-next/scripts/watch-specs.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/watch-specs-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN=$WORK/bin
REPO_PATH=$WORK/repo-path
CLAIMS=$WORK/claims.txt
PASSED=0
FAILED=0
RUN_EXIT=

ok() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    ok "$name"
  else
    bad "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    ok "$name"
  else
    bad "$name" "missing [$text]; $(tail -n 5 "$file" 2>/dev/null)"
  fi
}

expect_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    bad "$name" "unexpected [$text]"
  else
    ok "$name"
  fi
}

expect_file() {
  file=$1
  name=$2
  if [ -e "$file" ]; then
    ok "$name"
  else
    bad "$name" "missing [$file]"
  fi
}

expect_no_file() {
  file=$1
  name=$2
  if [ -e "$file" ]; then
    bad "$name" "unexpected [$file]"
  else
    ok "$name"
  fi
}

jget() { # file expression
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=eval(process.argv[2]);console.log(v)' "$1" "$2"
}

check_json() { # name file expression expected
  got=$(jget "$2" "$3" 2>&1)
  if [ "$got" = "$4" ]; then
    ok "$1"
  else
    bad "$1" "want '$4' got '$got'"
  fi
}

mkdir -p "$BIN" "$REPO_PATH" || exit 1
: > "$CLAIMS"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
FIXTURE_DIR=${FIXTURE_DIR:?FIXTURE_DIR is required}
case "$*" in
  *'issue list'*)
    if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'fake gh: simulated failure' >&2
      exit 1
    fi
    cat "$FIXTURE_DIR/issues.json"
    exit $?
    ;;
  *'/comments'*)
    if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'fake gh: simulated failure' >&2
      exit 1
    fi
    number=$(printf '%s\n' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\)/comments.*#\1#p')
    if [ -f "$FIXTURE_DIR/comments-$number.json" ]; then
      cat "$FIXTURE_DIR/comments-$number.json"
    else
      printf '[]\n'
    fi
    exit $?
    ;;
  *)
    printf 'fake gh: unexpected arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$BIN/gh"

cat > "$BIN/claim.sh" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != status ]; then
  printf 'fake claim: unexpected arguments: %s\n' "$*" >&2
  exit 2
fi
word=free
if [ -n "${CLAIM_FIXTURE:-}" ] && [ -f "$CLAIM_FIXTURE" ]; then
  found=$(awk -v n="$2" '$1 == n { print $2; exit }' "$CLAIM_FIXTURE")
  [ -n "$found" ] && word=$found
fi
printf '%s\n' "$word"
EOF
chmod +x "$BIN/claim.sh"

new_fixture() {
  FIXTURE=$WORK/fx-$1
  mkdir -p "$FIXTURE"
}

# run_watch OUT [extra watch-specs arguments]
run_watch() {
  out=$1
  shift
  env FIXTURE_DIR="$FIXTURE" WATCH_SPECS_CLAIM="$BIN/claim.sh" CLAIM_FIXTURE="$CLAIMS" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" --repo test/repo --repo-path "$REPO_PATH" --state "$STATE" \
      --interval 0 --once "$@" > "$out" 2> "$out.err"
  RUN_EXIT=$?
}

run_watch_raw() { # OUT [arguments]
  out=$1
  shift
  env FIXTURE_DIR="${FIXTURE:-$WORK/none}" WATCH_SPECS_CLAIM="$BIN/claim.sh" CLAIM_FIXTURE="$CLAIMS" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@" > "$out" 2> "$out.err"
  RUN_EXIT=$?
}

# --- baseline -----------------------------------------------------------------
new_fixture baseline
STATE=$WORK/state-baseline.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 1, "title": "Spec one", "state": "OPEN", "body": "## Problem Statement\none"}
]
JSON
: > "$CLAIMS"
run_watch "$WORK/baseline.out"
expect_exit 0 "baseline --once exits 0"
expect_has 'BASELINE' "baseline prints BASELINE" "$WORK/baseline.out"
expect_file "$STATE" "baseline writes the state file"
check_json "baseline records spec 1 open" "$STATE" 'j.specs["1"].state' open
check_json "baseline records a free claim" "$STATE" 'j.specs["1"].claim' free
expect_without 'LANDED' "baseline reports no event" "$WORK/baseline.out"

# --- LANDED -------------------------------------------------------------------
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 1, "title": "Spec one", "state": "CLOSED", "body": "## Problem Statement\none"}
]
JSON
cat > "$FIXTURE/comments-1.json" <<'JSON'
[
  {"id": 100, "body": "## 落地报告\nmerged", "html_url": "https://example.test/issues/1#comment-100"}
]
JSON
run_watch "$WORK/landed.out"
expect_exit 0 "LANDED exits 0"
expect_has $'LANDED\t#1\tSpec one\thttps://example.test/issues/1#comment-100' \
  "LANDED line carries the landing report url" "$WORK/landed.out"
expect_has $'SUMMARY\topen=0\tactive=0\tclosed=1' "LANDED summary counts" "$WORK/landed.out"
expect_has 'ALL_DONE' "LANDED with nothing left open prints ALL_DONE" "$WORK/landed.out"
check_json "LANDED state closed" "$STATE" 'j.specs["1"].state' closed
check_json "LANDED keeps report id" "$STATE" 'j.specs["1"].last_report_id' 100
check_json "LANDED keeps report kind" "$STATE" 'j.specs["1"].last_report_kind' landing

# --- LANDED without a landing report ------------------------------------------
new_fixture landed-empty
STATE=$WORK/state-landed-empty.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 14, "title": "Spec fourteen", "state": "OPEN", "body": "## Problem Statement\nx"}
]
JSON
run_watch "$WORK/landed-empty-base.out"
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 14, "title": "Spec fourteen", "state": "CLOSED", "body": "## Problem Statement\nx"}
]
JSON
run_watch "$WORK/landed-empty.out"
expect_exit 0 "LANDED without report exits 0"
expect_has $'LANDED\t#14\tSpec fourteen\t' "LANDED without report has empty extra" "$WORK/landed-empty.out"

# --- PARTIAL ------------------------------------------------------------------
new_fixture partial
STATE=$WORK/state-partial.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 2, "title": "Spec two", "state": "OPEN", "body": "## Problem Statement\ntwo"}
]
JSON
run_watch "$WORK/partial-base.out"
cat > "$FIXTURE/comments-2.json" <<'JSON'
[
  [
    {"id": 200, "body": "## 落地报告\npartial: ticket 1 merged", "html_url": "https://example.test/issues/2#comment-200"}
  ]
]
JSON
run_watch "$WORK/partial.out"
expect_exit 0 "PARTIAL exits 0"
expect_has $'PARTIAL\t#2\tSpec two\thttps://example.test/issues/2#comment-200' \
  "PARTIAL line carries the comment url" "$WORK/partial.out"
expect_has $'SUMMARY\topen=1\tactive=0\tclosed=0' "PARTIAL summary keeps the spec open" "$WORK/partial.out"
expect_without 'LANDED' "PARTIAL does not report LANDED" "$WORK/partial.out"
expect_without 'ALL_DONE' "PARTIAL does not report ALL_DONE" "$WORK/partial.out"

# --- PARKED -------------------------------------------------------------------
new_fixture parked
STATE=$WORK/state-parked.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 3, "title": "Spec three", "state": "OPEN", "body": "## Problem Statement\nthree"}
]
JSON
run_watch "$WORK/parked-base.out"
cat > "$FIXTURE/comments-3.json" <<'JSON'
[
  {"id": 300, "body": "## 停车报告\nneeds a human decision", "html_url": "https://example.test/issues/3#comment-300"}
]
JSON
run_watch "$WORK/parked.out"
expect_exit 0 "PARKED exits 0"
expect_has $'PARKED\t#3\tSpec three\thttps://example.test/issues/3#comment-300' \
  "PARKED line carries the comment url" "$WORK/parked.out"
expect_has $'SUMMARY\topen=1\tactive=0\tclosed=0' "PARKED summary counts" "$WORK/parked.out"
expect_without 'DIED' "PARKED does not report DIED" "$WORK/parked.out"

# --- STARTED ------------------------------------------------------------------
new_fixture started
STATE=$WORK/state-started.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 4, "title": "Spec four", "state": "OPEN", "body": "## Problem Statement\nfour"}
]
JSON
: > "$CLAIMS"
run_watch "$WORK/started-base.out"
printf '%s\n' '4 active' > "$CLAIMS"
run_watch "$WORK/started.out"
expect_exit 0 "STARTED exits 0"
expect_has $'STARTED\t#4\tSpec four\t' "STARTED line" "$WORK/started.out"
expect_has $'SUMMARY\topen=1\tactive=1\tclosed=0' "STARTED counts an active claim" "$WORK/started.out"
check_json "STARTED stores the active claim" "$STATE" 'j.specs["4"].claim' active

# --- DIED ---------------------------------------------------------------------
new_fixture died
STATE=$WORK/state-died.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 5, "title": "Spec five", "state": "OPEN", "body": "## Problem Statement\nfive"}
]
JSON
printf '%s\n' '5 active' > "$CLAIMS"
run_watch "$WORK/died-base.out"
printf '%s\n' '5 interrupted' > "$CLAIMS"
run_watch "$WORK/died.out"
expect_exit 0 "DIED exits 0"
expect_has $'DIED\t#5\tSpec five\t' "DIED line" "$WORK/died.out"
expect_has $'SUMMARY\topen=1\tactive=0\tclosed=0' "DIED summary counts" "$WORK/died.out"
check_json "DIED stores the interrupted claim" "$STATE" 'j.specs["5"].claim' interrupted

# --- a new report suppresses DIED ---------------------------------------------
new_fixture report-no-died
STATE=$WORK/state-report-no-died.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 6, "title": "Spec six", "state": "OPEN", "body": "## Problem Statement\nsix"}
]
JSON
printf '%s\n' '6 active' > "$CLAIMS"
run_watch "$WORK/report-no-died-base.out"
cat > "$FIXTURE/comments-6.json" <<'JSON'
[
  {"id": 600, "body": "## 落地报告\npartial: one ticket left", "html_url": "https://example.test/issues/6#comment-600"}
]
JSON
printf '%s\n' '6 interrupted' > "$CLAIMS"
run_watch "$WORK/report-no-died.out"
expect_exit 0 "report with interrupted claim exits 0"
expect_has $'PARTIAL\t#6\tSpec six\thttps://example.test/issues/6#comment-600' \
  "report is reported as PARTIAL" "$WORK/report-no-died.out"
expect_without 'DIED' "a new report suppresses DIED" "$WORK/report-no-died.out"

# --- NEW_SPEC -----------------------------------------------------------------
new_fixture new-spec
STATE=$WORK/state-new-spec.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 7, "title": "Spec seven", "state": "OPEN", "body": "## Problem Statement\nseven"}
]
JSON
: > "$CLAIMS"
run_watch "$WORK/new-spec-base.out"
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 7, "title": "Spec seven", "state": "OPEN", "body": "## Problem Statement\nseven"},
  {"number": 8, "title": "Spec eight", "state": "OPEN", "body": "## Problem Statement\neight"}
]
JSON
run_watch "$WORK/new-spec.out"
expect_exit 0 "NEW_SPEC exits 0"
expect_has $'NEW_SPEC\t#8\tSpec eight\t' "NEW_SPEC line" "$WORK/new-spec.out"
expect_has $'SUMMARY\topen=2\tactive=0\tclosed=0' "NEW_SPEC summary counts both specs" "$WORK/new-spec.out"
expect_without $'NEW_SPEC\t#7' "NEW_SPEC is not reported for known specs" "$WORK/new-spec.out"
check_json "NEW_SPEC stores the new spec" "$STATE" 'j.specs["8"].state' open

# --- ALL_DONE -----------------------------------------------------------------
new_fixture all-done
STATE=$WORK/state-all-done.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 9, "title": "Spec nine", "state": "OPEN", "body": "## Problem Statement\nnine"}
]
JSON
run_watch "$WORK/all-done-base.out"
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 9, "title": "Spec nine", "state": "CLOSED", "body": "## Problem Statement\nnine"}
]
JSON
cat > "$FIXTURE/comments-9.json" <<'JSON'
[
  {"id": 900, "body": "## 落地报告\nall merged", "html_url": "https://example.test/issues/9#comment-900"}
]
JSON
run_watch "$WORK/all-done-land.out"
expect_exit 0 "closing the last spec exits 0"
expect_has 'ALL_DONE' "closing the last spec prints ALL_DONE" "$WORK/all-done-land.out"
run_watch "$WORK/all-done.out"
expect_exit 0 "ALL_DONE exits 0 when nothing is open"
expect_has $'SUMMARY\topen=0\tactive=0\tclosed=1' "ALL_DONE summary" "$WORK/all-done.out"
expect_has 'ALL_DONE' "ALL_DONE line without events" "$WORK/all-done.out"
expect_without 'LANDED' "ALL_DONE run reports no event" "$WORK/all-done.out"

# --- --once without events ----------------------------------------------------
new_fixture once-empty
STATE=$WORK/state-once-empty.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 10, "title": "Spec ten", "state": "OPEN", "body": "## Problem Statement\nten"}
]
JSON
: > "$CLAIMS"
run_watch "$WORK/once-empty-base.out"
run_watch "$WORK/once-empty.out"
expect_exit 2 "--once without events exits 2"
expect_has $'SUMMARY\topen=1\tactive=0\tclosed=0' "--once without events prints SUMMARY" "$WORK/once-empty.out"
expect_without 'ALL_DONE' "--once without events does not print ALL_DONE" "$WORK/once-empty.out"
expect_without 'BASELINE' "--once with an existing state is not a baseline" "$WORK/once-empty.out"

# --- gh failure keeps the old snapshot ----------------------------------------
new_fixture gh-fail
STATE=$WORK/state-gh-fail.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 11, "title": "Spec eleven", "state": "OPEN", "body": "## Problem Statement\neleven"}
]
JSON
: > "$CLAIMS"
run_watch "$WORK/gh-fail-base.out"
cat > "$FIXTURE/comments-11.json" <<'JSON'
[
  {"id": 1100, "body": "## 落地报告\nlate report", "html_url": "https://example.test/issues/11#comment-1100"}
]
JSON
cp "$STATE" "$WORK/gh-fail-before.json"
FAKE_GH_FAIL=1 run_watch "$WORK/gh-fail.out"
expect_exit 3 "gh failure exits 3 in --once mode"
if cmp -s "$STATE" "$WORK/gh-fail-before.json"; then
  ok "gh failure leaves the snapshot untouched"
else
  bad "gh failure leaves the snapshot untouched" "state file changed"
fi
expect_has 'failed' "gh failure warns on stderr" "$WORK/gh-fail.out.err"
run_watch "$WORK/gh-fail-retry.out"
expect_exit 0 "the retry after a gh failure works"
expect_has $'PARTIAL\t#11\tSpec eleven\thttps://example.test/issues/11#comment-1100' \
  "a failed round does not consume the change" "$WORK/gh-fail-retry.out"

new_fixture gh-fail-baseline
STATE=$WORK/state-gh-fail-baseline.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 15, "title": "Spec fifteen", "state": "OPEN", "body": "## Problem Statement\nx"}
]
JSON
FAKE_GH_FAIL=1 run_watch "$WORK/gh-fail-baseline.out"
expect_exit 3 "baseline gh failure exits 3"
expect_no_file "$STATE" "baseline gh failure writes no state file"

# --- a corrupt state file is treated as a new baseline ------------------------
new_fixture corrupt-state
STATE=$WORK/state-corrupt.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 16, "title": "Spec sixteen", "state": "OPEN", "body": "## Problem Statement\nx"}
]
JSON
printf '%s\n' 'not json' > "$STATE"
run_watch "$WORK/corrupt.out"
expect_exit 0 "a corrupt state file exits 0"
expect_has 'BASELINE' "a corrupt state file is a baseline" "$WORK/corrupt.out"
expect_has 'not valid JSON' "a corrupt state file warns" "$WORK/corrupt.out.err"
expect_without 'NEW_SPEC' "a corrupt state file reports no event" "$WORK/corrupt.out"

# --- non-spec issues are ignored ----------------------------------------------
new_fixture nonspec
STATE=$WORK/state-nonspec.json
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"number": 12, "title": "Plain issue", "state": "OPEN", "body": "just a bug report"},
  {"number": 13, "title": "Spec thirteen", "state": "OPEN", "body": "## Problem Statement\nthirteen"}
]
JSON
run_watch "$WORK/nonspec.out"
expect_exit 0 "non-spec issues do not fail the run"
check_json "non-spec issue is not snapshotted" "$STATE" 'Object.keys(j.specs).sort().join(",")' 13
run_watch "$WORK/nonspec-poll.out"
expect_exit 2 "non-spec fixture only leaves an open spec"
expect_has $'SUMMARY\topen=1\tactive=0\tclosed=0' "non-spec issue is not counted" "$WORK/nonspec-poll.out"

# --- usage --------------------------------------------------------------------
run_watch_raw "$WORK/no-args.out"
expect_exit 64 "no arguments exits 64"
run_watch_raw "$WORK/unknown.out" --repo test/repo --repo-path "$REPO_PATH" --state "$WORK/x.json" --once --bogus
expect_exit 64 "unknown argument exits 64"
run_watch_raw "$WORK/no-repo.out" --repo-path "$REPO_PATH" --state "$WORK/x.json" --once
expect_exit 64 "missing --repo exits 64"
run_watch_raw "$WORK/bad-repo.out" --repo nodir --repo-path "$REPO_PATH" --state "$WORK/x.json" --once
expect_exit 64 "--repo without an owner exits 64"
run_watch_raw "$WORK/bad-interval.out" --repo test/repo --repo-path "$REPO_PATH" --state "$WORK/x.json" --once --interval x
expect_exit 64 "non-numeric --interval exits 64"
run_watch_raw "$WORK/bad-path.out" --repo test/repo --repo-path "$WORK/missing-repo" --state "$WORK/x.json" --once
expect_exit 64 "missing --repo-path exits 64"
run_watch_raw "$WORK/help.out" --help
expect_exit 0 "--help exits 0"
expect_has 'usage:' "--help prints usage" "$WORK/help.out"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
