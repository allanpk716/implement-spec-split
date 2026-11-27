#!/usr/bin/env bash
# Run one Opus review: a non-interactive judgment pass outside the calling
# Orchestrator session, on the model the Stage route table names for the stage.
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
# Stage route (GLOSSARY.md "Stage route", ADR 0004). The route is read from the
# table (scripts/stage-route.sh, which only the user changes, as /grill-router)
# on every invocation, so a session that is already executing switches at its
# next review: --kind code and draft read the review stage, --kind diagnose the
# diagnosis stage. The launcher, --model and --effort all come from the route.
# This wrapper removes the GLM/proxy Anthropic environment mappings and then
# runs the route's launcher headless with read-only tools: the claude profile
# is the official claude; any other profile (claude-glm today) is its own
# launcher, which sets its GLM mappings on top of the same clean environment,
# exactly as it does for a session the user starts by hand. When the profile is
# not claude, official Opus is not called: the route is reported on stderr. A
# code review's two review-axis subagents are pinned to opus on every profile,
# never to the route's model name: the Agent tool takes only the aliases
# sonnet|opus|haiku|fable, and the GLM launcher maps opus to its GLM model. The
# repair retry runs on the same route. The model is never changed here, and
# nothing falls back to another one.
#
# Every findings file starts with the route that produced it, on the default
# route as on a switched one, then a blank line, then the model's findings:
#   路由：审查（review）claude-glm / glm-5.4 / medium · 2026-11-27 16:30:00 +0800
#
# Exit codes:
#   0  success; findings are in --out
#   2  authentication failed
#   3  quota exhausted or rate limited
#   4  transient service or network unavailability
#   5  timed out
#   6  other launcher or findings-write error, among them the route's launcher
#      not found in PATH
#   7  findings under “需要人取舍” still lack a 推荐： or 可自动采纳：是|否
#      line after one repair retry; the offending items are listed on stderr
#  64  bad usage, among it a route that cannot be read from the Stage route
#      table: nothing starts with an empty model

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
RETRY_TMP=""
RETRY_ERR=""
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
  [ -z "$RETRY_TMP" ] || rm -f "$RETRY_TMP" 2>/dev/null || true
  [ -z "$RETRY_ERR" ] || rm -f "$RETRY_ERR" 2>/dev/null || true
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
      sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
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

# Read once per invocation: the route of the stage this kind judges on, from the
# Stage route table. A route that cannot be read is a usage error: the table is
# the only source of the model, so nothing starts with an empty one.
case "$KIND" in
  code|draft) STAGE=review; STAGE_LABEL='审查（review）' ;;
  diagnose) STAGE=diagnosis; STAGE_LABEL='诊断（diagnosis）' ;;
esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Prints one field of the stage's route as the table names it, or exits 64.
# The table's own hints (a line outside the catalog, an unreadable file, the
# first run's migration notes) went to stderr from the --launch read before
# this one and are silenced here, where they would only repeat.
route_field() {
  local value
  value=$("$HERE/stage-route.sh" --print "$STAGE" "$1" 2>/dev/null) ||
    die "cannot read the $STAGE route's $1 from the Stage route table (scripts/stage-route.sh --print $STAGE $1 exited $?)"
  [ -n "$value" ] || die "scripts/stage-route.sh --print $STAGE $1 printed nothing for the $STAGE route"
  printf '%s' "$value"
}

# The command that starts the route's profile headless with the route's model
# and effort, one argument per line, the launcher first. The model is in the
# profile's own form on the command line (the GLM launchers take glm-5.4[1m]);
# the reports below name it as the table does.
LAUNCH=$("$HERE/stage-route.sh" --launch "$STAGE" headless) ||
  die "cannot read the $STAGE route's launch command from the Stage route table (scripts/stage-route.sh --launch $STAGE headless exited $?)"
[ -n "$LAUNCH" ] || die "scripts/stage-route.sh --launch printed nothing for the $STAGE route"
ROUTE_ARGS=()
while IFS= read -r arg; do ROUTE_ARGS+=("$arg"); done <<< "$LAUNCH"
ROUTE_PROFILE=$(route_field profile)
ROUTE_MODEL=$(route_field model)
ROUTE_EFFORT=$(route_field effort)

