<!--
Implementation Brief template. Copy it into <run dir>/brief.md, fill every <...>,
delete sections that do not apply, and delete this comment. Write each Brief fresh;
do not sed-derive one Brief from another.
When the implement-spec-split implementing-role flow requires the worker to commit
its own steps, delete the "不要 git commit" fixed rule below and state the commit
requirement under 期望改法.
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

## 环境约束（找文件与子进程）

- Brief 里引用的仓库外文件都是确切路径（写 Brief 前已用系统索引或 `ls` 核实存在）。某个路径定位不到时，在输出里明写「未定位到，不作为依据」，不要按模糊路径自行全盘搜索。
- 不对 `$HOME` 或仓库目录之外做无边界 `find`：云盘同步目录（如 macOS 的 `~/Library/CloudStorage`）会被它触发按需拉取，看起来就像卡死。要搜系统用系统索引（macOS 用 `mdfind`；其他平台用系统索引工具或对已知子目录定点查找）；非用 `find` 不可时，剪枝挂载点本身，如 `find "$HOME" -path "$HOME/Library/CloudStorage" -prune -o …`。注意 `-not -path` 只过滤输出、不剪枝，照样会走进挂载。
- 结束前收割自己起的、仍在跑的长子进程（起时记下 pid，结束时 kill），不要留下卡死的孤儿进程。

## 禁区

- 不要修改：<文件或目录>
- 不要新增依赖（除非上面写明）
- <其他>

## 固定条款

- 不要 `git commit`，提交由调用方完成。
- 不要递归删除目录（`rm -rf`、`Remove-Item -Recurse`）；需要清理时在报告里说明。
- 只做本 Brief 范围内的事；发现范围外的问题写进报告，不要顺手改。
- 测试与验证一律前台跑完再交最终报告；不得把测试放到后台然后结束回合——空闲后不会被唤醒，后台收尾等于失联。
- 不得用 `bash -c`、`sh -c`、`$'…'` 内联包裹多行脚本（含 `rm` / `del` 等删除类命令时尤其如此）：多行脚本写进 `mktemp -d` 目录下的脚本文件执行，或拆成多次独立调用；临时目录的清理照上面「不要递归删除目录」那条，在报告里说明。

## 报告要求（写进最终回复，即 result.md）

1. **改动摘要**：改了哪些文件、各做了什么（每个文件一两行）。
2. **验收证据**：对每条验收命令写出：
   - 命令原文
   - 退出码
   - 输出末尾（最多 30 行，原样粘贴，不要概括）
3. **未完成或偏离 Brief 之处**：没有就写"无"。
4. **范围外发现**：没有就写"无"。
