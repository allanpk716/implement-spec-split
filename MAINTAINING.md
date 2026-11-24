# 维护说明 / 注意事项

本技能由 Matt Pocock 的 `implement-spec` 改写而来。下面记录改写时做过的决定和踩过的坑。同步上游或修改 `SKILL.md` 前请先读一遍，避免把问题改回去。

## 设计要点（不要改回去）

1. **每个子代理都要显式传 `model`。** 原版的子代理都继承会话模型，这也是做这个技能的原因。别让任何一步依赖继承，会话本身可能是任何模型。
2. **不要调用原版 `implement-spec`。**
   - 原版设了 `disable-model-invocation: true`，模型用 Skill 工具调用它会失败。
   - 就算能调，它会自己跑 review，而那次 review 用的是继承来的会话模型。
   - 所以 `SKILL.md` 自己写全了全部步骤，同步上游时要把变化手动搬进来。
3. **review 必须写全名 `mattpocock-skills:code-review`。**
   - Claude Code 有个同名的内置技能 `code-review`。它不会开 Standards 和 Spec 两个子代理，也就没法给它们指定 Opus。
   - 只写 `code-review` 可能调错技能，Opus review 就落空了。
   - 同理，`tdd` 写成全名 `mattpocock-skills:tdd`。
4. **编排的主代理跑在会话模型上。** 只有子代理的模型由本技能决定。主代理要判断 review 意见属于设计层面还是机械修复，所以会话不建议用太弱的模型。
5. **draft PR 流程。** 如果 tracker 靠 PR 关单，第一次合并后开 draft PR，最后标成可以 review。原版有这一步，最早的 split 版漏了，后来补回。
6. **找 spec（第 0 步）。** 原版没有这一步，是本技能加的。现在用 `scripts/pipeline-status.sh` 按 to-spec 模板标题 `## Problem Statement` 和 wayfinder 地图结构识别 Spec / Ticket，再保留旧的“开着父 issue + 未完成子票”形状；不要改回依赖标题里的“规格：”字样。原因是单票规格的正文只引用地图实现票（例如“实现票：#58”），实现票自己没有子票，旧的父 issue 查询会把它漏掉。
7. **push 和关单前先问用户。** 本技能加了这条，原版没有。例外是第 21 条（2026-11-24 由第 28 条修订）的无人值守落地：launch-wave 启动的会话默认带 `--auto-land`，不再问；显式 `--no-auto-land` 的批除外。
8. **GLM 只能放到会话外面跑（External worker）。**
   - Agent 工具的 `model` 参数只能选 `sonnet`、`opus`、`haiku`、`fable`。
   - 服务地址和 token 是整个进程共用的，所以没法让会话里的某一个子代理单独走 GLM。
   - 所以要另起一个 CLI 进程来跑 GLM，会话里只留下主代理和 review。
   - 2026-11-14 例外：新增 `agent` 后端。在 GLM 代理环境下，Agent 工具显式传 `model: opus` 实际会映射到 GLM-5.3（已实测），此时实现角色可以直接开会话内子代理，不必另起 codex/pi 进程。这是用户显式选择的后端（`--impl agent [--agent-model <model>]`），不是 codex/pi 出错后的降级路径；模型只允许 `sonnet|opus|haiku|fable`，`--impl sonnet` 是把模型钉在 sonnet 的兼容别名。
9. **External worker 用 codex（首选）或 pi，不用 `claude -p`。**
   - `claude -p` 接 GLM 跑无头模式，会被检测、被限流，下午高峰期更明显。这是用户实际用下来的经验。
   - 以前不用 codex 的几条理由，2026-10-17 的实验大多推翻了（证据见 `docs/codex-backend.md`）：
     - 不读 `CLAUDE.md`：加 `-c 'project_doc_fallback_filenames=["CLAUDE.md"]'` 就读（E2）；
     - 加载不了 tdd 技能：在提示词里写"先读 `<tdd dir>/SKILL.md`"就行，wrapper 的 `--skill` 就是这么做的（E3）；
     - 沙箱拦 worktree commit：改用 `--dangerously-bypass-approvals-and-sandbox`，和 pi 一样无沙箱（E1、E8，约束 2）；
     - 依赖模型端点：配置在 `~/.codex/config.toml`。wrapper 会从 `base_url` 推导预检地址，只探测本地回环端点（作者环境：Ferryman，`127.0.0.1:15722`）。
   - 换成 codex 的原因是**能看到进度**：pi 的 `-p` 模式外面看不出它在干什么，用户碰到过 worker 卡很久却没法判断。codex 的 `--json` 每个命令、改动、说明都有事件，`progress.sh` 能直接展示。
   - pi 后端保留，等 codex 后端用过一段时间再决定删不删。早先记录"pi 不在智谱 Coding Plan 支持工具名单里"已过时：2026-11-18 核实，中国区官方名单（<https://docs.bigmodel.cn/cn/coding-plan/tool/others>）同时列有 Codex 和 Pi Coding Agent，且都有官方接入页；Codex 页给出的正是我们用的 `open.bigmodel.cn/api/v1` + `wire_api = "responses"` 配置。条款没有逐字许可也没有禁止 `codex exec` 无头批量调用，主要风险是并发引起的 1302 限流。
   - **2026-11-18 决定：订阅 OpenAI 官方 Codex 套餐后，Worker harness 仍是 codex，Worker model 仍固定 GLM。** 订阅只用于用户自己交互。不换 harness 的原因：`codex-worker.sh` 每次显式传 `-m` 和 `-c model_provider=custom`，GLM key 在 custom provider 里，ChatGPT 登录写的是 `auth.json`，两者不冲突；换成别的 harness 要重新解决进度可见、Resume、杀进程树这些问题，还要重写 wrapper 和自测。评估 harness 的标准固定为五条：外部能看到进度、能 Resume 原会话、能连子进程一起杀干净（含 Windows）、在智谱支持名单内、会读 CLAUDE.md 和技能文件。
   - 同一天起 worker 用独立的 home（`CODEX_WORKER_HOME`，默认 `~/.codex-worker/`，由 `scripts/setup-worker-home.sh` 从 `~/.codex` 生成，不带 hooks、projects 和交互设置）。原因：订阅后用户会经常改交互那边的顶层模型、MCP 和 hooks，共用 `~/.codex` 会把这些改动漏进 worker，几百个 worker 会话也会混进交互历史。没有 worker home 时回退 `~/.codex` 并警告，所以别的机器不用马上改。`resume.json` 记下所用的 home，Resume 只用存档里的那个；切换前存下的老存档续不上，这个代价可以接受。
10. **pi 的 JSON 模式出错时退出码也是 0。**
    - `pi-worker.sh` 不看退出码，而是看事件流里最后一条 assistant 消息的 `stopReason`。
    - 再根据 `errorMessage` 判断错误类型：auth、quota、transient 或 error。
    - 改 wrapper 时别把这一点改回成看退出码。
11. **worker 的自我报告不能信。** `status: ok` 只说明它跑完了、没碰到 API 错误。主代理还要检查三件事：有新 commit、工作区是干净的、集成分支的最新提交已经合进来。最后测试结果以 merger 重跑的为准。
12. **GLM 不可用时不能自动换回 sonnet，也不能自动改用 agent。** 用 GLM 就是为了省 CC 额度，自动切回去这个目的就没了；`agent` 同理是用户显式选择的后端，不是备用路线。碰到 auth、quota 错误，或者重试完还是失败，要先停下来问用户。
13. **merger 一次只能跑一个，GLM worker 最多同时跑 `GLM_MAX_PARALLEL` 个。** 智谱高峰期会限流，所以并发数不能开大；默认 2，可用 `--parallel <n>` 按次覆盖，但开高了 429/quota 会触发整次 run 停下来问用户，得不偿失。
14. **pi 用 `--no-extensions --no-skills` 启动，只用 `--skill` 加载 tdd 技能。** 这样 Orca 装在 `~/.pi/agent` 下的扩展和 orchestration 技能不会混进 worker。
15. **External worker 的停止条件是两道，不再共用一个 30 分钟墙钟。**
    - `--time-limit` 按角色设定（implementer/fix 长上限，merger/exploration 短上限），按**整段**计：从本段第一次 attempt 开始量到段内最后一次 attempt，中间的 API 错误重试等待也计入；单个 attempt 只用剩余预算，预算耗尽就按 `timeout` 停，不新开 attempt。到点退出码 `5`、状态 `timeout`；`--idle-timeout`（默认 600s）监控事件流是否增长，超时退出码 `7`、状态 `stalled`。状态名 `timeout` 是沿用改造前的外部契约，不再改名，含义就是"到达 Time limit"。
    - 判卡死看事件流增长而不是墙钟：pi 的消息间隔实测最大约 114s，它自己的命令超时至多 300s，所以 600s 的 Idle timeout 不会误杀还在推进的 worker。
    - 停止 worker 时要连进程树一起杀（Windows 下 `taskkill //T //F`，配 `/proc/<pid>/winpid` 拿 Windows pid；Git Bash 的 `kill` 只能杀到 pi 本体，够不到它的工具子进程，会留孤儿）。pi 自己退出 124/137（比如被外部 OOM 杀）不算到达 Time limit，按普通 `error` 处理，不能 Resume。
    - `stalled` 按 error 处理（重写一次 Brief，再失败问用户），不续跑：卡死的会话不值得救。到 Time limit 停下的 worker 由 Orchestrator 决定是否 Resume（见要点 16）。
    - 别把它改回一个大墙钟超时，也别加自动续跑/重试循环。
    - `PI_WORKER_PI` 环境变量可替换 pi 可执行文件（与 `PI_WORKER_API_KEY` 同思路），自测用它造假 pi，确定性地测 Idle timeout、整段 Time limit、非 watchdog 杀死这些路径。
