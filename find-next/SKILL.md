---
name: find-next
description: 默认进入推进模式：循环扫描当前 GitHub 仓库的 wayfinder 地图与票，自动调查并关闭可关的 research 票、为决策票准备选项、推进没讨论完的地图（迷雾毕业、task/prototype 票）、分流地图外散票（等待时机 / 开地图 / 单个决策 / 直接起草规格 / 重复或过时）、批量起草规格和执行票，把所有需要人拍板的问题合成一轮，答完后自动发布并启动第 1 波 implement-spec-split 会话；规格合入 main 后可由 implement-spec-split 调 --next-wave 自动开下一波。--suggest 保留原先只推荐一个下一步的只读行为；--list 列出待办清单；--batch 是推进模式别名。用户问"下一步做什么""推进仓库""该推哪张票""哪个该 to-spec / to-tickets / grill 了""还有什么没做完""给我待办清单""批量写规格 / 批量拆票""接下来开发哪几份规格""开发顺序"，或输入 /find-next 时使用。参数 --suggest、--list、--batch、--workers N（可选）、--specs K、--worker codex|self|agent、--agent-model sonnet|opus|haiku|fable（仅 agent）、--no-auto-land（本批不做无人值守落地；默认无人值守，适合通宵运行）、--auto-land（兼容别名，等同默认）、--watch（只进入总控：汇报各规格落地进度、集中问停车规格要拍板的事、全部完成时给总结；推进模式收尾后也自动进入）。用户问"进度怎样""盯着开发""总控"时也用 --watch。
---

# find-next

默认在当前仓库进入**推进模式**：把 wayfinder 地图（包括还有 Map fog 的地图）、规格、散票和开发尽可能推进到可开发状态，只在真正需要人拍板时把所有问题合成一轮。`--suggest` 才是原先的只读建议模式，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Map fog、Fog graduation、Loose ticket triage、Waiting on timing、Next step、推进模式）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。

对跟踪器的写操作只允许出现在推进模式：按用户答案为调研票/决策票/task 票/散票写 Resolution、关票、更新地图；迷雾毕业后建票、接阻塞、改地图；散票分流同意后建地图和子票、接 sub-issue 与阻塞、评论并关原散票；发布草稿时新建规格票和执行票；启动规格前写领取记录。`--suggest` 和 `--list` 恒为只读。

## 用法

- `/find-next [--workers N] [--specs K] [--worker codex|agent] [--agent-model <model>] [--no-auto-land] [地图号、实现票号或规格号…]`：默认推进模式（见「推进模式」），也是地图、规格、票、开发的通用入口。它循环执行：扫描 → 自动调查/关闭 research 票 → 准备决策题 / 迷雾毕业建议 / task 清单 / prototype 反应题 / 散票分流建议 → 起草规格和执行票 → 有问题就一轮问用户 → 应用答案并再扫描 → 发布 → 启动第 1 波。起草、调研、决策准备、迷雾毕业、散票分流、task 和 prototype 交给 worker：不给 `--worker` 或给 `codex` 时照旧派 codex worker；`agent` 时改由主会话开 Agent 子代理执行这些步骤（`model` 显式传 `--agent-model`，默认 `sonnet`）。只支持 GitHub 跟踪器；本地 markdown 跟踪器请用 `--suggest` 或 `--list`
- `/find-next --suggest [--worker codex|self|agent] [--agent-model <model>]`：原先的默认行为，只读挑一个 Next step（见「建议模式流程」）；未给 `--worker` 时等同于 `codex`。支持 GitHub 和本地 markdown 跟踪器
- `/find-next --list`：不挑一个，列出当前仓库的全部待办清单（见「清单模式」）。总是我自己做，不派 worker，`--worker` 被忽略
- `/find-next --batch …`：推进模式别名，兼容旧用法
- `/find-next --watch`：只进入**总控**（见「总控」一节），不推进、不起草；推进模式第 11 步收尾后自动进入同一节。grill-feature / grill-map 启动规格后，本仓库没有总控在跑时也走这里
- `--workers N` 可选，是全机 GLM worker 总数；每份规格的 `--parallel` = N ÷ K（至少 1）。没给时读 `~/.cache/implement-spec-split/max-workers`（`scripts/max-workers.sh` 用的同一文件）；文件也没有就把 worker 上限并入本轮最后一个问题问用户。`--specs K` 是同时开几份规格，默认 2。**同一仓库同一时间只在一个会话里运行推进模式**：推进模式全程持仓库级 `find-next-advance` 锁（见「推进模式」第 1 步），第二个会话会被拦下；持锁会话被意外关闭后锁自动失效
- `--agent-model <sonnet|opus|haiku|fable>` 只在 `--worker agent` 时有效，默认 `sonnet`；给了 `--worker codex`/`self`（或不给 `--worker`）却给 `--agent-model` 是参数冲突，报错让用户改。一个开关管全程：`--worker agent` 决定本技能自己的调研/决策/起草方式，不提供混搭；生成的开发命令不带后端参数（实现走路由表）。
- **无人值守落地**（GLOSSARY.md）默认开启：本批规格（含之后自动开的波次）不停下问人；审查（按「审查」路由跑）的 findings 里带推荐、标「可自动采纳：是」的取舍按推荐落地并记为「自动拍板（可推翻）」，只有真要人决定的事才停车。落地、部分落地、停车都在规格 issue 下留报告，由本会话的总控汇总给用户。`--no-auto-land` 只在推进模式有效，用来让本批保留 push 前确认：第 10 步把它透传给 launch-wave.sh，`--apply` 会把 `auto_land: false` 写进启动状态，`--next-wave` 沿用；`--auto-land` 保留为兼容别名，等同默认。

只扫当前仓库，不跨仓库汇总。

## 阶段与优先级

候选按阶段排序，越靠近交付越靠前；同一阶段内，按下面写的规则排序：

1. **该 to-tickets**：存在 spec 产物，但没有任何票的 `## Parent` 指向它。spec 产物有两种：
   - spec 票：正文含 `Problem Statement` 或 `User Stories` 节，`Triage: ready-for-agent`
   - Closing ticket：已关闭的 task 票，它把一章写进了 `SPEC.md`（标题常为「SPEC 增补/改写…章」）

   地图 Destination 写了「可直接 `/to-tickets`」，算佐证信号。→ `/to-tickets <spec 票或 SPEC 章名>`
2. **该 to-spec**：→ `/to-spec`
   - 本地跟踪器：地图的 Destination 是 spec 或某个章节，Map frontier 已空（子票全部 closed，或只剩 Closing ticket 而且它的阻塞都已关闭），Map fog 为空（`scan.py` 的 `has_fog` 为 `false`），并且还没有产出（`SPEC.md` 没有这一章，也没有 spec 票指回这张地图）
   - GitHub：地图下有还没被任何 Spec 覆盖的 Map ticket（`pipeline-status.sh` 的 `missing` 段），或决策票全关、Map fog 为空、还没有 Spec 指回的地图（`mapSpecs` 段）。开着或已关闭的 Spec 都算覆盖；实现票只认 Spec 正文里的 `实现票：#N` 行（分隔符必须是冒号或「为」「是」，正文叙述里的「（实现票 #N）」不算），地图只认 `地图：#N`、`来源地图：#N` 等指回行。判断实现票候选时先用 `gh issue list --state all --search "#N in:title"` 查一下，有没有标题带 `(#N)` 却漏写这一行的 Spec，有就不是候选，并在输出里提醒用户补这一行、关掉这张实现票
   - 部分就绪：前沿没清空，但已关闭的决策足以撑起一个可独立交付的竖切。排在完全就绪之后，并标注「还剩 X、Y 没关」
3. **Map frontier 里的 Decision ticket**：open、阻塞全部已关闭、无 Assignee。按解锁的下游票数排序，数量相同时编号小的优先。
   - 在地图里的票 → `/wayfinder <地图> <票名>`（wayfinder 会认领、写 Resolution、关票、更新地图）
   - 不在任何地图里的散票：正文带「时机：」的标「等待时机：<条件>」，不推荐为 Next step，也不代判断条件是否满足；其他散票推荐 `/find-next <票号>` 推进模式分流（开地图 / 单个决策 / 直接起草规格 / 关票），`/grill-with-docs <票>` 保留为手动选项
   - research 票同样推荐 `/wayfinder`；按用户的全局规则，调研交给 codex worker

   flash 模式下，本阶段的 `/wayfinder`、`/grill-with-docs` 推荐按「flash 模式」一节替换。

