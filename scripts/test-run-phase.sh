#!/usr/bin/env bash
# Tests for scripts/run-phase.sh (uses a temporary HOME, never the real ~/.cache).

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RP=$ROOT/scripts/run-phase.sh
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
ok() { PASSED=$((PASSED+1)); printf 'PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
# jget FILE EXPR -> prints JS expression value of parsed json "j"
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=eval(process.argv[2]);console.log(v)' "$1" "$2"; }
check() { # name file expr expected
  local got; got=$(jget "$2" "$3" 2>&1)
  [ "$got" = "$4" ] && ok "$1" || bad "$1" "want '$4' got '$got'"
}

# every phase writes phase/wave/tickets/updated
for p in split implement integrate review land parked done; do
  d=$WORK/p-$p; mkdir -p "$d"
  out=$("$RP" "$p" --run-dir "$d" --wave 2 --merged 3 --in-progress 1 --todo 4 2>&1); rc=$?
  [ $rc -eq 0 ] || bad "phase $p exit" "rc=$rc $out"
  check "phase $p phase" "$d/run.json" 'j.phase' "$p"
  check "phase $p wave" "$d/run.json" 'j.wave' 2
  check "phase $p tickets" "$d/run.json" 'j.tickets.merged+","+j.tickets.in_progress+","+j.tickets.todo' "3,1,4"
  check "phase $p updated" "$d/run.json" '/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/.test(j.updated)' true
done

# overwrite
d=$WORK/ow; mkdir -p "$d"
"$RP" implement --run-dir "$d" --wave 1 --merged 0 --in-progress 2 --todo 3
"$RP" review --run-dir "$d" --wave 1 --merged 5 --in-progress 0 --todo 0
check overwrite-phase "$d/run.json" 'j.phase' review
check overwrite-count "$d/run.json" 'j.tickets.merged' 5
[ -z "$(ls "$d" | grep -v '^run.json$')" ] && ok "no temp leftovers" || bad "no temp leftovers" "$(ls "$d")"

# omitted fields are null
d=$WORK/nul; mkdir -p "$d"; "$RP" split --run-dir "$d"
check omitted-null "$d/run.json" 'j.wave===null && j.tickets.todo===null' true

# repo+spec: creates, then reuses the latest
H=$WORK/home; mkdir -p "$H"
HOME=$H "$RP" split --repo myrepo --spec 7 --wave 1
n=$(ls "$H/.cache/implement-spec-split/runs" | grep -c '^myrepo-7-')
[ "$n" = 1 ] && ok "repo+spec creates run dir" || bad "repo+spec creates run dir" "n=$n"
mkdir -p "$H/.cache/implement-spec-split/runs/myrepo-7-99990101-0000" "$H/.cache/implement-spec-split/runs/myrepo-70-99990101-0000"
HOME=$H "$RP" land --repo myrepo --spec 7
[ -f "$H/.cache/implement-spec-split/runs/myrepo-7-99990101-0000/run.json" ] && ok "uses latest run dir" || bad "uses latest run dir" "missing"
[ ! -f "$H/.cache/implement-spec-split/runs/myrepo-70-99990101-0000/run.json" ] && ok "spec 7 does not match 70" || bad "spec 7 vs 70" "wrong dir"

# ISS_STATE_DIR chooses the same Run root as board.sh.
S=$WORK/custom-state
HOME=$H ISS_STATE_DIR=$S "$RP" split --repo myrepo --spec 9 --wave 1
[ -f "$S/runs/myrepo-9-"*/run.json ] && ok "ISS_STATE_DIR selects run root" || bad "ISS_STATE_DIR selects run root" "missing custom-state run"

# invalid phase
out=$("$RP" bogus --run-dir "$WORK/p-done" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi usage && ok "invalid phase" || bad "invalid phase" "rc=$rc"
out=$("$RP" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "no args fails" || bad "no args fails" "rc=$rc"
"$RP" --help >/dev/null 2>&1 && ok "help exits 0" || bad "help exits 0" ""

# write failures: warn, exit 0
out=$("$RP" done --run-dir "$WORK/missing-dir" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -qi warn && ok "missing dir warns, exit 0" || bad "missing dir" "rc=$rc $out"
mkdir -p "$WORK/ro"; chmod 555 "$WORK/ro"
out=$("$RP" done --run-dir "$WORK/ro" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -qi warn && ok "unwritable dir warns, exit 0" || bad "unwritable dir" "rc=$rc $out"
chmod 755 "$WORK/ro"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
