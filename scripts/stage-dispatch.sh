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
#   stage-dispatch.sh verify --run-dir <dir>
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
# verify, for the reports (票 #47): Orca records no model for an adopted
# terminal (the Dispatch's launch.effective.model is null,
# docs/orca-smoke-2026-11-27.md 2.1), so the model a worker actually ran on is
# read off its TUI. verify prints, for the Run whose run directory it is
# given, the Stage route table as the table's display command shows it now
# (the six stages) and then one line per Orca worker this Run dispatched,
# `<role> #<ticket> → <route model> / <actual model> / <verdict>`: 一致 when
# the two are the same model (the GLM launchers' [1m] suffix aside, which the
# status line shows and the route does not), 警告 when they differ, 无法核对
# with the reason when no model could be read. The reading is taken from the
# worker's terminal status line (`terminal read --screen`: Claude Code's
# `[<model>] │ <dir> …` line) and, when the screen has none, from the provider
# of its full worker-show record (projection.provider, what Orca read off the
# TUI), and is recorded in the sidecar as actual_model {model, source,
# checked_at} — {model: null, note, checked_at} when neither named one. The
# record is what the reports read, and it can only be taken while the
# terminal exists: once the TUI left, the screen shows the shell, and once
# the terminal is closed the read comes back empty and Orca's provider with
# it (docs/orca-smoke-2026-11-27.md 6.1). So release takes the reading before
# it releases anything, and verify takes one live only for a dispatch that
# holds its terminal still (a worker that is running, say a parked Ticket's);
# a released dispatch is read from its record, and one without a record says
# 无法核对. Headless dispatches are not checked here: their route is on the
# first line of their own result (the executor's 路由 line). A 警告 is a
# warning on the line and on stderr and nothing else: verify exits 0 whatever
# the verdicts, release releases a mismatching worker all the same, and no
# report is held back by one. The effort is not verified: no status line
# carries it. The check lines are in dispatch order, by each sidecar's
# started_at; a sidecar without one is checked all the same and listed first.
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
# after a reading: actual_model (see verify); after a release: released_at
# (and worker_done.report_path naming the copy, when the report had to be
# taken out of the worktree). A sidecar without dispatch_id is a dispatch that
# did not complete; it names whatever was created so the caller can clean up.
#
# What a refused dispatch leaves behind depends on how far it got. The checks
# that create nothing -- bad usage, a route that cannot be read, an
# implementation route whose profile cannot run an interactive worker (64) or
# whose launcher is not in PATH (6), a run directory or dispatch directory
# that cannot be made (6) -- all run before the sidecar is written, so after
# them nothing is left behind and the same name dispatches again as soon as
# the route or PATH is fixed. From the sidecar on, every failure keeps it, so
# what it names is cleaned up by hand (above) and the re-brief takes
# --attempt 2.
#
# Exit codes:
#   0  dispatched (stdout: the sidecar path); worker_done received (stdout:
#      the report path); released; verified (stdout: the route table and the
#      check lines), whatever the verdicts; a headless executor exited 0
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
#   64 bad usage, among it a route that cannot be read, a --run-dir inside
#      the Spec worktree and a verify run directory that is not there:
#      nothing starts
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
       stage-dispatch.sh verify --run-dir <dir>

dispatch starts one Stage on its route from the Stage route table and prints
         the sidecar path (interactive), or runs the headless executor and
         prints its report path.
wait     blocks once for the dispatch's worker_done; prints the report path.
release  worker-release, terminal close, worktree rm, once the worker is done.
verify   prints the Stage route table and, per Orca worker of the Run's run
         directory, its route model against the model it actually ran on
         (read off its terminal, recorded in the sidecar); warns, never fails.
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
# the file and every object on a dotted path; a VALUE is stored as the string
# it is, or as JSON when written as @json:<json>. A field of an object is set
# by its dotted key (route.model=glm-5.4), so a value with a quote or a
# backslash in it stays a string: @json: is for fixed literals only (null,
# true, a number), never for JSON with a value spliced in by hand, which one
# quote in the value would break. The write is atomic.
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

  local form=interactive
  [ "$stage" = implementation ] || form=headless
  read_route "$stage" "$form"
  printf 'stage-dispatch: 本次派发路由：%s：%s / %s / %s（用户用 /grill-router 设置）\n' \
    "$(stage_label "$stage")" "$ROUTE_PROFILE" "$ROUTE_MODEL" "$ROUTE_EFFORT" >&2

  # The checks that create nothing run before the dispatch directory and the
  # sidecar exist (the header says why): a dispatch refused here leaves nothing
  # behind, so the same name dispatches again once the route or PATH is fixed.
  if [ "$form" = interactive ]; then
    check_interactive_launcher
  fi
  mkdir -p "$dispatch_dir" || die 6 "could not create the dispatch directory: $dispatch_dir"

  # The sidecar as far as it is known before anything starts.
  json_set "$sidecar" "version=1" "stage=$stage" "role=$role_name" "ticket=@json:${ticket:-null}" \
    "attempt=$attempt" "run_id=$run_id" "run_dir=$run_dir" "form=$form" "dispatch_dir=$dispatch_dir" \
    "route.profile=$ROUTE_PROFILE" "route.model=$ROUTE_MODEL" "route.effort=$ROUTE_EFFORT" \
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