16. **Resume 由 Orchestrator 决定，wrapper 永不自动续命。**
    - fresh run 一开始就把 cwd、model、skills、thinking 级别、session id 和第一段的 base head 写进 run dir 的 `resume.json`；`--resume --run-dir` 读取它们、在同一个 worktree 里续接同一个 pi 会话（Resume 提示词要求先把能过测试的成果 commit），向 `events.jsonl`/`stderr.log` 追加、继续编号新增 attempt 文件、覆盖 `status.json`。新一段的 Time limit、Idle timeout 和 API 错误重试预算由 Resume 调用的旗标决定，每段自己的预算。
    - 每次 Resume 都再烧一段 GLM 额度，所以只有 Orchestrator 能决定续跑：`timeout` 且有进展（`new_commits` ≥ 1 或树是脏的）才 Resume 一次；第二次 `timeout` 或没进展就问用户。`new_commits` 永远从第一段的 base head 起算，`segments` 记录段数（fresh = 1，每次 Resume +1），验收检查因此能看到跨段的全部 commit。
    - `stalled`（卡死）绝不 Resume：按 error 处理，重写一次 Brief，再失败问用户。
    - 坏 Resume（run dir 不存在、没有存档、存档指向的 pi session 文件已不在 run dir 的 `sessions/` 里、或带了 `--cwd`/`--brief`/`--model`/`--skill`/`--thinking`）退出码 64，绝不悄悄新开一个会话：绝不能把续跑落到别的 worktree 或别的 Brief 上。pi 对找不到的 `--session-id` 只在 stderr 警告一声就新建同 id 的新会话，所以 session 文件必须由 wrapper 自己查（pi 把会话存在 `<时间戳>_<session id>.jsonl`，首行是 `{"type":"session","id":...}`）。
    - 别给 wrapper 加自动 Resume 或不问用户的多重 Resume，那会把额度烧穿。
17. **codex 后端的坑（`codex-worker.sh`，详细证据和设计约束见 `docs/codex-backend.md`）。** 改 wrapper 前先读那份文档，别把这些改回去：
    - codex 和 wrapper 之间不能夹 MSYS 程序（`timeout`、`env`、管道）。夹了，`taskkill //T` 就杀不到 codex 的子进程（F9）。假 codex 也要用 `exec node` 的 sh 包一层，不能写 `#!/usr/bin/env node`。
    - stdin 必须是会结束的文件。codex 会一直读 stdin，开着的管道会让它永远挂住（F8）。
    - 不看 codex 的退出码（失败一律是 1），看事件：`turn.completed` 算 ok，`turn.failed` 按 message 分类。429 分不出是限流还是额度用完，因为 codex 把响应正文丢了（F1），所以按 transient 处理，错误信息里注明。
    - Idle timeout 只按 `thread.*`/`turn.*`/`item.*` 事件计时。`Reconnecting...` 这类顶层 `error` 行不算进展，否则代理断了会一直被当成活着（F4）。连续 3 条 `waiting for network` 就判代理断了。
    - 流空闲上限和重试次数用 `-c` 钉死（120s × 2 次重试），否则 SSE 半开时 codex 自己要拖约 30 分钟（F6）。V2 实测 365s 退出。
    - Resume 用 `codex exec <全部 exec 级参数> resume <thread_id> -`，exec 级参数必须写在 `resume` 之前（E5）。会话文件在全局 `~/.codex/sessions/`，坏 Resume 的检查是找文件名含 thread_id 的 rollout。
    - 答完不收尾：Idle timeout 触发时，如果最后一个进展事件就是 `agent_message`、也没有在跑的命令，把它存进 `result.md`，状态仍是 `stalled`，由 Orchestrator 走验收检查决定（插件 issue #391）。中途的说明文字（"我先看看 X"）不算。
    - Windows 的 pid 会很快被复用。`pid` 文件记录"pid + 进程启动时间"；`progress.sh` 先看 `status.json` 是否比 `pid` 新，再核对启动时间（V3 实测碰到过）。
    - bypass 下 codex 仍有内置命令策略，会拒绝 `rm -rf` 和 `Remove-Item -Recurse`（E15）。Brief 里别让它递归删目录。
    - 不走 codex-plugin-cc：它没有卡死检测和 Time limit，后台任务会永远停在 running，在 Git Bash 下取消会失败，还依赖本地补丁（见文档第一节"参考"）。插件只留给临时手动用。
18. **多个 Run 并行：选什么由 find-next 一处决定，领取、合入、worker 数量靠锁和领取记录（2026-11-12 改）。**
    - 原先的做法是「固定名 integration branch + 每个 Run 自己列候选、用户选」，不做锁。11-11 夜里用户在三个 worktree 同时启动，暴露了三个问题：各会话扫描到的状态在一分钟内就过时，#223 的会话以为 #222 没人做，把 #222 的判断又写了一遍；第 9 步「合最新 master → 测试 → 合入 → push」不是原子的，11-12 早上三份规格五分钟内先后合入，一次合并丢了内容要事后补；运行目录只按规格号命名，`235-*` 下混着两个仓库的运行。
    - 选什么：第 0 步不再扫描和列候选，必须带规格号；不带就让用户先跑 `/find-next --batch`，它输出确定性的开发顺序（find-next 设计要点第 12 条）。这样「扫描加挑选」只在一处发生，不需要给它加锁。
    - 领取：`scripts/claim.sh take` 在一把短的仓库级锁内建 `spec-<n>` 分支和 worktree，并写领取记录（持有者 Claude 进程的 PID 和启动时间）。「进行中」和「中断」靠领取记录判断，不再靠 Orca 元数据或用户猜；Orca 标记只给用户看。
    - 合入：第 9 步全程持有合入锁（`lock.sh acquire land --scope repo`），在临时 worktree 里合入并 push，不碰主 checkout；push 被拒就回到第一步，不强推。
    - worker 数量：`--parallel` 仍按 Run 计；另有全机共用的 worker 槽位（`ISS_MAX_WORKERS`，否则读 `~/.cache/implement-spec-split/max-workers`，默认 4；find-next 的 `--workers` 会写这个文件，因为 Orca 新开的会话拿不到环境变量），所有仓库所有 Run 的 wrapper 都要先拿槽位，拿不到排队、不计入 Time limit。
    - 中途被别的规格挡住的票一律等待，绝不在本规格里实现别的规格的范围；要判断对方状态时现查 `claim.sh status`，不能只看 issue 开着就说没人做。
    - 锁都用 `mkdir` 原子创建（macOS 没有 `flock`），持有者信息写进锁目录；持有者进程死了（PID 不在或启动时间对不上）由下一个等待者接管，所以会话崩溃不会留下永久的锁。启动标识默认经 `scripts/pid-start.sh` 获取：优先保持 `ps -o lstart=` 的旧值；Windows Git Bash/MSYS 的 `ps` 没有 `-o` 时回退读 `/proc/<pid>/stat` 的 starttime 并记作 `proc:<starttime>`，因此锁和 claim 在记录与判断时必须同用这一取法。
    - 运行目录改为 `runs/<仓库名>-<n>-<时间>/`。ticket worktree/分支命名仍是 `spec-<n>-t<m>`，Recovery 靠这两点找到上一个 Run 的残留。
    - 只覆盖同一个 clone 的多个 worktree（分支、领取记录、合入锁都在这个 clone 的 git 公共目录里）。
19. **`agent` 后端（2026-11-14 加）：会话内子代理跑实现角色，模型显式传。**
    - 起因：同一套技能要在两台机器上用。一台照旧 codex/pi 外部 worker；另一台 Claude Code 经代理走 GLM，Agent 工具显式传 `model: opus` 实际跑 GLM-5.3，体力活直接开内置子代理即可，不必装 codex/pi。默认行为零变化：`IMPLEMENT_BACKEND`、find-next 默认 worker、生成命令默认后缀都不动，不给新参数时 `launch-wave.sh` 的输出和状态文件与旧版逐字一致。
    - 命名固定为 `agent` / `--agent-model`，两个技能同名同义。`--impl sonnet` 保留为兼容别名（= `--impl agent --agent-model sonnet`），但 `--impl sonnet --agent-model X`、以及 `--agent-model` 配 `codex`/`pi` 都是参数冲突，要报错让用户改，不能悄悄忽略。模型只允许 `sonnet|opus|haiku|fable`。
    - `--parallel` 对 `agent` 后端数的是本 Run 同时在跑的实现类子代理（implementer/fix/merger/exploration），不给时不限（沿用原 sonnet 行为）；agent 子代理不取全机 worker 槽位（那是给 External worker 限 GLM 额度用的），总量由 find-next 的 workers ÷ specs 保证。这是给「多个子代理共用同一 GLM 账号」的机器限流用的，别把它改回只数 External worker。
    - find-next 只有一个开关 `--worker agent [--agent-model <model>]`，同时管自己的调研/决策/起草方式和生成的开发命令后端，不提供混搭。agent 路径与 codex 路径同构：照旧建运行目录、写 `brief.md`，子代理 prompt 固定为「读 brief.md 并照做，把最终报告写到 result.md，同时作为你的最终回复」，主会话照旧审 `result.md`；没有 `status.json`，以子代理返回为准。`launch-wave.sh` 新增 `--impl codex|agent [--agent-model X]`，agent 时透传 `--cmd-suffix "--impl agent --agent-model X"` 给 `pipeline-status.sh` 并写进启动状态，`--next-wave` 读回；旧状态文件没有该字段按 codex 处理。

