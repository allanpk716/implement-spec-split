#!/usr/bin/env bash
# Global hot switch for the judgment model, kept per role. The judgment model
# is the model that stands in for Opus where this skill uses it:
#
#   grill    Design sessions: /grill-feature, /grill-map, and the ones find-next
#            opens (scripts/design-session.sh reads this role at every launch)
#   review   every Opus review, code, draft and diagnose alike
#            (scripts/opus-review.sh reads this role on every call)
#
# The wrappers read the switch each time they run, so a session that is already
# executing picks it up at its next review or Design session, without being
# restarted.
#
# Usage:
#   judgment-model.sh                               show both roles
#   judgment-model.sh use <setting> [<setting> ...>] [--until <time> | --for <duration>]
#   judgment-model.sh <setting> [<setting> ...] [--until <time> | --for <duration>]
#   judgment-model.sh --print <role>                print only that role's effective model
#
#   A setting is `grill=<model>`, `review=<model>`, or a bare <model>, which
#   sets every role the same command does not name. One command therefore sets
#   both: `judgment-model.sh grill=opus review=glm-5.4`. A role the command
#   does not touch keeps its setting.
#   <model>   opus (the default) or glm-5.4 (stands in for Opus)
#   --until   ISO 8601 time, e.g. 2026-11-28T10:00:00+08:00; once reached every
#             role this command switched to glm-5.4 is back on opus
#   --for     a duration, e.g. 5h, 30m, 2d12h; same as --until now + duration
#   Without --until / --for the roles stay as set until they are changed again.
#
# --print always exits 0 and prints the effective model of the role: opus when
# the setting is missing, unreadable, unknown or expired.
#
# Exit codes:
#   0  done
#   64 bad usage
#   65 the setting could not be written
#
# The setting is $HOME/.claude/state/judgment-model (ISS_JUDGMENT_MODEL_FILE
# names another file). It holds a model and an until line per role:
# `grill=<opus|glm-5.4>`, `grill.until=<epoch seconds>`, and the same two for
# review; an empty until means no expiry.

set -u

STATE_FILE=${ISS_JUDGMENT_MODEL_FILE:-$HOME/.claude/state/judgment-model}
ROLES='grill review'
MODELS='opus glm-5.4'

die() {
  echo "judgment-model: $*" >&2
  exit 64
}

cannot_write() {
  echo "judgment-model: $*" >&2
  exit 65
}

show_help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

is_known_model() {
  case " $MODELS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

is_known_role() {
  case " $ROLES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Sets GRILL_MODEL, GRILL_UNTIL, REVIEW_MODEL and REVIEW_UNTIL. A missing file,
# a missing line and an unreadable file all read as empty.
read_setting() {
  GRILL_MODEL=
  GRILL_UNTIL=
  REVIEW_MODEL=
  REVIEW_UNTIL=
  local line key value prefix suffix
  [ -r "$STATE_FILE" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    value=$(printf '%s' "$value" | tr -d '[:space:]')
    case "$key" in
      grill|grill.model) prefix=GRILL suffix=MODEL ;;
      grill.until) prefix=GRILL suffix=UNTIL ;;
      review|review.model) prefix=REVIEW suffix=MODEL ;;
      review.until) prefix=REVIEW suffix=UNTIL ;;
      *) continue ;;
    esac
    eval "$prefix"_"$suffix"=\$value
  done < "$STATE_FILE" 2>/dev/null
  return 0
}

role_value() {
  case "$1" in
    grill) eval "printf '%s' \"\$GRILL_$2\"" ;;
    review) eval "printf '%s' \"\$REVIEW_$2\"" ;;
  esac
}

role_label() {
  case "$1" in
    grill) printf 'grill（Design session 讨论）' ;;
    review) printf 'review（全部 Opus review）' ;;
  esac
}

effective_model() {
  read_setting
  local model until now
  model=$(role_value "$1" MODEL)
  until=$(role_value "$1" UNTIL)
  is_known_model "$model" || { echo opus; return 0; }
  case "$until" in
    ''|*[!0-9]*) echo "$model"; return 0 ;;
  esac
  now=$(date +%s) || now=
  # An unreadable clock never expires the switch by itself.
  if [ -n "$now" ] && [ "$until" -le "$now" ]; then echo opus
  else echo "$model"; fi
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

# Prints one status line for a role; call after read_setting.
describe_role() {
  local role=$1 model until now
  model=$(role_value "$role" MODEL)
  until=$(role_value "$role" UNTIL)
  if [ "$model" = opus ] || ! is_known_model "$model"; then
    printf '%s：opus（默认）\n' "$(role_label "$role")"
    return 0
  fi
  case "$until" in
    ''|*[!0-9]*)
      printf '%s：%s（代替 Opus），不会自动切回；切回用 judgment-model.sh %s=opus\n' \
        "$(role_label "$role")" "$model" "$role"
      ;;
    *)
      now=$(date +%s) || now=
      if [ -n "$now" ] && [ "$until" -le "$now" ]; then
        printf '%s：opus（开关里的 %s 已于 %s 到期）\n' \
          "$(role_label "$role")" "$model" "$(format_until "$until")"
      else
        printf '%s：%s（代替 Opus），到 %s 自动切回 opus\n' \
          "$(role_label "$role")" "$model" "$(format_until "$until")"
      fi
      ;;
  esac
}

