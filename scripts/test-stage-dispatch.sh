#!/usr/bin/env bash
# Isolated fake-Orca tests for scripts/stage-dispatch.sh, the Stage dispatch
# module (issue #41). The fake orca sits off PATH and is reached only through
# ISS_ORCA; a guard orca on PATH fails the test if anything else calls it. The
# launchers the route names are fakes on PATH that record a start and fail: the
# module may only look them up, Orca's terminal starts them. The Stage route
# table is the real scripts/stage-route.sh reading a table of this test's own
# (ISS_STAGE_ROUTE_FILE). The headless executors are fakes swapped in through
# the module's test hooks. No real Orca, no launcher, no network.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/stage-dispatch.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stage-dispatch-test.XXXXXX")
# macOS /var is a symlink to /private/var: the module hands Orca physical
# paths (a path: selector must be canonical), so the test compares those.
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
ORCA_BIN=$WORK/orca-bin
ORCA_LOG=$WORK/orca.log
GUARD_LOG=$WORK/guard.log
LAUNCHER_LOG=$WORK/launcher.log
FAKE_LOG=$WORK/fake.log
SPEC_LOG=$WORK/spec.md
STAGE_ROUTE_FILE=$WORK/stage-route
RUN_DIR=$WORK/runs/implement-spec-split-26-20261128-0900
REPO=$WORK/repo
SPEC_WT=$WORK/wt/spec-26
TICKET_WT=$WORK/wt/spec-26-t41
PASSED=0
FAILED=0
RUN_EXIT=
RUN_STDOUT=$WORK/stdout.txt
RUN_STDERR=$WORK/stderr.txt

# The table and HOME of this test alone: the module and stage-route.sh never
# look at the user's real ~/.claude/state.
: > "$STAGE_ROUTE_FILE"
mkdir -p "$WORK/home"
export ISS_STAGE_ROUTE_FILE=$STAGE_ROUTE_FILE
export HOME=$WORK/home

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
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected; stderr=$(head -c 300 "$RUN_STDERR")"
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

expect_file_without() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text] in $(basename "$file")"
  else
    record PASS "$name"
  fi
}

expect_stdout() { # expected name
  actual=$(cat "$RUN_STDOUT" 2>/dev/null)
  if [ "$actual" = "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "stdout=[$actual], expected [$1]"
  fi
}

expect_count() { # text expected name file
  actual=$(grep -Fc -- "$1" "$4" 2>/dev/null || true)
  if [ "$actual" -eq "$2" ]; then
    record PASS "$3"
  else
    record FAIL "$3" "count=$actual, expected=$2"
  fi
}

# The Orca calls the fake received, in order, space separated: each top-level
# command and subcommand, without their arguments.
orca_sequence() {
  grep -v '^ARG ' "$ORCA_LOG" 2>/dev/null | grep -vxE 'orchestration|terminal|agent|status|repo|worktree' | tr '\n' ' '
}

# The value after the n-th occurrence of a flag in a log, or nothing.
value_after() { # flag n file
  awk -v flag="ARG $1" -v wanted="$2" '$0 == flag { seen++; if (seen == wanted) { getline; sub(/^ARG /, ""); print; exit } }' "$3"
}

# One field of a JSON file, or nothing when the file has no such field.
json_field() { # file dotted.path
  node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
    let value = root;
    for (const key of process.argv[2].split(".")) {
      if (value === null || value === undefined) break;
      value = value[key];
    }
    if (value === undefined || value === null) process.exit(1);
    process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
  ' "$@"
}

expect_json() { # expected name file dotted.path
  actual=$(json_field "$3" "$4")
  if [ "$actual" = "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "got [$actual], expected [$1]"
  fi
}

# Sets a route through the real table script, the way /grill-router does.
set_route() { # <stage>=<profile>/<model>/<effort>
  "$ROOT/scripts/stage-route.sh" use "$1" >/dev/null 2>&1
}

# The repository the module dispatches in: a main checkout with the Spec
# worktree on the Integration branch beside it, as Orca's worktree create
# leaves them.
git init --quiet --initial-branch=main "$REPO" || exit 1
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config commit.gpgsign false
printf 'test repository\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git -C "$REPO" worktree add --quiet -b spec-26 "$SPEC_WT" main || exit 1
mkdir -p "$RUN_DIR" "$BIN" "$ORCA_BIN" || exit 1
printf '# Ticket 41\n\nImplement the Stage dispatch module.\n' > "$WORK/brief-41.md"

cat > "$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
command=$1
shift
printf '%s\n' "$command" >> "$ORCA_LOG"
for argument in "$@"; do printf 'ARG %s\n' "$argument" >> "$ORCA_LOG"; done
case "$command" in
  worktree|terminal|orchestration)
    subcommand=$1
    shift
    printf '%s\n' "$subcommand" >> "$ORCA_LOG"
    ;;
  *) printf 'fake orca: unsupported command %s\n' "$command" >&2; exit 70 ;;
esac
if [ "${ORCA_TEST_FAIL:-}" = "$command $subcommand" ]; then
  printf 'fake orca: %s %s failed\n' "$command" "$subcommand" >&2
  exit 70
fi
case "$command $subcommand" in
  'worktree create')
    # The new worktree lives under ORCA_TEST_CREATE_ROOT, named as --name says.
    if [ -n "${ORCA_TEST_CREATE_ROOT:-}" ]; then
      name=
      previous=
      for argument in "$@"; do
        if [ "$previous" = --name ]; then name=$argument; fi
        previous=$argument
      done
      mkdir -p "$ORCA_TEST_CREATE_ROOT/$name"
      printf '%s\n' '{"ok":true,"result":{"worktree":{"path":"'"$ORCA_TEST_CREATE_ROOT/$name"'"}}}'
    else
      printf '%s\n' '{"ok":true,"result":{"worktree":{}}}'
    fi
    ;;
  'worktree rm') printf '%s\n' '{"ok":true,"result":{"removed":true}}' ;;
  'terminal create')
    if [ "${ORCA_TEST_CREATE_NO_HANDLE:-0}" = 1 ]; then
      printf '%s\n' '{"ok":true,"result":{"terminal":{"tabId":"tab_impl"}}}'
    else
      printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term_impl","tabId":"tab_impl"}}}'
    fi
    ;;
  'terminal close') printf '%s\n' '{"ok":true,"result":{"ptyKilled":true}}' ;;
  'orchestration worker-start')
    previous=
    for argument in "$@"; do
      if [ "$previous" = --spec-file ]; then cp "$argument" "$SPEC_LOG"; fi
      previous=$argument
    done
    if [ "${ORCA_TEST_START_NO_DISPATCH:-0}" = 1 ]; then
      printf '%s\n' '{"ok":true,"result":{"state":"ready"}}'
    else
      printf '%s\n' '{"ok":true,"result":{"dispatchId":"'"${ORCA_TEST_DISPATCH_ID:-ctx_impl}"'","taskId":"task_impl","runId":"run_spec26","state":"ready","mode":"terminal","terminal":"term_impl"}}'
    fi
    ;;
  'orchestration worker-show')
    if [ -n "${ORCA_TEST_SHOW_JSON:-}" ]; then cat "$ORCA_TEST_SHOW_JSON"; fi
    ;;
  'orchestration worker-release')
    printf '%s\n' '{"ok":true,"result":{"state":"released","processAction":"closed_agent_terminal"}}'
    ;;
  'orchestration check')
    if [ -n "${ORCA_TEST_CHECK_JSON:-}" ]; then cat "$ORCA_TEST_CHECK_JSON"; fi
    ;;
  *) printf 'fake orca: unsupported %s %s\n' "$command" "${subcommand:-}" >&2; exit 70 ;;
esac
exit 0
EOF
chmod +x "$ORCA_BIN/orca"

# Anything on PATH that reaches an orca bypassed the library.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf 'guard orca called with: %s\n' "$*" >> "$GUARD_LOG"
exit 99
EOF
chmod +x "$BIN/orca"

# The launchers a route can name: looked up, never started by the module.
for launcher in claude claude-glm claude-flash codex; do
  cat > "$BIN/$launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$LAUNCHER_LOG"
echo "fake launcher must only be started by Orca's terminal, never by the module" >&2
exit 99
EOF
  chmod +x "$BIN/$launcher"
done

# The headless executors, swapped in through the module's test hooks: they
# record what they were given, write the report where they were told, and exit
# with FAKE_TEST_EXIT.
cat > "$BIN/fake-codex-worker" <<'EOF'
#!/usr/bin/env bash
printf 'codex-worker' > "$FAKE_LOG"
for argument in "$@"; do printf 'ARG %s\n' "$argument" >> "$FAKE_LOG"; done
run_dir=
previous=
for argument in "$@"; do
  if [ "$previous" = --run-dir ]; then run_dir=$argument; fi
  previous=$argument
done
if [ "${FAKE_TEST_EXIT:-0}" = 0 ] && [ -n "$run_dir" ]; then
  printf 'research result\n' > "$run_dir/result.md"
  printf '%s\n' "{\"result_file\":\"$run_dir/result.md\",\"model\":\"glm-5.4\"}" > "$run_dir/status.json"
fi
exit "${FAKE_TEST_EXIT:-0}"
EOF
cat > "$BIN/fake-opus-review" <<'EOF'
#!/usr/bin/env bash
printf 'opus-review' > "$FAKE_LOG"
for argument in "$@"; do printf 'ARG %s\n' "$argument" >> "$FAKE_LOG"; done
out=
previous=
for argument in "$@"; do
  if [ "$previous" = --out ]; then out=$argument; fi
  previous=$argument
done
if [ "${FAKE_TEST_EXIT:-0}" = 0 ] && [ -n "$out" ]; then
  printf 'review findings\n' > "$out"
fi
exit "${FAKE_TEST_EXIT:-0}"
EOF
chmod +x "$BIN/fake-codex-worker" "$BIN/fake-opus-review"

# Stands in for stage-route.sh where the real table cannot produce the fault.
cat > "$WORK/fake-stage-route.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${DISPATCH_TEST_FAKE_ROUTE_EXIT:-0}" != 0 ]; then
  echo "fake stage-route: cannot read the route" >&2
  exit "$DISPATCH_TEST_FAKE_ROUTE_EXIT"
