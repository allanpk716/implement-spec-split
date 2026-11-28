#!/usr/bin/env bash
# Graph reading library: the one way frontier.sh and landing-check.sh read the
# graph of a repository (票 #86).
#
# Source it and call its functions. The two scripts read the same graph the same
# way — the same arguments, the same pipeline-status.sh --graph call, the same
# blocked_by endpoint, the same reading of a Ticket's labels — so that is
# written here once; what each script concludes from what it read stays in the
# script.
#
#   shell   graph_parse_args      --repo and --spec, --help, usage errors (64)
#           graph_require_tools   gh, node and pipeline-status.sh (1 when one is missing)
#           graph_load            pipeline-status.sh --graph into GRAPH_FILE (1 when it fails)
#           graph_node            the node reading layer, then the script's own node code
#
# graph_parse_args sets GRAPH_REPO and GRAPH_SPEC; graph_load sets GRAPH_FILE
# (the graph) and GRAPH_ERR (pipeline-status.sh's stderr) and installs the EXIT
# trap that removes both. The three are what graph_node hands to node.
#
# graph_node reads that code from stdin and runs it after the layer, so a script
# writes `graph_node <<'NODE' … NODE` where it wrote `node - … <<'NODE'`. The
# layer hands the code `repo`, `spec`, `tickets` (the Spec's Tickets, ascending),
# `open`, `fail` (exit 1), `missing` (exit 3), `parsePage`, `openBlockersOf`,
# `isPending`, `titled`, `clean` and `section`.
#
# The exit codes are the two scripts' own, and the functions here keep them:
#   1  fail closed: pipeline-status.sh --graph or a gh query failed
#   3  fail closed for good: the graph has no such Spec
#  64  bad usage
# Exit 3 is kept apart from 1 because SKILL.md step 9 retries a 1 and parks on a
# 3 at once: a Spec that is missing from the graph does not come back by
# waiting, and a keeper that resumed it would only find it missing again.
#
# GRAPH_NAME is the word the caller's messages start with (`landing-check: …`,
# `frontier: …`). It is read off the caller's own file name, so a script needs
# no line of its own; set it before sourcing to override. Nothing here runs a
# tool while it is sourced: a caller with a bare PATH keeps its name and its
# messages.

# --- plumbing -----------------------------------------------------------------