4. **地图迷雾待毕业**：地图决策票全关但 `## Not yet specified` 还有实质内容（GitHub 的 `fogMaps` 段，本地 `scan.py` 的 `fog_maps` 候选）。→ `/find-next --batch <地图号>`

跳过：Notes、标题或状态行里标了「搁置」的地图和票；搁置执行票不算待实现，只剩搁置执行票的规格也不算可以实现。

**不做**：建议模式不推荐「执行票已拆、可以开工」这一阶段（`/implement-spec-split`），`--list` 会列出但不作为 Next step，开发顺序由推进模式给出；不跨仓库汇总。

## 建议模式流程（`--suggest`）

1. 读 `docs/agents/issue-tracker.md`，确认跟踪器形态。
2. **机械扫描**（本地 markdown 跟踪器，也就是 `tracker/map*.md` + `tracker/tickets/NN-*.md`）：

   ```bash
   python3 -I <本技能目录>/scripts/scan.py --tracker <仓库>/tracker
   ```

   GitHub 跟踪器改跑 `~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh`，各段对应关系：`needsTickets` → 阶段 1，`missing` → 阶段 2，`exploring` → 阶段 3（这一段只列出地图，具体是哪张 Decision ticket，再用 `gh` 查那张地图的 Map frontier），`fogMaps` → 阶段 4，`implement` 不用；`--all` 的 `loose` 带 `fromMap` / `timing`，供散票判断使用。

   输出 JSON：每张票的票头、阻塞（含仍 open 的阻塞）、所属地图、Parent 引用与被引用、是否含 spec 正文、下游解锁数；每张地图的成员票、前沿与 `has_fog`；以及按阶段 1–4 粗筛的候选（含 `fog_maps`）。脚本只做确定性规则。
3. **判断**：确认候选能否成立（目的地是否达成、是否搁置、`SPEC.md` 里有没有这一章、候选算不算 spec 正文、散票的时机条件是否由用户明示已满足），按优先级挑出一个；带 `timing` 的散票只作为「等待时机」信息呈现，不成为候选。
   - `--worker self`：我自己读脚本输出，针对性地看几处地图 Notes、票正文和 `SPEC.md` 标题（`grep -n '^#' SPEC.md`）。
   - `--worker codex`：建运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-find-next/`，把 `scan.py` 的输出存成其中的 `scan.json`，再用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`，后台运行：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/brief.md \
       --run-dir <运行目录> --read-only --time-limit 1200 --idle-timeout 600
     ```

     结束后只读 `status.json`、`result.md`（worker 的最终回复，≤15 行结论），结论是 to-spec 或 to-tickets 时再读 `digest.md`。
   - `--worker agent`（仅非 flash 会话）：照旧建同一个运行目录、存 `scan.json`/`scan.txt`、用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`；但不运行 codex-worker.sh，而是开一个 Agent 子代理，`model` 显式传 `--agent-model` 的值（默认 `sonnet`），prompt 固定为：「读 <运行目录>/brief.md 并照做，把最终报告写到 <运行目录>/result.md，同时作为你的最终回复」。Brief 里「wrapper 会把最终回复存成 result.md，不要自己写」这类话是对 codex worker 说的，agent 模式下以 prompt 为准：子代理自己写 `result.md`。结束后照旧读 `result.md`（结论是 to-spec 或 to-tickets 时再读 `digest.md`）；没有 `status.json`，以子代理的返回为准。
   - worker 出错时按全局 CLAUDE.md 的处理表：`auth` / `quota` / `transient` → 告诉用户，问他们是等一会儿，还是 `--worker self`，**不自动降级**；`stalled` / `error` → 把失败原因补进 Brief，换新运行目录重跑一次；`violation` → 报告作废，把 `changed_paths` 交给用户。`agent` 子代理没有 `status.json`：返回为空或明确报错时，把失败原因补进 Brief、换新运行目录重派一次，再失败就停下报告；不自动改用 codex 或 self。
   - **阶段路由**：本技能所有 `codex-worker.sh` 调用（判断、调研、决策票、任务票、散票分流、批量起草）的模型和思考强度取自阶段路由表（`scripts/stage-route.sh`，GLOSSARY「Stage route」，ADR 0004）：带 `--read-only` 的读「调研起草」（research），其余读「实现」（implementation），两者默认都是 glm-5.4 / high；命令里不传 `--model`。wrapper 每次派发时读表：阶段路由非默认时压过显式参数，在 stderr 报一行并写进运行目录的 `stderr.log`；`status.json` 的 `model`、`thinking`、`profile` 记实际用的模型、思考强度和档案。worker 因型号不可用而失败、或预检（`scripts/selftest-codex.sh --only L1`）失败时，报告里点名 `status.json.model`、路由当前值（运行 `scripts/stage-route.sh` 查看）和复位命令（该阶段那一行「切回用」后面那串，如 `/grill-router use implementation=claude-glm/glm-5.4/high`）；不要自己改路由表。
4. **交接**：结论是 to-spec 或 to-tickets 时，那两个技能只能综合当前对话，所以要先把材料放进上下文。`self` 模式读地图和已关闭票的 Resolution；worker 模式读 `digest.md`。然后用几句话讲清要点，提示用户敲命令。结论是决策票或地图迷雾待毕业时，只报名字和命令；迷雾地图的命令是 `/find-next --batch <地图号>`。其他散票提示推进模式会分流；时机票只提示条件，用户明确说「开 #N」才继续。

   flash 模式下，本步要推荐的讨论入口按「flash 模式」一节替换。

## 清单模式（`--list`）

用户要「全貌」而不是「下一步」时用。对跟踪器同样只读。

1. **机械扫描**：
   - 先运行 `~/.claude/skills/implement-spec-split/scripts/completion-report.sh <仓库>`（不带 `--spec`），它的「完成度结论」原样放在清单最上面；脚本非 0 时在同样位置写一行「完成度结论（查询失败）」，不阻塞清单。
   - GitHub：`~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --all`。除默认段外还列出：「地图仍在探索」每张地图开着的决策票；「空地图（待 /wayfinder 画图）」（open、未搁置、没有子票的 `wayfinder:map`）；「认领后不动（>3 天）」（open、有 Assignee、`updated_at` 早于 3 天的 `wayfinder:*` 决策票）；「认领但没有活会话」（认领不到 3 天，但 Orca 里本仓库没有提到这张票的活 agent 会话；Orca 不可用时写「（Orca 不可用，未判断）」）；「状态没收尾」（规格已关闭但执行票还开着、实现票只被已关闭的规格覆盖、规格未关执行票全是搁置票）；「规格已落地、源票未关」（开着的散票，编号出现在某份已关闭规格的 `实现票：` 行上——它是那份规格的源票，落地时漏关了；推进模式第 4 步直接补关）；「散票」（不属于任何地图或规格、也没有被任何规格的 `实现票：` 行引用的 open issue，带标签、来源地图和时机）。「地图迷雾待毕业」在默认输出和 `--all` 都有。「可以实现」会排除未关执行票全是搁置票的规格；混合规格的搁置票带 `(搁置)` 后缀。
   - GitHub 另跑 `~/.claude/skills/implement-spec-split/scripts/grill-status.sh`，按 grill 题目列出每次 Design session 的规格与票完成数（中断的标「中断（无 handoff）」）。
   - 本地 markdown 跟踪器：`scan.py` 的 JSON 已含全部票、每张地图的 `has_fog`、`fog_maps` 候选和成员关系；按下面的分组自己归类。open、未搁置且 `members` 为空的地图归「空地图」。本地票头没有可信更新时间，不推断「认领后不动」，该组写「（本地跟踪器无 updated_at，不判断）」。
