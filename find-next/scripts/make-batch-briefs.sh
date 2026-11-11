#!/usr/bin/env bash
# Generate one drafting Brief per spec group for find-next --batch.

set -u

usage() {
  cat <<'EOF'
Usage: make-batch-briefs.sh [--repo <owner/name>] --example <issue>
                            [--note S<k>=<file>]... [--force]
                            <run-directory> S1=62 S2=63,64...

Generate <run-directory>/S<k>/brief.md from the batch Brief template. Tickets
in one group must have the same parent issue (the wayfinder map). Existing
brief.md files are rejected unless --force is passed.
EOF
}

die() {
  printf 'make-batch-briefs: %s\n' "$1" >&2
  exit 1
}

gh_current_repo() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

gh_issue_view() {
  gh issue view "$1" --repo "$REPO" --json "$2"
}

REPO=
EXAMPLE=
FORCE=0
RUN_DIR=
GROUP_KEYS=()
GROUP_TICKETS=()
NOTE_KEYS=()
NOTE_FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo requires <owner/name>"
      REPO=$2
      shift 2
      ;;
    --example)
      [ $# -ge 2 ] || die "--example requires an existing spec issue number"
      EXAMPLE=$2
      shift 2
      ;;
    --note)
      [ $# -ge 2 ] || die "--note requires S<k>=<file>"
      case "$2" in
        S*=*) ;;
        *) die "--note must have the form S<k>=<file>" ;;
      esac
      NOTE_KEYS+=("${2%%=*}")
      NOTE_FILES+=("${2#*=}")
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        if [ -z "$RUN_DIR" ]; then
          RUN_DIR=$1
        else
          GROUP_KEYS+=("${1%%=*}")
          GROUP_TICKETS+=("${1#*=}")
        fi
        shift
      done
      ;;
    -*)
      usage >&2
      die "unknown argument: $1"
      ;;
    *)
      if [ -z "$RUN_DIR" ]; then
        RUN_DIR=$1
      else
        GROUP_KEYS+=("${1%%=*}")
        GROUP_TICKETS+=("${1#*=}")
      fi
      shift
      ;;
  esac
done

[ -n "$RUN_DIR" ] || die "a run directory is required"
[ "${#GROUP_KEYS[@]}" -gt 0 ] || die "at least one S<k>=<ticket,...> group is required"
[[ "$EXAMPLE" =~ ^[1-9][0-9]*$ ]] || die "--example must be an issue number without #"
if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "--repo must be <owner/name>"
fi

SEEN_KEYS=()
SEEN_TICKETS=()
index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  key=${GROUP_KEYS[$index]}
  ticket_list=${GROUP_TICKETS[$index]}
  [[ "$key" =~ ^S[1-9][0-9]*$ ]] || die "group key must be S<number>: $key"
  [[ "$ticket_list" != "$key" ]] || die "group $key must be S<number>=<ticket,...>"
  seen_index=0
  while [ "$seen_index" -lt "${#SEEN_KEYS[@]}" ]; do
    [ "${SEEN_KEYS[$seen_index]}" != "$key" ] || die "duplicate group key: $key"
    seen_index=$((seen_index + 1))
  done
  SEEN_KEYS+=("$key")

  IFS=, read -r -a tickets <<< "$ticket_list"
  [ "${#tickets[@]}" -gt 0 ] || die "group $key has no tickets"
  group_seen=()
  for ticket in "${tickets[@]}"; do
    [[ "$ticket" =~ ^[1-9][0-9]*$ ]] || die "group $key has an invalid ticket number: $ticket"
    seen_index=0
    while [ "$seen_index" -lt "${#group_seen[@]}" ]; do
      [ "${group_seen[$seen_index]}" != "$ticket" ] ||
        die "group $key repeats ticket #$ticket"
      seen_index=$((seen_index + 1))
    done
    seen_index=0
    while [ "$seen_index" -lt "${#SEEN_TICKETS[@]}" ]; do
      [ "${SEEN_TICKETS[$seen_index]}" != "$ticket" ] ||
        die "ticket #$ticket appears in more than one group"
      seen_index=$((seen_index + 1))
    done
    group_seen+=("$ticket")
    SEEN_TICKETS+=("$ticket")
  done
  index=$((index + 1))
done

