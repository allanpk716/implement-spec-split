---
name: find-next
description: 默认进入推进模式：循环扫描当前 GitHub 仓库的 wayfinder 地图与票，自动调查并关闭可关的 research 票、为决策票准备选项、批量起草规格和执行票，把所有需要人拍板的问题合成一轮，答完后自动发布并启动第 1 波 implement-spec-split 会话；规格合入 main 后可由 implement-spec-split 调 --next-wave 自动开下一波。--suggest 保留原先只推荐一个下一步的只读行为；--list 列出待办清单；--batch 是推进模式别名。用户问"下一步做什么""推进仓库""该推哪张票""哪个该 to-spec / to-tickets / grill 了""还有什么没做完""给我待办清单""批量写规格 / 批量拆票""接下来开发哪几份规格""开发顺序"，或输入 /find-next 时使用。参数 --suggest、--list、--batch、--workers N（可选）、--specs K、--worker codex|pi|self|agent、--agent-model sonnet|opus|haiku|fable（仅 agent）。
---

# find-next

默认在当前仓库进入**推进模式**：尽可能把 wayfinder 地图和票推进到可开发状态，只在真正需要人拍板时把所有问题合成一轮。`--suggest` 才是原先的只读建议模式，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Next step、推进模式）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。

对跟踪器的写操作只允许出现在推进模式：按用户答案为调研票/决策票写 Resolution、关票、更新地图；发布草稿时新建规格票和执行票；启动规格前写领取记录。`--suggest` 和 `--list` 恒为只读。

## 用法

- `/find-next [--workers N] [--specs K] [--worker codex|pi|agent] [--agent-model <model>] [地图号、实现票号或规格号…]`：默认推进模式（见「推进模式」）。它循环执行：扫描 → 自动调查/关闭 research 票 → 准备决策题 → 起草规格和执行票 → 有问题就一轮问用户 → 应用答案并再扫描 → 发布 → 启动第 1 波。起草、调研和决策准备交给 worker：不给 `--worker` 或给 `codex` 时照旧派 codex worker；`pi` 维持现状（被忽略，等同 codex）；`agent` 时改由主会话开 Agent 子代理执行这些步骤（`model` 显式传 `--agent-model`，默认 `sonnet`），并让生成的开发命令也用 `--impl agent`。只支持 GitHub 跟踪器；本地 markdown 跟踪器请用 `--suggest` 或 `--list`
- `/find-next --suggest [--worker codex|pi|self|agent] [--agent-model <model>]`：原先的默认行为，只读挑一个 Next step（见「建议模式流程」）；未给 `--worker` 时等同于 `codex`。支持 GitHub 和本地 markdown 跟踪器
- `/find-next --list`：不挑一个，列出当前仓库的全部待办清单（见「清单模式」）。总是我自己做，不派 worker，`--worker` 被忽略
- `/find-next --batch …`：推进模式别名，兼容旧用法
- `--workers N` 可选，是全机 GLM worker 总数；每份规格的 `--parallel` = N ÷ K（至少 1）。没给时读 `~/.cache/implement-spec-split/max-workers`（`scripts/max-workers.sh` 用的同一文件）；文件也没有就把 worker 上限并入本轮最后一个问题问用户。`--specs K` 是同时开几份规格，默认 2。**同一仓库同一时间只在一个会话里运行推进模式**：起草、发布和地图更新没有全流程锁，两个会话同时跑会重复起草或重复关票
- `--agent-model <sonnet|opus|haiku|fable>` 只在 `--worker agent` 时有效，默认 `sonnet`；给了 `--worker codex`/`pi`/`self`（或不给 `--worker`）却给 `--agent-model` 是参数冲突，报错让用户改。一个开关管全程：`--worker agent` 同时决定本技能自己的调研/决策/起草方式和生成的开发命令后端，不提供混搭。

只扫当前仓库，不跨仓库汇总。

## 阶段与优先级

候选按阶段排序，越靠近交付越靠前；同一阶段内，按下面写的规则排序：