# Only the claude profiles start a headless Claude Code review: the review and
# diagnosis stages are verified for claude and claude-glm alone (the table's
# catalog).
LAUNCHER=${ROUTE_ARGS[0]:-}
case "$LAUNCHER" in
  claude|claude-glm|claude-flash) ;;
  *) die "the $STAGE route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, and the profile '$LAUNCHER' cannot run a headless review" ;;
esac
command -v "$LAUNCHER" >/dev/null 2>&1 || {
  echo "opus-review: the $STAGE route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT, but its launcher '$LAUNCHER' was not found in PATH" >&2
  exit 6
}

# The route is the user's decision, never a downgrade made here. Official Opus
# is called only by the claude profile on the model opus; any other route is
# said on stderr, and the prompt names the model executing it.
if [ "$ROUTE_PROFILE/$ROUTE_MODEL" = claude/opus ]; then
  REVIEWER_LINE="You are an Opus review running outside the calling session."
else
  echo "opus-review: the $STAGE route is $ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT (set by the user with /grill-router, scripts/stage-route.sh): this review runs on $ROUTE_MODEL through '$LAUNCHER'; official Opus is not called" >&2
  REVIEWER_LINE="You are an Opus review running outside the calling session, executed by $ROUTE_MODEL, the model the user's $STAGE route names in place of Opus."
fi

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
# The route's launch command comes first, so the array starts with the
# launcher itself; the tool lists and the permission rule are the same on every
# route.
CLAUDE_ARGS=(
  "${ROUTE_ARGS[@]}"
  --allowedTools "${ALLOWED_TOOLS[@]}"
  --disallowedTools "${DISALLOWED_TOOLS[@]}"
  --permission-prompts none
)

