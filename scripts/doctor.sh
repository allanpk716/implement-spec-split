#!/usr/bin/env bash
# Read-only environment doctor for implement-spec-split.

set -u

LANG_MODE=${DOCTOR_LANG:-zh}
JSON_MODE=0
WITH_GLM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lang)
      [ $# -ge 2 ] || { echo "usage: scripts/doctor.sh [--lang zh|en] [--json] [--with-glm] [--help]" >&2; exit 64; }
      case "$2" in zh|en) LANG_MODE=$2 ;; *) echo "--lang must be zh or en" >&2; exit 64 ;; esac
      shift 2
      ;;
    --json) JSON_MODE=1; shift ;;
    --with-glm) WITH_GLM=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/doctor.sh [options]

Options:
  --lang zh|en  Output language (default: zh, or DOCTOR_LANG=en)
  --json        Output one JSON object only
  --with-glm    Also run scripts/selftest-codex.sh --only L1
  -h, --help    Show this help

--with-glm makes a real model request and consumes a small number of tokens.
The doctor never modifies user configuration.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; echo "usage: scripts/doctor.sh [--lang zh|en] [--json] [--with-glm] [--help]" >&2; exit 64 ;;
  esac
done

for tool in node git mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required command not found: $tool" >&2; exit 1; }
done

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CODEX_DIR=${CODEX_HOME:-$HOME/.codex}
CONFIG_TOML=$CODEX_DIR/config.toml
SETTINGS_JSON=$CLAUDE_DIR/settings.json
GLOBAL_CLAUDE_MD=$CLAUDE_DIR/CLAUDE.md
EXPECTED_SKILL_DIR=$HOME/.claude/skills/implement-spec-split
TMP_ROOT=$(mktemp -d)
CHECKS=$TMP_ROOT/checks.jsonl
HOOKS_TSV=$TMP_ROOT/hooks.tsv
PREFLIGHT_TSV=$TMP_ROOT/preflight.tsv
SMOKE_OUT=$TMP_ROOT/smoke.out
GLM_OUT=$TMP_ROOT/glm.out
: > "$CHECKS"

