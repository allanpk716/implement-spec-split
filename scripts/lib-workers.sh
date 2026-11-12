#!/usr/bin/env bash
# Machine-wide External worker-limit configuration shared by both worker wrappers.

iss_state_dir() {
  printf '%s' "${ISS_STATE_DIR:-$HOME/.cache/implement-spec-split}"
}

iss_max_workers_file() {
  printf '%s/max-workers' "$(iss_state_dir)"
}

iss_max_workers() {
  local value file=""
  if [ -n "${ISS_MAX_WORKERS:-}" ]; then
    if [[ ! "$ISS_MAX_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
      if declare -F die >/dev/null 2>&1; then
        die "ISS_MAX_WORKERS must be a positive integer"
      else
        echo "lib-workers: ISS_MAX_WORKERS must be a positive integer" >&2
        exit 64
      fi
    fi
    printf '%s\n' "$ISS_MAX_WORKERS"
    return 0
  fi

  file=$(iss_max_workers_file)
  if [ -e "$file" ]; then
    value=$(cat "$file" 2>/dev/null || true)
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "max-workers: invalid integer in $file; using 4" >&2
  fi
  printf '4\n'
}

iss_max_workers_source() {
  local value file=""
  if [ -n "${ISS_MAX_WORKERS:-}" ]; then
    printf 'ISS_MAX_WORKERS'
    return 0
  fi

  file=$(iss_max_workers_file)
  if [ -e "$file" ]; then
    value=$(cat "$file" 2>/dev/null || true)
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      printf 'file'
      return 0
    fi
  fi
  printf 'default'
}
