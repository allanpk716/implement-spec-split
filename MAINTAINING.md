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
   - **2026-11-18 决定：订阅 OpenAI 官方 Codex 套餐后，Worker harness 仍是 codex，Worker model 仍固定 GLM。** 订阅只用于用户自己交互。不换 harness 的原因：`codex-worker.sh` 每次显式传 `-m` 和 `-c model_provider=custom`，GLM key 在 custom provider 里，ChatGPT 登录写的是 `auth.json`，两者不冲突；换成别的 harness 要重新解决进度可见、Resume、杀进程树这些问题，还要重写 wrapper 和自测。评估 harness 的标准固定为五条：外部能看到进度、能 Resume 原会话、能连子进程一起杀干净（含 Windows）、在智谱支持名单内、会读 CLAUDE.md 和技能文件。（2026-11-27 修订：「Worker model 仍固定 GLM」改为由用户的全局开关 `/worker-model` 决定——默认仍是 GLM（glm-5.4），可热切换到 glm-5.3 或 glm-5.3-flash，见第 42 条和 ADR 0003；harness 仍是 codex，这一条不变。）（2026-11-28 注：`/worker-model` 已删除，Worker model 改由用户的阶段路由表 `/grill-router` 决定——「调研起草」和「实现」两行，默认仍是 glm-5.4，见第 44 条和 ADR 0004。）
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
26. **2026-11-23：grill-feature / grill-map 交接后用 launch-wave 开实现会话。** oa-helper 规格 #80 的 Design session 交接回主会话后，主会话按第 5 步「走 `/implement-spec-split 80`」用 Skill 工具调本技能，因为设了 `disable-model-invocation` 被拒，只能停下让用户手敲。本技能保留 `disable-model-invocation`（Run 会花额度、会 push，只能由人或 launch-wave 发起）。两份 grill 技能的第 5 步改为跑 `launch-wave.sh --repo <owner/name> --only <n>[,<m>…] --apply`：它领取规格、开 worktree，并在新 Orca 会话里把 `/implement-spec-split <n>` 当作用户输入发出去。launch-wave 失败，或某份规格要手动启动时，才提示用户手敲。注意：试运行会打印整份开发顺序，`--apply` 只启动 `--only` 里列出的规格。（2026-11-27 注：两份技能第 5 步的 launch-wave 流程已被第 43 条取代，交接后直接接 find-next。）
27. **2026-11-23：默认 worker 模型升到 GLM-5.4。** 环境侧（`~/.codex-worker/config.toml`、claude-glm / claude-flash 的 models.env）已改用 glm-5.4（1M 上下文、支持图片输入），但 `codex-worker.sh` 默认用 `-m glm-5.3` 显式传模型，config.toml 里的值不起作用，worker 实际仍在跑 5.3。现在把脚本默认值、`SKILL.md` Config（`CODEX_MODEL` / `GLM_MODEL`）、测试和说明文字都改成 5.4；flash 档没有 glm-5.4-flash，仍用 glm-5.3-flash。上面第 24 条、ADR 0001 和 `docs/codex-backend.md` 记录的是当时的实测，保留 5.3 的写法。以后升级模型时，除了改 config，还要改脚本默认值。（2026-11-27 修订：脚本默认值现在只在 `scripts/worker-model.sh` 定义一次（`DEFAULT_MODEL`，允许值列表由它拼出），`codex-worker.sh` 和 `selftest-codex.sh` 用 `--print default` 向它要，`SKILL.md` 的 `CODEX_MODEL` 已删除；以后升级默认模型只改那一处，再加文档里的 glm-5.4 字样。见第 42 条和 ADR 0003。）（2026-11-28 注：Worker model 开关已删除，默认值改为只在阶段路由表 `scripts/stage-route.sh` 定义一次，`codex-worker.sh` 每次派发时读「调研起草」或「实现」那一行；见第 44 条和 ADR 0004。）
28. **2026-11-24：launch-wave 启动的会话默认无人值守落地（`--auto-land` 变默认，新增 `--no-auto-land` 退出）。** 事故：2026-11-23 oa-helper 规格 #75 由 grill 交接用 `launch-wave --only 75 --apply` 启动，没有 `--auto-land`，且不带它的 `--apply` 会清掉旧授权；会话 23:01 做完后停在第 9 步等确认 push，用户次日 08:26 才点，会话缓存失效白费 token。grill 交接路径根本不问授权，第 21 条靠 find-next 第 6 步那一问覆盖不到它。决定：
    - 凡经 `launch-wave.sh` 启动的会话（find-next 推进模式——2026-11-27 起 grill-feature / grill-map 交接也走它，见第 43 条；规格合入后的 `--next-wave --apply`）默认带 `--auto-land`，做完自动合入 main / push / 开下一波，不再停下问人；试运行（不带 `--apply`）生成的命令同样默认带 `--auto-land`。
    - 退出用 `--no-auto-land`；`--auto-land` 保留为可接受参数（等同默认，向后兼容），不报错。`--apply` 写启动状态时总是显式写 `auto_land: true` 或 `false`（`--no-auto-land` 时为 false）。
    - `--next-wave` 读状态：只有 `auto_land === false` 才关闭；字段缺失（旧状态文件）或状态文件不存在时视为开启。`--next-wave` 仍不接受 `--auto-land` / `--no-auto-land`，报错说明两者都要在初始 `--apply` 时给。
    - find-next 第 6 步不再问「本批无人值守落地吗？」；调用时带 `--no-auto-land` 才不落地并透传给 launch-wave，`--auto-land` 保留为兼容别名。手动敲 `/implement-spec-split <n>` 不带 `--auto-land` 仍保持 push 前确认，SKILL.md 第 9 步逻辑不改。无人值守落地本身的行为（合入/合 PR、CI 红自动修两轮、停车报告、落地报告）不变。
    - 2026-11-25 补充：见第 29 条，无人值守时带推荐的取舍改为自动拍板，部分落地不再算停车。
29. **2026-11-25：停车只留给真要人决定的事；find-next 会话常驻做总控；规格会话做完自关。** proxy-hub 一夜实测：规格 #18 全部做完、测试全绿，却因 Opus 的 8 条「需要人取舍」停车，只写在 issue 评论里没人看见；规格 #21 做完 2 张票后，剩下 4 张等规格②③也被标成停车，保留的 `spec-21` 分支让它显示为「中断」、占波次名额，而 `--next-wave` 从不恢复中断的规格，所以②③落地后也不会有人接着做；做完的会话一直挂在 Orca。用户对 11 条取舍里 10 条选了 Opus 推荐，剩下 1 条本就没有推荐。owner 定：
    - `opus-review.sh` 三类提示词在每条取舍的 `推荐：` 后加 `可自动采纳：是|否 — <原因>`；只有 `推荐：无`、不可撤回或对外（删数据、发布、外部服务、生产部署）、需要人动手或只有人知道的事才写「否」。无人值守 Run 对「是」按推荐落地并在落地报告列 `### 自动拍板（可推翻）`；「否」、`推荐：无` 或缺这一行才停车。flash 仍不自己判断，只照 Opus 的标记执行。
    - 停车报告第一节固定为 `### 需要你决定`（问题轮格式），不再写「回 find-next 选『先恢复』」之类让人猜的话。
    - 部分落地不是停车：落地后删 `spec-<n>` 分支（已全部进 main），规格回到空闲，阻塞它的规格落地后由 `--next-wave` 当新规格开起来；阶段记 `waiting`。部分落地也跑第 9.5 步的 `--next-wave`。
    - 无人值守 Run 最后一条命令是 `scripts/close-self.sh`：先跑一次 `progress-tab.sh close-all` 关掉本 worktree 的进度标签，再只关本会话自己的终端（按 `ORCA_TAB_ID` + `ORCA_AGENT_PANE` 找句柄），落地后连 worktree 一起删（干净且已并入 origin 才删）；会话开在主 worktree 的标签里时绝不删主 worktree、不用 `--all`。
    - find-next 推进模式收尾后不再让用户 `/clear` 和看 GitHub，而是进入「总控」（也可 `/find-next --watch` 单独进入，持 `find-next-supervise` 仓库锁）：后台跑只读的 `find-next/scripts/watch-specs.sh`，有落地/部分落地/停车/会话死掉才唤醒会话；停车的待决事项合成一轮问用户，答案写成规格 issue 的 `## 拍板` 评论后 `launch-wave --only <n> --apply` 恢复；Recovery 读最新的 `## 拍板` 执行。监控用脚本阻塞而不是 ScheduleWakeup 轮询，平时不花 token。
    - 选择不在 launch-wave 里禁止「部分被挡」的规格进第 1 波：先做能做的票能并行，代价只是多开一次会话；现在它能干净收尾、自动续上，就不再是问题。
30. **2026-11-25：遗留的 `spec-<n>-*` 分支只有还带着没进主分支的提交时才算已接手；主分支按 origin/HEAD → origin/main → main 的顺序找，都找不到就不过滤。** 局限：squash/rebase 方式合入的遗留分支不是 main 的祖先，仍会被判为未合入。
31. **2026-11-25：无人值守 Run 硬禁 AskUserQuestion（`hooks/unattended-ask-guard.js`）。** proxy-hub spec-19 的会话以 `/implement-spec-split 19 --impl agent --agent-model sonnet --auto-land --parallel 2` 启动，属于无人值守落地，规则要求不能等人；但会话按旧提示词弹了 5 次 AskUserQuestion，每次都卡到第二天有人来答。提示词已经改了（第 29 条：可自动采纳的取舍自动拍板），这个 hook 是不依赖模型理解提示词的硬兜底。决定：
    - 只处理 `tool_name === "AskUserQuestion"`，其他工具无输出退出。判定从 transcript（payload 的 `transcript_path`，JSONL）读：只对含 `/implement-spec-split</command-name>` 的行做 JSON 解析，取最后一次调用的 `<command-args>`，按空白切分，恰好有 `--auto-land` 才拒绝；以最后一次为准（先带后不带放行）。content 是字符串或 `[{type:"text", text}]` 数组都支持。
    - 为什么从 transcript 判定而不靠环境变量：会话由 `orca worktree create --agent … --prompt` 启动，没法给这一层注入环境变量；手动输入 `/implement-spec-split … --auto-land` 也要覆盖。子代理的 `transcript_path` 可能指向主会话 transcript，规则一样，不特判 `agent_id`。
    - 逃生口 `UNATTENDED_ASK_GUARD_DISABLE=1`；`transcript_path` 缺失、不可读、坏行或内部异常一律 fail open（不输出、退出 0）。按块流式读，几 MB 的 transcript 远低于 1 秒（测试断言 < 1 秒）。
    - 和 `ask-sanitize.js` 各自注册，两个 hook 都命中时 deny 覆盖 ask。

