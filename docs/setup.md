# 使用与配置指南

本仓库提供三种能力，彼此有依赖，按阶段配置即可：

| 阶段 | 能力 | 用在什么时候 | 依赖 |
|---|---|---|---|
| 0 | 公共基础 | 所有场景 | 无 |
| 1 | `/implement-spec-split`：按 spec 并行实现多个 ticket | 有一个拆好 ticket 的 spec，要一口气做完 | 阶段 0 |
| 2 | codex 后端：实现角色改用 GLM（不花 Claude 额度） | 想让阶段 1 的实现角色不用 Sonnet；也是阶段 3 的前提 | 阶段 0 |
| 3 | 全局 Opus / codex 分工：日常会话里 Opus 只做判断，写代码交给 codex worker | 平时在任何项目里和 Claude 协作 | 阶段 0、2 |

只想要日常分工、不用 spec 流程：做 0 → 2 → 3。只想要 spec 流程且用 Sonnet 实现：做 0 → 1。全部都要：0 → 1 → 2 → 3。

```
阶段 0 公共基础
 ├─ 阶段 1 spec 并行实现（--impl sonnet 即可用）
 │     └─ 加上阶段 2 后可用 --impl codex
 └─ 阶段 2 codex 后端
       └─ 阶段 3 全局分工（CLAUDE.md 规则 + delegate-guard hook）
```

---

## 阶段 0：公共基础

**安装**

1. Claude Code、Git、Node.js（脚本用 node 处理 JSON 和进程）。
2. Windows：Git Bash（wrapper 都是 Bash 脚本）。
3. 把本仓库克隆到 Claude 的技能目录，**路径不要改**，阶段 3 的规则和 hook 都按这个路径引用：

   ```bash
   git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
   ```

**验证**

```bash
ls ~/.claude/skills/implement-spec-split/{SKILL.md,scripts,templates,hooks}
```

---

## 阶段 1：按 spec 并行实现（`/implement-spec-split`）

