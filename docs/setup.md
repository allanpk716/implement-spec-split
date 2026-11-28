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
 ├─ 阶段 1 spec 并行实现（票的实现是 Orca worker，按「实现」路由派发）
 │     └─ 加上阶段 2 后，规格开始前的 headless 探索也可用
 └─ 阶段 2 codex 后端
       └─ 阶段 3 全局分工（CLAUDE.md 规则 + delegate-guard / unattended-ask-guard / unattended-stop-guard / land-push-guard / subagent-guard hook）
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
| 平台 | Windows 11 + Git Bash：完整验证（含真实 GLM 端到端）。Ubuntu 24.04：无模型的自测全部通过（`selftest-codex.sh --only V1`、hook 测试、doctor 测试），但没有用真实 codex 和 GLM 跑过。macOS 27（系统自带 bash 3.2）：完整验证（codex-cli 0.164.0，含真实 GLM 端到端 V3，2026-10-24） |
| codex-cli | 0.163.0、0.164.0。其他版本未验证，换版本后先跑 `scripts/selftest-codex.sh --only V1` |
| 模型 | GLM-5.4，经本地代理 |
| 阶段 1 | 旧的 `codex` wrapper 后端在试验仓库端到端验证过；规格 #26 起票的实现经 Orca worker 派发，这条路径等真机冒烟票验证 |
| find-next | 本地 markdown 跟踪器：脚本单测通过，`--worker codex` 在真实仓库实跑过一次（2026-11-01）。GitHub 路径未实跑 |
| 阶段 3 | hook 单元测试和本机冒烟测试通过；真实会话里的规则遵守情况仍在验收 |
| 安装命令 | 插件安装命令按本机已装的 marketplace 名（`mattpocock`）给出；`npm i -g @openai/codex` 是 codex 官方的安装方式。都没有在全新机器上重走一遍 |

---

## 阶段 0：公共基础

**安装**

1. Claude Code、Git、Node.js（脚本用 node 处理 JSON 和进程）。
2. Windows：Git Bash（wrapper 都是 Bash 脚本）。
3. 克隆本仓库，然后运行安装脚本——规格 #58 起安装只有这一条路，幂等、重复运行零修改：

   ```bash
   git clone https://github.com/allanpk716/implement-spec-split ~/.claude/skills/implement-spec-split
   cd ~/.claude/skills/implement-spec-split && ./install.sh
   ```

   两种安装形态都受支持：**clone 直装**（上面这种，`~/.claude/skills/implement-spec-split` 本身就是仓库，根技能位置就是主 checkout 的真实目录、算已就位，脚本只给子技能建链）和**软链**（克隆在别处，比如 `~/orca/implement-spec-split`，在那个克隆里运行 `./install.sh`，五个技能链都指向它）。`install.sh` 以自己所在的 checkout 为主 checkout，链指向它。两种形态下 `~/.claude/skills/implement-spec-split` 这个路径都成立（clone 直装是仓库本身，软链形态经链解析到克隆），阶段 3 的规则和 hook 照这个路径引用即可。

   `./install.sh` 做两件事：

   - **建技能软链**：扫描 git 跟踪的、含 `SKILL.md` 的目录（根技能和子技能 `find-next`、`grill-feature`、`grill-map`、`grill-router`），逐个确保 `~/.claude/skills/<name>` 是指向主 checkout 对应目录的软链——缺的建、指错的改指、仓库里已不存在的技能留下的悬空链删掉；同名真实目录不动、只警告。「指向正确」按链解析到的物理目录判定，所以下文手工写的 `ln -s ~/.claude/skills/implement-spec-split/<name> …` 解析到同一目录同样算就位。
   - **本机配置期望项**：一份「仓库对本机配置的期望」清单（`install.sh` 内置的数据），每项标 tighten（收紧）或 loosen（放宽）。tighten 项本机不满足时（v1 唯一一项：`delegate-guard` 的 PreToolUse matcher 覆盖 `Edit`、`Write`、`Bash`），先把 `settings.json` 备份到 `<settings 所在目录>/backups/install-<时间戳>/`，再用 node 原地改，改后校验是合法 JSON，不是就用备份还原并报 FAIL。loosen 项永不执行，只列进「未执行的放宽项」（人类输出的专门一节，`--json` 的 `unexecutedLoosenings` 数组），记 WARN、退出码 1。hook 没注册的期望项不算漂移，不处理也不报告（阶段 3 是可选采纳的，没注册 hook 之前 `install.sh` 只建链）。

   `./install.sh --check` 只报告不改（不建链、不写 `settings.json`、不建备份）：全部就位退出 0，有漂移退出 1。`./install.sh --json` 只输出一个 JSON 对象（形状沿用 `scripts/doctor.sh`：`checks` 数组 + `summary`），给脚本读。Windows（Git Bash）上不建链不删链，每个未就位的技能打印一行手工步骤（`mklink /J`，或者直接复制）记 WARN；期望项那段只经 node 读写文件，各平台一样。

   不想用脚本时，手工等价于在 macOS / Linux 上建这四条链（Windows 用 `mklink /J`，或者直接复制；技能新增、改名、退役时要自己跟着改）：

   ```bash
   ln -s ~/.claude/skills/implement-spec-split/find-next ~/.claude/skills/find-next
   ln -s ~/.claude/skills/implement-spec-split/grill-feature ~/.claude/skills/grill-feature
   ln -s ~/.claude/skills/implement-spec-split/grill-map ~/.claude/skills/grill-map
   ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router
   ```