2. **轻量判断**（我自己做，只看标题和标签，必要时 `gh issue view` 一两张）：
   - 散票里标题相近、描述同一现象的，标「疑似重复」；带 `timing` 的标「等待时机：<条件>」，不推断条件是否满足。
   - 「缺规格」里明显依赖别的票的（比如 Web UI 票依赖还在实现的后端规格、整体验收册票依赖所有功能），注明「等 #N」。
   - 「正在实现」的每份规格（GitHub）：`gh issue view <n> --comments` 只看最后一条评论是否为落地报告或 `## 停车报告`；`git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:relative)' 'refs/heads/spec-<n>-t*'` 看正在做的票分支及最近提交时间（票号取分支名 `t` 后的数字）。脚本里的「0/5」只数已关闭的票，正在做的票靠这一步补上。
   - 不逐张读正文，不派 worker；脚本输出就是清单主体。
3. **输出**，按分组列出，空的组写「（无）」：

```
待办清单 · <仓库名> · <日期>

完成度结论
<completion-report.sh 的输出原样放这里；脚本失败写「（查询失败）」>

按 grill 题目的进度
■ <题目>（<日期> feature|map）<进行中 / 已完成 / 中断>
  - #349 规格名：票 1/5 已关，正在做 #352（最近提交 12 分钟前）／停车：<一句原因>
（grill-status.sh 输出为空时写「（本仓库没有 Design session 记录）」）

A. 正在实现 / 可以实现（搁置票不算待实现）
- #212 规格名 0/9 已接手（分支 spec-212） → /implement-spec-split 212
B. 有规格、未拆票 → /to-tickets
C. 缺规格 → /to-spec（按地图分组）
D. 待讨论的决策票 → /wayfinder <地图> <票>
E. 地图迷雾待毕业 → /find-next --batch <地图>
F. 认领后不动（>3 天）/ 认领但没有活会话 → /find-next --batch
G. 空地图（待 /wayfinder 画图）
H. 状态没收尾（核对后关票 / 只剩搁置票可关规格，由用户确认）/ 规格已落地、源票未关（下次 /find-next --batch 直接补关）
I. 散票（bug / needs-triage 等；含等待时机、疑似重复和推进模式分流提示）

要你做的
- 现在：停车报告、待拍板的决策票（D 组）、中断的 grill（重新开 /grill-feature 或 /grill-map）、状态没收尾（H 组；其中「规格已落地、源票未关」跑一次 `/find-next --batch` 就自动补关）
- 自动进行中（不用管）：正在实现且未停车的规格，写出结果会出现在规格 issue 的落地报告
- 以后：按顶部完成度结论决定是否发版、发版后会解冻什么（handoff 里有上线顺序时照抄），及其他带触发条件的待办
空的段写「（无）」。

建议先做：<一两句，按「阶段与优先级」挑出的那一个>
```

   称呼票时写「#编号 标题」。清单最后给出单个 Next step 的结论，口径与建议模式一致。

   flash 模式下，本模板里的 `/wayfinder` 推荐按「flash 模式」一节替换。
4. 仓库里另有自由格式的 backlog 文档（如 `docs/backlog.md`）时，不机械解析，只在末尾提醒一句「另有 backlog 文档未纳入，建议把仍有效的条目迁成 issue」。

## 推进模式（默认；`--batch` 是别名）

用途：把用户从「逐张判断、逐个技能、逐轮确认」里解放出来。主会话只保留必须跨全批做的判断：分组、审稿、把关 Resolution、判断 `--apart`；读长材料和写长文都交给 worker——默认（不给 `--worker` 或给 `codex`）是新的 codex worker；`--worker agent` 时（仅非 flash 会话）是主会话开的 Agent 子代理（`model` 显式传 `--agent-model`，默认 `sonnet`）。每一轮尽可能自动推进，只有真正的取舍题才问用户，而且所有问题合成一轮。

flash 模式下，本节所有原本由主会话审读或复核的结论都按「flash 模式」一节交给按路由跑的审查（review）。

`--worker agent` 时的同构做法（适用于本节所有原本派 codex-worker.sh 的步骤；仅非 flash 会话，flash 模式下这些步骤照旧派 codex worker，见「flash 模式」一节的「worker 后端」）：照旧建运行目录和子目录、照旧写 `brief.md`，然后开一个 Agent 子代理，`model` 显式传 `--agent-model` 的值，prompt 固定为：「读 <该子目录>/brief.md 并照做，把最终报告写到 <该子目录>/result.md，同时作为你的最终回复」。Brief 里「wrapper 会把最终回复存成 result.md，不要自己写」这类话是对 codex worker 说的，agent 模式下以 prompt 为准：子代理自己写 `result.md`。没有 `status.json`，主会话以子代理的返回和 `result.md` 为准；失败时把原因补进 Brief、换新运行目录重派一次，再失败就停下报告，不自动改用 codex 或 self。

**子代理空闲却没交最终报告**（票 #79）：`--worker agent` 的子代理留下「测试在后台跑，跑完再报」之类的话、结束回合返回时，没有机制会再唤醒它，后台任务结束也没人来报——主会话不等这份报告，自己核实，按证据判定完成或失败并收尾，不无限等待。核实在前台做：`ps` 看它留下的进程还在不在（`ps -axo pid,etime,time,command`；还在跑的后台任务不是进展——它的回合已经结束，没人会去读结果——结束它）；看它该交的产物在不在、全不全（`result.md`，以及 Brief 要求的 `resolution.md`、草稿）；它会改仓库时（task、prototype）再看分支最近提交时间和工作区状态（`git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:relative)' 'refs/heads/<分支>'`、`git status --porcelain`）。产物齐全、该提交的已提交，就当作它交了报告，照常复核；产物缺失或没提交，按失败处理——把原因补进 Brief、换新运行目录重派一次，再失败就停下报告。

**主会话不内联包裹多行脚本**（票 #80）：不得用 `bash -c`、`sh -c`、`$'…'` 把多行脚本包进一条 Bash 命令，脚本里有没有 `rm` 都一样——禁的是包裹形态本身：bypass 模式（`--dangerously-skip-permissions`）下权限层照样会对它弹确认框，脚本里没有删除命令时也被误判过，无人值守的会话没人回答就卡死。必须多行的脚本写进 `mktemp -d` 目录下的脚本文件执行，脚本里配 `trap` 清理它自己的 `mktemp -d` 目录；除此之外的删除一律单独 `rm` 带字面路径；或把活拆成多次独立的 Bash 调用。各 Brief 模板的「环境约束（找文件与子进程）」一节写着 worker 侧的同一条约束。

**Brief 卫生**：往 Brief 里引用仓库外的文件（调研文档、别处的笔记、`~/ops` 下的脚本这类）前，先用系统索引（macOS 的 `mdfind`）或 `ls` 定位到确切路径并确认存在再写；定位不到就在 Brief 里明写「未定位到，不作为依据」，不给模糊路径让 worker 自行全盘搜索。各 Brief 模板的「环境约束（找文件与子进程）」一节是 worker 侧的对应约束。

推进模式只支持 GitHub 跟踪器。先读 `docs/agents/issue-tracker.md`；发现本地 markdown 跟踪器时，说明推进模式不支持，改按 `--suggest` 或 `--list` 执行。**同一仓库同一时间只在一个会话里运行推进模式**，由第 1 步的 `find-next-advance` 锁保证。

下文 `run-state.sh` 指 `<本技能目录>/scripts/run-state.sh`。进入第 2、3、4、5、6、9、10 步时各运行一次 `run-state.sh step <运行目录> <步骤号>`，会话被意外关闭后下次能看出停在哪一步。

