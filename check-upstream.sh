#!/usr/bin/env bash
# Compare the vendored snapshot of Matt Pocock's implement-spec against the installed/latest upstream.
# Usage: ./check-upstream.sh [path-to-mattpocock-skills-checkout]
#   default: ~/.claude/plugins/marketplaces/mattpocock (run `git -C <that> pull` or update the plugin first)
# After porting upstream changes into SKILL.md:  ./check-upstream.sh --accept
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--accept" ]; then accept=1; shift; else accept=0; fi
src="${1:-$HOME/.claude/plugins/marketplaces/mattpocock}"
file="$src/skills/engineering/implement-spec/SKILL.md"
[ -f "$file" ] || { echo "upstream file not found: $file" >&2; exit 2; }
commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "snapshot: $(cat "$here/upstream/COMMIT")"
echo "upstream: $commit"
if [ "$accept" = 1 ]; then
  cp "$file" "$here/upstream/implement-spec.SKILL.md"
  echo "$commit" > "$here/upstream/COMMIT"
  echo "snapshot updated."
  exit 0
fi
if diff -u "$here/upstream/implement-spec.SKILL.md" "$file"; then
  echo "no upstream changes."
else
  echo
  echo "upstream changed: port the diff above into SKILL.md, then run: $0 --accept${1:+ $1}"
  exit 1
fi