fi
case "$1" in
  --launch) printf '%s\n' "${DISPATCH_TEST_FAKE_LAUNCHER:-claude}" --model opus --effort high ;;
  --print)
    case "$3" in
      profile) printf 'claude\n' ;;
      model) printf 'opus\n' ;;
      effort) printf 'high\n' ;;
    esac
    ;;
esac
EOF
chmod +x "$WORK/fake-stage-route.sh"

# run <module arguments...>
#   Runs the module with the fakes, stdout in RUN_STDOUT and stderr in
#   RUN_STDERR. The knobs a case sets are the shell variables below;
#   fresh_case puts them all back.
run_module() {
  env HOME="$WORK/home" ISS_STAGE_ROUTE_FILE="$STAGE_ROUTE_FILE" \
      ISS_ORCA="$ORCA_BIN/orca" ORCA_LOG="$ORCA_LOG" GUARD_LOG="$GUARD_LOG" \
      LAUNCHER_LOG="$LAUNCHER_LOG" FAKE_LOG="$FAKE_LOG" SPEC_LOG="$SPEC_LOG" \
      ORCA_TEST_CREATE_ROOT="$ORCA_TEST_CREATE_ROOT" \
      ORCA_TEST_FAIL="$ORCA_TEST_FAIL" ORCA_TEST_CREATE_NO_HANDLE="$ORCA_TEST_CREATE_NO_HANDLE" \
      ORCA_TEST_START_NO_DISPATCH="$ORCA_TEST_START_NO_DISPATCH" \
      ORCA_TEST_DISPATCH_ID="$ORCA_TEST_DISPATCH_ID" \
      ORCA_TEST_SHOW_JSON="$ORCA_TEST_SHOW_JSON" ORCA_TEST_CHECK_JSON="$ORCA_TEST_CHECK_JSON" \
      FAKE_TEST_EXIT="$FAKE_TEST_EXIT" \
      DISPATCH_TEST_FAKE_ROUTE_EXIT="$DISPATCH_TEST_FAKE_ROUTE_EXIT" \
      DISPATCH_TEST_FAKE_LAUNCHER="$DISPATCH_TEST_FAKE_LAUNCHER" \
      ISS_DISPATCH_BARE="$ISS_DISPATCH_BARE" ISS_DISPATCH_LEAN_RULES="$ISS_DISPATCH_LEAN_RULES" \
      STAGE_DISPATCH_CODEX_WORKER="$STAGE_DISPATCH_CODEX_WORKER" \
      STAGE_DISPATCH_OPUS_REVIEW="$STAGE_DISPATCH_OPUS_REVIEW" \
      STAGE_DISPATCH_STAGE_ROUTE="$STAGE_DISPATCH_STAGE_ROUTE" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR" </dev/null
  RUN_EXIT=$?
}

# Starts a case clean: empty logs, a fresh run dir and child worktree path
# (nothing is deleted; each case gets its own), the default routes and every
# knob back. The lean start is on by default, so a case that does not care
# about it names a rules file that does not exist: its start is then a normal
# one whether or not #39 has landed templates/lean-rules.md.
CASE_N=0
fresh_case() {
  CASE_N=$((CASE_N + 1))
  : > "$ORCA_LOG"
  : > "$LAUNCHER_LOG"
  : > "$FAKE_LOG"
  : > "$SPEC_LOG"
  RUN_DIR=$WORK/runs/case-$CASE_N
  mkdir -p "$RUN_DIR"
  TICKET_WT=$WORK/wt/case-$CASE_N/spec-26-t41
  set_route implementation=claude-glm/glm-5.4/high
  set_route research=codex-glm/glm-5.4/high
  set_route review=claude/opus/high
  set_route diagnosis=claude/opus/high
  ORCA_TEST_CREATE_ROOT=$WORK/wt/case-$CASE_N
  ORCA_TEST_FAIL=
  ORCA_TEST_CREATE_NO_HANDLE=0
  ORCA_TEST_START_NO_DISPATCH=0
  ORCA_TEST_DISPATCH_ID=ctx_impl
  ORCA_TEST_SHOW_JSON=
  ORCA_TEST_CHECK_JSON=
  FAKE_TEST_EXIT=0
  DISPATCH_TEST_FAKE_ROUTE_EXIT=0
  DISPATCH_TEST_FAKE_LAUNCHER=claude
  ISS_DISPATCH_BARE=
  ISS_DISPATCH_LEAN_RULES=$WORK/no-such-rules.md
  STAGE_DISPATCH_CODEX_WORKER=$BIN/fake-codex-worker
  STAGE_DISPATCH_OPUS_REVIEW=$BIN/fake-opus-review
  STAGE_DISPATCH_STAGE_ROUTE=$ROOT/scripts/stage-route.sh
}

fresh_case

# --- usage -----------------------------------------------------------------------

fresh_case
run_module
expect_exit 64 'no subcommand exits 64'
bash "$SCRIPT" --help > "$WORK/help.out" 2>&1
if [ $? -eq 0 ] && grep -q 'Usage: stage-dispatch.sh' "$WORK/help.out"; then
  record PASS '--help prints the usage and exits 0'
else
  record FAIL '--help prints the usage and exits 0'
fi
run_module frobnicate
expect_exit 64 'an unknown subcommand exits 64'
run_module dispatch --stage painting --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'an unknown stage exits 64'
run_module dispatch --stage implementation --role merger --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'an unknown role exits 64'
expect_file_without 'worktree' 'a usage error calls no Orca' "$ORCA_LOG"

fresh_case
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'an interactive dispatch without --run exits 64'
expect_file_has '--run' 'the missing Run is named' "$RUN_STDERR"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
expect_exit 64 'an implement dispatch without --ticket exits 64'
run_module dispatch --stage implementation \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'a dispatch without --brief exits 64'
run_module dispatch --stage implementation --brief "$WORK/no-such-brief.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'a dispatch whose Brief file does not exist exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --base-branch spec-26 --ticket 41
expect_exit 64 'an implement dispatch without --parent-worktree exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$WORK/no-such-worktree" --base-branch spec-26 --ticket 41
expect_exit 64 'an implement dispatch whose parent worktree does not exist exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch main --ticket 41
expect_exit 64 'an implement dispatch whose base branch is not spec-<n> exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket x
expect_exit 64 'a ticket that is not a number exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'a dispatch without --run-dir exits 64'
expect_file_without 'worktree' 'none of the missing arguments calls Orca' "$ORCA_LOG"
expect_file_without 'fake launcher' 'a usage error starts no launcher' "$LAUNCHER_LOG"

# --- the run directory must be outside the Spec worktree --------------------------
# Everything a dispatch writes goes to the run directory so that it outlives the
# worktree, which release removes (User Story 22): a run directory inside the
# Spec worktree is a usage error, judged on physical paths, so a directory not
# created yet and a relative path are caught too. A sibling whose name merely
# starts the same is fine, and a headless stage, which removes no worktree, is
# not checked.

fresh_case
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$SPEC_WT" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'a run directory that is the Spec worktree itself exits 64'
expect_file_has 'outside the Spec worktree' 'the refusal says where the run directory has to be' "$RUN_STDERR"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$SPEC_WT/runs/not-yet" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 42
expect_exit 64 'a run directory under the Spec worktree that does not exist yet exits 64'
if [ -e "$SPEC_WT/runs" ]; then
  record FAIL 'a refused run directory is not created' "$SPEC_WT/runs"
else
  record PASS 'a refused run directory is not created'
fi
(cd "$SPEC_WT" || exit 99
  run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
    --run run_spec26 --run-dir runs/relative --parent-worktree . --base-branch spec-26 --ticket 43
  exit "$RUN_EXIT")
RUN_EXIT=$?
expect_exit 64 'a relative run directory inside the Spec worktree exits 64'
expect_file_has 'inside'" $SPEC_WT" 'the refusal names the worktree the run directory is inside' "$RUN_STDERR"
expect_file_without 'worktree' 'a refused run directory calls no Orca' "$ORCA_LOG"
SIBLING=$WORK/wt/spec-26-sibling
mkdir -p "$SIBLING/runs"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$SIBLING/runs" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 44
expect_exit 0 'a run directory in a sibling whose name merely starts the same is accepted'
expect_stdout "$SIBLING/runs/dispatch-implement-44.json" 'that dispatch completes as usual'
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$SPEC_WT/research-run" --ticket 45 --cwd "$SPEC_WT"
expect_exit 0 'a headless dispatch, which removes no worktree, may keep its run directory anywhere'

# --- the route cannot be read, or its launcher is missing -------------------------

fresh_case
STAGE_DISPATCH_STAGE_ROUTE=$WORK/fake-stage-route.sh
DISPATCH_TEST_FAKE_ROUTE_EXIT=66
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'an unreadable implementation route exits 64'
expect_file_has 'implementation route' 'the unreadable route names its stage' "$RUN_STDERR"
expect_file_without 'worktree' 'an unreadable route calls no Orca' "$ORCA_LOG"

fresh_case
STAGE_DISPATCH_STAGE_ROUTE=$WORK/fake-stage-route.sh
DISPATCH_TEST_FAKE_LAUNCHER=iss-missing-launcher
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 6 'a route whose launcher is not installed exits 6'
expect_file_has 'iss-missing-launcher' 'the missing launcher is named' "$RUN_STDERR"
expect_file_has 'claude / opus / high' 'the missing launcher is reported against its route' "$RUN_STDERR"
expect_file_without 'worktree' 'a missing launcher calls Orca not at all' "$ORCA_LOG"

# --- the default implementation route: child worktree, terminal, adoption --------

fresh_case
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 0 'an implement dispatch on the default route exits 0'
SIDECAR=$RUN_DIR/dispatch-implement-41.json
expect_stdout "$SIDECAR" 'dispatch prints the sidecar path'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'create create worker-start ' ]; then
  record PASS 'Orca is called once each, in order: worktree create, terminal create, worker-start'
else
  record FAIL 'Orca is called once each, in order: worktree create, terminal create, worker-start' "sequence=[$SEQUENCE]"
