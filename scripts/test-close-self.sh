#!/usr/bin/env bash
# Tests for scripts/close-self.sh (fake orca and temporary git repositories).
# close-self.sh reaches the fake orca only through ISS_ORCA, the one Orca
# replacement variable (scripts/lib-orca.sh); the fake sits outside PATH and
# the orca on PATH refuses every call, so a close-self.sh that stops going
# through the library fails here instead of reaching the real Orca.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/close-self.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/close-self-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# The physical path, without the // that a TMPDIR ending in a slash leaves:
# the scripts hand run directory paths through node, which normalises them.
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
ORCA_BIN=$WORK/orca-bin
MAIN=$WORK/main
ORIGIN=$WORK/origin.git
WT_CLEAN=$WORK/wt-clean
WT_DIRTY=$WORK/wt-dirty
WT_UNMERGED=$WORK/wt-unmerged
WT_MISMATCH=$WORK/wt-mismatch
ORCA_LOG=$WORK/orca.log
GUARD_LOG=$WORK/orca-guard.log
SHOW_DIR=$WORK/show
PASSED=0
FAILED=0
RUN_EXIT=
TAB_ID=tab-1
PANE=tab-1:leaf-1
HANDLE=
ORCA_FIXTURE=$WORK/orca-clean.json
ORCA_EXE=$ORCA_BIN/orca

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

expect_dir() {
  if [ -d "$1" ]; then ok "$2"; else bad "$2" "missing directory [$1]"; fi
}

expect_no_dir() {
  if [ -d "$1" ]; then bad "$2" "unexpected directory [$1]"; else ok "$2"; fi
}

expect_before() { # text1 text2 name file: the first line with text1 comes before the first with text2
  first=$(grep -nF -- "$1" "$4" 2>/dev/null | head -n 1 | cut -d: -f1)
  second=$(grep -nF -- "$2" "$4" 2>/dev/null | head -n 1 | cut -d: -f1)
  if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
    ok "$3"
  else
    bad "$3" "[$1] at line [$first], [$2] at line [$second]"
  fi
}

write_orca_fixture() { # file worktreePath [tabId] [leafId]
  node -e '
    const fs = require("fs");
    const [file, worktreePath, tabId, leafId] = process.argv.slice(1);
    const value = {ok: true, result: {terminals: [
      {handle: "term_self", tabId: tabId || "tab-1", leafId: leafId || "leaf-1",
       worktreePath, title: "/implement-spec-split 7"},
      {handle: "term_other", tabId: "tab-2", leafId: "leaf-2",
       worktreePath: "/elsewhere/other-repo", title: "#119 task"}
    ]}};
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$@"
}

write_show_fixture() { # worktreePath [handle]: terminal show --terminal <handle> --json
  node -e '
    const fs = require("fs");
    const [showDir, worktreePath, handle] = process.argv.slice(1);
    const value = {ok: true, result: {terminal: {
      handle: handle || "term_self", tabId: "tab-1", leafId: "leaf-1", worktreePath,
      title: "/implement-spec-split 7", connected: true, orphaned: false}}};
    fs.writeFileSync(showDir + "/" + (handle || "term_self") + ".json", JSON.stringify(value));
  ' "$@"
}

write_progress_fixture() { # file worktreePath
  node -e '
    const fs = require("fs");
    const [file, worktreePath] = process.argv.slice(1);
    const value = {ok: true, result: {terminals: [
      {handle: "term_self", tabId: "tab-1", leafId: "leaf-1",
       worktreeId: "wt-self", worktreePath, title: "/implement-spec-split 7"},
      {handle: "term_prog", tabId: "tab-2", worktreeId: "wt-self", title: "spec-7 t3"},
      {handle: "term_other_wt", tabId: "tab-3", worktreeId: "wt-other", title: "spec-7 t9"}
    ]}};
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$@"
}

write_sidecar() { # runDir name ticket specN ticketWorktree dispatch [released]
  # A sidecar as stage-dispatch.sh wait leaves it: the dispatch recorded, its
  # worker_done with a report that is on disk, in the dispatch dir (outside
  # the worktree).
  node -e '
    const fs = require("fs"), path = require("path");
    const [runDir, name, ticket, specN, ticketWorktree, dispatch, released] = process.argv.slice(1);
    const dir = path.join(runDir, name);
    fs.mkdirSync(dir, {recursive: true});
    const report = path.join(dir, "report.md");
    fs.writeFileSync(report, "# report of " + name + "\n");
    const value = {version: 1, stage: "implementation", role: "implement", ticket: Number(ticket), attempt: 1,
      run_id: "run_spec", run_dir: runDir, form: "interactive", dispatch_dir: dir,
      route: {profile: "claude-glm", model: "glm-5.4", effort: "high"}, started_at: "2026-11-28T00:00:00+0800",
      launcher: "claude-glm", bare: true, bare_note: "lean", brief: path.join(dir, "brief.md"),
      repo: process.env.REPO_PATH, parent_worktree: process.env.SPEC_WORKTREE,
      base_branch: "spec-" + specN, worktree: ticketWorktree, worktree_created: true,
      branch: "spec-" + specN + "-t" + ticket, report_path: report, spec_file: path.join(dir, "spec.md"),
      launch_command: "claude-glm", terminal: "term_" + dispatch, dispatch_id: dispatch, task_id: "task_" + dispatch,
      worker_done: {outcome: "succeeded", report_path: report, message_id: "msg_" + dispatch, received_at: "2026-11-28T01:00:00Z"}};
    if (released) value.released_at = "2026-11-28T02:00:00+0800";
    fs.writeFileSync(path.join(runDir, "dispatch-" + name + ".json"), JSON.stringify(value, null, 2) + "\n");
  ' "$@"
}

