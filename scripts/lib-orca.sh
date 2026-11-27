#!/usr/bin/env bash
# Orca public library: the one place this repository talks to Orca.
#
# Source it and call a function; never run `orca` directly. Every function goes
# through orca_run, the only line that starts Orca, so a change in Orca's
# Experimental API is fixed here once.
#
# Replacement variable: ISS_ORCA names the Orca executable (default `orca` on
# PATH). It is the only one in this repository; tests fake Orca by setting it,
# or by putting a fake `orca` on PATH the way test-design-session.sh does.
#
# Three groups:
#   worktree       orca_repo_list, orca_worktree_list, orca_worktree_create,
#                  orca_worktree_create_child, orca_worktree_rm
#   terminal       orca_terminal_list, orca_terminal_by_pane,
#                  orca_terminal_by_handle, orca_terminal_create,
#                  orca_terminal_switch, orca_terminal_wait, orca_terminal_close,
#                  orca_terminal_send, orca_terminal_read, orca_terminal_show
#   orchestration  orca_orchestration_run_create, orca_orchestration_send,
#                  orca_orchestration_check, orca_orchestration_worker_start,
#                  orca_orchestration_worker_dispatch, orca_orchestration_worker_stop,
#                  orca_orchestration_worker_show, orca_orchestration_worker_release,
#                  orca_orchestration_worker_list
# plus the two top-level Orca commands that belong to no group, orca_status and
# orca_agent_launch.
#
# Four rules, each kept by a signature or a default rather than by the caller:
#   1. One replacement variable. ISS_ORCA is read by orca_exe alone; a script
#      has no Orca variable of its own.
#   2. Dispatch and lookup name their Run. Every orchestration function that
#      acts on a Run takes the Run id as its first argument and exits 64
#      without it: a Run inherited from the terminal environment once
#      delivered mail to the wrong session. Two kinds are excepted, each for
#      the reason given at the function: worker_stop, worker_show and
#      worker_release address one dispatch by its id (a dispatch belongs to
#      exactly one Run, and the id is what worker-start returned), and
#      worker_list names no Run at all (the keeper has none of its own and
#      must see every worker).
#   3. No cached terminal handle. The library stores no handle and offers no
#      lookup over a saved list; orca_terminal_by_pane asks Orca again on every
#      call, so a handle that drifted is never reused.
#   4. Look, don't take. orca_orchestration_check peeks by default; only a
#      coordinator that consumes its own Run's mail passes --take. Waiting is
#      one blocking call (--wait --timeout-ms); the library has no polling.
#
# `repo list` is a read-only query of Orca's registry, the layer above
# worktrees, so it sits in the worktree group.
#
# A script that runs node and needs Orca from there does not spawn `orca`; it
# runs the library: `bash -c 'source "$1" && orca_terminal_list' _ <this file>`.
#
# A missing required argument is a usage error: the function prints one line
# to stderr and exits 64 without starting Orca.

# --- plumbing -----------------------------------------------------------------

orca_exe() { # prints the Orca executable
  printf '%s' "${ISS_ORCA:-orca}"
}

orca_run() { # <orca arguments...>: the only place Orca is started
  "$(orca_exe)" "$@"
}

orca_require_value() { # value what caller: exits 64 on an empty value
  [ -n "${1:-}" ] || {
    printf 'lib-orca: %s: %s is required\n' "$3" "$2" >&2
    exit 64
  }
}

# The two checks every option's value goes through, so the loop of each
# function names its options and nothing else.

orca_opt_value() { # value option what caller: exits 64 on a missing or option-like value
  # The value is missing, or is the next option: either way the option has none.
  [ -n "${1:-}" ] && [[ "$1" != -* ]] || {
    printf 'lib-orca: %s: %s needs %s, got [%s]\n' "$4" "$2" "$3" "${1:-}" >&2
    exit 64
  }
}

orca_opt_count() { # value option what caller: exits 64 unless value is a positive integer
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'lib-orca: %s: %s needs a positive integer of %s, got [%s]\n' "$4" "$2" "$3" "${1:-}" >&2
    exit 64
  }
}

# --- status and agent ---------------------------------------------------------
# Top-level Orca commands that belong to none of the three groups.

