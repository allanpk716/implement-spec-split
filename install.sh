#!/usr/bin/env bash
# 本机安装脚本（规格 #58），两段：
#   1. 技能软链（票 #63）：扫描 git 跟踪的、含 SKILL.md 的目录（根技能 + 子技能），
#      逐个确保 $ISS_SKILLS_DIR/<name> 是指向主 checkout 对应目录的软链；仓库里已
#      不存在的技能留下的悬空链删掉；同名真实目录不动、只警告。
#   2. 本机配置期望项（票 #64）：一张「仓库声明的期望配置项」清单（数据，见下），每项
#      标方向 tighten（收紧）或 loosen（放宽）。tighten 且本机不满足：先把 settings.json
#      备份到 <settings 所在目录>/backups/install-<时间戳>/，用 node 原地改，再校验改后
#      的文件是合法 JSON，不是就用备份还原、记 FAIL。loosen 一律不改，只列进「未执行的
#      放宽项」（人类可读输出的一节，--json 的独立数组）。hook 没注册的期望项不算漂移：
#      不处理、不报告（阶段 3 是用户可选采纳的）。doctor 接入（#65）、落地流程接入（#66）
#      不在这里。
#
# 主 checkout = 运行本脚本的那份 checkout（脚本所在目录的仓库根，按物理路径）。
# 经软链调用（bash ~/.claude/skills/implement-spec-split/install.sh）时也以脚本
# 真正所在的目录为准，不猜别的 checkout。「指向正确」按链解析到的物理目录判定，
# 不看链接文字：README 里经 ~/.claude/skills/implement-spec-split/<name> 写的链
# 解析到同一目录，同样算就位。
#
# 用法：./install.sh [--check] [--json] [--help]（-h 等同 --help；与未知参数时
#   打印的 usage 行同一个写法）
#   默认    安装：建缺的链、改指错的链、删悬空链、补不满足的 tighten 项，每处修改
#           打印一行；重复运行零修改
#   --check 只报告不改（两段都是：不写文件、不建备份）；退出码 0 = 全部就位，1 = 还有
#           未就位的
#   --json  只输出一个 JSON 对象，形状沿用 scripts/doctor.sh（checks 数组 + summary）
#
# 退出码：0 全部就位；1 仍有未就位的（另一份 clone 的真实目录、建链失败、Windows 的
#   手工步骤、--check 下不满足的 tighten 项、未执行的放宽项、settings.json 解析不了、
#   改后校验不过）；2 跑不起来，按脚本里的先后顺序：缺命令（node、git）、定位不到
#   脚本所在目录、不在 git checkout 里、HOME 未设（也没设 ISS_SKILLS_DIR /
#   ISS_CLAUDE_SETTINGS / CLAUDE_CONFIG_DIR）、期望项清单读不了或不是 JSON 数组、
#   建不出临时目录（mktemp -d）、建不出技能目录、仓库里没有跟踪的 SKILL.md；
#   64 用法错误。
#
# 环境变量：ISS_SKILLS_DIR  软链落点，默认 ~/.claude/skills；测试与冒烟指向临时目录，
#     设了它脚本只改它指向的位置。
#   ISS_CLAUDE_SETTINGS  settings.json 的位置，默认 ${CLAUDE_CONFIG_DIR:-~/.claude}/
#     settings.json（doctor.sh 读的同一个文件）；备份目录从它所在目录推导。测试与冒烟
#     指向临时文件，绝不拿真实的试。
#   ISS_CONFIG_EXPECTATIONS_FILE  换入一份期望项清单（JSON 数组），默认用下面内置的
#     那份；测试用它指夹具。
#   ISS_INSTALL_FAULT  仅 scripts/test-install.sh 用：corrupt-settings = 写完 settings.json
#     之后、校验之前把文件换成坏 JSON，走一遍「校验不过用备份还原」。
#
# 期望项清单（数据）：JSON 数组，每项
#   {"id": …, "direction": "tighten"|"loosen", "check": {…}, "fix": …}
#   check.type 目前只有 preToolUseMatcher：{"hook": "<脚本名>", "include": [工具…],
#   "exclude": [工具…]}。与 doctor.sh 同口径：取第一条 hooks.PreToolUse[] 里 command 含
#   <脚本名> 的注册，matcher 按 | 切开逐项字面比较，空 matcher 视为全覆盖；include 都在
#   且 exclude 都不在才算满足。
#   fix 是 tighten 项不满足时的修正方式，目前只有 append-matcher-tools：把缺的 include
#   工具按清单顺序追加到 matcher 末尾，已有的（如 NotebookEdit）原样保留。loosen 项
#   不看 fix，永远不修正。
#
# Windows（uname -s 为 MINGW* / MSYS*，沿用 doctor.sh 的平台判定）不建链不删链：
# Git Bash 里 mklink /J 要做路径转换、readlink 对 junction 又不可靠。每个未就位的
# 技能打印一行手工步骤（README 原话：mklink /J，或者直接复制）记 WARN；已在位的
# 目录联接或副本算就位（未核对指向）；--check 对缺链报 WARN 而不是 FAIL。第二段
# 只经 node 读写文件，各平台一样。
#
# --json 形状（#65 的 doctor 靠它读结果；键序固定，两次运行间稳定）：
#   {"mode":"install"|"check","windows":bool,"mainCheckout":"<物理路径>","skillsDir":"<原样>",
#    "claudeSettings":"<原样>",
#    "checks":[{"group":"skills"|"config","level":"PASS|WARN|FAIL","status":…,"changed":bool,
#               "name":…,"dir":…,"link":…,"target":…,"message":…,"hint":…}],
#    "unexecutedLoosenings":[…checks 里 status 为 loosen 的行…],
#    "summary":{"pass":n,"warn":n,"fail":n,"info":n,"changed":n,"drift":n}}
#   level 是这次运行之后的状态：安装模式下建好的链、补好的 tighten 项是 PASS，changed=true
#   的行是修改；status 取 ok | created | relinked | removed | missing | wrong | dangling |
#   real-dir | manual | present | tightened | unmet | loosen | error。group config 的行：
#   name 是期望项 id，link 是 settings.json，dir / target 为空；未执行的放宽项是 WARN
#   （机器与期望不一致，只是脚本不替人改）。退出码看 drift（level 不是 PASS 的行数），
#   不只看 FAIL——Windows 的 WARN、放宽项的 WARN 也是漂移。

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
  --check      Report only; change nothing (no link, no settings.json, no
               backup). Exit 1 when anything is not in place.
  --json       Output one JSON object only
  -h, --help   Show this help

