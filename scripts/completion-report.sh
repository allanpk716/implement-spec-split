#!/usr/bin/env bash
# Completion conclusion for a repository's grill topics: the current topic's
# progress, repository-wide topic status, a release recommendation, tickets a
# release would unfreeze, and interrupted grill sessions. When --spec belongs
# to no grill topic, the first line is that Spec's own landing conclusion and
# repository-wide status comes from pipeline-status.sh --graph (open Specs and
# the ready tickets that belong to no Spec or map); whether anyone is working
# on such a Spec comes from claim.sh status: an active or interrupted claim
# overrides the graph's status, a free claim leaves it as the graph has it.
# Read-only: it never tags and never pushes. claim.sh status creates an empty
# .git/implement-spec-split/claims/ when that directory does not exist yet;
# nothing else is written, --run-dir aside: what its verify writes stays
# inside the run directory it is given (the model it read, in each sidecar).
#
# --run-dir <dir> names the Spec's run directory (the Spec Run root, where
# scripts/stage-dispatch.sh keeps its sidecars) and makes the report end with
# what `stage-dispatch.sh verify --run-dir <dir>` prints: the Stage route table
# (the six stages, as the table's display command shows it) and one check line
# per Orca worker of the Run, its route model against the model actually read
# off its terminal — a mismatch as a warning, never a failed report (票 #47).
# A verify that fails (a run directory that is not there, no node) is one
# （查询失败） line: the report itself is never lost over it. Without --run-dir
# the report is as it was.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GRILL_STATUS=$HERE/grill-status.sh
PIPELINE_STATUS=$HERE/pipeline-status.sh
CLAIM_SH=$HERE/claim.sh
STAGE_DISPATCH=$HERE/stage-dispatch.sh

usage() {
  cat <<'USAGE'
Usage: completion-report.sh [<repo dir>] [--spec <n>] [--notify] [--run-dir <dir>]

Print a fixed-format Chinese completion conclusion: the current grill topic's
progress (--spec), repository-wide topic status, whether to tag a release (with
a suggested version and reasons), tickets that a release would unfreeze, and
interrupted grill sessions. When --spec belongs to no grill topic, the first
line states that Spec's own landing (landed, or partly landed with the tickets
still waiting for other Specs), open Specs are listed one per line, and only
ready tickets that belong to no Spec or map count as loose tickets; those
relations come from pipeline-status.sh --graph. --notify sends exactly one
notification when the --spec topic is complete; COMPLETION_NOTIFY_CMD overrides
the default osascript command and receives the title and body as two arguments.
--run-dir, the Spec's run directory, ends the report with the Stage route table
and stage-dispatch.sh verify's check lines (each Orca worker's route model
against the model it actually ran on); a verify that fails is one （查询失败）
line and the report stands.
USAGE
}

warn() {
  printf 'completion-report: %s\n' "$1" >&2
}

usage_error() {
  printf 'completion-report: %s\n' "$1" >&2
  usage >&2
  exit 64
}

REPO_ARG=
SPEC_ARG=
NOTIFY=false
RUN_DIR=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --spec)
      [ -n "${2:-}" ] || usage_error '--spec needs a positive integer'
      [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage_error '--spec needs a positive integer'
      SPEC_ARG=$2
      shift 2
      ;;
    --run-dir)
      [ -n "${2:-}" ] || usage_error '--run-dir needs a directory'
      RUN_DIR=$2
      shift 2
      ;;
    --notify)
      NOTIFY=true
      shift
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      [ -z "$REPO_ARG" ] || usage_error "unknown extra argument: $1"
      REPO_ARG=$1
      shift
      ;;
  esac
done

command -v git >/dev/null 2>&1 || usage_error 'git is required but was not found on PATH'
command -v gh >/dev/null 2>&1 || usage_error 'gh is required but was not found on PATH'
[ -x "$GRILL_STATUS" ] || usage_error "grill-status.sh not found: $GRILL_STATUS"

