#!/usr/bin/env bash
# The Stage route table (GLOSSARY.md "Stage route", ADR 0004): which Launcher
# profile, model and reasoning effort each of the six stages runs on, with an
# optional expiry. It replaces the two older switches, scripts/judgment-model.sh
# and scripts/worker-model.sh, and coexists with them until every reader has
# moved here (issues #32, #33, #34) and the old scripts are deleted (#38).
#
# A change takes effect at the stage's next dispatch or next new session. A
# session or worker that is already executing is never switched mid-call.
#
# Stages (the English names of the GLOSSARY "Stage" entry):
#   orchestration   编排      the flash main session the user types into; locked
#   design          讨论      Design sessions (scripts/design-session.sh, #34)
#   research        调研起草  codex worker dispatches with --read-only (#32)
#   implementation  实现      codex worker dispatches without --read-only (#32)
#   review          审查      scripts/opus-review.sh --kind code|draft (#33)
#   diagnosis       诊断      scripts/opus-review.sh --kind diagnose (#33)
#
# Usage:
#   stage-route.sh                               show the six routes
#   stage-route.sh use <stage>=<profile>/<model>/<effort> [<stage>=... ...]
#                    [--until <time> | --for <duration>]
#   stage-route.sh --print <stage> [profile|model|effort|until]
#   stage-route.sh --launch <stage> <interactive|headless>
#   stage-route.sh migrate                       (reserved for #29)
#
#   use sets every stage it names and leaves the others alone. The value is the
#   whole route, e.g. `use review=claude-glm/glm-5.4/medium`; setting a stage
#   back to its default route (the route its status line shows as 默认, or
#   names after 切回用) drops it from the table. One command sets several:
#   `use design=claude-glm/glm-5.4/high review=claude-glm/glm-5.4/medium`.
#   --until   an ISO 8601 time with its UTC offset, e.g. 2026-11-28T10:00:00+08:00
#   --for     a duration, e.g. 5h, 30m, 2d12h; same as --until now + duration
#   Either applies to every stage the command sets; once reached, each of them
#   is back on its default. Without one they stay as set until changed again.
#   When a command leaves review and implementation on the same model, one
#   warning says so on stderr; the routes are set all the same.
#
# The table is $HOME/.claude/state/stage-route (ISS_STAGE_ROUTE_FILE names
# another file). It holds one line per stage that is not on its default:
# `<stage>=<profile>/<model>/<effort>` plus `@<epoch seconds>` when it expires.
# Reading it:
#   missing line, expired line, or a line outside the verified catalog (a
#   combination not listed for the stage, or an effort the profile does not
#   take)                                      that stage is on its default;
#                                              an expired or unknown line is
#                                              named on stderr and in the status
#   a file that does not parse as a table      all six are on their default and
#                                              one line on stderr says so
# The hints go to stderr and never change the exit code: --print's stdout is
# read with $(...) by the dispatch scripts and holds nothing but the value.
#
# Default routes: orchestration claude-flash / glm-5.3-flash (locked, effort
# left to the launcher's own config); design claude / opus / high; research
# codex-glm / glm-5.4 / high; implementation claude-glm / glm-5.4 / high;
# review claude / opus / high; diagnosis the same as review.
#
# Verified catalog. `use` only accepts a (profile, model) pair for a stage it is
# listed under here, and each listing rests on a smoke test recorded in this
# repository:
#   claude / opus               design, review, diagnosis   the long-standing default
#   claude-glm / glm-5.4        design, review, diagnosis   opus-review.sh through claude-glm,
#                                                            headless smoke (MAINTAINING
#                                                            "尚未验证的事项") and two
#                                                            findings of 2026-11-27
#   claude-glm / glm-5.4        implementation               docs/orca-smoke-2026-11-27.md 2.1
#   claude-flash / glm-5.4      design                      docs/orca-smoke-2026-11-27.md 2.2
#   codex-glm / glm-5.4         research, implementation     codex worker's current default
#   codex-glm / glm-5.3         research, implementation     codex worker's default before
#                                                            2026-11-23
#   claude-flash / glm-5.3-flash orchestration               the locked default, nothing else
# codex-glm / glm-5.3-flash is not listed (docs/codex-backend.md E17) and
# neither is anything else without evidence.
#
# Launcher profiles (GLOSSARY.md "Launcher profile"). The table names a profile,
# never an Orca agent. `claude` is the bare official launcher; there is no
# claude-official command.
#   profile      launcher       model passed as        effort passed as    forms
#   claude       claude         --model <model>         --effort <effort>   interactive, headless (-p)
#   claude-glm   claude-glm     --model <model>[1m]     --effort <effort>   interactive, headless (-p)
#   claude-flash claude-flash   --model <model>[1m]     --effort <effort>   interactive, headless (-p)
#   codex-glm    codex          -m <model>              -c model_reasoning_effort=<effort>
#                                                            interactive, headless (exec)
# claude, claude-glm and claude-flash accept low, medium, high, xhigh and max;
# codex-glm accepts low, medium, high and xhigh (codex has no max). The [1m]
# suffix is the GLM launchers' own convention for their 1M-context models
# (glm-5.4, glm-5.3-flash): Claude Code assumes 200k for a model it does not
# recognise, so the suffix keeps the 1M window these launchers already give
# their opus and sonnet tiers. codex-glm has no launcher of its own: it is codex
# on the GLM provider, run headless through scripts/codex-worker.sh, which adds
# the provider and worker-home settings around the two arguments above.
#
# --launch prints the command that starts a stage's profile with its model and
# effort, one argument per line: the launcher on the first line, then its
# arguments. Nothing in it needs quoting. Read it into an array (the Mac's
# /usr/bin/env bash is 3.2, which has no mapfile):
#   args=(); while IFS= read -r arg; do args+=("$arg"); done \
#     < <(stage-route.sh --launch design interactive)
# then run "${args[@]}", or quote each argument when one string is needed
# (`printf '%q '`), as for `orca terminal create --command`. The locked
# orchestration stage is a usage error with nothing on stdout: no script starts
# it.
#
# --print is what the dispatch scripts call. With a field it prints that one
# value of the stage's effective route; with the stage alone it prints the
# stage's status line. `until` prints nothing at all (no line) when the stage
# has no expiry. A missing, expired, unknown or broken table still prints the
# default: profile, model and effort always have a value (orchestration has no
# effort in the table, see exit code 66).
#
# Exit codes:
#   0  done
#   64 bad usage: an unknown stage, field, profile or form; a combination outside
#      the catalog; an effort the profile does not take; the locked stage
#   65 the table could not be written
#   66 --print or --launch has no value to print (the orchestration stage has no
#      effort in the table); nothing is printed

