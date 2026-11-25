#!/usr/bin/env bash
# Watch the Specs of one repository and print one line per change, so that
# find-next's main session can sleep until something happens. Read-only: it only
# reads GitHub issues and comments through `gh`, reads claims through
# `claim.sh status`, and writes its own state file. It never writes to GitHub or
# to the repository.
#
# Usage:
#   watch-specs.sh --repo <owner/name> --repo-path <repo root> --state <file>
#                  [--interval 300] [--max 6600] [--once]
#
# A Spec is an issue (open or closed) whose body contains a line
# "## Problem Statement". Every round pulls all issues once, then reads the
# comments of every open Spec and of the Specs that were open in the last
# snapshot and are closed now, and reads the claim state of those Specs. The
# snapshot (state, last report comment id and kind, claim word per Spec) is
# stored in --state as JSON and written atomically (temp file + mv).
#
# Events, one per line, tab separated: <event>\t#<n>\t<title>\t<extra>
#   LANDED    open -> closed; extra is the html_url of the last "## 落地报告"
#             comment, empty when there is none
#   PARTIAL   a new "## 落地报告" comment appeared and the Spec is still open;
#             extra is the comment url
#   PARKED    a new "## 停车报告" comment appeared; extra is the comment url
#   STARTED   the claim changed from anything but active to active
#   DIED      the claim changed from active to interrupted, with no new report
#             comment in the same round
#   NEW_SPEC  an open Spec that was not in the last snapshot
# Events are printed first, then one summary line
#   SUMMARY\topen=<x>\tactive=<y>\tclosed=<z>
# and, when no open Spec is left, ALL_DONE.
#
# A missing state file means a first run: only the baseline snapshot is written,
# no events are reported, and --once prints BASELINE and exits 0.
#
# Exit codes:
#   0  events printed, baseline written, or no open Spec left (ALL_DONE)
#   2  no event within --max seconds, or --once found nothing (SUMMARY printed)
#   3  gh failed three rounds in a row (the single --once round counts as one)
#  64  bad usage

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SKILL_ROOT=$(cd -P -- "$SCRIPT_DIR/../.." && pwd) || exit 1
CLAIM=${WATCH_SPECS_CLAIM:-$SKILL_ROOT/scripts/claim.sh}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --repo <owner/name> --repo-path <repo root> --state <file>
                      [--interval 300] [--max 6600] [--once]

Read the Specs (issues whose body has a line "## Problem Statement") of one
repository, print one tab-separated line per change, and keep a JSON snapshot
in --state. Read-only: only gh reads and claim.sh status, plus its own state
file. A missing state file only writes the baseline snapshot and prints BASELINE
with --once.

Events: LANDED (open -> closed), PARTIAL (new 落地报告, still open),
PARKED (new 停车报告), STARTED (claim became active),
DIED (claim active -> interrupted, no new report), NEW_SPEC (open Spec not in
the snapshot).
Lines: <event>\\t#<n>\\t<title>\\t<extra>, then
SUMMARY\\topen=<x>\\tactive=<y>\\tclosed=<z>, and ALL_DONE when nothing is open.

Exit codes: 0 events or baseline or all done, 2 no event within --max seconds
(or --once), 3 gh failed three rounds in a row, 64 bad usage.
EOF
}

usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 64
}