cleanup() {
  for file in "$CHECKS" "$HOOKS_TSV" "$PREFLIGHT_TSV" "$SMOKE_OUT" "$GLM_OUT"; do
    [ -e "$file" ] && rm -f "$file"
  done
  rmdir "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

add() {
  CHECK_GROUP=$1 CHECK_LEVEL=$2 CHECK_ZH=$3 CHECK_EN=$4 HINT_ZH=${5:-} HINT_EN=${6:-} CHECK_FILE=$CHECKS \
    node -e '
      const fs = require("fs");
      const row = {
        group: process.env.CHECK_GROUP,
        level: process.env.CHECK_LEVEL,
        message: process.env.CHECK_ZH,
        messageEn: process.env.CHECK_EN,
        hint: process.env.HINT_ZH,
        hintEn: process.env.HINT_EN,
      };
      fs.appendFileSync(process.env.CHECK_FILE, JSON.stringify(row) + "\n");
    '
}

same_path() {
  local a=$1 b=$2
  if command -v cygpath >/dev/null 2>&1; then
    a=$(cygpath -m "$a" 2>/dev/null || printf '%s' "$a")
    b=$(cygpath -m "$b" 2>/dev/null || printf '%s' "$b")
  fi
  a=${a//\\//}
  b=${b//\\//}
  [ "${a,,}" = "${b,,}" ]
}

toml_custom_value() {
  CONFIG_TOML=$CONFIG_TOML TOML_KEY=$1 node - <<'NODE'
const fs = require('fs');
const lines = fs.readFileSync(process.env.CONFIG_TOML, 'utf8').split(/\r?\n/);
let inSection = false;
for (const line of lines) {
  if (/^\s*\[\s*model_providers\.custom\s*\]\s*$/.test(line)) { inSection = true; continue; }
  if (/^\s*\[/.test(line)) inSection = false;
  if (!inSection) continue;
  const match = line.match(new RegExp(`^\\s*${process.env.TOML_KEY}\\s*=\\s*(.*)$`));
  if (match) {
    console.log(match[1].trim().replace(/^['"]|['"]$/g, ''));
    process.exit(0);
  }
}
NODE
}

# 基础
if command -v node >/dev/null 2>&1; then
  add basic PASS "node 可用 ($(node --version))" "node is available ($(node --version))"
else
  add basic FAIL "node 不可用" "node is unavailable" "安装 Node.js" "Install Node.js"
fi
if command -v git >/dev/null 2>&1; then
  add basic PASS "git 可用 ($(git --version))" "git is available ($(git --version))"
else
  add basic FAIL "git 不可用" "git is unavailable" "安装 Git" "Install Git"
fi

UNAME_S=$(uname -s)
case "$UNAME_S" in
  MINGW*|MSYS*) add basic PASS "Git Bash" "Git Bash" ;;
  *) add basic WARN "未验证的平台，进程管理路径可能有问题" "Unverified platform; process-management paths may not work" "优先使用 Windows + Git Bash" "Prefer Windows with Git Bash" ;;
esac

if same_path "$SKILL_DIR" "$EXPECTED_SKILL_DIR"; then
  add basic PASS "技能目录在期望位置" "The skill directory is in the expected location"
else
  add basic WARN "技能目录不在 $EXPECTED_SKILL_DIR" "The skill directory is not at $EXPECTED_SKILL_DIR" "全局规则和 hook 按 ~/.claude/skills/implement-spec-split 引用，位置不同需要改路径" "Global rules and hooks reference ~/.claude/skills/implement-spec-split; adjust paths if this location differs"
fi

# 阶段 1
PLUGIN_FILE=$CLAUDE_DIR/plugins/installed_plugins.json
if PLUGIN_FILE=$PLUGIN_FILE node -e 'const f=process.env.PLUGIN_FILE;try{const p=JSON.parse(require("fs").readFileSync(f,"utf8")).plugins;process.exit(Object.keys(p||{}).some(k=>k.startsWith("mattpocock-skills@"))?0:1)}catch{process.exit(1)}'; then
  add stage1 PASS "mattpocock-skills 插件已安装" "The mattpocock-skills plugin is installed"
else
  add stage1 WARN "未找到 mattpocock-skills 插件" "The mattpocock-skills plugin was not found" "只影响 /implement-spec-split；在 Claude Code 运行 /plugin marketplace add mattpocock/skills 和 /plugin install mattpocock-skills@mattpocock" "Only affects /implement-spec-split; run /plugin marketplace add mattpocock/skills and /plugin install mattpocock-skills@mattpocock in Claude Code"
fi

# 阶段 3 配置状态先判定，用于决定阶段 2 缺失是 WARN 还是 FAIL。
HOOK_REGISTERED=0
RULE_INSTALLED=0
if [ -f "$SETTINGS_JSON" ]; then
  SETTINGS_JSON=$SETTINGS_JSON OUT_FILE=$HOOKS_TSV node - > "$HOOKS_TSV" <<'NODE'
const fs = require('fs');
let root;
try { root = JSON.parse(fs.readFileSync(process.env.SETTINGS_JSON, 'utf8')); } catch { process.exit(0); }
const entries = root?.hooks?.PreToolUse;
if (!Array.isArray(entries)) process.exit(0);
for (const entry of entries) {
  const hooks = Array.isArray(entry?.hooks) ? entry.hooks : [];
  for (const hook of hooks) {
    if (String(hook?.command || '').includes('delegate-guard.js')) {
      console.log([String(entry.matcher || ''), String(hook.command || '')].join('\t'));
    }
  }
}
NODE
  [ -s "$HOOKS_TSV" ] && HOOK_REGISTERED=1
fi
TEMPLATE_VERSION=$(sed -n 's/.*opus-codex-division: v\([0-9][0-9]*\).*/\1/p' "$SKILL_DIR/templates/global-claude-md.md" | tail -n 1)
if [ -f "$GLOBAL_CLAUDE_MD" ]; then
  INSTALLED_VERSION=$(sed -n 's/.*opus-codex-division: v\([0-9][0-9]*\).*/\1/p' "$GLOBAL_CLAUDE_MD" | tail -n 1)
  [ -n "$INSTALLED_VERSION" ] && RULE_INSTALLED=1
fi
if [ "$HOOK_REGISTERED" -eq 1 ] || [ "$RULE_INSTALLED" -eq 1 ]; then STAGE3_CONFIGURED=1; else STAGE3_CONFIGURED=0; fi

# 阶段 2
CODEX_BIN=$(command -v codex 2>/dev/null || true)
CODEX_VERSION=""
if [ -n "$CODEX_BIN" ]; then
  CODEX_VERSION=$(codex --version 2>/dev/null | head -n 1 | grep -o '[0-9][0-9.]*' | head -n 1 || true)
  if [ -n "$CODEX_VERSION" ]; then
    if [[ $CODEX_VERSION == 0.163.* ]]; then
      add stage2 PASS "codex 可用 ($CODEX_VERSION)" "codex is available ($CODEX_VERSION)"
    else
      add stage2 WARN "codex 版本为 $CODEX_VERSION，未经验证" "codex version is $CODEX_VERSION and is unverified" "先跑 scripts/selftest-codex.sh --only V1" "First run scripts/selftest-codex.sh --only V1"
    fi
  elif [ "$STAGE3_CONFIGURED" -eq 1 ]; then
    add stage2 FAIL "codex --version 无法运行" "codex --version could not run" "重装 npm i -g @openai/codex" "Reinstall with npm i -g @openai/codex"
  else
    add stage2 WARN "codex --version 无法运行" "codex --version could not run" "阶段 2/3 不可用；安装 npm i -g @openai/codex" "Stages 2/3 are unavailable; install with npm i -g @openai/codex"
  fi
elif [ "$STAGE3_CONFIGURED" -eq 1 ]; then
  add stage2 FAIL "codex 未安装" "codex is not installed" "阶段 3 已配置但后端缺失；安装 npm i -g @openai/codex" "Stage 3 is configured but its backend is missing; install with npm i -g @openai/codex"
else
  add stage2 WARN "codex 未安装" "codex is not installed" "阶段 2/3 不可用；安装 npm i -g @openai/codex" "Stages 2/3 are unavailable; install with npm i -g @openai/codex"
fi

BASE_URL=""
CONFIG_PROBLEM=""
if [ ! -f "$CONFIG_TOML" ]; then
  CONFIG_PROBLEM="config.toml 不存在"
elif ! grep -q '^\[model_providers\.custom\]' "$CONFIG_TOML"; then
  CONFIG_PROBLEM="config.toml 缺少 [model_providers.custom]"
else
  BASE_URL=$(toml_custom_value base_url)
  [ -n "$BASE_URL" ] || CONFIG_PROBLEM="config.toml 缺少 base_url"
fi
if [ -n "$CONFIG_PROBLEM" ]; then
  CONFIG_PROBLEM_EN=$(case "$CONFIG_PROBLEM" in
    *"不存在"*) printf '%s' "config.toml does not exist" ;;
    *"缺少 [model_providers.custom]"*) printf '%s' "config.toml is missing [model_providers.custom]" ;;
    *) printf '%s' "config.toml is missing base_url" ;;
  esac)
  if [ "$STAGE3_CONFIGURED" -eq 1 ]; then
    add stage2 FAIL "$CONFIG_PROBLEM" "$CONFIG_PROBLEM_EN" "按 docs/setup.md 阶段 2 配置 custom provider" "Configure the custom provider as described in docs/setup.md stage 2"
  else
    add stage2 WARN "$CONFIG_PROBLEM" "$CONFIG_PROBLEM_EN" "阶段 2/3 不可用；按 docs/setup.md 阶段 2 配置" "Stages 2/3 are unavailable; follow docs/setup.md stage 2"
  fi
else
  add stage2 PASS "custom provider base_url 已配置" "The custom provider base_url is configured"
  WIRE_API=$(toml_custom_value wire_api)
  if [ -n "$WIRE_API" ] && [ "$WIRE_API" != "responses" ]; then
    add stage2 WARN "wire_api 是 \"$WIRE_API\"，不是 responses" "wire_api is \"$WIRE_API\", not responses" "改为 wire_api = \"responses\"" "Change it to wire_api = \"responses\""
  fi
fi

PREFLIGHT_HOST=""
PREFLIGHT_PORT=""
PREFLIGHT_STATE=skip
if [ "${CODEX_WORKER_PREFLIGHT:-}" = "off" ] || [ "${CODEX_WORKER_SKIP_PREFLIGHT:-}" = "1" ]; then
  PREFLIGHT_STATE=disabled
elif [ -n "${CODEX_WORKER_PREFLIGHT:-}" ]; then
  PREFLIGHT_HOST=${CODEX_WORKER_PREFLIGHT%:*}
  PREFLIGHT_PORT=${CODEX_WORKER_PREFLIGHT##*:}
  PREFLIGHT_STATE=address
elif [ -n "$BASE_URL" ]; then
  PREFLIGHT_URL=$BASE_URL PREFLIGHT_TSV=$PREFLIGHT_TSV node - > "$PREFLIGHT_TSV" <<'NODE'
let url;
try { url = new URL(process.env.PREFLIGHT_URL); } catch { process.exit(0); }
const host = url.hostname.replace(/^\[|\]$/g, '');
const port = url.port ? Number(url.port) : (url.protocol === 'https:' ? 443 : 80);
console.log([host, port, url.protocol.replace(':', '')].join('\t'));
NODE
  if IFS=$'\t' read -r PREFLIGHT_HOST PREFLIGHT_PORT _ < "$PREFLIGHT_TSV"; then
    PREFLIGHT_STATE=address
  else
    PREFLIGHT_STATE=invalid
  fi
fi

case "$PREFLIGHT_STATE" in
  disabled)
    add stage2 INFO "预检已通过环境变量关闭" "Preflight is disabled by an environment variable"
    ;;
  invalid)
    add stage2 WARN "无法解析预检地址" "Could not resolve the preflight address" "检查 CODEX_WORKER_PREFLIGHT 或 config.toml 的 base_url" "Check CODEX_WORKER_PREFLIGHT or base_url in config.toml"
    ;;
  address)
    case "$PREFLIGHT_HOST" in
      localhost|::1|127.*)
        if PREFLIGHT_HOST=$PREFLIGHT_HOST PREFLIGHT_PORT=$PREFLIGHT_PORT node - <<'NODE'