set -u

STATE_FILE=${ISS_STAGE_ROUTE_FILE:-$HOME/.claude/state/stage-route}
STAGES='orchestration design research implementation review diagnosis'
PROFILES='claude claude-glm claude-flash codex-glm'
LOCKED=orchestration

# The default routes, one per line, in the syntax of `use`.
DEFAULTS='orchestration=claude-flash/glm-5.3-flash/
design=claude/opus/high
research=codex-glm/glm-5.4/high
implementation=claude-glm/glm-5.4/high
review=claude/opus/high
diagnosis=claude/opus/high'

# The verified catalog: a (profile, model) pair and the stages it is verified
# for. The header says what evidence stands behind each line. The lines are
# ordered so that a stage's default pair comes first in what a refusal lists.
CATALOG='claude/opus design review diagnosis
claude-glm/glm-5.4 design review diagnosis implementation
claude-flash/glm-5.4 design
codex-glm/glm-5.4 research implementation
codex-glm/glm-5.3 research implementation
claude-flash/glm-5.3-flash orchestration'

die() {
  echo "stage-route: $*" >&2
  exit 64
}

cannot_write() {
  echo "stage-route: $*" >&2
  exit 65
}

cannot_answer() {
  echo "stage-route: $*" >&2
  exit 66
}

