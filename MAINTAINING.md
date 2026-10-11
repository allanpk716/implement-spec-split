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
9. **External worker 用 pi，不用 `claude -p`，也不用 codex。**
   - `claude -p` 接 GLM 跑无头模式，会被检测、被限流，下午高峰期更明显。这是用户实际用下来的经验。
   - codex 依赖本机 cc-switch 代理（`127.0.0.1:15721`），代理不开就用不了。它也不读 `CLAUDE.md`，还加载不了 Claude 插件里的 tdd 技能。另外它的 `workspace-write` 沙箱会拦掉 worktree 里的 commit，因为 commit 要写主仓库的 `.git/worktrees/`，那不在放行范围内。
   - pi 直接连 bigmodel，能读 `CLAUDE.md`，能用 `--skill` 加载 tdd 技能，也没有沙箱。
   - pi 不在智谱公布的 Coding Plan 支持工具名单里，有被风控的可能。用户已经知道并接受。
10. **pi 的 JSON 模式出错时退出码也是 0。**
    - `pi-worker.sh` 不看退出码，而是看事件流里最后一条 assistant 消息的 `stopReason`。
    - 再根据 `errorMessage` 判断错误类型：auth、quota、transient 或 error。
    - 改 wrapper 时别把这一点改回成看退出码。
11. **worker 的自我报告不能信。** `status: ok` 只说明它跑完了、没碰到 API 错误。主代理还要检查三件事：有新 commit、工作区是干净的、集成分支的最新提交已经合进来。最后测试结果以 merger 重跑的为准。
12. **GLM 不可用时不能自动换回 sonnet。** 用 GLM 就是为了省 CC 额度，自动切回去这个目的就没了。碰到 auth、quota 错误，或者重试完还是失败，要先停下来问用户。
13. **merger 一次只能跑一个，GLM worker 最多同时跑 `GLM_MAX_PARALLEL` 个。** 智谱高峰期会限流，所以并发数不能开大。
14. **pi 用 `--no-extensions --no-skills` 启动，只用 `--skill` 加载 tdd 技能。** 这样 Orca 装在 `~/.pi/agent` 下的扩展和 orchestration 技能不会混进 worker。

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

- **L1 连通性**：`scripts/selftest.sh --only L1`。用 `--impl pi` 跑技能时，第 0 步也会执行这个检查。
- **L2 wrapper**：`scripts/selftest.sh`。它会在 `~/.cache/implement-spec-split-selftest/` 下建一个临时仓库和 worktree，让 pi 用 tdd 技能实现一个很小的 ticket，然后检查这几件事：
  - 有新 commit，工作区是干净的，测试我们自己重跑能通过；
  - 运行目录里的文件都在；
  - pi 确实读了 tdd 的 `SKILL.md`。

  另外还会测超时和认证失败两条路径。全部通过就删掉临时目录，失败则保留，方便排查。改了 `pi-worker.sh` 或升级了 pi 以后，都要重跑一遍。
- **L3 端到端**（手动）：
  1. 在 GitHub 上建一个临时的私有仓库，加一个最简单的 Node 项目（只要能跑 `npm test` 就行）。再执行 `/setup-matt-pocock-skills`，让 tracker 用 GitHub。
  2. 开一个 spec issue，下面挂 3 个子 issue，其中 #2 被 #1 阻塞。
  3. 在这个仓库里执行 `/implement-spec-split --impl pi`。
  4. 检查以下几点：
     - 不带参数时，第 0 步能找出这个 spec；
     - 第一批只派发了 #1 和 #3，#1 合并之后才派发 #2；
     - merger 是一个一个跑的；
     - review 的两个子代理用的是 `REVIEW_MODEL`；
     - fix 也是由 pi 来跑的；
     - 最后的报告里列出了每次运行的目录，并且标注了是否在高峰期。
  5. 用 `--impl sonnet` 再跑一遍。这次重点看：实现类的子代理确实用了 `IMPLEMENT_MODEL`，而且全程没有调用 `pi-worker.sh`。

## 安装方式

- 技能目录 `~/.claude/skills/implement-spec-split` 就是这个仓库的 git 克隆，在这里改完直接 commit、push。
- 不用软链接，因为 Windows 上软链接很麻烦。

## 尚未验证的事项（首次实跑时检查）

- 技能还没在真实项目上完整跑过一次。
- 不带参数运行时，`sub_issues_summary` 查询列出的 spec 对不对。
- review 时 Standards 和 Spec 两个子代理是否真的跑在 `REVIEW_MODEL` 上，实现子代理是否真的跑在 `IMPLEMENT_MODEL` 上。
- `--impl pi` 的完整流程（L3）：Brief 是否够用，验收检查能不能拦住不合格的 worker，fix 角色能不能根据 review 报告改对。L1 和 L2 已经在 2026-10-11 通过。
- 有 PR 流程的仓库里，draft PR 能不能开出来、最后能不能标成可以 review。

验证过的项目从这里删掉，发现的新问题补到"设计要点"里。