# The two checks an interactive dispatch can be refused by before anything is
# made: only the claude profiles open an interactive session this module can
# adopt (the launcher is the profile's own), and that launcher must be in
# PATH. cmd_dispatch runs this before the sidecar exists, so neither refusal
# leaves one behind.
check_interactive_launcher() {
  local launcher=${LAUNCH_ARGS[0]:-}
  case "$ROUTE_PROFILE" in
    claude|claude-glm|claude-flash) ;;
    *)
      die 64 "the implementation route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, and the profile '$ROUTE_PROFILE' cannot run an interactive worker: codex-glm runs headless through scripts/codex-worker.sh; route implementation to a claude profile with /grill-router"
      ;;
  esac
  command -v "$launcher" >/dev/null 2>&1 ||
    die 6 "the implementation route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, but its launcher '$launcher' was not found in PATH"
}

run_interactive() { # sidecar dispatch_dir brief run_id parent_worktree repo base_branch ticket role mcp_config start_timeout_ms
  local sidecar=$1 dispatch_dir=$2 brief=$3 run_id=$4 parent_worktree=$5 repo=$6
  local base_branch=$7 ticket=$8 role=$9 mcp_config=${10} start_timeout_ms=${11}
  local launcher=${LAUNCH_ARGS[0]:-} spec_n=${base_branch#spec-}
  local worktree= branch= worktree_created=0 title= report=$dispatch_dir/report.md spec_file=$dispatch_dir/spec.md
  local create_json= launch_json= worker_start_json= terminal= dispatch_id= task_id=
  local permission_args lean_args=() bare=0 bare_note= launch_command=

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

  # The model the worker actually ran on, read while its terminal still
  # exists: the reports take it from the sidecar (verify). A reading that
  # finds nothing is recorded as such; release goes on either way, since a
  # mismatch is a warning a report carries, never a refusal.
  ensure_model_recorded "$sidecar" "$dispatch_dir"

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

# --- verify: the model each worker actually ran on ---------------------------------

# The model a worker's TUI shows in its status line: the last line of the
# rendered screen shaped `[<model>] │ …` (Claude Code's status line, as
# docs/orca-smoke-2026-11-27.md 2.1 and G show it), or nothing when the screen
# has none. The last such line, since the status line sits at the bottom of
# the screen and a worker's own output may quote one.
screen_model() { # terminal read --screen --json on stdin
  node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const terminal = root.result?.terminal ?? root.terminal ?? root;
    const tail = Array.isArray(terminal.tail) ? terminal.tail : String(terminal.tail ?? "").split("\n");
    let model = "";
    for (const line of tail) {
      const match = /^\s*\[(.+?)\]\s*│/.exec(String(line ?? ""));
      if (match) model = match[1];
    }
    process.stdout.write(model);
  '
}

# The model Orca read off the worker's TUI, from the full worker-show record:
# projection.provider.model, or nothing when Orca has none.
provider_model() { # worker-show --full --json on stdin
  node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    const provider = root.result?.projection?.provider ?? root.projection?.provider;
    const model = provider && typeof provider === "object" ? String(provider.model ?? "") : "";
    process.stdout.write(model);
  '
}

# One reading of the model a dispatch's worker actually runs on: the status
# line of its terminal first, then, when the screen has none, the provider of
# its full worker-show record. Sets OBSERVED to "<model><TAB>status-line" or
# "<model><TAB>provider" and returns 0, or leaves it empty, sets OBSERVE_NOTE
# to why, and returns 1 when neither names a model. An Orca that cannot answer
# is a note, never a failure: the reading is for a report. Must be called
# directly, not in $(...): the note would stay in the subshell.
observe_model() { # sidecar dispatch_dir
  local sidecar=$1 dispatch_dir=$2 terminal dispatch_id json model=
  OBSERVED= OBSERVE_NOTE=
  terminal=$(json_get "$sidecar" terminal) || terminal=
  dispatch_id=$(json_get "$sidecar" dispatch_id) || dispatch_id=
  if [ -n "$terminal" ]; then
    if json=$(orca_terminal_read "$terminal" --screen 2>"$dispatch_dir/terminal-read.err"); then
      model=$(printf '%s\n' "$json" | screen_model) || model=
      [ -z "$model" ] || { OBSERVED="$model"$'\t'status-line; return 0; }
    else
      warn "could not read the screen of terminal $terminal: $(head -n 1 "$dispatch_dir/terminal-read.err")"
    fi
  fi
  if [ -n "$dispatch_id" ]; then
    if orca_orchestration_worker_show "$dispatch_id" --full > "$dispatch_dir/worker-show-full.json" \
      2>"$dispatch_dir/worker-show-full.err"; then
      model=$(provider_model < "$dispatch_dir/worker-show-full.json") || model=
      [ -z "$model" ] || { OBSERVED="$model"$'\t'provider; return 0; }
    else
      warn "orca orchestration worker-show --full failed for $dispatch_id: $(head -n 1 "$dispatch_dir/worker-show-full.err")"
    fi
  fi
  OBSERVE_NOTE='没读到终端状态行，worker-show --full 也没有 provider'
  return 1
}

# Records one reading in the sidecar: actual_model {model, source, checked_at}
# when a model was read, {model: null, note, checked_at} when none was. The
# object is emptied first (a fixed literal) and its fields set by their dotted
# keys: the model comes off a screen, so it is stored as the string it is,
# never spliced into @json: (a quote in it would break the sidecar).
record_model() { # sidecar dispatch_dir
  local sidecar=$1 dispatch_dir=$2
  if observe_model "$sidecar" "$dispatch_dir"; then
    json_set "$sidecar" "actual_model=@json:{}" "actual_model.model=${OBSERVED%%$'\t'*}" \
      "actual_model.source=${OBSERVED#*$'\t'}" "actual_model.checked_at=$(now_iso)" ||
      die 6 "could not write the sidecar $sidecar"
  else
    json_set "$sidecar" "actual_model=@json:{}" "actual_model.model=@json:null" "actual_model.note=$OBSERVE_NOTE" \
      "actual_model.checked_at=$(now_iso)" ||
      die 6 "could not write the sidecar $sidecar"
  fi
}

# Takes a reading only when the sidecar has none: a model already recorded
# (read off a TUI that was up at the time) is the better evidence and stays.
ensure_model_recorded() { # sidecar dispatch_dir
  json_get "$1" actual_model.model >/dev/null 2>&1 && return 0
  record_model "$1" "$2"
}

# `<role> #<ticket>（第 <n> 次）` for a check line: implement #41, 修复, 解冲突 #41（第 2 次）.
dispatch_label() { # role ticket attempt
  local label=$1
  case "$1" in
    implement) label=实现 ;;
    fix) label=修复 ;;
    merge) label=解冲突 ;;
  esac
  [ -z "$2" ] || label="$label #$2"
  [ -z "$3" ] || [ "$3" = 1 ] || label="${label}（第 $3 次）"
  printf '%s' "$label"
}

