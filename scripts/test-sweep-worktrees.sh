#!/usr/bin/env bash
# Isolated fake-dependency tests for scripts/sweep-worktrees.sh.
# No network, no Orca: orca is a fake outside PATH named by ISS_ORCA (the one
# Orca replacement variable) answering repo list, worktree list, worker-list
# and worker-show from fixture files and really removing git worktrees on
# worktree rm; claim.sh is a fake on PATH answering status from a fixture. The
# orca on PATH refuses every call.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/sweep-worktrees.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sweep-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
BIN=$WORK/bin
ORCA_BIN=$WORK/orca-bin
REPO=$WORK/repo
ORIGIN=$WORK/origin.git
RUNS=$WORK/runs
LAUNCH=$WORK/launch-state
FIXTURE=$WORK/fixture
ORCA_LOG=$WORK/orca.log
QUERY_LOG=$WORK/orca-query.log
CLAIM_LOG=$WORK/claim.log
GUARD_LOG=$WORK/orca-guard.log
PASSED=0
FAILED=0
RUN_EXIT=
OUT=

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

expect_has() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    ok "$2"
  else
    bad "$2" "missing [$1]; $(tail -n 5 "$3" 2>/dev/null)"
  fi
}

expect_without() { # text name file
  if grep -Fq -- "$1" "$3" 2>/dev/null; then
    bad "$2" "unexpected [$1]"
  else
    ok "$2"
  fi
}

expect_line() { # action path name: one output line with that action for that path
  if awk -F'\t' -v a="$1" -v p="$2" '$2 == a && $3 == p { found = 1 } END { exit found ? 0 : 1 }' "$OUT" 2>/dev/null; then
    ok "$3"
  else
    bad "$3" "no [$1] line for [$2]; $(grep -F -- "$2" "$OUT" 2>/dev/null | head -n 3)"
  fi
}

expect_no_action() { # action name: no output line carries that action
  if awk -F'\t' -v a="$1" '$2 == a { found = 1 } END { exit found ? 0 : 1 }' "$OUT" 2>/dev/null; then
    bad "$2" "unexpected [$1] line: $(awk -F'\t' -v a="$1" '$2 == a' "$OUT" | head -n 2)"
  else
    ok "$2"
  fi
}

expect_dir() {
  if [ -d "$1" ]; then ok "$2"; else bad "$2" "missing directory [$1]"; fi
}

expect_no_dir() {
  if [ -d "$1" ]; then bad "$2" "unexpected directory [$1]"; else ok "$2"; fi
}

mkdir -p "$BIN" "$ORCA_BIN" "$RUNS" "$LAUNCH" "$FIXTURE" "$REPO" 2>/dev/null || exit 1

# --- the repository: a main checkout with a bare origin ------------------------

git init --quiet --initial-branch=main "$REPO"
git -C "$REPO" config user.name 'Sweep Test'
git -C "$REPO" config user.email 'sweep@example.invalid'
git -C "$REPO" config commit.gpgsign false
printf '%s\n' 'test repository' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m 'initial commit'
git init --quiet --bare --initial-branch=main "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push --quiet origin main
git -C "$REPO" fetch --quiet origin
git -C "$REPO" remote set-head origin -a
REPO=$(cd "$REPO" && pwd -P)

# add_wt var branch [base]: a worktree of the repository on a new branch
add_wt() {
  local dir=$WORK/wt-$(printf '%s' "$2" | tr '/' '_')
  git -C "$REPO" worktree add --quiet -b "$2" "$dir" "${3:-origin/main}"
  printf -v "$1" '%s' "$(cd "$dir" && pwd -P)"
}

add_wt WT_19 spec-19
add_wt WT_20 spec-20
add_wt WT_21 spec-21
add_wt WT_22 spec-22
add_wt WT_22T3 spec-22-t3 spec-22
add_wt WT_23T4 spec-23-t4
add_wt WT_24T5 spec-24-t5
add_wt WT_25 spec-25
add_wt WT_FEAT feature-x
printf '%s\n' 'untracked' > "$WT_23T4/untracked.txt"
printf '%s\n' 'ticket work' > "$WT_24T5/ticket.txt"
git -C "$WT_24T5" add ticket.txt
git -C "$WT_24T5" commit --quiet -m 'ticket 5 work'
STALE=$WORK/wt-spec-26

