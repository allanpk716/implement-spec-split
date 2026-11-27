#!/usr/bin/env bash
# Global hot switch for the Worker model (GLOSSARY.md): the model an External
# worker's harness talks to. v1 covers the codex path only: scripts/codex-worker.sh
# reads the switch on every fresh run, so a Run that is already executing picks the
# new model up at its next dispatch, without being restarted. A Resume keeps the
# model of its first segment. The agent backend and pi-worker.sh are not switched.
#
# Usage:
#   worker-model.sh                               show the current status
#   worker-model.sh use <model> [--until <time> | --for <duration>]
#   worker-model.sh --print                       print only the effective model (one token)
#   worker-model.sh --print default               print only the default model
#   worker-model.sh --print until                 print the expiry (epoch seconds), or an empty line
#   worker-model.sh --print catalog               print whether the effective model is listed in the
#                                                 worker home's model catalog: yes, no, or unknown
#
#   <model>   glm-5.4 (the default), glm-5.3 or glm-5.3-flash
#   --until   ISO 8601 time, e.g. 2026-11-28T10:00:00+08:00; once reached the switch is back on glm-5.4
#   --for     a duration, e.g. 5h, 30m, 2d12h; same as --until now + duration
#   Without --until / --for the switch stays as set until it is changed again.
#   use glm-5.4 without a time is the reset: an explicit --model is honoured again.
#   A model without `use` is not accepted.
#
# codex-worker.sh applies this priority: the switch when it is not on the default,
# then an explicit --model, then the default.
#
# --print always exits 0 and prints the effective model: glm-5.4 when the setting
# is missing, unreadable, unknown or expired. --print default, --print until and
# --print catalog always exit 0 as well. `use` only warns, never refuses, when the
# model is not in the worker home's model catalog.
#
# Exit codes:
#   0  done
#   64 bad usage
#   65 the setting could not be written
#
# The setting is $HOME/.claude/state/worker-model (ISS_WORKER_MODEL_FILE names
# another file). It holds two lines: `worker=<model>` and `worker.until=<epoch
# seconds>`; an empty until means no expiry.

set -u

STATE_FILE=${ISS_WORKER_MODEL_FILE:-$HOME/.claude/state/worker-model}
# The default is defined here and nowhere else: codex-worker.sh and selftest-codex.sh
# ask for it with `--print default`, and the list of allowed models is built from it,
# so the next default upgrade is a one-line change here.
DEFAULT_MODEL=glm-5.4
MODELS="$DEFAULT_MODEL glm-5.3 glm-5.3-flash"

die() {
  echo "worker-model: $*" >&2
  exit 64
}

cannot_write() {
  echo "worker-model: $*" >&2
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

# Sets WORKER_MODEL and WORKER_UNTIL. A missing file, a missing line and an
# unreadable file all read as empty.
read_setting() {
  WORKER_MODEL=
  WORKER_UNTIL=
  local line key value
  [ -r "$STATE_FILE" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    value=$(printf '%s' "$value" | tr -d '[:space:]')
    case "$key" in
      worker|worker.model) WORKER_MODEL=$value ;;
      worker.until) WORKER_UNTIL=$value ;;
      *) continue ;;
    esac
  done < "$STATE_FILE" 2>/dev/null
  return 0
}

effective_model() {
  read_setting
  local now
  is_known_model "$WORKER_MODEL" || { echo "$DEFAULT_MODEL"; return 0; }
  case "$WORKER_UNTIL" in
    ''|*[!0-9]*) echo "$WORKER_MODEL"; return 0 ;;
  esac
  now=$(date +%s) || now=
  # An unreadable clock never expires the switch by itself.
  if [ -n "$now" ] && [ "$WORKER_UNTIL" -le "$now" ]; then echo "$DEFAULT_MODEL"
  else echo "$WORKER_MODEL"; fi
}