20. **并行子代理与按需 MCP（2026-11-15 实测后改）。** 530 个 codex 会话里 `spawn_agent` 调用为 0；一轮里同时发出多个工具调用的只占 2.3%；等模型的时间占 70–95%；1 到 6 个 worker 并发时，每轮延迟基本不变（中位 6–8 秒）；关掉 MCP 后启动从 9.4 秒降到 3.8 秒，且没有了 rmcp 报错。因此：新会话 prompt 固定要求并行调用并按需开 explorer 子代理；codex-worker 默认关 MCP，用 `--mcp` 按需开启；`~/.codex/config.toml` 设 `[agents] max_concurrent_threads_per_session = 3`（子代理不占 Worker slot）。主会话最清楚每个任务需要什么，所以「默认不带、按需分配」由派活的一方决定。
21. **2026-11-19：无人值守落地（`--auto-land`）。** 用户常在通宵跑 find-next 启动的整批规格：睡着时没人答问题，醒来后会话缓存早已过期，回去点「推送」既要等又费 token。决定：
    - 授权只在 find-next 推进模式取得（第 6 步那一问，或调用时带 `--auto-land`），经 launch-wave 写进启动状态、由 `--next-wave` 沿用；下一次不带它的 `--apply` 清掉授权。不做成仓库永久设置，免得哪天白天也无声 push 到 main；手动敲 `/implement-spec-split <n>` 不带参数时仍然确认。**2026-11-24 修订：launch-wave 启动的会话改为默认无人值守，见第 28 条。**
    - 落地方式不变：直接合入 main 并开下一波；走 PR 的仓库改为等 checks 后自动 `gh pr merge`，同样开下一波（只开 PR 等人审会让通宵只跑一波）。
    - 原先「问用户」的节点改为自动处理，有次数上限，超限就**停车**（规格 issue 下留停车报告、释放认领、结束会话，之后显示为「先恢复」），绝不挂着等人：测试红/CI 红派 fix 最多 2 轮；合 main 冲突由 merger 解决后，再由 REVIEW_MODEL 只审冲突解决部分；规格/ADR 已有答案的设计问题由主会话判断并写进落地报告，真取舍才停车；`transient` 等 10 分钟重试一次；`quota` 后台 sleep、每 30 分钟 preflight、最多 5 小时（sleep 不花 token）；`auth` 和 worker 第二次失败直接停车，不试第三次（两次都失败多半需要人）。
    - 落地成功也在规格 issue 下留落地报告，早上看 GitHub 即可，不回到过期会话。同一批里其他规格互不影响、照常落地。
22. **2026-11-19：进度看板（Progress board，grilling 定稿，已实现；launchd 常驻服务在 `~/ops`，票 #14）。** 一台机器上同时跑多个仓库的 find-next 和 Run，用户主要在手机上看，想不跑 find-next 就知道全局：有几张地图、关了哪些、哪些没转成规格，哪些规格没拆票，还剩多少规格和票，下一波从哪几份规格开始。决定：
    - 只读、只看本机。停止、续跑、开下一波这些动作仍然回到会话里做；唯一的按钮是「立即刷新」。
    - 仓库清单直接用 `orca repo list`（Repo registry），只算有 GitHub 远端、用过这条管线的仓库，不再自己维护一份。仓库从 Orca 里移除后，它在本机的残留（Run 目录、Launch state、快照）就可以 Board pruning；仍在 Orca 里的仓库，已关闭超过 14 天的规格的 Run 目录也可以清。清理一律先 dry-run，加 `--yes` 才删，不放进定时任务；未关闭规格的 Run 目录不删，Recovery 要用。
    - 结构数据复用 `pipeline-status.sh` 已有的关系判断（地图 sub-issue、规格正文里的「地图: #n」、规格→票），新增完整关系图 JSON 输出，判断逻辑不另写一份。`gh` 查一个仓库约 6 秒，所以不现查：在 `~/ops/services/` 里放 launchd 服务，每 10 分钟刷新活跃仓库（7 天内有活动或有进行中的规格），其余仓库每小时刷新，页面显示快照时间。
    - 编排器在阶段切换时往规格级 Run 目录写 `run.json`（阶段、波次、票数），只供看板展示；Recovery 仍以 GitHub 和工作树为准，不出现第二个事实来源。已实现 `scripts/run-phase.sh`（票 #9）：SKILL.md 在各阶段节点调用，写入失败只警告并以 0 退出，Recovery 明文不读 `run.json`。
    - 停车只从 `run.json` 的 `phase=parked` 判断，不读 GitHub 上的停车报告；`run.json` 写入失败时会漏报停车，这个风险可接受。
    - 不带子命令的 `board.sh` 终端视图先按刷新节奏刷新（过期才调 `gh`）再显示；Orca 返回空列表时，prune 也跳过第 1 类（更保守）。
    - 网页优先，只监听虚拟局域网地址和 127.0.0.1，不暴露到公网，不做登录。首页按「需要你处理」→最近活动排序，默认只显示 7 天内有活动的仓库，但有进行中、中断、停车报告的仓库始终显示。页面先用 mockit 定稿再实现。汇总脚本放本仓库，常驻服务放 `~/ops`。
    - 不写 ADR：用 Orca 当仓库清单、用快照加定时刷新，这两条都容易改回去。
23. **2026-11-19：默认后端按会话自动选（`IMPLEMENT_BACKEND = auto`）。** 自 10-11 起默认是 `sonnet`。find-next 生成的命令自带 `--impl codex`，所以平时不出问题；但手敲 `/implement-spec-split <n>` 不带 `--impl` 时，官方订阅会话会把实现角色全开成 Sonnet 子代理，花的是 Claude 额度，违背「判断以外交给 codex worker」的分工（Spec #7 的 Run 就是这样跑的）。同一套技能还要在 GLM 驱动的 Claude Code（`claude-glm` / Orca 的 OpenClaude 槽位）里用，那里的子代理本身就是 GLM，不该派 worker。决定：不带 `--impl` 时看环境里的 `DELEGATE_GUARD_DISABLE=1`（`claude-glm` 启动器设置的标记）：有就用 `agent`，没有就用 `codex`。只带 `--agent-model` 时也用 `agent`。显式 `--impl` 照旧优先；find-next 生成的命令不变。
24. **2026-11-20：Flash 模式的审核必须出会话。** 在 GLM 驱动的会话里，Agent 工具传 `opus` 只是把名字映射到 glm-5.3；同会话里开 Standards/Spec「opus」子代理仍是 GLM 审 GLM，等于假审核。因此 `FLASH_ORCHESTRATOR=1` 的代码审核、设计级意见、冲突复审和连续失败诊断都只能调用 `scripts/opus-review.sh`：它会清掉 GLM/Anthropic 代理映射，出会话用官方订阅的 `claude -p --model opus` 执行。脚本失败就停车，不降级到 GLM，也不由会话自审。
25. **2026-11-22：编排防卡死。** ssh-manager-mcp Spec 349 的 flash 编排会话里，实现子代理为跑一条 `gofmt -w` 裸调 `codex exec`，Bash 超时后命令转入后台，子代理和编排主会话都只「等通知」，codex 进程空转 10 小时无人发现；早上续会话时编排者还把日志里的启动钟点误算成运行时长。owner 定：delegate-guard 对所有会话（含子代理、非 flash、例外开关开启）一律拒绝 Bash 直接调用 `codex exec`，外部 worker 只能走 wrapper；编排派发实现/合并/修复角色后必须挂 `run-watchdog.sh`，指纹无进展即退出唤醒编排者，绝不无限等通知；判断时长先 `date` 再 `ps` 看 etime/time，不从日志钟点推算；`gofmt -w` 这类确定性格式化不算写源码，任何角色直接执行。
26. **2026-11-23：grill-feature / grill-map 交接后用 launch-wave 开实现会话。** oa-helper 规格 #80 的 Design session 交接回主会话后，主会话按第 5 步「走 `/implement-spec-split 80`」用 Skill 工具调本技能，因为设了 `disable-model-invocation` 被拒，只能停下让用户手敲。本技能保留 `disable-model-invocation`（Run 会花额度、会 push，只能由人或 launch-wave 发起）。两份 grill 技能的第 5 步改为跑 `launch-wave.sh --repo <owner/name> --only <n>[,<m>…] --apply`：它领取规格、开 worktree，并在新 Orca 会话里把 `/implement-spec-split <n>` 当作用户输入发出去。launch-wave 失败，或某份规格要手动启动时，才提示用户手敲。注意：试运行会打印整份开发顺序，`--apply` 只启动 `--only` 里列出的规格。
27. **2026-11-23：默认 worker 模型升到 GLM-5.4。** 环境侧（`~/.codex-worker/config.toml`、claude-glm / claude-flash 的 models.env）已改用 glm-5.4（1M 上下文、支持图片输入），但 `codex-worker.sh` 默认用 `-m glm-5.3` 显式传模型，config.toml 里的值不起作用，worker 实际仍在跑 5.3。现在把脚本默认值、`SKILL.md` Config（`CODEX_MODEL` / `GLM_MODEL`）、测试和说明文字都改成 5.4；flash 档没有 glm-5.4-flash，仍用 glm-5.3-flash。上面第 24 条、ADR 0001 和 `docs/codex-backend.md` 记录的是当时的实测，保留 5.3 的写法。以后升级模型时，除了改 config，还要改脚本默认值。
28. **2026-11-24：launch-wave 启动的会话默认无人值守落地（`--auto-land` 变默认，新增 `--no-auto-land` 退出）。** 事故：2026-11-23 oa-helper 规格 #75 由 grill 交接用 `launch-wave --only 75 --apply` 启动，没有 `--auto-land`，且不带它的 `--apply` 会清掉旧授权；会话 23:01 做完后停在第 9 步等确认 push，用户次日 08:26 才点，会话缓存失效白费 token。grill 交接路径根本不问授权，第 21 条靠 find-next 第 6 步那一问覆盖不到它。决定：
    - 凡经 `launch-wave.sh` 启动的会话（find-next 推进模式、grill-feature / grill-map 交接用的 `--only <n> --apply`、规格合入后的 `--next-wave --apply`）默认带 `--auto-land`，做完自动合入 main / push / 开下一波，不再停下问人；试运行（不带 `--apply`）生成的命令同样默认带 `--auto-land`。
    - 退出用 `--no-auto-land`；`--auto-land` 保留为可接受参数（等同默认，向后兼容），不报错。`--apply` 写启动状态时总是显式写 `auto_land: true` 或 `false`（`--no-auto-land` 时为 false）。
    - `--next-wave` 读状态：只有 `auto_land === false` 才关闭；字段缺失（旧状态文件）或状态文件不存在时视为开启。`--next-wave` 仍不接受 `--auto-land` / `--no-auto-land`，报错说明两者都要在初始 `--apply` 时给。
    - find-next 第 6 步不再问「本批无人值守落地吗？」；调用时带 `--no-auto-land` 才不落地并透传给 launch-wave，`--auto-land` 保留为兼容别名。手动敲 `/implement-spec-split <n>` 不带 `--auto-land` 仍保持 push 前确认，SKILL.md 第 9 步逻辑不改。无人值守落地本身的行为（合入/合 PR、CI 红自动修两轮、停车报告、落地报告）不变。

