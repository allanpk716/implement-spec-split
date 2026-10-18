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
6. **自动找 spec（第 0 步）。** 原版没有这一步，是本技能加的。它用 GitHub issue API 的 `sub_issues_summary` 字段，判断哪些父 issue 还有没关的子 ticket。
7. **push 和关单前先问用户。** 本技能加了这条，原版没有。
8. **GLM 只能放到会话外面跑（External worker）。**
   - Agent 工具的 `model` 参数只能选 `sonnet`、`opus`、`haiku`、`fable`。
   - 服务地址和 token 是整个进程共用的，所以没法让会话里的某一个子代理单独走 GLM。
   - 所以要另起一个 CLI 进程来跑 GLM，会话里只留下主代理和 review。
9. **External worker 用 codex（首选）或 pi，不用 `claude -p`。**
   - `claude -p` 接 GLM 跑无头模式，会被检测、被限流，下午高峰期更明显。这是用户实际用下来的经验。
   - 以前不用 codex 的几条理由，2026-10-17 的实验大多推翻了（证据见 `docs/codex-backend.md`）：
     - 不读 `CLAUDE.md`：加 `-c 'project_doc_fallback_filenames=["CLAUDE.md"]'` 就读（E2）；
     - 加载不了 tdd 技能：在提示词里写"先读 `<tdd dir>/SKILL.md`"就行，wrapper 的 `--skill` 就是这么做的（E3）；
     - 沙箱拦 worktree commit：改用 `--dangerously-bypass-approvals-and-sandbox`，和 pi 一样无沙箱（E1、E8，约束 2）；
     - 依赖本机代理：依然成立，现在是 Ferryman（`127.0.0.1:15722`）。所以 wrapper 先探端口，preflight 也会先探。
   - 换成 codex 的原因是**能看到进度**：pi 的 `-p` 模式外面看不出它在干什么，用户碰到过 worker 卡很久却没法判断。codex 的 `--json` 每个命令、改动、说明都有事件，`progress.sh` 能直接展示。
   - pi 后端保留，等 codex 后端用过一段时间再决定删不删。pi 不在智谱公布的 Coding Plan 支持工具名单里，有被风控的可能，用户已经知道并接受。
10. **pi 的 JSON 模式出错时退出码也是 0。**
    - `pi-worker.sh` 不看退出码，而是看事件流里最后一条 assistant 消息的 `stopReason`。
    - 再根据 `errorMessage` 判断错误类型：auth、quota、transient 或 error。
    - 改 wrapper 时别把这一点改回成看退出码。
11. **worker 的自我报告不能信。** `status: ok` 只说明它跑完了、没碰到 API 错误。主代理还要检查三件事：有新 commit、工作区是干净的、集成分支的最新提交已经合进来。最后测试结果以 merger 重跑的为准。
12. **GLM 不可用时不能自动换回 sonnet。** 用 GLM 就是为了省 CC 额度，自动切回去这个目的就没了。碰到 auth、quota 错误，或者重试完还是失败，要先停下来问用户。
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

- **codex 后端**：`scripts/selftest-codex.sh [--only L1|V1|V2|V3]`。各级的内容见脚本开头的注释和 `docs/codex-backend.md` 第三节：
  - V1：假 codex，确定性，不花 GLM；
  - V2：真 codex 连假服务器（`scripts/testing/mock-responses.js`），不花 GLM，要跑 6–7 分钟；
  - L1、V3：真 GLM，要求 Ferryman 开着。V3 会跑 tdd 小 ticket、Resume，以及 2 个 worker 并发。

  改了 `codex-worker.sh` 或 `progress.sh`，或者升级了 codex，都要把 V1、V2、V3 全部重跑一遍。用 `--impl codex` 跑技能时，第 0 步会跑 L1。
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
  5. 用 `--impl sonnet` 再跑一遍。这次重点看：实现类的子代理确实用了 `IMPLEMENT_MODEL`，而且全程没有调用 `pi-worker.sh`。

## 安装方式

- 面向 AI Agent 的安装/调用快速入口见 `docs/ai-agents.md`。
- 技能目录 `~/.claude/skills/implement-spec-split` 是这个仓库的 git 克隆。
- 如果在别的地方的克隆里改（比如 `~/orca/implement-spec-split`），commit 之后要在技能目录里执行 `git pull --ff-only <那个克隆的路径> main` 同步过去。
- 不用软链接，因为 Windows 上软链接很麻烦。

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

- 用 `--impl sonnet` 跑一遍完整流程，确认实现子代理真的跑在 `IMPLEMENT_MODEL` 上。
- `stalled` 在真实 L3 运行里的表现（目前只有 L2 用假 pi 做的确定性用例）。
- 第二次 `timeout` 时主代理会停下来问用户（2026-10-14 的 L3 里 Resume 一次就完成了，没走到这条路径）。
- exploration 角色。在小仓库里，主代理会按"可选"直接跳过它。
- 验收检查能不能拦住不合格的 worker。L3 里所有 worker 一次就通过了，没有触发过拦截。
- GLM 出错的处理：碰到 auth、quota 或 transient 错误时，主代理会不会停下来问用户。L2 只测了 wrapper 会不会给出正确的退出码。
- 有 PR 流程的仓库里，draft PR 能不能开出来、最后能不能标成可以 review。

验证过的项目从这里删掉，发现的新问题补到"设计要点"里。