For every directory git tracks with a SKILL.md (the root skill and the
sub-skills), makes ~/.claude/skills/<name> a symlink to that directory in the
checkout this script runs from, removes dangling links left by skills the
checkout no longer has, and never touches a real directory of the same name
(it warns instead). Re-running changes nothing once everything is in place.

Then the local configuration: every expectation the checkout declares (v1: the
delegate-guard PreToolUse matcher must cover Edit, Write and Bash; a hook that
is not registered is left alone) is checked against settings.json. A tighten
item not met is applied with node after the file is backed up to
backups/install-<timestamp>/ beside it, and the result is validated as JSON.
A loosen item is never applied: it is listed under unexecuted loosenings.

Environment:
  ISS_SKILLS_DIR               Where the links go (default ~/.claude/skills).
  ISS_CLAUDE_SETTINGS          settings.json to check (default
                               ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json).
  ISS_CONFIG_EXPECTATIONS_FILE A JSON file replacing the built-in expectation
                               list (tests use it).

On Windows (Git Bash) nothing is linked: each skill not in place prints the
manual step (mklink /J, or copy) as a WARN.

Exit codes: 0 all in place; 1 something is not in place; 2 could not run;
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

# settings.json: the file doctor.sh reads, unless ISS_CLAUDE_SETTINGS says otherwise.
[ -n "${ISS_CLAUDE_SETTINGS:-}" ] || [ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ -n "${HOME:-}" ] || { echo "HOME is not set; set ISS_CLAUDE_SETTINGS" >&2; exit 2; }
SETTINGS_JSON=${ISS_CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}
SETTINGS_BASE=$(basename -- "$SETTINGS_JSON")

