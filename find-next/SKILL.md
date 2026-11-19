---
name: find-next
description: 默认进入推进模式：循环扫描当前 GitHub 仓库的 wayfinder 地图与票，自动调查并关闭可关的 research 票、为决策票准备选项、推进没讨论完的地图（迷雾毕业、task/prototype 票）、分流地图外散票（等待时机 / 开地图 / 单个决策 / 重复或过时）、批量起草规格和执行票，把所有需要人拍板的问题合成一轮，答完后自动发布并启动第 1 波 implement-spec-split 会话；规格合入 main 后可由 implement-spec-split 调 --next-wave 自动开下一波。--suggest 保留原先只推荐一个下一步的只读行为；--list 列出待办清单；--batch 是推进模式别名。用户问"下一步做什么""推进仓库""该推哪张票""哪个该 to-spec / to-tickets / grill 了""还有什么没做完""给我待办清单""批量写规格 / 批量拆票""接下来开发哪几份规格""开发顺序"，或输入 /find-next 时使用。参数 --suggest、--list、--batch、--workers N（可选）、--specs K、--worker codex|pi|self|agent、--agent-model sonnet|opus|haiku|fable（仅 agent）、--auto-land（预先授权本批无人值守落地，适合通宵运行）。
---

# find-next

默认在当前仓库进入**推进模式**：把 wayfinder 地图（包括还有 Map fog 的地图）、规格、散票和开发尽可能推进到可开发状态，只在真正需要人拍板时把所有问题合成一轮。`--suggest` 才是原先的只读建议模式，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Map fog、Fog graduation、Loose ticket triage、Waiting on timing、Next step、推进模式）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。

对跟踪器的写操作只允许出现在推进模式：按用户答案为调研票/决策票/task 票/散票写 Resolution、关票、更新地图；迷雾毕业后建票、接阻塞、改地图；散票分流同意后建地图和子票、接 sub-issue 与阻塞、评论并关原散票；发布草稿时新建规格票和执行票；启动规格前写领取记录。`--suggest` 和 `--list` 恒为只读。

## 用法

