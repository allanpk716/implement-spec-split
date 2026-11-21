#!/usr/bin/env bash
# Run one Opus review: a non-interactive judgment pass on the official Claude
# subscription, outside the calling Orchestrator session.
#
# Usage:
#   opus-review.sh --kind code --input <branch-or-fixed-point>
#                   --out <findings-file> [--cwd <repository>]
#                   [--timeout <seconds>]
#   opus-review.sh --kind draft --input <draft-file> --out <findings-file>
#                   [--cwd <directory>] [--timeout <seconds>]
#   opus-review.sh --kind diagnose --input <failure-record-file>
#                   --out <findings-file> [--cwd <directory>]
#                   [--timeout <seconds>]
#
# --kind code reviews the repository at --cwd relative to the given fixed point
# through mattpocock-skills:code-review, with both review-axis subagents pinned
# to opus. --kind draft reviews a draft spec/ticket/research result.
# --kind diagnose diagnoses a failed worker/run and recommends 续跑, 改 Brief, or
# 停车. Every kind must mark items that need a human tradeoff under
# “需要人取舍”. --cwd defaults to the current directory. --timeout defaults to
# 3600 seconds for code and 1200 seconds for draft and diagnose.
#
# This wrapper removes GLM/proxy Anthropic environment mappings before invoking
# claude, then runs `claude -p --model opus` with read-only tools. Claude's final
# standard output is written atomically to --out. It never downgrades to GLM.
#
# Exit codes:
#   0  success; findings are in --out
#   2  authentication failed
#   3  quota exhausted or rate limited
#   4  transient service or network unavailability
#   5  timed out
#   6  other claude or findings-write error
#  64  bad usage

set -u

ORIG_PWD=$(pwd -P)

KIND=""
INPUT=""
OUT=""
CWD="$ORIG_PWD"
TIMEOUT=""
POLL_INTERVAL=0.2
CLAUDE_PID=""
OUTPUT_TMP=""
ERROR_TMP=""
TIMED_OUT=false

die() {
  echo "opus-review: $*" >&2
  exit 64
}

cleanup() {
  local rc="${1:-$?}"
  trap - EXIT HUP INT TERM
  if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill_claude_tree "$CLAUDE_PID" 2>/dev/null || true
  fi
  [ -z "$OUTPUT_TMP" ] || rm -f "$OUTPUT_TMP" 2>/dev/null || true
  [ -z "$ERROR_TMP" ] || rm -f "$ERROR_TMP" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)
      [ $# -ge 2 ] || die "--kind needs a value"
      KIND=$2; shift 2 ;;
    --input)
      [ $# -ge 2 ] || die "--input needs a value"
      INPUT=$2; shift 2 ;;
    --out)
      [ $# -ge 2 ] || die "--out needs a value"
      OUT=$2; shift 2 ;;
    --cwd)
      [ $# -ge 2 ] || die "--cwd needs a value"
      CWD=$2; shift 2 ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a value"
      TIMEOUT=$2; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

case "$KIND" in
  code|draft|diagnose) ;;
  "") die "--kind is required (code, draft, or diagnose)" ;;
  *) die "--kind must be code, draft, or diagnose (got $KIND)" ;;
esac
if [ -z "$TIMEOUT" ]; then
  if [ "$KIND" = code ]; then
    TIMEOUT=3600
  else
    TIMEOUT=1200
  fi
fi
[ -n "$INPUT" ] || die "--input is required"
[ -n "$OUT" ] || die "--out is required"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer (got $TIMEOUT)"
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer (got $TIMEOUT)"
[ -d "$CWD" ] || die "--cwd must be an existing directory: $CWD"
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || die "--cwd is not readable: $CWD"