## flash 模式设计要点（2026-11-20 规格定稿，ADR 0001）

三档分工：flash 主会话/规格会话（`claude-flash` = glm-5.3-flash，只执行与转述）、glm-5.4 子代理（全部源码修改与大量阅读）、官方 Opus（一切结论性判断）。要点：

- **白名单默认禁止**（不是黑名单）：flash 只做白名单内的事，漏列的情况会上交而不是被当成允许。评估过"flash 自己做小判断"和"黑名单"，都否了——flash 过度自信的小错会在后续波次放大，黑名单漏列即放行。
- **一行源码都不写**：delegate-guard flash 模式对源码写入阈值 0、`allow-direct-edit` 不生效，靠 hook 硬拦而不是靠 flash 自觉。
- **判断一律出会话**：GLM 会话里 "opus" 子代理是假的 Opus（见第 24 条），所以审核、诊断、冲突复审全走 `scripts/opus-review.sh`。Opus 不可用（退出码非 0）就停车，不降级、不自审、不自动重试。
- **Design session 承担讨论**：`/grill-feature`、`/grill-map` 由 Orca 开官方 Opus 会话，用户直接谈；讨论完当场 to-spec/to-tickets/commit/push（文档推送预授权），写 `handoff.md` 通知 flash。flash 在等待期间阻塞、不轮询不耗 token。
- **结论必须带出处**：flash 汇报的每个结论注明支撑它的 findings/result 文件路径，拿不出出处的结论不许说。防止 flash 把自己当判断者。
- **拿不准默认上交 Opus**，不自己在两个上交对象之间挑。
- **停车条件收紧**：flash 只对 Opus 标注「需要人取舍」的条目停车，不许自创取舍；但 Opus 脚本错误照常硬停车。「需要人取舍」的每一条都原样转给用户，flash 不许以「规格已写明」为由自己裁掉（2026-11-21 human-res-cost 规格 #49 实测：5 条里 flash 自判了 2 条）。
- **实现只能走 `/implement-spec-split`（2026-11-21 加）**：同一次实测里，flash 读完 Design session 的 handoff（Opus 写了「单 worker 串行即可」）后没调技能，自己建 worktree、手写 brief、直接跑 `codex-worker.sh`，认领、阶段标记、agent 后端、落地锁全被跳过。修法三层：grill-feature/grill-map 第 5 步规定实现待办必须走技能；design-session.sh 要求 handoff 只写「实现规格 #N」、不写执行方式；`codex-worker.sh` / `pi-worker.sh` 在 `FLASH_ORCHESTRATOR=1` 时拒跑，只有显式 `--impl codex|pi` 的 Run 带 `WORKER_ALLOW_FLASH=1` 放行——措辞拦不住 flash，和「一行源码不写」一样靠硬拦。
- **Opus 审查要能读 issue（2026-11-21 修）**：`opus-review.sh` 用 `--permission-prompts none`，原先白名单只有 git，`gh issue view` 被自动拒绝，Spec 轴只能拿 CONTEXT.md 和 commit message 凑数，等于没对照规格。现放行 `gh issue view` / `gh pr view` / `gh pr diff`（只读）。
- **「需要人取舍」必须带推荐（2026-11-21 修）**：flash 不许自补推荐理由，推荐只能来自 Opus；原先三类提示词只要求把取舍放进该节，Opus 便只写中性权衡，find-next 问题轮里 a–c 全无「建议」行（ssh-manager-mcp #348 散票分流实测）。现要求每条列选项与代价并写 `推荐：<选项> — <理由>`，实在无法推荐写 `推荐：无 — <原因>`；find-next 把它照抄为「建议」行。
- **flash 提问框乱码（2026-11-21 修）**：glm-5.3-flash 调 AskUserQuestion 时常在中英文交界、标点前夹回车符 `\r`（一个会话 4 次里 3 次），终端把提问框渲染成乱码，普通回复和 Bash 不受影响。措辞拦不住，改用 `hooks/ask-sanitize.js`（PreToolUse，`ask` + `updatedInput` 删掉 `\r` 后照常弹框，已在真实会话里验证不会多弹确认），注册在 flash 专用 settings。
- **交接后关闭 Design session（2026-11-21）**：Opus Design session 交出 handoff 后原本一直挂着，占 Orca 槽位，用户回去说话还会继续花 Opus 额度。现在 `design-session.sh` 收到 handoff 后等 3 秒（`ISS_DESIGN_CLOSE_DELAY`），用 `orca terminal close --terminal <handle> --tab` 关掉它的标签；关闭失败只提示不报错，`ISS_DESIGN_KEEP_SESSION=1` 保留。只处理 terminal 形态（有 handle）的会话，chat 形态没有 handle，保持原样。
- **Design session 自动切换焦点（2026-11-21）**：`orca agent launch` 默认开新标签但不切焦点，用户得自己找过去。现在 launch 加 `--focus` 直接切到 Design session；收到 handoff 后先用 `orca terminal switch --terminal $ORCA_TERMINAL_HANDLE` 切回发起等待的主会话终端，再关 Design 标签。切回失败只提示不报错；不在 Orca 终端里跑（没有 `ORCA_TERMINAL_HANDLE`）就不切。
- **界面 mock 在 Design session 里、to-spec 之前做（2026-11-21）**：选哪个 mock 本身是设计决定，放到 flash 去做的话，规格写的就是猜测；而且 flash 不做判断，Design session 交接后又会被关掉，没地方接着讨论。真正费 Opus 额度的是"监工"（写 Brief、读报告、看截图），不在会话放在哪，所以把监工拿掉：Opus 只写方向卡，用 `templates/brief-mock.md` 交给一个 codex worker 出单文件页面，worker 用 Playwright DOM 断言自检（非空、非源码、无横向溢出、关键交互点得通）并写 `mock/manifest.json`；Opus 不看截图和 HTML，按 manifest 的路径调一次 `mockit_submit`（mockit 没有 CLI 提交，只能走 MCP，但接受本地路径），由用户在手机上拍板。不加视觉模型自检：GLM-5.3 不支持多模态，智谱视觉 MCP（`@z_ai/mcp-server`）也没进 worker home；评委只有用户，视觉自检替用户省不了事，出现"坏页面送审"再接入。等用户审页面可能超过 2 小时，而后台 Bash 最多跑 7200000ms，所以 design-session.sh 超时后用 `--attach <run-dir>` 续等同一会话，技能遇退出码 5 自动续等。
- **子代理放行与进度标签（2026-11-21）**：ssh-manager-mcp spec-349 的 flash 编排会话派出 glm 子代理后，子代理继承 `FLASH_ORCHESTRATOR=1`，源码写入被 delegate-guard 全拦；三个子代理分别另起 headless `claude-glm`、改走 `orca orchestration worker-start`、用 `env -u` 绕过，导致正在开发的会话大多在 Orca 里不可见。现在 hook 在 flash payload 带非空 `agent_id` 时放行子代理源码写入、主会话仍全拦，并要求实现角色被拦时停下报告、禁止绕路；`ticket-watch.sh` 另开只读 Orca 进度标签显示 worktree、提交和文件状态。不做 `--impl orca` 后端：那会改派发、等待和恢复链路，测试面大，需要时再单独做。
- **回退优先**：改造前两仓库打 `pre-flash-orchestrator` tag、全局配置快照 + ROLLBACK.md 在 `~/.claude/backups/pre-flash-orchestrator-20261120/`；新行为只活在 flash 会话里，官方会话与 claude-glm 并存。改 flash 相关行为时先想回退路径还在不在。

## find-next 设计要点（2026-11-01 grilling 定稿）

`find-next/` 是放在本仓库里的另一个技能：扫描当前仓库的 wayfinder 地图与票。它最初只给出一个 Next step（GLOSSARY.md），2026-11-14 起默认进入推进模式，`--suggest` 保留这个旧行为。起因：在手机上用 wayfinder 讨论出一大堆票后，不知道下一步该对哪张做 to-spec / to-tickets / grilling。原版技能都要人自己去找。

1. **只给一个 Next step 和要敲的命令，外加最多 3 行备选。** 输出要适合在手机上读；没有候选时，说出最接近的一个和它还差什么。（2026-11-14 注：这是 `--suggest` 的规则；默认推进模式见第 14 条。）
   - **例外：`--list` 清单模式（2026-11-11 加）。** 起因：一个项目讨论了好几张地图、做了不少之后，用户想看「还剩什么」的全貌，单个 Next step 回答不了。清单主体来自 `pipeline-status.sh --all` 的机械输出，模型只补「疑似重复」「等 #N」这类轻量标注，所以不派 worker。清单末尾仍给出一个 Next step，口径与建议模式一致。
   - `--all` 比默认输出多三块：探索中地图的决策票、「状态没收尾」（规格已关闭但执行票还开着；实现票只被已关闭的规格覆盖；规格未关执行票全是搁置票）、「散票」（不属于任何地图或规格的 open issue，带来源地图和时机）。不加 `--all` 时输出不变，`implement-spec-split --status` 不受影响。
   - 自由格式的 backlog 文档不机械解析：格式不统一，误判代价大于收益。清单只提醒用户把仍有效的条目迁成 issue。