- `/find-next [--workers N] [--specs K] [--worker codex|pi|agent] [--agent-model <model>] [--auto-land] [地图号、实现票号或规格号…]`：默认推进模式（见「推进模式」），也是地图、规格、票、开发的通用入口。它循环执行：扫描 → 自动调查/关闭 research 票 → 准备决策题 / 迷雾毕业建议 / task 清单 / prototype 反应题 / 散票分流建议 → 起草规格和执行票 → 有问题就一轮问用户 → 应用答案并再扫描 → 发布 → 启动第 1 波。起草、调研、决策准备、迷雾毕业、散票分流、task 和 prototype 交给 worker：不给 `--worker` 或给 `codex` 时照旧派 codex worker；`pi` 维持现状（被忽略，等同 codex）；`agent` 时改由主会话开 Agent 子代理执行这些步骤（`model` 显式传 `--agent-model`，默认 `sonnet`），并让生成的开发命令也用 `--impl agent`。只支持 GitHub 跟踪器；本地 markdown 跟踪器请用 `--suggest` 或 `--list`
- `/find-next --suggest [--worker codex|pi|self|agent] [--agent-model <model>]`：原先的默认行为，只读挑一个 Next step（见「建议模式流程」）；未给 `--worker` 时等同于 `codex`。支持 GitHub 和本地 markdown 跟踪器
- `/find-next --list`：不挑一个，列出当前仓库的全部待办清单（见「清单模式」）。总是我自己做，不派 worker，`--worker` 被忽略
- `/find-next --batch …`：推进模式别名，兼容旧用法
- `--workers N` 可选，是全机 GLM worker 总数；每份规格的 `--parallel` = N ÷ K（至少 1）。没给时读 `~/.cache/implement-spec-split/max-workers`（`scripts/max-workers.sh` 用的同一文件）；文件也没有就把 worker 上限并入本轮最后一个问题问用户。`--specs K` 是同时开几份规格，默认 2。**同一仓库同一时间只在一个会话里运行推进模式**：起草、发布和地图更新没有全流程锁，两个会话同时跑会重复起草或重复关票
- `--agent-model <sonnet|opus|haiku|fable>` 只在 `--worker agent` 时有效，默认 `sonnet`；给了 `--worker codex`/`pi`/`self`（或不给 `--worker`）却给 `--agent-model` 是参数冲突，报错让用户改。一个开关管全程：`--worker agent` 同时决定本技能自己的调研/决策/起草方式和生成的开发命令后端，不提供混搭。
- `--auto-land` 只在推进模式有效：预先同意本批规格（含之后自动开的波次）**无人值守落地**（GLOSSARY.md），第 6 步不再问这一条，第 10 步给 launch-wave.sh 追加 `--auto-land`。适合问完问题就去睡觉的通宵运行。

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
   - 不在任何地图里的散票：正文带「时机：」的标「等待时机：<条件>」，不推荐为 Next step，也不代判断条件是否满足；其他散票推荐 `/find-next <票号>` 推进模式分流（开地图 / 单个决策 / 关票），`/grill-with-docs <票>` 保留为手动选项
   - research 票同样推荐 `/wayfinder`；按用户的全局规则，调研交给 codex worker

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
   - `--worker codex` / `pi`：建运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-find-next/`，把 `scan.py` 的输出存成其中的 `scan.json`，再用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`，后台运行：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/brief.md \
       --run-dir <运行目录> --read-only --time-limit 1200 --idle-timeout 600
     ```

     `pi` 用同目录的 `pi-worker.sh`。结束后只读 `status.json`、`result.md`（worker 的最终回复，≤15 行结论），结论是 to-spec 或 to-tickets 时再读 `digest.md`。
   - `--worker agent`：照旧建同一个运行目录、存 `scan.json`/`scan.txt`、用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`；但不运行 codex-worker.sh，而是开一个 Agent 子代理，`model` 显式传 `--agent-model` 的值（默认 `sonnet`），prompt 固定为：「读 <运行目录>/brief.md 并照做，把最终报告写到 <运行目录>/result.md，同时作为你的最终回复」。Brief 里「wrapper 会把最终回复存成 result.md，不要自己写」这类话是对 codex worker 说的，agent 模式下以 prompt 为准：子代理自己写 `result.md`。结束后照旧读 `result.md`（结论是 to-spec 或 to-tickets 时再读 `digest.md`）；没有 `status.json`，以子代理的返回为准。
   - worker 出错时按全局 CLAUDE.md 的处理表：`auth` / `quota` / `transient` → 告诉用户，问他们是等一会儿、换 `pi`，还是 `--worker self`，**不自动降级**；`stalled` / `error` → 把失败原因补进 Brief，换新运行目录重跑一次；`violation` → 报告作废，把 `changed_paths` 交给用户。`agent` 子代理没有 `status.json`：返回为空或明确报错时，把失败原因补进 Brief、换新运行目录重派一次，再失败就停下报告；不自动改用 codex 或 self。
4. **交接**：结论是 to-spec 或 to-tickets 时，那两个技能只能综合当前对话，所以要先把材料放进上下文。`self` 模式读地图和已关闭票的 Resolution；worker 模式读 `digest.md`。然后用几句话讲清要点，提示用户敲命令。结论是决策票或地图迷雾待毕业时，只报名字和命令；迷雾地图的命令是 `/find-next --batch <地图号>`。其他散票提示推进模式会分流；时机票只提示条件，用户明确说「开 #N」才继续。

## 清单模式（`--list`）

用户要「全貌」而不是「下一步」时用。对跟踪器同样只读。

