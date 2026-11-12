#!/usr/bin/env bash
# Named mkdir locks and counted worker slots for implement-spec-split.
# macOS has no flock(1); mkdir(2) is the atomic primitive used here.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-owner.sh
source "$HERE/lib-owner.sh"

DEFAULT_WAIT=540
DEFAULT_POLL=2

usage() {
  cat <<'EOF'
usage:
  lock.sh acquire <name> [--scope repo|global] [--wait SECONDS] [--owner-pid PID]
  lock.sh release <name> [--scope repo|global] [--owner-pid PID] [--force]
  lock.sh status  <name> [--scope repo|global]
  lock.sh slot-acquire <name> --max N [--wait SECONDS] [--owner-pid PID]
  lock.sh slot-release <name> <k> [--owner-pid PID] [--force]
EOF
}

die_usage() {
  echo "lock.sh: $*" >&2
  usage >&2
  exit 64
}

lock_state_root() {
  local scope="$1" git_dir
  if [ "$scope" = global ]; then
    printf '%s/locks' "${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}"
    return 0
  fi
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "lock.sh: --scope repo requires a Git repository" >&2
    return 1
  }
  git_dir=$(cd "$git_dir" && pwd)
  printf '%s/implement-spec-split/locks' "$git_dir"
}

lock_validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ "$1" != . ] && [ "$1" != .. ]
}