2. **一个技能覆盖所有阶段，不拆成 find-to-spec、find-issue-grill 等多个。** 拆开的话，同样的地图要扫好几遍，用户还得记住该先敲哪个命令，又回到了「人去找」。
3. **阶段优先级：越靠近交付越靠前。** to-tickets > to-spec（完全就绪的排在部分就绪之前）> Map frontier 里的 Decision ticket（按下游解锁数排，数量相同时编号小的优先）。理由：已经花过讨论成本、却还没变成执行票的东西最该先收口。
4. **候选单位是地图或 Spec，不是单张决策票。** 单张 Decision ticket 本身做不成 spec，spec 是对一片已经拍板的决策做综合。
5. **地图内的 Decision ticket 推荐 `/wayfinder <地图> <票>`，不推荐裸 `/grill-with-docs`。** 后者不认领、不写 Resolution、不关票，下次扫描会再次推荐同一张票。地图外的散票默认推荐 `/find-next` 推进模式分流；`/grill-with-docs` 只是手动备选，带时机的票只汇报条件。
6. **to-spec / to-tickets 不能由模型调用（`disable-model-invocation`），而且只综合当前对话。** 所以 find-next 先把材料放进上下文（self 模式读原票，worker 模式读 `digest.md`），再提示用户敲命令。
7. **对跟踪器只读**：不改票头、不认领、不打标签，以免和用户并发跑的 wayfinder 会话互相覆盖。唯一例外是 `--batch` 的发布步骤（见第 12 条）：只新建票，不改已有的票，并且要用户先确认。
8. **机械扫描用脚本，判断用模型。**
   - 本地 markdown 跟踪器用 `find-next/scripts/scan.py`（只用 Python 标准库，输出 JSON），GitHub 复用 `scripts/pipeline-status.sh`，两套识别规则不分叉。对应关系：`needsTickets` → to-tickets，`missing` → to-spec，`exploring` → Decision ticket（具体哪张再用 `gh` 查），`implement` 不用。
   - 两种跟踪器判断「该 to-spec」的口径不同。本地是地图的 Map frontier 已空，或只剩 Closing ticket；GitHub 是地图下的 Map ticket 还没被任何 Spec 覆盖。
9. **判断部分默认交给 codex worker（`--worker codex`），带 `--read-only`。** 要读多张地图 Notes 和票正文，体量大但判断稀疏。worker 出错按全局 CLAUDE.md 的处理表，不自动降级为 `self`。
10. **建议模式不推荐「执行票已拆、可以开工」这一阶段**（开发顺序由推进模式的后半给出，`/implement-spec-split --status` 也能看），也不跨仓库汇总。
11. **允许模型自动触发**（不设 `disable-model-invocation`）：它只读，误触发的代价只是一次扫描。
12. **`--batch` 批量模式（2026-11-11 加）：批量起草规格和执行票，用户确认一轮后发布。**
    - 起因：缺规格的票一多（ssh-manager-mcp 一次 9 张），逐张走「to-spec → 确认 → to-tickets → 确认 → clear」要几十次操作，每轮我还要重读同一张地图的材料。
    - 不改、不调用上游 `to-spec` / `to-tickets`：它们是插件技能，改了升级会被覆盖，而且不能由模型调用。起草 worker 直接读它们最新的 `SKILL.md`，照模板和规则写，所以上游更新会自动跟上。
    - 一个 worker 同时写一份规格和它的执行票：拆票主要依赖规格内容，分两轮确认要多问用户一次；用户大改某份规格时只重写那一份。
    - 分组在我：哪些实现票合成一份规格、跨规格的阻塞，都要看全批才判断得了，这是逐张走 to-spec 时做不到的。
    - 每条实现决定必须注明出处（决策票结论、地图 Notes、实现票正文），防止 worker 把推断写成决定。找不到出处的分两种：按仓库先例能定的细节（字段名、审计动作名）写进正文由实现者定；要用户拍板的写进 `unresolved`，每条带推荐答案，草稿先按推荐写并标「（待确认）」。第一次试跑（ssh-manager-mcp #223、#224）worker 把 7 条全放进未决，其中只有 2 条真要用户定，用户最后一句「都同意」就过了，所以要求带推荐答案、编号连续，让用户一句话能回复。
    - 不能挂在还没有规格的实现票上：试跑时一张执行票挂在缺规格的 #84 上，那份规格就永远收不了尾。改为把那部分移出本规格，用 `handoffs` 在对方票下留言，让它写规格时纳入。
    - Brief 用 `make-batch-briefs.sh` 生成而不是我手写：几份 Brief 只差票号和标题，手写纯属输出开销，组越多越明显。
    - 发布是对外写操作，由我在用户确认后用 `publish-batch.sh --apply` 执行，默认试运行。发布记录 `published.json` 让中途失败可以直接重跑、不重复建票。
    - 占位符只认 `{{S1}}`、`{{T2}}`、`{{S1/T2}}`、`{{#N}}` 四种：试跑时规格正文里有产品自身的 `{{sshmgr-secret:NAME}}` 语法，被当成占位符拒绝了。
    - 试运行有未决也打印完整计划，只有 `--apply` 拒绝；发布后的核对由脚本做。
    - **2026-11-12 起 `--batch` 同时负责「有规格、未拆票」和开发顺序。** 用户的用法是：只在一处运行 `find-next --batch` 决定做什么，再在多个 worktree 里各跑一个 `/implement-spec-split <规格号>`。所以 `--batch` 前半起草两类（缺规格、未拆票，后者用 `S<k>=spec:<n>` 分组，只拆票不建规格），后半总是输出全仓库的开发顺序。
    - 开发顺序由 `pipeline-status.sh --order` 确定性地算，不交给模型排：同样的状态每次给出同样的顺序，用户在几个 worktree 之间照着做不会乱。规则：被依赖的先做（规格 A 的票挡住规格 B 的票就建边 A→B，拓扑排序）→ 解锁下游多的先做 → 编号小的先做；第 1 波容量 = 并行数 − 进行中 − 中断；完全被挡住的不进第 1 波，部分被挡住的可以；中断的置顶「先恢复」；循环依赖单列，交给用户。模型只补 `--apart`（两份规格改同一块代码），因为这要读规格正文。
    - 输出要精简（用户 2026-11-12 要求）：每份规格一行，只给第 1 波命令，不写排序理由。
    - 起因：11-11 夜里三个会话同时运行 implement-spec-split，各自扫描、各自判断，#223 的会话以为 #222 没人做（其实一分钟前被领走），在 #228 里把 #222 的「权威端是否过旧」判断又写了一遍。开发顺序事先写清「#223 等 #222」就不会发生。
    - 只支持 GitHub 跟踪器：本地 markdown 跟踪器的规格写进 `SPEC.md` 章节，形态不同，需求出现再做。
    - **2026-11-12 改为确认后自动开会话**（之前定的是只输出顺序）。用户要以 find-next 为总入口：`--batch --workers N [--specs K]`，最后由 `launch-wave.sh` 先试运行（打印顺序表和每个会话要跑的命令），用户确认后加 `--apply --only` 在 Orca 里为新规格 `orca worktree create --branch spec-<n> --agent claude --prompt …`、为中断的规格在原 worktree `orca agent launch`。保留这一次确认：开工要花 GLM 额度。（2026-11-14 注：这个确认已被第 14 条取代。）
    - **同日再改为不确认、直接启动**（owner 2026-11-12 定）：`--batch` 发布后试运行打印顺序，紧接着加 `--apply` 启动全部可启动的条目；只有出现循环依赖时停下来问。规格发布前那一轮确认保留。合入后不自动接力开下一份，仍由用户再跑一次 `--batch`。（2026-11-14 注：最后一句已被第 14 条取代。）
    - **原 worktree 不在 Orca 列表里的恢复规格**（早先用 git 建在 `<仓库>-wt/` 下的）：Orca 命令行没有纳管已有 worktree 的命令，所以预留后在 Orca 管理的主工作树下 `orca terminal create --title spec-<n> --command "cd <worktree> && claude <命令>"`；主工作树也不在 Orca 里时才标「需手动」。代价是会话挂在主工作树的终端标签下，结束后不留输出。
    - `--workers N` 必填，是全机 worker 总数：每份 `--parallel` = N ÷ K，同时写进全机 worker 上限文件。否则 K 份各开 4 个会远超槽位，全在排队。（2026-11-14 注：必填已被第 14 条取代，现在先读状态文件和 max-workers。）
    - 先预留再启动：脚本先 `claim.sh reserve`（交接预留，带有效期，期间算进行中），再让 Orca 建分支和 worktree；新会话里的 `claim.sh take` 发现自己就在 `spec-<n>` 上，就接手预留，不再另建 worktree。若让 Orca 先建分支，`take` 会把它当成「中断」去问用户；若 Orca 用别的分支名，每份规格会多一个空 worktree。
    - 用 Orca 建的 worktree 才在 Orca 侧栏里可见（用户把外部 worktree 设成了隐藏），所以新规格的集成 worktree 由 Orca 建，不在 `<仓库>-wt/` 下；早先建在 `<仓库>-wt/` 下的中断规格不可见，脚本只给手动命令。
    - Orca 启动 Claude 时带 `--dangerously-skip-permissions`，自动开的会话不会卡在权限提示上；会话仍会在合入前确认 push、GLM 出错时停下等人。

