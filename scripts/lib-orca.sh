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
#                  orca_worktree_rm
#   terminal       orca_terminal_list, orca_terminal_by_pane,
#                  orca_terminal_create, orca_terminal_close, orca_terminal_send
#   orchestration  orca_orchestration_send, orca_orchestration_check
# plus the two top-level Orca commands that belong to no group, orca_status and
# orca_agent_launch.
#
# Four rules, each kept by a signature or a default rather than by the caller:
#   1. One replacement variable. ISS_ORCA is read by orca_exe alone; a script
#      has no Orca variable of its own.
#   2. Dispatch and lookup name their Run. Every orchestration function takes
#      the Run id as its first argument and exits 64 without it: a Run
#      inherited from the terminal environment once delivered mail to the
#      wrong session.
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

# --- terminal -----------------------------------------------------------------

orca_terminal_list() { # prints `terminal list --json`
  orca_run terminal list --json
}

orca_terminal_create() { # worktree_path title command: opens a terminal tab in that worktree
  # The command is the shell line the tab runs; the JSON result is printed.
  orca_require_value "${1:-}" 'a worktree path' terminal_create
  orca_require_value "${2:-}" 'a title' terminal_create
  orca_require_value "${3:-}" 'a command' terminal_create
  orca_run terminal create --worktree "path:$1" --title "$2" --command "$3" --json
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

orca_terminal_close() { # handle: closes the whole tab of that one terminal
  orca_require_value "${1:-}" 'a terminal handle' terminal_close
  orca_run terminal close --terminal "$1" --tab
}

orca_terminal_send() { # handle text: types the text into that terminal, then Enter
  orca_require_value "${1:-}" 'a terminal handle' terminal_send
  orca_require_value "${2:-}" 'a text' terminal_send
  orca_run terminal send --terminal "$1" --text "$2" --enter
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
orca_orchestration_check() { # run_id [--take] [--timeout-ms <positive integer>]
  local run=${1:-} take=0 timeout_ms=
  orca_require_run "$run" orchestration_check
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --take) take=1; shift ;;
      --timeout-ms)
        if [ $# -lt 2 ] || ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
          printf 'lib-orca: orchestration_check: --timeout-ms needs a positive integer of milliseconds, got [%s]\n' \
            "${2:-}" >&2
          exit 64
        fi
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
  [ "$take" -eq 1 ] || args+=(--peek)
  [ -n "$timeout_ms" ] && args+=(--wait --timeout-ms "$timeout_ms")
  orca_run "${args[@]}"
}
