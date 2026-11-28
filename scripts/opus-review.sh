#!/usr/bin/env bash
# One review on the model the Stage route table names for the stage, and the
# decision of where it runs. Out of session (the default form): a
# non-interactive judgment pass that the calling Orchestrator session starts
# and waits for. In session: read-only subagents of the calling session, whose
# findings this wrapper stamps (--where says which runs; --prompt,
# --repair-prompt and --stamp are the in-session form).
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
#   opus-review.sh --where --kind code|draft|diagnose
#   opus-review.sh --prompt --kind code --input <fixed-point>
#                   --out <findings-file> [--cwd <repository>]
#   opus-review.sh --prompt --kind draft|diagnose --input <file>
#                   --out <findings-file> [--cwd <directory>]
#   opus-review.sh --stamp --kind code|draft|diagnose --out <findings-file>
#                   (the findings on stdin)
#   opus-review.sh --repair-prompt --kind code|draft|diagnose
#                   --out <findings-file>
#                   (the brief of the repair, after a --stamp that exited 7)
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
# Where a review runs (票 #84, 2026-11-28; MAINTAINING 第 24 条's date note).
# The route decides, never the session: SKILL.md asks --where once per review
# and branches on its output alone. --where prints in-session or
# out-of-session on stdout and one line on stderr,
# 审查中（<profile> / <model>，会话内|出会话） followed by the reason (诊断中
# for --kind diagnose), written to be relayed to the user as it is: a review
# is named by its route, never "Opus" when the route is not Opus.
#   out-of-session  The route's profile is claude, an official model: the
#                   review runs as it always did, and a GLM session never
#                   passes a subagent off as that review (MAINTAINING 第 24
#                   条). Or the route is another profile (claude-glm today)
#                   but this session's subagents are not pinned to the route's
#                   model: CLAUDE_CODE_SUBAGENT_MODEL is unset, or differs
#                   from the route's model once its [1m] suffix is taken off
#                   (the GLM launchers' 1M-context marker), or
#                   CLAUDE_CODE_SUBAGENT_MODEL_FORCE is not exactly 1. The
#                   route is never switched quietly, so the review leaves the
#                   session as before.
#   in-session      The route is claude-glm / glm-5.4 and this session forces
#                   every subagent onto glm-5.4, the flash session's settings
#                   (~/ops/etc/claude-flash/settings.json). The user chose
#                   GLM for the Stage, so a GLM review is the review they
#                   asked for; a headless process on the same model only adds
#                   its startup and one more process that can hang.
# --prompt prints the text of an in-session review and nothing else: for
# draft and diagnose the one subagent's prompt; for code the session's
# procedure with the briefs of its three subagents, the Standards and Spec
# axes of mattpocock-skills:code-review (its steps restated, since a subagent
# cannot load the skill itself) and one that aggregates them and writes the
# 需要人取舍 section, so that the session writes no finding of its own. Every
# subagent is an Explore, the read-only type a flash session's main thread may
# spawn (hooks/subagent-guard.js), and takes no model.
# --stamp reads the findings from stdin and writes --out with the same first
# line as an out-of-session review plus two marks, that it ran in session and
# that the route's effort did not apply (no effort can be set on a subagent):
#   路由：审查（review）claude-glm / glm-5.4 / high（强度未生效）· 2026-11-28 16:30:00 +0800（会话内子代理）
# It applies to what it is given the checks of the 需要人取舍 section that the
# out-of-session pass applies to its own output, and exits 7 without writing
# --out when they fail. The first --stamp at an --out checks what the
# out-of-session first pass checks: every item has its 推荐： and 可自动采纳：
# lines (an item is a numbered line, a title or a top-level bullet together
# with the option and mark lines under it, indented or written flat; a
# section that is absent or says 无 passes, as there). What it refuses
# is kept next to --out as <out>.rejected, the trace of a refused review and
# what --repair-prompt is built from; a --stamp that writes --out removes it.
# While <out>.rejected exists a repair was asked for, and a --stamp checks
# what the out-of-session repair retry checks: it refuses as well a repair
# that dropped the section or turned it into 无, not only one whose items
# still lack their lines.
# --repair-prompt prints the brief of that repair and nothing else: the
# out-of-session repair prompt (the refused findings verbatim, then the items
# that lack their lines) under the in-session first line. The session gives it
# to one more read-only subagent and stamps that subagent's response.
# --prompt, --repair-prompt and --stamp all refuse, exit 64, unless --where
# would say in-session: the findings file of an official route is never
# written from a GLM session's subagents. --stamp exits 64 as well when the
# findings on stdin already start with a 路由： line: that is a file already
# stamped, a mistake of the caller and not a failed review.
#
# Every findings file starts with the route that produced it, on the default
# route as on a switched one, then a blank line, then the model's findings:
#   路由：审查（review）claude-glm / glm-5.4 / medium · 2026-11-27 16:30:00 +0800
#
# Exit codes:
#   0  success; findings are in --out (--where: the verdict is on stdout;
#      --prompt and --repair-prompt: the text is on stdout)
#   2  authentication failed
#   3  quota exhausted or rate limited
#   4  transient service or network unavailability
#   5  timed out
#   6  other launcher or findings-write error, among them the route's launcher
#      not found in PATH, and --stamp given no findings on stdin
#   7  findings under “需要人取舍” still lack a 推荐： or 可自动采纳：是|否
#      line after one repair retry; the offending items are listed on stderr
#      (--stamp: the same check before anything is written, and once a repair
#      was asked for also a repair that dropped the section or turned it into
#      无; the refused findings are kept as <out>.rejected)
#  64  bad usage, among it a route that cannot be read from the Stage route
#      table: nothing starts with an empty model; a --prompt, --repair-prompt
#      or --stamp call on a route --where does not call in-session; a
#      --repair-prompt call with no <out>.rejected to repair; and a --stamp
#      call given findings that already start with a 路由： line

