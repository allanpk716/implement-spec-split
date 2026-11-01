---
name: find-next
description: 扫描当前仓库的 wayfinder 地图与票，只挑出一个下一步（该 /to-tickets、该 /to-spec、还是该 grilling/research 哪张票）并给出要敲的命令。用户问"下一步做什么""该推哪张票""哪个该 to-spec / to-tickets / grill 了"，或输入 /find-next 时使用。参数 --worker codex|pi|self。
---

# find-next

在当前仓库里扫描跟踪器，**只给出一个 Next step**和要敲的命令，外加最多 3 行备选。术语（Spec、Closing ticket、Decision ticket、Map frontier、Next step）见 implement-spec-split 的 `GLOSSARY.md`，设计理由见其 `MAINTAINING.md`「find-next 设计要点」。对跟踪器只读：不改票头、不认领、不打标签、不写地图。

## 用法

- `/find-next`：等同于 `--worker codex`
- `/find-next --worker codex|pi|self`：判断部分交给谁做（见「流程」）

只扫当前仓库，不跨仓库汇总。

## 阶段与优先级

候选按阶段排序，越靠近交付越靠前；同一阶段内，按下面写的规则排序：

1. **该 to-tickets**：存在 spec 产物，但没有任何票的 `## Parent` 指向它。spec 产物有两种：
   - spec 票：正文含 `Problem Statement` 或 `User Stories` 节，`Triage: ready-for-agent`
   - Closing ticket：已关闭的 task 票，它把一章写进了 `SPEC.md`（标题常为「SPEC 增补/改写…章」）

   地图 Destination 写了「可直接 `/to-tickets`」，算佐证信号。→ `/to-tickets <spec 票或 SPEC 章名>`
2. **该 to-spec**：→ `/to-spec`
   - 本地跟踪器：地图的 Destination 是 spec 或某个章节，Map frontier 已空（子票全部 closed，或只剩 Closing ticket 而且它的阻塞都已关闭），并且还没有产出（`SPEC.md` 没有这一章，也没有 spec 票指回这张地图）
   - GitHub：地图下有还没被任何 Spec 覆盖的 Map ticket（`pipeline-status.sh` 的 `missing` 段）
   - 部分就绪：前沿没清空，但已关闭的决策足以撑起一个可独立交付的竖切。排在完全就绪之后，并标注「还剩 X、Y 没关」
3. **Map frontier 里的 Decision ticket**：open、阻塞全部已关闭、无 Assignee。按解锁的下游票数排序，数量相同时编号小的优先。
   - 在地图里的票 → `/wayfinder <地图> <票名>`（wayfinder 会认领、写 Resolution、关票、更新地图）
   - 不在任何地图里的散票（grilling 类、待分诊）→ `/grill-with-docs <票>`，并提醒用户讨论完手动关票
   - research 票同样推荐 `/wayfinder`；按用户的全局规则，调研交给 codex worker

跳过：Notes、标题或状态行里标了「搁置」的地图和票。

**不做**：不扫「执行票已拆、可以开工」这一阶段（`/implement-spec-split`）；不跨仓库汇总。

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