32. **2026-11-25：落地 push 前硬检查 land 锁（`hooks/land-push-guard.js`）。** proxy-hub spec-22 的 flash 会话在落地时执行了 `lock.sh acquire land --scope repo`，实际返回 2（spec-19 正占着锁），但会话在外面包了一层 `echo`，外层退出码变成 0，被误读成拿到了锁，于是在没持锁的情况下执行了 `git push origin HEAD:main`。决定：
    - 只在 transcript 里出现过 `/implement-spec-split` 命令调用（`<command-name>/implement-spec-split</command-name>`）的会话生效，带不带 `--auto-land` 都算；其他会话（包括人手动 push）一律放行。
    - 识别推送复用 delegate-guard 的 shell 分词和命令位置识别（先去掉 heredoc 正文，再剥掉重定向），在命令位置上找 `git … push …`，允许 `git -C <dir>` 这类全局选项，不用正则匹配整串命令；目标仓库目录依次取 `-C` 参数、命令里前置的 `cd <dir> &&`、payload 的 `cwd`。默认分支取 `git -C <dir> symbolic-ref --short refs/remotes/origin/HEAD` 去掉 `origin/`，失败时 `main` 和 `master` 都算。refspec 的目标端（`src:dst` 的 `dst`，或单写的 `<branch>`）是默认分支名，或没写 refspec 而当前分支就是默认分支，才视为落地 push；推 `spec-<n>` 等其他分支、`--tags`、`--delete` 其他分支一律放行，`--all`/`--mirror`/`--branches` 和匹配 refspec `:` 按 push 默认分支处理。
    - 实现上把 shell 分词和命令位置识别抽到 `hooks/lib-shell.js`，transcript 扫描抽到 `hooks/lib-transcript.js`；`delegate-guard.js` 和 `unattended-ask-guard.js` 改为复用这两个模块，行为不变。
    - 检查锁：`<git -C <dir> rev-parse --git-common-dir>/implement-spec-split/locks/land.lock/owner.json` 必须存在，`pid` 等于 hook 沿父进程向上找到的第一个 `claude` 进程 pid，`pid_start` 有记录时还要与 `scripts/pid-start.sh` 取到的启动时间一致；不满足就 deny。
    - 为什么做成 hook 而不只改提示词：这次不是模型不知道规则，而是外层 `echo` 把 `lock.sh` 的退出码 2 吃掉了；提示词写得再清楚，也挡不住退出码误读。hook 直接读锁目录和 `owner.json`，不依赖模型理解退出码，也不依赖它主动检查。
    - 逃生口 `LAND_PUSH_GUARD_DISABLE=1`；任何内部异常、`transcript_path` 缺失或不可读、找不到 claude 祖先进程都 fail open（后者在 stderr 打一行说明）。`LAND_PUSH_GUARD_OWNER_PID` 仅供测试注入本会话 claude pid，与 `scripts/lib-owner.sh` 的 `ISS_OWNER_PID` 同理。

33. **2026-11-26：Opus review 输出后校验「## 需要人取舍」的标记，缺了先用同一模型补标一次。** 11-20 至 11-25 排查：旧审查结果里这一节的条目没有 `可自动采纳` 行，flash 会话按第 29 条只能停车，3 次停车共等了 7.5 小时。决定：
    - 解析 `## 需要人取舍` 一节，每个顶层条目（编号或 `-`/`*` 开头）都必须有 `推荐：` 行和 `可自动采纳：是|否` 行；这一节不存在或只写「无」时通过。
    - 缺失时把原输出和缺失清单发回同一模型补标一次，要求只补这两行、其余原样保留；补完仍缺失就以新退出码 **7** 退出，stderr 列出缺失条目，头注释登记这个码。不降级、不跳过。
    - 测试在 `scripts/test-opus-review.sh`：缺标 → 补标成功、缺标 → 补标仍失败（退出码 7）、标记齐全（不重试）、一节写「无」、没有这一节。

34. **2026-11-26：同一 Run 的「review → fix → 复审」最多 3 轮。** 证据：spec-19 走了 4 轮（fix-review → fix-conflict → fix-conflict2 → fix-conflict3），每轮复审又出新 findings，循环没有下限。决定：全规格审查与冲突复审各自计数（一次冲突复审另起一个计数器，所以一个 Run 最多 3 轮全规格 + 3 轮冲突）。第 3 轮复审后仍有 findings 时：只剩机械项或「可以不改」的，直接落地并在落地报告列为已知遗留；还有正确性问题的，停车，类别 `error`。写在 Steps 第 8 步、Unattended landing 和 Flash mode 三处，后两处各一句并指回第 8 步。

35. **2026-11-26：新增 `scripts/frontier.sh`，前沿只从它的输出来。** 证据：spec-21 的会话凭读代码自己画依赖表，把被阻塞的票做掉了。决定：
    - `frontier.sh --repo <o/n> --spec <n>`：票集按第 0 步 Spec-to-Ticket 规则取，直接复用 `pipeline-status.sh --graph`，再逐张未关执行票查 `dependencies/blocked_by`；没有 open 阻塞票、不是搁置票、不是 `ready-for-human` 的才是前沿，一行一个票号。
    - 输出另起 `# blocked`（被挡的票及其 open 阻塞票）、`# human`（人工票）、`# shelved`（搁置票）。任一 gh 查询失败以非 0 退出、stderr 说明、stdout 不打印任何东西（fail closed）。
    - SKILL 第 1 步和第 6 步：前沿只能来自这个脚本，禁止自行判断，也不要自己查 `blocked_by` 去推翻它；脚本失败等 30 秒重试一次，再失败停车，类别 `transient`。
    - 测试 `scripts/test-frontier.sh` 用假 `gh` 跑真实 `pipeline-status.sh`。
    - 2026-11-28 注：第 45 条硬保证②给前沿多了一个条件——带 `shared-counter` 标签的票一次只放行编号最小的一张，其余即使没有开放阻塞也列在 `# blocked`、原因写「（等共享计数器：#m）」；上面「没有 open 阻塞票…的才是前沿」和「`# blocked`（被挡的票…）」两句对这类票不再完整。

36. **2026-11-26：`ready-for-human` 执行票与搁置票同等对待，并新增运维票规则。** 证据：proxy-hub #49 是上线票，原标 `ready-for-human`；用户决定改由 agent 经 ssh-manager 自动上线，票面带「## 护栏」一节。`pipeline-status.sh` 原来不认这个标签，一旦解除阻塞就会把真正的人工票派给实现者。决定：
    - `pipeline-status.sh`：带 `ready-for-human` 的执行票算「非待实现」，在票列表里加 `(人工)` 后缀；规格未关执行票只剩人工票（可混搁置票）时，不进「可以实现」、`--order` 和波次，改在 `--all` 的「状态没收尾」提示 `人工票待做：#n`。`--order --json` 现有字段不变，`--graph` 只新增 `tickets[].human`、`specs[].human_only` 和 `status: human`。
    - SKILL 新增 **Ops tickets**：票面写明经 ssh-manager 执行、带「## 护栏」或带 `ops` 标签的票是运维票；agent 后端在提示词里允许 `mcp__ssh-manager__*`（先 `list_servers`）并原文照抄护栏，codex 后端给 worker 加 `--mcp ssh-manager`、Brief 同样照抄护栏；违反护栏或验收不过时实现者只报告、不硬推，主会话停车，类别 `error`，停车报告附回滚步骤；运维票不走 TDD、不要求 commit，没有代码改动时验证闸门改为「票面验收标准逐条有证据」。
    - `ready-for-human` 票一律不派发。
    - 2026-11-27 注：find-next 三份批量起草 Brief 模板里「本票由 Opus 执行」的触发条件收窄为「真的不能交给实现者的事（需要用户本人的身份、凭据或物理动作）」；能由实现者经 ssh-manager 做的按上面的运维票写（正文写明经 ssh-manager 执行 + 「## 护栏」），保持 `ready-for-agent`。起因见 find-next 设计要点第 21 条。

37. **2026-11-26：落地时补开的后续票必须挂到规格下并登记 `blocked_by`。** 证据：spec-22 落地时补开收尾票 #50/#51/#52，只把依赖写在标题里（「依赖规格②」），没有挂到规格下，也没有登记 `blocked_by`，之后还把规格关了；三张票成了散票，按跟踪器的阻塞关系计算前沿时还会被误判为可以开工。决定：同时做到三件事——`gh api -X POST .../issues/<spec>/sub_issues -F sub_issue_id=<id>` 挂到本规格下；对它依赖的每张票 `gh api -X POST .../issues/<t>/dependencies/blocked_by -F issue_id=<id>`；规格保持开着，按部分落地处理。`<id>` 是 issue 的 `id` 字段（`gh issue view <n> --json id --jq .id`），不是编号。只写标题或正文不算依赖。

38. **2026-11-26：停车报告加两行机器可读的类别与可恢复时间。** 证据：另一个 worker 正在写守护程序 `scripts/keeper.sh`，要靠停车报告判断能否在额度重置后自动恢复。决定：`## 停车报告` 标题之后紧跟两行，写在 `### 需要你决定` 之前：`停车类别：quota|transient|decision|error|other`、`可恢复时间：<ISO 8601 含时区>|无`。`quota` 填额度重置时刻（不知道就当前时间 + 5 小时），`transient` 填当前时间 + 30 分钟，其余填 `无`。keeper 在可恢复时间之后自动恢复 `quota` 和 `transient`，所以「额度用尽」不再写成「等人恢复」。Opus review 退出码为 3（额度或 429）时按 `quota` 停车，其余退出码仍按原规则。

39. **2026-11-26：无人值守 Run 结束前必须自关，且不许以问人结束（`hooks/unattended-stop-guard.js`，Stop 事件）。** 证据：11-20 至 11-25 的 19 个无人值守 Run 调用过 `close-self.sh` 的是 0 个，10 个以「可以 /clear 了」结尾空转；spec-18 用纯文本发问后停住，`unattended-ask-guard` 只拦得住 AskUserQuestion。决定：最近一次 `/implement-spec-split` 带 `--auto-land` 时生效；规则 A：`run.json` 的 phase 为 done/waiting/parked 且 transcript 里没有 Bash 运行过 `close-self.sh` 就 block；规则 B：phase 不是这三个且最后一条 assistant 文本末 300 字以问号结尾或含「请确认 / 等你 / 需要你 / 要不要 / 是否继续 / 你来决定 / 请选择 / 回复我」就 block。`stop_hook_active` 时同一规则最多再拦 1 次（计数按 transcript 哈希存 `os.tmpdir()`），之后放行；找不到 `run.json` 只跑规则 B；逃生口 `UNATTENDED_STOP_GUARD_DISABLE=1`，异常 fail open。已知局限：`close-self.sh --dry-run` 也算已自关。