1. **该 to-tickets**：存在 spec 产物，但没有任何票的 `## Parent` 指向它。spec 产物有两种：
   - spec 票：正文含 `Problem Statement` 或 `User Stories` 节，`Triage: ready-for-agent`
   - Closing ticket：已关闭的 task 票，它把一章写进了 `SPEC.md`（标题常为「SPEC 增补/改写…章」）

   地图 Destination 写了「可直接 `/to-tickets`」，算佐证信号。→ `/to-tickets <spec 票或 SPEC 章名>`
2. **该 to-spec**：→ `/to-spec`
   - 本地跟踪器：地图的 Destination 是 spec 或某个章节，Map frontier 已空（子票全部 closed，或只剩 Closing ticket 而且它的阻塞都已关闭），并且还没有产出（`SPEC.md` 没有这一章，也没有 spec 票指回这张地图）
   - GitHub：地图下有还没被任何 Spec 覆盖的 Map ticket（`pipeline-status.sh` 的 `missing` 段），或前沿已空、还没有 Spec 指回的地图（`mapSpecs` 段）。开着或已关闭的 Spec 都算覆盖；实现票只认 Spec 正文里的 `实现票：#N` 行（分隔符必须是冒号或「为」「是」，正文叙述里的「（实现票 #N）」不算），地图只认 `地图：#N`、`来源地图：#N` 等指回行。判断实现票候选时先用 `gh issue list --state all --search "#N in:title"` 查一下，有没有标题带 `(#N)` 却漏写这一行的 Spec，有就不是候选，并在输出里提醒用户补这一行、关掉这张实现票
   - 部分就绪：前沿没清空，但已关闭的决策足以撑起一个可独立交付的竖切。排在完全就绪之后，并标注「还剩 X、Y 没关」
3. **Map frontier 里的 Decision ticket**：open、阻塞全部已关闭、无 Assignee。按解锁的下游票数排序，数量相同时编号小的优先。
   - 在地图里的票 → `/wayfinder <地图> <票名>`（wayfinder 会认领、写 Resolution、关票、更新地图）
   - 不在任何地图里的散票（grilling 类、待分诊）→ `/grill-with-docs <票>`，并提醒用户讨论完手动关票
   - research 票同样推荐 `/wayfinder`；按用户的全局规则，调研交给 codex worker

跳过：Notes、标题或状态行里标了「搁置」的地图和票。

**不做**：建议模式不推荐「执行票已拆、可以开工」这一阶段（`/implement-spec-split`），`--list` 会列出但不作为 Next step，开发顺序由推进模式给出；不跨仓库汇总。

## 建议模式流程（`--suggest`）

1. 读 `docs/agents/issue-tracker.md`，确认跟踪器形态。
2. **机械扫描**（本地 markdown 跟踪器，也就是 `tracker/map*.md` + `tracker/tickets/NN-*.md`）：

   ```bash
   python3 -I <本技能目录>/scripts/scan.py --tracker <仓库>/tracker
   ```

   GitHub 跟踪器改跑 `~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh`，各段对应关系：`needsTickets` → 阶段 1，`missing` → 阶段 2，`exploring` → 阶段 3（这一段只列出地图，具体是哪张 Decision ticket，再用 `gh` 查那张地图的 Map frontier），`implement` 不用。

   输出 JSON：每张票的票头、阻塞（含仍 open 的阻塞）、所属地图、Parent 引用与被引用、是否含 spec 正文、下游解锁数；每张地图的成员票与前沿；以及按阶段 1–3 粗筛的候选。脚本只做确定性规则。
