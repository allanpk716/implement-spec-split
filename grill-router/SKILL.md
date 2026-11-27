---
name: grill-router
description: 查看或切换阶段路由表——编排、讨论、调研起草、实现、审查、诊断六个阶段各用哪个启动器档案、模型和思考强度，可带到期时间。输入 /grill-router 时使用；用户说「路由」「切换路由」「哪个阶段用哪个模型」「把审查换成 glm」时也用，例如「/grill-router 审查用 glm 5.4」「/grill-router 讨论切到 glm，强度 medium，到明早十点」「/grill-router 实现用 glm-5.3 持续 5 小时」，不带参数只查看；「迁移旧开关」（/judgment-model、/worker-model 的设置）时也用。
disable-model-invocation: true
---

# grill-router

路由表属于用户，是全局的：`~/.claude/state/stage-route`，六个阶段各有一行路由（档案 / 模型 / 思考强度，可带到期）。改动对正在跑的会话和 worker 不生效，从该阶段的下一次派发、或下一次新开的 Design session 起生效（ADR 0004）。编排阶段锁定在 claude-flash，不可改。

本技能只运行 `stage-route.sh` 并转述它打印的六行状态：不改状态文件，不替用户决定切不切，也不做别的事。

1. 把用户写在命令后面的文字翻译成 `阶段=档案/模型/思考强度`：
   - 「迁移旧开关」「迁移」「把旧开关的设置拿过来」「migrate」：运行 `stage-route.sh migrate`（第 2 步的命令，把 `use …` 换成 `migrate`，不带别的参数）。它把两个旧开关的状态文件 `~/.claude/state/judgment-model`（旧 grill → 讨论，旧 review → 审查和诊断）和 `~/.claude/state/worker-model`（旧 worker → 调研起草和实现）里未到期的设置迁进路由表：思考强度取 `high`，到期时间照搬；迁不进的（模型不在已验证目录，例如 worker 的 glm-5.3-flash）保留旧文件；新表里已经设过且仍在生效的阶段不覆盖。脚本第一次运行（路由表文件还不存在时，跑的是哪条命令都算）会自己先这样迁移一次，之后只有 `migrate` 会迁。不要自己去读、改或删那两个旧文件，也不运行旧开关的脚本。
   - 阶段的说法：「编排」是 `orchestration`（锁定，不能设，用户要改就说明这一点）；「讨论」「设计讨论」「grill」是 `design`；「调研」「起草」「调研起草」「研究」是 `research`；「实现」「写代码」是 `implementation`；「审查」「审核」「review」是 `review`；「诊断」「排查失败」是 `diagnosis`。用户说「审查和诊断」就两个都写。
   - 档案的说法：「官方」「opus 订阅」「claude」是 `claude`；「glm 启动器」「claude-glm」是 `claude-glm`；「flash 启动器」「claude-flash」是 `claude-flash`；「codex」「codex-glm」是 `codex-glm`。
   - 模型的说法：`opus`；`glm-5.4`（「glm 5.4」「glm5.4」「用 glm 顶上」）；`glm-5.3`。`glm-5.3-flash` 只作编排的锁定默认，不给别的阶段设。用户只说模型没说档案：`opus` 配 `claude`，`glm-5.3` 配 `codex-glm`，`glm-5.4` 配该阶段当前的档案，当前档案的目录里没有它就配 `claude-glm`。
   - 思考强度的说法：`low`、`medium`、`high`、`xhigh`、`max`；「强度」「思考强度」「effort」都指它。用户没说强度：沿用该阶段当前的强度，新档案不接受时（codex 没有 `max`）用 `high`。
   - 用户只说了档案没说模型：用那个档案最顺的模型——`claude` 配 `opus`，其余三个配 `glm-5.4`。
   - 时间（可选，对这次设的所有阶段生效）：「到 <某个时间>」或 `until <time>` 写成 `--until <ISO 8601 含时区>`，例如 `--until 2026-11-28T10:00:00+08:00`；「<多久>」或 `for <duration>` 写成 `--for <时长>`，例如 5 小时是 `5h`、半小时是 `30m`、两天是 `2d`、一天半是 `1d12h`。换算前先用 Bash 运行 `date '+%Y-%m-%d %H:%M:%S %z'` 看今天的日期和时区。用户说的时间定不下是哪一天，或者写不成这两种形式，就问一句再运行。
   - 「切回」「恢复默认」：把该阶段设回默认路由——六行状态里该行「切回用 /grill-router use」后面那串就是。
   - 认不出阶段、档案或模型：不运行脚本，告诉用户可以这么写：`/grill-router`、`/grill-router 审查用 glm 5.4`、`/grill-router 讨论用 claude-glm 的 glm-5.4，强度 medium`、`/grill-router 审查切到 glm-5.4 到 11-28 10:00`、`/grill-router 实现用 glm-5.3 持续 5 小时`。不要猜。
2. 用 Bash 运行，放前台，不要后台：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use <阶段=档案/模型/思考强度> [<阶段=档案/模型/思考强度> ...] [--until <时间> | --for <时长>]
   ```

   一次设两样就是 `use design=claude-glm/glm-5.4/high review=claude-glm/glm-5.4/medium`。只查看时运行同一条命令但不带 `use …`；迁移旧开关时把 `use …` 换成 `migrate`。退出码 64 是写法不对或被拒绝（目录外的组合、编排阶段、档案不接受的强度），把 stderr 原样告诉用户。其他非 0 退出码（例如迁移时路由表写不成是退出码 65）同样原样转述；不要因此自己去改状态文件。
3. 回复直接以脚本打印的六行状态开头，原样照抄：前面不加标题或说明，外面不加代码围栏。stderr 里有警告或提示（审查与实现同模型、状态文件损坏或含未知组合、旧开关迁移的说明——已迁移、已到期不迁入、迁不进并保留旧文件、旧文件已删除）也原样转述。空一行，再用一两句说明这次改动意味着什么：
   - 有迁移说明：提醒一句，旧开关的设置已经进路由表（或者哪些没进来、为什么），以后切换只用 `/grill-router`。
   - 正在跑的会话和 worker 不受影响：讨论从下一次新开的 Design session 起用新路由（已经开着的要重开），审查、诊断、调研起草、实现从下一次派发起生效。
   - 某一行写着「不会自动切回」：提醒一句，切回用 `/grill-router <阶段>=<该行「切回用」后面那串>`。
   - 某一行带到期时间：说明到点自动回到默认。