note_index=0
while [ "$note_index" -lt "${#NOTE_KEYS[@]}" ]; do
  key=${NOTE_KEYS[$note_index]}
  file=${NOTE_FILES[$note_index]}
  [[ "$key" =~ ^S[1-9][0-9]*$ ]] || die "note key must be S<number>: $key"
  [ -n "$file" ] || die "note $key has an empty file path"
  [ -f "$file" ] || die "note file for $key was not found: $file"
  [ -r "$file" ] || die "note file for $key is not readable: $file"
  seen_index=0
  while [ "$seen_index" -lt "${#NOTE_KEYS[@]}" ]; do
    if [ "$seen_index" -ne "$note_index" ] &&
       [ "${NOTE_KEYS[$seen_index]}" = "$key" ]; then
      die "duplicate note key: $key"
    fi
    seen_index=$((seen_index + 1))
  done
  found=0
  for seen in "${GROUP_KEYS[@]}"; do
    if [ "$seen" = "$key" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || die "note key has no group: $key"
  note_index=$((note_index + 1))
done

command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"
command -v git >/dev/null 2>&1 || die "git is required but was not found on PATH"
command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"

REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "the current directory is not inside a git repository"
[ -n "$REPO_PATH" ] || die "git rev-parse returned an empty repository path"

if [ -z "$REPO" ]; then
  REPO=$(gh_current_repo) || die "could not detect the GitHub repository with gh repo view"
  [ -n "$REPO" ] || die "gh repo view returned an empty repository name"
fi

GROUP_ISSUES=()
GROUP_MAPS=()
GROUP_MAP_JSON=()
MAP_CACHE_KEYS=()
MAP_CACHE_JSON=()

issue_parent() {
  ISSUE_JSON=$1
  printf '%s' "$ISSUE_JSON" | node -e '
    let value;
    try {
      value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    } catch (error) {
      process.exit(1);
    }
    const parent = value && value.parent && value.parent.number;
    if (!Number.isInteger(parent) || parent <= 0) process.exit(1);
    process.stdout.write(String(parent));
  ' || return 1
}

index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  key=${GROUP_KEYS[$index]}
  ticket_list=${GROUP_TICKETS[$index]}
  IFS=, read -r -a tickets <<< "$ticket_list"
  group_map=
  group_issues=
  for ticket in "${tickets[@]}"; do
    issue_json=$(gh_issue_view "$ticket" number,title,parent) ||
      die "could not read issue #$ticket with gh issue view"
    ticket_map=$(issue_parent "$issue_json") ||
      die "issue #$ticket in group $key has no parent map"
    if [ -z "$group_map" ]; then
      group_map=$ticket_map
    elif [ "$group_map" != "$ticket_map" ]; then
      die "group $key has tickets with different parent maps: #$group_map and #$ticket_map"
    fi
    group_issues+="${group_issues:+$'\037'}$issue_json"
  done

  map_json=
  cache_index=0
  while [ "$cache_index" -lt "${#MAP_CACHE_KEYS[@]}" ]; do
    if [ "${MAP_CACHE_KEYS[$cache_index]}" = "$group_map" ]; then
      map_json=${MAP_CACHE_JSON[$cache_index]}
      break
    fi
    cache_index=$((cache_index + 1))
  done
  if [ -z "$map_json" ]; then
    map_json=$(gh_issue_view "$group_map" title) ||
      die "could not read map #$group_map with gh issue view"
    MAP_CACHE_KEYS+=("$group_map")
    MAP_CACHE_JSON+=("$map_json")
  fi

  GROUP_ISSUES+=("$group_issues")
  GROUP_MAPS+=("$group_map")
  GROUP_MAP_JSON+=("$map_json")
  index=$((index + 1))
done

case "$0" in
  */*) SCRIPT_SOURCE=$0 ;;
  *) SCRIPT_SOURCE=$(command -v -- "$0") || die "could not resolve the script path" ;;
esac
SCRIPT_DIR=$(cd -- "${SCRIPT_SOURCE%/*}" && pwd) || die "could not resolve the script directory"
TEMPLATE=$SCRIPT_DIR/../templates/brief-spec-batch.md
[ -f "$TEMPLATE" ] || die "Brief template was not found: $TEMPLATE"
[ -r "$TEMPLATE" ] || die "Brief template is not readable: $TEMPLATE"
SKILLS_ROOT=${FIND_NEXT_SKILLS_ROOT:-$HOME/.claude/plugins/cache/mattpocock/mattpocock-skills}
[ -d "$SKILLS_ROOT" ] || die "skills root was not found: $SKILLS_ROOT"

index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  key=${GROUP_KEYS[$index]}
  brief=$RUN_DIR/$key/brief.md
  if [ -e "$brief" ] && [ "$FORCE" -ne 1 ]; then
    die "brief already exists (use --force to replace it): $brief"
  fi
  index=$((index + 1))
done

set -- "$TEMPLATE" "$REPO_PATH" "$REPO" "$EXAMPLE" "$RUN_DIR" "$SKILLS_ROOT"
index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  set -- "$@" --group "${GROUP_KEYS[$index]}" "${GROUP_TICKETS[$index]}" \
    "${GROUP_ISSUES[$index]}" "${GROUP_MAPS[$index]}" "${GROUP_MAP_JSON[$index]}"
  index=$((index + 1))
done
note_index=0
while [ "$note_index" -lt "${#NOTE_KEYS[@]}" ]; do
  set -- "$@" --note "${NOTE_KEYS[$note_index]}" "${NOTE_FILES[$note_index]}"
  note_index=$((note_index + 1))
done

node - "$@" <<'NODE'
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const [templatePath, repoPath, repo, example, runDir, skillsRoot] = argv;
const groups = [];
const notes = new Map();
for (let index = 0; index < argv.length; index++) {
  if (argv[index] !== '--group' && argv[index] !== '--note') continue;
  if (argv[index] === '--group') {
    groups.push({
      key: argv[++index],
      ticketArgument: argv[++index],
      issuesArgument: argv[++index],
      mapArgument: argv[++index],
      mapJsonArgument: argv[++index],
    });
  } else {
    notes.set(argv[++index], argv[++index]);
  }
}

function fail(message) {
  process.stderr.write(`make-batch-briefs: ${message}\n`);
  process.exit(1);
}

function versionParts(name) {
  const match = /^v?(\d+(?:\.\d+)*)(?:[-+].*)?$/.exec(name);
  return match ? match[1].split('.').map(Number) : null;
}

function compareVersions(left, right) {
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index++) {
    const a = left[index] || 0;
    const b = right[index] || 0;
    if (a !== b) return a - b;
  }
  return 0;
}

function latestSkill(skillName) {
  let bestDirectory;
  let bestVersion;
  for (const entry of fs.readdirSync(skillsRoot, {withFileTypes: true})) {
    if (!entry.isDirectory()) continue;
    const version = versionParts(entry.name);
    if (!version) continue;
    const skillPath = path.join(
      skillsRoot, entry.name, 'skills', 'engineering', skillName, 'SKILL.md');
    if (!fs.existsSync(skillPath)) continue;
    if (!bestVersion ||
        compareVersions(version, bestVersion) > 0 ||
        (compareVersions(version, bestVersion) === 0 && entry.name > bestDirectory)) {
      bestDirectory = entry.name;
      bestVersion = version;
    }
  }
  if (!bestDirectory) {
    fail(`could not find the latest engineering/${skillName}/SKILL.md under ${skillsRoot}`);
  }
  return path.join(
    skillsRoot, bestDirectory, 'skills', 'engineering', skillName, 'SKILL.md');
}

const toSpec = latestSkill('to-spec');
const toTickets = latestSkill('to-tickets');

const parsedGroups = [];
for (const group of groups) {
  const ticketNumbers = group.ticketArgument.split(',');
  const issueRecords = group.issuesArgument
    .split('\u001f')
    .filter(value => value !== '')
    .map(value => {
      try {
        return JSON.parse(value);
      } catch (error) {
        fail(`could not parse the gh issue view result for group ${group.key}`);
      }
    });
  if (issueRecords.length !== ticketNumbers.length) {
    fail(`gh returned ${issueRecords.length} issues for ${ticketNumbers.length} tickets`);
  }

  let mapTitle;
  try {
    mapTitle = JSON.parse(group.mapJsonArgument).title;
  } catch (error) {
    mapTitle = undefined;
  }
  if (typeof mapTitle !== 'string' || mapTitle === '') {
    fail(`map #${group.mapArgument} has no title`);
  }

  const tickets = issueRecords.map((issue, index) => {
    const expected = Number(ticketNumbers[index]);
    if (!Number.isInteger(issue.number) || issue.number !== expected) {
      fail(`gh returned issue #${issue.number} where #${expected} was expected`);
    }
    if (typeof issue.title !== 'string' || issue.title === '') {
      fail(`issue #${expected} has no title`);
    }
    const parent = issue.parent && issue.parent.number;
    if (!Number.isInteger(parent) || parent <= 0) {
      fail(`issue #${expected} has no parent map`);
    }
    if (String(parent) !== group.mapArgument) {
      fail(`issue #${expected} has parent #${parent}, not #${group.mapArgument}`);
    }
    return {number: issue.number, title: issue.title};
  });

  let noteContent = '';
  if (notes.has(group.key)) {
    try {
      noteContent = fs.readFileSync(notes.get(group.key), 'utf8');
    } catch (error) {
      fail(`could not read the note for ${group.key}: ${error.message}`);
    }
  }
  parsedGroups.push({
    key: group.key,
    map: Number(group.mapArgument),
    mapTitle,
    tickets,
    noteContent,
    dir: path.resolve(runDir, group.key),
  });
}
for (const key of notes.keys()) {
  if (!parsedGroups.some(group => group.key === key)) {
    fail(`note key has no group: ${key}`);
  }
}

function replaceAll(text, name, value) {
  return text.split(`@@${name}@@`).join(String(value));
}

function ticketNumbers(tickets) {
  return tickets.map(ticket => `#${ticket.number}`).join('、');
}

function ticketList(tickets) {
  return tickets.map(ticket => `#${ticket.number}「${ticket.title}」`).join('、');
}

const groupLines = parsedGroups.map(group =>
  `- ${group.key} · 地图 #${group.map} · 覆盖 ${ticketList(group.tickets)}`).join('\n');

let template;
try {
  template = fs.readFileSync(templatePath, 'utf8');
} catch (error) {
  fail(`could not read the Brief template: ${error.message}`);
}
template = template.replace(/^\s*<!--[\s\S]*?-->\s*/, '');

