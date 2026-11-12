---
name: find-next
description: 扫描当前仓库的 wayfinder 地图与票，只挑出一个下一步（该 /to-tickets、该 /to-spec、还是该 grilling/research 哪张票）并给出要敲的命令；加 --list 时改为列出全部待办清单；加 --batch 时批量起草缺规格的票的规格与执行票、给有规格未拆票的规格起草执行票，用户确认一轮后发布，最后给出可以开发的规格的编号顺序。用户问"下一步做什么""该推哪张票""哪个该 to-spec / to-tickets / grill 了""还有什么没做完""给我待办清单""批量写规格 / 批量拆票""接下来开发哪几份规格""开发顺序"，或输入 /find-next 时使用。参数 --list、--batch、--worker codex|pi|self。
---

# find-next

在当前仓库里扫描跟踪器，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Next step）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。对跟踪器只读：不改票头、不认领、不打标签、不写地图。唯一例外是 `--batch` 的发布步骤，它在用户确认后新建规格票和执行票。

## 用法

- `/find-next`：等同于 `--worker codex`
- `/find-next --worker codex|pi|self`：判断部分交给谁做（见「流程」）
- `/find-next --list`：不挑一个，列出当前仓库的全部待办清单（见「清单模式」）。总是我自己做，不派 worker，`--worker` 被忽略
- `/find-next --batch [地图号、实现票号或规格号…]`：把「缺规格」的票批量起草成规格和执行票、给「有规格、未拆票」的规格起草执行票，用户确认一轮后发布，最后输出可以开发的规格的编号顺序（见「批量模式」）。不带参数时处理全部。没有要起草的就直接输出开发顺序。只支持 GitHub 跟踪器；起草总是交给 codex worker，`--worker` 被忽略。**同一仓库同一时间只在一个会话里运行 `--batch`**：起草和发布没有加锁，两个会话同时跑会重复起草

只扫当前仓库，不跨仓库汇总。

## 阶段与优先级

候选按阶段排序，越靠近交付越靠前；同一阶段内，按下面写的规则排序：

1. **该 to-tickets**：存在 spec 产物，但没有任何票的 `## Parent` 指向它。spec 产物有两种：
   - spec 票：正文含 `Problem Statement` 或 `User Stories` 节，`Triage: ready-for-agent`
   - Closing ticket：已关闭的 task 票，它把一章写进了 `SPEC.md`（标题常为「SPEC 增补/改写…章」）

   地图 Destination 写了「可直接 `/to-tickets`」，算佐证信号。→ `/to-tickets <spec 票或 SPEC 章名>`
2. **该 to-spec**：→ `/to-spec`
   - 本地跟踪器：地图的 Destination 是 spec 或某个章节，Map frontier 已空（子票全部 closed，或只剩 Closing ticket 而且它的阻塞都已关闭），并且还没有产出（`SPEC.md` 没有这一章，也没有 spec 票指回这张地图）
   - GitHub：地图下有还没被任何 Spec 覆盖的 Map ticket（`pipeline-status.sh` 的 `missing` 段）。开着或已关闭的 Spec 都算覆盖，但脚本只认 Spec 正文里的 `实现票：#N` 行（分隔符必须是冒号或「为」「是」，正文叙述里的「（实现票 #N）」不算）；判断时先用 `gh issue list --state all --search "#N in:title"` 查一下，有没有标题带 `(#N)` 却漏写这一行的 Spec，有就不是候选，并在输出里提醒用户补这一行、关掉这张实现票
   - 部分就绪：前沿没清空，但已关闭的决策足以撑起一个可独立交付的竖切。排在完全就绪之后，并标注「还剩 X、Y 没关」
3. **Map frontier 里的 Decision ticket**：open、阻塞全部已关闭、无 Assignee。按解锁的下游票数排序，数量相同时编号小的优先。
   - 在地图里的票 → `/wayfinder <地图> <票名>`（wayfinder 会认领、写 Resolution、关票、更新地图）
   - 不在任何地图里的散票（grilling 类、待分诊）→ `/grill-with-docs <票>`，并提醒用户讨论完手动关票
   - research 票同样推荐 `/wayfinder`；按用户的全局规则，调研交给 codex worker

跳过：Notes、标题或状态行里标了「搁置」的地图和票。

**不做**：默认模式不推荐「执行票已拆、可以开工」这一阶段（`/implement-spec-split`），`--list` 会列出但不作为 Next step，开发顺序由 `--batch` 给出；不跨仓库汇总。