write_workers_fixture() { # file [terminal dispatch terminalState]...
  # One page of worker-list --json: a worker per triple, the list covering
  # every Run (scope.source all), no next page.
  node -e '
    const fs = require("fs");
    const [file, ...rest] = process.argv.slice(1);
    const workers = [];
    for (let i = 0; i + 2 < rest.length; i += 3) {
      workers.push({dispatchId: rest[i + 1], taskId: "task_" + rest[i + 1], state: "succeeded",
        liveness: "exited", terminal: rest[i], terminalState: rest[i + 2], workspace: "repo::/elsewhere"});
    }
    fs.writeFileSync(file, JSON.stringify({ok: true, result: {workers, scope: {source: "all"}, nextCursor: null}}));
  ' "$@"
}

write_dispatch_show() { # dispatch state stage
  node -e '
    const fs = require("fs");
    const [showDir, dispatch, state, stage] = process.argv.slice(1);
    fs.writeFileSync(showDir + "/dispatch-" + dispatch + ".json", JSON.stringify({ok: true, result: {
      dispatchId: dispatch, state, stage, liveness: stage === "settled" ? "exited" : "live",
      terminal: "term_" + dispatch, terminalState: "retained"}}));
  ' "$SHOW_DIR" "$@"
}

run_close() { # OUT [arguments]
  out=$1
  shift
  env ORCA_TAB_ID="$TAB_ID" ORCA_AGENT_PANE="$PANE" ORCA_TERMINAL_HANDLE="$HANDLE" \
      ORCA_LOG="$ORCA_LOG" ORCA_GUARD_LOG="$GUARD_LOG" ORCA_FIXTURE="$ORCA_FIXTURE" \
      ORCA_SHOW_DIR="$SHOW_DIR" REPO_PATH="$MAIN" ORCA_WORKERS="${ORCA_WORKERS:-}" \
      ORCA_LIST_FAIL="${ORCA_LIST_FAIL:-0}" ORCA_FAIL="${ORCA_FAIL:-0}" \
      ORCA_RELEASE_REFUSE="${ORCA_RELEASE_REFUSE:-}" \
      ORCA_RELEASE_RETAIN="${ORCA_RELEASE_RETAIN:-}" \
      ISS_ORCA="$ORCA_EXE" \
      PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@" > "$out" 2> "$out.err"
  RUN_EXIT=$?
}

mkdir -p "$BIN" "$ORCA_BIN" "$SHOW_DIR" "$MAIN" || exit 1

# The fake Orca, outside PATH: every call is logged as one line with all its
# arguments. terminal list answers with $ORCA_FIXTURE (or fails when
# ORCA_FAIL=1); terminal show with $ORCA_SHOW_DIR/<handle>.json; worker-list
# with $ORCA_WORKERS; worker-show with $ORCA_SHOW_DIR/dispatch-<id>.json;
# worker-release succeeds unless $ORCA_RELEASE_REFUSE exists (then Orca refuses
# a worker that is not settled) and answers "retained" when
# $ORCA_RELEASE_RETAIN exists (a terminal the caller opened itself). worktree rm
# really removes the git worktree of $REPO_PATH and its branch, as Orca does,
# so that what is left on disk can be asserted.
cat > "$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$ORCA_LOG"
case "$*" in
  'terminal list --json')
    if [ "${ORCA_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'orca offline' >&2
      exit 1
    fi
    cat "$ORCA_FIXTURE"
    ;;
  'terminal show --terminal '*)
    handle=$4
    if [ -f "$ORCA_SHOW_DIR/$handle.json" ]; then
      cat "$ORCA_SHOW_DIR/$handle.json"
    else
      printf 'fake orca: no such terminal: %s\n' "$handle" >&2
      exit 1
    fi
    ;;
  'orchestration worker-list --json'|'orchestration worker-list --json --cursor '*)
    if [ "${ORCA_LIST_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'orca offline' >&2
      exit 1
    fi
    if [ -f "${ORCA_WORKERS:-}" ]; then cat "$ORCA_WORKERS"; else
      printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"all"},"nextCursor":null}}'
    fi
    ;;
  'orchestration worker-show --dispatch '*)
    dispatch=$4
    if [ -f "$ORCA_SHOW_DIR/dispatch-$dispatch.json" ]; then
      cat "$ORCA_SHOW_DIR/dispatch-$dispatch.json"
    else
      printf 'fake orca: no such dispatch: %s\n' "$dispatch" >&2
      exit 1
    fi
    ;;
  'orchestration worker-release --dispatch '*)
    if [ -f "${ORCA_RELEASE_REFUSE:-}" ]; then
      printf '%s\n' 'fake orca: dispatch is not settled' >&2
      exit 1
    fi
    if [ -f "${ORCA_RELEASE_RETAIN:-}" ]; then
      printf '%s\n' '{"ok":true,"result":{"state":"retained","reason":"external_terminal"}}'
    else
      printf '%s\n' '{"ok":true,"result":{"state":"released","processAction":"closed_agent_terminal"}}'
    fi
    ;;
  'terminal close --terminal '*)
    exit 0
    ;;
  'worktree rm --worktree path:'*)
    path=${4#path:}
    branch=
    if [ -d "$path" ]; then branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true); fi
    git -C "$REPO_PATH" worktree remove --force "$path" 2>/dev/null || true
    [ -z "$branch" ] || git -C "$REPO_PATH" branch -D "$branch" >/dev/null 2>&1 || true
    printf '%s\n' '{"ok":true,"result":{"removed":true}}'
    ;;
  *)
    printf 'fake orca: unexpected arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$ORCA_BIN/orca"

