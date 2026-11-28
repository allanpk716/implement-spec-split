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
# through scripts/lib-graph.sh, the reading layer scripts/frontier.sh shares. A
# landed Spec has had each of its `ready-for-agent` Tickets closed as it merged
# (merge-ticket.sh --close-ticket), so before the landing every one of them is
# closed. Five kinds of open Ticket do not hold the landing back, and are listed
# so that the report can name them:
#   waiting  an open blocker of it lies outside this Spec's Tickets (a Ticket
#            of another Spec, a standalone issue), or it is blocked, through
#            Tickets of this Spec, by one that waits for a person — a human
#            Ticket, or one under `# decision` — or by a shelved one; waiting
#            runs along the blocked_by edges inside the Spec, so a chain behind
#            such a Ticket waits too (SKILL.md "Tickets blocked by another
#            Spec": a partial landing);
#   human    carrying `ready-for-human`: never dispatched;
#   decision a Pending ticket (GLOSSARY.md 待定票; 票 #86 — the section's name,
#            not a map's Decision ticket): carrying no `ready-for-agent` label,
#            or one of `needs-info`, `needs-triage`, `wontfix` beside it. Those
#            three win over `ready-for-agent`: a Ticket that is both is
#            mislabelled, and is listed here for a person to put right. It
#            waits for a person's triage — a label that makes it an execution
#            Ticket again, or its closure — so nothing is dispatched for it,
#            and it is no debt of the Spec's while it waits;
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
#   # decision `#<t> <title>（待定）`;
#   # shelved  `#<t> <title>（搁置）`;
#   # source   `#<t> <title>（源票）`;
#   # report   one line per open Ticket that is neither human, decision, shelved
#              nor the source ticket, under # open or # waiting alike — the line
#              the report takes as it is, so that no report hides a Ticket the
#              Spec still owes, and the session never reads the reasons off the
#              issues: `剩余：#<t>` under # open, with its open blockers
#              (`剩余：#<t>（阻塞：#a #b）`), and `剩余：#<t> 等 …` for a
#              waiting one: `等 #<spec>` when the blocker is a Spec, `等 #<issue>`
#              when it is a standalone issue (several: `等 #a #b`), `等人工 #<t>`
#              a Ticket of this Spec that waits for a person — a human Ticket,
#              or one under # decision — and `等搁置 #<t>` a shelved one; a
#              Ticket that waits only behind another one names what that one
#              waits for.
# Tickets are ascending in every section. One that is both human and shelved
# is in both, and a source that is human or shelved is in those sections too; a
# Ticket under # decision is in that section alone.
#
# Exit codes:
#   0  the check passes: `# open` is empty (a Spec without Tickets passes)
#   1  fail closed: pipeline-status.sh or a gh query failed. Nothing is printed
#      on stdout in this case. The failure may pass: step 9 runs it once more.
#   2  the check fails: `# open` names at least one Ticket. Do not land.
#   3  fail closed for good: the graph has no such Spec. Nothing is printed on
#      stdout in this case. Waiting brings nothing back: step 9 parks at once.
#  64  bad usage

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-graph.sh
source "$HERE/lib-graph.sh"

graph_parse_args "$@"
graph_require_tools
graph_load

graph_node <<'NODE'
const ticketNumbers = new Set(tickets.map((ticket) => Number(ticket.number)));
const pendingNumbers = new Set(open.filter(isPending).map((ticket) => Number(ticket.number)));
// The open Tickets that hold no landing back and are listed without their
// blockers: human, shelved, the source ticket, and a Ticket under `# decision`.
// Every other open Ticket is asked for its blockers, from the endpoint
// frontier.sh reads.
const deferred = new Set(open
  .filter((ticket) => ticket.human === true || ticket.shelved === true || ticket.source === true ||
    pendingNumbers.has(Number(ticket.number)))
  .map((ticket) => Number(ticket.number)));
// The Tickets that wait for a person: a human Ticket, or one under `# decision`
// waiting for its triage. A Ticket blocked by one of them waits for that person.
const personNumbers = new Set(open
  .filter((ticket) => ticket.human === true || pendingNumbers.has(Number(ticket.number)))
  .map((ticket) => Number(ticket.number)));

const blockers = new Map();
for (const ticket of open) {
  const number = Number(ticket.number);
  if (deferred.has(number)) continue;
  blockers.set(number, openBlockersOf(number));
}

