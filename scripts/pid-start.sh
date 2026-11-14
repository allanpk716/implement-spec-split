#!/usr/bin/env bash
# Print a stable process start identifier without failing on MSYS ps.

set -u

pid="${1:-}"
[[ "$pid" =~ ^[0-9]+$ ]] || exit 0

output=$(ps -o lstart= -p "$pid" 2>/dev/null || true)
output=${output#"${output%%[![:space:]]*}"}
output=${output%"${output##*[![:space:]]}"}
if [ -n "$output" ]; then
  printf '%s\n' "$output"
  exit 0
fi

stat_file="${ISS_PROC_ROOT:-/proc}/$pid/stat"
if [ -r "$stat_file" ]; then
  stat=$(cat "$stat_file" 2>/dev/null || true)
  rest=${stat##*) }
  read -r -a fields <<< "$rest"
  start=${fields[19]:-}
  if [[ "$start" =~ ^[0-9]+$ ]]; then
    printf 'proc:%s\n' "$start"
  fi
fi

exit 0