set -u

ORIG_PWD=$(pwd -P)

MODE=run
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
BODY_TMP=""
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
  [ -z "$BODY_TMP" ] || rm -f "$BODY_TMP" 2>/dev/null || true
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
    --where|--prompt|--repair-prompt|--stamp)
      [ "$MODE" = run ] || die "give only one of --where, --prompt, --repair-prompt and --stamp"
      MODE=${1#--}; shift ;;
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

# What each form takes. --where decides from the route and the environment
# alone and starts nothing; --prompt is the in-session text of the same
# review, so it takes the same input and findings file; --stamp only writes the
# findings file, from stdin; --repair-prompt reads what --stamp refused next to
# that file.
TAKES_INPUT=
case "$MODE" in
  run) TAKES_INPUT=1 ;;
  prompt)
    TAKES_INPUT=1
    [ -z "$TIMEOUT" ] || die "--prompt takes no --timeout: the session's subagents have none"
    ;;
  where)
    [ -z "$INPUT$OUT$TIMEOUT" ] || die "--where takes --kind alone: it decides where the review runs and starts nothing"
    ;;
  stamp)
    [ -z "$INPUT" ] || die "--stamp takes no --input: the review already read it, the findings come on stdin"
    [ -z "$TIMEOUT" ] || die "--stamp takes no --timeout: nothing is started"
    ;;
  repair-prompt)
    [ -z "$INPUT" ] || die "--repair-prompt takes no --input: it repairs the findings a --stamp refused"
    [ -z "$TIMEOUT" ] || die "--repair-prompt takes no --timeout: nothing is started"
    ;;
esac
if [ -z "$TIMEOUT" ]; then
  if [ "$KIND" = code ]; then
    TIMEOUT=3600
  else
    TIMEOUT=1200
  fi
fi
# A form that takes an input and was given none is a usage error.
if [ -n "$TAKES_INPUT" ] && [ -z "$INPUT" ]; then
  die "--input is required"
fi
[ "$MODE" = where ] || [ -n "$OUT" ] || die "--out is required"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer (got $TIMEOUT)"
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer (got $TIMEOUT)"
[ -d "$CWD" ] || die "--cwd must be an existing directory: $CWD"
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || die "--cwd is not readable: $CWD"