1. **机械扫描**：
   - GitHub：`~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --all`。除默认段外还列出：「地图仍在探索」每张地图开着的决策票；「空地图（待 /wayfinder 画图）」（open、未搁置、没有子票的 `wayfinder:map`）；「认领后不动（>3 天）」（open、有 Assignee、`updated_at` 早于 3 天的 `wayfinder:*` 决策票）；「状态没收尾」（规格已关闭但执行票还开着、实现票只被已关闭的规格覆盖、规格未关执行票全是搁置票）；「散票」（不属于任何地图或规格的 open issue，带标签、来源地图和时机）。「地图迷雾待毕业」在默认输出和 `--all` 都有。「可以实现」会排除未关执行票全是搁置票的规格；混合规格的搁置票带 `(搁置)` 后缀。
   - 本地 markdown 跟踪器：`scan.py` 的 JSON 已含全部票、每张地图的 `has_fog`、`fog_maps` 候选和成员关系；按下面的分组自己归类。open、未搁置且 `members` 为空的地图归「空地图」。本地票头没有可信更新时间，不推断「认领后不动」，该组写「（本地跟踪器无 updated_at，不判断）」。
2. **轻量判断**（我自己做，只看标题和标签，必要时 `gh issue view` 一两张）：
   - 散票里标题相近、描述同一现象的，标「疑似重复」；带 `timing` 的标「等待时机：<条件>」，不推断条件是否满足。
   - 「缺规格」里明显依赖别的票的（比如 Web UI 票依赖还在实现的后端规格、整体验收册票依赖所有功能），注明「等 #N」。
   - 不逐张读正文，不派 worker；脚本输出就是清单主体。
3. **输出**，按分组列出，空的组写「（无）」：

```
待办清单 · <仓库名> · <日期>

A. 正在实现 / 可以实现（搁置票不算待实现）
- #212 规格名 0/9 已接手（分支 spec-212） → /implement-spec-split 212
B. 有规格、未拆票 → /to-tickets
C. 缺规格 → /to-spec（按地图分组）
D. 待讨论的决策票 → /wayfinder <地图> <票>
E. 地图迷雾待毕业 → /find-next --batch <地图>
F. 认领后不动（>3 天） → /find-next --batch
G. 空地图（待 /wayfinder 画图）
H. 状态没收尾（核对后关票 / 只剩搁置票可关规格，由用户确认）
I. 散票（bug / needs-triage 等；含等待时机、疑似重复和推进模式分流提示）

建议先做：<一两句，按「阶段与优先级」挑出的那一个>
```

   称呼票时写「#编号 标题」。清单最后给出单个 Next step 的结论，口径与建议模式一致。
4. 仓库里另有自由格式的 backlog 文档（如 `docs/backlog.md`）时，不机械解析，只在末尾提醒一句「另有 backlog 文档未纳入，建议把仍有效的条目迁成 issue」。

## 推进模式（默认；`--batch` 是别名）

用途：把用户从「逐张判断、逐个技能、逐轮确认」里解放出来。主会话只保留必须跨全批做的判断：分组、审稿、把关 Resolution、判断 `--apart`；读长材料和写长文都交给 worker——默认（不给 `--worker` 或给 `codex`/`pi`）是新的 codex worker；`--worker agent` 时是主会话开的 Agent 子代理（`model` 显式传 `--agent-model`，默认 `sonnet`）。每一轮尽可能自动推进，只有真正的取舍题才问用户，而且所有问题合成一轮。

`--worker agent` 时的同构做法（适用于本节所有原本派 codex-worker.sh 的步骤）：照旧建运行目录和子目录、照旧写 `brief.md`，然后开一个 Agent 子代理，`model` 显式传 `--agent-model` 的值，prompt 固定为：「读 <该子目录>/brief.md 并照做，把最终报告写到 <该子目录>/result.md，同时作为你的最终回复」。Brief 里「wrapper 会把最终回复存成 result.md，不要自己写」这类话是对 codex worker 说的，agent 模式下以 prompt 为准：子代理自己写 `result.md`。没有 `status.json`，主会话以子代理的返回和 `result.md` 为准；失败时把原因补进 Brief、换新运行目录重派一次，再失败就停下报告，不自动改用 codex 或 self。

