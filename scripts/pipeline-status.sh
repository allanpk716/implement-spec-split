#!/usr/bin/env bash
# List unfinished work in the wayfinder -> to-spec -> to-tickets -> implement pipeline.

set -u

usage() {
  cat <<'EOF'
Usage: pipeline-status.sh [--repo <owner/name>] [-h|--help]

Scan GitHub issues and local git branches, then list unfinished pipeline work by
stage. Without --repo, the repository is detected with `gh repo view`.

Only GitHub is supported. For other issue trackers, follow that repository's
tracker documentation instead.
EOF
}

die() {
  printf 'pipeline-status: %s\n' "$1" >&2
  exit 1
}

REPO=
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo requires <owner/name>"
      REPO=$2
      shift 2
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
  const pattern = /#([0-9]+)/g;
  for (const line of body.split(/\r?\n/)) {
    if (!/(实现票|Implementation tickets?)\s*[:：]/i.test(line)) continue;
    let match;
    while ((match = pattern.exec(line)) !== null) refs.add(Number(match[1]));
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
  const problemSpecs = issues.filter((issue) => (
    isOpen(issue) && !issue.pull_request && hasProblemStatement(issue)
  )).map((issue) => ({
    number: issue.number,
    title: issue.title || '',
    refs: bodyReferences(issue),
    ownChildren: Number(summary(issue).total || 0) > 0,
    ownChildCount: Number(summary(issue).total || 0),
  })).sort((a, b) => a.number - b.number);

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

  const output = {
    maps,
    implementations: implementationValues.sort((a, b) => a.number - b.number),
    specs: problemSpecs,
    oldCandidates,
    subRequests: requests,
  };
  process.stdout.write(JSON.stringify(output, null, 2));
  process.exit(0);
}

if (mode === 'collect') {
  const issues = readJson(args[0]).filter((issue) => !issue.pull_request);
  const stage = readJson(args[1]);
  const endpointDir = args[2];
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
    .map((spec) => ({number: spec.number, title: spec.title}))
    .sort((a, b) => a.number - b.number);

  const referencedImplementations = new Set();
  for (const spec of stage.specs) {
    for (const ref of spec.refs) referencedImplementations.add(Number(ref));
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

  const blockerRequests = uniqueNumbers(implement.flatMap((spec) => (
    spec.tickets.filter((ticket) => ticket.state === 'open').map((ticket) => ticket.number)
  )));
  const output = {
    implement,
    needsTickets,
    missing,
    exploring: stage.maps
      .filter((map) => map.openDecisionCount > 0)
      .map((map) => ({
        number: map.number,
        title: map.title,
        openDecisionCount: map.openDecisionCount,
      }))
      .sort((a, b) => a.number - b.number),
    blockerRequests,
  };
  process.stdout.write(JSON.stringify(output, null, 2));
  process.exit(0);
}

if (mode === 'render') {
  const issues = readJson(args[0]);
  const pipeline = readJson(args[1]);
  const blockerDir = args[2];
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
    }
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

if ! pipeline_node plan "$ISSUES_FILE" "$WORK/endpoints" > "$STAGE_FILE"; then
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

if ! pipeline_node collect "$ISSUES_FILE" "$STAGE_FILE" "$WORK/endpoints" > "$PIPELINE_FILE"; then
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

if ! pipeline_node render "$ISSUES_FILE" "$PIPELINE_FILE" "$WORK/blockers"; then
  die "could not render pipeline status"
fi
