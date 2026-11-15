<!--
find-next 推进模式迷雾毕业 Brief 模板。复制到 <运行目录>/brief.md，
填好 <...>，删掉本注释。
-->

# 任务：为 wayfinder 地图提出迷雾毕业建议（只读）

## 目标

仓库 `<仓库路径>`（GitHub `<owner/name>`）的地图 #<地图号>「<地图标题>」
决策票已全关，但 `## Not yet specified` 仍有迷雾。你要根据地图和已有 Resolution，
判断哪些雾已经可以毕业成票、哪些应判出范围或作废。主会话会复核你的建议，
合成到一轮里问用户；用户同意后才由主会话建票、接线、改地图。

## 先读

- 地图与评论：`gh issue view <地图号> --repo <owner/name> --comments`
- 已关闭决策票及 Resolution（至少包括：<票号列表；没有写「无」>）：
  `gh issue view <票号> --repo <owner/name> --comments`
- 相关规格 / ADR / 代码：<主会话列出的指针；没有写「无」>
- wayfinder 的 Fog of war、Out of scope、Work through the map 规则：
  <wayfinder SKILL.md 路径>

## 要求

1. 只处理地图目的地范围内的雾；已经由 live ticket 或已关闭决策覆盖的内容不要重复建议。
2. 每条新建票建议必须已经能把 Question 写尖锐；仍说不清的问题留在「毕业后剩下的迷雾」。
3. 建议判出范围或作废时，给出地图目的地或某条 Resolution 的依据，不凭偏好裁剪边界。
4. 阻塞对象只能建议已有的真实票号，或写「无」；不使用占位编号。

## 输出

写 `<运行目录>/fog.md`，只包含：

```
## 建议新建票

- Question：<精确问题>
  Type：<research|prototype|grilling|task>
  Blocked by：<#票号 / 无>
  Why now：<哪条 Resolution 让它可提问>

## 要从 Not yet specified 移除的段落

<原样摘录可删除的一小段；没有写「无」>

## 建议判出范围或作废的票

- #<票号> <标题>：<判出范围 / 作废；理由；对地图边界的影响>

## 毕业后剩下的迷雾

<仍留在 Not yet specified 的一小段；没有写「无」>
```

最终回复不超过 12 行：建议新建 N 张、判出范围/作废 N 张、剩余迷雾一句、`fog.md` 路径。
wrapper 会把最终回复存成 `result.md`；不要自己写 `result.md`。

## 不要做

- 不建票、不评论、不关票、不改标签、不改地图、不接阻塞
- 不改 `<运行目录>/fog.md` 以外的任何文件，不 commit
- 不递归删除目录，不绕过仓库或全局代理的网络限制