# 期望项清单（数据）：仓库对本机配置的期望，每项 id、direction（tighten 收紧 / loosen
# 放宽）、check（怎么检查）、fix（tighten 不满足时怎么修正；loosen 不看它）。v1 唯一一项：
# delegate-guard 的 PreToolUse matcher 覆盖 Edit、Write、Bash——与 doctor.sh「覆盖 Edit 和
# Write」「覆盖 Bash」两项同口径。NotebookEdit 不要求（README 只把 Bash 写成必须），
# 已有则原样保留。测试用 ISS_CONFIG_EXPECTATIONS_FILE 换入夹具（v1 没有 loosen 项，
# 「loosen 从不修改」只能靠夹具验证）。读不了或不是 JSON 数组 = 跑不起来，退出 2。
DEFAULT_EXPECTATIONS='[
  {
    "id": "delegate-guard-matcher",
    "direction": "tighten",
    "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "include": ["Edit", "Write", "Bash"]},
    "fix": "append-matcher-tools"
  }
]'
if [ -n "${ISS_CONFIG_EXPECTATIONS_FILE:-}" ]; then
  EXPECTATIONS_SOURCE=$ISS_CONFIG_EXPECTATIONS_FILE
  EXPECTATIONS=$(cat "$EXPECTATIONS_SOURCE" 2>/dev/null) || { echo "cannot read the expectation list: ${EXPECTATIONS_SOURCE}" >&2; exit 2; }
else
  EXPECTATIONS_SOURCE='install.sh 内置的期望项清单'
  EXPECTATIONS=$DEFAULT_EXPECTATIONS
fi
EXPECTATIONS=$EXPECTATIONS node -e 'if (!Array.isArray(JSON.parse(process.env.EXPECTATIONS))) process.exit(1);' 2>/dev/null \
  || { echo "the expectation list is not a JSON array: ${EXPECTATIONS_SOURCE}" >&2; exit 2; }

UNAME_S=$(uname -s)
case "$UNAME_S" in
  MINGW*|MSYS*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