40. **2026-11-26：守护进程 spec-keeper 接管死掉、卡住和额度停车的 Run（`scripts/keeper.sh`，服务在 `~/ops/services/spec-keeper/`，launchd 每 10 分钟）。** 证据：11-20 以来无人值守 Run 等人约 32.5 小时，其中约 22 小时是会话/worker 卡死或断线没人叫醒、以及 429/额度停车要人手动恢复；总控 find-next 会话自己也会死、会被 `/clear`。决定：用确定性脚本而不是再开一个 LLM 会话盯着；只处理启动状态 `auto_land` 不为 false 的仓库；动作只有四种：quota/transient 停车过了可恢复时间 → `launch-wave --only <n> --apply`；claim interrupted 且无新报告 → 同样恢复；claim active、phase 不是 done/parked、transcript（含 `<session>/subagents/` 下的子代理 transcript）与 Run 目录、worker 运行目录都超过 45 分钟没写入 → 先在会话终端发一行「继续…」，再过 45 分钟仍无写入才关终端、`claim.sh release --force`、恢复；decision/error/other 停车每份报告只通知一次。同一规格 24 小时最多自动恢复 3 次，「launch-wave 退出 0 且之后 claim 为 active」才计数（launch-wave 对不可启动的规格也退出 0）。缺 `run.json` 或 transcript 时一律跳过，宁可漏判不误杀；handoff 预留期内不做卡住处理。旧报告没有机器可读行时按关键词兜底（额度/429/quota/rate limit/resets → quota，其余 decision）。不写 GitHub、不 push、不删分支。暂停：`touch ~/ops/state/spec-keeper/paused`。