3. **判断**：确认候选能否成立（目的地是否达成、是否搁置、`SPEC.md` 里有没有这一章、候选算不算 spec 正文），按优先级挑出一个。
   - `--worker self`：我自己读脚本输出，针对性地看几处地图 Notes、票正文和 `SPEC.md` 标题（`grep -n '^#' SPEC.md`）。
   - `--worker codex` / `pi`：建运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-find-next/`，把 `scan.py` 的输出存成其中的 `scan.json`，再用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`，后台运行：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/brief.md \
       --run-dir <运行目录> --read-only --time-limit 1200 --idle-timeout 600
     ```

     `pi` 用同目录的 `pi-worker.sh`。结束后只读 `status.json`、`result.md`（worker 的最终回复，≤15 行结论），结论是 to-spec 或 to-tickets 时再读 `digest.md`。
   - `--worker agent`：照旧建同一个运行目录、存 `scan.json`/`scan.txt`、用 [templates/brief-judge.md](templates/brief-judge.md) 填好 `brief.md`；但不运行 codex-worker.sh，而是开一个 Agent 子代理，`model` 显式传 `--agent-model` 的值（默认 `sonnet`），prompt 固定为：「读 <运行目录>/brief.md 并照做，把最终报告写到 <运行目录>/result.md，同时作为你的最终回复」。Brief 里「wrapper 会把最终回复存成 result.md，不要自己写」这类话是对 codex worker 说的，agent 模式下以 prompt 为准：子代理自己写 `result.md`。结束后照旧读 `result.md`（结论是 to-spec 或 to-tickets 时再读 `digest.md`）；没有 `status.json`，以子代理的返回为准。
   - worker 出错时按全局 CLAUDE.md 的处理表：`auth` / `quota` / `transient` → 告诉用户，问他们是等一会儿、换 `pi`，还是 `--worker self`，**不自动降级**；`stalled` / `error` → 把失败原因补进 Brief，换新运行目录重跑一次；`violation` → 报告作废，把 `changed_paths` 交给用户。`agent` 子代理没有 `status.json`：返回为空或明确报错时，把失败原因补进 Brief、换新运行目录重派一次，再失败就停下报告；不自动改用 codex 或 self。
4. **交接**：结论是 to-spec 或 to-tickets 时，那两个技能只能综合当前对话，所以要先把材料放进上下文。`self` 模式读地图和已关闭票的 Resolution；worker 模式读 `digest.md`。然后用几句话讲清要点，提示用户敲命令。结论是决策票时，只报票名和命令。

## 清单模式（`--list`）

用户要「全貌」而不是「下一步」时用。对跟踪器同样只读。

1. **机械扫描**：
   - GitHub：`~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --all`。比默认输出多三块：「地图仍在探索」下列出每张地图开着的决策票；「状态没收尾」（规格已关闭但执行票还开着、实现票只被已关闭的规格覆盖）；「散票」（不属于任何地图或规格的 open issue，带标签）。
   - 本地 markdown 跟踪器：`scan.py` 的 JSON 已含全部票，按下面的分组自己归类。
2. **轻量判断**（我自己做，只看标题和标签，必要时 `gh issue view` 一两张）：
   - 散票里标题相近、描述同一现象的，标「疑似重复」。
   - 「缺规格」里明显依赖别的票的（比如 Web UI 票依赖还在实现的后端规格、整体验收册票依赖所有功能），注明「等 #N」。
   - 不逐张读正文，不派 worker；脚本输出就是清单主体。
3. **输出**，按分组列出，空的组写「（无）」：

```
待办清单 · <仓库名> · <日期>

A. 正在实现 / 可以实现
- #212 规格名 0/9 已接手（分支 spec-212） → /implement-spec-split 212
B. 有规格、未拆票 → /to-tickets
C. 缺规格 → /to-spec（按地图分组）
D. 待讨论的决策票 → /wayfinder <地图> <票>
E. 状态没收尾（核对后关票，由用户确认）
F. 散票（bug / needs-triage 等，含疑似重复标注）

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
     --run-dir <运行目录>/research-<票号> --read-only --time-limit 2400 --idle-timeout 600
   ```

   `--worker agent` 时不运行上面的命令：照旧建 `research-<票号>/`、写同样的 `brief.md`，改按本节开头的同构做法开只读的 Agent 子代理（`model` = `--agent-model`），prompt 指向 `<运行目录>/research-<票号>/brief.md` 与 `result.md`。

   我审读 `result.md` 和 `resolution.md`：事实有出处、没有把推断写成决定、Resolution 和地图索引行符合 wayfinder 格式。通过后按 tracker 文档写票：在票下发 Resolution 评论、关票、把一行 gist 追加到地图 `## Decisions so far`（保留其他段落和已有顺序）。小语病我直接改；材料不足就换新运行目录重派一次。**结论里出现需要取舍的问题时不关票**，把它改写成一条决策题，并入本轮第 5 步；已有的调研事实仍留在草稿里供用户参考。

