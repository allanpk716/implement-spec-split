#!/usr/bin/env bash
# Isolated fake-gh tests for scripts/completion-report.sh. Scratch directories
# are intentionally retained: this test never recursively deletes them.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/completion-report.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/completion-report-test.XXXXXX")
WORK=$(cd "$WORK" && pwd)
BIN=$WORK/bin
PASSED=0
FAILED=0
RUN_EXIT=

record() {
  status=$1
  name=$2
  detail=${3:-}
  if [ "$status" = PASS ]; then
    printf 'PASS %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$name" "${detail:+: $detail}"
    FAILED=$((FAILED + 1))
  fi
}

expect_exit() {
  expected=$1
  name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected"
  fi
}

expect_file_has() {
  text=$1
  name=$2
  file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "missing [$text] in $(basename "$file")"
  fi
}

expect_same_file() {
  expected=$1
  name=$2
  actual=$3
  if [ -f "$actual" ] && cmp -s "$expected" "$actual"; then
    record PASS "$name"
  else
    record FAIL "$name" "actual=$actual"
  fi
}

expect_count() {
  expected=$1
  name=$2
  file=$3
  actual=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  if [ "$actual" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "lines=$actual, expected=$expected"
  fi
}

expect_line() { # line-number expected name file
  local wanted=$1 expected=$2 name=$3 file=$4 actual
  actual=$(sed -n "${wanted}p" "$file" 2>/dev/null)
  if [ -n "$actual" ] && [ "$actual" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "line $wanted=[$actual], expected=[$expected]"
  fi
}

expect_has_count() { # text expected-line-count name file
  local text=$1 expected=$2 name=$3 file=$4 actual
  actual=$(grep -Fc -- "$text" "$file" 2>/dev/null || true)
  if [ "$actual" = "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "lines=[$actual], expected=$expected for [$text]"
  fi
}

expect_not_has() {
  local text=$1 name=$2 file=$3
  if grep -Fq -- "$text" "$file" 2>/dev/null; then
    record FAIL "$name" "unexpected [$text]"
  else
    record PASS "$name"
  fi
}

mkdir -p "$BIN"

cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -u
: "${CR_GH_DATA:?CR_GH_DATA is required}"
issue_file() { printf '%s/issue-%s.env' "$CR_GH_DATA" "$1"; }
issue_var() {
  file=$(issue_file "$1")
  value=$(grep -m1 "^$2=" "$file" 2>/dev/null | cut -d= -f2-)
  printf '%s' "${value:-$3}"
}
issue_failed() { [ "$(issue_var "$1" FAIL 0)" = 1 ]; }
list_csv() { printf '%s' "$1" | tr ',' ' '; }
json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}
# One GitHub issue object as pipeline-status.sh reads it from the issues list.
issue_json() {
  local n=$1 state title body labels closed_at subs sub total=0 completed=0
  local labels_json='[' first=true closed_json=null
  if [ ! -f "$(issue_file "$n")" ]; then
    printf '{"number":%s,"state":"open","title":"","labels":[],"body":""}' "$n"
    return 0
  fi
  state=$(issue_var "$n" STATE open)
  title=$(issue_var "$n" TITLE '')
  body=$(issue_var "$n" BODY '')
  body=${body//\\n/$'\n'}
  closed_at=$(issue_var "$n" CLOSED_AT '')
  subs=$(issue_var "$n" SUBS '')
  for sub in $(list_csv "$subs"); do
    [ -n "$sub" ] || continue
    total=$((total + 1))
    [ "$(issue_var "$sub" STATE open)" = closed ] && completed=$((completed + 1))
  done
  for labels in $(list_csv "$(issue_var "$n" LABELS '')"); do
    [ -n "$labels" ] || continue
    if [ "$first" = true ]; then first=false; else labels_json="$labels_json,"; fi
    labels_json="$labels_json{\"name\":\"$labels\"}"
  done
  labels_json="$labels_json]"
  [ -n "$closed_at" ] && closed_json=$(json_str "$closed_at")
  printf '{"number":%s,"title":%s,"state":"%s","body":%s,"labels":%s,"sub_issues_summary":{"total":%s,"completed":%s,"percent_completed":0},"issue_dependencies_summary":{"blocked_by":0,"total_blocked_by":0,"blocking":0,"total_blocking":0},"assignees":[],"updated_at":"2026-11-25T12:00:00Z","closed_at":%s}' \
    "$n" "$(json_str "$title")" "$state" "$(json_str "$body")" "$labels_json" \
    "$total" "$completed" "$closed_json"
}
json_array() { # numbers... → JSON array of those issues
  local out='[' first=true n
  for n in "$@"; do
    [ -n "$n" ] || continue
    if [ "$first" = true ]; then first=false; else out="$out,"; fi
    out="$out$(issue_json "$n")"
  done
  printf '%s]\n' "$out"
}
if [ "${1:-}" = repo ] && [ "${2:-}" = view ]; then
  if [ "${CR_GH_GRAPH_FAIL:-0}" = 1 ]; then
    printf 'fake gh: simulated graph failure\n' >&2
    exit 1
  fi
  printf 'completion-demo/proxy-hub\n'
  exit 0
fi
if [ "${1:-}" = api ]; then
  path= jq_prog= number=
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) shift ;;
      --jq) jq_prog=$2; shift 2 ;;
      -*) shift ;;
      *) [ -z "$path" ] && path=$1; shift ;;
    esac
  done
  number=$(printf '%s' "$path" | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p')
  case "$path" in
    *'issues?state=all'*)
      # The issue list pipeline-status.sh --graph starts from.
      if [ "${CR_GH_GRAPH_FAIL:-0}" = 1 ]; then
        printf 'fake gh: simulated graph failure\n' >&2
        exit 1
      fi
      out='['
      first=true
      for file in "$CR_GH_DATA"/issue-*.env; do
        [ -f "$file" ] || continue
        n=${file##*/issue-}
        n=${n%.env}
        if [ "$first" = true ]; then first=false; else out="$out,"; fi
        out="$out$(issue_json "$n")"
      done
      printf '%s]\n' "$out"
      exit 0
      ;;
    */sub_issues)
      if issue_failed "$number" || [ ! -f "$(issue_file "$number")" ]; then
        printf 'fake gh: issue %s failed\n' "$number" >&2
        exit 1
      fi
      subs=$(issue_var "$number" SUBS '')
      if [ -n "$jq_prog" ]; then
        for sub in $(list_csv "$subs"); do printf '%s\n' "$sub"; done
        exit 0
      fi
      json_array $(list_csv "$subs")
      exit 0
      ;;
    */dependencies/blocked_by)
      if issue_failed "$number" || [ ! -f "$(issue_file "$number")" ]; then
        printf 'fake gh: issue %s failed\n' "$number" >&2
        exit 1
      fi
      blocked=$(issue_var "$number" BLOCKED_BY '')
      if [ -n "$jq_prog" ]; then
        for blocker in $(list_csv "$blocked"); do
          [ "$(issue_var "$blocker" STATE open)" = open ] && printf '%s\n' "$blocker"
        done
        exit 0
      fi
      json_array $(list_csv "$blocked")
      exit 0
      ;;
  esac
  if issue_failed "$number" || [ ! -f "$(issue_file "$number")" ]; then
    printf 'fake gh: issue %s failed\n' "$number" >&2
    exit 1
  fi
  state=$(issue_var "$number" STATE open)
  title=$(issue_var "$number" TITLE '')
  closed_at=$(issue_var "$number" CLOSED_AT '')
  assignees=$(issue_var "$number" ASSIGNEES 0)
  completed=0
  total=0
  subs=$(issue_var "$number" SUBS '')
  IFS=',' read -ra sub_array <<<"$subs"
  for sub in ${sub_array[@]+"${sub_array[@]}"}; do
    total=$((total + 1))
    sub_state=$(issue_var "$sub" STATE open)
    [ "$sub_state" = closed ] && completed=$((completed + 1))
  done
  case "$jq_prog" in
    *closed_at*)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$state" "$title" "$completed" "$total" "$closed_at" "$assignees"
      ;;
    *)
      printf '%s\t%s\t%s\t%s\n' "$state" "$title" "$completed" "$total"
      ;;
  esac
  exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  label_mode=false
  body_mode=false
  for arg in "$@"; do
    [ "$arg" = ready-for-agent ] && label_mode=true
    [ "$arg" = number,title,body ] && body_mode=true
  done
  for file in "$CR_GH_DATA"/issue-*.env; do
    [ -f "$file" ] || continue
    n=${file##*/issue-}
    n=${n%.env}
    state=$(issue_var "$n" STATE open)
    [ "$state" = open ] || continue
    title=$(issue_var "$n" TITLE '')
    if [ "$label_mode" = true ]; then
      labels=$(issue_var "$n" LABELS '')
      case ",$labels," in
        *,ready-for-agent,*) printf '%s\t%s\n' "$n" "$title" ;;
      esac
    elif [ "$body_mode" = true ]; then
      timing=$(issue_var "$n" TIMING '')
      printf '%s\t%s\t%s\n' "$n" "$title" "$timing"
    fi
  done | sort -n
  exit 0
