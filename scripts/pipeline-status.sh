#!/usr/bin/env bash
# List unfinished work in the wayfinder -> to-spec -> to-tickets -> implement pipeline.
# --order's --apart pairs keep two Specs out of one wave, and keep the idle side out of
# the new wave while the other is in flight (running, or resumed first); see usage().

set -u

usage() {
  cat <<'EOF'
Usage: pipeline-status.sh [--repo <owner/name>] [--all] [--order] [--graph] [-h|--help]

Scan GitHub issues and local git branches, then list unfinished pipeline work by
stage. Without --repo, the repository is detected with `gh repo view`.

Only GitHub is supported. For other issue trackers, follow that repository's
tracker documentation instead.

  --all                  Also list decision details, empty maps, stale claims, hygiene, and loose issues.
                         Fresh wayfinder claims with no live Orca agent terminal naming the
                         ticket (#N in title or preview) in this repository's worktrees are
                         listed as orphan claims; without Orca they are left unchecked.
                         Hygiene reports `人工票待做：#n` for a Spec whose open execution
                         tickets are all `ready-for-human`; such tickets are never dispatched.
                         规格已落地、源票未关 lists an open loose ticket that a 实现票 line
                         names only on closed Specs.
  --order                Print a deterministic development order for implementable Specs.
  --parallel K           With --order, plan for K concurrent Specs (default: 2).
  --workers N            With --order, split N total workers across K concurrent Specs.
  --apart A:B            With --order, keep A and B out of the same wave, and keep the idle
                         side out of the new wave while the other is in flight (running, or
                         interrupted and resumed first). Repeatable.
  --cmd-suffix STR       With --order, append STR to each command (default: --auto-land; '' for none).
  --json                 With --order, print the same plan as JSON instead of a text table.
  --graph                Print the full relation graph as JSON for the Progress board (closed
                         maps, Specs and Tickets included); takes the --order options.
                         Top level: repo; counts {maps, specs, tickets}; maps[] {number, title,
                         state, shelved, has_fog, status closed|shelved|empty|exploring|
                         fog_pending|unconverted|converted, decisions_total, decisions_open,
                         spec_numbers, tickets[]}; specs[] {number, title, kind, state,
                         status landed|needs_tickets|ready|running|interrupted|shelved|human, map
                         (number or null), has_tickets, tickets[] {number, title, state,
                         shelved, human, ready_for_agent, on_hold, shared_counter, source},
                         tickets_total, tickets_closed, claim {state active|reserved|
                         interrupted|idle, branch, worktree, claimed_at} or null,
                         depends_on, extra_blockers}; loose_specs[] (Specs without a map);
                         next_wave (same object as --order --json).
                         Ticket flags come from GitHub labels, the title or the body:
                         `human` is the `ready-for-human` label, `ready_for_agent` the
                         `ready-for-agent` label, `on_hold` one of the labels that hold a
                         Ticket for a person (`needs-info`, `needs-triage`, `wontfix`). An
                         open Ticket that is neither `ready-for-human`, shelved nor the
                         source waits for a person's triage when it carries no
                         `ready-for-agent`, or when `on_hold` is set whatever else it
                         carries (either way frontier.sh lists it under `# decision` and
                         dispatches nothing for it, landing-check.sh holds no landing back
                         for it), `shared_counter`
                         the `shared-counter` label (a Ticket that bumps a shared counter;
                         frontier.sh releases one such Ticket at a time), `source` the loose
                         source ticket of a Spec without sub-issues (the mapless ticket its
                         实现票 line names), which is not an execution Ticket.

PIPELINE_STATUS_NOW may set an ISO-8601 current time for deterministic stale-claim tests.
PIPELINE_STATUS_ORCA_TERMINALS_JSON may name a file holding `orca terminal list --json`
output for orphan-claim tests; without it Orca is asked through scripts/lib-orca.sh,
which reads ISS_ORCA to name the Orca executable.
EOF
}

die() {
  printf 'pipeline-status: %s\n' "$1" >&2
  exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The one Orca call is made by the node code, which runs scripts/lib-orca.sh
# instead of spawning orca; ISS_LIB_ORCA (pipeline_node) hands it the library.
PID_START="$HERE/pid-start.sh"

REPO=
ALL=0
ORDER=0
PARALLEL=2
WORKERS=
# Every command launches unattended unless the caller opts the batch out
# (launch-wave passes '' then); how a Spec's tickets are implemented is the
# Stage route table's business, not an argument of the command.
CMD_SUFFIX='--auto-land'
JSON=0
GRAPH=0
APART=()
APART_COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo requires <owner/name>"
      REPO=$2
      shift 2
      ;;
    --all)
      ALL=1
      shift
      ;;
    --order)
      ORDER=1
      shift
      ;;
    --parallel)
      [ $# -ge 2 ] || die "--parallel requires <K>"
      case "$2" in
        *[!0-9]*|'') die "--parallel requires a positive integer" ;;
        0) die "--parallel requires a positive integer" ;;
      esac
      PARALLEL=$2
      shift 2
      ;;
    --workers)
      [ $# -ge 2 ] || die "--workers requires <N>"
      case "$2" in
        *[!0-9]*|'') die "--workers requires a positive integer" ;;
        0) die "--workers requires a positive integer" ;;
      esac
      WORKERS=$2
      shift 2
      ;;
    --apart)
      [ $# -ge 2 ] || die "--apart requires <A:B>"
      if ! [[ "$2" =~ ^[0-9]+:[0-9]+$ ]]; then
        die "--apart requires <A:B> with two issue numbers"
      fi
      APART+=("$2")
      APART_COUNT=$((APART_COUNT + 1))
      shift 2
      ;;
    --cmd-suffix)
      [ $# -ge 2 ] || die "--cmd-suffix requires <STR>"
      CMD_SUFFIX=$2
      shift 2
      ;;
    --json)
      JSON=1
      shift
      ;;
    --graph)
      GRAPH=1
      ORDER=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[ "$JSON" -eq 0 ] || [ "$ORDER" -eq 1 ] ||
  die "--json is only supported with --order"

command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"
command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"

# Keep every GitHub call in these two wrappers. They are also the seams used by
# scripts/test-pipeline-status.sh's fake gh.
gh_api() {
  gh api "$@"
}

gh_current_repo() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

if [ -z "$REPO" ]; then
  REPO=$(gh_current_repo) || die "could not detect the GitHub repository with gh repo view"
  [ -n "$REPO" ] || die "gh repo view returned an empty repository name"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pipeline-status.XXXXXX") ||
  die "could not create a temporary work directory"
trap 'rm -r "$WORK" 2>/dev/null' EXIT
mkdir -p "$WORK/endpoints" "$WORK/blockers" ||
  die "could not prepare the temporary work directory"

ISSUES_FILE=$WORK/issues.json
STAGE_FILE=$WORK/stage.json
PIPELINE_FILE=$WORK/pipeline.json

