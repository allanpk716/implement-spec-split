---
status: accepted
supersedes: ADR-0002, ADR-0003
---

# 阶段路由表 + Orca 执行层：3+1 个入口，每个阶段可全局热切换启动档案、模型和思考强度

用户定（2026-11-27）：主线是 flash 主会话（Orca 的 `openclaude` 槽位）敲 grill 或 find-next 命令，然后各流程用各自的会话和模型推进；目标是确定性的工作流，每个阶段能单独指定模型，并能全局热切换。ADR 0002、0003 只覆盖了审查、讨论和 codex 路径，默认路径（flash 会话 + 会话内子代理实现）上的写代码阶段两个开关都管不到；两个开关各有一个命令、一个状态文件和约 150 行近似代码。决定：

- **入口只有 3+1 个**：`/grill-feature`、`/grill-map`、`/find-next` 三个工作命令，加一个设置命令 `/grill-router`。`/judgment-model`、`/worker-model` 删除，不留别名（`/grill-router` 首次运行迁移旧状态文件里没到期的设置）。`implement-spec-split` 只由 find-next 在内部拉起，不再是用户命令。`/grill-feature` 讨论完、规格发布后自动接 find-next；`/grill-map` 同样自动接，find-next 会停在合成提问那一步。（2026-11-28 注：find-next 不再停在合成提问那一步——拍板轮每条按 worker 的推荐自动拍板（可推翻）、没有推荐的按可逆性规则自选，拍完不等回复，留给用户的只有需要本人身份、凭据、物理动作或主观反应的条目（规格 #58 票 #69，MAINTAINING 第 59 条）；两个入口自动接过去的照旧是推进模式。）
- **六个 Stage，一张 Stage route 表**（GLOSSARY.md）：编排、讨论、调研起草、实现、审查、诊断，每项为（Launcher profile, 模型, 思考强度, 可选到期）。下一次派发或下一次新会话生效，不中途换。编排在 v1 锁定为 flash。只接受跑过冒烟测试的组合；审查与实现同模型时当场警告一次，不拦。默认表见 Consequences。
- **执行方式由阶段固定，用户只选档案**：编排、讨论、实现由 Orca orchestration 托管（交互式 worker，生命周期交给 Orca）；调研起草、审查、诊断是 headless（`claude -p` / `codex exec`），保留退出码和只读违规检查的契约。（2026-11-28 注，票 #84：审查、诊断在路由是 GLM 且会话子代理被强制到路由模型时（flash 会话的设置）改在会话内开只读 Explore 子代理，不再另起无头进程；官方路由照旧 headless。在哪跑由 `scripts/opus-review.sh --where` 从路由表和会话环境确定性地给出，会话只按输出分支；会话内 findings 由 `--stamp` 写同一路径、同一首行格式，另标「（强度未生效）」「（会话内子代理）」。见 MAINTAINING 第 24 条的日期注。）
- **Launcher profile 由本项目维护，不用 Orca agent id**：Orca 不能注册自定义 agent（stablyai/orca#2284），`openclaude` 槽位不接受 `--model`。GLM 启动器走「`orca terminal create --command "<launcher> --model … --effort …"` + `worker-start --terminal`」收编（`docs/orca-smoke-2026-11-27.md` 实测通过，含嵌套 worktree）。
- **工作区是三层树**：主会话 → 规格（`new-child`）→ 票（`new-child`，`--base-branch spec-<n>`），侧栏可折叠；票合入后、规格落地后释放并删除工作区，停车的保留。`progress-tab.sh` 退役。merger 改为脚本，冲突才起 worker。（2026-11-28 注：实现是两层都走 `orca worktree create --parent-worktree path:<父工作区>` 建子工作区，不用 `new-child`——它没有 `--branch`、默认名字不满足集成分支必须是 `spec-<n>`，见 MAINTAINING 第 45 条；票那一层带 `--base-branch spec-<n>` 照旧。）
- **规格会话入口靠脚本验证结果**：`worker-start` 把 Orca 的 preamble 放在 spec 前，`/implement-spec-split N` 由模型自己调用 Skill（实测 flash 会照做，但不是机制保证）。`launch-wave` 在限定时间内检查认领记录是否出现；没出现时先读终端，确认没开始（如 prompt 还没提交）才停掉、`--retry-of` 重派一次，看到在动就延长等待，判断不了就停车（社区实测「已投递」不等于已开始、启动可慢到 13 分钟，沉默时盲目重派会把副作用做两遍）。（2026-11-28 注：认领判据是认领记录里的 pid 非空——会话执行认领后才算已启动，只有预留记录（`pid: null`）不算，规格 #26 US19。）
- **flash 主会话及其拉起的流程里，五个非编排阶段一律经路由表派发**，会话内用 Agent 工具做实现或审查由 hook 拦。CC 原生订阅会话保持现状（会话内子代理照用），只有经 `codex-worker.sh` 派出的 worker 受路由表影响：带 `--read-only` 读「调研起草」，否则读「实现」。（2026-11-28 注：规格 #26 票 #45 起，CC 原生订阅会话的实现阶段同样经派发模块（`stage-dispatch.sh`）走 Orca worker，不再用会话内子代理；只有第 7 步审查保留会话内子代理（`mattpocock-skills:code-review`），规格 US13 说的「会话内子代理不受影响」指的是 hook 不拦，不是实现仍可交给它。）（2026-11-28 注，票 #84：审查这一半重开一半——审查路由是 GLM 且会话子代理强制同模型时，flash 会话可以开只读的 Explore 子代理做审查（hook 本来就放行只读子代理，`opus-review.sh --where` 说了才会话内）；实现仍拦，官方路由的审查仍出会话。）

