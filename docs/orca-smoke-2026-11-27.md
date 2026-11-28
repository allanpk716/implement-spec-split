# Orca 1.4.274 实测：收编自定义启动器终端、已有 worktree 派发、headless 退出

> 日期：2026-11-27 · 主机：mini6（local）· Orca 1.4.274 · 仓库 `/Users/allan716/orca/implement-spec-split`（main @ `d75c418`）
> 前置只读报告：`~/.cache/codex-runs/implement-spec-split-20261127-1237-orca-route-facts/result.md` 第 2–4 节。本文所有结论均来自实际执行；未改 Orca 设置、`~/ops`、`~/.claude`、`~/.codex*`。

## 0. 五条总结

1. **收编自定义启动器终端这条路能走**：`orca terminal create --worktree path:<P> --command "<launcher> --model ..."` + `orca orchestration worker-start --spec-file <brief> --terminal <handle>` 实测成功；worker 收到 spec、完成任务、发出 `worker_done`（带 `reportPath`），Dispatch 记为 `succeeded`。
2. **模型与思考强度能经命令行生效**：`claude-glm --model glm-5.4`、`claude-flash --model glm-5.4 --effort high` 均被 Claude CLI 接受；`/status` 显示 `Model: glm-5.4`，启动横幅分别显示 `glm-5.4` 与 `glm-5.4 with high effort`，会话 transcript 记录 `"model":"glm-5.4"` / `"effort":"high"`。
3. **但 Orca 不知道命令行里的模型**：走 `--terminal` 收编时 Dispatch 只记 `launch.effective.agent="claude"`，`model`/`effort` 均为 `null`；模型只能从 TUI `/status`、启动横幅或 `~/.claude/projects/.../*.jsonl` 取证。
4. **已有 worktree 派发与同步等待都成立**：`--worktree path:P` 不新建 worktree、不重跑 setup（effects: `worktree=reused`、`setup=not_applicable`、`setupSource=existing_worktree`）；一个 Bash 里 `run-create → worker-start --run → check --run --wait` 未被 `consumer_fenced`，直接拿到 `worker_done`。
5. **两处意外**：(a) 普通 git worktree 用 `/tmp/...`（符号链接）报 `selector_not_found`，改用 canonical `/private/tmp/...` 后成功并被 Orca 当场收编为 workspace；(b) headless 用 `exec` 能让 terminal 真正退出且 `wait --for exit` 返回 `exitCode`，但退出后 `terminal read` 为空（只有 `terminal show` 的 `preview` 还留着输出）。

## 0.1 准备：一次性规格 worktree

```bash
orca worktree create --repo path:/Users/allan716/orca/implement-spec-split \
  --name smoke-route --base-branch main --json
```

```text
"path": "/Users/allan716/orca/workspaces/implement-spec-split/smoke-route",
"branch": "refs/heads/allanpk716/smoke-route",
"displayName": "smoke-route", "baseRef": "main",
"parentWorktreeId": "d9555660-...::/Users/allan716/orca/implement-spec-split"
```

下文 **P = `/Users/allan716/orca/workspaces/implement-spec-split/smoke-route`**。所有 worker spec 都是极小任务：在 P 根目录创建 `smoke-<编号>.txt`（内容 `ok`），然后 `orca orchestration send --type worker_done --outcome succeeded --report-path <该文件>`。创建前 `orca worktree list` 共 25 条。

## 1. `worker-start --worktree path:P --agent codex`（不带 `--model`）

**命令**

```bash
orca orchestration worker-start \
  --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --agent codex --spec-file /tmp/smoke-brief-1.md --json
orca orchestration check --wait --types worker_done --timeout-ms 30000 --json
```

**关键输出**

```text
{"ok":true,"result":{"dispatchId":"ctx_55ffcf18bfb4","taskId":"task_0f73b46b91a1",
"runId":"run_5996a58b950a","runCreated":true,"state":"ready","agent":"codex",
"mode":"terminal","terminal":"term_c051af42-...","workspace":"d9555660-...::.../smoke-route"}}

worker-show effects:
{"kind":"worktree","action":"reused","id":"d9555660-...::.../smoke-route"},
{"kind":"setup","action":"not_applicable","state":"not_applicable"},
{"kind":"terminal","role":"agent","action":"created","id":"term_c051af42-...","surface":"visible"},
{"kind":"dispatch_input","role":"agent","id":"term_c051af42-...","state":"accepted"}
"setupSource":"existing_worktree"

check --wait:
{"ok":true,"result":{"messages":[{"id":"msg_db7d6b3f5171","type":"worker_done",
"payload":{"taskId":"task_0f73b46b91a1","dispatchId":"ctx_55ffcf18bfb4",
"outcome":"succeeded","reportPath":".../smoke-route/smoke-1.txt"}}]}}
```

**判据：通过。** worktree 数量 25 → 25，P 的 HEAD 仍是 `d75c418`，`effects` 只有 `worktree=reused` / `setup=not_applicable`，新建的只是 agent terminal；`check --wait --types worker_done` 收到 `worker_done` 与 `reportPath`。

**意外**：codex TUI 状态行直接显示 `glm-5.4 high`（来自 `~/.codex/config.toml` 的默认，而非 `--model`）；worker 完成后约 2 分钟自动 release，手动 `worker-release` 返回 `already_released`、terminal 已自动关闭。

## 2. 最关键：`terminal create --command "<launcher>"` + `worker-start --terminal`

### 2.1 `claude-glm --dangerously-skip-permissions --model glm-5.4`

**命令**

```bash
orca terminal create --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --command "claude-glm --dangerously-skip-permissions --model glm-5.4" --json
orca orchestration worker-start --spec-file /tmp/smoke-brief-2.md \
  --terminal term_09b7ded8-6f5a-41fa-8478-038b2002e91e --json
```

**关键输出**

```text
terminal create → handle term_09b7ded8-6f5a-41fa-8478-038b2002e91e（surface=visible）

worker-start:
{"ok":true,"result":{"dispatchId":"ctx_36fa1015f597","taskId":"task_ae95210b48d6",
"runId":"run_5996a58b950a","state":"ready","mode":"terminal",
"terminal":"term_09b7ded8-...","workspace":"d9555660-...::.../smoke-route"}}

TUI 启动横幅:
▐▛████▛█   Claude Code v2.1.309
▝▜██████▀  glm-5.4 · API Usage Billing
⚠ Model "glm-5.4" isn't recognized · context assumed to be 200k tokens
[glm-5.4] │ smoke-route git:(allanpk716/smoke-route*)
```

`/status`（用 `orca terminal send --text "/status" --enter`）：

```text
Anthropic base URL:         https://open.bigmodel.cn/api/anthropic
Model:                      glm-5.4
Setting sources:            User settings, Command line arguments
```

worker 完成后：

```text
worker-show: state=succeeded, stage=settled
"effects":[...,{"kind":"terminal","role":"agent","action":"reused","id":"term_09b7ded8-..."},
           {"kind":"dispatch_input","role":"agent","id":"term_09b7ded8-...","state":"accepted"}]
"launch":{"requested":{"agent":null,"model":null,"effort":null},
          "effective":{"agent":"claude","model":null,"effort":null}}
inbox: msg_1cd3e2737f25 worker_done reportPath=.../smoke-2.txt outcome=succeeded
transcript: 13 × "model":"glm-5.4"
```

**判据：通过。** worker 收到 spec（2.2 的 TUI 截屏里可见注入的 brief 原文；2.1 的 worker 按该 brief 精确完成任务）、创建 `smoke-2.txt`、发出 `worker_done`、Dispatch=`succeeded`；`/status` + 横幅 + transcript 三重确认实际模型是 `glm-5.4`。

### 2.2 `claude-flash --dangerously-skip-permissions --model glm-5.4 --effort high`

**命令**

```bash
orca terminal create --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --command "claude-flash --dangerously-skip-permissions --model glm-5.4 --effort high" --json
orca orchestration worker-start --spec-file /tmp/smoke-brief-2b.md \
  --terminal term_0cad345c-1e64-4d87-ba08-dcd68c5db414 --json
```

**关键输出**

```text
{"ok":true,"result":{"dispatchId":"ctx_30d3e4944a5a","taskId":"task_941c73fb0a74",
"runId":"run_5996a58b950a","state":"ready","mode":"terminal",
"terminal":"term_0cad345c-...","workspace":"d9555660-...::.../smoke-route"}}

TUI 启动横幅:
▝▜██████▀  glm-5.4 with high effort · API Usage Billing

transcript（7722057e-0c64-4f3b-b6a7-0f8da1585ff3.jsonl）:
12 "model":"glm-5.4"
12 "effort":"high"

worker_done: msg_90127737ae26 reportPath=.../smoke-2b.txt outcome=succeeded
worker-show: state=succeeded, stage=settled
```

**判据：通过。** `--model` 与 `--effort high` 都被 Claude CLI 接受并生效（横幅明确写 `with high effort`，transcript 的 `output_config.effort` 也是 `high`）；worker 完成 `smoke-2b.txt` 并发 `worker_done`。

**意外 / 注意**

- `worker-start --terminal` 的 concise receipt **没有 `agent` 字段**（对比第 1 项有 `"agent":"codex"`）；只有 `worker-show --full` 的 `launch.effective.agent` 显示 `claude`，`model`/`effort` 仍是 `null`。
- 对这种「外部创建的 terminal」跑 `worker-release` 返回 `state=retained, reason=external_terminal, processAction=none`，**不会关闭终端**；必须另跑 `orca terminal close --terminal <handle>`（实测 `ptyKilled:true`）。
- 直接传 `--model glm-5.4`（不带 `[1m]`）会触发 Claude Code 的 200k 上下文告警；`~/ops/etc/claude-glm/models.env` 里 `opus`/`sonnet` 档映射的是 `glm-5.4[1m]`，要走 1M 窗口应传 `--model 'glm-5.4[1m]'` 或依赖 `ANTHROPIC_DEFAULT_*_MODEL`。
- 未传 `--effort` 的 claude-glm 会话 transcript 也记录 `effort=high`（opus 档的 Claude Code 默认），所以「effort 生效」的硬证据是 flash 那次横幅的 `with high effort`。

## 3. 未测

- 第 3 项（`codebuddy` 槽位 override 成 `claude-glm`）需改 Orca UI 设置，按要求不测。
- 第 7 项（`--on` 跨机器）禁止任何远程操作，不测。

## 4. `worker-start --agent openclaude --model glm-5.4`

**命令**

```bash
orca orchestration worker-start \
  --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --agent openclaude \
  --model glm-5.4 --spec-file /tmp/smoke-brief-4.md --json
```

**关键输出**

```text
{"ok":false,"error":{"code":"invalid_argument",
"message":"Agent openclaude does not support launch-time model selection.
 Omit --model to run the model from its own config.
 Orchestration mutation request ID: 07aa8710-fd1e-4007-aaf8-9f87b6c59f49.",
"data":{"nextSteps":["Fix the command flags or RPC params exactly as described by the error message.",
"Do not retry the same command unchanged."],
"orchestrationRequestId":"07aa8710-...","originalCommand":[...]}}}
```

**判据：通过（预期拒绝成立）。** 退出码 1；P 下没有生成 `smoke-4.txt`，`run-list`/`inbox` 没有新 dispatch，确实没有启动任何东西。

## 5. 一个 Bash 同步跑 `run-create → worker-start → check --run --wait`

在 P 的一个 Orca terminal 里执行 `bash /tmp/smoke5.sh`（脚本内容即下面三步）：

