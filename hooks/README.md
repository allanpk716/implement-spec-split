# delegate-guard hook

`delegate-guard.js` 是 Claude Code 的 `PreToolUse` hook，用于拦截超过阈值（默认 10 行）的源码修改，让这类工作改由外部 codex worker 处理。文档和配置类文件、阈值以内的小改动会放行；输入异常时也按放行处理，避免 hook 卡住会话。`FLASH_ORCHESTRATOR=1` 时启用 flash 模式，源码修改阈值为 0。

## 注册

完整的安装步骤（含全局分工规则）见 [docs/setup.md](../docs/setup.md) 第 3 阶段。把 `<you>` 换成你的用户名；macOS / Linux 换成脚本的绝对路径。在 `~/.claude/settings.json` 中加入：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/delegate-guard.js",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

若 `settings.json` 已有 `hooks.PreToolUse`，把上面的 matcher 配置合并到现有数组中即可。

matcher 必须包含 `Bash`，flash 模式才能识别 `sed -i`、heredoc、`>` / `>>` 重定向和 `tee` 这类源码写入。未设置 `FLASH_ORCHESTRATOR` 时，hook 收到 Bash 输入会直接放行，普通会话行为不变。`scripts/doctor.sh` 会检测这一项：matcher 缺 `Bash` 时在阶段 3 报 FAIL 并给出修正提示；它只检测，不改 `settings.json`。

## 裸调 codex exec 拦截

对所有会话生效：不论是否 `FLASH_ORCHESTRATOR`、是否子代理，也不受 `allow-direct-edit` 例外和 `DELEGATE_GUARD_DISABLE` 影响，hook 都会拒绝在 Bash 里直接调用 `codex exec`。判定方式是先复用现有的 shell 分词（去掉 heredoc 正文），再看某个命令位置（命令开头，或 `|` `;` `&&` `||` `&` `(` 之后，跳过 `env`、`VAR=val` 前缀、`nohup`、`timeout <n>`、`time`）的可执行名 basename 是否为 `codex`，且其后的第一个非选项参数是否为 `exec`（例如 `codex exec …`、`codex -C dir exec …`；只认 `exec`，不认 `codex e`）。

不拦 `codex --version`、`codex login status`、`codex-worker.sh`、`pi-worker.sh`、`selftest-codex.sh`，也不把字符串或 heredoc 正文里出现的 `codex` 字样当成命令。拒绝理由是裸 `codex exec` 没有卡死检测（2026-11-22 曾挂 10 小时）：headless 的 codex worker 一律通过 `~/.claude/skills/implement-spec-split/scripts/codex-worker.sh` 启动；票的实现由 `scripts/stage-dispatch.sh` 派发的 Orca worker 在自己的工作区里写（见下文「精简启动的 worker」），规格会话自己不写代码。hook 内部异常仍 fail open。

## 配置

阈值优先级为项目配置、环境变量、默认值：

1. 从 hook payload 的 `cwd` 开始逐级向上查找 `.claude/delegate-guard.json`，最多 20 级，找到第一个就停止。文件可配置：
   - `{"enabled": false}`：该项目完全不拦截；
   - `{"limit": 30}`：项目阈值为 30，必须是正整数；
   - 两个字段可同时使用。文件无法解析或字段非法时忽略该文件并继续按后续规则判定。
2. 环境变量 `DELEGATE_GUARD_LIMIT`：正整数，默认 10；非法值按未设置处理。
3. 默认值 10。

## flash 模式

设置 `FLASH_ORCHESTRATOR=1` 表示当前会话是 flash Orchestrator。此时源码文件（按常见源码扩展名判定；无扩展名和文档、配置、日志等非源码扩展名放行）的 `Edit`、`Write`、`NotebookEdit` 一律拦截，行数阈值等效为 0；常见的 Bash 源码写入也会拦截，包括 `sed -i`、`perl -i`、heredoc 加重定向、`>` / `>>` 重定向和 `tee`。子代理的 hook payload 带非空 `agent_id` 时放行其源码写入。Bash 只拦截目标是源码文件的写入；fd 重定向（如 `2>&1`）和 heredoc 正文里的 `>` 不当成写入目标。拒绝提示为「flash 会话不写源码：派 glm-5.4 子代理（或 codex worker）」。

flash 模式优先于 `DELEGATE_GUARD_DISABLE=1`、项目配置和 `allow-direct-edit` 例外开关；两者同时设置时仍会拦截源码。文档、配置、记忆等非源码文件照常放行。没有 `FLASH_ORCHESTRATOR=1` 时，阈值、例外开关和 Bash 放行行为都与原模式一致。

`DELEGATE_GUARD_HOME` 可指定例外开关和日志使用的 home 目录；未设置时使用 `os.homedir()`。