pipeline_node() {
  mode=$1
  shift
  ISS_PID_START_SCRIPT="$PID_START" ISS_LIB_ORCA="$HERE/lib-orca.sh" \
    node - "$mode" "$@" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const mode = process.argv[2];
const args = process.argv.slice(3);
const STALE_CLAIM_MS = 3 * 24 * 60 * 60 * 1000;

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function issueLabels(issue) {
  if (!Array.isArray(issue.labels)) return [];
  return issue.labels.map((label) => (
    typeof label === 'string' ? label : label.name
  )).filter(Boolean);
}

function hasLabel(issue, label) {
  return issueLabels(issue).includes(label);
}

// The triage labels that hold a Ticket for a person — a reporter's information,
// a maintainer's triage, or the decision not to fix it — before any agent may
// take it, whatever else the Ticket carries (票 #86; GLOSSARY.md "Pending
// ticket"). The graph reports them as one flag, `on_hold`.
const HOLD_LABELS = ['needs-info', 'needs-triage', 'wontfix'];

function hasHoldLabel(issue) {
  return HOLD_LABELS.some((label) => hasLabel(issue, label));
}

function hasWayfinderLabel(issue) {
  return issueLabels(issue).some((label) => label.startsWith('wayfinder:'));
}

function isMap(issue) {
  return hasLabel(issue, 'wayfinder:map');
}

function isOpen(issue) {
  return issue.state === 'open';
}

function hasProblemStatement(issue) {
  return String(issue.body || '').split(/\r?\n/).some((line) => line.trim() === '## Problem Statement');
}

function isShelved(issue) {
  if (String(issue.title || '').includes('搁置')) return true;
  return String(issue.body || '').split(/\r?\n/).some((line) => (
    /(?:状态|Status)\s*[:：]/i.test(line) &&
    (line.includes('搁置') || /\bshelved\b/i.test(line))
  ));
}

function summary(issue) {
  return issue.sub_issues_summary || {total: 0, completed: 0};
}

function unfinishedChildren(issue) {
  const value = summary(issue);
  return Number(value.total || 0) > 0 &&
    Number(value.completed || 0) < Number(value.total || 0);
}

function bodyReferences(issue) {
  const refs = new Set();
  const body = String(issue.body || '');
  const pattern = /(?:实现票\s*(?:[:：]|为|是)|Implementation\s+tickets?\s*[:：])\s*#[0-9]+(?:\s*(?:[,，、和]|and)\s*#[0-9]+)*/gi;
  const numberPattern = /#([0-9]+)/g;
  for (const line of body.split(/\r?\n/)) {
    let match;
    while ((match = pattern.exec(line)) !== null) {
      let numberMatch;
      while ((numberMatch = numberPattern.exec(match[0])) !== null) {
        refs.add(Number(numberMatch[1]));
      }
      numberPattern.lastIndex = 0;
    }
    pattern.lastIndex = 0;
  }
  return [...refs].sort((a, b) => a - b);
}

// The line-anchored twin of bodyReferences, read the way publish-batch.sh
// reads the line: only a line that starts with the 实现票 label names
// tickets. It serves the #83 loose-source semantics (source-ticket
// registration, the 散票 exclusion, landedSourceTickets); bodyReferences
// stays the looser set that every map-ticket path and its pinned
// expectations are built on.
function lineReferences(issue) {
  const refs = new Set();
  const pattern = /^[ \t]*(?:[-*][ \t]+)?(?:\*\*[ \t]*)?(?:实现票[ \t]*(?:[:：]|为|是)|Implementation[ \t]+tickets?[ \t]*[:：])[ \t]*#[0-9]+(?:[ \t]*(?:[,，、和]|and)[ \t]*#[0-9]+)*/i;
  for (const line of String(issue.body || '').split(/\r?\n/)) {
    const match = pattern.exec(line);
    if (!match) continue;
    for (const numberMatch of match[0].matchAll(/#([0-9]+)/g)) {
      refs.add(Number(numberMatch[1]));
    }
  }
  return [...refs].sort((a, b) => a - b);
}

function bodyMapReferences(issue) {
  const refs = new Set();
  const pattern = /^\s*(?:[-*]\s+)?(?:\*\*\s*)?(?:(?:来源)?地图|Map)\s*(?:\*\*)?\s*[:：]\s*(?:\*\*)?\s*#([0-9]+)(?![0-9])/i;
  for (const line of String(issue.body || '').split(/\r?\n/)) {
    const match = pattern.exec(line.trim());
    if (match) refs.add(Number(match[1]));
  }
  return [...refs].sort((a, b) => a - b);
}

function looseFromMap(issue) {
  for (const line of String(issue.body || '').split(/\r?\n/)) {
    const explicit = line.match(/^\s*(?:[-*]\s+)?(?:\*\*\s*)?来源地图\s*(?:\*\*)?\s*[:：]\s*(?:\*\*)?\s*#([0-9]+)(?![0-9])/i);
    if (explicit) return Number(explicit[1]);
    const narrative = line.match(/来自[^\r\n]*地图[^\r\n]*\(#([0-9]+)\)/);
    if (narrative) return Number(narrative[1]);
  }
  return null;
}

function looseTiming(issue) {
  for (const line of String(issue.body || '').split(/\r?\n/)) {
    const match = line.match(/^\s*(?:[-*]\s+)?(?:\*\*)?时机\s*[:：]\s*(.*)$/);
    if (!match) continue;
    const value = match[1].replace(/\*\*$/, '').trim();
    if (value === '') return null;
    return value.length > 120 ? value.slice(0, 120) : value;
  }
  return null;
}

function mapHasFog(issue) {
  const lines = String(issue.body || '').split(/\r?\n/);
  let start = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (/^##\s+Not yet specified\s*$/.test(lines[index])) {
      start = index + 1;
      break;
    }
  }
  if (start < 0) return false;

  let section = [];
  for (let index = start; index < lines.length; index += 1) {
    if (/^##\s+/.test(lines[index])) break;
    section.push(lines[index]);
  }
  const withoutComments = section.join('\n').replace(/<!--[\s\S]*?-->/g, '');
  const compact = withoutComments.replace(/\s+/g, '');
  const withoutListMarker = compact.replace(/^[-*+]/, '').toLowerCase();
  return !['', '无', '（无）', '(无)', 'none', 'n/a', '-']
    .includes(withoutListMarker);
}

function compactIssue(issue) {
  return {
    number: issue.number,
    state: issue.state,
    title: issue.title || '',
    labels: issueLabels(issue),
    childTotal: Number(summary(issue).total || 0),
    childCompleted: Number(summary(issue).completed || 0),
    body: issue.body || '',
  };
}

function readEndpoint(dir, kind, number) {
  const file = path.join(dir, `${kind}-${number}.json`);
  if (!fs.existsSync(file)) return [];
  const value = readJson(file);
  return Array.isArray(value) ? value : [];
}

function uniqueNumbers(values) {
  return [...new Set(values.map(Number))].sort((a, b) => a - b);
}

function numberLines(values) {
  return values.join('\n');
}

// Git helpers shared by the render and order modes, so both judge a Spec's
// branches the same way; keep a single copy and change the rule here only.
const gitState = {checked: false, inside: false};
function insideGit() {
  if (!gitState.checked) {
    try {
      const result = cp.execFileSync('git', ['rev-parse', '--is-inside-work-tree'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }).trim();
      gitState.inside = result === 'true';
    } catch (_) {
      gitState.inside = false;
    }
    gitState.checked = true;
  }
  return gitState.inside;
}

function gitSucceeds(args) {
  try {
    cp.execFileSync('git', args, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
    return true;
  } catch (_) {
    return false;
  }
}

// A leftover spec-<n>-* branch only proves in-flight work while it still
// holds commits the main branch lacks. One that has landed completely is
// debris from a (partial) landing and leaves the Spec free, exactly like the
// deleted integration branch does (GLOSSARY.md, Partial landing).
const mainBranchState = {checked: false, ref: ''};
function mainBranchRef() {
  if (!mainBranchState.checked) {
    mainBranchState.ref = [
      'refs/remotes/origin/HEAD', 'refs/remotes/origin/main', 'refs/heads/main',
    ].find((ref) => gitSucceeds(['rev-parse', '--verify', '--quiet', ref])) || '';
    mainBranchState.checked = true;
  }
  return mainBranchState.ref;
}

function mergedIntoMain(branch) {
  const main = mainBranchRef();
  // Without a main branch to compare against, the branch keeps counting.
  return main !== '' && gitSucceeds(['merge-base', '--is-ancestor', branch, main]);
}

function integrationBranch(number) {
  if (!insideGit()) return null;
  try {
    const exact = `spec-${number}`;
    const output = cp.execFileSync('git', [
      'branch', '--list', exact, `${exact}-*`, '--format=%(refname:short)',
    ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
      .split(/\r?\n/).map((value) => value.trim()).filter(Boolean);
    if (output.includes(exact)) return exact;
    return output.find((branch) => (
      branch.startsWith(`${exact}-`) && !mergedIntoMain(branch)
    )) || null;
  } catch (_) {
    return null;
  }
}

if (mode === 'map-requests') {
  const issues = readJson(args[0]).filter((issue) => !issue.pull_request);
  const maps = issues.filter(isMap).map((issue) => issue.number).sort((a, b) => a - b);
  process.stdout.write(numberLines(maps));
  process.exit(0);
}

if (mode === 'plan') {
  const issues = readJson(args[0]).filter((issue) => !issue.pull_request);
  const endpointDir = args[1];
  const all = args[2] === '1';
  const byNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));
  const mapIssues = issues.filter(isMap).sort((a, b) => a.number - b.number);
  const maps = [];
  const implementations = new Map();
  const mapChildNumbers = new Set();

  for (const mapIssue of mapIssues) {
    const children = readEndpoint(endpointDir, 'map', mapIssue.number);
    const decisions = children.filter((child) => hasWayfinderLabel(child));
    const implChildren = children.filter((child) => (
      isOpen(child) && !hasWayfinderLabel(child)
    ));
    const frontierIsEmpty = children.length > 0 && children.every((child) => (
      hasWayfinderLabel(child) && !isOpen(child)
    ));
    maps.push({
      number: mapIssue.number,
      state: mapIssue.state,
      title: mapIssue.title || '',
      openDecisionCount: decisions.filter(isOpen).length,
      open: isOpen(mapIssue),
      shelved: isShelved(mapIssue),
      childCount: children.length,
      frontierIsEmpty,
      hasFog: mapHasFog(mapIssue),
      openImplementationCount: implChildren.length,
    });
    for (const child of implChildren) {
      const record = compactIssue(child);
      record.mapNumber = Number(mapIssue.number);
      implementations.set(Number(child.number), record);
    }
    for (const child of children) {
      mapChildNumbers.add(Number(child.number));
    }
  }

  const allProblemSpecs = issues.filter((issue) => (
    !issue.pull_request && hasProblemStatement(issue)
  )).map((issue) => ({
    number: issue.number,
    state: issue.state,
    title: issue.title || '',
    refs: bodyReferences(issue),
    lineRefs: lineReferences(issue),
    ownChildren: Number(summary(issue).total || 0) > 0,
    ownChildCount: Number(summary(issue).total || 0),
    ownChildCompleted: Number(summary(issue).completed || 0),
    mapRefs: bodyMapReferences(issue),
  })).sort((a, b) => a.number - b.number);

  // A 实现票 line may also name a loose ticket: the source ticket a Spec was
  // drafted from (#83). It is the Spec's implementation the way a map ticket
  // is, only without a map (mapNumber null): it counts as covered, becomes the
  // Ticket of a single-ticket Spec, and is reported once its Spec has landed.
  // Only a line-anchored reference counts (lineReferences), so prose that
  // mentions the label mid-line registers nothing. Only an open ticket without
  // children counts; one with children keeps the role the scanner already gave
  // it (a legacy parent, a map's child).
  for (const spec of allProblemSpecs) {
    for (const ref of spec.lineRefs) {
      const issue = byNumber.get(Number(ref));
      if (!issue || mapChildNumbers.has(Number(ref))) continue;
      if (!isOpen(issue) || isMap(issue) || hasProblemStatement(issue)) continue;
      if (Number(summary(issue).total || 0) > 0) continue;
      const record = compactIssue(issue);
      record.mapNumber = null;
      implementations.set(Number(ref), record);
    }
  }

  const implementationValues = [...implementations.values()];
  const coveredRefs = uniqueNumbers(allProblemSpecs.flatMap((spec) => spec.refs));
  const coveredLineRefs = uniqueNumbers(allProblemSpecs.flatMap((spec) => spec.lineRefs));
  const coveredMapRefs = uniqueNumbers(allProblemSpecs.flatMap((spec) => spec.mapRefs));
  const problemSpecs = allProblemSpecs.filter((spec) => isOpen(spec));

  const oldCandidates = issues.filter((issue) => (
    isOpen(issue) &&
    !issue.pull_request &&
    !isMap(issue) &&
    !mapChildNumbers.has(Number(issue.number)) &&
    !hasProblemStatement(issue) &&
    unfinishedChildren(issue)
  )).map((issue) => ({
    number: issue.number,
    title: issue.title || '',
    ownChildCount: Number(summary(issue).total || 0),
  })).sort((a, b) => a.number - b.number);

  const requests = [];
  const requestSet = new Set();
  const request = (number) => {
    if (!requestSet.has(number)) {
      requestSet.add(number);
      requests.push(number);
    }
  };
  for (const spec of problemSpecs) {
    if (spec.ownChildren) request(spec.number);
  }
  for (const impl of implementationValues) {
    if (impl.childTotal > 0) request(impl.number);
  }
  for (const oldSpec of oldCandidates) request(oldSpec.number);
  requests.sort((a, b) => a - b);

  const closedSpecs = all ? allProblemSpecs.filter((spec) => (
    !isOpen(spec) && spec.ownChildren &&
    spec.ownChildCompleted < spec.ownChildCount
  )) : [];

  const output = {
    maps,
    implementations: implementationValues.sort((a, b) => a.number - b.number),
    specs: problemSpecs,
    allProblemSpecs: all ? allProblemSpecs : [],
    coveredRefs,
    coveredLineRefs,
    coveredMapRefs,
    oldCandidates,
    subRequests: requests,
    closedSpecs,
    closedSpecRequests: closedSpecs.map((spec) => spec.number),
  };
  process.stdout.write(JSON.stringify(output, null, 2));
  process.exit(0);
}

if (mode === 'collect') {
  const issues = readJson(args[0]).filter((issue) => !issue.pull_request);
  const stage = readJson(args[1]);
  const endpointDir = args[2];
  const all = args[3] === '1';
  const byNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));
  const implementations = new Map(stage.implementations.map((impl) => [Number(impl.number), impl]));

  // `source` marks the loose source ticket of a Spec (#83, mapNumber null): it
  // is in the Spec's `tickets` in the graph and in the coverage counts, but not
  // an execution Ticket. Only the caller that knows the ticket is one sets it;
  // the flag is false on every other path.
  function ticketRecord(number, source = false) {
    const issue = byNumber.get(Number(number));
    return {
      number: Number(number),
      state: issue ? issue.state : 'open',
      title: issue ? issue.title : '',
      shelved: issue ? isShelved(issue) : false,
      human: issue ? hasLabel(issue, 'ready-for-human') : false,
      // Read for the graph alone (ticketOf below reports them as `ready_for_agent`
      // and `on_hold`): an open Ticket without the first label, or with one of
      // the hold labels beside it, waits for a person's triage, and frontier.sh
      // and landing-check.sh keep it apart from the execution Tickets (票 #86).
      // Nothing in this script's own sections reads them yet.
      readyForAgent: issue ? hasLabel(issue, 'ready-for-agent') : false,
      onHold: issue ? hasHoldLabel(issue) : false,
      sharedCounter: issue ? hasLabel(issue, 'shared-counter') : false,
      source,
    };
  }

  function onlyShelvedOpenTickets(spec) {
    const openTickets = spec.tickets.filter((ticket) => ticket.state === 'open');
    return openTickets.length > 0 && openTickets.every((ticket) => ticket.shelved);
  }

  // A `ready-for-human` execution ticket is not waiting for an implementer,
  // exactly like a shelved one: it never enters 可以实现, the order or a wave.
  // A Spec whose open tickets are all shelved or human counts as human-only
  // when at least one is human, so --all can say who must still do it.
  function onlyHumanOpenTickets(spec) {
    const openTickets = spec.tickets.filter((ticket) => ticket.state === 'open');
    return openTickets.length > 0 &&
      openTickets.every((ticket) => ticket.shelved || ticket.human) &&
      openTickets.some((ticket) => ticket.human);
  }

  // Every issue that is somebody's child: a map's, a Spec's (its own, or an
  // implementation's), a legacy parent's. Known in every mode: the map and
  // subRequests endpoints are always loaded; closed Specs' sub endpoints
  // exist only under --all and --graph, and add nothing otherwise.
  const knownChildren = new Set();
  const mapChildren = new Set();
  for (const map of stage.maps) {
    for (const child of readEndpoint(endpointDir, 'map', map.number)) {
      knownChildren.add(Number(child.number));
      mapChildren.add(Number(child.number));
    }
  }
  const endpointNumbers = uniqueNumbers([
    ...(stage.subRequests || []),
    ...(stage.closedSpecRequests || []),
  ]);
  for (const number of endpointNumbers) {
    for (const child of readEndpoint(endpointDir, 'sub', number)) {
      knownChildren.add(Number(child.number));
    }
  }
  for (const oldSpec of stage.oldCandidates || []) {
    knownChildren.add(Number(oldSpec.number));
  }

  // The implementation a 实现票 reference names, for a childless Spec. A map
  // ticket always counts. A loose source ticket (#83, mapNumber null) counts
  // only when it is nobody's child: a line that misnames another issue's
  // child names no implementation, and the Spec stays in 有规格、未拆票.
  function implementationOf(ref) {
    const impl = implementations.get(Number(ref));
    if (!impl || impl.mapNumber !== null) return impl;
    return knownChildren.has(Number(ref)) ? undefined : impl;
  }

  const shelvedOnlySpecs = [];
  const humanOnlySpecs = [];
  const implement = [];
  for (const spec of stage.specs) {
    const referencesImplementation = spec.refs.some((ref) => implementationOf(ref));
    if (!spec.ownChildren && !referencesImplementation) continue;
    const tickets = [];
    const ticketSet = new Set();
    const addTickets = (numbers, source = false) => {
      for (const number of numbers) {
        if (!ticketSet.has(Number(number))) {
          ticketSet.add(Number(number));
          tickets.push(ticketRecord(number, source));
        }
      }
    };

    if (spec.ownChildren) {
      addTickets(readEndpoint(endpointDir, 'sub', spec.number).map((issue) => issue.number));
    } else {
      for (const ref of spec.refs) {
        const impl = implementationOf(ref);
        if (!impl) continue;
        if (impl.childTotal > 0) {
          addTickets(readEndpoint(endpointDir, 'sub', impl.number).map((issue) => issue.number));
        } else {
          // The single Ticket is the implementation itself. A mapless one is
          // the loose source ticket, flagged `source`: frontier.sh dispatches
          // no implementer for it and landing-check.sh does not count it
          // against the landing; it is closed with its Spec when that lands.
          addTickets([impl.number], impl.mapNumber === null);
        }
      }
    }
    tickets.sort((a, b) => a.number - b.number);
    const record = {
      number: spec.number,
      title: spec.title,
      kind: 'spec',
      tickets,
      closed: tickets.filter((ticket) => ticket.state === 'closed').length,
    };
    if (onlyShelvedOpenTickets(record)) shelvedOnlySpecs.push(record);
    else {
      if (onlyHumanOpenTickets(record)) {
        record.human_only = true;
        humanOnlySpecs.push(record);
      }
      implement.push(record);
    }
  }

  for (const oldSpec of stage.oldCandidates) {
    const tickets = readEndpoint(endpointDir, 'sub', oldSpec.number)
      .map((issue) => ticketRecord(issue.number))
      .sort((a, b) => a.number - b.number);
    const record = {
      number: oldSpec.number,
      title: oldSpec.title,
      kind: 'legacy',
      tickets,
      closed: tickets.filter((ticket) => ticket.state === 'closed').length,
    };
    if (onlyShelvedOpenTickets(record)) shelvedOnlySpecs.push(record);
    else {
      if (onlyHumanOpenTickets(record)) {
        record.human_only = true;
        humanOnlySpecs.push(record);
      }
      implement.push(record);
    }
  }
  implement.sort((a, b) => a.number - b.number);

  const needsTickets = stage.specs
    .filter((spec) => !spec.ownChildren && !spec.refs.some((ref) => implementationOf(ref)))
    .map((spec) => ({number: spec.number, title: spec.title, refs: spec.refs}))
    .sort((a, b) => a.number - b.number);

  const referencedImplementations = new Set();
  for (const ref of stage.coveredRefs || []) {
    referencedImplementations.add(Number(ref));
  }
  const missing = [];
  for (const map of stage.maps) {
    const children = [...implementations.values()].filter((impl) => (
      impl.mapNumber === Number(map.number)
    ));
    const tickets = children.filter((impl) => (
      !referencedImplementations.has(Number(impl.number)) && impl.childTotal === 0
    )).sort((a, b) => a.number - b.number);
    if (tickets.length > 0) {
      missing.push({
        number: map.number,
        title: map.title,
        tickets,
      });
    }
  }
  missing.sort((a, b) => a.number - b.number);

  const referencedMaps = new Set((stage.coveredMapRefs || []).map(Number));
  const readyMapFilter = (map) => (
      map.open &&
      !map.shelved &&
      map.childCount > 0 &&
      map.frontierIsEmpty &&
      Number(map.openImplementationCount || 0) === 0 &&
      !referencedMaps.has(Number(map.number))
    );
  const mapSpecs = stage.maps
    .filter((map) => readyMapFilter(map) && !map.hasFog)
    .map((map) => ({number: map.number, title: map.title}))
    .sort((a, b) => a.number - b.number);

  // Fog graduates whenever decisions are all closed, even if Specs already
  // point back or implementation tickets are open: the map is still not done.
  const fogMaps = stage.maps
    .filter((map) => (
      map.open && !map.shelved && map.childCount > 0 &&
      Number(map.openDecisionCount || 0) === 0 && map.hasFog
    ))
    .map((map) => ({number: map.number, title: map.title}))
    .sort((a, b) => a.number - b.number);

  const emptyMaps = stage.maps
    .filter((map) => map.open && !map.shelved && Number(map.childCount) === 0)
    .map((map) => ({number: map.number, title: map.title}))
    .sort((a, b) => a.number - b.number);

  const exploring = stage.maps
    .filter((map) => map.openDecisionCount > 0)
    .map((map) => {
      const record = {
        number: map.number,
        title: map.title,
        openDecisionCount: map.openDecisionCount,
      };
      if (all) {
        record.decisions = readEndpoint(endpointDir, 'map', map.number)
          .filter((decision) => isOpen(decision) && hasWayfinderLabel(decision))
          .map((decision) => {
            const dependencies = decision.issue_dependencies_summary || {};
            const assignees = Array.isArray(decision.assignees) ? decision.assignees : [];
            return {
              number: Number(decision.number),
              title: decision.title || '',
              label: issueLabels(decision).find((label) => label.startsWith('wayfinder:')) || '',
              blockedBy: Number(dependencies.blocked_by || 0),
              assignees: assignees.map((assignee) => (
                typeof assignee === 'string' ? assignee : assignee.login
              )).filter(Boolean),
            };
          })
          .sort((a, b) => a.number - b.number);
      }
      return record;
    })
    .sort((a, b) => a.number - b.number);

  const hygiene = all ? shelvedOnlySpecs.map((spec) => ({
    kind: 'shelved-only-spec',
    number: spec.number,
    title: spec.title,
    tickets: spec.tickets.filter((ticket) => (
      ticket.state === 'open' && ticket.shelved
    )).sort((a, b) => a.number - b.number),
  })) : [];
  const landedSourceTickets = [];
  if (all) {
    for (const spec of humanOnlySpecs) {
      hygiene.push({
        kind: 'human-only-spec',
        number: spec.number,
        title: spec.title,
        tickets: spec.tickets.filter((ticket) => (
          ticket.state === 'open' && ticket.human
        )).sort((a, b) => a.number - b.number),
      });
    }
    for (const spec of stage.closedSpecs || []) {
      const tickets = readEndpoint(endpointDir, 'sub', spec.number)
        .filter((ticket) => isOpen(ticket))
        .map((ticket) => ({
          number: Number(ticket.number),
          state: ticket.state,
          title: ticket.title || '',
        }))
        .sort((a, b) => a.number - b.number);
      if (tickets.length > 0) {
        hygiene.push({
          kind: 'closed-spec',
          number: spec.number,
          title: spec.title,
          tickets,
        });
      }
    }

    const openReferences = new Set(stage.specs.flatMap((spec) => spec.refs));
    const closedReferences = new Map();
    // The same two sets over line-anchored references, for loose source
    // tickets: a line that merely mentions the label names no source.
    const openLineReferences = new Set(stage.specs.flatMap((spec) => spec.lineRefs));
    const closedLineReferences = new Map();
    const rememberReference = (table, number, specNumber) => {
      if (!table.has(number)) table.set(number, []);
      table.get(number).push(specNumber);
    };
    for (const spec of stage.allProblemSpecs) {
      if (isOpen(spec)) continue;
      for (const ref of spec.refs) rememberReference(closedReferences, Number(ref), spec.number);
      for (const ref of spec.lineRefs) rememberReference(closedLineReferences, Number(ref), spec.number);
    }
    for (const impl of implementations.values()) {
      // A loose source ticket is reported as landedSourceTickets below.
      if (impl.mapNumber === null) continue;
      const specNumbers = uniqueNumbers(closedReferences.get(Number(impl.number)) || []);
      if (
        impl.childTotal === 0 &&
        specNumbers.length > 0 &&
        !openReferences.has(Number(impl.number))
      ) {
        hygiene.push({
          kind: 'implementation',
          number: impl.number,
          title: impl.title,
          specNumbers,
        });
      }
    }
    // A loose source ticket (#83) stays open until its Spec lands; once every
    // Spec naming it on a 实现票 line is closed, the only thing left is to
    // close it with a comment, which find-next does from this list. Only a
    // line-anchored reference counts, and another issue's child is never a
    // source ticket, however a 实现票 line spells it.
    for (const impl of implementations.values()) {
      if (impl.mapNumber !== null) continue;
      if (knownChildren.has(Number(impl.number))) continue;
      const specNumbers = uniqueNumbers(closedLineReferences.get(Number(impl.number)) || []);
      if (specNumbers.length > 0 && !openLineReferences.has(Number(impl.number))) {
        landedSourceTickets.push({number: impl.number, title: impl.title, specNumbers});
      }
    }
  }

  const loose = [];
  if (all) {
    // A ticket named on a 实现票 line has a Spec (open or landed); it is not
    // loose work to triage, whichever state that Spec is in.
    const coveredLineRefs = new Set((stage.coveredLineRefs || []).map(Number));
    for (const issue of issues) {
      if (
        isOpen(issue) &&
        !isMap(issue) &&
        !mapChildren.has(Number(issue.number)) &&
        !hasProblemStatement(issue) &&
        !knownChildren.has(Number(issue.number)) &&
        !coveredLineRefs.has(Number(issue.number))
      ) {
        loose.push({
          number: Number(issue.number),
          title: issue.title || '',
          labels: issueLabels(issue),
          fromMap: looseFromMap(issue),
          timing: looseTiming(issue),
        });
      }
    }
    loose.sort((a, b) => a.number - b.number);
  }

  const staleClaims = [];
  const orphanClaims = [];
  let orphanClaimsUnchecked = false;
  if (all) {
    const now = Date.parse(process.env.PIPELINE_STATUS_NOW || '');
    const nowMs = Number.isFinite(now)
      ? now
      : Date.now();
    const cutoff = nowMs - STALE_CLAIM_MS;
    const seenStale = new Set();
    const freshClaims = [];
    for (const map of stage.maps) {
      for (const decision of readEndpoint(endpointDir, 'map', map.number)) {
        if (!isOpen(decision) || !hasWayfinderLabel(decision)) continue;
        const assignees = Array.isArray(decision.assignees) ? decision.assignees : [];
        if (assignees.length === 0) continue;
        const updated = Date.parse(decision.updated_at || '');
        const number = Number(decision.number);
        if (seenStale.has(number)) continue;
        seenStale.add(number);
        if (Number.isFinite(updated) && updated >= cutoff) {
          freshClaims.push({decision, assignees, mapNumber: Number(map.number)});
          continue;
        }
        if (!Number.isFinite(updated)) continue;
        staleClaims.push({
          number,
          title: decision.title || '',
          label: issueLabels(decision).find((label) => label.startsWith('wayfinder:')) || '',
          assignees: assignees.map((assignee) => (
            typeof assignee === 'string' ? assignee : assignee.login
          )).filter(Boolean),
          updatedAt: decision.updated_at || '',
          mapNumber: Number(map.number),
        });
      }
    }
    staleClaims.sort((a, b) => a.number - b.number);

    // wayfinder claims only set the Assignee, so liveness comes from Orca: a
    // fresh claim is orphaned when no live agent terminal in this repository's
    // worktrees names the ticket in its title or screen preview.
    const terminals = freshClaims.length > 0 ? liveAgentTerminals() : [];
    if (terminals === null) {
      orphanClaimsUnchecked = true;
    } else {
      const worktrees = repoWorktreePaths();
      const local = terminals.filter((terminal) => worktrees.has(String(terminal.worktreePath || '')));
      for (const {decision, assignees, mapNumber} of freshClaims) {
        const number = Number(decision.number);
        const mention = new RegExp(`#${number}(?![0-9])`);
        const watched = local.some((terminal) => (
          mention.test(`${terminal.title || ''}\n${terminal.preview || ''}`)
        ));
        if (watched) continue;
        orphanClaims.push({
          number,
          title: decision.title || '',
          label: issueLabels(decision).find((label) => label.startsWith('wayfinder:')) || '',
          assignees: assignees.map((assignee) => (
            typeof assignee === 'string' ? assignee : assignee.login
          )).filter(Boolean),
          updatedAt: decision.updated_at || '',
          mapNumber,
        });
      }
      orphanClaims.sort((a, b) => a.number - b.number);
    }
  }

  function liveAgentTerminals() {
    let text;
    try {
      const fixture = process.env.PIPELINE_STATUS_ORCA_TERMINALS_JSON;
      // Orca is not spawned here: the library runs it and names it.
      text = fixture
        ? fs.readFileSync(fixture, 'utf8')
        : cp.execFileSync('bash', ['-c', 'source "$1" && orca_terminal_list', '_', process.env.ISS_LIB_ORCA], {
          encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000,
        });
      const value = JSON.parse(text);
      const list = value && value.result && Array.isArray(value.result.terminals)
        ? value.result.terminals : null;
      if (!list || value.ok === false) return null;
      return list.filter((terminal) => (
        terminal && terminal.connected && !terminal.orphaned && terminal.agentIdentity
      ));
    } catch (_) {
      return null;
    }
  }

  function repoWorktreePaths() {
    const paths = new Set();
    try {
      const output = cp.execFileSync('git', ['worktree', 'list', '--porcelain'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      });
      for (const line of output.split('\n')) {
        if (!line.startsWith('worktree ')) continue;
        const worktree = line.slice('worktree '.length);
        paths.add(worktree);
        try { paths.add(fs.realpathSync(worktree)); } catch (_) { /* keep the listed path */ }
      }
    } catch (_) {
      // Outside a git repository nothing counts as local.
    }
    return paths;
  }

  const blockerRequests = uniqueNumbers(implement.flatMap((spec) => (
    spec.tickets.filter((ticket) => ticket.state === 'open' && !ticket.shelved)
      .map((ticket) => ticket.number)
  )));
  const output = {
    implement,
    humanOnlySpecs,
    needsTickets,
    missing,
    mapSpecs,
    fogMaps,
    emptyMaps,
    exploring,
    staleClaims,
    orphanClaims,
    orphanClaimsUnchecked,
    blockerRequests,
    hygiene: all ? hygiene : [],
    landedSourceTickets: all ? landedSourceTickets : [],
    loose: all ? loose : [],
  };
  process.stdout.write(JSON.stringify(output, null, 2));
  process.exit(0);
}

if (mode === 'render') {
  const issues = readJson(args[0]);
  const pipeline = readJson(args[1]);
  const blockerDir = args[2];
  const all = args[3] === '1';
  const byNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));

  function clean(value) {
    return String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
  }

  function lastCommit(branch) {
    if (!branch) return '';
    try {
      return cp.execFileSync('git', ['log', '-1', '--format=%cr', branch], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }).trim();
    } catch (_) {
      return 'unknown';
    }
  }

  function blockersFor(spec) {
    const ticketNumbers = new Set(spec.tickets.map((ticket) => ticket.number));
    const openTickets = spec.tickets.filter((ticket) => (
      ticket.state === 'open' && !ticket.shelved && !ticket.human
    ));
    if (openTickets.length === 0) return [];
    const eachTicketHasExternal = openTickets.every((ticket) => {
      let file;
      try {
        file = readJson(path.join(blockerDir, `blocker-${ticket.number}.json`));
      } catch (_) {
        file = [];
      }
      return (Array.isArray(file) ? file : []).some((blocker) => (
        blocker.state === 'open' && !ticketNumbers.has(Number(blocker.number))
      ));
    });
    if (!eachTicketHasExternal) return [];

    const blockers = new Set();
    for (const ticket of openTickets) {
      let file;
      try {
        file = readJson(path.join(blockerDir, `blocker-${ticket.number}.json`));
      } catch (_) {
        file = [];
      }
      for (const blocker of Array.isArray(file) ? file : []) {
        if (blocker.state === 'open' && !ticketNumbers.has(Number(blocker.number))) {
          blockers.add(Number(blocker.number));
        }
      }
    }
    return [...blockers].sort((a, b) => a - b);
  }

  const lines = [];
  lines.push('可以实现');
  const implementableSpecs = pipeline.implement.filter((spec) => !spec.human_only);
  if (implementableSpecs.length === 0) {
    lines.push('（无）');
  } else {
    for (const spec of implementableSpecs) {
      const branch = integrationBranch(spec.number);
      let state;
      if (!insideGit()) {
        state = '未知（不在 git 仓库）';
      } else if (branch) {
        state = `已接手（分支 ${branch}，最后提交 ${lastCommit(branch)}）`;
      } else {
        state = '空闲';
      }
      const blockers = blockersFor(spec);
      if (blockers.length > 0) state += `；被卡住：${blockers.map((n) => `#${n}`).join(' ')}`;
      const tickets = spec.tickets.map((ticket) => (
        `#${ticket.number}${ticket.shelved ? '(搁置)' : ticket.human ? '(人工)' : ''}`
      )).join(' ');
      lines.push(`- #${spec.number} ${spec.closed}/${spec.tickets.length} ${state} ${clean(spec.title)} [票：${tickets}] → /implement-spec-split ${spec.number}`);
    }
  }

  lines.push('');
  lines.push('有规格、未拆票');
  if (pipeline.needsTickets.length === 0) {
    lines.push('（无）');
  } else {
    for (const spec of pipeline.needsTickets) {
      lines.push(`- #${spec.number} ${clean(spec.title)} → to-tickets`);
    }
  }

  lines.push('');
  lines.push('缺规格');
  if (pipeline.missing.length === 0) {
    lines.push('（无）');
  } else {
    for (const map of pipeline.missing) {
      lines.push(`地图 #${map.number} ${clean(map.title)}`);
      for (const ticket of map.tickets) {
        lines.push(`  - #${ticket.number} ${clean(ticket.title)} → to-spec`);
      }
    }
  }

  lines.push('');
  lines.push('地图仍在探索');
  if (pipeline.exploring.length === 0) {
    lines.push('（无）');
  } else {
    for (const map of pipeline.exploring) {
      lines.push(`- #${map.number} ${clean(map.title)}（开着决策票 ${map.openDecisionCount} 张） → wayfinder`);
      if (all) {
        for (const decision of map.decisions || []) {
          let state = '';
          if (decision.blockedBy > 0) state += '（有未关阻塞）';
          if (Array.isArray(decision.assignees) && decision.assignees.length > 0) {
            state += `（已认领：${decision.assignees.join('、')}）`;
          }
          lines.push(`  - #${decision.number} [${decision.label}] ${clean(decision.title)}${state}`);
        }
      }
    }
  }

  lines.push('');
  lines.push('地图缺规格');
  if (pipeline.mapSpecs.length === 0) {
    lines.push('（无）');
  } else {
    for (const map of pipeline.mapSpecs) {
      lines.push(`- #${map.number} ${clean(map.title)} → to-spec`);
    }
  }

  lines.push('');
  lines.push('地图迷雾待毕业');
  if ((pipeline.fogMaps || []).length === 0) {
    lines.push('（无）');
  } else {
    for (const map of pipeline.fogMaps) {
      lines.push(`- #${map.number} ${clean(map.title)} → /find-next --batch ${map.number}`);
    }
  }

  if (all) {
    lines.push('');
    lines.push('空地图（待 /wayfinder 画图）');
    if ((pipeline.emptyMaps || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const map of pipeline.emptyMaps) {
        lines.push(`- #${map.number} ${clean(map.title)} → /wayfinder ${map.number}`);
      }
    }

    lines.push('');
    lines.push('认领后不动（>3 天）');
    if ((pipeline.staleClaims || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const claim of pipeline.staleClaims) {
        const assignees = (claim.assignees || []).join('、');
        lines.push(
          `- #${claim.number} [${claim.label}] ${clean(claim.title)}（地图 #${claim.mapNumber}，已认领：${assignees}，更新于 ${claim.updatedAt}） → 询问是否取消认领并纳入推进`
        );
      }
    }

    lines.push('');
    lines.push('认领但没有活会话');
    if (pipeline.orphanClaimsUnchecked) {
      lines.push('（Orca 不可用，未判断）');
    } else if ((pipeline.orphanClaims || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const claim of pipeline.orphanClaims) {
        const assignees = (claim.assignees || []).join('、');
        lines.push(
          `- #${claim.number} [${claim.label}] ${clean(claim.title)}（地图 #${claim.mapNumber}，已认领：${assignees}，更新于 ${claim.updatedAt}，Orca 里没有提到它的活会话） → 询问是否取消认领并纳入推进`
        );
      }
    }

    lines.push('');
    lines.push('状态没收尾');
    if ((pipeline.hygiene || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const item of pipeline.hygiene) {
        if (item.kind === 'closed-spec') {
          const tickets = item.tickets.map((ticket) => `#${ticket.number}`).join(' ');
          lines.push(`- 规格 #${item.number} ${clean(item.title)} 已关闭，执行票还开着：${tickets} → 核对后关票`);
        } else if (item.kind === 'shelved-only-spec') {
          const tickets = item.tickets.map((ticket) => `#${ticket.number}`).join(' ');
          lines.push(`- 规格 #${item.number} ${clean(item.title)}：未关执行票只剩搁置票 ${tickets}，可关闭规格（核对后由用户确认）`);
        } else if (item.kind === 'human-only-spec') {
          const tickets = item.tickets.map((ticket) => `#${ticket.number}`).join(' ');
          lines.push(`- 规格 #${item.number} ${clean(item.title)}：人工票待做：${tickets} → 由人工完成，agent 不派发`);
        } else if (item.kind === 'implementation') {
          const specs = item.specNumbers.map((number) => `#${number}`).join('、');
          lines.push(`- 实现票 #${item.number} ${clean(item.title)} 的规格 ${specs} 已关闭，票还开着 → 核对后关票`);
        }
      }
    }

    lines.push('');
    lines.push('规格已落地、源票未关');
    if ((pipeline.landedSourceTickets || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const item of pipeline.landedSourceTickets) {
        const specs = item.specNumbers.map((number) => `#${number}`).join('、');
        lines.push(`- 散票 #${item.number} ${clean(item.title)} 的规格 ${specs} 已关闭，源票还开着 → 关票并留言`);
      }
    }

    lines.push('');
    lines.push('散票');
    if ((pipeline.loose || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const issue of pipeline.loose) {
        const labels = issue.labels.length > 0 ? ` [${issue.labels.join(',')}]` : '';
        const notes = [];
        if (issue.fromMap !== null && issue.fromMap !== undefined) {
          notes.push(`来自地图 #${issue.fromMap}`);
        }
        if (issue.timing) notes.push(`时机：${clean(issue.timing)}`);
        const note = notes.length > 0 ? `（${notes.join('；')}）` : '';
        lines.push(`- #${issue.number}${labels} ${clean(issue.title)}${note}`);
      }
    }
  }

  process.stdout.write(lines.join('\n') + '\n');
  process.exit(0);
}

if (mode === 'order') {
  const issues = readJson(args[0]);
  const pipeline = readJson(args[1]);
  const blockerDir = args[2];
  const parallel = Math.max(1, Number(args[3] || 2));
  // The shell always passes the command suffix (CMD_SUFFIX, --auto-land unless
  // --cmd-suffix says otherwise): no second default here.
  const commandSuffix = args[4];
  const suppliedClaimsDir = args[5] || '';
  const lstartCommand = args[6] || process.env.ISS_PID_START_SCRIPT;
  const workersArgument = args[7] || '';
  const jsonOutput = args[8] === '1';
  const workers = workersArgument === '' ? null : Number(workersArgument);
  const perSpecParallel = workers === null
    ? null
    : Math.max(1, Math.floor(workers / parallel));
  const nowEpochArgument = process.env.ISS_NOW_EPOCH;
  const nowEpoch = nowEpochArgument === undefined
    ? Math.floor(Date.now() / 1000)
    : Number(nowEpochArgument);
  const apartPairs = args.slice(9).map((value) => {
    const match = String(value).match(/^([0-9]+):([0-9]+)$/);
    if (!match) throw new Error(`invalid --apart value: ${value}`);
    return [Number(match[1]), Number(match[2])];
  });

  function clean(value) {
    return String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
  }

  function exactIntegrationBranchExists(number) {
    if (!insideGit()) return false;
    try {
      const exact = `spec-${number}`;
      const output = cp.execFileSync('git', [
        'branch', '--list', exact, '--format=%(refname:short)',
      ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
        .split(/\r?\n/).map((value) => value.trim()).filter(Boolean);
      return output.includes(exact);
    } catch (_) {
      return false;
    }
  }

  function commonGitDir() {
    try {
      const value = cp.execFileSync('git', ['rev-parse', '--git-common-dir'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }).trim();
      return path.resolve(process.cwd(), value);
    } catch (_) {
      return '';
    }
  }

  const claimsDir = suppliedClaimsDir || (() => {
    const commonDir = commonGitDir();
    return commonDir ? path.join(commonDir, 'implement-spec-split', 'claims') : '';
  })();

  function processStart(pid) {
    try {
      // Bare 'sh': Windows node cannot resolve '/bin/sh' (ENOENT), Git Bash puts sh on PATH.
      const output = cp.execFileSync('sh', [
        '-c', '"$1" "$2"', 'pipeline-status-lstart', String(lstartCommand), String(pid),
      ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
      return String(output || '').trim();
    } catch (_) {
      return '';
    }
  }

  const claimCache = new Map();
  function claimFor(specNumber) {
    if (claimCache.has(specNumber)) return claimCache.get(specNumber);
    let claim = null;
    if (claimsDir) {
      try {
        claim = readJson(path.join(claimsDir, `spec-${specNumber}.json`));
      } catch (_) {
        claim = null;
      }
    }
    claimCache.set(specNumber, claim);
    return claim;
  }

  function handoffAlive(claim) {
    if (!claim || (claim.handoff !== 'fresh' && claim.handoff !== 'resume')) return false;
    const until = Number(claim.handoff_until_epoch);
    return Number.isFinite(nowEpoch) && Number.isFinite(until) && nowEpoch < until;
  }

  function holderAlive(specNumber) {
    const claim = claimFor(specNumber);
    if (!claim) return false;
    if (handoffAlive(claim)) return true;
    const pid = Number(claim.pid);
    if (!Number.isFinite(pid) || pid <= 0) return false;
    const expected = String(claim.pid_start || '').trim();
    return expected !== '' && processStart(pid) === expected;
  }

  function checkoutWorktree(specNumber) {
    if (!insideGit()) return null;
    try {
      const output = cp.execFileSync('git', ['worktree', 'list', '--porcelain'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      const wanted = `refs/heads/spec-${specNumber}`;
      let worktreePath = null;
      for (const line of output.split(/\r?\n/)) {
        if (line.startsWith('worktree ')) {
          worktreePath = line.slice('worktree '.length);
        } else if (line === `branch ${wanted}` && worktreePath) {
          return worktreePath;
        } else if (line === '') {
          worktreePath = null;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  function resumeWorktree(specNumber) {
    const claim = claimFor(specNumber);
    const recorded = claim ? String(claim.worktree || '') : '';
    if (recorded !== '') {
      try {
        const resolved = path.resolve(recorded);
        if (fs.statSync(resolved).isDirectory()) return resolved;
      } catch (_) {
        // Fall through to git's worktree metadata below.
      }
    }
    return checkoutWorktree(specNumber);
  }

  function blockersForTicket(number) {
    try {
      const value = readJson(path.join(blockerDir, `blocker-${number}.json`));
      return Array.isArray(value) ? value : [];
    } catch (_) {
      return [];
    }
  }

  const issueByNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));
  const ticketOwner = new Map();
  function rememberTicketOwner(number, owner) {
    const key = Number(number);
    if (Number.isFinite(key) && !ticketOwner.has(key)) ticketOwner.set(key, owner);
  }

  for (const spec of pipeline.implement) {
    for (const ticket of spec.tickets) {
      rememberTicketOwner(ticket.number, {
        number: Number(spec.number),
        kind: 'implement',
      });
    }
  }

  for (const spec of pipeline.implement) {
    rememberTicketOwner(spec.number, {
      number: Number(spec.number),
      kind: 'implement',
    });
  }

  for (const spec of pipeline.needsTickets) {
    rememberTicketOwner(spec.number, {
      number: Number(spec.number),
      kind: 'needsTickets',
    });
  }
  for (const spec of pipeline.implement) {
    const issue = issueByNumber.get(Number(spec.number));
    for (const ref of bodyReferences(issue || {})) {
      rememberTicketOwner(ref, {
        number: Number(spec.number),
        kind: 'implement',
      });
    }
  }
  for (const spec of pipeline.needsTickets) {
    const issue = issueByNumber.get(Number(spec.number));
    for (const ref of bodyReferences(issue || {})) {
      rememberTicketOwner(ref, {
        number: Number(spec.number),
        kind: 'needsTickets',
      });
    }
  }

  const states = new Map();
  const branches = new Map();
  const records = new Map();
  // Human-only Specs stay in pipeline.implement so the graph still carries
  // their tickets, but they never enter the order or a wave.
  const orderedSpecs = pipeline.implement.filter((spec) => !spec.human_only);
  for (const spec of orderedSpecs) {
    const number = Number(spec.number);
    const branch = integrationBranch(number);
    const claim = claimFor(number);
    const exactBranchExists = exactIntegrationBranchExists(number);
    const liveHandoff = handoffAlive(claim);
    const reservedWithoutBranch = liveHandoff && !exactBranchExists;
    const expiredReservation = Boolean(claim && claim.handoff && !liveHandoff);
    let state;
    if (holderAlive(number)) {
      state = 'running';
    } else if (branch && !(expiredReservation && !exactBranchExists)) {
      state = 'interrupted';
    } else {
      state = 'idle';
    }
    const displayBranch = reservedWithoutBranch
      ? `spec-${number}`
      : branch;
    branches.set(number, displayBranch);
    states.set(number, state);
    records.set(number, {
      number,
      title: spec.title,
      branch: displayBranch,
      actualBranch: branch,
      state,
      claim,
      worktree: branch ? String((claim || {}).worktree || '') : '',
      dependencies: new Set(),
      extraBlockers: new Set(),
      complete: false,
      partial: false,
    });
  }

  const edges = new Map();
  for (const spec of orderedSpecs) {
    const target = Number(spec.number);
    const targetTickets = new Set(spec.tickets.map((ticket) => Number(ticket.number)));
    const openTickets = spec.tickets.filter((ticket) => (
      ticket.state === 'open' && !ticket.human
    ));
    const blockersByTicket = new Map();
    const frontier = [];
    for (const ticket of openTickets) {
      const openBlockers = blockersForTicket(ticket.number).filter((blocker) => (
        blocker.state === 'open'
      ));
      const internal = openBlockers.filter((blocker) => (
        targetTickets.has(Number(blocker.number))
      ));
      const external = openBlockers.filter((blocker) => (
        !targetTickets.has(Number(blocker.number))
      ));
      blockersByTicket.set(Number(ticket.number), external);
      if (internal.length === 0) frontier.push(ticket);
    }

    const record = records.get(target);
    record.complete = frontier.length === 0 ||
      frontier.every((ticket) => blockersByTicket.get(Number(ticket.number)).length > 0);

    for (const ticket of openTickets) {
      for (const blocker of blockersByTicket.get(Number(ticket.number))) {
        const blockerNumber = Number(blocker.number);
        const owner = ticketOwner.get(blockerNumber);
        if (owner && owner.number !== target) {
          record.dependencies.add(owner.number);
          if (!edges.has(owner.number)) edges.set(owner.number, new Set());
          edges.get(owner.number).add(target);
        } else if (!owner) {
          record.extraBlockers.add(blockerNumber);
        }
      }
    }
    record.partial = !record.complete &&
      (record.dependencies.size > 0 || record.extraBlockers.size > 0);
  }

  const implementNumbers = orderedSpecs.map((spec) => Number(spec.number));
  const idleNumbers = implementNumbers.filter((number) => states.get(number) === 'idle');
  const idleSet = new Set(idleNumbers);
  const idleEdges = new Map(idleNumbers.map((number) => [number, new Set()]));
  for (const [source, targets] of edges) {
    if (!idleSet.has(source)) continue;
    for (const target of targets) {
      if (idleSet.has(target)) idleEdges.get(source).add(target);
    }
  }

  function canReach(start, target) {
    const seen = new Set();
    const stack = [...(idleEdges.get(start) || [])];
    while (stack.length > 0) {
      const current = stack.pop();
      if (current === target) return true;
      if (seen.has(current)) continue;
      seen.add(current);
      for (const next of idleEdges.get(current) || []) stack.push(next);
    }
    return false;
  }
  const cyclic = new Set(idleNumbers.filter((number) => canReach(number, number)));
  const orderedNumbers = [];
  const remaining = new Set(idleNumbers.filter((number) => !cyclic.has(number)));
  const acyclicEdges = new Map();
  for (const [source, targets] of idleEdges) {
    if (!remaining.has(source)) continue;
    acyclicEdges.set(source, new Set([...targets].filter((target) => remaining.has(target))));
  }

  const reachableCounts = new Map();
  function reachableFrom(start) {
    if (reachableCounts.has(start)) return reachableCounts.get(start);
    const seen = new Set();
    const stack = [...(acyclicEdges.get(start) || [])];
    while (stack.length > 0) {
      const current = stack.pop();
      if (seen.has(current)) continue;
      seen.add(current);
      for (const next of acyclicEdges.get(current) || []) stack.push(next);
    }
    const value = seen.size;
    reachableCounts.set(start, value);
    return value;
  }

  const indegree = new Map([...remaining].map((number) => [number, 0]));
  for (const targets of acyclicEdges.values()) {
    for (const target of targets) indegree.set(target, indegree.get(target) + 1);
  }
  const available = [...remaining].filter((number) => indegree.get(number) === 0);
  while (available.length > 0) {
    available.sort((a, b) => (
      reachableFrom(b) - reachableFrom(a) || a - b
    ));
    const current = available.shift();
    orderedNumbers.push(current);
    for (const target of acyclicEdges.get(current) || []) {
      const value = indegree.get(target) - 1;
      indegree.set(target, value);
      if (value === 0) available.push(target);
    }
  }

  const interrupted = implementNumbers
    .filter((number) => states.get(number) === 'interrupted')
    .sort((a, b) => a - b);
  const running = implementNumbers
    .filter((number) => states.get(number) === 'running')
    .sort((a, b) => a - b);
  const capacity = Math.max(0, parallel - running.length - interrupted.length);
  // A running Spec and one resumed first both run beside the new wave, so an
  // --apart pair naming either holds its other side out of that wave too.
  const inFlight = new Set([...running, ...interrupted]);
  // The other side of every --apart pair naming number that is in set, ascending.
  function apartPartnersIn(number, set) {
    const held = [];
    for (const [left, right] of apartPairs) {
      if (left === number && set.has(right)) held.push(right);
      if (right === number && set.has(left)) held.push(left);
    }
    return [...new Set(held)].sort((a, b) => a - b);
  }
  function inFlightApartFrom(number) {
    return apartPartnersIn(number, inFlight);
  }
  const wave = [];
  const waveSet = new Set();
  for (const number of orderedNumbers) {
    if (wave.length >= capacity) break;
    const record = records.get(number);
    if (record.complete) continue;
    const conflicts = apartPartnersIn(number, inFlight).length > 0 ||
      apartPartnersIn(number, waveSet).length > 0;
    if (conflicts) continue;
    wave.push(number);
    waveSet.add(number);
  }
  const later = orderedNumbers.filter((number) => !waveSet.has(number));

  function formatCommand(number) {
    const suffix = commandSuffix === '' ? '' : ` ${commandSuffix}`;
    const workerSuffix = perSpecParallel === null ? '' : ` --parallel ${perSpecParallel}`;
    return `/implement-spec-split ${number}${suffix}${workerSuffix}`;
  }

  function annotation(number, firstWave) {
    const record = records.get(number);
    const dependencies = [...record.dependencies].sort((a, b) => a - b)
      .map((value) => `#${value}`);
    const extras = [...record.extraBlockers].sort((a, b) => a - b)
      .map((value) => `#${value}`);
    const heldFrom = inFlightApartFrom(number).map((value) => `#${value}`);
    const parts = [];
    if (dependencies.length > 0) {
      const prefix = firstWave && record.partial ? '部分等' : '等';
      parts.push(`${prefix} ${dependencies.join(' ')}`);
    }
    if (extras.length > 0) parts.push(`另需 ${extras.join(' ')}`);
    if (heldFrom.length > 0) parts.push(`避开 ${heldFrom.join(' ')}`);
    return parts.length > 0 ? `（${parts.join('；')}）` : '';
  }

  const plan = {
    parallel_specs: parallel,
    workers,
    per_spec_parallel: perSpecParallel,
    resume: interrupted.map((number) => {
      const record = records.get(number);
      return {
        spec: number,
        title: clean(record.title),
        branch: record.branch,
        worktree: resumeWorktree(number),
        command: formatCommand(number),
      };
    }),
    active: running.map((number) => {
      const record = records.get(number);
      return {
        spec: number,
        title: clean(record.title),
        branch: record.branch,
      };
    }),
    wave1: wave.map((number) => {
      const record = records.get(number);
      const note = annotation(number, true).replace(/^（|）$/g, '');
      return {
        spec: number,
        title: clean(record.title),
        command: formatCommand(number),
        note,
      };
    }),
    later: later.map((number, offset) => {
      const record = records.get(number);
      const note = annotation(number, false).replace(/^（|）$/g, '');
      return {
        index: wave.length + offset + 1,
        spec: number,
        title: clean(record.title),
        note,
      };
    }),
    cycles: [...cyclic].sort((a, b) => a - b),
    standalone: [...new Set(
      implementNumbers.flatMap((number) => [...records.get(number).extraBlockers])
    )].sort((a, b) => a - b),
  };

  if (process.env.ISS_GRAPH === '1') {
    // Full relation graph for the Progress board (--graph). Structure:
    // {repo, counts:{maps,specs,tickets}, maps:[...], specs:[...],
    //  loose_specs:[numbers], next_wave:<same object as --order --json>}
    const stage = readJson(process.env.ISS_STAGE_FILE);
    const endpointDir = process.env.ISS_ENDPOINT_DIR;
    const uniq = (values) => [...new Set(values.map(Number))].sort((a, b) => a - b);
    const ticketOf = (child) => ({
      number: Number(child.number),
      title: clean(child.title),
      state: child.state,
      shelved: isShelved(child),
      human: child.human === true || hasLabel(child, 'ready-for-human'),
      ready_for_agent: child.readyForAgent === true || hasLabel(child, 'ready-for-agent'),
      on_hold: child.onHold === true || hasHoldLabel(child),
      shared_counter: child.sharedCounter === true || hasLabel(child, 'shared-counter'),
      source: child.source === true,
    });
    const specIssue = (number) => {
      const issue = issueByNumber.get(Number(number));
      return issue && !issue.pull_request && hasProblemStatement(issue) ? issue : null;
    };
    const mapNumbers = new Set(stage.maps.map((map) => Number(map.number)));
    const shelvedOnly = new Set((pipeline.hygiene || [])
      .filter((item) => item.kind === 'shelved-only-spec').map((item) => Number(item.number)));
    const humanOnly = new Set((pipeline.humanOnlySpecs || [])
      .map((spec) => Number(spec.number)));
    const needsTickets = new Set(pipeline.needsTickets.map((spec) => Number(spec.number)));
    const implementByNumber = new Map(pipeline.implement.map((spec) => [Number(spec.number), spec]));

    function graphClaim(number, record = null) {
      const claim = record?.claim || claimFor(number);
      if (!claim && !record) return null;
      let state = record ? record.state : 'idle';
      if (handoffAlive(claim) && !exactIntegrationBranchExists(number)) state = 'reserved';
      else if (state === 'running') state = 'active';
      return {
        state,
        branch: record?.branch || String(claim?.branch || ''),
        worktree: record?.worktree || String(claim?.worktree || ''),
        claimed_at: claim?.claimed_at || null,
      };
    }

    // Ticket sets and map membership for every Spec, closed ones included.
    const specRecords = new Map();
    function closedTickets(spec) {
      if (spec.ownChildren) {
        return readEndpoint(endpointDir, 'sub', spec.number).map(ticketOf);
      }
      const found = [];
      for (const ref of spec.refs) {
        const children = readEndpoint(endpointDir, 'sub', ref);
        if (children.length > 0) found.push(...children.map(ticketOf));
        else if (issueByNumber.has(Number(ref))) found.push(ticketOf(issueByNumber.get(Number(ref))));
      }
      return found;
    }
    for (const spec of stage.allProblemSpecs) {
      const number = Number(spec.number);
      const open = spec.state === 'open';
      let tickets;
      if (open && implementByNumber.has(number)) {
        tickets = implementByNumber.get(number).tickets.map(ticketOf);
      } else if (open) {
        tickets = [];
      } else {
        tickets = closedTickets(spec);
      }
      const seen = new Set();
      tickets = tickets.filter((ticket) => !seen.has(ticket.number) && seen.add(ticket.number))
        .sort((a, b) => a.number - b.number);
      if (open && shelvedOnly.has(number)) {
        const shelvedSpec = (pipeline.hygiene || []).find((item) => (
          item.kind === 'shelved-only-spec' && Number(item.number) === number));
        const full = readEndpoint(endpointDir, 'sub', number);
        tickets = full.length > 0 ? full.map(ticketOf) : (shelvedSpec ? shelvedSpec.tickets.map(ticketOf) : []);
      }
      let status;
      let claim = null;
      if (!open) status = 'landed';
      else if (needsTickets.has(number)) status = 'needs_tickets';
      else if (shelvedOnly.has(number)) status = 'shelved';
      else if (humanOnly.has(number)) status = 'human';
      else if (records.has(number)) {
        const record = records.get(number);
        claim = graphClaim(number, record);
        status = record.state === 'idle' ? 'ready' : record.state;
      } else status = 'ready';
      const record = records.get(number);
      specRecords.set(number, {
        number,
        title: clean(spec.title),
        kind: 'spec',
        state: open ? 'open' : 'closed',
        status,
        human_only: humanOnly.has(number),
        map: null,
        has_tickets: tickets.length > 0,
        tickets,
        tickets_total: tickets.length,
        tickets_closed: tickets.filter((ticket) => ticket.state === 'closed').length,
        claim,
        depends_on: record ? [...record.dependencies].sort((a, b) => a - b) : [],
        extra_blockers: record ? [...record.extraBlockers].sort((a, b) => a - b) : [],
        map_refs: spec.mapRefs,
      });
    }
    for (const spec of pipeline.implement.filter((item) => item.kind === 'legacy')) {
      const number = Number(spec.number);
      const record = records.get(number);
      const tickets = spec.tickets.map(ticketOf);
      specRecords.set(number, {
        number, title: clean(spec.title), kind: 'legacy', state: 'open',
        status: !record ? 'human' : (record.state === 'idle' ? 'ready' : record.state),
        human_only: humanOnly.has(number),
        map: null, has_tickets: tickets.length > 0, tickets,
        tickets_total: tickets.length,
        tickets_closed: tickets.filter((ticket) => ticket.state === 'closed').length,
        claim: record ? graphClaim(number, record) : null,
        depends_on: record ? [...record.dependencies].sort((a, b) => a - b) : [],
        extra_blockers: record ? [...record.extraBlockers].sort((a, b) => a - b) : [],
        map_refs: [],
      });
    }

    const mapTicketNumbers = new Set();
    const mapRecords = stage.maps.map((map) => {
      const children = readEndpoint(endpointDir, 'map', map.number);
      const decisions = children.filter(hasWayfinderLabel);
      const childSpecs = children.filter((child) => specRecords.has(Number(child.number)))
        .map((child) => Number(child.number));
      const tickets = children.filter((child) => (
        !hasWayfinderLabel(child) && !specRecords.has(Number(child.number)) &&
        Number(summary(child).total || 0) === 0
      )).map(ticketOf).sort((a, b) => a.number - b.number);
      for (const ticket of tickets) mapTicketNumbers.add(ticket.number);
      const refSpecs = [...specRecords.values()]
        .filter((spec) => spec.map_refs.includes(Number(map.number))).map((spec) => spec.number);
      const specNumbers = uniq([...childSpecs, ...refSpecs]);
      const unconverted = pipeline.mapSpecs.some((item) => Number(item.number) === Number(map.number));
      let status;
      if (!map.open) status = 'closed';
      else if (map.shelved) status = 'shelved';
      else if (Number(map.childCount) === 0) status = 'empty';
      else if (map.openDecisionCount > 0) status = 'exploring';
      else if (map.hasFog) status = 'fog_pending';
      else if (unconverted) status = 'unconverted';
      else status = 'converted';
      return {
        number: Number(map.number),
        title: clean(map.title),
        state: map.open ? 'open' : 'closed',
        shelved: map.shelved,
        has_fog: map.hasFog,
        status,
        decisions_total: decisions.length,
        decisions_open: decisions.filter(isOpen).length,
        spec_numbers: specNumbers,
        tickets,
      };
    });
    for (const spec of specRecords.values()) {
      const owner = mapRecords.find((map) => map.spec_numbers.includes(spec.number));
      spec.map = owner ? owner.number : null;
      delete spec.map_refs;
    }
    const specList = [...specRecords.values()].sort((a, b) => a.number - b.number);
    const allTicketNumbers = new Map();
    for (const spec of specList) {
      for (const ticket of spec.tickets) allTicketNumbers.set(ticket.number, ticket.state);
    }
    for (const map of mapRecords) {
      for (const ticket of map.tickets) {
        if (!allTicketNumbers.has(ticket.number)) allTicketNumbers.set(ticket.number, ticket.state);
      }
    }
    const countBy = (items, field, value) => items.filter((item) => item[field] === value).length;
    const graph = {
      repo: process.env.ISS_REPO || '',
      counts: {
        maps: {
          total: mapRecords.length,
          closed: countBy(mapRecords, 'status', 'closed'),
          shelved: countBy(mapRecords, 'status', 'shelved'),
          empty: countBy(mapRecords, 'status', 'empty'),
          exploring: countBy(mapRecords, 'status', 'exploring'),
          fog_pending: countBy(mapRecords, 'status', 'fog_pending'),
          unconverted: countBy(mapRecords, 'status', 'unconverted'),
        },
        specs: {
          total: specList.length,
          landed: countBy(specList, 'status', 'landed'),
          needs_tickets: countBy(specList, 'status', 'needs_tickets'),
          ready: countBy(specList, 'status', 'ready'),
          running: countBy(specList, 'status', 'running'),
          interrupted: countBy(specList, 'status', 'interrupted'),
          shelved: countBy(specList, 'status', 'shelved'),
        },
        tickets: {
          total: allTicketNumbers.size,
          closed: [...allTicketNumbers.values()].filter((state) => state === 'closed').length,
        },
      },
      maps: mapRecords.sort((a, b) => a.number - b.number),
      specs: specList,
      loose_specs: specList.filter((spec) => spec.map === null).map((spec) => spec.number),
      next_wave: plan,
    };
    process.stdout.write(JSON.stringify(graph, null, 2) + '\n');
    process.exit(0);
  }

  if (jsonOutput) {
    process.stdout.write(JSON.stringify(plan, null, 2) + '\n');
    process.exit(0);
  }

  const lines = [];
  if (orderedSpecs.length === 0) {
    lines.push('开发顺序：没有可以实现的规格');
    process.stdout.write(lines.join('\n') + '\n');
    process.exit(0);
  }

  lines.push(workers === null
    ? `开发顺序（同时 ${parallel} 份）`
    : `开发顺序（同时 ${parallel} 份，共 ${workers} 个 worker）`);
  if (interrupted.length > 0) {
    lines.push(`先恢复：${interrupted.map((number) => `#${number}`).join(' ')}`);
  }
  if (running.length > 0) {
    lines.push(`进行中：${running.map((number) => (
      `#${number}（${branches.get(number)}）`
    )).join(' ')}`);
  }
  if (wave.length === 0) {
    const emptyWaveMessage = capacity === 0
      ? (interrupted.length > 0
        ? '无，先恢复上面的规格'
        : '无，等进行中的规格合入')
      : '无，都在等前置规格合入';
    lines.push(`第 1 波：（${emptyWaveMessage}）`);
  } else {
    lines.push('第 1 波：');
    let index = 1;
    for (const number of wave) {
      const record = records.get(number);
      lines.push(` ${index}. #${number} ${clean(record.title)} → ${formatCommand(number)}${annotation(number, true)}`);
      index += 1;
    }
  }
  if (later.length > 0) {
    lines.push('之后：');
    let index = wave.length + 1;
    for (const number of later) {
      const record = records.get(number);
      lines.push(` ${index}. #${number} ${clean(record.title)}${annotation(number, false)}`);
      index += 1;
    }
  }
  if (cyclic.size > 0) {
    const numbers = plan.cycles.map((number) => `#${number}`);
    lines.push(`循环依赖：${numbers.join(' ')}，需要人工决定`);
  }
  process.stdout.write(lines.join('\n') + '\n');
  process.exit(0);
}

process.stderr.write(`pipeline-status: internal error: unknown node mode ${mode}\n`);
process.exit(70);
NODE
}

if ! gh_api --paginate "repos/$REPO/issues?state=all&per_page=100" > "$ISSUES_FILE"; then
  die "gh api failed while listing issues for $REPO"
fi

MAP_REQUESTS=$(pipeline_node map-requests "$ISSUES_FILE") ||
  die "could not determine wayfinder maps"
for number in $MAP_REQUESTS; do
  if ! gh_api --paginate "repos/$REPO/issues/$number/sub_issues" > "$WORK/endpoints/map-$number.json"; then
    die "gh api failed while loading sub-issues for map #$number"
  fi
done

# --graph needs the --all view (shelved-only Specs) and closed Specs' tickets.
PLAN_ALL=$ALL
[ "$GRAPH" -eq 0 ] || PLAN_ALL=1

if ! pipeline_node plan "$ISSUES_FILE" "$WORK/endpoints" "$PLAN_ALL" > "$STAGE_FILE"; then
  die "could not analyze the first issue-graph stage"
fi

SUB_REQUESTS=$(node -e '
  const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(value.subRequests.join("\n"));
' "$STAGE_FILE") || die "could not determine sub-issue requests"
for number in $SUB_REQUESTS; do
  if ! gh_api --paginate "repos/$REPO/issues/$number/sub_issues" > "$WORK/endpoints/sub-$number.json"; then
    die "gh api failed while loading sub-issues for issue #$number"
  fi
done

CLOSED_SPEC_REQUESTS=$(node -e '
  const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(value.closedSpecRequests.join("\n"));
' "$STAGE_FILE") || die "could not determine closed-spec sub-issue requests"
if [ "$ALL" -eq 1 ]; then
  for number in $CLOSED_SPEC_REQUESTS; do
    if ! gh_api --paginate "repos/$REPO/issues/$number/sub_issues" > "$WORK/endpoints/sub-$number.json"; then
      die "gh api failed while loading closed-spec sub-issues for issue #$number"
    fi
  done
fi

if [ "$GRAPH" -eq 1 ]; then
  GRAPH_REQUESTS=$(node -e '
    const fs = require("fs");
    const stage = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const issues = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const byNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));
    const want = new Set();
    for (const spec of stage.allProblemSpecs) {
      if (spec.state === "open") continue;
      if (spec.ownChildren) want.add(Number(spec.number));
      else for (const ref of spec.refs) {
        const issue = byNumber.get(Number(ref));
        if (issue && issue.sub_issues_summary && Number(issue.sub_issues_summary.total) > 0) want.add(Number(ref));
      }
    }
    process.stdout.write([...want].sort((a, b) => a - b).join("\n"));
  ' "$STAGE_FILE" "$ISSUES_FILE") || die "could not determine closed-spec ticket requests"
  for number in $GRAPH_REQUESTS; do
    [ -e "$WORK/endpoints/sub-$number.json" ] && continue
    if ! gh_api --paginate "repos/$REPO/issues/$number/sub_issues" > "$WORK/endpoints/sub-$number.json"; then
      die "gh api failed while loading sub-issues for issue #$number"
    fi
  done
fi

if ! pipeline_node collect "$ISSUES_FILE" "$STAGE_FILE" "$WORK/endpoints" "$PLAN_ALL" > "$PIPELINE_FILE"; then
  die "could not analyze specs and tickets"
fi

BLOCKER_REQUESTS=$(node -e '
  const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(value.blockerRequests.join("\n"));
' "$PIPELINE_FILE") || die "could not determine dependency requests"
for number in $BLOCKER_REQUESTS; do
  if ! gh_api --paginate "repos/$REPO/issues/$number/dependencies/blocked_by" > "$WORK/blockers/blocker-$number.json"; then
    die "gh api failed while loading blockers for issue #$number"
  fi
done

if [ "$ORDER" -eq 1 ]; then
  ORDER_ARGS=(
    "$ISSUES_FILE"
    "$PIPELINE_FILE"
    "$WORK/blockers"
    "$PARALLEL"
    "$CMD_SUFFIX"
    ''
    "${ISS_PS_LSTART_CMD:-$PID_START}"
    "$WORKERS"
    "$JSON"
  )
  if [ "$APART_COUNT" -gt 0 ]; then
    for pair in "${APART[@]}"; do
      ORDER_ARGS+=("$pair")
    done
  fi
  if ! ISS_GRAPH=$GRAPH ISS_STAGE_FILE=$STAGE_FILE ISS_ENDPOINT_DIR=$WORK/endpoints ISS_REPO=$REPO \
    pipeline_node order "${ORDER_ARGS[@]}"; then
    die "could not render development order"
  fi
else
  if ! pipeline_node render "$ISSUES_FILE" "$PIPELINE_FILE" "$WORK/blockers" "$ALL"; then
    die "could not render pipeline status"
  fi
fi
