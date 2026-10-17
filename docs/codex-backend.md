# codex 后端：实验记录、设计约束与验证流程

目标有两个：
1. 本技能新增 `--impl codex`，由 `scripts/codex-worker.sh` 跑 External worker；
2. 平时的写代码任务（全局 CLAUDE.md 里"交给 PI"那一段）也改用 `codex-worker.sh`，并且能看到进度。

本文分三部分：实验证据（2026-10-17，NUC10，codex-cli 0.163.0，GLM-5.3 经 Ferryman `127.0.0.1:15722`）、由证据推出的设计约束、实现前后必须走完的验证流程。实现时如果和这里的约束冲突，先回来改这份文档，再改代码。

## 一、实验记录

实验脚本和输出在 `~/.cache/codex-exp/`（`mock.js` 是假 Responses 服务器，`fail.sh`/`run.sh` 是测量脚本），做完即可删除。

### 正常路径（真 GLM）

| # | 实验 | 结果 |
|---|---|---|
| E1 | worktree 里改代码 + `git commit`，`--approve-for-me` | ✅ 成功。auto_review 放行了写主仓库 `.git/worktrees/`。MAINTAINING.md 第 9 条"沙箱拦 worktree commit"已不成立 |
| E2 | `-c 'project_doc_fallback_filenames=["CLAUDE.md"]'` | ✅ 遵守了 CLAUDE.md 里的标记规则 |
| E3 | Brief 里写"先读 `<tdd dir>/SKILL.md`" | ✅ 读了，并走了先红后绿 |
| E4 | `--json` 事件流 | 每个命令/改文件/说明都有 `item.started`/`item.completed`；**事件不带时间戳** |
| E5 | `codex exec resume <thread_id>` | ✅ 上下文保留、能写。**`--approve-for-me` 等 exec 级参数必须写在 `resume` 之前**，写在后面报错退出 2 |
| E6 | 同一任务：`--approve-for-me` vs `--dangerously-bypass-approvals-and-sandbox` | approve：160s，输入 296K token（不含 auto_review 线程自身消耗）；bypass：54s，169K。两者都提交成功 |
| E7 | 不加 `--add-dir` 写仓库外文件（`--approve-for-me`） | auto_review 放行了。它在这里不是安全边界 |
| E8 | 默认只读模式（不加任何沙箱参数） | ❌ **Windows 上 pwsh/cmd 全被策略拒绝，连 `git status` 都跑不了**。只读模式在本机不可用（插件 `/codex:review` 走只读，大概率也受影响，未单独验证） |
| E9 | 4 个 worker 在不同 worktree 并发 | ✅ 无冲突 |
| E10 | 中文 prompt | ✅ 正常（该次因只读模式没法读文件，见 E8） |
| E11 | 测试命令跑 150s，不提示超时 | ✅ codex 自己轮询等待，期间每 30–70s 一条 `reasoning: "Poll."`，最终拿到输出 |
| E12 | 明确要求"等它跑完"的 240s 命令 | 期间**最长 208s 没有任何事件** |
| E13 | `-m glm-5.3 -c model_provider=custom` | ✅ 可用，能钉死模型和 provider |
| E15 | 实现 codex-worker.sh 时（bypass 模式，2026-10-17），codex 想清理测试目录 | **bypass 下仍有内置命令策略**：`rm -rf`、`Remove-Item -Recurse` 被拒（"blocked by policy"）。codex 会自己换写法或放弃清理，不会卡住。Brief 里不要要求它递归删目录，清理由 wrapper/调用方做 |
| E16 | 同一任务，33 分钟、212 行事件 | 外层 `wc -l < events.jsonl` 偶发 `No such file or directory`（Windows 上读正在写的文件）。监控读事件文件必须容错（codex-worker.sh 用 node 读、出错按 0 处理） |
| E14 | hooks：开着 vs `--disable hooks`，进程监控 | 两种情况下都没观察到 Ferryman/Orca 钩子进程，`codex exec` 0.163 实际上不触发它们。注意本会话里 `ORCA_PANE_KEY` 是设了的，若钩子触发会把 worker 的状态报到当前 Orca 面板 |

### 失败路径（假服务器 / 真 GLM 杀进程）