# The review axes are pinned to opus on every profile, never to $ROUTE_MODEL:
# the Agent tool's model takes only the aliases sonnet|opus|haiku|fable, and the
# GLM launcher maps opus to its GLM model, so the route's own name (glm-5.4)
# would be rejected by the tool's schema.
case "$KIND" in
  code)
    PROMPT="$REVIEWER_LINE
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
- For each item in that section, list the mutually exclusive options with their costs, then a line \`推荐：<option> — <reason>\`; if you genuinely cannot recommend one, write \`推荐：无 — <why>\` instead of omitting the line.
- After that line, add \`可自动采纳：是\` when an unattended Run may simply apply your recommendation and land, or \`可自动采纳：否 — <why>\` when it must stop for a human: only when you wrote \`推荐：无\`, the choice is irreversible or outward-facing (data deletion, publishing, external services, production deployment), or it needs a human action or knowledge only a human has. A recommendation that merely changes code, wording, or an internal contract is \`是\`.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  draft)
    PROMPT="$REVIEWER_LINE
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
- For each item in that section, list the mutually exclusive options with their costs, then a line \`推荐：<option> — <reason>\`; if you genuinely cannot recommend one, write \`推荐：无 — <why>\` instead of omitting the line.
- After that line, add \`可自动采纳：是\` when an unattended Run may simply apply your recommendation and land, or \`可自动采纳：否 — <why>\` when it must stop for a human: only when you wrote \`推荐：无\`, the choice is irreversible or outward-facing (data deletion, publishing, external services, production deployment), or it needs a human action or knowledge only a human has. A recommendation that merely changes code, wording, or an internal contract is \`是\`.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  diagnose)
    PROMPT="$REVIEWER_LINE
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
- For each item in that section, list the mutually exclusive options with their costs, then a line \`推荐：<option> — <reason>\`; if you genuinely cannot recommend one, write \`推荐：无 — <why>\` instead of omitting the line.
- After that line, add \`可自动采纳：是\` when an unattended Run may simply apply your recommendation and land, or \`可自动采纳：否 — <why>\` when it must stop for a human: only when you wrote \`推荐：无\`, the choice is irreversible or outward-facing (data deletion, publishing, external services, production deployment), or it needs a human action or knowledge only a human has. A recommendation that merely changes code, wording, or an internal contract is \`是\`.
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
esac

run_claude() {
  local prompt=$1
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
    # A GLM launcher sets its own GLM mappings on top of this clean
    # environment, exactly as it does for a session the user starts by hand.
    exec "${CLAUDE_ARGS[@]}" "$prompt"
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

show_claude_error() {
  local message=$1 out=$2 err=$3
  echo "opus-review: $message (claude exit $CLAUDE_EXIT); claude output follows" >&2
  sed -n '1,40p' "$err" >&2
  sed -n '1,40p' "$out" >&2
}

classify_claude_exit() {
  local out=$1 err=$2
  if grep -Eqi '(^|[^[:alnum:]])(529|503)([^[:alnum:]]|$)|overloaded|connection (error|refused|reset)|network error|ENOTFOUND|ECONNREFUSED|ETIMEDOUT' \
      "$out" "$err" 2>/dev/null; then
    show_claude_error "transient service or network unavailable" "$out" "$err"
    return 4
  elif grep -Eqi '(^|[^[:alnum:]])(429|402)([^[:alnum:]]|$)|usage limit|quota|rate limit|too many requests' \
      "$out" "$err" 2>/dev/null; then
    show_claude_error "quota exhausted or rate limited" "$out" "$err"
    return 3
  elif grep -Eqi '(^|[^[:alnum:]])(401|403)([^[:alnum:]]|$)|authenticat|unauthori[sz]ed|invalid api key|api key|login required|not logged in' \
      "$out" "$err" 2>/dev/null; then
    show_claude_error "authentication failed" "$out" "$err"
    return 2
  else
    show_claude_error "claude failed" "$out" "$err"
    return 6
  fi
}

# One claude pass into OUT_FILE (stderr in ERR_FILE). Returns the exit code the
# caller must use: 0, or 2/3/4/5/6 as classified above. CLAUDE_EXIT is set for
# show_claude_error.
run_claude_pass() {
  local prompt=$1 out=$2 err=$3 start now
  TIMED_OUT=false
  run_claude "$prompt" > "$out" 2> "$err" &
  CLAUDE_PID=$!
  start=$(date +%s)
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
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
    return 5
  fi
  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    classify_claude_exit "$out" "$err"
    return $?
  fi
  return 0
}

# Prints the top-level items of the “## 需要人取舍” section that lack a
# `推荐：` line or a `可自动采纳：是|否` line. Prints nothing when the section
# is absent or only says 无; prints NONE when it exists but has no real item.
missing_tradeoff_marks() {
  awk '
    function flush() {
      if (item != "" && !(has_rec && has_auto)) {
        gsub(/[\r\t]+/, " ", item)
        print item
      }
    }
    BEGIN { insec = 0; item = ""; has_rec = 0; has_auto = 0; meaningful = 0; saw_item = 0 }
    /^##[[:space:]]+需要人取舍[[:space:]]*$/ { insec = 1; next }
    insec && (/^##[[:space:]]/ || /^#[[:space:]]/) { insec = 0 }
    insec {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^###[#]*[[:space:]]/) next
      if (line ~ /^[[:space:]]*(无|（无）|\(无\)|none|NONE|None|n\/a|N\/A|-|—|没有)[[:space:]]*$/) next
      meaningful = 1
      if (line ~ /^[[:space:]]*([0-9]+[.、)]|[-*+])[[:space:]]+/ && line !~ /^[[:space:]]/) {
        # Free text before the first list item is a preamble, not an item;
        # drop it instead of reporting it as an unmarked item.
        if (saw_item) flush()
        item = line
        has_rec = (line ~ /推荐[*]*[：:]/)
        has_auto = (line ~ /可自动采纳[*]*[：:][*[:space:]]*(是|否)/)
        saw_item = 1
        next
      }
      if (item == "") item = line
      if (line ~ /推荐[*]*[：:]/) has_rec = 1
      if (line ~ /可自动采纳[*]*[：:][*[:space:]]*(是|否)/) has_auto = 1
    }
    END {
      if (insec && meaningful == 0) { print "NONE"; exit }
      flush()
    }
  ' "$1"
}

repair_prompt() {
  local original=$1 missing=$2
  # The original output is passed through verbatim (no expansion), so findings
  # containing `$`, backticks or backslashes cannot turn into commands here.
  printf '%s\n' 'You are the same Opus review, asked to repair your own previous output.'
  printf '%s\n' ''
  printf '%s\n' 'Your previous final response is reproduced verbatim between <previous-output> and </previous-output>.'
  printf '%s\n' ''
  printf '%s\n' 'In its section headed `## 需要人取舍`, the items listed between <missing-items> and </missing-items> lack the required `推荐：` line and/or the required `可自动采纳：是` or `可自动采纳：否 — <why>` line.'
  printf '%s\n' ''
  printf '%s\n' 'Repair only those items: add the missing `推荐：<option> — <reason>` line and the missing `可自动采纳：是` or `可自动采纳：否 — <why>` line to each of them, following the same rules as the original request. Keep every other line, heading, finding and wording exactly as it was: do not summarise, reorder, add sections, or drop content. Output the complete corrected response.'
  printf '%s\n' '' '<previous-output>'
  cat "$original"
  printf '%s\n' '</previous-output>' '' '<missing-items>'
  printf '%s\n' "$missing"
  printf '%s\n' '</missing-items>'
}

