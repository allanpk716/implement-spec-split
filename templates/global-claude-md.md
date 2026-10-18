<!--
Global division rules for ~/.claude/CLAUDE.md. Copy everything below the line into
your global CLAUDE.md (append it, or replace an older "交给 codex/PI 写代码" section).
Adjust the two placeholders first:
  - <GLM 代理说明>: how codex reaches GLM on this machine, e.g. "本机 Ferryman 代理 127.0.0.1:15722 上的 GLM"
  - the skill path, if the skill is not cloned to ~/.claude/skills/implement-spec-split
See docs/setup.md, stage 3.
-->

---

## Opus / codex 分工（控制费用）

CC 原生套餐用量不够。Opus 的额度只花在判断上，体量大而判断少的执行交给 codex worker：`codex exec` 走 <GLM 代理说明>，额度充足，由 wrapper 脚本 `codex-worker.sh` 运行。这个 wrapper 能看到进度、会自动判断卡死。

**判断标准**：看两个维度，一是判断密度（做错代价多大、要多少权衡），二是 token 体量（要读写多少源码、日志、输出）。交接本身有固定成本（写 Brief、读结果、审查），所以小任务交出去反而更贵。

|  | 体量小 | 体量大 |
|---|---|---|
| 判断密集 | **我做**：方案讨论、grill、架构取舍、根因判断、审查结论、放行 push/PR | **拆开**：worker 用调查 Brief 搜集事实，我看报告做决定 |
| 判断稀疏 | **我顺手做**：commit、push、无冲突合并、单条命令、≤10 行且根因明确的修改 | **交给 worker**：写功能、修 bug、补测试、重构、批量改文件、跑长测试修到绿、解合并冲突 |

- **硬规则**：对外或不可撤回的动作（push、开 PR、远程服务器操作、删数据、对外发布）一律由我执行或向用户确认，绝不交给 worker。worker 跑在 bypass 模式下，对整台机器有完全权限。
- **定位问题**：需要通读多个文件才能定位时，不要自己读，写调查 Brief 加 `--read-only` 交给 worker，我只看报告。报告不足以下判断时，再针对性地读几处。
- **超过 10 行的源码修改**一律交给 worker，不要用 Edit/Write，也不要用 Bash（`sed`、heredoc）绕过。文档、记忆、配置这类非代码文件不受限。PreToolUse hook `delegate-guard` 会拦截超限的修改。
- **例外**：用户明确说"这个你自己改"，或者问题严重、要求我直接动手时，才由我写大段代码。这时创建 `~/.claude/state/allow-direct-edit`，内容写过期时间（ISO 8601，默认 60 分钟后）。没有用户授权，绝不自行创建。
- **审查分档**：小改动扫一眼 diff 加抽查一条验收命令；涉及并发、安全、数据迁移、公共接口的改动要细审。worker 的"验收证据"不能替代我的抽查。
- **省上下文**：一个任务做完提醒用户 `/clear`；大输出先用 `head`/`grep` 过滤再看；大文件和长日志让 worker 读。

调用方式（脚本都在 `~/.claude/skills/implement-spec-split/scripts/`）：

1. 建运行目录 `~/.cache/codex-runs/<仓库名>-<YYYYmmdd-HHMM>-<简短任务名>/`，把 Brief 写成其中的 `brief.md`。Brief 从模板起草：实现任务用 `~/.claude/skills/implement-spec-split/templates/brief-implement.md`，调查任务用 `brief-investigate.md`。
2. 用 Bash `run_in_background: true` 运行：

   ```bash
   ~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --cwd <目标仓库> --brief <运行目录>/brief.md --run-dir <运行目录> \
     --time-limit 3600 --idle-timeout 600
   ```

   需要 TDD 时加 `--skill <tdd 技能目录>`。调查任务加 `--read-only`：工作区一旦有改动，`status.json` 会标记 `read_only_violation`，退出码为 8（`violation`），这次报告作废，改动要由我检查后处理。
3. 结束后读 `<运行目录>/status.json` 和 `result.md`。

**Brief 要自包含**：写清目标、相关文件路径与行号、根因分析、期望的修改方式、验收标准（要跑哪些测试/命令）、不要碰的范围。worker 读不到我们的对话。Brief 里还要写两条：

- "不要 commit"，因为提交由我来做；
- 不要让它递归删除目录，codex 会拒绝 `rm -rf`。

**看进度**：用户问"进行到哪了"，或者任务跑得比预期久时，运行 `~/.claude/skills/implement-spec-split/scripts/progress.sh <运行目录>`，转述其中的状态（running / finished / dead）、距上次进展的秒数、正在跑的命令和最近的动作。看一次就够，不要循环轮询：卡死由 wrapper 自己检测。

**按 `status.json` 的 `status` 处理**：

- `ok`（退出码 0）：只代表它跑完了，不代表做对了。照常审查。
- `auth` / `quota` / `transient`（2/3/4）：GLM 或代理不可用（`proxy not listening` 表示代理没开）。告诉用户，问是等一会儿还是我自己改。不要自己换方案。
- `timeout`（5）：到了 Time limit。如果已经有改动，用 `~/.claude/skills/implement-spec-split/scripts/codex-worker.sh --resume --run-dir <运行目录>` 续跑一次；第二次还是 timeout，或者根本没有进展，就问用户。
- `stalled`（7）或 `error`（6）：读 `stderr.log` 的末尾和 `result.md`，把失败原因补进 Brief，换一个新的运行目录重跑一次；再失败就问用户。
- `stalled` 但 `result_file` 不为空：codex 其实已经答完了，只是没有收尾。按 `ok` 审查。
- `violation`（8，只在 `--read-only` 时出现）：调查期间工作区被改了。看 `changed_paths`，用 `git diff` 确认改动后，告诉用户并由用户决定如何还原；报告不采信。

**收尾**：

- worker 结束后，我用 `git diff` 审查改动、跑测试。有问题就写一份新的 Brief，内容包括具体意见和"在现有改动基础上修改"，换新的运行目录再交给 worker，直到通过。最后向用户汇报结果。
- 审查通过后，commit / push / 开 PR 由我来做，不交给 worker。
- 设计依据和踩过的坑见 `~/.claude/skills/implement-spec-split/docs/codex-backend.md`。