const renderedGroups = [];
for (const group of parsedGroups) {
  let output = template;
  const values = new Map([
    ['REPO_PATH', repoPath],
    ['REPO', repo],
    ['MAP', group.map],
    ['MAP_TITLE', group.mapTitle],
    ['EXAMPLE', example],
    ['KEY', group.key],
    ['GROUP_DIR', group.dir],
    ['TO_SPEC', toSpec],
    ['TO_TICKETS', toTickets],
    ['TICKET_NUMS', ticketNumbers(group.tickets)],
    ['TICKETS', ticketList(group.tickets)],
    ['GROUPS', groupLines],
  ]);
  for (const [name, value] of values) {
    output = replaceAll(output, name, value);
  }
  const notesText = group.noteContent === ''
    ? ''
    : `\n## 本组补充\n\n${group.noteContent}\n`;
  output = replaceAll(output, 'NOTES', notesText);
  const leftover = /@@[A-Z_]+@@/.exec(output);
  if (leftover) fail(`Brief for ${group.key} still has variable ${leftover[0]}`);
  renderedGroups.push({group, output});
}

for (const {group} of renderedGroups) {
  const briefPath = path.join(group.dir, 'brief.md');
  if (fs.existsSync(briefPath)) {
    fail(`brief already exists (use --force to replace it): ${briefPath}`);
  }
}
for (const {group, output} of renderedGroups) {
  try {
    fs.mkdirSync(group.dir, {recursive: true});
    fs.writeFileSync(path.join(group.dir, 'brief.md'), output);
  } catch (error) {
    fail(`could not write ${group.dir}/brief.md: ${error.message}`);
  }
}
for (const {group} of renderedGroups) {
  const briefPath = path.join(group.dir, 'brief.md');
  console.log(briefPath);
  console.log(
    `~/.claude/skills/implement-spec-split/scripts/codex-worker.sh ` +
    `--cwd ${repoPath} --brief ${briefPath} --run-dir ${group.dir} ` +
    `--read-only --time-limit 2400 --idle-timeout 600`);
}
NODE