# Guard rail: this machine has a real `orca` on PATH. The one on the tests'
# PATH refuses every call, so a close-self.sh (or a script it runs) that stops
# going through ISS_ORCA fails here instead of reaching the real Orca.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_GUARD_LOG"
printf 'test-close-self: orca on PATH was called instead of ISS_ORCA\n' >&2
exit 99
EOF
chmod +x "$BIN/orca"

# A repository with a bare origin, so origin/HEAD and origin/main both exist.
git init --quiet --initial-branch=main "$MAIN"
git -C "$MAIN" config user.name 'Close Self Test'
git -C "$MAIN" config user.email 'close-self@example.invalid'
git -C "$MAIN" config commit.gpgsign false
printf '%s\n' 'test repository' > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit --quiet -m 'initial commit'
git init --quiet --bare --initial-branch=main "$ORIGIN"
git -C "$MAIN" remote add origin "$ORIGIN"
git -C "$MAIN" push --quiet origin main
git -C "$MAIN" fetch --quiet origin
git -C "$MAIN" remote set-head origin -a

# new_spec_worktree n var: a Spec worktree spec-<n> off origin/main, its
# physical path stored in the named variable
new_spec_worktree() {
  local dir=$WORK/wt-spec-$1
  git -C "$MAIN" worktree add --quiet -b "spec-$1" "$dir" origin/main
  printf -v "$2" '%s' "$(cd "$dir" && pwd -P)"
}

# new_ticket_worktree n m var: a Ticket worktree spec-<n>-t<m> off spec-<n>
new_ticket_worktree() {
  local dir=$WORK/wt-spec-$1-t$2
  git -C "$MAIN" worktree add --quiet -b "spec-$1-t$2" "$dir" "spec-$1"
  printf -v "$3" '%s' "$(cd "$dir" && pwd -P)"
}

# macOS gives /var/... while the scripts compare physical paths: every worktree
# path the scripts compare is the physical one.
new_spec_worktree 101 WT_CLEAN
new_spec_worktree 102 WT_DIRTY
new_spec_worktree 103 WT_UNMERGED
new_spec_worktree 104 WT_MISMATCH
printf '%s\n' 'untracked' > "$WT_DIRTY/untracked.txt"
printf '%s\n' 'feature' > "$WT_UNMERGED/feature.txt"
git -C "$WT_UNMERGED" add feature.txt
git -C "$WT_UNMERGED" commit --quiet -m 'unmerged work'

write_orca_fixture "$WORK/orca-clean.json" "$WT_CLEAN"
write_orca_fixture "$WORK/orca-dirty.json" "$WT_DIRTY"
write_orca_fixture "$WORK/orca-unmerged.json" "$WT_UNMERGED"
write_orca_fixture "$WORK/orca-main.json" "$MAIN"
write_orca_fixture "$WORK/orca-other-tab.json" "$WT_CLEAN" tab-9 leaf-9
write_show_fixture "$SHOW_DIR" "$WT_CLEAN"

# --- usage --------------------------------------------------------------------
run_close "$WORK/no-args.out" --bogus
expect_exit 64 "unknown argument exits 64"
run_close "$WORK/help.out" --help
expect_exit 0 "--help exits 0"
expect_has 'usage:' "--help prints usage" "$WORK/help.out"

# --- outside Orca -------------------------------------------------------------
rm -f "$ORCA_LOG"
TAB_ID= PANE= HANDLE=
run_close "$WORK/skip.out"
TAB_ID=tab-1 PANE=tab-1:leaf-1
expect_exit 0 "outside Orca exits 0"
expect_has 'skip: not in Orca' "outside Orca prints skip" "$WORK/skip.out"
if [ -e "$ORCA_LOG" ]; then
  bad "outside Orca calls no orca" "$(cat "$ORCA_LOG")"
else
  ok "outside Orca calls no orca"
fi
rm -f "$ORCA_LOG"

# --- ISS_ORCA is the only way to reach orca -----------------------------------
# An `orca` on PATH must not be used when ISS_ORCA names a program that does
# not exist: then this is not an Orca session and nothing is closed.
ORCA_EXE=$WORK/no-such-orca
run_close "$WORK/no-orca.out"
ORCA_EXE=$ORCA_BIN/orca
expect_exit 0 "a missing ISS_ORCA program exits 0"
expect_has 'skip: not in Orca' "a missing ISS_ORCA program prints skip" "$WORK/no-orca.out"
if [ -e "$GUARD_LOG" ]; then
  bad "a missing ISS_ORCA program never falls back to the orca on PATH" "$(cat "$GUARD_LOG")"
else
  ok "a missing ISS_ORCA program never falls back to the orca on PATH"
fi

