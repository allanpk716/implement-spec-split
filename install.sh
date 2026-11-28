#!/usr/bin/env bash
# 本机安装脚本（规格 #58）。第一段（票 #63）只做技能软链：
#   扫描 git 跟踪的、含 SKILL.md 的目录（根技能 + 子技能），逐个确保
#   $ISS_SKILLS_DIR/<name> 是指向主 checkout 对应目录的软链；仓库里已不存在的
#   技能留下的悬空链删掉；同名真实目录不动、只警告。本机配置期望项（#64）、
#   doctor 接入（#65）、落地流程接入（#66）不在这里。
#
# 主 checkout = 运行本脚本的那份 checkout（脚本所在目录的仓库根，按物理路径）。
# 经软链调用（bash ~/.claude/skills/implement-spec-split/install.sh）时也以脚本
# 真正所在的目录为准，不猜别的 checkout。「指向正确」按链解析到的物理目录判定，
# 不看链接文字：README 里经 ~/.claude/skills/implement-spec-split/<name> 写的链
# 解析到同一目录，同样算就位。
#
# 用法：./install.sh [--check] [--json] [-h|--help]
#   默认    安装：建缺的链、改指错的链、删悬空链，每处修改打印一行；重复运行零修改
#   --check 只报告不改；退出码 0 = 全部就位，1 = 还有未就位的
#   --json  只输出一个 JSON 对象，形状沿用 scripts/doctor.sh（checks 数组 + summary）
#
# 退出码：0 全部就位；1 仍有未就位的技能（另一份 clone 的真实目录、建链失败、
#   Windows 的手工步骤）；2 跑不起来（缺命令、不在 git checkout 里、建不出技能
#   目录）；64 用法错误。
#
# 环境变量：ISS_SKILLS_DIR  软链落点，默认 ~/.claude/skills；测试与冒烟指向临时目录，
#   设了它脚本只改它指向的位置。
#
# Windows（uname -s 为 MINGW* / MSYS*，沿用 doctor.sh 的平台判定）不建链不删链：
# Git Bash 里 mklink /J 要做路径转换、readlink 对 junction 又不可靠。每个未就位的
# 技能打印一行手工步骤（README 原话：mklink /J，或者直接复制）记 WARN；已在位的
# 目录联接或副本算就位（未核对指向）；--check 对缺链报 WARN 而不是 FAIL。
#
# --json 形状（#65 的 doctor 靠它读结果；键序固定，两次运行间稳定）：
#   {"mode":"install"|"check","windows":bool,"mainCheckout":"<物理路径>","skillsDir":"<原样>",
#    "checks":[{"group":"skills","level":"PASS|WARN|FAIL","status":…,"changed":bool,
#               "name":…,"dir":…,"link":…,"target":…,"message":…,"hint":…}],
#    "summary":{"pass":n,"warn":n,"fail":n,"info":n,"changed":n,"drift":n}}
#   level 是这次运行之后的状态：安装模式下建好的链是 PASS，changed=true 的行是修改；
#   status 取 ok | created | relinked | removed | missing | wrong | dangling |
#   real-dir | manual | present | error。退出码看 drift（level 不是 PASS 的行数），
#   不只看 FAIL——Windows 的 WARN 也是漂移。后续票往 checks 里加别的 group
#   （#64 的本机配置期望项），本票只留位置。

set -u

# The checkout is where this script lives; never one inherited from the caller.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

CHECK_MODE=0
JSON_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_MODE=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --check      Report only; change nothing. Exit 1 when any skill is not in place.
  --json       Output one JSON object only
  -h, --help   Show this help

For every directory git tracks with a SKILL.md (the root skill and the
sub-skills), makes ~/.claude/skills/<name> a symlink to that directory in the
checkout this script runs from, removes dangling links left by skills the
checkout no longer has, and never touches a real directory of the same name
(it warns instead). Re-running changes nothing once everything is in place.

Environment:
  ISS_SKILLS_DIR  Where the links go (default ~/.claude/skills).

On Windows (Git Bash) nothing is linked: each skill not in place prints the
manual step (mklink /J, or copy) as a WARN.

Exit codes: 0 all in place; 1 some skill is not in place; 2 could not run;
64 usage error.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; echo "usage: ./install.sh [--check] [--json] [--help]" >&2; exit 64 ;;
  esac
done

