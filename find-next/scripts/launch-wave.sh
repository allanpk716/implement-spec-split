#!/usr/bin/env bash
# Launch the first development wave in Orca after find-next publishes specs.
#
# A Spec session is an Orca orchestration worker (ADR 0004), not a prompt handed
# to `worktree create`: --apply first creates the Spec's worktree as a child of
# the main worktree (the first level of the three-level tree), then dispatches
# the session into it with `worker-start --run <wave Run> --worktree path:<it>
# --agent <slot> --spec-file <spec>`, so its life (liveness, completion,
# takeover) is Orca's. The spec is the generated command,
# `/implement-spec-split <n> ...`, written to a file; Orca puts its own preamble
# in front of it and the model calls the skill itself, so the guards keyed on
# that command name keep working.
#
# The agent slot is read from the Stage route table's 编排 route every time a
# wave is dispatched (the route is locked to flash, Orca's openclaude slot,
# which takes no --model). How a Spec's tickets are implemented is the route
# table's business too, read by the Spec session at its own dispatches: nothing
# about it is chosen or recorded here.
#
# A dispatched session counts as started only once its claim record carries a
# pid (`claim.sh status`), i.e. once the session ran `claim.sh take`. The
# Handoff reservation launch-wave writes beforehand is not that: it exists
# before the session does. So after dispatching, launch-wave waits for each
# Spec's pid (ISS_CLAIM_WAIT, default 900s; a session has been seen to take 13
# minutes to start), reading the claim every ISS_CLAIM_POLL seconds. Waiting for
# one Spec never delays the dispatch of another: every Spec is dispatched first,
# each in its own subshell, and the waiting happens afterwards.
#
# When the wait runs out, the terminal is read before anything else
# (terminal read --screen; once the process has exited that comes back empty, so
# terminal show's preview is read next -- an empty read is never taken as proof
# that nothing started). Then one of four branches:
#   not started (the process exited, or the TUI is up without the spec typed)
#     -> worker-stop, then one retry with --task and --retry-of into the same
#        worktree (the placement is not inherited);
#   working (assistant output on screen) -> the wait is extended, never past
#        the reservation's own lifetime (claim.sh reserve --ttl); at that cap
#        the Spec is reported, not redispatched, a retry included;
#   cannot tell -> parked: nothing is stopped or redispatched, one line
#        `#<n> 停车：<reason>` carries what the terminal showed, the Run and
#        the dispatch, and the command to restart the Spec with;
#   the retry did not start either -> parked the same way: a retry that exited
#        parks at once; a retry that sits idle is stopped first (the evidence
#        is the first dispatch's), and parks once Orca confirms the stop.
# A parked Spec whose process is known to have exited, or whose idle session
# Orca confirmed stopped, gets its reservation released, as a failed launch
# does; otherwise the reservation is left to expire, so that a session that is
# merely slow is not started twice.
#
# Each --apply that dispatches anything creates one Orca Run for the wave,
# prints it and records it in the launch state (a run with nothing to launch
# creates none and keeps the recorded one: the keeper asks for a Spec every few
# minutes, and must not leave empty Runs behind). The Run exists to dispatch
# the Spec sessions and to take the wave over; each session creates its own Run
# for its ticket workers, and no Spec session reports into the wave's Run --
# whether a Spec is done is read from `pipeline-status.sh` and the keeper. Run
# creation and dispatch run in this process, so
# Orca binds the Run to the terminal this script runs in. Not verified: a
# caller without a terminal identity (keeper under launchd) being accepted as
# that Run's coordinator (规格 #26, probe 4 of #39); an Orca that refuses shows
# up as 启动失败 with Orca's message.
#
# Usage:
#   launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart A:B]...
#                  [--only 222,237] [--apply] [--next-wave] [--auto-land|--no-auto-land]
#
# Without --apply the development order is printed and nothing is claimed.
# --workers falls back to the launch state and then the machine-wide max-workers
# file; in --next-wave so do --specs and --apart. --next-wave launches only
# free first-wave Specs, never resumes interrupted ones, and refuses cycles.
# Spec sessions launched here are unattended by default: every generated
# command ends with --auto-land and --apply records auto_land: true;
# --no-auto-land opts this batch out. --next-wave cannot take either flag.
# FLASH_ORCHESTRATOR=1 records that a flash orchestrator launched the batch.
# The launch state keeps impl and agent_model from before 规格 #26 unread.
#
# Environment: ISS_PIPELINE_STATUS, ISS_CLAIM, ISS_MAX_WORKERS_CMD, ISS_LOCK,
# ISS_LAUNCH_STATE_DIR, ISS_STATE_DIR, ISS_LAUNCH_WAVE_LOCK_WAIT, ISS_MAX_WORKERS,
# ISS_CLAIM_WAIT, ISS_CLAIM_POLL, ISS_LAUNCH_START_TIMEOUT; ISS_ORCA names Orca
# (read by lib-orca.sh alone); ISS_STAGE_ROUTE_FILE via stage-route.sh.
# Test hooks: LAUNCH_WAVE_STAGE_ROUTE names another Stage route table script;
# ISS_CLAIM_WAIT=0 checks the claim once and goes straight to the terminal.
#
# Exit codes:
#   0  printed the order, or launched the wave (parked Specs count as failures)
#   1  bad usage, a Spec failed or parked, or the launch lock could not be taken
#   2  --next-wave found a dependency cycle, or Orca is not there for --apply
#  64  the 编排 route could not be read

set -u

usage() {
  cat <<'EOF'
Usage: launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart A:B]...
                      [--only 222,237] [--apply] [--next-wave]
                      [--auto-land|--no-auto-land]

Print the development order, then optionally reserve and launch its first wave.
Without --apply, this script only shows what would run and makes no claims.
--workers falls back to the launch state and then the machine-wide max-workers
file. In --next-wave, --specs and --apart also fall back to the launch state.
--next-wave is for the end of an implement-spec-split Run: it launches only free
first-wave Specs, never resumes interrupted ones, and refuses cycles.
--apply hands each Spec of the wave to Orca orchestration: a child worktree
spec-<n> on branch spec-<n> off origin's HEAD under the main worktree (a
resumed Spec keeps its worktree), then `worker-start --run <wave Run>
--worktree path:<it> --agent openclaude --spec-file <spec>` starts the session
there. The agent slot is the route table's 编排 route (locked to flash). Each
--apply creates one Orca Run for the wave, prints it and records it in the
launch state; the Spec sessions are dispatched from it (none reports into it),
and a new terminal takes the wave over with `orca orchestration run-use --id <run>`.
A session is reported 已启动 only once its claim record carries a pid, since
the Handoff reservation is written before the session starts. ISS_CLAIM_WAIT
(seconds, default 900) bounds that wait per Spec and ISS_CLAIM_POLL (seconds,
default 10) is how often the claim is read; ISS_LAUNCH_START_TIMEOUT (seconds,
default 900) bounds Orca's wait for the session to take its spec. Waiting for
one Spec never delays the dispatch of another. When the wait runs out the
terminal is read first: a session that never started is stopped and retried
once (--retry-of); one that is working gets the wait extended, no later than
its reservation expires, and is then reported rather than failed, a retry
included; anything else, and a retry that does not start either (stopped
first, when it sits idle), parks the Spec with `#<n> 停车：…` and the command
to restart it.
Spec sessions launched here are unattended by default: every generated command
ends with --auto-land, and --apply records auto_land: true. --no-auto-land opts
this batch out (commands omit --auto-land, the state records auto_land:
false); --auto-land is accepted as the default. --next-wave reuses the
recorded value, treating a state file without the field as authorized.
--next-wave cannot accept --auto-land or --no-auto-land itself; give either
with the initial --apply. With FLASH_ORCHESTRATOR=1 the launch state records
that a flash orchestrator launched the batch. How a Spec's tickets are
implemented follows the route table's 实现 route, read when they are
dispatched; --impl and --agent-model were removed and are refused.
EOF
}

