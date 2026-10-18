# 使用与配置指南
English: [setup.en.md](setup.en.md)

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

## 安全须知（开始前务必读）

- **worker 拥有整机权限**：codex worker 以 `--dangerously-bypass-approvals-and-sandbox` 运行，能读写本机任意文件、执行任意命令，不受沙箱限制（Windows 上 codex 的只读、可写沙箱都不可用，见 [codex-backend.md](codex-backend.md) E8）。Brief 里的"禁区"只是给模型的指示，不是强制隔离。不要在存有敏感数据、且不能接受误操作的机器上使用；重要仓库请先确保有远端备份。
- **代码会发给第三方模型服务**：Brief 内容，以及 worker 读到的源码、日志、命令输出，都会发送到你配置的模型服务（例如智谱 GLM）。公司或客户项目先确认合规要求。
- **对外动作不交给 worker**：push、开 PR、远程服务器操作、删除数据都应该由 Claude 执行，或者由你确认。全局分工规则（阶段 3）里写的就是这条，但它是规则约束，不是技术隔离。
- **hook 是失败放行的**：delegate-guard 出现任何异常都会放行，以免卡住会话。所以要定期用 `scripts/doctor.sh` 确认它确实在工作。

## 适用前提与代价

这套分工是为一种特定情况优化的：**Claude 额度紧张（例如订阅套餐的用量上限），同时另有便宜或额度充足的模型（例如 GLM 编程套餐）**。动手前先确认这个前提是否成立：

- **交接有固定成本**：每交出去一个任务，Claude 都要写 Brief、读结果、审查 diff，不合格还要写返工 Brief。小任务交出去反而更贵，所以规则里设了"≤10 行自己改"的门槛。如果你用 API 按量计费，或者 Claude 额度很宽裕，这套流程可能并不省钱。
- **质量取决于审查**：worker 用的模型通常比 Opus 弱。作者实际使用时遇到过 worker 的测试全部通过、报告也属实，但缺陷恰好落在测试覆盖之外的情况，最后是靠细审 diff 才发现的。审查松懈，问题就会混进代码。
- **会变慢**：每轮 worker 要几分钟到几十分钟，交互式的快速试错体验会变差。
- **成本数据**：目前还没有系统的对比数据，作者正在收集。

## 验证状态

| 项目 | 状态 |
|---|---|
| 平台 | Windows 11 + Git Bash：完整验证。macOS / Linux：未验证（进程管理有非 Windows 分支，但没有跑过） |
| codex-cli | 0.163.0。其他版本未验证，换版本后先跑 `scripts/selftest-codex.sh --only V1` |
| 模型 | GLM-5.3，经本地代理 |
| 阶段 1 | `--impl codex`、`--impl pi` 在试验仓库端到端验证过；`--impl sonnet` 未验证 |
| 阶段 3 | hook 单元测试和本机冒烟测试通过；真实会话里的规则遵守情况仍在验收 |
| 安装命令 | 插件安装命令按本机已装的 marketplace 名（`mattpocock`）给出；`npm i -g @openai/codex` 是 codex 官方的安装方式。都没有在全新机器上重走一遍 |

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

