#!/usr/bin/env bash
# The landing check of one Spec (SKILL.md step 9): is every Ticket the agent
# owed closed?
#
# Usage:
#   landing-check.sh --repo <owner/name> --spec <n>
#
# The ticket set follows the Spec-to-Ticket rules in SKILL.md step 0 (the
# Spec's sub-issues, otherwise the implementation tickets named on its
# `实现票：#N` line and their sub-issues), read from pipeline-status.sh --graph
# as scripts/frontier.sh reads it. A landed Spec has had each of its
# `ready-for-agent` Tickets closed as it merged (merge-ticket.sh
# --close-ticket), so before the landing every one of them is closed. Four
# kinds of open Ticket do not hold the landing back, and are listed so that the
# report can name them:
#   waiting  an open blocker of it lies outside this Spec's Tickets (a Ticket
#            of another Spec, a standalone issue), or it is blocked, through
#            Tickets of this Spec, by a human or a shelved one; waiting runs
#            along the blocked_by edges inside the Spec, so a chain behind such
#            a Ticket waits too (SKILL.md "Tickets blocked by another Spec": a
#            partial landing);
#   human    carrying `ready-for-human`: never dispatched;
#   shelved  titled 【搁置】, or marked so in its body;
#   source   the loose source ticket of a Spec without sub-issues (the graph's
#            `source` flag: the mapless ticket its 实现票 line names, 票 #83).
#            Not an execution ticket: nothing is dispatched for it, and step 9
#            closes it together with the Spec, so its being open is no debt.
# Every other open Ticket is under `# open` and fails the check: it is work the
# Spec still owes, or a Ticket that merged without being closed (票 #78: four
# merged Tickets left open emptied the frontier of Spec #26, which nearly
# landed with 4 of its 9 Tickets).
#
# Output (stdout; a section that is empty is printed as `（无）`):
#   # open     one line per open Ticket that holds the landing back,
#              `#<t> <title>` and, when it has open blockers, `（阻塞：#a #b）`;
#   # waiting  the Tickets that wait, in the same form;
#   # human    `#<t> <title>（人工）`;
#   # shelved  `#<t> <title>（搁置）`;
#   # source   `#<t> <title>（源票）`;
#   # report   one line per open Ticket that is neither human, shelved nor the
#              source ticket, under # open or # waiting alike — the line the
#              report takes as it is, so that no report hides a Ticket the Spec
#              still owes, and the session never reads the reasons off the
#              issues: `剩余：#<t>` under # open, with its open blockers
#              (`剩余：#<t>（阻塞：#a #b）`), and `剩余：#<t> 等 …` for a
#              waiting one: `等 #<spec>` when the blocker is a Spec, `等 #<issue>`
#              when it is a standalone issue (several: `等 #a #b`), `等人工 #<t>`
#              a human Ticket of this Spec, `等搁置 #<t>` a shelved one; a
#              Ticket that waits only behind another one names what that one
#              waits for.
# Tickets are ascending in every section. One that is both human and shelved
# is in both, and a source that is human or shelved is in those sections too.
#
# Exit codes:
#   0  the check passes: `# open` is empty (a Spec without Tickets passes)
#   1  fail closed: pipeline-status.sh or a gh query failed, or the graph has
#      no such Spec. Nothing is printed on stdout in this case.
#   2  the check fails: `# open` names at least one Ticket. Do not land.
#  64  bad usage

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage_error() {
  printf 'landing-check: %s\n' "$1" >&2
  exit 64
}