1. **拿锁、接续上次中断的推进、扫描**：
   1. 在仓库根运行 `~/.claude/skills/implement-spec-split/scripts/lock.sh acquire find-next-advance --scope repo --wait 0`。退出码非 0 就停止推进模式：用 `lock.sh status find-next-advance --scope repo` 告诉用户持锁会话的 pid 和开始时间，建议等它结束或改用 `--list`；不拿锁的 `--suggest`、`--list` 不受影响。持锁会话已死时 `acquire` 会自动接管，不用人工清理。
   2. 建运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-find-next-advance/`，立即运行 `run-state.sh init <运行目录> --repo <owner/name> --repo-path <仓库根>`。
   3. 运行 `run-state.sh pending --repo <owner/name> --repo-path <仓库根>`，列出本仓库没收尾的旧推进运行（原会话已死的新版运行；没有状态文件、7 天内、内容指向本仓库的旧版运行）。输出「（无）」就跳到第 4 小步。有就把这段输出原样放在本轮第一条输出里，再加 `--json` 取结构化数据，然后不问用户，逐个处理：
      - 票级产出（research/decision/fog/task/loose/prototype 且 `has_result`）：`gh issue view <N> --json state,updatedAt`。票仍 open，且 `updatedAt` 早于 `result_mtime`，就**复用**：把旧子目录（多次尝试取有 `result.md` 的那个）复制到本次运行目录下的同名子目录 `<类型>-<N>/`（复制，不移动），后面的步骤视为这张票的 worker 已经跑完，直接进入复核，不再派 worker。否则作废，按正常流程重派。
      - 规格组 `S<k>`：`published.exists` 且不完整的，在**旧运行目录**里重跑 `publish-batch.sh --apply --no-order <旧目录>/S*/manifest.json` 接着发（脚本支持中途失败后重跑）；有 `spec.md`/`manifest.json` 但完全没发布的，若对应实现票/地图仍满足起草条件，复制进本次运行目录，作为第 5 步的草稿，按 5.4 重新审稿后再用，不重新起草；只有 brief 或 note 的作废。
      - 处理完一个旧运行就 `run-state.sh abandon <旧目录>`。
      - 复用、作废、接着发布的结果都记下来，放进第 11 步收尾报告的「接续上次中断的推进」一段。
   4. **扫描**：

      ```bash
      ~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --all
      ```

      保存为运行目录下的 `scan-<轮次>.txt`。带地图号、实现票号或规格号时，只推进参数指向的范围；不带时处理全仓库。

2. **research 票（自动，不问用户）**：从「地图仍在探索」每张地图的前沿里找出 open、阻塞全关、无 Assignee、标签为 `wayfinder:research` 的票。pipeline 输出已标注「有未关阻塞」「已认领」；漏信息时用 `gh issue view <n> --json assignees,labels` 和 tracker 文档的 blocker 查询补齐。每张票一个子目录 `research-<票号>/`，用 [templates/brief-research.md](templates/brief-research.md) 填 Brief，后台运行：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/research-<票号>/brief.md \
     --run-dir <运行目录>/research-<票号> --read-only --mcp all --time-limit 2400 --idle-timeout 600
   ```

   `--worker agent` 时不运行上面的命令：照旧建 `research-<票号>/`、写同样的 `brief.md`，改按本节开头的同构做法开只读的 Agent 子代理（`model` = `--agent-model`），prompt 指向 `<运行目录>/research-<票号>/brief.md` 与 `result.md`。

   我审读 `result.md` 和 `resolution.md`：事实有出处、没有把推断写成决定、Resolution 和地图索引行符合 wayfinder 格式。通过后按 tracker 文档写票：在票下发 Resolution 评论、关票、把一行 gist 追加到地图 `## Decisions so far`（保留其他段落和已有顺序）。小语病我直接改；材料不足就换新运行目录重派一次。**结论里出现需要取舍的问题时不关票**，把它改写成一条决策题，并入本轮第 6 步；已有的调研事实仍留在草稿里供用户参考。

   flash 模式下，本段审读和后续写票动作按「flash 模式」一节并入当轮审查（review）。

3. **决策、迷雾、task 与 prototype 票（worker 准备，一轮问用户）**：research 票全部处置完后重新运行 `pipeline-status.sh --all`，看最新前沿、`fogMaps`、`emptyMaps`、`staleClaims`（「认领后不动（>3 天）」）和 `orphanClaims`（「认领但没有活会话」：认领不到 3 天，但 Orca 里本仓库各 worktree 没有标题或屏幕内容提到 `#N` 的活 agent 会话，多半是认领它的会话被意外关闭了）。
   - **决策票**：open、阻塞全关、无 Assignee、标签为 `wayfinder:grilling` 的票每张派一个只读 worker，子目录 `decision-<票号>/`，用 [templates/brief-decision.md](templates/brief-decision.md)。worker 读票、地图、相关 ADR、规格和代码，产出问题陈述、2–4 个选项及代价、推荐答案和理由，写在 `decision.md`；不写票、不关票、不改地图。命令同上（含 `--mcp all`）；`--worker agent` 时同样按本节开头的同构做法开子代理，prompt 指向 `<运行目录>/decision-<票号>/brief.md` 与 `result.md`。worker 判断「无需用户决策」（已有 ADR/地图决定）时，我复核依据，仍把它作为一条「建议直接关：<依据>」放进第 6 步那一轮，用户同意后再写 Resolution、关票：grilling 是 HITL，wayfinder 规定代理不能替人回答。
   - **地图迷雾**：扫描到 `fogMaps` 时，每张地图派一个只读 worker，子目录 `fog-<地图号>/`，用 [templates/brief-fog.md](templates/brief-fog.md)。worker 读地图、`Decisions so far` 和相关 Resolution，写 `fog.md`：建议新建的票（问题、`wayfinder:` 类型、阻塞对象）、应从 `Not yet specified` 移除的段落、建议判出范围或作废的票（附理由）、毕业后仍剩下的迷雾。这些变成第 6 步的「建议新建 / 建议判出范围」条目；未获用户同意前，主会话不改地图边界。
     地图迷雾的 codex 命令同决策票（含 `--mcp all`）。
   - **task 票**：前沿里 open、阻塞全关、无 Assignee、标签为 `wayfinder:task` 的票每张派一个 worker，子目录 `task-<票号>/`，用 [templates/brief-task.md](templates/brief-task.md)。这个 worker **不是只读**，但只能改 Brief 明确写出的范围。能独自完成（AFK）的做掉并写 Resolution 草稿；需要人做的写精确清单。我复核结果同 research：事实有出处、没有越界，清晰 AFK 结果直接写 Resolution、关票、更新地图；人工清单放进第 6 步那一轮。
   - **prototype 票**：前沿里 open、阻塞全关、无 Assignee、标签为 `wayfinder:prototype` 的票，单次运行最多处理 2 张；每张一个 worker，子目录 `prototype-<票号>/`，用 [templates/brief-prototype.md](templates/brief-prototype.md)。UI 原型按 mockit 技能做独立页面，由我复核后提交 mockit；非 UI 原型放在 `prototype/<票号>` 临时分支上，worker 本地提交但不得 push，我复核后 push 该分支，不开 PR、永不合并，推进模式下不单独确认。随后把可访问链接 / 分支链接和一句要反应的问题放进第 6 步那一轮，用户表态后再写 Resolution。第 3 张及以后的 prototype 票留到第 11 步收尾列出。

   flash 模式下，本步骤决策选项、迷雾/task/prototype 建议和「我复核」依据都按「flash 模式」一节并入当轮审查（review）。

   writable worker 的命令去掉 `--read-only`：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/task-<票号>/brief.md \
     --run-dir <运行目录>/task-<票号> --time-limit 2400 --idle-timeout 600
   ```

   task / prototype 需要操作远程服务器时，给上面的 codex 命令传 `--mcp ssh-manager`。
   `--worker agent` 时所有新 worker 都按本节开头的同构做法开子代理；task / prototype 子代理同样只能执行 Brief 写明的范围。

4. **散票分流（worker 只读给建议；等待时机直接写回票面）**：处理「散票」段里 open、未搁置且不带 `wontfix` 的票；bug、needs-triage 等都进入。带地图号/实现票号/规格号参数时，只有参数直接指向某张散票才处理它；来源地图或相关规格的编号不自动带入散票。
   - **「规格已落地、源票未关」段的票**：这些散票的编号出现在某份已关闭规格的 `实现票：` 行上，是那份规格的源票；规格落地时本该随 `实现票：` 行一起关掉（implement-spec-split 第 9 步），漏了才出现在这里。它们不再进「散票」段、不派 worker、不问用户，由我直接补关：`gh issue close <票号> --comment "规格 #<规格号> 已关闭，本票是它的源票（\`实现票：\` 行），随之关闭。"`；同一票列了多份规格时照抄全部编号。关掉后下一轮扫描不再出现。
   - **正文带 `timing` 的票**：默认「等待时机」，不派 worker、不提问、不自行判断条件是否满足。汇报单列「等待时机」段（#号、标题、条件），并提示「要现在开就回『开 #N』」。
   - **其他散票**：每张派一个只读 worker，子目录 `loose-<票号>/`，用 [templates/brief-loose.md](templates/brief-loose.md)。worker 读票、评论、`fromMap` 指向的地图、相关规格/ADR/代码和 wayfinder 规则，输出五选一：**该开地图**（`map-draft.md` 写标题、Destination、首批 research/决策票标题与一句话、Not yet specified 迷雾、阻塞关系）、**单个决策**（问题、2–4 个选项及代价、推荐答案）、**直接起草规格**（票面已写清要做什么、验收标准在哪，不需要地图或决策；`triage.md` 的「起草说明」指出票面哪几节、哪条评论写了要求，为什么不需要地图或决策）、**重复或过时**（被哪张票/哪次提交覆盖的依据）、**等待时机**（正文无时机行但依据显示现在不该开，写条件）。命令同决策票：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/loose-<票号>/brief.md \
       --run-dir <运行目录>/loose-<票号> --read-only --mcp all --time-limit 2400 --idle-timeout 600
     ```

     `--worker agent` 时同样按本节开头的同构做法开只读 Agent 子代理，prompt 指向 `<运行目录>/loose-<票号>/brief.md` 与 `result.md`。
   - 我复核 `triage.md` 及分类附件：依据必须指向真实 issue/评论/提交/文件；地图草案符合 wayfinder 格式且不扩大原票边界；决策题仍是 HITL；「直接起草规格」的起草说明确实指向票面写清的要求和验收标准，没有把要 owner 拍板的取舍混进来（混进来的改按单个决策处理：重派或并入第 6 步）。worker 判定的「等待时机」不提问，但复核通过后由主会话直接写回票面（这是记录已得出的结论，不需要用户同意）：正文首行插入 `时机：<条件>`（保留原正文其余部分；已有时机行则替换它），去掉 `needs-triage` 标签，并评论一条「分流记录（<日期> find-next 推进器）」：分类、依据、条件、「要提前开工回『开 #N』」。这样下次扫描会识别时机行，不再重复派 worker 分流。「直接起草规格」同样不提问：复核通过即按第 5.1 步成组、进第 5 步起草，未决项随该组 `unresolved` 进第 6 步。该开地图、单个决策、重复或过时三类仍按第 6 步问用户后处理。

   flash 模式下，本段复核和分类建议按「flash 模式」一节并入当轮审查（review），「等待时机」的写回动作也照该节执行。

