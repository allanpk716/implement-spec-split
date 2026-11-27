#!/usr/bin/env bash
# Open a Design session on the design route and wait for its handoff report, or
# attach to an existing run directory and keep waiting for its handoff.
#
# The route (GLOSSARY.md "Stage route", ADR 0004) is read from the table
# (scripts/stage-route.sh, which only the user changes, as /grill-router) each
# time a session is launched. Its Launcher profile names the launcher; the model
# and reasoning effort go on that launcher's command line, which is how a Design
# session can run on something other than Opus. The session is an Orca terminal
# in the repository running `<launcher> --model … --effort …`, adopted as a
# worker of a Run with `worker-start --terminal`, which also delivers the prompt
# as the Task. Every profile but the official claude adds
# --dangerously-skip-permissions to that command; claude keeps its TUI's
# permission prompts, the user being present in a Design session. The typed
# command records the launcher's exit code in <run dir>/exit-code, which, with
# one `terminal wait --for exit`, is how the wait notices that the session
# ended. A session that is already open keeps the route it started on; --attach
# keeps waiting for it either way and reads no route.
#
# Usage:
#   scripts/design-session.sh feature|map (<topic> | --topic-file <path>)
#                   [--timeout <seconds>]
#   scripts/design-session.sh --attach <run-dir> [--timeout <seconds>]
#
# The run directory is created under DESIGN_SESSION_ROOT (default:
# ~/.cache/implement-spec-split/design) as <repo>-<YYYYmmdd-HHMM>-<kind>.
# stdout is the handoff.md path on success; diagnostics go to stderr, the route
# of this session first. An early map handoff (the user said 先到这) opens
# handoff.md with the line "提前交接：先到这" and is reported on stderr as
# "design-session: 提前交接：…". DESIGN_SESSION_STAGE_ROUTE names another
# Stage route table script (for the tests).
#
# Exit codes:
#   0  handoff received and its report exists
#  64  invalid usage or repository, or the design route could not be read
#  5  orchestration wait timed out
#  6  Orca run creation/terminal/worker-start/check failed, the route's launcher
#      was not found, or the handoff was unusable
#  7  Design session ended before handing off

set -u
SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

usage() {
  cat <<'USAGE'
Usage: design-session.sh feature|map (<topic> | --topic-file <path>)
                   [--timeout <seconds>]
       design-session.sh --attach <run-dir> [--timeout <seconds>]

feature calls mattpocock-skills:grill-with-docs.
map calls mattpocock-skills:wayfinder and accepts an early "先到这" handoff
     (handoff.md opens with "提前交接：先到这", reported on stderr).
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
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Every Orca call goes through the library; this script has no Orca variable.
. "$HERE/lib-orca.sh"

# The map prompt asks an early handoff (the user said 先到这) to open with this
# line; the Orchestrator leaves find-next alone when it is reported on stderr.
EARLY_HANDOFF_MARKER='提前交接：先到这'
# How long worker-start may wait for the launcher's TUI to take the Task.
START_TIMEOUT_MS=180000

if [ "$MODE" = launch ]; then
  # Read once per launch: the design route. A route that cannot be read is a
  # usage error: the table is the only source of the launcher and the model, so
  # nothing starts without one. The table's own hints (a line outside the
  # catalog, an unreadable file, the first run's migration notes) went to
  # stderr from the --launch read; the --print reads after it are silenced.
  STAGE=design
  STAGE_LABEL='讨论（design）'
  STAGE_ROUTE=${DESIGN_SESSION_STAGE_ROUTE:-$HERE/stage-route.sh}
  LAUNCH=$("$STAGE_ROUTE" --launch "$STAGE" interactive) ||
    die 64 "cannot read the $STAGE route's launch command from the Stage route table ($STAGE_ROUTE --launch $STAGE interactive exited $?)"
  [ -n "$LAUNCH" ] || die 64 "$STAGE_ROUTE --launch printed nothing for the $STAGE route"
  LAUNCH_ARGS=()
  while IFS= read -r arg; do LAUNCH_ARGS+=("$arg"); done <<< "$LAUNCH"

  route_field() {
    local value
    value=$("$STAGE_ROUTE" --print "$STAGE" "$1" 2>/dev/null) ||
      die 64 "cannot read the $STAGE route's $1 from the Stage route table ($STAGE_ROUTE --print $STAGE $1 exited $?)"
    [ -n "$value" ] || die 64 "$STAGE_ROUTE --print $STAGE $1 printed nothing for the $STAGE route"
    printf '%s' "$value"
  }
  ROUTE_PROFILE=$(route_field profile)
  ROUTE_MODEL=$(route_field model)
  ROUTE_EFFORT=$(route_field effort)
  LAUNCHER=${LAUNCH_ARGS[0]:-}
  # Only the claude profiles open an interactive Claude Code session (the
  # design stage is verified for them alone in the table's catalog).
  case "$ROUTE_PROFILE" in
    claude|claude-glm|claude-flash) ;;
    *) die 64 "the $STAGE route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, and the profile '$ROUTE_PROFILE' cannot run a Design session" ;;
  esac
  printf 'design-session: 本次讨论路由：%s：%s / %s / %s（用户用 /grill-router 设置）：本次 Design session 由 %s 经 %s 执行\n' \
    "$STAGE_LABEL" "$ROUTE_PROFILE" "$ROUTE_MODEL" "$ROUTE_EFFORT" "$ROUTE_MODEL" "$LAUNCHER" >&2
  command -v "$LAUNCHER" >/dev/null 2>&1 ||
    die 6 "the $STAGE route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, but its launcher '$LAUNCHER' was not found in PATH"