# Prints the expiry of a switch that is in effect, as epoch seconds; an empty line
# when the switch is on the default, has no expiry, has expired, or the clock
# cannot be read. It answers exactly what codex-worker.sh will apply.
effective_until() {
  read_setting
  local now
  is_known_model "$WORKER_MODEL" && [ "$WORKER_MODEL" != "$DEFAULT_MODEL" ] || { echo; return 0; }
  case "$WORKER_UNTIL" in
    ''|*[!0-9]*) echo; return 0 ;;
  esac
  now=$(date +%s) || { echo; return 0; }
  if [ "$now" -lt "$WORKER_UNTIL" ]; then echo "$WORKER_UNTIL"; else echo; fi
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

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# Prints the worker home codex-worker.sh would use, in its resolution order:
# CODEX_WORKER_HOME, then ~/.codex-worker when it exists, then ${CODEX_HOME:-$HOME/.codex}.
# Prints nothing when CODEX_WORKER_HOME is set but is not a directory (the wrapper
# refuses that case before any model is chosen).
worker_home() {
  if [ "${CODEX_WORKER_HOME+set}" = set ]; then
    [ -n "$CODEX_WORKER_HOME" ] && [ -d "$CODEX_WORKER_HOME" ] || return 1
    printf '%s\n' "$CODEX_WORKER_HOME"
  elif [ -d "$HOME/.codex-worker" ]; then
    printf '%s\n' "$HOME/.codex-worker"
  else
    printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
  fi
}

# Prints yes, no or unknown: is $1 listed in the worker home's model catalog, the
# file named by model_catalog_json in its config.toml? unknown means the catalog
# cannot be read, and the caller skips the check then.
catalog_status() {
  local home
  home=$(worker_home) || { echo unknown; return 0; }
  WORKER_HOME_W="$(winpath "$home")" CATALOG_MODEL="$1" node -e '
    const fs = require("fs"), path = require("path"), os = require("os");
    const unknown = () => { console.log("unknown"); process.exit(0); };
    let text;
    try { text = fs.readFileSync(path.join(process.env.WORKER_HOME_W, "config.toml"), "utf8"); }
    catch { unknown(); }
    let catalog = null;
    for (const line of text.split(/\r?\n/)) {
      if (/^\s*\[/.test(line)) break; // model_catalog_json is a root key
      const match = line.match(/^\s*model_catalog_json\s*=\s*(?:"((?:\\.|[^"\\])*)"|\x27([^\x27]*)\x27|([^#\s]+))\s*(?:#.*)?$/);
      if (!match) continue;
      if (match[3] !== undefined) catalog = match[3];
      else if (match[2] !== undefined) catalog = match[2];
      else { try { catalog = JSON.parse("\"" + match[1] + "\""); } catch { catalog = match[1]; } }
    }
    if (!catalog) unknown();
    if (catalog === "~" || catalog.startsWith("~/")) catalog = path.join(os.homedir(), catalog.slice(1));
    let data;
    try { data = JSON.parse(fs.readFileSync(catalog, "utf8")); }
    catch { unknown(); }
    // The catalog is {"models": [{"slug": ...}]} today; walking every string keeps the
    // check honest if the entry key changes.
    const names = new Set();
    const walk = value => {
      if (typeof value === "string") names.add(value);
      else if (Array.isArray(value)) value.forEach(walk);
      else if (value && typeof value === "object") Object.values(value).forEach(walk);
    };
    walk(data);
    console.log(names.has(process.env.CATALOG_MODEL) ? "yes" : "no");
  ' 2>/dev/null || echo unknown
}

# Prints the warning for a model the worker home's catalog does not list. It names
# the three steps that make the model usable, in order (ADR 0003, flash's L1).
catalog_warning_text() {
  printf '%s 不在 worker 模型目录里（worker home 的 config.toml 中 model_catalog_json 指向的文件），L1 未验。' "$1"
  printf '先跑 scripts/selftest-codex.sh --only L1 --model %s；报错指向型号或目录时，在 ~/.codex/models.json 补条目并重跑 scripts/setup-worker-home.sh（直接改 ~/.codex-worker/models.json 会被下次重跑覆盖）。' "$1"
}