lock_validate_nonnegative() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# A freshly mkdir'd lock has a tiny window before owner.json is renamed into place.
# Do not treat that window as stale until it has lasted longer than a healthy writer.
lock_missing_owner_is_old() {
  local dir="$1" mtime now grace="${ISS_LOCK_OWNER_GRACE:-2}"
  mtime=$(stat -f %m "$dir" 2>/dev/null) || mtime=$(stat -c %Y "$dir" 2>/dev/null) || mtime=0
  now=$(date +%s)
  [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$grace" =~ ^[0-9]+$ ]] && \
    [ "$now" -ge "$((mtime + grace))" ]
}

lock_takeover_mutex_is_old() {
  local dir="$1" mtime now grace="${ISS_LOCK_TAKEOVER_GRACE:-30}"
  mtime=$(stat -f %m "$dir" 2>/dev/null) || mtime=$(stat -c %Y "$dir" 2>/dev/null) || mtime=0
  now=$(date +%s)
  [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$grace" =~ ^[0-9]+$ ]] && \
    [ "$now" -ge "$((mtime + grace))" ]
}

lock_write_owner() {
  local dir="$1" pid="$2" pid_start="$3" cwd acquired_at
  cwd=$(pwd)
  acquired_at=$(owner_iso_now)
  OWNER_DIR="$(printf '%s' "$dir")" OWNER_PID="$pid" OWNER_START="$pid_start" \
  OWNER_CWD="$cwd" OWNER_AT="$acquired_at" OWNER_TEMP="owner.json.$$" node -e '
    const fs = require("fs"), path = require("path");
    const e = process.env;
    const value = JSON.stringify({
      pid: +e.OWNER_PID, pid_start: e.OWNER_START, cwd: e.OWNER_CWD,
      acquired_at: e.OWNER_AT
    });
    const dir = e.OWNER_DIR, temporary = path.join(dir, e.OWNER_TEMP);
    fs.writeFileSync(temporary, value + "\n");
    fs.renameSync(temporary, path.join(dir, "owner.json"));
  '
}

# Move a dead owner's directory aside, delete only its owner file, and rmdir it.
# Only the process whose mv succeeded is allowed to recreate the real lock path.
lock_takeover_directory() {
  local dir="$1" label="$2" temporary old_owner
  temporary="${dir}.takeover.$$.$RANDOM"
  if mv "$dir" "$temporary" 2>/dev/null; then
    if [ -f "$temporary/owner.json" ]; then
      old_owner=$(owner_record_line "$temporary/owner.json")
      rm -f "$temporary/owner.json"
    else
      old_owner="{}"
    fi
    if ! rmdir "$temporary" 2>/dev/null; then
      echo "lock.sh: warning: takeover left $temporary (it contained an unexpected entry)" >&2
    fi
    echo "lock.sh: took over stale $label held by $old_owner" >&2
    return 0
  fi
  return 1
}

# The takeover mutex is a fixed sibling directory. If mkdir fails, a live
# takeover is normally in progress. A long-lived mutex is assumed to be from a
# process killed during takeover; remove only an old, empty mutex and retry once.
lock_acquire_takeover_mutex() {
  local mutex="$1"
  if mkdir "$mutex" 2>/dev/null; then
    return 0
  fi
  if lock_takeover_mutex_is_old "$mutex" && rmdir "$mutex" 2>/dev/null; then
    mkdir "$mutex" 2>/dev/null && return 0
  fi
  return 1
}

lock_try_acquire_path() {
  local dir="$1" label="$2" pid="$3" pid_start="$4"
  local fields opid ostart line first_opid first_ostart first_missing=false
  local still_stale=false mutex="${dir}.takeover" owner_rc=0
  if mkdir "$dir" 2>/dev/null; then
    lock_write_owner "$dir" "$pid" "$pid_start" || return 1
    return 0
  fi

  fields=$(owner_read "$dir/owner.json") || fields=""
  IFS=$'\t' read -r opid ostart _ _ <<< "$fields"
  line=$(owner_record_line "$dir/owner.json")
  first_opid="${opid:-}"
  first_ostart="${ostart:-}"
  [ -z "$first_opid" ] && [ ! -f "$dir/owner.json" ] && first_missing=true
  if [ -n "${opid:-}" ] && owner_same "$pid" "$pid_start" "$opid" "${ostart:-}"; then
    return 0
  fi
  if [ -z "${opid:-}" ] && [ ! -f "$dir/owner.json" ] && ! lock_missing_owner_is_old "$dir"; then
    OWNER_BLOCKING="$line"
    return 1
  fi
  if [ -n "${opid:-}" ] && owner_alive "$opid" "${ostart:-}"; then
    OWNER_BLOCKING="$line"
    return 1
  fi

  # Another waiter may have replaced the stale directory between the checks
  # above and the atomic move below. Recheck under a takeover mutex before
  # removing anything; if the owner changed, this round simply does not acquire.
  if ! lock_acquire_takeover_mutex "$mutex"; then
    OWNER_BLOCKING="$line"
    return 1
  fi

  fields=$(owner_read "$dir/owner.json") || fields=""
  IFS=$'\t' read -r opid ostart _ _ <<< "$fields"
  line=$(owner_record_line "$dir/owner.json")
  if [ ! -d "$dir" ]; then
    rmdir "$mutex" 2>/dev/null || \
      echo "lock.sh: warning: could not remove takeover mutex $mutex" >&2
    OWNER_BLOCKING="$line"
    return 1
  fi

  if [ -n "${opid:-}" ]; then
    # The complete identity must match the first read. In particular, do not
    # remove a newly installed live owner merely because its pid was recycled.
    if [ "$opid" = "${first_opid:-}" ] && [ "$ostart" = "${first_ostart:-}" ] && \
       ! owner_alive "$opid" "${ostart:-}"; then
      still_stale=true
    fi
  elif $first_missing && [ -z "${opid:-}" ] && [ ! -f "$dir/owner.json" ] && \
       lock_missing_owner_is_old "$dir"; then
    still_stale=true
  fi

  if $still_stale && lock_takeover_directory "$dir" "$label"; then
    if mkdir "$dir" 2>/dev/null; then
      lock_write_owner "$dir" "$pid" "$pid_start" || owner_rc=1
      rmdir "$mutex" 2>/dev/null || \
        echo "lock.sh: warning: could not remove takeover mutex $mutex" >&2
      return "$owner_rc"
    fi
  fi

  rmdir "$mutex" 2>/dev/null || \
    echo "lock.sh: warning: could not remove takeover mutex $mutex" >&2
  OWNER_BLOCKING="$line"
  return 1
}

lock_wait_for_path() {
  local dir="$1" label="$2" pid="$3" pid_start="$4" wait_seconds="$5"
  local deadline=$(( $(date +%s) + wait_seconds )) poll next_note=30 elapsed
  poll="${ISS_LOCK_POLL:-$DEFAULT_POLL}"

  while :; do
    OWNER_BLOCKING=""
    if lock_try_acquire_path "$dir" "$label" "$pid" "$pid_start"; then
      return 0
    fi
    if [ "$wait_seconds" = 0 ] || [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "${OWNER_BLOCKING:-{}"
      return 2
    fi
    elapsed=$(( $(date +%s) - (deadline - wait_seconds) ))
    if [ "$elapsed" -ge "$next_note" ]; then
      local age=0
      if [ -n "${OWNER_BLOCKING:-}" ] && [ "$OWNER_BLOCKING" != "{}" ]; then
        age=$(OWNER_BLOCKING="$OWNER_BLOCKING" node -e '
          const o = JSON.parse(process.env.OWNER_BLOCKING);
          const at = new Date(o.acquired_at || 0);
          process.stdout.write(String(Number.isFinite(at.getTime()) ? Math.max(0, Math.floor((Date.now() - at.getTime()) / 1000)) : 0));
        ')
      fi
      local blocking_cwd=""
      [ -n "${OWNER_BLOCKING:-}" ] && [ "$OWNER_BLOCKING" != "{}" ] && \
        blocking_cwd=$(OWNER_BLOCKING="$OWNER_BLOCKING" node -e 'process.stdout.write(JSON.parse(process.env.OWNER_BLOCKING).cwd || "")')
      local blocking_pid=""
      [ -n "${OWNER_BLOCKING:-}" ] && [ "$OWNER_BLOCKING" != "{}" ] && \
        blocking_pid=$(OWNER_BLOCKING="$OWNER_BLOCKING" node -e 'process.stdout.write(String(JSON.parse(process.env.OWNER_BLOCKING).pid || ""))')
      echo "等待锁 ${label}：持有者 ${blocking_cwd}（pid ${blocking_pid}）已持有 ${age} 秒" >&2
      next_note=$((elapsed + 30))
    fi
    sleep "$poll"
  done
}

lock_release_path() {
  local dir="$1" pid="$2" pid_start="$3" force="$4" fields opid ostart temporary
  [ -e "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    echo "lock.sh: lock path is not a directory: $dir" >&2
    return 3
  fi
  if ! $force; then
    fields=$(owner_read "$dir/owner.json") || fields=""
    IFS=$'\t' read -r opid ostart _ _ <<< "$fields"
    owner_same "$pid" "$pid_start" "${opid:-}" "${ostart:-}" || {
      echo "lock.sh: lock is held by another owner" >&2
      return 3
    }
  fi
  temporary="${dir}.release.$$.$RANDOM"
  if ! mv "$dir" "$temporary" 2>/dev/null; then
    # Another legitimate release or takeover won the atomic move; the lock is no
    # longer ours to inspect.
    return 0
  fi
  rm -f "$temporary/owner.json"
  rmdir "$temporary" 2>/dev/null || {
    echo "lock.sh: warning: lock directory contained an unexpected entry: $temporary" >&2
    return 3
  }
}

lock_status_path() {
  local dir="$1" fields opid ostart line
  if [ ! -e "$dir" ]; then
    echo free
    return 0
  fi
  line=$(owner_record_line "$dir/owner.json")
  fields=$(owner_read "$dir/owner.json") || fields=""
  IFS=$'\t' read -r opid ostart _ _ <<< "$fields"
  if owner_alive "${opid:-}" "${ostart:-}"; then
    echo "held $line"
  else
    echo "stale $line"
  fi
}

lock_parse_common() {
  COMMAND=${1:-}
  [ -n "$COMMAND" ] || die_usage "missing command"
  shift
  NAME=""
  SCOPE=repo
  WAIT=$DEFAULT_WAIT
  OWNER_PID_OPTION=""
  FORCE=false
  MAX=""
  SLOT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)
        [ "${2:-}" = repo ] || [ "${2:-}" = global ] || die_usage "--scope must be repo or global"
        SCOPE="$2"; shift 2 ;;
      --wait)
        lock_validate_nonnegative "${2:-}" || die_usage "--wait must be a nonnegative integer"
        WAIT="$2"; shift 2 ;;
      --owner-pid)
        owner_valid_pid "${2:-}" || die_usage "--owner-pid must be a positive integer"
        OWNER_PID_OPTION="$2"; shift 2 ;;
      --force) FORCE=true; shift ;;
      --max)
        [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die_usage "--max must be a positive integer"
        MAX="$2"; shift 2 ;;
      *)
        if [ -z "$NAME" ]; then
          NAME="$1"
        elif [ -z "$SLOT" ] && [ "$COMMAND" = slot-release ]; then
          SLOT="$1"
        else
          die_usage "unknown or repeated argument: $1"
        fi
        shift ;;
    esac
  done

  lock_validate_name "$NAME" || die_usage "invalid lock name"
  if [ "$COMMAND" = slot-release ]; then
    [[ "$SLOT" =~ ^[1-9][0-9]*$ ]] || die_usage "slot-release needs a positive slot number"
  else
    [ -z "$SLOT" ] || die_usage "unexpected slot number"
  fi

  OWNER_PID="$OWNER_PID_OPTION"
  if [ -z "$OWNER_PID" ]; then
    OWNER_PID=$(owner_resolve_pid) || die_usage "could not resolve owner pid"
  fi
  OWNER_PID_START=$(owner_start_for "$OWNER_PID")
  [ -n "$OWNER_PID_START" ] || die_usage "could not determine process start for pid $OWNER_PID"
}