TMP_ROOT=$(mktemp -d) || { echo "cannot create a temporary directory" >&2; exit 2; }
ROWS=$TMP_ROOT/rows.tsv
EVAL=$TMP_ROOT/expect.tsv
LOOSEN=$TMP_ROOT/loosen.txt
ERR=$TMP_ROOT/err
cleanup() {
  rm -f "$ROWS" "$EVAL" "$LOOSEN" "$ERR"
  rmdir "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
: > "$ROWS"
: > "$LOOSEN"

N_PASS=0
N_WARN=0
N_FAIL=0
N_CHANGED=0
N_LOOSEN=0

# add_row <group> <LEVEL> <status> <changed 0|1> <name> <dir> <link> <target> <message> [hint]
# Records one result: a row for --json, a line for the terminal (one line per
# change, as the spec asks). A loosen row (an unexecuted loosening) is also
# collected for the 未执行的放宽项 section and array.
add_row() {
  local group=$1 level=$2 status=$3 changed=$4 name=$5 dir=$6 link=$7 target=$8 message=$9 hint=${10:-} suffix=
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$group" "$level" "$status" "$changed" "$name" "$dir" "$link" "$target" "$message" "$hint" >> "$ROWS"
  case "$level" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
  esac
  [ "$changed" -eq 1 ] && N_CHANGED=$((N_CHANGED + 1))
  if [ "$status" = loosen ]; then
    N_LOOSEN=$((N_LOOSEN + 1))
    printf '%s\n' "$message" >> "$LOOSEN"
  fi
  if [ "$JSON_MODE" -eq 0 ]; then
    [ -n "$hint" ] && suffix=" -> ${hint}"
    printf '[%s] %s%s\n' "$level" "$message" "$suffix"
  fi
}

# The skills segment's rows (group skills): add <LEVEL> <status> <changed 0|1>
# <name> <dir> <link> <target> <message> [hint].
add() {
  add_row skills "$@"
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

# ---- 第二段：本机配置期望项（票 #64） ----

# config_node <op> [item]: the JSON tool of the config segment. settings.json and
# the expectation list come in by environment (the way doctor.sh and
# publish-batch.sh hand values to node), the job by <op>:
#   evaluate  one \x1f-separated row per expectation item, in list order:
#             idx, verdict, id, direction, hook, before, after, missing, want,
#             kept, reason. verdict is ok | unmet | unregistered | unfixable |
#             bad, or parse (one row for the whole file: settings.json is not
#             JSON). An item is judged against the first PreToolUse entry whose
#             command names the hook -- the one doctor.sh judges; without such an
#             entry it is unregistered, which is not drift.
#   fix       tighten item <item>: append its missing tools to that entry's
#             matcher, keep the file's indentation, trailing newline and rwx
#             permission bits, and put the new text in place through a temporary
#             file beside it (rename is atomic on one filesystem). Exit 3 when
#             settings.json is not JSON, 4 when there is nothing to fix, 5 when
#             the write failed.
#   validate  exit 0 when settings.json parses, 1 when it does not.
config_node() {
  SETTINGS_JSON=$SETTINGS_JSON EXPECTATIONS=$EXPECTATIONS ISS_OP=$1 ISS_ITEM=${2:-} node <<'NODE'
const fs = require('fs');
const file = process.env.SETTINGS_JSON;
const sep = '\x1f';
const readText = () => fs.readFileSync(file, 'utf8');
// A blank matcher is every tool, as doctor.sh reads it.
const covers = (matcher, tool) => matcher === '' || matcher.split('|').includes(tool);

// The first PreToolUse entry whose hook command names <script> (doctor.sh's
// hooks_registered, first registration), with its matcher as a string.
function registration(root, script) {
  const entries = root?.hooks?.PreToolUse;
  if (!Array.isArray(entries)) return null;
  for (const entry of entries) {
    const hooks = Array.isArray(entry?.hooks) ? entry.hooks : [];
    for (const hook of hooks) {
      if (String(hook?.command || '').includes(script)) return {entry, matcher: String(entry?.matcher || '')};
    }
  }
  return null;
}

// What the registration lacks of the item's include list, and what it keeps of
// the exclude list.
function judge(check, reg) {
  return {
    missing: (check.include || []).filter(tool => !covers(reg.matcher, tool)),
    kept: (check.exclude || []).filter(tool => covers(reg.matcher, tool)),
  };
}

function evaluate() {
  const list = JSON.parse(process.env.EXPECTATIONS);
  // One row per item, one line each: a field may not hold a line break or the
  // separator (a parse error quotes the input, a matcher may hold anything).
  const clean = value => String(value).replace(/[\r\n\x1f]/g, ' ');
  const emit = row => console.log(row.map(clean).join(sep));
  let root;
  try {
    root = JSON.parse(readText());
  } catch (e) {
    emit(['0', 'parse', '', '', '', '', '', '', '', '', e.message]);
    return;
  }
  list.forEach((item, idx) => {
    // idx, verdict, id, direction, hook, before, after, missing, want, kept, reason
    const row = [String(idx), 'bad', '', '', '', '', '', '', '', '', ''];
    const bad = reason => { row[10] = reason; emit(row); };
    if (!item || typeof item !== 'object' || Array.isArray(item)) return bad('不是对象');
    row[2] = String(item.id ?? '');
    row[3] = String(item.direction ?? '');
    if (item.direction !== 'tighten' && item.direction !== 'loosen') return bad('direction 必须是 tighten 或 loosen');
    const check = item.check;
    if (!check || typeof check !== 'object' || check.type !== 'preToolUseMatcher') return bad('未知的检查方式');
    if (typeof check.hook !== 'string' || !check.hook) return bad('check.hook 必须是 hook 脚本名');
    const include = check.include === undefined ? [] : check.include;
    const exclude = check.exclude === undefined ? [] : check.exclude;
    if (!Array.isArray(include) || !Array.isArray(exclude) || ![...include, ...exclude].every(t => typeof t === 'string' && t)) {
      return bad('check.include / check.exclude 必须是工具名数组');
    }
    row[4] = check.hook;
    const reg = registration(root, check.hook);
    if (!reg) { row[1] = 'unregistered'; emit(row); return; }
    const {missing, kept} = judge(check, reg);
    row[5] = reg.matcher;
    row[8] = (item.direction === 'tighten' ? include : exclude).join('|');
    if (missing.length === 0 && kept.length === 0) {
      row[1] = 'ok';
    } else if (item.direction === 'loosen') {
      row[1] = 'unmet';
    } else if (kept.length > 0 || item.fix !== 'append-matcher-tools') {
      row[1] = 'unfixable';
      row[10] = kept.length > 0 ? '排除工具没有自动修正方法' : '未知的修正方式';
    } else {
      row[1] = 'unmet';
      row[6] = reg.matcher + '|' + missing.join('|');
    }
    row[7] = missing.join('|');
    row[9] = kept.join('|');
    emit(row);
  });
}

function fix() {
  const item = JSON.parse(process.env.EXPECTATIONS)[Number(process.env.ISS_ITEM)];
  let root, orig;
  try {
    orig = readText();
    root = JSON.parse(orig);
  } catch (e) {
    process.stderr.write(String(e.message));
    process.exit(3);
  }
  const reg = registration(root, item.check.hook);
  if (!reg) { process.stderr.write('the hook is no longer registered'); process.exit(4); }
  const {missing} = judge(item.check, reg);
  if (missing.length === 0) { process.stderr.write('the matcher already covers the tools'); process.exit(4); }
  reg.entry.matcher = reg.matcher + '|' + missing.join('|');
  // The indentation of the original: its first indented line, counted in spaces,
  // or a tab when that line starts with one; two spaces when there is none. The
  // trailing newline stays as it was.
  const lead = orig.match(/^[ \t]+(?=\S)/m);
  const indent = !lead ? 2 : lead[0].includes('\t') ? '\t' : lead[0].length;
  const text = JSON.stringify(root, null, indent) + (orig.endsWith('\n') ? '\n' : '');
  JSON.parse(text);                            // what gets written must parse
  const tmp = file + '.install-' + process.pid + '.tmp';
  try {
    fs.writeFileSync(tmp, text);
    // The new file takes the rwx bits of the one it replaces (0600 stays
    // 0600): the backup and the restore keep them (cp -p), so a rewrite must
    // not be the one path that widens the file. A fresh file would get the
    // default mode of the process umask instead.
    fs.chmodSync(tmp, fs.statSync(file).mode & 0o777);
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    process.stderr.write(String(e.message));
    process.exit(5);
  }
}

function validate() {
  try {
    JSON.parse(readText());
  } catch {
    process.exit(1);
  }
}

const op = process.env.ISS_OP;
if (op === 'evaluate') evaluate();
else if (op === 'fix') fix();
else if (op === 'validate') validate();
else process.exit(64);
NODE
}

# backup_settings: copy settings.json to <its directory>/backups/install-<time>/
# and echo that directory. Nothing (and a message in $ERR) when the copy could
# not be made and verified byte for byte -- nothing else may happen then.
backup_settings() {
  local base dir
  base=$(dirname -- "$SETTINGS_JSON")
  mkdir -p "$base/backups" 2>"$ERR" || return 1
  dir=$base/backups/install-$(date +%Y%m%d-%H%M%S)
  # A second backup within the same second: the process id tells them apart.
  mkdir "$dir" 2>/dev/null || { dir=$dir-$$; mkdir "$dir" 2>"$ERR" || return 1; }
  if ! cp -p "$SETTINGS_JSON" "$dir/$SETTINGS_BASE" 2>"$ERR"; then
    rmdir "$dir" 2>/dev/null
    return 1
  fi
  if ! cmp -s "$SETTINGS_JSON" "$dir/$SETTINGS_BASE"; then
    rm -f "$dir/$SETTINGS_BASE"
    rmdir "$dir" 2>/dev/null
    echo "the backup differs from ${SETTINGS_JSON}" > "$ERR"
    return 1
  fi
  printf '%s\n' "$dir"
}

# config_fix <idx> <id> <hook> <before> <after> <missing>: tighten one item in
# place. Back settings.json up first, apply, then validate the file as written;
# whatever goes wrong after the backup puts it back, and the row is FAIL.
config_fix() {
  local idx=$1 id=$2 hook=$3 before=$4 after=$5 missing=$6 name backup_dir what
  name=${hook%.*}
  if ! backup_dir=$(backup_settings); then
    add_row config FAIL error 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}，备份失败，未改：$(tr '\n' ' ' < "$ERR")" ""
    return
  fi
  if config_node fix "$idx" 2>"$ERR"; then
    # Test seam for scripts/test-install.sh: pretend the write produced broken JSON.
    [ "${ISS_INSTALL_FAULT:-}" = corrupt-settings ] && printf '{"broken":\n' > "$SETTINGS_JSON"
    if config_node validate 2>"$ERR"; then
      add_row config PASS tightened 1 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}，已补为 \"${after}\"" "原文件备份：${backup_dir}/${SETTINGS_BASE}"
      return
    fi
    what='改后的 settings.json 不是合法 JSON'
  else
    what="修改失败：$(tr '\n' ' ' < "$ERR")"
  fi
  if cp -p "$backup_dir/$SETTINGS_BASE" "$SETTINGS_JSON" 2>"$ERR" && cmp -s "$backup_dir/$SETTINGS_BASE" "$SETTINGS_JSON"; then
    add_row config FAIL error 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}，${what}，已用备份还原（${backup_dir}）" ""
  else
    add_row config FAIL error 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}，${what}，还原也失败：原文件在 ${backup_dir}/${SETTINGS_BASE}，请手工放回" ""
  fi
}