13. **2026-11-14：`--batch` 也覆盖「地图本身该出一份规格」（起因：oa-helper 地图 #1）。** 它的子票全是已关闭的 `wayfinder:*` 决策票、前沿已空，且没有任何 Spec 用 `地图：#N` / `来源地图：#N` 行指回这张地图；此前脚本既不算 `missing` 也不算 `exploring`，`--batch` 只能手工走 `/to-spec`、`/to-tickets`。决定：`pipeline-status.sh` 新增 `mapSpecs` 段（默认与 `--all` 都输出），被 Spec 指回的地图不再进 `mapSpecs`（`exploring` 不受影响：批量起草的实现票规格也写 `地图：#N`，有规格不代表地图的决策都收口了）；指回行后面允许跟说明文字（#11 写的是 `来源地图：#1（全部决策见…）`）；批量组写法为 `S<k>=map:<地图号>`，一次起草一份地图级规格和执行票，规格正文只写 `地图：#N` 行、不写 `实现票：` 行，发布时新建规格并把执行票挂到它下面。

14. **2026-11-14：`find-next` 默认改为推进模式，规格合入后自动开下一波。** 用户目标是提高自动化程度：原先「只给一个 Next step」的行为改名 `--suggest`，`--batch` 只是推进模式别名。推进模式每轮扫描后自动派 worker 调查前沿 research 票，主会话复核结论、按 wayfinder 格式写 Resolution、关票、更新地图；`grilling` 票由 worker 准备问题/选项/推荐（`prototype`、`task` 要做原型或手工操作，仍交给 `/wayfinder`；worker 认为已有决定、无需再问的 grilling 票也要放进那一轮由用户点头才关，因为 wayfinder 规定 grilling 是 HITL、代理不能替人回答），主会话把决策题、调研转来的取舍题和规格草稿 `unresolved` 合成一轮问用户。人工关口保留三处：取舍/决策题的一轮确认、有未决的组发布前需答案、implement-spec-split push 前确认。research 结论清晰时不再问用户；草稿没有未决的组自动发布、不再单独确认。`/find-next --workers` 变为可选：推进器没读到全机 `max-workers` 文件才问用户；`launch-wave.sh --next-wave` 则先读启动状态，再读 `max-workers` 文件。规格直接合入 main 后，当前 Run 只在第 9 步末尾运行一条 `launch-wave.sh --next-wave --apply` 就收尾，不接力做下一份：合入时上下文已满，而下一份规格的事实都在 issue 和 main 上，新 Orca 会话从零开工更省 token、不串味。开发顺序每次由 `pipeline-status.sh --order` 重算，不缓存顺序本身；只缓存 workers/specs/apart 这些需要人或主会话判断的结果（`~/.cache/implement-spec-split/launch/<owner>__<name>.json`），避免下一波重复问或重复读规格。`launch-wave.sh --apply` 和 `--next-wave` 全程持仓库级 `launch-wave` 锁，防止两份规格几乎同时合入时重复计算、重复领取或重复启动；`--next-wave` 只启动空闲第 1 波，不自动恢复中断规格，遇到循环依赖非零退出交回 `/find-next`。

15. **2026-11-15：`/find-next --batch` 推进「没讨论完的地图」，成为地图、规格、票、开发的通用入口（grilling 定稿）。** 用户目标：除主动新开地图用 `/wayfinder` 外，只敲 `/find-next --batch`。此前推进模式只推前沿 research/grilling 票，漏了五种状态：(G1) `mapSpecs` 只看决策票全关，不看 `## Not yet specified`，迷雾还在就起草地图级规格；(G2) 关票后只追加 Decisions so far，不做 wayfinder 第 5 步（迷雾毕业、判出范围、作废失效票），前沿一空地图就停；(G3) `prototype`/`task` 票只列不做；(G4) 已认领但无人推进的票永远被跳过；(G5) 没有子票的空地图看不见。决定：
    - 地图就绪 = 决策票全关**且** Map fog 为空。判空规则：去掉 HTML 注释和空白后为空，或只剩「无 / （无）/ None / N/A」之类占位词；其余一律算有迷雾（宁可多出一条毕业建议）。前沿空但有迷雾的地图走迷雾毕业，不起草规格。
    - 迷雾毕业：关票后（以及扫描时遇到前沿空、有迷雾的地图）派 worker 读地图和 Resolution，提出新建票（问题、类型、阻塞）、要移出 Not yet specified 的段落、要判出范围或作废的票；作为「建议新建 / 建议判出范围」条目并入那一轮，用户同意后主会话建票、接线、改地图。判出范围改变地图边界，所以不自动做。
    - task 票：worker 判断能独自完成（AFK）就做，结果写成 Resolution 草稿；需要人的给清单放进那一轮。prototype 票：worker 做粗原型，UI 走 mockit，非 UI 放 `prototype/<票号>` 临时分支（主会话 push、不开 PR、永不合并，推进模式下不再单独确认），那一轮附链接问反应；每次运行最多处理 2 张 prototype，其余在收尾列出。
    - 那一轮里用户回「展开 <条目>」时，当前会话就地对该票做 grilling + domain-modeling，写 Resolution 后继续推进，不必另开 `/wayfinder`。
    - 已认领超过 3 天且无评论、无更新的决策票，在那一轮问「取消认领并纳入推进吗」，不自动取消（可能有别的会话在做）。
    - 空地图（`wayfinder:map` 没有子票）属于画图阶段，只在收尾提示用 `/wayfinder` 画图，不代办，与「新开地图用 wayfinder」的边界一致。
    - 单次运行最多问用户 3 轮，超出就收尾列出剩余待拍板事项，下次再跑接着推；用户可回「先到这」提前结束。
    - 规则不分叉：`--suggest` 在 Decision ticket 之后新增「地图迷雾待毕业」阶段（推荐 `/find-next --batch <地图>`），`--list` 增加「空地图」「认领后不动」两块，本地跟踪器 `scan.py` 同样按迷雾判断地图是否就绪。

16. **2026-11-15：推进模式接管散票分流；搁置执行票不算待实现。** 地图收尾时，迷雾会转成地图外的 `needs-triage` 散票；此前推进模式只把它们列在末尾，让用户自己判断去 `/wayfinder` 还是 `/grill-with-docs`，结果是无人推进（nexa #24 收尾后的 #49/#50 就是这个形态：正文带来源地图和「时机：」）。决定：
    - 散票分流：正文带「时机：」的票默认「等待时机」，只汇报条件和「要现在开就回『开 #N』」，不派 worker、不提问；其他 open、未搁置且非 `wontfix` 的散票由只读 worker 分成该开地图 / 单个决策 / 重复或过时 / 等待时机，并入同一轮问用户。等待时机是否成熟由人判断，避免推进器为了走完流程而催促或提前开工。
    - 建地图必须用户同意：地图的 Destination 和首批票是范围承诺，worker 只能给草案；同意后主会话建 `wayfinder:map`、子票和阻塞，并在同一轮复查扫描里继续推进新地图。默认关闭原散票并链接新地图，只有草案明确说明更好时才把原票挂为子票改造成首张 decision/research 票。
    - 搁置执行票不待实现：`pipeline-status.sh` 构建可实现规格和开发顺序时跳过 `isShelved` 的执行票；若某规格的未关执行票全是搁置票（如 nexa #40 只剩 #47），该规格不进「可以实现」/`--order`/波次，而在 `--all` 的「状态没收尾」提示可关闭规格。混合规格仍可实现，票列表给搁置票加 `(搁置)` 后缀，进度分母不变。

17. **2026-11-22：grill 题目最后一份规格落地时必须给出完成度结论与发版推荐；「等待时机」分流结论写回票面。** 起因：三份规格全部落地、master 比上一个 tag 多 75 个提交，收尾报告却只说「#371 等待时机」，用户看不出「做完了、该你发版」；同一天 `/find-next --batch 371` 跑三次，每次都重新分流同一张票，因为第 4 步只汇报不写票面。决定：`scripts/completion-report.sh` 统一产出「本次题目进度 + 全仓库状态 + 是否发版（含建议版本号）+ 会解冻的等待时机票 + 中断 grill」，implement-spec-split 落地成功后、find-next 收尾和 `--list` 都把它放在最上面；散票分流判为「等待时机」后由主会话把 `时机：<条件>` 写回票面、去掉 `needs-triage` 并留分流记录，下次扫描直接跳过。
18. **2026-11-24：推进运行可接续；推进模式持仓库锁；wayfinder 认领靠 Orca 判活。** 起因：ssh-manager-mcp 同一上午两个推进会话先后被关掉，一个写好了 #373 的起草说明，一个已经产出 #373 的分流结论（`triage.md`），都没写回票面；再跑 `/find-next` 时 #373 只是一张普通散票，旧产出看不见也用不上，两个会话差 2 分钟对同一仓库并发也无人拦。规格层早有认领记录判活（中断标「先恢复」），推进器自己和 wayfinder 认领没有。决定：
    - `find-next/scripts/run-state.sh`：推进运行开头写 `run-state.json`（仓库、owner pid 与启动时间、当前步骤），收尾或终止写 `finished_at`。下次推进第 1 步 `pending` 列出本仓库未收尾的运行；票级产出在票没更新过（`updatedAt` 早于 `result.md`）时复用，发布到一半的在旧目录重跑 `publish-batch.sh`，处理完 `abandon`。只列 owner 已死的新版运行：owner 还活着就是另一个正在跑的会话，归锁管。无状态文件的旧版运行按目录名含 `find-next`、7 天内、内容提到本仓库路径或 `owner/name` 识别，只剩已完整发布规格组的旧版运行不列；第一次上线时会列出若干正常收尾的旧运行，主会话核对后 `abandon`，之后不再出现。
    - 推进模式全程持 `lock.sh` 的仓库级 `find-next-advance` 锁，`--wait 0`，拿不到就停；会话被关掉锁按 pid 加启动时间自动失效。`--suggest`、`--list` 只读，不拿锁。
    - wayfinder 是上游技能，认领只写 Assignee、不记 pid，本仓库改不了，所以 `pipeline-status.sh --all` 新增 `orphanClaims`：认领不到 3 天、但 `orca terminal list --json` 里本仓库 worktree 下没有标题或屏幕预览提到 `#N` 的活 agent 终端的票，单列「认领但没有活会话」，推进模式那一轮问是否取消认领。判断是启发式（会话标题或屏幕没提到票号会误报），所以只提问、不自动取消；Orca 不可用时不判断，退回 3 天规则。
    - 已知限制：owner pid 由 `lib-owner.sh` 沿父进程找名为 `claude` 的进程；flash 模式等非 `claude` 进程名的编排会话找不到，会退回到当次命令的父 shell，锁和 `run-state` 的判活会立即失效（不会误拦，但也拦不住并发）。

