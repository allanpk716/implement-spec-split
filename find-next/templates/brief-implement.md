<!--
implement-spec-split 票实现类 Brief 模板（规格 #26）。规格会话经 scripts/stage-dispatch.sh 派发一个
Orca worker 去做一张执行票（--role implement --ticket <m>）时，复制本文件到
<Spec Run root>/briefs/implement-<m>[-<attempt>].md，填好 <...>，删掉本注释和不适用的节。
每份 Brief 从头写，不要用 sed 或查找替换从另一份改出来（票号、分支名会留下）。

只带产物，不带规格会话的过程：规格 issue 内容 + 探索笔记（相关文件与调用关系）+ 票 issue 内容。
规格会话里怎么讨论、试过什么、为什么派这张票，一律不写——worker 看不到那段对话，也不需要。
worker 多半是精简启动（--bare：不加载 CLAUDE.md、技能、插件和 hooks），它要遵守的规则必须都在
本 Brief 和精简规则文件（templates/lean-rules.md，#39）里，不能指望 Skill 工具或 hook。
fix / 冲突角色（--role fix / --role merge）沿用本模板：把「票内容」换成审查报告或冲突文件清单的指针，
工作区是集成分支的规格工作区，并在「要求」里写明只做审查项 / 只解冲突。
-->

# 任务：实现规格 #<n> 的执行票 #<m>（<一句话目标>）

## 工作区与分支

- 工作区：`<...>`，分支 `spec-<n>-t<m>`，基于集成分支 `spec-<n>`。开工前确认 `git merge-base --is-ancestor spec-<n> HEAD` 成立；不成立就 `git reset --hard spec-<n>`。
- 集成分支由调用方用脚本合入。你不要合并任何分支（包括集成分支的最新提交）、不要 push、不要碰别的工作区。
- 运行目录（工作区之外）：`<dispatch dir>`；报告路径以派发前言给的为准（`<dispatch dir>/report.md`）。

## 先读（三样产物）

1. **规格内容**——规格 issue #<n> 正文，原样：
   <粘贴 `gh issue view <n> --repo <owner/name>` 的正文。太长时只留 Problem Statement、与本票有关的 User Stories 和 Implementation Decisions，并注明「已节选」。>
2. **探索笔记**——规格开始前一次只读探索写下的，这里只摘与本票相关的部分：
   - 笔记全文：`<Spec Run root>/research/notes.md`
   - 相关文件：`<文件>:<行号>`——<它是什么、谁调用它、本票要动它哪里>
   - 调用关系：`<函数 (文件:行号) -> 函数 (文件:行号) -> …>`
   - 不要碰的文件 / 已知约束：<...；没有写「无」>
3. **票内容**——票 issue #<m> 正文，原样：
   <粘贴 `gh issue view <m> --repo <owner/name>` 的正文，含验收清单。>

## 要求

1. 测试先行：先写会失败的测试，再写实现让它通过，再重构；每一步都跑测试。测试命令见「验收命令」。
2. 自己提交：每个逻辑步骤一个 commit（消息用仓库惯用的语言，写明票号 `#<m>`）；结束前工作区必须干净（`git status --porcelain` 为空），不留未提交或未跟踪的文件。
3. 不要再派发任何 worker 或子代理，不要启动另一个 claude / codex 进程；必须等待时在前台等够，不要起后台进程后就结束。测试与验证一律前台跑完再交最终报告；不得把测试放到后台然后结束回合——worker 空闲后不会被唤醒，后台收尾等于失联。「验收命令」在前台逐条跑完、看到退出码，再写报告、再发 `worker_done`；命令太久被挪到后台的，继续在前台等它结束。
4. If a source-write hook blocks you, stop and state that in your report. Do not work around it: do not use `env -u FLASH_ORCHESTRATOR`, do not start another `claude`, `claude-glm`, or `codex` process, do not use `orca orchestration worker-start`, and do not write source through Bash to bypass the hook.
5. Run any `rm` as its own Bash command with literal paths: no variables, globs, `$(...)`, or `sh -c` strings, and never chained with `&&`, `;` or pipes. Do not pass `rm` as an argument to a wrapper script; call `docker rm <name>` directly. Prefer fresh directory names over deleting and recreating one.
6. 范围：只做「期望改动」列出的修改点。范围外的问题写进报告，不要顺手改。设计级或微妙正确性的问题不要猜，写进报告交回，由调用方决定。
7. git 命令因已存在的 `.lock` 文件失败时（多个 Run 共用一个仓库），等几秒重试，最多 3 次；绝不删 `.lock` 文件。

