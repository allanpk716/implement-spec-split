#!/usr/bin/env bash
# Publish drafted find-next spec batches and their execution tickets to GitHub.

set -u

usage() {
  cat <<'EOF'
Usage: publish-batch.sh [--repo <owner/name>] [--apply] [--only S1,S3] <manifest.json>...

Read one manifest per drafted spec, validate all references first, then publish
GitHub issues. Without --apply, no write request is sent.

Manifest fields:
  key        Required spec key, matching S<number>.
  title      Required issue title.
  body       Required markdown file, relative to the manifest, unless
             existing_spec is used.
  existing_spec
             Optional positive issue number. The group only creates execution
             tickets and attaches them to this already-existing open spec.
  labels     Optional string array; defaults to ["ready-for-agent"].
  tickets    Array of execution tickets with T<number> keys, bodies, optional
             labels, and blocked_by references.
  unresolved Optional array of strings or objects with question, proposal,
             and affects. Objects are recommended. Dry runs still print the
             plan; --apply rejects a selected manifest containing any item.
  handoffs   Optional array of {issue, note}. Existing issues receive the
             rendered note after all issues, relations, and body patches.

blocked_by and {{...}} body placeholders may refer to:
  T1         A ticket in the same manifest.
  S2         A spec manifest passed to this invocation, or one with a
             published.json record next to it.
  S2/T1      A ticket in another passed manifest (or its record).
  #212       An existing issue in the target repository.
Only these four formats are placeholders; other {{...}} text is preserved as-is.

Execution tickets are created after all selected specs, in dependency order.
Each is immediately attached as a sub-issue and given its blocked-by edges.
Progress is recorded in published.json beside every manifest, so an interrupted
--apply run can be retried without duplicate issues or edges.
EOF
}

die() {
  printf 'publish-batch: %s\n' "$1" >&2
  exit 1
}

gh_api() {
  gh api "$@"
}

gh_current_repo() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

REPO=
APPLY=0
ONLY=
MANIFESTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo requires <owner/name>"
      REPO=$2
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --only)
      [ $# -ge 2 ] || die "--only requires a comma-separated list of spec keys"
      ONLY=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --internal-api)
      shift
      gh_api "$@"
      exit $?
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        MANIFESTS+=("$1")
        shift
      done
      ;;
    -*)
      usage >&2
      die "unknown argument: $1"
      ;;
    *)
      MANIFESTS+=("$1")
      shift
      ;;
  esac
done

[ "${#MANIFESTS[@]}" -gt 0 ] || die "at least one manifest.json is required"

command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"
command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"

if [ -z "$REPO" ]; then
  REPO=$(gh_current_repo) || die "could not detect the GitHub repository with gh repo view"
  [ -n "$REPO" ] || die "gh repo view returned an empty repository name"
fi