| # | 场景 | codex 的表现 |
|---|---|---|
| F1 | 429（正文 1302 限流） | **不重试**，约 10s 退出码 1，`turn.failed: "exceeded retry limit, last status: 429 Too Many Requests"`，**响应正文被丢弃** |
| F2 | 429（正文 1113 余额不足） | 与 F1 完全相同。**codex 输出里分不出限流和额度用完** |
| F3 | 401 | 重试 5 次（`Reconnecting... n/5`，消息含正文），约 10s 退出码 1，`turn.failed` |
| F4 | 代理端口不通 | **无限重连**，每约 30s 一条 `{"type":"error","message":"Reconnecting... waiting for network ..."}`，420s 仍未退出；`request_max_retries=1`、`stream_max_retries=1` **都无效** |
| F5 | 接受请求但从不响应 | 无任何事件，420s 未退出 |
| F6 | 发了 SSE 头后不再发数据 | 默认 300s 流空闲超时 × 5 次重试 ≈ 30 分钟；加 `stream_idle_timeout_ms=30000`、`stream_max_retries=1` 后 70s 退出码 1 |
| F7 | 客户端给错 token（真 Ferryman） | 照常成功：Ferryman 不校验客户端 token，换用自己的 key。认证错误只会来自智谱侧 |
| F8 | stdin 是没关闭的管道 | **挂住**，直到 stdin 关闭（打印 `Reading additional input from stdin...`） |
| F9 | `timeout codex ...` 后对 timeout 的 winpid `taskkill //T` | ❌ **杀不干净**：`sh → node → codex.exe → pwsh → node` 全部成为孤儿。MSYS 程序（timeout）启动 sh shim 会断开 Windows 父子链 |
| F10 | 子 shell 里 `exec node <codex.js>`，对其 winpid `taskkill //T` | ✅ 整棵树都死了 |
| F11 | 子 shell 里 `exec codex`（经 sh shim，但中间没有 MSYS 程序） | ✅ 也能杀干净。pi-worker 现在的写法（`exec "$PI_BIN"`）属于这一种，没有问题 |
| F12 | 命令执行中被硬杀，再 `resume <thread_id>` | ✅ 能续上，记得之前的 commit，继续完成新工作 |

### 参考：codex-plugin-cc 1.0.6 源码与 issue（2026-10-17 查阅）

**插件怎么做的。** 它通过 `codex app-server` 的 JSON-RPC 跑任务，不走 `exec --json`：
- 一个工作区共用一个 broker 进程；
- 后台任务由一个 detached 的 node worker 执行；
- 进度按 phase 归类（running/editing/verifying/finalizing）写进 job 日志；
- 取消时先发 `turn/interrupt`，再 `taskkill /T`。

**issue 区里和本方案相关的问题**（截至查阅日全部 open）：

| 问题 | issue | 和本文的关系 |
|---|---|---|
| 后台任务没有 Time limit，也没有卡死检测，停在 running 一挂就是几十分钟到一天以上 | #520 #478 #615 #183 | 约束 6 的由来。#520 的评论里有人用 `timeout codex exec ... < /dev/null` 绕过，和 F8 一致 |
| codex 不发结束事件，任务永远停在 running。#391 有 17 条评论，有人一次会话 12 个任务里卡了 4 个 | #391 #698 #598 #781 | exec 也可能出现：最后的 `agent_message` 已经吐出，但一直没有 `turn.completed`、进程也不退。见约束 13 |
| 在 Git Bash 下，`SHELL` 把 `taskkill` 的参数搞坏，导致取消失败 | #708 #647 | 和 F9 是同一类问题：MSYS 掺进 Windows 进程管理就会出事 |
| 非英文 Windows 上解析 `taskkill` 输出失败 | #423 #310 | 本机是中文系统。约束 3：杀完要按进程是否还活着来判断，不读 taskkill 的输出 |
| worker 进程已经死了，状态却永远是 running | #704 #639 #517 | 约束 14 |
| broker 进程泄漏；一个会话结束，会把其他会话正在跑的任务一起杀掉 | #543 #540 #612 #803 | exec 每个 worker 一个进程，不共享，没有这个问题 |
| 只读/可写沙箱在 Windows 上不可用；worktree 的 gitdir 在可写范围之外 | #349 #295 #765 #304 #145 | 与 E8 一致；E1 能成功是因为 auto_review 放行了。约束 2 选 bypass |
| 写任务报告"完成"，实际一个文件也没写 | #531 | 验收检查本来就会拦下 |
| 多个进程同时用同一个 `~/.codex` 会有竞争 | #382 | E9 里 4 个并发没有出问题，但 V3 要专门测并发 |
| 前台任务撞上 Bash 工具 10 分钟的上限，会被杀掉 | #542 | 一律用 `run_in_background` |