fi
expect_file_has 'ARG --parent-worktree' 'the child worktree hangs under the Spec worktree' "$ORCA_LOG"
expect_file_has "ARG path:$SPEC_WT" 'the parent is the Spec worktree, by path' "$ORCA_LOG"
expect_file_has 'ARG --name' 'the child worktree gets the Ticket name' "$ORCA_LOG"
expect_file_has 'ARG spec-26-t41' 'the worktree, the branch and the title all name spec-<n>-t<m>' "$ORCA_LOG"
expect_file_has 'ARG --branch' 'the child gets its own branch' "$ORCA_LOG"
expect_file_has 'ARG --base-branch' 'the child is based on the Integration branch' "$ORCA_LOG"
expect_file_has 'ARG spec-26' 'the base branch is spec-<n>' "$ORCA_LOG"
expect_file_has 'ARG --issue' 'the child worktree is filed under the ticket' "$ORCA_LOG"
expect_file_has 'ARG 41' 'the issue is the ticket number' "$ORCA_LOG"
if [ "$(value_after --repo 1 "$ORCA_LOG")" = "path:$REPO" ]; then
  record PASS 'the repository is the main checkout the Spec worktree belongs to'
else
  record FAIL 'the repository is the main checkout the Spec worktree belongs to' "repo=[$(value_after --repo 1 "$ORCA_LOG")]"
fi
expect_file_without 'ARG --agent' 'no agent is started by worktree create' "$ORCA_LOG"
expect_file_without 'ARG --prompt' 'no prompt is passed to worktree create' "$ORCA_LOG"
expect_file_without 'ARG --no-parent' 'the child is not created parentless' "$ORCA_LOG"
if [ "$(value_after --worktree 1 "$ORCA_LOG")" = "path:$TICKET_WT" ]; then
  record PASS 'the terminal opens in the child worktree Orca created'
else
  record FAIL 'the terminal opens in the child worktree Orca created' "worktree=[$(value_after --worktree 1 "$ORCA_LOG")]"
fi
expect_file_has 'ARG spec-26 t41' 'the terminal title is spec-<n> t<m>' "$ORCA_LOG"
expect_file_without 'ARG --focus' 'the worker terminal opens in the background' "$ORCA_LOG"
expect_file_has 'ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high; echo $? > ' \
  'the typed command runs the default route: claude-glm, its model in the [1m] form, and the effort' "$ORCA_LOG"
expect_file_has '/implement-41/exit-code' 'the typed command records the launcher exit code' "$ORCA_LOG"
expect_file_without 'ARG --bare' 'with no rules file the default start is a normal one' "$ORCA_LOG"
expect_file_has 'ARG --run' 'worker-start names its Run' "$ORCA_LOG"
expect_file_has 'ARG run_spec26' 'worker-start targets the given Run' "$ORCA_LOG"
expect_file_has 'ARG --terminal' 'worker-start adopts the terminal' "$ORCA_LOG"
expect_file_has 'ARG term_impl' 'worker-start adopts the handle terminal create returned' "$ORCA_LOG"
expect_file_has 'ARG --spec-file' 'worker-start reads the Task from a file' "$ORCA_LOG"
expect_file_has 'ARG --json' 'worker-start emits JSON' "$ORCA_LOG"
expect_file_has 'ARG --timeout-ms' 'worker-start bounds the wait for the worker to take the Task' "$ORCA_LOG"
expect_file_has 'Implement the Stage dispatch module.' 'the Task carries the Brief' "$SPEC_LOG"
expect_file_has 'worker_done' 'the Task tells the worker to report worker_done' "$SPEC_LOG"
expect_file_has '--task-id' 'the Task tells the worker to carry the Task id' "$SPEC_LOG"
expect_file_has "$RUN_DIR/implement-41/report.md" 'the Task names a report path outside the worktree' "$SPEC_LOG"
expect_file_has "$TICKET_WT" 'the Task names the worktree it works in' "$SPEC_LOG"
if [ -s "$LAUNCHER_LOG" ]; then
  record FAIL 'the module never starts the launcher itself' "log=$(cat "$LAUNCHER_LOG")"
else
  record PASS 'the module never starts the launcher itself'
fi
if [ -s "$GUARD_LOG" ]; then
  record FAIL 'the module reaches Orca only through the library' "log=$(cat "$GUARD_LOG")"
else
  record PASS 'the module reaches Orca only through the library'
fi
# The sidecar: what a report needs, outside the worktree.
expect_json implementation 'sidecar names the stage' "$SIDECAR" stage
expect_json implement 'sidecar names the role' "$SIDECAR" role
expect_json 41 'sidecar names the ticket' "$SIDECAR" ticket
expect_json run_spec26 'sidecar names the Run' "$SIDECAR" run_id
expect_json interactive 'sidecar names the form' "$SIDECAR" form
expect_json claude-glm 'sidecar names the route profile' "$SIDECAR" route.profile
expect_json glm-5.4 'sidecar names the route model' "$SIDECAR" route.model
expect_json high 'sidecar names the route effort' "$SIDECAR" route.effort
expect_json claude-glm 'sidecar names the launcher' "$SIDECAR" launcher
expect_json "$SPEC_WT" 'sidecar names the parent worktree' "$SIDECAR" parent_worktree
expect_json spec-26 'sidecar names the base branch' "$SIDECAR" base_branch
expect_json spec-26-t41 'sidecar names the branch' "$SIDECAR" branch
expect_json "$TICKET_WT" 'sidecar names the worktree path' "$SIDECAR" worktree
expect_json term_impl 'sidecar names the terminal handle' "$SIDECAR" terminal
expect_json ctx_impl 'sidecar names the dispatch id' "$SIDECAR" dispatch_id
expect_json task_impl 'sidecar names the task id' "$SIDECAR" task_id
expect_json "$RUN_DIR/implement-41/report.md" 'sidecar names the report path it told the worker' "$SIDECAR" report_path
expect_json false 'sidecar says the start was not a lean one' "$SIDECAR" bare
expect_file_has 'was not found' 'the sidecar bare_note says why: the rules file is missing' "$SIDECAR"
expect_json 1 'sidecar names the attempt' "$SIDECAR" attempt
expect_file_has '本次派发路由：实现（implementation）：claude-glm / glm-5.4 / high' 'the route is reported on stderr' "$RUN_STDERR"

# --- a route change reaches the next dispatch only ---------------------------------
# The verified catalog lists one claude profile for the implementation stage,
# so the real table can change its effort alone; the launcher change is covered
# below through the fake table, as test-design-session.sh does for faults the
# real table cannot produce.

fresh_case
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
BEFORE=$RUN_DIR/dispatch-implement-41.json
cp "$BEFORE" "$WORK/before-sidecar.json"
set_route implementation=claude-glm/glm-5.4/medium
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 42
expect_exit 0 'a dispatch after a route change exits 0'
AFTER=$RUN_DIR/dispatch-implement-42.json
expect_json medium 'the next dispatch uses the new route effort' "$AFTER" route.effort
expect_file_has 'ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort medium; echo $? > ' \
  'the next dispatch runs the launcher with the new effort' "$ORCA_LOG"
expect_file_without '--effort high' 'the next dispatch no longer runs the old effort' "$ORCA_LOG"
expect_file_has '本次派发路由：实现（implementation）：claude-glm / glm-5.4 / medium' \
  'the new route is reported on stderr' "$RUN_STDERR"
if cmp -s "$WORK/before-sidecar.json" "$BEFORE"; then
  record PASS 'the sidecar of the earlier dispatch is unchanged'
else
  record FAIL 'the sidecar of the earlier dispatch is unchanged' "$(cat "$BEFORE")"
fi
expect_json high 'the earlier sidecar keeps its route effort' "$BEFORE" route.effort

# The official claude profile (through the fake table): the same command shape,
# with its model unadorned.
set_route implementation=claude-glm/glm-5.4/high
STAGE_DISPATCH_STAGE_ROUTE=$WORK/fake-stage-route.sh
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 43
expect_exit 0 'an implementation dispatch on the official claude profile exits 0'
expect_file_has 'ARG claude --dangerously-skip-permissions --model opus --effort high; echo $? > ' \
  'the official claude route runs claude with --model opus; an unattended worker skips permission prompts' "$ORCA_LOG"
expect_file_without '\[1m\]' 'the official claude profile passes its model without the [1m] suffix' "$ORCA_LOG"
STAGE_DISPATCH_STAGE_ROUTE=$ROOT/scripts/stage-route.sh

# A codex-glm implementation route cannot open an interactive worker.
set_route implementation=codex-glm/glm-5.4/high
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 44
expect_exit 64 'a codex-glm implementation route exits 64'
expect_file_has 'codex-glm / glm-5.4 / high' 'the unusable route is named' "$RUN_STDERR"
expect_file_has 'cannot run an interactive worker' 'the reason is given' "$RUN_STDERR"
expect_file_without 'worktree' 'an unusable route calls Orca not at all' "$ORCA_LOG"
set_route implementation=claude-glm/glm-5.4/high

# The same dispatch name twice: the second is refused; --attempt gives it a
# fresh name, and the first sidecar stays.
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 64 'a second dispatch of the same name exits 64'
expect_file_has 'already has a sidecar' 'the refusal names the existing sidecar' "$RUN_STDERR"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41 --attempt 2
expect_exit 0 'the same ticket with --attempt 2 exits 0'
expect_stdout "$RUN_DIR/dispatch-implement-41-2.json" 'the second attempt gets its own sidecar name'
expect_json 2 'the second attempt records its attempt number' "$RUN_DIR/dispatch-implement-41-2.json" attempt
if cmp -s "$WORK/before-sidecar.json" "$BEFORE"; then
  record PASS 'a re-brief leaves the first attempt sidecar as it was'
else
  record FAIL 'a re-brief leaves the first attempt sidecar as it was'
fi
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41 --attempt 0
expect_exit 64 '--attempt 0 exits 64'

# --- the lean start: on by default, ISS_DISPATCH_BARE is the opt-out -----------------

# The default rules file is templates/lean-rules.md (#39's to settle): whether
# or not it is there, that is the path the sidecar talks about.
fresh_case
ISS_DISPATCH_LEAN_RULES=
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 40
expect_exit 0 'a dispatch with the rules file left to its default exits 0'
expect_file_has 'templates/lean-rules.md' 'the default rules file is templates/lean-rules.md' \
  "$RUN_DIR/dispatch-implement-40.json"

