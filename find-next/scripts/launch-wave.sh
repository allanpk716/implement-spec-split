#!/usr/bin/env bash
# Launch the first development wave in Orca after find-next publishes specs.

set -u

usage() {
  cat <<'EOF'
Usage: launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart A:B]...
                      [--only 222,237] [--apply] [--next-wave]
                      [--impl codex|agent] [--agent-model sonnet|opus|haiku|fable]

Print the development order, then optionally reserve and launch its first wave.
Without --apply, this script only shows what would run and makes no claims.
--workers falls back to the launch state and then the machine-wide max-workers
file. In --next-wave, --specs and --apart also fall back to the launch state.
--next-wave is for the end of an implement-spec-split Run: it launches only free
first-wave Specs, never resumes interrupted ones, and refuses cycles.
When the main worktree is Orca-managed, resumed worktrees outside Orca use a terminal tab in it.
--impl picks the backend named in the generated commands: codex (default) or
agent. With agent, --agent-model names the model (default sonnet) and every
command gets "--impl agent --agent-model <model>" instead of "--impl codex".
--apply records the backend in the launch state and --next-wave reuses it;
state files without the field keep the codex backend. --agent-model is only
valid together with --impl agent.
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
IMPL=codex
AGENT_MODEL=sonnet
IMPL_GIVEN=0
AGENT_MODEL_GIVEN=0
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
    --impl)
      [ $# -ge 2 ] || die "--impl requires <codex|agent>"
      case "$2" in
        codex|agent) IMPL=$2 ;;
        *) die "--impl requires codex or agent (use --impl agent --agent-model <model>)" ;;
      esac
      IMPL_GIVEN=1
      shift 2
      ;;
    --agent-model)
      [ $# -ge 2 ] || die "--agent-model requires <sonnet|opus|haiku|fable>"
      case "$2" in
        sonnet|opus|haiku|fable) AGENT_MODEL=$2 ;;
        *) die "--agent-model must be sonnet, opus, haiku or fable" ;;
      esac
      AGENT_MODEL_GIVEN=1
      shift 2
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

