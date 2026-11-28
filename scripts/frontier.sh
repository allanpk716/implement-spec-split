#!/usr/bin/env bash
# Print the Tickets of one Spec that may be started now.
#
# Usage:
#   frontier.sh --repo <owner/name> --spec <n>
#
# The ticket set follows the Spec-to-Ticket rules in SKILL.md step 0 (the
# Spec's sub-issues, otherwise the implementation tickets named on its
# `实现票：#N` line and their sub-issues), read from pipeline-status.sh --graph
# through scripts/lib-graph.sh, the reading layer landing-check.sh shares.
# A ticket is in the frontier when GitHub's `dependencies/blocked_by` holds no
# open blocker for it, it is not shelved, it does not carry `ready-for-human`,
# and it carries `ready-for-agent` without any of `needs-info`, `needs-triage`
# and `wontfix` beside it (票 #86: a Pending ticket — GLOSSARY.md 待定票, not a
# map's Decision ticket — waits for a person's triage, whether it is unlabelled
# or held by one of those three labels whatever else it carries, so nothing is
# dispatched for it until a person triages it). Among such tickets carrying the
# `shared-counter` label (the graph's `shared_counter` flag: it bumps a shared
# counter) only the lowest-numbered one is in the frontier; the others wait in
# `# blocked`, naming it, until that one is merged and closed.
#
# The loose source ticket of the Spec (the graph's `source` flag: the mapless
# ticket its `实现票：#N` line names when the Spec has no sub-issues, 票 #83) is
# never in the frontier. It is not an execution ticket: nothing is dispatched
# for it, and it is closed together with the Spec when that lands (SKILL.md
# step 9). It is listed under `# source`, without a blocker query.
#
# Output:
#   zero or more lines `#<t>` — the frontier, one ticket per line, ascending;
#   then the sections `# blocked` (blocked tickets with their open blockers,
#   and `shared-counter` tickets waiting for the one released:
#   `（等共享计数器：#m）`), `# human` (ready-for-human tickets, never
#   dispatched), `# decision` (Pending tickets: those without `ready-for-agent`
#   or held by `needs-info` / `needs-triage` / `wontfix` beside it — never
#   dispatched either), `# shelved` (shelved tickets) and `# source` (the loose
#   source ticket). A ticket may appear in more than one of `# human`,
#   `# shelved` and `# source`; one under `# decision` is in that section alone,
#   and neither it nor the source ticket is asked for its blockers.
#
# Exit codes:
#   0  success
#   1  fail closed: pipeline-status.sh or a gh query failed. Nothing is printed
#      on stdout in this case. The failure may pass: step 1 runs it once more.
#   3  fail closed for good: the graph has no such Spec. Nothing is printed on
#      stdout in this case. Waiting brings nothing back: step 1 parks at once.
#  64  bad usage

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-graph.sh
source "$HERE/lib-graph.sh"

graph_parse_args "$@"
graph_require_tools
graph_load

graph_node <<'NODE'
const blockers = new Map();
for (const ticket of open) {
  const number = Number(ticket.number);
  // The loose source ticket and a Ticket under `# decision` are listed, never
  // dispatched: no blocker query for either.
  if (ticket.source === true || isPending(ticket)) continue;
  blockers.set(number, openBlockersOf(number));
}

const frontier = [];
const blocked = [];
const human = [];
const pending = [];
const shelved = [];
const source = [];
// The one `shared-counter` ticket released this run (the lowest-numbered among
// those that pass the other frontier conditions; `open` is ascending, so the
// first one met is it). The rest wait for it in `# blocked`, naming it.
let releasedCounterTicket = null;
for (const ticket of open) {
  const number = Number(ticket.number);
  const line = titled(ticket);
  if (ticket.human === true) human.push(`${line}（人工）`);
  if (ticket.shelved === true) shelved.push(`${line}（搁置）`);
  if (ticket.source === true) {
    source.push(`${line}（源票）`);
    continue;
  }
  if (isPending(ticket)) {
    pending.push(`${line}（待定）`);
    continue;
  }
  const openBlockers = blockers.get(number) || [];
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
for (const [title, lines] of [
  ['# blocked', blocked],
  ['# human', human],
  ['# decision', pending],
  ['# shelved', shelved],
  ['# source', source],
]) {
  out.push(...section(title, lines));
}
process.stdout.write(`${out.join('\n')}\n`);
NODE