### ops 票（仅在票是 ops 票时保留本节；ops 票不要求第 1、2 条）

- 本票经 ssh-manager 执行：可以用 `mcp__ssh-manager__*` 工具（调用方已用 `--mcp-config` 加上）。先 `mcp__ssh-manager__list_servers` 拿真实 `server_id`，读该服务器的 `caveats` / `role` / `services` 再动手，不要凭记忆猜主机。
- 护栏（票的 `## 护栏` 一节，原样）：
  <原样粘贴>
- 护栏挡住你要做的事、或验收标准达不到时，只报告、不硬推；报告里写清远端改了什么、怎么回滚。
- 没改代码时，验收标准每一条都要有证据（命令输出、服务状态、截图）。

## 期望改动

1. <具体修改点；引用上面「相关文件」的 `文件:行号`>
2. <...>

## 验收命令

在工作区里按顺序执行，全部通过才算完成：

```
<命令 1，例如 bash scripts/test-xxx.sh>
<命令 2>
```

## 环境约束（找文件与子进程）

- Brief 里引用的仓库外文件都是确切路径（写 Brief 前已用系统索引或 `ls` 核实存在）。某个路径定位不到时，在输出里明写「未定位到，不作为依据」，不要按模糊路径自行全盘搜索。
- 不对 `$HOME` 或仓库目录之外做无边界 `find`：云盘同步目录（如 macOS 的 `~/Library/CloudStorage`）会被它触发按需拉取，看起来就像卡死。要搜系统用系统索引（macOS 用 `mdfind`；其他平台用系统索引工具或对已知子目录定点查找）；非用 `find` 不可时，剪枝挂载点本身，如 `find "$HOME" -path "$HOME/Library/CloudStorage" -prune -o …`。注意 `-not -path` 只过滤输出、不剪枝，照样会走进挂载。
- 测试或长命令要在前台等它跑完再收尾：不得把它放到后台然后结束回合——空闲后不会被唤醒，后台收尾等于失联。
- 不得用 `bash -c`、`sh -c`、`$'…'` 内联包裹多行脚本（含 `rm` / `del` 等删除类命令时尤其如此）——bypass 模式（`--dangerously-skip-permissions`）下权限层照样会对内联脚本里的删除命令弹确认框，无人值守的会话没人回答就卡死。多行脚本写进 `mktemp -d` 目录下的脚本文件执行，脚本里配 `trap` 清理；或拆成多次独立调用。脚本自身 `trap` 清理它的 `mktemp -d` 目录除外，其他删除一律单独 `rm` 带字面路径。
- 结束前收割自己起的、仍在跑的长子进程（起时记下 pid，结束时 kill），不要留下卡死的孤儿进程。

## 禁区

- 不要修改：<文件或目录>
- 不要新增依赖（除非上面写明）
- 不合并、不 push、不开 PR、不碰 issue（不评论、不关票、不改标签）

## 报告（写进运行目录的报告路径，不写在工作区里）

报告写上面的报告路径——它在工作区之外，删工作区不丢；不要写在工作区里。内容：

1. **改动摘要**：改了哪些文件、各做了什么（每个文件一两行）；提交列表（`git log --oneline spec-<n>..HEAD`）。
2. **验收证据**：对每条验收命令写出命令原文、退出码、输出末尾（最多 30 行，原样粘贴，不要概括）。
3. **未完成或偏离 Brief 之处**：没有就写「无」。
4. **范围外发现 / 设计级疑问**：没有就写「无」。

## 完成后（worker_done）

报告写完后，最后一步按 Orca 前言给的**完整命令**发送 `worker_done`：必须带 `--task-id`（缺了会被拒收），`--outcome succeeded`（没完成就 `failed`），`--report-path` 指向上面的报告路径。发送就是本会话的最后一步，之后本会话会被关闭。不要把报告内容当作最终回复来代替发送。
