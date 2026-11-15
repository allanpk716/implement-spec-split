<!--
find-next 推进模式 prototype 票 Brief 模板。复制到 <运行目录>/brief.md，
填好 <...>，删掉本注释。主会话会复核原型、提交 mockit 或 push 临时分支。
-->

# 任务：为 wayfinder prototype 票 #<票号> 做粗原型

## 目标

仓库 `<仓库路径>`（GitHub `<owner/name>`）的地图 #<地图号>「<地图标题>」里，
prototype 票 #<票号>「<票标题>」需要一件便宜的粗原型来让人反应。你要产出原型和使用说明；
主会话复核后负责发布原型链接、问用户反应，再写 Resolution。

## 先读

- 票和评论：`gh issue view <票号> --repo <owner/name> --comments`
- 地图与相关 Resolution：`gh issue view <地图号> --repo <owner/name> --comments`
- UI 原型的 mockit 技能规则：<mockit SKILL.md 路径>
- 相关代码 / 设计材料：<主会话列出的指针；没有写「无」>

## 原型形态

- 形态：<UI / 非 UI；主会话按票 Question 预判，worker 可在最终回复中说明更合适的形态>
- 目的反应：<要让用户看懂并反应的一个问题>

## 要求

1. UI 原型按 mockit 技能做成独立页面，放在 `<运行目录>/mockit/`，不接入生产路由。
2. 非 UI 原型从当前默认分支新建本地分支 `prototype/<票号>`，把原型放在该分支；
   可以提交本地 commit，但不得 push、不开 PR、不合并。
3. 原型要便宜、粗糙、能比较真实地暴露关键取舍；不追求生产质量，不扩大实现范围。
4. 明确写出给用户看的一句话问题，以及原型中每个可反应差异的位置。

## 输出

写 `<运行目录>/prototype.md`，只包含：

```
形态：<UI mockit / 非 UI 临时分支>
位置：<运行目录内路径 / prototype/<票号> 分支与入口>
要反应的问题：<一两句>
使用/查看步骤：<编号步骤>
关键差异：<2–4 条；每条对应一个取舍>
Resolution 草稿：<概括原型事实和仍待用户反应的点，不替用户表态>
```

最终回复不超过 12 行：形态、位置、要反应的问题、`prototype.md` 路径。
wrapper 会把最终回复存成 `result.md`；不要自己写 `result.md`。

## 不要做

- 不 push、不开 PR、不合并、不改 main / 默认分支
- 不认领、不评论、不关票、不改标签、不建 issue、不改地图
- UI 页面留在运行目录；除 Brief 说明的非 UI 临时分支外，不改目标仓库
- 不递归删除目录，不绕过仓库或全局代理的网络限制