```bash
RUN_ID=$(orca orchestration run-create --objective "smoke item 5 consumer_fenced probe" --json | jq -r .result.runId)
orca orchestration worker-start --run "$RUN_ID" \
  --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --agent codex --spec-file /tmp/smoke-brief-5.md --json
orca orchestration check --run "$RUN_ID" --wait --types worker_done --timeout-ms 120000 --json
```

**关键输出**

```text
ORCA_TERMINAL_HANDLE=term_b063ac05-d90c-4c1f-8ee6-4ec28fec6e79
{"ok":true,"result":{"runId":"run_28d271f69672","objective":"smoke item 5 consumer_fenced probe"}}
{"ok":true,"result":{"dispatchId":"ctx_99cced11b968","taskId":"task_341c77322b76",
"runId":"run_28d271f69672","state":"ready","agent":"codex","mode":"terminal",
"terminal":"term_7e36119d-...","workspace":"...::.../smoke-route"}}
{"_keepalive":true,"_heartbeat":true,"elapsedMs":15002,"deadlineMs":120000}
{"ok":true,"result":{"messages":[{"id":"msg_d78904230c76","type":"worker_done",
"payload":{"taskId":"task_341c77322b76","dispatchId":"ctx_99cced11b968",
"outcome":"succeeded","reportPath":".../smoke-5.txt"}}]}}
```

**判据：通过，且没有 `consumer_fenced`。** 在 Orca terminal 的普通 Bash 里就能创建并「拥有」Run，`check --run --wait --types worker_done` 阻塞约 15–45s 后直接返回 `worker_done` + `reportPath`；stderr 每 15s 一条 `_keepalive`，需要 `jq "select(._keepalive|not)"` 过滤。`inbox --run run_28d271f69672 --full --json` 同样能读到该消息（只读、不消费）。

## 6. `exec claude-glm -p ...` 让 terminal 随进程退出

### 6.1 `exec` 变体

```bash
orca terminal create --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --command "exec claude-glm -p --model glm-5.4 'reply with the word ok'" --json
orca terminal wait --terminal term_98fc033e-d864-47e3-8732-d7fcc00d0824 \
  --for exit --timeout-ms 120000 --json
orca terminal read --terminal term_98fc033e-d864-47e3-8732-d7fcc00d0824 --json
```

```text
wait: {"ok":true,"result":{"wait":{"condition":"exit","satisfied":true,
      "status":"exited","exitCode":0,"exitCause":{"kind":"unknown","reason":"host_status_unavailable"}}}}
read: status=exited source=stream truncated=false  tail=[]   ← 退出后读不到输出
terminal show.preview:
't recognize the model "glm-5.4", so it assumes a context window of 200k tokens...
[claude-code:unrecognized_model] {"model":"glm-5.4","query_source":"sdk"}
ok
```

**判据：部分通过。** terminal 确实随进程退出，`wait --for exit` 触发并给出 `exitCode: 0`（`read` 的 JSON 确实没有 `exitCode`，只有 `status`，这点与旧报告一致）；但退出后 `terminal read`（stream 与 `--screen` 都试过）返回空 `tail`，只有 `terminal show` 的 `preview` 还保留输出。**要在进程退出前把 stdout 重定向到文件，或用 `--command "...; echo $? > file"` 的非 exec 变体。**

### 6.2 `cmd; echo $? > P/exit-code` 变体

```bash
orca terminal create --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --command 'claude-glm -p --model glm-5.4 "reply with the word ok"; echo $? > /Users/allan716/orca/workspaces/implement-spec-split/smoke-route/exit-code' --json
orca terminal wait --terminal term_89d81c35-e05d-45d3-bae0-7bf209ef7aee \
  --for exit --timeout-ms 5000 --json
```

```text
wait: {"ok":false,"error":{"code":"timeout","message":"timeout"}}   ← shell 还在，符合预期
read: status=running source=stream
... [claude-code:unrecognized_model] {"model":"glm-5.4","query_source":"sdk"}
ok
allan716@allan716deMini smoke-route %
exit-code 文件内容: 0
```

**判据：通过。** 退出码能可靠拿到（`P/exit-code` = `0`）；代价是 shell 不退出、`--for exit` 不会触发，需要轮询退出码文件。

## 8. 非 Orca 管理的普通 git worktree

```bash
git worktree add /tmp/smoke-plain-wt -b smoke-plain main
orca orchestration worker-start --worktree path:/tmp/smoke-plain-wt \
  --agent codex --spec-file /tmp/smoke-brief-8.md --json
```

```text
{"ok":false,"error":{"code":"selector_not_found",
"message":"No workspace matches --worktree path:/tmp/smoke-plain-wt.
 Nothing was started; no effects were applied.",
"data":{"selector":"path:/tmp/smoke-plain-wt",...,"effectsApplied":false}}
```

改用 canonical 路径 `/private/tmp/smoke-plain-wt`（macOS 的 `/tmp` 是符号链接）后：

```text
{"ok":true,"result":{"dispatchId":"ctx_8375ec75aabd","taskId":"task_c92365695223",
"runId":"run_5996a58b950a","state":"ready","agent":"codex","mode":"terminal",
"terminal":"term_54383f7e-...","workspace":"d9555660-...::/private/tmp/smoke-plain-wt"}}
worker_done: msg_d52fb3b08063 reportPath=/tmp/smoke-plain-wt/smoke-8.txt outcome=succeeded
worker-show: state=succeeded
```

**判据：通过（带条件）。** 普通 git worktree 可以直接派发，Orca 会按 `<repo-id>::<canonical path>` 当场生成 workspace id；但 `path:` 必须是 canonical 绝对路径，`/tmp/...` 这种符号链接路径会 `selector_not_found`（且明确 `effectsApplied:false`，不会留下半启动状态）。事后 `orca worktree list` / `worktree ps` 都没有为它留下持久条目。

## 清理

```bash
orca orchestration worker-release --dispatch ctx_55ffcf18bfb4 --json   # already_released
orca orchestration worker-release --dispatch ctx_36fa1015f597 --json   # retained / external_terminal
orca orchestration worker-release --dispatch ctx_30d3e4944a5a --json   # retained / external_terminal
orca orchestration worker-release --dispatch ctx_99cced11b968 --json   # released / closed_agent_terminal
orca orchestration worker-release --dispatch ctx_8375ec75aabd --json   # released / closed_agent_terminal
orca terminal close --terminal term_09b7ded8-6f5a-41fa-8478-038b2002e91e --json
orca terminal close --terminal term_0cad345c-1e64-4d87-ba08-dcd68c5db414 --json
orca terminal close --terminal term_b063ac05-d90c-4c1f-8ee6-4ec28fec6e79 --json
orca terminal close --terminal term_98fc033e-d864-47e3-8732-d7fcc00d0824 --json
orca terminal close --terminal term_89d81c35-e05d-45d3-bae0-7bf209ef7aee --json
orca terminal close --terminal term_978dedb0-9935-4cd1-b0fa-64aa0e138b9d --json
orca worktree rm --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-route \
  --force --delete-branch --json
git worktree remove --force /tmp/smoke-plain-wt   # 有未跟踪 smoke-8.txt，必须 --force
git branch -D smoke-plain
```

说明：`orca worktree rm` 返回 `{"removed":true}`；`allanpk716/smoke-route` 与 `smoke-plain` 两个分支均已删除；P 与 `/tmp/smoke-plain-wt` 目录均已不存在。两条 Run 记录（`run_5996a58b950a`、`run_28d271f69672`）仍留在 Orca 的 `run-list` 里——Run 只是 namespace/mailbox，不占 worktree/terminal，清理清单未要求删除。

## 清理后证据

`git worktree list`（12 条，无 smoke-route / smoke-plain）：

```text
/Users/allan716/orca/implement-spec-split                d75c418 [main]
/Users/allan716/dev/implement-spec-split-v2              9272656 [feat/plugin-lead-worker]
/Users/allan716/dev/implement-spec-split-v2-a            2c52858 [feat/plw-a]
/Users/allan716/dev/implement-spec-split-v2-b            0ca3b8d [feat/plw-b]
/Users/allan716/dev/implement-spec-split-v2-c            fc85c7d [feat/plw-c]
/Users/allan716/orca/implement-spec-split-wt/spec-15-fix c424fe0 [spec-15-fix]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t16 13ce2fe [spec-15-t16]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t17 36c4eda [spec-15-t17]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t18 44b140b [spec-15-t18]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t20 a6f455b [spec-15-t20]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t21 88e71f9 [spec-15-t21]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t22 35c2e58 [spec-15-t22]
```

`orca worktree list`（24 条，无 smoke 条目；格式 `<id>  <branch>  <displayName>`）：

```text
f06fc2ca-7f8c-4888-a876-ef99d0a622f6::/Users/allan716/orca/ferryman    refs/heads/main    main
d9555660-2c89-47f1-a9c5-48aab13b8cef::/Users/allan716/orca/implement-spec-split    refs/heads/main    main
7052adaf-ddd9-48d1-8fb1-5bf639149243::/Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/research_things        research_things
77a1017c-c4aa-4da6-bcce-707126cb8d18::/Users/allan716/orca/ssh-manager-mcp    refs/heads/master    master
77a1017c-c4aa-4da6-bcce-707126cb8d18::/Users/allan716/orca/workspaces/ssh-manager-mcp/galeocerdo    refs/heads/allanpk716/find-next-task    Find next task
ef75c00b-5afa-4b97-8d76-3f7a3ab43efd::/Users/allan716/orca/supplier-profile-mcp    refs/heads/main    main
ba9c4d5d-76de-4ac4-8000-f9a9063ec3b4::/Users/allan716/orca/nexa    refs/heads/master    master
45d464da-02f8-4b99-8d12-b4d1fc886c4c::/Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/文档处理        文档处理
45d464da-02f8-4b99-8d12-b4d1fc886c4c::/Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/文档处理::workspace:219af53c-e8f1-4c62-9972-538b68fdaf0d        11 月绩效
3f53e11f-d6d5-4c3a-abd9-4323b646690b::/Users/allan716/orca/model-convert    refs/heads/fix/40-kit-realmachine    fix/40-kit-realmachine
31bc0fd6-f9ff-41f8-a82c-21099443c8a4::/Users/allan716/orca/agent-taskboard    refs/heads/main    main
d2f4e6bb-b44d-452a-88fb-8891491e3789::/Users/allan716/mnt/nas214/YOLO伪造训练数据实验        YOLO伪造训练数据实验
d73080c5-ff53-45b3-9230-1b0e0df53505::/Users/allan716/orca/algo-eval    refs/heads/master    master
c4353bab-b7b7-473c-bc29-f7fcdd094c9f::/Users/allan716/orca/dl-experiment-skills    refs/heads/main    main
a457ba2f-227f-4e01-b979-09b850c7bf84::/Users/allan716/dev/synthyolo    refs/heads/master    master
0d732018-0bba-434d-b086-4259d6aaa480::/Users/allan716/AutoTasks    refs/heads/master    master
b3d9928d-12c5-4aa0-9ef6-41794af3aaa0::/Users/allan716/orca/oa-helper    refs/heads/master    master
ffc9d55e-1fc1-4abf-a7bf-781a76dc6d52::/Users/allan716/orca/human-res-cost    refs/heads/master    master
deada692-a2c2-4410-862a-2ee3697035c2::/Users/allan716/orca/taskboard-orca-plugin    refs/heads/main    main
713d1b88-83b9-4496-b56e-f7ececa4d36f::/Users/allan716/orca/proxy_pool    refs/heads/master    master
2f8cb0a0-b5f7-4a45-8366-936fa301fffd::/Users/allan716/orca/proxy-hub    refs/heads/main    main
2f8cb0a0-b5f7-4a45-8366-936fa301fffd::/Users/allan716/orca/workspaces/proxy-hub/spec-21    refs/heads/spec-21    spec-21
2f8cb0a0-b5f7-4a45-8366-936fa301fffd::/Users/allan716/orca/workspaces/proxy-hub/spec-22    refs/heads/spec-22    spec-22
50dcc558-bf7d-4c8e-a6bf-dafa43e3064e::/Users/allan716/orca/work-daily-system    refs/heads/main    main
```