show_help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

is_known_stage() {
  case " $STAGES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

is_known_profile() {
  case " $PROFILES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

stage_label() {
  case "$1" in
    orchestration) printf '编排（orchestration）' ;;
    design) printf '讨论（design）' ;;
    research) printf '调研起草（research）' ;;
    implementation) printf '实现（implementation）' ;;
    review) printf '审查（review）' ;;
    diagnosis) printf '诊断（diagnosis）' ;;
  esac
}

# Prints the (profile, model) pairs verified for a stage, joined by ", ".
catalog_for_stage() {
  local pair stages found=
  while read -r pair stages; do
    case " $stages " in
      *" $1 "*) found="${found:+$found, }$pair" ;;
    esac
  done <<< "$CATALOG"
  printf '%s' "$found"
}

# Succeeds when the catalog lists the pair for the stage.
is_verified() {
  local pair stages
  while read -r pair stages; do
    [ "$pair" = "$1/$2" ] || continue
    case " $stages " in
      *" $3 "*) return 0 ;;
    esac
  done <<< "$CATALOG"
  return 1
}

# Prints the efforts a profile takes, space separated.
profile_efforts() {
  case "$1" in
    codex-glm) printf 'low medium high xhigh' ;;
    *) printf 'low medium high xhigh max' ;;
  esac
}