[ -n "$REPO" ] || die "--repo is required"
[[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] ||
  die "--repo must be <owner/name>"
[ "$AGENT_MODEL_GIVEN" -eq 0 ] || [ "$IMPL" = agent ] ||
  die "--agent-model requires --impl agent; drop it or switch to the agent backend"

PIPELINE_STATUS=${ISS_PIPELINE_STATUS:-$SKILL_ROOT/scripts/pipeline-status.sh}
CLAIM=${ISS_CLAIM:-$SKILL_ROOT/scripts/claim.sh}
MAX_WORKERS_CMD=${ISS_MAX_WORKERS_CMD:-$SKILL_ROOT/scripts/max-workers.sh}
ORCA=${ISS_ORCA:-orca}
LOCK=${ISS_LOCK:-$SKILL_ROOT/scripts/lock.sh}
LAUNCH_STATE_DIR=${ISS_LAUNCH_STATE_DIR:-$HOME/.cache/implement-spec-split/launch}
WORKER_STATE_DIR=${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}
LAUNCH_STATE_FILE="$LAUNCH_STATE_DIR/${REPO/\//__}.json"
MAX_WORKERS_FILE="$WORKER_STATE_DIR/max-workers"

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

valid_positive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
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

read_next_wave_state() {
  local value pair
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
  if [ "$IMPL_GIVEN" -eq 0 ]; then
    value=$(state_string impl)
    case "$value" in
      agent)
        IMPL=agent
        ;;
      codex|'')
        IMPL=codex
        ;;
      *)
        die "launch state contains an invalid backend: $value"
        ;;
    esac
  fi
  if [ "$IMPL" = agent ] && [ "$AGENT_MODEL_GIVEN" -eq 0 ]; then
    value=$(state_string agent_model)
    case "$value" in
      sonnet|opus|haiku|fable)
        AGENT_MODEL=$value
        ;;
      '')
        AGENT_MODEL=sonnet
        ;;
      *)
        die "launch state contains an invalid agent model: $value"
        ;;
    esac
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
  STATE_IMPL="$IMPL" STATE_AGENT_MODEL="$AGENT_MODEL" \
  STATE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) node -e '
    const fs = require("fs"), path = require("path");
    const apart = process.env.STATE_APART.split(/\r?\n/).filter(Boolean);
    const backend = process.env.STATE_IMPL === "agent"
      ? {impl: "agent", agent_model: process.env.STATE_AGENT_MODEL}
      : {};
    const value = JSON.stringify({
      workers: +process.env.STATE_WORKERS,
      specs: +process.env.STATE_SPECS,
      apart,
      ...backend,
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

first_error_line() {
  local value
  value=$(first_line "$2")
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  first_line "$1"
}

pipeline_args() {
  PIPELINE_ARGS=(--order --repo "$REPO" --parallel "$SPECS" --workers "$WORKERS")
  if [ "$IMPL" = agent ]; then
    PIPELINE_ARGS+=(--cmd-suffix "--impl agent --agent-model $AGENT_MODEL")
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
  ORCA_LIST=$("$ORCA" worktree list --json 2>/dev/null)
  node -e 'JSON.parse(process.argv[1])' "$ORCA_LIST" >/dev/null 2>&1
}

in_orca() {
  node - "$1" "$ORCA_LIST" <<'NODE'
const fs = require('fs');
function real(value) {
  try { return fs.realpathSync(value); } catch (_) { return value; }
}
const wanted = real(process.argv[2]);
const value = JSON.parse(process.argv[3]);
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
  if "$ORCA" status --json > "$run_out" 2> "$run_err" && orca_worktrees; then
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
        printf ' #%s（恢复，在主工作树开终端标签）→ cd %s 后运行 %s\n' \
          "$spec" "$worktree" "$command"
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

if ! "$ORCA" status --json > "$run_out" 2> "$run_err" || ! orca_worktrees; then
  printf '%s\n' '不在 Orca 里，无法自动启动。' >&2
  exit 2
fi

if ! "$MAX_WORKERS_CMD" "$WORKERS"; then
  die "max-workers failed"
fi

if [ "$NEXT_WAVE" -ne 1 ]; then
  read_plan "${PIPELINE_ARGS[@]}" --json
  ENTRIES=$(plan_entries)
fi

write_launch_state

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

if ! git_main fetch origin "$MAIN_BRANCH" > "$run_out" 2> "$run_err"; then
  printf '警告：git fetch origin %s 失败，继续使用本地状态。\n' "$MAIN_BRANCH" >&2
fi

while IFS=$'\t' read -r kind spec command_json worktree_json; do
  [ -n "$kind" ] || continue
  if [ "${#ONLY_SPECS[@]}" -gt 0 ] && ! only_contains "$spec"; then
    continue
  fi
  command=$(decode_json_string "$command_json")
  worktree=$(decode_json_string "$worktree_json")

  if [ "$kind" = resume ]; then
    if [ -z "$worktree" ] ||
       { ! in_orca "$worktree" && ! in_orca "$MAIN_WORKTREE"; }; then
      if [ "${#ONLY_SPECS[@]}" -eq 0 ]; then
        if [ -z "$worktree" ]; then
          printf ' #%s（恢复，找不到 worktree，需手动）\n' "$spec"
        else
          printf ' #%s（恢复，worktree 不在 Orca 列表里，需手动）→ cd %s 后运行 %s\n' \
            "$spec" "$worktree" "$command"
        fi
      else
        # --only already reported an unavailable resume spec above.
        continue
      fi
      skipped=$((skipped + 1))
      continue
    fi

    reserve_output=$(claim_main reserve "$spec" --resume 2> "$run_err")
    reserve_status=$?
    if [ "$reserve_status" -ne 0 ]; then
      reason=$(first_line "$run_err")
      [ -n "$reason" ] || reason=$(printf '%s\n' "$reserve_output" | sed -n '1p')
      [ -n "$reason" ] || reason="退出码 $reserve_status"
      printf '#%s 恢复领取失败：%s\n' "$spec" "$reason"
      skipped=$((skipped + 1))
      continue
    fi
    resume_worktree=$(printf '%s\n' "$reserve_output" | sed -n '1p')
    if in_orca "$worktree"; then
      if "$ORCA" agent launch --agent claude --worktree "path:$resume_worktree" \
        --prompt "$command" --json < /dev/null > "$run_out" 2> "$run_err"; then
        printf '#%s 已启动：%s\n' "$spec" "$resume_worktree"
        started=$((started + 1))
      else
        claim_main release "$spec" --force >/dev/null 2>&1 || true
        printf '#%s 启动失败：%s\n' "$spec" "$(first_error_line "$run_err" "$run_out")"
        failed=$((failed + 1))
      fi
    else
      escaped_worktree=$(printf '%q' "$worktree")
      escaped_command=$(printf '%q' "$command")
      if "$ORCA" terminal create --worktree "path:$MAIN_WORKTREE" \
        --title "spec-$spec" \
        --command "cd $escaped_worktree && claude $escaped_command" \
        --json < /dev/null > "$run_out" 2> "$run_err"; then
        printf '#%s 已启动：%s（挂在主工作树的终端标签 spec-%s）\n' \
          "$spec" "$worktree" "$spec"
        started=$((started + 1))
      else
        claim_main release "$spec" --force >/dev/null 2>&1 || true
        printf '#%s 启动失败：%s\n' "$spec" "$(first_error_line "$run_err" "$run_out")"
        failed=$((failed + 1))
      fi
    fi
    continue
  fi

  reserve_output=$(claim_main reserve "$spec" 2> "$run_err")
  reserve_status=$?
  if [ "$reserve_status" -eq 3 ]; then
    status_line=$(printf '%s\n' "$reserve_output" | sed -n '1p')
    printf '#%s 已被其他会话领取：%s\n' "$spec" "$status_line"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$reserve_status" -ne 0 ]; then
    reason=$(first_line "$run_err")
    [ -n "$reason" ] || reason=$(printf '%s\n' "$reserve_output" | sed -n '1p')
    [ -n "$reason" ] || reason="退出码 $reserve_status"
    printf '#%s 领取失败：%s\n' "$spec" "$reason"
    skipped=$((skipped + 1))
    continue
  fi

  if "$ORCA" worktree create --repo "path:$MAIN_WORKTREE" --name "spec-$spec" \
    --branch "spec-$spec" --base-branch "origin/$MAIN_BRANCH" --issue "$spec" \
    --no-parent --agent claude --prompt "$command" --json < /dev/null > "$run_out" 2> "$run_err"; then
    created=$(extract_created_worktree "$(cat "$run_out")")
    [ -n "$created" ] || created='路径未知'
    printf '#%s 已启动：%s\n' "$spec" "$created"
    started=$((started + 1))
  else
    claim_main release "$spec" --force >/dev/null 2>&1 || true
    branch=spec-$spec
    if git_main show-ref --verify --quiet "refs/heads/$branch" &&
       ! git_main worktree list --porcelain | grep -Fxq "branch refs/heads/$branch"; then
      branch_commit=$(git_main rev-parse --verify "$branch^{commit}" 2>/dev/null || true)
      base_commit=$(git_main rev-parse --verify "origin/$MAIN_BRANCH^{commit}" 2>/dev/null || true)
      if [ -n "$branch_commit" ] && [ "$branch_commit" = "$base_commit" ]; then
        git_main branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    printf '#%s 启动失败：%s\n' "$spec" "$(first_error_line "$run_err" "$run_out")"
    failed=$((failed + 1))
  fi
done <<EOF
$ENTRIES
EOF

printf '已启动 %s 份，跳过 %s 份，失败 %s 份。\n' "$started" "$skipped" "$failed"
[ "$failed" -eq 0 ] || exit 1
exit 0