show_status() {
  local role
  read_setting
  for role in $ROLES; do
    describe_role "$role"
  done
}

write_setting() {
  local directory temporary
  directory=$(dirname "$STATE_FILE")
  mkdir -p "$directory" 2>/dev/null || cannot_write "cannot create $directory"
  temporary=$(mktemp "$STATE_FILE.XXXXXX") || cannot_write "cannot write next to $STATE_FILE"
  {
    printf 'grill=%s\ngrill.until=%s\n' "$GRILL_MODEL" "$GRILL_UNTIL"
    printf 'review=%s\nreview.until=%s\n' "$REVIEW_MODEL" "$REVIEW_UNTIL"
  } > "$temporary" || {
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

# Prints an ISO 8601 time as epoch seconds.
epoch_of() {
  node -e '
    const time = Date.parse(process.argv[1]);
    if (Number.isNaN(time)) process.exit(1);
    console.log(Math.floor(time / 1000));
  ' "$1" 2>/dev/null
}

use_settings() {
  # base: a bare model, for every role the command does not name.
  local base= new_grill= new_review= until= limit= given=0 seconds now model role switched=0
  local set_grill=0 set_review=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --until)
        [ $# -ge 2 ] || die "--until needs a value"
        given=1; limit=$2; shift 2 ;;
      --for)
        [ $# -ge 2 ] || die "--for needs a value"
        given=2; limit=$2; shift 2 ;;
      *=*)
        role=${1%%=*}
        model=${1#*=}
        is_known_role "$role" || die "unknown role '$role' (roles: ${ROLES// /, })"
        is_known_model "$model" || die "unsupported model '$model' for $role (supported: ${MODELS// /, })"
        case "$role" in
          grill) new_grill=$model; set_grill=1 ;;
          review) new_review=$model; set_review=1 ;;
        esac
        shift
        ;;
      *)
        model=$1
        is_known_model "$model" || die "unsupported model '$model' (supported: ${MODELS// /, })"
        base=$model
        shift
        ;;
      -*) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$base$new_grill$new_review" ] ||
    die "use needs a setting such as glm-5.4, grill=opus or review=glm-5.4"
  if [ -n "$base" ]; then
    [ -n "$new_grill" ] || new_grill=$base
    [ "$new_review" ] || new_review=$base
    set_grill=1
    set_review=1
  fi
  case "$given" in
    0) until= ;;
    1)
      until=$(epoch_of "$limit") ||
        die "--until must be an ISO 8601 time such as 2026-11-28T10:00:00+08:00 (got '$limit')"
      ;;
    2)
      seconds=$(duration_seconds "$limit") ||
        die "--for must be a duration such as 5h, 30m or 2d12h (got '$limit')"
      [ "$seconds" -gt 0 ] || die "--for must be greater than zero (got '$limit')"
      now=$(date +%s) || cannot_write 'cannot read the clock'
      until=$((now + seconds))
      ;;
  esac
  if [ "$given" -ne 0 ]; then
    for model in "$new_grill" "$new_review"; do
      [ -n "$model" ] && [ "$model" != opus ] && switched=1
    done
    [ "$switched" -eq 1 ] || die "--until and --for only apply to a substitute model, not to opus"
  fi
  read_setting
  # A role the command leaves alone keeps both its model and its expiry.
  [ "$set_grill" -eq 0 ] || { GRILL_MODEL=$new_grill; GRILL_UNTIL=; }
  [ "$set_review" -eq 0 ] || { REVIEW_MODEL=$new_review; REVIEW_UNTIL=; }
  [ -z "$GRILL_MODEL" ] && GRILL_MODEL=opus
  [ -z "$REVIEW_MODEL" ] && REVIEW_MODEL=opus
  [ "$GRILL_MODEL" = opus ] || [ "$set_grill" -eq 0 ] || GRILL_UNTIL=$until
  [ "$REVIEW_MODEL" = opus ] || [ "$set_review" -eq 0 ] || REVIEW_UNTIL=$until
  write_setting
  show_status
}

case "${1:-}" in
  '') show_status ;;
  -h|--help) show_help ;;
  --print)
    [ $# -eq 2 ] || die "--print needs exactly one role (${ROLES// /, })"
    is_known_role "$2" || die "unknown role '$2' (roles: ${ROLES// /, })"
    effective_model "$2"
    ;;
  use)
    [ $# -ge 2 ] || die "use needs a setting such as glm-5.4, grill=opus or review=glm-5.4"
    shift
    use_settings "$@"
    ;;
  -*) die "unknown argument: $1" ;;
  *) use_settings "$@" ;;
esac