41. **2026-11-26：判断模型全局热切换（`scripts/judgment-model.sh`，ADR 0002）。** 证据：Opus 周额度用到 99%（`orca account list` 的 `rateLimits.claude.weekly.usedPercent`），要到周五 10:00 才重置，期间每次 Opus review 都会以退出码 3 停车。用户要一个全局开关：Opus 没额度时把所有用 Opus 的地方切到 glm-5.4，已经在执行的会话也要跟着切。决定：开关是 `~/.claude/state/judgment-model`，按角色记（`grill=`、`review=` 各一行模型、一行 `until=<epoch 秒>`，到期自动回 opus）。两个角色：`grill` 管 Design session 讨论，`review` 管全部 Opus review。用户要求一条命令同时定两样，所以写法是 `judgment-model.sh grill=opus review=glm-5.4 [--until <ISO 8601> | --for <时长>]`：不带角色的模型表示两个都设，没提到的角色保持原样（模型和到期时间都不动）。`opus-review.sh` 报 `--print review`，`design-session.sh` 报 `--print grill`。给用户敲的入口是 `/judgment-model`（薄包装技能 `judgment-model/`，软链到 `~/.claude/skills/`，和 grill-feature 一样）：它只运行脚本并转述那一行状态；设了 `disable-model-invocation`，只能由用户敲，否则会话看到额度错误就可能自己调用它把模型降了。读开关放在两个出口脚本里：`opus-review.sh` 和 `design-session.sh` 每次被调用时读一次，所以运行中的 flash 会话不用重开、SKILL.md 里的旧指令也不用变，下一次审查就是新模型。仍然是用户手动切，退出码 3 不自动降级，ADR 0001 的「不降级」对会话不变。glm-5.4 的走法：审查清掉会话继承的 GLM/flash 环境变量后经 `ISS_GLM_LAUNCHER`（默认 `claude-glm`）执行 `--model opus`（启动器里映射到 glm-5.4），工具白名单、`--permission-prompts none`、超时和退出码都不变；Design session 用 `orca terminal create --worktree path:<仓库根>` 起终端，敲入 `claude-glm --dangerously-skip-permissions "$(cat <运行目录>/prompt.txt)"`（提示词太长，不能直接敲进终端），界面 mock 改由它自己做，因为 claude-glm 的系统提示词不让派 worker。踩的坑：Orca 终端里敲入的命令结束后 shell 还活着，`orca terminal wait --for exit` 察觉不到 `claude-glm` 退出（实测 `sleep 4` 结束后等满 30 秒才超时），所以启动命令末尾加 `echo $? > <运行目录>/exit-code`，等待循环轮询这个文件来判断会话已结束，`--attach` 同样认它。切换后 findings 首行加 `判断模型：glm-5.4…`，stderr 也报告；opus 路径逐字不变。测试：`scripts/test-judgment-model.sh`，外加 `test-opus-review.sh`、`test-design-session.sh` 各一组切换用例（测试里用 `ISS_JUDGMENT_MODEL_FILE` 指到临时文件，免得本机真实的开关影响测试）。（2026-11-27 注：Design session 这一半已被第 44 条取代——讨论阶段改读阶段路由表、经「开终端跑启动器 + `worker-start --terminal` 收编」启动，`ISS_GLM_LAUNCHER` 和按模型名分支的 mock 条款都不再有了。）
42. **2026-11-27：Worker model 全局热切换（`scripts/worker-model.sh`，ADR 0003）。** 证据：判断模型已有 `/judgment-model`（第 41 条），Worker model 没有对等开关，由「哪条路径在干活」决定：`--impl codex` 的 Run 照 SKILL.md 显式传 `--model glm-5.4`（第 27 条的坑：wrapper 永远显式传 `-m`，`config.toml` 的 `model` 对 worker 无效），只改脚本默认值对正在跑的 Run 无效；find-next 的 codex worker 和全局分工的日常派活用脚本默认值；会话内子代理的型号在启动器 `exec` 时钉死，任何状态文件都切不动。用户定：独立开关（不并入 `judgment-model.sh`，那是「代替 Opus」的判断模型，这是被代替的一方），状态文件 `~/.claude/state/worker-model`（`worker=<model>`、`worker.until=<epoch 秒>`），允许值 `glm-5.4`（默认）`glm-5.3` `glm-5.3-flash`，`--until` / `--for` 到期回默认，`use glm-5.4` 即复位，默认型号配到期退出 64，不带 `use` 的裸型号退出 64。优先级：开关（非默认）> 显式 `--model` > 默认——`SKILL.md` 让会话照抄 `--model glm-5.4`，已开着的 Run 只有让开关压过它才切得动。覆盖范围一刀切：所有 `codex-worker.sh` 调用（实现角色、find-next 的调研/决策/起草 worker、日常派活），wrapper 层分不开「编码」与「阅读」。v1 只管 codex 路径：`pi-worker.sh`、`launch-wave.sh`、`--agent-model`、keeper、run-phase、hooks、doctor 都不动，agent 后端作为否决项写进 ADR。实现：`codex-worker.sh` 的 `MODEL` 默认改空，只在 fresh-run 分支（Resume 的 `else` 分支内、`write_state` 之前）调 `resolve_worker_model` 读开关；开关非默认时每次派发在 stderr 打一行并追加到运行目录的 `stderr.log`（型号、被覆盖的 `--model`、到期、是否在 worker 目录、复位命令 `/worker-model use glm-5.4`），`status.json.model` / `resume.json.model` 如实记最终型号；Resume 不读不打印，沿用第一段的模型。默认值只在 `worker-model.sh` 定义一次（`DEFAULT_MODEL`），wrapper 和 selftest 用 `--print default` 向它要，下次升级只改这一处。`--print`、`--print default` 输出为空时 wrapper 退出 64，显式传空 `--model ""` 且开关为默认时同样退出 64（绝不带空 `-m` 启动 codex）；这个防御分支没有可测手段（要一个坏掉的开关脚本），不加测试钩子。`use` 对不在 worker 目录（`model_catalog_json`，按 wrapper 的顺序解析 worker home：`CODEX_WORKER_HOME` → `~/.codex-worker` → `${CODEX_HOME:-$HOME/.codex}`）的型号只在 stderr 警告（先跑 `selftest-codex.sh --only L1 --model <型号>`，补 `~/.codex/models.json` 条目，重跑 `setup-worker-home.sh`），不拦截；派发时也复查一次目录，把「不在 worker 目录，L1 未验」并进同一行 stderr（`--for 2d` 的开关两天后让每个派发失败时，stderr 里否则只有型号）。文档：`SKILL.md` 的 `CODEX_MODEL` 删除，派发模板和 step 0 预检都不再传 `--model`，预检失败和 worker 失败的停车/重派都要点名开关当前值、`status.json.model` 与复位命令；落地报告、停车报告（`### 现状` 下）和最终报告在任一开关非默认时同时写两个开关的状态（Worker model 行取各 worker `status.json.model` 的去重集合，agent 后端和没做 review 的 Run 写「不适用」）。`templates/global-claude-md.md`（及英文版）加一句并升 v2，doctor 对本机 v1 规则文件报 WARN，提醒同步。selftest 三规则（findings D2）：显式 `--model` → 隔离开关（`ISS_WORKER_MODEL_FILE` 指向不存在的路径），测的确实是它，人跑 `--only L1 --model glm-5.3-flash` 才测得到 flash；不给 `--model` → 取开关 `--print`、不隔离，step 0 预检测的才是 worker 实际用的型号；V1/V2/V3 一律隔离，只有 V1 的开关用例逐次用 `env ISS_WORKER_MODEL_FILE=<临时文件>` 覆盖。`test-locks.sh` 也跑真 wrapper（不带 `--model`），同样隔离。入口 `/worker-model`（薄技能 `worker-model/`，软链到 `~/.claude/skills/`，train3060 不装——那边不调 `codex-worker.sh`，装了只会显示一个什么都不影响的状态）。`disable-model-invocation` 与 ADR 0002 一样是软约束：挡的是 Skill 工具，会话仍可经 Bash 跑脚本，`hooks/` 没有相关拦截。两个开关同时非默认时无人值守 Run 照常自动落地（用户定案，不停车、不硬拦），代价与理由见 ADR 0003。测试：`scripts/test-worker-model.sh`，`selftest-codex.sh --only V1` 的开关用例（覆盖优先级、到期回默认、坏文件回默认、复位后 `--model` 重新生效、Resume 不换模型、规则 1/2/3）。（已被阶段路由表取代，2026-11-28，规格 #25）
43. **2026-11-27：grill-feature / grill-map 收到 handoff 后自动接 find-next 推进模式，不再由主会话执行待办（规格 #35）。** 起因：Design session 交接后还要用户手动推进 find-next；两份薄技能的第 5 步让主会话逐条执行 handoff 待办、再手跑 `launch-wave --only`，等于把 find-next 的扫描、起草、发布、启动第 1 波和总控在技能里又写了一遍。决定：第 5 步只写「交接到 find-next」——先查 `lock.sh status find-next-supervise --scope repo`，打印 `held` 就说明那个会话已在总控并停下（沿用第 29 条的互斥），`free` / `stale` 就调 `find-next` 技能的推进模式（默认、不带参数，不带 `--suggest` / `--list` / `--watch`），之后扫描、起草、发布、启动第 1 波和总控都由 find-next 自己做，技能正文不复制它的步骤；主会话不再执行 handoff 待办、不再手跑 launch-wave、不再直接调 implement-spec-split。「先到这」的判定做成机器可读，不让 flash 读文件猜：map 的 prompt 要求提前交接时 handoff.md 首行原样写 `提前交接：先到这`，`design-session.sh` 收到 handoff 时核对首行（容忍 Markdown 标题或列表符号、句末标点、半角冒号；标记不在首行不算），命中就在 stderr 打 `design-session: 提前交接：handoff.md 首行是「提前交接：先到这」`；grill-map 看到这行不接 find-next，只转述 handoff 里的地图状态和下一步。handoff 说提前结束但脚本没报（早于本约定开的会话，`--attach` 续等时遇到）按「不接」处理并告诉用户——漏判只会多问用户一句，不会违背「先到这」去启动 find-next。测试：`scripts/test-design-session.sh`（假 orca 用 `DESIGN_TEST_HANDOFF_FILE` 指定 handoff 内容）。
44. **2026-11-27：Design session 按讨论路由经「开终端跑启动器 + `worker-start --terminal` 收编」启动（规格 #34，ADR 0004）。** 起因：讨论阶段走 Orca 内置的 `claude` 槽位（`agent launch`），模型和思考强度都传不进去，只能靠判断模型开关在 opus 和 glm-5.4 之间二选一。决定：`design-session.sh` 每次启动读一次「讨论」路由（`stage-route.sh --launch design interactive` 给启动器和 `--model`、`--effort`，`--print design profile|model|effort` 给报告用；读不到就以用法错误退出 64，不带着空模型开会话；`--attach` 不读路由，继续等它拿到的那个会话，所以改路由只影响下一次新开的 Design session）。Orca 调用全部经 `lib-orca.sh`（为它补了 `orca_orchestration_run_create`、`orca_orchestration_worker_start`、`orca_terminal_switch`、`orca_terminal_wait`，`orca_terminal_create` 加了可选的 `--focus`；`ISS_ORCA` 不再由这个脚本读）：`run-create` → `terminal create --focus --command "<启动器> --dangerously-skip-permissions --model … --effort …; echo $? > <运行目录>/exit-code"` → `worker-start --run <id> --terminal <handle> --spec-file <运行目录>/prompt.txt --timeout-ms 180000`；`agent launch`、`agent show` 删除，prompt 不再经命令行传，而是作为 Task 由 `worker-start --spec-file` 注入。Orca 的 worker 前言排在 Task 前面，首行的斜杠命令不再由 CLI 展开（`docs/orca-smoke-2026-11-27.md` 第二轮 G 项），所以 prompt 改为让会话用 Skill 工具加载上游技能；上报沿用前言给的完整 `worker_done` 命令，必须带 `--task-id`、`--report-path` 指向 handoff.md（同一记录 B 节踩过缺 `--task-id` 被拒收），不再写旧的 `send --subject`。mock 条款按路由的档案分支：`claude` 档案交给 worker 出页面，其他档案自己做。等待期间不循环调 Orca：整个超时只起一次后台 `terminal wait --for exit`，每轮等待是一次阻塞的 `check --run --take --timeout-ms`，会话提前结束靠启动命令写出的退出码文件和这一次 wait（`agent show` 轮询删掉）。stderr 第一行报本次路由 `design-session: 本次讨论路由：讨论（design）：<档案> / <模型> / <思考强度>`，两份薄技能第 4 步照此转述、第 7 步由 `/judgment-model grill=glm-5.4` 改为 `/grill-router use design=claude-glm/glm-5.4/high`，description 不再写「官方订阅上的 Design session」。踩的坑：`--launch` 对 GLM 档案输出 `glm-5.4[1m]`，`[1m]` 在 Orca 终端的 zsh 里是 glob，裸拼进 `--command` 会让整条命令不执行，所以启动命令的每个参数都经 `printf %q` 引用；Orca 对收编的外部终端不记模型（Dispatch 的 `launch.effective.model` 为 null），模型只能从路由行和 TUI 的 `/status` 核对。真机验证（收编后上游技能能否经 Skill 工具加载、`worker_done` 是否被接受、用户是否仍被切到新标签、Orca 会不会自己关掉收编的终端）归规格 #25 的人工冒烟票，本票只用假 orca。测试：`scripts/test-design-session.sh`（路由表是真的 `stage-route.sh` 读测试自己的 `ISS_STAGE_ROUTE_FILE`；缺启动器、读表失败这两条真表造不出来，经 `DESIGN_SESSION_STAGE_ROUTE` 换成假表脚本）、`scripts/test-lib-orca.sh`。（2026-11-28 注：官方 `claude` 档案的启动命令不再带 `--dangerously-skip-permissions`，TUI 照常弹权限确认，to-spec / commit / push 多几次确认；`claude-glm`、`claude-flash` 照旧带。用户拍板，规格 #25 审查「需要人取舍」第 3 项选 B。）
45. **2026-11-28：拆票时识别共享计数器票并串行——三个起草模板加同一条规则，find-next 审稿项与 `--apart` 判断各加半句；硬保证三点（`shared-counter` 标签、前沿一次只放行一张、在飞规格算 `--apart` 冲突）追加在本条末尾（规格 #62，承接 #24 的 B 方向；硬保证由 #76、#77 实现）。** 起因：版本号、CHANGELOG、迁移序号这类共享计数器（GLOSSARY.md）一处存在、每次递增，两张执行票各在自己的 worktree 里 bump 它，文件层面不重叠、git 看不见冲突，第二张合入就把重复的编号带进集成分支和 main（#24；社区实测 Victor Estival：#409 与 #621 都改成 0.23.0 并各加一条 CHANGELOG，第二个合入必须重新 bump）。本仓库此前没有一条规则让拆票的起草 worker 识别这类票：三个起草 Brief 模板的「阻塞关系的规则」只按「真正依赖」挂 `blocked_by`，find-next 的审稿项「阻塞合理」和第 10 步 `--apart` 判断都只看代码块与模块（#51）。#24 Resolution 选 C「先 B 后 A」：先做「拆票时识别 → 串行」（本条，软规则），后做「合入时 re-bump」（A 方向，#52 承接）；B 管不撞、A 管漏网，识别是拆票时的模型判断，漏判由 A 兜底，本规格不做合入时检测。决定（软规则三点）：① `find-next/templates/brief-spec-batch.md`、`brief-tickets-batch.md`、`brief-map-spec-batch.md` 的「阻塞关系的规则」加同一条措辞的规则——会改同一处计数器的执行票同规格内按顺序挂 `blocked_by` 链（写 `T<n>`，后一张等前一张，不是全部等第一张）；跨规格的挂不了（别组票号未定），在 `result.md` 末尾加一行「共享计数器：<本组票> ↔ <别组规格或票>：<计数器>」提示主会话判断 `--apart`，没有就不加；只给真正改同一处计数器的票挂，改不同计数器或不碰计数器的票不挂，拿不准按 Brief 里「未决的两种处理」处理、不要猜。② `find-next/SKILL.md` 第 5.4 步审稿项「阻塞合理」后加「碰同一计数器的票已串行」（#76 再补「并带 `shared-counter` 标签」半句，见下）。③ 第 10 步 `--apart` 判断由「改同一块代码」加「都改同一计数器」，依据在规格正文里的模块之外加起草 worker 在 `result.md` 里的共享计数器提示；「拿不准不传」不变。同批登记：GLOSSARY.md 加 Shared counter 词条（英文定义 + `_Avoid_`，初稿只写概念与软规则，标签语义那句由 #76 随硬保证①补入，见下）；ADR 0004「单独记票」加日期注指向 #62（B 方向）与 #52（A 方向）。链的放行依赖「合入即关票」：`frontier.sh` 与 `pipeline-status.sh --order` 都以阻塞票 `state === 'open'` 判阻塞，链上后一张要等前一张的票关闭才进前沿，而「票合入集成分支并通过测试后立即关闭」现在是会话的实际做法而不是写下来的规则——根 SKILL.md 只在第 9 步落地时关票，#36 的关闭评论「已实现并合入集成分支 spec-25（提交 71ad3d1，集成 tip bdd5882）…落地随规格 #25」可证（#36 的 closedAt 比 #25 早约 6 小时）；把它写进 `docs/agents/issue-tracker.md` 与给 #45 留言由 #76 和清单 `handoffs` 承担，根 SKILL.md 不改。证据：#24 Resolution；上轮 findings M4「三个模板才是起草 worker 读的规则」（`make-batch-briefs.sh` 里没有阻塞规则，规则住在模板里，所以改模板而不是改脚本）。测试：`find-next/scripts/test-make-batch-briefs.sh` 在已渲染的 spec 组、只拆票组、收口地图组三种 Brief 各加一条 `expect_has` 断言规则句子（96 → 99 用例，原有用例不变）；另用 `make-batch-briefs.sh` 往临时运行目录生成 Brief 人工核对规则可见、变量替换正常。提示词文本不做单元测试。硬保证三点（#76、#77 追加，2026-11-28；规格 #62「硬保证（已采纳推荐：落最小版）」）：① **标记 = 专用标签 `shared-counter`，不加清单字段。** `frontier.sh` 只读 `pipeline-status.sh --graph`，图里的票级标志（`human`、`shelved`）都来自 GitHub 上的标签或正文，清单只在运行目录里存活，所以标记落在标签上：起草 worker 经清单票级现有的 `labels` 写出（`["ready-for-agent", "shared-counter"]`——`publish-batch.sh` 的 `labelList` 对 `labels` 是整体替换不是合并，省掉 `ready-for-agent` 票就不进前沿），清单格式与发布脚本不改；`--graph` 票级数据加布尔 `shared_counter`，`ticketOf` 沿用 `human` 的写法（`child.sharedCounter === true || hasLabel(child, 'shared-counter')`，`ticketRecord` 预算，覆盖开放规格、落地规格、搁置规格、legacy 父 issue 四条路径），字段名沿用图里 `has_tickets`/`tickets_total` 的 snake_case。标签要先在仓库里存在（与五个 triage 标签同样的前提），本仓库已建；其他登记仓库第一次发布带 `shared-counter` 的草稿前要先建（REST 建票接口对不存在的标签是静默丢弃还是报错未核实）。标签约定登记在 `docs/agents/issue-tracker.md`「Conventions」（谁打、谁读、效果）。随标签一起修订的软规则文字：三个模板的规则句在 `blocked_by` 链之后补「并给这些票在清单 `labels` 里写上 `shared-counter`（写成 `"labels": ["ready-for-agent", "shared-counter"]`，省略会丢掉默认的 `ready-for-agent`）：同规格里带这个标签的票，前沿一次只放行一张，链漏挂了也兜得住」；`find-next/SKILL.md` 第 5.4 步审稿项补成「碰同一计数器的票已串行并带 `shared-counter` 标签」；GLOSSARY 的 Shared counter 词条补标签语义（起草经清单 `labels` 打 `shared-counter`，`--graph` 报成 `shared_counter`，前沿据此一次放一张），Frontier 词条补「带 `shared-counter` 标签的票一次只放行编号最小的一张，其余等它」（后者是②的词条）。② **`frontier.sh` 同标记最多放行一张。** 通过其余前沿条件（无开放阻塞、未搁置、非人工）且带标记的票里只有编号最小的一张进前沿，其余列在 `# blocked` 段、原因写「（等共享计数器：#m）」（措辞沿用「（阻塞：#20）」），不新增输出段落，根 SKILL.md 不改；带标记但有开放阻塞的票照旧列在 `# blocked`（阻塞原因）、不占名额，带 `ready-for-human` 或搁置的同样不占。没有带标记的票时输出逐字不变（`test-frontier.sh` 用金标准 `cmp` 钉住）。它依赖「合入即关票」——票合入集成分支并通过测试后立即关闭——这是会话的实际做法而不是写下来的规则（根 SKILL.md 只在第 9 步落地时关票，#36 的关闭评论可证），#76 把它写进 `docs/agents/issue-tracker.md` 的标签约定，并经清单 `handoffs` 给 #45 留言在重写第 5 步时写明；#45 是否采纳不受本规格控制。已知限制（审查「需要人取舍」第 1 项选 A，自动拍板）：`frontier.sh` 无状态，只按「当前合格的带标记票里编号最小」放行；编号最小的带标记票若在另一张已在飞期间解除阻塞、取消搁置或转回非人工，下一次重算会改放它、把已在飞的那张列成「等共享计数器」，两张计数器票可能同时在飞。主机制仍是 `blocked_by` 链，这种漏网由 A 方向（#52）合入时 re-bump 兜底，`frontier.sh` 不为此加条件（加了会让最低号票被外部挡住时整组停摆，与「带阻塞不占名额」相抵）。③ **开发顺序把在飞的规格算进 `--apart` 冲突。** `--apart A:B` 里一侧是进行中（running）或先恢复（interrupted——它和进行中一样占容量，恢复后与新波并发）的规格时，另一侧不进新波、留在「之后」，注记点名避开的规格；`--next-wave` 经同一个开发顺序复用启动状态里的 `--apart` 对，自然得到同样的保证，launch-wave 不改（#77 实现，测试见「自测·流水线状态」）。证据：上轮 findings D3（标签还是清单字段，按 `frontier.sh` 读哪种数据定）、M2（`--apart` 只保证不在同一波启动、不保证不并发）；本轮 findings D9（「合入即关票」不是写下来的规则）、取舍 10A（合入即关票一句写进跟踪器约定而不是根 SKILL.md，自动拍板可推翻）。测试：`scripts/test-frontier.sh` 用现有假 `gh` 夹具加四个场景（两张带标记无阻塞票只放行编号小的、其余点名等谁；小的关闭后放行大的；带标记但有开放阻塞仍在 `# blocked` 且不占名额；带标记且 `ready-for-human` 或搁置不占名额）与无标记票逐字金标准（25 → 45 用例，原有用例不变）；`scripts/test-pipeline-status.sh` 加独立夹具断言 `--graph` 四条路径上的 `shared_counter` 真假（199 → 202 用例，原有用例不变）；`find-next/scripts/test-make-batch-briefs.sh` 另加三条断言钉住标签子句（99 → 102 用例；#75 的三条规则句断言原样保留）。