takes_effort() {
  case " $(profile_efforts "$1") " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# Prints the efforts of a profile the way a message lists them.
list_efforts() {
  local effort out=
  for effort in $(profile_efforts "$1"); do
    out="${out:+$out, }$effort"
  done
  printf '%s' "$out"
}

# Prints the default route of a stage as <profile>/<model>/<effort>.
default_route() {
  local line
  while IFS= read -r line; do
    [ "${line%%=*}" != "$1" ] || { printf '%s\n' "${line#*=}"; return 0; }
  done <<< "$DEFAULTS"
}

# Loads the table into R_<stage>_PROFILE, R_<stage>_MODEL, R_<stage>_EFFORT and
# R_<stage>_UNTIL, all empty for a stage without a line. A line that is not
# `<stage>=<profile>/<model>/<effort>[@<epoch>]` makes the whole table unread:
# every R_ variable is left empty, TABLE_CORRUPT is 1 and one line goes to
# stderr unless READ_QUIET is set.
TABLE_CORRUPT=0
READ_QUIET=

read_table() {
  local stage line raw key value profile model effort until number=0
  TABLE_CORRUPT=0
  for stage in $STAGES; do
    eval "R_${stage}_PROFILE=; R_${stage}_MODEL=; R_${stage}_EFFORT=; R_${stage}_UNTIL="
  done
  [ -f "$STATE_FILE" ] && [ -r "$STATE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    raw=$line
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    if ! is_known_stage "$key" ||
      ! [[ "$value" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/([a-z]+)(@([0-9]+))?$ ]]; then
      [ -n "$READ_QUIET" ] ||
        echo "stage-route: 状态文件 $STATE_FILE 无法解析（第 $number 行：${raw}），六个阶段按默认路由" >&2
      TABLE_CORRUPT=1
      for stage in $STAGES; do
        eval "R_${stage}_PROFILE=; R_${stage}_MODEL=; R_${stage}_EFFORT=; R_${stage}_UNTIL="
      done
      return 0
    fi
    profile=${BASH_REMATCH[1]} model=${BASH_REMATCH[2]}
    effort=${BASH_REMATCH[3]} until=${BASH_REMATCH[5]}
    eval "R_${key}_PROFILE=\$profile; R_${key}_MODEL=\$model; R_${key}_EFFORT=\$effort; R_${key}_UNTIL=\$until"
  done < "$STATE_FILE"
}

# Succeeds when a stored line is one this version accepts for the stage: the
# locked stage only as its default, the others inside the catalog with an
# effort the profile takes.
line_is_valid() {
  local route
  if [ "$1" = "$LOCKED" ]; then
    route=$(default_route "$1")
    [ "$2/$3/$4" = "$route" ]
    return $?
  fi
  is_verified "$2" "$3" "$1" && takes_effort "$2" "$4"
}

NOW=

NOW=$(date +%s) || NOW=

# Splits a route written as <profile>/<model>/<effort> into SPLIT_PROFILE,
# SPLIT_MODEL and SPLIT_EFFORT.
split_route() {
  IFS=/ read -r SPLIT_PROFILE SPLIT_MODEL SPLIT_EFFORT <<< "$1"
}

# Works out the effective route of every stage: E_<stage>_PROFILE, _MODEL,
# _EFFORT and _UNTIL, plus E_<stage>_REASON, empty when the line is in effect
# and otherwise why the stage is on its default. Call after read_table. An
# unreadable clock (NOW empty) never expires a route by itself.
resolve_table() {
  local stage profile model effort until reason
  for stage in $STAGES; do
    eval "profile=\$R_${stage}_PROFILE; model=\$R_${stage}_MODEL; effort=\$R_${stage}_EFFORT; until=\$R_${stage}_UNTIL"
    reason=
    if [ "$TABLE_CORRUPT" -eq 1 ]; then
      reason=corrupt
    elif [ -n "$profile" ] && ! line_is_valid "$stage" "$profile" "$model" "$effort"; then
      reason=unknown
      [ -n "$READ_QUIET" ] ||
        echo "stage-route: 状态文件 $STATE_FILE 里的 ${stage}=${profile}/${model}/${effort} 不在已验证目录（档案、模型或思考强度不合法），${stage} 按默认路由" >&2
    elif [ -n "$profile" ] && [ -n "$until" ] && [ -n "$NOW" ] && [ "$until" -le "$NOW" ]; then
      reason=expired
    fi
    if [ -z "$profile" ] || [ -n "$reason" ]; then
      split_route "$(default_route "$stage")"
      profile=$SPLIT_PROFILE model=$SPLIT_MODEL effort=$SPLIT_EFFORT until=
    fi
    eval "E_${stage}_PROFILE=\$profile; E_${stage}_MODEL=\$model; E_${stage}_EFFORT=\$effort; E_${stage}_UNTIL=\$until; E_${stage}_REASON=\$reason"
  done
}

format_until() {
  node -e '
    const date = new Date(Number(process.argv[1]) * 1000);
    const pad = (n) => String(n).padStart(2, "0");
    const offset = -date.getTimezoneOffset();
    const sign = offset >= 0 ? "+" : "-";
    const zone = sign + pad(Math.floor(Math.abs(offset) / 60)) + ":" + pad(Math.abs(offset) % 60);
    console.log(`${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())} ${zone}`);
  ' "$1" 2>/dev/null || printf '@%s' "$1"
}

# Prints one status line for a stage; call after resolve_table.
describe_stage() {
  local stage=$1 label profile model effort until reason default
  local raw_profile raw_model raw_effort raw_until
  label=$(stage_label "$stage")
  eval "profile=\$E_${stage}_PROFILE; model=\$E_${stage}_MODEL; effort=\$E_${stage}_EFFORT; until=\$E_${stage}_UNTIL; reason=\$E_${stage}_REASON"
  if [ "$stage" = "$LOCKED" ]; then
    printf '%s：%s / %s / 启动器默认（锁定，不可改）\n' "$label" "$profile" "$model"
    return 0
  fi
  default=$(default_route "$stage")
  eval "raw_profile=\$R_${stage}_PROFILE; raw_model=\$R_${stage}_MODEL; raw_effort=\$R_${stage}_EFFORT; raw_until=\$R_${stage}_UNTIL"
  case "$reason" in
    expired)
      printf '%s：%s / %s / %s（默认；表里的 %s / %s / %s 已于 %s 到期）\n' \
        "$label" "$profile" "$model" "$effort" \
        "$raw_profile" "$raw_model" "$raw_effort" "$(format_until "$raw_until")"
      ;;
    unknown)
      printf '%s：%s / %s / %s（默认；表里的 %s / %s / %s 不在已验证目录）\n' \
        "$label" "$profile" "$model" "$effort" "$raw_profile" "$raw_model" "$raw_effort"
      ;;
    # In effect, or the default because the whole table is unread: the line on
    # stderr has said which.
    ''|corrupt)
      if [ "$profile/$model/$effort" = "$default" ]; then
        printf '%s：%s / %s / %s（默认）\n' "$label" "$profile" "$model" "$effort"
      elif [ -z "$until" ]; then
        printf '%s：%s / %s / %s，不会自动切回；切回用 /grill-router use %s=%s\n' \
          "$label" "$profile" "$model" "$effort" "$stage" "$default"
      else
        printf '%s：%s / %s / %s，到 %s 自动切回默认\n' \
          "$label" "$profile" "$model" "$effort" "$(format_until "$until")"
      fi
      ;;
  esac
}