## 流程

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
   - worker 出错时按全局 CLAUDE.md 的处理表：`auth` / `quota` / `transient` → 告诉用户，问他们是等一会儿、换 `pi`，还是 `--worker self`，**不自动降级**；`stalled` / `error` → 把失败原因补进 Brief，换新运行目录重跑一次；`violation` → 报告作废，把 `changed_paths` 交给用户。
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

   称呼票时写「#编号 标题」。清单最后给出单个 Next step 的结论，口径与默认模式一致。
4. 仓库里另有自由格式的 backlog 文档（如 `docs/backlog.md`）时，不机械解析，只在末尾提醒一句「另有 backlog 文档未纳入，建议把仍有效的条目迁成 issue」。

## 批量模式（`--batch`）

用途：一条命令做完两件事。前半把「缺规格」的票起草成规格和执行票、把「有规格、未拆票」的规格起草成执行票，代替逐张走「`/to-spec` → `/to-tickets` → `/clear`」，中间确认一轮；后半给出全仓库可以开发的规格的编号顺序，用户照着在各个 worktree 里运行 `/implement-spec-split <规格号>`。读材料、写长文都在 worker 那边做，我只花在分组、审稿、发布和排序判断上。

不能调用 `/to-spec`、`/to-tickets` 本身（`disable-model-invocation`），所以起草 worker 直接读这两个上游技能的 `SKILL.md`，照它们的模板和规则写。两个技能里「问用户」的步骤合并成下面第 5 步的一轮。

