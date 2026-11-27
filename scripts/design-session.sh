#!/usr/bin/env bash
# Open an official-subscription Design session and wait for its handoff report,
# or attach to an existing run directory and keep waiting for its handoff.
#
# The `grill` role of the judgment model switch (scripts/judgment-model.sh) is
# read when a session is launched. With glm-5.4 the Design session is not
# opened on the official subscription: an Orca terminal in the repository runs
# the launcher named by ISS_GLM_LAUNCHER (default: claude-glm) with the same
# prompt, run directory and handoff contract. The typed launch command records
# its exit code in <run dir>/exit-code, which is how the wait notices that the
# session ended. A session that is already open keeps the model it started on;
# --attach keeps waiting for it either way.
#
# Usage:
#   scripts/design-session.sh feature|map (<topic> | --topic-file <path>)
#                   [--timeout <seconds>]
#   scripts/design-session.sh --attach <run-dir> [--timeout <seconds>]
#
# The run directory is created under DESIGN_SESSION_ROOT (default:
# ~/.cache/implement-spec-split/design) as <repo>-<YYYYmmdd-HHMM>-<kind>.
# ISS_ORCA can name another Orca executable. stdout is the handoff.md path on
# success; diagnostics go to stderr.
#
# Exit codes:
#   0  handoff received and its report exists
#  64  invalid usage or repository
#   5  orchestration wait timed out
#   6  Orca run creation/launch/check failed, or handoff was unusable
#   7  Design session ended before handing off

set -u
SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

usage() {
  cat <<'USAGE'
Usage: design-session.sh feature|map (<topic> | --topic-file <path>)
                   [--timeout <seconds>]
       design-session.sh --attach <run-dir> [--timeout <seconds>]

feature calls mattpocock-skills:grill-with-docs.
map calls mattpocock-skills:wayfinder and accepts an early "先到这" handoff.
--attach resumes waiting for a run created by a previous invocation.
--timeout is in seconds (default 7200).
USAGE
}

die_usage() {
  echo "design-session: $*" >&2
  usage >&2
  exit 64
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

MODE=launch
ATTACH_RUN_DIR=
if [ "${1:-}" = --attach ]; then
  MODE=attach
  shift
  [ $# -gt 0 ] || die_usage '--attach needs a run directory'
  case $1 in
    -*) die_usage '--attach needs a run directory' ;;
  esac
  ATTACH_RUN_DIR=$1
  shift
else
  KIND=${1:-}
  [ -n "$KIND" ] || die_usage 'kind is required'
  case "$KIND" in
    feature|map) ;;
    *) die_usage "kind must be feature or map, not '$KIND'" ;;
  esac
  shift
fi

TIMEOUT_SECONDS=7200
TOPIC=
TOPIC_FILE=
TOPIC_GIVEN=0
TOPIC_FILE_GIVEN=0
while [ $# -gt 0 ]; do
  case $1 in
    --topic-file)
      [ "$MODE" = launch ] || die_usage '--topic-file is valid only when starting a session'
      [ $# -ge 2 ] || die_usage '--topic-file needs a value'
      case $2 in -*) die_usage '--topic-file needs a value' ;; esac
      TOPIC_FILE=$2
      TOPIC_FILE_GIVEN=1
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || die_usage '--timeout needs a value'
      case $2 in -*) die_usage '--timeout needs a value' ;; esac
      TIMEOUT_SECONDS=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ "$MODE" = attach ]; then
        die_usage "unexpected argument: $1"
      fi
      if [ "$TOPIC_GIVEN" -eq 1 ]; then
        die_usage "unexpected topic: $1"
      fi
      TOPIC=$1
      TOPIC_GIVEN=1
      shift
      ;;
  esac
done
if [ "$MODE" = attach ] && [ "$TOPIC_GIVEN" -eq 1 ]; then
  die_usage 'unexpected topic in attach mode'
fi
if [ "$TOPIC_GIVEN" -eq 1 ] && [ "$TOPIC_FILE_GIVEN" -eq 1 ]; then
  die_usage 'pass either a topic or --topic-file, not both'
