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

## 安装方式

- 技能目录 `~/.claude/skills/implement-spec-split` 就是这个仓库的 git 克隆，在这里改完直接 commit、push。
- 不用软链接，因为 Windows 上软链接很麻烦。

## 尚未验证的事项（首次实跑时检查）

- 技能还没在真实项目上完整跑过一次。
- 不带参数运行时，`sub_issues_summary` 查询列出的 spec 对不对。
- review 时 Standards 和 Spec 两个子代理是否真的跑在 `REVIEW_MODEL` 上，实现子代理是否真的跑在 `IMPLEMENT_MODEL` 上。
- 有 PR 流程的仓库里，draft PR 能不能开出来、最后能不能标成可以 review。

验证过的项目从这里删掉，发现的新问题补到"设计要点"里。