load_table() {
  read_table
  resolve_table
}

# Prints the model the way a profile's launcher takes it on the command line.
model_arg() {
  case "$1" in
    claude-glm|claude-flash)
      case "$2" in
        glm-5.4|glm-5.3-flash) printf '%s[1m]' "$2" ;;
        *) printf '%s' "$2" ;;
      esac
      ;;
    *) printf '%s' "$2" ;;
  esac
}

# Prints, one argument per line, the command that starts a stage's profile in
# the given form with the stage's model and effort; call after resolve_table.
launch_command() {
  local stage=$1 form=$2 profile model effort
  eval "profile=\$E_${stage}_PROFILE; model=\$E_${stage}_MODEL; effort=\$E_${stage}_EFFORT"
  case "$profile" in
    claude|claude-glm|claude-flash)
      if [ "$form" = headless ]; then
        printf '%s\n' "$profile" -p --model "$(model_arg "$profile" "$model")" --effort "$effort"
      else
        printf '%s\n' "$profile" --model "$(model_arg "$profile" "$model")" --effort "$effort"
      fi
      ;;
    codex-glm)
      if [ "$form" = headless ]; then
        printf '%s\n' codex exec -m "$model" -c "model_reasoning_effort=$effort"
      else
        printf '%s\n' codex -m "$model" -c "model_reasoning_effort=$effort"
      fi
      ;;
  esac
}

# Replaces the table with the lines printed by its argument.
write_table() {
  local directory temporary
  directory=$(dirname "$STATE_FILE")
  mkdir -p "$directory" 2>/dev/null || cannot_write "cannot create $directory"
  temporary=$(mktemp "$STATE_FILE.XXXXXX") || cannot_write "cannot write next to $STATE_FILE"
  printf '%s' "$1" > "$temporary" || {
    rm -f "$temporary"
    cannot_write "cannot write $temporary"
  }
  mv -f "$temporary" "$STATE_FILE" || {
    rm -f "$temporary"
    cannot_write "cannot replace $STATE_FILE"
  }
}

