<!--
find-next 判断 Brief 模板。复制到 <运行目录>/brief.md，填好 <...>，删掉本注释。
-->

# 任务：从跟踪器里挑出唯一的下一步（只读调查）

## 目标

在仓库 `<仓库路径>` 的跟踪器里挑出**一个**下一步动作，再给出最多 3 个备选。结论直接作为你的**最终回复**（wrapper 会把它存成 `result.md`，不要自己写这个文件）。结论是 to-spec 或 to-tickets 时，另写一份文件 `<运行目录>/digest.md`。

## 输入

- 机械扫描结果：`<运行目录>/scan.json`。本地跟踪器由 `scan.py` 生成，内容是票头、阻塞、所属地图、Parent 引用、下游解锁数，以及粗筛候选；GitHub 跟踪器是 `pipeline-status.sh` 的输出，存为 `<运行目录>/scan.txt`，这时用 `gh` 查票，并把下面的本地路径换成 issue。先读扫描结果，再针对性地去看原文。
- 术语：`~/.claude/skills/implement-spec-split/GLOSSARY.md`（Spec、Closing ticket、Decision ticket、Map frontier）
- 跟踪器约定：`<仓库路径>/docs/agents/issue-tracker.md`
- 地图：`<仓库路径>/tracker/map*.md`；票：`<仓库路径>/tracker/tickets/NN-*.md`；定稿规格：`<仓库路径>/SPEC.md`（先用 `grep -n '^#' SPEC.md` 看章节目录）

## 判定规则（按优先级，越靠前越优先）

1. **该 to-tickets**：存在 spec 产物，但没有任何票的 `## Parent` 指向它。spec 产物包括：正文含 `Problem Statement` / `User Stories` 的 spec 票，以及已关闭的地图收口票（它把一章写进了 SPEC.md）。要核实 SPEC.md 里确实有这一章。
2. **该 to-spec**：地图的 Destination 是 spec 或某个章节，前沿已空（或只剩收口票、而且它的阻塞都已关闭），并且还没有产出。部分就绪的竖切排在完全就绪之后，并注明还剩哪几张票没关。
3. **Map frontier 里的 Decision ticket**：open、阻塞全部已关闭、无 Assignee。先按 `scan.json` 里的下游解锁数排，数量相同时编号小的优先。在地图里的票，命令是 `/wayfinder <地图> <票名>`；散票的命令是 `/grill-with-docs <票>`。

跳过：Notes、标题或状态行里标了「搁置」的地图和票，以及正文写明「实际被……挡住」的票。如果你认为 `scan.json` 的粗筛有误（例如漏判、误判搁置），以原文为准，并在 result.md 里用一行说明。

## 输出

最终回复只包含下面的格式，不超过 15 行，不要加开场白或总结。没有任何候选时，第一行写「下一步：无」，接着写最接近的一个和它还差什么：

```
下一步：<阶段> · <地图名 / 票名>
理由：<一两句，引用文件路径>
命令：/<command> <参数>

备选：
- <阶段> · <名字>：<一句理由>
```

`digest.md`（只在结论是 to-spec 或 to-tickets 时写，≤150 行）：该地图或 spec 的 Destination；每张已关闭票的 Resolution 要点，每条一到三行，附 `文件:行号`；对应 SPEC.md 章节的位置；还没决定的事项。只写摘要和指针，不要大段照抄原文。

## 不要做

- 这是只读调查：除 `<运行目录>/digest.md` 外，不要改动任何文件，不要 commit
- 不要递归删除目录
- 不要联网