orca_status() { # prints `status --json`: whether Orca is up
  orca_run status --json
}

orca_agent_launch() { # agent worktree_path prompt: starts the agent in an existing worktree
  orca_require_value "${1:-}" 'an agent' agent_launch
  orca_require_value "${2:-}" 'a worktree path' agent_launch
  orca_require_value "${3:-}" 'a prompt' agent_launch
  orca_run agent launch --agent "$1" --worktree "path:$2" --prompt "$3" --json
}

# --- worktree -----------------------------------------------------------------

orca_repo_list() { # prints `repo list --json`: the registry Orca keeps
  orca_run repo list --json
}

orca_worktree_list() { # prints `worktree list --json`
  orca_run worktree list --json
}

orca_worktree_create() { # repo_path name branch base_branch issue agent prompt
  # Creates the named worktree on a new branch off the base branch, files it
  # under the issue and starts the agent in it with the prompt; prints the
  # JSON result.
  orca_require_value "${1:-}" 'a repository path' worktree_create
  orca_require_value "${2:-}" 'a worktree name' worktree_create
  orca_require_value "${3:-}" 'a branch' worktree_create
  orca_require_value "${4:-}" 'a base branch' worktree_create
  orca_require_value "${5:-}" 'an issue number' worktree_create
  orca_require_value "${6:-}" 'an agent' worktree_create
  orca_require_value "${7:-}" 'a prompt' worktree_create
  orca_run worktree create --repo "path:$1" --name "$2" --branch "$3" \
    --base-branch "$4" --issue "$5" --no-parent --agent "$6" --prompt "$7" --json
}

orca_worktree_rm() { # path: removes that worktree, forced, with its branch
  orca_require_value "${1:-}" 'a worktree path' worktree_rm
  orca_run worktree rm --worktree "path:$1" --force --delete-branch
}

# The nested form, for the worktrees of the three-level tree (ADR 0004: main
# session -> Spec -> ticket): the new worktree hangs under the parent worktree
# in Orca's lineage (parentWorktreeId), and no agent starts in it here. The
# caller starts the session that works there afterwards: launch-wave.sh
# dispatches a Spec session into it (orca_orchestration_worker_dispatch), and
# stage-dispatch.sh opens the terminal of a Ticket's worker itself. --branch and
# --base-branch are the caller's to name, since a child does not inherit its
# parent's branch (docs/orca-smoke-2026-11-27.md, A4: new-child would pick
# origin/main). Prints the JSON result.
orca_worktree_create_child() { # repo_path name branch base_branch issue parent_worktree
  orca_require_value "${1:-}" 'a repository path' worktree_create_child
  orca_require_value "${2:-}" 'a worktree name' worktree_create_child
  orca_require_value "${3:-}" 'a branch' worktree_create_child
  orca_require_value "${4:-}" 'a base branch' worktree_create_child
  orca_require_value "${5:-}" 'an issue number' worktree_create_child
  orca_require_value "${6:-}" 'a parent worktree' worktree_create_child
  orca_run worktree create --repo "path:$1" --name "$2" --branch "$3" \
    --base-branch "$4" --issue "$5" --parent-worktree "path:$6" --json
}

# --- terminal -----------------------------------------------------------------

orca_terminal_list() { # prints `terminal list --json`
  orca_run terminal list --json
}

orca_terminal_create() { # worktree_path title command [--focus]: opens a terminal tab in that worktree
  # The command is the shell line the tab runs; the JSON result is printed.
  # --focus switches to the new tab; without it Orca opens it in the background.
  local worktree=${1:-} title=${2:-} command=${3:-}
  orca_require_value "${worktree:-}" 'a worktree path' terminal_create
  orca_require_value "${title:-}" 'a title' terminal_create
  orca_require_value "${command:-}" 'a command' terminal_create
  local args=(terminal create --worktree "path:$worktree" --title "$title" --command "$command")
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --focus) args+=(--focus); shift ;;
      *)
        printf 'lib-orca: terminal_create: unknown argument [%s] (the one option is --focus)\n' "$1" >&2
        exit 64
        ;;
    esac
  done
  orca_run "${args[@]}" --json
}