# --- fakes -------------------------------------------------------------------

cat > "$BIN/claim.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$CLAIM_LOG"
[ -f "$FIXTURE/claim-fail" ] && exit 1
spec=${2:-}
line=$(awk -F'\t' -v n="$spec" '$1 == n { line = $2 " " $3 } END { if (line) print line }' "$FIXTURE/claims.txt" 2>/dev/null)
if [ -n "$line" ]; then printf '%s\n' "$line"; else printf 'free\n'; fi
EOF

# The fake Orca. repo list answers with $FIXTURE/orca-repos.json; worktree list
# with $FIXTURE/orca-worktrees.json (or fails when orca-worktree-list-fail
# exists); worker-list walks the pages $FIXTURE/workers.json and
# workers-<cursor>.json (or fails when orca-worker-list-fail exists);
# worker-show answers with $FIXTURE/worker-show-<dispatch>.json; worktree rm
# really removes the git worktree and its branch from $REPO_PATH, as Orca does.
cat > "$ORCA_BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "repo list")
    printf '%s\n' "$*" >> "$QUERY_LOG"
    cat "$FIXTURE/orca-repos.json"
    exit 0
    ;;
  "worktree list")
    printf '%s\n' "$*" >> "$QUERY_LOG"
    if [ -f "$FIXTURE/orca-worktree-list-fail" ]; then
      printf '%s\n' 'orca offline' >&2
      exit 1
    fi
    cat "$FIXTURE/orca-worktrees.json"
    exit 0
    ;;
  "orchestration worker-list")
    printf '%s\n' "$*" >> "$QUERY_LOG"
    if [ -f "$FIXTURE/orca-worker-list-fail" ]; then
      printf '%s\n' 'orca offline' >&2
      exit 1
    fi
    cursor=
    while [ $# -gt 0 ]; do
      [ "$1" = --cursor ] && cursor=${2:-}
      shift
    done
    if [ -z "$cursor" ]; then
      cat "$FIXTURE/workers.json"
    elif [ -f "$FIXTURE/workers-$cursor.json" ]; then
      cat "$FIXTURE/workers-$cursor.json"
    else
      printf 'fake orca: no workers-%s.json fixture\n' "$cursor" >&2
      exit 1
    fi
    exit 0
    ;;
  "orchestration worker-show")
    printf '%s\n' "$*" >> "$QUERY_LOG"
    dispatch=
    while [ $# -gt 0 ]; do
      [ "$1" = --dispatch ] && dispatch=${2:-}
      shift
    done
    if [ -f "$FIXTURE/worker-show-$dispatch.json" ]; then
      cat "$FIXTURE/worker-show-$dispatch.json"
    else
      printf 'fake orca: no worker-show fixture for %s\n' "${dispatch:-<none>}" >&2
      exit 1
    fi
    exit 0
    ;;
  "worktree rm")
    printf '%s\n' "$*" >> "$ORCA_LOG"
    path=
    while [ $# -gt 0 ]; do
      [ "$1" = --worktree ] && path=${2#path:}
      shift
    done
    branch=
    if [ -d "$path" ]; then branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true); fi
    git -C "$REPO_PATH" worktree remove --force "$path" 2>/dev/null || true
    [ -z "$branch" ] || git -C "$REPO_PATH" branch -D "$branch" >/dev/null 2>&1 || true
    printf '%s\n' '{"ok":true,"result":{"removed":true}}'
    exit 0
    ;;
esac
printf 'fake orca: unexpected arguments: %s\n' "$*" >&2
exit 2
EOF

cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_GUARD_LOG"
printf 'test-sweep-worktrees: orca on PATH was called instead of ISS_ORCA\n' >&2
exit 99
EOF
chmod +x "$BIN/claim.sh" "$BIN/orca" "$ORCA_BIN/orca"

# --- fixtures ----------------------------------------------------------------
# worktrees: the Orca list of this repository: the orphan Ticket (its parent
# gone: parentWorktreeId null), a Spec worktree with a parent, and a Spec
# worktree whose directory no longer exists (a left-over registration).
# workers: one page; a live worker in spec-21, one Orca cannot vouch for in
# spec-25; claims: spec-19 is held by a live session; runs: spec-20 parked.
write_orca_worktrees() {
  node -e '
    const fs = require("fs");
    const [file, main, orphan, spec22, stale, staleEntry] = process.argv.slice(1);
    const entry = (path, branch, extra) => Object.assign(
      {id: "repo-1::" + path, repoId: "repo-1", path, branch, isMainWorktree: false, parentWorktreeId: "wt_main", childWorktreeIds: []}, extra);
    const worktrees = [
      entry(main, "refs/heads/main", {isMainWorktree: true, parentWorktreeId: null}),
      entry(orphan, "refs/heads/spec-22-t3", {parentWorktreeId: null}),
      entry(spec22, "refs/heads/spec-22", {})];
    if (staleEntry) worktrees.push(entry(stale, "refs/heads/spec-26", {parentWorktreeId: null}));
    fs.writeFileSync(file, JSON.stringify({ok: true, result: {worktrees}}));
  ' "$FIXTURE/orca-worktrees.json" "$REPO" "$WT_22T3" "$WT_22" "$STALE" "${1:-1}"
}

write_workers() {
  node -e '
    const fs = require("fs");
    const [file, live, unsure, scope] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({ok: true, result: {scope: {source: scope || "all"}, nextCursor: null, workers: [
      {dispatchId: "ctx_live", taskId: "task_live", state: "running", liveness: "live", terminal: "term_live",
       terminalState: "active", workspace: "repo-1::" + live},
      {dispatchId: "ctx_unsure", taskId: "task_unsure", state: "ready", liveness: "unverifiable", terminal: "term_unsure",
       terminalState: "retained", workspace: "repo-1::" + unsure}]}}));
  ' "$@"
}