REPO_ROOT=$(git -C "${REPO_ARG:-.}" rev-parse --show-toplevel 2>/dev/null) ||
  usage_error 'run this script from a git repository, or pass a repository directory'
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
REPO_NAME=${ORIGIN_URL##*/}
REPO_NAME=${REPO_NAME%.git}
REPO_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
[ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$REPO_ROOT")

# ---------------------------------------------------------------- grill data

GRILL_FAILED=false
TSV=$(bash "$GRILL_STATUS" --tsv "$REPO_ROOT" 2>/dev/null) || {
  TSV=''
  GRILL_FAILED=true
}

RUN_NAMES=()
RUN_KINDS=()
RUN_TIMES=()
RUN_STATUSES=()
RUN_TITLES=()
RUN_SPECS=()
RUN_OPENS=()
if [ -n "$TSV" ]; then
  while IFS=$'\t' read -r rn rk rt rs rtitle rspecs ropen; do
    [ -n "${rn:-}" ] || continue
    RUN_NAMES+=("$rn")
    RUN_KINDS+=("${rk:-}")
    RUN_TIMES+=("${rt:-}")
    RUN_STATUSES+=("${rs:-}")
    RUN_TITLES+=("${rtitle:-}")
    RUN_SPECS+=("${rspecs:-}")
    RUN_OPENS+=("${ropen:-}")
  done <<EOF
$TSV
EOF
fi

TOPIC_COUNT=${#RUN_NAMES[@]}

# ------------------------------------------------------------------ gh data

SPEC_DB='
'
SPEC_QUERY_JQ='[.state, .title, (.sub_issues_summary.completed // 0), (.sub_issues_summary.total // 0), (.closed_at // ""), ((.assignees // []) | length)] | @tsv'
query_spec() {
  local n=$1 fields
  fields=$( (
    cd "$REPO_ROOT" &&
      gh api "repos/{owner}/{repo}/issues/$n" --jq "$SPEC_QUERY_JQ"
  ) 2>/dev/null) || fields=''
  if [ -z "$fields" ]; then
    SPEC_DB=$(printf '%s\n%s\tFAILED\t（查询失败）\t0\t0\t\t0' "$SPEC_DB" "$n")
  else
    SPEC_DB=$(printf '%s\n%s\t%s' "$SPEC_DB" "$n" "$fields")
  fi
}

spec_field() {
  local n=$1 field=$2
  awk -F '\t' -v n="$n" -v field="$field" '$1 == n { print $field; exit }' <<EOF
$SPEC_DB
EOF
}

ALL_SPECS=()
has_spec() {
  local n=$1 s
  for s in ${ALL_SPECS[@]+"${ALL_SPECS[@]}"}; do
    [ "$s" = "$n" ] && return 0
  done
  return 1
}
index=0
while [ "$index" -lt "$TOPIC_COUNT" ]; do
  [ -n "${RUN_SPECS[$index]}" ] || { index=$((index + 1)); continue; }
  IFS=',' read -ra spec_array <<<"${RUN_SPECS[$index]}"
  for n in ${spec_array[@]+"${spec_array[@]}"}; do
    [ -n "$n" ] || continue
    has_spec "$n" || ALL_SPECS+=("$n")
  done
  index=$((index + 1))
done
for n in ${ALL_SPECS[@]+"${ALL_SPECS[@]}"}; do
  query_spec "$n"
done

EXCLUDED='
'
mark_excluded() {
  EXCLUDED=$(printf '%s\n%s' "$EXCLUDED" "$1")
}
is_excluded() {
  printf '%s\n' "$EXCLUDED" | grep -Fxq -- "$1"
}
for n in ${ALL_SPECS[@]+"${ALL_SPECS[@]}"}; do
  mark_excluded "$n"
  subs=$( (
    cd "$REPO_ROOT" &&
      gh api "repos/{owner}/{repo}/issues/$n/sub_issues" --jq '.[].number'
  ) 2>/dev/null) || subs=''
  for s in $subs; do
    mark_excluded "$s"
  done
done

# A --spec outside every grill topic gets its own conclusion below; whether or
# not the graph knows it, keep it and its tickets out of the loose tickets.
if [ -n "$SPEC_ARG" ] && ! has_spec "$SPEC_ARG"; then
  query_spec "$SPEC_ARG"
  mark_excluded "$SPEC_ARG"
  subs=$( (
    cd "$REPO_ROOT" &&
      gh api "repos/{owner}/{repo}/issues/$SPEC_ARG/sub_issues" --jq '.[].number'
  ) 2>/dev/null) || subs=''
  for s in $subs; do
    mark_excluded "$s"
  done
fi

RFA_FAILED=false
RFA_RAW=$( (
  cd "$REPO_ROOT" &&
    gh issue list --state open --label ready-for-agent \
      --json number,title --limit 1000 --jq '.[] | [.number, .title] | @tsv'
) 2>/dev/null) || RFA_FAILED=true

TIMING_FAILED=false
TIMING_JQ='.[] | [.number, .title, ((.body // "") | split("\n") | map(select(test("^\\s*([-*]\\s+)?(\\*\\*)?时机\\s*[:：]"))) | map(sub("^\\s*([-*]\\s+)?(\\*\\*)?时机\\s*[:：]\\s*"; "") | sub("\\*\\*$"; "") | .[0:120]) | first // "")] | @tsv'
TIMING_RAW=$( (
  cd "$REPO_ROOT" &&
    gh issue list --state open --json number,title,body --limit 1000 \
      --jq "$TIMING_JQ"
) 2>/dev/null) || TIMING_FAILED=true
if [ -n "$TIMING_RAW" ]; then
  TIMING_RAW=$(printf '%s\n' "$TIMING_RAW" | sort -n)
fi

line_field() {
  printf '%s' "$1" | awk -F '\t' -v f="$2" '{ print $f }'
}

RELEASE_TIMING_LINES=()
OTHER_TIMING_LINES=()
TIMING_NUMBERS='
'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$(line_field "$line" 1)
  condition=$(line_field "$line" 3)
  [ -n "$condition" ] || continue
  TIMING_NUMBERS=$(printf '%s\n%s' "$TIMING_NUMBERS" "$n")
  if printf '%s' "$condition" | grep -Eqi '发版|发布|tag|版本'; then
    RELEASE_TIMING_LINES+=("$line")
  else
    OTHER_TIMING_LINES+=("$line")
  fi
done <<EOF
$TIMING_RAW
EOF

# ---------------------------------------------------------------- graph data
# Spec, ticket and map relations come from pipeline-status.sh --graph; this
# script does not re-derive them. When the graph cannot be read the report
# says （查询失败） for the parts that need it and carries on.

read -r -d '' GRAPH_NODE <<'NODE' || true
const fs = require('fs');
let graph;
try {
  graph = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (error) {
  process.exit(1);
}
if (!graph || typeof graph !== 'object') process.exit(1);
const clean = (value) => String(value == null ? '' : value).replace(/[\r\n\t]+/g, ' ').trim();
const csv = (list) => (Array.isArray(list) ? list.map(Number).filter((n) => Number.isFinite(n)) : []).join(',');
const lines = [];
const partial = new Set();
const wave = graph.next_wave && Array.isArray(graph.next_wave.wave) ? graph.next_wave.wave : [];
for (const entry of wave) {
  if (entry && /部分等/.test(String(entry.note || ''))) partial.add(Number(entry.spec));
}
for (const spec of Array.isArray(graph.specs) ? graph.specs : []) {
  if (!spec) continue;
  lines.push(['spec', Number(spec.number), spec.state, spec.status,
    Number(spec.tickets_total || 0), Number(spec.tickets_closed || 0),
    csv(spec.depends_on), csv(spec.extra_blockers),
    partial.has(Number(spec.number)) ? 1 : 0, clean(spec.title)].join('\t'));
  for (const ticket of Array.isArray(spec.tickets) ? spec.tickets : []) {
    if (!ticket) continue;
    lines.push(['ticket', Number(ticket.number), Number(spec.number), ticket.state,
      ticket.shelved ? 1 : 0].join('\t'));
  }
}
for (const map of Array.isArray(graph.maps) ? graph.maps : []) {
  if (!map) continue;
  for (const ticket of Array.isArray(map.tickets) ? map.tickets : []) {
    if (ticket) lines.push(['mapticket', Number(ticket.number), Number(map.number)].join('\t'));
  }
}
process.stdout.write(lines.length ? `${lines.join('\n')}\n` : '');
NODE

GRAPH_FAILED=false
GRAPH_JSON=
if [ -x "$PIPELINE_STATUS" ] && command -v node >/dev/null 2>&1; then
  if ! GRAPH_JSON=$( (
    cd "$REPO_ROOT" && bash "$PIPELINE_STATUS" --graph
  ) 2>/dev/null); then
    GRAPH_JSON=
    GRAPH_FAILED=true
  fi
else
  GRAPH_FAILED=true
fi
GRAPH_TSV=
if [ "$GRAPH_FAILED" = false ]; then
  if ! GRAPH_TSV=$(printf '%s\n' "$GRAPH_JSON" | node -e "$GRAPH_NODE" 2>/dev/null); then
    GRAPH_TSV=
    GRAPH_FAILED=true
  fi
fi
GRAPH_JSON=

TAB=$'\t'
GRAPH_SPEC_ROWS=()
GRAPH_TICKET_ROWS=()
GRAPH_MAP_TICKET_ROWS=()
if [ "$GRAPH_FAILED" = false ]; then
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      "spec$TAB"*) GRAPH_SPEC_ROWS+=("${row#spec$TAB}") ;;
      "ticket$TAB"*) GRAPH_TICKET_ROWS+=("${row#ticket$TAB}") ;;
      "mapticket$TAB"*) GRAPH_MAP_TICKET_ROWS+=("${row#mapticket$TAB}") ;;
    esac
  done <<EOF
$GRAPH_TSV
EOF
fi
GRAPH_TSV=

graph_spec_row() { # spec number → its graph row, or nothing
  local n=$1 row
  for row in ${GRAPH_SPEC_ROWS[@]+"${GRAPH_SPEC_ROWS[@]}"}; do
    [ "$(line_field "$row" 1)" = "$n" ] && {
      printf '%s' "$row"
      return 0
    }
  done
  return 1
}

graph_is_spec() {
  graph_spec_row "$1" >/dev/null 2>&1
}

graph_ticket_owner() { # ticket number → the Spec that owns it, or nothing
  local n=$1 row
  for row in ${GRAPH_TICKET_ROWS[@]+"${GRAPH_TICKET_ROWS[@]}"}; do
    [ "$(line_field "$row" 1)" = "$n" ] && {
      printf '%s' "$(line_field "$row" 2)"
      return 0
    }
  done
  return 1
}

if [ "$GRAPH_FAILED" = false ]; then
  for row in ${GRAPH_SPEC_ROWS[@]+"${GRAPH_SPEC_ROWS[@]}"}; do
    mark_excluded "$(line_field "$row" 1)"
  done
  for row in ${GRAPH_TICKET_ROWS[@]+"${GRAPH_TICKET_ROWS[@]}"}; do
    mark_excluded "$(line_field "$row" 1)"
  done
  for row in ${GRAPH_MAP_TICKET_ROWS[@]+"${GRAPH_MAP_TICKET_ROWS[@]}"}; do
    mark_excluded "$(line_field "$row" 1)"
  done
fi

STRAY_LINES=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$(line_field "$line" 1)
  is_excluded "$n" && continue
  printf '%s\n' "$TIMING_NUMBERS" | grep -Fxq -- "$n" && continue
  STRAY_LINES+=("$line")
done <<EOF
$RFA_RAW
EOF

# ----------------------------------------------------------------- git data

git -C "$REPO_ROOT" fetch --tags origin >/dev/null 2>&1 || true
DEFAULT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
if [ -z "$DEFAULT_BRANCH" ]; then
  if git -C "$REPO_ROOT" rev-parse -q --verify origin/main >/dev/null 2>&1; then
    DEFAULT_BRANCH=main
  elif git -C "$REPO_ROOT" rev-parse -q --verify origin/master >/dev/null 2>&1; then
    DEFAULT_BRANCH=master
  fi
fi
TAG=
UNPUBLISHED=
TAG_EPOCH=
if [ -n "$DEFAULT_BRANCH" ]; then
  TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "origin/$DEFAULT_BRANCH" 2>/dev/null || true)
  if [ -n "$TAG" ]; then
    UNPUBLISHED=$(git -C "$REPO_ROOT" rev-list --count "$TAG..origin/$DEFAULT_BRANCH" 2>/dev/null || true)
    TAG_EPOCH=$(git -C "$REPO_ROOT" log -1 --format=%ct "$TAG" 2>/dev/null || true)
  fi
