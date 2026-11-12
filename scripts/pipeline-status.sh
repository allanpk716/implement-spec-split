#!/usr/bin/env bash
# List unfinished work in the wayfinder -> to-spec -> to-tickets -> implement pipeline.

set -u

usage() {
  cat <<'EOF'
Usage: pipeline-status.sh [--repo <owner/name>] [--all] [--order] [-h|--help]

Scan GitHub issues and local git branches, then list unfinished pipeline work by
stage. Without --repo, the repository is detected with `gh repo view`.

Only GitHub is supported. For other issue trackers, follow that repository's
tracker documentation instead.

  --all                  Also list exploring decisions, ticket-hygiene candidates, and loose issues.
  --order                Print a deterministic development order for implementable Specs.
  --parallel K           With --order, plan for K concurrent Specs (default: 2).
  --workers N            With --order, split N total workers across K concurrent Specs.
  --apart A:B            With --order, keep A and B out of the same wave. Repeatable.
  --cmd-suffix STR       With --order, append STR to each command (default: --impl codex).
  --json                 With --order, print the same plan as JSON instead of a text table.
EOF
}

die() {
  printf 'pipeline-status: %s\n' "$1" >&2
  exit 1
}

REPO=
ALL=0
ORDER=0
PARALLEL=2
WORKERS=
CMD_SUFFIX='--impl codex'
JSON=0
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
  node - "$mode" "$@" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const mode = process.argv[2];
