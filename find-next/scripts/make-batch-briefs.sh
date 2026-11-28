#!/usr/bin/env bash
# Generate one drafting Brief per spec group for find-next --batch.

set -u

usage() {
  cat <<'EOF'
Usage: make-batch-briefs.sh [--repo <owner/name>] --example <issue>
                            [--note S<k>=<file>]... [--force]
                            <run-directory> S1=62 S2=63,64...
                                                   S3=spec:224...
                                                   S4=map:41...
                                                   S5=loose:51,52...

Generate <run-directory>/S<k>/brief.md from the batch Brief template. Tickets
in one group must have the same parent issue (the wayfinder map). A group of
the form S<k>=spec:<issue> drafts execution tickets for that already-existing
spec instead of creating a new spec. A group of the form S<k>=map:<issue>
drafts one map-level spec and its execution tickets; --example is optional and
is needed only when an existing spec can serve as the style reference. A group
of the form S<k>=loose:<issue,...> drafts one spec and its execution tickets
from loose tickets that belong to no map (their numbers become the spec's
实现票 line). Existing brief.md files are rejected unless --force is passed.
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
GROUP_MODES=()
NOTE_KEYS=()
NOTE_FILES=()
SEEN_MAPS=()

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
[ "${#GROUP_KEYS[@]}" -gt 0 ] || die "at least one S<k>=<group> argument is required"
[ -z "$EXAMPLE" ] || [[ "$EXAMPLE" =~ ^[1-9][0-9]*$ ]] ||
  die "--example must be an issue number without #"
if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "--repo must be <owner/name>"
fi

SEEN_KEYS=()
SEEN_TICKETS=()
SEEN_EXISTING_SPECS=()
index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  key=${GROUP_KEYS[$index]}
  ticket_argument=${GROUP_TICKETS[$index]}
  [[ "$key" =~ ^S[1-9][0-9]*$ ]] || die "group key must be S<number>: $key"
  [[ "$ticket_argument" != "$key" ]] ||
    die "group $key must be S<number>=<ticket,...>, S<number>=spec:<issue>, S<number>=map:<issue>, or S<number>=loose:<issue,...>"
  seen_index=0
  while [ "$seen_index" -lt "${#SEEN_KEYS[@]}" ]; do
    [ "${SEEN_KEYS[$seen_index]}" != "$key" ] || die "duplicate group key: $key"
    seen_index=$((seen_index + 1))
  done
  SEEN_KEYS+=("$key")

  if [[ "$ticket_argument" == spec:* ]]; then
    spec_number=${ticket_argument#spec:}
    [[ "$spec_number" =~ ^[1-9][0-9]*$ ]] ||
      die "group $key has an invalid existing spec number: $spec_number"
    seen_index=0
    while [ "$seen_index" -lt "${#SEEN_EXISTING_SPECS[@]}" ]; do
      [ "${SEEN_EXISTING_SPECS[$seen_index]}" != "$spec_number" ] ||
        die "existing spec #$spec_number appears in more than one group"
      seen_index=$((seen_index + 1))
    done
    seen_index=0
    while [ "$seen_index" -lt "${#SEEN_TICKETS[@]}" ]; do
      [ "${SEEN_TICKETS[$seen_index]}" != "$spec_number" ] ||
        die "existing spec #$spec_number also appears as an implementation ticket"
      seen_index=$((seen_index + 1))
    done
    SEEN_EXISTING_SPECS+=("$spec_number")
    GROUP_MODES+=("existing-spec")
  elif [[ "$ticket_argument" == map:* ]]; then
    map_number=${ticket_argument#map:}
    [[ "$map_number" =~ ^[1-9][0-9]*$ ]] ||
      die "group $key has an invalid map number: $map_number"
    seen_index=0
    while [ "$seen_index" -lt "${#SEEN_MAPS[@]}" ]; do
      [ "${SEEN_MAPS[$seen_index]}" != "$map_number" ] ||
        die "map #$map_number appears in more than one map group"
      seen_index=$((seen_index + 1))
    done
    SEEN_MAPS+=("$map_number")
    GROUP_MODES+=("map")
  else
    group_mode=tickets
    ticket_list_argument=$ticket_argument
    if [[ "$ticket_argument" == loose:* ]]; then
      group_mode=loose
      ticket_list_argument=${ticket_argument#loose:}
    fi
    IFS=, read -r -a tickets <<< "$ticket_list_argument"
    [ "${#tickets[@]}" -gt 0 ] || die "group $key has no tickets"
    group_seen=()
    for ticket in "${tickets[@]}"; do
      [[ "$ticket" =~ ^[1-9][0-9]*$ ]] ||
        die "group $key has an invalid ticket number: $ticket"
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
      seen_index=0
      while [ "$seen_index" -lt "${#SEEN_EXISTING_SPECS[@]}" ]; do
        [ "${SEEN_EXISTING_SPECS[$seen_index]}" != "$ticket" ] ||
          die "implementation ticket #$ticket also appears as an existing spec"
        seen_index=$((seen_index + 1))
      done
      group_seen+=("$ticket")
      SEEN_TICKETS+=("$ticket")
    done
    GROUP_MODES+=("$group_mode")
  fi
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
GROUP_SPEC_JSON=()
GROUP_NUMBERS=()
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

existing_spec_facts() {
  printf '%s' "$1" | node -e '
    let value;
    try {
      value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    } catch (_) {
      process.exit(1);
    }
    const body = String(value && value.body || "");
    const hasProblemStatement = /^[ \t]*## Problem Statement[ \t\r]*$/m.test(body);
    process.stdout.write(`${String(value && value.state || "").toLowerCase()}\n${hasProblemStatement ? 1 : 0}\n`);
  '
}

existing_spec_implementation_numbers() {
  printf '%s' "$1" | node -e '
    let value;
    try {
      value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    } catch (_) {
      process.exit(1);
    }
    const numbers = new Set();
    const body = String(value && value.body || "");
    const linkPattern = /^[ \t]*实现票\s*[：:][ \t]*#[1-9][0-9]*(?:\s*(?:[,，、和]|and)\s*#[1-9][0-9]*)*/gm;
    for (const lineMatch of body.matchAll(linkPattern)) {
      for (const match of lineMatch[0].matchAll(/#([1-9][0-9]*)/g)) {
        numbers.add(match[1]);
      }
    }
    for (const number of numbers) console.log(number);
  '
}

existing_spec_map_numbers() {
  printf '%s' "$1" | node -e '
    let value;
    try {
      value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    } catch (_) {
      process.exit(1);
    }
    const numbers = new Set();
    const body = String(value && value.body || "");
    const linePattern = /^[ \t]*(?:[-*][ \t]+)?(?:\*\*[ \t]*)?(?:(?:来源)?地图|Map)[ \t]*(?:\*\*)?[ \t]*[：:][ \t]*(?:\*\*)?[ \t]*#([1-9][0-9]*)(?![0-9])/im;
    for (const line of body.split(/\r?\n/)) {
      const match = linePattern.exec(line);
      if (match) numbers.add(Number(match[1]));
    }
    for (const number of [...numbers].sort((a, b) => a - b)) console.log(number);
  '
}

map_facts() {
  printf '%s' "$1" | node -e '
    let value;
    try {
      value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    } catch (_) {
      process.exit(1);
    }
    process.stdout.write(String(value && value.state || "").toLowerCase());
  '
}

gh_sub_issue_count() {
  gh api "repos/$REPO/issues/$1/sub_issues" --jq length
}

index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  key=${GROUP_KEYS[$index]}
  ticket_argument=${GROUP_TICKETS[$index]}
  group_map=
  group_issues=
  group_spec_json=
  group_numbers=

  if [ "${GROUP_MODES[$index]}" = "existing-spec" ]; then
    spec_number=${ticket_argument#spec:}
    group_spec_json=$(gh_issue_view "$spec_number" number,title,state,body) ||
      die "could not read existing spec #$spec_number with gh issue view"
    spec_facts=$(existing_spec_facts "$group_spec_json") ||
      die "could not parse existing spec #$spec_number"
    spec_state=${spec_facts%%$'\n'*}
    spec_has_heading=${spec_facts##*$'\n'}
    [ "$spec_state" = "open" ] ||
      die "existing spec #$spec_number is not open (state: $spec_state)"
    [ "$spec_has_heading" = "1" ] ||
      die "existing spec #$spec_number has no ## Problem Statement section"
    sub_issue_count=$(gh_sub_issue_count "$spec_number") ||
      die "could not read sub-issues of existing spec #$spec_number"
    [[ "$sub_issue_count" =~ ^[0-9]+$ ]] ||
      die "gh returned an invalid sub-issue count for existing spec #$spec_number"
    [ "$sub_issue_count" -eq 0 ] ||
      die "existing spec #$spec_number already has sub-issues"

    implementation_numbers=$(existing_spec_implementation_numbers "$group_spec_json") ||
      die "could not parse the implementation ticket links of existing spec #$spec_number"
    impl_numbers=${implementation_numbers//$'\n'/,}
    IFS=, read -r -a tickets <<< "$impl_numbers"
    group_numbers=$impl_numbers
    if [ "${#tickets[@]}" -eq 0 ]; then
      map_numbers=$(existing_spec_map_numbers "$group_spec_json") ||
        die "could not parse the map links of existing spec #$spec_number"
      if [ -n "$map_numbers" ]; then
        group_map=${map_numbers%%$'\n'*}
      else
        printf 'make-batch-briefs: existing spec #%s has neither a 实现票： line nor a 地图：/来源地图： line; drafting it as a hand-written spec without a map\n' "$spec_number" >&2
      fi
    fi
  elif [ "${GROUP_MODES[$index]}" = "map" ]; then
    group_map=${ticket_argument#map:}
    tickets=()
  elif [ "${GROUP_MODES[$index]}" = "loose" ]; then
    IFS=, read -r -a tickets <<< "${ticket_argument#loose:}"
    group_numbers=${ticket_argument#loose:}
  else
    IFS=, read -r -a tickets <<< "$ticket_argument"
    group_numbers=$ticket_argument
  fi

  if [ "${GROUP_MODES[$index]}" != "map" ] && [ "${#tickets[@]}" -gt 0 ]; then
    for ticket in "${tickets[@]}"; do
      if [ "${GROUP_MODES[$index]}" = "existing-spec" ]; then
        seen_index=0
        while [ "$seen_index" -lt "${#SEEN_TICKETS[@]}" ]; do
          [ "${SEEN_TICKETS[$seen_index]}" != "$ticket" ] ||
            die "implementation ticket #$ticket appears in more than one group"
          seen_index=$((seen_index + 1))
        done
      fi
      issue_json=$(gh_issue_view "$ticket" number,title,parent) ||
        die "could not read issue #$ticket with gh issue view"
      if [ "${GROUP_MODES[$index]}" = "loose" ]; then
        # A loose source ticket belongs to no map; one with a parent is a map
        # implementation ticket and belongs in a S<k>=<ticket,...> group.
        if ticket_map=$(issue_parent "$issue_json"); then
          die "issue #$ticket in loose group $key has parent #$ticket_map; pass map implementation tickets as $key=$ticket"
        fi
      else
        ticket_map=$(issue_parent "$issue_json") ||
          die "issue #$ticket in group $key has no parent map"
        if [ -z "$group_map" ]; then
          group_map=$ticket_map
        elif [ "$group_map" != "$ticket_map" ]; then
          die "group $key has tickets with different parent maps: #$group_map and #$ticket_map"
        fi
      fi
      group_issues+="${group_issues:+$'\037'}$issue_json"
      if [ "${GROUP_MODES[$index]}" = "existing-spec" ]; then
        SEEN_TICKETS+=("$ticket")
      fi
    done
  fi

  map_json=
  cache_index=0
  while [ "$cache_index" -lt "${#MAP_CACHE_KEYS[@]}" ]; do
    if [ "${MAP_CACHE_KEYS[$cache_index]}" = "$group_map" ]; then
      map_json=${MAP_CACHE_JSON[$cache_index]}
      break
    fi
    cache_index=$((cache_index + 1))
  done
  if [ -z "$map_json" ] && [ -n "$group_map" ]; then
    map_json=$(gh_issue_view "$group_map" number,title,state) ||
      die "could not read map #$group_map with gh issue view"
    MAP_CACHE_KEYS+=("$group_map")
    MAP_CACHE_JSON+=("$map_json")
  fi
  if [ "${GROUP_MODES[$index]}" = "map" ]; then
    map_state=$(map_facts "$map_json") ||
      die "could not parse map #$group_map"
    [ "$map_state" = "open" ] ||
      die "map #$group_map is not open (state: $map_state)"
  fi

  GROUP_ISSUES+=("$group_issues")
  GROUP_MAPS+=("$group_map")
  GROUP_MAP_JSON+=("$map_json")
  GROUP_SPEC_JSON+=("$group_spec_json")
  GROUP_NUMBERS+=("$group_numbers")
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
TICKETS_TEMPLATE=$SCRIPT_DIR/../templates/brief-tickets-batch.md
[ -f "$TICKETS_TEMPLATE" ] || die "Brief template was not found: $TICKETS_TEMPLATE"
[ -r "$TICKETS_TEMPLATE" ] || die "Brief template is not readable: $TICKETS_TEMPLATE"
MAP_TEMPLATE=$SCRIPT_DIR/../templates/brief-map-spec-batch.md
[ -f "$MAP_TEMPLATE" ] || die "Brief template was not found: $MAP_TEMPLATE"
[ -r "$MAP_TEMPLATE" ] || die "Brief template is not readable: $MAP_TEMPLATE"
LOOSE_TEMPLATE=$SCRIPT_DIR/../templates/brief-loose-spec-batch.md
[ -f "$LOOSE_TEMPLATE" ] || die "Brief template was not found: $LOOSE_TEMPLATE"
[ -r "$LOOSE_TEMPLATE" ] || die "Brief template is not readable: $LOOSE_TEMPLATE"
SKILLS_ROOT=${FIND_NEXT_SKILLS_ROOT:-$HOME/.claude/plugins/cache/mattpocock/mattpocock-skills}
[ -d "$SKILLS_ROOT" ] || die "skills root was not found: $SKILLS_ROOT"

set -- "$TEMPLATE" "$TICKETS_TEMPLATE" "$MAP_TEMPLATE" "$LOOSE_TEMPLATE" "$REPO_PATH" "$REPO" "$EXAMPLE" \
  "$RUN_DIR" "$SKILLS_ROOT"
if [ "$FORCE" -eq 1 ]; then
  set -- "$@" --force
fi
index=0
while [ "$index" -lt "${#GROUP_KEYS[@]}" ]; do
  set -- "$@" --group "${GROUP_KEYS[$index]}" "${GROUP_NUMBERS[$index]}" \
    "${GROUP_MODES[$index]}" "${GROUP_ISSUES[$index]}" "${GROUP_MAPS[$index]}" \
    "${GROUP_MAP_JSON[$index]}" "${GROUP_SPEC_JSON[$index]}"
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
const [
  templatePath, ticketsTemplatePath, mapTemplatePath, looseTemplatePath, repoPath, repo,
  example, runDir, skillsRoot,
] = argv;
const force = argv.includes('--force');
const groups = [];
const notes = new Map();
for (let index = 0; index < argv.length; index++) {
  if (argv[index] !== '--group' && argv[index] !== '--note') continue;
  if (argv[index] === '--group') {
    groups.push({
      key: argv[++index],
      // Comma-joined ticket numbers the shell looked up; empty when the group has none.
      numbersArgument: argv[++index],
      mode: argv[++index],
      issuesArgument: argv[++index],
      mapArgument: argv[++index],
      mapJsonArgument: argv[++index],
      specJsonArgument: argv[++index],
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
  const existingSpecMode = group.mode === 'existing-spec';
  const mapMode = group.mode === 'map';
  const looseMode = group.mode === 'loose';
  // An existing Spec hangs under a map through its 实现票 line or its 地图： line;
  // a hand-written Spec has neither, and the shell passes an empty mapArgument for it.
  const hasMap = group.mapArgument !== '';
  if (!existingSpecMode && !mapMode && !looseMode && group.mode !== 'tickets') {
    fail(`internal error: unknown group mode ${group.mode}`);
  }
  const ticketNumbers = group.numbersArgument === ''
    ? []
    : group.numbersArgument.split(',');
  const expectedIssues = ticketNumbers.length;
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
  if (issueRecords.length !== expectedIssues) {
    fail(`gh returned ${issueRecords.length} issues for ${expectedIssues} tickets`);
  }

  let mapTitle = null;
  if (hasMap) {
    try {
      mapTitle = JSON.parse(group.mapJsonArgument).title;
    } catch (error) {
      mapTitle = undefined;
    }
    if (typeof mapTitle !== 'string' || mapTitle === '') {
      fail(`map #${group.mapArgument} has no title`);
    }
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
    const hasParent = Number.isInteger(parent) && parent > 0;
    // A loose group takes tickets that belong to no map; every other group
    // takes map implementation tickets, all of the group's one map.
    if (!looseMode && !hasParent) fail(`issue #${expected} has no parent map`);
    if (looseMode && hasParent) fail(`issue #${expected} has parent #${parent}, not a loose ticket`);
    if (!looseMode && String(parent) !== group.mapArgument) {
      fail(`issue #${expected} has parent #${parent}, not #${group.mapArgument}`);
    }
    return {number: issue.number, title: issue.title};
  });

  let existingSpec = null;
  let existingSpecTitle = '';
  if (existingSpecMode) {
    let spec;
    try {
      spec = JSON.parse(group.specJsonArgument);
    } catch (error) {
      fail(`could not parse the gh issue view result for group ${group.key}`);
    }
    existingSpec = Number(spec.number);
    existingSpecTitle = String(spec.title || '');
    if (!Number.isInteger(existingSpec) || existingSpec <= 0) {
      fail(`existing spec for group ${group.key} has no issue number`);
    }
    if (existingSpecTitle === '') {
      fail(`existing spec #${existingSpec} has no title`);
    }
  }

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
    map: hasMap ? Number(group.mapArgument) : null,
    mapTitle,
    mode: group.mode,
    tickets,
    existingSpec,
    existingSpecTitle,
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

function mapReference(group) {
  return `地图 #${group.map}「${group.mapTitle}」`;
}

function mapGuidanceLine(group) {
  return `- 必要时读${mapReference(group)}（\`gh issue view ${group.map} --comments\`）和相关代码，只为了确认拆分边界、测试切入点、已有可复用模块和命名习惯。`;
}

// The three form-specific sentences of the existing-spec Brief (Spec linked through an
// 实现票 line, Spec linked through a 地图： line, hand-written Spec with neither). Every
// form gets a true sentence, so no variable renders empty.
function existingSpecLines(group) {
  if (group.tickets.length > 0) {
    return {
      origin: `它覆盖${mapReference(group)}下的实现票 ${ticketList(group.tickets)}。`,
      ticketsLine: `- 实现票本身：\`gh issue view <n> --comments\`（逐张读 ${ticketNumbers(group.tickets)}），确认规格没有漏掉它们正文里的验收要求。实现票指向的已关闭决策票，若规格没有吸收结论，按未决处理，不要自行补规格。`,
      mapLine: mapGuidanceLine(group),
    };
  }
  if (group.map !== null) {
    return {
      origin: `它不挂在任何地图实现票下，正文用「地图：」/「来源地图：」行指回${mapReference(group)}。`,
      ticketsLine: '- 这份规格没有「实现票：」行，没有地图实现票可读；拆票只以规格正文和下面的地图为依据，不要去找实现票。',
      mapLine: mapGuidanceLine(group),
    };
  }
  return {
    origin: '它没有地图实现票（没挂地图的手写规格），只读规格正文与相关代码。',
    ticketsLine: '- 这份规格没有「实现票：」行，也没有「地图：」/「来源地图：」行，没有地图实现票可读；拆票只以规格正文为依据，不要去找实现票。',
    mapLine: '- 没有地图可读；相关代码按需读，只为了确认拆分边界、测试切入点、已有可复用模块和命名习惯。',
  };
}

const groupLines = parsedGroups.map(group => {
  if (group.mode === 'map') {
    return `- ${group.key}：地图 #${group.map} ${group.mapTitle}（地图级规格）`;
  }
  if (group.mode === 'loose') {
    return `- ${group.key} · 散票 ${ticketList(group.tickets)}`;
  }
  return group.existingSpec === null
    ? `- ${group.key} · 地图 #${group.map} · 覆盖 ${ticketList(group.tickets)}`
    : `- ${group.key}：已有规格 #${group.existingSpec} ${group.existingSpecTitle}（只拆票）`;
}).join('\n');

let template;
try {
  template = fs.readFileSync(templatePath, 'utf8');
} catch (error) {
  fail(`could not read the Brief template: ${error.message}`);
}
template = template.replace(/^\s*<!--[\s\S]*?-->\s*/, '');

let ticketsTemplate;
try {
  ticketsTemplate = fs.readFileSync(ticketsTemplatePath, 'utf8');
} catch (error) {
  fail(`could not read the Brief template: ${error.message}`);
}
ticketsTemplate = ticketsTemplate.replace(/^\s*<!--[\s\S]*?-->\s*/, '');

let mapTemplate;
try {
  mapTemplate = fs.readFileSync(mapTemplatePath, 'utf8');
} catch (error) {
  fail(`could not read the Brief template: ${error.message}`);
}
mapTemplate = mapTemplate.replace(/^\s*<!--[\s\S]*?-->\s*/, '');

let looseTemplate;
try {
  looseTemplate = fs.readFileSync(looseTemplatePath, 'utf8');
} catch (error) {
  fail(`could not read the Brief template: ${error.message}`);
}
looseTemplate = looseTemplate.replace(/^\s*<!--[\s\S]*?-->\s*/, '');

const exampleGuidance = example
  ? `- 风格参考：本仓库已有的一份规格和它的执行票 #${example}（\`gh issue view ${example}\`，执行票用 \`gh api repos/${repo}/issues/${example}/sub_issues\` 列出）。执行票标题沿用仓库已有标题的格式（看 #${example} 的执行票和地图下的实现票，包括前缀和冒号的全角半角）。`
  : `- 风格参考：仓库里还没有规格。执行票标题参考地图下已有票的标题格式（包括前缀和冒号的全角半角）。`;

const renderedGroups = [];
for (const group of parsedGroups) {
  let output = group.mode === 'map'
    ? mapTemplate
    : group.mode === 'loose'
      ? looseTemplate
      : (group.existingSpec === null ? template : ticketsTemplate);
  const values = new Map([
    ['REPO_PATH', repoPath],
    ['REPO', repo],
    ['MAP', group.map],
    ['MAP_TITLE', group.mapTitle],
    ['EXAMPLE_GUIDANCE', exampleGuidance],
    ['KEY', group.key],
    ['GROUP_DIR', group.dir],
    ['TO_SPEC', toSpec],
    ['TO_TICKETS', toTickets],
    ['TICKET_NUMS', ticketNumbers(group.tickets)],
    ['TICKETS', ticketList(group.tickets)],
    ['GROUPS', groupLines],
  ]);
  if (group.existingSpec !== null) {
    values.set('SPEC_NUM', group.existingSpec);
    values.set('SPEC_TITLE', group.existingSpecTitle);
    const lines = existingSpecLines(group);
    values.set('SPEC_ORIGIN', lines.origin);
    values.set('TICKETS_LINE', lines.ticketsLine);
    values.set('MAP_LINE', lines.mapLine);
  }
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
  if (!force && fs.existsSync(briefPath)) {
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