orca_terminal_switch() { # handle: brings that terminal's tab to the front
  orca_require_value "${1:-}" 'a terminal handle' terminal_switch
  orca_run terminal switch --terminal "$1"
}

# One blocking wait, as with an orchestration check: the library never polls.
# The condition is exit or tui-idle, and the wait always carries a timeout,
# since one without it could block forever.
orca_terminal_wait() { # handle exit|tui-idle timeout_ms: waits once for the condition
  orca_require_value "${1:-}" 'a terminal handle' terminal_wait
  case "${2:-}" in
    exit|tui-idle) ;;
    *)
      printf 'lib-orca: terminal_wait: the condition is exit or tui-idle, got [%s]\n' "${2:-}" >&2
      exit 64
      ;;
  esac
  orca_opt_count "${3:-}" --timeout-ms milliseconds terminal_wait
  orca_run terminal wait --terminal "$1" --for "$2" --timeout-ms "$3" --json
}

# Rule 3: the handle is resolved again on every call. This asks Orca for the
# terminal list each time it runs; nothing in the library remembers a handle
# between calls, so a handle that drifted is never reused.
orca_terminal_by_pane() { # tabId leafId -> handle<TAB>worktreePath
  # Exits 1 when Orca lists no terminal with that pane, 2 when the list cannot
  # be parsed, 3 when Orca itself fails (its stderr is passed through).
  local list
  list=$(orca_terminal_list) || return 3
  printf '%s' "$list" | TAB_ID=$1 LEAF_ID=$2 node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); }
    catch { process.exit(2); }
    const terminals = value && value.result && Array.isArray(value.result.terminals)
      ? value.result.terminals
      : (value && Array.isArray(value.terminals) ? value.terminals : null);
    if (!terminals) process.exit(2);
    const terminal = terminals.find((item) =>
      String(item.tabId || "") === process.env.TAB_ID &&
      String(item.leafId || "") === process.env.LEAF_ID);
    if (!terminal || !terminal.handle) process.exit(1);
    process.stdout.write(String(terminal.handle) + "\t" + String(terminal.worktreePath || "") + "\n");
  '
}

# The same receipt for a terminal named by its handle: the one every terminal
# Orca opens inherits as ORCA_TERMINAL_HANDLE, which is all a session Orca
# dispatched or adopted may carry (规格 #26, US24: no ORCA_TAB_ID, no
# ORCA_AGENT_PANE). Asked of Orca on every call, like by_pane; the handle is
# never trusted to be current on its own.
orca_terminal_by_handle() { # handle -> handle<TAB>worktreePath
  # Exits 1 when Orca has no such terminal (or says ok:false), 2 when the
  # receipt cannot be parsed, 3 when Orca itself fails (its stderr is passed
  # through).
  local show
  orca_require_value "${1:-}" 'a terminal handle' terminal_by_handle
  show=$(orca_terminal_show "$1") || return 3
  printf '%s' "$show" | node -e '
    const fs = require("fs");
    let value;
    try { value = JSON.parse(fs.readFileSync(0, "utf8")); }
    catch { process.exit(2); }
    const result = value && typeof value === "object" ? value.result : null;
    const terminal = result && typeof result === "object" ? result.terminal : null;
    if (value && value.ok === false) process.exit(1);
    if (!terminal || typeof terminal !== "object") process.exit(2);
    if (!terminal.handle) process.exit(1);
    process.stdout.write(String(terminal.handle) + "\t" + String(terminal.worktreePath || "") + "\n");
  '
}

orca_terminal_close() { # handle: closes the whole tab of that one terminal
  orca_require_value "${1:-}" 'a terminal handle' terminal_close
  orca_run terminal close --terminal "$1" --tab
}

orca_terminal_send() { # handle text: types the text into that terminal, then Enter
  orca_require_value "${1:-}" 'a terminal handle' terminal_send
  orca_require_value "${2:-}" 'a text' terminal_send
  orca_run terminal send --terminal "$1" --text "$2" --enter
}