const args = process.argv.slice(3);

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
    maps.push({
      number: mapIssue.number,
      state: mapIssue.state,
      title: mapIssue.title || '',
      openDecisionCount: decisions.filter(isOpen).length,
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

  const implementationValues = [...implementations.values()];
  const allProblemSpecs = issues.filter((issue) => (
    !issue.pull_request && hasProblemStatement(issue)
  )).map((issue) => ({
    number: issue.number,
    state: issue.state,
    title: issue.title || '',
    refs: bodyReferences(issue),
    ownChildren: Number(summary(issue).total || 0) > 0,
    ownChildCount: Number(summary(issue).total || 0),
    ownChildCompleted: Number(summary(issue).completed || 0),
  })).sort((a, b) => a.number - b.number);
  const coveredRefs = uniqueNumbers(allProblemSpecs.flatMap((spec) => spec.refs));
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

  function ticketRecord(number) {
    const issue = byNumber.get(Number(number));
    return {
      number: Number(number),
      state: issue ? issue.state : 'open',
      title: issue ? issue.title : '',
    };
  }

  const implement = [];
  for (const spec of stage.specs) {
    const referencesImplementation = spec.refs.some((ref) => implementations.has(Number(ref)));
    if (!spec.ownChildren && !referencesImplementation) continue;
    const tickets = [];
    const ticketSet = new Set();
    const addTickets = (numbers) => {
      for (const number of numbers) {
        if (!ticketSet.has(Number(number))) {
          ticketSet.add(Number(number));
          tickets.push(ticketRecord(number));
        }
      }
    };

    if (spec.ownChildren) {
      addTickets(readEndpoint(endpointDir, 'sub', spec.number).map((issue) => issue.number));
    } else {
      for (const ref of spec.refs) {
        const impl = implementations.get(Number(ref));
        if (!impl) continue;
        if (impl.childTotal > 0) {
          addTickets(readEndpoint(endpointDir, 'sub', impl.number).map((issue) => issue.number));
        } else {
          addTickets([impl.number]);
        }
      }
    }
    tickets.sort((a, b) => a.number - b.number);
    implement.push({
      number: spec.number,
      title: spec.title,
      kind: 'spec',
      tickets,
      closed: tickets.filter((ticket) => ticket.state === 'closed').length,
    });
  }

  for (const oldSpec of stage.oldCandidates) {
    const tickets = readEndpoint(endpointDir, 'sub', oldSpec.number)
      .map((issue) => ticketRecord(issue.number))
      .sort((a, b) => a.number - b.number);
    implement.push({
      number: oldSpec.number,
      title: oldSpec.title,
      kind: 'legacy',
      tickets,
      closed: tickets.filter((ticket) => ticket.state === 'closed').length,
    });
  }
  implement.sort((a, b) => a.number - b.number);

  const needsTickets = stage.specs
    .filter((spec) => !spec.ownChildren && !spec.refs.some((ref) => implementations.has(Number(ref))))
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

  const hygiene = [];
  if (all) {
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
    for (const spec of stage.allProblemSpecs) {
      if (isOpen(spec)) continue;
      for (const ref of spec.refs) {
        const number = Number(ref);
        if (!closedReferences.has(number)) closedReferences.set(number, []);
        closedReferences.get(number).push(spec.number);
      }
    }
    for (const impl of implementations.values()) {
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
  }

  const loose = [];
  if (all) {
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
    for (const issue of issues) {
      if (
        isOpen(issue) &&
        !isMap(issue) &&
        !mapChildren.has(Number(issue.number)) &&
        !hasProblemStatement(issue) &&
        !knownChildren.has(Number(issue.number))
      ) {
        loose.push({
          number: Number(issue.number),
          title: issue.title || '',
          labels: issueLabels(issue),
        });
      }
    }
    loose.sort((a, b) => a.number - b.number);
  }

  const blockerRequests = uniqueNumbers(implement.flatMap((spec) => (
    spec.tickets.filter((ticket) => ticket.state === 'open').map((ticket) => ticket.number)
  )));
  const output = {
    implement,
    needsTickets,
    missing,
    exploring,
    blockerRequests,
    hygiene: all ? hygiene : [],
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

  function integrationBranch(number) {
    if (!insideGit()) return null;
    try {
      const exact = `spec-${number}`;
      const output = cp.execFileSync('git', [
        'branch', '--list', exact, `${exact}-*`, '--format=%(refname:short)',
      ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
        .split(/\r?\n/).map((value) => value.trim()).filter(Boolean);
      if (output.includes(exact)) return exact;
      return output.find((branch) => branch.startsWith(`${exact}-`)) || null;
    } catch (_) {
      return null;
    }
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
    const openTickets = spec.tickets.filter((ticket) => ticket.state === 'open');
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
  if (pipeline.implement.length === 0) {
    lines.push('（无）');
  } else {
    for (const spec of pipeline.implement) {
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
      const tickets = spec.tickets.map((ticket) => `#${ticket.number}`).join(' ');
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

  if (all) {
    lines.push('');
    lines.push('状态没收尾');
    if ((pipeline.hygiene || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const item of pipeline.hygiene) {
        if (item.kind === 'closed-spec') {
          const tickets = item.tickets.map((ticket) => `#${ticket.number}`).join(' ');
          lines.push(`- 规格 #${item.number} ${clean(item.title)} 已关闭，执行票还开着：${tickets} → 核对后关票`);
        } else if (item.kind === 'implementation') {
          const specs = item.specNumbers.map((number) => `#${number}`).join('、');
          lines.push(`- 实现票 #${item.number} ${clean(item.title)} 的规格 ${specs} 已关闭，票还开着 → 核对后关票`);
        }
      }
    }

    lines.push('');
    lines.push('散票');
    if ((pipeline.loose || []).length === 0) {
      lines.push('（无）');
    } else {
      for (const issue of pipeline.loose) {
        const labels = issue.labels.length > 0 ? ` [${issue.labels.join(',')}]` : '';
        lines.push(`- #${issue.number}${labels} ${clean(issue.title)}`);
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
  const commandSuffix = args[4] === undefined ? '--impl codex' : args[4];
  const suppliedClaimsDir = args[5] || '';
  const lstartCommand = args[6] || 'ps -o lstart= -p';
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

  function integrationBranch(number) {
    if (!insideGit()) return null;
    try {
      const exact = `spec-${number}`;
      const output = cp.execFileSync('git', [
        'branch', '--list', exact, `${exact}-*`, '--format=%(refname:short)',
      ], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
        .split(/\r?\n/).map((value) => value.trim()).filter(Boolean);
      if (output.includes(exact)) return exact;
      return output.find((branch) => branch.startsWith(`${exact}-`)) || null;
    } catch (_) {
      return null;
    }
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
      const output = cp.execFileSync('/bin/sh', [
        '-c', `${lstartCommand} "$@"`, 'pipeline-status-lstart', String(pid),
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
  for (const spec of pipeline.implement) {
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
  for (const spec of pipeline.implement) {
    const target = Number(spec.number);
    const targetTickets = new Set(spec.tickets.map((ticket) => Number(ticket.number)));
    const openTickets = spec.tickets.filter((ticket) => ticket.state === 'open');
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

  const implementNumbers = pipeline.implement.map((spec) => Number(spec.number));
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
  const wave = [];
  const waveSet = new Set();
  for (const number of orderedNumbers) {
    if (wave.length >= capacity) break;
    const record = records.get(number);
    if (record.complete) continue;
    const conflicts = apartPairs.some(([left, right]) => (
      (left === number && waveSet.has(right)) ||
      (right === number && waveSet.has(left))
    ));
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
    const parts = [];
    if (dependencies.length > 0) {
      const prefix = firstWave && record.partial ? '部分等' : '等';
      parts.push(`${prefix} ${dependencies.join(' ')}`);
    }
    if (extras.length > 0) parts.push(`另需 ${extras.join(' ')}`);
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

  if (jsonOutput) {
    process.stdout.write(JSON.stringify(plan, null, 2) + '\n');
    process.exit(0);
  }

  const lines = [];
  if (pipeline.implement.length === 0) {
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

if ! pipeline_node plan "$ISSUES_FILE" "$WORK/endpoints" "$ALL" > "$STAGE_FILE"; then
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

if ! pipeline_node collect "$ISSUES_FILE" "$STAGE_FILE" "$WORK/endpoints" "$ALL" > "$PIPELINE_FILE"; then
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
    "${ISS_PS_LSTART_CMD:-ps -o lstart= -p}"
    "$WORKERS"
    "$JSON"
  )
  if [ "$APART_COUNT" -gt 0 ]; then
    for pair in "${APART[@]}"; do
      ORDER_ARGS+=("$pair")
    done
  fi
  if ! pipeline_node order "${ORDER_ARGS[@]}"; then
    die "could not render development order"
  fi
else
  if ! pipeline_node render "$ISSUES_FILE" "$PIPELINE_FILE" "$WORK/blockers" "$ALL"; then
    die "could not render pipeline status"
  fi
fi