`orca terminal list`（12 条，无本次创建的终端；格式 `<handle>  <title>  <worktreePath>  <agentIdentity>`）：

```text
term_fb80992a-12d2-4fe3-b439-bf497c1ea906  查看本机资源使用情况             (global)                                        kimi
term_2743a11e-5755-4fec-860a-a56ea8695ede  Claude Code                       /Users/allan716/orca/work-daily-system             claude
term_ecf5e9b4-0b9d-45b4-9759-ce5a914891c7  rakazo 升级                      /Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/research_things    claude
term_43639236-31d0-493f-bd5e-68d65a42bb9d  Android TV 海报墙视频应用         /Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/research_things    claude
term_7dc32f9c-b937-46b2-a5dd-6b25754bddac  work-daily-system绩效数据源       /Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/文档处理    claude
term_0fb428d9-32fe-4a65-ab98-73883b530263  Execute PROMPT.md instructions    /Users/allan716/AutoTasks                            codex
term_b06d82a5-364a-4d7a-963b-0e722ca57753  Orca 依赖与 agent harness 抽象层  /Users/allan716/orca/implement-spec-split               claude
term_438faba0-e9fc-40a0-ba1d-b5cf2689393d  Claude Code                       /Users/allan716/orca/oa-helper                        pi
term_25c1678f-0ee7-4d5a-bfc8-8c9643afba40  Claude Code                       /Users/allan716/orca/proxy-hub                     openclaude
term_25f5dc7c-521d-4c89-abbb-60a7a8f2d93d  Terminal 1                         /Users/allan716/orca/proxy-hub                     -
term_fdd1efcf-4abf-4c53-9f09-6a8f3c9f253a  Claude Code                       /Users/allan716/orca/human-res-cost                 claude
term_e739cfed-7a68-4f30-9fda-f1ae40ce0c83  ✦ 🐋 一人之下漫画下载渠道         /Users/allan716/Library/CloudStorage/SynologyDrive-MyEmpiricalData/research_things    dsh
```

## 结论对照（对上一轮报告第 4 节）

| # | 不确定点 | 实测结论 |
|---|---|---|
| 1 | `--worktree path:` 是否不新建 worktree、不重跑 setup | **成立**：`worktree=reused`、`setup=not_applicable`、`setupSource=existing_worktree`，只新建 agent terminal |
| 2 | `--terminal` 能否收编 `claude-glm`/`claude-flash` 并注入 spec | **能**：两个 launcher 都完成 `worker_done`，Dispatch=`succeeded`；模型由 launcher CLI 参数决定，Dispatch 不记录 |
| 4 | `--agent openclaude --model` 的确切拒绝 | `invalid_argument: Agent openclaude does not support launch-time model selection. Omit --model...`，exit 1，无副作用 |
| 5 | Bash 同步 `check --wait` 是否 `consumer_fenced` | **不 fenced**：`run-create → worker-start --run → check --run --wait` 在一个 Bash 内直接返回 `worker_done` |
| 6 | `exec` 能否让 terminal 退出并被 `--for exit` 捕获、输出能否读 | 退出与 `exitCode` 可以；退出后 `terminal read` 为空，只有 `terminal show.preview`；`echo $? > file` 可拿退出码 |
| 8 | 普通 git worktree 能否用 `--worktree path:` | **能，但必须 canonical path**：`/tmp/...` → `selector_not_found`；`/private/tmp/...` → 成功并当场收编 |

---

## 第二轮（嵌套与启动开销）

> 日期：2026-11-27 · 主机：mini6（local）· Orca 1.4.274 · 仓库 `/Users/allan716/orca/implement-spec-split`（本地 `main` @ `d75c418`，`origin/main` @ `093c22c`）· Run `run_c617c92e3d42`
> 本轮所有 worker 消息都落在 `run:run_c617c92e3d42`，没有一条投到环境里继承的 `term_b06d82a5-364a-4d7a-963b-0e722ca57753`（见 0.1）。未改 Orca 设置、`~/ops`、`~/.claude`、`~/.codex*`。

### 0. 五条总结

1. **三层嵌套成立，两条路径都能用**：`worker-start --worktree new-child`（从 L1 的终端执行）与 `orca worktree create --parent-worktree path:<L1>` 都把 L2 挂到 L1 下；`orca worktree list --json` 的 `parentWorktreeId` / `childWorktreeIds` 双向一致（L1 的 `childWorktreeIds` 同时列出 L2 与 L2b）。但 `new-child` **不带 `--base-branch` 时新分支落在 `origin/main`（`093c22c`），不是父 worktree 的 HEAD（`d75c418`）**；要「票分支基于集成分支」必须显式 `--base-branch <L1 分支>`。
2. **嵌套 worktree 里收编自定义启动器成功**：在 L2 里 `orca terminal create --command "claude-glm --dangerously-skip-permissions --model glm-5.4 --effort high"` + `worker-start --terminal <handle> --run <id> --spec-file ...`，worker 完成 `smoke-b.txt` 并发出被接受的 `worker_done`；Dispatch `succeeded`，`worker-show --full` 的 `projection.provider` 记为 `claude` / `glm-5.4`（`launch.effective.model` 仍是 `null`，与第一轮一致）。
3. **父级关闭不级联**：释放 L1 的 agent 终端、关闭 L1 的普通 shell、关闭 Run 的协调终端，L2 worktree 与其中正在跑的 worker 都不受影响；`orca worktree rm` L1 会把子 worktree 变成**孤儿**（`parentWorktreeId: null`），既不拒绝也不级联删除。协调终端关闭后 worker 的 `worker_done` 仍进 Run，`inbox --run` 仍可读，新终端 `run-use --id <run>` 可接管。
4. **new-child 的 keepOpenByDefault=true**：receipt 里 `keepOpenByDefault: true` / `keptOpen: true`，`worker-show` 的 `terminalResource.releaseState=retained`、`retainedReason=user_requested`、`autoReleaseAt=null`；`worker-release` 只关终端（`closed_agent_terminal`），worktree 与分支都保留。
5. **claude-glm 精简收益很大、GLM 前缀缓存可命中**：同一个 "reply ok"，默认 18,639 input tokens / 6.2s；`--strict-mcp-config --mcp-config '{"mcpServers":{}}'` 16,518；再加 `--disable-slash-commands --setting-sources ''` 13,845；`--bare` 1,212（-93.5%，1.5s）。第二次相同请求 `cache_read_input_tokens=18,688`（>0），但几分钟后同样的请求又 miss（64）。

### 0.1 消息隔离：先建 Run、用自己的协调终端（两处 `consumer_fenced`）

**命令（失败两步 + 成功两步）**

```bash
# ① 用环境继承的句柄不行：本 shell 被 attest 成 term_b06d82a5，不能冒充别的终端
orca orchestration run-create --objective "..." --from term_c5a1a4a3-b864-4043-afc3-034e8ddd228d --json
# ② 在自建的协调终端里建 Run（用 orca terminal send 送进去执行）
orca terminal create --worktree path:/Users/allan716/orca/implement-spec-split \
  --command "bash" --title "smoke2-coord" --json
orca orchestration run-create --objective "smoke round2 nested worktree launcher release" --json
# ③ 把 Run 绑到 L1 里的自建终端（A 路径 1 需要 caller 在 L1）
orca orchestration run-use --id run_c617c92e3d42 --json
```

```text
① {"ok":false,"error":{"code":"consumer_fenced",
   "message":"This terminal is attested as term_b06d82a5-... and cannot act as term_c5a1a4a3-..."}}
② {"ok":true,"result":{"runId":"run_c617c92e3d42","objective":"smoke round2 nested worktree launcher release"}}
③ {"ok":true,"result":{"runId":"run_c617c92e3d42","objective":"..."}}
   run-current → {"ok":true,"result":{"runId":"run_c617c92e3d42",...}}
```

**判据：通过（带条件）。** 隔离成立，但有两个硬约束：

- `--from <handle>` 不能跨终端冒充：本 shell 的 `ORCA_TERMINAL_HANDLE` 是继承来的 `term_b06d82a5`，`--from` 指到自建终端立即 `consumer_fenced`。
- `worker-start --run <id>` 只认「协调者本人」：在 L1 的普通 shell（非 Run 协调终端）里执行直接被拒——
  `{"ok":false,"error":{"code":"consumer_fenced","message":"worker-start needs the coordinator bound to the Run, or a worker on an active Dispatch in it."}}`。
  解决办法是 `run-use` 把 Run 绑到 L1 里的自建 bash，再用 `orca terminal send --text ... --enter` 把命令送进去执行（本轮全部协调命令都这样跑）。

### A. 三层嵌套

#### A1. 路径 2：`orca worktree create --parent-worktree` 直接建 L1/L2

**命令**

```bash
orca worktree create --repo path:/Users/allan716/orca/implement-spec-split \
  --name smoke-l1 --base-branch main \
  --parent-worktree "id:d9555660-2c89-47f1-a9c5-48aab13b8cef::/Users/allan716/orca/implement-spec-split" --json
orca worktree create --repo path:/Users/allan716/orca/implement-spec-split \
  --name smoke-l2b --base-branch allanpk716/smoke-l1 \
  --parent-worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-l1 --json
```

```text
smoke-l1:  path=.../workspaces/implement-spec-split/smoke-l1
           branch=refs/heads/allanpk716/smoke-l1
           parentWorktreeId=d9555660-...::/Users/allan716/orca/implement-spec-split
           lineage.capture={source:explicit-cli-flag, confidence:explicit}
smoke-l2b: path=.../smoke-l2b  branch=refs/heads/allanpk716/smoke-l2b
           parentWorktreeId=d9555660-...::.../smoke-l1
```

**判据：通过。** `--parent-worktree` 存在且可用，selector 支持 `identity:` / `active` / `id:<repo-id>::<path>` / `branch:` / `issue:` / `path:` / `folder:` / `worktree:`；另有 `--no-parent` 强制无父。L1 的父是协调终端所在的根 worktree，L2b 的父是 L1。

#### A2. 路径 1：从 L1 里的终端 `worker-start --worktree new-child`

**命令**（在 L1 的自建 bash 里执行，该终端已 `run-use` 绑定 Run）

```bash
orca orchestration worker-start --run run_c617c92e3d42 \
  --worktree new-child --name smoke-l2 --agent codex \
  --base-branch allanpk716/smoke-l1 --spec-file /tmp/smoke2/brief-l2.md --json --timeout-ms 120000
```

```text
{"ok":true,"result":{"dispatchId":"ctx_9fa4a8e56970","taskId":"task_4a22cef641a3",
"runId":"run_c617c92e3d42","state":"ready","agent":"codex","mode":"terminal",
"terminal":"term_c8d25618-...","workspace":"d9555660-...::.../smoke-l2","keptOpen":true}}

worker-show effects[0] = {"kind":"worktree","action":"created_child","id":"...::.../smoke-l2","name":"smoke-l2"}
startOptions.baseBranch = "allanpk716/smoke-l1"
```