## Considered Options

- **只换生命周期底座、模型分工不动**（调研稿 `20261127_1027_…Orca换底座方案.md` 的方案）：否决。它保留「`--impl agent` 会话内子代理不动」，而会话内子代理没有出口脚本，实现阶段永远切不了，与用户的核心诉求冲突。生命周期换底座的部分保留，作为本 ADR 的执行层。
- **路由表直接写 Orca agent id**：否决，见上文 #2284 与 `openclaude` 不支持 `--model`。Orca 以后支持自定义 agent 时只改档案，表不动。
- **审查、诊断也改成 Orca worker**：否决。`worker-start` 只起 TUI，没有 per-dispatch 工具白名单、没有退出码；无人值守会自动采纳审查结论，额度停车和失败必须分得清。
- **保留两个旧开关当别名**：否决，用户要入口少。
- **原生会话也强制走路由表并拦子代理**：先同意后撤回。原生会话是用户在场的手动场景，保持现状。（2026-11-28 注：规格 #26 票 #45 起部分重开——原生会话的实现阶段也经派发模块，与 flash 会话同一条路；拦截没有重开，原生会话的子代理仍不由 hook 拦。）
- **票的实现 worker 在规格工作区里开终端标签**：否决，用户不要一堆标签；改为嵌套子工作区。
- **规格会话入口改回 `worktree create --prompt`（命令行展开，确定）**：否决，那样拿不到 Orca 的 worker 生命周期；改用脚本检查认领记录。

## Consequences

- 默认路由（与上线前实际行为一致，只有实现阶段换了执行方式）：编排 claude-flash（锁定）；讨论 claude / opus / high；调研起草 codex-glm / glm-5.4 / high；实现 claude-glm / glm-5.4 / high；审查 claude / opus / high；诊断同审查。
- **实现和 fix 用 `--bare`**：实测同一极小任务 18.6K → 1.2K input tokens。`--bare` 不加载 CLAUDE.md、技能、插件和 hooks，规则改由 `--append-system-prompt-file` 注入一份精简规则，需要的 MCP 用 `--mcp-config` 加。实现 worker 身上原来靠 hook 的硬拦降为提示词，由合入前的脚本门（新提交、工作区干净、测试通过）和审查兜底。`--bare` 在 TUI + 收编下是否可用是规格的第一个验证项。
- 每层会话只带上一层的产物：规格 issue → 票的 Brief（含规格开始前一次 headless 探索写下的相关文件和调用关系），不带上一层的过程。
- 走收编路线时 Orca 的 Dispatch 不记模型（`launch.effective.model` 为 null），模型由派发脚本写进落地报告、停车报告和最终报告，三份报告都打印完整路由表，并读 worker 终端状态行核对实际模型，与路由表不符时警告、不拦。
- Orca 的 orchestration 标 Experimental，API 两周十余次变更：所有 Orca 调用收敛到一个 `lib-orca.sh`。派发必须显式 `--run`，否则 Orca 按继承的终端环境认定协调者，消息会投到错误的会话（实测踩到）。`lib-orca.sh` 不缓存终端 handle（stablyai/orca#9163，handle 会漂移）、脚本里不用不带 `--peek` 的 `check`（会取走协调会话的消息；例外是消费自己 Run 邮件的协调者——design-session 等 handoff、`stage-dispatch.sh wait` 等票的 worker_done——见 `lib-orca.sh` Rule 4）、不轮询。
- `orca worktree rm` 删父工作区会把子工作区变孤儿：清理顺序必须先票后规格。`new-child` 默认保留工作区，`worker-release` 不删工作区，脚本要显式删除，并带 `--delete-branch`（新版默认留分支）；另有定期清理扫掉无主的遗弃工作区（社区有攒到 173GB 的实例）。
- 主会话或协调终端关闭不影响下层；新终端 `orca orchestration run-use --id <run>` 接管。keeper.sh 与 Orca 心跳并行一段时间再定去留：判活以 `worker-list` 的 liveness 为第一证据、mtime 为第二证据；「确认失败」与「无法确认」分开，无法确认的不自动重派（Orca 官方不许凭 `unverifiable` 自动恢复）。
- 自定义 agent 官方已明确不做任意 CLI（stablyai/orca#14952 closed not planned），启动档案是长期方案；PR #47662（基于已安装 agent 的自定义 agent）合入后可把档案迁过去，路由表不动。
- 社区调研（`20261127_1354_社区如何用Orca做多Agent工作流_调研.md`）确认整体形状是主流，路由表、嵌套工作区、合并互斥、全天判活四点社区没有成体系的做法；`whutlichao/orchestra-auto` 与本项目同构但用平级工作区，只借鉴其把关与收尾规则，不整体采用。版本号、CHANGELOG 这类共享计数器在并行票间的冲突不在本 ADR 范围，单独记票（2026-11-28 注：单独记票 = #24；Resolution 后 B 方向由 #62 承接，A 方向由 #52 承接）（2026-11-28 注：订正上注——「A 方向由 #52 承接」已随 #52 作为规格 #61 的重复关闭而失效：A 方向由规格 #61 承接，执行票 #73/#74；B 方向 = 规格 #62，执行票 #51）。
- `pi-worker.sh` 退役；`codex-worker.sh` 保留为 headless 执行器。
- ADR 0001 的「会话不许自己换模型」仍成立：换模型只能是用户经 `/grill-router` 改表，脚本执行。`/grill-router` 是 `disable-model-invocation`，与旧开关一样是软约束。