for tool in node git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required command not found: $tool" >&2; exit 2; }
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || { echo "cannot locate the script directory: $0" >&2; exit 2; }
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git checkout: ${SCRIPT_DIR}（主 checkout 取脚本所在的仓库根）" >&2; exit 2; }
REPO_ROOT=$(cd "$REPO_ROOT" && pwd -P)

[ -n "${ISS_SKILLS_DIR:-}" ] || [ -n "${HOME:-}" ] || { echo "HOME is not set; set ISS_SKILLS_DIR" >&2; exit 2; }
SKILLS_DIR=${ISS_SKILLS_DIR:-$HOME/.claude/skills}

UNAME_S=$(uname -s)
case "$UNAME_S" in
  MINGW*|MSYS*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

TMP_ROOT=$(mktemp -d) || { echo "cannot create a temporary directory" >&2; exit 2; }
ROWS=$TMP_ROOT/rows.tsv
ERR=$TMP_ROOT/err
cleanup() {
  rm -f "$ROWS" "$ERR"
  rmdir "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
: > "$ROWS"

N_PASS=0
N_WARN=0
N_FAIL=0
N_CHANGED=0

# add <LEVEL> <status> <changed 0|1> <name> <dir> <link> <target> <message> [hint]
# Records one result: a row for --json, a line for the terminal (one line per
# change, as the spec asks). group is always skills until #64 adds its own.
add() {
  local level=$1 status=$2 changed=$3 name=$4 dir=$5 link=$6 target=$7 message=$8 hint=${9:-} suffix=
  printf 'skills\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$level" "$status" "$changed" "$name" "$dir" "$link" "$target" "$message" "$hint" >> "$ROWS"
  case "$level" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
  esac
  [ "$changed" -eq 1 ] && N_CHANGED=$((N_CHANGED + 1))
  if [ "$JSON_MODE" -eq 0 ]; then
    [ -n "$hint" ] && suffix=" -> ${hint}"
    printf '[%s] %s%s\n' "$level" "$message" "$suffix"
  fi
}

# The physical path of an existing directory (every symlink resolved), or nothing.
phys() {
  (cd "$1" 2>/dev/null && pwd -P)
}

win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# manual_hint <link> <target> [remove-first]: the Windows manual step, README's
# wording (mklink /J, or copy) with the two paths filled in.
manual_hint() {
  local step
  step="在 cmd.exe 里执行：mklink /J \"$(win_path "$1")\" \"$(win_path "$2")\"，或者直接复制"
  if [ -n "${3:-}" ]; then
    printf '先删除 "%s"，再%s' "$(win_path "$1")" "$step"
  else
    printf '%s' "$step"
  fi
}

# skill_name <SKILL.md>: the frontmatter name, or nothing.
skill_name() {
  local file=$1
  [ "$(head -n 1 "$file" | tr -d '\r')" = "---" ] || return 0
  tr -d '\r' < "$file" | sed -n '2,/^---$/p' | sed -n 's/^name:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]$//"
}

# inside_repo <path>: whether <path> lies under the checkout, judged by its
# nearest existing ancestor (the path itself may be gone -- that is the point).
inside_repo() {
  local path=$1 rest= ancestor=
  while [ -n "$path" ] && [ ! -e "$path" ]; do
    rest=/${path##*/}${rest}
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  [ -n "$path" ] || return 1
  ancestor=$(phys "$path") || return 1
  [ -n "$ancestor" ] || return 1
  case "${ancestor}${rest}/" in "${REPO_ROOT}"/*) return 0 ;; esac
  return 1
}

# relink <dir> <name> <link> <target> <what>: replace a wrong or dangling link;
# <what> describes the old one ("悬空链 <path>" or "指向 <path>"). A symlink is
# never a real directory, so replacing it loses nothing.
relink() {
  local dir=$1 name=$2 link=$3 target=$4 what=$5
  if rm -f "$link" && ln -s "$target" "$link" 2>"$ERR"; then
    add PASS relinked 1 "$name" "$dir" "$link" "$target" "${name} 已改指（原为${what}）" "$target"
  else
    add FAIL error 0 "$name" "$dir" "$link" "$target" "${name} 改指失败：$(tr '\n' ' ' < "$ERR")" ""
  fi
}

# windows_skill <dir> <name> <link> <target>: nothing is made or removed; a
# skill that is not verifiably in place gets the manual step as a WARN.
windows_skill() {
  local dir=$1 name=$2 link=$3 target=$4
  if [ -L "$link" ]; then
    if [ -e "$link" ] && [ "$(phys "$link")" = "$target" ]; then
      add PASS ok 0 "$name" "$dir" "$link" "$target" "${name} 软链已指向主 checkout" "$target"
    else
      add WARN manual 0 "$name" "$dir" "$link" "$target" "${name} 软链指向别处或已悬空：$(readlink "$link")（Windows 不自动改指）" "$(manual_hint "$link" "$target" remove)"
    fi
  elif [ -d "$link" ]; then
    add PASS present 0 "$name" "$dir" "$link" "$target" "${name} 已存在（目录联接或副本，未核对指向）" ""
  else
    add WARN manual 0 "$name" "$dir" "$link" "$target" "${name} 缺链（Windows 不自动建链）" "$(manual_hint "$link" "$target")"
  fi
}

# skill <dir> <name>: the skill in directory <dir> ("." is the root), named
# <name>. Its link is $SKILLS_DIR/<name> and must resolve to $REPO_ROOT/<dir>.
skill() {
  local dir=$1 name=$2 target link old actual
  if [ "$dir" = . ]; then target=$REPO_ROOT; else target=$REPO_ROOT/$dir; fi
  link=$SKILLS_DIR/$name
  if [ "$IS_WINDOWS" -eq 1 ]; then
    windows_skill "$dir" "$name" "$link" "$target"
    return
  fi
  if [ -L "$link" ]; then
    old=$(readlink "$link")
    if [ ! -e "$link" ]; then
      if [ "$CHECK_MODE" -eq 1 ]; then
        add FAIL dangling 0 "$name" "$dir" "$link" "$target" "${name} 悬空链：${old} 不存在" "运行 ${REPO_ROOT}/install.sh 改指"
      else
        relink "$dir" "$name" "$link" "$target" "悬空链 ${old}"
      fi
      return
    fi
    actual=$(phys "$link")
    [ -n "$actual" ] || actual=$old   # a link to a file, which cd cannot enter
    if [ "$actual" = "$target" ]; then
      add PASS ok 0 "$name" "$dir" "$link" "$target" "${name} 软链已指向主 checkout" "$target"
    elif [ "$CHECK_MODE" -eq 1 ]; then
      add FAIL wrong 0 "$name" "$dir" "$link" "$target" "${name} 指向别处：${actual}（主 checkout 是 ${target}）" "运行 ${REPO_ROOT}/install.sh 改指"
    else
      relink "$dir" "$name" "$link" "$target" "指向 ${actual}"
    fi
    return
  fi
  if [ -e "$link" ]; then
    # Not a symlink: a real directory (or a file). Never touched.
    actual=$(phys "$link")
    if [ "$actual" = "$target" ]; then
      add PASS ok 0 "$name" "$dir" "$link" "$target" "${name} 是真实目录，就是主 checkout 的对应目录，视为已就位" ""
    else
      add WARN real-dir 0 "$name" "$dir" "$link" "$target" "${name} 是真实目录不是软链，未动：${link}（主 checkout 是 ${target}）" "另一份 clone？确认后改名或删除，再运行 ${REPO_ROOT}/install.sh"
    fi
    return
  fi
  if [ "$CHECK_MODE" -eq 1 ]; then
    add FAIL missing 0 "$name" "$dir" "$link" "$target" "${name} 缺链：${link}" "运行 ${REPO_ROOT}/install.sh 建链"
    return
  fi
  if ln -s "$target" "$link" 2>"$ERR"; then
    add PASS created 1 "$name" "$dir" "$link" "$target" "${name} 已建链" "$target"
  else
    add FAIL error 0 "$name" "$dir" "$link" "$target" "${name} 建链失败：$(tr '\n' ' ' < "$ERR")" ""
  fi
}

# stale_links: dangling links in the skills directory that point into this
# checkout, at a directory it no longer has (the two old switches left some).
# They are not skills any more, so the per-skill pass never sees them. A
# dangling link pointing anywhere else is somebody else's and stays.
stale_links() {
  local entry name target
  [ -d "$SKILLS_DIR" ] || return 0
  for entry in "$SKILLS_DIR"/* "$SKILLS_DIR"/.[!.]*; do
    [ -L "$entry" ] || continue
    [ -e "$entry" ] && continue
    name=${entry##*/}
    if printf '%s\n' "$KNOWN" | grep -Fxq -- "$name"; then continue; fi
    target=$(readlink "$entry")
    case "$target" in /*) ;; *) target=$SKILLS_DIR/$target ;; esac
    inside_repo "$target" || continue
    if [ "$CHECK_MODE" -eq 1 ]; then
      add FAIL dangling 0 "$name" "" "$entry" "" "${name} 悬空链：仓库里已没有这个技能，${target} 不存在" "运行 ${REPO_ROOT}/install.sh 删除"
    elif rm -f "$entry"; then
      add PASS removed 1 "$name" "" "$entry" "" "${name} 已删除悬空链（原指向 ${target}）" ""
    else
      add FAIL error 0 "$name" "" "$entry" "" "${name} 删除悬空链失败：${entry}" ""
    fi
  done
}

if [ "$JSON_MODE" -eq 0 ]; then
  MODE_TEXT=安装
  [ "$CHECK_MODE" -eq 0 ] || MODE_TEXT='只检查（--check）'
  printf '主 checkout：%s（运行本脚本的 checkout）\n' "$REPO_ROOT"
  printf '技能目录：%s\n' "$SKILLS_DIR"
  printf '模式：%s\n' "$MODE_TEXT"
fi

if [ "$CHECK_MODE" -eq 0 ] && [ "$IS_WINDOWS" -eq 0 ]; then
  mkdir -p "$SKILLS_DIR" || { echo "cannot create the skills directory: ${SKILLS_DIR}" >&2; exit 2; }
fi

# The skills: every git-tracked SKILL.md, root first, in git's order. A file
# merely named like one (upstream/implement-spec.SKILL.md) is not a skill.
# core.quotePath=false: git would otherwise print a non-ASCII path escaped and
# quoted, which the pattern below could not match.
KNOWN=
SKILL_FILES=$(git -c core.quotePath=false -C "$REPO_ROOT" ls-files 2>/dev/null | grep -E '(^|/)SKILL\.md$') || true
[ -n "$SKILL_FILES" ] || { echo "no SKILL.md is tracked in ${REPO_ROOT}" >&2; exit 2; }
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if [ "$file" = SKILL.md ]; then dir=.; else dir=${file%/SKILL.md}; fi
  name=$(skill_name "$REPO_ROOT/$file")
  if [ -z "$name" ]; then
    add FAIL error 0 "" "$dir" "" "" "${file} 没有 frontmatter 的 name，跳过" "在 frontmatter 里补一行 name: <技能名>"
    continue
  fi
  if printf '%s\n' "$KNOWN" | grep -Fxq -- "$name"; then
    add FAIL error 0 "$name" "$dir" "" "" "${file} 与另一个技能重名（${name}），跳过" "frontmatter 的 name 必须唯一"
    continue
  fi
  KNOWN=$KNOWN$name$'\n'
  skill "$dir" "$name"
done <<< "$SKILL_FILES"

if [ "$IS_WINDOWS" -eq 0 ]; then
  stale_links
fi

if [ "$JSON_MODE" -eq 1 ]; then
  ROWS=$ROWS CHECK_MODE=$CHECK_MODE IS_WINDOWS=$IS_WINDOWS REPO_ROOT=$REPO_ROOT SKILLS_DIR=$SKILLS_DIR node <<'NODE'
const fs = require('fs');
const rows = fs.readFileSync(process.env.ROWS, 'utf8').split('\n').filter(Boolean).map(line => {
  const [group, level, status, changed, name, dir, link, target, message, hint] = line.split('\x1f');
  return {group, level, status, changed: changed === '1', name, dir, link, target, message, hint};
});
const summary = {pass: 0, warn: 0, fail: 0, info: 0, changed: 0, drift: 0};
for (const row of rows) {
  summary[row.level.toLowerCase()] += 1;
  if (row.changed) summary.changed += 1;
  if (row.level !== 'PASS') summary.drift += 1;
}
process.stdout.write(JSON.stringify({
  mode: process.env.CHECK_MODE === '1' ? 'check' : 'install',
  windows: process.env.IS_WINDOWS === '1',
  mainCheckout: process.env.REPO_ROOT,
  skillsDir: process.env.SKILLS_DIR,
  checks: rows,
  summary,
}) + '\n');
NODE
else
  printf 'PASS %s / WARN %s / FAIL %s / 改动 %s 处\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_CHANGED"
fi

if [ $((N_WARN + N_FAIL)) -gt 0 ]; then exit 1; fi
exit 0
