#!/usr/bin/env bash
# Completion conclusion for a repository's grill topics: the current topic's
# progress, repository-wide topic status, a release recommendation, tickets a
# release would unfreeze, and interrupted grill sessions. Read-only: it never
# tags and never pushes.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GRILL_STATUS=$HERE/grill-status.sh

usage() {
  cat <<'USAGE'
Usage: completion-report.sh [<repo dir>] [--spec <n>] [--notify]

Print a fixed-format Chinese completion conclusion: the current grill topic's
progress (--spec), repository-wide topic status, whether to tag a release (with
a suggested version and reasons), tickets that a release would unfreeze, and
interrupted grill sessions. --notify sends exactly one notification when the
--spec topic is complete; COMPLETION_NOTIFY_CMD overrides the default
osascript command and receives the title and body as two arguments.
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
        fi
      done
      ONGOING_PARTS+=("   ⏳ $(topic_display "${RUN_TITLES[$index]}")：$(printf '%s\n' "${open_parts[@]}" | join_lines '、')")
    fi
    index=$((index + 1))
  done

  stray_parts=()
  for line in ${STRAY_LINES[@]+"${STRAY_LINES[@]}"}; do
    stray_parts+=("#$(line_field "$line" 1) $(line_field "$line" 2)")
  done

  if [ "${#ONGOING_PARTS[@]}" -gt 0 ] || [ "${#stray_parts[@]}" -gt 0 ] || [ "$RFA_FAILED" = true ]; then
    if [ "${#ONGOING_PARTS[@]}" -gt 0 ]; then
      OUT+=("   仓库里还有 ${#ONGOING_PARTS[@]} 个题目没完成：")
      for part in ${ONGOING_PARTS[@]+"${ONGOING_PARTS[@]}"}; do
        OUT+=("$part")
      done
    fi
    if [ "${#stray_parts[@]}" -gt 0 ]; then
      OUT+=("   还有 ${#stray_parts[@]} 张就绪票在实现队列：$(printf '%s\n' "${stray_parts[@]}" | join_lines '、')")
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
      if [ "${#ONGOING_PARTS[@]}" -eq 1 ]; then
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
        OUT+=('   推荐：B（它正在实现，等它）')
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