write_worker_show() { # dispatch liveness
  node -e '
    const fs = require("fs");
    const [file, dispatch, liveness] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({ok: true, result: {dispatchId: dispatch, state: liveness === "live" ? "running" : "ready",
      stage: liveness === "live" ? "working" : "ready", liveness, terminal: "term_" + dispatch, terminalState: "retained"}}));
  ' "$@"
}

new_fixture() {
  rm -rf "$FIXTURE"
  # the worktrees a real run removed, back where they were (same paths: the
  # Orca fixtures name them)
  [ -d "$WT_22" ] || git -C "$REPO" worktree add --quiet -b spec-22 "$WT_22" origin/main
  [ -d "$WT_22T3" ] || git -C "$REPO" worktree add --quiet -b spec-22-t3 "$WT_22T3" spec-22
  mkdir -p "$FIXTURE"
  : > "$ORCA_LOG"
  : > "$QUERY_LOG"
  : > "$CLAIM_LOG"
  rm -rf "$RUNS" "$LAUNCH"
  mkdir -p "$RUNS/repo-20-20260101-0000" "$LAUNCH"
  printf '{"phase":"parked","updated":"2026-11-28T00:00:00+0800"}\n' > "$RUNS/repo-20-20260101-0000/run.json"
  printf '%s\n' '{"workers": 4, "specs": 2, "apart": [], "auto_land": true, "updated": "2026-11-28T00:00:00Z"}' > "$LAUNCH/test__repo.json"
  printf '%s\n' '{"ok": true, "result": {"repos": [{"id": "repo-1", "path": "'"$REPO"'", "gitRemoteIdentity": {"canonicalKey": "github.com/test/repo"}}]}}' > "$FIXTURE/orca-repos.json"
  write_orca_worktrees
  write_workers "$FIXTURE/workers.json" "$WT_21" "$WT_25"
  write_worker_show "$FIXTURE/worker-show-ctx_live.json" ctx_live live
  write_worker_show "$FIXTURE/worker-show-ctx_unsure.json" ctx_unsure unverifiable
  printf '19\tactive\t{"spec":19}\n' > "$FIXTURE/claims.txt"
}