5. **起草规格/执行票**：沿用下面 5.1–5.4（对应原批量模式第 2–4 步）。此轮没有可起草组就跳过。

   flash 模式下，地图组能否进入起草先按「flash 模式」一节检查 Resolution 门槛。
   1. **分组（我做）**：取「缺规格」「地图缺规格」和「有规格、未拆票」三段；所在地图仍在探索、且决策票会影响这张实现票的，不进起草，在输出里说明还差哪张决策票。「地图迷雾待毕业」和「空地图」不进起草。看标题，必要时 `gh issue view` 实现票正文，把同一地图里紧密相关的实现票合成一份规格，其余一张一份；每份已有规格单独成组（`S<k>=spec:<规格号>`，只拆票；正文「实现票：」「地图：/来源地图：」两行都没有的已有规格是手写规格，`make-batch-briefs.sh` 照样生成不含地图指引的 Brief，并在 stderr 提示一行）；每张已收口且无迷雾的地图单独成组（`S<k>=map:<地图号>`）；第 4 步判为「直接起草规格」的散票也成组（`S<k>=loose:<票号>`，默认一张一组，紧密相关的几张可合在一组），和地图实现票组放进同一批起草，`make-batch-briefs.sh` 按组形态选用 `brief-loose-spec-batch.md`，要求 `spec.md` 首行写 `实现票：#<源票>`、不写 `地图：` 行。源票发布后保持 open，规格落地时由 implement-spec-split 第 9 步随 `实现票：` 行关闭，漏关的由第 4 步「规格已落地、源票未关」段兜底。一份规格是一个可独立交付、可独立验收的竖切；明显串行依赖的单独成组，靠阻塞关系衔接。
   2. **生成 Brief**：运行目录下每组 `S<k>/`，不手写，用脚本生成：

      ```bash
      <本技能目录>/scripts/make-batch-briefs.sh [--example <已有规格号>] [--note S2=<补充说明文件>] [--force] <运行目录> S1=62 S2=63,64 S3=spec:224 S4=map:41 S5=loose:51
      ```

      某组需要额外提示时写成小文件用 `--note` 传入。仓库已有规格时传 `--example`；一份都没有可不传。`--force` 只在确定要在已有运行目录重新生成 Brief 时用：它会整文件覆盖已存在的 `brief.md`。
   3. **worker 并行起草**：按脚本打印的命令后台运行，最多 3 个同时，组更多分批：

      ```bash
      ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/S<k>/brief.md \
        --run-dir <运行目录>/S<k> --read-only --time-limit 2400 --idle-timeout 600
      ```

      `--worker agent` 时不运行上面的命令：照旧用脚本生成各组的 `S<k>/brief.md`，改按本节开头的同构做法开 Agent 子代理（`model` = `--agent-model`），prompt 指向 `<运行目录>/S<k>/brief.md` 与 `result.md`；同样最多 3 个同时，组更多分批。

      草稿只在运行目录，不在仓库内。不能调用 `/to-spec`、`/to-tickets` 本身；worker 直接读最新上游技能规则。

      flash 模式下，起草结果出现未决地图条目时按「flash 模式」一节改推荐 `/grill-map`。
   4. **审稿（我做）**：读 `result.md`、`manifest.json`、`spec.md` 和执行票正文，检查实现决定都有出处且出处确实这么定了；`实现票：` 行正确——地图组 `实现票：`、`地图：` 两行都有，散票组只有 `实现票：#<源票>` 一行、没有 `地图：` 行（散票组的出处要指向源票正文或 owner 评论）；源票没有混进执行票；执行票是竖切、阻塞合理、碰同一计数器的票已串行并带 `shared-counter` 标签、跨组阻塞对得上；`blocked_by` 不挂还没有规格的实现票，该交接的写进 `handoffs`；`unresolved` 只留真正要用户拍板的事，每条带推荐答案；标题格式与仓库一致。用 `publish-batch.sh <全部 manifest.json>` 试运行核对计划。小问题直接改；大问题换新 Brief 重派那一组。

      flash 模式下，本段审稿按「flash 模式」一节并入当轮审查（review）。

6. **一轮问用户（没有问题就跳过）**：把第 3 步决策题、迷雾毕业建议、task 人工清单、prototype 反应题、`staleClaims` 与 `orphanClaims` 处理题（后者问「#N 认领了但 Orca 里没有活会话在处理，取消认领并纳入推进吗？」）、第 2 步转来的取舍题、第 4 步散票分流建议、第 5 步每组 `unresolved`、缺少的全机 worker 上限，合成一条手机友好的消息。编号全批连续（a、b、c…），每组只给一两行摘要和必要上下文，选项各占一行；最后一个问题可以是「全机 GLM worker 总数用 N 吗？」。**无人值守落地**（GLOSSARY.md）不再提问：launch-wave.sh 默认带 `--auto-land`，本批规格（含之后自动开的波次）会不停下问人；调用时带了 `--no-auto-land` 才保留 push 前确认，第 10 步原样透传。**单次运行累计最多问用户 3 轮**；第 3 轮结束后不再发起第 4 轮，剩余待拍板事项留到收尾，下次 `/find-next --batch` 接着推。结尾写：

   flash 模式下，本步只直接转述选择题；「展开」处理见「flash 模式」一节。

   ```
   推进器 · <仓库名> · 需要拍板 <N> 条

   a. #<票号> <票名>：<问题一两句>
      A. <选项> — <代价>
      B. <选项> — <代价>
      建议 A：<理由>
   b. 地图 #<地图号> <地图名> 迷雾毕业：<建议新建 / 建议判出范围的一行摘要> → 建议：<采纳/修改>
   c. #<票号> <task 票名>：<需要人做的一步> → 建议：<动作>
   d. #<票号> <prototype 票名>：<原型链接；要用户反应的一句>
   e. #<票号> <已认领票名>：取消认领并纳入本次推进吗？→ 建议：<是/否>
   f. S1 <规格标题>：<未决问题> → 建议：<推荐答案>
   g. #<散票号> <散票名>：为它建地图？Destination：<一句>；首批：<票标题摘要> → 建议：<是/否>
   h. #<散票号> <散票名>：<单个决策问题；可用与决策票相同的选项格式>
   i. #<散票号> <散票名>：建议关：<重复/过时依据一句>
   ...
   ```

   「等待时机」不占拍板编号、不提问，单独列在问题后（第 4 步写回票面的票也要在这里可见）：

   ```
   等待时机（不提问）：
   - #<票号> <票名>：<条件>；要现在开就回「开 #<票号>」
   ```

   条件是人要做的动作（发版、实机验证等）时，把它归入最终收尾顶部完成度结论的「👉 要你做」/「发版后会解冻」，不要只写成被动等待。

   ```
   请回复「都同意」，或指出要改哪几条（例如：a 选 B、f 再想想、worker 用 6）。
   也可以回「展开 <条目>」就地讨论；回「先到这」立即收尾。
   ```

   用户对某条回「展开」时，当前会话就地对那张票调用 grilling 和 domain-modeling 技能，写完 Resolution 后继续推进，不要求另开 `/wayfinder`；单个决策类散票同样可「展开」。没有任何要问的，直接做第 8 步的复查扫描。

   flash 模式下，「展开」条目改开 Design session，见「flash 模式」一节。

