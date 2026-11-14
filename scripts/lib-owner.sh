#!/usr/bin/env bash
# Shared owner identity helpers for implement-spec-split locks and claims.
# A pid is considered alive only when its current process start time matches the
# recorded start time. This prevents a recycled pid from looking like the old owner.

OWNER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

owner_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

owner_valid_pid() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Resolve the pid that conceptually owns an operation. ISS_OWNER_PID is useful in
# deterministic tests; production walks from this shell to the Claude session, and
# uses the immediate parent if no Claude process is found.
owner_resolve_pid() {
  local pid="" comm="" parent="" visited=0
  if [ -n "${ISS_OWNER_PID:-}" ]; then
    owner_valid_pid "$ISS_OWNER_PID" || return 1
    printf '%s' "$ISS_OWNER_PID"
    return 0
  fi

  pid=$$
  while owner_valid_pid "$pid" && [ "$pid" != 0 ] && [ "$visited" -lt 1000 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    comm=$(owner_trim "$comm")
    if [ "$(basename "$comm" 2>/dev/null || true)" = claude ]; then
      printf '%s' "$pid"
      return 0
    fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null || true)
    parent=$(owner_trim "$parent")
    owner_valid_pid "$parent" || break
    [ "$parent" = "$pid" ] && break
    pid=$parent
    visited=$((visited + 1))
  done

  if owner_valid_pid "$PPID"; then
    printf '%s' "$PPID"
    return 0
  fi
  return 1
}

owner_start_for() {
  local pid="$1" output=""
  owner_valid_pid "$pid" || return 0
  if [ -n "${ISS_PS_LSTART_CMD:-}" ]; then
    # The variable is normally a command path. Quoting it as one command also keeps
    # a test helper path containing spaces usable.
    output=$(eval "\"\$ISS_PS_LSTART_CMD\" \"\$pid\"" 2>/dev/null || true)
  else
    output=$("$OWNER_LIB_DIR/pid-start.sh" "$pid" 2>/dev/null || true)
  fi
  owner_trim "$output"
}

# Read pid, pid_start, cwd and acquired_at from owner.json. Output is tab-separated;
# callers must not use this for untrusted JSON presentation.
owner_read() {
  local file="$1"
  OWNER_FILE="$(printf '%s' "$file")" node -e '
    const fs = require("fs");
    const clean = v => String(v ?? "").replace(/[\t\n\r]+/g, " ");
    try {
      const o = JSON.parse(fs.readFileSync(process.env.OWNER_FILE, "utf8"));
      process.stdout.write([
        clean(o.pid), clean(o.pid_start), clean(o.cwd), clean(o.acquired_at)
      ].join("\t"));
    } catch {}
  '
}

owner_record_line() {
  local file="$1"
  OWNER_FILE="$(printf '%s' "$file")" node -e '
    const fs = require("fs");
    try {
      const o = JSON.parse(fs.readFileSync(process.env.OWNER_FILE, "utf8"));
      process.stdout.write(JSON.stringify({
        pid: o.pid, pid_start: o.pid_start, cwd: o.cwd, acquired_at: o.acquired_at
      }));
    } catch { process.stdout.write("{}"); }
  '
}

owner_alive() {
  local pid="$1" recorded_start="$2" current_start
  owner_valid_pid "$pid" || return 1
  [ -n "$recorded_start" ] || return 1
  current_start=$(owner_start_for "$pid")
  [ -n "$current_start" ] && [ "$current_start" = "$recorded_start" ]
}

owner_same() {
  local pid="$1" pid_start="$2" other_pid="$3" other_pid_start="$4"
  [ "$pid" = "$other_pid" ] && [ -n "$pid_start" ] && [ "$pid_start" = "$other_pid_start" ]
}

owner_iso_now() {
  date +%Y-%m-%dT%H:%M:%S%z
}

owner_epoch_now() {
  local value="${ISS_NOW_EPOCH:-}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    date +%s
  fi
}

# A claim record is alive when its recorded process identity is still alive, or
# when it is an unexpired handoff reservation. The epoch override keeps expiry
# deterministic in tests.
claim_record_alive() {
  local file="$1" pid="" pid_start=""
  IFS=$'\t' read -r pid pid_start <<< "$(claim_record_owner_fields "$file")"
  if [ -n "$pid" ] && owner_alive "$pid" "${pid_start:-}"; then
    return 0
  fi

  CLAIM_RECORD_FILE="$(printf '%s' "$file")" \
  CLAIM_NOW_EPOCH="$(owner_epoch_now)" node -e '
    const fs = require("fs");
    try {
      const claim = JSON.parse(fs.readFileSync(process.env.CLAIM_RECORD_FILE, "utf8"));
      const handoff = claim.handoff;
      if (handoff !== "fresh" && handoff !== "resume") process.exit(1);
      const until = claim.handoff_until_epoch;
      if (typeof until !== "number" || !Number.isSafeInteger(until)) process.exit(1);
      const now = Number(process.env.CLAIM_NOW_EPOCH);
      process.exit(now < until ? 0 : 1);
    } catch {
      process.exit(1);
    }
  '
}

claim_record_owner_fields() {
  local file="$1"
  CLAIM_RECORD_FILE="$(printf '%s' "$file")" node -e '
    const fs = require("fs");
    const clean = value => String(value ?? "").replace(/[\t\n\r]+/g, " ");
    try {
      const claim = JSON.parse(fs.readFileSync(process.env.CLAIM_RECORD_FILE, "utf8"));
      process.stdout.write([clean(claim.pid), clean(claim.pid_start)].join("\t"));
    } catch {}
  '
}

owner_age_seconds() {
  local value="$1"
  OWNER_DATE="$(printf '%s' "$value")" node -e '
    const value = new Date(process.env.OWNER_DATE);
    const seconds = Number.isFinite(value.getTime()) ? Math.max(0, Math.floor((Date.now() - value.getTime()) / 1000)) : 0;
    process.stdout.write(String(seconds));
  '
}