# Prints the status; call after read_setting.
show_status() {
  read_setting
  local model until now effective
  model=$WORKER_MODEL
  until=$WORKER_UNTIL
  if is_known_model "$model" && [ "$model" != "$DEFAULT_MODEL" ]; then
    case "$until" in
      ''|*[!0-9]*)
        printf 'Worker model：%s（默认 %s），不会自动切回；切回用 /worker-model use %s\n' \
          "$model" "$DEFAULT_MODEL" "$DEFAULT_MODEL"
        ;;
      *)
        now=$(date +%s) || now=
        if [ -n "$now" ] && [ "$until" -le "$now" ]; then
          printf 'Worker model：%s（默认；开关里的 %s 已于 %s 到期）\n' \
            "$DEFAULT_MODEL" "$model" "$(format_until "$until")"
        else
          printf 'Worker model：%s（默认 %s），到 %s 自动切回 %s\n' \
            "$model" "$DEFAULT_MODEL" "$(format_until "$until")" "$DEFAULT_MODEL"
        fi
        ;;
    esac
  else
    printf 'Worker model：%s（默认）\n' "$DEFAULT_MODEL"
  fi
  effective=$(effective_model)
  if [ "$(catalog_status "$effective")" = no ]; then
    echo "worker-model: warning: $(catalog_warning_text "$effective")" >&2
  fi
}

write_setting() {
  local directory temporary
  directory=$(dirname "$STATE_FILE")
  mkdir -p "$directory" 2>/dev/null || cannot_write "cannot create $directory"
  temporary=$(mktemp "$STATE_FILE.XXXXXX") || cannot_write "cannot write next to $STATE_FILE"
  printf 'worker=%s\nworker.until=%s\n' "$WORKER_MODEL" "$WORKER_UNTIL" > "$temporary" || {
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

use_model() {
  local model= until= limit= given=0 seconds now
  while [ $# -gt 0 ]; do
    case "$1" in
      --until)
        [ $# -ge 2 ] || die "--until needs a value"
        given=1; limit=$2; shift 2 ;;
      --for)
        [ $# -ge 2 ] || die "--for needs a value"
        given=2; limit=$2; shift 2 ;;
      -*)
        die "unknown argument: $1" ;;
      *)
        [ -z "$model" ] || die "use takes one model (got '$model' and '$1')"
        model=$1
        shift
        ;;
    esac
  done
  [ -n "$model" ] || die "use needs a model (supported: ${MODELS// /, })"
  is_known_model "$model" || die "unsupported model '$model' (supported: ${MODELS// /, })"
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
  # An expiry only means something for a substitute model: the default is where an
  # expiry returns to.
  if [ "$given" -ne 0 ] && [ "$model" = "$DEFAULT_MODEL" ]; then
    die "--until and --for only apply to a substitute model, not to $DEFAULT_MODEL; to reset run: use $DEFAULT_MODEL"
  fi
  WORKER_MODEL=$model
  WORKER_UNTIL=$until
  write_setting
  show_status
}

case "${1:-}" in
  '') show_status ;;
  -h|--help) show_help ;;
  --print)
    case "${2:-}" in
      '')
        [ $# -eq 1 ] || die "--print takes no model; see --print default, --print until, --print catalog"
        effective_model
        ;;
      default|until|catalog)
        [ $# -eq 2 ] || die "--print $2 takes no further argument"
        case "$2" in
          default) printf '%s\n' "$DEFAULT_MODEL" ;;
          until) effective_until ;;
          catalog) catalog_status "$(effective_model)" ;;
        esac
        ;;
      *) die "unknown --print argument '$2' (expected default, until or catalog)" ;;
    esac
    ;;
  use)
    [ $# -ge 2 ] || die "use needs a model (supported: ${MODELS// /, })"
    shift
    use_model "$@"
    ;;
  -*) die "unknown argument: $1" ;;
  *) die "a model is set with use: worker-model.sh use $1" ;;
esac
