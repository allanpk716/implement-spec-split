#!/usr/bin/env bash
# List Design sessions for a repository, with spec and ticket progress.

set -u

usage() {
  cat <<'USAGE'
Usage: grill-status.sh [<repo dir>] [-h|--help]

Without <repo dir>, the current directory is used. For every Design session run
under DESIGN_SESSION_ROOT (default ~/.cache/implement-spec-split/design), print
its topic, spec states, and ticket progress.
USAGE
}

die() {
  printf 'grill-status: %s\n' "$1" >&2
  exit 1
}

REPO_ARG=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      [ -z "$REPO_ARG" ] || die "unknown extra argument: $1"
      REPO_ARG=$1
      shift
      ;;
  esac
done

command -v git >/dev/null 2>&1 || die 'git is required but was not found on PATH'
command -v gh >/dev/null 2>&1 || die 'gh is required but was not found on PATH'

REPO_ROOT=$(git -C "${REPO_ARG:-.}" rev-parse --show-toplevel 2>/dev/null) ||
  die 'run this script from a git repository, or pass a repository directory'
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
REPO_NAME=${ORIGIN_URL##*/}
REPO_NAME=${REPO_NAME%.git}
REPO_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
[ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$REPO_ROOT")

ROOT=${DESIGN_SESSION_ROOT:-${ISS_DESIGN_SESSION_ROOT:-$HOME/.cache/implement-spec-split/design}}
TOTAL=0
COMPLETED=0
ONGOING=0
INTERRUPTED=0

for RUN_DIR in "$ROOT/$REPO_NAME"-*/; do
  [ -d "$RUN_DIR" ] || continue
  RUN_BASE=$(basename "$RUN_DIR")
  RUN_REST=${RUN_BASE#"$REPO_NAME"-}
  # A repo named foo must not consume foo-bar-20260101-1200-feature. The date
  # must follow the repository-name prefix directly; a numeric infix is used
  # when several sessions start within the same minute.
  [[ "$RUN_REST" =~ ^([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])-([0-9][0-9])([0-9][0-9])(-[0-9]+)?-(feature|map)$ ]] ||
    continue
  RUN_DATE=${BASH_REMATCH[1]}
  RUN_HOUR=${BASH_REMATCH[2]}
  RUN_MINUTE=${BASH_REMATCH[3]}
  RUN_KIND=${BASH_REMATCH[5]}
  DISPLAY_TIME="${RUN_DATE:0:4}-${RUN_DATE:4:2}-${RUN_DATE:6:2} $RUN_HOUR:$RUN_MINUTE"

  HANDOFF=$RUN_DIR/handoff.md
  TOPIC_FILE=$RUN_DIR/topic.md
  TITLE='（题目未记录）'
  DETAIL_OUTPUT=

  if [ -f "$HANDOFF" ]; then
    HANDOFF_LINE=
    IFS= read -r HANDOFF_LINE < "$HANDOFF" || HANDOFF_LINE=
    case "$HANDOFF_LINE" in
      *：*) TITLE=${HANDOFF_LINE#*：} ;;
    esac
    [ -n "$TITLE" ] || TITLE='（题目未记录）'

    ALL_CLOSED=1
    SPEC_LINES=$(awk '
      /^##[[:space:]]*/ {
        in_specs = ($0 ~ /^##[[:space:]]*规格[[:space:]]*$/)
        next
      }
      in_specs && /^-[[:space:]]+#[0-9]+/ { print }
    ' "$HANDOFF" 2>/dev/null) || ALL_CLOSED=0

    while IFS= read -r SPEC_LINE; do
      [ -n "$SPEC_LINE" ] || continue
      [[ "$SPEC_LINE" =~ ^-[[:space:]]+#([0-9]+) ]] || continue
      ISSUE_NUMBER=${BASH_REMATCH[1]}
      ISSUE_FIELDS=$( (
        cd "$REPO_ROOT" &&
          gh api "repos/{owner}/{repo}/issues/$ISSUE_NUMBER" \
            --jq '[.state, .title, (.sub_issues_summary.completed // 0), (.sub_issues_summary.total // 0)] | @tsv'
      ) 2>/dev/null)
      GH_STATUS=$?
      if [ "$GH_STATUS" -ne 0 ] || [ -z "$ISSUE_FIELDS" ]; then
        DETAIL_OUTPUT="${DETAIL_OUTPUT}  #$ISSUE_NUMBER （查询失败）
"
        ALL_CLOSED=0
        continue
      fi

      IFS=$'\t' read -r ISSUE_STATE ISSUE_TITLE TICKETS_COMPLETED TICKETS_TOTAL <<EOF
$ISSUE_FIELDS
EOF
      ISSUE_STATE=$(printf '%s' "$ISSUE_STATE" | tr '[:lower:]' '[:upper:]')
      case "$ISSUE_STATE" in
        OPEN|CLOSED) ;;
        *) ISSUE_STATE='' ;;
      esac
      case "$TICKETS_TOTAL" in
        ''|*[!0-9]*) TICKETS_TOTAL=0 ;;
      esac
      case "$TICKETS_COMPLETED" in
        ''|*[!0-9]*) TICKETS_COMPLETED=0 ;;
      esac
      if [ -z "$ISSUE_STATE" ]; then
        DETAIL_OUTPUT="${DETAIL_OUTPUT}  #$ISSUE_NUMBER （查询失败）
"
        ALL_CLOSED=0
        continue
      fi
      if [ "$TICKETS_TOTAL" -eq 0 ]; then
        TICKET_PROGRESS='票 -'
      else
        TICKET_PROGRESS="票 $TICKETS_COMPLETED/$TICKETS_TOTAL"
      fi
      DETAIL_OUTPUT="${DETAIL_OUTPUT}  #$ISSUE_NUMBER [$ISSUE_STATE] $ISSUE_TITLE  $TICKET_PROGRESS
"
      [ "$ISSUE_STATE" = CLOSED ] || ALL_CLOSED=0
    done <<EOF
$SPEC_LINES
EOF

    if [ "$ALL_CLOSED" -eq 1 ]; then
      STATE='已完成'
      COMPLETED=$((COMPLETED + 1))
    else
      STATE='进行中'
      ONGOING=$((ONGOING + 1))
    fi
  else
    STATE='中断（无 handoff）'
    INTERRUPTED=$((INTERRUPTED + 1))
    if [ -f "$TOPIC_FILE" ]; then
      TOPIC_LINE=
      IFS= read -r TOPIC_LINE < "$TOPIC_FILE" || TOPIC_LINE=
      if [ -n "$TOPIC_LINE" ]; then
        TITLE=$TOPIC_LINE
        if [ "${#TITLE}" -gt 60 ]; then
          TITLE="${TITLE:0:60}…"
        fi
      fi
    fi
  fi

  TOTAL=$((TOTAL + 1))
  printf '■ %s  (%s %s)  %s\n' "$TITLE" "$DISPLAY_TIME" "$RUN_KIND" "$STATE"
  [ -z "$DETAIL_OUTPUT" ] || printf '%s' "$DETAIL_OUTPUT"
done

if [ "$TOTAL" -eq 0 ]; then
  printf '%s\n' '（本仓库没有 Design session 记录）'
  exit 0
fi

printf '共 %d 次 grill：已完成 %d，进行中 %d，中断 %d\n' \
  "$TOTAL" "$COMPLETED" "$ONGOING" "$INTERRUPTED"