publish_node() {
  mode=$1
  shift
  node - "$mode" "$@" <<'NODE'
const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');

const mode = process.argv[2];
const argv = process.argv.slice(3);
const repo = argv[0];
const apply = argv[1] === '1';
const onlyArgument = argv[2];
const manifestPaths = argv.slice(argv.indexOf('--') + 1);
const errors = [];
const externalIds = new Map();
const externalIssues = new Map();
let manifests = [];
let byKey = new Map();
let selectedKeys = new Set();
const PLACEHOLDER_PATTERN = /\{\{(#[0-9]+|S[0-9]+\/T[0-9]+|S[0-9]+|T[0-9]+)\}\}/g;

function fail(message) {
  process.stderr.write(`publish-batch: ${message}\n`);
  process.exit(2);
}

function check(condition, message) {
  if (!condition) errors.push(message);
  return condition;
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function unique(values) {
  return [...new Set(values)];
}

function selected(manifest) {
  return selectedKeys.has(manifest.key);
}

function placeholderReferences(body) {
  PLACEHOLDER_PATTERN.lastIndex = 0;
  const references = [];
  for (let match;
       (match = PLACEHOLDER_PATTERN.exec(String(body || ''))) !== null;) {
    references.push(match[1]);
  }
  return references;
}

function hasPlaceholder(body) {
  PLACEHOLDER_PATTERN.lastIndex = 0;
  const result = PLACEHOLDER_PATTERN.test(String(body || ''));
  PLACEHOLDER_PATTERN.lastIndex = 0;
  return result;
}

function issueFromRecord(value, key, type) {
  if (!isPlainObject(value)) return null;
  const number = Number(value.number);
  const databaseId = Number(value.databaseId ?? value.id);
  if (!Number.isInteger(number) || number <= 0) return null;
  if (!Number.isInteger(databaseId) || databaseId <= 0) return null;
  return {
    key, type, number, databaseId,
    title: String(value.title || ''),
    patchPending: Boolean(value.patchPending),
  };
}

function readRecord(manifest) {
  const file = path.join(manifest.dir, 'published.json');
  if (!fs.existsSync(file)) return {issues: {}, relations: [], handoffs: []};
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read ${file}: ${error.message}`);
  }
  if (!isPlainObject(value) || !isPlainObject(value.issues) ||
      !Array.isArray(value.relations)) {
    throw new Error(`invalid publish record ${file}`);
  }
  if (value.repo !== undefined && value.repo !== repo) {
    throw new Error(`publish record ${file} belongs to ${value.repo}, not ${repo}`);
  }
  const issues = {};
  for (const [key, issue] of Object.entries(value.issues)) {
    const type = String(key).startsWith('S') ? 'spec' : 'ticket';
    const parsed = issueFromRecord(issue, key, type);
    if (parsed) issues[key] = parsed;
  }
  if (value.handoffs !== undefined && !Array.isArray(value.handoffs)) {
    throw new Error(`invalid publish record ${file}: handoffs must be an array`);
  }
  return {
    issues,
    relations: value.relations.map(String),
    handoffs: Array.isArray(value.handoffs) ? value.handoffs.map(String) : [],
    file,
  };
}

function labelList(value, where) {
  if (value === undefined) return ['ready-for-agent'];
  if (!Array.isArray(value) || value.length === 0 ||
      value.some((label) => typeof label !== 'string' || label.trim() === '')) {
    errors.push(`${where}: labels must be a non-empty string array`);
    return [];
  }
  return value.slice();
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

function parseManifest(file) {
  const absolute = path.resolve(file);
  let value;
  try {
    value = JSON.parse(fs.readFileSync(absolute, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read manifest ${file}: ${error.message}`);
  }
  if (!isPlainObject(value)) throw new Error(`manifest ${file} must be an object`);
  const manifest = {
    file: absolute,
    dir: path.dirname(absolute),
    key: value.key,
    title: value.title,
    existingSpec: value.existing_spec,
    labels: labelList(value.labels, `manifest ${file} labels`),
    ticketDefinitions: Array.isArray(value.tickets) ? value.tickets : [],
    unresolved: Array.isArray(value.unresolved) ? value.unresolved : [],
    unresolvedDefinitions: Array.isArray(value.unresolved) ? value.unresolved : [],
    handoffDefinitions: Array.isArray(value.handoffs) ? value.handoffs : [],
    source: value,
  };
  return manifest;
}

function loadManifests() {
  const seenFiles = new Set();
  for (const file of manifestPaths) {
    const absolute = path.resolve(file);
    if (seenFiles.has(absolute)) errors.push(`duplicate manifest: ${file}`);
    seenFiles.add(absolute);
    let manifest;
    try {
      manifest = parseManifest(file);
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    check(/^S[0-9]+$/.test(String(manifest.key)) &&
      typeof manifest.title === 'string' && manifest.title.trim() !== '',
    `manifest ${file}: key must match S<number> and title must be non-empty`);
    check(manifest.existingSpec === undefined ||
      (Number.isInteger(manifest.existingSpec) && manifest.existingSpec > 0),
    `manifest ${file}: existing_spec must be a positive integer`);
    manifest.tickets = [];
    const ticketKeys = new Set();
    manifest.ticketDefinitions.forEach((definition, index) => {
      const where = `manifest ${file} ticket ${index + 1}`;
      if (!isPlainObject(definition)) {
        errors.push(`${where}: must be an object`);
        return;
      }
      const key = String(definition.key || '');
      check(/^T[0-9]+$/.test(key), `${where}: key must match T<number>`);
      check(typeof definition.title === 'string' && definition.title.trim() !== '',
        `${where}: title must be non-empty`);
      check(ticketKeys.has(key) === false, `${where}: duplicate ticket key ${key}`);
      ticketKeys.add(key);
      const bodyFile = definition.body;
      check(typeof bodyFile === 'string' && bodyFile !== '',
        `${where}: body must be a relative file path`);
      check(typeof bodyFile !== 'string' || !path.isAbsolute(bodyFile),
        `${where}: body path must be relative: ${bodyFile}`);
      const absoluteBody = typeof bodyFile === 'string'
        ? path.resolve(manifest.dir, bodyFile) : '';
      let body = '';
      if (absoluteBody) {
        try {
          const stat = fs.statSync(absoluteBody);
          check(stat.isFile(), `${where}: body is not a file: ${bodyFile}`);
          if (stat.isFile()) body = fs.readFileSync(absoluteBody, 'utf8');
        } catch (_) {
          errors.push(`${where}: body file not found: ${bodyFile}`);
        }
      }
      check(body.trim() !== '', `${where}: body file is empty: ${bodyFile}`);
      manifest.tickets.push({
        key, title: definition.title || '', body, bodyFile,
        labels: labelList(definition.labels, `${where} labels`),
        blockedBy: Array.isArray(definition.blocked_by) ? definition.blocked_by : [],
      });
    });
    if (manifest.existingSpec !== undefined) {
      check(manifest.source.body === undefined,
        `manifest ${file}: body must be omitted when existing_spec is used`);
      manifest.bodyFile = '';
      manifest.absoluteBodyFile = '';
      manifest.body = '';
    } else {
      const bodyFile = manifest.source.body;
      check(typeof bodyFile === 'string' && bodyFile !== '',
        `manifest ${file}: body must be a relative file path`);
      check(typeof bodyFile !== 'string' || !path.isAbsolute(bodyFile),
        `manifest ${file}: body path must be relative: ${bodyFile}`);
      manifest.bodyFile = bodyFile;
      manifest.absoluteBodyFile = typeof bodyFile === 'string'
        ? path.resolve(manifest.dir, bodyFile) : '';
      try {
        const stat = fs.statSync(manifest.absoluteBodyFile);
        check(stat.isFile(), `manifest ${file}: body is not a file: ${bodyFile}`);
        if (stat.isFile()) manifest.body = fs.readFileSync(manifest.absoluteBodyFile, 'utf8');
      } catch (_) {
        manifest.body = '';
        errors.push(`manifest ${file}: body file not found: ${bodyFile}`);
      }
      check((manifest.body || '').trim() !== '',
        `manifest ${file}: body file is empty: ${bodyFile}`);
    }
    manifests.push(manifest);
  }
  const keys = manifests.map((manifest) => String(manifest.key));
  for (const key of keys) {
    if (keys.filter((value) => value === key).length > 1) {
      errors.push(`duplicate spec key: ${key}`);
    }
  }
  const existingSpecs = manifests
    .filter((manifest) => manifest.existingSpec !== undefined)
    .map((manifest) => manifest.existingSpec);
  for (const number of existingSpecs) {
    if (existingSpecs.filter((value) => value === number).length > 1) {
      errors.push(`duplicate existing_spec: #${number}`);
    }
  }
  byKey = new Map(manifests.map((manifest) => [String(manifest.key), manifest]));
  const onlyValues = onlyArgument ? onlyArgument.split(',').map((key) => key.trim()) : [];
  check(onlyValues.every((key) => key !== ''), '--only contains an empty key');
  for (const key of unique(onlyValues)) {
    check(byKey.has(key), `--only references unknown spec key: ${key}`);
    selectedKeys.add(key);
  }
  if (!onlyArgument) selectedKeys = new Set(manifests.map((manifest) => String(manifest.key)));
  for (const manifest of manifests) {
    check(manifest.source.unresolved === undefined ||
      Array.isArray(manifest.source.unresolved),
    `manifest ${manifest.file}: unresolved must be an array`);
    check(manifest.source.handoffs === undefined ||
      Array.isArray(manifest.source.handoffs),
    `manifest ${manifest.file}: handoffs must be an array`);
    manifest.unresolved = [];
    manifest.unresolvedDefinitions.forEach((item, index) => {
      const where = `manifest ${manifest.file} unresolved ${index + 1}`;
      if (nonEmptyString(item)) {
        manifest.unresolved.push({question: item});
        return;
      }
      if (!isPlainObject(item)) {
        errors.push(`${where}: must be a non-empty string or object`);
        return;
      }
      const valid = ['question', 'proposal', 'affects']
        .every((name) => nonEmptyString(item[name]));
      if (!valid) {
        errors.push(
          `${where}: object items require non-empty string question, proposal, and affects`
        );
        return;
      }
      manifest.unresolved.push({
        question: item.question, proposal: item.proposal, affects: item.affects,
      });
    });
    manifest.handoffs = [];
    manifest.handoffDefinitions.forEach((item, index) => {
      const where = `manifest ${manifest.file} handoff ${index + 1}`;
      if (!isPlainObject(item)) {
        errors.push(`${where}: must be an object`);
        return;
      }
      if (!Number.isInteger(item.issue) || item.issue <= 0) {
        errors.push(`${where}: issue must be a positive integer`);
      }
      if (!nonEmptyString(item.note)) {
        errors.push(`${where}: note must be a non-empty string`);
      }
      if (Number.isInteger(item.issue) && item.issue > 0 && nonEmptyString(item.note)) {
        manifest.handoffs.push({index, issue: item.issue, note: item.note});
      }
    });
    try {
      manifest.record = readRecord(manifest);
    } catch (error) {
      errors.push(error.message);
      manifest.record = {issues: {}, relations: [], handoffs: []};
    }
    if (apply && selected(manifest) && manifest.unresolved.length > 0) {
      const questions = manifest.unresolved.map((item) => item.question);
      errors.push(`manifest ${manifest.key} has unresolved items: ${questions.join('、')}`);
    }
  }
}

function referenceSyntax(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  const value = raw.trim();
  let match = /^#([0-9]+)$/.exec(value);
  if (match) return {kind: 'existing', number: Number(match[1]), display: value};
  match = /^T([0-9]+)$/.exec(value);
  if (match) return {kind: 'ticket', ticketKey: `T${match[1]}`, display: value};
  match = /^(S[0-9]+)$/.exec(value);
  if (match) return {kind: 'spec', specKey: match[1], display: value};
  match = /^(S[0-9]+)\/(T[0-9]+)$/.exec(value);
  if (match) {
    return {
      kind: 'ticket', specKey: match[1], ticketKey: match[2],
      display: `${match[1]}/${match[2]}`,
    };
  }
  return null;
}

function resolveReference(raw, from, where) {
  const syntax = referenceSyntax(raw);
  if (!syntax) {
    errors.push(`${where}: invalid reference ${JSON.stringify(raw)}`);
    return null;
  }
  if (syntax.kind === 'existing') return syntax;
  if (syntax.kind === 'spec') {
    const target = byKey.get(syntax.specKey);
    if (!target) {
      errors.push(`${where}: unknown spec reference ${syntax.display}`);
      return null;
    }
    syntax.target = target;
    return syntax;
  }
  const target = syntax.specKey
    ? byKey.get(syntax.specKey)
    : from;
  if (!target) {
    errors.push(`${where}: unknown spec reference ${syntax.display}`);
    return null;
  }
  syntax.target = target;
  syntax.display = syntax.specKey ? syntax.display : `${from.key}/${syntax.ticketKey}`;
  return syntax;
}

function recordedIssue(reference) {
  if (!reference.target) return null;
  if (reference.kind === 'spec') {
    return reference.target.record.issues[reference.target.key] || null;
  }
  return reference.target.record.issues[reference.ticketKey] || null;
}

function requireResolvableReference(reference, where, sourceManifest) {
  if (reference.kind === 'existing') return true;
  const issue = recordedIssue(reference);
  if (issue) return true;
  if (reference.target && reference.target.existingSpec !== undefined) return true;
  if (selected(reference.target)) return true;
  if (!selected(sourceManifest)) return true;
  errors.push(
    `${where}: ${reference.display} has no publish record and is outside --only`
  );
  return false;
}

function validateReferences() {
  for (const manifest of manifests) {
    const refs = [[manifest.body, `${manifest.key} spec body`]];
    for (const ticket of manifest.tickets) {
      check(Array.isArray(ticket.blockedBy), `${manifest.key}/${ticket.key}: blocked_by must be an array`);
      if (!Array.isArray(ticket.blockedBy)) ticket.blockedBy = [];
      ticket.blockedBy = unique(ticket.blockedBy);
      ticket.blockedBy.forEach((raw) => {
        const reference = resolveReference(raw, manifest, `${manifest.key}/${ticket.key} blocked_by`);
        if (reference) {
          requireResolvableReference(
            reference, `${manifest.key}/${ticket.key} blocked_by`, manifest
          );
          ticket.references = ticket.references || [];
          ticket.references.push(reference);
        }
      });
      refs.push([ticket.body, `${manifest.key}/${ticket.key} body`]);
    }
    for (const handoff of manifest.handoffs) {
      refs.push([handoff.note, `${manifest.key} handoff #${handoff.issue} note`]);
    }
    for (const [body, where] of refs) {
      for (const raw of placeholderReferences(body)) {
        const reference = resolveReference(raw, manifest, where);
        if (reference) {
          requireResolvableReference(
            reference, `${where} placeholder {{${raw}}}`, manifest
          );
        }
      }
    }
  }
}

function ticketEdges() {
  const edges = [];
  const nodes = new Map();
  for (const manifest of manifests) {
    for (const ticket of manifest.tickets) {
      const id = `${manifest.key}/${ticket.key}`;
      nodes.set(id, {id, manifest, ticket, blockers: []});
    }
  }
  for (const node of nodes.values()) {
    for (const raw of node.ticket.blockedBy) {
      const reference = resolveReference(raw, node.manifest, 'internal topology');
      if (!reference || reference.kind !== 'ticket') continue;
      const blockerId = `${reference.target.key}/${reference.ticketKey}`;
      if (nodes.has(blockerId)) {
        nodes.get(blockerId).blockers.push(node.id);
        edges.push({blocker: blockerId, dependent: node.id});
      }
    }
  }
  return {nodes, edges};
}

function validateTicketGraph() {
  const graph = ticketEdges();
  const incoming = new Map([...graph.nodes.keys()].map((id) => [id, 0]));
  for (const edge of graph.edges) incoming.set(edge.dependent, incoming.get(edge.dependent) + 1);
  const indexes = new Map();
  for (const [id, node] of graph.nodes) {
    const specIndex = manifests.indexOf(node.manifest);
    indexes.set(id, specIndex * 100000 + node.manifest.tickets.indexOf(node.ticket));
  }
  const ready = [...graph.nodes.keys()]
    .filter((id) => incoming.get(id) === 0);
  const order = [];
  const inserted = new Set();
  while (ready.length > 0) {
    ready.sort((left, right) => indexes.get(left) - indexes.get(right));
    const id = ready.shift();
    order.push(id);
    inserted.add(id);
    for (const dependent of graph.nodes.get(id).blockers) {
      incoming.set(dependent, incoming.get(dependent) - 1);
      if (incoming.get(dependent) === 0) ready.push(dependent);
    }
  }
  if (order.length !== graph.nodes.size) {
    const cycle = [...graph.nodes.keys()].filter((id) => !inserted.has(id));
    errors.push(`execution ticket dependency cycle: ${cycle.join(' -> ')}`);
  }
  graph.order = order;
  return graph;
}

function ghApi(endpoint, method, fields = []) {
  const args = method ? ['-X', method, endpoint] : [endpoint];
  for (const [name, value] of fields) args.push(name, String(value));
  try {
    return execFileSync(process.env.PUBLISH_SCRIPT, ['--internal-api', ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    const detail = [error.stderr, error.stdout, error.message]
      .filter(Boolean).map(String).join('\n').trim();
    fail(`GitHub request failed at ${method || 'GET'} ${endpoint}${detail ? `:\n${detail}` : ''}`);
  }
}

function validateExistingIssues() {
  const numbers = new Set();
  for (const manifest of manifests) {
    if (manifest.existingSpec !== undefined) numbers.add(manifest.existingSpec);
    const add = (body) => {
      for (const raw of placeholderReferences(body)) {
        const reference = referenceSyntax(raw);
        if (reference && reference.kind === 'existing') numbers.add(reference.number);
      }
    };
    for (const ticket of manifest.tickets) {
      ticket.blockedBy.forEach((raw) => {
        const reference = referenceSyntax(raw);
        if (reference && reference.kind === 'existing') numbers.add(reference.number);
      });
      add(ticket.body);
    }
    add(manifest.body);
    for (const handoff of manifest.handoffs) numbers.add(handoff.issue);
  }
  for (const number of [...numbers].sort((a, b) => a - b)) {
    let issue;
    try {
      issue = JSON.parse(ghApi(`repos/${repo}/issues/${number}`));
    } catch (_) {
      fail(`GitHub request failed while checking existing issue #${number}`);
    }
    check(Number(issue.id) > 0 && Number(issue.number) === number,
      `existing issue reference #${number} was not returned by GitHub`);
    if (Number(issue.id) > 0) externalIds.set(number, Number(issue.id));
    if (Number(issue.id) > 0) {
      externalIssues.set(number, {
        number,
        databaseId: Number(issue.id),
        title: String(issue.title || `#${number}`),
        state: String(issue.state || 'open'),
        body: String(issue.body || ''),
      });
    }
  }
  inspectExistingSpecs();
}

function inspectExistingSpecs() {
  for (const manifest of manifests) {
    if (manifest.existingSpec === undefined) continue;
    const issue = externalIssues.get(manifest.existingSpec);
    if (!issue) {
      errors.push(`manifest ${manifest.key}: existing spec #${manifest.existingSpec} was not returned by GitHub`);
      continue;
    }
    check(issue.state === 'open',
      `manifest ${manifest.key}: existing spec #${manifest.existingSpec} is not open`);
    check(/^[ \t]*## Problem Statement[ \t\r]*$/m.test(issue.body),
      `manifest ${manifest.key}: existing spec #${manifest.existingSpec} has no ## Problem Statement section`);
    check(manifest.title === issue.title,
      `manifest ${manifest.key}: title must equal existing spec #${manifest.existingSpec} title`);

    const recorded = manifest.record.issues[manifest.key];
    if (manifest.record.file && !recorded) {
      errors.push(`invalid publish record ${manifest.record.file}: missing existing spec ${manifest.key}`);
    }
    if (recorded) {
      check(recorded.number === issue.number && recorded.databaseId === issue.databaseId,
        `manifest ${manifest.key}: publish record spec must remain #${issue.number}`);
    } else if (!manifest.record.file) {
      manifest.record.issues[manifest.key] = {
        key: manifest.key,
        type: 'spec',
        number: issue.number,
        databaseId: issue.databaseId,
        title: issue.title,
      };
      manifest.existingSpecRecordPending = true;
    }
    const foreignChildren = checkExistingSpecChildren(manifest);
    check(foreignChildren.length === 0,
      `manifest ${manifest.key}: existing spec #${manifest.existingSpec} already has sub-issues: ${foreignChildren.map((number) => `#${number}`).join('、')}`);
  }
}

function checkExistingSpecChildren(manifest) {
  const spec = manifest.record.issues[manifest.key];
  if (!spec) return [];
  const actual = new Set(returnedIssueNumbers(JSON.parse(
    ghApi(`repos/${repo}/issues/${spec.number}/sub_issues?per_page=100`)
  )));
  const own = new Set(manifest.tickets
    .map((ticket) => manifest.record.issues[ticket.key])
    .filter(Boolean)
    .map((ticket) => ticket.number));
  return [...actual].filter((number) => !own.has(number));
}

function saveRecord(manifest) {
  const value = {
    repo,
    issues: manifest.record.issues,
    relations: unique(manifest.record.relations),
    handoffs: unique(manifest.record.handoffs || []),
  };
  const temporary = path.join(manifest.dir, '.published.json.tmp');
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(temporary, manifest.record.file ||
    path.join(manifest.dir, 'published.json'));
}

function relationKey(kind, left, right) {
  if (kind === 'sub') return `sub:${left}/${right}`;
  if (kind === 'patch') return `patch:${left}/${right}`;
  return `dependency:${left}<-${right}`;
}

function rememberIssue(manifest, key, issue, title) {
  const type = key.startsWith('T') ? 'ticket' : 'spec';
  manifest.record.issues[key] = {
    key, type, number: Number(issue.number), databaseId: Number(issue.id), title,
  };
  saveRecord(manifest);
}

function rememberRelation(manifest, relation) {
  if (manifest.record.relations.includes(relation)) return;
  manifest.record.relations.push(relation);
  saveRecord(manifest);
}

function rememberHandoff(manifest, handoff) {
  const relation = `handoff:${handoff.index}:${handoff.issue}`;
  if (manifest.record.handoffs.includes(relation)) return false;
  manifest.record.handoffs.push(relation);
  saveRecord(manifest);
  return true;
}

function sendHandoffs() {
  for (const manifest of manifests.filter(selected)) {
    const spec = manifest.record.issues[manifest.key];
    if (!spec) fail(`internal error: missing published spec ${manifest.key}`);
    for (const handoff of manifest.handoffs) {
      const relation = `handoff:${handoff.index}:${handoff.issue}`;
      if (manifest.record.handoffs.includes(relation)) continue;
      const note = renderBody(handoff.note, manifest);
      if (hasPlaceholder(note)) {
        fail(`internal error: unresolved placeholder remains in ${manifest.key} handoff #${handoff.issue}`);
      }
      const body = `${note}\n\n（规格 #${spec.number} 批量发布时留下）`;
      ghApi(
        `repos/${repo}/issues/${handoff.issue}/comments`, 'POST', [['-f', `body=${body}`]]
      );
      rememberHandoff(manifest, handoff);
      process.stdout.write(`已在 #${handoff.issue} 留言（来自 ${manifest.key}）\n`);
    }
  }
}

function createIssue(manifest, key, title, body, labels, type) {
  const fields = [['-f', `title=${title}`], ['-f', `body=${body}`]];
  for (const label of labels) fields.push(['-f', `labels[]=${label}`]);
  const response = JSON.parse(ghApi(`repos/${repo}/issues`, 'POST', fields));
  check(Number(response.number) > 0 && Number(response.id) > 0,
    `GitHub did not return number and id for ${manifest.key}/${key}`);
  if (!(Number(response.number) > 0)) fail('invalid issue response');
  rememberIssue(manifest, key, response, title);
  manifest.record.issues[key].patchPending = hasPlaceholder(body);
  saveRecord(manifest);
  process.stdout.write(
    `已新建${type === 'spec' ? '规格' : '执行票'} ${manifest.key}` +
    `${type === 'ticket' ? `/${key}` : ''} #${response.number}「${title}」\n`
  );
  return manifest.record.issues[key];
}

function referenceNumber(reference) {
  if (reference.kind === 'existing') {
    const id = externalIds.get(reference.number);
    if (!id) fail(`internal error: missing database id for #${reference.number}`);
    return {number: reference.number, databaseId: id};
  }
  const issue = recordedIssue(reference);
  if (!issue) return null;
  return issue;
}

function renderBody(body, manifest) {
  PLACEHOLDER_PATTERN.lastIndex = 0;
  return String(body || '').replace(PLACEHOLDER_PATTERN, (all, raw) => {
    const reference = referenceSyntax(raw);
    if (!reference) return all;
    const resolved = resolveReference(reference.display, manifest, 'body render');
    const issue = resolved && referenceNumber(resolved);
    return issue ? String(issue.number) : all;
  });
}

function bodyHasFutureReference(body, manifest) {
  return hasPlaceholder(renderBody(body, manifest));
}

function attachTicket(manifest, ticket) {
  const spec = manifest.record.issues[manifest.key];
  const child = manifest.record.issues[ticket.key];
  const relation = relationKey('sub', manifest.key, ticket.key);
  if (manifest.record.relations.includes(relation)) return;
  ghApi(
    `repos/${repo}/issues/${spec.number}/sub_issues`, 'POST',
    [['-F', `sub_issue_id=${child.databaseId}`]]
  );
  rememberRelation(manifest, relation);
}

function dependencyParts(manifest, ticket, raw) {
  const reference = resolveReference(raw, manifest, 'dependency render');
  const blocker = reference && referenceNumber(reference);
  const dependent = manifest.record.issues[ticket.key];
  if (!reference || !blocker || !dependent) {
    fail(`internal error: unresolved dependency ${manifest.key}/${ticket.key} <- ${raw}`);
  }
  return {reference, blocker, dependent};
}

function addDependency(manifest, ticket, raw) {
  const parts = dependencyParts(manifest, ticket, raw);
  const relation = relationKey(
    'dependency', `${manifest.key}/${ticket.key}`, parts.reference.display
  );
  if (manifest.record.relations.includes(relation)) return;
  ghApi(
    `repos/${repo}/issues/${parts.dependent.number}/dependencies/blocked_by`, 'POST',
    [['-F', `issue_id=${parts.blocker.databaseId}`]]
  );
  rememberRelation(manifest, relation);
}

function displayReference(manifest, raw) {
  const reference = referenceSyntax(raw);
  if (!reference) return String(raw);
  if (reference.kind === 'ticket' && !reference.specKey) {
    return `${manifest.key}/${reference.ticketKey}`;
  }
  return reference.display;
}

function printDryRun(graph) {
  const order = graph.order
    .map((id) => graph.nodes.get(id))
    .filter((node) => selected(node.manifest));
  const processedIssues = new Set();
  const pendingPatches = [];
  const unresolvedAtCreation = (body, manifest) => {
    for (const raw of placeholderReferences(body)) {
      const syntax = referenceSyntax(raw);
      if (!syntax || syntax.kind === 'existing') continue;
      const target = syntax.specKey ? byKey.get(syntax.specKey) : manifest;
      if (!target) continue;
      const issueKey = syntax.kind === 'spec' ? target.key : syntax.ticketKey;
      if (target.record.issues[issueKey]) continue;
      if (!selected(target)) continue;
      const identity = syntax.kind === 'spec'
        ? target.key : `${target.key}/${syntax.ticketKey}`;
      if (!processedIssues.has(identity)) return true;
    }
    return false;
  };
  for (const manifest of manifests.filter(selected)) {
    if (manifest.record.issues[manifest.key]) {
      if (manifest.record.issues[manifest.key].patchPending) {
        pendingPatches.push({manifest, key: manifest.key});
      }
    } else if (unresolvedAtCreation(manifest.body, manifest)) {
      pendingPatches.push({manifest, key: manifest.key});
    }
    processedIssues.add(manifest.key);
  }
  let newSpecs = 0;
  let newTickets = 0;
  for (const manifest of manifests.filter(selected)) {
    if (manifest.record.issues[manifest.key]) {
      if (manifest.existingSpec !== undefined) {
        const spec = manifest.record.issues[manifest.key];
        process.stdout.write(
          `使用已有规格 ${manifest.key} #${spec.number}「${manifest.title}」（只拆票）\n`
        );
      }
      continue;
    }
    newSpecs += 1;
    process.stdout.write(
      `将新建规格 ${manifest.key}「${manifest.title}」 标签：${manifest.labels.join(',')}\n`
    );
  }
  for (const node of order) {
    const {manifest, ticket} = node;
    if (manifest.record.issues[ticket.key]) continue;
    newTickets += 1;
    let suffix = ` → 挂到 ${manifest.key} 下`;
    if (ticket.blockedBy.length > 0) {
      suffix += `，被 ${ticket.blockedBy.map((raw) => displayReference(manifest, raw)).join('、')} 挡住`;
    }
    process.stdout.write(`将新建执行票 ${manifest.key}/${ticket.key}「${ticket.title}」${suffix}\n`);
    processedIssues.add(`${manifest.key}/${ticket.key}`);
    if (manifest.record.issues[ticket.key]) {
      if (manifest.record.issues[ticket.key].patchPending) {
        pendingPatches.push({manifest, key: ticket.key});
      }
    } else if (unresolvedAtCreation(ticket.body, manifest)) {
      pendingPatches.push({manifest, key: ticket.key});
    }
  }
  for (const item of pendingPatches) {
    process.stdout.write(`将回填正文 ${
      item.key.startsWith('T') ? `${item.manifest.key}/${item.key}` : item.manifest.key
    }「${
      item.key.startsWith('T')
        ? item.manifest.tickets.find((ticket) => ticket.key === item.key).title
        : item.manifest.title
    }」\n`);
  }
  printHandoffPreviews();
  printIssues();
  process.stdout.write(
    `试运行：将发布 ${newSpecs} 张规格、${newTickets} 张执行票，加 --apply 执行\n`
  );
  printUnresolved();
  process.stdout.write('发布后会运行 pipeline-status.sh --order 输出开发顺序。\n');
}

function printHandoffPreviews() {
  for (const manifest of manifests.filter(selected)) {
    for (const handoff of manifest.handoffs) {
      const note = renderBody(handoff.note, manifest).slice(0, 60);
      process.stdout.write(
        `将在 #${handoff.issue} 留言（来自 ${manifest.key}）：${note}…\n`
      );
    }
  }
}

function printUnresolved() {
  for (const manifest of manifests.filter(selected)) {
    if (manifest.unresolved.length === 0) continue;
    process.stdout.write(
      `${manifest.key} 有 ${manifest.unresolved.length} 条未决（--apply 会拒绝这份）：\n`
    );
    for (const item of manifest.unresolved) {
      if (item.proposal === undefined) {
        process.stdout.write(`- ${item.question}\n`);
      } else {
        process.stdout.write(
          `- ${item.question} → 推荐：${item.proposal}（影响：${item.affects}）\n`
        );
      }
    }
  }
}

function returnedIssueNumbers(value) {
  if (!Array.isArray(value)) return [];
  return value.map((item) => {
    if (Number.isInteger(item)) return item;
    const nested = item && (item.blocked_by_issue || item.issue || item.blocked_by);
    return Number(item && (item.number !== undefined ? item.number : nested && nested.number));
  }).filter((number) => Number.isInteger(number) && number > 0);
}

function verifyPublication() {
  const problems = [];
  for (const manifest of manifests.filter(selected)) {
    const spec = manifest.record.issues[manifest.key];
    if (!spec) {
      problems.push(`${manifest.key} has no published spec number`);
      continue;
    }
    const actual = new Set(returnedIssueNumbers(JSON.parse(
      ghApi(`repos/${repo}/issues/${spec.number}/sub_issues?per_page=100`)
    )));
    for (const ticket of manifest.tickets) {
      const issue = manifest.record.issues[ticket.key];
      if (issue && !actual.has(issue.number)) {
        problems.push(`规格 #${spec.number} 缺子票 #${issue.number}`);
      }
    }
  }
  for (const manifest of manifests.filter(selected)) {
    for (const ticket of manifest.tickets) {
      const dependent = manifest.record.issues[ticket.key];
      if (!dependent) continue;
      const actual = new Set(returnedIssueNumbers(JSON.parse(
        ghApi(`repos/${repo}/issues/${dependent.number}/dependencies/blocked_by?per_page=100`)
      )));
      for (const raw of ticket.blockedBy) {
        const reference = resolveReference(raw, manifest, 'verify dependency');
        const blocker = reference && referenceNumber(reference);
        if (blocker && !actual.has(blocker.number)) {
          problems.push(
            `执行票 #${dependent.number} 缺阻塞 #${blocker.number}`
          );
        }
      }
    }
  }
  if (problems.length === 0) {
    process.stdout.write('核对：子票与阻塞关系都对上了\n');
    return true;
  }
  for (const problem of unique(problems)) process.stdout.write(`${problem}\n`);
  return false;
}

function printIssues() {
  for (const manifest of manifests.filter(selected)) {
    const spec = manifest.record.issues[manifest.key];
    process.stdout.write(
      `${manifest.key} ${spec ? `#${spec.number}` : '未建'} ${manifest.title}\n`
    );
    for (const ticket of manifest.tickets) {
      const issue = manifest.record.issues[ticket.key];
      process.stdout.write(
        `${manifest.key}/${ticket.key} ${issue ? `#${issue.number}` : '未建'} ${ticket.title}\n`
      );
    }
  }
}

function patchIssue(manifest, key, number, body) {
  const relation = relationKey('patch', manifest.key, key);
  if (manifest.record.relations.includes(relation)) return;
  ghApi(`repos/${repo}/issues/${number}`, 'PATCH', [['-f', `body=${body}`]]);
  manifest.record.issues[key].patchPending = false;
  rememberRelation(manifest, relation);
}

function applyBatch(graph) {
  const pendingPatches = [];
  prepareExistingSpecRecords();
  for (const manifest of manifests.filter(selected)) {
    let issue = manifest.record.issues[manifest.key];
    if (!issue) {
      const body = renderBody(manifest.body, manifest);
      issue = createIssue(
        manifest, manifest.key, manifest.title, body, manifest.labels, 'spec'
      );
      if (hasPlaceholder(body)) pendingPatches.push({manifest, key: manifest.key});
    } else if (issue.patchPending) {
      pendingPatches.push({manifest, key: manifest.key});
    }
  }

  for (const id of graph.order) {
    const node = graph.nodes.get(id);
    const {manifest, ticket} = node;
    if (!selected(manifest)) continue;
    let issue = manifest.record.issues[ticket.key];
    if (!issue) {
      const body = renderBody(ticket.body, manifest);
      issue = createIssue(
        manifest, ticket.key, ticket.title, body, ticket.labels, 'ticket'
      );
      if (hasPlaceholder(body)) pendingPatches.push({manifest, key: ticket.key});
    } else if (issue.patchPending) {
      pendingPatches.push({manifest, key: ticket.key});
    }
    attachTicket(manifest, ticket);
    for (const blocker of ticket.blockedBy) addDependency(manifest, ticket, blocker);
  }

  const patchKeys = new Set();
  for (const item of pendingPatches) {
    const identity = `${item.manifest.key}/${item.key}`;
    if (patchKeys.has(identity)) continue;
    patchKeys.add(identity);
    const body = item.key.startsWith('T')
      ? item.manifest.tickets.find((ticket) => ticket.key === item.key).body
      : item.manifest.body;
    const issue = item.manifest.record.issues[item.key];
    const rendered = renderBody(body, item.manifest);
    if (hasPlaceholder(rendered)) {
      fail(`internal error: unresolved placeholder remains in ${identity}`);
    }
    patchIssue(item.manifest, item.key, issue.number, rendered);
  }

  sendHandoffs();
  const verified = verifyPublication();
  printIssues();
  const specs = manifests.filter(selected)
    .filter((manifest) => manifest.existingSpec === undefined).length;
  const tickets = manifests.filter(selected)
    .reduce((total, manifest) => total + manifest.tickets.length, 0);
  process.stdout.write(`已发布 ${specs} 张规格、${tickets} 张执行票\n`);
  if (!verified) fail('publication verification failed');
}

function prepareExistingSpecRecords() {
  for (const manifest of manifests.filter(selected)) {
    if (manifest.existingSpec === undefined) continue;
    const foreignChildren = checkExistingSpecChildren(manifest);
    if (foreignChildren.length > 0) {
      fail(`manifest ${manifest.key}: existing spec #${manifest.existingSpec} already has sub-issues: ${foreignChildren.map((number) => `#${number}`).join('、')}`);
    }
    if (manifest.existingSpecRecordPending) {
      saveRecord(manifest);
      manifest.existingSpecRecordPending = false;
    }
  }
}

if (mode !== 'run') {
  process.stderr.write(`publish-batch: internal error: unknown node mode ${mode}\n`);
  process.exit(70);
}

try {
  loadManifests();
  validateReferences();
  const graph = validateTicketGraph();
  if (errors.length > 0) {
    fail(`validation failed:\n- ${unique(errors).join('\n- ')}`);
  }
  validateExistingIssues();
  if (errors.length > 0) {
    fail(`validation failed:\n- ${unique(errors).join('\n- ')}`);
  }
  if (apply) applyBatch(graph);
  else printDryRun(graph);
} catch (error) {
  fail(error.message);
}
NODE
}

export PUBLISH_SCRIPT=$0
if ! publish_node run "$REPO" "$APPLY" "$ONLY" -- "${MANIFESTS[@]}"; then
  die "batch publication failed"
fi

if [ "$APPLY" -eq 1 ]; then
  case "$0" in
    */*) PUBLISH_SCRIPT_SOURCE=$0 ;;
    *) PUBLISH_SCRIPT_SOURCE=$(command -v -- "$0") ||
         die "could not resolve the publish script path" ;;
  esac
  PUBLISH_SCRIPT_DIR=$(cd -- "${PUBLISH_SCRIPT_SOURCE%/*}" && pwd) ||
    die "could not resolve the publish script directory"
  SKILL_ROOT=$(cd -- "$PUBLISH_SCRIPT_DIR/.." && pwd) ||
    die "could not resolve the skill root"
  PIPELINE_STATUS=${ISS_PIPELINE_STATUS:-$SKILL_ROOT/scripts/pipeline-status.sh}
  if ! "$PIPELINE_STATUS" --order --repo "$REPO"; then
    printf 'publish-batch: pipeline-status.sh --order failed; published issues were not changed by this failure\n' >&2
  fi
fi