推进模式只支持 GitHub 跟踪器。先读 `docs/agents/issue-tracker.md`；发现本地 markdown 跟踪器时，说明推进模式不支持，改按 `--suggest` 或 `--list` 执行。**同一仓库同一时间只在一个会话里运行推进模式**；开工前确认没有另一个本仓库推进器会话。

1. **扫描**：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --all
   ```

   保存为运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-find-next-advance/scan-<轮次>.txt`。带地图号、实现票号或规格号时，只推进参数指向的范围；不带时处理全仓库。

2. **research 票（自动，不问用户）**：从「地图仍在探索」每张地图的前沿里找出 open、阻塞全关、无 Assignee、标签为 `wayfinder:research` 的票。pipeline 输出已标注「有未关阻塞」「已认领」；漏信息时用 `gh issue view <n> --json assignees,labels` 和 tracker 文档的 blocker 查询补齐。每张票一个子目录 `research-<票号>/`，用 [templates/brief-research.md](templates/brief-research.md) 填 Brief，后台运行：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/research-<票号>/brief.md \
     --run-dir <运行目录>/research-<票号> --read-only --mcp all --time-limit 2400 --idle-timeout 600
   ```

   `--worker agent` 时不运行上面的命令：照旧建 `research-<票号>/`、写同样的 `brief.md`，改按本节开头的同构做法开只读的 Agent 子代理（`model` = `--agent-model`），prompt 指向 `<运行目录>/research-<票号>/brief.md` 与 `result.md`。

   我审读 `result.md` 和 `resolution.md`：事实有出处、没有把推断写成决定、Resolution 和地图索引行符合 wayfinder 格式。通过后按 tracker 文档写票：在票下发 Resolution 评论、关票、把一行 gist 追加到地图 `## Decisions so far`（保留其他段落和已有顺序）。小语病我直接改；材料不足就换新运行目录重派一次。**结论里出现需要取舍的问题时不关票**，把它改写成一条决策题，并入本轮第 6 步；已有的调研事实仍留在草稿里供用户参考。

