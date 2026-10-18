<!--
Implementation Brief template. Copy it into <run dir>/brief.md, fill every <...>,
delete sections that do not apply, and delete this comment. Write each Brief fresh;
do not sed-derive one Brief from another.
-->

# 任务：<一句话目标>

## 目标

<要达成什么；完成后的可观察行为>

## 上下文

- 仓库：`<路径>`，分支 / worktree：`<...>`
- 相关文件：
  - `<文件>:<行号>`：<它是什么，为什么相关>
- 先读：<CLAUDE.md、AGENTS.md、设计文档等>

## 根因 / 设计决定

<已经定下的判断：根因、选定的方案、为什么不选别的方案。worker 不要重新做这些决定。>

## 期望改法

1. <具体修改点>
2. <...>

## 验收命令

按顺序执行，全部通过才算完成：

```
<命令 1>
<命令 2>
```

## 禁区

- 不要修改：<文件或目录>
- 不要新增依赖（除非上面写明）
- <其他>

## 固定条款

- 不要 `git commit`，提交由调用方完成。
- 不要递归删除目录（`rm -rf`、`Remove-Item -Recurse`）；需要清理时在报告里说明。
- 只做本 Brief 范围内的事；发现范围外的问题写进报告，不要顺手改。

## 报告要求（写进最终回复，即 result.md）

1. **改动摘要**：改了哪些文件、各做了什么（每个文件一两行）。
2. **验收证据**：对每条验收命令写出：
   - 命令原文
   - 退出码
   - 输出末尾（最多 30 行，原样粘贴，不要概括）
3. **未完成或偏离 Brief 之处**：没有就写"无"。
4. **范围外发现**：没有就写"无"。