run_sweep() { # OUT [arguments]: runs in $PWD, or in RUN_CWD when set
  OUT=$1
  shift
  (
    cd "${RUN_CWD:-$PWD}" || exit 1
    env HOME="$WORK/home" FIXTURE="$FIXTURE" FIXTURE_DIR="$FIXTURE" ORCA_LOG="$ORCA_LOG" QUERY_LOG="$QUERY_LOG" \
        CLAIM_LOG="$CLAIM_LOG" ORCA_GUARD_LOG="$GUARD_LOG" REPO_PATH="$REPO" \
        SWEEP_CLAIM="$BIN/claim.sh" SWEEP_LAUNCH_STATE_DIR="$LAUNCH" SWEEP_RUNS_DIR="$RUNS" \
        ISS_ORCA="$ORCA_BIN/orca" PATH="$BIN:$PATH" \
        bash "$SCRIPT" "$@" > "$OUT" 2> "$OUT.err"
  )
  RUN_EXIT=$?
}

# --- usage --------------------------------------------------------------------
new_fixture
run_sweep "$WORK/bogus.out" --bogus
expect_exit 64 "unknown argument exits 64"
run_sweep "$WORK/help.out" --help
expect_exit 0 "--help exits 0"
expect_has 'usage:' "--help prints usage" "$WORK/help.out"

# --- --dry-run lists and removes nothing --------------------------------------
new_fixture
run_sweep "$WORK/dry.out" --dry-run
expect_exit 0 "--dry-run exits 0"
expect_line would-remove "$WT_22" "--dry-run would remove an abandoned Spec worktree"
expect_line would-remove "$WT_22T3" "--dry-run would remove an orphan Ticket worktree"
expect_line would-remove "$STALE" "--dry-run would remove a registration whose directory is gone"
expect_has "parentWorktreeId" "--dry-run marks the orphan as one" "$OUT"
expect_line keep "$REPO" "the main worktree is never removed"
expect_line keep "$WT_19" "a claimed Spec worktree is kept"
expect_has '认领' "the claimed one says why" "$OUT"
expect_line keep "$WT_20" "a parked Spec worktree is kept"
expect_has '停车' "the parked one says why" "$OUT"
expect_line keep "$WT_21" "a Spec worktree with a live worker is kept"
expect_has 'ctx_live' "the live worker names its dispatch" "$OUT"
expect_line keep "$WT_23T4" "a Ticket worktree with uncommitted changes is kept"
expect_line keep "$WT_24T5" "a Ticket worktree with unmerged work is kept"
expect_line skip "$WT_FEAT" "a worktree on another branch is skipped"
expect_has 'summary' "--dry-run prints a summary" "$OUT"
expect_without 'worktree rm' "--dry-run removes nothing" "$ORCA_LOG"
expect_dir "$WT_22" "--dry-run keeps the abandoned Spec worktree"
expect_dir "$WT_22T3" "--dry-run keeps the orphan Ticket worktree"
if [ -s "$GUARD_LOG" ]; then
  bad "--dry-run never calls the orca on PATH" "$(cat "$GUARD_LOG")"
else
  ok "--dry-run never calls the orca on PATH"
fi

# --- a real run removes exactly what --dry-run listed -------------------------
new_fixture
run_sweep "$WORK/real.out"
expect_exit 0 "a real run exits 0"
expect_line removed "$WT_22" "the abandoned Spec worktree is removed"
expect_line removed "$WT_22T3" "the orphan Ticket worktree is removed"
expect_line removed "$STALE" "the registration whose directory is gone is removed"
expect_has "worktree rm --worktree path:$WT_22 --force --delete-branch" "removal goes through orca with the branch" "$ORCA_LOG"
expect_has "worktree rm --worktree path:$WT_22T3 --force --delete-branch" "the Ticket worktree too" "$ORCA_LOG"
expect_has "worktree rm --worktree path:$STALE --force --delete-branch" "the stale registration too" "$ORCA_LOG"
if [ "$(grep -Fc 'worktree rm' "$ORCA_LOG")" -eq 3 ]; then
  ok "nothing else is removed"