3. **决策票（worker 准备，一轮问用户）**：research 票全部处置完后重新运行 `pipeline-status.sh --all`，看最新前沿。open、阻塞全关、无 Assignee、标签为 `wayfinder:grilling` 的票每张派一个只读 worker，子目录 `decision-<票号>/`，用 [templates/brief-decision.md](templates/brief-decision.md)。worker 读票、地图、相关 ADR、规格和代码，产出问题陈述、2–4 个选项及代价、推荐答案和理由，写在 `decision.md`；不写票、不关票、不改地图。命令同上；`--worker agent` 时同样按本节开头的同构做法开子代理，prompt 指向 `<运行目录>/decision-<票号>/brief.md` 与 `result.md`。worker 判断「无需用户决策」（已有 ADR/地图决定）时，我复核依据，仍把它作为一条「建议直接关：<依据>」放进第 5 步那一轮，用户同意后再写 Resolution、关票：grilling 是 HITL，wayfinder 规定代理不能替人回答。`wayfinder:prototype`、`wayfinder:task` 票不自动处理（要做原型或手工操作，不是选项题），在第 10 步收尾里列出，提示用户用 `/wayfinder <地图> <票>` 处理。

4. **起草规格/执行票**：沿用下面 4.1–4.4（对应原批量模式第 2–4 步）。此轮没有可起草组就跳过。
   1. **分组（我做）**：取「缺规格」「地图缺规格」和「有规格、未拆票」三段；所在地图仍在探索、且决策票会影响这张实现票的，不进起草，在输出里说明还差哪张决策票。看标题，必要时 `gh issue view` 实现票正文，把同一地图里紧密相关的实现票合成一份规格，其余一张一份；每份已有规格单独成组（`S<k>=spec:<规格号>`，只拆票）；每张已收口地图单独成组（`S<k>=map:<地图号>`）。一份规格是一个可独立交付、可独立验收的竖切；明显串行依赖的单独成组，靠阻塞关系衔接。
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

5. **一轮问用户（没有问题就跳过）**：把第 3 步决策题、第 2 步转来的取舍题、第 4 步每组 `unresolved`、以及缺少的全机 worker 上限，合成一条手机友好的消息。编号全批连续（a、b、c…），每组只给一两行摘要和必要上下文，选项各占一行；最后一个问题可以是「全机 GLM worker 总数用 N 吗？」。结尾写：

   ```
   推进器 · <仓库名> · 需要拍板 <N> 条

   a. #<票号> <票名>：<问题一两句>
      A. <选项> — <代价>
      B. <选项> — <代价>
      建议 A：<理由>
   b. S1 <规格标题>：<未决问题> → 建议：<推荐答案>
   ...
   ```

   ```
   请回复「都同意」，或指出要改哪几条（例如：a 选 B、c 再想想、worker 用 6）。
   ```

   没有任何要问的，直接做第 7 步的复查扫描。

6. **应用答案**：用户同意的决策票/取舍题，把答案写进 Resolution 评论、关票、更新地图 Decisions so far；草稿未决按原批量规则处理：对应草稿去掉「（待确认）」，出处写「（owner <日期> 推进器确认）」，清空该组 `unresolved`；小改动我直接改草稿，大改动重派该组；用户说「再想想」的那张票或那组草稿不发布、不再追问，保留给 `/wayfinder` 或后续推进。用户给出的 worker 数在启动时传给 `launch-wave.sh`，由脚本写入全机 worker 上限文件。

7. **再扫描**：第 6 步关票可能解锁新的 research/决策票，或让某张地图前沿清空并出现在 `mapSpecs`。重新运行 `pipeline-status.sh --all`：有新可自动处理的对象就回到第 2 步；新对象带来新取舍时，只把新增问题问一轮；扫描不再出现新对象就往下走。若某张票反复生成同一未决问题、或用户明确说再想想，终止这条分支并在收尾说明阻塞点，不循环追问。