# --- terminal not found -------------------------------------------------------
ORCA_FIXTURE=$WORK/orca-other-tab.json
run_close "$WORK/notfound.out"
expect_exit 1 "a missing terminal exits 1"
expect_has 'no Orca terminal matches' "a missing terminal warns" "$WORK/notfound.out.err"
ORCA_FIXTURE=$WORK/orca-clean.json

# Orca itself failing is said as such, and nothing is closed.
rm -f "$ORCA_LOG"
ORCA_FAIL=1
run_close "$WORK/orca-down.out"
ORCA_FAIL=0
expect_exit 1 "an Orca that cannot answer exits 1"
expect_has 'orca terminal list failed' "an Orca that cannot answer is reported as such" "$WORK/orca-down.out.err"
expect_has 'orca offline' "an Orca that cannot answer: its message is passed through" "$WORK/orca-down.out.err"
expect_without 'terminal close' "an Orca that cannot answer closes nothing" "$ORCA_LOG"

# --- default: close only this tab ---------------------------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/default.out"
expect_exit 0 "default run exits 0"
expect_has 'terminal close --terminal term_self --tab' "default run closes its own tab" "$ORCA_LOG"
expect_without 'worktree rm' "default run does not remove a worktree" "$ORCA_LOG"
expect_without '--all' "default run never uses --all" "$ORCA_LOG"
expect_dir "$WT_CLEAN" "default run keeps the worktree"

# --- the adopted form: no tab variables, the inherited handle (规格 #26) -------
# A session Orca dispatched or adopted may carry neither ORCA_TAB_ID nor
# ORCA_AGENT_PANE. The handle every Orca terminal inherits,
# ORCA_TERMINAL_HANDLE, is asked of Orca with terminal show instead.
rm -f "$ORCA_LOG"
TAB_ID= PANE= HANDLE=term_self
run_close "$WORK/handle.out"
TAB_ID=tab-1 PANE=tab-1:leaf-1 HANDLE=
expect_exit 0 "with only the inherited handle exits 0"
expect_has 'terminal show --terminal term_self --json' "asks Orca about the inherited handle" "$ORCA_LOG"
expect_without 'terminal list' "does not list terminals for a handle it already has" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "with only the inherited handle closes its own tab" "$ORCA_LOG"

rm -f "$ORCA_LOG"
TAB_ID= PANE= HANDLE=term_self
run_close "$WORK/handle-dry.out" --remove-worktree "$WT_CLEAN" --dry-run
TAB_ID=tab-1 PANE=tab-1:leaf-1 HANDLE=
expect_exit 0 "with only the inherited handle, --remove-worktree --dry-run exits 0"
expect_has "dry-run: orca worktree rm --worktree path:$WT_CLEAN --force --delete-branch" \
  "the worktree path comes from terminal show" "$WORK/handle-dry.out"

# A tab that Orca no longer lists, with the inherited handle present: the
# handle still resolves, and the session is closed through it.
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-other-tab.json
HANDLE=term_self
run_close "$WORK/handle-fallback.out"
HANDLE=
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "a stale pane with a live handle exits 0"
expect_has 'no Orca terminal matches' "a stale pane with a live handle warns about the pane" "$WORK/handle-fallback.out.err"
expect_has 'terminal show --terminal term_self --json' "a stale pane with a live handle asks Orca about the handle" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "a stale pane with a live handle closes its own tab" "$ORCA_LOG"

# A handle Orca does not have: the session says it is in Orca, so this is an
# error, not a skip.
rm -f "$ORCA_LOG"
TAB_ID= PANE= HANDLE=term_gone
run_close "$WORK/handle-gone.out"
TAB_ID=tab-1 PANE=tab-1:leaf-1
expect_exit 1 "an inherited handle Orca does not have exits 1"
expect_has 'inherited handle term_gone' "an inherited handle Orca does not have warns" "$WORK/handle-gone.out.err"
expect_without 'skip: not in Orca' "a session that names a terminal is never said to be outside Orca" "$WORK/handle-gone.out"
expect_without 'terminal close' "nothing is closed for a handle Orca does not have" "$ORCA_LOG"

# --- a session that is an Orca dispatch ends with worker-release (规格 #26) ----
# When the terminal is the agent terminal of a dispatch (worker-list names a
# worker whose terminal is this handle), the session is a worker and is
# released: Orca closes the terminal and archives the transcript. Any other
# case closes the terminal with terminal close --tab.
write_workers_fixture "$WORK/workers-self.json" term_self ctx_self retained
write_dispatch_show ctx_self succeeded settled
rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-self.json
run_close "$WORK/dispatch.out"
ORCA_WORKERS=
expect_exit 0 "a settled dispatch of this terminal exits 0"
expect_has 'orchestration worker-list --json' "asks Orca for the workers" "$ORCA_LOG"
expect_has 'orchestration worker-show --dispatch ctx_self --json' "asks Orca whether the dispatch is settled" "$ORCA_LOG"
expect_has 'orchestration worker-release --dispatch ctx_self --json' "a settled dispatch is released" "$ORCA_LOG"
expect_without 'terminal close' "a released dispatch needs no terminal close" "$ORCA_LOG"

rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-self.json
run_close "$WORK/dispatch-dry.out" --dry-run
ORCA_WORKERS=
expect_exit 0 "a settled dispatch in --dry-run exits 0"
expect_has 'dry-run: orca orchestration worker-release --dispatch ctx_self --json' \
  "--dry-run prints the release" "$WORK/dispatch-dry.out"
