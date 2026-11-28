<!--
find-next 推进模式迷雾毕业 Brief 模板。复制到 <运行目录>/brief.md，
填好 <...>，删掉本注释。
-->

# 任务：为 wayfinder 地图提出迷雾毕业建议（只读）

## 目标

仓库 `<仓库路径>`（GitHub `<owner/name>`）的地图 #<地图号>「<地图标题>」
决策票已全关，但 `## Not yet specified` 仍有迷雾。你要根据地图和已有 Resolution，
判断哪些雾已经可以毕业成票、哪些应判出范围或作废。主会话会复核你的建议，
和其他要拍板的条目合成一轮按推荐自动拍板（可推翻）；拍板后才由主会话建票、接线、改地图。

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

## 环境约束（找文件与子进程）

- Brief 里引用的仓库外文件都是确切路径（写 Brief 前已用系统索引或 `ls` 核实存在）。某个路径定位不到时，在输出里明写「未定位到，不作为依据」，不要按模糊路径自行全盘搜索。
- 不对 `$HOME` 或仓库目录之外做无边界 `find`：云盘同步目录（如 macOS 的 `~/Library/CloudStorage`）会被它触发按需拉取，看起来就像卡死。要搜系统用系统索引（macOS 用 `mdfind`；其他平台用系统索引工具或对已知子目录定点查找）；非用 `find` 不可时，剪枝挂载点本身，如 `find "$HOME" -path "$HOME/Library/CloudStorage" -prune -o …`。注意 `-not -path` 只过滤输出、不剪枝，照样会走进挂载。
- 测试或长命令要在前台等它跑完再收尾：不得把它放到后台然后结束回合——空闲后不会被唤醒，后台收尾等于失联。
- 不得用 `bash -c`、`sh -c`、`$'…'` 内联包裹多行脚本（含 `rm` / `del` 等删除类命令时尤其如此）——bypass 模式（`--dangerously-skip-permissions`）下权限层照样会对内联脚本里的删除命令弹确认框，无人值守的会话没人回答就卡死。多行脚本写进 `mktemp -d` 目录下的脚本文件执行，脚本里配 `trap` 清理；或拆成多次独立调用。脚本自身 `trap` 清理它的 `mktemp -d` 目录除外，其他删除一律单独 `rm` 带字面路径。
- 结束前收割自己起的、仍在跑的长子进程（起时记下 pid，结束时 kill），不要留下卡死的孤儿进程。

## 不要做

- 不建票、不评论、不关票、不改标签、不改地图、不接阻塞
- 不改 `<运行目录>/fog.md` 以外的任何文件，不 commit
- 不递归删除目录，不绕过仓库或全局代理的网络限制