装完任意阶段后都可以运行 `scripts/doctor.sh` 检查。

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
2. **准备一个兼容 OpenAI Responses API 的端点**。codex 用 `wire_api = "responses"` 和模型通信，所以端点必须能处理 Responses API 请求（`POST /v1/responses`，流式 SSE）。只提供 Chat Completions 接口（`/v1/chat/completions`）的服务不能直接用。可选方案：
   - **本地代理**：在本机跑一个代理，对外提供 Responses API，对内转发给模型服务并注入 key。作者用的是 [Ferryman](https://github.com/allanpk716/ferryman) 里的代理功能，监听 `127.0.0.1:15722`。注意这个功能目前没有作为 Ferryman 的公开功能写进文档。
   - **原生支持 Responses API 的模型服务**：如果你的模型服务商直接提供 Responses API，把 `base_url` 指过去即可。
   - **自建兼容网关**：一些开源 LLM 网关可以把 Responses API 转换成 Chat Completions。是否兼容 codex 要自己验证，可以用下面的 `--only L1` 测。

3. 在 `~/.codex/config.toml` 配置一个名为 `custom` 的 provider，指向这个端点。作者环境的写法（本地代理 `127.0.0.1:15722`，由代理负责对接智谱、注入真实 key）：

   ```toml
   model_provider = "custom"
   model = "glm-5.3"

   [model_providers.custom]
   name = "zhipu_glm"
   base_url = "http://127.0.0.1:15722/v1"
   wire_api = "responses"
   requires_openai_auth = true
   ```

   provider 的名字必须是 `custom`：wrapper 用 `-c model_provider=custom -m glm-5.3` 钉死 provider 和模型。模型不是 `glm-5.3` 时，调用 `codex-worker.sh` 要加 `--model <id>`，阶段 1 则修改 `SKILL.md` Config 里的 `CODEX_MODEL`。key 不要写进本仓库。

4. **启动前预检**：每次启动 worker 前，`codex-worker.sh` 会先确认端点可达。预检地址按下面的优先级确定：
   1. 环境变量 `CODEX_WORKER_PREFLIGHT=off`：不做预检。
   2. 环境变量 `CODEX_WORKER_PREFLIGHT=<host>:<port>`：探测这个地址。
   3. 否则读 `config.toml` 里 `[model_providers.custom]` 的 `base_url`。只有回环地址（`127.0.0.1`、`localhost`、`::1`）才会做 TCP 探测；远程地址跳过预检，交给 codex 自己报错。

   本地代理没开时，worker 会立即以 `transient` 退出，错误信息是 `local proxy at <host>:<port> is not listening`。

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

   保留 `<!-- opus-codex-division: vN -->` 这一行版本标记。以后模板更新时，`scripts/doctor.sh` 会比较你 CLAUDE.md 里的标记和模板里的标记，不一致就提醒你同步。

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

- 任何异常都放行（fail-open），hook 坏了不会卡住会话，但也就不再拦截。异常会记进 `~/.claude/state/delegate-guard.log`，`scripts/doctor.sh` 会提示最近 7 天内的错误。

**调整 hook**

- **全局阈值**：环境变量 `DELEGATE_GUARD_LIMIT`（正整数，默认 10）。
- **英文提示**：环境变量 `DELEGATE_GUARD_LANG=en`。
- 这两个环境变量都可以写进 `~/.claude/settings.json` 的 `env` 字段，对所有会话生效。
- **按项目调整**：在项目里放 `.claude/delegate-guard.json`，内容为 `{"limit": 30}`（这个项目的阈值改成 30），或者 `{"enabled": false}`（这个项目不拦截）。hook 从会话的当前目录开始逐级向上找，用最近的那个文件；项目配置的优先级高于环境变量。
- 注意：任何仓库都可以自带这个文件把 hook 关掉。hook 是帮 Claude 守规则的自律工具，不是安全边界。

**验证**

```bash
# 1. hook 单元测试：应输出 Summary: 35 passed, 0 failed
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

## 自检

`scripts/doctor.sh` 自身的检查只读取本机配置，不修改配置文件。它按"基础、阶段 1、阶段 2、阶段 3"报告当前状态：

- `PASS`：检查通过。
- `WARN`：该项可能影响对应阶段，但不阻塞其他阶段；按提示修复。
- `FAIL`：该阶段必要配置缺失或已验证失效；按提示修复。
- `INFO`：阶段未配置或按规则跳过的检查。

参数：

- `--lang zh|en`：输出中文或英文；也可用 `DOCTOR_LANG=en`。
- `--json`：只输出一个 JSON 对象，便于脚本处理。
- `--with-glm`：额外运行 `scripts/selftest-codex.sh --only L1`，会真实请求模型并消耗少量 token。
- `--help`：查看帮助。

有任何 `FAIL` 时脚本退出码为 1，否则为 0。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| worker 状态是 `transient`，错误是 `local proxy at <host>:<port> is not listening` | 本地代理没开，或者 `config.toml` 的 `base_url` 端口写错。开起来后让 Claude 重跑；确实不需要预检就设 `CODEX_WORKER_PREFLIGHT=off` |
| worker 状态是 `transient`，错误是 `endpoint unreachable` | codex 连不上模型端点（网络或远程服务问题）。先用 `scripts/selftest-codex.sh --only L1` 单独测连通性 |
| `auth` / `quota` | GLM key 失效或额度用完。Claude 会停下来问你，不会自己换方案 |
| hook 不拦截 | 检查 `settings.json` 里的路径；新开会话；用上面的冒烟命令测 hook 本身；看是否有未过期的 `allow-direct-edit` |
| 某个项目里 Claude 不按分工走 | 项目级 CLAUDE.md 可能写了相反的规则，优先看项目规则是否冲突 |
| 调查任务返回 `violation`（退出码 8） | worker 在只读调查里改了文件。看 `status.json` 的 `changed_paths` 和 `git diff`，由你决定怎么还原 |
| `--impl codex` 运行中途停下问你 | 有 worker 撞上限流；降低 `--parallel`，或换到闲时 |