# Prints the check line of one dispatch's sidecar: its route model against the
# model recorded as actually run, read live first when none is recorded and
# the dispatch still holds its terminal.
verify_sidecar() { # sidecar
  local sidecar=$1 form role ticket attempt route_model actual note dispatch_dir label
  form=$(json_get "$sidecar" form) || form=
  # A headless dispatch runs no Orca worker; its route is on its own result's
  # first line.
  [ "$form" = interactive ] || return 0
  role=$(json_get "$sidecar" role) || role=
  ticket=$(json_get "$sidecar" ticket) || ticket=
  attempt=$(json_get "$sidecar" attempt) || attempt=1
  route_model=$(json_get "$sidecar" route.model) || route_model='?'
  label=$(dispatch_label "$role" "$ticket" "$attempt")
  dispatch_dir=$(json_get "$sidecar" dispatch_dir) || dispatch_dir=$(dirname -- "$sidecar")
  if ! json_get "$sidecar" dispatch_id >/dev/null 2>&1; then
    printf '%s → %s / ? / 无法核对：派发没完成\n' "$label" "$route_model"
    return 0
  fi
  actual=$(json_get "$sidecar" actual_model.model) || actual=
  if [ -z "$actual" ]; then
    if json_get "$sidecar" released_at >/dev/null 2>&1; then
      # Released before a reading was taken, or with none found: the terminal
      # is gone, so nothing can be read now.
      note=$(json_get "$sidecar" actual_model.note) || note='释放前没读到'
      printf '%s → %s / ? / 无法核对：%s\n' "$label" "$route_model" "$note"
      return 0
    fi
    ensure_model_recorded "$sidecar" "$dispatch_dir"
    actual=$(json_get "$sidecar" actual_model.model) || actual=
  fi
  if [ -z "$actual" ]; then
    note=$(json_get "$sidecar" actual_model.note) || note='没读到终端状态行'
    printf '%s → %s / ? / 无法核对：%s\n' "$label" "$route_model" "$note"
    return 0
  fi
  # The GLM launchers pass glm-5.4 as glm-5.4[1m]; the status line shows the
  # suffix and the route does not: the same model.
  if [ "${actual%\[1m\]}" = "$route_model" ]; then
    printf '%s → %s / %s / 一致\n' "$label" "$route_model" "$actual"
  else
    printf '%s → %s / %s / 警告：实际模型 %s 与路由 %s 不符\n' "$label" "$route_model" "$actual" "$actual" "$route_model"
    warn "${label} 的实际模型 ${actual} 与路由 ${route_model} 不符（只警告，不拦落地）"
  fi
  return 0
}