8. **发布**：没有 `unresolved` 的组直接发布，**不再确认**（owner 2026-11-14 定）。有问题但用户已答的组在应用答案后发布；用户说再想想的组不发布。发布用：

   ```bash
   <本技能目录>/scripts/publish-batch.sh --apply --no-order [--only S1,S3] <运行目录>/S*/manifest.json
   ```

   脚本建规格票和执行票、挂子票、加阻塞、回填占位符、写交接留言，并记录 `published.json`；中途失败修好后重跑，不手工补。核对失败就把缺项报给用户并停止。

9. **开发顺序与启动（每次都做）**：发布完或不需要发布时，先运行：

   ```bash
   <本技能目录>/scripts/launch-wave.sh --repo <owner/name> [--workers N] [--specs K] [--apart 224:239 …] [--impl agent --agent-model <model>]
   ```

   排序由 `pipeline-status.sh --order` 确定性计算：被依赖的先做 → 解锁下游多的先做 → 编号小的先做；完全被挡住的不进第 1 波；进行中的不排；中断的标「先恢复」。我只补「改同一块代码」的 `--apart A:B` 判断，依据规格正文里的模块；拿不准不传。有 `--apart` 时按重跑后的结果为准。`--apply` 会把本次 workers/specs/apart（`agent` 后端时还包括后端与模型）写入 `~/.cache/implement-spec-split/launch/<owner>__<name>.json`，供合入后的 `--next-wave` 复用；开发顺序本身每次重算。没给 `--workers` 时脚本按第 5 步得到的答案传入；第 5 步也没问（已有 max-workers 文件）就不传，让脚本读状态文件或 max-workers 文件。

   `--worker agent` 时，试运行和 `--apply` 两次都要在 launch-wave.sh 后面追加 `--impl agent --agent-model <model>`（即第 1 波每条命令变成 `/implement-spec-split <n> --impl agent --agent-model <model> --parallel <P>`）。`--apply` 会把它写进启动状态，合入后的 `--next-wave --apply` 不带参数也会沿用；不给 `--worker agent` 时不追加任何后端参数，生成命令与现状逐字一致。

   **原样转述试运行输出，不加解释**，不问用户，紧接着用同样参数加 `--apply` 再运行一次。唯一例外：出现「循环依赖」时不加 `--apply`，问用户怎么定。另需单独提醒一行：表里写「另需 #N」的规格要另开会话处理那张票。脚本会写全机 worker 上限、预留规格、在 Orca 里建 worktree 并启动 `/implement-spec-split <n> --impl codex --parallel <P>`（`--worker agent` 时为 `--impl agent --agent-model <model> --parallel <P>`）；「需手动」条目按脚本输出提醒。合入后的自动下一波见 implement-spec-split 根技能第 9 步。

10. **收尾**：原样转述启动结果，列出已启动、跳过、失败和需手动的规格。提醒用户：之后每份规格合入 main 时，implement-spec-split 会在第 9 步末尾只运行一条 `launch-wave.sh --next-wave --apply` 开新会话；本推进器会话可以 `/clear`。各规格会话仍会在 push 前确认、GLM 额度/auth/transient 出错、worker 连续失败时停下等人。

## 推进模式出错处理与终止

- worker `auth` / `quota` / `transient`：停止后续自动动作，把错误和已完成的安全结果告诉用户，问是等、换 `pi` 还是停止；不自动降级为 `self` 或其他模型。
- worker `stalled` / `error`：把失败原因补进 Brief，换新运行目录重跑一次；再失败就停下报告。
- worker `violation`：报告作废，把 `changed_paths` 交给用户；不发布、不关票。
- `--worker agent` 的子代理没有 `status.json` 和上述错误码：以子代理返回与 `result.md` 为准，失败时换新运行目录重派一次；再失败就停下报告，不自动改用 codex 或 self。
- GitHub 或发布脚本失败：停止在当前操作，不手工补已由脚本负责的创建/核对；可修复后重跑幂等脚本。
- 一轮扫描没有任何 research、决策、起草、发布或启动可做：输出当前最接近的阻塞点并结束。
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