## flash 模式设计要点（2026-11-20 规格定稿，ADR 0001）

三档分工：flash 主会话/规格会话（`claude-flash` = glm-5.3-flash，只执行与转述）、glm-5.4 子代理（全部源码修改与大量阅读）、官方 Opus（一切结论性判断）。要点：

- **白名单默认禁止**（不是黑名单）：flash 只做白名单内的事，漏列的情况会上交而不是被当成允许。评估过"flash 自己做小判断"和"黑名单"，都否了——flash 过度自信的小错会在后续波次放大，黑名单漏列即放行。
- **一行源码都不写**：delegate-guard flash 模式对源码写入阈值 0、`allow-direct-edit` 不生效，靠 hook 硬拦而不是靠 flash 自觉。
- **判断一律出会话**：GLM 会话里 "opus" 子代理是假的 Opus（见第 24 条），所以审核、诊断、冲突复审全走 `scripts/opus-review.sh`。Opus 不可用（退出码非 0）就停车，不降级、不自审、不自动重试。
- **每个阶段的路由由用户全局热切换（2026-11-27，ADR 0004，取代原先的判断模型开关和 Worker model 开关，即 ADR 0002、0003）**：一张阶段路由表（`scripts/stage-route.sh`，`~/.claude/state/stage-route`）给编排、讨论、调研起草、实现、审查、诊断六个阶段各记一项（启动器档案 / 模型 / 思考强度，可带到期），用户只用 `/grill-router` 一条命令查看和设置；编排锁定 flash，没冒烟测试过的（档案、模型）组合拒绝，审查与实现同模型只警告一次不拦。派发脚本每次派发时读自己那一行（`opus-review.sh` 读审查或诊断、`design-session.sh` 读讨论、`codex-worker.sh` 带 `--read-only` 读调研起草否则读实现），所以运行中的会话下一次派发才生效、不中途切换；会话自己仍然不许降级（`/grill-router` 是 `disable-model-invocation`）。切换后 stderr 和 findings 首行写明本次路由，落地报告和最终报告要注明。
- **Design session 承担讨论**：`/grill-feature`、`/grill-map` 由 Orca 按讨论路由开 Design session（`/grill-router`，默认官方 Opus；启动方式见设计要点第 44 条），用户直接谈；讨论完当场 to-spec/to-tickets/commit/push（文档推送预授权），写 `handoff.md` 通知 flash。flash 在等待期间阻塞、不轮询不耗 token。
- **结论必须带出处**：flash 汇报的每个结论注明支撑它的 findings/result 文件路径，拿不出出处的结论不许说。防止 flash 把自己当判断者。
- **拿不准默认上交 Opus**，不自己在两个上交对象之间挑。
- **停车条件收紧**（2026-11-25 起无人值守时只对 Opus 标「可自动采纳：否」或「推荐：无」的条目停车，见第 29 条）：flash 只对 Opus 标注「需要人取舍」的条目停车，不许自创取舍；但 Opus 脚本错误照常硬停车。「需要人取舍」的每一条都原样转给用户，flash 不许以「规格已写明」为由自己裁掉（2026-11-21 human-res-cost 规格 #49 实测：5 条里 flash 自判了 2 条）。
- **实现只能走 `/implement-spec-split`（2026-11-21 加）**：同一次实测里，flash 读完 Design session 的 handoff（Opus 写了「单 worker 串行即可」）后没调技能，自己建 worktree、手写 brief、直接跑 `codex-worker.sh`，认领、阶段标记、agent 后端、落地锁全被跳过。修法三层：grill-feature/grill-map 第 5 步规定实现待办必须走技能；design-session.sh 要求 handoff 只写「实现规格 #N」、不写执行方式；`codex-worker.sh` / `pi-worker.sh` 在 `FLASH_ORCHESTRATOR=1` 时拒跑，只有显式 `--impl codex|pi` 的 Run 带 `WORKER_ALLOW_FLASH=1` 放行——措辞拦不住 flash，和「一行源码不写」一样靠硬拦。
- **Opus 审查要能读 issue（2026-11-21 修）**：`opus-review.sh` 用 `--permission-prompts none`，原先白名单只有 git，`gh issue view` 被自动拒绝，Spec 轴只能拿 CONTEXT.md 和 commit message 凑数，等于没对照规格。现放行 `gh issue view` / `gh pr view` / `gh pr diff`（只读）。
- **「需要人取舍」必须带推荐（2026-11-21 修）**：flash 不许自补推荐理由，推荐只能来自 Opus；原先三类提示词只要求把取舍放进该节，Opus 便只写中性权衡，find-next 问题轮里 a–c 全无「建议」行（ssh-manager-mcp #348 散票分流实测）。现要求每条列选项与代价并写 `推荐：<选项> — <理由>`，实在无法推荐写 `推荐：无 — <原因>`；find-next 把它照抄为「建议」行。
- **flash 提问框乱码（2026-11-21 修）**：glm-5.3-flash 调 AskUserQuestion 时常在中英文交界、标点前夹回车符 `\r`（一个会话 4 次里 3 次），终端把提问框渲染成乱码，普通回复和 Bash 不受影响。措辞拦不住，改用 `hooks/ask-sanitize.js`（PreToolUse，`ask` + `updatedInput` 删掉 `\r` 后照常弹框，已在真实会话里验证不会多弹确认），注册在 flash 专用 settings。
- **交接后关闭 Design session（2026-11-21）**：Opus Design session 交出 handoff 后原本一直挂着，占 Orca 槽位，用户回去说话还会继续花 Opus 额度。现在 `design-session.sh` 收到 handoff 后等 3 秒（`ISS_DESIGN_CLOSE_DELAY`），用 `orca terminal close --terminal <handle> --tab` 关掉它的标签；关闭失败只提示不报错，`ISS_DESIGN_KEEP_SESSION=1` 保留。只处理 terminal 形态（有 handle）的会话，chat 形态没有 handle，保持原样。
- **Design session 自动切换焦点（2026-11-21）**：`orca agent launch` 默认开新标签但不切焦点，用户得自己找过去。现在 launch 加 `--focus` 直接切到 Design session；收到 handoff 后先用 `orca terminal switch --terminal $ORCA_TERMINAL_HANDLE` 切回发起等待的主会话终端，再关 Design 标签。切回失败只提示不报错；不在 Orca 终端里跑（没有 `ORCA_TERMINAL_HANDLE`）就不切。
- **界面 mock 在 Design session 里、to-spec 之前做（2026-11-21）**：选哪个 mock 本身是设计决定，放到 flash 去做的话，规格写的就是猜测；而且 flash 不做判断，Design session 交接后又会被关掉，没地方接着讨论。真正费 Opus 额度的是"监工"（写 Brief、读报告、看截图），不在会话放在哪，所以把监工拿掉：Opus 只写方向卡，用 `templates/brief-mock.md` 交给一个 codex worker 出单文件页面，worker 用 Playwright DOM 断言自检（非空、非源码、无横向溢出、关键交互点得通）并写 `mock/manifest.json`；Opus 不看截图和 HTML，按 manifest 的路径调一次 `mockit_submit`（mockit 没有 CLI 提交，只能走 MCP，但接受本地路径），由用户在手机上拍板。不加视觉模型自检：GLM-5.3 不支持多模态，智谱视觉 MCP（`@z_ai/mcp-server`）也没进 worker home；评委只有用户，视觉自检替用户省不了事，出现"坏页面送审"再接入。等用户审页面可能超过 2 小时，而后台 Bash 最多跑 7200000ms，所以 design-session.sh 超时后用 `--attach <run-dir>` 续等同一会话，技能遇退出码 5 自动续等。
- **子代理放行与进度标签（2026-11-21）**：ssh-manager-mcp spec-349 的 flash 编排会话派出 glm 子代理后，子代理继承 `FLASH_ORCHESTRATOR=1`，源码写入被 delegate-guard 全拦；三个子代理分别另起 headless `claude-glm`、改走 `orca orchestration worker-start`、用 `env -u` 绕过，导致正在开发的会话大多在 Orca 里不可见。现在 hook 在 flash payload 带非空 `agent_id` 时放行子代理源码写入、主会话仍全拦，并要求实现角色被拦时停下报告、禁止绕路；`ticket-watch.sh` 另开只读 Orca 进度标签显示 worktree、提交和文件状态。不做 `--impl orca` 后端：那会改派发、等待和恢复链路，测试面大，需要时再单独做。2026-11-25 补：开标签、解析 `orca terminal create --json`、记录 handle 改由 `scripts/progress-tab.sh` 完成，模型只调用一条命令（spec-22 把请求 `id` 当成 handle、把 `<TAB>` 写成字面量，第 10 步一个标签都没关掉）；一张票的 merger 合并并通过测试后立即关掉它的实现标签和合并标签，fix、merge main 标签在角色结束时关，不再等到第 10 步（一个规格跑一天能积 10 个以上标签）。
- **回退优先**：改造前两仓库打 `pre-flash-orchestrator` tag、全局配置快照 + ROLLBACK.md 在 `~/.claude/backups/pre-flash-orchestrator-20261120/`；新行为只活在 flash 会话里，官方会话与 claude-glm 并存。改 flash 相关行为时先想回退路径还在不在。
- **Orca 调用收敛到公共库（2026-11-27，规格 #25）**：Orca 的 Experimental API 调用原先散在各脚本里，替换可执行文件的变量有 `ISS_ORCA`、`KEEPER_ORCA`、`PIPELINE_STATUS_ORCA`，board 和 close-self 干脆写死 `orca`，测试各伪造一处；实测还踩到两个坑：`orchestration` 不显式带 `--run` 时从终端环境继承 Run，消息投错会话；终端 handle 在一次运行里复用早先拿到的值，漂移后打错目标。现在 `scripts/lib-orca.sh` 是唯一出口，分 worktree、terminal、orchestration 三组函数，`orca_run` 是全仓库唯一启动 Orca 的行。四条规则都落在签名或默认值上，不靠调用方自觉：全仓库只剩 `ISS_ORCA` 一个替换变量，且只由 `orca_exe` 读；orchestration 函数第一个参数就是 Run id，为空、是选项、缺席都退出 64，参数里再带一个 `--run` 也拒绝；库里不存 handle，`orca_terminal_by_pane` 每次调用都重新向 Orca 要终端列表（同一进程连调两次会问 Orca 两次）；`orca_orchestration_check` 默认 `--peek`，只有协调者消费自己 Run 的邮件（design session 等 handoff）才传 `--take`，等待只有 `--timeout-ms <n>` 展开成的一次 `--wait --timeout-ms <n>`，裸 `--wait`（可能永久阻塞）和任何轮询都不提供。`repo list` 是只读的仓库登记查询、是 worktree 的上层，归 worktree 组。迁移分票做：先 close-self、keeper（本条），launch-wave、pipeline-status、board 在 #31，design-session 在 #34；`progress-tab.sh` 不迁，换底座规格 #26 退役它。keeper 第二轮关终端原是这里唯一的例外（复用上一轮写进 state 文件的 handle），#55 起消除：nudge 记录只存 pane（`tabId`/`leafId`），关终端前经 `orca_terminal_by_pane` 重新向 Orca 要当前 handle；pane 不在 Orca 列表里就按「终端已关」处理（不关、照常释放 claim 并恢复），Orca 答不上来记 ERROR 而不是当作终端已关。测试是 `scripts/test-lib-orca.sh`；`test-keeper.sh` 把假 orca 挪到 PATH 之外、只经 `ISS_ORCA` 指定，并在 PATH 上放一个拒绝一切调用的 `orca`——本机 PATH 上有真 orca，迁移前这个测试悄悄打到了真 Orca 的只读查询，护栏让「不走公共库」立刻失败。

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
    - Orca 启动 Claude 时带 `--dangerously-skip-permissions`，自动开的会话不会卡在权限提示上（2026-11-24 注：OpenClaude 槽位不带，flash 会话的 bypass 由 `claude-flash` 启动器自己补，见 docs/setup.md 阶段 4）；会话仍会在合入前确认 push、GLM 出错时停下等人。

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
19. **2026-11-24：Design session 首行用斜杠命令加载上游技能。** 起因：proxy-hub 的 `/grill-map` Design session 讨论完话题后停下，让用户手敲 `/mattpocock-skills:wayfinder`，因为上游 wayfinder 设了 `disable-model-invocation`，Skill 工具调不起来；grill-with-docs 同样设了这个标记。决定：`design-session.sh` 的启动 prompt 首行写 `/$UPSTREAM`，`orca agent launch --prompt` 送进去的是用户输入，斜杠命令能加载这类技能，后面的话题和交接约定成为技能参数（和 launch-wave 发 `/implement-spec-split <n>` 同一机制）。Git Bash 会把开头的 `/` 改写成路径，所以同样设 `MSYS2_ARG_CONV_EXCL` 豁免 `/mattpocock-skills`。
20. **2026-11-27：`S<k>=spec:<n>` 支持没有「实现票：」行的已有规格。** 起因：Design session 只发规格不拆票时（#25、#26），`make-batch-briefs.sh` 遇到正文没有「实现票：」行的规格直接 `die`（#27），而扫描器和 SKILL.md 都把「没有子票的规格」算「有规格、未拆票」，文档承诺覆盖、脚本却不支持。决定：
    - 没有「实现票：」行时再解析正文的「地图：#N」/「来源地图：#N」行（正则与 `pipeline-status.sh` 的 `bodyMapReferences` 一致），解析到就把那张地图当本组的地图（取标题、走既有地图校验，Brief 保留 `地图 #N「标题」` 和 `gh issue view N` 指引）；两行都没有才是手写规格：不取地图，并在 stderr 提示一行，不硬停（第 29 条：停车只留给真要人决定的事）。子票数不为 0 的仍拒绝。
    - Brief 里随规格形态变化的三句（身份句、实现票行、地图行）由脚本整句注入（`@@SPEC_ORIGIN@@`、`@@TICKETS_LINE@@`、`@@MAP_LINE@@`），不让模板用空变量拼句：第一版让模板同时兼顾两种形态，手写规格渲染出「它覆盖的地图实现票 已在…列出」这种假句，审查打回。