fi

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

# The terminal handle a launch receipt carries. A terminal create reports
# result.terminal; an agent launch, which a session started before routes has
# and --attach may still meet, reports result.outcome. Either way the handle is
# what the wait and the close need. Exits 1 when the receipt is not JSON, 2
# when it is JSON without a handle.
terminal_handle_from_json() {
  node -e '
    const fs = require("fs");
    let root;
    try { root = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch { process.exit(1); }
    const result = root.result ?? {};
    const handle = result.terminal?.handle ?? result.outcome?.handle;
    if (typeof handle !== "string" || !handle) process.exit(2);
    process.stdout.write(handle);
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
  # A receipt without a handle (a chat-shaped session from before routes) is
  # waited on through the Run alone.
  SESSION_HANDLE=$(terminal_handle_from_json "$LAUNCH_FILE")
  [ $? -ne 1 ] || die 6 'attach launch.json could not be parsed'
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
  RUN_CREATE_JSON=$(orca_orchestration_run_create "Design session handoff for $REPO_NAME" \
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
      EARLY_HANDOFF="用户说“先到这”时可以提前交接：handoff.md 首行必须原样写「${EARLY_HANDOFF_MARKER}」（主会话据此不接 find-next），其余行写清地图状态和下一步。"
      ;;
  esac

  # Mock pages: on the claude profile the session only writes the direction
  # card and hands the pages to a worker, because supervising them is what
  # costs Opus quota. A session on any other profile has no such quota to save
  # and is told by its launcher not to use workers, so it makes and checks the
  # pages itself.
  if [ "$ROUTE_PROFILE" = claude ]; then
    MOCK_CLAUSE='涉及界面或交互取舍、用户要看到才能定时，先出 mock 再写规格：用 ~/.claude/skills/implement-spec-split/templates/brief-mock.md 写方向卡和 Brief，交给 codex-worker.sh 出页面并自检；你不看截图和 HTML，只按它产出的 mock/manifest.json 调一次 mockit_submit，等用户拍板后用 mockit_get_review 取裁决。选中的页面复制到仓库 docs/<主题>-mock/，规格引用它作为界面验收基准。'
  else
    MOCK_CLAUSE="涉及界面或交互取舍、用户要看到才能定时，先出 mock 再写规格：按 ~/.claude/skills/implement-spec-split/templates/brief-mock.md 的「方向卡」「产出」「验收」自己做候选页面和自检脚本，全部写在 $RUN_DIR/mock/ 下，node $RUN_DIR/mock/check.mjs 全部 PASS 后只调一次 mockit_submit，等用户拍板后用 mockit_get_review 取裁决。选中的页面复制到仓库 docs/<主题>-mock/，规格引用它作为界面验收基准。"
  fi
  # Orca's worker preamble comes ahead of the Task, so a leading slash command
  # in it is not expanded by the CLI any more (docs/orca-smoke-2026-11-27.md,
  # round 2, G): the session is told to load the upstream skill with the Skill
  # tool. The handoff is reported the way a worker reports, with the complete
  # worker_done command the preamble gives: Orca rejects one without --task-id
  # (same record, B).
  PROMPT=$(cat <<EOF
请先用 Skill 工具加载上游技能 ${UPSTREAM}（Orca 的 worker 前言排在本消息前面，斜杠命令不再由 CLI 展开），再把下面的话题和交接约定当作它的输入；不要让用户手敲斜杠命令。
你是一个 Design session，由 Orchestrator 从当前仓库转来。请处理用户话题：
$TOPIC

上游技能：${UPSTREAM}（已由上面的 Skill 调用加载，不要重复加载）
$KIND_INSTRUCTIONS

运行目录：$RUN_DIR

交接约定：
1. 讨论完成后，在同一会话接着做 to-spec 和 to-tickets；to-tickets 照常让用户确认拆分。
   $MOCK_CLAUSE
2. 上下文过重、一次要产出多份规格，或 main 已经变化时，提示用户另开 Design session，不要硬塞进本次会话。
3. GLOSSARY、ADR 等文档改动由你自己 commit 并 push。
4. 写不超过 30 行的 $RUN_DIR/handoff.md，包含：规格号、票号、新增或改动的 ADR 与术语、给 Orchestrator 的待办。实现类待办只写「实现规格 #N」（多份写各自规格号和先后顺序），不写由谁、用 worker 还是子代理、串行还是并行去做：执行方式由 /implement-spec-split 决定。
5. 最后按 Orca 前言给的完整命令上报 worker_done：必须带 --task-id，--outcome succeeded，--report-path 指向 $RUN_DIR/handoff.md。发送后本会话会被自动关闭，发送就是最后一步；不要用别的命令上报。
${EARLY_HANDOFF}
EOF
  )
  printf '%s' "$PROMPT" > "$RUN_DIR/prompt.txt" ||
    die 6 "could not persist the prompt to $RUN_DIR/prompt.txt"
  # The terminal runs the route's launcher and records its exit code: an Orca
  # terminal outlives what was typed into it, so `terminal wait --for exit`
  # alone would not notice the session ending. Each argument is quoted for the
  # terminal's shell (the GLM launchers' model ends in [1m], a glob character).
  # The Task is delivered by worker-start below, not on this command line.
  # The official claude profile starts without --dangerously-skip-permissions,
  # so its TUI asks before push and Bash as in any session the user opens by
  # hand (the user is present in a Design session); the other profiles keep the
  # flag, as the GLM terminal path always has.
  if [ "$ROUTE_PROFILE" = claude ]; then
    PERMISSION_ARGS=()
  else
    PERMISSION_ARGS=(--dangerously-skip-permissions)
  fi
  LAUNCH_COMMAND="$(printf ' %q' "${LAUNCH_ARGS[0]}" ${PERMISSION_ARGS[@]+"${PERMISSION_ARGS[@]}"} "${LAUNCH_ARGS[@]:1}")"
  LAUNCH_COMMAND="${LAUNCH_COMMAND# }; echo \$? > $(printf '%q' "$RUN_DIR/exit-code")"
  LAUNCH_JSON=$(orca_terminal_create "$REPO_ROOT" "Design session $KIND" "$LAUNCH_COMMAND" --focus \
    2>"$RUN_DIR/launch.err") ||
    die 6 "orca terminal create failed: $(cat "$RUN_DIR/launch.err")"
  printf '%s\n' "$LAUNCH_JSON" > "$RUN_DIR/launch.json"
  # Without the handle the wait could neither follow nor close the terminal.
  SESSION_HANDLE=$(terminal_handle_from_json "$RUN_DIR/launch.json")
  case $? in
    0) ;;
    2) die 6 'orca terminal create returned no terminal handle' ;;
    *) die 6 'orca terminal create JSON could not be parsed' ;;
  esac
  WORKER_START_JSON=$(orca_orchestration_worker_start "$RUN_ID" \
    --terminal "$SESSION_HANDLE" --spec-file "$RUN_DIR/prompt.txt" \
    --timeout-ms "$START_TIMEOUT_MS" 2>"$RUN_DIR/worker-start.err") ||
    die 6 "orca orchestration worker-start failed for terminal $SESSION_HANDLE (close it by hand if the launcher is still running there): $(cat "$RUN_DIR/worker-start.err")"
  printf '%s\n' "$WORKER_START_JSON" > "$RUN_DIR/worker-start.json"
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