if [ "$KIND" != code ] && [ -n "$TAKES_INPUT" ]; then
  case "$INPUT" in
    /*) ;;
    *) INPUT="$ORIG_PWD/$INPUT" ;;
  esac
  [ -f "$INPUT" ] || die "--input must be an existing file for --kind $KIND: $INPUT"
  [ -r "$INPUT" ] || die "--input is not readable: $INPUT"
fi

OUT_DIR=$(dirname "$OUT")
[ "$MODE" = where ] || [ -d "$OUT_DIR" ] || die "--out parent directory must exist: $OUT_DIR"
[ "$MODE" = where ] || [ ! -d "$OUT" ] || die "--out must be a file, not a directory: $OUT"

# Read once per invocation: the route of the stage this kind judges on, from the
# Stage route table. A route that cannot be read is a usage error: the table is
# the only source of the model, so nothing starts with an empty one.
case "$KIND" in
  code|draft) STAGE=review; STAGE_LABEL='审查（review）'; STAGE_WORD=审查 ;;
  diagnose) STAGE=diagnosis; STAGE_LABEL='诊断（diagnosis）'; STAGE_WORD=诊断 ;;
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
# the reports below name it as the table does. Only the default form starts
# anything, so only it reads the launch command.
ROUTE_ARGS=()
if [ "$MODE" = run ]; then
  LAUNCH=$("$HERE/stage-route.sh" --launch "$STAGE" headless) ||
    die "cannot read the $STAGE route's launch command from the Stage route table (scripts/stage-route.sh --launch $STAGE headless exited $?)"
  [ -n "$LAUNCH" ] || die "scripts/stage-route.sh --launch printed nothing for the $STAGE route"
  while IFS= read -r arg; do ROUTE_ARGS+=("$arg"); done <<< "$LAUNCH"
fi
# route_field runs inside $(...), so its die only ends that subshell: the
# status is what ends the script. (The default form never gets here with a
# broken table -- the --launch read above dies first -- but --where does.)
ROUTE_PROFILE=$(route_field profile) || exit $?
ROUTE_MODEL=$(route_field model) || exit $?
ROUTE_EFFORT=$(route_field effort) || exit $?

# Works out where this kind's review runs, by the header's rules, into WHERE
# (in-session or out-of-session) and WHERE_LINE, the one line --where prints
# for the user: the route, where the review runs, and why. Call after the
# route is read. A variable is braced wherever a CJK character could follow
# it: bash 3.2 reads those bytes as part of the name.
decide_where() {
  local sub_model route
  route="$ROUTE_PROFILE / $ROUTE_MODEL / $ROUTE_EFFORT"
  WHERE_LINE="${STAGE_WORD}中（$ROUTE_PROFILE / ${ROUTE_MODEL}，出会话）：${STAGE_WORD}路由 $route"
  if [ "$ROUTE_PROFILE" = claude ]; then
    WHERE=out-of-session
    WHERE_LINE="$WHERE_LINE 是官方模型，照旧由 opus-review.sh 出会话执行"
    return 0
  fi
  sub_model=${CLAUDE_CODE_SUBAGENT_MODEL:-}
  # The [1m] suffix is the GLM launchers' 1M-context marker, not part of the
  # model's name; one suffix is taken off and nothing else is.
  sub_model=${sub_model%\[1m\]}
  if [ -z "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    WHERE=out-of-session
    WHERE_LINE="$WHERE_LINE 是 GLM，但本会话没有设 CLAUDE_CODE_SUBAGENT_MODEL，会话内子代理跑哪个模型判断不出来；路由不能被悄悄换掉，照旧出会话"
  elif [ "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" != 1 ]; then
    WHERE=out-of-session
    WHERE_LINE="$WHERE_LINE 是 GLM，但本会话的 CLAUDE_CODE_SUBAGENT_MODEL_FORCE 不是 1，会话内子代理不保证跑路由模型；路由不能被悄悄换掉，照旧出会话"
  elif [ "$sub_model" != "$ROUTE_MODEL" ]; then
    WHERE=out-of-session
    WHERE_LINE="$WHERE_LINE 是 GLM，但本会话子代理被强制跑 ${sub_model}（CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL}），与路由模型不一致；路由不能被悄悄换掉，照旧出会话"
  else
    WHERE=in-session
    WHERE_LINE="${STAGE_WORD}中（$ROUTE_PROFILE / ${ROUTE_MODEL}，会话内）：${STAGE_WORD}路由 $route 是 GLM，本会话子代理被强制跑同一模型（CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL}，CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1）"
  fi
  return 0
}

case "$MODE" in
  where)
    decide_where
    printf '%s\n' "$WHERE"
    printf '%s\n' "$WHERE_LINE" >&2
    exit 0
    ;;
  prompt|stamp|repair-prompt)
    # The in-session form exists only where --where says so: an official
    # route's findings file is never written from a GLM session's subagents.
    decide_where
    if [ "$WHERE" != in-session ]; then
      echo "opus-review: --$MODE needs a review that --where calls in-session; nothing written: $WHERE_LINE" >&2
      exit 64
    fi
    ;;
esac

# The two lines every 需要人取舍 item carries: the same in the out-of-session
# prompts and in the in-session aggregate brief.
MARK_RULES='- For each item in that section, list the mutually exclusive options with their costs, then a line `推荐：<option> — <reason>`; if you genuinely cannot recommend one, write `推荐：无 — <why>` instead of omitting the line.
- After that line, add `可自动采纳：是` when an unattended Run may simply apply your recommendation and land, or `可自动采纳：否 — <why>` when it must stop for a human: only when you wrote `推荐：无`, the choice is irreversible or outward-facing (data deletion, publishing, external services, production deployment), or it needs a human action or knowledge only a human has. A recommendation that merely changes code, wording, or an internal contract is `是`.'

# Sets PROMPT to the prompt of one review pass of the kind, out of session or
# in; $1 is its first line, which says who runs the review and where.
build_prompt() {
  local reviewer_line=$1
  case "$KIND" in
  code)
    PROMPT="$reviewer_line
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
$MARK_RULES
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  draft)
    PROMPT="$reviewer_line
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
$MARK_RULES
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  diagnose)
    PROMPT="$reviewer_line
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
$MARK_RULES
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text."
    ;;
  esac
}

# Prints the items of the “## 需要人取舍” section that lack a `推荐：` line or
# a `可自动采纳：是|否` line. Prints nothing when the section is absent or only
# says 无; prints NONE when it exists but has no real item.
#
# An item opens at a line the margin marks as one and ends where the next
# opens: a numbered line, a title (a line that is all bold, with or without a
# bullet), or a bulleted line at the left margin that follows an item already
# carrying both marks. Everything until then is the item's — options and
# marks, indented under it or written flat at the left margin under its title
# — so an option line never counts as an item of its own. Free text above the
# items is a preamble and is not reported. A flat list with neither numbers,
# bold titles nor complete marks between two items cannot be split, and is
# read as one item.
missing_tradeoff_marks() {
  awk '
    # Prints the open item when it lacks a mark (unless told not to), then
    # forgets it.
    function close_item(report) {
      if (report && item != "" && !(has_rec && has_auto)) {
        gsub(/[\r\t]+/, " ", item)
        print item
      }
      item = ""; has_rec = 0; has_auto = 0; from_text = 0; seen_body = 0
    }
    # Opens the item of a line that opens one.
    function open_item(text) {
      item = text
      has_rec = (text ~ /推荐[*]*[：:]/)
      has_auto = (text ~ /可自动采纳[*]*[：:][*[:space:]]*(是|否)/)
      saw_item = 1; from_text = 0; seen_body = 0
    }
    BEGIN { insec = 0; item = ""; has_rec = 0; has_auto = 0; meaningful = 0; saw_item = 0; from_text = 0; seen_body = 0 }
    /^##[[:space:]]+需要人取舍[[:space:]]*$/ { insec = 1; next }
    insec && (/^##[[:space:]]/ || /^#[[:space:]]/) { insec = 0 }
    insec {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^###[#]*[[:space:]]/) next
      if (line ~ /^[[:space:]]*(无|（无）|\(无\)|none|NONE|None|n\/a|N\/A|-|—|没有)[[:space:]]*$/) next
      meaningful = 1
      is_rec = (line ~ /推荐[*]*[：:]/)
      is_auto = (line ~ /可自动采纳[*]*[：:][*[:space:]]*(是|否)/)
      numbered = (line ~ /^[0-9]+[.、)]([^0-9A-Za-z]|$)/)
      bullet = (line ~ /^[-*+][[:space:]]+/)
      # A title: a line that is all bold, with or without a bullet, and
      # neither a mark nor a lettered option such as **A. …**.
      title = (!is_rec && !is_auto && line !~ /\*\*[A-Za-z][.、:：)]/ &&
        (line ~ /^\*\*[^*]+\*\*[[:space:]]*$/ || (bullet && line ~ /^[-*+][[:space:]]+\*\*[^*]+\*\*[[:space:]]*$/)))
      if (numbered || title) {
        # A numbered line or a title always opens an item. Free text that
        # never gained a line of its own was the preamble above the items:
        # dropped, not reported.
        close_item(!(from_text && !seen_body))
        if (title) { item = line; saw_item = 1; from_text = 1 }
        else open_item(line)
        next
      }
      if (bullet && (!saw_item || (has_rec && has_auto))) {
        # A bulleted line at the left margin opens an item when nothing is
        # open or the open item has both marks; otherwise it falls through as
        # a line of the open item, an option or a mark written flat under
        # its title.
        if (saw_item) close_item(1)
        open_item(line)
        next
      }
      # Any other line belongs to the open item: its marks count, and a line
      # of its own makes free text an item.
      if (item == "") { item = line; from_text = 1 }
      else seen_body = 1
      if (is_rec) has_rec = 1
      if (is_auto) has_auto = 1
    }
    END {
      if (insec && meaningful == 0) { print "NONE"; exit }
      close_item(1)
    }
  ' "$1"
}

# Prints the prompt of the repair pass: $1 its first line, which says who
# repairs and where; $2 the file of the findings to repair; $3 the items that
# lack their lines. The findings are passed through verbatim (no expansion),
# so findings containing `$`, backticks or backslashes cannot turn into
# commands here.
print_repair_prompt() {
  local reviewer_line=$1 original=$2 missing=$3
  printf '%s\n' "$reviewer_line"
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

# --prompt for --kind code: the text the session follows, with the briefs of
# its three subagents. mattpocock-skills:code-review's process is restated
# here because a subagent cannot load the skill itself, and the axes are kept
# apart and judged by a subagent each, as out of session; the session only
# passes text on and pipes the result into --stamp. The Standards and Spec
# briefs and the smell baseline are the upstream skill's own words, kept
# verbatim: scripts/test-opus-review.sh compares them with the upstream file
# (~/.claude/plugins/marketplaces/mattpocock/skills/engineering/code-review/
# SKILL.md) wherever it is installed, so that the two forms of review do not
# drift apart. Update them together.
insession_code_text() {
  local text stamp_command
  case "$OUT" in
    /*) stamp_command="$HERE/opus-review.sh --stamp --kind code --out '$OUT'" ;;
    *) stamp_command="$HERE/opus-review.sh --stamp --kind code --out '$ORIG_PWD/$OUT'" ;;
  esac
  # Read through read, not $(cat …): bash 3.2 scans a here-document inside
  # command substitution for quotes, and an apostrophe in this text ends it.
  read -r -d '' text <<'TEXT' || true
You are running one code review inside the calling session as read-only subagents, on @MODEL@, the model the user's @STAGE@ route names in place of Opus. The session itself writes no finding: every judgment below is a subagent's. Every subagent is spawned with subagent_type Explore, the read-only type a flash session's main thread may spawn, in the foreground and in a fresh context (never a fork), and no model is passed on any Agent call: this session's CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 already pins every subagent to @MODEL@, the model the route names. Do not modify files anywhere in this review.

Repository: @CWD@
Review fixed point: @FIXED@
Diff command: git diff @FIXED@...HEAD
Commit list: git log @FIXED@..HEAD --oneline

Required procedure (the two-axis review of mattpocock-skills:code-review, its axes kept apart):
1. Confirm the fixed point resolves (git rev-parse @FIXED@) and the diff is non-empty. A ref that does not resolve or an empty diff is an error to report to the session, not a review: stop and say so.
2. Spawn the Standards and the Spec axis subagents together, in the foreground, each with the brief of its axis below followed by the rules under "Every subagent" below.
3. When both have returned, spawn one aggregate subagent with both axis reports verbatim and the "Aggregate brief" below followed by the same rules.
4. Pipe the aggregate subagent's final response, exactly as it came back, into `@STAMP@`, and from then on act on that findings file exactly as on an out-of-session one.

Every subagent:
- Use read-only tools only: Read, Grep, Glob, git status, git diff, git show, git log, git rev-parse, git merge-base, git ls-files, git cat-file, gh issue view, gh pr view, gh pr diff. Do not modify files.
- Return the findings themselves, suitable for an Orchestrator to act on, without conversational wrapper text.

Standards axis brief:
First confirm the fixed point and run the diff command above. Search the repository for every file that documents how code should be written; when CODING_STANDARDS.md or CONTRIBUTING.md exists it must be on your list. The brief of the axis, as the skill words it: Report, per file/hunk where relevant, (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls: documented-standard breaches can be hard, but baseline smells are always judgement calls, and a documented repo standard overrides the baseline. Skip anything tooling enforces. Under 400 words.

Smell baseline (Fowler, Refactoring ch. 3), the skill's own list; a documented repository standard overrides it:
- **Mysterious Name**: a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession**: a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery**: one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change**: one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality**: abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man**: a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest**: a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

Spec axis brief:
First confirm the fixed point and run the diff command above. Find the originating spec in this order: issue references in the commit messages (#123, Closes #45), read with gh issue view; then a spec file under docs/, specs/ or .scratch/ matching the branch name or feature. If nothing is found, report "no spec available" instead of guessing. The brief of the axis, as the skill words it: Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding. Under 400 words.

Aggregate brief:
You are the same review, aggregating its two axes; you add no finding of your own. Present the two axis reports under `## Standards` and `## Spec`, verbatim or lightly cleaned, and do not merge or rerank findings across the two axes: they are deliberately separate. End that part with a one-line summary: total findings per axis and the worst issue within each axis, never a single winner across axes. When the Spec axis reported no spec available, say so under `## Spec`.
Then:
- End with a section headed exactly `## 需要人取舍`.
- Put every finding that needs a human decision or tradeoff in that section. If there are none, put only `无` in it.
@MARKS@
- This entire final response is saved verbatim as the findings file; do not add conversational wrapper text.
TEXT
  text=${text//@MODEL@/$ROUTE_MODEL}
  text=${text//@STAGE@/$STAGE}
  text=${text//@CWD@/$CWD}
  text=${text//@FIXED@/$INPUT}
  text=${text//@STAMP@/$stamp_command}
  text=${text//@MARKS@/$MARK_RULES}
  printf '%s\n' "$text"
}

# Writes a findings file: its first line, the route that produced it, then a
# blank line, then the findings of $2, into $1. $3 is the first line's printf
# format over the stage label, the route's profile, model and effort, and the
# time: the plain route line out of session, the one with the two marks of the
# header in session. The file is written whole, through a temporary file next
# to it, or not at all: exits 6 when it cannot be written.
write_first_line() {
  local out=$1 body=$2 format=$3 tmp
  tmp=$(mktemp "$out.tmp.XXXXXX") || exit 6
  { printf "$format" \
      "$STAGE_LABEL" "$ROUTE_PROFILE" "$ROUTE_MODEL" "$ROUTE_EFFORT" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    cat "$body"
  } > "$tmp" || { rm -f "$tmp"; exit 6; }
  if ! mv -f "$tmp" "$out"; then
    rm -f "$tmp"
    echo "opus-review: cannot write findings to $out" >&2
    exit 6
  fi
}

# The checks a repair must pass, the same for the out-of-session repair retry
# and for a --stamp that follows a repair: the repair may add the missing
# lines, never take the items away. $1 is the file of the repaired findings
# and $2 the function that refuses on the caller's behalf — it takes the
# message and, when there are items, their list, says why on stderr and exits
# 7. Prints nothing and returns when the repair passes.
restamp_recheck() {
  local file=$1 refuse=$2 still_missing
  still_missing=$(missing_tradeoff_marks "$file")
  if ! grep -Eq '^##[[:space:]]+需要人取舍[[:space:]]*$' "$file"; then
    "$refuse" "the repair retry dropped ## 需要人取舍; refusing to accept it"
  fi
  if [ "$still_missing" = NONE ]; then
    "$refuse" "the repair retry turned ## 需要人取舍 into 无; refusing to drop the items"
  fi
  if [ -n "$still_missing" ]; then
    "$refuse" "需要人取舍 items still lack 推荐：/可自动采纳： lines after one repair retry:" "$still_missing"
  fi
}

# --stamp: the findings on stdin, checked the way the out-of-session pass
# checks its own output, then written under the in-session first line. Nothing
# is written unless everything holds; what is refused is kept as $OUT.rejected.
stamp_findings() {
  local missing restamp=false
  BODY_TMP=$(mktemp "$OUT.tmp.XXXXXX") || exit 6
  if ! cat > "$BODY_TMP"; then
    echo "opus-review: cannot read the findings on stdin" >&2
    exit 6
  fi
  if ! grep -Eq '[^[:space:]]' "$BODY_TMP" 2>/dev/null; then
    echo "opus-review: no findings on stdin (empty or whitespace only)" >&2
    exit 6
  fi
  if head -n 1 "$BODY_TMP" | grep -Eq '^路由：'; then
    echo "opus-review: the findings on stdin already start with a 路由： line, so that file was stamped already; --stamp writes that line itself: give it the review's findings alone (nothing written)" >&2
    exit 64
  fi
  # restamp: an earlier --stamp left the findings it refused at this --out,
  # so a repair was asked for, and what arrives now is that repair, held to
  # the stricter standard of the out-of-session repair retry.
  [ -f "$OUT.rejected" ] && restamp=true
  missing=$(missing_tradeoff_marks "$BODY_TMP")
  if $restamp; then
    restamp_recheck "$BODY_TMP" refuse_findings
  fi
  # What is left is the check of the first pass: every item carries its lines.
  # No retry here: a subagent that has returned cannot be asked again, so the
  # session asks --repair-prompt for the brief and stamps again.
  case "$missing" in
    ''|NONE) ;;
    *)
      refuse_findings "需要人取舍 items lack 推荐：/可自动采纳： lines; have them repaired once (--repair-prompt) and stamp again:" "$missing"
      ;;
  esac
  # The in-session first line: the same route line, with the two marks the
  # header names. No effort can be set on a subagent, so the route's did not
  # apply and the line says so.
  write_first_line "$OUT" "$BODY_TMP" '路由：%s%s / %s / %s（强度未生效）· %s（会话内子代理）\n\n'
  rm -f "$BODY_TMP"; BODY_TMP=""
  rm -f "$OUT.rejected"
  exit 0
}

# What --stamp does with findings it refuses: says why on stderr (and lists
# the items, when given), keeps them as $OUT.rejected for the trace and for
# --repair-prompt, and exits 7. --out itself is not written.
refuse_findings() {
  echo "opus-review: $1; nothing written to $OUT, the refused findings are kept as $OUT.rejected" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  if mv -f "$BODY_TMP" "$OUT.rejected"; then
    BODY_TMP=""
  else
    echo "opus-review: cannot keep the refused findings as $OUT.rejected" >&2
  fi
  exit 7
}

# What the out-of-session pass does with a repair retry that failed those
# checks: says why on stderr, drops the retry's files and exits 7. The
# counterpart of refuse_findings, which keeps what it refused.
refuse_retry() {
  echo "opus-review: $1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  rm -f "$RETRY_TMP" "$RETRY_ERR"
  exit 7
}

# --repair-prompt: the brief of the repair of what the last --stamp at --out
# refused, those findings kept as $OUT.rejected. The out-of-session repair
# prompt under the in-session first line; the items are read from the refused
# findings again, the way --stamp found them.
repair_prompt_mode() {
  local missing
  [ -f "$OUT.rejected" ] || die "nothing to repair: no --stamp at --out $OUT exited 7, so $OUT.rejected does not exist"
  [ -r "$OUT.rejected" ] || die "the refused findings are not readable: $OUT.rejected"
  missing=$(missing_tradeoff_marks "$OUT.rejected")
  case "$missing" in
    '') die "nothing to repair: the refused findings in $OUT.rejected have no 需要人取舍 section" ;;
    NONE) die "nothing to repair: the refused findings in $OUT.rejected say 无 under 需要人取舍" ;;
  esac
  print_repair_prompt "You are the same review, asked to repair your own previous output, running as a read-only subagent of the calling session on $ROUTE_MODEL, the model the user's $STAGE route names in place of Opus." \
    "$OUT.rejected" "$missing"
}

if [ "$MODE" = prompt ]; then
  if [ "$KIND" = code ]; then
    insession_code_text
  else
    build_prompt "You are a review running as a read-only subagent of the calling session, on $ROUTE_MODEL, the model the user's $STAGE route names in place of Opus."
    printf '%s\n' "$PROMPT"
  fi
  exit 0
fi
if [ "$MODE" = repair-prompt ]; then
  repair_prompt_mode
  exit 0
fi
if [ "$MODE" = stamp ]; then
  stamp_findings
  # stamp_findings exits on every path of its own; this is for the day it
  # returns instead.
  exit $?
fi

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
build_prompt "$REVIEWER_LINE"

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
    RETRY_PROMPT=$(print_repair_prompt 'You are the same Opus review, asked to repair your own previous output.' "$OUTPUT_TMP" "$MISSING_MARKS")
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
    # The repair may add lines, never take the items away.
    restamp_recheck "$RETRY_TMP" refuse_retry
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
write_first_line "$OUT" "$OUTPUT_TMP" '路由：%s%s / %s / %s · %s\n\n'
rm -f "$OUTPUT_TMP"
OUTPUT_TMP=""
exit 0