**替代品 umum-ai/claude-codex-bridge**：同样基于 app-server，通过 Claude Code Channels 把进度推进会话里，还能中途追加指令。但它只有 10 个 star，依赖的 Channels 还是研究预览，README 里没写卡死检测。它默认用 `danger-full-access` + `approvalPolicy: never`，这点和约束 2 的选择相同。目前不采用，以后 Channels 稳定了再看。

**为什么不用 app-server，而用 `exec --json`。** app-server 的好处是能优雅中断、能中途追加指令、事件更细。代价是要自己实现 JSON-RPC 客户端、维护 turn 的状态机。上面那一串"永远 running"的问题，大多出在插件自己的状态机上（#391 #698 #781）。本方案只需要"跑完一个任务，能监控、能杀、能续"，`exec --json` 加 wrapper 的 watchdog 就够了，出错的面也小得多。以后如果需要"中途追加指令"，再考虑 app-server。

## 二、设计约束（由上面的证据推出）

1. **直接调 `codex exec --json`，不走 codex-plugin-cc。** 插件有几个问题：
   - 依赖本地补丁，`claude plugin update` 会把补丁冲掉；
   - 没有卡死检测，也没有 Time limit；
   - `codex-rescue` 子代理跑在 sonnet 上，会花 Claude 额度。

   插件只保留给临时手动用。
2. **沙箱用 `--dangerously-bypass-approvals-and-sandbox`**，与 pi 的"无沙箱"对等。原因：
   - 只读模式在本机不可用（E8）；
   - auto_review 慢约 3 倍，token 也更多（E6）；
   - auto_review 拦不住写仓库外（E7）。

   安全边界仍然靠 worktree 隔离、Brief 规则和验收检查。exploration 角色同样用 bypass，"不改仓库"由 Brief 规则加验收检查（`new_commits` = 0 且树干净）保证。
3. **启动方式：子 shell 里 `exec node <codex.js> exec ...`**，或者 `exec codex`。wrapper 和 codex 之间**绝不能插入 MSYS 程序**（`timeout`、不带 exec 的 sh），否则杀进程树会失效（F9）。杀进程沿用 pi-worker 的 `kill_tree`。
4. **stdin 必须是会结束的输入。** Brief 用 `< brief.md` 喂给 stdin，prompt 参数写 `-`；或者 stdin 用 `</dev/null`、Brief 走参数。绝不能继承一个开着的管道（F8）。
5. **固定参数：**
   - `-m <model> -c model_provider=custom`：防止 CC Switch 改了 config 后悄悄换模型；
   - `-c 'project_doc_fallback_filenames=["CLAUDE.md"]'`；
   - `--disable hooks`；
   - `-c model_providers.custom.stream_idle_timeout_ms=120000 -c model_providers.custom.stream_max_retries=2`：把 F6 压到约 6 分钟以内；
   - `-o <run dir>/result.md`；
   - `-C <cwd>`；
   - `--add-dir`：只在需要写仓库外目录时加（exploration 的笔记目录）。
6. **Idle timeout 只按"有进展的事件"计时。**
   - 有进展：`type` 以 `item.` 或 `turn.` 开头的行。
   - 没有进展：`type: "error"` 的 `Reconnecting...` 行。只看文件变大会被 F4 的重连行一直骗下去，永远判不出卡死。
   - 默认值仍是 600s：大于 E12 观察到的 208s 空档，也大于约 6 分钟的流空闲上限（约束 5）。
