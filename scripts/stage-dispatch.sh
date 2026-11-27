#!/usr/bin/env bash
# Dispatch one Stage of a Spec on its Stage route (GLOSSARY.md "Stage route",
# ADR 0004): a Ticket's implementation, a fix or merge-conflict role, a research
# worker, or a headless review. The Orca public library (scripts/lib-orca.sh)
# offers the worktree, terminal and orchestration calls; picking the Launcher
# profile, the model and the effort and building the command is this module's,
# and it reads the route table afresh on every dispatch (scripts/stage-route.sh,
# which only the user changes, as /grill-router): a change reaches the next
# dispatch and never a worker that is already running.
#
# Usage:
#   stage-dispatch.sh dispatch --stage implementation --brief <file>
#                  --run <run id> --run-dir <dir> --parent-worktree <spec worktree>
#                  --base-branch spec-<n> [--repo <path>] [--ticket <m>]
#                  [--role implement|fix|merge] [--mcp-config <file>]
#                  [--attempt <n>] [--start-timeout-ms <n>]
#   stage-dispatch.sh dispatch --stage research --brief <file> --run-dir <dir>
#                  [--ticket <m>] [--cwd <dir>] [--mcp <names|all>]...
#                  [--run <run id>] [--attempt <n>]
#   stage-dispatch.sh dispatch --stage review|diagnosis --input <fixed point|file>
#                  --run-dir <dir> [--ticket <m>] [--kind code|draft] [--out <file>]
#                  [--cwd <dir>] [--timeout <seconds>] [--run <run id>] [--attempt <n>]
#   stage-dispatch.sh wait --sidecar <file> [--timeout <seconds>]
#   stage-dispatch.sh release --sidecar <file>
#
# --run is the Spec's Orca Run (#40: one Run per Spec), named explicitly and
# never inherited from the terminal. --run-dir is the Spec's run directory
# (~/.cache/implement-spec-split/runs/<repo>-<n>-<...>); everything a dispatch
# writes goes there, outside any worktree, so deleting the worktree loses none
# of it -- a run directory inside the Spec worktree is refused (exit 64), since
# release removes that worktree. A dispatch's files live in <run dir>/<name>/
# and its sidecar in <run dir>/dispatch-<name>.json, where <name> is the role
# and, when there is one, the ticket: implement-41, fix, merge-41, research-41,
# review-41, diagnosis; --attempt 2 and up append -2, -3... (a re-brief gets a
# fresh name and never overwrites an earlier sidecar).
#
# Interactive stages (implementation: implement, fix and merge roles). The
# route's Launcher profile names the launcher and the form of --model and
# --effort (claude, claude-glm and claude-flash; a codex-glm implementation
# route is a usage error, since codex on GLM runs only headless through
# scripts/codex-worker.sh). The implement role gets a child worktree of the
# Spec worktree, spec-<n>-t<m> on its own branch off --base-branch (a child
# does not inherit its parent's branch, so the base is always named), filed
# under the ticket; fix and merge roles work in the Spec worktree itself on the
# Integration branch, since that is where a fix or a merge resolution belongs
# (the Spec worktree must have --base-branch checked out), and release leaves
# that worktree alone. A terminal opens in that worktree running `<launcher>
# --dangerously-skip-permissions --model … --effort …` and recording the
# launcher's exit code in <dispatch dir>/exit-code (a worker is unattended, so
# no profile keeps its permission prompts), and is adopted with `worker-start
# --terminal --run --spec-file`. The Task is <dispatch dir>/spec.md: a short
# preamble naming the worktree, the report path (<dispatch dir>/report.md) and
# the worker_done report Orca expects with its --task-id, then the Brief as
# given (the Brief states the commit requirement; scripts/merge-ticket.sh's
# gate needs a commit and a clean tree).
#
# Paths that travel into another directory are taken relative to the caller's
# and made absolute first: --brief, --input (as a file), --out, --mcp-config
# and ISS_DISPATCH_LEAN_RULES, since the executor runs in --cwd and the
# terminal in the worktree.
#
# Lean start (精简启动; ADR 0004 Consequences: --bare takes a trivial task from
# 18.6K to 1.2K input tokens). One name for it everywhere: the switch is the
# environment variable ISS_DISPATCH_BARE, the flag it passes the launcher is
# --bare (hence the sidecar's bare and bare_note fields), and the rules file
# variable is named after the lean rules it points at. On, which is the
# default, the implement and fix roles start with `--bare
# --append-system-prompt-file <rules> [--mcp-config <file>]`: --bare loads no
# CLAUDE.md, skills, plugins or hooks, so the rules file carries them as a
# prompt and --mcp-config adds the MCP servers the ticket needs (ops tickets:
# ssh-manager). ISS_DISPATCH_LEAN_RULES names the rules file (default
# templates/lean-rules.md, which #39 settles); without the file the start is a
# normal one and the sidecar's bare_note says so. ISS_DISPATCH_BARE is the
# opt-out: 0, off, no or false turns the lean start off; unset, or any other
# value, leaves it on. The default follows the ticket (#41: lean unless #39
# finds it unusable), so the day #39's verification (the TUI + adoption form
# under --bare, and whether a second --append-system-prompt-file stacks) says
# it cannot be used, the default is turned back off here. --mcp-config is
# passed on a normal start too. The merge role never starts lean, whatever
# the switch and the rules file: it resolves conflicts on the Integration
# branch itself, the riskiest work a worker does here, and --bare would drop
# the CLAUDE.md and the hooks (land-push-guard, delegate-guard) that work
# needs; it is dispatched only on a conflict, so the tokens saved are not
# worth it. Its sidecar's bare_note names the role as the reason.
#
# Headless stages are handed to the executor that already reads the table:
# research runs scripts/codex-worker.sh --read-only (the research route),
# review and diagnosis run scripts/opus-review.sh (their routes). The module
# only builds the arguments; the exit code and the report path pass through
# (codex-worker: result.md / status.json's result_file; opus-review: --out).
# Nothing is adopted and no worktree is made: --cwd (default the current
# directory) is where the executor runs. WORKER_ALLOW_FLASH is not set here:
# under FLASH_ORCHESTRATOR=1 codex-worker.sh refuses as it does for any other
# caller.
#
# wait is one blocking `check --run --take --types worker_done --wait
# --timeout-ms` and nothing else (ADR 0004: no polling): this module is the
# coordinator consuming its own Run's mail. Every worker_done in the batch
# Orca returns is recorded in the sidecar of its dispatch (the run dir's
# dispatch-*.json, matched by dispatch id), so a wait on one ticket that is
# woken by another's worker_done loses nothing: the batch is also kept in
# <dispatch dir>/wait.json. --types narrows what wakes the wait, not what the
# batch holds, and the batch is the Run's whole FIFO: it may carry mail that
# is no worker_done (another Ticket's worker asking its Spec session, say),
# which the check took and which is now in no mailbox but this module's. A
# wait that took any prints each such message on stdout as one line of JSON
# and exits 8 before reporting anything else, even when this dispatch's own
# worker_done came in the same batch (it is recorded all the same, and the
# next wait returns it at once); the caller handles the mail, then waits
# again. A report path the worker gives relative to its worktree is resolved
# against it; one that is not on disk is exit 6. A wait on a dispatch whose
# worker_done was already recorded returns at once without asking Orca. On a
# timeout the caller decides whether to wait again or to judge the worker's
# liveness.
#
# release, after the Ticket branch is merged: refuses (exit 2) unless the
# sidecar records a worker_done whose report is on disk and Orca reports the
# dispatch settled. A report the worker wrote inside the child worktree (a
# relative path, resolved against it) would go with the worktree, so it is
# copied into the dispatch dir as report-from-worktree.md first and the
# sidecar's worker_done.report_path is pointed at the copy (a copy that fails
# is exit 6 and nothing is released). Then `worker-release --dispatch`, then
# `terminal close` on the terminal this module opened (Orca retains a terminal
# it did not open, docs/orca-smoke-2026-11-27.md D), then `worktree rm
# --delete-branch` on the child worktree. A parked Ticket is not released: the
# caller decides.
#
# Sidecar fields: version, stage, role, ticket, attempt, run_id, run_dir,
# route {profile, model, effort}, form (interactive|headless), dispatch_dir,
# started_at; interactive: launcher, bare, bare_note (the lean start: whether
# the start was one, and why not when it was not), brief, repo,
# parent_worktree, base_branch, branch, worktree, worktree_created, spec_file,
# report_path (where the worker was told to write), launch_command, terminal,
# dispatch_id, task_id; headless: script, brief|input, kind (review), cwd,
# report_path (the executor's report once it ran), exit_code, finished_at;
# after a wait: worker_done {outcome, report_path, message_id, received_at};
# after a release: released_at (and worker_done.report_path naming the copy,
# when the report had to be taken out of the worktree). A sidecar without
# dispatch_id is a dispatch that did not complete; it names whatever was
# created so the caller can clean up.
#
# Exit codes:
#   0  dispatched (stdout: the sidecar path); worker_done received (stdout:
#      the report path); released; a headless executor exited 0
#   2  release refused: the worker is not settled, or its report is not on disk
#   5  the wait timed out
#   6  a prerequisite is missing (node, the route's launcher, a headless
#      executor script) or the run directory or the dispatch directory could
#      not be created; Orca failed (worktree create, terminal create,
#      worker-start, check, worker-show, worker-release, worktree rm) or
#      answered with something unusable (no handle, no dispatch id, a
#      worker_done whose report is not on disk); the sidecar could not be
#      written; a report inside the child worktree could not be copied out
#      before its removal
#   7  the wait returned on another dispatch's worker_done; this worker's is
#      still to come: wait again
#   8  the wait took mail of the Run that is no worker_done (stdout: each
#      message as a line of JSON; the batch is kept in wait.json): handle it,
#      then wait again
#   64 bad usage, among it a route that cannot be read and a --run-dir inside
#      the Spec worktree: nothing starts
#   A headless dispatch exits with the executor's own exit code (codex-worker.sh
#   and opus-review.sh document theirs).
#
# Test hooks: STAGE_DISPATCH_STAGE_ROUTE swaps the Stage route table script;
# STAGE_DISPATCH_CODEX_WORKER and STAGE_DISPATCH_OPUS_REVIEW swap the two
# headless executors.