# What a terminal shows. Without --screen the read is the accumulated output,
# which a TUI breaks into fragments; --screen is the rendered frame, which is
# what tells a session that is working from one that never started. A window
# of the stream (--cursor) is not offered: the caller wants the screen or the
# whole output. Once the process has exited the read comes back empty; what
# the terminal last showed is then only in orca_terminal_show's preview.
orca_terminal_read() { # handle [--screen] [--limit <positive integer>]: prints `terminal read --json`
  orca_require_value "${1:-}" 'a terminal handle' terminal_read
  local handle=$1 screen=0 limit=
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --screen) screen=1; shift ;;
      --limit)
        orca_opt_count "${2:-}" --limit lines terminal_read
        limit=$2
        shift 2
        ;;
      *)
        printf 'lib-orca: terminal_read: unknown argument [%s] (the options are --screen and --limit <n>)\n' "$1" >&2
        exit 64
        ;;
    esac
  done
  local args=(terminal read --terminal "$handle")
  [ "$screen" -eq 0 ] || args+=(--screen)
  [ -z "$limit" ] || args+=(--limit "$limit")
  orca_run "${args[@]}" --json
}

orca_terminal_show() { # handle: prints `terminal show --json`, the metadata and the preview
  orca_require_value "${1:-}" 'a terminal handle' terminal_show
  orca_run terminal show --terminal "$1" --json
}

# --- orchestration -------------------------------------------------------------

# Rule 2: a Run is named, never inherited. The Run id must be the caller's own
# non-option word; the terminal environment is not consulted.
orca_require_run() { # run_id caller: exits 64 unless run_id can name a Run
  case "${1:-}" in
    ''|-*)
      printf 'lib-orca: %s: a Run id is required as the first argument (a Run is never inherited from the terminal); got [%s]\n' \
        "$2" "${1:-}" >&2
      exit 64
      ;;
  esac
}

orca_orchestration_run_create() { # objective: creates and binds a Run; prints the JSON result
  orca_require_value "${1:-}" 'an objective' run_create
  orca_run orchestration run-create --objective "$1" --json
}

orca_orchestration_send() { # run_id <orca send arguments...>
  local run=${1:-} argument
  orca_require_run "$run" orchestration_send
  shift
  for argument in "$@"; do
    case "$argument" in
      --run)
        printf 'lib-orca: orchestration_send: pass the Run id once, as the first argument\n' >&2
        exit 64
        ;;
    esac
  done
  orca_run orchestration send --run "$run" "$@"
}

# Rule 4: a check looks by default, and waits at most once. --take is for a
# coordinator that consumes its own Run's mail (design session waiting for a
# handoff); anything else must not take messages an agent still needs to see.
# Waiting is one blocking call: --timeout-ms <n> becomes --wait --timeout-ms
# <n>. There is no bare --wait (it could block forever) and no polling here.
# --types <type,...> narrows what wakes the wait (worker_done alone, for a
# dispatch waiting on its worker); the batch Orca returns is the whole FIFO
# either way.
orca_orchestration_check() { # run_id [--take] [--types <type,...>] [--timeout-ms <positive integer>]
  local run=${1:-} take=0 timeout_ms= types=
  orca_require_run "$run" orchestration_check
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --take) take=1; shift ;;
      --types)
        orca_opt_value "${2:-}" --types 'a comma-separated list of message types' orchestration_check
        types=$2
        shift 2
        ;;
      --timeout-ms)
        orca_opt_count "${2:-}" --timeout-ms milliseconds orchestration_check
        timeout_ms=$2
        shift 2
        ;;
      *)
        printf 'lib-orca: orchestration_check: unknown argument [%s]\n' "$1" >&2
        exit 64
        ;;
    esac
  done
  local args=(orchestration check --run "$run" --json)
  [ -z "$types" ] || args+=(--types "$types")
  [ "$take" -eq 1 ] || args+=(--peek)
  [ -n "$timeout_ms" ] && args+=(--wait --timeout-ms "$timeout_ms")
  orca_run "${args[@]}"
}