# On (the default: the switch unset), with a rules file: the implementation
# stage starts bare.
fresh_case
printf '%s\n' '# lean rules' 'Commit your work; no hooks here.' > "$WORK/lean-rules.md"
printf '%s\n' '{"mcpServers":{"ssh-manager":{"command":"sshmgr"}}}' > "$WORK/mcp.json"
ISS_DISPATCH_LEAN_RULES=$WORK/lean-rules.md
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41 \
  --mcp-config "$WORK/mcp.json"
expect_exit 0 'a dispatch with the lean start on by default exits 0'
expect_file_has "ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high --bare --append-system-prompt-file $WORK/lean-rules.md --mcp-config $WORK/mcp.json; echo \$? > " \
  'the lean start adds --bare, the rules file and the MCP config after the route arguments' \
  "$ORCA_LOG"
expect_json true 'the sidecar says the start was a lean one' "$RUN_DIR/dispatch-implement-41.json" bare
expect_file_has "$WORK/lean-rules.md" 'the sidecar bare_note names the rules file' "$RUN_DIR/dispatch-implement-41.json"

# On without a rules file: a normal start, and the sidecar says why.
: > "$ORCA_LOG"
ISS_DISPATCH_LEAN_RULES=$WORK/no-such-rules.md
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 42
expect_exit 0 'a dispatch with the lean start on but no rules file exits 0'
expect_file_has 'ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high; echo $? > ' \
  'no rules file means a normal start' "$ORCA_LOG"
expect_file_without 'ARG --bare' 'no rules file means no --bare' "$ORCA_LOG"
expect_json false 'the sidecar says the start was not a lean one' "$RUN_DIR/dispatch-implement-42.json" bare
expect_file_has 'was not found' 'the sidecar bare_note says the rules file is missing' "$RUN_DIR/dispatch-implement-42.json"
expect_file_has "$WORK/no-such-rules.md" 'the sidecar bare_note names the rules file it looked for' \
  "$RUN_DIR/dispatch-implement-42.json"

# Explicitly off, with a rules file that is there: a normal start, and the
# sidecar says the switch did it. 0, off, no and false all turn it off.
ISS_DISPATCH_BARE=0
ISS_DISPATCH_LEAN_RULES=$WORK/lean-rules.md
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 43
expect_exit 0 'a dispatch with ISS_DISPATCH_BARE=0 exits 0'
expect_file_without 'ARG --bare' 'ISS_DISPATCH_BARE=0 means no --bare, rules file or not' "$ORCA_LOG"
expect_json false 'the sidecar says ISS_DISPATCH_BARE=0 made the start a normal one' "$RUN_DIR/dispatch-implement-43.json" bare
expect_file_has 'ISS_DISPATCH_BARE=0 turns the lean start off' 'the sidecar bare_note names the switch and its value' \
  "$RUN_DIR/dispatch-implement-43.json"
off_ticket=46
for off in off no false OFF; do
  ISS_DISPATCH_BARE=$off
  : > "$ORCA_LOG"
  run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
    --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket "$off_ticket"
  OFF_SIDECAR=$RUN_DIR/dispatch-implement-$off_ticket.json
  if [ "$RUN_EXIT" -eq 0 ] && [ "$(json_field "$OFF_SIDECAR" bare)" = false ] &&
     ! grep -Fq 'ARG --bare' "$ORCA_LOG" && ! grep -Fq 'ARG --append-system-prompt-file' "$ORCA_LOG"; then
    record PASS "ISS_DISPATCH_BARE=$off turns the lean start off too"
  else
    record FAIL "ISS_DISPATCH_BARE=$off turns the lean start off too" "exit=$RUN_EXIT, log=$(grep -F 'ARG --bare' "$ORCA_LOG")"
  fi
  off_ticket=$((off_ticket + 1))
done

# Any other value is on, 1 included: the switch only ever turns the lean start off.
ISS_DISPATCH_BARE=1
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 45
expect_exit 0 'a dispatch with ISS_DISPATCH_BARE=1 exits 0'
expect_file_has "ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high --bare --append-system-prompt-file $WORK/lean-rules.md; echo \$? > " \
  'ISS_DISPATCH_BARE=1 is on, like the default' "$ORCA_LOG"
expect_json true 'ISS_DISPATCH_BARE=1 records a lean start' "$RUN_DIR/dispatch-implement-45.json" bare

# A fix role gets the lean arguments too, on the same route.
: > "$ORCA_LOG"
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
expect_exit 0 'a fix dispatch with the lean start on exits 0'
expect_file_has "ARG claude-glm --dangerously-skip-permissions --model glm-5.4\[1m\] --effort high --bare --append-system-prompt-file $WORK/lean-rules.md; echo \$? > " \
  'a fix role gets the lean arguments as well' "$ORCA_LOG"

# --- fix and merge roles: in the Spec worktree, no child -----------------------------

fresh_case
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
expect_exit 0 'a fix dispatch exits 0'
expect_stdout "$RUN_DIR/dispatch-fix.json" 'a fix dispatch without a ticket is named fix'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'create worker-start ' ]; then
  record PASS 'a fix dispatch creates no worktree: only the terminal and the adoption'
else
  record FAIL 'a fix dispatch creates no worktree: only the terminal and the adoption' "sequence=[$SEQUENCE]"
fi
if [ "$(value_after --worktree 1 "$ORCA_LOG")" = "path:$SPEC_WT" ]; then
  record PASS 'the fix terminal opens in the Spec worktree'
else
  record FAIL 'the fix terminal opens in the Spec worktree' "worktree=[$(value_after --worktree 1 "$ORCA_LOG")]"
fi
expect_file_has 'ARG spec-26 fix' 'the fix terminal title is spec-<n> fix' "$ORCA_LOG"
expect_json fix 'the fix sidecar names the role' "$RUN_DIR/dispatch-fix.json" role
expect_json "$SPEC_WT" 'the fix sidecar names the Spec worktree' "$RUN_DIR/dispatch-fix.json" worktree
expect_json false 'the fix sidecar says no worktree was created' "$RUN_DIR/dispatch-fix.json" worktree_created
expect_json spec-26 'the fix sidecar names the Integration branch' "$RUN_DIR/dispatch-fix.json" branch
expect_json implementation 'the fix sidecar names the implementation stage' "$RUN_DIR/dispatch-fix.json" stage
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 0 'a fix dispatch with a ticket exits 0'
expect_stdout "$RUN_DIR/dispatch-fix-41.json" 'a fix dispatch with a ticket is named fix-<m>'
run_module dispatch --stage implementation --role merge --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 0 'a merge dispatch exits 0'
expect_file_has 'ARG spec-26 merge t41' 'the merge terminal title is spec-<n> merge t<m>' "$ORCA_LOG"
expect_json "$SPEC_WT" 'the merge sidecar names the Spec worktree' "$RUN_DIR/dispatch-merge-41.json" worktree
run_module dispatch --stage implementation --role merge --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
expect_exit 64 'a merge dispatch without --ticket exits 64'

# --- Orca failures: each step stops there --------------------------------------------

fresh_case
ORCA_TEST_FAIL='worktree create'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41
expect_exit 6 'a failing worktree create exits 6'
expect_file_has 'orca worktree create failed' 'the worktree create failure is surfaced' "$RUN_STDERR"
expect_file_has 'fake orca: worktree create failed' "Orca's own error is passed through" "$RUN_STDERR"
if grep -qx 'create' "$ORCA_LOG" && ! grep -qx 'terminal' "$ORCA_LOG"; then
  record PASS 'a failed worktree create opens no terminal'
else
  record FAIL 'a failed worktree create opens no terminal' "log=$(cat "$ORCA_LOG")"
fi
if json_field "$RUN_DIR/dispatch-implement-41.json" dispatch_id >/dev/null; then
  record FAIL 'an incomplete sidecar carries no dispatch id'
else
  record PASS 'an incomplete sidecar carries no dispatch id'
fi

ORCA_TEST_FAIL='terminal create'
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 42
expect_exit 6 'a failing terminal create exits 6'
expect_file_has 'orca terminal create failed' 'the terminal create failure is surfaced' "$RUN_STDERR"
if grep -qx 'worker-start' "$ORCA_LOG"; then
  record FAIL 'a failed terminal create adopts nothing'
else
  record PASS 'a failed terminal create adopts nothing'
fi

ORCA_TEST_FAIL=
ORCA_TEST_CREATE_NO_HANDLE=1
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 43
expect_exit 6 'a terminal create without a handle exits 6'
expect_file_has 'no terminal handle' 'the missing handle is reported' "$RUN_STDERR"
if grep -qx 'worker-start' "$ORCA_LOG"; then
  record FAIL 'a terminal without a handle is not adopted'
else
  record PASS 'a terminal without a handle is not adopted'
fi

ORCA_TEST_CREATE_NO_HANDLE=0
ORCA_TEST_FAIL='orchestration worker-start'
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 44
expect_exit 6 'a failing worker-start exits 6'
expect_file_has 'orca orchestration worker-start failed' 'the worker-start failure is surfaced' "$RUN_STDERR"
expect_file_has 'term_impl' 'a failed worker-start names the terminal it left open' "$RUN_STDERR"
expect_json term_impl 'the incomplete sidecar still names the terminal, for a clean-up' "$RUN_DIR/dispatch-implement-44.json" terminal

ORCA_TEST_FAIL=
ORCA_TEST_START_NO_DISPATCH=1
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 45
expect_exit 6 'a worker-start receipt without a dispatch id exits 6'
expect_file_has 'no dispatch id' 'the missing dispatch id is reported' "$RUN_STDERR"

# --- --repo names the repository Orca files the worktree under -----------------------

fresh_case
mkdir -p "$WORK/another-checkout"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41 \
  --repo "$WORK/another-checkout"
expect_exit 0 'a dispatch with --repo exits 0'
if [ "$(value_after --repo 1 "$ORCA_LOG")" = "path:$WORK/another-checkout" ]; then
  record PASS '--repo is passed to Orca as the repository'
else
  record FAIL '--repo is passed to Orca as the repository' "repo=[$(value_after --repo 1 "$ORCA_LOG")]"
fi
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 46 \
  --repo "$WORK/no-such-checkout"
expect_exit 64 'a --repo that is not a directory exits 64'