## 评估过、没有采纳的方案

以后再有人提议引入同类东西，先看这里的理由是否还成立，别重复评估。

1. **2026-11-15：不集成 pstack（Lauren Tan / @poteto 的 `/poteto-mode` 技能包）。** 调研文档：`research_things/20261115_1215_pstack对比Matt技能调研.md`（用户的 research_things 目录，不在本仓库）。pstack 主打"开工后把活干扎实"，逐项对照本技能后，没有明显收益：
   - 多模型互审（`/interrogate`）：本技能已经是实现与 review 分模型（GLM/Sonnet 实现、Opus review、Spec 轴对照规格），这正是它的核心思路，而且做得更硬。pstack 在 Claude Code 里反而做不到按子代理指定模型。
   - "测试绿 ≠ 真能用"：每票 TDD、worker 验证门、merger 每次合并都重跑测试、Go 交叉编译 vet、落地前合 main 再跑一遍，已经覆盖。
   - 复现优先修 bug：已有 `mattpocock-skills:diagnosing-bugs`，而且不属于"规格→实现"这条流水线。
   - arena / swarm（同题多解、分片并行）：和机器级 `ISS_MAX_WORKERS` 共享一份 GLM 额度冲突；同一个模型写 N 份方案，差异也小。属于负收益。
   - playbook 逐字写进任务清单防跳步：关键步骤已经写死（"Do not skip this step"、落地锁、验证门）。
   - 会话接管 / 挂起：已有 `claim.sh` 的 interrupted/Recovery、worker `--resume`，以及 Ferryman 交接。
   - 成本：调研引用的实测是挂上 pstack 后时间和 token 都约翻倍；本机单供应商（GLM），多模型那部分价值还要再打折。

   唯一的真实增量是"项目级验证技能"：一组能在真实界面或真实运行里证明核心功能可用的脚本。但它是每个目标项目各自的资产，应写进该项目的 CLAUDE.md 和规格验收标准，本通用编排技能替不了。截至评估时，L3 记录里只在真实运行中才暴露的问题都出在编排脚本自身，还没有出现过"目标项目测试绿了但功能坏了"。**重新评估的触发条件**：实际跑波次时反复出现"review 和测试都过了，合入后功能却坏了"，再考虑在第 7 步 review 前加一步"仓库写了验证命令就先跑"。

## 同步上游

`upstream/` 里存着原版 `SKILL.md` 和对应的上游 commit（`upstream/COMMIT`）。

1. 先更新本机的 mattpocock 插件或市场仓库（`~/.claude/plugins/marketplaces/mattpocock`）。
2. 运行 `./check-upstream.sh`，看它打出的 diff。
3. 把有意义的变化改进 `SKILL.md`，同时对照上面的设计要点，别把它们改丢了。
4. 运行 `./check-upstream.sh --accept`，刷新存档和 commit 号。
5. 提交并 push。

再留意一下：
- 上游的 `code-review`、`tdd` 等技能如果改了名，或者不再开子代理，第 7 步也要跟着改。
- 脚本对比时不管换行符差异，因为本机插件文件是 CRLF 换行，仓库里是 LF。

## 自测

- **批量发布**：`bash find-next/scripts/test-publish-batch.sh`。用假 `gh` 测校验、试运行、发布顺序、占位符回填、未决、交接留言、只拆票的已有规格组、发布后调用开发顺序脚本、发布后核对、`--only` 与中途失败后重跑，不访问网络。
- **批量 Brief 生成**：`bash find-next/scripts/test-make-batch-briefs.sh`。用假 `gh` 测变量替换、上游技能版本选择与参数校验。
- **流水线状态**：`bash scripts/test-pipeline-status.sh`。它用假 `gh` 和临时 git 仓库测独立规格、单票规格、原版父规格、旧父 issue 形状、缺规格分组、探索中的地图、分支接手、外部阻塞、`--order` 开发顺序（状态、排序、波次、`--apart`、循环依赖）和 gh 失败，不访问网络。
- **进度看板**：`bash scripts/test-board.sh`。用假 orca、假 pipeline-status、临时 git 仓库和临时 Run/Worker 目录测仓库登记、刷新节奏、关系图快照、认领状态、Run 阶段、Worker 异常、终端/网页输出、EPIPE、Board pruning 和帮助文本，不访问网络。
- **Run 阶段记录**：`bash scripts/test-run-phase.sh`。用临时 HOME/ISS_STATE_DIR 测各阶段写入、覆盖、省略字段、最新 Run 目录选择、状态目录覆盖、写失败只警告和参数校验。
- **票进度标签**：`bash scripts/test-ticket-watch.sh`。用临时 git 仓库测 `ticket-watch.sh --once` 的 worktree、分支、领先提交、脏文件、最近提交和外部 worker run dir 输出，worktree 清理后的零退出提示，以及缺失参数和非法 interval 的报错，不访问网络。
- **编排看门狗**：`bash scripts/test-run-watchdog.sh`。用临时 git 仓库和小间隔测 `run-watchdog.sh` 的卡死（STALLED/退出码 3）、后台持续提交判活到 max（ALIVE/退出码 2）、worktree 消失判结束（DONE/退出码 0）、多对象混合输出、worker run dir 进展计入指纹和参数错误（退出码 64），不访问网络。
- **delegate-guard**：`node hooks/test-delegate-guard.js`。测普通阈值、flash 源码拦截与子代理放行、Bash 各类源码写入形态、裸调 `codex exec` 在所有会话（含子代理、非 flash、`DELEGATE_GUARD_DISABLE=1`）被拦而 wrapper/非 exec 子命令/字符串与 heredoc 字样放行、`gofmt -w`/`goimports -w`/`go fmt` 放行、项目配置与例外开关，不访问网络。
- **锁与领取记录**：`bash scripts/test-locks.sh`。测 `lock.sh` 的互斥、重入、等待超时、死持有者接管、槽位排队，`claim.sh` 的领取、并发领取、恢复与释放权限、交接预留与接手，worker 上限配置文件，以及两个 `codex-worker.sh` 在 `ISS_MAX_WORKERS=1` 下排队，不访问网络。
- **Design session**：`bash scripts/test-design-session.sh`。用假 orca 测 feature/map prompt、`--agent claude`、`orchestration check --wait` 超时、会话退出、launch/check 失败、handoff 缺失、启动前未交接 session 提醒（7 天内、无 handoff、同仓库名前缀才提醒；过期、已交接、其他仓库不提醒且退出码不变）和两个薄技能文本（含提醒转述），不调用真实 Orca。
- **完成度结论**：`bash scripts/test-completion-report.sh`。用临时 Design session 目录、带 tag 与提交的临时 git 仓库、假 `gh` 和假通知命令，测情形 1/2（推荐 A/B）/3、无 tag、未发布提交为 0、minor/patch/非语义化 tag 版本号、发版解冻与普通等待时机、中断 grill、`--notify` 仅完成时通知一次且失败不改变退出码、gh 失败写「（查询失败）」和用法错误退出 64，不访问网络。
- **grill 进度查询**：`bash scripts/test-grill-status.sh`。用临时 Design session 目录和假 `gh` 测已完成 / 进行中 / 中断（有无 topic.md）、仓库名前缀不误匹配、gh 失败和无记录，不访问网络。
- **自动启动第 1 波**：`bash find-next/scripts/test-launch-wave.sh`。用假 pipeline-status、claim、max-workers、orca 测试运行输出、不在 Orca 时的手动输出、预留后再启动、预留冲突跳过、启动失败撤销预留并删空分支、`--only` 过滤和恢复条目（含原 worktree 不在 Orca 时在主工作树开终端标签、路径带空格的转义）、`--apply` 写启动状态、`--next-wave` 读取状态/max-workers、跳过中断条目、无可启动、循环依赖和仓库锁占用，以及 `--impl agent --agent-model` 的命令后缀、状态写入/读回、旧状态回退 codex 与非法参数，不调用真实 orca。另测 `FLASH_ORCHESTRATOR=1` 的首波/恢复路径用 `openclaude`、终端用 `claude-flash`、默认 agent 后端写入状态，以及无标记的下一波从状态读回 flash 选择。
- **codex 后端**：`scripts/selftest-codex.sh [--only L1|V1|V2|V3]`。各级的内容见脚本开头的注释和 `docs/codex-backend.md` 第三节：
  - V1：假 codex，确定性，不花 GLM；
  - V2：真 codex 连假服务器（`scripts/testing/mock-responses.js`），不花 GLM，要跑 6–7 分钟；
  - L1、V3：真 GLM，要求配置的模型端点可用（作者环境：Ferryman）。V3 会跑 tdd 小 ticket、Resume，以及 2 个 worker 并发。

  改了 `codex-worker.sh` 或 `progress.sh`，或者升级了 codex，都要把 V1、V2、V3 全部重跑一遍。用 `--impl codex` 跑技能时，第 0 步会跑 L1。