fi

iso_epoch() {
  local iso=$1 epoch stripped
  [ -n "$iso" ] || return 0
  epoch=$(date -u -d "$iso" +%s 2>/dev/null || true)
  if [ -z "$epoch" ] || ! printf '%s' "$epoch" | grep -Eq '^[0-9]+$'; then
    stripped=${iso%Z}
    epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$stripped" +%s 2>/dev/null || true)
  fi
  [ -n "$epoch" ] && printf '%s' "$epoch"
  return 0
}

GIT_COMMON=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
CLAIM_DIR=
if [ -n "$GIT_COMMON" ] && (cd "$GIT_COMMON" >/dev/null 2>&1); then
  CLAIM_DIR=$(cd "$GIT_COMMON" 2>/dev/null && pwd)/implement-spec-split/claims
fi

spec_claimed() {
  local n=$1 assignees
  if [ -n "$CLAIM_DIR" ] && [ -f "$CLAIM_DIR/spec-$n.json" ]; then
    return 0
  fi
  assignees=$(spec_field "$n" 7)
  [ "$assignees" = 0 ] && return 1
  [ -n "$assignees" ] && [ "$assignees" != FAILED ]
}

# What claim.sh status says about a Spec: active (its claim record is alive,
# i.e. the holder pid still has its recorded start time or the handoff
# reservation has not expired), interrupted (its exact (spec-N) or old-style
# (spec-N-<role>, excluding -t<n>/-fix*) branch exists but the record is dead)
# or free. Empty when the state could not be read.
spec_claim_state() {
  local n=$1 state
  [ -x "$CLAIM_SH" ] || return 0
  state=$( (
    cd "$REPO_ROOT" && bash "$CLAIM_SH" status "$n"
  ) 2>/dev/null) || return 0
  printf '%s' "${state%% *}"
}

