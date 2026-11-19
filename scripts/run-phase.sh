#!/usr/bin/env bash
# Write run.json (phase, wave, ticket counts, updated) into a Spec-level Run directory.
# Display-only for the Progress board: Recovery never reads it. A failed write only warns.

usage() {
  cat <<'USAGE'
Usage: run-phase.sh <phase> (--run-dir DIR | --repo NAME --spec N) [--wave W] [--merged A] [--in-progress B] [--todo C]

phase: split | implement | integrate | review | land | parked | done
Run directory: DIR as given, or with --repo/--spec the newest
  ~/.cache/implement-spec-split/runs/<repo>-<n>-*/ (created, stamped now, if none exists).
Rewrites run.json atomically each call; omitted fields are written as null.
A write failure prints a warning and exits 0; an invalid phase or usage error exits 2.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
phase=${1:-}; shift 2>/dev/null
case "$phase" in
  split|implement|integrate|review|land|parked|done) ;;
  *) echo "run-phase: invalid phase '$phase'" >&2; usage >&2; exit 2 ;;
esac

dir= repo= spec= wave= merged= inprog= todo=
while [ $# -gt 0 ]; do
  case $1 in
    --run-dir) dir=${2:-}; shift 2 ;;
    --repo) repo=${2:-}; shift 2 ;;
    --spec) spec=${2:-}; shift 2 ;;
    --wave) wave=${2:-}; shift 2 ;;
    --merged) merged=${2:-}; shift 2 ;;
    --in-progress) inprog=${2:-}; shift 2 ;;
    --todo) todo=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-phase: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

num() { case $1 in ''|*[!0-9]*) [ -z "$1" ] && echo null || { echo "run-phase: not a number: $1" >&2; usage >&2; exit 2; } ;; *) echo "$1" ;; esac; }
wave_j=$(num "$wave") || exit 2
merged_j=$(num "$merged") || exit 2
inprog_j=$(num "$inprog") || exit 2
todo_j=$(num "$todo") || exit 2

if [ -z "$dir" ]; then
  if [ -z "$repo" ] || [ -z "$spec" ]; then
    echo "run-phase: need --run-dir, or --repo and --spec" >&2; usage >&2; exit 2
  fi
  base=$HOME/.cache/implement-spec-split/runs
  dir=
  for c in "$base/$repo-$spec"-*/; do
    [ -d "$c" ] && dir=${c%/}   # glob sorts by name, so the last is the newest timestamp
  done
  if [ -z "$dir" ]; then
    dir=$base/$repo-$spec-$(date +%Y%m%d-%H%M)
    mkdir -p "$dir" 2>/dev/null || { echo "run-phase: warning: cannot create $dir; run.json not written" >&2; exit 0; }
  fi
fi

if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
  echo "run-phase: warning: $dir is missing or not writable; run.json not written" >&2
  exit 0
fi

tmp=$dir/.run.json.$$
if printf '{"phase":"%s","wave":%s,"tickets":{"merged":%s,"in_progress":%s,"todo":%s},"updated":"%s"}\n' \
     "$phase" "$wave_j" "$merged_j" "$inprog_j" "$todo_j" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$tmp" 2>/dev/null \
   && mv -f "$tmp" "$dir/run.json" 2>/dev/null; then
  exit 0
fi
rm -f "$tmp" 2>/dev/null
echo "run-phase: warning: could not write $dir/run.json" >&2
exit 0