3. **决策、迷雾、task 与 prototype 票（worker 准备，一轮问用户）**：research 票全部处置完后重新运行 `pipeline-status.sh --all`，看最新前沿、`fogMaps`、`emptyMaps` 和 `staleClaims`。
   - **决策票**：open、阻塞全关、无 Assignee、标签为 `wayfinder:grilling` 的票每张派一个只读 worker，子目录 `decision-<票号>/`，用 [templates/brief-decision.md](templates/brief-decision.md)。worker 读票、地图、相关 ADR、规格和代码，产出问题陈述、2–4 个选项及代价、推荐答案和理由，写在 `decision.md`；不写票、不关票、不改地图。命令同上（含 `--mcp all`）；`--worker agent` 时同样按本节开头的同构做法开子代理，prompt 指向 `<运行目录>/decision-<票号>/brief.md` 与 `result.md`。worker 判断「无需用户决策」（已有 ADR/地图决定）时，我复核依据，仍把它作为一条「建议直接关：<依据>」放进第 6 步那一轮，用户同意后再写 Resolution、关票：grilling 是 HITL，wayfinder 规定代理不能替人回答。
   - **地图迷雾**：扫描到 `fogMaps` 时，每张地图派一个只读 worker，子目录 `fog-<地图号>/`，用 [templates/brief-fog.md](templates/brief-fog.md)。worker 读地图、`Decisions so far` 和相关 Resolution，写 `fog.md`：建议新建的票（问题、`wayfinder:` 类型、阻塞对象）、应从 `Not yet specified` 移除的段落、建议判出范围或作废的票（附理由）、毕业后仍剩下的迷雾。这些变成第 6 步的「建议新建 / 建议判出范围」条目；未获用户同意前，主会话不改地图边界。
     地图迷雾的 codex 命令同决策票（含 `--mcp all`）。
   - **task 票**：前沿里 open、阻塞全关、无 Assignee、标签为 `wayfinder:task` 的票每张派一个 worker，子目录 `task-<票号>/`，用 [templates/brief-task.md](templates/brief-task.md)。这个 worker **不是只读**，但只能改 Brief 明确写出的范围。能独自完成（AFK）的做掉并写 Resolution 草稿；需要人做的写精确清单。我复核结果同 research：事实有出处、没有越界，清晰 AFK 结果直接写 Resolution、关票、更新地图；人工清单放进第 6 步那一轮。
   - **prototype 票**：前沿里 open、阻塞全关、无 Assignee、标签为 `wayfinder:prototype` 的票，单次运行最多处理 2 张；每张一个 worker，子目录 `prototype-<票号>/`，用 [templates/brief-prototype.md](templates/brief-prototype.md)。UI 原型按 mockit 技能做独立页面，由我复核后提交 mockit；非 UI 原型放在 `prototype/<票号>` 临时分支上，worker 本地提交但不得 push，我复核后 push 该分支，不开 PR、永不合并，推进模式下不单独确认。随后把可访问链接 / 分支链接和一句要反应的问题放进第 6 步那一轮，用户表态后再写 Resolution。第 3 张及以后的 prototype 票留到第 11 步收尾列出。

   writable worker 的命令去掉 `--read-only`：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/task-<票号>/brief.md \
     --run-dir <运行目录>/task-<票号> --time-limit 2400 --idle-timeout 600
   ```

   task / prototype 需要操作远程服务器时，给上面的 codex 命令传 `--mcp ssh-manager`。
   `--worker agent` 时所有新 worker 都按本节开头的同构做法开子代理；task / prototype 子代理同样只能执行 Brief 写明的范围。

4. **散票分流（worker 只读给建议，一轮问用户）**：处理「散票」段里 open、未搁置且不带 `wontfix` 的票；bug、needs-triage 等都进入。带地图号/实现票号/规格号参数时，只有参数直接指向某张散票才处理它；来源地图或相关规格的编号不自动带入散票。
   - **正文带 `timing` 的票**：默认「等待时机」，不派 worker、不提问、不自行判断条件是否满足。汇报单列「等待时机」段（#号、标题、条件），并提示「要现在开就回『开 #N』」。
   - **其他散票**：每张派一个只读 worker，子目录 `loose-<票号>/`，用 [templates/brief-loose.md](templates/brief-loose.md)。worker 读票、评论、`fromMap` 指向的地图、相关规格/ADR/代码和 wayfinder 规则，输出四选一：**该开地图**（`map-draft.md` 写标题、Destination、首批 research/决策票标题与一句话、Not yet specified 迷雾、阻塞关系）、**单个决策**（问题、2–4 个选项及代价、推荐答案）、**重复或过时**（被哪张票/哪次提交覆盖的依据）、**等待时机**（正文无时机行但依据显示现在不该开，写条件）。命令同决策票：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/loose-<票号>/brief.md \
       --run-dir <运行目录>/loose-<票号> --read-only --mcp all --time-limit 2400 --idle-timeout 600
     ```

     `--worker agent` 时同样按本节开头的同构做法开只读 Agent 子代理，prompt 指向 `<运行目录>/loose-<票号>/brief.md` 与 `result.md`。
   - 我复核 `triage.md` 及分类附件：依据必须指向真实 issue/评论/提交/文件；地图草案符合 wayfinder 格式且不扩大原票边界；决策题仍是 HITL。worker 判定的「等待时机」只汇报不提问。

