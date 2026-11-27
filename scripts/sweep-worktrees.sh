#!/usr/bin/env bash
# Sweep the abandoned Spec and Ticket worktrees of this machine's registered
# repositories (规格 #26, US17; ADR 0004).
#
# Orca keeps the branch of a worktree it removes unless told otherwise, and
# removing a parent worktree leaves its children behind as orphans, so worktrees
# and branches pile up. This script finds what nobody needs any more and, unless
# --dry-run is given, removes it with its branch (`orca worktree rm --force
# --delete-branch`). The keeper calls it once a round; it is a script of this
# repository and runs on its own, so the keeper's fate does not affect it.
#
# A worktree is swept only when every one of these holds:
#   1. it belongs to a registered repository: one with a Launch state
#      (~/.cache/implement-spec-split/launch/<owner>__<name>.json) whose
#      auto_land is not false, located through Orca's repo registry (falling
#      back to ~/orca/<name> and ~/orca/workspaces/<name>);
#   2. its branch is a Spec branch spec-<n> or a Ticket branch spec-<n>-t<m>;
#      anything else (a feature branch, a detached worktree) is not this
#      pipeline's and is skipped;
#   3. it is neither the main worktree nor the worktree this command runs in;
#   4. its Spec is not parked: the newest run directory of the Spec
#      (<runs>/<name>-<n>-*/run.json) does not say phase parked (the worktree
#      keeps the unlanded work for Recovery);
#   5. its Spec is not claimed: `claim.sh status <n>` prints free (active and
#      interrupted both keep it);
#   6. no live worker is in it: the workers worker-list lists for its workspace
#      are asked of worker-show one by one, and every one exited (none at all
#      is fine). A live worker keeps it; so does anything Orca cannot vouch for
#      -- a worker whose liveness is neither live nor exited, a worker-show
#      that fails, a list Orca cannot answer or that cannot be read, a list cut
#      short at SWEEP_PAGES, and a list scoped to the Run bound to the calling
#      terminal (scope.source bound: it says nothing about the other Runs) --
#      since "no live worker" is a claim about every worker;
#   7. it is clean (no uncommitted or untracked change) and its branch is an
#      ancestor of origin's default branch (origin/HEAD, else origin/main, else
#      main), or the branch is already gone: nothing unlanded is ever removed.
#
# The candidates are the worktrees git lists for the repository plus the ones
# Orca lists for it (by repoId), joined on the real path. A Ticket worktree
# Orca lists with parentWorktreeId null is an orphan (its Spec worktree is
# gone) and is named as one; an Orca entry whose directory no longer exists is
# a left-over registration and is removed the same way. The Orca list is an
# addition: without it the git worktrees are judged all the same.
#
# Usage:
#   sweep-worktrees.sh [--dry-run] [--repo <owner/name>]
#
#   --dry-run  list what would be removed and why everything else is kept;
#              remove nothing
#   --repo     only this repository, given as owner/name
#
# Output, one line per worktree, tab-separated: repository, action, path,
# reason. Actions: would-remove (--dry-run), removed, keep, skip (not a Spec
# or Ticket branch, or a repository that is not registered or has auto_land
# false), failed. The last line per repository is a summary: repository,
# summary, -, the counts.
#
# Environment:
#   SWEEP_CLAIM             claim.sh (default the one next to this script)
#   SWEEP_LAUNCH_STATE_DIR  Launch state directory (default
#                          $ISS_LAUNCH_STATE_DIR, else
#                          ~/.cache/implement-spec-split/launch)
#   SWEEP_RUNS_DIR          root of the run directories (default
#                          $ISS_STATE_DIR/runs, else
#                          ~/.cache/implement-spec-split/runs)
#   SWEEP_PAGES             pages of the worker list walked at most (default 10)
#   ISS_ORCA                the Orca executable (default `orca`), read by
#                          scripts/lib-orca.sh; every Orca call goes through it
#
# Exit codes: 0 round finished (also when nothing was swept, and when a worker
# could not be vouched for: only that worktree was kept; each worktree is
# judged on its own), 64 usage error, 1 the worker list could not be trusted
# for some repository (nothing of it was removed), claim.sh could not answer
# for a candidate (only that candidate was kept), or a removal failed.

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=lib-orca.sh
source "$SCRIPT_DIR/lib-orca.sh"