7. **应用答案、迷雾毕业与散票分流**：用户同意的决策票/取舍题，把答案写进 Resolution 评论、关票、更新地图 Decisions so far；「展开」条目按第 6 步的 grilling + domain-modeling 结果同样收票。task 票按用户完成的人工步骤或确认过的 AFK 结果写 Resolution、关票、更新地图；prototype 按用户反应写 Resolution、关票并链接原型资产。`staleClaims`、`orphanClaims` 只有用户同意才取消认领；取消后它按前沿规则进入后续扫描，不自动视为已处理。草稿未决按原批量规则处理：对应草稿去掉「（待确认）」，出处写「（owner <日期> 推进器确认）」，清空该组 `unresolved`；小改动我直接改草稿，大改动重派该组；用户说「再想想」的那张票或那组草稿不发布、不再追问，保留给 `/wayfinder` 或后续推进。用户给出的 worker 数在启动时传给 `launch-wave.sh`，由脚本写入全机 worker 上限文件。

   flash 模式下，用户「再想想」后的地图入口按「flash 模式」一节改推荐 `/grill-map`。

   用户同意迷雾毕业建议后，按 wayfinder 规则**先建新票**（每张票正文一个精确 Question、带正确的 `wayfinder:<type>` 标签、挂到地图下），**第二遍**再接阻塞并写真实编号的交叉引用；然后改地图：毕业的段落从 `Not yet specified` 删除，只留在新票里；建议判出范围的票关掉，并在 `Out of scope` 写一行原因和链接；建议作废的票按 wayfinder 规则关闭或改正，说明依据。未获同意的雾留在原段，不代删。用户回「先到这」时立即进入收尾，不再应用未确认事项。

   用户同意为散票建地图后，我按 wayfinder 地图格式建 `wayfinder:map` 票（正文含 `Destination`、`Decisions so far`、`Not yet specified`，并写「来源散票：#N」），按草案建子票、接 sub-issue 与阻塞。默认在原散票下评论指向新地图后关闭它；若草案明确说明「把原散票挂为子票并改成该地图首张 decision/research 票」更好，才采用该方案。单个决策同意后写 Resolution、关票；重复或过时同意后评论依据并关票。「直接起草规格」的散票没有要应用的答案：它的规格草稿已随第 5 步审稿，发布后源票不动（见第 5.1 步）。用户对等待时机票回「开 #N」时，先把正文首行的时机行去掉（保留其余正文、按第 4 步的记录方式留评说明提前开工），再视为它进入第 4 步的 worker 分流，下一轮呈现结果；回「再想想」则不动、不再追问。

8. **再扫描**：第 7 步关票可能解锁新的 research/决策/task/prototype 票，或让某张地图决策票全关；此时若 Map fog 仍非空，它会出现在 `fogMaps` 而不是 `mapSpecs`。新建的散票地图也进入同一轮扫描，按地图规则继续推进（research 自动、决策出题、迷雾毕业）。重新运行 `pipeline-status.sh --all`：有新可自动处理的对象就回到第 2 步；新 `fogMaps` 按第 3 步派迷雾 worker；新对象带来新取舍时，只把新增问题问一轮，并继续遵守单次 3 轮上限；扫描不再出现新对象就往下走。若某张票反复生成同一未决问题、或用户明确说再想想，终止这条分支并在收尾说明阻塞点，不循环追问。

   flash 模式下，本步新产生的审读材料按「flash 模式」一节重新合成一轮审查（review）。

9. **发布**：没有 `unresolved` 的组直接发布，**不再确认**（owner 2026-11-14 定）。有问题但用户已答的组在应用答案后发布；用户说再想想的组不发布。发布用：

   ```bash
   <本技能目录>/scripts/publish-batch.sh --apply --no-order [--only S1,S3] <运行目录>/S*/manifest.json
   ```

   脚本建规格票和执行票、挂子票、加阻塞、回填占位符、写交接留言，并记录 `published.json`；中途失败修好后重跑，不手工补。核对失败就把缺项报给用户并停止。

10. **开发顺序与启动（每次都做）**：发布完或不需要发布时，先运行：

   ```bash
   <本技能目录>/scripts/launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart 224:239 …] [--no-auto-land]
   ```

   排序由 `pipeline-status.sh --order` 确定性计算：被依赖的先做 → 解锁下游多的先做 → 编号小的先做；完全被挡住的不进第 1 波；进行中的不排；中断的标「先恢复」；搁置执行票不算待实现，未关执行票全是搁置票的规格不进顺序或波次。我只补「改同一块代码」或「都改同一计数器」的 `--apart A:B` 判断，依据规格正文里的模块和起草 worker 在 `result.md` 里的共享计数器提示；拿不准不传。有 `--apart` 时按重跑后的结果为准。`--apply` 会把本次 workers/specs/apart 和这一波的 Orca Run 写入 `~/.cache/implement-spec-split/launch/<owner>__<name>.json`，供合入后的 `--next-wave` 复用；开发顺序本身每次重算。没给 `--workers` 时脚本按第 6 步得到的答案传入；第 6 步也没问（已有 max-workers 文件）就不传，让脚本读状态文件或 max-workers 文件。

   默认无人值守落地：试运行和 `--apply` 不带参数时每条命令末尾带 `--auto-land`，`--apply` 把 `auto_land: true` 写进启动状态，`--next-wave` 沿用；显式 `--no-auto-land` 时命令不带它，状态写 `auto_land: false`，`--next-wave` 也沿用它（旧状态文件没有该字段时按开启处理）。`--auto-land` 仍可接受，等同默认。命令里不再有实现后端参数：规格会话按路由表「编排」项经 Orca 托管启动，票的实现按路由表「实现」项派发，都不在这里选。

   **原样转述试运行输出，不加解释**，不问用户，紧接着用同样参数加 `--apply` 再运行一次。唯一例外：出现「循环依赖」时不加 `--apply`，问用户怎么定。另需单独提醒一行：表里写「另需 #N」的规格要另开会话处理那张票。`--apply` 会写全机 worker 上限、预留规格、为这一波建一个 Orca Run（打印 run id），在 Orca 里把规格工作区挂在主工作区下并经 Orca 托管启动 `/implement-spec-split <n> --auto-land --parallel <P>`；会话认领（claim 记录里出现 pid）后才报「已启动」，没认领的先读终端再决定重派一次或停车。`#<n> 停车：…` 和紧跟的「重新启动：…」原样转述给用户；「需手动」条目按脚本输出提醒。认领等待可能超过 30 分钟：每份规格先等 `ISS_CLAIM_WAIT`（默认 900 秒），终端在动就延长到预留到期（默认 1800 秒），`worker-start` 自己还另有最长 900 秒等会话接收 spec；超过前台 Bash 上限时按后台任务的写法运行（`run_in_background: true`），拿到输出再转述。合入后的自动下一波见 implement-spec-split 根技能第 9 步。