- **codex worker home 生成**：`bash scripts/test-setup-worker-home.sh`。用临时目录里的假源 home 测配置键/表过滤、`model_catalog_json` 改写、文件复制、权限、幂等备份和输出不泄漏配置值，不访问网络、不碰真实 `~/.codex`。
- **Opus review 入口**：`bash scripts/test-opus-review.sh`。用临时 HOME/PATH 里的假 `claude` 测三类 prompt、GLM 代理环境变量清理、`--model opus`、只读工具白名单、findings 原子写入、认证/额度/超时/其他错误的不同退出码和超时进程树回收，不访问网络、不花 Opus 额度。
- **L1 连通性（pi）**：`scripts/selftest.sh --only L1`。用 `--impl pi` 跑技能时，第 0 步也会执行这个检查。
- **L2 wrapper（pi）**：`scripts/selftest.sh`。它会在 `~/.cache/implement-spec-split-selftest/` 下建一个临时仓库和 worktree，让 pi 用 tdd 技能实现一个很小的 ticket，然后检查这几件事：
  - 有新 commit，工作区是干净的，测试我们自己重跑能通过；
  - 运行目录里的文件都在；
  - pi 确实读了 tdd 的 `SKILL.md`。

  另外还会测 Time limit（`--time-limit`）、Resume（先把一个小 tdd ticket 用很小的 Time limit 停在退出码 5，再 `--resume --run-dir` 用正常上限续完，断言退出码 0、`segments` = 2、`new_commits` 从第一段 base 起算、树干净、我们重跑测试通过、两个段的事件都在 `events.jsonl` 里）、坏 Resume（没有存档的 run dir 退出码 64；存档里 session 文件丢了的也退出码 64，都不需要真 pi）、Idle timeout、非 watchdog 杀死（假 pi 自杀成 137，断言按 `error` 处理而不是可 Resume 的 `timeout`）、整段 Time limit（假 pi 每次都报 429，重试等待要把整段预算烧完，断言不再新开 attempt 而按 `timeout` 停）、杀进程树（假 pi 起一个原生 node 子进程，断言 pi 被杀时子进程也死）和认证失败几条路径，除前两条外全用 `PI_WORKER_PI` 造假 pi，确定性、不依赖 GLM。全部通过就删掉临时目录，失败则保留，方便排查。改了 `pi-worker.sh` 或升级了 pi 以后，都要重跑一遍。
- **L3 端到端**（手动）：私有仓库 `allanpk716/iss-e2e-test` 先留着，以后做回归测试接着用，本地路径是 `~/orca/iss-e2e-test`，已经加进 Orca。再测时开一个新 spec 就行，不用重建仓库。第一次搭建的步骤如下：
  1. 在 GitHub 上建一个临时的私有仓库，加一个最简单的 Node 项目（只要能跑 `npm test` 就行）。再执行 `/setup-matt-pocock-skills`，让 tracker 用 GitHub。
  2. 开一个 spec issue，下面挂 3 个子 issue，其中 #2 被 #1 阻塞。
  3. 在这个仓库里执行 `/implement-spec-split --impl codex`（或 `--impl pi`）。
  4. 检查以下几点：
     - 不带参数时，第 0 步能找出这个 spec；
     - 第一批只派发了 #1 和 #3，#1 合并之后才派发 #2；
     - merger 是一个一个跑的；
     - 到 Time limit 被停下的 worker 被 Orchestrator Resume 一次（`--resume --run-dir`），续跑后通过验收检查（`segments` = 2）；
     - review 的两个子代理用的是 `REVIEW_MODEL`；
     - fix 也是由 External worker（codex 或 pi）来跑的；
     - （codex）跑完没有残留的 codex/node 进程，`progress.sh` 的输出和 `status.json` 一致；
     - 最后的报告里列出了每次运行的目录，并且标注了是否在高峰期。
  5. 用 `--impl agent`（或别名 `--impl sonnet`）再跑一遍。这次重点看：实现类的子代理确实用了 agent 模型（`--agent-model`，默认 `IMPLEMENT_MODEL`），而且全程没有调用 `pi-worker.sh`；给了 `--parallel N` 时实现类子代理的并发确实不超过 N。

## 安装方式

- 面向 AI Agent 的安装/调用快速入口见 `docs/ai-agents.md`。
- 技能目录 `~/.claude/skills/implement-spec-split` 是这个仓库的 git 克隆。
- 如果在别的地方的克隆里改（比如 `~/orca/implement-spec-split`），commit 之后要在技能目录里执行 `git pull --ff-only <那个克隆的路径> main` 同步过去。
- 不用软链接，因为 Windows 上软链接很麻烦。
- `find-next` 是本仓库里的子目录技能，要单独让 Claude Code 发现：mac / Linux 上软链接 `ln -s <克隆>/find-next ~/.claude/skills/find-next`；Windows 上用目录联接 `mklink /J`，或者直接复制。

## 已验证（2026-10-11，临时仓库 `allanpk716/iss-e2e-test` 上的 L3 测试）

- 不带参数运行时，第 0 步用 `sub_issues_summary` 查询能正确找到 spec。
- `--impl pi` 的完整流程走通了：
  - 前沿调度正确：先跑 #2 和 #3，两个都合并后才跑 #4；
  - merger 一次只跑一个；
  - 每个 worker 都经过了验收检查；
  - 写代码的 worker 都读了 tdd 技能；
  - fix 角色按 review 报告改好了；
  - 第 9 步合并、push、关单都正常。
- review 的两个子代理确实跑在 `REVIEW_MODEL`（opus）上。
- 发现的问题：主代理用 sed 从上一份 Brief 改出下一份，结果留下了错误的 issue 编号。已经在 `SKILL.md` 里要求每份 Brief 都从头写。

## 已验证（2026-10-14，`iss-e2e-test` 的 spec #5，L3 测试 Time limit 和 Resume）

- 为了确定能触发 Time limit，#6 implementer 的第一段故意把 Time limit 设得很小。其余角色都用 Config 里的值。
- 第一次给 60s：worker 停在 `timeout`，没有任何进展（`new_commits` = 0，工作区干净）。主代理按规则判断出"不 Resume，要问用户"。
- 换新的运行目录，给 150s：停在 `timeout` 时工作区是脏的（有进展）。主代理用 `--resume` 续了一次，用的是 `GLM_TIME_LIMIT_IMPL`：
  - 用的还是同一个 pi 会话：只有一个会话文件，第 2 段收到的是 Resume 提示词；
  - 第 2 段 87s 就提交完成；
  - `segments` = 2，`new_commits` = 2，从第一段的 base head 起算；
  - 通过了验收检查，merger 重跑测试也通过了。
- `--time-limit` 和 `--idle-timeout` 在真实运行中都生效了。merger 用的是 `GLM_TIME_LIMIT_SHORT`，各跑了 16–21s。
- 发现的问题：Brief 直接写在运行目录里时，wrapper 用 `cp` 拷贝自己，会往 stderr 打一条 "same file"。已经改成同一个文件就跳过。

## 已验证（2026-10-17，codex 后端 V0–V3）

- `selftest-codex.sh` 的 V1（42 项）、V2（8 项）、V3（16 项）全部通过，跑完没有残留进程。
- 发现并修复了一个只在真实运行里出现的问题：Windows pid 复用，导致已结束的 run 被报成 `running`。

## 已验证（2026-10-18，`iss-e2e-test` 的 spec #8，L3 测试 `--impl codex`，即 V4）

- 不带参数运行，第 0 步找到了 spec #8，并先跑了 codex 的 preflight（`selftest-codex.sh --only L1`）。
- 调度正确：#9 和 #11 并行；#9 合并之后才派发 #10；merger 一次只跑一个，时间上不重叠。
- 8 次 worker 运行（3 个 implementer、4 个 merger、1 个 fix）全部是 codex：
  - 都是一次 `ok`，单段，耗时 22–144s；
  - 整个 spec 从派发到修复合并共约 11 分钟。
- 写代码的 worker（implementer 和 fix）都读了 tdd 的 `SKILL.md`。每次运行都通过了验收检查。
- review 的两个子代理跑在 opus 上，fix 由 codex 完成，修了 3 项。
- 第 9 步 push 和关单之前，主代理停下来问了用户。
- 跑完没有残留的 codex 进程；每个 run dir 上 `progress.sh` 都显示 `finished: ok`，和 `status.json` 一致。
- 本次没有走到 Resume、`stalled` 和补救这几条路径（V3 用真 GLM 测过 Resume，V1 用假 codex 测过其余路径）。

## 已验证（2026-10-18，全局"写代码交给 codex worker"流程，即 V5）

全局 `~/.claude/CLAUDE.md` 改成用 `codex-worker.sh` 写代码之后，在 iss-e2e-test 里新开一个会话，让它修 V4 review 留下的取整 bug（`0 K` 输出 `-273.1 °C`）。提需求时没提 codex。

- 主代理没有自己用 Edit/Write 改代码，也没用 `pi -p`。它写的 Brief 很规范：根因定位到 `format.js:9`，写了改法和验收标准，也写了"不要 commit"和"不要 rm -rf"。
- 它用 `codex-worker.sh` 在后台运行 worker，22s 就 `ok` 了。
- 主代理看了 diff、跑了测试（68 项全过），然后自己 commit 并 push。
- 问它"进行到哪了"时任务已经做完，所以它直接汇报了结果，没有调 `progress.sh`。运行中用 `progress.sh` 查进度，在 V3、V4 里验证过。

## 尚未验证的事项

- 用 `--impl agent` 跑一遍完整流程，确认实现子代理真的跑在 agent 模型（默认 `IMPLEMENT_MODEL`）上；含非默认 `--agent-model`（例如 GLM 代理环境下的 `opus`）和 `--parallel` 限流的实机验证。
- `stalled` 在真实 L3 运行里的表现（目前只有 L2 用假 pi 做的确定性用例）。
- 第二次 `timeout` 时主代理会停下来问用户（2026-10-14 的 L3 里 Resume 一次就完成了，没走到这条路径）。
- exploration 角色。在小仓库里，主代理会按"可选"直接跳过它。
- 验收检查能不能拦住不合格的 worker。L3 里所有 worker 一次就通过了，没有触发过拦截。
- GLM 出错的处理：碰到 auth、quota 或 transient 错误时，主代理会不会停下来问用户。L2 只测了 wrapper 会不会给出正确的退出码。
- 有 PR 流程的仓库里，draft PR 能不能开出来、最后能不能标成可以 review。

验证过的项目从这里删掉，发现的新问题补到"设计要点"里。