# Prints the duration in seconds, or fails when it is not a sum of d/h/m/s.
duration_seconds() {
  local value=$1 days hours minutes seconds
  [ -n "$value" ] || return 1
  [[ "$value" =~ ^([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]] || return 1
  days=${BASH_REMATCH[1]%d}
  hours=${BASH_REMATCH[2]%h}
  minutes=${BASH_REMATCH[3]%m}
  seconds=${BASH_REMATCH[4]%s}
  echo $(( ${days:-0} * 86400 + ${hours:-0} * 3600 + ${minutes:-0} * 60 + ${seconds:-0} ))
}

# Prints an ISO 8601 time with its UTC offset as epoch seconds, or fails.
epoch_of() {
  # Date.parse would quietly read a time without an offset as local time, so
  # the offset is required here rather than assumed.
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
  node -e '
    const time = Date.parse(process.argv[1]);
    if (Number.isNaN(time)) process.exit(1);
    console.log(Math.floor(time / 1000));
  ' "$1" 2>/dev/null
}

# use: every stage the command names takes the route given, the others keep
# their line as it is.
use_routes() {
  local stage profile model effort value route named= lines= until= expiry= limit= given=0 seconds now off_default=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --until|--for)
        [ $# -ge 2 ] || die "$1 needs a value"
        [ "$given" -eq 0 ] || die "give only one of --until and --for"
        if [ "$1" = --until ]; then given=1; else given=2; fi
        limit=$2
        shift 2
        ;;
      *=*)
        stage=${1%%=*}
        value=${1#*=}
        is_known_stage "$stage" || die "unknown stage '$stage' (stages: ${STAGES// /, })"
        if [ "$stage" = "$LOCKED" ]; then
          route=$(default_route "$stage")
          die "$stage is locked on ${route%\/} in v1: it is the main session you are already in, and no script starts it"
        fi
        case " $named " in
          *" $stage "*) die "use names $stage twice" ;;
        esac
        if ! [[ "$value" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/([a-z]+)$ ]]; then
          die "a route is <profile>/<model>/<effort>, e.g. claude-glm/glm-5.4/high (got '$1')"
        fi
        profile=${BASH_REMATCH[1]} model=${BASH_REMATCH[2]} effort=${BASH_REMATCH[3]}
        is_known_profile "$profile" ||
          die "unknown profile '$profile' for $stage (profiles: ${PROFILES// /, })"
        is_verified "$profile" "$model" "$stage" ||
          die "$profile/$model is not in the verified catalog for $stage; verified for $stage: $(catalog_for_stage "$stage")"
        takes_effort "$profile" "$effort" ||
          die "$profile does not accept effort '$effort' (accepts: $(list_efforts "$profile"))"
        eval "N_${stage}_PROFILE=\$profile; N_${stage}_MODEL=\$model; N_${stage}_EFFORT=\$effort"
        named="$named $stage"
        shift
        ;;
      *) die "unknown argument after use: $1" ;;
    esac
  done
  [ -n "$named" ] || die "use needs a route such as design=claude-glm/glm-5.4/high (stages: ${STAGES// /, })"
  if [ "$given" -ne 0 ]; then
    # An expiry only means something for a route that differs from the default.
    for stage in $named; do
      eval "profile=\$N_${stage}_PROFILE; model=\$N_${stage}_MODEL; effort=\$N_${stage}_EFFORT"
      [ "$profile/$model/$effort" != "$(default_route "$stage")" ] && off_default=1
    done
    [ "$off_default" -eq 1 ] ||
      die "--until and --for only apply to a route that differs from the default; every stage in this command is set to its default, so there is nothing to switch back from"
  fi
  case "$given" in
    0) expiry= ;;
    1)
      expiry=$(epoch_of "$limit") ||
        die "--until must be an ISO 8601 time with its UTC offset such as 2026-11-28T10:00:00+08:00 (got '$limit')"
      ;;
    2)
      seconds=$(duration_seconds "$limit") ||
        die "--for must be a duration such as 5h, 30m or 2d12h (got '$limit')"
      [ "$seconds" -gt 0 ] || die "--for must be greater than zero (got '$limit')"
      now=$(date +%s) || cannot_write 'cannot read the clock'
      expiry=$((now + seconds))
      ;;
  esac
  load_table
  for stage in $STAGES; do
    [ "$stage" != "$LOCKED" ] || continue
    case " $named " in
      *" $stage "*)
        eval "profile=\$N_${stage}_PROFILE; model=\$N_${stage}_MODEL; effort=\$N_${stage}_EFFORT"
        until=$expiry
        [ "$profile/$model/$effort" != "$(default_route "$stage")" ] || { profile=; until=; }
        eval "E_${stage}_UNTIL=\$until"
        ;;
      *)
        eval "profile=\$R_${stage}_PROFILE; model=\$R_${stage}_MODEL; effort=\$R_${stage}_EFFORT; until=\$R_${stage}_UNTIL"
        ;;
    esac
    [ -z "$profile" ] || lines="${lines:+$lines$'\n'}$stage=$profile/$model/$effort${until:+@$until}"
  done
  write_table "$lines"
  # The status is read back from the file just written, so it says exactly what
  # the next dispatch will see; the second read stays quiet about lines this
  # run already reported.
  READ_QUIET=1
  load_table
  show_status
  # The same model reviewing what it wrote is no change of reviewer. Said once
  # per command, never a refusal.
  if [ "$E_review_MODEL" = "$E_implementation_MODEL" ]; then
    echo "stage-route: 警告：审查（review）和实现（implementation）现在是同一个模型 ${E_review_MODEL}，等于没有换模型审查；不拦，下一次派发生效" >&2
  fi
}