**判据：通过。** 新 worktree 的 `parentWorktreeId` 是 L1 的 id（见 A3），effects 记 `created_child`，`baseBranch` 记的就是传入的 L1 分支。

#### A3. 三层 parent 关系（`orca worktree list --json`）

```text
.../smoke-l1   refs/heads/allanpk716/smoke-l1   parent=...::/Users/allan716/orca/implement-spec-split
               children=[...::.../smoke-l2, ...::.../smoke-l2b]
.../smoke-l2   refs/heads/allanpk716/smoke-l2   parent=...::.../smoke-l1   children=[]
.../smoke-l2b  refs/heads/allanpk716/smoke-l2b  parent=...::.../smoke-l1   children=[]
```

**判据：通过（数据模型层面）。** 根 → L1 → {L2, L2b} 三层成立，父子双向一致；侧栏 UI 本轮没有视觉确认（CLI 无 UI 访问），以 `parentWorktreeId`/`childWorktreeIds` 为准。`git worktree list` 同时显示三个目录分别在自己的分支上。

#### A4. 意外：`new-child` 的默认 base 是 `origin/main`，不是父 worktree 的 HEAD

同一个 L1 终端里再做一次 new-child，但**不带 `--base-branch`**：

```bash
orca orchestration worker-start --run run_c617c92e3d42 \
  --worktree new-child --name smoke-d2 --agent codex --spec-file /tmp/smoke2/brief-l2.md --json --full
```

```text
新 worktree smoke-d2 的 HEAD = 093c22c（= origin/main）
L1 / 本地 main 的 HEAD = d75c418（比 origin/main 多 2 个提交）
```

**判据：失败（相对「基于 L1 分支」的预期）。** `new-child` 只负责「挂在谁下面」，不负责「基于谁的分支」：不带 `--base-branch` 时它用仓库默认 base（`origin/main`），会丢掉父 worktree 上未推送的提交。A2 里显式 `--base-branch allanpk716/smoke-l1` 才得到 `d75c418`。**要模拟票分支基于集成分支，必须写 `--base-branch`。**

### B. 嵌套 worktree 里收编自定义启动器

**命令**

```bash
orca terminal create --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-l2 \
  --command "claude-glm --dangerously-skip-permissions --model glm-5.4 --effort high" \
  --title "smoke2-l2-glm" --json
orca orchestration worker-start --run run_c617c92e3d42 \
  --terminal term_c70d6217-400e-4069-b8a0-c3b34a01f3e9 \
  --spec-file /tmp/smoke2/brief-b.md --json --timeout-ms 120000
```

```text
TUI 横幅: ▐▛███▛█ Claude Code v2.1.309
          ▝▜██████▀ glm-5.4 with high effort · API Usage Billing
          cwd = ~/orca/workspaces/implement-spec-split/smoke-l2
worker-start: {"ok":true,"result":{"dispatchId":"ctx_4b75841db491","taskId":"task_82261bc37be8",
  "state":"ready","terminal":"term_c70d6217-...","workspace":"...::.../smoke-l2"}}
worker_done: msg_3ce188bac651 → run:run_c617c92e3d42
  payload={"taskId":"task_82261bc37be8","dispatchId":"ctx_4b75841db491",
           "outcome":"succeeded","reportPath":"smoke-b.txt"}
worker-show --full: state=succeeded, stage=settled,
  provider={"id":"claude","model":"glm-5.4"}, workspace=...::.../smoke-l2
```

**判据：通过。** 嵌套 L2 里收编 `claude-glm` 成功，worker 创建 `smoke-b.txt`、发出被接受的 `worker_done`、Dispatch=`succeeded`。`launch.effective.model` 仍是 `null`（与第一轮一致），但 `worker-show --full` 的 `projection.provider` 这次是 `{id:"claude", model:"glm-5.4"}`（从 TUI 状态取到）。

**意外（值得写进 brief 模板）**：spec 里给的 `orca orchestration send --type worker_done --subject ... --outcome ... --report-path ...` 缺 `--task-id`，Orca 拒收并回一条 `Rejected worker_done`（`_orcaLifecycleRejection.code=missing_task_id`）；worker 自己按 preamble 的恢复规则补上 `--from/--task-id/--dispatch-id/--body` 重发才成功（见 G 的 preamble）。**写 brief 时要么照抄 preamble 的完整 send 命令，要么明确「按前言给的完整命令发送」。**

### C. 父级关闭的影响

准备：L2 里起一个长任务 worker（`sleep 180`，dispatch `ctx_6f36c1bb1ff8`），L1 里起一个普通 worker（`ctx_fae900e89249`，完成后 settled）。每步前后对比 `orca worktree list --json`。

#### C1. 关闭 / release L1 的 agent 终端

```bash
orca orchestration worker-release --dispatch ctx_fae900e89249 --json
orca terminal close --terminal term_235d275a-585e-46bd-92d2-598728483041 --json   # L1 的普通 shell
```

```text
release → {"state":"released","processAction":"closed_agent_terminal","archive":"transcript [captured]"}
close   → {"ptyKilled":true}
worktree list 前后一致：smoke-l1 / smoke-l2 / smoke-l2b 都在，parent 关系不变
L2 长任务 worker：state=ready, liveness=live, activity=working（未受影响）
```

**判据：通过。** 父 worktree 的 agent 终端被 release、父 worktree 的普通 shell 被关闭，L2 的 worktree、parent 关系、正在跑的 worker 全部不受影响。

#### C2. `worker-release` / `orca worktree rm` L1

```bash
# 先确认 L2 无未提交内容（git status 干净后）
orca worktree rm --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-l1 --json
```

```text
{"ok":true,"result":{"removed":true}}
之后 worktree list：
  .../smoke-l2   parent=null
  .../smoke-l2b  parent=null
git worktree list 里 smoke-l1 消失，smoke-l2 / smoke-l2b 仍在各自分支
分支 allanpk716/smoke-l1 仍保留（未加 --delete-branch）
```

**判据：通过（行为=孤儿化，不是拒绝也不是级联删除）。** `orca worktree rm` 删父 worktree 时不会因为「有子 worktree」拒绝，也不会删子；子 worktree 被改成顶层（`parentWorktreeId: null`），目录、分支都还在。`worker-release` 只关终端，help 明确「Never deletes the worktree」，实测也如此。

#### C3. 协调终端（Run 的 coordinator）关闭

```bash
orca terminal close --terminal term_583d00c0-3053-4916-ac5f-4f0b22cf12b8 --json
# 长任务 worker 稍后自己跑完并发 worker_done
orca orchestration inbox --run run_c617c92e3d42 --limit 20 --full --json
# 新终端接管
orca terminal create --worktree path:/Users/allan716/orca/implement-spec-split --command bash --title smoke2-coord2 --json
orca orchestration run-use --id run_c617c92e3d42 --json
orca orchestration check --run run_c617c92e3d42 --peek --json
```

```text
close → {"ptyKilled":true}
worktree list 不变；L2 worker 仍 live
inbox --run（协调终端已关）→ 仍有 msg_250033aebf6b worker_done
  payload={"taskId":"task_99f0ed6448ef","dispatchId":"ctx_6f36c1bb1ff8","outcome":"succeeded"}
  to_handle=run:run_c617c92e3d42
run-use → {"ok":true,"result":{"runId":"run_c617c92e3d42",...}}
run-current → 同上；check --run --peek → 返回全部 5 条历史消息（含协调终端关闭后那条）
```

**判据：通过。** 协调终端关闭后：(1) worker 的 `worker_done` 照常进 Run 的 mailbox（`to_handle=run:<id>`）；(2) `inbox --run` 在没有协调者的 shell 里仍可读；(3) 新终端 `run-use --id <run>` 即可接管，`run-current` / `check --run` 都恢复正常。接管命令就是 `orca orchestration run-use`（help 里的「Resume coordinating a Run」），没有单独的 adopt/bind 动词。

### D. keepOpenByDefault 与 release

**命令**

```bash
orca orchestration worker-start --run run_c617c92e3d42 --worktree new-child --name smoke-d2 \
  --agent codex --spec-file /tmp/smoke2/brief-l2.md --json --full --timeout-ms 120000
orca orchestration worker-show --dispatch ctx_9fa4a8e56970 --full --json
orca orchestration worker-release --dispatch ctx_9fa4a8e56970 --json
```

```text
receipt（--full，new-child）: "keepOpenByDefault": true, "keptOpen": true
receipt（concise，new-child）: "keptOpen": true
worker-show: terminalResource.releaseState="retained", retainedReason="user_requested",
             autoReleaseAt=null, ownershipState="owned"
worker-release → {"state":"released","processAction":"closed_agent_terminal",
                  "archive":"transcript [captured]"}
之后：worktree 仍在（branch=allanpk716/smoke-l2，parent 不变，isArchived=false），
      terminal show → orphaned:true，worker-show releaseState=released
对照：path: 起的 worker（ctx_6f36c1bb1ff8）完成约 2 分钟后自动 release（worker-list= released）
      external terminal 起的 worker（ctx_4b75841db491）release 返回 retained/external_terminal，需手动 close
```

**判据：通过。** `keepOpenByDefault=true`（CLI 把它折算成 concise 的 `keptOpen:true`），所以 new-child 的 worker 完成后不会自动关；`worker-release` 只关终端、归档 transcript，**worktree 和分支都保留**（`git worktree list`、`git branch` 都还在）。这与第一轮「path: worker 约 2 分钟自动 release」形成对照。

### E. claude-glm 启动开销与精简

统一命令形态（cwd=仓库根，prompt 固定 `"reply ok"`，stdout 到文件）：

```bash
cd /Users/allan716/orca/implement-spec-split
claude-glm -p "reply ok" --output-format json > /tmp/smoke2/e/e1-1.json
claude-glm -p "reply ok" --output-format json --strict-mcp-config --mcp-config '{"mcpServers":{}}' > /tmp/smoke2/e/e2.json
claude-glm -p "reply ok" --output-format json --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --disable-slash-commands --setting-sources '' > /tmp/smoke2/e/e3.json
claude-glm -p "reply ok" --output-format json --bare > /tmp/smoke2/e/e4.json
```

| # | 变体 | input_tokens | cache_creation | cache_read | output | real | duration_ms | total_cost_usd |
|---|---|---|---|---|---|---|---|---|
| 1 | 默认（第 1 次） | 18,639 | 0 | 64 | 111 | 6.22s | 4,323 | 0.096002 |
| 2 | `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`（第 1 次） | 16,518 | 0 | 128 | 80 | 13.02s | 12,756 | 0.084654 |
| 3 | 2 + `--disable-slash-commands --setting-sources ''` | 13,845 | 0 | 64 | 31 | 5.59s | 5,440 | 0.070032 |
| 4 | `--bare` | 1,212 | 0 | 0 | 3 | 1.54s | 1,396 | 0.006135 |

```text
四次 result 都是 {"type":"result","subtype":"success","is_error":false,"result":"ok"}
modelUsage: canonicalModel=glm-5.4[1m], contextWindow=1000000
```

**判据：通过。** 三个开关都存在且都能降 input tokens：`--strict-mcp-config` -11.4%，再加 `--disable-slash-commands --setting-sources ''` -25.7%，`--bare` -93.5%（18,639 → 1,212），墙钟 6.2s → 1.5s。`--bare` 下 `ANTHROPIC_AUTH_TOKEN` 仍可用（help 说 auth 只认 `ANTHROPIC_API_KEY`，实测 token 环境变量也走通），`--settings` / `--append-system-prompt-file` 仍生效，`claude-glm` 包装不需要改。

**意外 / 注意**