21. **2026-11-27：起草模板里的「本票由 Opus 执行」只留给真的不能交给实现者的票。** 起因：flash 轮次审查发现三张真机票靠审查 M1 才在发布前拦下——模板只说「用到 ssh-manager 的写『本票由 Opus 执行』」，没说标签，发布后就是 `ready-for-agent` 的人工票（#27 评论 B-1）。第一版修法让这类票标 `ready-for-human`，但触发条件仍是「用到 ssh-manager MCP、真机或远程服务器」，与第 36 条运维票规则相反（那类票本该派给实现者）。决定：三份批量模板的触发条件收窄为「真的不能交给实现者的（需要用户本人的身份、凭据或物理动作）」才写「本票由 Opus 执行」，并在 manifest 该票写 `"labels": ["ready-for-human"]`；能由实现者经 ssh-manager 做的写成运维票（正文写明经 ssh-manager 执行 + `## 护栏`，模板给了最小护栏样例），保持 `ready-for-agent`。
22. **2026-11-27：Brief 卫生与环境约束。** 起因：#53——推进器 Brief 里写了「`research_things/` 下文件名含 `20261127_1354` 的调研文档」这个模糊路径，子代理找不到就对 `$HOME` 全盘 `find`，走进 SynologyDrive 挂载卡死 2h42m（命令里的 `-not -path` 只过滤输出、不剪枝），worker 交完结果后进程残留为孤儿。决定：
    - 主会话写 Brief 前先用系统索引（macOS 的 `mdfind`）或 `ls` 把仓库外文件核实到确切路径再写；定位不到就明写「未定位到，不作为依据」，不给模糊路径让 worker 全盘找（find-next/SKILL.md 推进模式导言）。
    - 10 份 Brief 模板各带同一节「环境约束（找文件与子进程）」：仓库外文件都是确切路径、不对 `$HOME` 或仓库之外做无边界 `find`（要搜用系统索引；非用 `find` 不可时对挂载点本身 `-prune`，`-not -path` 不剪枝）、结束前收割自己起的仍在跑的长子进程。文案不含作者机器的事实（`mdfind` 标了平台、云盘路径只是举例），`test-make-batch-briefs.sh` 断言 10 份逐字相同，防改一处漏九处。
    - 进程收尾只能落到模板层：`codex-worker.sh` 没有进程组管理，`kill_tree` 按 ppid 走树且只在 watchdog 路径调用，codex 正常退出不收割；agent 后端不经过它。根治要在 harness 层，不在本仓库。

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
- **批量 Brief 生成**：`bash find-next/scripts/test-make-batch-briefs.sh`。用假 `gh` 测变量替换、上游技能版本选择与参数校验，只拆票的已有规格三种形态（有「实现票：」行、只有「地图：」行、两行都没有的手写规格，含 stderr 提示与子票不为 0 仍拒绝），共享计数器规则（已渲染的 spec 组、只拆票组、收口地图组三种 Brief 各断言规则句「会改同一处计数器的执行票按顺序挂 `blocked_by` 链…」与「并给这些票在清单 `labels` 里写上 `shared-counter`」两句，共 6 条），以及 10 份 Brief 模板「环境约束」节逐字相同，`--force` 覆盖既有 Brief（占位 Brief 覆盖并写出后续组、重跑换组重写、无既有文件照常生成）。
- **流水线状态**：`bash scripts/test-pipeline-status.sh`。它用假 `gh` 和临时 git 仓库测独立规格、单票规格、原版父规格、旧父 issue 形状、缺规格分组、探索中的地图、分支接手、已合入的遗留分支、外部阻塞、`--order` 开发顺序（状态、排序、波次、`--apart`（同波错开；一侧在飞——进行中或先恢复——时另一侧不进新波、留在「之后」并注记「避开 #N」，对调顺序同样，两侧都不在飞逐字不变，`--json` 里在 `later` 不在 `wave1`）、循环依赖）、`ready-for-human` 执行票（`(人工)` 后缀、只剩人工票的规格不进「可以实现」/`--order`/波次、`--all` 提示「人工票待做」、`--graph` 的 `human`/`human_only`/`status: human`）、`shared-counter` 执行票（`--graph` 的 `shared_counter`：带标签为真、不带为假，开放规格、落地规格、搁置规格、legacy 父 issue 四条路径都测）和 gh 失败，不访问网络。假 `orca` 放在 PATH 之外、只经 `ISS_ORCA` 指给 pipeline-status（PATH 上另放一个拒绝一切调用的 `orca` 护栏）：孤儿认领默认读 `PIPELINE_STATUS_ORCA_TERMINALS_JSON` 指的 fixture 文件；不设时经公共库问 Orca，假 orca 收到的只有 `terminal list --json`，Orca 失败或输出不可解析都打印「（Orca 不可用，未判断）」，不带 `--all` 不问 Orca。
- **前沿计算**：`bash scripts/test-frontier.sh`。用假 `gh` 和临时夹具跑真实 `pipeline-status.sh --graph`，测未阻塞票、只有已关闭阻塞的票、被挡票及其阻塞票、`ready-for-human` 票、搁置票的分节输出，前沿行在前且升序，`shared-counter` 票一次只放行编号最小一张（其余列 `# blocked` 并点名在等哪张、小的关闭后放行大的、带开放阻塞或 `ready-for-human`/搁置的不占名额），没有带标记票时整份输出与金标准逐字一致，未知规格、pipeline-status 失败、`blocked_by` 查询失败都 fail closed（stdout 为空），以及参数错误，不访问网络。
- **unattended-stop-guard**：`node hooks/test-unattended-stop-guard.js`。临时 transcript + 临时 `ISS_STATE_DIR`/`TMPDIR`：非无人值守放行、done/waiting/parked 未自关 block、已自关放行、问句 block、非问句放行、找不到 `run.json` 只跑规则 B、`stop_hook_active` 循环上限、逃生口、坏 transcript fail open、6MB transcript 2 秒内判定，不访问网络。
- **spec-keeper**：`bash scripts/test-keeper.sh`。假 `gh`/`claim.sh`/`launch-wave.sh`/`lock.sh` 在 PATH 上，假 `orca` 放在 PATH 之外、只经 `ISS_ORCA` 指给 keeper（PATH 上另放一个拒绝一切调用的 `orca` 护栏，keeper 不走公共库就立刻失败）：quota 停车未到点不动、到点恢复；decision 只通知一次；24h 第 4 次改通知；interrupted 恢复；卡住第一轮发「继续」、第二轮关终端+释放+恢复，关之前按 pane 经 `orca_terminal_by_pane` 重新解析 handle，不复用上一轮写进 state 的（#55：覆盖 handle 漂移、终端已关且旧 handle 被别的终端拿走、Orca 答不上来、dry-run、只存 handle 的旧格式 nudge 记录、未到时间只等待）；有写入不动；旧报告关键词兜底；`--dry-run` 零写；非 auto_land 跳过；锁冲突、暂停、gh 失败都退出 0。
- **进度看板**：`bash scripts/test-board.sh`。假 `orca` 放在 PATH 之外、只经 `ISS_ORCA` 指给 board（PATH 上另放一个拒绝一切调用的 `orca` 护栏；假 orca 收到的只有 `repo list --json`），加假 pipeline-status、临时 git 仓库和临时 Run/Worker 目录测仓库登记、刷新节奏、关系图快照、认领状态、Run 阶段、Worker 异常、终端/网页输出、EPIPE、Board pruning 和帮助文本，不访问网络。
- **Run 阶段记录**：`bash scripts/test-run-phase.sh`。用临时 HOME/ISS_STATE_DIR 测各阶段写入、覆盖、省略字段、最新 Run 目录选择、状态目录覆盖、写失败只警告和参数校验。
- **票进度标签**：`bash scripts/test-ticket-watch.sh`。用临时 git 仓库测 `ticket-watch.sh --once` 的 worktree、分支、领先提交、脏文件、最近提交和外部 worker run dir 输出，worktree 清理后的零退出提示，以及缺失参数和非法 interval 的报错，不访问网络。
- **进度标签开关**：`bash scripts/test-progress-tab.sh`。用假 orca 测 `progress-tab.sh open` 只认 `result.terminal.handle` 且以 `term_` 开头、同标题不重复开、没有 `ORCA_WORKTREE_ID` 时什么都不做、`--command` 里带空格的路径转义；`close` 只关指定标题并删掉对应行；`close-all` 兼容字面量 `<TAB>`、跳过非 `term_` handle，并按标题和 worktree 兜底扫描（不关 `spec-<n> ✓`、`Claude Code`、其他 spec 号、其他 worktree、自己的 tabId）；`--dry-run` 只打印不执行 close，不调用真实 orca。
- **编排看门狗**：`bash scripts/test-run-watchdog.sh`。用临时 git 仓库和小间隔测 `run-watchdog.sh` 的卡死（STALLED/退出码 3）、后台持续提交判活到 max（ALIVE/退出码 2）、worktree 消失判结束（DONE/退出码 0）、多对象混合输出、worker run dir 进展计入指纹和参数错误（退出码 64），不访问网络。
- **delegate-guard**：`node hooks/test-delegate-guard.js`。测普通阈值、flash 源码拦截与子代理放行、Bash 各类源码写入形态、裸调 `codex exec` 在所有会话（含子代理、非 flash、`DELEGATE_GUARD_DISABLE=1`）被拦而 wrapper/非 exec 子命令/字符串与 heredoc 字样放行、`gofmt -w`/`goimports -w`/`go fmt` 放行、项目配置与例外开关，不访问网络。
- **unattended-ask-guard**：`node hooks/test-unattended-ask-guard.js`。用临时 transcript 测字符串和数组 content 的 `--auto-land` 拒绝、不带时放行、以最后一次调用为准、`--auto-landing` 不算、普通对话里提到不算、缺 `transcript_path`/文件不存在/坏 JSON 行 fail open、非 AskUserQuestion 放行、子代理 payload 同样判定、`UNATTENDED_ASK_GUARD_DISABLE=1` 放行，以及 6MB transcript 在 1 秒内判定，不访问网络。
- **land-push-guard**：`node hooks/test-land-push-guard.js`。用临时 bare origin、clone、伪造 transcript 和 `land.lock/owner.json`，测无锁时 `git push origin HEAD:main` / `git push origin main` / `git -C <dir> push origin HEAD:refs/heads/main` / `cd <dir> && git push` / `git push origin HEAD` / `git push <仓库路径>` / 带 `2>&1` 或重定向的 push 被 deny，锁属于别的 pid 被 deny，锁属于本会话放行，`pid_start` 不一致 deny、为空只看 pid，推 `spec-7`/`--tags`/`--delete spec-7` 放行，会话没调用过技能放行，`echo`/heredoc 正文放行，逃生口放行，transcript 缺失放行，找不到 claude 祖先进程放行并在 stderr 说明，`origin/HEAD` 缺失时按 `main`/`master` 兜底，`--all` 和匹配 refspec `:` 被 deny，不访问网络。
- **环境 doctor**：`bash scripts/test-doctor.sh`。用临时 HOME/`CLAUDE_CONFIG_DIR`/`CODEX_HOME` 和假 codex 测完整配置、阶段 3 未配置 / 只配置一半、hook 路径缺失、matcher 只覆盖 Bash、matcher 缺 `Bash`（报 FAIL、提示按 hooks README 和 docs/setup.md 补上，且不改 `settings.json`）、hook 命令用绝对路径 node、规则版本过期、未验证的 codex 版本、缺 codex（分阶段 3 是否已配置）、本地代理端口空闲 / 监听 / 远程、预检关闭、例外开关、hook 错误日志、插件缺失、英文输出无中文和未知参数，不访问网络、不碰真实配置。
- **锁与领取记录**：`bash scripts/test-locks.sh`。测 `lock.sh` 的互斥、重入、等待超时、死持有者接管、槽位排队，`claim.sh` 的领取、并发领取、恢复与释放权限、交接预留与接手，worker 上限配置文件，以及两个 `codex-worker.sh` 在 `ISS_MAX_WORKERS=1` 下排队，不访问网络。
- **Design session**：`bash scripts/test-design-session.sh`。用假 orca 测 feature/map prompt、按讨论路由启动（Orca 调用按序只有 `run-create`、`terminal create --focus`、`worker-start --terminal --run --spec-file`、一次 `terminal wait`、一次阻塞的 `check --run`、`switch`、`close`；默认路由敲进终端的是 `claude --model opus --effort high`（官方 `claude` 档案不带 `--dangerously-skip-permissions`，TUI 照常弹权限确认），用真 `stage-route.sh use` 把「讨论」切到 `claude-glm / glm-5.4 / high`、`claude-flash / glm-5.4 / medium` 后命令（这两个档案照旧带 `--dangerously-skip-permissions`）、stderr 路由行和 mock 条款跟着变，切回默认即复原（标志也随之去掉），只切审查不影响讨论；改路由后 `--attach` 仍等旧会话、不读路由、不开新终端；缺启动器退出 6、路由读不到退出 64，两者都不调 Orca）、`--take` 的 `check --wait` 超时、会话退出（退出码文件和一次 `terminal wait` 两种来源）、run-create / terminal create / worker-start / check 失败、无 handle、handoff 缺失、提前交接（handoff.md 首行标记 `提前交接：先到这`：原样、带标题符号 / 半角冒号 / 句末标点都在 stderr 报「提前交接」，不在首行不报，`--attach` 也报）、启动前未交接 session 提醒（7 天内、无 handoff、同仓库名前缀才提醒；过期、已交接、其他仓库不提醒且退出码不变）、`--attach` 对路由之前的 agent launch 回执仍能取到 handle，和两个薄技能文本（含路由行转述、提醒转述、交接后接 find-next 推进模式、第 7 步走 `/grill-router`、map 的「先到这」不接）。路由表是真的 `stage-route.sh` 读测试自己的 `ISS_STAGE_ROUTE_FILE`，HOME 也指到临时目录，不碰本机真实的 `~/.claude/state`；缺启动器和读表失败这两条真表造不出来，经 `DESIGN_SESSION_STAGE_ROUTE` 换成假表脚本。不调用真实 Orca。
- **Orca 公共库**：`bash scripts/test-lib-orca.sh`。沿用 Design session 测试的假 `orca` 写法（PATH 假命令记录命令与每个参数），在子 shell 里 source `scripts/lib-orca.sh` 逐个调函数，核对假 orca 收到的内容：`ISS_ORCA` 指向 PATH 之外的第二个假 orca 时只有它被调用、`orca_exe` 跟随；`orchestration send` 的 `--run <id>` 紧跟子命令、Run id 为空/是选项/缺席/重复都退出 64 且不启动 Orca；`orchestration check` 默认 `--peek`、`--take` 才去掉、`--timeout-ms` 展开成一次 `--wait --timeout-ms`、裸 `--wait`/非正整数/缺值/未知选项都退出 64；`terminal by_pane` 同一进程连调两次 Orca 被问两次且看到漂移后的新 handle，找不到/解析不了/Orca 失败分别退出 1/2/3；`orchestration run-create` 带 `--objective`；`orchestration worker-start` 只收编一种形态——`--run <id>` 紧跟子命令、`--terminal <handle>` 和 `--spec-file <path>` 必填、`--timeout-ms` 可选、Run id 为空/重复/缺终端/缺 spec 文件/带 `--model` 之类它不收的选项都退出 64 且不启动 Orca；`terminal create` 的 `--focus` 可选、别的选项退出 64，`terminal switch` 必带 handle，`terminal wait` 必带 exit|tui-idle 和正整数超时（一次阻塞等待）、条件或超时不对退出 64；`status`、`agent launch`、`worktree list`/`create`、`terminal close`/`send`、`worktree rm`、`repo list` 的命令行逐字一致、必填参数为空退出 64，不调用真实 Orca。
- **会话自关**：`bash scripts/test-close-self.sh`。用假 `orca` 和带 bare origin 的临时 git 仓库测 `close-self.sh`：假 orca 经 `ISS_ORCA` 指向（PATH 上也放同一份，给还没迁到公共库的 `progress-tab.sh` 用）；不在 Orca 里（没有 `ORCA_TAB_ID` / `ORCA_AGENT_PANE`）打印 `skip: not in Orca` 且不调 orca；`ISS_ORCA` 指向不存在的程序时同样打印 skip，不回落 PATH 上的 orca；找不到本会话的终端退出 1 并告警；默认只关自己的标签，不删 worktree、不用 `--all`；`--remove-worktree` 指向本终端干净且已并入 origin 的 worktree 时经 `orca worktree rm --force --delete-branch` 连 worktree 和分支一起删，脏 / 未合并时只关标签并说明原因，指向别的 worktree 时只用 `git worktree remove` 和 `git branch -d`（不带 `--force`）、只关自己的标签，指向主 worktree 时告警且什么都不删；先 `progress-tab.sh close-all` 关本 Run 的进度标签再关自己的标签（别的 worktree 的、自己标签上同名的、改名后的 spec 标签都不关）；`--dry-run` 只打印不执行；未知参数退出 64、`--help` 退出 0，不调用真实 Orca。
- **完成度结论**：`bash scripts/test-completion-report.sh`。用临时 Design session 目录、带 tag 与提交的临时 git 仓库、假 `gh` 和假通知命令，测情形 1/2（推荐 A/B）/3、无 tag、未发布提交为 0、minor/patch/非语义化 tag 版本号、发版解冻与普通等待时机、中断 grill、`--notify` 仅完成时通知一次且失败不改变退出码、gh 失败写「（查询失败）」和用法错误退出 64，不访问网络。
- **grill 进度查询**：`bash scripts/test-grill-status.sh`。用临时 Design session 目录和假 `gh` 测已完成 / 进行中 / 中断（有无 topic.md）、仓库名前缀不误匹配、gh 失败和无记录，不访问网络。
- **自动启动第 1 波**：`bash find-next/scripts/test-launch-wave.sh`。假 pipeline-status、claim、max-workers 在 PATH 上，假 orca 放在 PATH 之外、只经 `ISS_ORCA` 指给 launch-wave（PATH 上另放一个拒绝一切调用的 `orca` 护栏；`ISS_ORCA` 指向不存在的程序时不回落到 PATH，按不在 Orca 里输出手动命令），测试运行输出、不在 Orca 时的手动输出、预留后再启动、预留冲突跳过、启动失败撤销预留并删空分支、`--only` 过滤和恢复条目（含原 worktree 不在 Orca 时在主工作树开终端标签、路径带空格的转义）、`--apply` 写启动状态、`--next-wave` 读取状态/max-workers、跳过中断条目、无可启动、循环依赖和仓库锁占用，以及 `--impl agent --agent-model` 的命令后缀、状态写入/读回、旧状态回退 codex 与非法参数，不调用真实 orca。另测 `FLASH_ORCHESTRATOR=1` 的首波/恢复路径用 `openclaude`、终端用 `claude-flash`、默认 agent 后端写入状态，以及无标记的下一波从状态读回 flash 选择；flash 段逐字核对整份 Orca 调用日志（试运行只问 `status`、`worktree list` 各一次，`--apply` 同样问完这两声再加一次 `worktree create`、`agent launch` 或 `terminal create`，每个参数各占一行）。
- **codex 后端**：`scripts/selftest-codex.sh [--model <id>] [--only L1|V1|V2|V3]`。各级的内容见脚本开头的注释和 `docs/codex-backend.md` 第三节：
  - V1：假 codex，确定性，不花 GLM；
  - V2：真 codex 连假服务器（`scripts/testing/mock-responses.js`），不花 GLM，要跑 6–7 分钟；
  - L1、V3：真 GLM，要求配置的模型端点可用（作者环境：Ferryman）。V3 会跑 tdd 小 ticket、Resume，以及 2 个 worker 并发。

  模型与思考强度来自阶段路由表（`scripts/stage-route.sh`），自测按三条规则把本机真实的路由表隔开：给了 `--model` 就测这个模型，并把 `ISS_STAGE_ROUTE_FILE` 指到 `/dev/null`（一张没有任何行的表，所有阶段按默认；否则非默认路由会压过显式 `--model`）；没给 `--model` 就测「实现」阶段的实际路由且不隔离，所以第 0 步的 L1 预检索的就是 worker 真正会跑的模型和强度；V1、V2、V3 一律与真实路由表隔离，V1 末尾的路由用例每次调用把 `ISS_STAGE_ROUTE_FILE` 指到临时文件，测非默认路由压过 `--model` / `--thinking`、带 `--read-only` 读「调研起草」、到期 / 未知组合 / 损坏文件回默认并带上路由表的提示、复位后 `--model` 重新生效、Resume 沿用第一段的模型和强度、codex-glm 跑不了的路由和读表失败都以用法错误退出且不启动 codex、本机 worker 目录缺模型只加提示不拦；L1 开跑前恢复入口处的隔离状态，整套跑一遍时 L1 仍按前两条规则走。改了 `codex-worker.sh` 或 `progress.sh`，或者升级了 codex，都要把 V1、V2、V3 全部重跑一遍。用 `--impl codex` 跑技能时，第 0 步会跑 L1（命令不带 `--model`）。