fi
printf 'fake gh: unsupported invocation: %s\n' "$*" >&2
exit 70
FAKE_GH
chmod +x "$BIN/gh"

cat > "$BIN/notify-ok" <<'NOTIFY_OK'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$COMPLETION_NOTIFY_LOG"
NOTIFY_OK
chmod +x "$BIN/notify-ok"

cat > "$BIN/notify-fail" <<'NOTIFY_FAIL'
#!/usr/bin/env bash
exit 1
NOTIFY_FAIL
chmod +x "$BIN/notify-fail"

commit_at() {
  date=$1
  message=$2
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git commit -q --allow-empty -m "$message"
}

# make_repo <name> — creates a local origin whose URL basename is
# completion-demo.git (grill-status derives the repo name from it) and a clone.
make_repo() {
  name=$1
  origin=$WORK/repos/$name/completion-demo.git
  clone=$WORK/repos/$name/main
  mkdir -p "$origin"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" config user.name test
  git -C "$clone" config user.email test@example.com
  (
    cd "$clone"
    commit_at 2026-10-01T00:00:00Z 'base'
  )
  git -C "$clone" push -q origin main
}

push_all() {
  git -C "$1" push -q origin main
  git -C "$1" push -q --tags origin 2>/dev/null || true
  git -C "$1" fetch -q origin
}