const net = require('net');
const socket = net.createConnection({host: process.env.PREFLIGHT_HOST, port: Number(process.env.PREFLIGHT_PORT)});
const stop = code => { socket.destroy(); process.exit(code); };
socket.once('connect', () => stop(0));
socket.once('error', () => stop(1));
setTimeout(() => stop(1), 3000);
NODE
        then
          add stage2 PASS "本地代理 $PREFLIGHT_HOST:$PREFLIGHT_PORT 可达" "Local proxy $PREFLIGHT_HOST:$PREFLIGHT_PORT is reachable"
        else
          add stage2 FAIL "本地代理 $PREFLIGHT_HOST:$PREFLIGHT_PORT 没开" "Local proxy $PREFLIGHT_HOST:$PREFLIGHT_PORT is not running" "启动本地代理，或修正 base_url 端口" "Start the local proxy or correct the base_url port"
        fi
        ;;
      *)
        add stage2 INFO "预检地址 $PREFLIGHT_HOST:$PREFLIGHT_PORT 是远程地址，跳过 TCP 探测" "Preflight address $PREFLIGHT_HOST:$PREFLIGHT_PORT is remote; TCP probing is skipped"
        ;;
    esac
    ;;
esac

# 阶段 3
if [ "$STAGE3_CONFIGURED" -eq 0 ]; then
  add stage3 INFO "阶段 3 未配置" "Stage 3 is not configured"