set -u

SCRIPT_NAME=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# Every Orca call goes through the library; this script has no Orca variable.
# shellcheck source=lib-orca.sh
. "$HERE/lib-orca.sh"

usage() {
  cat <<'USAGE'
Usage: stage-dispatch.sh dispatch --stage implementation --brief <file>
                  --run <run id> --run-dir <dir> --parent-worktree <spec worktree>
                  --base-branch spec-<n> [--repo <path>] [--ticket <m>]
                  [--role implement|fix|merge] [--mcp-config <file>]
                  [--attempt <n>] [--start-timeout-ms <n>]
       stage-dispatch.sh dispatch --stage research --brief <file> --run-dir <dir>
                  [--ticket <m>] [--cwd <dir>] [--mcp <names|all>]...
                  [--run <run id>] [--attempt <n>]
       stage-dispatch.sh dispatch --stage review|diagnosis --input <fixed point|file>
                  --run-dir <dir> [--ticket <m>] [--kind code|draft] [--out <file>]
                  [--cwd <dir>] [--timeout <seconds>] [--run <run id>] [--attempt <n>]
       stage-dispatch.sh wait --sidecar <file> [--timeout <seconds>]
       stage-dispatch.sh release --sidecar <file>

dispatch starts one Stage on its route from the Stage route table and prints
         the sidecar path (interactive), or runs the headless executor and
         prints its report path.
wait     blocks once for the dispatch's worker_done; prints the report path.
release  worker-release, terminal close, worktree rm, once the worker is done.
USAGE
}

die() { # code message
  code=$1
  shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$code"
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

warn() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

need_value() { # flag [next]
  if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
    usage_error "$1 needs a value"
  fi
}

command -v node >/dev/null 2>&1 || die 6 'node is required but was not found on PATH'

# --- JSON ------------------------------------------------------------------------
# The sidecar and Orca's receipts are read and written through node, so quotes,
# backticks and newlines in any value need no shell escaping.

# json_get FILE PATH [PATH...]: prints the first PATH the JSON has, as a string
# (an object or array as JSON); exits 1 when none is there, 2 when FILE is not
# JSON.
json_get() {
  node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(2); }
    for (const path of process.argv.slice(2)) {
      let value = root;
      for (const key of path.split(".")) {
        if (value === null || value === undefined) break;
        value = value[key];
      }
      if (value !== undefined && value !== null) {
        process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
        process.exit(0);
      }
    }
    process.exit(1);
  ' "$@"
}