- `--setting-sources ''`（空列表）可用，等于不加载 user/project/local 三个来源；配合 `--disable-slash-commands` 把 input 从 16.5k 降到 13.8k。
- 第 2 组单次 13.0s 是模型侧延迟波动（同组第二次 5.3s），token 数才是稳定指标；每组至少跑了 2 次。
- `--bare` 会跳过 CLAUDE.md 自动发现、hooks、插件同步、LSP、auto-memory；`claude-glm` 的 `--settings`/`--append-system-prompt-file` 是显式传入的，仍然加载。
- 这些 `total_cost_usd` 是 Claude Code 按 `costBasis: unknown` 估的，不是智谱账单。

### F. GLM 前缀缓存

**命令**：E(1) 连续跑两次（间隔约 10 秒），再隔几分钟跑第三次。

```text
第 1 次: input_tokens=18639  cache_creation=0  cache_read_input_tokens=64
第 2 次: input_tokens=15    cache_creation=0  cache_read_input_tokens=18688   ← 命中
第 3 次（约 5 分钟后）: input_tokens=18639  cache_creation=0  cache_read_input_tokens=64  ← 又 miss
e2 第 2 次: input=6,    cache_read=16640    e3 第 2 次: input=21, cache_read=13888
e4(--bare) 第 2 次: input=1212, cache_read=0（短前缀不命中）
```

**判据：通过。** 第二次 `cache_read_input_tokens=18688 > 0`，说明智谱端有隐式前缀缓存：第一次请求的 18.6k 前缀被缓存，第二次只按 15 个新 token 计费。但缓存是异步/短 TTL 的：几分钟后同样请求又回到 `cache_read=64`；`--bare` 的 1.2k 短前缀连续两次都不命中（官方建议重复前缀 500+ tokens 才容易命中）。

**官方文档（联网核对，2026-11-27）**

- 上下文缓存：<https://docs.bigmodel.cn/cn/guide/capabilities/cache>
  - 隐式缓存、自动识别重复前缀，无需手动配置；命中数在 `usage.prompt_tokens_details.cached_tokens`。
  - 计费：新内容按标准价、**缓存命中按优惠价（通常为标准价的 50%）**；**仅适用于标准 API 计费，不包括资源包和 GLM Coding Plan 套餐**。
  - 建议重复前缀 500 tokens 以上；缓存异步生效，「首次请求后稍等片刻再发起后续请求效果更好」。
- API 定价（各模型缓存命中单价）：<https://docs.bigmodel.cn/cn/guide/start/pricing>（例：GLM-5.3 输入 8 元/M、缓存命中 2 元/M；GLM-5.3-Flash 输入 0.8 元/M、缓存命中 0.23 元/M）
- 注意：`claude-glm` 走的是 `open.bigmodel.cn/api/anthropic`（GLM Coding Plan），按上面文档缓存计费**不适用于 Coding Plan 套餐**，所以 `cache_read` 对套餐内用量是「省 token/省延迟」，不一定等于账单打折。

### G. spec 里的斜杠命令

**命令**

```bash
orca orchestration worker-start --agent openclaude \
  --worktree path:/Users/allan716/orca/workspaces/implement-spec-split/smoke-g2 \
  --run run_c617c92e3d42 --spec "/worker-model" --json --timeout-ms 120000
```

```text
worker-start: {"ok":true,"result":{"dispatchId":"ctx_6f6936587c2d","taskId":"task_8d010f930ece",
  "state":"ready","agent":"openclaude","terminal":"term_a6025ddb-...","workspace":"...::.../smoke-g2"}}

TUI 屏幕顺序（terminal read --screen）：
  ... preamble（SUB-DISPATCH、worker-start 示例、reply 示例）...
  ---
  === TASK ===
  /worker-model
  ⏺ Skill(worker-model)
    ⎿  Successfully loaded skill
  ⏺ Reading ~/.claude/projects/.../memory/worker-model-switch.md
    ⎿  $ ~/.claude/skills/implement-spec-split/scripts/worker-model.sh
  ⏺ Worker model：glm-5.4（默认）
    当前就是默认状态，没有启用替代型号。...
  [glm-5.3-flash[1m]] │ smoke-g2 git:(allanpk716/smoke-g2)
```

**判据：通过。** openclaude（`glm-5.3-flash[1m]`）把 spec 当成 slash 命令执行了：模型调用 `Skill(worker-model)`，技能被加载并运行 `worker-model.sh`，最后原样打印开关状态「Worker model：glm-5.4（默认）」。**Orca 注入的 worker preamble 在 spec 前面**，spec 被放进 `=== TASK ===` 块末尾；CLI 本身不把开头的 `/` 当命令展开，是模型读到文本后自己走 Skill 工具。完成后按要求手动 `worker-stop`（`state=stopped, processAction=closed_agent_terminal`），没有发 `worker_done`。

### 清理

```bash
orca orchestration worker-stop   --dispatch ctx_6f6936587c2d --json   # G 的 openclaude
orca orchestration worker-release --dispatch ctx_4b75841db491 --json  # retained / external_terminal
orca orchestration worker-release --dispatch ctx_7261c9ae167a --json  # released / closed_agent_terminal
orca terminal close --terminal term_c70d6217-400e-4069-b8a0-c3b34a01f3e9 --json  # B 的 claude-glm
orca terminal close --terminal term_c5a1a4a3-b864-4043-afc3-034e8ddd228d --json  # 协调终端 1
orca terminal close --terminal term_62a00670-5f8f-4391-b288-376b21fec0d3 --json  # 协调终端 2（接管用）
orca terminal close --terminal term_c5a6568b-69d6-4a11-bec5-8137aca1f7da --json  # D 的临时协调终端
orca worktree rm --worktree path:.../smoke-l2  --delete-branch --json
orca worktree rm --worktree path:.../smoke-l2b --delete-branch --json
orca worktree rm --worktree path:.../smoke-g2  --delete-branch --json
orca worktree rm --worktree path:.../smoke-g1  --delete-branch --json
orca worktree rm --worktree path:.../smoke-d2  --delete-branch --json
orca worktree rm --worktree path:.../smoke-d1  --delete-branch --json
git branch -D allanpk716/smoke-l1
```

说明：`smoke-l1` 的目录在 C2 里已被 `orca worktree rm` 删除，但分支保留，最后用 `git branch -D` 删除；`smoke-d2` 第一次 rm 因 worker 留下的 `smoke-l2.txt`（未跟踪）报 `runtime_error: ... ?? smoke-l2.txt`，`git clean -f` 后重试成功。所有 worker 最终都是 `released`（`ctx_4b75841db491` 的 terminalResource 记录仍是 `retained`，因为它是外部终端，实际已 `terminal close`，`ptyKilled:true`）。Run `run_c617c92e3d42` 仍留在 `run-list`（与第一轮一致，Run 只是 namespace/mailbox）。

### 清理后证据

`git worktree list`（12 条，无 smoke）：

```text
/Users/allan716/orca/implement-spec-split                d75c418 [main]
/Users/allan716/dev/implement-spec-split-v2              9272656 [feat/plugin-lead-worker]
/Users/allan716/dev/implement-spec-split-v2-a            2c52858 [feat/plw-a]
/Users/allan716/dev/implement-spec-split-v2-b            0ca3b8d [feat/plw-b]
/Users/allan716/dev/implement-spec-split-v2-c            fc85c7d [feat/plw-c]
/Users/allan716/orca/implement-spec-split-wt/spec-15-fix c424fe0 [spec-15-fix]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t16 13ce2fe [spec-15-t16]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t17 36c4eda [spec-15-t17]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t18 44b140b [spec-15-t18]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t20 a6f455b [spec-15-t20]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t21 88e71f9 [spec-15-t21]
/Users/allan716/orca/implement-spec-split-wt/spec-15-t22 35c2e58 [spec-15-t22]
```

`git branch --list '*smoke*'`：空（无输出）。

`orca worktree list`：24 条，无 smoke 条目（本轮开始前也是 24 条）；`orca worktree list | grep -i smoke` 无输出。

`orca terminal list`：12 条，无本轮创建的终端（本轮开始前也是 12 条）。

`orca orchestration worker-list --run run_c617c92e3d42`：

```text
ctx_7261c9ae167a  succeeded  released
ctx_6f6936587c2d  stopped    released
ctx_fae900e89249  succeeded  released
ctx_6f36c1bb1ff8  succeeded  released
ctx_4b75841db491  succeeded  retained   ← 外部终端的记账记录，终端已 close（ptyKilled:true）
ctx_9fa4a8e56970  succeeded  released
```

---

## 第三轮（阶段路由表真实冒烟：讨论、审查、诊断、实现、调研起草各切换一次）

> 日期：2026-11-28 · 主机：mini6（local）· Orca 1.4.274 · Claude Code 2.1.332 · codex-cli 0.164.0 · 票 #49（规格 #25 的真实冒烟，经规格 #58 派发）
> 被测的是本机安装的技能与脚本（`~/.claude/skills/implement-spec-split` 软链指向的主 checkout `/Users/allan716/orca/implement-spec-split`）和真实路由表 `~/.claude/state/stage-route`，不是仓库文件。冒烟途中（15:41:14）主 checkout 被别的会话从 `819f816` 快进到 `7a39284`；两个提交之间受测文件只有 `scripts/opus-review.sh` 变了，第 3 节跑的是 `7a39284` 这一份。
> 场地 `allanpk716/iss-e2e-test`（本地 `~/orca/iss-e2e-test`，main @ `cc6c51e`）。证据目录 `~/.cache/implement-spec-split/runs/implement-spec-split-58-20261128-1213/implement-49/evidence/`，每一步的命令原文、回执、屏幕和 transcript 摘录都在里面。
> 路由表是全局的，别的会话随时在派发：每次切换只保留到对应的派发读完路由就还原（第 3、4 节各 7–18 秒；讨论那一次留到 Design session 结束，约 10 分半），清理时与 0.1 记下的表逐字节比对。除为场地 clone 接受一次 Claude Code 的目录信任对话（写进 `~/.claude.json` 的 `projects` 条目）外，未改 Orca 设置、`~/ops`、`~/.claude/settings.json`、hooks；旧开关文件 `~/.claude/state/judgment-model` 没有碰。

### 0. 六条总结

1. **审查、诊断、实现、调研起草各切换一次，下一次派发都按新路由跑，模型与思考强度在多处留痕，报告首部写对。** findings 首行、无头 transcript 的 `effort`、sidecar 的 `route` 与 `launch_command`、`status.json` 和 codex rollout 的 `turn_context` 互相印证；两份 findings 的「需要人取舍」一次写成合格的 `推荐：` 与 `可自动采纳：是|否`。讨论的模型与强度同样生效（`glm-5.4` / `medium`）。
2. **讨论阶段收编启动的三处风险：两处成立，上游技能加载不成立。** 开终端 + `worker-start --terminal` 收编成立，自动切到 Design session 标签、交接后切回成立，handoff 上报被 Orca 接受、主会话收到成立。但 `mattpocock-skills:grill-with-docs` 设了 `disable-model-invocation: true`，Skill 工具拒绝加载，`design-session.sh` 写进 prompt 的首句做不到，Design session 第一步就停下等用户；这次是用户在它的标签里手敲 `/mattpocock-skills:grill-with-docs` 才走完（见 2.1）。
3. **迁移在真机走通**：临时表上，两份未到期的旧状态文件迁出五项、带上到期时间，旧文件按规则删除；已到期的设置不迁入，目录外的设置迁不进、旧文件保留；真实表全程未动。
4. **改回默认后下一次派发恢复**，已经开着的 worker 不受影响（表改回默认后它新的一轮仍是启动时的强度）。
5. **doctor 的两条 matcher 行都是 PASS**，与 `~/.claude/settings.json` 的 `Edit|Write|NotebookEdit|Bash` 一致。doctor 整体退出 1，两个 FAIL 都与 matcher 无关：一个是本机 `~/.claude/CLAUDE.md` 里没有分工标记（标记在 `~/.claude/rules/opus-codex-split.md`），一个是在 claude-glm 会话里跑、环境带着 `DELEGATE_GUARD_DISABLE=1` 让冒烟测试假失败。
6. **场地和工具的几处出入**：`orca terminal create --worktree path:<新 clone>` 报 `selector_not_found`，要先 `orca repo add`；新目录第一次开会话有 Claude Code 的信任对话（默认选中「No, exit」）。另外 #84 之后，flash 会话里 GLM 路由的审查、诊断走会话内子代理（强度未生效），第 3 节的「强度生效」只对出会话形态成立。