# The base branch must exist, and a fix or merge role must find the Spec
# worktree on it: that is where its work belongs.
: > "$ORCA_LOG"
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-99 --ticket 47
expect_exit 64 'an implement dispatch whose base branch does not exist exits 64'
expect_file_has 'spec-99' 'the missing base branch is named' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'a missing base branch calls Orca not at all' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a missing base branch calls Orca not at all'
fi
OTHER_WT=$WORK/wt/other-branch
git -C "$REPO" worktree add --quiet -b other-branch "$OTHER_WT" main
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$OTHER_WT" --base-branch spec-26
expect_exit 64 'a fix dispatch into a worktree not on the Integration branch exits 64'
expect_file_has 'other-branch' 'the branch the worktree is on is named' "$RUN_STDERR"
expect_file_has 'spec-26' 'the expected Integration branch is named' "$RUN_STDERR"

# --- wait: one blocking check, no polling -------------------------------------------

# dispatch_ticket <m> [extra dispatch arguments]: the usual implement dispatch.
dispatch_ticket() {
  local m=$1
  shift
  run_module dispatch --stage implementation --brief "$WORK/brief-41.md" \
    --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket "$m" "$@"
}
# write_check <file> <dispatch id> <report path>: a check batch holding that
# one worker_done.
write_check() {
  printf '%s\n' '{"ok":true,"result":{"messages":[{"id":"msg_'"$(basename "$1" .json)"'","type":"worker_done","payload":{"taskId":"task_impl","dispatchId":"'"$2"'","outcome":"succeeded","reportPath":"'"$3"'"}}]}}' > "$1"
}

fresh_case
dispatch_ticket 41
SIDECAR=$RUN_DIR/dispatch-implement-41.json
DISPATCH_DIR=$RUN_DIR/implement-41
printf '%s\n' 'worker report' > "$DISPATCH_DIR/report.md"
run_module wait
expect_exit 64 'wait without --sidecar exits 64'
run_module wait --sidecar "$WORK/no-such-sidecar.json"
expect_exit 64 'wait with a missing sidecar exits 64'
printf '%s\n' 'not json' > "$WORK/not-json.json"
run_module wait --sidecar "$WORK/not-json.json"
expect_exit 64 'wait with a sidecar that is not JSON exits 64'
run_module wait --sidecar "$SIDECAR" --timeout 0
expect_exit 64 'wait with --timeout 0 exits 64'
run_module wait --sidecar "$SIDECAR" --timeout soon
expect_exit 64 'wait with a word for --timeout exits 64'
expect_file_without 'check' 'none of the bad waits asks Orca' "$ORCA_LOG"

# Received: one consuming check that waits, bounded by the timeout.
write_check "$WORK/check-done.json" ctx_impl "$DISPATCH_DIR/report.md"
ORCA_TEST_CHECK_JSON=$WORK/check-done.json
: > "$ORCA_LOG"
run_module wait --sidecar "$SIDECAR" --timeout 1
expect_exit 0 'wait exits 0 when the worker_done arrives'
expect_stdout "$DISPATCH_DIR/report.md" 'wait prints the report path the worker_done named'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'check ' ]; then
  record PASS 'wait makes exactly one Orca call: check'
else
  record FAIL 'wait makes exactly one Orca call: check' "sequence=[$SEQUENCE]"
fi
CHECK_CALLS=$(grep -c '^check$' "$ORCA_LOG")
if [ "$CHECK_CALLS" = 1 ]; then
  record PASS 'check is called once, not in a loop'
else
  record FAIL 'check is called once, not in a loop' "calls=$CHECK_CALLS"
fi
expect_file_has 'ARG --run' 'the check names the Run' "$ORCA_LOG"
expect_file_has 'ARG run_spec26' 'the check targets the dispatch Run' "$ORCA_LOG"
expect_file_has 'ARG --types' 'the check wakes on the message type it waits for' "$ORCA_LOG"
expect_file_has 'ARG worker_done' 'the check waits for worker_done alone' "$ORCA_LOG"
expect_file_has 'ARG --wait' 'the check is a blocking wait' "$ORCA_LOG"
expect_file_has 'ARG --timeout-ms' 'the wait has a timeout' "$ORCA_LOG"
expect_file_has 'ARG 1000' 'the timeout is converted to milliseconds' "$ORCA_LOG"
expect_file_without 'ARG --peek' 'the coordinator takes rather than peeks' "$ORCA_LOG"
expect_json succeeded 'the sidecar records the outcome' "$SIDECAR" worker_done.outcome
expect_json "$DISPATCH_DIR/report.md" 'the sidecar records the report path' "$SIDECAR" worker_done.report_path
expect_json msg_check-done 'the sidecar records the message id' "$SIDECAR" worker_done.message_id
if [ -s "$DISPATCH_DIR/wait.json" ]; then
  record PASS 'the taken batch is kept in the dispatch dir'
else
  record FAIL 'the taken batch is kept in the dispatch dir'
fi

# A dispatch whose worker_done is already recorded returns at once.
: > "$ORCA_LOG"
run_module wait --sidecar "$SIDECAR" --timeout 1
expect_exit 0 'wait on an already recorded worker_done exits 0'
expect_stdout "$DISPATCH_DIR/report.md" 'wait on an already recorded worker_done still prints the report path'
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'wait on an already recorded worker_done asks Orca nothing' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'wait on an already recorded worker_done asks Orca nothing'
fi

# Timed out: exit 5, one check, and the sidecar has no worker_done.
printf '%s\n' '{"ok":true,"result":{"timedOut":true,"messages":[]}}' > "$WORK/check-timeout.json"
ORCA_TEST_CHECK_JSON=$WORK/check-timeout.json
ORCA_TEST_DISPATCH_ID=ctx_42
dispatch_ticket 42
SIDECAR_42=$RUN_DIR/dispatch-implement-42.json
: > "$ORCA_LOG"
run_module wait --sidecar "$SIDECAR_42" --timeout 1
expect_exit 5 'a wait that times out exits 5'
expect_file_has '超时' 'the timeout is reported' "$RUN_STDERR"
expect_file_has 'ctx_42' 'the timeout names the dispatch' "$RUN_STDERR"
CHECK_CALLS=$(grep -c '^check$' "$ORCA_LOG")
if [ "$CHECK_CALLS" = 1 ]; then
  record PASS 'a timed-out wait made one check and did not retry'
else
  record FAIL 'a timed-out wait made one check and did not retry' "calls=$CHECK_CALLS"
fi
if json_field "$SIDECAR_42" worker_done >/dev/null; then
  record FAIL 'a timed-out wait records no worker_done'
else
  record PASS 'a timed-out wait records no worker_done'
fi

# Woken by another dispatch's worker_done: that one is recorded, this wait
# returns 7, and the other wait then returns at once.
ORCA_TEST_DISPATCH_ID=ctx_43
dispatch_ticket 43
SIDECAR_43=$RUN_DIR/dispatch-implement-43.json
ORCA_TEST_DISPATCH_ID=ctx_44
dispatch_ticket 44
SIDECAR_44=$RUN_DIR/dispatch-implement-44.json
printf '%s\n' 'worker 44 report' > "$RUN_DIR/implement-44/report.md"
write_check "$WORK/check-44.json" ctx_44 "$RUN_DIR/implement-44/report.md"
ORCA_TEST_CHECK_JSON=$WORK/check-44.json
: > "$ORCA_LOG"
run_module wait --sidecar "$SIDECAR_43" --timeout 1
expect_exit 7 'a wait woken by another dispatch worker_done exits 7'
expect_file_has 'ctx_44' 'the other dispatch is named' "$RUN_STDERR"
expect_json "$RUN_DIR/implement-44/report.md" "the other dispatch's sidecar records its worker_done" "$SIDECAR_44" worker_done.report_path
if json_field "$SIDECAR_43" worker_done >/dev/null; then
  record FAIL "the waiting dispatch's sidecar records nothing"
else
  record PASS "the waiting dispatch's sidecar records nothing"
fi
: > "$ORCA_LOG"
run_module wait --sidecar "$SIDECAR_44" --timeout 1
expect_exit 0 'a wait on the dispatch whose worker_done was recorded already exits 0'
expect_stdout "$RUN_DIR/implement-44/report.md" 'it prints that report path'
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'it asks Orca nothing' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'it asks Orca nothing'
fi

# A worker_done whose report is not on disk is an error, not a path to nowhere.
ORCA_TEST_DISPATCH_ID=ctx_45
dispatch_ticket 45
SIDECAR_45=$RUN_DIR/dispatch-implement-45.json
write_check "$WORK/check-45.json" ctx_45 "$RUN_DIR/implement-45/report.md"
ORCA_TEST_CHECK_JSON=$WORK/check-45.json
run_module wait --sidecar "$SIDECAR_45" --timeout 1
expect_exit 6 'a worker_done that names a report not on disk exits 6'
expect_file_has 'not on disk' 'the missing report is reported' "$RUN_STDERR"

# A worker that reports its path relative to its worktree (as the smoke test's
# worker did) is understood: wait resolves it against the worktree. What that
# means for release, which removes the worktree, is under release below.
ORCA_TEST_DISPATCH_ID=ctx_48a
dispatch_ticket 48
SIDECAR_48=$RUN_DIR/dispatch-implement-48.json
printf '%s\n' 'relative report' > "$WORK/wt/case-$CASE_N/spec-26-t48/report.md"
write_check "$WORK/check-48.json" ctx_48a report.md
ORCA_TEST_CHECK_JSON=$WORK/check-48.json
run_module wait --sidecar "$SIDECAR_48" --timeout 1
expect_exit 0 'a worker_done with a relative report path exits 0'
expect_stdout "$WORK/wt/case-$CASE_N/spec-26-t48/report.md" 'the relative path is resolved against the worktree'
expect_json "$WORK/wt/case-$CASE_N/spec-26-t48/report.md" 'the sidecar records the resolved path' "$SIDECAR_48" worker_done.report_path

# Orca failing, and sidecars wait cannot use.
ORCA_TEST_FAIL='orchestration check'
ORCA_TEST_DISPATCH_ID=ctx_46
dispatch_ticket 46
run_module wait --sidecar "$RUN_DIR/dispatch-implement-46.json" --timeout 1
expect_exit 6 'a failing check exits 6'
expect_file_has 'orca orchestration check failed' 'the check failure is surfaced' "$RUN_STDERR"
ORCA_TEST_FAIL=
ORCA_TEST_START_NO_DISPATCH=1
dispatch_ticket 47
ORCA_TEST_START_NO_DISPATCH=0
run_module wait --sidecar "$RUN_DIR/dispatch-implement-47.json" --timeout 1
expect_exit 64 'wait on a dispatch that did not complete exits 64'
expect_file_has 'no dispatch_id' 'the incomplete sidecar is named' "$RUN_STDERR"