# json_set FILE KEY=VALUE...: sets each (dotted) KEY of the JSON file, creating
# the file; a VALUE written as @json:<json> is stored as JSON. The write is
# atomic.
json_set() {
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    let root = {};
    if (fs.existsSync(file)) {
      try { root = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(2); }
    }
    for (const pair of process.argv.slice(2)) {
      const eq = pair.indexOf("=");
      const path = pair.slice(0, eq).split(".");
      const raw = pair.slice(eq + 1);
      const value = raw.startsWith("@json:") ? JSON.parse(raw.slice(6)) : raw;
      let target = root;
      for (const key of path.slice(0, -1)) {
        if (typeof target[key] !== "object" || target[key] === null) target[key] = {};
        target = target[key];
      }
      target[path[path.length - 1]] = value;
    }
    const tmp = file + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(root, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$@" || return $?
}

now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

true_false() { # 1|0 -> true|false
  [ "$1" -eq 1 ] && printf true || printf false
}

# A path as this module will hand it on: physical when it exists, and absolute
# either way (relative to the caller's directory), since it travels into a
# worktree or a --cwd that is not the caller's.
absolute_path() { # path
  local path=$1
  if [ -d "$path" ]; then
    cd -P "$path" && pwd
  elif [ -f "$path" ]; then
    printf '%s/%s\n' "$(cd -P "$(dirname -- "$path")" && pwd)" "$(basename -- "$path")"
  else
    [[ "$path" = /* ]] || path=$PWD/$path
    printf '%s' "$path"
  fi
}

# A path as it will be once it exists: absolute, and physical as far as it
# already exists (the part that does not is appended unchanged). This is what
# tells a directory that does not exist yet from one inside another.
resolved_path() { # path
  local path=$1 rest=
  path=$(absolute_path "$path")
  path=${path%/}
  while [ ! -e "$path" ]; do
    rest=/${path##*/}$rest
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  printf '%s%s' "$(cd -P "$path" 2>/dev/null && pwd || printf '%s' "$path")" "$rest"
}

# Whether a path lies inside a directory, the directory itself counting as
# inside, both as they will be once they exist: the comparison is
# resolved_path's, so a relative path or one not created yet is judged too.
inside_dir() { # path dir
  case "$(resolved_path "$1")/" in
    "$(resolved_path "$2")"/*) return 0 ;;
  esac
  return 1
}

# --- the route -------------------------------------------------------------------

STAGE_ROUTE=${STAGE_DISPATCH_STAGE_ROUTE:-$HERE/stage-route.sh}
LEAN_RULES=${ISS_DISPATCH_LEAN_RULES:-$HERE/../templates/lean-rules.md}
START_TIMEOUT_MS_DEFAULT=180000
WAIT_TIMEOUT_SECONDS_DEFAULT=7200

stage_label() { # stage
  case "$1" in
    implementation) printf '实现（implementation）' ;;
    research) printf '调研起草（research）' ;;
    review) printf '审查（review）' ;;
    diagnosis) printf '诊断（diagnosis）' ;;
  esac
}

route_field() { # stage field: one value of the stage's route, as the table names it
  local value
  value=$("$STAGE_ROUTE" --print "$1" "$2" 2>/dev/null) ||
    die 64 "cannot read the $1 route's $2 from the Stage route table ($STAGE_ROUTE --print $1 $2 exited $?); nothing starts"
  [ -n "$value" ] || die 64 "$STAGE_ROUTE --print $1 $2 printed nothing for the $1 route; nothing starts"
  printf '%s' "$value"
}

# Reads the stage's route into ROUTE_PROFILE, ROUTE_MODEL, ROUTE_EFFORT and, for
# the interactive form, LAUNCH_ARGS (the launcher first); a route that cannot
# be read is a usage error. The table's own hints went to stderr from the
# --launch read; the --print reads after it are silenced.
read_route() { # stage interactive|headless
  local stage=$1 form=$2 arg launch
  if [ "$form" = interactive ]; then
    launch=$("$STAGE_ROUTE" --launch "$stage" interactive) ||
      die 64 "cannot read the $stage route's launch command from the Stage route table ($STAGE_ROUTE --launch $stage interactive exited $?); nothing starts"
    [ -n "$launch" ] || die 64 "$STAGE_ROUTE --launch printed nothing for the $stage route; nothing starts"
    LAUNCH_ARGS=()
    while IFS= read -r arg; do LAUNCH_ARGS+=("$arg"); done <<< "$launch"
  fi
  ROUTE_PROFILE=$(route_field "$stage" profile)
  ROUTE_MODEL=$(route_field "$stage" model)
  ROUTE_EFFORT=$(route_field "$stage" effort)
}

# --- dispatch --------------------------------------------------------------------

cmd_dispatch() {
  local stage= brief= input= run_id= run_dir= parent_worktree= base_branch= repo_arg= ticket=
  local role=implement mcp_config= attempt=1 start_timeout_ms=$START_TIMEOUT_MS_DEFAULT
  local kind=code kind_given=0 out= cwd=$PWD cwd_given=0 timeout= mcp_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) need_value "$@"; stage=$2; shift 2 ;;
      --brief) need_value "$@"; brief=$2; shift 2 ;;
      --input) need_value "$@"; input=$2; shift 2 ;;
      --run) need_value "$@"; run_id=$2; shift 2 ;;
      --run-dir) need_value "$@"; run_dir=$2; shift 2 ;;
      --parent-worktree) need_value "$@"; parent_worktree=$2; shift 2 ;;
      --base-branch) need_value "$@"; base_branch=$2; shift 2 ;;
      --repo) need_value "$@"; repo_arg=$2; shift 2 ;;
      --ticket) need_value "$@"; ticket=$2; shift 2 ;;
      --role) need_value "$@"; role=$2; shift 2 ;;
      --mcp-config) need_value "$@"; mcp_config=$2; shift 2 ;;
      --attempt) need_value "$@"; attempt=$2; shift 2 ;;
      --start-timeout-ms) need_value "$@"; start_timeout_ms=$2; shift 2 ;;
      --kind) need_value "$@"; kind=$2; kind_given=1; shift 2 ;;
      --out) need_value "$@"; out=$2; shift 2 ;;
      --cwd) need_value "$@"; cwd=$2; cwd_given=1; shift 2 ;;
      --timeout) need_value "$@"; timeout=$2; shift 2 ;;
      --mcp) need_value "$@"; mcp_args+=("--mcp" "$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  [ -n "$stage" ] || usage_error 'dispatch needs --stage (implementation, research, review or diagnosis)'
  [ -n "$run_dir" ] || usage_error 'dispatch needs --run-dir (the Spec run directory)'
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || usage_error "--attempt must be a positive integer, got [$attempt]"
  [ -z "$ticket" ] || [[ "$ticket" =~ ^[1-9][0-9]*$ ]] ||
    usage_error "--ticket must be a ticket number, got [$ticket]"
  [ -z "$timeout" ] || [[ "$timeout" =~ ^[1-9][0-9]*$ ]] ||
    usage_error "--timeout must be a positive integer number of seconds, got [$timeout]"
  case "$stage" in
    implementation)
      [ -n "$brief" ] || usage_error 'an implementation dispatch needs --brief'
      [ -n "$run_id" ] || usage_error "an implementation dispatch needs --run (the Spec's Orca Run id)"
      [ -n "$parent_worktree" ] || usage_error 'an implementation dispatch needs --parent-worktree (the Spec worktree)'
      [ -n "$base_branch" ] || usage_error 'an implementation dispatch needs --base-branch (the Integration branch, spec-<n>)'
      [[ "$base_branch" =~ ^spec-[1-9][0-9]*$ ]] ||
        usage_error "--base-branch must be the Integration branch spec-<n>, got [$base_branch]"
      case "$role" in
        implement|merge) [ -n "$ticket" ] || usage_error "a $role dispatch needs --ticket" ;;
        fix) ;;
        *) usage_error "--role must be implement, fix or merge, got [$role]" ;;
      esac
      [[ "$start_timeout_ms" =~ ^[1-9][0-9]*$ ]] ||
        usage_error "--start-timeout-ms must be a positive integer of milliseconds, got [$start_timeout_ms]"
      [ -z "$input" ] && [ "$kind_given" -eq 0 ] && [ -z "$out" ] && [ -z "$timeout" ] && [ ${#mcp_args[@]} -eq 0 ] &&
        [ "$cwd_given" -eq 0 ] ||
        usage_error "--input, --kind, --out, --cwd, --timeout and --mcp belong to the headless stages"
      [ -z "$mcp_config" ] || [ -f "$mcp_config" ] ||
        usage_error "--mcp-config must be an existing file: $mcp_config"
      ;;
    research)
      [ -n "$brief" ] || usage_error 'a research dispatch needs --brief'
      [ -z "$input" ] && [ "$kind_given" -eq 0 ] && [ -z "$out" ] && [ -z "$timeout" ] && [ -z "$mcp_config" ] &&
        [ -z "$parent_worktree" ] && [ -z "$base_branch" ] && [ -z "$repo_arg" ] && [ "$role" = implement ] ||
        usage_error 'a research dispatch takes --brief, --run-dir, --ticket, --cwd, --mcp, --run and --attempt only'
      ;;
    review)
      [ -n "$input" ] || usage_error 'a review dispatch needs --input (a fixed point for code, a draft file for draft)'
      case "$kind" in code|draft) ;; *) usage_error "--kind must be code or draft, got [$kind]" ;; esac
      [ -z "$brief" ] && [ -z "$mcp_config" ] && [ ${#mcp_args[@]} -eq 0 ] && [ -z "$parent_worktree" ] &&
        [ -z "$base_branch" ] && [ -z "$repo_arg" ] && [ "$role" = implement ] ||
        usage_error 'a review dispatch takes --input, --run-dir, --ticket, --kind, --out, --cwd, --timeout, --run and --attempt only'
      ;;
    diagnosis)
      [ -n "$input" ] || usage_error 'a diagnosis dispatch needs --input (the failure record file)'
      [ -z "$brief" ] && [ "$kind_given" -eq 0 ] && [ -z "$mcp_config" ] && [ ${#mcp_args[@]} -eq 0 ] &&
        [ -z "$parent_worktree" ] && [ -z "$base_branch" ] && [ -z "$repo_arg" ] && [ "$role" = implement ] ||
        usage_error 'a diagnosis dispatch takes --input, --run-dir, --ticket, --out, --cwd, --timeout, --run and --attempt only'
      ;;
    *) usage_error "--stage must be implementation, research, review or diagnosis, got [$stage]" ;;
  esac
  if [ -n "$brief" ] && [ ! -f "$brief" ]; then usage_error "--brief must be an existing file: $brief"; fi
  if [ -n "$input" ] && [ "$kind" != code ] && [ ! -f "$input" ]; then
    usage_error "--input must be an existing file for --kind $kind: $input"
  fi
  [ -d "$cwd" ] || usage_error "--cwd must be an existing directory: $cwd"
  cwd=$(cd -P "$cwd" && pwd) || usage_error "--cwd is not readable: $cwd"
  # Paths that travel into another directory are made absolute here.
  [ -z "$brief" ] || brief=$(absolute_path "$brief")
  if [ -n "$input" ] && [ "$kind" != code ]; then input=$(absolute_path "$input"); fi
  [ -z "$mcp_config" ] || mcp_config=$(absolute_path "$mcp_config")
  [ -z "$out" ] || [[ "$out" = /* ]] || out=$PWD/$out
  [[ "$LEAN_RULES" = /* ]] || LEAN_RULES=$PWD/$LEAN_RULES

  # The Spec worktree and, for the repository Orca names, the main checkout it
  # belongs to (the way launch-wave names it), unless the caller names one.
  local repo=
  if [ "$stage" = implementation ]; then
    parent_worktree=$(cd -P "$parent_worktree" 2>/dev/null && pwd) ||
      usage_error "--parent-worktree is not a directory: $parent_worktree"
    git -C "$parent_worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      usage_error "--parent-worktree must be a git worktree: $parent_worktree"
    if [ -n "$repo_arg" ]; then
      repo=$(cd -P "$repo_arg" 2>/dev/null && pwd) || usage_error "--repo is not a directory: $repo_arg"
    else
      repo=$(git -C "$parent_worktree" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
      [ -n "$repo" ] || usage_error "could not find the main checkout of $parent_worktree; pass --repo <path>"
    fi
    # The Ticket branch is based on the Integration branch, which must be
    # there; a fix or merge role works on it, so the Spec worktree must have
    # it checked out.
    git -C "$parent_worktree" rev-parse --verify --quiet "$base_branch^{commit}" >/dev/null 2>&1 ||
      usage_error "the Integration branch $base_branch does not exist in $repo"
    if [ "$role" != implement ]; then
      local on_branch=
      on_branch=$(git -C "$parent_worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || on_branch=
      [ "$on_branch" = "$base_branch" ] ||
        usage_error "a $role dispatch works in the Spec worktree on the Integration branch, but $parent_worktree is on '${on_branch:-no branch}', not $base_branch"
    fi
    # Everything a dispatch writes must outlive the worktree, which release
    # removes: a run directory inside the Spec worktree is a usage error
    # (spec #26, User Story 22). Compared on physical paths as far as they
    # exist, so a relative path or a directory not created yet is judged too.
    if inside_dir "$run_dir" "$parent_worktree"; then
      usage_error "--run-dir must be outside the Spec worktree, but $run_dir is inside $parent_worktree: release removes the worktree, and with it every sidecar and report written under it"
    fi
  fi

  # A directory that cannot be made is no misuse of the command line: exit 6,
  # as for a missing launcher, and nothing starts.
  mkdir -p "$run_dir" || die 6 "could not create the run directory: $run_dir"
  run_dir=$(cd -P "$run_dir" && pwd) || die 6 "could not resolve the run directory: $run_dir"

  # The dispatch's name: its role and, when there is one, its ticket.
  local role_name=$role
  [ "$stage" = implementation ] || role_name=$stage
  local name=$role_name
  [ -z "$ticket" ] || name="$name-$ticket"
  [ "$attempt" -eq 1 ] || name="$name-$attempt"
  local dispatch_dir=$run_dir/$name sidecar=$run_dir/dispatch-$name.json
  [ ! -e "$sidecar" ] ||
    usage_error "a dispatch named $name already has a sidecar ($sidecar); a re-brief takes --attempt <n> and never overwrites it"
  mkdir -p "$dispatch_dir" || die 6 "could not create the dispatch directory: $dispatch_dir"

  local form=interactive
  [ "$stage" = implementation ] || form=headless
  read_route "$stage" "$form"
  printf 'stage-dispatch: 本次派发路由：%s：%s / %s / %s（用户用 /grill-router 设置）\n' \
    "$(stage_label "$stage")" "$ROUTE_PROFILE" "$ROUTE_MODEL" "$ROUTE_EFFORT" >&2

  # The sidecar as far as it is known before anything starts.
  json_set "$sidecar" "version=1" "stage=$stage" "role=$role_name" "ticket=@json:${ticket:-null}" \
    "attempt=$attempt" "run_id=$run_id" "run_dir=$run_dir" "form=$form" "dispatch_dir=$dispatch_dir" \
    "route=@json:{\"profile\":\"$ROUTE_PROFILE\",\"model\":\"$ROUTE_MODEL\",\"effort\":\"$ROUTE_EFFORT\"}" \
    "started_at=$(now_iso)" ||
    die 6 "could not write the sidecar $sidecar"

  if [ "$form" = headless ]; then
    run_headless "$stage" "$sidecar" "$dispatch_dir" "$brief" "$input" "$kind" "$out" "$cwd" "$timeout" \
      ${mcp_args[@]+"${mcp_args[@]}"}
    return $?
  fi
  run_interactive "$sidecar" "$dispatch_dir" "$brief" "$run_id" "$parent_worktree" "$repo" \
    "$base_branch" "$ticket" "$role" "$mcp_config" "$start_timeout_ms"
}

# --- interactive: child worktree, terminal, adoption -------------------------------

run_interactive() { # sidecar dispatch_dir brief run_id parent_worktree repo base_branch ticket role mcp_config start_timeout_ms
  local sidecar=$1 dispatch_dir=$2 brief=$3 run_id=$4 parent_worktree=$5 repo=$6
  local base_branch=$7 ticket=$8 role=$9 mcp_config=${10} start_timeout_ms=${11}
  local launcher=${LAUNCH_ARGS[0]:-} spec_n=${base_branch#spec-}
  local worktree= branch= worktree_created=0 title= report=$dispatch_dir/report.md spec_file=$dispatch_dir/spec.md
  local create_json= launch_json= worker_start_json= terminal= dispatch_id= task_id=
  local permission_args lean_args=() bare=0 bare_note= launch_command=

  # Only the claude profiles open an interactive session this module can adopt;
  # the launcher is the profile's own.
  case "$ROUTE_PROFILE" in
    claude|claude-glm|claude-flash) ;;
    *)
      die 64 "the implementation route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, and the profile '$ROUTE_PROFILE' cannot run an interactive worker: codex-glm runs headless through scripts/codex-worker.sh; route implementation to a claude profile with /grill-router"
      ;;
  esac
  command -v "$launcher" >/dev/null 2>&1 ||
    die 6 "the implementation route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, but its launcher '$launcher' was not found in PATH"

  # The lean start (精简启动) is the default for the implement and fix roles:
  # with a rules file they start bare; without one it is a normal start, and
  # the sidecar says why. ISS_DISPATCH_BARE is the opt-out (0, off, no,
  # false). The merge role never starts lean (the header says why), whatever
  # the switch and the rules file, and its bare_note names the role, not a
  # missing file or the switch, as the reason.
  if [ "$role" = merge ]; then
    bare_note='the merge role starts normally whatever ISS_DISPATCH_BARE and the rules file: it resolves conflicts on the Integration branch, where CLAUDE.md and the hooks must stay loaded'
  else
    case "$(printf '%s' "${ISS_DISPATCH_BARE:-}" | tr '[:upper:]' '[:lower:]')" in
      0|off|no|false)
        bare_note="ISS_DISPATCH_BARE=${ISS_DISPATCH_BARE} turns the lean start off: a normal one"
        ;;
      *)
        if [ -f "$LEAN_RULES" ]; then
          bare=1
          bare_note="lean start, --bare with the rules in $LEAN_RULES"
          lean_args=(--bare --append-system-prompt-file "$LEAN_RULES")
        else
          bare_note="the lean rules file was not found ($LEAN_RULES): no lean start, a normal one"
        fi
        ;;
    esac
  fi
  [ -z "$mcp_config" ] || lean_args+=(--mcp-config "$mcp_config")
  json_set "$sidecar" "launcher=$launcher" "bare=@json:$(true_false "$bare")" "bare_note=$bare_note" \
    "brief=$brief" "repo=$repo" "parent_worktree=$parent_worktree" "base_branch=$base_branch" ||
    die 6 "could not write the sidecar $sidecar"

  # The implement role gets a child worktree off the Integration branch; fix and
  # merge roles work in the Spec worktree itself.
  case "$role" in
    implement)
      branch=spec-$spec_n-t$ticket
      create_json=$(orca_worktree_create_child "$repo" "$branch" "$branch" "$base_branch" "$ticket" "$parent_worktree" \
        2>"$dispatch_dir/worktree-create.err") ||
        die 6 "orca worktree create failed for $branch under $parent_worktree: $(cat "$dispatch_dir/worktree-create.err") (sidecar: $sidecar)"
      printf '%s\n' "$create_json" > "$dispatch_dir/worktree-create.json"
      worktree=$(json_get "$dispatch_dir/worktree-create.json" result.worktree.path) ||
        die 6 "orca worktree create returned no worktree path (sidecar: $sidecar)"
      [ ! -d "$worktree" ] || worktree=$(cd -P "$worktree" && pwd)
      worktree_created=1
      title="spec-$spec_n t$ticket"
      ;;
    merge)
      worktree=$parent_worktree
      branch=$base_branch
      title="spec-$spec_n merge t$ticket"
      ;;
    fix)
      worktree=$parent_worktree
      branch=$base_branch
      title="spec-$spec_n fix"
      ;;
  esac
  json_set "$sidecar" "worktree=$worktree" "worktree_created=@json:$(true_false "$worktree_created")" \
    "branch=$branch" "report_path=$report" "spec_file=$spec_file" ||
    die 6 "could not write the sidecar $sidecar"

  # The Task: where the worker works and how it reports, then the Brief.
  {
    printf '你是一个实现类 worker（%s），由规格会话按「实现」路由经 Orca 派发，在下面的工作区里完成 Brief 交给你的事。\n\n' "$role"
    printf '工作区：%s（分支 %s）\n' "$worktree" "$branch"
    printf '运行目录：%s\n' "$dispatch_dir"
    printf '报告路径：%s\n\n' "$report"
    printf '%s\n' '约定：'
    printf '%s\n' '1. 只做 Brief 范围内的事；范围外的问题写进报告，不要顺手改。'
    printf '%s\n' '2. 报告写在上面的报告路径（工作区之外，删工作区不丢），内容按 Brief 的「报告要求」。'
    printf '%s\n' '3. 最后按 Orca 前言给的完整命令上报 worker_done：必须带 --task-id，--outcome succeeded（没完成就 failed），--report-path 指向上面的报告路径。发送后本会话会被关闭，发送就是最后一步。'
    printf '%s\n\n' '4. 不要再派发任何 worker 或子代理，不要启动另一个 claude / codex 进程；必须等待时在前台等够。'
    printf '%s\n' '--- Brief ---'
    cat "$brief"
  } > "$spec_file" || die 6 "could not write the Task to $spec_file"

  # The terminal runs the route's launcher and records its exit code. Each
  # argument is quoted for the terminal's shell (the GLM launchers' model ends
  # in [1m], a glob character). The Task is delivered by worker-start below.
  permission_args=(--dangerously-skip-permissions)
  launch_command="$(printf ' %q' "${LAUNCH_ARGS[0]}" "${permission_args[@]}" "${LAUNCH_ARGS[@]:1}" ${lean_args[@]+"${lean_args[@]}"})"
  launch_command="${launch_command# }; echo \$? > $(printf '%q' "$dispatch_dir/exit-code")"
  launch_json=$(orca_terminal_create "$worktree" "$title" "$launch_command" 2>"$dispatch_dir/terminal-create.err") ||
    die 6 "orca terminal create failed in $worktree: $(cat "$dispatch_dir/terminal-create.err") (sidecar: $sidecar)"
  printf '%s\n' "$launch_json" > "$dispatch_dir/terminal-create.json"
  terminal=$(json_get "$dispatch_dir/terminal-create.json" result.terminal.handle result.outcome.handle)
  case $? in
    0) ;;
    2) die 6 "orca terminal create JSON could not be parsed (sidecar: $sidecar)" ;;
    *) die 6 "orca terminal create returned no terminal handle (sidecar: $sidecar)" ;;
  esac
  json_set "$sidecar" "terminal=$terminal" "launch_command=$launch_command" || die 6 "could not write the sidecar $sidecar"

  worker_start_json=$(orca_orchestration_worker_start "$run_id" --terminal "$terminal" \
    --spec-file "$spec_file" --timeout-ms "$start_timeout_ms" 2>"$dispatch_dir/worker-start.err") ||
    die 6 "orca orchestration worker-start failed for terminal $terminal (close it by hand if the launcher is still running there): $(cat "$dispatch_dir/worker-start.err") (sidecar: $sidecar)"
  printf '%s\n' "$worker_start_json" > "$dispatch_dir/worker-start.json"
  dispatch_id=$(json_get "$dispatch_dir/worker-start.json" result.dispatchId) ||
    die 6 "orca orchestration worker-start returned no dispatch id (terminal $terminal; sidecar: $sidecar)"
  task_id=$(json_get "$dispatch_dir/worker-start.json" result.taskId) || task_id=
  json_set "$sidecar" "dispatch_id=$dispatch_id" "task_id=$task_id" || die 6 "could not write the sidecar $sidecar"

  printf '%s\n' "$sidecar"
  return 0
}

# --- headless: the executors that read the table themselves -------------------------

run_headless() { # stage sidecar dispatch_dir brief input kind out cwd timeout [--mcp <names|all>]...
  # Everything the executor needs comes in as an argument, the MCP selection
  # of a research dispatch included; nothing is read from the caller's scope.
  local stage=$1 sidecar=$2 dispatch_dir=$3 brief=$4 input=$5 kind=$6 out=$7 cwd=$8 timeout=$9
  local script= report= exit_code= timeout_args=() mcp_args=("${@:10}")
  [ -z "$timeout" ] || timeout_args=(--timeout "$timeout")
  case "$stage" in
    research)
      script=${STAGE_DISPATCH_CODEX_WORKER:-$HERE/codex-worker.sh}
      [ -x "$script" ] || die 6 "the $stage executor was not found: $script"
      json_set "$sidecar" "script=$script" "brief=$brief" "cwd=$cwd" ||
        die 6 "could not write the sidecar $sidecar"
      ( cd "$cwd" && exec "$script" --cwd "$cwd" --brief "$brief" --run-dir "$dispatch_dir" --read-only ${mcp_args[@]+"${mcp_args[@]}"} )
      exit_code=$?
      ;;
    review|diagnosis)
      script=${STAGE_DISPATCH_OPUS_REVIEW:-$HERE/opus-review.sh}
      [ -x "$script" ] || die 6 "the $stage executor was not found: $script"
      [ "$stage" = review ] || kind=diagnose
      [ -n "$out" ] || out=$dispatch_dir/findings.md
      json_set "$sidecar" "script=$script" "input=$input" "kind=$kind" "cwd=$cwd" "report_path=$out" ||
        die 6 "could not write the sidecar $sidecar"
      ( cd "$cwd" && exec "$script" --kind "$kind" --input "$input" --out "$out" --cwd "$cwd" ${timeout_args[@]+"${timeout_args[@]}"} )
      exit_code=$?
      ;;
  esac
  # The report path passes through: what the executor wrote, where it said.
  case "$stage" in
    research)
      report=$(json_get "$dispatch_dir/status.json" result_file 2>/dev/null) || report=
      [ -n "$report" ] || [ ! -f "$dispatch_dir/result.md" ] || report=$dispatch_dir/result.md
      ;;
    *) report=$out ;;
  esac
  [ -z "$report" ] || [ -f "$report" ] || report=
  json_set "$sidecar" "exit_code=@json:$exit_code" "report_path=$report" "finished_at=$(now_iso)" ||
    die 6 "could not write the sidecar $sidecar"
  [ -z "$report" ] || printf '%s\n' "$report"
  return "$exit_code"
}

# --- wait -------------------------------------------------------------------------

cmd_wait() {
  local sidecar= timeout=$WAIT_TIMEOUT_SECONDS_DEFAULT
  while [ $# -gt 0 ]; do
    case "$1" in
      --sidecar) need_value "$@"; sidecar=$2; shift 2 ;;
      --timeout) need_value "$@"; timeout=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  [ -n "$sidecar" ] || usage_error 'wait needs --sidecar (the path dispatch printed)'
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] ||
    usage_error "--timeout must be a positive integer number of seconds, got [$timeout]"
  [ -f "$sidecar" ] || usage_error "sidecar not found: $sidecar"
  local run_id dispatch_id dispatch_dir run_dir form report timed_out
  form=$(json_get "$sidecar" form) ||
    die 64 "$sidecar is not a dispatch sidecar (no form field, or not JSON)"
  [ "$form" = interactive ] ||
    usage_error "nothing to wait for: the dispatch in $sidecar is $form, not an adopted worker"
  run_id=$(json_get "$sidecar" run_id) || die 64 "sidecar $sidecar has no run_id"
  dispatch_id=$(json_get "$sidecar" dispatch_id) ||
    die 64 "sidecar $sidecar has no dispatch_id: the dispatch did not complete (see its dispatch dir)"
  dispatch_dir=$(json_get "$sidecar" dispatch_dir) || die 64 "sidecar $sidecar has no dispatch_dir"
  run_dir=$(json_get "$sidecar" run_dir) || die 64 "sidecar $sidecar has no run_dir"

  # A worker_done taken by an earlier wait on another dispatch of this Run is
  # already in the sidecar; the record is authoritative.
  report=$(json_get "$sidecar" worker_done.report_path) || report=
  if [ -n "$report" ]; then
    printf '%s\n' "$report"
    return 0
  fi

  # One blocking check, consuming: the batch is kept whole in wait.json.
  local timeout_ms=$((timeout * 1000)) recorded others
  orca_orchestration_check "$run_id" --take --types worker_done --timeout-ms "$timeout_ms" \
    > "$dispatch_dir/wait.json" 2> "$dispatch_dir/wait.err" ||
    die 6 "orca orchestration check failed for run $run_id: $(cat "$dispatch_dir/wait.err")"
  recorded=$(record_worker_done "$dispatch_dir/wait.json" "$run_dir") ||
    die 6 "orca orchestration check returned JSON that could not be read: $dispatch_dir/wait.json"
  # --types narrows what wakes the wait, not what the batch holds: mail of
  # this Run that is no worker_done (another Ticket's worker asking its Spec
  # session, say) was taken by the same check and is now in no mailbox but
  # wait.json. It goes to the caller on stdout, one line of JSON each, with
  # exit 8, before anything else is reported: a worker waiting for an answer
  # must not wait unseen. The worker_done of this batch is recorded all the
  # same; the caller handles the mail and waits again.
  others=$(printf '%s\n' "$recorded" | sed -n 's/^other //p')
  printf '%s\n' "$recorded" | while IFS= read -r line; do
    # The empty line of an empty batch (a timeout) is nothing to warn about.
    case "$line" in
      ''|recorded\ *|other\ *) ;;
      *) warn "the check took mail this wait was not waiting for: $line (kept in $dispatch_dir/wait.json)" ;;
    esac
  done
  if [ -n "$others" ]; then
    printf '%s\n' "$others"
    die 8 "the wait for dispatch ${dispatch_id} took mail of run ${run_id} that is no worker_done (each message printed on stdout; the batch is kept in ${dispatch_dir}/wait.json): handle it, then wait again"
  fi

  report=$(json_get "$sidecar" worker_done.report_path) || report=
  if [ -n "$report" ]; then
    # The worker reports after writing; a path to nowhere is its error, not a
    # report the caller can act on.
    [ -f "$report" ] ||
      die 6 "worker_done for ${dispatch_id} names a report that is not on disk: $report (the message is kept in $dispatch_dir/wait.json)"
    printf '%s\n' "$report"
    return 0
  fi
  timed_out=$(node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(2); }
    process.stdout.write(root.result?.timedOut === true ? "1" : "0");
  ' "$dispatch_dir/wait.json") || die 6 "orca orchestration check returned JSON that could not be read: $dispatch_dir/wait.json"
  if [ "$timed_out" = 1 ]; then
    die 5 "等待 ${dispatch_id} 的 worker_done 超时（${timeout} 秒）；由调用方决定再等一次还是按判活处理"
  fi
  die 7 "the wait for dispatch ${dispatch_id} returned on another dispatch's worker_done ($(printf '%s' "$recorded" | tr '\n' ';')); this one's is still to come: wait again"
}

# Records every worker_done in the taken batch in the sidecar of its dispatch
# (the run dir's dispatch-*.json whose dispatch_id matches); prints one line
# per message: "recorded <dispatch id> <sidecar>", "unknown <dispatch id>", or
# "other <the message as JSON>" for mail that is no worker_done, as Orca gave
# it.
record_worker_done() { # wait_json run_dir
  node -e '
    const fs = require("fs"), path = require("path");
    const [waitJson, runDir] = process.argv.slice(1);
    let root;
    try { root = JSON.parse(fs.readFileSync(waitJson, "utf8")); } catch { process.exit(2); }
    const messages = root.result?.messages ?? root.messages ?? [];
    const sidecars = [];
    for (const name of fs.readdirSync(runDir)) {
      if (!/^dispatch-.*\.json$/.test(name)) continue;
      const file = path.join(runDir, name);
      try {
        const value = JSON.parse(fs.readFileSync(file, "utf8"));
        if (value.dispatch_id) sidecars.push({file, value});
      } catch { /* not JSON: no sidecar of this module; every write here is atomic */ }
    }
    const received = new Date().toISOString();
    for (const message of messages) {
      let payload = message.payload;
      if (typeof payload === "string") { try { payload = JSON.parse(payload); } catch { payload = {}; } }
      payload = payload ?? {};
      const type = message.type ?? payload.type;
      const isDone = type === "worker_done" || (!type && payload.dispatchId && payload.outcome);
      if (!isDone) { process.stdout.write(`other ${JSON.stringify(message)}\n`); continue; }
      const dispatchId = String(payload.dispatchId ?? message.dispatchId ?? "");
      const match = sidecars.find((item) => String(item.value.dispatch_id) === dispatchId);
      if (!match) {
        process.stdout.write(`unknown ${dispatchId || "(no dispatch id)"}\n`);
        continue;
      }
      // A worker may report its path relative to its worktree; resolve it.
      let reportPath = String(payload.reportPath ?? payload.report_path ?? "");
      if (reportPath && !path.isAbsolute(reportPath) && match.value.worktree) {
        reportPath = path.join(match.value.worktree, reportPath);
      }
      match.value.worker_done = {
        outcome: String(payload.outcome ?? ""),
        report_path: reportPath,
        message_id: String(message.id ?? message.messageId ?? ""),
        received_at: received,
      };
      // The same atomic write as json_set: a reader never sees half a sidecar.
      const tmp = match.file + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(match.value, null, 2) + "\n");
      fs.renameSync(tmp, match.file);
      process.stdout.write(`recorded ${dispatchId} ${match.file}\n`);
    }
  ' "$@" || return $?
}