5. **起草规格/执行票**：沿用下面 5.1–5.4（对应原批量模式第 2–4 步）。此轮没有可起草组就跳过。
   1. **分组（我做）**：取「缺规格」「地图缺规格」和「有规格、未拆票」三段；所在地图仍在探索、且决策票会影响这张实现票的，不进起草，在输出里说明还差哪张决策票。「地图迷雾待毕业」和「空地图」不进起草。看标题，必要时 `gh issue view` 实现票正文，把同一地图里紧密相关的实现票合成一份规格，其余一张一份；每份已有规格单独成组（`S<k>=spec:<规格号>`，只拆票）；每张已收口且无迷雾的地图单独成组（`S<k>=map:<地图号>`）。一份规格是一个可独立交付、可独立验收的竖切；明显串行依赖的单独成组，靠阻塞关系衔接。
   2. **生成 Brief**：运行目录下每组 `S<k>/`，不手写，用脚本生成：

      ```bash
      <本技能目录>/scripts/make-batch-briefs.sh [--example <已有规格号>] [--note S2=<补充说明文件>] <运行目录> S1=62 S2=63,64 S3=spec:224 S4=map:41
      ```

      某组需要额外提示时写成小文件用 `--note` 传入。仓库已有规格时传 `--example`；一份都没有可不传。
   3. **worker 并行起草**：按脚本打印的命令后台运行，最多 3 个同时，组更多分批：

      ```bash
      ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/S<k>/brief.md \
        --run-dir <运行目录>/S<k> --read-only --time-limit 2400 --idle-timeout 600
      ```

      `--worker agent` 时不运行上面的命令：照旧用脚本生成各组的 `S<k>/brief.md`，改按本节开头的同构做法开 Agent 子代理（`model` = `--agent-model`），prompt 指向 `<运行目录>/S<k>/brief.md` 与 `result.md`；同样最多 3 个同时，组更多分批。

      草稿只在运行目录，不在仓库内。不能调用 `/to-spec`、`/to-tickets` 本身；worker 直接读最新上游技能规则。
   4. **审稿（我做）**：读 `result.md`、`manifest.json`、`spec.md` 和执行票正文，检查实现决定都有出处且出处确实这么定了；`实现票：`、`地图：`两行正确；执行票是竖切、阻塞合理、跨组阻塞对得上；`blocked_by` 不挂还没有规格的实现票，该交接的写进 `handoffs`；`unresolved` 只留真正要用户拍板的事，每条带推荐答案；标题格式与仓库一致。用 `publish-batch.sh <全部 manifest.json>` 试运行核对计划。小问题直接改；大问题换新 Brief 重派那一组。

6. **一轮问用户（没有问题就跳过）**：把第 3 步决策题、迷雾毕业建议、task 人工清单、prototype 反应题、`staleClaims` 处理题、第 2 步转来的取舍题、第 4 步散票分流建议、第 5 步每组 `unresolved`、缺少的全机 worker 上限，以及无人值守落地授权，合成一条手机友好的消息。编号全批连续（a、b、c…），每组只给一两行摘要和必要上下文，选项各占一行；最后一个问题可以是「全机 GLM worker 总数用 N 吗？」。**无人值守落地**（GLOSSARY.md）：本次会启动规格、且调用时没带 `--auto-land` 时，加一问「本批规格（含之后自动开的波次）无人值守落地吗？——合入 main/合 PR、CI 红自动修、出问题在规格 issue 留停车报告，不停下等你」；只剩这一问时也要问，它是唯一的授权入口。调用时带了 `--auto-land` 即视为已同意，不再问。**单次运行累计最多问用户 3 轮**；第 3 轮结束后不再发起第 4 轮，剩余待拍板事项留到收尾，下次 `/find-next --batch` 接着推。结尾写：

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

   「等待时机」不占拍板编号、不提问，单独列在问题后：

   ```
   等待时机（不提问）：
   - #<票号> <票名>：<条件>；要现在开就回「开 #<票号>」
   ```

   ```
   请回复「都同意」，或指出要改哪几条（例如：a 选 B、f 再想想、worker 用 6）。
   也可以回「展开 <条目>」就地讨论；回「先到这」立即收尾。
   ```

   用户对某条回「展开」时，当前会话就地对那张票调用 grilling 和 domain-modeling 技能，写完 Resolution 后继续推进，不要求另开 `/wayfinder`；单个决策类散票同样可「展开」。没有任何要问的，直接做第 8 步的复查扫描。