else
  if [ "$HOOK_REGISTERED" -eq 0 ]; then
    add stage3 FAIL "阶段 3 只配置了一半：缺少 delegate-guard hook" "Stage 3 is half-configured: the delegate-guard hook is missing" "按 docs/setup.md 阶段 3 注册 hook" "Register the hook as described in docs/setup.md stage 3"
  elif [ "$RULE_INSTALLED" -eq 0 ]; then
    add stage3 FAIL "阶段 3 只配置了一半：缺少全局 CLAUDE.md 分工标记" "Stage 3 is half-configured: the global CLAUDE.md division marker is missing" "按 docs/setup.md 阶段 3 同步模板" "Sync the template as described in docs/setup.md stage 3"
  fi

  if [ "$HOOK_REGISTERED" -eq 1 ]; then
    HOOK_MATCHER=""
    HOOK_COMMAND=""
    HOOK_PATH=""
    while IFS=$'\t' read -r matcher command; do
      HOOK_MATCHER=$matcher
      HOOK_COMMAND=$command
      HOOK_PATH=$(HOOK_COMMAND=$command node -e '
        const command = process.env.HOOK_COMMAND;
        const match = command.match(/(?:^|[|;&\s])(?:node(?:\.exe)?)\s+(?:"([^"]+)"|\x27([^\x27]+)\x27|(\S+))/i);
        const path = match ? (match[1] || match[2] || match[3] || "") : "";
        console.log(path.includes("delegate-guard.js") ? path : "");
      ')
      break
    done < "$HOOKS_TSV"

    matcher_covers() {
      local matcher=$1 tool=$2 item
      IFS='|' read -ra items <<< "$matcher"
      for item in "${items[@]}"; do
        [[ $item == "$tool" ]] && return 0
      done
      return 1
    }
    if matcher_covers "$HOOK_MATCHER" Edit && matcher_covers "$HOOK_MATCHER" Write; then
      add stage3 PASS "hook matcher 覆盖 Edit 和 Write" "The hook matcher covers Edit and Write"
    else
      add stage3 FAIL "hook matcher \"$HOOK_MATCHER\" 未同时覆盖 Edit 和 Write" "The hook matcher \"$HOOK_MATCHER\" does not cover both Edit and Write" "参考 docs/setup.md 使用 Edit|Write|NotebookEdit" "Use Edit|Write|NotebookEdit as shown in docs/setup.md"
    fi

    if [ -z "$HOOK_PATH" ]; then
      add stage3 FAIL "无法从 hook command 解析 delegate-guard.js 路径" "Could not parse the delegate-guard.js path from the hook command" "使用 node <绝对路径>/delegate-guard.js" "Use node <absolute-path>/delegate-guard.js"
    elif [ ! -f "$HOOK_PATH" ]; then
      add stage3 FAIL "delegate-guard.js 不存在：$HOOK_PATH" "delegate-guard.js does not exist: $HOOK_PATH" "hook 会静默失效；修正 settings.json 里的路径" "The hook fails silently; fix the path in settings.json"
    else
      add stage3 PASS "delegate-guard.js 存在" "delegate-guard.js exists"
      EXPECTED_HOOK=$SKILL_DIR/hooks/delegate-guard.js
      if same_path "$HOOK_PATH" "$EXPECTED_HOOK"; then
        add stage3 PASS "hook 指向本技能的 delegate-guard.js" "The hook points to this skill's delegate-guard.js"
      else
        add stage3 WARN "hook 指向另一个 delegate-guard.js：$HOOK_PATH" "The hook points to a different delegate-guard.js: $HOOK_PATH" "确认这是刻意保留的副本，否则改指本技能目录" "Confirm this copy is intentional; otherwise point it at this skill directory"
      fi
      SMOKE_HOME=$TMP_ROOT/guard-home
      mkdir -p "$SMOKE_HOME"
      DELEGATE_GUARD_HOME=$SMOKE_HOME node "$HOOK_PATH" <<'JSON' >> "$SMOKE_OUT" 2>&1 || true
{"tool_name":"Write","tool_input":{"file_path":"doctor-smoke.py","content":"line\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\n"}}
JSON
      if grep -q '"permissionDecision":"deny"' "$SMOKE_OUT"; then
        add stage3 PASS "delegate-guard 冒烟测试拒绝 15 行 Write" "The delegate-guard smoke test denies a 15-line Write"
      else
        add stage3 FAIL "delegate-guard 冒烟测试未拒绝 15 行 Write" "The delegate-guard smoke test did not deny a 15-line Write" "hook 会静默失效；运行 hooks/test-delegate-guard.js 并检查配置" "The hook fails silently; run hooks/test-delegate-guard.js and inspect the configuration"
      fi
      rmdir "$SMOKE_HOME" 2>/dev/null || true
    fi
  fi

  if [ "$RULE_INSTALLED" -eq 1 ]; then
    if [ "$INSTALLED_VERSION" = "$TEMPLATE_VERSION" ]; then
      add stage3 PASS "全局分工规则版本为 v$INSTALLED_VERSION" "The global division rules are version v$INSTALLED_VERSION"
    else
      add stage3 WARN "全局分工规则是 v${INSTALLED_VERSION:-缺失}，模板是 v${TEMPLATE_VERSION:-缺失}" "Global division rules are v${INSTALLED_VERSION:-missing}; the template is v${TEMPLATE_VERSION:-missing}" "模板已更新，请按 docs/setup.md 第 3 阶段同步" "The template changed; sync it as described in docs/setup.md stage 3"
    fi
  fi

  OVERRIDE_FILE=$CLAUDE_DIR/state/allow-direct-edit
  if [ -f "$OVERRIDE_FILE" ]; then
    OVERRIDE_RESULT=$(OVERRIDE_FILE=$OVERRIDE_FILE node -e '
      const fs=require("fs"); const raw=fs.readFileSync(process.env.OVERRIDE_FILE,"utf8").trim();
      const at=/^\d+$/.test(raw)?Number(raw)*1000:Date.parse(raw);
      if(Number.isFinite(at)&&at>Date.now()) console.log("valid\t"+new Date(at).toISOString()); else console.log("expired\t");
    ')
    if [[ $OVERRIDE_RESULT == valid* ]]; then
      EXPIRES=${OVERRIDE_RESULT#valid$'\t'}
      add stage3 WARN "hook 当前被例外开关绕过，到 $EXPIRES 失效" "The hook is currently bypassed by the override until $EXPIRES" "如需恢复拦截，删除 $OVERRIDE_FILE" "Delete $OVERRIDE_FILE to restore enforcement"
    else
      add stage3 PASS "例外开关不存在或已过期" "The override is absent or expired"
    fi
  else
    add stage3 PASS "例外开关不存在" "The override is absent"
  fi

  GUARD_LOG=$CLAUDE_DIR/state/delegate-guard.log
  if [ -f "$GUARD_LOG" ]; then
    LAST_ERROR=$(GUARD_LOG=$GUARD_LOG node -e '
      const fs=require("fs"); const cutoff=Date.now()-7*86400000;
      let last=""; for(const line of fs.readFileSync(process.env.GUARD_LOG,"utf8").split(/\r?\n/)){
        if(!line.includes(" error ")) continue; const match=line.match(/^(\S+)/); const at=match?Date.parse(match[1]):NaN; if(Number.isFinite(at)&&at>=cutoff) last=line;
      } console.log(last);
    ')
    if [ -n "$LAST_ERROR" ]; then
      add stage3 WARN "delegate-guard.log 最近 7 天有 error：$LAST_ERROR" "delegate-guard.log has an error in the last 7 days: $LAST_ERROR" "运行 hooks/test-delegate-guard.js 并检查 hook 路径" "Run hooks/test-delegate-guard.js and check the hook path"
    else
      add stage3 PASS "delegate-guard.log 最近 7 天没有 error" "delegate-guard.log has no errors in the last 7 days"
    fi
  fi
fi

if [ "$WITH_GLM" -eq 1 ]; then
  if bash "$SKILL_DIR/scripts/selftest-codex.sh" --only L1 > "$GLM_OUT" 2>&1; then
    add stage2 PASS "GLM 连通性测试通过" "The GLM connectivity test passed"
  else
    add stage2 FAIL "GLM 连通性测试失败" "The GLM connectivity test failed" "查看上方 selftest 输出和本地代理状态" "Check the selftest output above and the local proxy"
  fi
  cat "$GLM_OUT"
fi

CHECK_FILE=$CHECKS LANG_MODE=$LANG_MODE JSON_MODE=$JSON_MODE node <<'NODE'
const fs = require('fs');
const rows = fs.readFileSync(process.env.CHECK_FILE, 'utf8').trim().split('\n')
  .filter(Boolean).map(line => JSON.parse(line));
const summary = {pass: 0, warn: 0, fail: 0, info: 0};
for (const row of rows) summary[row.level.toLowerCase()] += 1;
if (process.env.JSON_MODE === '1') {
  process.stdout.write(JSON.stringify({
    checks: rows.map(({group, level, message, messageEn, hint, hintEn}) => ({
      group,
      level,
      message: process.env.LANG_MODE === 'en' ? messageEn : message,
      hint: process.env.LANG_MODE === 'en' ? (hintEn || '') : (hint || ''),
    })),
    summary,
  }) + '\n');
} else {
  const labels = {zh: ['基础', '阶段 1', '阶段 2', '阶段 3'], en: ['Basic', 'Stage 1', 'Stage 2', 'Stage 3']};
  const language = process.env.LANG_MODE;
  const keys = ['basic', 'stage1', 'stage2', 'stage3'];
  for (const key of keys) {
    const group = rows.filter(row => row.group === key);
    if (!group.length) continue;
    console.log(`## ${labels[language][keys.indexOf(key)]}`);
    for (const row of group) {
      const message = language === 'en' ? row.messageEn : row.message;
      const hint = language === 'en' ? (row.hintEn || '') : (row.hint || '');
      console.log(`[${row.level.toUpperCase()}] ${message}${hint ? ` -> ${hint}` : ''}`);
    }
  }
  console.log(`PASS ${summary.pass} / WARN ${summary.warn} / FAIL ${summary.fail}`);
}
NODE

if grep -q '"level":"FAIL"' "$CHECKS"; then exit 1; fi
exit 0