die() {
  printf 'launch-wave: %s\n' "$1" >&2
  exit "${2:-1}"
}

SCRIPT_SOURCE=$0
if [[ "$SCRIPT_SOURCE" == */* ]]; then
  SCRIPT_DIR=${SCRIPT_SOURCE%/*}
else
  SCRIPT_DIR=$(command -v -- "$SCRIPT_SOURCE") || die "could not resolve the launch script path"
  SCRIPT_DIR=${SCRIPT_DIR%/*}
fi
SKILL_ROOT=$(cd -P -- "$SCRIPT_DIR/../.." && pwd) || die "could not resolve the skill root"

REPO=
WORKERS=
SPECS=2
APART=()
ONLY=
APPLY=0
NEXT_WAVE=0
WORKERS_GIVEN=0
SPECS_GIVEN=0
APART_GIVEN=0
AUTO_LAND=1
AUTO_LAND_GIVEN=0
FLASH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo requires <owner/name>"
      REPO=$2
      shift 2
      ;;
    --workers)
      [ $# -ge 2 ] || die "--workers requires <N>"
      case "$2" in
        *[!0-9]*|'') die "--workers requires a positive integer" ;;
        0) die "--workers requires a positive integer" ;;
      esac
      WORKERS=$2
      WORKERS_GIVEN=1
      shift 2
      ;;
    --specs)
      [ $# -ge 2 ] || die "--specs requires <K>"
      case "$2" in
        *[!0-9]*|'') die "--specs requires a positive integer" ;;
        0) die "--specs requires a positive integer" ;;
      esac
      SPECS=$2
      SPECS_GIVEN=1
      shift 2
      ;;
    --apart)
      [ $# -ge 2 ] || die "--apart requires <A:B>"
      if ! [[ "$2" =~ ^[0-9]+:[0-9]+$ ]]; then
        die "--apart requires <A:B> with two issue numbers"
      fi
      APART+=("$2")
      APART_GIVEN=1
      shift 2
      ;;
    --only)
      [ $# -ge 2 ] || die "--only requires a comma-separated list of spec numbers"
      ONLY=$2
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --next-wave)
      NEXT_WAVE=1
      shift
      ;;
    --impl|--agent-model)
      die "$1 was removed (规格 #26): a Spec's tickets are implemented on the route table's 实现 route, read when they are dispatched; drop the flag"
      ;;
    --auto-land)
      AUTO_LAND=1
      AUTO_LAND_GIVEN=1
      shift
      ;;
    --no-auto-land)
      AUTO_LAND=0
      AUTO_LAND_GIVEN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

if [ "${FLASH_ORCHESTRATOR:-}" = 1 ]; then
  FLASH=1
fi

[ "$AUTO_LAND_GIVEN" -eq 0 ] || [ "$NEXT_WAVE" -eq 0 ] ||
  die "--auto-land and --no-auto-land are not valid with --next-wave; give either with the initial --apply"
[ -n "$REPO" ] || die "--repo is required"
[[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] ||
  die "--repo must be <owner/name>"

PIPELINE_STATUS=${ISS_PIPELINE_STATUS:-$SKILL_ROOT/scripts/pipeline-status.sh}
CLAIM=${ISS_CLAIM:-$SKILL_ROOT/scripts/claim.sh}
MAX_WORKERS_CMD=${ISS_MAX_WORKERS_CMD:-$SKILL_ROOT/scripts/max-workers.sh}
# The Stage route table, read once per --apply for the 编排 route's agent slot.
STAGE_ROUTE=${LAUNCH_WAVE_STAGE_ROUTE:-$SKILL_ROOT/scripts/stage-route.sh}
# Orca is reached only through the public library; ISS_ORCA, read there, names the
# executable.
# shellcheck source=../../scripts/lib-orca.sh
source "$SKILL_ROOT/scripts/lib-orca.sh"
LOCK=${ISS_LOCK:-$SKILL_ROOT/scripts/lock.sh}
LAUNCH_STATE_DIR=${ISS_LAUNCH_STATE_DIR:-$HOME/.cache/implement-spec-split/launch}
WORKER_STATE_DIR=${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}
LAUNCH_STATE_FILE="$LAUNCH_STATE_DIR/${REPO/\//__}.json"
MAX_WORKERS_FILE="$WORKER_STATE_DIR/max-workers"
# How long a dispatched Spec may take to claim (seconds), how often the claim
# is read, and how long Orca may wait for the session to take its spec.
CLAIM_WAIT=${ISS_CLAIM_WAIT:-900}
CLAIM_POLL=${ISS_CLAIM_POLL:-10}
START_TIMEOUT=${ISS_LAUNCH_START_TIMEOUT:-900}

valid_non_negative() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

valid_positive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

valid_non_negative "$CLAIM_WAIT" || die "ISS_CLAIM_WAIT must be a non-negative integer of seconds"
valid_non_negative "$CLAIM_POLL" || die "ISS_CLAIM_POLL must be a non-negative integer of seconds"
valid_positive "$START_TIMEOUT" || die "ISS_LAUNCH_START_TIMEOUT must be a positive integer of seconds"
START_TIMEOUT_MS=$((START_TIMEOUT * 1000))

command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"
command -v git >/dev/null 2>&1 || die "git is required but was not found on PATH"

WORKTREE_OUTPUT=$(git worktree list --porcelain 2>/dev/null) ||
  die "could not list git worktrees"
MAIN_WORKTREE=$(printf '%s\n' "$WORKTREE_OUTPUT" | sed -n 's/^worktree //p' | sed -n '1p')
[ -n "$MAIN_WORKTREE" ] || die "could not determine the main git worktree"

# --repo must name this checkout's origin; otherwise worktrees would be created
# in the wrong repository.
ORIGIN_URL=$(git -C "$MAIN_WORKTREE" remote get-url origin 2>/dev/null || true)
ORIGIN_SLUG=$(printf '%s' "$ORIGIN_URL" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | tr '[:upper:]' '[:lower:]')
[ "$ORIGIN_SLUG" = "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] ||
  die "--repo $REPO does not match this checkout's origin ($ORIGIN_URL); run from that repository"
MAIN_BRANCH=$(git -C "$MAIN_WORKTREE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
MAIN_BRANCH=${MAIN_BRANCH#origin/}
[ -n "$MAIN_BRANCH" ] || MAIN_BRANCH=master

git_main() {
  git -C "$MAIN_WORKTREE" "$@" < /dev/null
}

claim_main() {
  (
    cd "$MAIN_WORKTREE" || exit 125
    "$CLAIM" "$@" < /dev/null
  )
}

now_epoch() {
  date +%s
}

decode_json_string() {
  JSON_STRING=$1 node -e '
    const value = JSON.parse(process.env.JSON_STRING || "null");
    process.stdout.write(typeof value === "string" ? value : "");
  '
}

state_string() {
  STATE_FILE_ACT="$LAUNCH_STATE_FILE" STATE_FIELD="$1" node -e '
    const fs = require("fs");
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE_ACT, "utf8")); }
    catch (_) { process.exit(0); }
    const field = value && value[process.env.STATE_FIELD];
    process.stdout.write(
      typeof field === "number" && Number.isFinite(field) ? String(field) :
      (typeof field === "string" ? field : "")
    );
  '
}

state_apart() {
  STATE_FILE_ACT="$LAUNCH_STATE_FILE" node -e '
    const fs = require("fs");
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE_ACT, "utf8")); }
    catch (_) { process.exit(0); }
    if (!Array.isArray(value.apart)) process.exit(0);
    for (const item of value.apart) {
      if (typeof item === "string" && item !== "") process.stdout.write(item + "\n");
    }
  '
}

state_auto_land() {
  STATE_FILE_ACT="$LAUNCH_STATE_FILE" node -e '
    const fs = require("fs");
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE_ACT, "utf8")); }
    catch (_) { process.exit(0); }
    process.exit(value && value.auto_land === false ? 1 : 0);
  '
}

state_flash() {
  STATE_FILE_ACT="$LAUNCH_STATE_FILE" node -e '
    const fs = require("fs");
    let value = null;
    try { value = JSON.parse(fs.readFileSync(process.env.STATE_FILE_ACT, "utf8")); }
    catch (_) { process.exit(1); }
    process.exit(value && value.flash === true ? 0 : 1);
  '
}

read_workers_without_flag() {
  local value
  if [ -n "${ISS_MAX_WORKERS:-}" ]; then
    valid_positive "$ISS_MAX_WORKERS" || die "ISS_MAX_WORKERS must be a positive integer"
    WORKERS=$ISS_MAX_WORKERS
    return
  fi
  value=$(state_string workers)
  if valid_positive "$value"; then
    WORKERS=$value
    return
  fi
  if [ -f "$MAX_WORKERS_FILE" ]; then
    value=$(sed -n '1p' "$MAX_WORKERS_FILE" 2>/dev/null || true)
    if valid_positive "$value"; then
      WORKERS=$value
      return
    fi
    die "invalid integer in $MAX_WORKERS_FILE; ask the user for --workers"
  fi
  die "--workers is required: no launch state or max-workers file; ask the user for --workers"
}

# impl and agent_model, the fields from before 规格 #26 that named the
# implementation backend, are not read: a Spec's implementation is the route
# table's, so an old state file is simply followed on everything else.
read_next_wave_state() {
  local value pair
  if [ "$FLASH" -eq 0 ] && state_flash; then
    FLASH=1
  fi
  if [ "$WORKERS_GIVEN" -eq 0 ]; then
    read_workers_without_flag
  fi
  if [ "$SPECS_GIVEN" -eq 0 ]; then
    value=$(state_string specs)
    if valid_positive "$value"; then SPECS=$value; fi
  fi
  if [ "$APART_GIVEN" -eq 0 ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      [[ "$pair" =~ ^[0-9]+:[0-9]+$ ]] ||
        die "launch state contains an invalid --apart pair: $pair"
      APART+=("$pair")
    done < <(state_apart)
  fi
  if state_auto_land; then
    AUTO_LAND=1
  else
    AUTO_LAND=0
  fi
}

write_launch_state() {
  mkdir -p "$LAUNCH_STATE_DIR" || die "could not create launch state directory: $LAUNCH_STATE_DIR"
  state_apart_value=''
  if [ "${#APART[@]}" -gt 0 ]; then
    state_apart_value=$(printf '%s\n' "${APART[@]}")
  fi
  STATE_DIR_ACT="$LAUNCH_STATE_DIR" STATE_FILE_ACT="$LAUNCH_STATE_FILE" \
  STATE_WORKERS="$WORKERS" STATE_SPECS="$SPECS" STATE_APART="$state_apart_value" \
  STATE_AUTO_LAND="$AUTO_LAND" \
  STATE_FLASH="$FLASH" STATE_AGENT="$AGENT" STATE_RUN="${RUN_ID:-}" \
  STATE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) node -e '
    const fs = require("fs"), path = require("path");
    const apart = process.env.STATE_APART.split(/\r?\n/).filter(Boolean);
    const authorization = {auto_land: process.env.STATE_AUTO_LAND === "1"};
    // The slot the 编排 route named for this wave, the same one the dispatches carry.
    const session = process.env.STATE_FLASH === "1"
      ? {flash: true, launch_agent: process.env.STATE_AGENT}
      : {};
    const wave = process.env.STATE_RUN === "" ? {} : {run: process.env.STATE_RUN};
    const value = JSON.stringify({
      workers: +process.env.STATE_WORKERS,
      specs: +process.env.STATE_SPECS,
      apart,
      ...session,
      ...authorization,
      ...wave,
      updated: process.env.STATE_AT,
    }, null, 2) + "\n";
    const temporary = path.join(process.env.STATE_DIR_ACT, `.${path.basename(process.env.STATE_FILE_ACT)}.write.${process.pid}`);
    fs.writeFileSync(temporary, value);
    fs.renameSync(temporary, process.env.STATE_FILE_ACT);
  ' || die "could not write launch state: $LAUNCH_STATE_FILE"
}

if [ "$NEXT_WAVE" -eq 1 ]; then
  read_next_wave_state
elif [ "$WORKERS_GIVEN" -eq 0 ]; then
  read_workers_without_flag
fi

first_line() {
  sed -n '1p' "$1" 2>/dev/null
}

# What a failed call has to say, in one line: the first line of its stderr,
# else the error message in its JSON output, else the first line of that output.
first_error_line() {
  local value
  value=$(first_line "$1")
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  value=$(ERROR_FILE="$2" node -e '
    let value;
    try { value = JSON.parse(require("fs").readFileSync(process.env.ERROR_FILE, "utf8")); } catch (_) { process.exit(0); }
    const message = value && value.error && value.error.message;
    if (typeof message === "string" && message !== "") process.stdout.write(message.split("\n")[0]);
  ')
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  first_line "$2"
}

# Every generated command carries --auto-land unless the batch opted out; the
# suffix is always passed so the plan never depends on pipeline-status's
# default. Nothing about the implementation backend is in it any more.
pipeline_args() {
  PIPELINE_ARGS=(--order --repo "$REPO" --parallel "$SPECS" --workers "$WORKERS")
  if [ "$AUTO_LAND" -eq 1 ]; then
    PIPELINE_ARGS+=(--cmd-suffix '--auto-land')
  else
    PIPELINE_ARGS+=(--cmd-suffix '')
  fi
  if [ "${#APART[@]}" -gt 0 ]; then
    for pair in "${APART[@]}"; do
      PIPELINE_ARGS+=(--apart "$pair")
    done
  fi
}

read_plan() {
  local args=("$@")
  PLAN_JSON=$("$PIPELINE_STATUS" "${args[@]}" 2> "$run_err") ||
    die "pipeline-status failed: $(first_line "$run_err")"
}

plan_entries() {
  PLAN_JSON=$PLAN_JSON node <<'NODE'
const plan = JSON.parse(process.env.PLAN_JSON);
const rows = [
  ...(plan.resume || []).map((item) => ({kind: 'resume', ...item})),
  ...(plan.wave1 || []).map((item) => ({kind: 'wave', ...item})),
];
for (const item of rows) {
  const worktree = item.kind === 'resume' ? item.worktree : null;
  process.stdout.write(
    `${item.kind}\t${item.spec}\t${JSON.stringify(item.command || '')}\t${JSON.stringify(worktree === undefined ? null : worktree)}\n`
  );
}
NODE
}

plan_cycles() {
  PLAN_JSON=$PLAN_JSON node <<'NODE'
const plan = JSON.parse(process.env.PLAN_JSON);
for (const spec of Array.isArray(plan.cycles) ? plan.cycles : []) {
  process.stdout.write(`${spec}\n`);
}
NODE
}

cycle_report() {
  CYCLES=$1 node <<'NODE'
const rows = process.env.CYCLES.split(/\r?\n/).filter(Boolean).map((spec) => `#${spec}`);
process.stdout.write(`循环依赖：${rows.join("、")}，不自动启动。请运行 /find-next。\n`);
NODE
}

next_wave_entries() {
  plan_entries | awk -F '\t' '$1 == "wave" { print }'
}

next_wave_resume_hints() {
  PLAN_JSON=$PLAN_JSON node <<'NODE'
const plan = JSON.parse(process.env.PLAN_JSON);
for (const item of Array.isArray(plan.resume) ? plan.resume : []) {
  process.stdout.write(` #${item.spec}（中断，先恢复；--next-wave 不自动恢复）\n`);
}
NODE
}

orca_worktrees() {
  ORCA_LIST=$(orca_worktree_list 2>/dev/null)
  # Pass the JSON via a temp file: on Windows/MSYS the worktree list can exceed
  # the ~32KB per-argument limit and `node -e ... "$ORCA_LIST"` dies with
  # "Argument list too long" (exit 126), making Orca detection fail.
  [ -n "${ORCA_LIST_FILE:-}" ] || ORCA_LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/launch-wave-orca.XXXXXX") || return 1
  printf '%s' "$ORCA_LIST" > "$ORCA_LIST_FILE"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$ORCA_LIST_FILE" >/dev/null 2>&1
}

in_orca() {
  node - "$1" "$ORCA_LIST_FILE" <<'NODE'
const fs = require('fs');
function real(value) {
  try { return fs.realpathSync(value); } catch (_) { return value; }
}
const wanted = real(process.argv[2]);
const value = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const worktrees = (value && value.result && Array.isArray(value.result.worktrees))
  ? value.result.worktrees : [];
process.exit(worktrees.some((item) => real(item.path) === wanted) ? 0 : 1);
NODE
}

extract_created_worktree() {
  ORCA_OUTPUT=$1 node <<'NODE'
let value;
try { value = JSON.parse(process.env.ORCA_OUTPUT); } catch (_) { process.exit(0); }
const path = value && value.result && value.result.worktree && value.result.worktree.path;
if (typeof path === 'string' && path !== '') process.stdout.write(path);
NODE
}

# One line, whatever came in: a message that ends up in the summary has no
# line breaks or tabs, and is cut before it grows into a transcript.
one_line() {
  ONE_LINE_TEXT=$1 node -e '
    const text = String(process.env.ONE_LINE_TEXT || "").replace(/[\t\r\n]+/g, " ").replace(/ {2,}/g, " ").trim();
    process.stdout.write(text.length > 200 ? text.slice(0, 199) + "…" : text);
  '
}

# The value of one field of a JSON result, or nothing: `{"result":{"field":…}}`
# and `{"field":…}` are both accepted.
json_field() { # json field
  JSON_TEXT=$1 JSON_FIELD=$2 node -e '
    let value;
    try { value = JSON.parse(process.env.JSON_TEXT); } catch (_) { process.exit(0); }
    const result = value && value.result && typeof value.result === "object" ? value.result : value;
    const field = result ? result[process.env.JSON_FIELD] : undefined;
    if (typeof field === "string" || typeof field === "number") process.stdout.write(String(field));
  '
}

# Reads a worker-start receipt (first dispatch or retry alike): the dispatch,
# Task and terminal it names go to RECEIPT_DISPATCH, RECEIPT_TASK and
# RECEIPT_TERMINAL. Returns 1, with RECEIPT_ERROR saying why in one line, when
# the call exited with the given status or the receipt lacks any of the three;
# what happens then is the caller's (a failed launch, or a parked retry).
read_receipt() { # out_file err_file status
  local out=$1 err_file=$2 status=$3 receipt
  RECEIPT_DISPATCH= RECEIPT_TASK= RECEIPT_TERMINAL= RECEIPT_ERROR=
  receipt=$(cat "$out" 2>/dev/null)
  RECEIPT_DISPATCH=$(json_field "$receipt" dispatchId)
  RECEIPT_TASK=$(json_field "$receipt" taskId)
  RECEIPT_TERMINAL=$(json_field "$receipt" terminal)
  if [ "$status" -eq 0 ] && [ -n "$RECEIPT_DISPATCH" ] && [ -n "$RECEIPT_TASK" ] && [ -n "$RECEIPT_TERMINAL" ]; then
    return 0
  fi
  RECEIPT_ERROR=$(first_error_line "$err_file" "$out")
  [ -n "$RECEIPT_ERROR" ] || RECEIPT_ERROR="worker-start 没有返回 dispatch（退出码 ${status}）"
  return 1
}

run_out=$(mktemp "${TMPDIR:-/tmp}/launch-wave-out.XXXXXX") || die "could not create a temporary output file"
run_err=$(mktemp "${TMPDIR:-/tmp}/launch-wave-err.XXXXXX") || die "could not create a temporary error file"
LOCK_HELD=0

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$LOCK_HELD" -eq 1 ]; then
    "$LOCK" release launch-wave --scope repo >/dev/null 2>&1 || true
  fi
  rm -f "$run_out" "$run_err"
  [ -n "${ORCA_LIST_FILE:-}" ] && rm -f "$ORCA_LIST_FILE"
  [ -n "${DISPATCH_DIR:-}" ] && rm -rf "$DISPATCH_DIR"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

acquire_launch_lock() {
  "$LOCK" acquire launch-wave --scope repo --wait "${ISS_LAUNCH_WAVE_LOCK_WAIT:-540}" ||
    die "could not acquire the launch-wave repository lock"
  LOCK_HELD=1
}

pipeline_args

if [ "$APPLY" -eq 1 ]; then
  acquire_launch_lock
fi

if [ "$NEXT_WAVE" -eq 1 ]; then
  "$PIPELINE_STATUS" "${PIPELINE_ARGS[@]}" || die "pipeline-status failed"
  printf '\n'
  read_plan "${PIPELINE_ARGS[@]}" --json
  CYCLES=$(plan_cycles)
  if [ -n "$CYCLES" ]; then
    cycle_report "$CYCLES"
    exit 2
  fi
  ENTRIES=$(next_wave_entries)
  next_wave_resume_hints
  if [ -z "$ENTRIES" ]; then
    printf '%s\n' '无可启动'
    exit 0
  fi
fi

if [ "$APPLY" -eq 0 ]; then
  if [ "$NEXT_WAVE" -ne 1 ]; then
    "$PIPELINE_STATUS" "${PIPELINE_ARGS[@]}" || die "pipeline-status failed"
    printf '\n'
    read_plan "${PIPELINE_ARGS[@]}" --json
    ENTRIES=$(plan_entries)
  fi

  IN_ORCA=0
  if orca_status > "$run_out" 2> "$run_err" && orca_worktrees; then
    IN_ORCA=1
  fi

  if [ -n "$ENTRIES" ]; then
    if [ "$IN_ORCA" -eq 1 ]; then
      printf '%s\n' '现在启动吗？会在 Orca 里自动运行：'
    else
      printf '%s\n' '不在 Orca 里，请在各 worktree 手动运行：'
    fi
  fi
  while IFS=$'\t' read -r kind spec command_json worktree_json; do
    [ -n "$kind" ] || continue
    command=$(decode_json_string "$command_json")
    worktree=$(decode_json_string "$worktree_json")
    if [ "$kind" = resume ]; then
      if [ -z "$worktree" ]; then
        printf ' #%s（恢复，找不到 worktree，需手动）\n' "$spec"
      elif [ "$IN_ORCA" -eq 1 ] && in_orca "$worktree"; then
        printf ' #%s（恢复，原 worktree）→ %s\n' "$spec" "$command"
      elif [ "$IN_ORCA" -eq 1 ] && in_orca "$MAIN_WORKTREE"; then
        printf ' #%s（恢复，Orca 列表外的 worktree）→ %s\n' "$spec" "$command"
      elif [ "$IN_ORCA" -eq 1 ]; then
        printf ' #%s（恢复，worktree 不在 Orca 列表里，需手动）→ cd %s 后运行 %s\n' \
          "$spec" "$worktree" "$command"
      else
        printf ' #%s（恢复，需手动）→ cd %s 后运行 %s\n' "$spec" "$worktree" "$command"
      fi
    elif [ "$IN_ORCA" -eq 1 ]; then
      printf ' #%s（新 worktree）→ %s\n' "$spec" "$command"
    else
      printf ' #%s → %s\n' "$spec" "$command"
    fi
  done <<EOF
$ENTRIES
EOF
  if [ -z "$ENTRIES" ]; then
    printf '%s\n' '没有可以启动的规格。'
  fi
  exit 0
fi

if ! orca_status > "$run_out" 2> "$run_err" || ! orca_worktrees; then
  printf '%s\n' '不在 Orca 里，无法自动启动。' >&2
  exit 2
fi

# The 编排 route decides which Orca agent slot starts a Spec session, and its
# profile is the launcher a person restarts a session with (a profile is its
# launcher's name: claude, claude-glm, claude-flash). Both are read here, once
# per wave before anything is changed, so a change to the table is picked up by
# the next dispatch; the stage is locked, so the profile is claude-flash unless
# the table cannot be read at all.
ORCHESTRATION_PROFILE=$("$STAGE_ROUTE" --print orchestration profile 2> "$run_err") ||
  die "could not read the 编排 route ($STAGE_ROUTE --print orchestration profile): $(first_line "$run_err")" 64
orchestration_agent() { # profile -> the Orca agent slot it starts a Spec session with
  case "$1" in
    claude-flash)
      printf '%s' openclaude
      ;;
    claude)
      printf '%s' claude
      ;;
    *)
      die "the 编排 route names the profile $1, which has no Orca agent slot to start a Spec session with" 64
      ;;
  esac
}
AGENT=$(orchestration_agent "$ORCHESTRATION_PROFILE") || exit $?

if ! "$MAX_WORKERS_CMD" "$WORKERS"; then
  die "max-workers failed"
fi

if [ "$NEXT_WAVE" -ne 1 ]; then
  read_plan "${PIPELINE_ARGS[@]}" --json
  ENTRIES=$(plan_entries)
fi

ONLY_SPECS=()
if [ -n "$ONLY" ]; then
  IFS=, read -r -a only_fields <<< "$ONLY"
  for field in "${only_fields[@]}"; do
    [[ "$field" =~ ^[0-9]+$ ]] || die "--only contains an invalid spec number: $field"
    duplicate=0
    if [ "${#ONLY_SPECS[@]}" -gt 0 ]; then
      for existing in "${ONLY_SPECS[@]}"; do
        if [ "$existing" = "$field" ]; then duplicate=1; break; fi
      done
    fi
    [ "$duplicate" -eq 1 ] || ONLY_SPECS+=("$field")
  done
fi

only_contains() {
  [ "${#ONLY_SPECS[@]}" -gt 0 ] || return 1
  if [ "${#ONLY_SPECS[@]}" -gt 0 ]; then
    for existing in "${ONLY_SPECS[@]}"; do
      [ "$existing" = "$1" ] && return 0
    done
  fi
  return 1
}

started=0
skipped=0
failed=0

if [ "${#ONLY_SPECS[@]}" -gt 0 ]; then
  available_specs=$(printf '%s\n' "$ENTRIES" | while IFS=$'\t' read -r kind spec command_json worktree_json; do
    [ -n "$kind" ] || continue
    worktree=$(decode_json_string "$worktree_json")
    if [ "$kind" = wave ] ||
       { [ "$kind" = resume ] && [ -n "$worktree" ] &&
         { in_orca "$worktree" || in_orca "$MAIN_WORKTREE"; }; }; then
      printf '%s\n' "$spec"
    fi
  done)
  for spec in "${ONLY_SPECS[@]}"; do
    if ! printf '%s\n' "$available_specs" | grep -Fxq -- "$spec"; then
      printf '#%s 已不可启动，跳过\n' "$spec"
      skipped=$((skipped + 1))
    fi
  done
fi

# The entries this run dispatches: everything, or the --only ones.
DISPATCH_ENTRIES=()
while IFS=$'\t' read -r kind spec command_json worktree_json; do
  [ -n "$kind" ] || continue
  if [ "${#ONLY_SPECS[@]}" -gt 0 ] && ! only_contains "$spec"; then
    continue
  fi
  DISPATCH_ENTRIES+=("$kind"$'\t'"$spec"$'\t'"$command_json"$'\t'"$worktree_json")
done <<EOF
$ENTRIES
EOF

# The Run of the wave, kept from the launch state when this run dispatches
# nothing (a --only that found nothing to launch must not leave an empty Run
# behind every time the keeper asks).
RUN_ID=$(state_string run)
if [ "${#DISPATCH_ENTRIES[@]}" -gt 0 ]; then
  # One Orca Run per wave, named in every dispatch: a Run inherited from the
  # terminal environment once delivered mail to the wrong session.
  orca_orchestration_run_create "Spec sessions of the development wave for $REPO" > "$run_out" 2> "$run_err" ||
    die "could not create the Orca Run for this wave: $(first_error_line "$run_err" "$run_out")"
  RUN_ID=$(node -e '
    let value;
    try { value = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (_) { process.exit(0); }
    const result = value && value.result;
    const id = result && (result.runId || result.id);
    if (typeof id === "string" && id !== "") process.stdout.write(id);
  ' < "$run_out")
  [ -n "$RUN_ID" ] || die "could not read the Orca Run id from run-create: $(first_error_line "$run_err" "$run_out")"
  printf 'Orca Run：%s（只用于派发与接管；接管用 orca orchestration run-use --id %s）\n' "$RUN_ID" "$RUN_ID"
fi

write_launch_state

if [ "${#DISPATCH_ENTRIES[@]}" -eq 0 ]; then
  printf '已启动 %s 份，跳过 %s 份，失败 %s 份。\n' "$started" "$skipped" "$failed"
  exit 0
fi

if ! git_main fetch origin "$MAIN_BRANCH" > "$run_out" 2> "$run_err"; then
  printf '警告：git fetch origin %s 失败，继续使用本地状态。\n' "$MAIN_BRANCH" >&2
fi

DISPATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/launch-wave-dispatch.XXXXXX") ||
  die "could not create a temporary dispatch directory"

# Undoes a launch that started nothing: the reservation goes, and a worktree
# this run created goes with its branch (a resumed Spec's worktree holds earlier
# work and stays). A branch left behind is deleted only while it is still at its
# base and attached to nothing, as before.
abandon_launch() { # spec kind created_path
  local branch branch_commit base_commit
  claim_main release "$1" --force >/dev/null 2>&1 || true
  if [ "$2" = wave ] && [ -n "${3:-}" ]; then
    orca_worktree_rm "$3" >/dev/null 2>&1 || true
  fi
  branch=spec-$1
  if git_main show-ref --verify --quiet "refs/heads/$branch" &&
     ! git_main worktree list --porcelain | grep -Fxq "branch refs/heads/$branch"; then
    branch_commit=$(git_main rev-parse --verify "$branch^{commit}" 2>/dev/null || true)
    base_commit=$(git_main rev-parse --verify "origin/$MAIN_BRANCH^{commit}" 2>/dev/null || true)
    if [ -n "$branch_commit" ] && [ "$branch_commit" = "$base_commit" ]; then
      git_main branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
}

# One record per Spec in $DISPATCH_DIR/<spec>.tsv, fields separated by the
# unit separator (a tab would not do: read folds runs of it, and the message
# field is empty for a pending Spec):
#   status, message, dispatch, task, terminal, worktree path, kind, command.
# pending means dispatched and waiting for its claim; skipped and failed are
# final (message says what happened); ignored is a Spec --only already reported.
US=$'\x1f'
write_result() { # spec status message dispatch task terminal path kind command
  printf '%s\n' "$2$US$3$US${4:-}$US${5:-}$US${6:-}$US${7:-}$US${8:-}$US${9:-}" > "$DISPATCH_DIR/$1.tsv"
}

reserve_failed_reason() { # reserve_output err_file status
  local reason
  reason=$(first_line "$2")
  [ -n "$reason" ] || reason=$(printf '%s\n' "$1" | sed -n '1p')
  [ -n "$reason" ] || reason="退出码 $3"
  one_line "$reason"
}

# Reserves the Spec, makes sure it has a worktree and dispatches the session
# into it. Runs in a subshell per Spec (see the dispatch loop), so it reports
# through its result record and never through die.
dispatch_spec() { # kind spec command worktree
  local kind=$1 spec=$2 command=$3 worktree=$4
  local reserve_output reserve_status reason= resume_worktree created=''
  local receipt_status=0 path err
  local spec_file=$DISPATCH_DIR/spec-$spec.md err_file=$DISPATCH_DIR/spec-$spec.err
  local create_out=$DISPATCH_DIR/spec-$spec.create.out
  local dispatch_out=$DISPATCH_DIR/spec-$spec.dispatch.out

  if [ "$kind" = resume ]; then
    if [ -z "$worktree" ] || { ! in_orca "$worktree" && ! in_orca "$MAIN_WORKTREE"; }; then
      if [ "${#ONLY_SPECS[@]}" -eq 0 ]; then
        if [ -z "$worktree" ]; then
          write_result "$spec" skipped " #${spec}（恢复，找不到 worktree，需手动）"
        else
          write_result "$spec" skipped " #${spec}（恢复，worktree 不在 Orca 列表里，需手动）→ cd $worktree 后运行 $command"
        fi
      else
        # --only already reported an unavailable resume spec above.
        write_result "$spec" ignored ''
      fi
      return
    fi
    reserve_output=$(claim_main reserve "$spec" --resume 2> "$err_file")
    reserve_status=$?
    if [ "$reserve_status" -ne 0 ]; then
      write_result "$spec" skipped "#$spec 恢复领取失败：$(reserve_failed_reason "$reserve_output" "$err_file" "$reserve_status")"
      return
    fi
    resume_worktree=$(printf '%s\n' "$reserve_output" | sed -n '1p')
    path=$resume_worktree
  else
    reserve_output=$(claim_main reserve "$spec" 2> "$err_file")
    reserve_status=$?
    if [ "$reserve_status" -eq 3 ]; then
      write_result "$spec" skipped "#$spec 已被其他会话领取：$(one_line "$(printf '%s\n' "$reserve_output" | sed -n '1p')")"
      return
    fi
    if [ "$reserve_status" -ne 0 ]; then
      write_result "$spec" skipped "#$spec 领取失败：$(reserve_failed_reason "$reserve_output" "$err_file" "$reserve_status")"
      return
    fi
    if ! orca_worktree_create_child "$MAIN_WORKTREE" "spec-$spec" "spec-$spec" "origin/$MAIN_BRANCH" \
         "$spec" "$MAIN_WORKTREE" < /dev/null > "$create_out" 2> "$err_file"; then
      err=$(first_error_line "$err_file" "$create_out")
      abandon_launch "$spec" wave ''
      write_result "$spec" failed "#$spec 启动失败：$(one_line "$err")"
      return
    fi
    created=$(extract_created_worktree "$(cat "$create_out")")
    if [ -z "$created" ]; then
      err=$(first_error_line "$err_file" "$create_out")
      [ -n "$err" ] || err='Orca 没有返回新工作区的路径'
      abandon_launch "$spec" wave ''
      write_result "$spec" failed "#$spec 启动失败：$(one_line "$err")"
      return
    fi
    path=$created
  fi

  # The spec is the generated command, exactly: the guards keyed on
  # /implement-spec-split read it from the session's transcript.
  printf '%s\n' "$command" > "$spec_file"
  orca_orchestration_worker_dispatch "$RUN_ID" --worktree "$path" --agent "$AGENT" \
    --spec-file "$spec_file" --timeout-ms "$START_TIMEOUT_MS" \
    < /dev/null > "$dispatch_out" 2> "$err_file" || receipt_status=$?
  if ! read_receipt "$dispatch_out" "$err_file" "$receipt_status"; then
    abandon_launch "$spec" "$kind" "$created"
    write_result "$spec" failed "#$spec 启动失败：$(one_line "$RECEIPT_ERROR")"
    return
  fi
  write_result "$spec" pending '' "$RECEIPT_DISPATCH" "$RECEIPT_TASK" "$RECEIPT_TERMINAL" "$path" "$kind" "$command"
}

# Every Spec is dispatched before any claim is waited for, each in its own
# subshell: a session that takes minutes to take its spec holds up nobody.
DISPATCH_PIDS=()
DISPATCH_ORDER=()
for entry in "${DISPATCH_ENTRIES[@]}"; do
  IFS=$'\t' read -r kind spec command_json worktree_json <<< "$entry"
  command=$(decode_json_string "$command_json")
  worktree=$(decode_json_string "$worktree_json")
  DISPATCH_ORDER+=("$spec")
  dispatch_spec "$kind" "$spec" "$command" "$worktree" &
  DISPATCH_PIDS+=($!)
done
for pid in "${DISPATCH_PIDS[@]+"${DISPATCH_PIDS[@]}"}"; do
  wait "$pid"
done

# Entries still waiting for their claim, unit-separated: spec, dispatch, task,
# terminal, worktree path, attempts, kind, command, deadline (epoch seconds).
PENDING=()
for spec in "${DISPATCH_ORDER[@]+"${DISPATCH_ORDER[@]}"}"; do
  status=; message=; dispatch=; task=; terminal=; path=; kind=; command=
  if [ -f "$DISPATCH_DIR/$spec.tsv" ]; then
    IFS=$US read -r status message dispatch task terminal path kind command < "$DISPATCH_DIR/$spec.tsv"
  fi
  case "$status" in
    pending)
      PENDING+=("$spec$US$dispatch$US$task$US$terminal$US$path${US}1$US$kind$US$command$US$(( $(now_epoch) + CLAIM_WAIT ))")
      ;;
    skipped)
      [ -n "$message" ] && printf '%s\n' "$message"
      skipped=$((skipped + 1))
      ;;
    ignored)
      ;;
    *)
      if [ -z "$message" ]; then
        message="#$spec 启动失败：launch-wave 内部错误（没有派发结果）"
      fi
      printf '%s\n' "$message"
      failed=$((failed + 1))
      ;;
  esac
done

# The first line of what `claim.sh status` says about the Spec.
claim_status_line() { # spec
  claim_main status "$1" 2>/dev/null | sed -n '1p'
}

# A field of the Spec's claim record once status prints one (active or
# interrupted: a session that claimed and then died did claim); nothing when
# the record is free or has no such field. The pid is what a session running
# claim.sh take writes; the Handoff reservation launch-wave writes has null.
claim_record_field() { # spec field
  local line
  line=$(claim_status_line "$1") || return 1
  printf '%s\n' "$line" | FIELD=$2 node -e '
    const fs = require("fs");
    let line = "";
    try { line = fs.readFileSync(0, "utf8").trim().split("\n")[0]; } catch (_) {}
    const match = /^(active|interrupted)\s+(\{.*\})\s*$/.exec(line);
    if (!match) process.exit(0);
    try {
      const record = JSON.parse(match[2]);
      const value = record[process.env.FIELD];
      if (Number.isSafeInteger(value) && value > 0) process.stdout.write(String(value));
    } catch (_) {}
  '
}

# Reads the terminal the session was dispatched to and sets VERDICT to one of
# exited, not_started, moving, unknown, with TERMINAL_NOTE saying what was
# read. The rendered screen comes first; an empty read (the process exited, or
# the screen is unavailable) is followed by terminal show's preview, which
# survives the exit. A read that says nothing is never read as "not started":
#   exited        the process is gone (Orca's one verdict that authorizes a stop)
#   moving        assistant output on screen: the session is working
#   not_started   a TUI that never saw the spec typed into it
#   unknown       anything else, including an empty terminal still running
terminal_verdict() { # handle spec -> VERDICT, TERMINAL_NOTE
  local handle=$1 spec=$2 read_file=$DISPATCH_DIR/spec-$2.read.json show_file=$DISPATCH_DIR/spec-$2.show.json
  local parsed
  orca_terminal_read "$handle" --screen > "$read_file" 2> "$run_err" || true
  orca_terminal_show "$handle" > "$show_file" 2> /dev/null || true
  parsed=$(READ_FILE="$read_file" SHOW_FILE="$show_file" SPEC="$spec" node <<'NODE'
const fs = require("fs");
const env = process.env;
function terminal(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    const result = value && value.result;
    if (result && result.terminal && typeof result.terminal === "object") return result.terminal;
    if (result && typeof result === "object") return result;
    return value && typeof value === "object" ? value : {};
  } catch (_) { return {}; }
}
const read = terminal(env.READ_FILE), show = terminal(env.SHOW_FILE);
const status = String(read.status || show.status || "");
let text = Array.isArray(read.tail) ? read.tail.map(String).join("\n") : "";
let source = "screen";
if (text.trim() === "") {
  const preview = String(show.preview || "");
  if (preview.trim() !== "") { text = preview; source = "preview"; }
}
// The idle TUI's welcome box carries a ✳ too, so the spinner alone is no
// sign of work: only the assistant's own output, or the states that say it
// is producing some, count.
const working = /⏺|⎿|esc to interrupt|Thinking/.test(text);
let verdict;
if (status === "exited") verdict = "exited";
else if (working) verdict = "moving";
else if (text.trim() !== "" && !text.includes(`/implement-spec-split ${env.SPEC}`)) verdict = "not_started";
else verdict = "unknown";
const lines = text.split("\n").map((line) => line.trim()).filter(Boolean);
const summary = (lines.slice(-3).join(" / ") || "无内容").slice(0, 160);
process.stdout.write([verdict, `${source}/${status || "状态未知"}：${summary}`].join("\t"));
NODE
)
  VERDICT=${parsed%%$'\t'*}
  TERMINAL_NOTE=${parsed#*$'\t'}
}

# A parked Spec: nothing more is started for it here. release=1 only when its
# process is known to have exited, or its idle session was confirmed stopped by
# Orca; otherwise the reservation is left to expire so that a session that is
# merely slow is not started twice. Either way the lines name what was seen,
# the Run and the dispatch, and how to restart.
park_spec() { # spec reason dispatch path command release
  local spec=$1 reason=$2 dispatch=$3 path=$4 command=$5 restart launcher=$ORCHESTRATION_PROFILE
  if [ "$6" = 1 ]; then
    claim_main release "$spec" --force >/dev/null 2>&1 || true
    restart="launch-wave.sh --repo $REPO --only $spec --apply"
  else
    # The 编排 route's profile is the launcher: never a constant here.
    restart="确认该终端已停后 cd $path 运行 ${launcher} '$command'，或等预留到期后运行 launch-wave.sh --repo $REPO --only $spec --apply"
  fi
  printf '#%s 停车：%s；Run %s，dispatch %s。\n' "$spec" "$reason" "$RUN_ID" "$dispatch"
  printf '  重新启动：%s\n' "$restart"
  failed=$((failed + 1))
}

TIMEOUT_ENTRY=
# The wait for this Spec ran out. Sets TIMEOUT_ENTRY to the entry to keep
# waiting for (a retry, or an extended wait) or leaves it empty when the Spec
# is settled (reported, or parked).
handle_timeout() { # spec dispatch task terminal path attempts kind command now
  TIMEOUT_ENTRY=
  local spec=$1 dispatch=$2 task=$3 terminal=$4 path=$5 attempts=$6 kind=$7 command=$8 now=$9
  local verdict note receipt_status=0 until cap_deadline
  local retry_out=$DISPATCH_DIR/spec-$spec.retry.out retry_err=$DISPATCH_DIR/spec-$spec.retry.err
  local stop_out=$DISPATCH_DIR/spec-$spec.stop.out
  terminal_verdict "$terminal" "$spec"
  verdict=$VERDICT
  note=$TERMINAL_NOTE

  # A retry that did not start either is the end of the road: one that exited
  # parks at once; one that sits idle is stopped on the same evidence as the
  # first time (a TUI up without the spec) and parks once Orca confirms the
  # stop, reservation released, so that --only runs again at once and no idle
  # TUI is left holding the slot. A retry whose terminal is working gets the
  # same extended wait as the first dispatch did, and the same report at the
  # cap: "still failing after the retry" means it still did not claim, not
  # that its terminal is busy.
  if [ "$verdict" != moving ] && [ "$attempts" -ge 2 ]; then
    if [ "$verdict" = not_started ]; then
      if orca_orchestration_worker_stop "$dispatch" > "$stop_out" 2> "$run_err"; then
        park_spec "$spec" "重派后仍没开始，已停掉（终端 ${note}）" "$dispatch" "$path" "$command" 1
      else
        park_spec "$spec" "重派后仍没开始，要停掉但无法确认原会话已停（worker-stop：$(one_line "$(first_error_line "$run_err" "$stop_out")")；终端 ${note}）" \
          "$dispatch" "$path" "$command" 0
      fi
    else
      park_spec "$spec" "重派后仍未认领（终端 ${note}）" "$dispatch" "$path" "$command" \
        "$([ "$verdict" = exited ] && printf 1 || printf 0)"
    fi
    return
  fi

  case "$verdict" in
    exited|not_started)
      if ! orca_orchestration_worker_stop "$dispatch" > "$stop_out" 2> "$run_err"; then
        if [ "$verdict" = exited ]; then
          # Orca's own rule: an exited process is proof enough to retry.
          printf '警告：#%s 的 worker-stop 失败（终端已退出，照常重派）：%s\n' \
            "$spec" "$(one_line "$(first_error_line "$run_err" "$stop_out")")" >&2
        else
          park_spec "$spec" "要重派但无法确认原会话已停（worker-stop：$(one_line "$(first_error_line "$run_err" "$stop_out")")；终端 ${note}）" \
            "$dispatch" "$path" "$command" 0
          return
        fi
      fi
      orca_orchestration_worker_dispatch "$RUN_ID" --worktree "$path" --agent "$AGENT" \
        --task "$task" --retry-of "$dispatch" --timeout-ms "$START_TIMEOUT_MS" \
        < /dev/null > "$retry_out" 2> "$retry_err" || receipt_status=$?
      if ! read_receipt "$retry_out" "$retry_err" "$receipt_status"; then
        park_spec "$spec" "确认没开始（终端 ${note}），停掉后重派失败：$(one_line "$RECEIPT_ERROR")" \
          "$dispatch" "$path" "$command" 1
        return
      fi
      printf '#%s 没开始（%s），已停掉并重派一次（dispatch %s）。\n' "$spec" "$note" "$RECEIPT_DISPATCH"
      TIMEOUT_ENTRY="$spec$US$RECEIPT_DISPATCH$US$RECEIPT_TASK$US$RECEIPT_TERMINAL$US$path${US}2$US$kind$US$command$US$(( $(now_epoch) + CLAIM_WAIT ))"
      ;;
    moving)
      until=$(claim_record_field "$spec" handoff_until_epoch)
      cap_deadline=$((now + CLAIM_WAIT))
      if [ -n "$until" ] && [ "$until" -lt "$cap_deadline" ]; then
        cap_deadline=$until
      fi
      if [ "$cap_deadline" -le "$now" ]; then
        printf '#%s 仍未认领（终端在动，已等到预留到期）：%s；Run %s，dispatch %s。不重派。\n' \
          "$spec" "$note" "$RUN_ID" "$dispatch"
        skipped=$((skipped + 1))
        return
      fi
      printf '#%s 尚未认领但终端在动（%s），延长等待。\n' "$spec" "$note"
      TIMEOUT_ENTRY="$spec$US$dispatch$US$task$US$terminal$US$path$US$attempts$US$kind$US$command$US$cap_deadline"
      ;;
    *)
      park_spec "$spec" "判断不了（终端 ${note}）" "$dispatch" "$path" "$command" 0
      ;;
  esac
}

while [ "${#PENDING[@]}" -gt 0 ]; do
  now=$(now_epoch)
  next=()
  for entry in "${PENDING[@]}"; do
    IFS=$US read -r spec dispatch task terminal path attempts kind command deadline <<< "$entry"
    # A deadline that did not survive the trip counts as passed: the loop must
    # always end, and the timeout branch is what ends it.
    valid_non_negative "${deadline:-}" || deadline=$now
    if [ -n "$(claim_record_field "$spec" pid || true)" ]; then
      printf '#%s 已启动：%s（Run %s，dispatch %s）\n' "$spec" "$path" "$RUN_ID" "$dispatch"
      started=$((started + 1))
      continue
    fi
    if [ "$now" -ge "$deadline" ]; then
      handle_timeout "$spec" "$dispatch" "$task" "$terminal" "$path" "$attempts" "$kind" "$command" "$now"
      [ -z "$TIMEOUT_ENTRY" ] || next+=("$TIMEOUT_ENTRY")
      continue
    fi
    next+=("$entry")
  done
  PENDING=("${next[@]+"${next[@]}"}")
  [ "${#PENDING[@]}" -gt 0 ] && sleep "$CLAIM_POLL"
done

printf '已启动 %s 份，跳过 %s 份，失败 %s 份。\n' "$started" "$skipped" "$failed"
[ "$failed" -eq 0 ] || exit 1
exit 0