- **codex worker home 生成**：`bash scripts/test-setup-worker-home.sh`。用临时目录里的假源 home 测配置键/表过滤、`model_catalog_json` 改写、文件复制、权限、幂等备份和输出不泄漏配置值，不访问网络、不碰真实 `~/.codex`。
- **Opus review 入口**：`bash scripts/test-opus-review.sh`。用临时 HOME/PATH 里的假 `claude`、假 `claude-glm` 和指向临时文件的 `ISS_STAGE_ROUTE_FILE`（路由经 `stage-route.sh use` 设置）测三类 prompt、GLM 代理环境变量清理、路由表驱动（默认路由走官方 `claude` 且带 `--model opus --effort high`；审查切成 `claude-glm / glm-5.4 / medium` 后经假 `claude-glm` 执行并带 `--model glm-5.4[1m] --effort medium`，两个审查轴子代理钉 `opus`（Agent 工具只收别名，GLM 启动器自己映射到 GLM；不钉路由的模型名）；`draft` 读「审查」、`diagnose` 读「诊断」，只动讨论或诊断不影响审查；到期回默认；路由表读不出来退出码 64 且不启动任何启动器；缺启动器退出 6；补标两趟走同一启动器、额度错误不回落到官方 claude）、findings 首行每次写本次路由（阶段、档案、模型、思考强度、时间）、只读工具白名单、findings 原子写入、认证/额度/超时/其他错误的不同退出码、超时进程树回收，以及 `## 需要人取舍` 的标记校验（缺标 → 同模型补标一次、补标仍失败退出码 7 并列出条目、标记齐全不重试、「无」和没有这一节都通过），不访问网络、不花 Opus 额度。
- **阶段路由表**：`bash scripts/test-stage-route.sh`。用临时状态文件和假 `date` 测六个阶段的默认表、`use` 单项与多项、只动一个阶段时其余阶段的行不变、设回默认即离开表、`--until` / `--for` 与按阶段到期、目录外的组合 / 编排锁定 / 档案不接受的强度一律拒绝且不改表、审查与实现同模型只警告一次不拦、未知组合回默认并提示、损坏文件整表回默认并提示、`--print` 四个字段与找不到值时退出 66、`--launch` 四个档案的交互与 headless 启动命令，旧开关迁移（没有表时的第一次运行自动迁入两个旧开关里未到期的设置：思考强度取 high、到期时间照搬、旧 `grill` 进讨论、旧 `review` 进审查和诊断、旧 `worker` 进调研起草和实现；已到期的忽略；反推不出档案或目录外的型号保留旧文件并提示，同一次里其余的照常迁入；迁完删旧文件；表里已生效的阶段不覆盖；表已在时只有 `migrate` 才迁；`migrate` 无参数、无可迁时说一声、无可迁不改写表、写不成退出 65；迁移说明只走 stderr，`--print` 的 stdout 仍只有值；`ISS_STAGE_ROUTE_FILE` 改位置的表只看自己旁边的旧文件），以及 `/grill-router` 技能文件的写法和各用户文档对路由表的说法（README、setup 两份只写 `/grill-router` 的软链与用法，GLOSSARY 的 Judgment model、Worker model、Design session、Opus review 四个词条指向 Stage route，其余纯文档不再出现两个旧开关命令），两个旧开关的脚本、技能目录和测试已删除、不留别名；不调真实启动器。
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
- 「讨论」路由切到 glm-5.4 后的真实 Design session（Orca 终端里起 `claude-glm`、靠 `exit-code` 判定结束、收编后经 Skill 工具加载上游技能、mockit 提交）没有实机跑过，归规格 #25 的人工冒烟；`claude-glm --resume` 续接官方 Opus 开的 Design session 只验证了同一端点下的续接。`opus-review.sh` 经 `claude-glm` 的无头调用已冒烟（落到 `glm-5.4[1m]`）。
- 路由表的真实冒烟（在 Orca 里各切换一次讨论、审查、实现、调研起草的路由，确认下一次派发生效、模型与思考强度生效、报告首部写对）没有跑过，不进自动测试；已验证目录里各项的证据见 `scripts/stage-route.sh` 头注释。
- `codex-glm / glm-5.3-flash` 不在已验证目录里（`docs/codex-backend.md` E17）：flash 不在 `~/.codex-worker/models.json` 目录里，L1 没有实证；L1 通过也只证明端点接受该型号，不证明 `model_reasoning_effort = "high"` 被接受或有效，也不证明 1M 上下文可用。

验证过的项目从这里删掉，发现的新问题补到"设计要点"里。