# --- release -------------------------------------------------------------------------
# finished_ticket <m> [extra dispatch arguments]: an implement dispatch whose
# worker_done was received and whose report is on disk, ready to release.
finished_ticket() {
  local m=$1 report=$RUN_DIR/implement-$1/report.md
  shift
  ORCA_TEST_DISPATCH_ID=ctx_$m
  dispatch_ticket "$m" "$@"
  printf '%s\n' "worker $m report" > "$report"
  write_check "$WORK/check-$m.json" "ctx_$m" "$report"
  ORCA_TEST_CHECK_JSON=$WORK/check-$m.json
  run_module wait --sidecar "$RUN_DIR/dispatch-implement-$m.json" --timeout 1
}
# write_show <file> <state> <stage>: a worker-show receipt.
write_show() {
  printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_x","state":"'"$2"'","stage":"'"$3"'","liveness":"exited"}}' > "$1"
}

fresh_case
dispatch_ticket 41
SIDECAR=$RUN_DIR/dispatch-implement-41.json
run_module release
expect_exit 64 'release without --sidecar exits 64'
run_module release --sidecar "$WORK/no-such-sidecar.json"
expect_exit 64 'release with a missing sidecar exits 64'
run_module release --sidecar "$WORK/not-json.json"
expect_exit 64 'release with a sidecar that is not JSON exits 64'
: > "$ORCA_LOG"
run_module release --sidecar "$SIDECAR"
expect_exit 2 'release without a recorded worker_done exits 2'
expect_file_has 'release refused' 'the refusal says so' "$RUN_STDERR"
expect_file_has 'no worker_done' 'the refusal names the missing worker_done' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'a refusal calls Orca not at all' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a refusal calls Orca not at all'
fi

# Done, report on disk, worker settled: release, close, remove.
write_show "$WORK/show-settled.json" succeeded settled
ORCA_TEST_SHOW_JSON=$WORK/show-settled.json
ORCA_TEST_DISPATCH_ID=ctx_50
finished_ticket 50
SIDECAR_50=$RUN_DIR/dispatch-implement-50.json
: > "$ORCA_LOG"
run_module release --sidecar "$SIDECAR_50"
expect_exit 0 'release exits 0 once the worker is done'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show worker-release close rm ' ]; then
  record PASS 'Orca is called once each, in order: worker-show, worker-release, terminal close, worktree rm'
else
  record FAIL 'Orca is called once each, in order: worker-show, worker-release, terminal close, worktree rm' "sequence=[$SEQUENCE]"
fi
expect_file_has 'ARG --dispatch' 'worker-show and worker-release name the dispatch' "$ORCA_LOG"
expect_count 'ARG ctx_50' 2 'both address the sidecar dispatch id' "$ORCA_LOG"
expect_file_has 'ARG --terminal' 'the terminal this module opened is closed explicitly' "$ORCA_LOG"
expect_file_has 'ARG term_impl' 'it is the adopted handle' "$ORCA_LOG"
expect_file_has 'ARG --tab' 'the whole tab goes' "$ORCA_LOG"
if [ "$(value_after --worktree 1 "$ORCA_LOG")" = "path:$WORK/wt/case-$CASE_N/spec-26-t50" ]; then
  record PASS 'the child worktree is removed'
else
  record FAIL 'the child worktree is removed' "worktree=[$(value_after --worktree 1 "$ORCA_LOG")]"
fi
expect_file_has 'ARG --delete-branch' 'the child worktree branch is deleted with it' "$ORCA_LOG"
expect_stdout "released ctx_50 ($WORK/wt/case-$CASE_N/spec-26-t50 removed)" 'release names the dispatch and the worktree it removed'
if [ -n "$(json_field "$SIDECAR_50" released_at)" ]; then
  record PASS 'the sidecar records the release time'
else
  record FAIL 'the sidecar records the release time'
fi

# A report the worker wrote inside the child worktree (it reported a relative
# path, which wait resolved against the worktree; the smoke test's worker did
# just that) would go with the worktree release removes: the report is copied
# into the dispatch dir first and the sidecar points at the copy, before
# anything is released. The Orca order is as ever: the copy is no Orca call.
ORCA_TEST_DISPATCH_ID=ctx_51
dispatch_ticket 51
SIDECAR_51=$RUN_DIR/dispatch-implement-51.json
TICKET_WT_51=$WORK/wt/case-$CASE_N/spec-26-t51
printf '%s\n' 'report written inside the worktree' > "$TICKET_WT_51/report.md"
write_check "$WORK/check-51.json" ctx_51 report.md
ORCA_TEST_CHECK_JSON=$WORK/check-51.json
run_module wait --sidecar "$SIDECAR_51" --timeout 1
expect_json "$TICKET_WT_51/report.md" 'wait recorded the report where the worker put it: inside the worktree' \
  "$SIDECAR_51" worker_done.report_path
: > "$ORCA_LOG"
run_module release --sidecar "$SIDECAR_51"
expect_exit 0 'release of a report inside the child worktree exits 0'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show worker-release close rm ' ]; then
  record PASS 'the copy is no Orca call: still worker-show, worker-release, terminal close, worktree rm'
else
  record FAIL 'the copy is no Orca call: still worker-show, worker-release, terminal close, worktree rm' "sequence=[$SEQUENCE]"
fi
expect_json "$RUN_DIR/implement-51/report-from-worktree.md" 'the sidecar points at the copy in the dispatch dir' \
  "$SIDECAR_51" worker_done.report_path
if [ "$(cat "$RUN_DIR/implement-51/report-from-worktree.md" 2>/dev/null)" = 'report written inside the worktree' ]; then
  record PASS 'the report is in the dispatch dir, out of the worktree release removes'
else
  record FAIL 'the report is in the dispatch dir, out of the worktree release removes' \
    "copy=[$(cat "$RUN_DIR/implement-51/report-from-worktree.md" 2>/dev/null)]"
fi
expect_json "$RUN_DIR/implement-51/report.md" 'the report path the worker was told stays as told' "$SIDECAR_51" report_path
expect_stdout "released ctx_51 ($TICKET_WT_51 removed)" 'the worktree is removed all the same'
run_module wait --sidecar "$SIDECAR_51" --timeout 1
expect_stdout "$RUN_DIR/implement-51/report-from-worktree.md" 'a later wait prints the copy, outside the worktree'

# The copy stands between the report and the worktree rm: when it cannot be
# made, release refuses before releasing anything (exit 6), the sidecar keeps
# naming the file in the worktree, and a release tried again, once the copy
# can be made, goes through.
ORCA_TEST_DISPATCH_ID=ctx_52
dispatch_ticket 52
SIDECAR_52=$RUN_DIR/dispatch-implement-52.json
TICKET_WT_52=$WORK/wt/case-$CASE_N/spec-26-t52
printf '%s\n' 'report to rescue' > "$TICKET_WT_52/report.md"
write_check "$WORK/check-52.json" ctx_52 report.md
ORCA_TEST_CHECK_JSON=$WORK/check-52.json
run_module wait --sidecar "$SIDECAR_52" --timeout 1
mkdir "$RUN_DIR/implement-52/report-from-worktree.md"
chmod 500 "$RUN_DIR/implement-52/report-from-worktree.md"
: > "$ORCA_LOG"
run_module release --sidecar "$SIDECAR_52"
COPY_EXIT=$RUN_EXIT
chmod 700 "$RUN_DIR/implement-52/report-from-worktree.md"
RUN_EXIT=$COPY_EXIT
expect_exit 6 'a report inside the worktree that cannot be copied out exits 6'
expect_file_has 'could not be copied' 'the failure says the report could not be copied' "$RUN_STDERR"
expect_file_has 'nothing was released' 'the refusal says nothing was released' "$RUN_STDERR"
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show ' ]; then
  record PASS 'only worker-show was asked: nothing released, closed or removed'
else
  record FAIL 'only worker-show was asked: nothing released, closed or removed' "sequence=[$SEQUENCE]"
fi
expect_json "$TICKET_WT_52/report.md" 'the sidecar still names the report in the worktree' "$SIDECAR_52" worker_done.report_path
expect_json '' 'the sidecar records no release' "$SIDECAR_52" released_at
if [ -e "$RUN_DIR/implement-52/report-from-worktree.md/report.md" ]; then
  record FAIL 'nothing half-copied is left behind' 'a copy landed despite the refusal'
else
  record PASS 'nothing half-copied is left behind'
fi
rmdir "$RUN_DIR/implement-52/report-from-worktree.md"
: > "$ORCA_LOG"
run_module release --sidecar "$SIDECAR_52"
expect_exit 0 'a release tried again, with the copy possible, goes through'
expect_json "$RUN_DIR/implement-52/report-from-worktree.md" 'the sidecar now points at the copy' "$SIDECAR_52" worker_done.report_path
if [ "$(cat "$RUN_DIR/implement-52/report-from-worktree.md" 2>/dev/null)" = 'report to rescue' ]; then
  record PASS 'the retried release copied the report out'
else
  record FAIL 'the retried release copied the report out' "copy=[$(cat "$RUN_DIR/implement-52/report-from-worktree.md" 2>/dev/null)]"
fi

# Recorded, but the report is gone: refused before Orca is asked anything.
ORCA_TEST_DISPATCH_ID=ctx_42
finished_ticket 42
rm -f "$RUN_DIR/implement-42/report.md"
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-implement-42.json"
expect_exit 2 'release with a recorded worker_done but no report on disk exits 2'
expect_file_has 'not on disk' 'the missing report is named' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'a missing report calls Orca not at all' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a missing report calls Orca not at all'
fi

# The worker is not settled: refused after the one look, before any release.
write_show "$WORK/show-live.json" ready working
ORCA_TEST_SHOW_JSON=$WORK/show-live.json
ORCA_TEST_DISPATCH_ID=ctx_43
finished_ticket 43
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-implement-43.json"
expect_exit 2 'release of a worker that is not settled exits 2'
expect_file_has 'not ended' 'the refusal says the worker is not ended' "$RUN_STDERR"
expect_file_has 'state=ready' 'the refusal names the state Orca reported' "$RUN_STDERR"
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show ' ]; then
  record PASS 'only worker-show was asked; nothing released, closed or removed'