if [ "$KIND" != code ]; then
  case "$INPUT" in
    /*) ;;
    *) INPUT="$ORIG_PWD/$INPUT" ;;
  esac
  [ -f "$INPUT" ] || die "--input must be an existing file for --kind $KIND: $INPUT"
  [ -r "$INPUT" ] || die "--input is not readable: $INPUT"
fi

OUT_DIR=$(dirname "$OUT")
[ -d "$OUT_DIR" ] || die "--out parent directory must exist: $OUT_DIR"
[ ! -d "$OUT" ] || die "--out must be a file, not a directory: $OUT"

ALLOWED_TOOLS=(
  Read
  Grep
  Glob
  'Bash(git status:*)'
  'Bash(git diff:*)'
  'Bash(git show:*)'
  'Bash(git log:*)'
  'Bash(git rev-parse:*)'
  'Bash(git merge-base:*)'
  'Bash(git ls-files:*)'
  'Bash(git cat-file:*)'
  'Bash(gh issue view:*)'
  'Bash(gh pr view:*)'
  'Bash(gh pr diff:*)'
  Skill
  Agent
)
DISALLOWED_TOOLS=(
  Edit
  Write
  MultiEdit
  NotebookEdit
  WebFetch
  WebSearch
)
CLAUDE_ARGS=(
  -p
  --model opus
  --allowedTools "${ALLOWED_TOOLS[@]}"
  --disallowedTools "${DISALLOWED_TOOLS[@]}"
  --permission-prompts none
)

case "$KIND" in
  code)
    PROMPT="You are an Opus review running outside the calling session.
Repository: $CWD
Review fixed point: $INPUT

Required procedure:
1. Call the Skill tool with exactly \`mattpocock-skills:code-review\` (not the built-in code-review skill).
2. Review the current repository state relative to the fixed point above.
3. When that skill spawns its Standards and Spec review-axis subagents, explicitly set each subagent model to \`opus\`; neither subagent may inherit or downgrade the model.
4. Read whatever repository context and git history you need. Do not modify files.

Output requirements:
- Return the review findings themselves, suitable for an Orchestrator to act on.
- End with a section headed exactly \`## 需要人取舍\`.
- Put every finding that needs a human decision or tradeoff in that section. If there are none, put only \`无\` in it.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  draft)
    PROMPT="You are an Opus review running outside the calling session.
Draft to review: $INPUT

Read the complete draft. It may be a draft specification, ticket, or research result. Judge whether:
- its problem, solution, scope, and acceptance criteria are coherent and testable;
- important design decisions are actually decided, rather than hidden behind optimistic language;
- it conflicts with repository terms, ADRs, or the evidence supplied in the draft;
- its risks and non-goals are stated clearly enough for implementation.

Use read-only tools for any repository context you need. Do not modify files.

Output requirements:
- Return findings as concrete, numbered items; separate mechanical fixes from design concerns.
- Recommend whether the draft is ready for implementation and what must change first.
- End with a section headed exactly \`## 需要人取舍\`.
- Put every unresolved judgment call that needs a human tradeoff in that section. If there are none, put only \`无\` in it.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  diagnose)
    PROMPT="You are an Opus review running outside the calling session.
Failure record: $INPUT

Read the complete failure record and inspect the relevant read-only repository context. Diagnose the root cause; do not settle for restating the final symptom. Distinguish evidence from conjecture and check alternative explanations.

Recommend exactly one next action from:
1. 续跑 — explain what can safely continue and why the failure is understood;
2. 改 Brief — give the concrete Brief changes needed before another run;
3. 停车 — explain why continuing would waste work or hide a systemic problem.

Use read-only tools only. Do not modify files.

Output requirements:
- State the root cause, supporting evidence, and recommended action.
- Include any follow-up checks needed to confirm the diagnosis.
- End with a section headed exactly \`## 需要人取舍\`.
- Put every diagnosis or remedy that requires a human tradeoff in that section. If there are none, put only \`无\` in it.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
esac

command -v claude >/dev/null 2>&1 || {
  echo "opus-review: claude executable not found in PATH" >&2
  exit 6
}

run_claude() {
  (
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL \
      CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE FLASH_ORCHESTRATOR
    local name rest
    while IFS='=' read -r name rest; do
      if [[ "$name" =~ ^ANTHROPIC_DEFAULT_[A-Za-z0-9_]+_MODEL$ ]]; then
        unset "$name"
      fi
    done < <(env)
    cd "$CWD" || exit 6
    exec claude "${CLAUDE_ARGS[@]}" "$PROMPT"
  )
}

tree_pids() {
  PID_ROOT="$1" node -e '
    const {spawnSync} = require("child_process");
    const table = spawnSync("ps", ["-A", "-o", "pid=", "-o", "ppid="], {encoding: "utf8"});
    if (table.error || table.status !== 0) process.exit(1);
    const children = new Map();
    for (const line of String(table.stdout || "").split("\n")) {
      const match = line.trim().match(/^(\d+)\s+(\d+)$/);
      if (!match) continue;
      children.set(+match[2], [...(children.get(+match[2]) || []), +match[1]]);
    }
    const root = +process.env.PID_ROOT, seen = new Set([root]), queue = [root], out = [root];
    while (queue.length) {
      for (const child of children.get(queue.shift()) || []) {
        if (seen.has(child)) continue;
        seen.add(child); queue.push(child); out.push(child);
      }
    }
    console.log(out.join(" "));
  ' 2>/dev/null
}

kill_claude_tree() {
  local root="$1" pid_text pids=() child alive i
  pid_text=$(tree_pids "$root") || pid_text="$root"
  read -r -a pids <<< "$pid_text"
  [ ${#pids[@]} -gt 0 ] || pids=("$root")
  for child in "${pids[@]}"; do kill -TERM "$child" 2>/dev/null || true; done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alive=""
    for child in "${pids[@]}"; do kill -0 "$child" 2>/dev/null && alive=1; done
    [ -z "$alive" ] && return 0
    sleep 0.1
  done
  for child in "${pids[@]}"; do kill -KILL "$child" 2>/dev/null || true; done
  sleep 0.1
  for child in "${pids[@]}"; do kill -0 "$child" 2>/dev/null && return 1; done
  return 0
}

OUTPUT_TMP=$(mktemp "$OUT.tmp.XXXXXX") || exit 6
ERROR_TMP=$(mktemp "$OUT.stderr.XXXXXX") || exit 6

run_claude > "$OUTPUT_TMP" 2> "$ERROR_TMP" &
CLAUDE_PID=$!
START=$(date +%s)
while kill -0 "$CLAUDE_PID" 2>/dev/null; do
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
    TIMED_OUT=true
    kill_claude_tree "$CLAUDE_PID" 2>/dev/null || true
    break
  fi
  sleep "$POLL_INTERVAL"
done
wait "$CLAUDE_PID"
CLAUDE_EXIT=$?
CLAUDE_PID=""

if $TIMED_OUT; then
  echo "opus-review: timed out after ${TIMEOUT}s; no findings written" >&2
  exit 5
fi

show_claude_error() {
  echo "opus-review: $1 (claude exit $CLAUDE_EXIT); claude output follows" >&2
  sed -n '1,40p' "$ERROR_TMP" >&2
  sed -n '1,40p' "$OUTPUT_TMP" >&2
}

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  if grep -Eqi '(^|[^[:alnum:]])(529|503)([^[:alnum:]]|$)|overloaded|connection (error|refused|reset)|network error|ENOTFOUND|ECONNREFUSED|ETIMEDOUT' \
      "$OUTPUT_TMP" "$ERROR_TMP" 2>/dev/null; then
    show_claude_error "transient service or network unavailable"
    exit 4
  elif grep -Eqi '(^|[^[:alnum:]])(429|402)([^[:alnum:]]|$)|usage limit|quota|rate limit|too many requests' \
      "$OUTPUT_TMP" "$ERROR_TMP" 2>/dev/null; then
    show_claude_error "quota exhausted or rate limited"
    exit 3
  elif grep -Eqi '(^|[^[:alnum:]])(401|403)([^[:alnum:]]|$)|authenticat|unauthori[sz]ed|invalid api key|api key|login required|not logged in' \
      "$OUTPUT_TMP" "$ERROR_TMP" 2>/dev/null; then
    show_claude_error "authentication failed"
    exit 2
  else
    show_claude_error "claude failed"
    exit 6
  fi
fi

if ! grep -Eq '[^[:space:]]' "$OUTPUT_TMP" 2>/dev/null; then
  echo "opus-review: claude produced empty findings" >&2
  exit 6
fi

if ! mv -f "$OUTPUT_TMP" "$OUT"; then
  echo "opus-review: cannot write findings to $OUT" >&2
  exit 6
fi
OUTPUT_TMP=""
exit 0