CLAIM=${SWEEP_CLAIM:-$SCRIPT_DIR/claim.sh}
GIT=${SWEEP_GIT:-git}
LAUNCH_STATE_DIR=${SWEEP_LAUNCH_STATE_DIR:-${ISS_LAUNCH_STATE_DIR:-$HOME/.cache/implement-spec-split/launch}}
RUNS_ROOT=${SWEEP_RUNS_DIR:-${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}/runs}
PAGES=${SWEEP_PAGES:-10}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--dry-run] [--repo <owner/name>]

Sweep the abandoned Spec and Ticket worktrees (branches spec-<n> and
spec-<n>-t<m>) of the registered repositories (Launch state with auto_land):
those with no live worker, no claim, a Spec that is not parked, a clean tree
and a branch merged into origin's default branch are removed with their branch
(orphans and left-over Orca registrations included). The main worktree and the
worktree this runs in are never removed. --dry-run lists instead of removing.

  --dry-run  list what would be removed and why the rest is kept
  --repo     only this repository (owner/name)

Environment: SWEEP_CLAIM, SWEEP_LAUNCH_STATE_DIR, SWEEP_RUNS_DIR, SWEEP_PAGES
(10), ISS_ORCA (the Orca executable, see lib-orca.sh).
Output: one tab-separated line per worktree (repository, action, path, reason)
and a summary line per repository.
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

DRY=0
ONLY_REPO=

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY=1
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || usage_error '--repo requires <owner/name>'
      ONLY_REPO=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