# A dispatch in the one form this repository uses: a terminal the caller opened
# is adopted as the worker of a Task in the Run. The launcher is already running
# in that terminal with its model and effort on the command line (Orca records
# neither for an adopted terminal), so --model, --effort and --agent have no
# place here; the spec is a file, whose quotes and backticks need no escaping.
# --timeout-ms bounds the wait for the worker to take the spec.
orca_orchestration_worker_start() { # run_id --terminal <handle> --spec-file <path> [--timeout-ms <positive integer>]
  local run=${1:-} handle= spec= timeout_ms=
  orca_require_run "$run" worker_start
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --run)
        printf 'lib-orca: worker_start: pass the Run id once, as the first argument\n' >&2
        exit 64
        ;;
      --terminal)
        orca_opt_value "${2:-}" --terminal 'a terminal handle' worker_start
        handle=$2
        shift 2
        ;;
      --spec-file)
        orca_opt_value "${2:-}" --spec-file 'a file path' worker_start
        spec=$2
        shift 2
        ;;
      --timeout-ms)
        orca_opt_count "${2:-}" --timeout-ms milliseconds worker_start
        timeout_ms=$2
        shift 2
        ;;
      *)
        printf 'lib-orca: worker_start: unknown argument [%s] (a worker starts by adopting a terminal: --terminal <handle> --spec-file <path> [--timeout-ms <n>])\n' \
          "$1" >&2
        exit 64
        ;;
    esac
  done
  [ -n "$handle" ] || {
    printf 'lib-orca: worker_start: --terminal <handle> is required: a worker starts by adopting a terminal the caller opened\n' >&2
    exit 64
  }
  [ -n "$spec" ] || {
    printf 'lib-orca: worker_start: --spec-file <path> is required: the spec is read from a file\n' >&2
    exit 64
  }
  local args=(orchestration worker-start --run "$run" --terminal "$handle" --spec-file "$spec" --json)
  [ -z "$timeout_ms" ] || args+=(--timeout-ms "$timeout_ms")
  orca_run "${args[@]}"
}

# The other form of worker-start: Orca itself starts the agent in a worktree
# the caller names, so the session's life (liveness, completion, takeover) is
# Orca's to manage. The slot runs the model from its own configuration, so
# --model has no place here (openclaude rejects it); --terminal is the adopted
# form above. The spec is a file, except on a retry: --retry-of names the
# dispatch being retried and needs --task, the Task that already carries the
# spec, and the placement (--worktree, --agent) is repeated because Orca does
# not inherit it. --timeout-ms bounds the wait for the worker to take the spec.
orca_orchestration_worker_dispatch() { # run_id --worktree <path> --agent <slot> (--spec-file <path> | --task <task_id> [--retry-of <dispatch_id>]) [--timeout-ms <positive integer>]
  local run=${1:-} worktree= agent= spec= task= retry_of= timeout_ms=
  orca_require_run "$run" worker_dispatch
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --run)
        printf 'lib-orca: worker_dispatch: pass the Run id once, as the first argument\n' >&2
        exit 64
        ;;
      --worktree)
        orca_opt_value "${2:-}" --worktree 'a worktree path' worker_dispatch
        worktree=$2
        shift 2
        ;;
      --agent)
        orca_opt_value "${2:-}" --agent 'an agent slot' worker_dispatch
        agent=$2
        shift 2
        ;;
      --spec-file)
        orca_opt_value "${2:-}" --spec-file 'a file path' worker_dispatch
        spec=$2
        shift 2
        ;;
      --task)
        orca_opt_value "${2:-}" --task 'a Task id' worker_dispatch
        task=$2
        shift 2
        ;;
      --retry-of)
        orca_opt_value "${2:-}" --retry-of 'a dispatch id' worker_dispatch
        retry_of=$2
        shift 2
        ;;
      --timeout-ms)
        orca_opt_count "${2:-}" --timeout-ms milliseconds worker_dispatch
        timeout_ms=$2
        shift 2
        ;;
      *)
        printf 'lib-orca: worker_dispatch: unknown argument [%s] (a worker is dispatched with --worktree <path> --agent <slot> and a spec file or a Task; --model is the agent slot'"'"'s to decide)\n' \
          "$1" >&2
        exit 64
        ;;
    esac
  done
  [ -n "$worktree" ] || {
    printf 'lib-orca: worker_dispatch: --worktree <path> is required: a dispatched worker is placed in a worktree\n' >&2
    exit 64
  }
  [ -n "$agent" ] || {
    printf 'lib-orca: worker_dispatch: --agent <slot> is required: Orca starts that agent in the worktree\n' >&2
    exit 64
  }
  if [ -n "$spec" ] && [ -n "$task" ]; then
    printf 'lib-orca: worker_dispatch: give one of --spec-file and --task, not both\n' >&2
    exit 64
  fi
  [ -n "$spec" ] || [ -n "$task" ] || {
    printf 'lib-orca: worker_dispatch: --spec-file <path> is required (or --task <id> for a retry): the spec is read from a file\n' >&2
    exit 64
  }
  if [ -n "$retry_of" ] && [ -z "$task" ]; then
    printf 'lib-orca: worker_dispatch: --retry-of needs --task <task_id>: the Task already carries the spec\n' >&2
    exit 64
  fi
  local args=(orchestration worker-start --run "$run" --worktree "path:$worktree" --agent "$agent")
  if [ -n "$task" ]; then
    args+=(--task "$task")
    [ -z "$retry_of" ] || args+=(--retry-of "$retry_of")
  else
    args+=(--spec-file "$spec")
  fi
  args+=(--json)
  [ -z "$timeout_ms" ] || args+=(--timeout-ms "$timeout_ms")
  orca_run "${args[@]}"
}