1. **扫描**：`pipeline-status.sh --all`，取「缺规格」和「有规格、未拆票」两段；带参数时只留参数里的地图、实现票或规格。所在地图还在「地图仍在探索」段、并且决策票会影响这张实现票的，不进批量，在输出里说明还差哪张决策票。两段都没有要起草的，直接跳到第 7 步。
2. **分组（我做）**：看标题，必要时 `gh issue view` 实现票正文（不读决策票全文），把同一地图里紧密相关的实现票合成一份规格，其余一张一份；每份「有规格、未拆票」的规格单独成一组（写法 `S<k>=spec:<规格号>`，只起草执行票，发布时挂到这份已有规格下面，不新建规格票）。每组编号 `S1`、`S2`…。分组原则：一份规格是一个可独立交付、可独立验收的竖切；明显串行依赖的（如整体验收册依赖所有功能）单独成组，靠阻塞关系衔接。
3. **起草（worker 并行）**：
   - 运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-spec-batch/`，每组一个子目录 `S<k>/`，它就是那个 worker 的运行目录。
   - Brief 不手写，用脚本从 [templates/brief-spec-batch.md](templates/brief-spec-batch.md) 生成（它自己取票和地图标题、最新的 to-spec / to-tickets 路径，并在每份里列出所有组，用来写跨规格阻塞）：

     ```bash
     <本技能目录>/scripts/make-batch-briefs.sh --example <已有规格号> [--note S2=<补充说明文件>] <运行目录> S1=62 S2=63,64 S3=spec:224
     ```

     某组需要额外提示（比如某张 ADR 要重点读、正文里的 Open questions 要先查代码）时，写成小文件用 `--note` 传入，不改生成结果。
   - 脚本最后打印每组的运行命令。后台运行，最多 3 个同时跑，组更多就分批派：

     ```bash
     ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <仓库> --brief <运行目录>/S<k>/brief.md \
       --run-dir <运行目录>/S<k> --read-only --time-limit 2400 --idle-timeout 600
     ```

     草稿写在运行目录里，不在仓库内，所以用 `--read-only` 守住仓库。出错按全局 CLAUDE.md 的处理表。
4. **审稿（我做）**：读每组的 `result.md`、`manifest.json`、`spec.md` 和执行票正文，逐份检查：
   - 实现决定都注明了出处，并且出处里确实这么定了（抽查几条）；
   - `实现票：`、`地图：` 两行正确；
   - 执行票是竖切、粒度合适，阻塞边合理，跨组阻塞两边对得上（A 写了被 S2 挡住，S2 的范围确实提供 A 需要的东西）；
   - `blocked_by` 不挂在还没有规格的实现票上；该交给别的票的部分写进了 `handoffs`；
   - `unresolved` 里只有真正要用户拍板的事（命令名、界面、安全语义、范围归属），每条带推荐答案；字段名、审计动作名这类按先例能定的细节应写进正文由实现者定，误放进来的我挪回正文；
   - 执行票标题格式与仓库已有的票一致；
   - 用 `publish-batch.sh <全部 manifest.json>` 试运行：有未决也会打印完整计划、未决清单和留言预告，确认阻塞关系正确。

   小问题我直接改草稿文件；需要重读材料的大问题，写意见进新 Brief、换新运行目录重派那一组。
5. **问用户一轮**：一次性列出，适合手机阅读：

   ```
   批量起草 · <仓库名> · N 份规格、M 张执行票

   S1 <规格标题>（覆盖 #62、#63）
   摘要：<一两句>
   测试切入点：<一句>，对吗？
   执行票：
   1. <标题> — 交付：<一句>；被挡：无
   2. <标题> — 交付：<一句>；被挡：1、S2
   交接：<#84（要它写规格时纳入什么）；没有写「无」>
   未决（按推荐答案已写进草稿）：
   a. <问题> → 建议：<推荐答案>
   b. …

   S2 …（未决编号接着排：c、d…）

   请确认：各份的测试切入点、拆分粒度、阻塞关系，以及 a–<末号> 的建议（可以只回「都同意」，或指出要改哪几条）。
   确认后我发布（会新建 N + M 张 issue，并在交接的票下留言）。
   ```

   未决编号全批连续，让用户能一句话回复。用户同意的建议：把草稿里对应的「（待确认）」去掉，出处写「（owner <日期> 批量起草确认）」，清空那份的 `unresolved`。用户改了某份的测试切入点或拆分：小改我直接改草稿；大改那份退回 worker 重写，其他份照常发布。用户要再想想的未决，那份先不发布，留给 `/wayfinder` 或 `/grill-with-docs`。
6. **发布（我做，用户确认后）**：

   ```bash
   <本技能目录>/scripts/publish-batch.sh --apply [--only S1,S3] <运行目录>/S*/manifest.json
   ```

   先建规格票（`spec:<规格号>` 组不建，直接用已有规格），再按阻塞顺序建执行票、挂成规格的子票、加原生阻塞边，占位符换成真实票号，最后在 `handoffs` 指向的票下留言。每一步记进各组的 `published.json`，中途失败修好后直接重跑，不会重复建票或重复留言。结束时脚本读回子票和阻塞关系核对，通过后运行 `pipeline-status.sh --order` 打印开发顺序（第 7 步）。核对没过（退出码非零）就把缺的项报给用户，不手工补。
7. **开发顺序（每次都做）**：`publish-batch.sh --apply` 成功后会自动运行下面的命令；没有发布时（没有要起草的，或用户这次都不发布）我自己运行：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/pipeline-status.sh --order [--parallel 2] [--apart 224:239 …]
   ```

   排序由脚本按固定规则算（被依赖的先做 → 解锁下游多的先做 → 编号小的先做；完全被挡住的不进第 1 波；中断的标「先恢复」，进行中的不排）。规格是空闲、进行中还是中断，脚本看本地分支和领取记录（implement-spec-split 领取规格时写的），不看 Orca。

   我只补一类判断：「改同一块代码」的两份可以开工的规格，用 `--apart A:B` 传给脚本，它会把后一份顺延到下一波。依据是两份规格正文里写的模块，拿不准就不传。有 `--apart` 时重跑一次脚本，用重跑的结果。

   **原样转述脚本的表，不加解释**。之后只补两类一行提醒：被「单独的票」（表里写「另需 #N」）挡住的，提醒另开会话处理那张票；出现「循环依赖」的，问用户怎么定。然后提醒用户：每个 worktree 粘贴第 1 波的一条命令；哪个会话做完，就开编号最小、前置已合入的那一份，拿不准时重跑 `/find-next --batch`。最后提醒 `/clear`。

   ```
   开发顺序（同时 2 份）
   先恢复：#235
   第 1 波：
    1. #222 新旧版本混跑降级 → /implement-spec-split 222 --impl codex
    2. #224 机密项下发记录 → /implement-spec-split 224 --impl codex
   之后：
    3. #223 上传内容机密占位符（等 #222）
    4. #237 新增服务器与锚定
   ```

## 输出（适合手机阅读）

```
下一步：<阶段> · <地图名 / 票名>
理由：<一两句>
命令：/<command> <参数>

备选：
- <阶段> · <名字>：<一句理由>
（最多 3 行；没有就省略）
```

没有任何候选时，直接说「没有就绪的下一步」，再给出最接近的一个和它还差什么。称呼票和地图时用名字（名字里可以带编号），不要只列编号。
