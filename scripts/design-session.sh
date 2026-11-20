#!/usr/bin/env bash
# Open an official-Opus Design session and wait for its handoff report.
#
# Usage:
#   scripts/design-session.sh feature|map <topic> [--timeout <seconds>]
#
# The run directory is created under DESIGN_SESSION_ROOT (default:
# ~/.cache/implement-spec-split/design) as <repo>-<YYYYmmdd-HHMM>-<kind>.
# ISS_ORCA can name another Orca executable. stdout is the handoff.md path on
# success; diagnostics go to stderr.
#
# Exit codes:
#   0  handoff received and its report exists
#   2  invalid usage or repository
#   3  orchestration wait timed out
#   4  Design session ended before handing off
#   5  Orca launch or check failed
#   6  message had no usable handoff report

set -u

usage() {
  cat <<'USAGE'
Usage: design-session.sh feature|map <topic> [--timeout <seconds>]

feature calls mattpocock-skills:grill-with-docs.
map calls mattpocock-skills:wayfinder and accepts an early "先到这" handoff.
--timeout is in seconds (default 7200).
USAGE
}

die_usage() {
  echo "design-session: $*" >&2
  usage >&2
  exit 2
}

die() {
  code=$1
  shift
  echo "design-session: $*" >&2
  exit "$code"
}

for argument in "$@"; do
  case "$argument" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

KIND=${1:-}
TOPIC=${2:-}
[ -n "$KIND" ] || die_usage 'kind is required'
[ -n "$TOPIC" ] || die_usage 'topic is required'
case "$KIND" in
  feature|map) ;;
  *) die_usage "kind must be feature or map, not '$KIND'" ;;
esac
shift 2

TIMEOUT_SECONDS=7200
while [ $# -gt 0 ]; do
  case $1 in
    --timeout)
      TIMEOUT_SECONDS=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) die_usage '--timeout must be a positive integer number of seconds' ;;
esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || die_usage '--timeout must be greater than zero'

command -v git >/dev/null 2>&1 || die 2 'git is required but was not found on PATH'
command -v node >/dev/null 2>&1 || die 2 'node is required but was not found on PATH'
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die 2 'run this script from a git repository'
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
REPO_NAME=${ORIGIN_URL##*/}
REPO_NAME=${REPO_NAME%.git}
REPO_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
[ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$REPO_ROOT")
ROOT=${DESIGN_SESSION_ROOT:-${ISS_DESIGN_SESSION_ROOT:-$HOME/.cache/implement-spec-split/design}}
STAMP=$(date +%Y%m%d-%H%M)
RUN_DIR=$ROOT/$REPO_NAME-$STAMP-$KIND
SUFFIX=1
while [ -e "$RUN_DIR" ]; do
  SUFFIX=$((SUFFIX + 1))
  RUN_DIR=$ROOT/$REPO_NAME-$STAMP-$SUFFIX-$KIND
done
mkdir -p "$RUN_DIR" || die 2 "could not create run directory: $RUN_DIR"

case "$KIND" in
  feature)
    UPSTREAM=mattpocock-skills:grill-with-docs
    KIND_INSTRUCTIONS='先用上游技能 grill 这个小功能，再继续下面的交接约定。'
    EARLY_HANDOFF=''
    ;;
  map)
    UPSTREAM=mattpocock-skills:wayfinder
    KIND_INSTRUCTIONS='先用上游 wayfinder 技能推进这张大模块地图，再继续下面的交接约定。'
    EARLY_HANDOFF='用户说“先到这”时可以提前交接；handoff.md 必须写清地图状态和下一步。'
    ;;
esac

PROMPT=$(cat <<EOF
你是一个 Design session，由 Orchestrator 从当前仓库转来。请处理用户话题：
$TOPIC

上游技能：$UPSTREAM
$KIND_INSTRUCTIONS

运行目录：$RUN_DIR

交接约定：
1. 讨论完成后，在同一会话接着做 to-spec 和 to-tickets；to-tickets 照常让用户确认拆分。
2. 上下文过重、一次要产出多份规格，或 main 已经变化时，提示用户另开 Design session，不要硬塞进本次会话。
3. GLOSSARY、ADR 等文档改动由你自己 commit 并 push。
4. 写不超过 30 行的 $RUN_DIR/handoff.md，包含：规格号、票号、新增或改动的 ADR 与术语、给 Orchestrator 的待办。
5. 最后运行 orca orchestration send --report-path $RUN_DIR/handoff.md 通知主会话。
${EARLY_HANDOFF}
EOF
)

ORCA=${ISS_ORCA:-orca}
LAUNCH_JSON=$("$ORCA" agent launch --agent claude --json --prompt "$PROMPT" 2>"$RUN_DIR/launch.err") ||
  die 5 "orca agent launch failed: $(cat "$RUN_DIR/launch.err")"