expect_without 'worker-release' "--dry-run releases nothing" "$ORCA_LOG"
expect_without 'terminal close' "--dry-run closes nothing" "$ORCA_LOG"

# A dispatch that is not settled (no worker_done yet): Orca refuses a release,
# so the terminal is closed and Orca releases the dispatch once it is gone.
write_dispatch_show ctx_self running working
rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-self.json
run_close "$WORK/dispatch-running.out"
ORCA_WORKERS=
expect_exit 0 "a running dispatch of this terminal exits 0"
expect_has 'orchestration worker-show --dispatch ctx_self --json' "asks Orca whether the dispatch is settled" "$ORCA_LOG"
expect_without 'worker-release' "a running dispatch is not released" "$ORCA_LOG"
expect_has 'not settled' "a running dispatch is said to be not settled" "$WORK/dispatch-running.out.err"
expect_has 'terminal close --terminal term_self --tab' "a running dispatch closes its terminal instead" "$ORCA_LOG"

# A release Orca refuses, or one that retains the terminal (a terminal the
# caller opened itself): the terminal is closed all the same.
write_dispatch_show ctx_self succeeded settled
rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-self.json ORCA_RELEASE_REFUSE=$WORK/refuse
touch "$WORK/refuse"
run_close "$WORK/dispatch-refused.out"
ORCA_WORKERS= ORCA_RELEASE_REFUSE=
expect_exit 0 "a refused release exits 0"
expect_has 'orchestration worker-release --dispatch ctx_self --json' "the release was tried" "$ORCA_LOG"
expect_has 'did not release' "the refused release is reported" "$WORK/dispatch-refused.out.err"
expect_has 'terminal close --terminal term_self --tab' "a refused release closes the terminal instead" "$ORCA_LOG"

rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-self.json ORCA_RELEASE_RETAIN=$WORK/retain
touch "$WORK/retain"
run_close "$WORK/dispatch-retained.out"
ORCA_WORKERS= ORCA_RELEASE_RETAIN=
expect_exit 0 "a retained terminal exits 0"
expect_has 'orchestration worker-release --dispatch ctx_self --json' "the release was tried" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "a terminal Orca retained is closed here" "$ORCA_LOG"

# A worker-list Orca cannot answer, a worker whose terminal is another's, or a
# worker Orca already released: none of them is this session, which is closed
# as a plain terminal.
rm -f "$ORCA_LOG"
ORCA_LIST_FAIL=1
run_close "$WORK/dispatch-orca-down.out"
ORCA_LIST_FAIL=0
expect_exit 0 "a failing worker-list exits 0"
expect_has 'worker-list failed' "a failing worker-list is reported" "$WORK/dispatch-orca-down.out.err"
expect_has 'terminal close --terminal term_self --tab' "a failing worker-list still closes the terminal" "$ORCA_LOG"

write_workers_fixture "$WORK/workers-others.json" term_other ctx_other retained term_self ctx_old released
rm -f "$ORCA_LOG"
ORCA_WORKERS=$WORK/workers-others.json
run_close "$WORK/dispatch-others.out"
ORCA_WORKERS=
expect_exit 0 "other workers in the list exit 0"
expect_without 'worker-release' "another terminal's worker is not released" "$ORCA_LOG"
expect_without 'worker-show' "a released worker of this terminal is not this session" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "only this terminal is closed" "$ORCA_LOG"

# --- --remove-worktree matches, dirty -----------------------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-dirty.json
run_close "$WORK/dirty.out" --remove-worktree "$WT_DIRTY"
expect_exit 0 "dirty worktree exits 0"
expect_has 'terminal close --terminal term_self --tab' "dirty worktree only closes the tab" "$ORCA_LOG"
expect_without 'worktree rm' "dirty worktree is not removed" "$ORCA_LOG"
expect_has 'uncommitted' "dirty worktree explains why" "$WORK/dirty.out.err"
expect_dir "$WT_DIRTY" "dirty worktree still exists"

# --- --remove-worktree matches, unmerged --------------------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-unmerged.json
run_close "$WORK/unmerged.out" --remove-worktree "$WT_UNMERGED"
expect_exit 0 "unmerged worktree exits 0"
expect_has 'terminal close --terminal term_self --tab' "unmerged worktree only closes the tab" "$ORCA_LOG"
expect_without 'worktree rm' "unmerged worktree is not removed" "$ORCA_LOG"
expect_has 'not merged' "unmerged worktree explains why" "$WORK/unmerged.out.err"
expect_dir "$WT_UNMERGED" "unmerged worktree still exists"

# --- --remove-worktree pointing at the main worktree --------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-main.json
run_close "$WORK/keep-main.out" --remove-worktree "$MAIN"
expect_exit 0 "pointing at the main worktree exits 0"
expect_has 'main worktree' "pointing at the main worktree warns" "$WORK/keep-main.out.err"
expect_has 'terminal close --terminal term_self --tab' "pointing at the main worktree still closes its own tab" "$ORCA_LOG"
expect_without 'worktree rm' "pointing at the main worktree removes nothing" "$ORCA_LOG"
expect_dir "$MAIN" "the main worktree still exists"
ORCA_FIXTURE=$WORK/orca-clean.json

# --- --dry-run ----------------------------------------------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/dry.out" --remove-worktree "$WT_CLEAN" --dry-run
expect_exit 0 "--dry-run exits 0"
expect_has "dry-run: orca worktree rm --worktree path:$WT_CLEAN --force --delete-branch" \
  "--dry-run prints the worktree removal" "$WORK/dry.out"
