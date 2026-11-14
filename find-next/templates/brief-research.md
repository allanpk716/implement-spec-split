<!--
find-next 推进模式 research 票 Brief 模板。复制到 <运行目录>/brief.md，
填好 <...>，删掉本注释。
-->

# 任务：调查 wayfinder research 票 #<票号>（只读仓库，写运行目录）

## 目标

仓库 `<仓库路径>`（GitHub `<owner/name>`）的地图 #<地图号>「<地图标题>」里，
research 票 #<票号>「<票标题>」已在前沿：它开着、阻塞全关、没有 Assignee。
你要调查它的问题，给出可以记录进票和地图的结论。主会话会复核你的结论，
再按 wayfinder 的格式写 Resolution、关票、更新地图；你不要做这些写操作。

## 先读

- 票和评论：`gh issue view <票号> --repo <owner/name> --comments`
- 地图和已有关联决策：`gh issue view <地图号> --repo <owner/name> --comments`
- 相关规格、执行票、ADR 和代码（按票里的指针补全）：
  <这里列出主会话已经确认的相关文件或 issue，没有写「无」>
- wayfinder 的 Resolution / Decisions-so-far 格式：
  <wayfinder SKILL.md 路径>

## 要求

1. 只回答这张票的 Question，不扩展成实现方案，不改规格或执行票。
2. 结论必须区分事实、推断和未决取舍；每条事实给 issue 评论、文件、ADR 或代码位置。
3. 若调研揭示新的票或应从 fog 中毕业的问题，用一行提出，不自行建票。
4. 若结论需要用户在互斥选项间拍板，不要替用户选；把它写成待决问题、2–4 个选项、代价和推荐答案。

## 输出

写 `<运行目录>/resolution.md`，只包含：

```
## Resolution 草稿

<一两段结论；可直接作为 resolution comment 发布>

依据：
- <issue 评论 / 文件:行 / ADR：一句事实>

地图索引行草稿：
- [<票标题>](<票链接>)：<一行答案>

新增/毕业票据建议：
- <没有写「无」>

需要用户拍板：
- <没有写「无」；有问题时写问题、选项、代价、推荐答案>
```

最终回复不超过 15 行：结论一两句、`resolution.md` 的路径、是否需要用户拍板。
wrapper 会把最终回复存成 `result.md`；不要自己写 `result.md`。

## 不要做

- 不认领、不评论、不关票、不改标签、不改地图、不建新 issue
- 除 `<运行目录>/resolution.md` 外不改动任何文件，不 commit
- 不递归删除目录，不绕过仓库或全局代理的网络限制
