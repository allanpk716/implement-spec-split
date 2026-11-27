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