11. **收尾**：先运行 `~/.claude/skills/implement-spec-split/scripts/completion-report.sh <仓库>`（不带 `--spec`），把输出原样放在收尾报告最上面（脚本非 0 时写「完成度结论（查询失败）」），下面才是本轮做了什么；第 1 步接续过旧推进运行时，先写一段「接续上次中断的推进」（复用了哪些票的产出、作废重派了哪些、在旧目录接着发布了哪些规格）。原样转述启动结果，列出已启动、跳过、失败和需手动的规格。列出 `emptyMaps`（若有），逐张提示「用 `/wayfinder <地图号>` 画图」，不代画、不建第一批票。单列「等待时机」（#号、标题、条件、要现在开就回「开 #N」；条件是人要做的动作时已在顶部完成度结论里给出对应动作）、未结案的散票分流建议、本轮按「规格已落地、源票未关」补关的源票，以及从散票起草的规格（源票号 → 规格组）。列出因单次 2 张上限未处理的 prototype 票、因 3 轮问询上限或「先到这」留下的待拍板事项，提示下次运行 `/find-next --batch` 接着推。不要让用户 `/clear` 或去看 GitHub：本会话接着做总控。最后运行 `run-state.sh finish <运行目录>`，再 `lock.sh release find-next-advance --scope repo`，然后进入「总控」一节（本轮启动了规格、或仓库里还有开着的规格时；都没有就到此结束）。

   flash 模式下，空地图提示按「flash 模式」一节改推荐 `/grill-map`。

## 总控（`--watch`；推进模式收尾后自动进入）

用途：用户只看这一个会话。规格会话做完就自己关掉（implement-spec-split 第 10 步），落地进度、要拍板的事、全部完成，都在这里说。

1. **拿锁**：仓库根运行 `~/.claude/skills/implement-spec-split/scripts/lock.sh acquire find-next-supervise --scope repo --wait 0`。非 0 说明已有活的总控会话：用 `lock.sh status find-next-supervise --scope repo` 告诉用户它的 pid 和开始时间，到此结束。
2. **挂监控**：状态文件固定为 `~/.cache/implement-spec-split/supervise/<owner>__<name>.json`。Bash `run_in_background: true`、`timeout` 7200000 运行：

   ```bash
   <本技能目录>/scripts/watch-specs.sh --repo <owner/name> --repo-path <仓库根> \
     --state ~/.cache/implement-spec-split/supervise/<owner>__<name>.json --interval 300 --max 6600
   ```

   这个脚本只读、不唤醒会话，有事件才退出。不要另外轮询、不要 sleep、不要用 ScheduleWakeup。
3. **收到通知就处理**，先立即重新挂上第 2 步的监控（处理期间的变化不会丢，下次退出时一起报），再按事件行处理：
   - 退出码 2（到 `--max` 无事件）：只重新挂，不对用户说话。
   - `LANDED` / `PARTIAL`：读该评论（`gh api` 取 url 对应评论正文），给用户一行：`✅ #<n> <标题> 已落地（票 a/b）` 或 `◐ #<n> 部分落地，剩 <票> 等 #<规格>，依赖落地后自动接着做`；评论里有 `### 自动拍板（可推翻）` 时逐条一行列出，末尾写「要推翻就回『推翻 #<n> <条目>』」。然后运行一次 `launch-wave.sh --repo <owner/name> --next-wave --apply` 补开下一波（规格会话自己也会开；脚本持锁、预留认领，重复调用无害），有新启动的规格时一行转述。
   - `PARKED`：读该停车报告的 `### 需要你决定`，按推进模式第 6 步的问题轮格式问用户（编号 a、b…，选项各一行，建议照抄）；同时停车的多份合成一轮。用户回答后，把答案写成规格 issue 的评论 `## 拍板`（逐条「<条目>：选 <X>（owner <日期> 总控）」），再运行 `launch-wave.sh --repo <owner/name> --only <n> --apply` 让规格接着做（中断的规格由它恢复），一行转述结果。用户说「先放着」就不动，下次总结里仍列出。
   - `DIED`（会话没留报告就没了）：运行一次 `launch-wave.sh --repo <owner/name> --only <n> --apply` 恢复，并告诉用户一行；同一规格第二次 `DIED` 不再自动恢复，作为要拍板事项问用户。
   - `STARTED` / `NEW_SPEC`：不单独说话，合进下一次给用户的进度行。
   - 每次对用户说话都以 `SUMMARY` 行带一行总进度：`进度：已落地 x · 进行中 y · 等依赖 z · 待你拍板 w`。
   - `ALL_DONE`：运行 `~/.claude/skills/implement-spec-split/scripts/completion-report.sh <仓库>`，原样放在最上面，下面列本次总控期间落地的规格、全部自动拍板条目、仍需人做的票（如 `ready-for-human` 的上线票）。然后 `lock.sh release find-next-supervise --scope repo`，结束总控。
4. **用户插话**：用户在总控期间问进度，就用 `watch-specs.sh ... --once`（同一状态文件）加 `pipeline-status.sh` 回答；要推翻某条自动拍板：规格还开着（部分落地）时，在规格 issue 下评论 `## 拍板`（写明推翻哪条、改选什么），下次 Run 先按它补改；规格已关闭时，新建一张 `ready-for-agent` 的散票「推翻 #<n> 自动拍板：<条目> 改选 <X>」，正文引用落地报告，下次推进模式会把它分流。用户说「停止总控」：停掉后台监控，释放锁，告诉用户之后用 `/find-next --watch` 重新进入。
5. 会话被意外关闭：锁随进程失效；状态文件保留，下次 `/find-next --watch` 从上次快照接着报。

## 推进模式出错处理与终止

- worker `auth` / `quota` / `transient`：停止后续自动动作，把错误和已完成的安全结果告诉用户，问是等还是停止；不自动降级为 `self` 或其他模型。
- worker `stalled` / `error`：把失败原因补进 Brief，换新运行目录重跑一次；再失败就停下报告。
- worker `violation`：报告作废，把 `changed_paths` 交给用户；不发布、不关票。
- `--worker agent` 的子代理没有 `status.json` 和上述错误码：以子代理返回与 `result.md` 为准，失败时换新运行目录重派一次；再失败就停下报告，不自动改用 codex 或 self。
- `--worker agent` 的子代理空闲却没交最终报告（留下「测试在后台跑，跑完再报」之类的话就结束回合）：不等它，按「推进模式」开头的核实规则自己核实（`ps`、产物、`git`），按证据判定完成或失败再收尾。
- GitHub 或发布脚本失败：停止在当前操作，不手工补已由脚本负责的创建/核对；可修复后重跑幂等脚本。
- 一轮扫描没有任何 research、决策、迷雾毕业、task、prototype、散票分流、起草、发布或启动可做：先放 `completion-report.sh <仓库>` 的完成度结论（脚本非 0 时写「完成度结论（查询失败）」），下面再输出当前最接近的阻塞点（含空地图、已认领不动的票、等待时机的散票）并结束。
- 已问满 3 轮或用户回「先到这」：不再发下一轮问题，按第 11 步收尾并列出剩余待拍板事项。
- 用户要求停止：不再发任何写请求；已在后台的 worker 等它结束后只读结果，不应用自动写操作。
- 任何原因终止推进模式（含上面各条停下、用户要求停止）：运行 `run-state.sh finish <运行目录> --aborted <一句原因>`，再 `lock.sh release find-next-advance --scope repo`。会话被意外关闭来不及做这两步时，锁自动失效，下次推进由第 1 步接续。

flash 模式下，审查（review）与 Design session 的失败处理见「flash 模式」一节。

## flash 模式（`FLASH_ORCHESTRATOR=1`）

本节只在 `FLASH_ORCHESTRATOR=1` 时生效；未设置或值不是 `1` 时，上文行为不变。flash 主会话只调度 worker、运行脚本、转述已备好的问题和机械执行明确指令；所有审读结论交给按「审查」路由跑的审查（review），需要展开讨论的问题交给 Design session。