REPO=
REPO_PATH=
STATE=
INTERVAL=300
MAX=6600
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage_error '--repo requires <owner/name>'
      REPO=$2
      shift 2
      ;;
    --repo-path)
      [ $# -ge 2 ] || usage_error '--repo-path requires a path'
      REPO_PATH=$2
      shift 2
      ;;
    --state)
      [ $# -ge 2 ] || usage_error '--state requires a file'
      STATE=$2
      shift 2
      ;;
    --interval)
      [ $# -ge 2 ] || usage_error '--interval requires seconds'
      INTERVAL=$2
      shift 2
      ;;
    --max)
      [ $# -ge 2 ] || usage_error '--max requires seconds'
      MAX=$2
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$REPO" ] || usage_error '--repo is required'
case "$REPO" in
  */*) ;;
  *) usage_error "--repo must be <owner/name>, got '$REPO'" ;;
esac
[ -n "$REPO_PATH" ] || usage_error '--repo-path is required'
[ -d "$REPO_PATH" ] || usage_error "--repo-path is not a directory: $REPO_PATH"
REPO_PATH=$(cd -P -- "$REPO_PATH" 2>/dev/null && pwd -P) || usage_error "--repo-path is not readable: $REPO_PATH"
[ -n "$STATE" ] || usage_error '--state is required'
case "$INTERVAL" in
  ''|*[!0-9]*) usage_error "--interval must be a non-negative integer, got '$INTERVAL'" ;;
esac
case "$MAX" in
  ''|*[!0-9]*) usage_error "--max must be a non-negative integer, got '$MAX'" ;;
esac
command -v gh >/dev/null 2>&1 || { printf '%s: gh is required but was not found on PATH\n' "$SCRIPT_NAME" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { printf '%s: node is required but was not found on PATH\n' "$SCRIPT_NAME" >&2; exit 1; }
[ -x "$CLAIM" ] || { printf '%s: claim.sh not executable: %s\n' "$SCRIPT_NAME" "$CLAIM" >&2; exit 1; }

mkdir -p -- "$(dirname -- "$STATE")" 2>/dev/null ||
  { printf '%s: cannot create the directory of %s\n' "$SCRIPT_NAME" "$STATE" >&2; exit 1; }

if [ -f "$STATE" ] && ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
     "$STATE" >/dev/null 2>&1; then
  printf '%s: state file %s is not valid JSON; writing a new baseline\n' "$SCRIPT_NAME" "$STATE" >&2
  rm -f -- "$STATE"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/watch-specs.XXXXXX") ||
  { printf '%s: could not create a temporary directory\n' "$SCRIPT_NAME" >&2; exit 1; }
cleanup() {
  rm -f "$WORK"/* 2>/dev/null
  rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT

FAILURES=0
ELAPSED=0
CLAIM_WARNED=0

# collect_snapshot: read GitHub and the claims into $WORK, then write
# $WORK/new-state.json, $WORK/events.txt and $WORK/result.txt. Returns non-zero
# when any gh call fails; the caller then keeps the old state file untouched.
collect_snapshot() {
  rm -f "$WORK"/* 2>/dev/null
  if ! gh issue list --repo "$REPO" --state all --limit 200 \
       --json number,title,state,body > "$WORK/issues.json" 2> "$WORK/gh.err"; then
    printf '%s: gh issue list failed: %s\n' "$SCRIPT_NAME" "$(head -n 1 "$WORK/gh.err" 2>/dev/null)" >&2
    return 1
  fi
  if ! STATE_FILE="$STATE" WORK_DIR="$WORK" node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.env.WORK_DIR;
    const issues = JSON.parse(fs.readFileSync(path.join(dir, "issues.json"), "utf8"));
    let old = {specs: {}};
    try {
      const parsed = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (parsed && parsed.specs && typeof parsed.specs === "object") old = parsed;
    } catch {}
    const specs = [];
    for (const issue of Array.isArray(issues) ? issues : []) {
      if (!issue || typeof issue.number !== "number") continue;
      const body = String(issue.body || "");
      if (!body.split(/\r?\n/).some((line) => line.trim() === "## Problem Statement")) continue;
      specs.push({
        number: issue.number,
        title: String(issue.title || "").replace(/[\t\r\n]+/g, " ").trim(),
        state: String(issue.state || "").toLowerCase() === "closed" ? "closed" : "open",
      });
    }
    specs.sort((a, b) => a.number - b.number);
    const need = new Set();
    for (const spec of specs) {
      if (spec.state === "open") need.add(spec.number);
      const prev = old.specs[String(spec.number)];
      if (prev && prev.state === "open" && spec.state === "closed") need.add(spec.number);
    }
    fs.writeFileSync(path.join(dir, "specs.json"), JSON.stringify(specs));
    fs.writeFileSync(path.join(dir, "need.txt"),
      [...need].sort((a, b) => a - b).join("\n") + "\n");
  '; then
    printf '%s: could not read the issue list\n' "$SCRIPT_NAME" >&2
    return 1
  fi

  local n claim
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! gh api "repos/$REPO/issues/$n/comments" --paginate --slurp \
         > "$WORK/comments-$n.json" 2> "$WORK/gh.err"; then
      printf '%s: gh comments for #%s failed: %s\n' "$SCRIPT_NAME" "$n" "$(head -n 1 "$WORK/gh.err" 2>/dev/null)" >&2
      return 1
    fi
    claim=$( cd "$REPO_PATH" 2>/dev/null && "$CLAIM" status "$n" 2>>"$WORK/claim.err" | awk '{print $1; exit}' )
    if [ -z "$claim" ]; then
      claim=free
      if [ "$CLAIM_WARNED" -eq 0 ] && [ -s "$WORK/claim.err" ]; then
        CLAIM_WARNED=1
        printf '%s: claim.sh status failed for #%s; treating the claim as free\n' "$SCRIPT_NAME" "$n" >&2
      fi
    fi
    printf '%s' "$claim" > "$WORK/claim-$n.txt"
  done < "$WORK/need.txt"

  if ! STATE_FILE="$STATE" WORK_DIR="$WORK" node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.env.WORK_DIR;
    const specs = JSON.parse(fs.readFileSync(path.join(dir, "specs.json"), "utf8"));
    let old = {specs: {}};
    try {
      const parsed = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (parsed && parsed.specs && typeof parsed.specs === "object") old = parsed;
    } catch {}
    const need = new Set(fs.readFileSync(path.join(dir, "need.txt"), "utf8")
      .split(/\r?\n/).filter(Boolean).map(Number));

    function readComments(n) {
      const file = path.join(dir, "comments-" + n + ".json");
      if (!fs.existsSync(file)) return [];
      let value;
      try { value = JSON.parse(fs.readFileSync(file, "utf8")); }
      catch { throw new Error("bad comments JSON for #" + n); }
      const pages = Array.isArray(value) && value.length && Array.isArray(value[0]) ? value : [value];
      return pages.flat();
    }
    function lastReport(comments) {
      let last = null;
      for (const comment of comments) {
        if (!comment) continue;
        const body = String(comment.body || "").trim();
        let kind = null;
        if (body.startsWith("## 落地报告")) kind = "landing";
        else if (body.startsWith("## 停车报告")) kind = "parking";
        if (!kind) continue;
        last = {id: comment.id == null ? null : Number(comment.id), kind, url: String(comment.html_url || "")};
      }
      return last;
    }

    const fresh = {specs: {}};
    const events = [];
    let open = 0, active = 0, closed = 0;
    for (const spec of specs) {
      const key = String(spec.number);
      const prev = old.specs[key] || null;
      const title = String(spec.title || "").replace(/[\t\r\n]+/g, " ").trim();
      let entry;
      if (need.has(spec.number)) {
        const report = lastReport(readComments(spec.number));
        let claim = "free";
        try {
          claim = fs.readFileSync(path.join(dir, "claim-" + spec.number + ".txt"), "utf8").trim() || "free";
        } catch {}
        entry = {
          state: spec.state,
          last_report_id: report ? report.id : null,
          last_report_kind: report ? report.kind : null,
          claim,
        };
        const newReport = Boolean(report) && (!prev || prev.last_report_id == null ||
          Number(report.id) > Number(prev.last_report_id));
        if (prev && prev.state === "open" && spec.state === "closed") {
          events.push(["LANDED", "#" + spec.number, title, report && report.kind === "landing" ? report.url : ""]);
        }
        if (newReport && spec.state === "open" && report.kind === "landing") {
          events.push(["PARTIAL", "#" + spec.number, title, report.url]);
        }
        if (newReport && report.kind === "parking") {
          events.push(["PARKED", "#" + spec.number, title, report.url]);
        }
        if (prev && prev.claim !== "active" && claim === "active") {
          events.push(["STARTED", "#" + spec.number, title, ""]);
        }
        if (prev && prev.claim === "active" && claim === "interrupted" && !newReport) {
          events.push(["DIED", "#" + spec.number, title, ""]);
        }
        if (!prev && spec.state === "open") {
          events.push(["NEW_SPEC", "#" + spec.number, title, ""]);
        }
      } else {
        entry = {
          state: spec.state,
          last_report_id: prev ? (prev.last_report_id == null ? null : prev.last_report_id) : null,
          last_report_kind: prev ? (prev.last_report_kind == null ? null : prev.last_report_kind) : null,
          claim: prev && prev.claim ? prev.claim : "free",
        };
      }
      fresh.specs[key] = entry;
      if (spec.state === "open") {
        open += 1;
        if (entry.claim === "active") active += 1;
      } else {
        closed += 1;
      }
    }
    fs.writeFileSync(path.join(dir, "new-state.json"),
      JSON.stringify({version: 1, specs: fresh.specs}, null, 2) + "\n");
    fs.writeFileSync(path.join(dir, "events.txt"),
      events.map((event) => event.join("\t")).join("\n") + (events.length ? "\n" : ""));
    fs.writeFileSync(path.join(dir, "result.txt"),
      "OPEN=" + open + "\nACTIVE=" + active + "\nCLOSED=" + closed + "\nEVENTS=" + events.length + "\n");
  '; then
    printf '%s: could not compare the snapshots\n' "$SCRIPT_NAME" >&2
    return 1
  fi
  return 0
}

write_state() {
  local tmp="$STATE.tmp.$$"
  cp -- "$WORK/new-state.json" "$tmp" 2>/dev/null || return 1
  mv -f -- "$tmp" "$STATE" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

result_value() {
  sed -n "s/^$1=//p" "$WORK/result.txt" 2>/dev/null | head -n 1
}

print_summary() {
  printf 'SUMMARY\topen=%s\tactive=%s\tclosed=%s\n' \
    "$(result_value OPEN)" "$(result_value ACTIVE)" "$(result_value CLOSED)"
}

if [ ! -f "$STATE" ]; then
  if collect_snapshot; then
    write_state || { printf '%s: could not write %s\n' "$SCRIPT_NAME" "$STATE" >&2; exit 1; }
    FAILURES=0
    if [ "$ONCE" -eq 1 ]; then
      printf 'BASELINE\n'
      exit 0
    fi
    if [ "$(result_value OPEN)" = 0 ]; then
      print_summary
      printf 'ALL_DONE\n'
      exit 0
    fi
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  else
    FAILURES=$((FAILURES + 1))
    if [ "$FAILURES" -ge 3 ] || [ "$ONCE" -eq 1 ]; then
      exit 3
    fi
  fi
fi

while :; do
  if collect_snapshot; then
    FAILURES=0
    write_state || { printf '%s: could not write %s\n' "$SCRIPT_NAME" "$STATE" >&2; exit 1; }
    if [ "$(result_value EVENTS)" -gt 0 ]; then
      cat "$WORK/events.txt"
      print_summary
      if [ "$(result_value OPEN)" = 0 ]; then
        printf 'ALL_DONE\n'
      fi
      exit 0
    fi
    if [ "$(result_value OPEN)" = 0 ]; then
      print_summary
      printf 'ALL_DONE\n'
      exit 0
    fi
    if [ "$ONCE" -eq 1 ]; then
      print_summary
      exit 2
    fi
    if [ "$ELAPSED" -ge "$MAX" ]; then
      print_summary
      exit 2
    fi
  else
    FAILURES=$((FAILURES + 1))
    if [ "$FAILURES" -ge 3 ] || [ "$ONCE" -eq 1 ]; then
      exit 3
    fi
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