case "${ONLY_REPO:-}" in
  '') ;;
  */*) ;;
  *) usage_error "--repo must be <owner/name>, got '$ONLY_REPO'" ;;
esac
case "$PAGES" in
  ''|*[!0-9]*|0) usage_error "SWEEP_PAGES must be a positive integer, got '$PAGES'" ;;
esac

for tool in node "$GIT" "$(orca_exe)"; do
  command -v "$tool" >/dev/null 2>&1 ||
    { printf '%s: %s is required but was not found on PATH\n' "$SCRIPT_NAME" "$tool" >&2; exit 1; }
done
[ -f "$CLAIM" ] ||
  { printf '%s: claim.sh not found: %s\n' "$SCRIPT_NAME" "$CLAIM" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sweep.XXXXXX") || {
  printf '%s: could not create a temporary directory\n' "$SCRIPT_NAME" >&2
  exit 1
}
trap 'rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null' EXIT

# The worktree this command runs in, if any: never a candidate for removal.
HERE_WT=$("$GIT" rev-parse --show-toplevel 2>/dev/null || true)

# --- node helpers ------------------------------------------------------------

# The registered repositories (Launch state files), with whether they land
# unattended; only those are swept.
list_repos() { # prints repo<US>auto_land
  LAUNCH_STATE_DIR=$LAUNCH_STATE_DIR ONLY_REPO=${ONLY_REPO:-} node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.env.LAUNCH_STATE_DIR;
    const want = (process.env.ONLY_REPO || "").toLowerCase();
    const rows = [];
    let files = [];
    try { files = fs.readdirSync(dir); } catch (_) {}
    for (const name of files.sort()) {
      const match = name.match(/^([^_]+)__(.+)\.json$/);
      if (!match) continue;
      const repo = match[1] + "/" + match[2];
      if (want && repo.toLowerCase() !== want) continue;
      let value = null;
      try { value = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8")); } catch (_) {}
      rows.push([repo, value && value.auto_land === false ? "0" : "1"].join("\x1f"));
    }
    process.stdout.write(rows.join("\n") + (rows.length ? "\n" : ""));
  '
}

# The Orca repo registry maps owner/name to the local checkout; prints
# path<TAB>Orca repo id, or nothing.
repo_path() { # repo -> path<TAB>repo id
  REPO_WANT=$1 node -e '
    const fs = require("fs");
    const want = process.env.REPO_WANT.toLowerCase();
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
    const repos = value && value.result && Array.isArray(value.result.repos) ? value.result.repos : [];
    for (const repo of repos) {
      const key = String((repo.gitRemoteIdentity && repo.gitRemoteIdentity.canonicalKey) || "")
        .toLowerCase().replace(/^github\.com\//, "");
      if (key !== want) continue;
      const candidate = String(repo.path || "");
      if (candidate && fs.existsSync(candidate)) {
        process.stdout.write(candidate + "\t" + String(repo.id || ""));
        process.exit(0);
      }
    }
  ' "$WORK/orca-repos.json"
}

origin_slug() { # path -> owner/name of origin, or nothing
  "$GIT" -C "$1" remote get-url origin 2>/dev/null |
    sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | tr '[:upper:]' '[:lower:]'
}

# The candidates of one repository: git's worktrees plus Orca's entries for it,
# joined on the real path. One row per worktree: path<US>branch<US>isMain
# <US>orphan<US>exists<US>inOrca<US>here (US is the unit separator, \x1f: a
# detached worktree has an empty branch column, which a tab would collapse and
# so shift every flag one column left). A Ticket branch Orca lists with
# no parent is an orphan; an Orca entry whose repoId is not the repository's
# counts only when git already lists its path (then the repo id was not
# available, and the path is the evidence).
candidates() { # repo id
  REPO_ID=${1:-} HERE_WT=${HERE_WT:-} node -e '
    const fs = require("fs");
    const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
    const rows = new Map();
    const add = (path, branch, flags) => {
      if (!path) return;
      const key = real(path);
      const row = rows.get(key) || {path: key, branch: "", isMain: 0, orphan: 0, exists: 0, inOrca: 0};
      if (branch) row.branch = branch;
      for (const name of flags) row[name] = 1;
      row.exists = fs.existsSync(key) ? 1 : 0;
      rows.set(key, row);
    };
    let porcelain = "";
    try { porcelain = fs.readFileSync(process.argv[1], "utf8"); } catch (_) {}
    let first = true;
    for (const block of porcelain.split(/\n\n+/)) {
      const lines = block.split("\n");
      const worktree = lines.find((line) => line.startsWith("worktree "));
      if (!worktree) continue;
      const branch = (lines.find((line) => line.startsWith("branch ")) || "").slice("branch ".length);
      add(worktree.slice("worktree ".length), branch, first ? ["isMain"] : []);
      first = false;
    }
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch (_) {}
    const list = value && value.result && Array.isArray(value.result.worktrees) ? value.result.worktrees : [];
    const repoId = process.env.REPO_ID || "";
    for (const item of list) {
      if (!item || !item.path) continue;
      if (repoId && String(item.repoId || "") !== repoId) continue;
      const branch = String(item.branch || "");
      const ticket = /^refs\/heads\/spec-[1-9][0-9]*-t[1-9][0-9]*$/.test(branch);
      const flags = ["inOrca"];
      if (item.isMainWorktree === true) flags.push("isMain");
      if (ticket && item.parentWorktreeId == null) flags.push("orphan");
      add(item.path, branch, flags);
    }
    const here = process.env.HERE_WT ? real(process.env.HERE_WT) : "";
    for (const row of rows.values()) {
      const marks = [row.isMain, row.orphan, row.exists, row.inOrca, here && row.path === here ? 1 : 0];
      process.stdout.write([row.path, row.branch, ...marks].join("\x1f") + "\n");
    }
  ' "$WORK/worktrees.txt" "$WORK/orca-worktrees.json"
}

# Every worker Orca lists, page by page, as realpath<TAB>dispatchId rows kept
# in WORKERS; SCOPE is what the list said it covers. Exits 1 when Orca fails,
# 2 when a page cannot be read, 3 when the list was cut short at SWEEP_PAGES.
walk_workers() {
  local cursor= page=0 list rows line next
  WORKERS=
  SCOPE=
  while :; do
    page=$((page + 1))
    list=$(orca_orchestration_worker_list ${cursor:+--cursor "$cursor"} 2>"$WORK/worker-list.err") || return 1
    rows=$(printf '%s' "$list" | node -e '
      const fs = require("fs");
      const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
      let value;
      try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
      const result = value && value.result;
      if (!result || !Array.isArray(result.workers)) process.exit(2);
      const out = ["scope\t" + String((result.scope && result.scope.source) || "")];
      for (const worker of result.workers) {
        if (!worker || !worker.dispatchId) continue;
        const workspace = String(worker.workspace || "");
        const cut = workspace.indexOf("::");
        out.push(real(cut >= 0 ? workspace.slice(cut + 2) : workspace) + "\t" + String(worker.dispatchId));
      }
      out.push("cursor\t" + (result.nextCursor == null ? "" : String(result.nextCursor)));
      process.stdout.write(out.join("\n") + "\n");
    ') || return 2
    next=
    while IFS= read -r line; do
      case "$line" in
        cursor$'\t'*) next=${line#cursor$'\t'} ;;
        scope$'\t'*) SCOPE=${line#scope$'\t'} ;;
        *) WORKERS="${WORKERS}${line}"$'\n' ;;
      esac
    done <<< "$rows"
    [ -n "$next" ] || return 0
    [ "$page" -ge "$PAGES" ] && return 3
    cursor=$next
  done
}

# What the workers of one worktree are, each asked of worker-show (never of
# the list): none | exited | live<TAB>dispatch | unverifiable<TAB>evidence.
worker_verdict() { # worktree realpath
  local want=$1 dispatches dispatch liveness evidence= verdict=exited
  dispatches=$(printf '%s\n' "$WORKERS" | awk -F'\t' -v w="$want" '$1 == w { print $2 }')
  [ -n "$dispatches" ] || { printf 'none'; return 0; }
  for dispatch in $dispatches; do
    liveness=$(orca_orchestration_worker_show "$dispatch" 2>"$WORK/worker-show.err" | node -e '
      const fs = require("fs");
      let value;
      try { value = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
      process.stdout.write(String(((value && value.result) || {}).liveness || ""));
    ') || liveness=
    case "$liveness" in
      live) printf 'live\t%s' "$dispatch"; return 0 ;;
      exited) ;;
      *) verdict=unverifiable; evidence="$evidence $dispatch liveness=${liveness:-unknown}" ;;
    esac
  done
  if [ "$verdict" = exited ]; then printf 'exited'; else printf 'unverifiable\t%s' "${evidence# }"; fi
}

# Whether the Spec's newest run directory says the Spec is parked.
parked() { # repo name, spec -> 0 when parked
  RUNS_ROOT=$RUNS_ROOT node -e '
    const fs = require("fs"), path = require("path");
    const prefix = process.argv[2] + "-" + process.argv[3] + "-";
    let dirs = [];
    try {
      dirs = fs.readdirSync(process.env.RUNS_ROOT, {withFileTypes: true})
        .filter((entry) => entry.isDirectory() && entry.name.startsWith(prefix)).map((entry) => entry.name).sort();
    } catch (_) {}
    if (!dirs.length) process.exit(1);
    try {
      const value = JSON.parse(fs.readFileSync(path.join(process.env.RUNS_ROOT, dirs[dirs.length - 1], "run.json"), "utf8"));
      process.exit(value.phase === "parked" ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' x "$1" "$2"
}

worktree_clean() { # path -> 0 when git status --porcelain is empty
  local out
  out=$("$GIT" -C "$1" status --porcelain 2>/dev/null) || return 1
  [ -z "$out" ]
}

# origin's default branch, the first of these that exists.
origin_main_ref() { # repo -> origin/HEAD | origin/main | main
  local ref
  for ref in origin/HEAD origin/main main; do
    if "$GIT" -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

# A branch is merged when it is an ancestor of origin's default branch, or
# when it is already gone (nothing is left to lose, and --delete-branch is a
# no-op).
branch_merged() { # repo branch-ref
  local base
  base=$(origin_main_ref "$1") || return 1
  "$GIT" -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1 || return 0
  "$GIT" -C "$1" merge-base --is-ancestor "$2" "$base" >/dev/null 2>&1
}

# --- one repository -----------------------------------------------------------

emit() { # repo action path reason
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

sweep_repo() { # repo path orca repo id
  local repo=$1 path=$2 orca_id=$3 name=${1#*/}
  local removed=0 would=0 keep=0 skip=0 failed=0 judgement=0
  local cpath cbranch cisMain corphan cexists corca chere kind spec
  local claim word verdict base reason
  "$GIT" -C "$path" worktree list --porcelain > "$WORK/worktrees.txt" 2>/dev/null || : > "$WORK/worktrees.txt"
  orca_worktree_list > "$WORK/orca-worktrees.json" 2>/dev/null || : > "$WORK/orca-worktrees.json"
  local walk=0
  walk_workers || walk=$?
  local unsure= why=
  if [ "$walk" -ne 0 ] || [ "$SCOPE" != all ]; then
    judgement=1
    case "$walk" in
      1) why="worker-list 失败：$(head -n 1 "$WORK/worker-list.err" 2>/dev/null)" ;;
      2) why='worker-list 的输出无法解析' ;;
      3) why="worker-list 超过 $PAGES 页" ;;
      *) why="worker-list 只覆盖本终端绑定的 Run（scope.source=${SCOPE}）" ;;
    esac
    unsure="无法确认 worker 状态（${why}），不删"
  fi
  while IFS=$'\x1f' read -r cpath cbranch cisMain corphan cexists corca chere; do
    [ -n "$cpath" ] || continue
    if [ "$cisMain" = 1 ]; then
      emit "$repo" keep "$cpath" '主工作区，绝不删'
      keep=$((keep + 1))
      continue
    fi
    kind=
    if [[ "$cbranch" =~ ^refs/heads/spec-([1-9][0-9]*)$ ]]; then
      kind=spec
      spec=${BASH_REMATCH[1]}
    elif [[ "$cbranch" =~ ^refs/heads/spec-([1-9][0-9]*)-t[1-9][0-9]*$ ]]; then
      kind=ticket
      spec=${BASH_REMATCH[1]}
    else
      emit "$repo" skip "$cpath" "不是规格分支 spec-<n> 或票分支 spec-<n>-t<m>，不属于本流水线，不处理"
      skip=$((skip + 1))
      continue
    fi
    if [ "$chere" = 1 ]; then
      emit "$repo" keep "$cpath" '清扫命令所在的工作区，不删'
      keep=$((keep + 1))
      continue
    fi
    if [ -n "$unsure" ]; then
      emit "$repo" keep "$cpath" "$unsure"
      keep=$((keep + 1))
      continue
    fi
    claim=$(cd "$path" && "$CLAIM" status "$spec" 2>"$WORK/claim.err" </dev/null) || claim=
    word=$(printf '%s\n' "$claim" | sed -n '1p' | awk '{print $1}')
    case "${word:-}" in
      free) ;;
      active|interrupted)
        emit "$repo" keep "$cpath" "有认领（claim.sh status #${spec}：${word}），不删"
        keep=$((keep + 1))
        continue
        ;;
      *)
        emit "$repo" keep "$cpath" "认领状态读不到（claim.sh status #$spec 退出非 0 或无输出：$(head -n 1 "$WORK/claim.err" 2>/dev/null)），不删"
        keep=$((keep + 1))
        judgement=1
        continue
        ;;
    esac
    if parked "$name" "$spec"; then
      emit "$repo" keep "$cpath" "停车规格（run.json phase=parked），工作区留给 Recovery，不删"
      keep=$((keep + 1))
      continue
    fi
    verdict=$(worker_verdict "$cpath")
    case "$verdict" in
      none|exited) ;;
      live$'\t'*)
        emit "$repo" keep "$cpath" "有活跃 worker（dispatch ${verdict#live$'\t'}），不删"
        keep=$((keep + 1))
        continue
        ;;
      *)
        emit "$repo" keep "$cpath" "无法确认 worker 状态（${verdict#unverifiable$'\t'}），不删"
        keep=$((keep + 1))
        continue
        ;;
    esac
    if [ "$cexists" = 1 ] && ! worktree_clean "$cpath"; then
      emit "$repo" keep "$cpath" '有未提交或未跟踪的更改，不删'
      keep=$((keep + 1))
      continue
    fi
    if ! base=$(origin_main_ref "$path") || ! branch_merged "$path" "$cbranch"; then
      emit "$repo" keep "$cpath" "分支 ${cbranch#refs/heads/} 未并入 ${base:-origin 的默认分支}，不删"
      keep=$((keep + 1))
      continue
    fi
    reason="遗弃工作区：无 worker、无认领、未停车、干净且已并入 $base"
    [ "$corphan" = 1 ] && reason="${reason}；Orca 列表里 parentWorktreeId 为空的孤儿"
    [ "$cexists" = 0 ] && reason="${reason}；目录已不存在（Orca 登记残留）"
    if [ "$DRY" -eq 1 ]; then
      emit "$repo" would-remove "$cpath" "$reason"
      would=$((would + 1))
      continue
    fi
    if orca_worktree_rm "$cpath" > "$WORK/rm.out" 2> "$WORK/rm.err"; then
      emit "$repo" removed "$cpath" "$reason"
      removed=$((removed + 1))
    else
      emit "$repo" failed "$cpath" "orca worktree rm 失败：$(head -n 1 "$WORK/rm.err" 2>/dev/null)"
      failed=$((failed + 1))
    fi
  done < <(candidates "$orca_id")
  printf '%s\tsummary\t-\tremoved=%d would-remove=%d keep=%d skip=%d failed=%d\n' \
    "$repo" "$removed" "$would" "$keep" "$skip" "$failed"
  [ "$failed" -eq 0 ] && [ "$judgement" -eq 0 ]
}