### 0.1 准备：起始状态

**命令**

```bash
orca worktree list --json; orca terminal list --json; orca terminal list --include-visual-layouts --json
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh
shasum -a 256 ~/.claude/state/stage-route
gh repo clone allanpk716/iss-e2e-test /Users/allan716/orca/iss-e2e-test
```

**关键输出**

```text
Orca：31 个工作区、25 个终端（之后「无残留」都对照这两份）
~/.claude/state/stage-route（95 字节，无尾换行）
sha256 911078b20d70a0beee3f0b2dff03beeba1e8fc711edf4e1d0e975364bc17393f
design=claude-glm/glm-5.4/high
review=claude-glm/glm-5.4/high
diagnosis=claude-glm/glm-5.4/high
编排（orchestration）：claude-flash / glm-5.3-flash / 启动器默认（锁定，不可改）
讨论（design）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use design=claude/opus/high
调研起草（research）：codex-glm / glm-5.4 / high（默认）
实现（implementation）：claude-glm / glm-5.4 / high（默认）
审查（review）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use review=claude/opus/high
诊断（diagnosis）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use diagnosis=claude/opus/high
```

起始表里讨论、审查、诊断三行本来就是非默认（`claude-glm / glm-5.4 / high`）。所以这三项的「切换一次」是把强度换成 `medium`（不是任何启动器的默认档，「强度生效」才有别于默认值），还原是设回 `high`；实现、调研起草从阶段默认切到非默认，再设回阶段默认。真实表的每次改动都是 `stage-route.sh use …`，也就是 `/grill-router` 第 2 步运行的那条命令。

**判据：通过。** 起始清单与路由表落盘。

### 1. 迁移（只在临时表上）

**命令**

```bash
# 临时目录 <A> 里先放两份未到期的旧状态文件，不放 stage-route
printf 'grill=glm-5.4\ngrill.until=\nreview=glm-5.4\nreview.until=%s\n' $(( $(date +%s) + 3600 )) > <A>/judgment-model
printf 'worker=glm-5.3\nworker.until=\n' > <A>/worker-model
orca repo add --path /Users/allan716/orca/iss-e2e-test --json        # 见下：terminal create 之前必须先做
orca terminal create --worktree path:/Users/allan716/orca/iss-e2e-test --title smoke49-step2-migrate \
  --command "ISS_STAGE_ROUTE_FILE=<A>/stage-route claude-flash --dangerously-skip-permissions" --json
orca terminal send --terminal <handle> --text "/grill-router" --enter --json
# 补充一组（脚本直跑，不起会话）：<B> 里 grill.until 是过去的时间、worker=glm-5.3-flash
ISS_STAGE_ROUTE_FILE=<B>/stage-route bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh
```

**关键输出**

```text
terminal create（repo add 之前）→ {"ok":false,"error":{"code":"selector_not_found",
  "message":"No Orca workspace matched the worktree selector \"path:/Users/allan716/orca/iss-e2e-test\"."}}
repo add → repo id 0457b82d-d0d9-4d8b-a7c5-63eee93ebd21，工作区 0457b82d-…::/Users/allan716/orca/iss-e2e-test（Orca 工作区 31 → 32）
terminal wait --for tui-idle → satisfied:false, blockedReason:"agent-trust-workspace"   ← 信任对话，默认选中「No, exit」
横幅: Claude Code v2.1.332 · glm-5.3-flash[1m] · API Usage Billing · ~/orca/iss-e2e-test · ● high · /effort

/grill-router 之后（会话里跑的是 ~/.claude/skills/implement-spec-split/scripts/stage-route.sh，不带参数）：
stage-route: 已迁移：旧开关 judgment-model 的 grill=glm-5.4 → design=claude-glm/glm-5.4/high
stage-route: 已迁移：旧开关 judgment-model 的 review=glm-5.4 → review=claude-glm/glm-5.4/high@1795855112、diagnosis=claude-glm/glm-5.4/high@1795855112
stage-route: 已迁移：旧开关 worker-model 的 worker=glm-5.3 → research=codex-glm/glm-5.3/high、implementation=codex-glm/glm-5.3/high
stage-route: 旧开关状态文件 <A>/judgment-model 已删除
stage-route: 旧开关状态文件 <A>/worker-model 已删除
编排（orchestration）：claude-flash / glm-5.3-flash / 启动器默认（锁定，不可改）
讨论（design）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use design=claude/opus/high
调研起草（research）：codex-glm / glm-5.3 / high，不会自动切回；切回用 /grill-router use research=codex-glm/glm-5.4/high
实现（implementation）：codex-glm / glm-5.3 / high，不会自动切回；切回用 /grill-router use implementation=claude-glm/glm-5.4/high
审查（review）：claude-glm / glm-5.4 / high，到 2026-11-28 16:38 +08:00 自动切回默认
诊断（diagnosis）：claude-glm / glm-5.4 / high，到 2026-11-28 16:38 +08:00 自动切回默认
（会话的回复把这五行 stderr 和六行状态逐字转述，再空一行说明「这是路由表第一次运行…」）

<A>/stage-route：
design=claude-glm/glm-5.4/high
research=codex-glm/glm-5.3/high
implementation=codex-glm/glm-5.3/high
review=claude-glm/glm-5.4/high@1795855112
diagnosis=claude-glm/glm-5.4/high@1795855112

<B> 组（脚本直跑）：
stage-route: 旧开关 judgment-model 的 grill=glm-5.4 已到期，不迁入
stage-route: 旧开关 worker-model 的 worker=glm-5.3-flash 迁不进 research、implementation：codex-glm/glm-5.3-flash 不在已验证目录，旧文件 <B>/worker-model 保留
stage-route: 旧开关状态文件 <B>/judgment-model 已删除
六行全是默认；<B>/stage-route 写出但是空文件（0 字节）；--print research model 的 stdout 只有 glm-5.4
真实表 sha256：911078b2…（全程不变）
```

**判据：通过。** 五项等于迁移结果，编排行不变，旧文件按 #29 的规则处理：每一项都迁走的文件被删，有一项迁不进的文件保留，已到期的设置不迁入。两处与预期不同：(a) `orca terminal create --worktree path:` 对刚 clone 的目录不当场收编，要先 `orca repo add`（第一轮第 8 项的当场收编是 `worker-start --worktree path:`）；(b) 新目录第一次开会话有信任对话，实现者以用户身份选了「Yes, I trust this folder」。

### 2. 讨论

**命令**

```bash
orca terminal create --worktree path:/Users/allan716/orca/iss-e2e-test --command bash --title smoke49-coord --json
# 协调终端里：bash ~/.claude/skills/implement-spec-split/scripts/lock.sh acquire find-next-supervise --scope repo --owner-pid $$
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use design=claude-glm/glm-5.4/medium
orca terminal create --worktree path:/Users/allan716/orca/iss-e2e-test \
  --command "claude-flash --dangerously-skip-permissions" --title smoke49-flash-main --json
orca terminal send --terminal <flash 主会话> --text "/grill-feature 给 bin/convert.js 加一个可选参数 --precision <0..6>…" --enter --json
orca terminal list --json; orca terminal list --include-visual-layouts --json
orca orchestration worker-show --dispatch <Design session 的 dispatch> --full --json
orca terminal read --terminal <Design session> --screen --json
```

话题里写明「不发布 issue、不 commit / push、handoff 回来后不进 find-next」，又在场地仓库里持着 `find-next-supervise` 锁：两者都是为了不让主会话在场地上起 find-next 的推进模式（它会起草、发布、起实现会话）。这次主会话按话题里的交代没有走到查锁那一步。

**关键输出**

```text
flash 主会话（claude-flash / glm-5.3-flash[1m]）：Write 话题文件 → 后台跑 design-session.sh →
  路由提示（来自脚本 stderr）：本次讨论路由：讨论（design）：claude-glm / glm-5.4 / medium（用户用 /grill-router 设置）

design-session.sh 的 stderr / stdout：
design-session: 本次讨论路由：讨论（design）：claude-glm / glm-5.4 / medium（用户用 /grill-router 设置）：本次 Design session 由 glm-5.4 经 claude-glm 执行
/Users/allan716/.cache/implement-spec-split/design/iss-e2e-test-20261128-1544-feature/handoff.md

run-create.json: {"runId":"run_d2d62237290e","objective":"Design session handoff for iss-e2e-test"}
worker-start.json: {"ok":true,"result":{"dispatchId":"ctx_d08281b3a41c","taskId":"task_470a50ffb797",
  "runId":"run_d2d62237290e","state":"ready","mode":"terminal","terminal":"term_e569df34-…"}}
worker-show --full（收编记录）:
  effects: {"kind":"worktree","action":"reused"}, {"kind":"setup","action":"not_applicable"},
           {"kind":"terminal","role":"agent","action":"reused","id":"term_e569df34-…"},
           {"kind":"dispatch_input","role":"agent","id":"term_e569df34-…","state":"accepted"}
  launch.requested / effective: agent、model、effort 都是 null
  projection.provider: {"id":"claude","model":"glm-5.4[1m]"}
  terminalResource: ownershipState external, releaseState not_requested, autoReleaseAt null

模型与强度：/status → Model: glm-5.4[1m]（这一版的 /status 不显示强度）
  进程命令行: claude --settings ~/ops/etc/claude-glm/settings.json … --dangerously-skip-permissions --model glm-5.4[1m] --effort medium
  transcript fd5ec98c-0155-456b-9f20-095d0217631a：40 条 assistant 记录全是 "model":"glm-5.4"、"effort":"medium"

terminal list --include-visual-layouts（Design session 运行中）:
  activeTabId = 313427d4-…（title "Design session feature"）；标签依次 smoke49-coord、smoke49-flash-main、Design session feature
```

**判据：收编启动通过。** `orca terminal list` 多出终端，`worker-start --terminal` 回执 `state: ready`，effects 是 `terminal reused` + `dispatch_input accepted`；Orca 不记收编终端的模型和强度（`launch.effective` 都是 null，与第一轮 2.1 一致），模型从状态行（provider `glm-5.4[1m]`）取，强度从命令行和 transcript 取。风险 3（自动切到新标签）通过：`--focus` 生效，当前标签是 Design session。

#### 2.1 风险 1：上游技能加载——不通过

Design session 的第一个工具调用：

```text
Skill({"skill":"mattpocock-skills:grill-with-docs"})
→ <tool_use_error>Skill mattpocock-skills:grill-with-docs cannot be used with Skill tool due to disable-model-invocation.
  Ask the user to run /mattpocock-skills:grill-with-docs themselves — it cannot be invoked via the Skill tool.
  Do not replicate this skill's workflow by other means — it is reserved for explicit user invocation.</tool_use_error>
```