expect_without 'worktree rm --worktree' "--dry-run executes no worktree removal" "$ORCA_LOG"
expect_without 'terminal close' "--dry-run executes no terminal close" "$ORCA_LOG"
expect_dir "$WT_CLEAN" "--dry-run keeps the worktree"

rm -f "$ORCA_LOG"
run_close "$WORK/dry-default.out" --dry-run
expect_exit 0 "--dry-run without --remove-worktree exits 0"
expect_has 'dry-run: orca terminal close --terminal term_self --tab' \
  "--dry-run prints the terminal close" "$WORK/dry-default.out"
expect_without 'terminal close --terminal' "--dry-run executes no terminal close by default" "$ORCA_LOG"

# --- progress tabs are no longer close-self's business (规格 #26) --------------
# progress-tab.sh is retired by 规格 #26: close-self.sh neither runs it nor
# closes any progress tab, not even the ones of this very worktree. Only this
# session's own tab is closed.
write_progress_fixture "$WORK/orca-progress.json" "$WT_CLEAN"
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-progress.json
run_close "$WORK/progress.out"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "with progress tabs in the worktree exits 0"
expect_has 'terminal close --terminal term_self --tab' "closes its own tab" "$ORCA_LOG"
expect_without 'terminal close --terminal term_prog --tab' "does not close the worktree's progress tab" "$ORCA_LOG"
expect_without 'terminal close --terminal term_other_wt --tab' "does not close another worktree's progress tab" "$ORCA_LOG"

rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-progress.json
run_close "$WORK/progress-dry.out" --dry-run
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "with progress tabs in --dry-run exits 0"
expect_has 'dry-run: orca terminal close --terminal term_self --tab' \
  "--dry-run still prints its own close" "$WORK/progress-dry.out"
expect_without 'term_prog' "--dry-run prints no progress tab close" "$WORK/progress-dry.out"
expect_without 'terminal close --terminal' "--dry-run executes no close" "$ORCA_LOG"

# --- Tickets before the Spec (规格 #26, US20) -----------------------------------
# The sidecars of the Spec's run directory name the Ticket worktrees that are
# left; each goes through stage-dispatch.sh release (worker-release, terminal
# close, worktree rm --delete-branch) before the Spec worktree itself, so that
# removing the parent orphans nothing.

new_spec_worktree 105 WT_A
new_ticket_worktree 105 7 WT_TA
write_orca_fixture "$WORK/orca-a.json" "$WT_A"
write_show_fixture "$SHOW_DIR" "$WT_A"
write_sidecar "$WORK/run-a" implement-7 7 105 "$WT_TA" ctx_t7
write_dispatch_show ctx_t7 succeeded settled
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-a.json
SPEC_WORKTREE=$WT_A run_close "$WORK/tickets.out" --run-dir "$WORK/run-a" --remove-worktree "$WT_A"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "a Spec with one merged, settled Ticket exits 0"
expect_has 'orchestration worker-release --dispatch ctx_t7 --json' "the Ticket's worker is released" "$ORCA_LOG"
expect_has 'terminal close --terminal term_ctx_t7 --tab' "the Ticket's terminal is closed" "$ORCA_LOG"
expect_has "worktree rm --worktree path:$WT_TA --force --delete-branch" "the Ticket worktree is removed with its branch" "$ORCA_LOG"
expect_has "worktree rm --worktree path:$WT_A --force --delete-branch" "the Spec worktree is removed with its branch" "$ORCA_LOG"
expect_before "worktree rm --worktree path:$WT_TA --force --delete-branch" \
  "worktree rm --worktree path:$WT_A --force --delete-branch" "the Ticket worktree goes before the Spec worktree" "$ORCA_LOG"
expect_no_dir "$WT_TA" "the Ticket worktree is gone"
if git -C "$MAIN" show-ref --verify --quiet refs/heads/spec-105-t7; then
  bad "the Ticket branch is gone" "branch spec-105-t7 still exists"
else
  ok "the Ticket branch is gone"
fi
expect_no_dir "$WT_A" "the Spec worktree is gone"
if git -C "$MAIN" show-ref --verify --quiet refs/heads/spec-105; then
  bad "the Spec branch is gone" "branch spec-105 still exists"
else
  ok "the Spec branch is gone"
fi
expect_has 'released_at' "the sidecar records the release" "$WORK/run-a/dispatch-implement-7.json"
expect_has 'released ctx_t7' "the release is reported on stdout" "$WORK/tickets.out"

# The same in --dry-run: every step printed, nothing done.
new_spec_worktree 106 WT_B
new_ticket_worktree 106 8 WT_TB
write_orca_fixture "$WORK/orca-b.json" "$WT_B"
write_show_fixture "$SHOW_DIR" "$WT_B"
write_sidecar "$WORK/run-b" implement-8 8 106 "$WT_TB" ctx_t8
write_dispatch_show ctx_t8 succeeded settled
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-b.json
run_close "$WORK/tickets-dry.out" --run-dir "$WORK/run-b" --remove-worktree "$WT_B" --dry-run
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "Tickets first in --dry-run exits 0"
expect_has "dry-run: stage-dispatch.sh release --sidecar $WORK/run-b/dispatch-implement-8.json" \
  "--dry-run prints the Ticket release" "$WORK/tickets-dry.out"