- **按轮合成审查（review）**：一个推进轮次里出现多类材料时，等本轮 worker 全部结束，把所有原本由主会话「我审读 / 我复核」的材料合成一个输入文件，再进入会写跟踪器或发布答案的步骤。输入文件开头写明仓库、运行目录、轮次、每份材料的票号或组号，以及它在原有流程中对应的步骤；然后按材料分节原样附上 research 的 `result.md` 与 `resolution.md`、决策选项及「无需用户决策」依据、迷雾/task/prototype/散票分流建议与 Resolution 草稿、规格草稿、执行票草稿和 `manifest.json`。本轮没有可审材料时不调用。只要审，一轮只审一次；在哪里审由路由决定，不由 flash 决定——先问 `opus-review.sh --where --kind draft`：stdout 给 `in-session` 或 `out-of-session`，stderr 给一行 `审查中（<档案> / <模型>，会话内|出会话）` 加原因，这一行原样转述给用户——审查按路由命名，不要把它说成 Opus 审查，也不要用路由没给的名字。`out-of-session`（官方路由，或会话子代理不保证跑路由模型）照旧出会话执行：

  ```bash
  ~/.claude/skills/implement-spec-split/scripts/opus-review.sh --where --kind draft
  ~/.claude/skills/implement-spec-split/scripts/opus-review.sh --kind draft \
    --input <运行目录>/flash-review-input-<轮次>.md \
    --out <运行目录>/opus-draft-review-<轮次>.md --cwd <仓库>
  ```

  `in-session`（审查路由是 GLM，且本会话子代理被强制跑同一模型）时不起无头进程：`opus-review.sh --prompt --kind draft` 带同样的 `--input` / `--out` / `--cwd` 打印审读提示词，原样交给一个 `subagent_type: Explore` 的子代理（只读类型，flash 主线程只放行这类；前台等，不传 `model`），再把它的最终回复原样经 stdin 交给 `opus-review.sh --stamp --kind draft --out <同一个 findings 文件>`。`--stamp` 写出的首行是 `路由：审查（review）claude-glm / glm-5.4 / high（强度未生效）· <时间>（会话内子代理）`；退出码 7 时被拒正文留在 `<同一个 findings 文件>.rejected`（汇报时带上这个路径），补标 brief 向脚本要、不自组一个字：`opus-review.sh --repair-prompt --kind draft --out <同一个 findings 文件>` 打印的文本原样交给一个 `Explore` 子代理，再把它的回复 `--stamp` 一次——这一次 `## 需要人取舍` 被删、变成「无」或仍缺行同样 7；仍 7 按审查出错处理（见下）。之后的处理与出会话的 findings 完全一样。

  Flash 只照 findings 执行：通过或给出可照抄修改时，才写 Resolution、关票、更新地图、改草稿或发布；findings 要求重派时，把其指出的缺陷补进新 Brief 并重派对应 worker；findings 标为「需要人取舍」的条目原样进入第 6 步问题轮，每条的「推荐：」行照抄为该条的「建议」行（审查写「推荐：无」时如实写「无建议：<原因>」）。不得在 findings 之外自行判断「小问题」、补充推荐理由或放宽审读标准。向用户汇报结论时注明对应 findings 文件路径。
- **散票分流沿用 owner 结论**：散票分流结论为「等待时机」、且票下已有 owner（`authorAssociation=OWNER`）的分流评论、结论一致时，不需要再走审查：直接按第 4 步写回票面，并在汇报里注明「沿用 owner <时间> 的分流评论」。结论不一致或没有 owner 评论时，仍按当轮审查处理。
- **地图起草门槛**：`S<k>=map:<地图号>` 组只有在地图已收口、Map fog 为空、且它依赖的每张 Decision ticket 都能在该票 Resolution 中读到完整决定时，才派 worker 起草；地图摘要不能替代票 Resolution。无法机械确认、仍有开着的 Decision ticket、或起草/审稿结果出现未决条目时，这一组不发布、不改成选择题，改推荐 `/grill-map <地图号或话题>`，等 Design session 交接后再进入后续轮次。
- **问题轮与「展开」**：本轮全部问题都是已备好选项的选择题时，flash 直接按原有格式合并和转述，不新增判断、不改写选项和推荐。用户对某条回「展开」时，不在当前会话讨论，直接开对应的 Design session（等价于 `/grill-map` 或 `/grill-feature`）：

  ```bash
  bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh map|feature "<条目上下文>"
  ```

  `map` 用于地图、迷雾、空地图、地图内 decision/research 票和大模块话题；`feature` 用于小功能或单个决策类散票。flash 提示用户切换、阻塞等待 handoff，成功后只读 `handoff.md` 并执行其中交给 Orchestrator 的待办，脚本非 0 时转述 stderr 并停止。
- **推荐入口替换**：flash 模式下，上文推荐 `/wayfinder` 的地方改推荐 `/grill-map`；推荐 `/grill-with-docs` 的地方，小功能或单个决策改 `/grill-feature`，画图、推进地图或大模块讨论改 `/grill-map`。`/find-next` 自身入口和 `/to-spec`、`/to-tickets`、`/implement-spec-split` 的推荐不变。
- **worker 后端**：没给 `--worker` 时按 `--worker codex` 处理，和上文默认一致：flash 主会话开不了会写代码的子代理（`subagent-guard` 只放行 Explore、Plan、claude-code-guide，`general-purpose` 和缺省类型都拒），所以调研、决策、起草照旧派 codex worker，按路由表「调研起草」项走。`codex-worker.sh` 在 `FLASH_ORCHESTRATOR=1` 时拒跑：flash 模式下每条 wrapper 命令前都要加 `WORKER_ALLOW_FLASH=1`，不管 `--worker codex` 是显式给的还是缺省；非 flash 会话不设它，任何情况下都不许绕开本技能自己起 worker。`--worker agent` 只留给非 flash 会话：flash 会话里给了它（可带 `--agent-model`）也按 `--worker codex` 执行，不停下来问，上文各步「`--worker agent` 时…」的做法在 flash 模式下都不适用。
- **第 1 波启动**：仍按第 10 步的原有命令试运行并 `--apply`；规格会话由 `launch-wave.sh` 按路由表「编排」项（锁定 flash）经 Orca 托管启动，用的就是 OpenClaude 槽位，技能层不重复实现该规则。
- **审查不可用**：退出码为 3（额度或 429）时按 quota 停车，其余非 0 退出码仍按原规则停车并说明（退出码含义见 scripts/opus-review.sh 头注释）；不自动重试、不降级到 GLM、不改由 flash 自己审读（`--where` 说 `in-session` 时按上面的会话内流程走，那是路由指定的模型在审，不是 flash 自己审读）。Design session 脚本失败同样停下并转述错误。
- **阶段路由**：`/grill-router`（只由用户敲，背后是 `~/.claude/skills/implement-spec-split/scripts/stage-route.sh`）是用户设置的全局路由表（GLOSSARY.md 的 Stage route）：编排、讨论、调研起草、实现、审查、诊断六个阶段各用哪个启动器档案、模型和思考强度，可带到期。`opus-review.sh` 每次被调用时自己读「审查」（`--kind code`、`draft`）或「诊断」（`--kind diagnose`）的路由，`design-session.sh` 读「讨论」，正在推进的运行不用重开，下一次审查就是新路由。审查在哪里跑也由这张表决定：`opus-review.sh --where` 给结论（官方档案一律出会话；GLM 档案且会话子代理强制跑同一模型才在会话内；其余照旧出会话，路由不被悄悄换掉），不要自己判断。findings 文件首行每次都是 `路由：审查（review）claude-glm / glm-5.4 / medium · <时间>`，会话内审查的首行在强度后多「（强度未生效）」、行尾多「（会话内子代理）」；档案不是 `claude` 时出会话的 `opus-review.sh` 的 stderr 会说明本次没调官方 Opus。照常按 findings 执行，汇报结论时带上这一行。不要自己改路由表，也不要把切换当成降级而拒收 findings。
- **worker 派发路由**：同一张路由表（见「建议模式流程」第 3 步的「阶段路由」）在本技能里只管 `codex-worker.sh` 的派发；flash 模式下的派发全是 `codex-worker.sh`，全部按路由表走（ADR 0004）。不要自己改路由表。

## 建议模式输出（适合手机阅读）

```
下一步：<阶段> · <地图名 / 票名>
理由：<一两句>
命令：/<command> <参数>

备选：
- <阶段> · <名字>：<一句理由>
（最多 3 行；没有就省略）
```

没有任何候选时，直接说「没有就绪的下一步」，再给出最接近的一个和它还差什么。称呼票和地图时用名字（名字里可以带编号），不要只列编号。