7. **应用答案、迷雾毕业与散票分流**：用户同意的决策票/取舍题，把答案写进 Resolution 评论、关票、更新地图 Decisions so far；「展开」条目按第 6 步的 grilling + domain-modeling 结果同样收票。task 票按用户完成的人工步骤或确认过的 AFK 结果写 Resolution、关票、更新地图；prototype 按用户反应写 Resolution、关票并链接原型资产。`staleClaims` 只有用户同意才取消认领；取消后它按前沿规则进入后续扫描，不自动视为已处理。草稿未决按原批量规则处理：对应草稿去掉「（待确认）」，出处写「（owner <日期> 推进器确认）」，清空该组 `unresolved`；小改动我直接改草稿，大改动重派该组；用户说「再想想」的那张票或那组草稿不发布、不再追问，保留给 `/wayfinder` 或后续推进。用户给出的 worker 数在启动时传给 `launch-wave.sh`，由脚本写入全机 worker 上限文件。

   用户同意迷雾毕业建议后，按 wayfinder 规则**先建新票**（每张票正文一个精确 Question、带正确的 `wayfinder:<type>` 标签、挂到地图下），**第二遍**再接阻塞并写真实编号的交叉引用；然后改地图：毕业的段落从 `Not yet specified` 删除，只留在新票里；建议判出范围的票关掉，并在 `Out of scope` 写一行原因和链接；建议作废的票按 wayfinder 规则关闭或改正，说明依据。未获同意的雾留在原段，不代删。用户回「先到这」时立即进入收尾，不再应用未确认事项。

   用户同意为散票建地图后，我按 wayfinder 地图格式建 `wayfinder:map` 票（正文含 `Destination`、`Decisions so far`、`Not yet specified`，并写「来源散票：#N」），按草案建子票、接 sub-issue 与阻塞。默认在原散票下评论指向新地图后关闭它；若草案明确说明「把原散票挂为子票并改成该地图首张 decision/research 票」更好，才采用该方案。单个决策同意后写 Resolution、关票；重复或过时同意后评论依据并关票。用户对等待时机票回「开 #N」时，视为它进入第 4 步的 worker 分流，下一轮呈现结果；回「再想想」则不动、不再追问。

8. **再扫描**：第 7 步关票可能解锁新的 research/决策/task/prototype 票，或让某张地图决策票全关；此时若 Map fog 仍非空，它会出现在 `fogMaps` 而不是 `mapSpecs`。新建的散票地图也进入同一轮扫描，按地图规则继续推进（research 自动、决策出题、迷雾毕业）。重新运行 `pipeline-status.sh --all`：有新可自动处理的对象就回到第 2 步；新 `fogMaps` 按第 3 步派迷雾 worker；新对象带来新取舍时，只把新增问题问一轮，并继续遵守单次 3 轮上限；扫描不再出现新对象就往下走。若某张票反复生成同一未决问题、或用户明确说再想想，终止这条分支并在收尾说明阻塞点，不循环追问。

9. **发布**：没有 `unresolved` 的组直接发布，**不再确认**（owner 2026-11-14 定）。有问题但用户已答的组在应用答案后发布；用户说再想想的组不发布。发布用：

   ```bash
   <本技能目录>/scripts/publish-batch.sh --apply --no-order [--only S1,S3] <运行目录>/S*/manifest.json
   ```

   脚本建规格票和执行票、挂子票、加阻塞、回填占位符、写交接留言，并记录 `published.json`；中途失败修好后重跑，不手工补。核对失败就把缺项报给用户并停止。