expect_has "path:$WT_TB --force --delete-branch" "--dry-run names the Ticket worktree and its branch" "$WORK/tickets-dry.out"
expect_has "dry-run: orca worktree rm --worktree path:$WT_B --force --delete-branch" \
  "--dry-run prints the Spec worktree removal after it" "$WORK/tickets-dry.out"
expect_without 'worktree rm --worktree' "--dry-run removes no Ticket worktree" "$ORCA_LOG"
expect_without 'worker-release' "--dry-run releases no worker" "$ORCA_LOG"
expect_dir "$WT_TB" "--dry-run keeps the Ticket worktree"
expect_dir "$WT_B" "--dry-run keeps the Spec worktree"
expect_without 'released_at' "--dry-run leaves the sidecar alone" "$WORK/run-b/dispatch-implement-8.json"

# A Ticket whose worker is not done is not released, and the Spec worktree it
# hangs under stays too (removing the parent would orphan it).
new_spec_worktree 107 WT_C
new_ticket_worktree 107 9 WT_TC
write_orca_fixture "$WORK/orca-c.json" "$WT_C"
write_show_fixture "$SHOW_DIR" "$WT_C"
write_sidecar "$WORK/run-c" implement-9 9 107 "$WT_TC" ctx_t9
write_dispatch_show ctx_t9 running working
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-c.json
run_close "$WORK/ticket-running.out" --run-dir "$WORK/run-c" --remove-worktree "$WT_C"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "a Spec with a running Ticket worker exits 0"
expect_has 'orchestration worker-show --dispatch ctx_t9 --json' "the Ticket's worker is asked about" "$ORCA_LOG"
expect_without 'worker-release' "a running Ticket worker is not released" "$ORCA_LOG"
expect_without 'worktree rm' "nothing is removed while a Ticket worker runs" "$ORCA_LOG"
expect_has 'release refused' "the refused release is reported" "$WORK/ticket-running.out.err"
expect_has 'not merged, or a worker not done' "the Spec worktree is said to be kept for the Ticket" "$WORK/ticket-running.out.err"
expect_has 'terminal close --terminal term_self --tab' "the session still closes its own tab" "$ORCA_LOG"
expect_dir "$WT_TC" "the Ticket worktree stays"
expect_dir "$WT_C" "the Spec worktree stays"

# A Ticket branch with unmerged work is kept without asking Orca at all.
new_spec_worktree 108 WT_D
new_ticket_worktree 108 10 WT_TD
printf '%s\n' 'ticket work' > "$WT_TD/ticket.txt"
git -C "$WT_TD" add ticket.txt
git -C "$WT_TD" commit --quiet -m 'ticket 10 work'
write_orca_fixture "$WORK/orca-d.json" "$WT_D"
write_show_fixture "$SHOW_DIR" "$WT_D"
write_sidecar "$WORK/run-d" implement-10 10 108 "$WT_TD" ctx_t10
write_dispatch_show ctx_t10 succeeded settled
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-d.json
run_close "$WORK/ticket-unmerged.out" --run-dir "$WORK/run-d" --remove-worktree "$WT_D"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "a Spec with an unmerged Ticket exits 0"
expect_without 'worker-show' "an unmerged Ticket is not asked of Orca" "$ORCA_LOG"
expect_without 'worktree rm' "an unmerged Ticket worktree is not removed" "$ORCA_LOG"
expect_has 'keeping Ticket worktree' "the unmerged Ticket is said to be kept" "$WORK/ticket-unmerged.out.err"
expect_has 'spec-108-t10 is not merged into spec-108' "the reason names the branch" "$WORK/ticket-unmerged.out.err"
expect_dir "$WT_TD" "the unmerged Ticket worktree stays"
expect_dir "$WT_D" "the Spec worktree stays with it"

# A dirty Ticket worktree is kept the same way.
new_spec_worktree 110 WT_F
new_ticket_worktree 110 12 WT_TF
printf '%s\n' 'untracked' > "$WT_TF/untracked.txt"
write_orca_fixture "$WORK/orca-f.json" "$WT_F"
write_show_fixture "$SHOW_DIR" "$WT_F"
write_sidecar "$WORK/run-f" implement-12 12 110 "$WT_TF" ctx_t12
write_dispatch_show ctx_t12 succeeded settled
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-f.json
run_close "$WORK/ticket-dirty.out" --run-dir "$WORK/run-f" --remove-worktree "$WT_F"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "a Spec with a dirty Ticket exits 0"
expect_without 'worktree rm' "a dirty Ticket worktree is not removed" "$ORCA_LOG"
expect_has 'uncommitted or untracked changes' "the dirty Ticket is said to be kept" "$WORK/ticket-dirty.out.err"
expect_dir "$WT_TF" "the dirty Ticket worktree stays"
expect_dir "$WT_F" "the Spec worktree stays with it"

# After parking the caller passes no --remove-worktree: the Spec worktree
# keeps the unlanded work, while a merged, settled Ticket is still released.
new_spec_worktree 109 WT_E
new_ticket_worktree 109 11 WT_TE
write_orca_fixture "$WORK/orca-e.json" "$WT_E"
write_show_fixture "$SHOW_DIR" "$WT_E"
write_sidecar "$WORK/run-e" implement-11 11 109 "$WT_TE" ctx_t11
write_dispatch_show ctx_t11 succeeded settled
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-e.json
run_close "$WORK/parking.out" --run-dir "$WORK/run-e"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "after parking exits 0"
expect_has "worktree rm --worktree path:$WT_TE --force --delete-branch" "a merged Ticket is released after parking too" "$ORCA_LOG"
expect_without "worktree rm --worktree path:$WT_E --force" "the Spec worktree is not removed after parking" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "after parking the session closes its own tab" "$ORCA_LOG"
expect_dir "$WT_E" "the Spec worktree stays after parking"