它没有绕过去，而是发了一条 escalation（`msg_a81800d5beaf`）就结束了回合，没有发 worker_done；Orca 随后发「Worker stopped without reporting」。用户（这次是实现者）在 Design session 标签里手敲 `/mattpocock-skills:grill-with-docs …` 之后，`mattpocock-skills:grilling` 和 `mattpocock-skills:domain-modeling` 两个子技能经 Skill 工具加载成功，讨论才继续。

根因是 `design-session.sh` 写进 prompt 的首句（「请先用 Skill 工具加载上游技能 ${UPSTREAM}…不要让用户手敲斜杠命令」）与上游技能的标记冲突：`grill-with-docs`、`wayfinder`、`to-spec`、`to-tickets` 的 SKILL.md 都带 `disable-model-invocation: true`，Skill 工具对它们一律拒绝，MAINTAINING「find-next 设计要点」第 6、19 条早有记录。worker 前言排在本消息前面之后首行斜杠命令不再由 CLI 展开，于是换成了 Skill 工具加载（规格 #34），换的时候没有对照上游的标记；`scripts/test-design-session.sh` 断言的正是这句做不到的话。第 3 节的诊断拿这次失败当输入，得出同样的结论和一组具体改法。

#### 2.2 风险 2：handoff 上报被接受、主会话收到并切回——通过（手敲之后）

```text
Design session 的最后一条命令:
  orca orchestration send --from term_e569df34-… --type worker_done --subject "convert CLI --precision 设计已定稿，handoff 已写" \
    --body '…' --task-id task_470a50ffb797 --dispatch-id ctx_d08281b3a41c --outcome succeeded --report-path <运行目录>/handoff.md
check.json（design-session.sh 的 check --run … --take 取到）:
  {"id":"msg_403d5e2edbae","type":"worker_done","payload":{"taskId":"task_470a50ffb797","dispatchId":"ctx_d08281b3a41c",
   "outcome":"succeeded","reportPath":"…/iss-e2e-test-20261128-1544-feature/handoff.md"}}
worker-show: state succeeded, stage settled（dispatch completed 2026-11-28T07:51:29Z）
switch.out: Focused terminal term_515d8495-… (tab ead08247-…).
close.out: Closed terminal tab 313427d4-… (term_e569df34-…).
exit-code: 143      session-wait.out: condition exit satisfied, exitCause {"kind":"operator_close"}
主会话屏幕:
  ⏺ Background command "启动 grill-feature Design session 并后台等待 handoff" completed (exit code 0)
  ⏺ Design session 已完成并交回本会话（退出码 0）。按你的指示，不进入 find-next，就此停下。
    handoff 路径：/Users/allan716/.cache/implement-spec-split/design/iss-e2e-test-20261128-1544-feature/handoff.md
terminal list --include-visual-layouts（交接后）: activeTabId = ead08247-…（smoke49-flash-main），Design session 标签已关
```

**判据：通过。** 带全 `--task-id` / `--dispatch-id` 的 worker_done 被接受，`design-session.sh` 打印 handoff 路径、切回主会话、关掉 Design session 标签并以 0 退出，主会话收到完成通知。

#### 2.3 这一轮另外看到的

- **Design session 停下等人时主会话没有任何提示。** `design-session.sh` 的等待循环用 `check --run … --take` 取走 Run 的全部邮件，只认 reportPath 等于 handoff.md 的 worker_done，其余的不打印就继续等。这次 Design session 自己的 escalation、Orca 的「Worker stopped without reporting」、它讨论第一轮发给协调者的 question（`msg_d97079cd4dd3`）三封都是这样被取走的（Run 信箱里三封都是已读，收件人是 `run:run_d2d62237290e`；`check.json` 每轮覆盖，`check.err` 只有 keepalive）；后台任务的 stderr 只在任务结束时出现在主会话屏幕上。`stage-dispatch.sh` 对同类邮件是逐条打印并退出 8，`design-session.sh` 没有对应处理。发现问题的唯一途径是用户正看着 Design session 标签（这次正是风险 3 保证了这一点）。
- **交接约定第 5 条把 `--outcome` 写死成 `succeeded`**，失败时无法如实上报（Design session 自己在 handoff 里提的）。
- 刚建好的后台终端在 `terminal show` 里是 `orphaned: true`，也不在 `--include-visual-layouts` 的 `visualLayouts` 里；`orca terminal switch` 到它一次之后才正常。判断「当前标签」前要先确认这个工作区的布局已经出现过。
- 主会话有后台 shell 在跑时 `terminal wait --for tui-idle` 一直不满足（等 handoff 的那几分钟都是这样），不能用等它来判断「主会话这一轮说完了」。
- 靠 `exit-code` 判定结束这条路径只见到收尾那一次（终端被关时写下 143）；「没交接就退出」的分支（退出码 7）没有触发。
- mockit 提交、`claude-glm --resume` 续接、map（wayfinder）这次都没有跑。

还原：`stage-route.sh use design=claude-glm/glm-5.4/high`（15:52:35），表回到起始值。

### 3. 审查、诊断

**命令**

```bash
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use review=claude-glm/glm-5.4/medium diagnosis=claude-glm/glm-5.4/medium
bash ~/.claude/skills/implement-spec-split/scripts/opus-review.sh --kind code --input ac93eb6 \
  --out <证据目录>/step4-review/findings-code.md --cwd /Users/allan716/orca/iss-e2e-test --timeout 1500
bash ~/.claude/skills/implement-spec-split/scripts/opus-review.sh --kind diagnose --input <2.1 那次失败写成的失败记录> \
  --out <证据目录>/step4-review/findings-diagnose.md --cwd /Users/allan716/orca/iss-e2e-test --timeout 1200
# 两个进程都起来、读完路由之后：stage-route.sh use review=claude-glm/glm-5.4/high diagnosis=claude-glm/glm-5.4/high
```

`--input ac93eb6` 是测试仓库 HEAD 的父提交（diff 是 `cc6c51e` 一个提交，3 个文件 +14/−1）。

**关键输出**

```text
stderr:
opus-review: the review route is claude-glm / glm-5.4 / medium (set by the user with /grill-router, scripts/stage-route.sh): this review runs on glm-5.4 through 'claude-glm'; official Opus is not called
opus-review: the diagnosis route is claude-glm / glm-5.4 / medium (set by the user with /grill-router, scripts/stage-route.sh): this review runs on glm-5.4 through 'claude-glm'; official Opus is not called
进程命令行（两个）: claude --settings ~/ops/etc/claude-glm/settings.json … -p --model glm-5.4[1m] --effort medium --allowedTools Read Grep Glob Bash(git status:*) …
退出码: code 0（15:56:26）  diagnose 0（15:56:22）；没有触发修复重试

findings-code.md 首行:
路由：审查（review）claude-glm / glm-5.4 / medium · 2026-11-28 15:56:26 +0800
  ## 需要人取舍：1 条，带「推荐：A — …」「可自动采纳：是」
findings-diagnose.md 首行:
路由：诊断（diagnosis）claude-glm / glm-5.4 / medium · 2026-11-28 15:56:22 +0800
  ## 需要人取舍：4 条，每条带「推荐：…」和「可自动采纳：是 | 否 — …」
无头 transcript（entrypoint sdk-cli）: 1b471f99-… 22 条、61133d34-… 44 条，全是 "model":"glm-5.4"、"effort":"medium"
```

诊断的结论是「改 Brief」：启动脚本的 prompt 与上游标记冲突、等待循环丢弃 escalation，并给出七项具体改法（与 2.3 一致）。

**判据：通过。** 启动器、模型、强度生效；两份 findings 首行写对，结论标记一次写成合格的 `推荐：` 与 `可自动采纳：是|否`。这就是已验证目录里 `claude-glm / glm-5.4` 审查、诊断那一格的真实冒烟证据。

**注意**

- 这份 `opus-review.sh` 是主 checkout `7a39284` 的（带 #84 的 `--where / --prompt / --stamp`）。`--where` 的判定是：本会话没设 `CLAUDE_CODE_SUBAGENT_MODEL` 时出会话；换成 flash 会话的设置（`CLAUDE_CODE_SUBAGENT_MODEL=glm-5.4[1m]`、`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`）时，code 和 diagnose 都是 `in-session`。也就是说 flash 会话里 GLM 路由的审查、诊断现在走会话内子代理，强度未生效；本节的「强度生效」只对出会话形态成立。
- 代码审查注明 `gh issue list` 和 `npm test` 被权限系统拒绝（只读工具白名单，设计如此），两个评审子代理显式指定为 `opus`（别名映射到 GLM）。

### 4. 实现、调研起草

#### 4.1 调研起草（`codex-worker.sh --read-only`）

**命令**

```bash
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use research=codex-glm/glm-5.3/medium
bash ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd /Users/allan716/orca/iss-e2e-test --brief <调研 Brief> \
  --run-dir <运行目录>/smoke-research-1 --read-only --time-limit 600 --idle-timeout 300
# worker 起来、读完路由之后：stage-route.sh use research=codex-glm/glm-5.4/high
```

**关键输出**

```text
stderr（也写进运行目录的 stderr.log）:
codex-worker: 阶段路由生效：调研起草（research）：codex-glm / glm-5.3 / medium；复位 /grill-router use research=codex-glm/glm-5.4/high
codex 进程: codex exec --json … -m glm-5.3 … -c model_reasoning_effort=medium
resume.json / status.json: "model":"glm-5.3", "thinking":"medium", "profile":"codex-glm"
status.json: status ok, attempts 1, duration_s 51, read_only true, read_only_violation false, changed_paths []
codex rollout（~/.codex-worker/sessions/2026/11/28/rollout-…-01a22128-….jsonl）: {"type":"turn_context","model":"glm-5.3","effort":"medium"}
退出码 0
```

**判据：通过。** 路由行、`status.json`、codex 自己的 rollout 三处一致，只读没有违规。

#### 4.2 实现（`stage-dispatch.sh dispatch --stage implementation`）

**命令**（在协调终端里；Run 的协调者必须是发起 `worker-start` 的终端，所以派发、等待都敲在它里面）

```bash
git -C /Users/allan716/orca/iss-e2e-test branch spec-14 main          # 派发模块要 --base-branch spec-<n>
orca orchestration run-create --objective "smoke #49 implementation dispatch (route table smoke)" --json
# → run_5a226db6d81b
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use implementation=claude-glm/glm-5.4/medium
# 协调终端里敲：
bash ~/.claude/skills/implement-spec-split/scripts/stage-dispatch.sh dispatch --stage implementation --brief <极小任务的 Brief> \
  --run run_5a226db6d81b --run-dir <运行目录>/smoke-run --parent-worktree /Users/allan716/orca/iss-e2e-test \
  --base-branch spec-14 --repo /Users/allan716/orca/iss-e2e-test --ticket 2
# sidecar 写出 route 之后：stage-route.sh use implementation=claude-glm/glm-5.4/high
# 协调终端里敲：
bash ~/.claude/skills/implement-spec-split/scripts/stage-dispatch.sh wait --sidecar <运行目录>/smoke-run/dispatch-implement-2.json --timeout 600
```

Brief 是「在工作区根目录建一个一行的 `smoke-impl-probe.md`，不 commit、不 push」。

**关键输出**