# Whether handoff.md opens with the marker. A Markdown heading or bullet
# prefix, a closing punctuation and a half-width colon do not hide it; the
# marker on any later line does not count.
is_early_handoff() {
  node -e '
    const fs = require("fs");
    const first = fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/, 1)[0];
    const line = first.replace(/^\s*(?:#+|[-*])\s*/, "")
      .replace(/[\s。.！!]*$/, "")
      .replace(":", "：");
    process.exit(line === process.argv[2] ? 0 : 1);
  ' "$1" "$EARLY_HANDOFF_MARKER" 2>/dev/null
}

accept_handoff() {
  handoff=$1
  [ -f "$handoff" ] ||
    die 6 "handoff report is missing: $handoff"
  printf '%s\n' "$handoff"
  if is_early_handoff "$handoff"; then
    printf 'design-session: 提前交接：handoff.md 首行是「%s」\n' "$EARLY_HANDOFF_MARKER" >&2
  fi
  cleanup_wait
  # Bring the user back to the Orchestrator terminal that started this wait.
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    orca_terminal_switch "$ORCA_TERMINAL_HANDLE" > "$RUN_DIR/switch.out" 2>&1 ||
      printf 'design-session: 未能切回主会话（%s），请手动切换\n' "$ORCA_TERMINAL_HANDLE" >&2
  fi
  # The Design session's job ends with the handoff; close its tab so it stops
  # holding an Orca slot and Opus quota (Orca does not close a terminal it did
  # not open). ISS_DESIGN_KEEP_SESSION=1 keeps it.
  if [ -n "$SESSION_HANDLE" ] && [ "${ISS_DESIGN_KEEP_SESSION:-}" != 1 ]; then
    sleep "${ISS_DESIGN_CLOSE_DELAY:-3}"
    orca_terminal_close "$SESSION_HANDLE" > "$RUN_DIR/close.out" 2>&1 ||
      printf 'design-session: 未能关闭 Design session（%s），请手动关闭\n' "$SESSION_HANDLE" >&2
  fi
  exit 0
}

# Ends the wait for a Design session that stopped without handing off. Without
# an argument the ending was observed through the one terminal wait; with one
# it is the exit code the launcher wrote to $RUN_DIR/exit-code.
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

# One terminal wait for the whole timeout, in the background: it returns as
# soon as the session's terminal exits. Together with the exit code file this
# is how an ended session is noticed; nothing asks Orca in a loop.
if [ -n "$SESSION_HANDLE" ]; then
  orca_terminal_wait "$SESSION_HANDLE" exit "$TIMEOUT_MS" \
    > "$RUN_DIR/session-wait.out" 2> "$RUN_DIR/session-wait.err" &
  SESSION_WAIT_PID=$!
fi

# Watches the local signs only while the blocking check runs: the exit code
# file, and the two background processes. Each Orca call below is one blocking
# wait; none of them is repeated inside this loop.
monitor_check() {
  while kill -0 "$CHECK_PID" 2>/dev/null; do
    sleep "$POLL_SECONDS"
    if [ -s "$RUN_DIR/check.out" ]; then
      return 0
    fi
    if [ -s "$RUN_DIR/exit-code" ]; then
      session_ended "$(tr -d '[:space:]' < "$RUN_DIR/exit-code")"
    fi
    if [ -n "$SESSION_WAIT_PID" ] && ! kill -0 "$SESSION_WAIT_PID" 2>/dev/null; then
      wait "$SESSION_WAIT_PID"
      SESSION_WAIT_STATUS=$?
      SESSION_WAIT_PID=
      if [ "$SESSION_WAIT_STATUS" -eq 0 ]; then
        session_ended
      fi
    fi
  done
}

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
  # The coordinator of this Run takes its mail: the handoff message is addressed
  # to this wait and to nothing else.
  orca_orchestration_check "$RUN_ID" --take --timeout-ms "$REMAINING_MS" \
    > "$RUN_DIR/check.out" 2> "$RUN_DIR/check.err" &
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
