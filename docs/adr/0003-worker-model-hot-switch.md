# Worker model 可由用户全局热切换（独立开关，v1 只管 codex 路径）

ADR 0002 给了判断模型一个用户开关；Worker model（GLOSSARY.md：External worker 的 harness 对话的模型）没有对等开关，由「哪条路径在干活」决定：`--impl codex` 的 Run 照 SKILL.md 显式传 `--model glm-5.4`；find-next 的 codex worker 和全局分工（阶段 3）里的日常派活不传 `--model`，用 `codex-worker.sh` 的默认值；`config.toml` 的 `model` 对 worker 不起作用，因为 wrapper 永远显式传 `-m`（MAINTAINING.md 第 27 条踩过这个坑）。所以只改脚本默认值对正在跑的 Run 无效，而「正在跑的 Run 下一次派发就换模型」正是要做的事。热切换只能在出口脚本里做：会话内子代理的型号在启动器 `exec` 时由环境变量钉死，flash 会话更是 `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` 强制 glm-5.4，任何状态文件都切不动它——这是 ADR 0002 让出口脚本每次调用时读开关的根据，也是它否决「会话内映射」的先例。用户定（2026-11-27）：给 Worker model 一个与 `/judgment-model` 同构、但独立的开关。`scripts/worker-model.sh`，状态文件 `~/.claude/state/worker-model`（`worker=<model>`、`worker.until=<epoch 秒>`），薄技能 `/worker-model`（`disable-model-invocation: true`，只能由用户敲：会话看到额度或 429 错误时可能自己调用它把模型降了）。允许值 `glm-5.4`（默认）`glm-5.3` `glm-5.3-flash`，可带 `--until` / `--for` 到期回默认，`use glm-5.4` 即复位。`codex-worker.sh` 每次新起 worker（fresh run）时读它：开关非默认就压过 `--model`，否则用显式 `--model`，否则用默认；Resume 不读开关，沿用第一段保存的模型。覆盖范围一刀切：所有 `codex-worker.sh` 调用。v1 只管 codex 路径。默认值只在 `worker-model.sh` 定义一次，wrapper 和 selftest 用 `--print default` 向它要。

## Considered Options

- **`--model` 压过开关**：否决。SKILL.md 让会话照抄 `--model glm-5.4`，已开着的 Run 和 find-next 总控会话全切不动，而热切换正是做这件事的理由。代价换成开关生效期间显式 `--model` 失效，靠 stderr 一行、运行目录的 `stderr.log`、`status.json.model` 和落地报告兜底；selftest 用 `ISS_WORKER_MODEL_FILE` 隔离。
- **只改默认值、不热**：否决。约 15 行就能做，但旧会话继续传 `--model glm-5.4`，切不动；也没有到期。
- **并入 `judgment-model.sh` 当第三角色**：否决。概念拉伸：Judgment model 的定义是「代替 Opus」，Worker model 是被代替的一方，默认值、允许值、到期回退的目标都不同。要改 13 处 `opus` 字面量和约 12 处「两个角色」的文档，回归面压在刚上线的 ADR 0002 上。
- **让开关管 agent 后端**：否决。flash 子代理的型号由启动器的 `models.env` 钉死（`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`），唯一杠杆是改 `~/ops` 下的文件且只对新会话生效；别名到型号的映射由启动器环境变量决定，开关存不下具体型号；让 flash Run 改派 External worker 违背 ADR 0001 的三档分工；动的是 `~/ops` 另一套规范；只靠提示词没有硬拦。
- **抽 `lib-switch.sh`**（与 `judgment-model.sh` 约 150 行近似代码）：首版不抽。抽了要改 `judgment-model.sh`，回归面又压回 ADR 0002。记在这里免得下一个人顺手去抽。
- **`--force-model`、`ISS_WORKER_MODEL` 环境变量覆盖、`pi-worker.sh` 接开关、只管实现角色或分 `impl`·`read` 两角色、flash 等实证再进允许值、沿用 `coder-model` 命名**：否决。`--force-model` 让会话绕开用户的开关，与 ADR 0002「会话不许自己换模型，是脚本按用户的开关执行」相悖；环境变量覆盖同义且更隐蔽；pi 的型号是 `glm/glm-5.4` 这种 provider/id 格式，本机 pi 也不可用；wrapper 层分不开「编码」与「阅读」，find-next 的调研、决策、起草 worker 都不传 `--model`，要分就得再加角色或反转优先级，后者牺牲 `--impl codex` Run 的热切换；flash 先进允许值，`use` 对不在 worker 目录的型号只警告不拦截，L1 实证与目录条目是落地后用户的环境步骤；`coder-model` 不是 GLOSSARY 的术语（_Avoid_: implement model, backend model）。
- **两个开关同时非默认时停车或硬拦**：否决，代价见 Consequences 第二条。