fail_closed() {
  printf 'landing-check: %s\n' "$1" >&2
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
[ -f "$HERE/pipeline-status.sh" ] || fail_closed "pipeline-status.sh not found next to landing-check.sh"

GRAPH_FILE=$(mktemp "${TMPDIR:-/tmp}/landing-check-graph.XXXXXX") ||
  fail_closed "could not create a temporary graph file"
GRAPH_ERR=$(mktemp "${TMPDIR:-/tmp}/landing-check-graph-err.XXXXXX") ||
  fail_closed "could not create a temporary graph error file"
trap 'rm -f "$GRAPH_FILE" "$GRAPH_ERR" 2>/dev/null' EXIT

if ! "$HERE/pipeline-status.sh" --repo "$REPO" --graph > "$GRAPH_FILE" 2> "$GRAPH_ERR"; then
  printf 'landing-check: pipeline-status.sh --graph failed for %s\n' "$REPO" >&2
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
  process.stderr.write(`landing-check: ${message}\n`);
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

const tickets = (Array.isArray(spec.tickets) ? spec.tickets : [])
  .slice()
  .sort((a, b) => Number(a.number) - Number(b.number));
const open = tickets.filter((ticket) => ticket.state === 'open');
const ticketNumbers = new Set(tickets.map((ticket) => Number(ticket.number)));
const deferred = new Set(open
  .filter((ticket) => ticket.human === true || ticket.shelved === true || ticket.source === true)
  .map((ticket) => Number(ticket.number)));
const humanNumbers = new Set(open
  .filter((ticket) => ticket.human === true)
  .map((ticket) => Number(ticket.number)));

// The open blockers of every open Ticket that is neither human, shelved nor
// the source ticket, from the endpoint frontier.sh reads. The deferred kinds
// are listed without theirs.
const blockers = new Map();
for (const ticket of open) {
  const number = Number(ticket.number);
  if (deferred.has(number)) continue;
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

// A Ticket waits when an open blocker of it lies outside this Spec, or when it
// is blocked by one that waits or is deferred; that spreads along the edges
// inside the Spec until nothing changes. The rest is `# open`.
//
// What a waiting Ticket waits for is kept as it is found, so that `# report`
// is the check's own reading: a blocker outside the Spec is another Spec or a
// standalone issue (both `number`), a deferred one of this Spec is `human` or
// `shelved`, and a Ticket that waits only behind another one waits for what
// that one waits for.
const reasonKey = (reason) => `${reason.kind}:${reason.number}`;
function reasonsFor(number) {
  const reasons = [];
  const keys = new Set();
  for (const blocker of blockers.get(number) || []) {
    const found = !ticketNumbers.has(blocker)
      ? [{kind: 'number', number: blocker}]
      : deferred.has(blocker)
        ? [{kind: humanNumbers.has(blocker) ? 'human' : 'shelved', number: blocker}]
        : waitsFor.get(blocker) || [];
    for (const reason of found) {
      if (!keys.has(reasonKey(reason))) {
        keys.add(reasonKey(reason));
        reasons.push(reason);
      }
    }
  }
  return reasons;
}

const waiting = new Set();
const waitsFor = new Map();
for (let changed = true; changed;) {
  changed = false;
  for (const ticket of open) {
    const number = Number(ticket.number);
    if (deferred.has(number) || waiting.has(number)) continue;
    const reasons = reasonsFor(number);
    if (reasons.length > 0) {
      waiting.add(number);
      waitsFor.set(number, reasons);
      changed = true;
    }
  }
}

function clean(value) {
  return String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
}

function line(ticket) {
  const number = Number(ticket.number);
  const openBlockers = blockers.get(number) || [];
  const suffix = openBlockers.length > 0
    ? `（阻塞：${openBlockers.map((value) => `#${value}`).join(' ')}）`
    : '';
  return `#${number} ${clean(ticket.title)}${suffix}`;
}

// The landing report's line for an open execution Ticket, whichever section
// lists it. A waiting one says what it waits for, the reasons by kind (the
// numbers, then 人工, then 搁置), each kind ascending, the groups joined by `、`.
// The numbers follow 等 after one space (等 #20 #22); 人工 and 搁置 follow it
// directly (等人工 #11, 等搁置 #11).
const KIND_ORDER = {number: 0, human: 1, shelved: 2};
const KIND_HEAD = {number: ' ', human: '人工 ', shelved: '搁置 '};
function reportLine(number) {
  if (!waiting.has(number)) {
    // Under # open: work the Spec still owes, named with the open blockers its
    // # open line names (they are Tickets of this Spec that are open too).
    const openBlockers = blockers.get(number) || [];
    const suffix = openBlockers.length > 0
      ? `（阻塞：${openBlockers.map((value) => `#${value}`).join(' ')}）`
      : '';
    return `剩余：#${number}${suffix}`;
  }
  const reasons = (waitsFor.get(number) || []).slice()
    .sort((a, b) => (a.kind === b.kind ? a.number - b.number : KIND_ORDER[a.kind] - KIND_ORDER[b.kind]));
  const groups = ['number', 'human', 'shelved']
    .map((kind) => {
      const numbers = reasons.filter((reason) => reason.kind === kind);
      return numbers.length === 0 ? '' : KIND_HEAD[kind] + numbers.map((reason) => `#${reason.number}`).join(' ');
    })
    .filter(Boolean);
  return `剩余：#${number} 等${groups.join('、')}`;
}

const blocking = [];
const waitingLines = [];
const human = [];
const shelved = [];
const source = [];
for (const ticket of open) {
  const number = Number(ticket.number);
  if (ticket.human === true) human.push(`#${number} ${clean(ticket.title)}（人工）`);
  if (ticket.shelved === true) shelved.push(`#${number} ${clean(ticket.title)}（搁置）`);
  if (ticket.source === true) source.push(`#${number} ${clean(ticket.title)}（源票）`);
  if (deferred.has(number)) continue;
  if (waiting.has(number)) waitingLines.push(line(ticket));
  else blocking.push(line(ticket));
}

const out = [];
for (const [title, lines] of [
  ['# open', blocking],
  ['# waiting', waitingLines],
  ['# human', human],
  ['# shelved', shelved],
  ['# source', source],
  // Every open Ticket that is neither human, shelved nor the source ticket,
  // under # open or # waiting alike: a report must never hide a Ticket the
  // Spec still owes.
  ['# report', open
    .filter((ticket) => !deferred.has(Number(ticket.number)))
    .map((ticket) => reportLine(Number(ticket.number)))],
]) {
  out.push(title);
  out.push(...(lines.length > 0 ? lines : ['（无）']));
}
process.stdout.write(`${out.join('\n')}\n`);
process.exit(blocking.length === 0 ? 0 : 2);
NODE
