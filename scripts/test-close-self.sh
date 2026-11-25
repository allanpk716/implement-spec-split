#!/usr/bin/env bash
# Tests for scripts/close-self.sh (fake orca and temporary git repositories).

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/close-self.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/close-self-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN=$WORK/bin
MAIN=$WORK/main
ORIGIN=$WORK/origin.git
WT_CLEAN=$WORK/wt-clean
WT_DIRTY=$WORK/wt-dirty
WT_UNMERGED=$WORK/wt-unmerged
WT_MISMATCH=$WORK/wt-mismatch
ORCA_LOG=$WORK/orca.log
PASSED=0
FAILED=0
RUN_EXIT=
TAB_ID=tab-1
PANE=tab-1:leaf-1
ORCA_FIXTURE=$WORK/orca-clean.json

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

run_close() { # OUT [arguments]
  out=$1
  shift
  env ORCA_TAB_ID="$TAB_ID" ORCA_AGENT_PANE="$PANE" ORCA_LOG="$ORCA_LOG" \
      ORCA_FIXTURE="$ORCA_FIXTURE" PATH="$BIN:$PATH" \
      bash "$SCRIPT" "$@" > "$out" 2> "$out.err"
  RUN_EXIT=$?
}

mkdir -p "$BIN" "$MAIN" || exit 1

cat > "$BIN/orca" <<'EOF'
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
  *)
    exit 0
    ;;
esac
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

git -C "$MAIN" worktree add --quiet -b spec-101 "$WT_CLEAN" origin/main
git -C "$MAIN" worktree add --quiet -b spec-102 "$WT_DIRTY" origin/main
git -C "$MAIN" worktree add --quiet -b spec-103 "$WT_UNMERGED" origin/main
git -C "$MAIN" worktree add --quiet -b spec-104 "$WT_MISMATCH" origin/main
# macOS gives /var/... while the scripts compare physical paths.
WT_CLEAN=$(cd "$WT_CLEAN" && pwd -P)
WT_DIRTY=$(cd "$WT_DIRTY" && pwd -P)
WT_UNMERGED=$(cd "$WT_UNMERGED" && pwd -P)
WT_MISMATCH=$(cd "$WT_MISMATCH" && pwd -P)
printf '%s\n' 'untracked' > "$WT_DIRTY/untracked.txt"
printf '%s\n' 'feature' > "$WT_UNMERGED/feature.txt"
git -C "$WT_UNMERGED" add feature.txt
git -C "$WT_UNMERGED" commit --quiet -m 'unmerged work'

write_orca_fixture "$WORK/orca-clean.json" "$WT_CLEAN"
write_orca_fixture "$WORK/orca-dirty.json" "$WT_DIRTY"
write_orca_fixture "$WORK/orca-unmerged.json" "$WT_UNMERGED"
write_orca_fixture "$WORK/orca-main.json" "$MAIN"
write_orca_fixture "$WORK/orca-other-tab.json" "$WT_CLEAN" tab-9 leaf-9

# --- outside Orca -------------------------------------------------------------
rm -f "$ORCA_LOG"
env ORCA_TAB_ID= ORCA_AGENT_PANE= ORCA_LOG="$ORCA_LOG" ORCA_FIXTURE="$ORCA_FIXTURE" \
    PATH="$BIN:$PATH" bash "$SCRIPT" > "$WORK/skip.out" 2> "$WORK/skip.err"
RUN_EXIT=$?
expect_exit 0 "outside Orca exits 0"
expect_has 'skip: not in Orca' "outside Orca prints skip" "$WORK/skip.out"
if [ -e "$ORCA_LOG" ]; then
  bad "outside Orca calls no orca" "$(cat "$ORCA_LOG")"
else
  ok "outside Orca calls no orca"
fi
rm -f "$ORCA_LOG"

# --- terminal not found -------------------------------------------------------
ORCA_FIXTURE=$WORK/orca-other-tab.json
run_close "$WORK/notfound.out"
expect_exit 1 "a missing terminal exits 1"
expect_has 'no Orca terminal matches' "a missing terminal warns" "$WORK/notfound.out.err"
ORCA_FIXTURE=$WORK/orca-clean.json

# --- default: close only this tab ---------------------------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/default.out"
expect_exit 0 "default run exits 0"
expect_has 'terminal close --terminal term_self --tab' "default run closes its own tab" "$ORCA_LOG"
expect_without 'worktree rm' "default run does not remove a worktree" "$ORCA_LOG"
expect_without '--all' "default run never uses --all" "$ORCA_LOG"
expect_dir "$WT_CLEAN" "default run keeps the worktree"

# --- --remove-worktree matches, clean and merged ------------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/removed.out" --remove-worktree "$WT_CLEAN"
expect_exit 0 "matching clean merged worktree exits 0"
expect_has "worktree rm --worktree path:$WT_CLEAN --force --delete-branch" \
  "matching clean merged worktree is removed through orca" "$ORCA_LOG"
expect_without 'terminal close' "orca worktree rm ends the session, no extra close" "$ORCA_LOG"
expect_without '--all' "worktree removal never uses --all" "$ORCA_LOG"

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

# --- --dry-run ----------------------------------------------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-clean.json
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

# --- --remove-worktree does not match this terminal ---------------------------
rm -f "$ORCA_LOG"
ORCA_FIXTURE=$WORK/orca-main.json
run_close "$WORK/mismatch.out" --remove-worktree "$WT_MISMATCH"
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

# --- --remove-worktree pointing at the main worktree --------------------------
rm -f "$ORCA_LOG"
run_close "$WORK/keep-main.out" --remove-worktree "$MAIN"
expect_exit 0 "pointing at the main worktree exits 0"
expect_has 'main worktree' "pointing at the main worktree warns" "$WORK/keep-main.out.err"
expect_has 'terminal close --terminal term_self --tab' "pointing at the main worktree still closes its own tab" "$ORCA_LOG"
expect_without 'worktree rm' "pointing at the main worktree removes nothing" "$ORCA_LOG"
expect_dir "$MAIN" "the main worktree still exists"

# --- usage --------------------------------------------------------------------
run_close "$WORK/no-args.out" --bogus
expect_exit 64 "unknown argument exits 64"
run_close "$WORK/help.out" --help
expect_exit 0 "--help exits 0"
expect_has 'usage:' "--help prints usage" "$WORK/help.out"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