run_claude_pass "$PROMPT" "$OUTPUT_TMP" "$ERROR_TMP"
PASS_RC=$?
[ "$PASS_RC" -eq 0 ] || exit "$PASS_RC"

if ! grep -Eq '[^[:space:]]' "$OUTPUT_TMP" 2>/dev/null; then
  echo "opus-review: claude produced empty findings" >&2
  exit 6
fi

MISSING_MARKS=$(missing_tradeoff_marks "$OUTPUT_TMP")
case "$MISSING_MARKS" in
  ''|NONE) ;;
  *)
    echo "opus-review: 需要人取舍 items lack 推荐：/可自动采纳： lines; asking the same model to repair them once:" >&2
    printf '%s\n' "$MISSING_MARKS" >&2
    RETRY_PROMPT=$(repair_prompt "$OUTPUT_TMP" "$MISSING_MARKS")
    RETRY_TMP=$(mktemp "$OUT.repair.XXXXXX") || exit 6
    RETRY_ERR=$(mktemp "$OUT.repair.stderr.XXXXXX") || exit 6
    run_claude_pass "$RETRY_PROMPT" "$RETRY_TMP" "$RETRY_ERR"
    RETRY_RC=$?
    if [ "$RETRY_RC" -ne 0 ]; then
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit "$RETRY_RC"
    fi
    if ! grep -Eq '[^[:space:]]' "$RETRY_TMP" 2>/dev/null; then
      echo "opus-review: claude produced empty findings during the repair retry" >&2
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit 6
    fi
    STILL_MISSING=$(missing_tradeoff_marks "$RETRY_TMP")
    if ! grep -Eq '^##[[:space:]]+需要人取舍[[:space:]]*$' "$RETRY_TMP"; then
      echo "opus-review: the repair retry dropped ## 需要人取舍; refusing to accept it" >&2
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit 7
    fi
    if [ "$STILL_MISSING" = NONE ]; then
      echo "opus-review: the repair retry turned ## 需要人取舍 into 无; refusing to drop the items" >&2
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit 7
    fi
    if [ -n "$STILL_MISSING" ]; then
      echo "opus-review: 需要人取舍 items still lack 推荐：/可自动采纳： lines after one repair retry:" >&2
      printf '%s\n' "$STILL_MISSING" >&2
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit 7
    fi
    if ! mv -f "$RETRY_TMP" "$OUTPUT_TMP"; then
      echo "opus-review: cannot keep the repaired findings" >&2
      rm -f "$RETRY_TMP" "$RETRY_ERR"
      exit 6
    fi
    rm -f "$RETRY_ERR"
    ;;
esac

# Every findings file names the route that produced it on its first line: a
# route other than the official Opus one is not the review the Orchestrator
# expects, and on the default route the same line is what lets a report tell
# the two apart.
PROVENANCE_TMP=$(mktemp "$OUT.tmp.XXXXXX") || exit 6
{ printf '路由：%s%s / %s / %s · %s\n\n' \
    "$STAGE_LABEL" "$ROUTE_PROFILE" "$ROUTE_MODEL" "$ROUTE_EFFORT" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  cat "$OUTPUT_TMP"
} > "$PROVENANCE_TMP" || { rm -f "$PROVENANCE_TMP"; exit 6; }
mv -f "$PROVENANCE_TMP" "$OUTPUT_TMP" || { rm -f "$PROVENANCE_TMP"; exit 6; }

if ! mv -f "$OUTPUT_TMP" "$OUT"; then
  echo "opus-review: cannot write findings to $OUT" >&2
  exit 6
fi
OUTPUT_TMP=""
exit 0