# --- release ----------------------------------------------------------------------

cmd_release() {
  local sidecar=
  while [ $# -gt 0 ]; do
    case "$1" in
      --sidecar) need_value "$@"; sidecar=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  [ -n "$sidecar" ] || usage_error 'release needs --sidecar (the path dispatch printed)'
  [ -f "$sidecar" ] || usage_error "sidecar not found: $sidecar"
  local form dispatch_id terminal worktree worktree_created report dispatch_dir state stage kept
  form=$(json_get "$sidecar" form) || die 64 "$sidecar is not a dispatch sidecar (no form field, or not JSON)"
  if [ "$form" = headless ]; then
    warn "nothing to release: the dispatch in $sidecar ran headless and holds no Orca resource"
    return 0
  fi
  dispatch_id=$(json_get "$sidecar" dispatch_id) ||
    die 64 "sidecar $sidecar has no dispatch_id: the dispatch did not complete (see its dispatch dir)"
  terminal=$(json_get "$sidecar" terminal) || terminal=
  worktree=$(json_get "$sidecar" worktree) || worktree=
  worktree_created=$(json_get "$sidecar" worktree_created) || worktree_created=false
  dispatch_dir=$(json_get "$sidecar" dispatch_dir) || dispatch_dir=.

  # Nothing is released while the worker may still be writing its report.
  report=$(json_get "$sidecar" worker_done.report_path) || report=
  [ -n "$report" ] ||
    die 2 "release refused: dispatch $dispatch_id has no worker_done recorded in $sidecar (wait for it first); a worker that is not done is not released"
  [ -f "$report" ] ||
    die 2 "release refused: the report of dispatch $dispatch_id is not on disk ($report); release only once the report has landed"
  orca_orchestration_worker_show "$dispatch_id" > "$dispatch_dir/worker-show.json" 2> "$dispatch_dir/worker-show.err" ||
    die 6 "orca orchestration worker-show failed for $dispatch_id: $(cat "$dispatch_dir/worker-show.err")"
  state=$(json_get "$dispatch_dir/worker-show.json" result.state) || state=
  stage=$(json_get "$dispatch_dir/worker-show.json" result.stage) || stage=
  case "$stage $state" in
    *settled*|*succeeded*|*failed*) ;;
    *)
      die 2 "release refused: dispatch $dispatch_id is not ended (state=${state:-unknown}, stage=${stage:-unknown}); release only a settled worker"
      ;;
  esac

  # A report the worker wrote inside the child worktree (a relative path is
  # resolved against it) would go with the worktree: copied into the dispatch
  # dir before anything is released, and the sidecar points at the copy from
  # then on, so a release tried again finds it there. Only the worktree that is
  # about to be removed is worth copying out of.
  if [ "$worktree_created" = true ] && [ -n "$worktree" ] && inside_dir "$report" "$worktree"; then
    kept=$dispatch_dir/report-from-worktree.md
    cp -p -- "$report" "$kept" 2> "$dispatch_dir/report-copy.err" ||
      die 6 "release refused: the report of dispatch $dispatch_id lies inside the worktree $worktree and could not be copied to $kept: $(cat "$dispatch_dir/report-copy.err"); nothing was released"
    json_set "$sidecar" "worker_done.report_path=$kept" || die 6 "could not write the sidecar $sidecar"
  fi

  orca_orchestration_worker_release "$dispatch_id" > "$dispatch_dir/worker-release.json" 2> "$dispatch_dir/worker-release.err" ||
    die 6 "orca orchestration worker-release failed for $dispatch_id: $(cat "$dispatch_dir/worker-release.err")"
  # Orca retains a terminal this module opened: close it here.
  if [ -n "$terminal" ]; then
    orca_terminal_close "$terminal" > "$dispatch_dir/terminal-close.out" 2>&1 ||
      warn "could not close terminal $terminal (close it by hand): $(cat "$dispatch_dir/terminal-close.out")"
  fi
  local removed='worktree kept'
  if [ "$worktree_created" = true ] && [ -n "$worktree" ]; then
    orca_worktree_rm "$worktree" > "$dispatch_dir/worktree-rm.json" 2> "$dispatch_dir/worktree-rm.err" ||
      die 6 "orca worktree rm failed for $worktree: $(cat "$dispatch_dir/worktree-rm.err")"
    removed="$worktree removed"
  fi
  json_set "$sidecar" "released_at=$(now_iso)" || die 6 "could not write the sidecar $sidecar"
  printf 'released %s (%s)\n' "$dispatch_id" "$removed"
  return 0
}

# --- entry ------------------------------------------------------------------------

[ $# -gt 0 ] || { usage >&2; exit 64; }
for argument in "$@"; do
  case "$argument" in
    -h|--help) usage; exit 0 ;;
  esac
done

SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  dispatch) cmd_dispatch "$@" ;;
  wait) cmd_wait "$@" ;;
  release) cmd_release "$@" ;;
  *) usage_error "unknown subcommand: $SUBCOMMAND (dispatch, wait or release)" ;;
esac