10. **开发顺序与启动（每次都做）**：发布完或不需要发布时，先运行：

   ```bash
   <本技能目录>/scripts/launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart 224:239 …] [--impl agent --agent-model <model>] [--auto-land]
   ```

   排序由 `pipeline-status.sh --order` 确定性计算：被依赖的先做 → 解锁下游多的先做 → 编号小的先做；完全被挡住的不进第 1 波；进行中的不排；中断的标「先恢复」；搁置执行票不算待实现，未关执行票全是搁置票的规格不进顺序或波次。我只补「改同一块代码」的 `--apart A:B` 判断，依据规格正文里的模块；拿不准不传。有 `--apart` 时按重跑后的结果为准。`--apply` 会把本次 workers/specs/apart（`agent` 后端时还包括后端与模型）写入 `~/.cache/implement-spec-split/launch/<owner>__<name>.json`，供合入后的 `--next-wave` 复用；开发顺序本身每次重算。没给 `--workers` 时脚本按第 6 步得到的答案传入；第 6 步也没问（已有 max-workers 文件）就不传，让脚本读状态文件或 max-workers 文件。

   `--worker agent` 时，试运行和 `--apply` 两次都要在 launch-wave.sh 后面追加 `--impl agent --agent-model <model>`（即第 1 波每条命令变成 `/implement-spec-split <n> --impl agent --agent-model <model> --parallel <P>`）。`--apply` 会把它写进启动状态，合入后的 `--next-wave --apply` 不带参数也会沿用；不给 `--worker agent` 时不追加任何后端参数，生成命令与现状逐字一致。

   用户同意了无人值守落地时，试运行和 `--apply` 都追加 `--auto-land`：每条命令末尾带 `--auto-land`，`--apply` 把授权写进启动状态，`--next-wave` 沿用；不带 `--auto-land` 的 `--apply` 会清掉旧授权（授权只对这一批有效）。

   **原样转述试运行输出，不加解释**，不问用户，紧接着用同样参数加 `--apply` 再运行一次。唯一例外：出现「循环依赖」时不加 `--apply`，问用户怎么定。另需单独提醒一行：表里写「另需 #N」的规格要另开会话处理那张票。脚本会写全机 worker 上限、预留规格、在 Orca 里建 worktree 并启动 `/implement-spec-split <n> --impl codex --parallel <P>`（`--worker agent` 时为 `--impl agent --agent-model <model> --parallel <P>`）；「需手动」条目按脚本输出提醒。合入后的自动下一波见 implement-spec-split 根技能第 9 步。

11. **收尾**：原样转述启动结果，列出已启动、跳过、失败和需手动的规格。列出 `emptyMaps`（若有），逐张提示「用 `/wayfinder <地图号>` 画图」，不代画、不建第一批票。单列「等待时机」（#号、标题、条件、要现在开就回「开 #N」）与未结案的散票分流建议。列出因单次 2 张上限未处理的 prototype 票、因 3 轮问询上限或「先到这」留下的待拍板事项，提示下次运行 `/find-next --batch` 接着推。提醒用户：之后每份规格合入 main 时，implement-spec-split 会在第 9 步末尾只运行一条 `launch-wave.sh --next-wave --apply` 开新会话；本推进器会话可以 `/clear`。各规格会话仍会在 push 前确认、GLM 额度/auth/transient 出错、worker 连续失败时停下等人；无人值守落地时不确认、不等人，落地或停车都在规格 issue 下留报告，早上看 GitHub 即可。

## 推进模式出错处理与终止

- worker `auth` / `quota` / `transient`：停止后续自动动作，把错误和已完成的安全结果告诉用户，问是等、换 `pi` 还是停止；不自动降级为 `self` 或其他模型。
- worker `stalled` / `error`：把失败原因补进 Brief，换新运行目录重跑一次；再失败就停下报告。
- worker `violation`：报告作废，把 `changed_paths` 交给用户；不发布、不关票。
- `--worker agent` 的子代理没有 `status.json` 和上述错误码：以子代理返回与 `result.md` 为准，失败时换新运行目录重派一次；再失败就停下报告，不自动改用 codex 或 self。
- GitHub 或发布脚本失败：停止在当前操作，不手工补已由脚本负责的创建/核对；可修复后重跑幂等脚本。
- 一轮扫描没有任何 research、决策、迷雾毕业、task、prototype、散票分流、起草、发布或启动可做：输出当前最接近的阻塞点（含空地图、已认领不动的票、等待时机的散票）并结束。
- 已问满 3 轮或用户回「先到这」：不再发下一轮问题，按第 11 步收尾并列出剩余待拍板事项。
- 用户要求停止：不再发任何写请求；已在后台的 worker 等它结束后只读结果，不应用自动写操作。

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
