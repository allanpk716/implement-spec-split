#!/usr/bin/env bash
# Print the Tickets of one Spec that may be started now.
#
# Usage:
#   frontier.sh --repo <owner/name> --spec <n>
#
# The ticket set follows the Spec-to-Ticket rules in SKILL.md step 0 (the
# Spec's sub-issues, otherwise the implementation tickets named on its
# `实现票：#N` line and their sub-issues), read from pipeline-status.sh --graph.
# A ticket is in the frontier when GitHub's `dependencies/blocked_by` holds no
# open blocker for it, it is not shelved, and it does not carry
# `ready-for-human`. Among such tickets carrying the `shared-counter` label
# (the graph's `shared_counter` flag: it bumps a shared counter) only the
# lowest-numbered one is in the frontier; the others wait in `# blocked`,
# naming it, until that one is merged and closed.
#
# Output:
#   zero or more lines `#<t>` — the frontier, one ticket per line, ascending;
#   then the sections `# blocked` (blocked tickets with their open blockers,
#   and `shared-counter` tickets waiting for the one released:
#   `（等共享计数器：#m）`), `# human` (ready-for-human tickets, never
#   dispatched) and `# shelved` (shelved tickets). A ticket may appear in more
#   than one of those three.
#
# Exit codes:
#   0  success
#   1  fail closed: pipeline-status.sh or a gh query failed, or the graph has
#      no such Spec. Nothing is printed on stdout in this case.
#  64  bad usage

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage_error() {
  printf 'frontier: %s\n' "$1" >&2
  exit 64
}

fail_closed() {
  printf 'frontier: %s\n' "$1" >&2
  exit 1
}

REPO=""
SPEC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage_error "--repo requires <owner/name>"
      REPO=$2
      shift 2
      ;;
    --spec)
      [ $# -ge 2 ] || usage_error "--spec requires <n>"
      SPEC=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$REPO" ] || usage_error "--repo is required"
[ -n "$SPEC" ] || usage_error "--spec is required"
[[ "$SPEC" =~ ^[0-9]+$ ]] || usage_error "--spec must be an issue number (got $SPEC)"
command -v gh >/dev/null 2>&1 || fail_closed "gh is required but was not found on PATH"
command -v node >/dev/null 2>&1 || fail_closed "node is required but was not found on PATH"
[ -f "$HERE/pipeline-status.sh" ] || fail_closed "pipeline-status.sh not found next to frontier.sh"

GRAPH_FILE=$(mktemp "${TMPDIR:-/tmp}/frontier-graph.XXXXXX") ||
  fail_closed "could not create a temporary graph file"
GRAPH_ERR=$(mktemp "${TMPDIR:-/tmp}/frontier-graph-err.XXXXXX") ||
  fail_closed "could not create a temporary graph error file"
trap 'rm -f "$GRAPH_FILE" "$GRAPH_ERR" 2>/dev/null' EXIT

if ! "$HERE/pipeline-status.sh" --repo "$REPO" --graph > "$GRAPH_FILE" 2> "$GRAPH_ERR"; then
  printf 'frontier: pipeline-status.sh --graph failed for %s\n' "$REPO" >&2
  sed -n '1,20p' "$GRAPH_ERR" >&2
  exit 1
fi

node - "$GRAPH_FILE" "$REPO" "$SPEC" <<'NODE'
const fs = require('fs');
const cp = require('child_process');

const graphFile = process.argv[2];
const repo = process.argv[3];
const specNumber = Number(process.argv[4]);

function fail(message) {
  process.stderr.write(`frontier: ${message}\n`);
  process.exit(1);
}

let graph;
try {
  graph = JSON.parse(fs.readFileSync(graphFile, 'utf8'));
} catch (error) {
  fail(`cannot parse pipeline-status --graph output: ${error.message}`);
}

const spec = (Array.isArray(graph.specs) ? graph.specs : [])
  .find((item) => Number(item.number) === specNumber);
if (!spec) {
  fail(`spec #${specNumber} not found in the ${repo} graph; is it an issue with a ## Problem Statement heading?`);
}

function parsePage(text, number) {
  const trimmed = String(text || '').trim();
  if (trimmed === '') return [];
  try {
    return JSON.parse(trimmed);
  } catch (_) {
    // gh --paginate may concatenate one JSON array per page; join them.
    try {
      const joined = JSON.parse(`[${trimmed.replace(/]\s*\[/g, '],[')}]`);
      return joined.flat();
    } catch (error) {
      fail(`cannot parse dependencies/blocked_by for issue #${number}: ${error.message}`);
    }
  }
  return [];
}

const open = (Array.isArray(spec.tickets) ? spec.tickets : [])
  .filter((ticket) => ticket.state === 'open')
  .sort((a, b) => Number(a.number) - Number(b.number));

const blockers = new Map();
for (const ticket of open) {
  const number = Number(ticket.number);
  let text;
  try {
    text = cp.execFileSync('gh', [
      'api', '--paginate', `repos/${repo}/issues/${number}/dependencies/blocked_by`,
    ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
  } catch (error) {
    const detail = error && error.stderr ? `: ${String(error.stderr).trim()}` : '';
    fail(`gh api failed for issue #${number} dependencies/blocked_by${detail}`);
  }
  const list = parsePage(text, number);
  blockers.set(number, (Array.isArray(list) ? list : [])
    .filter((item) => item && item.state === 'open')
    .map((item) => Number(item.number))
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => a - b));
}

function clean(value) {
  return String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
}

const frontier = [];
const blocked = [];
const human = [];
const shelved = [];
// The one `shared-counter` ticket released this run (the lowest-numbered among
// those that pass the other frontier conditions; `open` is ascending, so the
// first one met is it). The rest wait for it in `# blocked`, naming it.
let releasedCounterTicket = null;
for (const ticket of open) {
  const number = Number(ticket.number);
  const openBlockers = blockers.get(number) || [];
  const line = `#${number} ${clean(ticket.title)}`;
  if (ticket.human === true) human.push(`${line}（人工）`);
  if (ticket.shelved === true) shelved.push(`${line}（搁置）`);
  if (openBlockers.length > 0) {
    blocked.push(`${line}（阻塞：${openBlockers.map((value) => `#${value}`).join(' ')}）`);
  }
  if (openBlockers.length === 0 && ticket.shelved !== true && ticket.human !== true) {
    if (ticket.shared_counter !== true) {
      frontier.push(`#${number}`);
    } else if (releasedCounterTicket === null) {
      releasedCounterTicket = number;
      frontier.push(`#${number}`);
    } else {
      blocked.push(`${line}（等共享计数器：#${releasedCounterTicket}）`);
    }
  }
}

const out = [...frontier];
out.push('# blocked');
out.push(...(blocked.length > 0 ? blocked : ['（无）']));
out.push('# human');
out.push(...(human.length > 0 ? human : ['（无）']));
out.push('# shelved');
out.push(...(shelved.length > 0 ? shelved : ['（无）']));
process.stdout.write(`${out.join('\n')}\n`);
NODE