else
  record FAIL 'only worker-show was asked; nothing released, closed or removed' "sequence=[$SEQUENCE]"
fi

# Each Orca failure stops the sequence there.
write_show "$WORK/show-settled.json" succeeded settled
ORCA_TEST_SHOW_JSON=$WORK/show-settled.json
ORCA_TEST_FAIL='orchestration worker-show'
ORCA_TEST_DISPATCH_ID=ctx_44
finished_ticket 44
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-implement-44.json"
expect_exit 6 'a failing worker-show exits 6'
expect_file_has 'orca orchestration worker-show failed' 'the worker-show failure is surfaced' "$RUN_STDERR"
ORCA_TEST_FAIL='orchestration worker-release'
ORCA_TEST_DISPATCH_ID=ctx_45
finished_ticket 45
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-implement-45.json"
expect_exit 6 'a failing worker-release exits 6'
expect_file_has 'orca orchestration worker-release failed' 'the worker-release failure is surfaced' "$RUN_STDERR"
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show worker-release ' ]; then
  record PASS 'a failed release closes no terminal and removes no worktree'
else
  record FAIL 'a failed release closes no terminal and removes no worktree' "sequence=[$SEQUENCE]"
fi
ORCA_TEST_FAIL='terminal close'
ORCA_TEST_DISPATCH_ID=ctx_46
finished_ticket 46
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-implement-46.json"
expect_exit 0 'a failing terminal close is a warning, not a failure'
expect_file_has 'could not close terminal term_impl' 'the terminal left open is named' "$RUN_STDERR"
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show worker-release close rm ' ]; then
  record PASS 'the worktree is still removed after a failed close'
else
  record FAIL 'the worktree is still removed after a failed close' "sequence=[$SEQUENCE]"
fi
ORCA_TEST_FAIL='worktree rm'
ORCA_TEST_DISPATCH_ID=ctx_47
finished_ticket 47
run_module release --sidecar "$RUN_DIR/dispatch-implement-47.json"
expect_exit 6 'a failing worktree rm exits 6'
expect_file_has 'orca worktree rm failed' 'the worktree rm failure is surfaced' "$RUN_STDERR"
ORCA_TEST_FAIL=

# A fix role ran in the Spec worktree: released, but the worktree stays.
ORCA_TEST_DISPATCH_ID=ctx_48
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" --ticket 48 \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
printf '%s\n' 'fix report' > "$RUN_DIR/fix-48/report.md"
write_check "$WORK/check-48.json" ctx_48 "$RUN_DIR/fix-48/report.md"
ORCA_TEST_CHECK_JSON=$WORK/check-48.json
run_module wait --sidecar "$RUN_DIR/dispatch-fix-48.json" --timeout 1
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-fix-48.json"
expect_exit 0 'release of a fix role exits 0'
SEQUENCE=$(orca_sequence)
if [ "$SEQUENCE" = 'worker-show worker-release close ' ]; then
  record PASS 'a fix role is released and closed, and the Spec worktree is left alone'
else
  record FAIL 'a fix role is released and closed, and the Spec worktree is left alone' "sequence=[$SEQUENCE]"
fi
expect_stdout 'released ctx_48 (worktree kept)' 'release says the worktree was kept'
if grep -Fq "ARG path:$SPEC_WT" "$ORCA_LOG"; then
  record FAIL 'the Spec worktree is never removed'
else
  record PASS 'the Spec worktree is never removed'
fi

# A fix role's report inside the Spec worktree stays where it is: release does
# not remove that worktree, so there is nothing to copy out of.
ORCA_TEST_DISPATCH_ID=ctx_53
run_module dispatch --stage implementation --role fix --brief "$WORK/brief-41.md" --ticket 53 \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26
mkdir -p "$SPEC_WT/.reports"
printf '%s\n' 'fix report inside the Spec worktree' > "$SPEC_WT/.reports/fix-53.md"
write_check "$WORK/check-53.json" ctx_53 .reports/fix-53.md
ORCA_TEST_CHECK_JSON=$WORK/check-53.json
run_module wait --sidecar "$RUN_DIR/dispatch-fix-53.json" --timeout 1
expect_json "$SPEC_WT/.reports/fix-53.md" 'wait resolved the relative path against the Spec worktree' \
  "$RUN_DIR/dispatch-fix-53.json" worker_done.report_path
: > "$ORCA_LOG"
run_module release --sidecar "$RUN_DIR/dispatch-fix-53.json"
expect_exit 0 'release of a fix role whose report is in the Spec worktree exits 0'
expect_json "$SPEC_WT/.reports/fix-53.md" 'the sidecar still names the report in the Spec worktree, which is not removed' \
  "$RUN_DIR/dispatch-fix-53.json" worker_done.report_path
if [ -e "$RUN_DIR/fix-53/report-from-worktree.md" ]; then
  record FAIL 'a report in a worktree that stays is not copied' "$RUN_DIR/fix-53/report-from-worktree.md"
else
  record PASS 'a report in a worktree that stays is not copied'
fi

# An incomplete sidecar has nothing to release.
ORCA_TEST_START_NO_DISPATCH=1
dispatch_ticket 49
ORCA_TEST_START_NO_DISPATCH=0
run_module release --sidecar "$RUN_DIR/dispatch-implement-49.json"
expect_exit 64 'release of a dispatch that did not complete exits 64'
expect_file_has 'no dispatch_id' 'the incomplete sidecar is named' "$RUN_STDERR"

# --- headless stages: handed to the executors that read the table -------------------

# research: codex-worker.sh with --read-only, in the cwd given, run dir of its own.
fresh_case
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --ticket 41 --cwd "$SPEC_WT"
expect_exit 0 'a research dispatch exits 0'
expect_file_has 'codex-worker' 'research is handed to codex-worker.sh' "$FAKE_LOG"
expect_file_has "ARG --cwd" 'codex-worker gets the cwd' "$FAKE_LOG"
expect_file_has "ARG $SPEC_WT" 'codex-worker runs in the cwd the caller gave' "$FAKE_LOG"
expect_file_has "ARG $WORK/brief-41.md" 'codex-worker gets the Brief' "$FAKE_LOG"
expect_file_has "ARG $RUN_DIR/research-41" 'codex-worker gets the dispatch dir as its run dir' "$FAKE_LOG"
expect_file_has 'ARG --read-only' 'research runs read-only, which is what makes it the research route' "$FAKE_LOG"
expect_file_without 'ARG --model' 'the module passes no model: the executor reads the table itself' "$FAKE_LOG"
expect_stdout "$RUN_DIR/research-41/result.md" "the report path is codex-worker's result file"
RESEARCH=$RUN_DIR/dispatch-research-41.json
expect_json headless 'the research sidecar names the headless form' "$RESEARCH" form
expect_json research 'the research sidecar names the stage' "$RESEARCH" stage
expect_json codex-glm 'the research sidecar names the research route profile' "$RESEARCH" route.profile
expect_json glm-5.4 'the research sidecar names the research route model' "$RESEARCH" route.model
expect_json high 'the research sidecar names the research route effort' "$RESEARCH" route.effort
expect_json "$BIN/fake-codex-worker" 'the research sidecar names the executor' "$RESEARCH" script
expect_json 0 'the research sidecar records the exit code' "$RESEARCH" exit_code
expect_json "$RUN_DIR/research-41/result.md" 'the research sidecar records the report path' "$RESEARCH" report_path
expect_file_has '本次派发路由：调研起草（research）：codex-glm / glm-5.4 / high' 'the research route is reported on stderr' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'a headless dispatch calls no Orca' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'a headless dispatch calls no Orca'
fi

# The executor's exit code passes through, and with it no report is claimed.
FAKE_TEST_EXIT=4
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --ticket 42 --cwd "$SPEC_WT"
expect_exit 4 "codex-worker's exit code passes through"
expect_stdout '' 'a failed research dispatch prints no report path'
expect_json 4 'the sidecar records the failed exit code' "$RUN_DIR/dispatch-research-42.json" exit_code
expect_json '' 'the sidecar has no report path for a failed run' "$RUN_DIR/dispatch-research-42.json" report_path
FAKE_TEST_EXIT=0

# --mcp reaches codex-worker; --attempt names a second run of the same ticket.
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --ticket 41 --cwd "$SPEC_WT" \
  --mcp ssh-manager --mcp all --attempt 2
expect_exit 0 'a research dispatch with --mcp and --attempt exits 0'
expect_file_has 'ARG --mcp' 'codex-worker gets the MCP selection' "$FAKE_LOG"
expect_file_has 'ARG ssh-manager' 'the named MCP servers pass through' "$FAKE_LOG"
expect_file_has 'ARG all' 'a second --mcp passes through' "$FAKE_LOG"
expect_json 2 'the second research attempt records its attempt number' "$RUN_DIR/dispatch-research-41-2.json" attempt

# Only the research route is read: switching it moves the sidecar, not the executor.
set_route research=codex-glm/glm-5.3/xhigh
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --cwd "$SPEC_WT"
expect_exit 0 'a research dispatch without a ticket exits 0'
expect_json glm-5.3 'the research sidecar follows a switched research route model' "$RUN_DIR/dispatch-research.json" route.model
expect_json xhigh 'the research sidecar follows a switched research route effort' "$RUN_DIR/dispatch-research.json" route.effort
set_route research=codex-glm/glm-5.4/high