这是 [Matt Pocock 的 `implement-spec`](https://github.com/mattpocock/skills) 的改版：编排逻辑相同，但每个角色单独指定模型。实现角色（exploration / implementer / merger / fix）用便宜模型，两个 code review 子代理固定用 Opus。

**安装**

1. 安装 `mattpocock-skills` 插件（本技能用它的 `tdd`、`code-review` 技能）。在 Claude Code 里：

   ```text
   /plugin marketplace add mattpocock/skills
   /plugin install mattpocock-skills@mattpocock
   ```

2. 在**目标项目**里运行一次 `/setup-matt-pocock-skills`，生成 `docs/agents/issue-tracker.md`（告诉技能 issue 在哪里、怎么查）。

**准备 spec**

spec 是一个 GitHub 父 issue，它的子 issue 就是 ticket，ticket 之间的依赖决定哪些能并行。可以用 mattpocock 的规划类技能生成，也可以手工建。

**使用**

```text
/implement-spec-split                      # 不带参数：自动列出未完成的 spec 让你选
/implement-spec-split #12                  # 指定 spec
/implement-spec-split #12 --impl sonnet    # 实现角色用 Sonnet 子代理（默认）
/implement-spec-split #12 --impl codex     # 实现角色用 codex worker（需要阶段 2）
/implement-spec-split #12 --impl codex --parallel 3
```

**并行是怎么发生的**

- 技能先读 spec 和 ticket，建任务图。依赖都已满足的 ticket 组成"前沿"，前沿里的 ticket 各开一个 worktree 并行实现。
- 合并串行进行：同一时间只有一个 merger 把完成的 ticket 合进集成分支。
- 并发上限：`--impl sonnet` 时由 Claude 子代理并发；`--impl codex/pi` 时由 `GLM_MAX_PARALLEL` 控制（默认 2），可以用 `--parallel n` 只对本次运行覆盖。建议 2–3，闲时最多 4：智谱高峰期会限流，任何一个 worker 撞上 429 都会让整个运行停下来问你。
- 每个 ticket 完成后都要经过验证关口和两个 Opus 审查（Standards、Spec）才算完。

默认值在 `SKILL.md` 的 "Config" 一节修改。

**验证**

在一个有 spec 的试验仓库里跑一次 `/implement-spec-split <spec> --impl sonnet`，观察：前沿里的 ticket 并行开工，合并串行，最后有两份审查报告。

---

## 阶段 2：codex 后端（GLM）

让 `codex exec` 用 GLM 干活。阶段 1 的 `--impl codex` 和阶段 3 的日常分工都靠它。

**安装**

1. 安装 codex CLI（已测试 0.163.0）：`npm i -g @openai/codex`，然后 `codex --version` 确认。
2. 在 `~/.codex/config.toml` 配置一个名为 `custom` 的 provider，指向能提供 GLM 的 **Responses API** 端点。本机的写法（经本地 Ferryman 代理 `127.0.0.1:15722`，由代理负责对接智谱、注入真实 key）：

   ```toml
   model_provider = "custom"
   model = "glm-5.3"

   [model_providers.custom]
   name = "zhipu_glm"
   base_url = "http://127.0.0.1:15722/v1"
   wire_api = "responses"
   requires_openai_auth = true
   ```

   provider 的名字必须是 `custom`：wrapper 用 `-c model_provider=custom -m glm-5.3` 钉死 provider 和模型。key 不要写进本仓库。
3. 如果用代理，确保代理在跑（本机就是 Ferryman 开着）。

**验证**

```bash
cd ~/.claude/skills/implement-spec-split
scripts/selftest-codex.sh --only V1   # 用假 codex 测 wrapper 本身，不花 token，应输出 OK: all checks passed
scripts/selftest-codex.sh --only L1   # 真连一次 GLM，花极少 token；失败多半是代理没开或 provider 配置错
```

**设计依据**

为什么用 `exec --json` 加 wrapper、为什么用 bypass 模式、Windows 上的坑，见 [codex-backend.md](codex-backend.md)。

---

## 阶段 3：全局 Opus / codex 分工

让**所有项目**的日常会话都按这个分工走：Opus 负责讨论、定方案、做根因判断、审查和放行，写代码和读大量代码交给 codex worker。由两部分组成：

| 部分 | 放在哪 | 作用 |
|---|---|---|
| 分工规则 | `~/.claude/CLAUDE.md` | 告诉 Claude 什么自己做、什么交出去、怎么调 worker、怎么处理结果 |
| delegate-guard hook | `~/.claude/settings.json` | 机械地拦下对源码超过 10 行的直接修改，不依赖模型记得规则 |

**安装**

1. **写入分工规则**：打开 [templates/global-claude-md.md](../templates/global-claude-md.md)，把分隔线以下的内容追加进 `~/.claude/CLAUDE.md`。如果原来有旧版"写代码交给 codex/PI"的段落，替换掉。先改两处占位：
   - `<GLM 代理说明>`：本机 codex 怎么连 GLM，例如"本机 Ferryman 代理 `127.0.0.1:15722` 上的 GLM"；
   - 技能路径：如果没克隆到 `~/.claude/skills/implement-spec-split`，全部替换成实际路径。

2. **注册 hook**：在 `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组里**追加**一项（不要覆盖已有的 hook）：

   ```json
   {
     "matcher": "Edit|Write|NotebookEdit",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/delegate-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   macOS / Linux 把路径换成 `node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js` 的绝对路径。改之前先备份 `settings.json`。

3. 新开一个 Claude Code 会话，hook 和规则才会完整生效。

**hook 的判定规则**

- 只管 `Edit`、`Write`、`NotebookEdit`，不管 Bash（Bash 写文件靠规则约束）。
- 放行：扩展名为 `.md .txt .json .jsonc .yaml .yml .toml .ini .cfg .csv` 的文件，以及 `.gitignore`、`.gitattributes`；改动不超过 10 行的源码修改。
- 拒绝：超过 10 行的源码修改（Edit 取 old/new 中较多的行数；Write 取全文行数）。
- 例外开关：`~/.claude/state/allow-direct-edit`，内容是过期时间（ISO 8601 或 epoch 秒），过期前全部放行。规则要求只有用户明确授权时才由 Claude 创建。你也可以自己创建：

  ```bash
  mkdir -p ~/.claude/state && date -d '+60 min' -Iseconds > ~/.claude/state/allow-direct-edit
  ```

- 任何异常都放行（fail-open），hook 坏了不会卡住会话，但也就不再拦截。

**验证**

```bash
# 1. hook 单元测试：应输出 Summary: 19 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-delegate-guard.js

# 2. 冒烟：应输出一段 permissionDecision 为 deny 的 JSON
node -e 'console.log(JSON.stringify({tool_name:"Write",tool_input:{file_path:"C:/x/a.py",content:"l\n".repeat(15)}}))' \
  | node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js
```

3. 在新会话里让 Claude 直接写一个 15 行的 `.py` 文件：应该被拦下，并看到"按规则应写 Brief 交给 codex worker"的理由。
4. 分流测验：新会话里问 Claude 下面每项"谁做 + 一句理由"（不执行）。期望答案见括号：
   - 讨论新功能的架构取舍（Opus）
   - 新增一个带测试的接口，约 200 行（codex）
   - 偶发失败的测试，涉及 3 个模块（调查 Brief 交 codex，Opus 判断）
   - 把已审过的改动 commit（Opus）
   - 改一行拼错的常量名（Opus 直接改）
   - 合并时 6 个文件冲突（codex 解冲突，Opus 审）
   - push 并开 PR（Opus，push 前确认）
   - 在远程服务器上重启服务（Opus，不交 worker）

**日常怎么用**

不用记命令，正常和 Claude 说需求即可。规则生效后会这样运作：

- 讨论、定方案、做决定：Claude（Opus）自己来。
- 要写代码：Claude 按 [templates/brief-implement.md](../templates/brief-implement.md) 写 Brief，后台起 codex worker，完成后审查 diff、抽查验收命令；不合格就写返工 Brief 再跑。
- 要定位问题：Claude 按 [templates/brief-investigate.md](../templates/brief-investigate.md) 写调查 Brief，加 `--read-only` 交给 worker，只看报告。
- commit、push、开 PR、操作服务器：Claude 自己做，对外动作先问你。
- 想看 worker 进度：直接问"进行到哪了"，Claude 会运行 `scripts/progress.sh` 转述。
- 想让 Claude 自己写某段代码：明确说"这个你自己改"，它会开 60 分钟的例外开关。

运行记录在 `~/.cache/codex-runs/<仓库>-<时间>-<任务>/`，里面有 `brief.md`、`status.json`、`result.md`、事件流和日志。

---

## 更新与回滚

- **更新**：`cd ~/.claude/skills/implement-spec-split && git pull`。模板和脚本立即生效；hook 下次调用即生效。
- **分工规则更新**：仓库里的 `templates/global-claude-md.md` 改了之后，需要手动同步到 `~/.claude/CLAUDE.md`（全局文件不在仓库管理范围内）。
- **暂停分工**：从 `settings.json` 删掉 delegate-guard 那一项，并从 CLAUDE.md 删掉分工一节。
- **换机器**：要搬三样东西：克隆本仓库（阶段 0）、`~/.codex/config.toml` 与代理（阶段 2）、CLAUDE.md 分工一节和 `settings.json` 的 hook 注册（阶段 3）。只克隆仓库不够。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| worker 状态是 `transient`，错误里有 `proxy not listening` | 代理（Ferryman）没开。开起来后让 Claude 重跑 |
| `auth` / `quota` | GLM key 失效或额度用完。Claude 会停下来问你，不会自己换方案 |
| hook 不拦截 | 检查 `settings.json` 里的路径；新开会话；用上面的冒烟命令测 hook 本身；看是否有未过期的 `allow-direct-edit` |
| 某个项目里 Claude 不按分工走 | 项目级 CLAUDE.md 可能写了相反的规则，优先看项目规则是否冲突 |
| 调查任务返回 `violation`（退出码 8） | worker 在只读调查里改了文件。看 `status.json` 的 `changed_paths` 和 `git diff`，由你决定怎么还原 |
| `--impl codex` 运行中途停下问你 | 有 worker 撞上限流；降低 `--parallel`，或换到闲时 |