# --- main ---------------------------------------------------------------------

: > "$WORK/orca-repos.json"
orca_repo_list > "$WORK/orca-repos.json" 2>/dev/null || : > "$WORK/orca-repos.json"

STATUS=0
ROWS=$(list_repos)
if [ -z "$ROWS" ] && [ -n "$ONLY_REPO" ]; then
  emit "$ONLY_REPO" skip - '未登记的仓库（Launch state 里没有它），不处理'
  printf '%s\tsummary\t-\tremoved=0 would-remove=0 keep=0 skip=0 failed=0\n' "$ONLY_REPO"
fi
while IFS=$'\x1f' read -r repo auto_land; do
  [ -n "$repo" ] || continue
  if [ "$auto_land" = 0 ]; then
    emit "$repo" skip - 'auto_land=false，不处理'
    continue
  fi
  found=$(repo_path "$repo")
  path=${found%%$'\t'*}
  orca_id=${found#*$'\t'}
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    orca_id=
    path=
    for candidate in "$HOME/orca/${repo#*/}" "$HOME/orca/workspaces/${repo#*/}"; do
      [ -d "$candidate" ] || continue
      [ "$(origin_slug "$candidate")" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ] || continue
      path=$candidate
      break
    done
  fi
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    emit "$repo" skip - '找不到本地 checkout，不处理'
    continue
  fi
  path=$(cd -P "$path" && pwd) || continue
  sweep_repo "$repo" "$path" "$orca_id" || STATUS=1
done <<< "$ROWS"

exit "$STATUS"