# config_segment: the expectation list against settings.json, after the skills.
# No settings.json means no hook is registered: nothing to expect. One FAIL row
# when it is not JSON (nothing is touched, in either mode). Items whose hook is
# not registered are neither handled nor reported. In --check an unmet tighten
# item is a FAIL row and nothing is written; otherwise it is fixed one at a
# time. An unexecuted loosening is a WARN row (drift the script will not fix).
config_segment() {
  local idx verdict id direction hook before after missing want kept reason name
  [ -f "$SETTINGS_JSON" ] || return 0
  if ! config_node evaluate > "$EVAL" 2>"$ERR"; then
    add_row config FAIL error 0 "" "" "$SETTINGS_JSON" "" "期望项检查失败：$(tr '\n' ' ' < "$ERR")" "检查 ${EXPECTATIONS_SOURCE}"
    return
  fi
  while IFS=$'\x1f' read -r idx verdict id direction hook before after missing want kept reason; do
    [ -n "$idx" ] || continue
    name=${hook%.*}
    case "$verdict" in
      parse)
        add_row config FAIL error 0 "" "" "$SETTINGS_JSON" "" "settings.json 不是合法 JSON，未改：${SETTINGS_JSON}（${reason}）" "修好后重新运行 ${REPO_ROOT}/install.sh" ;;
      unregistered) ;;   # 阶段 3 是可选采纳的：hook 没注册不算漂移，不处理也不报告
      bad)
        add_row config FAIL error 0 "$id" "" "$SETTINGS_JSON" "" "期望项 ${id:-?} 无法识别：${reason}" "检查 ${EXPECTATIONS_SOURCE}" ;;
      ok)
        if [ "$direction" = loosen ]; then
          add_row config PASS ok 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher 已不含 ${want}（放宽项已满足）" ""
        else
          add_row config PASS ok 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher 已覆盖 ${want}" ""
        fi ;;
      unmet)
        if [ "$direction" = loosen ]; then
          add_row config WARN loosen 0 "$id" "" "$SETTINGS_JSON" "" "放宽项未执行：${name} hook 的 PreToolUse matcher 含 ${kept}（仓库期望不含）" "安装脚本不改放宽项；需要的话手工改"
        elif [ "$CHECK_MODE" -eq 1 ]; then
          add_row config FAIL unmet 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}（期望覆盖 ${want}）" "运行 ${REPO_ROOT}/install.sh 补上（原文件先备份）"
        else
          config_fix "$idx" "$id" "$hook" "$before" "$after" "$missing"
        fi ;;
      unfixable)
        add_row config FAIL unmet 0 "$id" "" "$SETTINGS_JSON" "" "${name} hook 的 PreToolUse matcher \"${before}\" 缺 ${missing}，但没有自动修正方法（${reason}）" "手工把 ${missing} 加进 matcher" ;;
    esac
  done < "$EVAL"
}