```text
dispatch 的 stderr: stage-dispatch: 本次派发路由：实现（implementation）：claude-glm / glm-5.4 / medium（用户用 /grill-router 设置）
dispatch exit=0，stdout 是 sidecar 路径
sidecar: "route":{"profile":"claude-glm","model":"glm-5.4","effort":"medium"}
  "launch_command":"claude-glm --dangerously-skip-permissions --model glm-5.4\\[1m\\] --effort medium; echo $? > …/exit-code"
  "bare":false（主 checkout 没有 templates/lean-rules.md，普通启动）
worktree create → /Users/allan716/orca/workspaces/iss-e2e-test/spec-14-t2（分支 spec-14-t2，baseRef spec-14，父是场地工作区）
worker-start.json: {"dispatchId":"ctx_6dbcc2c4e60c","taskId":"task_b4bf0841fbd4","runId":"run_5a226db6d81b","state":"ready","mode":"terminal",…}
worker-show --full: launch.effective {agent: claude, model: null, effort: null}；provider {"id":"claude","model":"glm-5.4[1m]"}
  effects: worktree reused / setup not_applicable / terminal reused / dispatch_input accepted
worker 终端状态行: [glm-5.4[1m]] │ spec-14-t2 git:(spec-14-t2*)      （没有信任对话）
worker transcript adefa3f9-…: 5 条全是 "model":"glm-5.4"、"effort":"medium"
wait: exit=0，stdout 是报告路径；wait.json {"id":"msg_507b7f01aa9b","type":"worker_done","outcome":"succeeded",…}
stage-dispatch.sh verify --run-dir …: 实现 #2 → glm-5.4 / glm-5.4[1m] / 一致（sidecar actual_model 的来源是 status-line）
```

**判据：通过。** 下一次派发按切过的路由执行：sidecar 的 `route` 和 `launch_command`、终端状态行、transcript 一致。worker 19 秒完成，探针文件一行，报告 3 行。

### 5. 改回默认

**命令**

```bash
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use design=claude/opus/high review=claude/opus/high \
  diagnosis=claude/opus/high implementation=claude-glm/glm-5.4/high research=codex-glm/glm-5.4/high
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh            # 以及 --launch <stage> interactive|headless ×5
# 同一秒把默认指向官方 Opus 的三行设回起始值，不让全局表停在 Opus 上：
bash ~/.claude/skills/implement-spec-split/scripts/stage-route.sh use design=claude-glm/glm-5.4/high review=claude-glm/glm-5.4/high diagnosis=claude-glm/glm-5.4/high
# 再派一次调研起草（smoke-research-2）和一次实现（--ticket 3，sidecar 是 dispatch-implement-3.json）
```

**关键输出**

```text
六行全是「默认」，表文件 0 字节；--launch：design / review / diagnosis → claude --model opus --effort high，
  research → codex -m glm-5.4 -c model_reasoning_effort=high，implementation → claude-glm --model glm-5.4[1m] --effort high
调研起草 #2: codex-worker: 阶段路由：调研起草（research）：codex-glm / glm-5.4 / high（默认）
  status.json "model":"glm-5.4","thinking":"high"；rollout {"model":"glm-5.4","effort":"high"}；退出 0
实现 #3: stderr「本次派发路由：实现（implementation）：claude-glm / glm-5.4 / high」；sidecar route {claude-glm, glm-5.4, high}，
  launch_command … --effort high；transcript 73342552-… 12 条 effort high；wait exit=0，msg_950998fdefaa worker_done succeeded
对照（4.2 留着的 worker，起在 claude-glm / glm-5.4 / medium）: 表改回默认之后 /status 仍是 Model: glm-5.4[1m]；
  16:04 再问它一句，transcript 新增的一条仍是 "effort":"medium"
```

**判据：通过。** 改回默认后，下一次派发恢复到阶段默认；已经开着的 worker 不受影响。讨论、审查、诊断的阶段默认是官方 Opus，没有为它们再派一次（不花 Opus 额度），只记了表和启动命令。

### 6. doctor

**命令**

```bash
bash /Users/allan716/orca/implement-spec-split/scripts/doctor.sh      # 主 checkout；doctor 按脚本位置解析路径，等于在主 checkout 里跑
bash <票工作区>/scripts/doctor.sh                                     # 规格 #58 的版本（带 #65 的 install.sh --check），对照用
```

**关键输出**（主 checkout 的 doctor，`7a39284`）

```text
## 阶段 3
[FAIL] 阶段 3 只配置了一半：缺少全局 CLAUDE.md 分工标记 -> 按 docs/setup.md 阶段 3 同步模板
[PASS] hook matcher 覆盖 Edit 和 Write
[PASS] hook matcher 覆盖 Bash
[PASS] delegate-guard.js 存在
[WARN] hook 指向另一个 delegate-guard.js：/Users/allan716/.claude/skills/implement-spec-split/hooks/delegate-guard.js -> …
[FAIL] delegate-guard 冒烟测试未拒绝 15 行 Write -> hook 会静默失效；运行 hooks/test-delegate-guard.js 并检查配置
[WARN] 未注册 subagent-guard hook：flash 主线程仍能开会话内子代理 -> …
PASS 10 / WARN 3 / FAIL 2   退出 1
本机实际 matcher: Edit|Write|NotebookEdit|Bash（/opt/homebrew/bin/node /Users/allan716/.claude/skills/implement-spec-split/hooks/delegate-guard.js）
```

**判据：通过。** #36 落地的两条 matcher 检查在真机给出的结果与本机一致。两个 FAIL 都不是 matcher：

- 「缺少全局 CLAUDE.md 分工标记」：标记 `<!-- opus-codex-division: v1 -->` 在 `~/.claude/rules/opus-codex-split.md` 里，`~/.claude/CLAUDE.md` 没有（模板是 v2）。本机配置与 doctor 的预期不一致。
- 「delegate-guard 冒烟测试未拒绝 15 行 Write」：这次是从 claude-glm 会话里跑的，环境带着启动器导出的 `DELEGATE_GUARD_DISABLE=1`，doctor 的冒烟继承了它；只去掉这一个变量、用同一份输入再跑，得到 `permissionDecision: deny`。在 claude-glm 会话里跑 doctor 会有这一条。

**注意**

- 主 checkout 没有 `install.sh`，它的 doctor 也没有 #65 的接入（这两样只在规格 #58 的分支上）。规格 #58 版 doctor 从票工作区跑时，`install.sh --check` 以自己所在的 checkout 为主 checkout，于是五条技能链都报「软链指错」（WARN），配置期望项 `delegate-guard-matcher` 是 PASS（「已覆盖 Edit|Write|Bash」），`unexecutedLoosenings` 为空。
- doctor 的「技能目录不在 …」「hook 指向另一个 delegate-guard.js」是拿物理路径和 `~/.claude/skills/...` 软链路径按字符串比，从主 checkout 跑也会报。

### 清理

```bash
rm <子工作区>/smoke-impl-probe.md                       # 探针文件各用一条独立的 rm
rm <子工作区>/smoke-impl-probe-2.md
bash ~/.claude/skills/implement-spec-split/scripts/stage-dispatch.sh release --sidecar <运行目录>/smoke-run/dispatch-implement-2.json
bash ~/.claude/skills/implement-spec-split/scripts/stage-dispatch.sh release --sidecar <运行目录>/smoke-run/dispatch-implement-3.json
orca terminal close --terminal term_515d8495-… --json   # flash 主会话
(cd /Users/allan716/orca/iss-e2e-test && bash ~/.claude/skills/implement-spec-split/scripts/lock.sh release find-next-supervise --scope repo --force)
orca terminal close --terminal term_38defa05-… --json   # 协调终端
git -C /Users/allan716/orca/iss-e2e-test branch -D spec-14
rm /tmp/grill-feature-topic-20261128-precision.md
```

说明：两次 `release` 各是 `worker-release`（外部终端，返回 `retained / external_terminal`）→ `terminal close --tab` → `worktree rm --delete-branch`（`removed: true`），子工作区里 Orca 自建的「Terminal 1」随 worktree 一起没了；第 1 节的终端和 Design session 标签在此之前已关。场地 clone 按 Brief 保留（下次复用），它在 Orca 里的登记（`orca repo add` 建的）留着，CLI 只能 hide、删不掉。两条 Run 记录 `run_5a226db6d81b`、`run_d2d62237290e` 和 Design session 的运行目录（含 `handoff.md`）留着，不占终端和工作区。

### 清理后证据

路由表还原为 0.1 记下的表（`cmp` 与 0.1 的副本逐字节一致，sha256 `911078b2…`）：

```text
编排（orchestration）：claude-flash / glm-5.3-flash / 启动器默认（锁定，不可改）
讨论（design）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use design=claude/opus/high
调研起草（research）：codex-glm / glm-5.4 / high（默认）
实现（implementation）：claude-glm / glm-5.4 / high（默认）
审查（review）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use review=claude/opus/high
诊断（diagnosis）：claude-glm / glm-5.4 / high，不会自动切回；切回用 /grill-router use diagnosis=claude/opus/high
```

`git worktree list`（场地仓库，只剩主 checkout；本地分支只有 `main`，工作区干净，远端 `main` 仍是 `cc6c51e`）：

```text
/Users/allan716/orca/iss-e2e-test cc6c51e [main]
```

`orca worktree list`：30 条（0.1 时 31 条）。与 0.1 相比，多的是场地 clone 的登记 `0457b82d-…::/Users/allan716/orca/iss-e2e-test`（clone 保留复用）；少的两条（`…/implement-71/smoke/iss-e2e-test`、`…/implement-spec-split/spec-58-t71`）是并行的票 #71 收走的。`orca worktree list | grep -E 'iss-e2e-test|spec-14'` 只剩这一条登记，`spec-14-t2` / `spec-14-t3` 都不在。

`orca terminal list`：22 条（0.1 时 25 条），差异都是别的会话的；`orca terminal list | grep -E 'iss-e2e-test|smoke49|spec-14'` 无输出。本次开的终端（第 1 节的 `smoke49-step2-migrate`、flash 主会话、协调终端、两个 worker、子工作区里的两个「Terminal 1」）和 Design session 标签全部关闭，`orca agent list` 在场地仓库下没有条目。

`orca orchestration worker-list --run run_5a226db6d81b`：

```text
ctx_4f558b2404f1  succeeded  retained   ← 外部终端的记账记录，终端已关（terminal close --tab）
ctx_6dbcc2c4e60c  succeeded  retained   ← 同上
```

Design session 的 `ctx_d08281b3a41c` 同样是 `succeeded / settled / retained`，它的标签由 `design-session.sh` 关掉。

### 结论对照（票 #49 的七条验收）

| # | 验收标准 | 结论 |
|---|---|---|
| 1 | 五个阶段各切换一次，下一次派发生效、模型与思考强度生效、报告首部写对 | 审查、诊断、实现、调研起草**通过**；讨论的模型、强度和路由行**通过**，但 Design session 的上游技能加载不过（2.1） |
| 2 | 讨论阶段收编启动的三处风险各有明确结论 | 上游技能加载**不通过**；handoff 上报被接受、主会话收到并切回**通过**（用户手敲之后）；自动切到新标签**通过** |
| 3 | 迁移在真机走一遍；目录里审查、诊断那一格的证据补齐 | **通过**（第 1 节、第 3 节） |
| 4 | 结果写进实测记录或规格评论 | 本节 |
| 5 | doctor 的 delegate-guard matcher 检查与本机一致 | **通过**；doctor 整体退出 1，两个 FAIL 与 matcher 无关 |
| 6 | `claude-glm / glm-5.4` 的审查、诊断能写出合格的结论标记 | **通过**（一次写成，没有修复重试） |
| 7 | MAINTAINING「尚未验证的事项」对应条目已清 | 已清路由表冒烟那条；讨论那条改成只剩没跑过的部分和没过的那一点 |