fi
if [ "$TOPIC_FILE_GIVEN" -eq 1 ]; then
  [ -f "$TOPIC_FILE" ] ||
    die_usage "--topic-file must be an existing file: $TOPIC_FILE"
  [ -r "$TOPIC_FILE" ] ||
    die_usage "--topic-file is not readable: $TOPIC_FILE"
  TOPIC=$(cat < "$TOPIC_FILE" && printf x) || die_usage "could not read topic file: $TOPIC_FILE"
  TOPIC=${TOPIC%x}
  [ -n "$TOPIC" ] || die_usage '--topic-file must not be empty'
elif [ "$MODE" = launch ] && [ "$TOPIC_GIVEN" -eq 0 ]; then
  die_usage 'topic is required'
fi
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) die_usage '--timeout must be a positive integer number of seconds' ;;
esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || die_usage '--timeout must be greater than zero'

command -v node >/dev/null 2>&1 || die 64 'node is required but was not found on PATH'
ORCA=${ISS_ORCA:-orca}
# Git Bash rewrites a leading-slash --prompt as a POSIX path; exempt the skill prefix.
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/mattpocock-skills"

# Read once per launch: the grill role. Anything unreadable means opus.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JUDGMENT_MODEL=$("$HERE/judgment-model.sh" --print grill 2>/dev/null || true)
case "$JUDGMENT_MODEL" in
  glm-5.4) ;;
  *) JUDGMENT_MODEL=opus ;;
esac
GLM_LAUNCHER=${ISS_GLM_LAUNCHER:-claude-glm}

run_id_from_json() {
  node -e '
    const fs = require("fs");
    const root = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const outcome = root.result ?? root;
    const id = outcome.id ?? outcome.runId ?? outcome.run?.id;
    if (typeof id !== "string" || !id) process.exit(1);
    process.stdout.write(id);
  ' "$1"
}