拒绝提示默认为中文。设置 `DELEGATE_GUARD_LANG=en` 时使用英文提示；其他值按中文处理。

环境变量可以写进 `~/.claude/settings.json` 的 `env` 字段，对所有会话生效，例如：

```json
{
  "env": {
    "DELEGATE_GUARD_LIMIT": "20",
    "DELEGATE_GUARD_LANG": "en"
  }
}
```

例外开关仍然优先于项目配置。hook 内部异常或项目配置非法时仍会放行，并向 `<home>/.claude/state/delegate-guard.log` 追加一行日志；`<home>` 来自 `DELEGATE_GUARD_HOME` 或系统 home。日志超过 1MB 时会先清空再写入，写日志失败不影响 hook 结果。

## 例外开关

如需临时允许主模型直接修改源码，可在 `<home>/.claude/state/allow-direct-edit` 写入未来的 ISO 8601 时间或 epoch 秒，例如 `2026-01-01T00:00:00Z`。时间过期或内容无法解析时例外无效。

flash 模式不使用这个例外开关：flash 会话一行源码都不写（见 [ADR 0001](../docs/adr/0001-cheap-orchestrator-default-deny.md)）。

## 精简启动的 worker（规格 #26）

implement-spec-split 派发实现类 worker（票的实现、fix）时默认精简启动（GLOSSARY.md「Lean start (精简启动)」）：`scripts/stage-dispatch.sh` 用「实现」路由的启动器加 `--bare --append-system-prompt-file <精简规则文件> [--mcp-config …]` 开一个终端，再用 `worker-start --terminal` 收编。`--bare` 不加载 CLAUDE.md、技能、插件和 **hooks**——包括本目录的 delegate-guard（flash 模式的源码拦截）、land-push-guard、unattended-ask-guard、unattended-stop-guard。所以：

- 对精简启动的 worker，这些 hook 的硬拦不存在。原来靠 hook 挡住的事（flash 会话不写源码、没持落地锁不许 push、无人值守不问人、收尾前必须 close-self）降为**提示词**：写在 Brief（`find-next/templates/brief-implement.md` 的「要求」）和精简规则文件（`templates/lean-rules.md`，人工票 #39 落地）里。
- 兜底不在 hook，在**合入前的脚本门和审查**：`scripts/merge-ticket.sh` 合入前检查票分支有新提交、票工作区和集成工作区都干净，合入后跑测试命令，任何一项不满足就不合（退出 2 / 4）；第 7 步审查照旧。worker 也没有 push 的机会：合入、落地都由规格会话做，Brief 明确写「不合并、不 push」。
- merge 角色（解冲突）永远不精简启动——它在集成分支上干活，需要 CLAUDE.md 和 hooks 都在——所以 land-push-guard 等对它照常生效。
- 没有精简规则文件时派发模块退回普通启动，hooks 照常加载；`ISS_DISPATCH_BARE=0` 也可关掉精简启动。每次派发是哪种启动记在 sidecar 的 `bare` / `bare_note`。
- 规格会话本身不是精简启动的，上面几个 hook 对它照常生效：它一行源码不写（flash 模式）、push 前必须持落地锁、无人值守时不问人。

`--bare` 在 TUI + 收编形态下是否可用、第二个 `--append-system-prompt-file` 是叠加还是覆盖、`--bare` 配非空 `--mcp-config`，是 #39 的验证项；结论出来前，本节按「精简 worker 身上这些 hook 不存在」理解。

## ask-sanitize hook

`ask-sanitize.js` 是 Claude Code 的 `PreToolUse` hook，用于删除 `AskUserQuestion` 输入字符串里的回车符（U+000D）：flash 会话的 glm-5.3-flash 可能在 question/header/label/description 中夹入回车，导致终端把问题框渲染成乱码。hook 只对 `AskUserQuestion` 生效，会递归清洗 `tool_input` 中的字符串，并通过 `permissionDecision: "ask"` 和 `updatedInput` 用清洗后的输入照常弹出提问框；其他工具或异常输入一律无输出放行。

把它放进 flash 会话专用的 settings（作者环境为 `~/ops/etc/claude-flash/settings.json`）：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "node <skills>/implement-spec-split/hooks/ask-sanitize.js",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

测试命令：

```text
node hooks/test-ask-sanitize.js
```

## unattended-ask-guard hook

`unattended-ask-guard.js` 是 Claude Code 的 `PreToolUse` hook，用于在无人值守的 `/implement-spec-split --auto-land` 会话（含其子代理）里拒绝 `AskUserQuestion`：没人会来回答，提问只会把会话卡到第二天有人来答。提示词已经要求不问人，这个 hook 是不依赖模型理解提示词的硬兜底。