if [ -z "${GRAPH_NAME:-}" ]; then
  # The caller's own file name, its directory and `.sh` left out — read without
  # a tool, so the name survives a PATH that lacks one.
  GRAPH_NAME=${0##*/}
  GRAPH_NAME=${GRAPH_NAME%.sh}
fi
# pipeline-status.sh lies next to this file, as it does next to every caller.
# The directory is read without a tool too (a bare file name means this one).
GRAPH_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$GRAPH_LIB_DIR" != "${BASH_SOURCE[0]}" ] || GRAPH_LIB_DIR=.
GRAPH_PIPELINE_STATUS=$(cd "$GRAPH_LIB_DIR" && pwd)/pipeline-status.sh

graph_usage_error() { # message: exits 64
  printf '%s: %s\n' "$GRAPH_NAME" "$1" >&2
  exit 64
}

graph_fail_closed() { # message: exits 1
  printf '%s: %s\n' "$GRAPH_NAME" "$1" >&2
  exit 1
}

# --- arguments -----------------------------------------------------------------

graph_parse_args() { # <arguments...>: reads --repo and --spec into GRAPH_REPO and GRAPH_SPEC
  GRAPH_REPO=
  GRAPH_SPEC=
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        [ $# -ge 2 ] || graph_usage_error "--repo requires <owner/name>"
        GRAPH_REPO=$2
        shift 2
        ;;
      --spec)
        [ $# -ge 2 ] || graph_usage_error "--spec requires <n>"
        GRAPH_SPEC=$2
        shift 2
        ;;
      -h|--help)
        # The caller's header comment, from its second line down to `set -u`.
        sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        graph_usage_error "unknown argument: $1"
        ;;
    esac
  done
  [ -n "$GRAPH_REPO" ] || graph_usage_error "--repo is required"
  [ -n "$GRAPH_SPEC" ] || graph_usage_error "--spec is required"
  [[ "$GRAPH_SPEC" =~ ^[0-9]+$ ]] || graph_usage_error "--spec must be an issue number (got $GRAPH_SPEC)"
}

# --- the graph -----------------------------------------------------------------

graph_require_tools() { # exits 1 when gh, node or pipeline-status.sh is missing
  command -v gh >/dev/null 2>&1 || graph_fail_closed "gh is required but was not found on PATH"
  command -v node >/dev/null 2>&1 || graph_fail_closed "node is required but was not found on PATH"
  [ -f "$GRAPH_PIPELINE_STATUS" ] || graph_fail_closed "pipeline-status.sh not found next to ${GRAPH_NAME}.sh"
}

graph_load() { # runs pipeline-status.sh --graph for GRAPH_REPO; GRAPH_FILE then holds the graph
  GRAPH_FILE=$(mktemp "${TMPDIR:-/tmp}/${GRAPH_NAME}-graph.XXXXXX") ||
    graph_fail_closed "could not create a temporary graph file"
  GRAPH_ERR=$(mktemp "${TMPDIR:-/tmp}/${GRAPH_NAME}-graph-err.XXXXXX") ||
    graph_fail_closed "could not create a temporary graph error file"
  trap 'rm -f "$GRAPH_FILE" "$GRAPH_ERR" 2>/dev/null' EXIT

  if ! "$GRAPH_PIPELINE_STATUS" --repo "$GRAPH_REPO" --graph > "$GRAPH_FILE" 2> "$GRAPH_ERR"; then
    printf '%s: pipeline-status.sh --graph failed for %s\n' "$GRAPH_NAME" "$GRAPH_REPO" >&2
    sed -n '1,20p' "$GRAPH_ERR" >&2
    exit 1
  fi
}

graph_node() { # the script's own node code on stdin: runs it after the reading layer
  {
    cat <<'NODE'
const fs = require('fs');
const cp = require('child_process');

// [node, -, name, graphFile, repo, specNumber]
const name = process.argv[2];
const graphFile = process.argv[3];
const repo = process.argv[4];
const specNumber = Number(process.argv[5]);

// Exit 1 is a failure that may pass (a query failed) and exit 3 one that will
// not (the graph has no such Spec); the header of lib-graph.sh says why they
// are kept apart.
function fail(message) {
  process.stderr.write(`${name}: ${message}\n`);
  process.exit(1);
}

function missing(message) {
  process.stderr.write(`${name}: ${message}\n`);
  process.exit(3);
}

let graph;
try {
  graph = JSON.parse(fs.readFileSync(graphFile, 'utf8'));
} catch (error) {
  fail(`cannot parse pipeline-status --graph output: ${error.message}`);
}

// The Spec among the graph's Specs, landed ones included, by issue number.
const spec = (Array.isArray(graph.specs) ? graph.specs : [])
  .find((item) => Number(item.number) === specNumber);
if (!spec) {
  missing(`spec #${specNumber} not found in the ${repo} graph; is it an issue with a ## Problem Statement heading?`);
}

// The Spec's Tickets, ascending, and the open ones among them.
const tickets = (Array.isArray(spec.tickets) ? spec.tickets : [])
  .slice()
  .sort((a, b) => Number(a.number) - Number(b.number));
const open = tickets.filter((ticket) => ticket.state === 'open');

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

// The open blockers of one issue, ascending, from the endpoint both scripts
// read. Fails closed when gh does.
function openBlockersOf(number) {
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
  return (Array.isArray(list) ? list : [])
    .filter((item) => item && item.state === 'open')
    .map((item) => Number(item.number))
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => a - b);
}

function clean(value) {
  return String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
}

// `#<number> <title>`, the way both scripts name a Ticket on a line.
function titled(ticket) {
  return `#${Number(ticket.number)} ${clean(ticket.title)}`;
}

// A section of the output: its title, then its lines, or `（无）` when it has none.
function section(title, lines) {
  return [title, ...(lines.length > 0 ? lines : ['（无）'])];
}

// An open Ticket that waits for a person before any agent may take it (票 #86):
// it carries no `ready-for-agent` label (the graph's `ready_for_agent` flag), and
// is none of the other kinds that are accounted for elsewhere — a human Ticket
// (`ready-for-human`), a shelved one, the loose source ticket. Both scripts
// list it under `# decision`, dispatch nothing for it and ask for no blockers of
// its own, and landing-check.sh lets no landing wait for it. What it waits for
// is a person's triage: the label back (then it is an execution Ticket again),
// or its closure. A Ticket that carries `ready-for-agent` is an execution
// Ticket whatever else it carries.
function isPending(ticket) {
  return ticket.ready_for_agent !== true && ticket.human !== true &&
    ticket.shelved !== true && ticket.source !== true;
}
NODE
    cat
  } | node - "$GRAPH_NAME" "$GRAPH_FILE" "$GRAPH_REPO" "$GRAPH_SPEC"
}