cmd_verify() {
  local run_dir=
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) need_value "$@"; run_dir=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  [ -n "$run_dir" ] || usage_error 'verify needs --run-dir (the Spec run directory)'
  [ -d "$run_dir" ] || usage_error "run directory not found: $run_dir"
  run_dir=$(cd -P "$run_dir" && pwd) || usage_error "run directory is not readable: $run_dir"

  # The table as it stands now, by its own display command; its hints go to
  # stderr as ever, and a table that cannot be read is one line in the report,
  # not the end of it.
  local route_err route_hint= route_table route_status=0
  if route_err=$(mktemp "$run_dir/verify-route.XXXXXX"); then
    route_table=$("$STAGE_ROUTE" 2>"$route_err") || route_status=$?
    route_hint=$(head -n 1 "$route_err")
    cat "$route_err" >&2
    rm -f "$route_err"
  else
    route_table=$("$STAGE_ROUTE") || route_status=$?
  fi
  printf '%s\n' '路由表（当前值）：'
  if [ "$route_status" -eq 0 ] && [ -n "$route_table" ]; then
    printf '%s\n' "$route_table"
  else
    printf '（读取失败：%s）\n' "${route_hint:-stage-route 退出 $route_status}"
  fi

  # One line per Orca worker of the Run, in the order they were dispatched
  # (the sidecar's started_at), so the report reads as the Run went. The rows
  # are joined on the unit separator: a sidecar without started_at keeps its
  # empty first column (a tab would collapse and put the path in the start
  # time's place), sorts first and is checked like any other.
  printf '%s\n' '核对（派发 → 路由模型 / 实际模型 / 结论）：'
  local sidecar form started order=() sorted
  for sidecar in "$run_dir"/dispatch-*.json; do
    [ -f "$sidecar" ] || continue
    form=$(json_get "$sidecar" form) || form=
    [ "$form" = interactive ] || continue
    started=$(json_get "$sidecar" started_at) || started=
    order+=("$started"$'\x1f'"$sidecar")
  done
  if [ "${#order[@]}" -eq 0 ]; then
    printf '%s\n' '（本次 Run 没有派发 Orca worker）'
    return 0
  fi
  sorted=$(printf '%s\n' "${order[@]}" | sort -t $'\x1f' -k1,1)
  while IFS=$'\x1f' read -r started sidecar; do
    verify_sidecar "$sidecar"
  done <<< "$sorted"
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
  verify) cmd_verify "$@" ;;
  *) usage_error "unknown subcommand: $SUBCOMMAND (dispatch, wait, release or verify)" ;;
esac