else
  bad "nothing else is removed" "$(grep -F 'worktree rm' "$ORCA_LOG")"
fi
expect_no_dir "$WT_22" "the abandoned Spec worktree is gone"
expect_no_dir "$WT_22T3" "the orphan Ticket worktree is gone"
if git -C "$REPO" show-ref --verify --quiet refs/heads/spec-22; then
  bad "the removed Spec branch is gone" "branch spec-22 still exists"
else
  ok "the removed Spec branch is gone"
fi
if git -C "$REPO" show-ref --verify --quiet refs/heads/spec-22-t3; then
  bad "the removed Ticket branch is gone" "branch spec-22-t3 still exists"
else
  ok "the removed Ticket branch is gone"
fi
expect_dir "$REPO" "the main worktree still exists"
expect_dir "$WT_19" "the claimed Spec worktree still exists"
expect_dir "$WT_20" "the parked Spec worktree still exists"
expect_dir "$WT_21" "the Spec worktree with the live worker still exists"
expect_dir "$WT_23T4" "the dirty Ticket worktree still exists"
expect_dir "$WT_24T5" "the unmerged Ticket worktree still exists"
expect_dir "$WT_FEAT" "the worktree on another branch still exists"
expect_line keep "$WT_25" "a worktree whose worker Orca cannot vouch for is kept"
expect_has 'ctx_unsure' "the unverifiable worker names its dispatch" "$OUT"
if [ -s "$GUARD_LOG" ]; then
  bad "the orca on PATH is never called" "$(cat "$GUARD_LOG")"
else
  ok "the orca on PATH is never called"
fi

# Every worker of a worktree exited (two dispatches, as a re-brief leaves
# them): that is "no live worker", and the worktree is judged like one with
# none (a regression: the exited verdict once came back padded and was read as
# unverifiable).
new_fixture
node -e '
  const fs = require("fs");
  const [file, live, unsure, gone] = process.argv.slice(1);
  const base = JSON.parse(fs.readFileSync(file, "utf8"));
  base.result.workers.push(
    {dispatchId: "ctx_gone1", state: "failed", liveness: "exited", terminal: "term_gone1", terminalState: "released", workspace: "repo-1::" + gone},
    {dispatchId: "ctx_gone2", state: "succeeded", liveness: "exited", terminal: "term_gone2", terminalState: "released", workspace: "repo-1::" + gone});
  fs.writeFileSync(file, JSON.stringify(base));
' "$FIXTURE/workers.json" "$WT_21" "$WT_25" "$WT_22"
write_worker_show "$FIXTURE/worker-show-ctx_gone1.json" ctx_gone1 exited
write_worker_show "$FIXTURE/worker-show-ctx_gone2.json" ctx_gone2 exited
run_sweep "$WORK/all-exited.out" --dry-run
expect_exit 0 "a worktree whose workers all exited exits 0"
expect_line would-remove "$WT_22" "a worktree whose workers all exited is abandoned"
expect_has 'orchestration worker-show --dispatch ctx_gone1 --json' "each exited worker is asked of worker-show" "$QUERY_LOG"
expect_has 'orchestration worker-show --dispatch ctx_gone2 --json' "the other exited worker too" "$QUERY_LOG"
expect_has '无法确认' "the unverifiable one is still kept" "$OUT"
expect_without "无法确认 worker 状态（exited" "an exited verdict is never read as unverifiable" "$OUT"

# --- Orca that cannot answer keeps everything ---------------------------------
# worker-list scoped to the calling terminal's Run, or Orca down: "no live
# worker" is a claim about every worker, so nothing is removed and the exit
# code says the round could not judge.
new_fixture
write_workers "$FIXTURE/workers.json" "$WT_21" "$WT_25" bound
run_sweep "$WORK/bound.out" --dry-run