7. **识别"代理断了"，提前结束。** 连续 3 条 `waiting for network`（约 90s）就杀掉，状态记为 `transient`。错误信息里写明"代理 15722 不通"。
8. **错误分类改看 `turn.failed.error.message`。** 规则如下：

   | 条件 | 状态 |
   |---|---|
   | 含 `401` / `403` / `身份验证` / `unauthorized` | `auth` |
   | 含 `429` | `transient` |
   | `stream disconnected` / `idle timeout` / 网络类 | `transient` |
   | 其他 | `error` |
   | 最后是 `turn.completed` | `ok` |

   429 分不出是限流还是额度用完（F1/F2）。wrapper 按 transient 重试，重试完退出码 4，错误信息里注明"可能是额度用完"。SKILL.md 对 transient 和 quota 的处理本来就相同（停止派发，问用户），所以不影响编排逻辑。不看 codex 的退出码（失败一律是 1），只看事件。
9. **Resume：**
   - `thread.started.thread_id` 写进 `resume.json`；
   - 续跑命令是 `codex exec <全部 exec 级参数> resume <thread_id> -`，Resume 提示词走 stdin；
   - 参数顺序见 E5；
   - 会话文件在全局 `~/.codex/sessions/`，不在 run dir 里。坏 Resume 的检查改成"`~/.codex/sessions` 下能找到包含该 thread_id 的 rollout 文件"，找不到就退出 64；
   - 不能用 `--ephemeral`。
10. **对外契约与 pi-worker 保持一致：** 参数、run dir 文件、`status.json` 字段（`session_id` 字段放 thread_id）、退出码 0/2/3/4/5/6/7/64、Resume 规则。SKILL.md 的编排逻辑不分叉，只换脚本名和 Config。
11. **Preflight：** 检查 15722 端口在监听，再跑 L1（让模型回一个词）。端口不通直接报"Ferryman 没开"。
12. **测试钩子：** `CODEX_WORKER_CODEX` 可以换成假的 codex 可执行文件（同 `PI_WORKER_PI` 的思路），`CODEX_WORKER_BASE_URL` 可以把 provider 指向假服务器。
13. **挽救"答完了却不收尾"的情况**（插件 #391）。触发条件：Idle timeout 触发时，已经出现过 `agent_message` 而没有 `turn.completed`。处理：
    - 照样杀掉；
    - 把最后一条 `agent_message` 写进 `result.md`；
    - 状态记为 `stalled`，`error` 里注明"已有最终回复"。

    不改成 `ok`，由 Orchestrator 走验收检查来判断：如果 commit 和测试都在，就当完成处理。
14. **worker 死了要能看出来**（插件 #704）。
    - wrapper 启动时把 Windows pid 写进 `<run dir>/pid`；
    - 正常结束写 `status.json`；
    - `progress.sh` 遇到"没有 `status.json`，pid 也不在了"，就报 `dead`，不能显示成还在跑。
    - **Windows 的 pid 会很快被复用**（V3 实测：一个已结束 26 分钟的 run，其 pid 被别的进程占用，`progress.sh` 报成了 `running`）。所以判断顺序是：`status.json` 不比 pid 文件旧，就是 `finished`；否则 pid 文件里同时记录进程的启动时间，pid 活着并且启动时间对得上，才算 `running`。

    这能覆盖 CC 会话关闭、后台任务被系统杀掉之类的情况。
15. **杀进程后要确认结果。** `taskkill` 之后，按 pid 查询进程是否还在（中文系统下 taskkill 的输出不可靠，插件 #423）；还在就再杀一次，并记录到 `stderr.log`。

### 平时写代码怎么用

全局 CLAUDE.md 里"交给 PI"改成：

1. 写 Brief 文件；
2. 用 `codex-worker.sh` 在后台运行（Bash `run_in_background`）；
3. 用 `progress.sh <run dir>` 查看进度。

`progress.sh` 是新增的小脚本，打印：最近 N 个动作（命令、改了哪些文件、说明）、距上次有进展过了多少秒、当前是否有命令正在运行、累计 token。用户在手机 Orca 的终端里也能直接跑。超过 Idle timeout 由 wrapper 自动杀掉并报 `stalled`，不会再无声卡住。

## 三、验证流程

每一级都必须全部通过才能进入下一级。任何一条失败，先修实现，再从这一级重跑。

### V0 静态检查
- `bash -n` 两个脚本；对照本文第二节逐条确认实现里都有对应的代码。

