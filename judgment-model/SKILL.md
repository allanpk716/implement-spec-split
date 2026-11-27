---
name: judgment-model
description: 查看或切换全局判断模型开关——grill 讨论和其余 Opus 用途各用 opus 还是 glm-5.4。输入 /judgment-model 时使用；一条命令可以同时设两样，例如「/judgment-model 讨论用 opus，其他用 glm 5.4」，可以带「到 <时间>」或「<时长>」，不带参数只查看状态。
disable-model-invocation: true
---

# judgment-model

开关属于用户，是全局的：`~/.claude/state/judgment-model`，对正在跑的会话从下一次 Opus review、或下一次新开的 Design session 起生效（ADR 0002）。它分两个角色，各用各的模型：

- `grill`：Design session 讨论，也就是 `/grill-feature`、`/grill-map`，以及 find-next 里回「展开」开的讨论。
- `review`：其余全部 Opus 用途，即 Opus review 的三类——代码审核、草稿审读、失败诊断。

本技能只运行 `judgment-model.sh` 并转述它打印的两行状态：不改开关文件，不替用户决定切不切，也不做别的事。

1. 把用户写在命令后面的文字翻译成 `角色=模型`：
   - 角色的说法：「讨论」「grill」「设计讨论」是 `grill`；「其他」「其余」「审查」「review」是 `review`。用户只说「其他用 …」而没提讨论时，只设 `review`，讨论保持原样。
   - 模型的说法：`opus`、「切回」「用回 Opus」是 `opus`；`glm-5.4`、`glm 5.4`、`glm5.4`、「用 glm 顶上」是 `glm-5.4`。
   - 用户只写了一个模型、没说给谁：两个角色都设成它，写成不带角色的 `glm-5.4` 或 `opus`。
   - 写了两个模型却没说哪个给谁：问一句，不要猜。
   - 时间（可选，对这次设成 glm-5.4 的角色都生效）：「到 <某个时间>」或 `until <time>` 写成 `--until <ISO 8601 含时区>`，例如 `--until 2026-11-28T10:00:00+08:00`；「<多久>」或 `for <duration>` 写成 `--for <时长>`，例如 5 小时是 `5h`、半小时是 `30m`、两天是 `2d`、一天半是 `1d12h`。换算前先用 Bash 运行 `date '+%Y-%m-%d %H:%M:%S %z'` 看今天的日期和时区。用户说的时间定不下是哪一天，或者写不成这两种形式，就问一句再运行。
   - 认不出角色也认不出模型：不运行脚本，告诉用户可以这么写：`/judgment-model`、`/judgment-model glm-5.4`、`/judgment-model 讨论用 opus，其他用 glm 5.4`、`/judgment-model 其他用 glm-5.4 到 11-28 10:00`、`/judgment-model opus`。
2. 用 Bash 运行，放前台，不要后台：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/judgment-model.sh use <角色=模型> [<角色=模型>] [--until <时间> | --for <时长>]
   ```

   一次设两样就是 `use grill=opus review=glm-5.4`。只查看时运行同一条命令但不带 `use …`。退出码 64 是写法不对，把 stderr 原样告诉用户。其他非 0 退出码同样原样转述；不要因此自己去改开关文件。
3. 回复直接以脚本打印的两行状态开头，原样照抄：前面不加标题或说明，外面不加代码围栏。空一行，再用一两句说明这次改动意味着什么：
   - `grill` 是 `glm-5.4`：之后新开的 Design session 由 glm-5.4 执行；已经开着的要重开，或者在那个仓库的终端里用 `claude-glm --resume` 续接原对话。
   - `review` 是 `glm-5.4`：正在跑的会话从下一次 Opus review 起由 glm-5.4 审查，正在进行的那一次不变。
   - 某一行写着「不会自动切回」：提醒一句，切回用 `/judgment-model <角色>=opus`。
   - 角色回到 `opus`：从下一次审查、或下一次新开的 Design session 起恢复 Opus。