# review: opus-review.sh --kind code on the review route, findings where --out says.
run_module dispatch --stage review --input HEAD~1 --run-dir "$RUN_DIR" --ticket 41 --cwd "$SPEC_WT" --timeout 900
expect_exit 0 'a code review dispatch exits 0'
expect_file_has 'opus-review' 'review is handed to opus-review.sh' "$FAKE_LOG"
expect_file_has 'ARG --kind' 'opus-review gets its kind' "$FAKE_LOG"
expect_file_has 'ARG code' 'a review dispatch is a code review by default' "$FAKE_LOG"
expect_file_has 'ARG --input' 'opus-review gets the input' "$FAKE_LOG"
expect_file_has 'ARG HEAD~1' 'the fixed point passes through' "$FAKE_LOG"
expect_file_has "ARG $RUN_DIR/review-41/findings.md" 'the findings file defaults into the dispatch dir' "$FAKE_LOG"
expect_file_has "ARG $SPEC_WT" 'opus-review runs in the cwd the caller gave' "$FAKE_LOG"
expect_file_has 'ARG --timeout' 'the timeout passes through' "$FAKE_LOG"
expect_file_has 'ARG 900' 'the timeout value passes through' "$FAKE_LOG"
expect_stdout "$RUN_DIR/review-41/findings.md" 'the findings path is printed'
REVIEW=$RUN_DIR/dispatch-review-41.json
expect_json headless 'the review sidecar names the headless form' "$REVIEW" form
expect_json review 'the review sidecar names the stage' "$REVIEW" stage
expect_json claude 'the review sidecar names the review route profile' "$REVIEW" route.profile
expect_json opus 'the review sidecar names the review route model' "$REVIEW" route.model
expect_json "$BIN/fake-opus-review" 'the review sidecar names the executor' "$REVIEW" script
expect_json "$RUN_DIR/review-41/findings.md" 'the review sidecar records the findings path' "$REVIEW" report_path

# A draft review takes a file; --out names the findings file; the exit code
# passes through.
printf '%s\n' '# draft' 'A draft spec.' > "$WORK/draft.md"
run_module dispatch --stage review --kind draft --input "$WORK/draft.md" --run-dir "$RUN_DIR" --out "$WORK/draft-findings.md"
expect_exit 0 'a draft review dispatch exits 0'
expect_file_has 'ARG draft' 'the draft kind passes through' "$FAKE_LOG"
expect_file_has "ARG $WORK/draft.md" 'the draft file passes through' "$FAKE_LOG"
expect_stdout "$WORK/draft-findings.md" 'the findings path is the --out the caller gave'
FAKE_TEST_EXIT=7
run_module dispatch --stage review --input HEAD~1 --run-dir "$RUN_DIR" --ticket 42
expect_exit 7 "opus-review's exit code passes through"
expect_json 7 'the review sidecar records the failed exit code' "$RUN_DIR/dispatch-review-42.json" exit_code
expect_stdout '' 'a failed review dispatch prints no findings path'
FAKE_TEST_EXIT=0

# diagnosis: opus-review.sh --kind diagnose on the diagnosis route, which can
# differ from the review route.
printf '%s\n' '# failure record' 'Two failures.' > "$WORK/failure.md"
set_route diagnosis=claude-glm/glm-5.4/medium
run_module dispatch --stage diagnosis --input "$WORK/failure.md" --run-dir "$RUN_DIR"
expect_exit 0 'a diagnosis dispatch exits 0'
expect_file_has 'ARG diagnose' 'diagnosis is the diagnose kind' "$FAKE_LOG"
expect_file_has "ARG $WORK/failure.md" 'the failure record passes through' "$FAKE_LOG"
expect_stdout "$RUN_DIR/diagnosis/findings.md" 'the findings path is printed'
expect_json diagnosis 'the diagnosis sidecar names the stage' "$RUN_DIR/dispatch-diagnosis.json" stage
expect_json claude-glm 'the diagnosis sidecar names the diagnosis route profile' "$RUN_DIR/dispatch-diagnosis.json" route.profile
expect_json medium 'the diagnosis sidecar names the diagnosis route effort' "$RUN_DIR/dispatch-diagnosis.json" route.effort
expect_file_has '本次派发路由：诊断（diagnosis）：claude-glm / glm-5.4 / medium' 'the diagnosis route is reported on stderr' "$RUN_STDERR"
set_route diagnosis=claude/opus/high

# An executor that is not there is exit 6.
STAGE_DISPATCH_CODEX_WORKER=$WORK/no-such-codex-worker
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --ticket 43
expect_exit 6 'a missing research executor exits 6'
expect_file_has 'research executor was not found' 'the missing executor is named' "$RUN_STDERR"
STAGE_DISPATCH_CODEX_WORKER=$BIN/fake-codex-worker
STAGE_DISPATCH_OPUS_REVIEW=$WORK/no-such-opus-review
run_module dispatch --stage review --input HEAD~1 --run-dir "$RUN_DIR" --ticket 44
expect_exit 6 'a missing review executor exits 6'
STAGE_DISPATCH_OPUS_REVIEW=$BIN/fake-opus-review

# Usage of the headless stages.
run_module dispatch --stage review --run-dir "$RUN_DIR"
expect_exit 64 'a review dispatch without --input exits 64'
run_module dispatch --stage diagnosis --input "$WORK/failure.md" --kind draft --run-dir "$RUN_DIR"
expect_exit 64 'a diagnosis dispatch with --kind exits 64'
run_module dispatch --stage research --input "$WORK/draft.md" --run-dir "$RUN_DIR"
expect_exit 64 'a research dispatch without --brief exits 64'
run_module dispatch --stage review --kind draft --input "$WORK/no-such-draft.md" --run-dir "$RUN_DIR"
expect_exit 64 'a draft review whose draft file is missing exits 64'
run_module dispatch --stage review --input HEAD~1 --cwd "$WORK/no-such-dir" --run-dir "$RUN_DIR"
expect_exit 64 'a dispatch whose --cwd is missing exits 64'
run_module dispatch --stage implementation --brief "$WORK/brief-41.md" --run run_spec26 --run-dir "$RUN_DIR" \
  --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 41 --mcp ssh-manager
expect_exit 64 'an implementation dispatch with --mcp exits 64'
run_module dispatch --stage research --brief "$WORK/brief-41.md" --run-dir "$RUN_DIR" --mcp-config "$WORK/mcp.json"
expect_exit 64 'a research dispatch with --mcp-config exits 64'

# wait and release have nothing to do for a headless dispatch.
: > "$ORCA_LOG"
run_module release --sidecar "$REVIEW"
expect_exit 0 'release of a headless dispatch exits 0'
expect_file_has 'nothing to release' 'release says why' "$RUN_STDERR"
if [ -s "$ORCA_LOG" ]; then
  record FAIL 'release of a headless dispatch calls no Orca' "log=$(cat "$ORCA_LOG")"
else
  record PASS 'release of a headless dispatch calls no Orca'
fi
run_module wait --sidecar "$REVIEW" --timeout 1
expect_exit 64 'wait on a headless dispatch exits 64'
expect_file_has 'nothing to wait for' 'wait says why' "$RUN_STDERR"

# Relative paths are resolved against the caller's directory before they travel
# into another one: the executor runs in --cwd, the terminal in the worktree.
cd "$WORK"
run_module dispatch --stage research --brief brief-41.md --run-dir "$RUN_DIR" --ticket 45 --cwd "$SPEC_WT"
expect_exit 0 'a research dispatch with a relative Brief exits 0'
expect_file_has "ARG $WORK/brief-41.md" 'the Brief reaches codex-worker as an absolute path' "$FAKE_LOG"
run_module dispatch --stage review --input draft.md --run-dir "$RUN_DIR" --ticket 46 --out relative-findings.md
expect_exit 0 'a review dispatch with a relative --out exits 0'
expect_stdout "$WORK/relative-findings.md" 'a relative --out is resolved against the caller directory'
run_module dispatch --stage implementation --brief brief-41.md \
  --run run_spec26 --run-dir "$RUN_DIR" --parent-worktree "$SPEC_WT" --base-branch spec-26 --ticket 45 \
  --mcp-config wt/../mcp.json
expect_exit 0 'an implement dispatch with a relative --mcp-config exits 0'
expect_file_has "--mcp-config $WORK/mcp.json; echo" 'the MCP config reaches the terminal command as a physical absolute path' "$ORCA_LOG"
cd "$ROOT"

# --- the header, the docs and the library rules --------------------------------------

# The header is the module's contract: usage, exit codes, sidecar fields.
HEADER=$WORK/header.txt
sed -n '1,/^set -u$/p' "$SCRIPT" > "$HEADER"
for text in 'Usage:' 'stage-dispatch.sh dispatch --stage implementation' \
  'stage-dispatch.sh wait --sidecar <file>' 'stage-dispatch.sh release --sidecar <file>' \
  'Exit codes:' '2  release refused' '5  the wait timed out' '64 bad usage' \
  'Sidecar fields:' 'dispatch_id' 'terminal' 'worktree' 'route' 'bare_note' \
  'ISS_DISPATCH_BARE is the' '--append-system-prompt-file' '--mcp-config' \
  'report-from-worktree.md' 'worker_done' '--delete-branch' 'Test hooks:'; do
  expect_file_has "$text" "header documents [$text]" "$HEADER"
done
run_module --help
expect_exit 0 '--help exits 0'
expect_file_has 'Usage: stage-dispatch.sh' '--help prints the usage' "$RUN_STDOUT"

# The module leaves the Orca executable to the library and keeps none of its own.
if grep -Fq 'ISS_ORCA' "$SCRIPT"; then
  record FAIL 'stage-dispatch.sh leaves ISS_ORCA to the library'
else
  record PASS 'stage-dispatch.sh leaves ISS_ORCA to the library'
fi
if grep -Eq '"\$ORCA"|\$\{ORCA\}|\$ORCA ' "$SCRIPT"; then
  record FAIL 'stage-dispatch.sh keeps no Orca executable of its own'
else
  record PASS 'stage-dispatch.sh keeps no Orca executable of its own'
fi
# Every Orca call is a library call: no `orca` in command position in the
# module (error messages may name the command that failed).
if grep -vE '^\s*#' "$SCRIPT" | grep -Eq '(^|[;&|])\s*orca |\$\(\s*orca |exec\s+orca '; then
  record FAIL 'stage-dispatch.sh starts no orca command itself'
else
  record PASS 'stage-dispatch.sh starts no orca command itself'
fi
expect_file_has 'bash scripts/test-stage-dispatch.sh' 'MAINTAINING registers the new test' "$ROOT/MAINTAINING.md"
expect_file_has 'worker-show' 'MAINTAINING library entry names the new worker-show test' "$ROOT/MAINTAINING.md"
expect_file_has 'worktree create` 带 `--parent-worktree' 'MAINTAINING library entry names the new child worktree form' "$ROOT/MAINTAINING.md"

if [ "$FAILED" -gt 0 ]; then
  printf 'Artifacts: %s\n' "$WORK"
fi
printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
[ "$FAILED" -eq 0 ]