# -------------------------------------------------------------- formatting

join_lines() {
  local sep=$1 out= line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$out" ]; then
      out="$out$sep$line"
    else
      out="$line"
    fi
  done
  printf '%s' "$out"
}

display_title() {
  local title=$1
  if [ "${#title}" -gt 60 ]; then
    title="${title:0:60}…"
  fi
  printf '%s' "$title"
}

topic_display() {
  local title
  title=$(display_title "$1")
  if [[ "$title" =~ ^(地图[[:space:]]*#[0-9]+)（(.*)）$ ]]; then
    printf '%s《%s》' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '《%s》' "$title"
  fi
}

spec_progress_text() {
  local n=$1 state completed total
  state=$(spec_field "$n" 2)
  if [ "$state" = FAILED ]; then
    printf '#%s （查询失败）' "$n"
    return
  fi
  completed=$(spec_field "$n" 4)
  total=$(spec_field "$n" 5)
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  if [ "$total" -eq 0 ]; then
    printf '#%s' "$n"
  else
    printf '#%s 票 %s/%s' "$n" "$completed" "$total"
  fi
}

topic_specs() {
  local index=$1
  IFS=',' read -ra t_specs <<<"${RUN_SPECS[$index]}"
  printf '%s\n' ${t_specs[@]+"${t_specs[@]}"}
}

topic_has_spec() {
  local index=$1 wanted=$2 n
  [ -n "${RUN_SPECS[$index]}" ] || return 1
  while IFS= read -r n; do
    [ "$n" = "$wanted" ] && return 0
  done < <(topic_specs "$index")
  return 1
}

topic_specs_after_tag() {
  local index=$1 n closed_at epoch
  [ -n "$TAG_EPOCH" ] || return 1
  while IFS= read -r n; do
    closed_at=$(spec_field "$n" 6)
    [ -n "$closed_at" ] || continue
    epoch=$(iso_epoch "$closed_at")
    [ -n "$epoch" ] || continue
    [ "$epoch" -gt "$TAG_EPOCH" ] && return 0
  done < <(topic_specs "$index")
  return 1
}

format_numbers() { # "19,20" → "#19、#20"
  printf '%s' "$1" | sed 's/^/#/; s/,/、#/g'
}

ticket_open_blockers() { # ticket number → comma-separated numbers of its open blockers
  local t=$1 out
  out=$( (
    cd "$REPO_ROOT" &&
      gh api "repos/{owner}/{repo}/issues/$t/dependencies/blocked_by" \
        --jq '.[] | select(.state == "open") | .number'
  ) 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s' "$out" | tr '\n' ',' | sed 's/,$//'
}

blocker_owner() { # issue number → the Spec that owns it, else the number itself
  local b=$1 owner
  owner=$(graph_ticket_owner "$b" 2>/dev/null || true)
  if [ -z "$owner" ] && graph_is_spec "$b"; then
    owner=$b
  fi
  printf '%s' "${owner:-$b}"
}

# analyze_remaining <comma-separated open ticket numbers>: what those tickets
# wait for, per ticket. Sets REMAINING_TEXT and returns 0 when every remaining
# ticket waits on something outside its own Spec ("#28、#29 等 #19；#33 等
# #20"), 1 when at least one can be worked on now (REMAINING_TEXT lists the
# tickets), 2 when the blocker query failed.
analyze_remaining() {
  local tickets=$1 t blockers b owner owners key i found
  local keys=() groups=() waiting=true parts=()
  REMAINING_TEXT=
  for t in $(printf '%s' "$tickets" | tr ',' ' '); do
    [ -n "$t" ] || continue
    if ! blockers=$(ticket_open_blockers "$t"); then
      return 2
    fi
    owners=
    for b in $(printf '%s' "$blockers" | tr ',' ' '); do
      [ -n "$b" ] || continue
      owner=$(blocker_owner "$b")
      [ "$owner" = "$SPEC_ARG" ] && continue
      owners="$owners $owner"
    done
    owners=$(printf '%s\n' $owners | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
    [ -n "$owners" ] || waiting=false
    found=-1
    i=0
    for key in ${keys[@]+"${keys[@]}"}; do
      if [ "$key" = "$owners" ]; then
        found=$i
        break
      fi
      i=$((i + 1))
    done
    if [ "$found" -lt 0 ]; then
      keys+=("$owners")
      groups+=("#$t")
    else
      groups[$found]="${groups[$found]}、#$t"
    fi
  done
  if [ "$waiting" != true ]; then
    REMAINING_TEXT=$(format_numbers "$tickets")
    return 1
  fi
  i=0
  for key in ${keys[@]+"${keys[@]}"}; do
    parts+=("${groups[$i]} 等 $(format_numbers "$key")")
    i=$((i + 1))
  done
  REMAINING_TEXT=$(printf '%s\n' "${parts[@]}" | join_lines '；')
  return 0
}

# The first line of the report for a --spec that belongs to no grill topic.
spec_conclusion() {
  local n=$1 row= state= status= total=0 closed=0 deps= extras= title= gh_state
  local progress= label= remaining= shelved= rc=0 wait_text=
  row=$(graph_spec_row "$n" 2>/dev/null || true)
  gh_state=$(spec_field "$n" 2)
  if [ -n "$row" ]; then
    state=$(line_field "$row" 2)
    status=$(line_field "$row" 3)
    total=$(line_field "$row" 4)
    closed=$(line_field "$row" 5)
    deps=$(line_field "$row" 6)
    extras=$(line_field "$row" 7)
    title=$(display_title "$(line_field "$row" 9)")
  elif [ "$gh_state" = open ] || [ "$gh_state" = closed ]; then
    state=$gh_state
    total=$(spec_field "$n" 5)
    closed=$(spec_field "$n" 4)
    title=$(display_title "$(spec_field "$n" 3)")
  else
    printf '⚠️ 规格 #%s（查询失败）' "$n"
    return 0
  fi
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$closed" in ''|*[!0-9]*) closed=0 ;; esac
  label="规格 #$n $title"
  [ "$total" -gt 0 ] && progress="票 $closed/$total"
  [ "$status" = interrupted ] && [ -n "$progress" ] && progress="${progress}，实现中断待恢复"
  if [ "$state" != closed ] && [ "$status" = shelved ]; then
    printf '🟡 规格 #%s 已搁置%s' "$n" "${progress:+（${progress}）}"
    return 0
  fi
  if [ "$state" = closed ]; then
    printf '✅ %s 已落地%s' "$label" "${progress:+（${progress}）}"
    return 0
  fi
  if [ "$total" -gt 0 ] && [ "$closed" -ge "$total" ]; then
    printf '✅ %s 已落地（%s，issue 还没关）' "$label" "$progress"
    return 0
  fi
  if [ "$total" -eq 0 ]; then
    printf '🟡 规格 #%s 还没拆票' "$n"
    return 0
  fi
  remaining=
  shelved=
  for row in ${GRAPH_TICKET_ROWS[@]+"${GRAPH_TICKET_ROWS[@]}"}; do
    [ "$(line_field "$row" 2)" = "$n" ] || continue
    [ "$(line_field "$row" 3)" = open ] || continue
    if [ "$(line_field "$row" 4)" = 1 ]; then
      shelved="$shelved,$(line_field "$row" 1)"
    else
      remaining="$remaining,$(line_field "$row" 1)"
    fi
  done
  remaining=${remaining#,}
  shelved=${shelved#,}
  if [ -n "$shelved" ]; then
    wait_text="剩 $(format_numbers "$shelved")（搁置）"
    [ -n "$remaining" ] && wait_text="${wait_text}、$(format_numbers "$remaining") 待实现"
    printf '🟡 规格 #%s 还开着（%s）：%s' "$n" "$progress" "$wait_text"
    return 0
  fi
  if [ -z "$remaining" ]; then
    # Without graph rows only the counts are known.
    printf '🟡 规格 #%s 还开着（%s）：剩 %s 张票' "$n" "$progress" "$((total - closed))"
    return 0
  fi
  analyze_remaining "$remaining"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$closed" -gt 0 ]; then
      printf '🟡 规格 #%s 部分落地：剩 %s' "$n" "$REMAINING_TEXT"
    else
      printf '🟡 规格 #%s 还没开始（%s）：%s' "$n" "$progress" "$REMAINING_TEXT"
    fi
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    # Ticket blockers unreadable: fall back to the Spec-level dependencies.
    wait_text=
    [ -n "$deps" ] && wait_text="，等 $(format_numbers "$deps")"
    [ -n "$extras" ] && wait_text="${wait_text}，另需 $(format_numbers "$extras")"
    printf '🟡 规格 #%s 还开着（%s）：剩 %s%s' "$n" "$progress" \
      "$(format_numbers "$remaining")" "$wait_text"
    return 0
  fi
  printf '🟡 规格 #%s 还开着（%s）：剩 %s 待实现' "$n" "$progress" "$REMAINING_TEXT"
  return 0
}

# graph spec row [status] → "#19 规格②…（实现中，票 4/5）" / "#20 规格③…（等 #19）".
# The optional status replaces the graph's: an active or interrupted claim
# overrides the graph, a free claim keeps the graph's status.
open_spec_text() {
  local row=$1 n status total closed deps extras partial title progress= wait_text= text=
  n=$(line_field "$row" 1)
  status=${2:-$(line_field "$row" 3)}
  total=$(line_field "$row" 4)
  closed=$(line_field "$row" 5)
  deps=$(line_field "$row" 6)
  extras=$(line_field "$row" 7)
  partial=$(line_field "$row" 8)
  title=$(display_title "$(line_field "$row" 9)")
  [ "$total" -gt 0 ] && progress="票 $closed/$total"
  if [ -n "$deps" ]; then
    if [ "$partial" = 1 ]; then
      wait_text="部分等 $(format_numbers "$deps")"
    else
      wait_text="等 $(format_numbers "$deps")"
    fi
  fi
  if [ -n "$extras" ]; then
    if [ -n "$wait_text" ]; then
      wait_text="${wait_text}；另需 $(format_numbers "$extras")"
    else
      wait_text="另需 $(format_numbers "$extras")"
    fi
  fi
  case "$status" in
    running) text=实现中 ;;
    interrupted) text=中断待恢复 ;;
    needs_tickets) text=还没拆票 ;;
    shelved) text=已搁置 ;;
    *)
      if [ -n "$wait_text" ]; then
        text=$wait_text
        wait_text=
        progress=
      else
        text=待开始
      fi
      ;;
  esac
  [ -n "$progress" ] && text="${text}，${progress}"
  [ -n "$wait_text" ] && text="${text}；${wait_text}"
  printf '⏳ #%s %s（%s）' "$n" "$title" "$text"
}

# ------------------------------------------------------------------- output

OUT=()

CURRENT_INDEX=-1
if [ -n "$SPEC_ARG" ]; then
  index=0
  while [ "$index" -lt "$TOPIC_COUNT" ]; do
    if topic_has_spec "$index" "$SPEC_ARG"; then
      CURRENT_INDEX=$index
    fi
    index=$((index + 1))
  done
fi

# A --spec outside every grill topic leads with its own conclusion.
if [ -n "$SPEC_ARG" ] && [ "$CURRENT_INDEX" -lt 0 ]; then
  OUT+=("$(spec_conclusion "$SPEC_ARG")")
fi

SHOW_REPO_BLOCK=true
SHOW_RELEASE=true
if [ "$GRILL_FAILED" = true ]; then
  OUT+=('⚠️ grill 题目进度（查询失败）')
  SHOW_REPO_BLOCK=false
  SHOW_RELEASE=false
fi

if [ "$CURRENT_INDEX" -ge 0 ]; then
  title=$(display_title "${RUN_TITLES[$CURRENT_INDEX]}")
  if [ "${RUN_STATUSES[$CURRENT_INDEX]}" = done ]; then
    parts=()
    while IFS= read -r n; do
      parts+=("$(spec_progress_text "$n")")
    done < <(topic_specs "$CURRENT_INDEX")
    OUT+=("✅ 你 grill 的《${title}》已全部完成（$(printf '%s\n' "${parts[@]}" | join_lines '、')）")
  else
    closed=0
    total=0
    while IFS= read -r n; do
      total=$((total + 1))
      state=$(spec_field "$n" 2)
      [ "$state" = closed ] && closed=$((closed + 1))
    done < <(topic_specs "$CURRENT_INDEX")
    OUT+=("🔵 你 grill 的《${title}》：进度 $closed/$total 份规格")
    while IFS= read -r n; do
      state=$(spec_field "$n" 2)
      spec_title=$(spec_field "$n" 3)
      completed=$(spec_field "$n" 4)
      total=$(spec_field "$n" 5)
      case "$total" in
        ''|*[!0-9]*) total=0 ;;
      esac
      if [ "$state" = closed ]; then
        OUT+=("   ✅ #$n $spec_title")
      elif [ "$state" = FAILED ]; then
        OUT+=("   ⏳ #$n （查询失败）")
      elif [ "$total" -eq 0 ]; then
        OUT+=("   ⏳ #$n $spec_title")
      else
        OUT+=("   ⏳ #$n ${spec_title}（票 $completed/${total}）")
      fi
    done < <(topic_specs "$CURRENT_INDEX")
    OUT+=('   → 不用做什么，等剩下的规格落地后会再告诉你。')
    SHOW_REPO_BLOCK=false
    SHOW_RELEASE=false
  fi
fi

ONGOING_PARTS=()
CLAIMED=false
ACTIVE_SPECS=() # the Specs someone is working on, for the release advice
HAS_OPEN_SPECS=false
OPEN_SPEC_COUNT=0
OPEN_SPEC_LINES=()
if [ "$SHOW_REPO_BLOCK" = true ]; then
  index=0
  while [ "$index" -lt "$TOPIC_COUNT" ]; do
    if [ "${RUN_STATUSES[$index]}" = ongoing ] &&
      { [ -z "$SPEC_ARG" ] || [ "$index" != "$CURRENT_INDEX" ]; }; then
      open_parts=()
      [ -n "${RUN_OPENS[$index]}" ] || RUN_OPENS[$index]=''
      IFS=',' read -ra open_specs <<<"${RUN_OPENS[$index]}"
      for n in ${open_specs[@]+"${open_specs[@]}"}; do
        [ -n "$n" ] || continue
        open_parts+=("$(spec_progress_text "$n")")
        if spec_claimed "$n"; then
          CLAIMED=true
          ACTIVE_SPECS+=("$n")
        fi
      done
      ONGOING_PARTS+=("   ⏳ $(topic_display "${RUN_TITLES[$index]}")：$(printf '%s\n' "${open_parts[@]}" | join_lines '、')")
    fi
    index=$((index + 1))
  done

  # Open Specs that belong to no grill topic: one line each, at most ten.
  # claim.sh status applies to every one of them: an active or interrupted
  # claim overrides whatever the graph says (human-only, shelved, needs_tickets
  # and ready alike), a free claim keeps the graph's status.
  if [ "$GRAPH_FAILED" = false ]; then
    for row in ${GRAPH_SPEC_ROWS[@]+"${GRAPH_SPEC_ROWS[@]}"}; do
      n=$(line_field "$row" 1)
      [ "$(line_field "$row" 2)" = closed ] && continue
      has_spec "$n" && continue
      [ "$n" = "$SPEC_ARG" ] && continue
      OPEN_SPEC_COUNT=$((OPEN_SPEC_COUNT + 1))
      status=$(line_field "$row" 3)
      case "$(spec_claim_state "$n")" in
        active) status=running ;;
        interrupted) status=interrupted ;;
      esac
      if [ "$status" = running ]; then
        CLAIMED=true
        ACTIVE_SPECS+=("$n")
      fi
      [ "$OPEN_SPEC_COUNT" -gt 10 ] && continue
      OPEN_SPEC_LINES+=("$(open_spec_text "$row" "$status")")
    done
  fi
  [ "$OPEN_SPEC_COUNT" -gt 0 ] && HAS_OPEN_SPECS=true

  stray_parts=()
  for line in ${STRAY_LINES[@]+"${STRAY_LINES[@]}"}; do
    stray_parts+=("#$(line_field "$line" 1) $(line_field "$line" 2)")
  done

  if [ "${#ONGOING_PARTS[@]}" -gt 0 ] || [ "$HAS_OPEN_SPECS" = true ] ||
    [ "${#stray_parts[@]}" -gt 0 ] || [ "$RFA_FAILED" = true ] || [ "$GRAPH_FAILED" = true ]; then
    if [ "$TOPIC_COUNT" -eq 0 ]; then
      OUT+=('（本仓库没有 grill 题目记录）')
    elif [ "${#ONGOING_PARTS[@]}" -eq 0 ] && [ "$HAS_OPEN_SPECS" = true ]; then
      OUT+=('✅ 仓库里所有 grill 的题目都已完成')
    fi
    if [ "${#ONGOING_PARTS[@]}" -gt 0 ]; then
      OUT+=("   仓库里还有 ${#ONGOING_PARTS[@]} 个题目没完成：")
      for part in ${ONGOING_PARTS[@]+"${ONGOING_PARTS[@]}"}; do
        OUT+=("$part")
      done
    fi
    if [ "$GRAPH_FAILED" = true ]; then
      OUT+=('   ⚠️ 仓库里还在进行的规格（查询失败）')
    elif [ "$HAS_OPEN_SPECS" = true ]; then
      OUT+=("   仓库里还在进行的规格（$OPEN_SPEC_COUNT 个）：")
      for part in ${OPEN_SPEC_LINES[@]+"${OPEN_SPEC_LINES[@]}"}; do
        OUT+=("      $part")
      done
      if [ "$OPEN_SPEC_COUNT" -gt "${#OPEN_SPEC_LINES[@]}" ]; then
        OUT+=("      另有 $((OPEN_SPEC_COUNT - ${#OPEN_SPEC_LINES[@]})) 个")
      fi
    fi
    if [ "${#stray_parts[@]}" -gt 0 ]; then
      if [ "$GRAPH_FAILED" = true ]; then
        OUT+=("   还有 ${#stray_parts[@]} 张就绪票（查询失败，未排除规格和子票）：$(printf '%s\n' "${stray_parts[@]}" | join_lines '、')")
      else
        OUT+=("   还有 ${#stray_parts[@]} 张不属于任何规格的散票：$(printf '%s\n' "${stray_parts[@]}" | join_lines '、')")
      fi
    fi
    if [ "$RFA_FAILED" = true ]; then
      OUT+=('   就绪票状态（查询失败）')
    fi
  elif [ "$TOPIC_COUNT" -eq 0 ]; then
    OUT+=('（本仓库没有 grill 题目记录）')
  else
    OUT+=('✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票')
  fi