remind_pending_design_sessions() {
  cutoff=$(date -v-7d +%Y%m%d-%H%M 2>/dev/null) ||
    cutoff=$(date -d '7 days ago' +%Y%m%d-%H%M 2>/dev/null) ||
    cutoff=
  [ -n "$cutoff" ] || return 0

  pending_count=0
  pending_lines=
  for directory in "$ROOT/$REPO_NAME"-*/; do
    [ -d "$directory" ] || continue
    directory=${directory%/}
    run_base=$(basename "$directory")
    run_rest=${run_base#"$REPO_NAME"-}
    # Match the repository-name prefix rule used by grill-status.sh: the date
    # must follow the repository name directly, so repo `foo` never consumes
    # `foo-bar-20260101-1200-feature`.
    [[ "$run_rest" =~ ^([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])-([0-9][0-9])([0-9][0-9])(-[0-9]+)?-(feature|map)$ ]] ||
      continue
    stamp="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    # Old, un-handed sessions are historical noise; only the last 7 days count.
    [[ "$stamp" < "$cutoff" ]] && continue
    [ -f "$directory/handoff.md" ] && continue
    kind=${BASH_REMATCH[5]}
    title='（题目未记录）'
    if [ -f "$directory/topic.md" ]; then
      topic_line=
      IFS= read -r topic_line < "$directory/topic.md" || topic_line=
      if [ -n "$topic_line" ]; then
        title=$topic_line
      fi
    fi
    display="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
    pending_count=$((pending_count + 1))
    pending_lines="${pending_lines}- ${display} ${kind} ${title}  续等：design-session.sh --attach ${directory}
"
  done

  if [ "$pending_count" -gt 0 ]; then
    printf '提醒：本仓库还有 %d 个 Design session 没交接：\n%s' \
      "$pending_count" "$pending_lines" >&2
  fi
}

session_info_from_json() {
  node -e '
    const fs = require("fs");
    const root = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    // An agent launch reports result.outcome; a terminal create reports
    // result.terminal, which is always a terminal without a session id.
    const terminal = root.result?.terminal;
    const outcome = root.result?.outcome ?? terminal ?? {};
    process.stdout.write([
      outcome.kind ?? (terminal ? "terminal" : ""),
      outcome.sessionId ?? "",
      outcome.handle ?? terminal?.handle ?? "",
    ].join("\x1f"));
  ' "$1"
}

if [ "$MODE" = attach ]; then
  [ -d "$ATTACH_RUN_DIR" ] ||
    die_usage "--attach run directory does not exist: $ATTACH_RUN_DIR"
  RUN_DIR=$(cd "$ATTACH_RUN_DIR" 2>/dev/null && pwd) ||
    die_usage "could not resolve attach run directory: $ATTACH_RUN_DIR"
  RUN_CREATE_FILE=$RUN_DIR/run-create.json
  LAUNCH_FILE=$RUN_DIR/launch.json
  [ -f "$RUN_CREATE_FILE" ] ||
    die_usage "attach run is missing run-create.json: $RUN_DIR"
  [ -r "$RUN_CREATE_FILE" ] ||
    die_usage "attach run-create.json is not readable: $RUN_CREATE_FILE"
  [ -f "$LAUNCH_FILE" ] ||
    die_usage "attach run is missing launch.json: $RUN_DIR"
  [ -r "$LAUNCH_FILE" ] ||
    die_usage "attach launch.json is not readable: $LAUNCH_FILE"
  RUN_ID=$(run_id_from_json "$RUN_CREATE_FILE") ||
    die 6 'attach run-create.json returned no Run id'
  SESSION_INFO=$(session_info_from_json "$LAUNCH_FILE") ||
    die 6 'attach launch.json could not be parsed'
  # \x1f is not IFS whitespace, so an empty sessionId cannot shift handle left.
  IFS=$'\037' read -r SESSION_KIND SESSION_ID SESSION_HANDLE <<EOF
$SESSION_INFO
EOF
else
  command -v git >/dev/null 2>&1 || die 64 'git is required but was not found on PATH'
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die 64 'run this script from a git repository'
  ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
  REPO_NAME=${ORIGIN_URL##*/}
  REPO_NAME=${REPO_NAME%.git}
  REPO_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
  [ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$REPO_ROOT")
  ROOT=${DESIGN_SESSION_ROOT:-${ISS_DESIGN_SESSION_ROOT:-$HOME/.cache/implement-spec-split/design}}
  remind_pending_design_sessions
  STAMP=$(date +%Y%m%d-%H%M)
  RUN_DIR=$ROOT/$REPO_NAME-$STAMP-$KIND
  SUFFIX=1
  while [ -e "$RUN_DIR" ]; do
    SUFFIX=$((SUFFIX + 1))
    RUN_DIR=$ROOT/$REPO_NAME-$STAMP-$SUFFIX-$KIND
  done
  mkdir -p "$RUN_DIR" || die 64 "could not create run directory: $RUN_DIR"
  RUN_DIR=$(cd "$RUN_DIR" && pwd) || die 64 "could not resolve run directory: $RUN_DIR"
  printf '%s' "$TOPIC" > "$RUN_DIR/topic.md" ||
    die 64 "could not persist topic to $RUN_DIR/topic.md"
fi

if [ "$MODE" = launch ]; then
  RUN_CREATE_JSON=$("$ORCA" orchestration run-create \
    --objective "Design session handoff for $REPO_NAME" --json \
    2>"$RUN_DIR/run-create.err") ||
    die 6 "orca orchestration run-create failed: $(cat "$RUN_DIR/run-create.err")"
  printf '%s\n' "$RUN_CREATE_JSON" > "$RUN_DIR/run-create.json"
  RUN_ID=$(run_id_from_json "$RUN_DIR/run-create.json") ||
    die 6 'orca orchestration run-create returned no Run id'

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

  # The upstream skills set disable-model-invocation, so the Skill tool cannot
  # load them. Lead with the slash command: the launch prompt arrives as user
  # input, which may invoke them; everything after it becomes the arguments.
  #
  # Mock pages: on Opus the session only writes the direction card and hands
  # the pages to a worker, because supervising them is what costs Opus quota.
  # A session on the substitute model has no such quota to save and is told by
  # its launcher not to use workers, so it makes and checks the pages itself.
  if [ "$JUDGMENT_MODEL" = opus ]; then
    MOCK_CLAUSE='涉及界面或交互取舍、用户要看到才能定时，先出 mock 再写规格：用 ~/.claude/skills/implement-spec-split/templates/brief-mock.md 写方向卡和 Brief，交给 codex-worker.sh 出页面并自检；你不看截图和 HTML，只按它产出的 mock/manifest.json 调一次 mockit_submit，等用户拍板后用 mockit_get_review 取裁决。选中的页面复制到仓库 docs/<主题>-mock/，规格引用它作为界面验收基准。'
  else
    MOCK_CLAUSE="涉及界面或交互取舍、用户要看到才能定时，先出 mock 再写规格：按 ~/.claude/skills/implement-spec-split/templates/brief-mock.md 的「方向卡」「产出」「验收」自己做候选页面和自检脚本，全部写在 $RUN_DIR/mock/ 下，node $RUN_DIR/mock/check.mjs 全部 PASS 后只调一次 mockit_submit，等用户拍板后用 mockit_get_review 取裁决。选中的页面复制到仓库 docs/<主题>-mock/，规格引用它作为界面验收基准。"
  fi
  PROMPT=$(cat <<EOF
/$UPSTREAM
你是一个 Design session，由 Orchestrator 从当前仓库转来。请处理用户话题：
$TOPIC

上游技能：${UPSTREAM}（已由首行斜杠命令加载，不要再用 Skill 工具调它，也不要让用户手敲）
$KIND_INSTRUCTIONS

运行目录：$RUN_DIR

交接约定：
1. 讨论完成后，在同一会话接着做 to-spec 和 to-tickets；to-tickets 照常让用户确认拆分。
   $MOCK_CLAUSE
2. 上下文过重、一次要产出多份规格，或 main 已经变化时，提示用户另开 Design session，不要硬塞进本次会话。
3. GLOSSARY、ADR 等文档改动由你自己 commit 并 push。
4. 写不超过 30 行的 $RUN_DIR/handoff.md，包含：规格号、票号、新增或改动的 ADR 与术语、给 Orchestrator 的待办。实现类待办只写「实现规格 #N」（多份写各自规格号和先后顺序），不写由谁、用 worker 还是子代理、串行还是并行去做：执行方式由 /implement-spec-split 决定。
5. 最后运行 orca orchestration send --subject "Design session handoff" --to run:$RUN_ID --report-path "$RUN_DIR/handoff.md" 通知主会话。发送后本会话会被自动关闭，发送就是最后一步。
${EARLY_HANDOFF}
EOF
  )
  if [ "$JUDGMENT_MODEL" = opus ]; then
    LAUNCH_JSON=$("$ORCA" agent launch --agent claude --focus --json --prompt "$PROMPT" 2>"$RUN_DIR/launch.err") ||
      die 6 "orca agent launch failed: $(cat "$RUN_DIR/launch.err")"
  else
    command -v "${GLM_LAUNCHER%% *}" >/dev/null 2>&1 ||
      die 6 "the judgment model switch for grill is $JUDGMENT_MODEL, but its launcher '${GLM_LAUNCHER%% *}' was not found in PATH"
    printf 'design-session: 全局判断模型开关（grill）为 %s（用户用 judgment-model.sh 设置）：本次 Design session 由 %s 经 %s 执行，不是官方 Opus\n' \
      "$JUDGMENT_MODEL" "$JUDGMENT_MODEL" "$GLM_LAUNCHER" >&2
    # The prompt is far too long to type into a terminal, so the terminal reads
    # it back from the run directory. The typed command also records the
    # launcher's exit code: an Orca terminal outlives what was typed into it,
    # so `terminal wait --for exit` alone would not notice the session ending.
    printf '%s' "$PROMPT" > "$RUN_DIR/prompt.txt" ||
      die 6 "could not persist the prompt to $RUN_DIR/prompt.txt"
    LAUNCH_COMMAND="$GLM_LAUNCHER --dangerously-skip-permissions \"\$(cat $(printf '%q' "$RUN_DIR/prompt.txt"))\"; echo \$? > $(printf '%q' "$RUN_DIR/exit-code")"
    LAUNCH_JSON=$("$ORCA" terminal create --worktree "path:$REPO_ROOT" --focus --json \
      --command "$LAUNCH_COMMAND" \
      2>"$RUN_DIR/launch.err") ||
      die 6 "orca terminal create failed: $(cat "$RUN_DIR/launch.err")"
  fi
  printf '%s\n' "$LAUNCH_JSON" > "$RUN_DIR/launch.json"
  SESSION_INFO=$(session_info_from_json "$RUN_DIR/launch.json") ||
    die 6 'orca launch JSON could not be parsed'
  # \x1f is not IFS whitespace, so an empty sessionId cannot shift handle left.
  IFS=$'\037' read -r SESSION_KIND SESSION_ID SESSION_HANDLE <<EOF
$SESSION_INFO
EOF
  # Without the handle the wait could neither follow nor close the terminal.
  if [ "$JUDGMENT_MODEL" != opus ] && [ -z "$SESSION_HANDLE" ]; then
    die 6 'orca terminal create returned no terminal handle'
  fi
fi

TIMEOUT_MS=$((TIMEOUT_SECONDS * 1000))
CHECK_PID=
SESSION_WAIT_PID=
POLL_SECONDS=${ISS_DESIGN_SESSION_POLL:-2}
WAIT_STARTED=$(date +%s)
WAIT_DEADLINE=$((WAIT_STARTED + TIMEOUT_SECONDS))
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

matching_report_path() {
  printf '%s\n' "$1" | node -e '
    const fs = require("fs");
    const root = JSON.parse(fs.readFileSync(0, "utf8"));
    const messages = root.result?.messages ?? root.messages ?? [];
    for (const message of messages) {
      let payload = message.payload;
      if (typeof payload === "string") {
        try { payload = JSON.parse(payload); } catch (_) { continue; }
      }
      const reportPath = payload?.reportPath ?? payload?.report_path;
      if (reportPath === process.argv[1]) {
        process.stdout.write(reportPath);
        process.exit(0);
      }
    }
  ' "$2"
}

accept_handoff() {
  handoff=$1
  [ -f "$handoff" ] ||
    die 6 "handoff report is missing: $handoff"
  printf '%s\n' "$handoff"
  cleanup_wait
  # Bring the user back to the Orchestrator terminal that started this wait.
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    "$ORCA" terminal switch --terminal "$ORCA_TERMINAL_HANDLE" --json > "$RUN_DIR/switch.json" 2>&1 ||
      printf 'design-session: 未能切回主会话（%s），请手动切换\n' "$ORCA_TERMINAL_HANDLE" >&2
  fi
  # The Design session's job ends with the handoff; close its tab so it stops
  # holding an Orca slot and Opus quota. ISS_DESIGN_KEEP_SESSION=1 keeps it.
  if [ -n "$SESSION_HANDLE" ] && [ "${ISS_DESIGN_KEEP_SESSION:-}" != 1 ]; then
    sleep "${ISS_DESIGN_CLOSE_DELAY:-3}"
    "$ORCA" terminal close --terminal "$SESSION_HANDLE" --tab --json > "$RUN_DIR/close.json" 2>&1 ||
      printf 'design-session: 未能关闭 Design session（%s），请手动关闭\n' "$SESSION_HANDLE" >&2
  fi
  exit 0
}

# Ends the wait for a Design session that stopped without handing off. Without
# an argument the ending was observed through Orca; with one it is the exit
# code the substitute launcher wrote to $RUN_DIR/exit-code.
session_ended() {
  if [ -f "$RUN_DIR/handoff.md" ]; then
    accept_handoff "$RUN_DIR/handoff.md"
  fi
  cleanup_wait
  if [ -n "${1:-}" ]; then
    printf 'design-session: 启动命令已退出，退出码 %s；输出见 Orca 里的 Design session 标签\n' "$1" >&2
  fi
  die 7 'Design session 已结束且未交出 handoff.md'
}

if [ "$MODE" = attach ] && [ -f "$RUN_DIR/handoff.md" ]; then
  # A consuming check may already have taken the handoff message before the
  # previous waiter exited. The report file is authoritative in that case.
  accept_handoff "$RUN_DIR/handoff.md"
fi

if [ -n "$SESSION_ID" ]; then
  monitor_check() {
    while kill -0 "$CHECK_PID" 2>/dev/null; do
      sleep "$POLL_SECONDS"
      if [ -s "$RUN_DIR/check.out" ]; then
        return 0
      fi
      SHOW_JSON=$("$ORCA" agent show --id "$SESSION_ID" --json 2>/dev/null || true)
      if [ -n "$SHOW_JSON" ] && ! printf '%s\n' "$SHOW_JSON" | node -e '
        const fs = require("fs");
        const root = JSON.parse(fs.readFileSync(0, "utf8"));
        if (root.ok === false) process.exit(0);
        const places = root.result?.places;
        process.exit(Array.isArray(places) && places.length > 0 ? 0 : 1);
      '; then
        if [ -f "$RUN_DIR/handoff.md" ]; then
          accept_handoff "$RUN_DIR/handoff.md"
        fi
        cleanup_wait
        CHECK_PID=
        die 7 'Design session 已结束且未交出 handoff.md'
      fi
    done
  }
elif [ "$SESSION_KIND" = terminal ] && [ -n "$SESSION_HANDLE" ]; then
  "$ORCA" terminal wait --terminal "$SESSION_HANDLE" --for exit \
    --timeout-ms "$TIMEOUT_MS" > "$RUN_DIR/session-wait.out" 2> "$RUN_DIR/session-wait.err" &
  SESSION_WAIT_PID=$!
  monitor_check() {
    while kill -0 "$CHECK_PID" 2>/dev/null; do
      sleep "$POLL_SECONDS"
      if [ -s "$RUN_DIR/check.out" ]; then
        return 0
      fi
      if [ -s "$RUN_DIR/exit-code" ]; then
        session_ended "$(tr -d '[:space:]' < "$RUN_DIR/exit-code")"
      fi
      if ! kill -0 "$SESSION_WAIT_PID" 2>/dev/null; then
        wait "$SESSION_WAIT_PID"
        SESSION_WAIT_STATUS=$?
        SESSION_WAIT_PID=
        if [ "$SESSION_WAIT_STATUS" -eq 0 ]; then
          session_ended
        fi
      fi
    done
  }
else
  monitor_check() {
    while kill -0 "$CHECK_PID" 2>/dev/null; do
      if [ -s "$RUN_DIR/check.out" ]; then
        return 0
      fi
      sleep "$POLL_SECONDS"
    done
  }
fi

wait_timed_out() {
  printf 'bash %q --attach %q --timeout %s\n' \
    "$SCRIPT_PATH" "$RUN_DIR" "$TIMEOUT_SECONDS" >&2
  die 5 "等待 handoff 超时（${TIMEOUT_SECONDS} 秒）"
}

while :; do
  NOW=$(date +%s)
  REMAINING_MS=$(( (WAIT_DEADLINE - NOW) * 1000 ))
  if [ "$REMAINING_MS" -le 0 ]; then
    wait_timed_out
  fi
  "$ORCA" orchestration check --run "$RUN_ID" --wait --json \
    --timeout-ms "$REMAINING_MS" > "$RUN_DIR/check.out" 2> "$RUN_DIR/check.err" &
  CHECK_PID=$!
  monitor_check
  wait "$CHECK_PID"
  CHECK_STATUS=$?
  CHECK_PID=
  CHECK_JSON=$(cat "$RUN_DIR/check.out" 2>/dev/null || true)
  printf '%s\n' "$CHECK_JSON" > "$RUN_DIR/check.json"
  if [ "$CHECK_STATUS" -ne 0 ]; then
    die 6 "orca orchestration check failed: $(cat "$RUN_DIR/check.err")"
  fi
  if printf '%s\n' "$CHECK_JSON" | node -e '
    const fs = require("fs");
    const root = JSON.parse(fs.readFileSync(0, "utf8"));
    process.exit(root.result?.timedOut === true ? 0 : 1);
  '; then
    wait_timed_out
  fi

  HANDOFF=$(matching_report_path "$CHECK_JSON" "$RUN_DIR/handoff.md" || true)
  if [ -n "$HANDOFF" ]; then
    accept_handoff "$HANDOFF"
  fi
  sleep "$POLL_SECONDS"
done