show_status() {
  local stage
  for stage in $STAGES; do
    describe_stage "$stage"
  done
}

print_field() {
  local stage=$1 field=$2 value=
  case "$field" in
    '') value=$(describe_stage "$stage") ;;
    profile|model|effort|until) eval "value=\$E_${stage}_$(uppercase_field "$field")" ;;
  esac
  if [ "$field" = until ]; then
    [ -n "$value" ] || return 0
  elif [ -z "$value" ]; then
    if [ "$stage" = "$LOCKED" ] && [ "$field" = effort ]; then
      cannot_answer "the $stage stage has no effort in the table: its launcher's own config decides"
    fi
    cannot_answer "the $stage stage has no $field to print"
  fi
  printf '%s\n' "$value"
}

uppercase_field() {
  case "$1" in
    profile) printf PROFILE ;;
    model) printf MODEL ;;
    effort) printf EFFORT ;;
    until) printf UNTIL ;;
  esac
}

case "${1:-}" in
  '') load_table; show_status ;;
  -h|--help) show_help ;;
  --print)
    [ $# -ge 2 ] && [ $# -le 3 ] || die "--print takes a stage and at most one of profile, model, effort, until (stages: ${STAGES// /, })"
    is_known_stage "$2" || die "unknown stage '$2' (stages: ${STAGES// /, })"
    case "${3:-}" in
      ''|profile|model|effort|until) ;;
      *) die "unknown field '${3:-}' for --print (fields: profile, model, effort, until)" ;;
    esac
    load_table
    print_field "$2" "${3:-}"
    ;;
  --launch)
    [ $# -eq 3 ] || die "--launch takes a stage and a form: --launch <stage> <interactive|headless> (stages: ${STAGES// /, })"
    is_known_stage "$2" || die "unknown stage '$2' (stages: ${STAGES// /, })"
    case "$3" in
      interactive|headless) ;;
      *) die "unknown form '$3' for --launch (forms: interactive, headless)" ;;
    esac
    [ "$2" != "$LOCKED" ] ||
      die "$2 is locked and no script starts it: it is the main session you are already in, so it has no launch command"
    load_table
    launch_command "$2" "$3"
    ;;
  use)
    [ $# -ge 2 ] || die "use needs a route such as design=claude-glm/glm-5.4/high (stages: ${STAGES// /, })"
    shift
    use_routes "$@"
    ;;
  migrate)
    die "migrate is not available yet: it arrives with issue #29; until then scripts/judgment-model.sh and scripts/worker-model.sh keep working on their own"
    ;;
  -*) die "unknown argument: $1" ;;
  *=*) die "a route is set with use: stage-route.sh use $1" ;;
  *) die "unknown command '$1' (commands: use, migrate; options: --print, --launch)" ;;
esac
