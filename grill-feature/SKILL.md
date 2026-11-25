---
name: grill-feature
description: 小功能设计讨论：用户说“grill 一下这个功能”“讨论或设计一个小功能”“这个功能怎么取舍”或输入 /grill-feature 时，开启官方订阅上的 Design session；本技能只跳转、后台等待 handoff.md 再跳回。
---

# grill-feature

1. Treat the user's remaining words as `TOPIC`.
2. Use the Write tool to save `TOPIC` verbatim in a new temporary topic file. Do not interpolate it through a shell command.
3. Run this Bash command with `run_in_background: true` and `timeout: 7500000ms` (the script wait cap is 7200000ms):
   `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh feature --topic-file <topic-file> --timeout 7200`
   If the command's stderr prints `提醒：本仓库还有 … Design session 没交接：`, relay that reminder verbatim to the user and ask whether to resume the old topic first (with the printed `design-session.sh --attach <运行目录>` command) or continue opening this new one; when the user has already explicitly asked for a new session, relay the reminder and continue without asking.
4. Orca switches to the new Design session tab on launch; tell the user to continue there. Do not answer design questions or poll the run directory. Once the handoff arrives the script switches back to this terminal and closes the Design session tab (`ISS_DESIGN_KEEP_SESSION=1` keeps it open).
5. After the completion notification arrives, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
   - Todo items that implement Specs start through launch-wave, which opens an Orca session per Spec with `/implement-spec-split <n>` as its user input. From the repository root run `~/.claude/skills/implement-spec-split/find-next/scripts/launch-wave.sh --repo <owner/name> --only <n>[,<m>...] --apply` (comma-separate several Specs) and relay its result lines verbatim. The Spec lands unattended by default (merge, push and next wave without asking); pass `--no-auto-land` to keep the push confirmation. Do not call implement-spec-split with the Skill tool: it sets `disable-model-invocation` and the call fails. When launch-wave fails or reports a Spec as needing manual start, tell the user to type `/implement-spec-split <n>` themselves. After a Spec starts, this session reports its progress: if `~/.claude/skills/implement-spec-split/scripts/lock.sh status find-next-supervise --scope repo` shows a live holder, say that session is already supervising and stop; otherwise invoke the `find-next` skill with `--watch` (its 总控 section), so landing, decisions and the final summary come back here.
   - Never create the worktree, write the Brief, or call `codex-worker.sh` / `pi-worker.sh` yourself, whatever the handoff says about workers: implement-spec-split does the claim, phase marks, backend choice, review, and landing.
6. On exit code 5, tell the user the Design session is still waiting, then run the `design-session.sh --attach <run-dir> ...` command printed in stderr with the same background Bash parameters. Repeat after every exit code 5, with no limit. On any other non-zero exit, report the script's stderr and stop.