判定方式：hook 读取 payload 里的 `transcript_path`（JSONL，每行一个 JSON），按块流式读取，只对包含 `/implement-spec-split</command-name>` 的行做 JSON 解析，取**最后一次** `/implement-spec-split` 调用的 `<command-args>`，按空白切分；其中恰好有 `--auto-land` 这个词就拒绝，`--auto-landing` 之类不算。以最后一次调用为准：先带后不带放行，先不带后带拒绝。子代理 payload 的 `transcript_path` 可能指向主会话 transcript，规则相同，不特判 `agent_id`。hook 只处理 `tool_name === "AskUserQuestion"`，其他工具直接无输出退出；`transcript_path` 缺失、不可读、某行 JSON 解析失败或 hook 内部异常都 fail open（不输出、退出 0）。

逃生口：环境变量 `UNATTENDED_ASK_GUARD_DISABLE=1` 时直接放行。

注册：在 `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组里**追加**一项（不要覆盖已有的 hook）。它和 delegate-guard、ask-sanitize 各自注册、互不替代；两个 hook 都命中 `AskUserQuestion` 时 deny 覆盖 ask。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "node ~/.claude/skills/implement-spec-split/hooks/unattended-ask-guard.js",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

macOS / Linux 用上面的绝对路径；Windows 把路径换成 `node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-ask-guard.js`。claude-flash 和 openclaude 是用 `--settings` 叠加启动的，用户级 `~/.claude/settings.json` 照样生效，不需要在各自的 settings 里重复注册。

测试命令：

```text
node hooks/test-unattended-ask-guard.js
```

## unattended-stop-guard hook

`unattended-stop-guard.js` 是 Claude Code 的 `Stop` hook，是无人值守 `/implement-spec-split --auto-land` 会话的最后一道兜底：会话要结束时，它检查这个 Run 是不是真的收尾了。起因是 2026-11-20 至 11-25 的排查：19 个无人值守 Run 里调用过 `close-self.sh` 的是 0 个，其中 10 个以「可以 /clear 了」结尾空转着不关；spec-18 还有一次用纯文本发问后停住。`unattended-ask-guard` 只拦得住 `AskUserQuestion` 工具，拦不住纯文本提问和「不自关就结束」。

生效条件：与 `unattended-ask-guard` 相同。hook 读取 payload 的 `transcript_path`，取**最后一次** `/implement-spec-split` 调用的 `<command-args>`，其中恰好有 `--auto-land` 这个词才生效；其他会话一律放行。

Run 状态：从 command-args 取第一个数字参数作为 `<n>`，再从 `ISS_STATE_DIR`（默认 `~/.cache/implement-spec-split`）下的 `runs/<repo>-<n>-*/run.json` 取 `phase`。`<repo>` 依次尝试 payload `cwd` 所在 git 仓库的 origin 仓库名（`<name>` 部分）、worktree 路径 `.../workspaces/<repo>/spec-<n>` 里的 `<repo>`，以及主 checkout 的目录名（SKILL.md 告诉 `run-phase.sh` 用的那个）；取 `run.json` mtime 最新的匹配目录。找不到 `run.json` 时只执行规则 B。

两条规则：

- **规则 A（自关）**：`phase` 为 `done`、`waiting` 或 `parked`，且 transcript 里没有任何 Bash tool_use 的 command 包含 `close-self.sh` 时，block。理由提醒先确认落地/停车报告评论已发出，最后一条命令运行 `<skill dir>/scripts/close-self.sh`（落地后加 `--remove-worktree <集成 worktree>`，停车不加），见 SKILL.md 第 10 步。
- **规则 B（问人）**：`phase` 不是 `parked`、`done`、`waiting`，且最后一条 assistant 消息的文本（取最后一个 text block 的最后 300 个字符）以 `？` / `?` 结尾，或包含 `请确认`、`等你`、`需要你`、`要不要`、`是否继续`、`你来决定`、`请选择`、`回复我` 时，block。理由告诉模型：可自动采纳的按推荐做，合并冲突交 merger + Opus 审查，真要人决定的写停车报告后停车并自关；只是在等后台任务就继续等通知，不要问人。

`phase` 为 `split`、`implement`、`integrate`、`review`、`land` 且最后一条消息不是在问人时放行，所以等后台任务通知时正常结束一轮不会被拦。

防死循环：payload 的 `stop_hook_active` 为 true（会话已经在 Stop hook 的续跑里）时，同一条规则最多再 block 1 次，之后放行并在 stderr 打一行警告。计数按 transcript 路径的哈希写到 `<os.tmpdir()>/unattended-stop-guard/<hash>.json`，两条规则各算各的；`stop_hook_active` 为 false 的一次新停止会把计数清零，所以一次循环事故不会让本会话余下的时间都失去保护。

逃生口：`UNATTENDED_STOP_GUARD_DISABLE=1` 时直接放行。`transcript_path` 缺失、不可读、JSON 损坏、`run.json` 损坏或任何内部异常都 fail open（不输出、退出 0）。

注册：`Stop` 事件没有 matcher。在 `~/.claude/settings.json` 的 `hooks.Stop` 数组里**追加**一项（不要覆盖已有的 hook）：

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node ~/.claude/skills/implement-spec-split/hooks/unattended-stop-guard.js",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

macOS / Linux 用上面的绝对路径；Windows 把路径换成 `node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-stop-guard.js`。claude-flash 和 openclaude 是用 `--settings` 叠加启动的，用户级 `~/.claude/settings.json` 照样生效，不需要在各自的 settings 里重复注册。

测试命令：

```text
node hooks/test-unattended-stop-guard.js
```

## land-push-guard hook

`land-push-guard.js` 是 Claude Code 的 `PreToolUse` hook，用于在会话里跑过 `/implement-spec-split` 之后拦住「没持本仓库 land 锁就 push 默认分支」的操作。起因是 2026-11-25 proxy-hub spec-22：落地时执行了 `lock.sh acquire land --scope repo`，实际返回 2（spec-19 正占着锁），但命令被包在一层 `echo` 里，外层退出码变成 0，被误读成拿到了锁，于是在没持锁的情况下执行了 `git push origin HEAD:main`。提示词管不住这种退出码误读，所以做成 hook，直接读锁目录和 `owner.json`。

生效条件：hook 读取 payload 的 `transcript_path`，只要 transcript 里出现过 `<command-name>/implement-spec-split</command-name>`（带不带 `--auto-land` 都算）就生效；其他会话（包括人手动 push）一律放行。

实现上把 shell 分词和命令位置识别抽到 `hooks/lib-shell.js`，transcript 扫描抽到 `hooks/lib-transcript.js`；`delegate-guard.js` 和 `unattended-ask-guard.js` 改为复用这两个模块，行为不变（各自的测试仍全绿）。

判定方式：

- **识别 push**：复用 delegate-guard 的 shell 分词和命令位置识别（先去掉 heredoc 正文，再剥掉重定向，避免 `2>&1` 里的 `&` 被当成命令分隔符），在命令位置上找 `git … push …`，允许 `git -C <dir>` 这类全局选项；不拿正则去匹配整串命令，所以 `echo "git push origin main"`、heredoc 正文里的 `git push` 都不会被误拦。
- **目标仓库目录**：依次取 `git -C <dir>`、命令里前置的 `cd <dir> &&`（识别不了就用 payload 的 `cwd`）。
- **默认分支**：`git -C <dir> symbolic-ref --short refs/remotes/origin/HEAD` 去掉 `origin/`；失败时 `main` 和 `master` 都算默认分支。
- **视为落地 push**：refspec 的目标端（`src:dst` 里的 `dst`，或单写的 `<branch>`，允许 `refs/heads/` 前缀）是默认分支名；或者没写 refspec、而当前分支就是默认分支。`HEAD`/`@` 单写按当前分支算。推 `spec-<n>` 等其他分支、`--tags`、`--delete` 其他分支一律放行；`--all`、`--mirror`、`--branches` 和匹配 refspec `:` 会 push 默认分支，按落地 push 处理。
- **检查锁**：`<git -C <dir> rev-parse --git-common-dir>/implement-spec-split/locks/land.lock/owner.json` 必须存在，其中的 `pid` 等于 hook 沿父进程向上找到的第一个 `claude` 进程 pid；`pid_start` 有记录时还要与 `scripts/pid-start.sh` 取到的启动时间一致。不满足就 deny，理由里给出 `<skill dir>/scripts/lock.sh acquire land --scope repo` 的完整命令，并提醒退出码 2 表示别的 Run 正持锁。

逃生口：`LAND_PUSH_GUARD_DISABLE=1` 时直接放行。任何内部异常、`transcript_path` 缺失或不可读都 fail open（不输出、退出 0）；找不到 claude 祖先进程时也放行，并在 stderr 打一行 `land-push-guard: no claude ancestor process found; allowing the push`。`LAND_PUSH_GUARD_OWNER_PID` 仅供测试注入本会话 claude pid，与 `scripts/lib-owner.sh` 的 `ISS_OWNER_PID` 同理。

注册：在 `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组里**追加**一项（不要覆盖已有的 hook）：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node ~/.claude/skills/implement-spec-split/hooks/land-push-guard.js",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

macOS / Linux 用上面的绝对路径；Windows 把路径换成 `node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/land-push-guard.js`。

测试命令：

```text
node hooks/test-land-push-guard.js
```

## 测试

```text
node hooks/test-delegate-guard.js
```

测试会逐项打印 PASS/FAIL，最后输出汇总和 20 次运行的中位耗时；有任何失败时退出码为非 0。当前共 60 项。
