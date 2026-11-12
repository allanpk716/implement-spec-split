#!/usr/bin/env bash
# Read or atomically configure the machine-wide External worker limit.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-workers.sh
source "$HERE/lib-workers.sh"

usage() {
  cat >&2 <<'EOF'
usage: max-workers.sh [N]
EOF
}

die() {
  echo "max-workers: $*" >&2
  exit 64
}

[ $# -le 1 ] || { usage; exit 64; }

if [ $# -eq 0 ]; then
  VALUE=$(iss_max_workers) || exit $?
  printf '%s (%s)\n' "$VALUE" "$(iss_max_workers_source)"
  exit 0
fi

VALUE="$1"
[[ "$VALUE" =~ ^[1-9][0-9]*$ ]] || die "N must be a positive integer"

mkdir -p "$(iss_state_dir)" || die "could not create state directory"
FILE=$(iss_max_workers_file)
TEMPORARY="$FILE.write.$$.$RANDOM"
printf '%s\n' "$VALUE" > "$TEMPORARY" || die "could not write $TEMPORARY"
mv "$TEMPORARY" "$FILE" || {
  rm -f "$TEMPORARY"
  die "could not replace $FILE"
}
printf 'max-workers = %s\n' "$VALUE"