expect_exit 1 "a worker-list scoped to a Run exits 1"
expect_line keep "$WT_22" "a scoped list keeps the abandoned worktree"
expect_has '无法确认' "a scoped list says it could not confirm" "$OUT"

new_fixture
touch "$FIXTURE/orca-worker-list-fail"
run_sweep "$WORK/list-fail.out"
expect_exit 1 "a failing worker-list exits 1"
expect_line keep "$WT_22" "a failing worker-list keeps the abandoned worktree"
expect_without 'worktree rm' "a failing worker-list removes nothing" "$ORCA_LOG"
expect_dir "$WT_22" "a failing worker-list leaves the worktree"

new_fixture
touch "$FIXTURE/claim-fail"
run_sweep "$WORK/claim-fail.out"
expect_exit 1 "a claim.sh that cannot answer exits 1"
expect_line keep "$WT_22" "an unreadable claim keeps the abandoned worktree"
expect_without 'worktree rm' "an unreadable claim removes nothing" "$ORCA_LOG"

# --- the Orca worktree list is an addition, not a requirement -----------------
# Without it the git worktrees are still judged; only the stale registration
# (which git does not know) is out of reach.
new_fixture
touch "$FIXTURE/orca-worktree-list-fail"
run_sweep "$WORK/wt-list-fail.out" --dry-run
expect_exit 0 "a failing worktree list still exits 0"
expect_line would-remove "$WT_22" "a failing worktree list still judges the git worktrees"
expect_without "$STALE" "a failing worktree list cannot see the stale registration" "$OUT"

# --- --repo and auto_land -----------------------------------------------------
new_fixture
run_sweep "$WORK/other.out" --repo other/repo --dry-run
expect_exit 0 "--repo for an unregistered repository exits 0"
expect_has 'summary' "--repo for an unregistered repository still prints a summary" "$OUT"
expect_no_action would-remove "--repo for an unregistered repository lists nothing"

new_fixture
printf '%s\n' '{"workers": 4, "specs": 2, "apart": [], "auto_land": false, "updated": "2026-11-28T00:00:00Z"}' > "$LAUNCH/test__repo.json"
run_sweep "$WORK/no-auto-land.out"
expect_exit 0 "auto_land=false exits 0"
expect_has 'auto_land=false' "auto_land=false is reported" "$OUT"
expect_without 'worktree rm' "auto_land=false removes nothing" "$ORCA_LOG"
expect_dir "$WT_22" "auto_land=false leaves the worktree"

# --- the worktree the sweep runs in is never removed --------------------------
new_fixture
RUN_CWD=$WT_22
run_sweep "$WORK/here.out" --dry-run
RUN_CWD=
expect_exit 0 "run from inside a worktree exits 0"
expect_line keep "$WT_22" "the worktree the sweep runs in is kept"
expect_has '清扫命令所在' "and says so" "$OUT"
expect_without "worktree rm --worktree path:$WT_22 " "run from inside a worktree removes nothing" "$ORCA_LOG"

# --- an empty branch column keeps its place ------------------------------------
# A detached worktree has no branch line in git's porcelain, so its branch
# column is empty (Orca lists it the same way). The unit separator keeps the
# flags behind it in their columns; a tab collapsed them, the main worktree's
# isMain flag read as its branch and it was reported as a skip.
new_fixture
node -e '
  const fs = require("fs");
  const [file, main] = process.argv.slice(1);
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const item of value.result.worktrees) if (item.path === main) item.branch = "";
  fs.writeFileSync(file, JSON.stringify(value));
' "$FIXTURE/orca-worktrees.json" "$REPO"
git -C "$REPO" checkout --quiet --detach
run_sweep "$WORK/detached.out" --dry-run
git -C "$REPO" checkout --quiet main
expect_exit 0 "a detached main worktree exits 0"
expect_line keep "$REPO" "a detached main worktree is kept as the main one"
expect_has '主工作区' "and says so" "$OUT"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