fi

# ------------------------------------------------------------ release advice

UNFREEZE_SHOWN=false
if [ "$SHOW_RELEASE" = true ] && [ -n "$TAG" ]; then
  if [ -z "$UNPUBLISHED" ]; then
    OUT+=('👉 发版推荐（查询失败）')
  elif [ "$UNPUBLISHED" -eq 0 ]; then
    OUT+=("👉 当前代码已全部发布（${TAG}），无需发版")
  else
    other_work=false
    [ "${#ONGOING_PARTS[@]}" -gt 0 ] && other_work=true
    [ "${#STRAY_LINES[@]}" -gt 0 ] && other_work=true
    [ "$HAS_OPEN_SPECS" = true ] && other_work=true

    done_topics=()
    bump_minor=false
    index=0
    while [ "$index" -lt "$TOPIC_COUNT" ]; do
      if [ "${RUN_STATUSES[$index]}" = done ] && topic_specs_after_tag "$index"; then
        bump_minor=true
        spec_numbers=$(printf '%s' "${RUN_SPECS[$index]}" | sed 's/,/ #/g; s/^/#/')
        done_topics+=("$(topic_display "${RUN_TITLES[$index]}")$spec_numbers")
      fi
      index=$((index + 1))
    done
    if [ "$bump_minor" != true ]; then
      if git -C "$REPO_ROOT" log --first-parent --merges "$TAG..origin/$DEFAULT_BRANCH" --format=%s 2>/dev/null |
        grep -Eqi 'feat|新增|规格'; then
        bump_minor=true
      fi
    fi

    version=
    if [[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      if [ "$bump_minor" = true ]; then
        version=$(printf 'v%s.%s.0' "${BASH_REMATCH[1]}" "$((BASH_REMATCH[2] + 1))")
      else
        version=$(printf 'v%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$((BASH_REMATCH[3] + 1))")
      fi
    fi

    if [ "$other_work" = false ]; then
      if [ -n "$version" ]; then
        OUT+=("👉 推荐：打 tag 发版 ${version}（$DEFAULT_BRANCH 比 $TAG 多 $UNPUBLISHED 个提交未发布）")
      else
        OUT+=("👉 推荐：打新 tag（$DEFAULT_BRANCH 比 $TAG 多 $UNPUBLISHED 个提交未发布）")
      fi
      if [ "${#done_topics[@]}" -gt 0 ]; then
        OUT+=("   包含：$(printf '%s\n' "${done_topics[@]}" | join_lines '；')")
      fi
      OUT+=('   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。')
    else
      OUT+=("👉 要你做：二选一（$DEFAULT_BRANCH 比 $TAG 多 $UNPUBLISHED 个提交未发布）")
      if [ -n "$version" ]; then
        OUT+=("   A. 现在发版 ${version}（只带已完成的）")
      else
        OUT+=('   A. 现在打新 tag（只带已完成的）')
      fi
      if [ "${#ONGOING_PARTS[@]}" -eq 1 ] && [ "$HAS_OPEN_SPECS" != true ]; then
        wait_title=
        index=0
        while [ "$index" -lt "$TOPIC_COUNT" ]; do
          if [ "${RUN_STATUSES[$index]}" = ongoing ] &&
            { [ -z "$SPEC_ARG" ] || [ "$index" != "$CURRENT_INDEX" ]; }; then
            wait_title=$(topic_display "${RUN_TITLES[$index]}")
          fi
          index=$((index + 1))
        done
        OUT+=("   B. 等${wait_title}完成一起发")
      else
        OUT+=('   B. 等所有在做的工作完成一起发')
      fi
      if [ "$CLAIMED" = true ]; then
        active_list=
        for n in ${ACTIVE_SPECS[@]+"${ACTIVE_SPECS[@]}"}; do
          active_list="${active_list:+${active_list},}${n}"
        done
        OUT+=("   推荐：B（$(format_numbers "$active_list") 正在实现，做完再发）")
      else
        OUT+=('   推荐：A（没人在做，不该被它挡住）')
      fi
      OUT+=('   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。')
    fi

    for line in ${RELEASE_TIMING_LINES[@]+"${RELEASE_TIMING_LINES[@]}"}; do
      OUT+=("   发版后会解冻：#$(line_field "$line" 1) $(line_field "$line" 2)")
      UNFREEZE_SHOWN=true
    done
  fi
fi

for line in ${OTHER_TIMING_LINES[@]+"${OTHER_TIMING_LINES[@]}"}; do
  OUT+=("⏳ 等待时机（不提问）：#$(line_field "$line" 1) $(line_field "$line" 2)：$(line_field "$line" 3)")
done
if [ "$UNFREEZE_SHOWN" != true ]; then
  for line in ${RELEASE_TIMING_LINES[@]+"${RELEASE_TIMING_LINES[@]}"}; do
    OUT+=("⏳ 等待时机（不提问）：#$(line_field "$line" 1) $(line_field "$line" 2)：$(line_field "$line" 3)")
  done
fi
if [ "$TIMING_FAILED" = true ]; then
  OUT+=('⚠️ 等待时机票（查询失败）')
fi

INT_TIMES=()
INT_TITLES=()
INT_KINDS=()
index=0
while [ "$index" -lt "$TOPIC_COUNT" ]; do
  if [ "${RUN_STATUSES[$index]}" = interrupted ]; then
    INT_TIMES+=("${RUN_TIMES[$index]}")
    INT_TITLES+=("${RUN_TITLES[$index]}")
    INT_KINDS+=("${RUN_KINDS[$index]}")
  fi
  index=$((index + 1))
done
if [ "${#INT_TIMES[@]}" -eq 1 ]; then
  OUT+=("⚠️ 有 1 个 grill 中断了没有结论：${INT_TIMES[0]}「${INT_TITLES[0]}」")
  case "${INT_KINDS[0]}" in
    map) OUT+=('   要续上就重新 /grill-map 这个话题。') ;;
    *) OUT+=('   要续上就重新 /grill-feature 这个话题。') ;;
  esac
elif [ "${#INT_TIMES[@]}" -gt 1 ]; then
  OUT+=("⚠️ 有 ${#INT_TIMES[@]} 个 grill 中断了没有结论：")
  index=0
  while [ "$index" -lt "${#INT_TIMES[@]}" ]; do
    OUT+=("   ${INT_TIMES[$index]}「${INT_TITLES[$index]}」→ 要续上就重新 /grill-feature 或 /grill-map 这个话题")
    index=$((index + 1))
  done
fi

# ---------------------------------------------------------------- route block
# With --run-dir the report ends with what the dispatch module's verify prints
# for the Run: the Stage route table and a check line per Orca worker (route
# model against the model read off its terminal, a mismatch as a warning). The
# user reads the report to know who did the work (票 #47). verify never fails
# over a verdict; when it fails at all (no such run directory, no node) the
# block is one line and the report stands — the landing is already done.
if [ -n "$RUN_DIR" ]; then
  ROUTE_BLOCK=
  if [ -x "$STAGE_DISPATCH" ] && command -v node >/dev/null 2>&1; then
    # verify's stderr (a mismatch warning, the table's hints) passes through.
    ROUTE_BLOCK=$(bash "$STAGE_DISPATCH" verify --run-dir "$RUN_DIR")
    ROUTE_STATUS=$?
  else
    ROUTE_STATUS=1
  fi
  if [ "$ROUTE_STATUS" -eq 0 ] && [ -n "$ROUTE_BLOCK" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      OUT+=("   $line")
    done <<EOF
$ROUTE_BLOCK
EOF
  else
    OUT+=('   ⚠️ 路由表与模型核对（查询失败）')
  fi
fi

if [ "${#OUT[@]}" -gt 0 ]; then
  printf '%s\n' ${OUT[@]+"${OUT[@]}"}
fi

# -------------------------------------------------------------- notification

if [ "$NOTIFY" = true ] && [ "$CURRENT_INDEX" -ge 0 ] &&
  [ "${RUN_STATUSES[$CURRENT_INDEX]:-}" = done ]; then
  body=${OUT[0]:-}
  if [ -n "${COMPLETION_NOTIFY_CMD:-}" ]; then
    if ! "$COMPLETION_NOTIFY_CMD" "$REPO_NAME" "$body" >/dev/null 2>&1; then
      warn 'notification command failed (ignored)'
    fi
  elif command -v osascript >/dev/null 2>&1; then
    escaped=${body//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    if ! osascript -e "display notification \"$escaped\" with title \"$REPO_NAME\"" >/dev/null 2>&1; then
      warn 'notification failed (ignored)'
    fi
  else
    warn 'osascript not found; notification skipped'
  fi
fi

exit 0