// A Ticket waits when an open blocker of it lies outside this Spec, or when it
// is blocked by one that waits or is deferred; that spreads along the edges
// inside the Spec until nothing changes. The rest is `# open`.
//
// What a waiting Ticket waits for is kept as it is found, so that `# report`
// is the check's own reading. A reason has a kind, and KINDS is the one place
// the kinds are enumerated; KIND_LIST is the same table in the order of a
// report line. `head` is what follows 等 before the numbers of a kind (等 #20
// #22, 等人工 #11, 等搁置 #11). `holds` reads a blocker's own reason off the
// graph, and at most one kind holds: a blocker outside this Spec's Tickets is
// another Spec or a standalone issue, read by its number; one of this Spec that
// is deferred is `human` when it waits for a person — a human Ticket, or one
// under `# decision` — shelved as well or not, and `shelved` otherwise. A
// Ticket of this Spec that no kind holds waits itself, and the Ticket behind it
// waits for what that one waits for.
const KINDS = {
  number: {order: 0, head: ' ', holds: (blocker) => !ticketNumbers.has(blocker)},
  human: {order: 1, head: '人工 ', holds: (blocker) => deferred.has(blocker) && personNumbers.has(blocker)},
  shelved: {order: 2, head: '搁置 ', holds: (blocker) => deferred.has(blocker) && !personNumbers.has(blocker)},
};
const KIND_LIST = Object.entries(KINDS).sort((a, b) => a[1].order - b[1].order);

const reasonKey = (reason) => `${reason.kind}:${reason.number}`;
function reasonsFor(number) {
  const reasons = [];
  const keys = new Set();
  for (const blocker of blockers.get(number) || []) {
    const own = KIND_LIST.find(([, kind]) => kind.holds(blocker));
    const found = own ? [{kind: own[0], number: blocker}] : (waitsFor.get(blocker) || []);
    for (const reason of found) {
      const key = reasonKey(reason);
      if (!keys.has(key)) {
        keys.add(key);
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

// The open blockers of a Ticket as the suffix of a line that names it,
// `（阻塞：#a #b）` ascending, or nothing when it has none.
function blockerSuffix(number) {
  const openBlockers = blockers.get(number) || [];
  return openBlockers.length > 0
    ? `（阻塞：${openBlockers.map((value) => `#${value}`).join(' ')}）`
    : '';
}

function line(ticket) {
  return `${titled(ticket)}${blockerSuffix(Number(ticket.number))}`;
}

// The landing report's line for an open execution Ticket, whichever section
// lists it. A waiting one says what it waits for: the reasons by kind, in the
// order of KINDS (the numbers, then 人工, then 搁置), each kind ascending, the
// groups joined by `、`.
function reportLine(number) {
  if (!waiting.has(number)) {
    // Under # open: work the Spec still owes, named with the open blockers its
    // # open line names (they are Tickets of this Spec that are open too).
    return `剩余：#${number}${blockerSuffix(number)}`;
  }
  const reasons = (waitsFor.get(number) || []).slice()
    .sort((a, b) => KINDS[a.kind].order - KINDS[b.kind].order || a.number - b.number);
  const groups = KIND_LIST
    .map(([kind, {head}]) => {
      const numbers = reasons.filter((reason) => reason.kind === kind);
      return numbers.length === 0 ? '' : head + numbers.map((reason) => `#${reason.number}`).join(' ');
    })
    .filter(Boolean);
  return `剩余：#${number} 等${groups.join('、')}`;
}

const blocking = [];
const waitingLines = [];
const human = [];
const pendingLines = [];
const shelved = [];
const source = [];
for (const ticket of open) {
  const number = Number(ticket.number);
  const title = titled(ticket);
  if (ticket.human === true) human.push(`${title}（人工）`);
  if (pendingNumbers.has(number)) pendingLines.push(`${title}（待定）`);
  if (ticket.shelved === true) shelved.push(`${title}（搁置）`);
  if (ticket.source === true) source.push(`${title}（源票）`);
  if (deferred.has(number)) continue;
  if (waiting.has(number)) waitingLines.push(line(ticket));
  else blocking.push(line(ticket));
}

const out = [];
for (const [title, lines] of [
  ['# open', blocking],
  ['# waiting', waitingLines],
  ['# human', human],
  ['# decision', pendingLines],
  ['# shelved', shelved],
  ['# source', source],
  // Every open Ticket that is neither human, decision, shelved nor the source
  // ticket, under # open or # waiting alike: a report must never hide a Ticket
  // the Spec still owes.
  ['# report', open
    .filter((ticket) => !deferred.has(Number(ticket.number)))
    .map((ticket) => reportLine(Number(ticket.number)))],
]) {
  out.push(...section(title, lines));
}
process.stdout.write(`${out.join('\n')}\n`);
process.exit(blocking.length === 0 ? 0 : 2);
NODE