if [ "$JSON_MODE" -eq 0 ]; then
  MODE_TEXT=安装
  [ "$CHECK_MODE" -eq 0 ] || MODE_TEXT='只检查（--check）'
  printf '主 checkout：%s（运行本脚本的 checkout）\n' "$REPO_ROOT"
  printf '技能目录：%s\n' "$SKILLS_DIR"
  printf '配置文件：%s\n' "$SETTINGS_JSON"
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

# 第二段：本机配置期望项。各平台一样，只在 settings.json 存在时做事。
config_segment

if [ "$JSON_MODE" -eq 1 ]; then
  ROWS=$ROWS CHECK_MODE=$CHECK_MODE IS_WINDOWS=$IS_WINDOWS REPO_ROOT=$REPO_ROOT SKILLS_DIR=$SKILLS_DIR SETTINGS_JSON=$SETTINGS_JSON node <<'NODE'
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
  claudeSettings: process.env.SETTINGS_JSON,
  checks: rows,
  unexecutedLoosenings: rows.filter(row => row.status === 'loosen'),
  summary,
}) + '\n');
NODE
else
  printf 'PASS %s / WARN %s / FAIL %s / 改动 %s 处\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_CHANGED"
  if [ "$N_LOOSEN" -gt 0 ]; then
    printf '\n未执行的放宽项（本脚本只报告，不改；需要的话手工做）：\n'
    sed 's/^/- /' "$LOOSEN"
  fi
fi

if [ $((N_WARN + N_FAIL)) -gt 0 ]; then exit 1; fi
exit 0