# Rule 2: the three calls that follow address one dispatch by its id and name
# no Run: a dispatch belongs to exactly one Run, and the id is what
# worker-start returned.

# Stops that dispatch's agent. Orca refuses (exit 1, stop_unknown) when it
# cannot prove the agent has stopped; the caller must then look before acting
# again, not assume it is gone.
orca_orchestration_worker_stop() { # dispatch_id: stops that worker
  orca_require_value "${1:-}" 'a dispatch id' worker_stop
  orca_run orchestration worker-stop --dispatch "$1" --json
}

# --full asks for the whole record Orca holds instead of the concise view. It
# is where the model of an adopted terminal can be read: the concise view has
# no model, and the full record's projection.provider carries what Orca read
# off the worker's TUI ({id, model}), or null once it could read nothing.
orca_orchestration_worker_show() { # dispatch_id [--full]: prints `worker-show --json` (state, stage, liveness)
  local dispatch=${1:-} full=0
  orca_require_value "$dispatch" 'a dispatch id' worker_show
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1; shift ;;
      *)
        printf 'lib-orca: worker_show: unknown argument [%s] (the one option is --full)\n' "$1" >&2
        exit 64
        ;;
    esac
  done
  local args=(orchestration worker-show --dispatch "$dispatch")
  [ "$full" -eq 0 ] || args+=(--full)
  orca_run "${args[@]}" --json
}

# Releases a settled worker: closes the agent terminal Orca opened and archives
# the transcript. Orca refuses one that is not settled and exits non-zero; a
# terminal the caller opened itself is retained and must be closed by the caller
# with orca_terminal_close; the worktree and branch are never touched.
orca_orchestration_worker_release() { # dispatch_id: prints the JSON receipt
  orca_require_value "${1:-}" 'a dispatch id' worker_release
  orca_run orchestration worker-release --dispatch "$1" --json
}

# The list keeper.sh searches for the worker of a Spec worktree. No Run is
# named: the keeper has no Run of its own and must see every worker, so --run
# is not offered (without it Orca lists all workers, or those of the Run the
# calling terminal is bound to). One page per call: --cursor asks for the page
# after the one whose nextCursor it carries. The caller walks the pages; the
# library does not loop.
orca_orchestration_worker_list() { # [--cursor <cursor>]: prints one page of `worker-list --json`
  local cursor=
  while [ $# -gt 0 ]; do
    case "$1" in
      --cursor)
        orca_opt_value "${2:-}" --cursor 'a cursor' worker_list
        cursor=$2
        shift 2
        ;;
      *)
        printf 'lib-orca: worker_list: unknown argument [%s] (the one option is --cursor)\n' "$1" >&2
        exit 64
        ;;
    esac
  done
  local args=(orchestration worker-list --json)
  [ -z "$cursor" ] || args+=(--cursor "$cursor")
  orca_run "${args[@]}"
}