main() {
  local command="${1:-}"
  lock_parse_common "$@"
  local root path i result blocking
  # Counted slots coordinate every worktree and repository on the machine, so they
  # always use the global state root even though acquire/release/status has scopes.
  if [ "$COMMAND" = slot-acquire ] || [ "$COMMAND" = slot-release ]; then
    root=$(lock_state_root global) || exit 64
  else
    root=$(lock_state_root "$SCOPE") || exit 64
  fi
  mkdir -p "$root"

  case "$COMMAND" in
    acquire)
      path="$root/$NAME.lock"
      lock_wait_for_path "$path" "$NAME" "$OWNER_PID" "$OWNER_PID_START" "$WAIT"
      ;;
    release)
      path="$root/$NAME.lock"
      lock_release_path "$path" "$OWNER_PID" "$OWNER_PID_START" "$FORCE"
      ;;
    status)
      path="$root/$NAME.lock"
      lock_status_path "$path"
      ;;
    slot-acquire)
      [ -n "$MAX" ] || die_usage "slot-acquire needs --max N"
      mkdir -p "$root/$NAME.slots"
      local deadline=$(( $(date +%s) + WAIT )) next_note=30 elapsed age
      local blocking_cwd blocking_pid blocking
      while :; do
        blocking=""
        for i in $(seq 1 "$MAX"); do
          path="$root/$NAME.slots/$i.lock"
          OWNER_BLOCKING=""
          if lock_try_acquire_path "$path" "$NAME slot $i" "$OWNER_PID" "$OWNER_PID_START"; then
            printf '%s\n' "$i"
            return 0
          fi
          blocking="${OWNER_BLOCKING:-}"
        done

        if [ "$WAIT" = 0 ] || [ "$(date +%s)" -ge "$deadline" ]; then
          printf '%s\n' "${blocking:-{}}"
          return 2
        fi
        elapsed=$(( $(date +%s) - (deadline - WAIT) ))
        if [ "$elapsed" -ge "$next_note" ]; then
          age=0; blocking_cwd=""; blocking_pid=""
          if [ -n "$blocking" ] && [ "$blocking" != "{}" ]; then
            age=$(OWNER_BLOCKING="$blocking" node -e '
              const o = JSON.parse(process.env.OWNER_BLOCKING);
              const at = new Date(o.acquired_at || 0);
              process.stdout.write(String(Number.isFinite(at.getTime()) ? Math.max(0, Math.floor((Date.now() - at.getTime()) / 1000)) : 0));
            ')
            blocking_cwd=$(OWNER_BLOCKING="$blocking" node -e 'process.stdout.write(JSON.parse(process.env.OWNER_BLOCKING).cwd || "")')
            blocking_pid=$(OWNER_BLOCKING="$blocking" node -e 'process.stdout.write(String(JSON.parse(process.env.OWNER_BLOCKING).pid || ""))')
          fi
          echo "等待锁 $NAME slots：持有者 ${blocking_cwd}（pid ${blocking_pid}）已持有 $age 秒" >&2
          next_note=$((elapsed + 30))
        fi
        sleep "${ISS_LOCK_POLL:-$DEFAULT_POLL}"
      done
      ;;
    slot-release)
      path="$root/$NAME.slots/$SLOT.lock"
      lock_release_path "$path" "$OWNER_PID" "$OWNER_PID_START" "$FORCE"
      ;;
    *)
      die_usage "unknown command: $command"
      ;;
  esac
}

main "$@"
