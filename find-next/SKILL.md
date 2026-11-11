---
name: find-next
description: 扫描当前仓库的 wayfinder 地图与票，只挑出一个下一步（该 /to-tickets、该 /to-spec、还是该 grilling/research 哪张票）并给出要敲的命令；加 --list 时改为列出全部待办清单。用户问"下一步做什么""该推哪张票""哪个该 to-spec / to-tickets / grill 了""还有什么没做完""给我待办清单"，或输入 /find-next 时使用。参数 --list、--worker codex|pi|self。
---

# find-next

在当前仓库里扫描跟踪器，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Next step）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。对跟踪器只读：不改票头、不认领、不打标签、不写地图。

## 用法

- `/find-next`：等同于 `--worker codex`
- `/find-next --worker codex|pi|self`：判断部分交给谁做（见「流程」）
- `/find-next --list`：不挑一个，列出当前仓库的全部待办清单（见「清单模式」）。总是我自己做，不派 worker，`--worker` 被忽略

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

**不做**：默认模式不推荐「执行票已拆、可以开工」这一阶段（`/implement-spec-split`），`--list` 会列出但不作为 Next step；不跨仓库汇总。

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