**验证**

```bash
ls ~/.claude/skills/implement-spec-split/{SKILL.md,scripts,templates,hooks}
~/.claude/skills/implement-spec-split/install.sh --check      # 全部就位退出 0；有漂移退出 1 并列出每一处
```

装完任意阶段后都可以运行 `scripts/doctor.sh` 检查；它报「本机安装状态」有漂移时，按提示运行 `./install.sh` 修。

---

## 阶段 1：按 spec 并行实现（`/implement-spec-split`）

这是 [Matt Pocock 的 `implement-spec`](https://github.com/mattpocock/skills) 的改版：编排逻辑相同，但每个角色单独指定模型。实现角色（exploration / implementer / fix；合并先走脚本、冲突才起 worker）用便宜模型，全部由规格会话经 `scripts/stage-dispatch.sh` 派成 Orca worker，启动器、模型和思考强度来自阶段路由表；两个 code review 子代理固定用 Opus。

**安装**

1. 安装 `mattpocock-skills` 插件（本技能用它的 `tdd`、`code-review` 技能）。在 Claude Code 里：

   ```text
   /plugin marketplace add mattpocock/skills
   /plugin install mattpocock-skills@mattpocock
   ```

2. 在**目标项目**里运行一次 `/setup-matt-pocock-skills`，生成 `docs/agents/issue-tracker.md`（告诉技能 issue 在哪里、怎么查）。

3. Orca，以及「实现」路由指向的启动器在 PATH 上（默认 `claude-glm`，见 `scripts/stage-route.sh`；改路由用 `/grill-router`）：票的实现 worker 是 Orca worker，没有 Orca 派不出去。规格开始前的 headless 探索走 `codex-worker.sh`，需要阶段 2。

**准备 spec**

spec 是一个 GitHub 父 issue，它的子 issue 就是 ticket，ticket 之间的依赖决定哪些能并行。可以用 mattpocock 的规划类技能生成，也可以手工建。

**使用**

```text
/implement-spec-split                      # 不带参数：提示先跑 /find-next --batch，由它给出顺序和命令
/implement-spec-split #12                  # 指定 spec
/implement-spec-split #12 --parallel 3     # 本 Run 同时最多派 3 个票的 worker
```

**并行是怎么发生的**

- 技能先读 spec 和 ticket，建任务图。依赖都已满足的 ticket 组成"前沿"，前沿里的 ticket 各在自己的子工作区（挂在规格工作区下）并行实现。
- 合并串行进行，而且先由脚本合：`scripts/merge-ticket.sh` 没冲突就直接合进集成分支并跑测试，有冲突或碰撞的共享计数器才派一个 worker 解。
- 并发上限：`GLM_MAX_PARALLEL` 控制（默认 2），可以用 `--parallel n` 只对本次运行覆盖。建议 2–3，闲时最多 4：智谱高峰期会限流，任何一个 worker 撞上 429 都会让整个运行停下来问你。
- 每个 ticket 完成后都要经过验证关口和两个 Opus 审查（Standards、Spec）才算完。
- 多个 spec 同时做：在同一个 clone 的多个 Orca worktree 里各开一个会话、各跑一次技能。不带 spec 编号时，技能不扫描、也不列候选，只提示「先运行 `/find-next --batch`，它给出开发顺序和每个 worktree 要敲的命令」然后停下：选哪个开发只在 find-next 一处决定，几个 worktree 同时启动也不会各自扫描、各选一个。带上编号后，会话的 worktree 关联到该 issue、标签页改名为 `spec-<n> …`。进行中或疑似中断的 spec 由 find-next 的开发顺序列进「先恢复」并给出命令，照着敲就是接着做上次没做完的（Recovery）。`--parallel` 按每个运行计，几个运行的 worker 数相加，共享 GLM 额度。

**工作区三层与接管**

- **侧栏是一棵可折叠的树**，不再有进度标签（规格 #26）：主会话 → 规格工作区 `spec-<n>`（分支 `spec-<n>`，从 `origin/main` 切出，由 find-next 的 launch-wave 建为主会话工作区的子工作区）→ 票工作区 `spec-<n>-t<m>`（分支 `spec-<n>-t<m>`，从集成分支 `spec-<n>` 切出，由派发模块建为规格工作区的子工作区），每张票的 worker 跑在标题为 `spec-<n> t<m>` 的终端里；fix 和冲突解算角色直接在规格工作区里跑。看一张票属于哪份规格、做到哪了，看侧栏就行。
- **工作区由脚本删**：票合入后 `scripts/stage-dispatch.sh release` 连分支一起删掉票工作区；规格落地后 `scripts/close-self.sh` 先删完剩下的票工作区、再删规格工作区；停车的规格保留工作区；遗弃的由 keeper 每轮经 `scripts/sweep-worktrees.sh` 清扫（只删干净且已并入 origin 的；有未落地提交的工作区不会被清扫，要人处理）。不要手工 `orca worktree rm` 还有票工作区的规格工作区——子工作区会变成孤儿（Orca 不级联也不拒绝）。
- **每份规格一个 Orca Run**：规格会话在第 0 步 `orca orchestration run-create` 建自己那份（票的 worker 都向它汇报），启动这一波的 `launch-wave.sh --apply` 另建一份给这一波的规格会话。主会话、规格会话或任何协调终端关掉都不影响下层：worker 照常跑，`worker_done` 照常进 Run。在新终端里接管：

  ```bash
  cat ~/.cache/implement-spec-split/runs/<仓库>-<n>-<时间>/orca-run-id        # 某份规格的 Run（取该规格最新的运行目录）
  grep '"run"' ~/.cache/implement-spec-split/launch/<owner>__<仓库>.json       # 某一波的 Run（启动状态文件）
  orca orchestration run-use --id <run id> --json
  ```

  `run-use` 之后这个终端又是 Run 的协调者（`orca orchestration run-current` 能认出它），`stage-dispatch.sh` 的 `dispatch` / `wait` / `release` 重新可用；被替换掉的规格会话按技能的 Recovery 接着做。接管不重派任何东西——worker 本来就没停。

默认值在 `SKILL.md` 的 "Config" 一节修改。

**验证**

在一个有 spec 的试验仓库里跑一次 `/implement-spec-split <spec>`，观察：前沿里的 ticket 各在自己的子工作区并行开工，合并串行且先走脚本，最后有两份审查报告。（规格 #26 的派发路径以规格 #26 的真机冒烟票为准。）

---

## 找下一步（`/find-next`）

用 wayfinder 讨论出一堆票之后，不知道下一步该对哪张做 to-spec、to-tickets 还是 grilling，就用 `find-next`（本仓库 `find-next/` 目录下的第二个技能）。它扫描当前仓库的地图和票，**只推荐一个下一步**，附上要敲的命令，外加最多 3 行备选：

| 优先级 | 情形 | 推荐命令 |
|---|---|---|
| 1 | 有 Spec 但还没拆执行票 | `/to-tickets <Spec>` |
| 2 | 地图的决策都已拍板，还没写成 Spec | `/to-spec` |
| 3 | 地图上可以接着讨论的 Decision ticket（解锁下游最多的优先） | `/wayfinder <地图> <票>`；不在地图里的散票用 `/grill-with-docs` |

被标成「搁置」的地图和票会跳过。实现阶段不扫，那是 `/implement-spec-split --status` 的事。

**安装**：阶段 0 的 `./install.sh` 已经把它、两个 Design session 薄包装技能和阶段路由命令 `/grill-router`（用法见阶段 4）一起软链到技能目录，仓库更新后重跑一次即可（`git pull && ./install.sh`，落地流程会自动跑）。手工等价（Windows 用 `mklink /J`，或者直接复制）：

```bash
ln -s ~/.claude/skills/implement-spec-split/find-next ~/.claude/skills/find-next
ln -s ~/.claude/skills/implement-spec-split/grill-feature ~/.claude/skills/grill-feature
ln -s ~/.claude/skills/implement-spec-split/grill-map ~/.claude/skills/grill-map
ln -s ~/.claude/skills/implement-spec-split/grill-router ~/.claude/skills/grill-router
```

**用法**：`/find-next [--worker codex|self]`，也可以直接问「下一步做什么」。想看全貌时用 `/find-next --list`，或者直接问「还有什么没做完」：列出全部待办（正在实现、未拆票、缺规格、待讨论的决策票、状态没收尾、散票），不派 worker。决定接下来开发什么时用 `/find-next --batch --workers 4`（`--workers` 是全机 GLM worker 总数，`--specs` 是同时开几份规格，默认 2）：缺规格的票和有规格未拆票的规格，每组由一个 codex worker 起草，审稿后每个待定条目按 worker 的推荐自动拍板（可推翻，不等回答）再统一发布；最后总是给出全仓库可以开发的规格的编号顺序和每个会话要跑的命令，随后它在 Orca 里自动开 worktree 并启动会话（不在 Orca 里时把命令复制到各个 worktree 运行）。要改某条拍板就回「推翻 #<n> <条目> 改选 <X>」。一波合入后再跑一次开下一波。同一仓库同一时间只在一个会话里跑 `--batch`。

- 默认 `codex`：机械扫描交给脚本（本地 markdown 跟踪器用 `find-next/scripts/scan.py`，GitHub 用 `scripts/pipeline-status.sh`），判断交给一个只读的 codex worker，会话里只读它不超过 15 行的结论。需要先完成阶段 2。
- `self`：会话自己判断，不依赖 codex。
- 推荐 to-spec 或 to-tickets 时，会先把材料读进当前会话，因为这两个技能只综合当前对话，然后再提示你敲命令。

全程只读，不改票、不认领。设计理由见 `MAINTAINING.md`「find-next 设计要点」。

## 阶段 2：codex 后端（GLM）

让 `codex exec` 用 GLM 干活。阶段 1 的 headless 探索和阶段 3 的日常分工都靠它。

**安装**

1. 安装 codex CLI（已测试 0.163.0、0.164.0）：`npm i -g @openai/codex`，然后 `codex --version` 确认。
2. **准备一个兼容 OpenAI Responses API 的端点**。codex 用 `wire_api = "responses"` 和模型通信，所以端点必须能处理 Responses API 请求（`POST /v1/responses`，流式 SSE）。只提供 Chat Completions 接口（`/v1/chat/completions`）的服务不能直接用。可选方案：
   - **本地代理**：在本机跑一个代理，对外提供 Responses API，对内转发给模型服务并注入 key。作者用的是 [Ferryman](https://github.com/allanpk716/ferryman) 里的代理功能，监听 `127.0.0.1:15722`。注意这个功能目前没有作为 Ferryman 的公开功能写进文档。
   - **原生支持 Responses API 的模型服务**：如果你的模型服务商直接提供 Responses API，把 `base_url` 指过去即可。
   - **自建兼容网关**：一些开源 LLM 网关可以把 Responses API 转换成 Chat Completions。是否兼容 codex 要自己验证，可以用下面的 `--only L1` 测。

3. 在 `~/.codex/config.toml` 配置一个名为 `custom` 的 provider，指向这个端点。作者环境的写法（本地代理 `127.0.0.1:15722`，由代理负责对接智谱、注入真实 key）：

   ```toml
   model_provider = "custom"
   model = "glm-5.4"

   [model_providers.custom]
   name = "zhipu_glm"
   base_url = "http://127.0.0.1:15722/v1"
   wire_api = "responses"
   requires_openai_auth = true
   ```

   provider 的名字必须是 `custom`：wrapper 用 `-c model_provider=custom -m <模型>` 钉死 provider 和模型，模型和思考强度取自阶段路由表（`scripts/stage-route.sh`，默认 `glm-5.4` / `high`）。模型不是 `glm-5.4` 时，用 `/grill-router` 把「实现」和「调研起草」两个阶段设到已验证目录里的组合（例如 `/grill-router use implementation=codex-glm/glm-5.3/high research=codex-glm/glm-5.3/high`），不要给 `codex-worker.sh` 传 `--model`。key 不要写进本仓库。

   照智谱官方 Codex 教程配置、直连 `open.bigmodel.cn` 的话，教程里的 provider 叫 `ZAI`：把 `model_provider = "ZAI"` 和 `[model_providers.ZAI]` 都改成 `custom`，`name = "ZAI"` 可以保留（codex 0.164 起 `name` 不能为空）。否则 worker 会报 `model_providers.custom: provider name must not be empty`。支持其他 provider 名见 issue #6。

4. **启动前预检**：每次启动 worker 前，`codex-worker.sh` 会先确认端点可达。预检地址按下面的优先级确定：
   1. 环境变量 `CODEX_WORKER_PREFLIGHT=off`：不做预检。
   2. 环境变量 `CODEX_WORKER_PREFLIGHT=<host>:<port>`：探测这个地址。
   3. 否则读 `config.toml` 里 `[model_providers.custom]` 的 `base_url`。只有回环地址（`127.0.0.1`、`localhost`、`::1`）才会做 TCP 探测；远程地址跳过预检，交给 codex 自己报错。

   本地代理没开时，worker 会立即以 `transient` 退出，错误信息是 `local proxy at <host>:<port> is not listening`。

5. **MCP 默认关闭，按需开启**：worker 启动时会关掉 `config.toml` 里的全部 MCP 服务（启动更快，工具描述也不占上下文）。要联网搜索的调研任务给 `codex-worker.sh` 加 `--mcp all`，要操作远程服务器的加 `--mcp ssh-manager`（可写多个服务名，逗号分隔）；写代码的任务不加。续跑沿用第一次的设置。
6. **子代理并发上限**：worker 的固定前言会要求 codex 并行调用独立命令、勘察时开 explorer 子代理。子代理不占 worker 槽位，建议在 `config.toml` 里限制并发：

   ```toml
   [agents]
   max_concurrent_threads_per_session = 3
   ```

7. **生成独立的 worker home（推荐）**：上面几步配好 `~/.codex/config.toml` 后，运行 `scripts/setup-worker-home.sh`，它会生成 `~/.codex-worker/`，只带 provider、MCP 和 `[agents]`，不带 hooks、projects 和交互设置。之后 worker 只读这个目录，你交互用的 codex 可以随意改配置（比如切到 OpenAI 订阅），不会影响 worker。改了 `~/.codex/config.toml` 里 worker 相关的部分要重跑一次（幂等，内容变了会先备份）。想放到别处就设 `CODEX_WORKER_HOME`。没有 worker home 时 wrapper 退回 `~/.codex` 并警告。

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

让**所有项目**的日常会话都按这个分工走：Opus 负责讨论、定方案、做根因判断、审查和放行，写代码和读大量代码交给 codex worker。由五部分组成：

| 部分 | 放在哪 | 作用 |
|---|---|---|
| 分工规则 | `~/.claude/CLAUDE.md` | 告诉 Claude 什么自己做、什么交出去、怎么调 worker、怎么处理结果 |
| delegate-guard hook | `~/.claude/settings.json` | 机械地拦下对源码超过 10 行的直接修改，不依赖模型记得规则 |
| unattended-ask-guard hook | `~/.claude/settings.json` | 无人值守的 `--auto-land` Run 里拒绝 `AskUserQuestion`，不依赖模型记得不问人 |
| unattended-stop-guard hook | `~/.claude/settings.json` | 无人值守的 `--auto-land` Run 结束前，没自关不许结束，也不许以问人结束 |
| land-push-guard hook | `~/.claude/settings.json` | 会话跑过 `/implement-spec-split` 后，没持本仓库 land 锁就不许 push 默认分支 |
| subagent-guard hook | `~/.claude/settings.json` | flash 会话主线程里拦住用 Agent 工具开能写代码的子代理（实现、fix、冲突解算经派发模块派发） |

**安装**

1. **写入分工规则**：打开 [templates/global-claude-md.md](../templates/global-claude-md.md)，把分隔线以下的内容追加进 `~/.claude/CLAUDE.md`。如果原来有旧版"写代码交给 codex/PI"的段落，替换掉。先改两处占位：
   - `<GLM 代理说明>`：本机 codex 怎么连 GLM，例如"本机 Ferryman 代理 `127.0.0.1:15722` 上的 GLM"；
   - 技能路径：如果没克隆到 `~/.claude/skills/implement-spec-split`，全部替换成实际路径。

   保留 `<!-- opus-codex-division: vN -->` 这一行版本标记。以后模板更新时，`scripts/doctor.sh` 会比较你 CLAUDE.md 里的标记和模板里的标记，不一致就提醒你同步。

2. **注册 hook**：在 `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组里**追加**一项（不要覆盖已有的 hook）：

   ```json
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
   ```

   macOS / Linux 把路径换成 `node ~/.claude/skills/implement-spec-split/hooks/delegate-guard.js` 的绝对路径。matcher 里的 `Bash` 不用手工核对和备份：之后在仓库里运行 `./install.sh`，它把「delegate-guard 的 matcher 覆盖 `Edit`、`Write`、`Bash`」列为期望项（tighten），发现已注册的这条缺 `Bash` 时先把 `settings.json` 备份到 `~/.claude/backups/install-<时间戳>/`，再把缺的工具追加到 matcher 末尾（已有的 `NotebookEdit` 原样保留），改后校验是合法 JSON；照上面原样注册（已含 `Bash`）就不用补。`install.sh` 不替你注册 hook——hook 没注册不算漂移，下面几个 hook 仍要手工加。

   **同时注册 unattended-ask-guard**：无人值守的 `/implement-spec-split --auto-land` 会话里没人会来回答，这个 hook 会拒绝 `AskUserQuestion`，并提示模型改走自动拍板或停车报告。在同一个 `hooks.PreToolUse` 数组里再追加一项：

   ```json
   {
     "matcher": "AskUserQuestion",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-ask-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   macOS / Linux 同样换成绝对路径。它按 transcript 里最后一次 `/implement-spec-split` 调用是否带 `--auto-land` 判定，`UNATTENDED_ASK_GUARD_DISABLE=1` 可临时关闭；详见 [hooks/README.md](../hooks/README.md)。

   **同时注册 land-push-guard**：会话里跑过 `/implement-spec-split` 后，往默认分支（`main` / `master`，或 `origin/HEAD` 指向的分支）push 必须先持有本仓库的 land 锁；这个 hook 直接读锁目录，不依赖模型记得先加锁，也不依赖它读懂 `lock.sh` 的退出码。在同一个 `hooks.PreToolUse` 数组里再追加一项：

   ```json
   {
     "matcher": "Bash",
     "hooks": [
       {
         "type": "command",
         "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/land-push-guard.js",
         "timeout": 5
       }
     ]
   }
   ```

   macOS / Linux 同样换成绝对路径。它只在 transcript 里出现过 `/implement-spec-split` 命令调用的会话生效；`LAND_PUSH_GUARD_DISABLE=1` 可临时关闭；详见 [hooks/README.md](../hooks/README.md)。

   **同时注册 unattended-stop-guard**：无人值守的 `--auto-land` Run 结束前，这个 hook 拦住两种情况：Run 已 `done` / `waiting` / `parked` 却没运行 `scripts/close-self.sh`（会话空转着不关），以及最后一条回复在问人（纯文本提问，`unattended-ask-guard` 拦不到的那条路）。它注册在 `Stop` 事件上，不是 `PreToolUse`，所以在 `~/.claude/settings.json` 里新增（已有就追加）`hooks.Stop` 数组：

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/unattended-stop-guard.js",
               "timeout": 10
             }
           ]
         }
       ]
     }
   }
   ```

   macOS / Linux 同样换成绝对路径。它和 `unattended-ask-guard` 一样按 transcript 里最后一次 `/implement-spec-split` 调用是否带 `--auto-land` 判定；`UNATTENDED_STOP_GUARD_DISABLE=1` 可临时关闭；详见 [hooks/README.md](../hooks/README.md)。

   **同时注册 subagent-guard**（规格 #26 起）：flash 会话（`FLASH_ORCHESTRATOR=1`）的主线程里，这个 hook 拦住用 Agent 工具开能写代码的子代理——票的实现、fix、冲突解算固定经 `scripts/stage-dispatch.sh` 按「实现」路由派发给 Orca worker，审查走 `scripts/opus-review.sh`，提示词管不住 flash 自己开 `general-purpose` 子代理，所以和「一行源码不写」一样靠 hook 硬拦。只读子代理（`Explore`、`Plan`、`claude-code-guide`）照常放行；非 flash 会话不受影响。在 `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组里**追加**一项（不要覆盖 delegate-guard、unattended-ask-guard、land-push-guard 已有的项）：

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Agent|Task",
           "hooks": [
             {
               "type": "command",
               "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/subagent-guard.js",
               "timeout": 5
             }
           ]
         }
       ]
     }
   }
   ```

   macOS / Linux 同样换成绝对路径。它只在 `FLASH_ORCHESTRATOR=1` 时生效，注册在用户级对官方会话和 claude-glm 没有影响；详见 [hooks/README.md](../hooks/README.md)。

3. 新开一个 Claude Code 会话，hook 和规则才会完整生效。

**hook 的判定规则**

- **普通会话**只按行数拦截 `Edit`、`Write`、`NotebookEdit`；Bash 输入直接放行。
- `FLASH_ORCHESTRATOR=1` 的 flash 会话中，源码 `Edit` / `Write` / `NotebookEdit` 阈值为 0，并拦截 `sed -i`、heredoc 重定向、`>` / `>>`、`tee` 等常见 Bash 源码写入。
- 普通会话放行：扩展名为 `.md .txt .json .jsonc .yaml .yml .toml .ini .cfg .csv` 的文件，以及 `.gitignore`、`.gitattributes`；改动不超过 10 行的源码修改。flash 会话同样放行这些非源码文件。
- 普通会话拒绝：超过 10 行的源码修改（Edit 取 old/new 中较多的行数；Write 取全文行数）。
- 例外开关：`~/.claude/state/allow-direct-edit`，内容是过期时间（ISO 8601 或 epoch 秒），普通会话过期前全部放行；flash 会话不使用它。规则要求只有用户明确授权时才由 Claude 创建。你也可以自己创建：

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
# 1. hook 单元测试：应输出 Summary: 60 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-delegate-guard.js

# 2. land-push-guard 单元测试：应输出 Summary: 27 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-land-push-guard.js

# 3. unattended-stop-guard 单元测试：应输出 Summary: 41 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-unattended-stop-guard.js

# 4. subagent-guard 单元测试：应输出 Summary: 14 passed, 0 failed
node ~/.claude/skills/implement-spec-split/hooks/test-subagent-guard.js

# 5. 冒烟：应输出一段 permissionDecision 为 deny 的 JSON
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

## 阶段 4：flash 模式（便宜主会话）

日常调度不花订阅额度：主会话（Orchestrator）由智谱 `glm-5.3-flash` 驱动，只做白名单内的执行与转述；源码修改和大量阅读由规格会话经 `scripts/stage-dispatch.sh` 按路由表（「实现」「调研起草」）派给 glm-5.4 worker 在各自的工作区里做（规格 #26 起不再用会话内子代理，hook 会拦）；所有结论性判断（审核、根因、取舍、能否落地、是否停车）出会话交给官方订阅的 Opus（[ADR 0001](adr/0001-cheap-orchestrator-default-deny.md)）。本阶段只适配 mini6（macOS）。

**前提**

- 阶段 0（`./install.sh` 已跑，`/grill-feature`、`/grill-map`、`/grill-router` 三个软链就位）和阶段 3（delegate-guard hook）已就绪。
- `claude-glm` 已配好（阶段 2 的 GLM 端点与 API Key）：`claude-flash` 复用它的端点和 `~/ops/state/claude-glm/apikey`，不复制密钥。
- 安装启动器（四件套在 `~/ops/services/claude-flash/`，详见其 README.md）：

  ```bash
  cd ~/ops/services/claude-flash && ./install.sh   # 建 /opt/homebrew/bin/claude-flash 软链
  ```

**开 flash 主会话**

- 终端直接跑 `claude-flash`（它注入 `FLASH_ORCHESTRATOR=1`、flash 专用 settings 和系统提示词：白名单、判断上交 Opus、源码经派发模块交给 worker；排除官方会话的 Opus/codex 分工规则，关闭 codex 插件）。
- 权限模式：启动器给普通会话自动补 `--dangerously-skip-permissions`（已带则不重复），flash 会话一律 bypass。Orca 的 OpenClaude 槽位不会替它加这个参数，缺了会落到 auto mode：无人值守的规格会话可能被分类器拦下，分类器请求走智谱网关还会弹计费通知。
- 挂到 Orca 槽位：把 `/opt/homebrew/bin/openclaude` 软链改指 `~/ops/services/claude-flash/claude-flash`（Orca 设置 → Agents → OpenClaude 的命令覆盖填 `claude-flash` 绝对路径亦可）。此后 Orca 的 OpenClaude 槽位开出的就是 flash 主会话；原 `claude-glm` 会话不受影响，仍可手动使用。
- 冒烟验证：

  ```bash
  claude-flash -p '你是什么模型？只答模型名' --output-format json
  claude-flash -p '用 Bash 输出 $FLASH_ORCHESTRATOR' --allowedTools Bash   # 应输出 1
  ```

**两个设计入口（Design session）**

- `/grill-feature <想法>`：小功能。flash 主会话调 `scripts/design-session.sh` 开出一个 Design session（按「讨论」阶段的路由启动，默认官方 Opus），然后阻塞等待、不耗 token；Orca 会自动切到那个会话，你直接和 Opus 讨论，讨论完它当场做 to-spec、to-tickets、commit、push，写交接摘要后通知 flash 继续并自动切回主会话，flash 读完摘要就在主会话接着跑 `/find-next` 推进模式（起草、发布、启动第 1 波、总控都在这里）。
- `/grill-map <地图或想法>`：大模块（wayfinder 地图）。同上，接上后 find-next 把要拍板的取舍合成一轮按推荐自动拍板（可推翻）、不等回复，接着往下推进；你说"先到这"就提前结束，这时不接 find-next，flash 只转述交接摘要里的地图状态和下一步。
- Design session 的运行目录在 `~/.cache/implement-spec-split/design/<repo>-<时间>-<kind>/`，交接摘要是其中的 `handoff.md`。

**规格会话与 Opus review**

- flash 主会话里跑 `/find-next` 时，launch-wave 用 OpenClaude 槽位（即 flash）开规格会话；票的实现由规格会话经 `scripts/stage-dispatch.sh` 按「实现」路由派成 Orca worker（默认 claude-glm / glm-5.4），一份规格从头跑到尾不占订阅额度。
- flash 规格会话里的代码审核、草稿审读、连续失败诊断不落在会话内（GLM 会话里的 "opus" 子代理实际是 GLM，等于假审核），一律调 `scripts/opus-review.sh` 出会话执行（按「审查」「诊断」阶段的路由，默认官方 Opus）：`--kind code`（审分支/固定点）、`--kind draft`（审规格/票草稿）、`--kind diagnose`（诊断失败、建议续跑/改 Brief/停车）。任何非 0 退出码都停车并说明（含义见脚本头注释），不自动重试、不降级 GLM、不会话内自审。

**阶段路由表：每个阶段用哪个启动器、模型和思考强度（`/grill-router`）**

讨论、调研起草、实现、审查、诊断各用哪个启动器档案、模型和思考强度，由一张全局路由表决定（薄包装技能 `grill-router/`，按上文软链安装；ADR 0004）。编排阶段锁定在 flash，不可改。Opus 没额度时，在任意 Claude Code 会话里敲一条斜杠命令就能把审查、讨论切到 glm-5.4，一条命令可以同时定几个阶段：

```text
/grill-router                                      # 查看六个阶段当前的路由
/grill-router 审查用 glm 5.4，讨论用 glm 5.4          # 一条命令同时定两样
/grill-router 审查切到 glm-5.4 到 明早 7:00             # 只改审查，到点自动回到默认
/grill-router 讨论切到 glm，强度 medium，持续 5 小时       # 只改讨论，连思考强度一起定
/grill-router 审查切回默认                             # 把审查设回默认路由
```

不在会话里时用脚本，效果相同。`use` 后面写一到多个 `阶段=档案/模型/思考强度`，没提到的阶段不动；设回默认路由就是离开表：

```bash
S=~/.claude/skills/implement-spec-split/scripts/stage-route.sh
$S use review=claude-glm/glm-5.4/high design=claude-glm/glm-5.4/medium   # 一次设两样
$S use review=claude-glm/glm-5.4/medium --until 2026-11-28T07:00:00+08:00  # 到点自动回到默认
$S use review=claude-glm/glm-5.4/medium --for 5h                          # 或：从现在起 5 小时（也支持 30m、2d12h）
$S use review=claude/opus/high                                           # 设回默认路由
$S                                                                      # 查看当前状态
$S migrate                                                              # 迁移旧开关里未到期的设置
```

- 六个阶段和默认路由：编排 `claude-flash` / glm-5.3-flash（锁定）；讨论 `claude` / opus / high；调研起草 `codex-glm` / glm-5.4 / high；实现 `claude-glm` / glm-5.4 / high；审查、诊断 `claude` / opus / high。档案 `claude` 是官方订阅的裸 `claude`，`claude-glm`、`claude-flash` 是两个 GLM 启动器，`codex-glm` 是经 `codex-worker.sh` 跑的 codex。不在默认上的那一行会在「切回用 /grill-router use」后面写出它的默认路由，照抄就是切回。
- 哪个脚本读哪一行：`design-session.sh` 读「讨论」；`opus-review.sh --kind code|draft` 读「审查」、`--kind diagnose` 读「诊断」；`codex-worker.sh` 带 `--read-only` 读「调研起草」，否则读「实现」。都是每次派发时读一次，所以**已经在跑的 flash 规格会话和 find-next 会话不用重开**：路由改了以后，正在进行的这一次不受影响，下一次派发才生效。
- 路由表是 `~/.claude/state/stage-route`，对本机所有仓库、所有会话生效。只接受冒烟测试过的（档案、模型）组合，目录外的写法退出码 64、不改表；思考强度可选 low、medium、high、xhigh、max（codex 没有 max）。到期、目录外的组合、文件损坏都自动回到默认并在 stderr 提示。审查和实现被设成同一个模型时警告一次（等于没换模型审查），不拦。
- 审查出会话仍走 `opus-review.sh`，不会变成会话内子代理；切到 glm-5.4 后经 `claude-glm` 执行，stderr 和 findings 文件首行都写明本次路由（阶段、档案、模型、思考强度）。glm-5.4 审 glm-5.4 写的代码不如 Opus，看落地报告时留意这一行。
- Design session 只在**新开**时读「讨论」路由：切过去后 `/grill-feature`、`/grill-map` 开出的是 glm-5.4 会话（Orca 终端里跑对应的启动器，界面 mock 由它自己做，不派 worker），交接和等待流程不变。
- 已经开着的 Opus Design session 换不了模型。要在原对话上接着谈：在那个仓库的终端里运行 `claude-glm --resume`，从列表里选它；交接约定还在原对话里，运行目录和等待也不变。等待超时了，用 stderr 里打印的 `design-session.sh --attach <运行目录>` 续等。
- 不会自动切换：Opus review 报额度错误（退出码 3）照旧按 `quota` 停车，已经停车的规格仍由 keeper 在可恢复时间之后恢复。切不切由你决定。
- **从旧版升级**：旧版装过 `judgment-model`、`worker-model` 两个开关的，删掉 `~/.claude/skills/` 下这两个软链，按上文软链 `grill-router`。第一次运行 `/grill-router`（任何派发脚本第一次读表也一样）会把旧设置里未到期的迁进路由表：思考强度取 high，到期时间照搬；迁不进的（模型不在已验证目录，例如旧 worker 开关的 glm-5.3-flash）保留旧文件并提示。之后只有 `/grill-router migrate` 会再迁一次。

**flash 的边界**

- 白名单内：跑脚本并按退出码分支、读短的结构化输出、照现成文本写票、转述已备好选项的问题、经派发模块（`stage-dispatch.sh dispatch` / `wait` / `release`）启动与收尾 worker、启动会话、跑 Opus review、无冲突合并与 commit、逐条执行 findings。
- 一行源码都不写：阶段 3 的 delegate-guard 在 flash 会话里对源码写入硬拦（阈值 0，`~/.claude/state/allow-direct-edit` 不生效）。
- 每个结论注明出处（派发角色的报告路径——sidecar 里的 `worker_done.report_path`，worker 空闲未报时是主会话核实后写的 `<dispatch dir>/session-verify.md`——或 Opus findings 路径）；拿不准交给谁时默认上交 Opus；push、打 tag、发版先问用户（Design session 推送文档除外）。

**回退**

两仓库都打了书签 tag `pre-flash-orchestrator`，全局配置快照在 `~/.claude/backups/pre-flash-orchestrator-20261120/`：按其中的 ROLLBACK.md 四步回退（技能仓库 checkout tag、~/ops 还原并卸载 claude-flash、`~/.claude/` 配置拷回、Orca 槽位指回 claude-glm）。新行为只在 flash 会话里生效，官方会话和原 `claude-glm` 会话一直可并存。

---

## 更新与回滚

- **更新**：`cd ~/.claude/skills/implement-spec-split && git pull && ./install.sh`（clone 直装形态；软链形态在克隆目录里跑同一条）。`install.sh` 补上仓库新增技能的软链、删掉已退役技能的悬空链、把期望项里新的 tighten 项补上（先备份）；重复运行零修改。模板和脚本立即生效；hook 下次调用即生效。无人值守落地会在每次落地后自动跑它（根 `SKILL.md` 第 9 步），clone 直装的这份会先被快进到新 main，所以平时不用手工更新；快进不了（不在 `main` 或不干净）时落地报告的「要你做的」会写一句 `git pull`。已知限制：clone 直装形态下如果别处还有一份主 checkout（落地流程从那份主 checkout 跑 `install.sh`），`~/.claude/skills/implement-spec-split` 这个真实目录每次都会报一条 WARN「是真实目录不是软链，未动…另一份 clone？确认后改名或删除」，`install.sh` 因此每次落地都退出 1、落地报告的「要你做的」每次挂这一条，重复运行清不掉——属预期，不影响已经完成的落地；要它消失，按提示把这份 clone 改名或删除（改用软链形态）后重跑 `./install.sh`。
- **分工规则更新**：仓库里的 `templates/global-claude-md.md` 改了之后，需要手动同步到 `~/.claude/CLAUDE.md`（全局文件不在仓库管理范围内）。
- **升级到阶段路由表**：旧版装过 `judgment-model`、`worker-model` 两个开关的，`./install.sh` 会删掉 `~/.claude/skills/` 下这两个悬空软链、软链 `grill-router`；第一次运行 `/grill-router` 会迁移旧设置（见阶段 4）。
- **暂停分工**：从 `settings.json` 删掉 delegate-guard 那一项，并从 CLAUDE.md 删掉分工一节。之后 `install.sh` 不再对它有期望（hook 没注册不算漂移），只是阶段 4 用不了。
- **换机器**：要搬三样东西：克隆本仓库并运行 `./install.sh`（阶段 0）、`~/.codex/config.toml` 与代理（阶段 2）、CLAUDE.md 分工一节和 `settings.json` 的 hook 注册（阶段 3）。只克隆仓库不够。

## 自检

`scripts/doctor.sh` 自身的检查只读取本机配置，不修改配置文件。它按"基础、阶段 1、阶段 2、阶段 3"报告当前状态，其中「基础」组的「本机安装状态」一项调 `install.sh --check --json`（同样只读）：技能链缺 / 指错 / 悬空记 WARN，tighten 期望项未满足记 FAIL，这两种的提示是「运行 install.sh（落地时会自动运行）」；提示不全是这一句——脚本不替人做的，提示写明要手工做：另一份 clone 的真实目录（确认后改名或删除）、Windows 的建链（`install.sh --check` 打印的 `mklink /J` 步骤）、放宽项（需要的话手工改，安装脚本不放宽配置），其余是「在技能目录里运行 bash install.sh --check 看详情」。阶段 3 自己的检查（如 matcher 缺 `Bash`）报 FAIL 时给的也是手工改法，不是「运行 install.sh」。各状态的含义：

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
| 规格运行中途因额度 / 429 停车 | 有 worker 撞上限流；降低 `--parallel`，或换到闲时 |