## Consequences

- **flash 与 ADR 0001 的证据有张力，要点名。** ADR 0001 Considered Options 第 1 条的原话：「flash 容易过度自信，小判断出错会在后续波次放大，省下的钱不够抵返工」（[ADR 0001](0001-cheap-orchestrator-default-deny.md)，MAINTAINING.md 的 flash 设计要点）。那条否决的是 flash 编排会话自己做判断；这里是 flash 当 External worker 写代码，判断仍归 review。但 flash 写代码 → fix 轮数上升（上限 3）→ Opus review 次数上升，而 Opus 额度正是 ADR 0002 的起因。review 若也切到 glm-5.4，就是 **flash 写、glm-5.4 审、无人值守自动拍板**，张力落到下一条。
- **两个开关同时非默认时，无人值守 Run 照常自动落地，这是决定不是遗漏。** 两个开关各自是用户的明确决定（ADR 0002：「开关是用户的明确决定，不是系统自己降级」）。B（落地前停车，类别 `decision`）会在最需要它起作用的额度枯竭期把通宵批次全部停下，正违背 ADR 0002 和 MAINTAINING.md 第 29 条「可自动采纳的不停车」，还要多一处停车规则和 keeper 通知。C（脚本层拒绝「flash 写 + 非 Opus 审」）在 Opus 没额度时直接没得跑，且把两件独立的事耦死。可见性靠落地报告、停车报告（`### 现状` 下）和最终报告同时写两个开关的状态。
- **一刀切**：读多判断少的活（调研、起草）也降档；flash 的 1M 上下文是试验值，find-next 带 `--mcp all` 的调研 worker 上下文压力最大；规格和票的草稿质量只靠主会话或 Opus review 兜底。
- **环境未就绪就切 flash**：在用户做完 flash 的 L1 与目录项之前，每个 codex Run 两次失败后停车，一整批无人值守规格可能全停。
- **中途切换没有预检**：step 0 的 L1 只覆盖切换之后新开的 Run。开关在派发时读取（`acquire_worker_slot` 之前），排队中的 worker 保留派发时的型号，复位后仍会按旧型号起跑一次。
- **软约束**：`disable-model-invocation` 挡的是 Skill 工具，会话仍可经 Bash 跑 `scripts/worker-model.sh use …`；`hooks/` 里没有任何 judgment-model 相关拦截。与 ADR 0002 一样是软约束。
- **`worker-model.sh --print` 是每次 fresh run 的硬依赖**：脚本坏了所有 codex 派发退出 64（Resume 不受影响）。有意选择：宁可停车，不带空 `-m` 启动 codex。`--print`、`--print default` 输出为空时的两处防御没有可测手段，不加测试钩子。
- mini6 无人值守的默认路径（flash + agent 后端）不受影响；train3060（agent 后端，不调 `codex-worker.sh`）上开关惰性，那边不装 `/worker-model`。
- 旧会话传的 `--model` 被静默覆盖，只有 stderr、`stderr.log`、`status.json.model`、落地报告可查。
- 两个斜杠命令；与 `judgment-model.sh` 约 150 行近似重复。调研报告提的「`/judgment-model` 技能识别编码说法时转调」首版不做。
- **flash 的 L1**：先裸测 `scripts/selftest-codex.sh --only L1 --model glm-5.3-flash`；失败且报错指向型号或目录时，在 `~/.codex/models.json` 补条目并重跑 `scripts/setup-worker-home.sh` 再测。实际走了哪个分支、结果补一行到 `docs/codex-backend.md` 的实验表（现为 E17，未验证）。分支 1 裸测通过时，`model_reasoning_effort = "high"` 是否被接受、1M 上下文是否可用，记为**未验证**：L1 只证明端点接受该型号。