# A sidecar already released is left alone.
rm -f "$ORCA_LOG"
SPEC_WORKTREE=$WT_CLEAN write_sidecar "$WORK/run-g" implement-13 13 101 "$WORK/wt-spec-101-t13" ctx_t13 released
run_close "$WORK/ticket-released.out" --run-dir "$WORK/run-g"
expect_exit 0 "a released Ticket sidecar exits 0"
expect_without 'worker-show' "a released Ticket is not asked of Orca" "$ORCA_LOG"
expect_without 'worktree rm' "a released Ticket removes nothing" "$ORCA_LOG"
expect_has 'terminal close --terminal term_self --tab' "still closes its own tab" "$ORCA_LOG"

# A Ticket worktree of the Spec that no sidecar names still counts: the Spec
# worktree is kept, since removing it would orphan that child.
new_ticket_worktree 101 99 WT_T99
rm -f "$ORCA_LOG"
run_close "$WORK/ticket-unknown.out" --run-dir "$WORK/run-g" --remove-worktree "$WT_CLEAN" --dry-run
expect_exit 0 "a Spec with an unrecorded Ticket worktree exits 0"
expect_without "dry-run: orca worktree rm --worktree path:$WT_CLEAN" \
  "the Spec worktree is not even printed for removal while a Ticket worktree is left" "$WORK/ticket-unknown.out"
expect_has "$WT_T99" "the left Ticket worktree is named" "$WORK/ticket-unknown.out.err"
expect_has 'not merged, or a worker not done' "the Spec worktree is said to be kept for it" "$WORK/ticket-unknown.out.err"
git -C "$MAIN" worktree remove --force "$WT_T99"
git -C "$MAIN" branch -D spec-101-t99 >/dev/null 2>&1

# A run directory that does not exist releases nothing and says so.
rm -f "$ORCA_LOG"
run_close "$WORK/run-dir-missing.out" --run-dir "$WORK/no-such-run-dir" --remove-worktree "$WT_CLEAN" --dry-run
expect_exit 0 "a missing run directory exits 0"
expect_has 'run directory' "a missing run directory is reported" "$WORK/run-dir-missing.out.err"
expect_has "dry-run: orca worktree rm --worktree path:$WT_CLEAN --force --delete-branch" \
  "a missing run directory does not stop the Spec worktree removal" "$WORK/run-dir-missing.out"

# --- --remove-worktree does not match this terminal ---------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-main.json
run_close "$WORK/mismatch.out" --remove-worktree "$WT_MISMATCH"
ORCA_FIXTURE=$WORK/orca-clean.json
expect_exit 0 "mismatching path exits 0"
expect_has 'terminal close --terminal term_self --tab' "mismatching path closes only its own tab" "$ORCA_LOG"
expect_without 'worktree rm' "mismatching path does not call orca worktree rm" "$ORCA_LOG"
expect_without '--all' "mismatching path never uses --all" "$ORCA_LOG"
expect_no_dir "$WT_MISMATCH" "mismatching path removes the worktree with git"
if git -C "$MAIN" show-ref --verify --quiet refs/heads/spec-104; then
  bad "mismatching path deletes the merged branch" "branch spec-104 still exists"
else
  ok "mismatching path deletes the merged branch"
fi

# --- --remove-worktree matches, clean and merged ------------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/removed.out" --remove-worktree "$WT_CLEAN"
expect_exit 0 "matching clean merged worktree exits 0"
expect_has "worktree rm --worktree path:$WT_CLEAN --force --delete-branch" \
  "matching clean merged worktree is removed through orca" "$ORCA_LOG"
expect_without '--all' "worktree removal never uses --all" "$ORCA_LOG"
expect_no_dir "$WT_CLEAN" "matching clean merged worktree is gone"
if git -C "$MAIN" show-ref --verify --quiet refs/heads/spec-101; then
  bad "matching clean merged worktree takes its branch along" "branch spec-101 still exists"
else
  ok "matching clean merged worktree takes its branch along"
fi
# Orca ends the session with the removal; were the terminal still there
# afterwards (the fake Orca closes nothing), the only thing that may follow is
# this session's own close.
rm=$(grep -nF 'worktree rm' "$ORCA_LOG" | head -n 1 | cut -d: -f1)
last=$(wc -l < "$ORCA_LOG" | tr -d ' ')
if [ "$last" -eq "$((rm + 1))" ] && tail -n 1 "$ORCA_LOG" | grep -Fq -- 'terminal close --terminal term_self --tab'; then
  ok "nothing but this session's own close follows the worktree removal"
else
  bad "nothing but this session's own close follows the worktree removal" "rm at $rm of $last lines: $(tail -n 2 "$ORCA_LOG")"
fi

# --- the orca on PATH was never used ------------------------------------------
if [ -s "$GUARD_LOG" ]; then
  bad "orca on PATH is never called" "$(cat "$GUARD_LOG")"
else
  ok "orca on PATH is never called"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
