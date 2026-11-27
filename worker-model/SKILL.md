---
name: worker-model
description: 查看或切换全局 Worker model 开关——codex worker（External worker）写代码、读材料用的模型，默认 glm-5.4，可切到 glm-5.3 或 glm-5.3-flash。输入 /worker-model 时使用；可以带「到 <时间>」或「<时长>」，不带参数只查看状态。
disable-model-invocation: true
---

# worker-model

开关属于用户，是全局的：`~/.claude/state/worker-model`，对所有走 `codex-worker.sh` 的 External worker 生效——`--impl codex` 的实现角色、find-next 派的 codex worker（调研、决策、起草）、全局分工里的日常派活（ADR 0003）。wrapper 每次新起 worker 时读它，所以正在跑的 Run 下一次派发就是新模型，不用重启；已经在跑的 worker 不变，续跑（Resume）沿用第一段的模型。它不管 `agent` 后端和 pi：flash 环境默认的 agent 后端不经过它，那些运行的子代理型号由启动器决定。

本技能只运行 `worker-model.sh` 并转述它打印的状态行：不改开关文件，不替用户决定切不切，也不做别的事。

1. 把用户写在命令后面的文字翻译成一条 `use` 命令：
   - 模型的说法：`glm-5.4`、`glm 5.4`、`glm5.4`、「切回」「用回默认」「复位」是 `glm-5.4`（也就是复位）；`glm-5.3`、`glm 5.3` 是 `glm-5.3`；`glm-5.3-flash`、`flash`、「用 flash 写」是 `glm-5.3-flash`。
   - 时间（可选，只对替代型号有意义）：「到 <某个时间>」或 `until <time>` 写成 `--until <ISO 8601 含时区>`，例如 `--until 2026-11-28T10:00:00+08:00`；「<多久>」或 `for <duration>` 写成 `--for <时长>`，例如 5 小时是 `5h`、半小时是 `30m`、两天是 `2d`、一天半是 `1d12h`。换算前先用 Bash 运行 `date '+%Y-%m-%d %H:%M:%S %z'` 看今天的日期和时区。用户说的时间定不下是哪一天，或者写不成这两种形式，就问一句再运行。
   - 用户要切回默认又带了时间：不运行脚本，告诉用户到期只对替代型号有意义，复位直接 `/worker-model use glm-5.4`。
   - 认不出模型：不运行脚本，告诉用户可以这么写：`/worker-model`、`/worker-model use glm-5.3`、`/worker-model use glm-5.3-flash 到 明早 7:00`、`/worker-model use glm-5.4`。
2. 用 Bash 运行，放前台，不要后台：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/worker-model.sh use <模型> [--until <时间> | --for <时长>]
   ```

   只查看时运行同一条命令但不带 `use …`。退出码 64 是写法不对，把 stderr 原样告诉用户。其他非 0 退出码同样原样转述；不要因此自己去改开关文件。
3. 回复直接以脚本打印的状态行开头，原样照抄：前面不加标题或说明，外面不加代码围栏。脚本在 stderr 给了「不在 worker 模型目录」的警告时，把那一行也原样转述，并提醒先做验证：`scripts/selftest-codex.sh --only L1 --model <型号>`；报错指向型号或目录时，在 `~/.codex/models.json` 补条目、重跑 `scripts/setup-worker-home.sh`（直接改 `~/.codex-worker/models.json` 会被下次重跑覆盖）。空一行，再用一两句说明这次改动意味着什么：
   - 设成替代型号：之后新起的 codex worker 都用它；正在跑的 Run 从下一次派发起生效，已经在跑的 worker 不变，续跑（Resume）仍用第一段的模型。开关生效期间调用方显式传的 `--model` 会被覆盖，wrapper 会在 stderr 和运行目录的 `stderr.log` 里写一行说明。
   - 某一行写着「不会自动切回」：提醒一句，切回用 `/worker-model use glm-5.4`。
   - 回到默认：从下一次派发起恢复 glm-5.4，显式 `--model` 重新生效。