printf '%s\n' "$LAUNCH_JSON" > "$RUN_DIR/launch.json"
SESSION_INFO=$(printf '%s\n' "$LAUNCH_JSON" | node -e '
  const fs = require("fs");
  const root = JSON.parse(fs.readFileSync(0, "utf8"));
  const outcome = root.result?.outcome ?? root.result ?? {};
  process.stdout.write([outcome.kind ?? "", outcome.sessionId ?? "", outcome.handle ?? ""].join("\t"));
')
IFS=$'\t' read -r SESSION_KIND SESSION_ID SESSION_HANDLE <<EOF
$SESSION_INFO
EOF

TIMEOUT_MS=$((TIMEOUT_SECONDS * 1000))
CHECK_PID=
SESSION_WAIT_PID=
cleanup_wait() {
  for pid in "$CHECK_PID" "$SESSION_WAIT_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  CHECK_PID=
  SESSION_WAIT_PID=
}
trap cleanup_wait INT TERM EXIT
"$ORCA" orchestration check --wait --json --timeout-ms "$TIMEOUT_MS" \
  > "$RUN_DIR/check.out" 2> "$RUN_DIR/check.err" &
CHECK_PID=$!
POLL_SECONDS=${ISS_DESIGN_SESSION_POLL:-2}
if [ -n "$SESSION_ID" ]; then
  while kill -0 "$CHECK_PID" 2>/dev/null; do
    sleep "$POLL_SECONDS"
    if [ -s "$RUN_DIR/check.out" ]; then
      break
    fi
    SHOW_JSON=$("$ORCA" agent show --id "$SESSION_ID" --json 2>/dev/null || true)
    if [ -n "$SHOW_JSON" ] && ! printf '%s\n' "$SHOW_JSON" | node -e '
      const fs = require("fs");
      const root = JSON.parse(fs.readFileSync(0, "utf8"));
      const places = root.result?.places;
      process.exit(Array.isArray(places) && places.length > 0 ? 0 : 1);
    '; then
      cleanup_wait
      CHECK_PID=
      die 4 'Design session 已结束且未交出 handoff.md'
    fi
  done
elif [ "$SESSION_KIND" = terminal ] && [ -n "$SESSION_HANDLE" ]; then
  "$ORCA" terminal wait --terminal "$SESSION_HANDLE" --for exit \
    --timeout-ms "$TIMEOUT_MS" > "$RUN_DIR/session-wait.out" 2> "$RUN_DIR/session-wait.err" &
  SESSION_WAIT_PID=$!
  while kill -0 "$CHECK_PID" 2>/dev/null; do
    sleep "$POLL_SECONDS"
    if [ -s "$RUN_DIR/check.out" ]; then
      break
    fi
    if ! kill -0 "$SESSION_WAIT_PID" 2>/dev/null; then
      wait "$SESSION_WAIT_PID"
      SESSION_WAIT_STATUS=$?
      SESSION_WAIT_PID=
      if [ "$SESSION_WAIT_STATUS" -eq 0 ]; then
        cleanup_wait
        die 4 'Design session 已结束且未交出 handoff.md'
      fi
    fi
  done
fi
wait "$CHECK_PID"
CHECK_STATUS=$?
CHECK_PID=
cleanup_wait
CHECK_JSON=$(cat "$RUN_DIR/check.out" 2>/dev/null || true)
printf '%s\n' "$CHECK_JSON" > "$RUN_DIR/check.json"
if [ "$CHECK_STATUS" -ne 0 ]; then
  die 5 "orca orchestration check failed: $(cat "$RUN_DIR/check.err")"
fi
if printf '%s\n' "$CHECK_JSON" | node -e '
  const fs = require("fs");
  const root = JSON.parse(fs.readFileSync(0, "utf8"));
  process.exit(root.result?.timedOut === true ? 0 : 1);
'; then
  die 3 "等待 handoff 超时（${TIMEOUT_SECONDS} 秒）"
fi

HANDOFF=$(printf '%s\n' "$CHECK_JSON" | node -e '
  const fs = require("fs");
  const root = JSON.parse(fs.readFileSync(0, "utf8"));
  const messages = root.result?.messages ?? root.messages ?? [];
  for (const message of messages) {
    let payload = message.payload;
    if (typeof payload === "string") {
      try { payload = JSON.parse(payload); } catch (_) { continue; }
    }
    const reportPath = payload?.reportPath ?? payload?.report_path;
    if (typeof reportPath === "string" && reportPath) {
      process.stdout.write(reportPath);
      process.exit(0);
    }
  }
') || die 6 'orchestration message had no reportPath'
[ -n "$HANDOFF" ] || die 6 'orchestration message had no reportPath'
[ -f "$HANDOFF" ] || die 6 "handoff report is missing: $HANDOFF"
printf '%s\n' "$HANDOFF"
exit 0