### V1 假 codex（确定性，不花 GLM）
用 `CODEX_WORKER_CODEX` 指向一个 node 写的假 codex，按场景脚本吐事件：

| 用例 | 期望 |
|---|---|
| 正常完成 | 退出 0；`result.md`、`status.json`、`resume.json` 齐全；`session_id` = 假 thread_id |
| `turn.failed` 401 | 退出 2，不重试 |
| `turn.failed` 429 两次后成功 | 重试后退出 0，`attempts` = 3 |
| `turn.failed` 429 一直失败 | 退出 4，错误信息提到可能是额度 |
| 只吐 `Reconnecting... waiting for network` | 约 90s 内退出 4，信息提到代理 |
| 只吐 `Reconnecting n/5` 行、无进展（idle 设 20s） | 退出 7（证明 error 行不重置 Idle 计时） |
| 完全不吐事件（idle 设 20s） | 退出 7 |
| 一直有进展但超过 Time limit | 退出 5，`resume.json` 可用 |
| 对上一条 `--resume` | 假 codex 收到的参数顺序正确（exec 级参数在 `resume` 前，thread_id 正确），`segments` = 2 |
| 坏 Resume：无 resume.json / thread 对应的 rollout 不存在 / 带了 `--cwd` 等 | 退出 64，不启动 codex |
| 假 codex 起一个原生 node 孙进程后卡住，被 Idle timeout 杀 | 孙进程也死了（按命令行标记查 Win32_Process） |
| 假 codex 读 stdin 直到 EOF | 不挂住（证明 stdin 会结束） |
| 吐出 `agent_message` 后既不发 `turn.completed` 也不退出（idle 设 20s） | 退出 7，`result.md` 是那条回复，`error` 里注明已有最终回复 |
| 运行中途 wrapper 自身被 `taskkill` 杀掉 | `progress.sh` 报 `dead`，不是 running |
| 杀进程树后确认 | `stderr.log` 记录了确认结果，pid 不在了 |

### V2 真 codex + 假服务器（不花 GLM）
用 `CODEX_WORKER_BASE_URL` 指向 `mock.js`，覆盖第一节 F1、F3、F4、F6：

- F1 和 F3：分别得到退出码 4 和 2；
- F4：约 90s 内得到 4；
- F6：在约束 5 设定的上限内退出，不会拖到 30 分钟。

### V3 真 GLM 小任务（selftest L1/L2）
在临时仓库的 worktree 里完成一个小 tdd ticket。断言：

- 退出 0，有新 commit，树干净，我们重跑测试能通过；
- 事件里能看到读了 tdd 的 `SKILL.md`；
- CLAUDE.md 里的标记规则被遵守；
- 运行中调用 `progress.sh` 能输出有意义的内容。

再用很小的 Time limit 让它停在 5，`--resume` 续完：`segments` = 2，`new_commits` 从第一段起算，测试通过。

另外同时跑 2 个 worker，各自在自己的 worktree 里（插件 #382 说共享 `~/.codex` 会有竞争）：两个都要通过上面的断言，`stderr.log` 里不能有 sqlite/lock 相关的错误。

### V4 L3 端到端
在 `allanpk716/iss-e2e-test` 上开新 spec，执行 `/implement-spec-split --impl codex`。检查项沿用 MAINTAINING.md 的 L3 清单，再加两条：

- 跑完没有残留的 codex/node 进程；
- 每次运行结束时 `progress.sh` 的最后输出和 `status.json` 一致。

### V5 平时用法试运行
用改好的全局 CLAUDE.md，做一个真实的小修复任务。确认：

- 主代理确实走了 `codex-worker.sh`；
- 运行中能用 `progress.sh` 回答"进行到哪了"；
- 结束后按 `git diff` 审查。

## 四、实施顺序

1. `scripts/codex-worker.sh`、假 codex、selftest 扩展（V0–V3）。
2. SKILL.md 加 `--impl codex`，同步改 MAINTAINING.md（重写第 9 条，新增 codex 相关要点）和 GLOSSARY.md；README 同步。
3. V4。
4. `scripts/progress.sh`，改全局 CLAUDE.md，V5。
5. pi 后端是否删除，等 V4、V5 通过、用过一段时间后再定。