make_handoff() { # dir title kind date spec-lines...
  dir=$1
  title=$2
  kind=$3
  date=$4
  shift 4
  mkdir -p "$dir"
  {
    printf '# Design session handoff：%s\n\n## 规格\n' "$title"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$dir/handoff.md"
}

make_interrupted() { # dir kind date topic
  dir=$1
  kind=$2
  date=$3
  topic=$4
  mkdir -p "$dir"
  printf '%s\n' "$topic" > "$dir/topic.md"
}

make_issue() { # data-dir n key=value...
  dir=$1
  n=$2
  shift 2
  mkdir -p "$dir"
  {
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$dir/issue-$n.env"
}

run_report() { # out stderr -- args...
  out=$1
  err=$2
  shift 2
  (
    cd "$REPO"
    PATH="$BIN:$PATH" \
    DESIGN_SESSION_ROOT="$DESIGN_ROOT" \
    CR_GH_DATA="$GH_DATA" \
    COMPLETION_NOTIFY_CMD="$NOTIFY_CMD" \
    COMPLETION_NOTIFY_LOG="$NOTIFY_LOG" \
      bash "$SCRIPT" "$@"
  ) > "$out" 2> "$err"
  RUN_EXIT=$?
}

NOTIFY_CMD=$BIN/notify-ok

# ------------------------------------------------------------------ fixture A
# Two topics: feature done (#101 #102, closed after tag), map ongoing (#203).

make_repo demo-a
REPO_A=$WORK/repos/demo-a/main
GH_A=$WORK/gh-a
DESIGN_A=$WORK/design-a
mkdir -p "$GH_A" "$DESIGN_A"

make_issue "$GH_A" 101 STATE=closed TITLE=规格一 SUBS=111,112 CLOSED_AT=2026-11-02T10:00:00Z ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_A" 102 STATE=open TITLE=规格二 SUBS=121,122,123 ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_A" 111 STATE=closed TITLE=子票一
make_issue "$GH_A" 112 STATE=closed TITLE=子票二
make_issue "$GH_A" 121 STATE=closed TITLE=子票三
make_issue "$GH_A" 122 STATE=open TITLE=子票九
make_issue "$GH_A" 123 STATE=open TITLE=子票十
make_issue "$GH_A" 203 STATE=open TITLE=规格：读写路径收尾 SUBS=301,302,303,304,305 ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_A" 301 STATE=closed TITLE=子票四
make_issue "$GH_A" 302 STATE=closed TITLE=子票五
make_issue "$GH_A" 303 STATE=closed TITLE=子票六
make_issue "$GH_A" 304 STATE=open TITLE=子票七
make_issue "$GH_A" 305 STATE=open TITLE=子票八
for n in 111 112 121 301 302 303 304 305; do :; done

make_handoff "$DESIGN_A/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一' '- #102 规格二'
make_handoff "$DESIGN_A/completion-demo-20261102-1000-map" '地图 #200（读写路径收尾）' map 2026-11-02 \
  '- #203 规格：读写路径收尾'

(
  cd "$REPO_A"
  commit_at 2026-11-01T00:00:00Z 'tagged base'
  git tag v0.24.0
  push_all .
  commit_at 2026-11-03T00:00:00Z 'post one'
  commit_at 2026-11-04T00:00:00Z 'post two'
  commit_at 2026-11-05T00:00:00Z 'post three'
  push_all .
)

REPO=$REPO_A
GH_DATA=$GH_A
DESIGN_ROOT=$DESIGN_A

# Scenario 1: current topic still in progress; no notification.
: > "$WORK/notify-1.log"
NOTIFY_LOG=$WORK/notify-1.log
run_report "$WORK/s1.out" "$WORK/s1.err" "$REPO" --spec 101 --notify
expect_exit 0 'in-progress topic exits zero'
cat > "$WORK/s1.expected" <<'EOF'
🔵 你 grill 的《题目甲》：进度 1/2 份规格
   ✅ #101 规格一
   ⏳ #102 规格二（票 1/3）
   → 不用做什么，等剩下的规格落地后会再告诉你。
EOF
expect_same_file "$WORK/s1.expected" 'in-progress topic renders case 1' "$WORK/s1.out"
expect_count 0 'in-progress topic does not notify' "$WORK/notify-1.log"

# Fixture A2: same topics, but the feature topic is complete.

GH_A2=$WORK/gh-a2
mkdir -p "$GH_A2"
cp "$GH_A"/issue-101.env "$GH_A"/issue-111.env "$GH_A"/issue-112.env   "$GH_A"/issue-203.env "$GH_A"/issue-301.env "$GH_A"/issue-302.env   "$GH_A"/issue-303.env "$GH_A"/issue-304.env "$GH_A"/issue-305.env "$GH_A2/"
make_issue "$GH_A2" 102 STATE=closed TITLE=规格二 SUBS=121 CLOSED_AT=2026-11-02T10:05:00Z ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_A2" 121 STATE=closed TITLE=子票三
GH_DATA=$GH_A2

# Scenario 2: current topic done, another topic ongoing, nobody claimed it.
run_report "$WORK/s2.out" "$WORK/s2.err" "$REPO" --spec 101
expect_exit 0 'case 2 exits zero'
cat > "$WORK/s2.expected" <<'EOF'
✅ 你 grill 的《题目甲》已全部完成（#101 票 2/2、#102 票 1/1）
   仓库里还有 1 个题目没完成：
   ⏳ 地图 #200《读写路径收尾》：#203 票 3/5
👉 要你做：二选一（main 比 v0.24.0 多 3 个提交未发布）
   A. 现在发版 v0.25.0（只带已完成的）
   B. 等地图 #200《读写路径收尾》完成一起发
   推荐：A（没人在做，不该被它挡住）
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s2.expected" 'case 2 with unclaimed other work recommends A' "$WORK/s2.out"

# Scenario 3: same, but the ongoing spec has a claim record → recommend B.
mkdir -p "$REPO_A/.git/implement-spec-split/claims"
printf '{}' > "$REPO_A/.git/implement-spec-split/claims/spec-203.json"
run_report "$WORK/s3.out" "$WORK/s3.err" "$REPO" --spec 101
expect_exit 0 'claimed case exits zero'
sed 's/推荐：A（没人在做，不该被它挡住）/推荐：B（它正在实现，等它）/' \
  "$WORK/s2.expected" > "$WORK/s3.expected"
expect_same_file "$WORK/s3.expected" 'claimed other work recommends B' "$WORK/s3.out"
rm -f "$REPO_A/.git/implement-spec-split/claims/spec-203.json"

# ------------------------------------------------------------------ fixture B
# Everything done, one release-timing ticket, one interrupted feature session.

GH_B=$WORK/gh-b
DESIGN_B=$WORK/design-b
mkdir -p "$GH_B" "$DESIGN_B"
cp "$GH_A"/issue-101.env "$GH_A"/issue-111.env "$GH_A"/issue-112.env "$GH_B/"
make_issue "$GH_B" 102 STATE=closed TITLE=规格二 SUBS=121 CLOSED_AT=2026-11-02T10:05:00Z ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_B" 121 STATE=closed TITLE=子票三
make_issue "$GH_B" 203 STATE=closed TITLE=规格：读写路径收尾 SUBS=301,302,303,304,305 CLOSED_AT=2026-11-03T09:00:00Z ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_B" 301 STATE=closed TITLE=子票四
make_issue "$GH_B" 302 STATE=closed TITLE=子票五
make_issue "$GH_B" 303 STATE=closed TITLE=子票六
make_issue "$GH_B" 304 STATE=closed TITLE=子票七
make_issue "$GH_B" 305 STATE=closed TITLE=子票八
make_issue "$GH_B" 371 STATE=open TITLE='rpm 系发行版未采集系统包' TIMING='出现包含 abc123 的 tag'

make_handoff "$DESIGN_B/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一' '- #102 规格二'
make_handoff "$DESIGN_B/completion-demo-20261102-1000-map" '地图 #200（读写路径收尾）' map 2026-11-02 \
  '- #203 规格：读写路径收尾'
make_interrupted "$DESIGN_B/completion-demo-20261103-0800-feature" feature 2026-11-03 '被打断的话题'

make_repo demo-b
REPO_B=$WORK/repos/demo-b/main
(
  cd "$REPO_B"
  commit_at 2026-11-01T00:00:00Z 'tagged base'
  git tag v0.24.0
  push_all .
  for i in 1 2 3 4 5; do commit_at "2026-11-0${i}T12:00:00Z" "post $i"; done
  push_all .
)

REPO=$REPO_B
GH_DATA=$GH_B
DESIGN_ROOT=$DESIGN_B

: > "$WORK/notify-4.log"
NOTIFY_LOG=$WORK/notify-4.log
run_report "$WORK/s4.out" "$WORK/s4.err" "$REPO" --spec 101 --notify
expect_exit 0 'all-complete case exits zero'
cat > "$WORK/s4.expected" <<'EOF'
✅ 你 grill 的《题目甲》已全部完成（#101 票 2/2、#102 票 1/1）
✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票
👉 推荐：打 tag 发版 v0.25.0（main 比 v0.24.0 多 5 个提交未发布）
   包含：《题目甲》#101 #102；地图 #200《读写路径收尾》#203
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
   发版后会解冻：#371 rpm 系发行版未采集系统包
⚠️ 有 1 个 grill 中断了没有结论：2026-11-03 08:00「被打断的话题」
   要续上就重新 /grill-feature 这个话题。
EOF
expect_same_file "$WORK/s4.expected" 'all-complete case renders case 3' "$WORK/s4.out"
expect_count 1 'complete topic notifies exactly once' "$WORK/notify-4.log"
expect_file_has 'completion-demo|✅ 你 grill 的《题目甲》已全部完成' \
  'notification receives repo and first line' "$WORK/notify-4.log"

# Notification failure must not change the exit code or output.
NOTIFY_CMD=$BIN/notify-fail
run_report "$WORK/s5.out" "$WORK/s5.err" "$REPO" --spec 101 --notify
expect_exit 0 'notification failure keeps exit zero'
expect_same_file "$WORK/s4.expected" 'notification failure keeps output' "$WORK/s5.out"
expect_file_has 'notification command failed (ignored)' \
  'notification failure warns' "$WORK/s5.err"
NOTIFY_CMD=$BIN/notify-ok

# ------------------------------------------------------------------ fixture C
# No tags at all.

make_repo demo-c
REPO_C=$WORK/repos/demo-c/main
(
  cd "$REPO_C"
  commit_at 2026-11-01T00:00:00Z 'only commit'
  push_all .
)
GH_C=$WORK/gh-c
DESIGN_C=$WORK/design-c
mkdir -p "$GH_C" "$DESIGN_C"
cp "$GH_A"/issue-101.env "$GH_A"/issue-111.env "$GH_A"/issue-112.env "$GH_C/"
make_handoff "$DESIGN_C/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一'

REPO=$REPO_C
GH_DATA=$GH_C
DESIGN_ROOT=$DESIGN_C
run_report "$WORK/s6.out" "$WORK/s6.err" "$REPO" --spec 101
expect_exit 0 'no-tag case exits zero'
cat > "$WORK/s6.expected" <<'EOF'
✅ 你 grill 的《题目甲》已全部完成（#101 票 2/2）
✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票
EOF
expect_same_file "$WORK/s6.expected" 'repository without tags omits release advice' "$WORK/s6.out"

# ------------------------------------------------------------------ fixture D
# Everything published; one ordinary and one release timing ticket; map grill
# interrupted.

make_repo demo-d
REPO_D=$WORK/repos/demo-d/main
(
  cd "$REPO_D"
  commit_at 2026-11-01T00:00:00Z 'tagged tip'
  git tag v0.24.0
  commit_at 2026-11-02T00:00:00Z 'after tag'
  git tag -f v0.24.0 >/dev/null 2>&1
  git reset -q --hard v0.24.0
  push_all .
)
GH_D=$WORK/gh-d
DESIGN_D=$WORK/design-d
mkdir -p "$GH_D" "$DESIGN_D"
cp "$GH_A"/issue-101.env "$GH_A"/issue-111.env "$GH_A"/issue-112.env "$GH_D/"
make_issue "$GH_D" 400 STATE=open TITLE=实机验证票 TIMING='实机验证通过后'
make_issue "$GH_D" 401 STATE=open TITLE=等发版票 TIMING='出现 v0.24.0 之后的 tag'
make_handoff "$DESIGN_D/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一'
make_interrupted "$DESIGN_D/completion-demo-20261103-0800-map" map 2026-11-03 '被打断的地图话题'

REPO=$REPO_D
GH_DATA=$GH_D
DESIGN_ROOT=$DESIGN_D
run_report "$WORK/s7.out" "$WORK/s7.err" "$REPO"
expect_exit 0 'fully-published case exits zero'
cat > "$WORK/s7.expected" <<'EOF'
✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票
👉 当前代码已全部发布（v0.24.0），无需发版
⏳ 等待时机（不提问）：#400 实机验证票：实机验证通过后
⏳ 等待时机（不提问）：#401 等发版票：出现 v0.24.0 之后的 tag
⚠️ 有 1 个 grill 中断了没有结论：2026-11-03 08:00「被打断的地图话题」
   要续上就重新 /grill-map 这个话题。
EOF
expect_same_file "$WORK/s7.expected" 'fully published case lists timing tickets' "$WORK/s7.out"

# ------------------------------------------------------------------ fixture E
# Done topic closed before the tag and plain post commits → patch bump.

make_repo demo-e
REPO_E=$WORK/repos/demo-e/main
(
  cd "$REPO_E"
  commit_at 2026-11-01T00:00:00Z 'tagged base'
  git tag v0.24.0
  push_all .
  commit_at 2026-11-02T00:00:00Z 'post one'
  commit_at 2026-11-03T00:00:00Z 'post two'
  push_all .
)
GH_E=$WORK/gh-e
DESIGN_E=$WORK/design-e
mkdir -p "$GH_E" "$DESIGN_E"
make_issue "$GH_E" 101 STATE=closed TITLE=规格一 SUBS=111,112 CLOSED_AT=2026-10-15T00:00:00Z ASSIGNEES=0 LABELS=ready-for-agent
make_issue "$GH_E" 111 STATE=closed TITLE=子票一
make_issue "$GH_E" 112 STATE=closed TITLE=子票二
make_handoff "$DESIGN_E/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一'

REPO=$REPO_E
GH_DATA=$GH_E
DESIGN_ROOT=$DESIGN_E
run_report "$WORK/s8.out" "$WORK/s8.err" "$REPO"
expect_exit 0 'patch-bump case exits zero'
cat > "$WORK/s8.expected" <<'EOF'
✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票
👉 推荐：打 tag 发版 v0.24.1（main 比 v0.24.0 多 2 个提交未发布）
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s8.expected" 'plain commits bump patch version' "$WORK/s8.out"

# ------------------------------------------------------------------ fixture F
# No grill topics; a feat merge after the tag → minor bump.

make_repo demo-f
REPO_F=$WORK/repos/demo-f/main
(
  cd "$REPO_F"
  commit_at 2026-11-01T00:00:00Z 'tagged base'
  git tag v0.24.0
  push_all .
  git checkout -q -b feature-x
  commit_at 2026-11-02T00:00:00Z 'work'
  git checkout -q main
  GIT_AUTHOR_DATE=2026-11-03T00:00:00Z GIT_COMMITTER_DATE=2026-11-03T00:00:00Z \
    git merge -q --no-ff feature-x -m 'feat: 新后台采集'
  push_all .
)
GH_F=$WORK/gh-f
DESIGN_F=$WORK/design-f
mkdir -p "$GH_F" "$DESIGN_F"

REPO=$REPO_F
GH_DATA=$GH_F
DESIGN_ROOT=$DESIGN_F
run_report "$WORK/s9.out" "$WORK/s9.err" "$REPO"
expect_exit 0 'feat-merge case exits zero'
cat > "$WORK/s9.expected" <<'EOF'
（本仓库没有 grill 题目记录）
👉 推荐：打 tag 发版 v0.25.0（main 比 v0.24.0 多 2 个提交未发布）
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s9.expected" 'feat merge bumps minor without topics' "$WORK/s9.out"

# ------------------------------------------------------------------ fixture G
# Non-semver tag → suggest a new tag without a version.

make_repo demo-g
REPO_G=$WORK/repos/demo-g/main
(
  cd "$REPO_G"
  commit_at 2026-11-01T00:00:00Z 'tagged base'
  git tag release-2026
  push_all .
  commit_at 2026-11-02T00:00:00Z 'post one'
  push_all .
)
GH_G=$WORK/gh-g
DESIGN_G=$WORK/design-g
mkdir -p "$GH_G" "$DESIGN_G"
cp "$GH_A"/issue-101.env "$GH_A"/issue-111.env "$GH_A"/issue-112.env "$GH_G/"
make_handoff "$DESIGN_G/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一'

REPO=$REPO_G
GH_DATA=$GH_G
DESIGN_ROOT=$DESIGN_G
run_report "$WORK/s10.out" "$WORK/s10.err" "$REPO"
expect_exit 0 'non-semver tag case exits zero'
cat > "$WORK/s10.expected" <<'EOF'
✅ 仓库里所有 grill 的题目都已完成，没有在做的规格和票
👉 推荐：打新 tag（main 比 release-2026 多 1 个提交未发布）
   包含：《题目甲》#101
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s10.expected" 'non-semver tag omits version number' "$WORK/s10.out"

# ------------------------------------------------------------------ fixture H
# gh query failure for one spec.

GH_H=$WORK/gh-h
DESIGN_H=$WORK/design-h
mkdir -p "$GH_H" "$DESIGN_H"
make_issue "$GH_H" 101 STATE=closed TITLE=规格一 SUBS=111,112 CLOSED_AT=2026-11-02T00:00:00Z FAIL=1
make_issue "$GH_H" 102 STATE=open TITLE=规格二 SUBS=121,122,123
make_issue "$GH_H" 111 STATE=closed TITLE=子票一
make_issue "$GH_H" 112 STATE=closed TITLE=子票二
make_issue "$GH_H" 121 STATE=closed TITLE=子票三
make_issue "$GH_H" 122 STATE=open TITLE=子票四
make_issue "$GH_H" 123 STATE=open TITLE=子票五
make_handoff "$DESIGN_H/completion-demo-20261101-0900-feature" 题目甲 feature 2026-11-01 \
  '- #101 规格一' '- #102 规格二'

REPO=$REPO_A
GH_DATA=$GH_H
DESIGN_ROOT=$DESIGN_H
run_report "$WORK/s11.out" "$WORK/s11.err" "$REPO" --spec 101
expect_exit 0 'gh failure keeps exit zero'
cat > "$WORK/s11.expected" <<'EOF'
🔵 你 grill 的《题目甲》：进度 0/2 份规格
   ⏳ #101 （查询失败）
   ⏳ #102 规格二（票 1/3）
   → 不用做什么，等剩下的规格落地后会再告诉你。
EOF
expect_same_file "$WORK/s11.expected" 'gh failure renders query-failed spec' "$WORK/s11.out"

# ------------------------------------------------------------------ fixture I
# proxy-hub shape: no grill topic, Specs that depend on each other, the Spec
# that just landed (#22) with its tickets, and one real loose ticket (#60).
# Issue relations (Spec bodies, sub-issues, blockers) are served to
# pipeline-status.sh --graph by the same fake gh.

PS='## Problem Statement'
make_repo demo-i
REPO_I=$WORK/repos/demo-i/main
(
  cd "$REPO_I"
  commit_at 2026-11-20T00:00:00Z 'tagged base'
  git tag v1.2.0
  push_all .
  commit_at 2026-11-24T00:00:00Z 'post one'
  commit_at 2026-11-24T01:00:00Z 'post two'
  push_all .
)
GH_I=$WORK/gh-i
DESIGN_I=$WORK/design-i
mkdir -p "$GH_I" "$DESIGN_I" "$REPO_I/.git/implement-spec-split/claims"
make_issue "$GH_I" 19 STATE=open TITLE='规格② hub 路由' BODY="$PS" SUBS=28,29,30,31,32 LABELS=ready-for-agent
make_issue "$GH_I" 28 STATE=closed TITLE='hub 路由 票1'
make_issue "$GH_I" 29 STATE=closed TITLE='hub 路由 票2'
make_issue "$GH_I" 30 STATE=closed TITLE='hub 路由 票3'
make_issue "$GH_I" 31 STATE=closed TITLE='hub 路由 票4'
make_issue "$GH_I" 32 STATE=open TITLE='hub 路由 票5' LABELS=ready-for-agent
make_issue "$GH_I" 20 STATE=open TITLE='规格③ 认证' BODY="$PS" SUBS=33,34 LABELS=ready-for-agent
make_issue "$GH_I" 33 STATE=open TITLE='认证 票1' LABELS=ready-for-agent BLOCKED_BY=32
make_issue "$GH_I" 34 STATE=open TITLE='认证 票2' LABELS=ready-for-agent BLOCKED_BY=32
make_issue "$GH_I" 21 STATE=open TITLE='规格④ 限流' BODY="$PS" SUBS=35 LABELS=ready-for-agent
make_issue "$GH_I" 35 STATE=open TITLE='限流 票1' LABELS=ready-for-agent BLOCKED_BY=32,33
make_issue "$GH_I" 22 STATE=closed TITLE='规格⑤ proxy-hub 收尾' BODY="$PS" SUBS=36,37,38 CLOSED_AT=2026-11-25T10:00:00Z LABELS=ready-for-agent
make_issue "$GH_I" 36 STATE=closed TITLE='收尾 票1'
make_issue "$GH_I" 37 STATE=closed TITLE='收尾 票2'
make_issue "$GH_I" 38 STATE=closed TITLE='收尾 票3'
make_issue "$GH_I" 60 STATE=open TITLE='补 README 的安装步骤' LABELS=ready-for-agent
# A live handoff claim is what pipeline-status.sh reads as 实现中.
printf '{"handoff":"fresh","handoff_until_epoch":4102444800,"branch":"spec-19"}' \
  > "$REPO_I/.git/implement-spec-split/claims/spec-19.json"

REPO=$REPO_I
GH_DATA=$GH_I
DESIGN_ROOT=$DESIGN_I

# Scenario 12: --spec belongs to no grill topic and has just landed.
run_report "$WORK/s12.out" "$WORK/s12.err" "$REPO" --spec 22
expect_exit 0 'no-topic landed spec exits zero'
expect_line 1 '✅ 规格 #22 规格⑤ proxy-hub 收尾 已落地（票 3/3）' \
  'landed spec leads the report' "$WORK/s12.out"
cat > "$WORK/s12.expected" <<'EOF'
✅ 规格 #22 规格⑤ proxy-hub 收尾 已落地（票 3/3）
（本仓库没有 grill 题目记录）
   仓库里还在进行的规格（3 个）：
      ⏳ #19 规格② hub 路由（实现中，票 4/5）
      ⏳ #20 规格③ 认证（等 #19）
      ⏳ #21 规格④ 限流（等 #19、#20）
   还有 1 张不属于任何规格的散票：#60 补 README 的安装步骤
👉 要你做：二选一（main 比 v1.2.0 多 2 个提交未发布）
   A. 现在发版 v1.2.1（只带已完成的）
   B. 等所有在做的工作完成一起发
   推荐：B（它正在实现，等它）
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s12.expected" 'no-topic report lists specs, dependencies and the one loose ticket' "$WORK/s12.out"
expect_has_count '#22' 1 'landed spec appears only in its conclusion' "$WORK/s12.out"
expect_has_count '散票' 1 'exactly one loose-ticket line' "$WORK/s12.out"

# Scenario 13: the landing ran before the Spec issue was closed; every ticket
# is closed, so it still reads as landed and stays out of every other list.
GH_I2=$WORK/gh-i2
mkdir -p "$GH_I2"
cp "$GH_I"/issue-*.env "$GH_I2/"
make_issue "$GH_I2" 22 STATE=open TITLE='规格⑤ proxy-hub 收尾' BODY="$PS" SUBS=36,37,38 LABELS=ready-for-agent
GH_DATA=$GH_I2
run_report "$WORK/s13.out" "$WORK/s13.err" "$REPO" --spec 22
expect_exit 0 'still-open landed spec exits zero'
expect_line 1 '✅ 规格 #22 规格⑤ proxy-hub 收尾 已落地（票 3/3，issue 还没关）' \
  'open issue with every ticket closed reads as landed' "$WORK/s13.out"
expect_has_count '#22' 1 'open just-landed spec appears only in its conclusion' "$WORK/s13.out"
expect_file_has '   仓库里还在进行的规格（3 个）：' 'open just-landed spec left out of ongoing specs' "$WORK/s13.out"
expect_file_has '   还有 1 张不属于任何规格的散票：#60 补 README 的安装步骤' \
  'open just-landed spec and its tickets are not loose tickets' "$WORK/s13.out"

# Scenario 14: partial landing — #34 landed, #33 waits on #32 of Spec #19.
GH_I3=$WORK/gh-i3
mkdir -p "$GH_I3"
cp "$GH_I"/issue-*.env "$GH_I3/"
make_issue "$GH_I3" 34 STATE=closed TITLE='认证 票2'
GH_DATA=$GH_I3
run_report "$WORK/s14.out" "$WORK/s14.err" "$REPO" --spec 20
expect_exit 0 'partial landing exits zero'
expect_line 1 '🟡 规格 #20 部分落地：剩 #33 等 #19' \
  'partial landing names the waiting ticket and the Spec it waits for' "$WORK/s14.out"
expect_file_has '   仓库里还在进行的规格（2 个）：' 'partial spec is not repeated as ongoing' "$WORK/s14.out"
expect_file_has '      ⏳ #21 规格④ 限流（等 #19、#20）' 'dependents still name the partial spec' "$WORK/s14.out"
expect_file_has '   还有 1 张不属于任何规格的散票：#60 补 README 的安装步骤' \
  'waiting ticket of the partial spec is not a loose ticket' "$WORK/s14.out"

# Scenario 15: pipeline-status.sh --graph fails; the gh-based conclusion stays
# first and each affected section says （查询失败）.
export CR_GH_GRAPH_FAIL=1
GH_DATA=$GH_I
run_report "$WORK/s15.out" "$WORK/s15.err" "$REPO" --spec 22
unset CR_GH_GRAPH_FAIL
expect_exit 0 'graph failure exits zero'
expect_line 1 '✅ 规格 #22 规格⑤ proxy-hub 收尾 已落地（票 3/3）' \
  'graph failure keeps the gh-based conclusion first' "$WORK/s15.out"
cat > "$WORK/s15.expected" <<'EOF'
✅ 规格 #22 规格⑤ proxy-hub 收尾 已落地（票 3/3）
（本仓库没有 grill 题目记录）
   ⚠️ 仓库里还在进行的规格（查询失败）
   还有 8 张就绪票（查询失败，未排除规格和子票）：#19 规格② hub 路由、#20 规格③ 认证、#21 规格④ 限流、#32 hub 路由 票5、#33 认证 票1、#34 认证 票2、#35 限流 票1、#60 补 README 的安装步骤
👉 要你做：二选一（main 比 v1.2.0 多 2 个提交未发布）
   A. 现在发版 v1.2.1（只带已完成的）
   B. 等所有在做的工作完成一起发
   推荐：A（没人在做，不该被它挡住）
   回复「发版」我来打 tag 并推送（打之前会先跟你确认版本号）。
EOF
expect_same_file "$WORK/s15.expected" 'graph failure reports （查询失败） and continues' "$WORK/s15.out"

# ---------------------------------------------------------------- usage errors

run_report "$WORK/u1.out" "$WORK/u1.err" "$REPO" --bogus
expect_exit 64 'unknown option exits 64'
run_report "$WORK/u2.out" "$WORK/u2.err" "$REPO" --spec abc
expect_exit 64 'non-numeric --spec exits 64'
run_report "$WORK/u3.out" "$WORK/u3.err" "$REPO" "$REPO" extra
expect_exit 64 'extra positional exits 64'
run_report "$WORK/u4.out" "$WORK/u4.err" --help
expect_exit 0 'help exits zero'
expect_file_has 'Usage: completion-report.sh' 'help prints usage' "$WORK/u4.out"

printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
printf 'Scratch retained: %s\n' "$WORK"
[ "$FAILED" -eq 0 ]
