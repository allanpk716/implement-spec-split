---
name: grill-map
description: 大模块 wayfinder 地图：用户说“开/推进一张地图”“重构大模块”“画 wayfinder 地图”“先到这”或输入 /grill-map 时，开启官方订阅上的 Design session；本技能只跳转、后台等待 handoff.md 再跳回。
---

# grill-map

1. Treat the user's map or idea as `TOPIC`.
2. Use the Write tool to save `TOPIC` verbatim in a new temporary topic file. Do not interpolate it through a shell command.
3. Run this Bash command with `run_in_background: true` and `timeout: 7500000ms` (the script wait cap is 7200000ms):
   `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh map --topic-file <topic-file> --timeout 7200`
   If the command's stderr prints `提醒：本仓库还有 … Design session 没交接：`, relay that reminder verbatim to the user and ask whether to resume the old topic first (with the printed `design-session.sh --attach <运行目录>` command) or continue opening this new one; when the user has already explicitly asked for a new session, relay the reminder and continue without asking.
4. Orca switches to the new Design session tab on launch; tell the user to continue there. Do not answer map questions or poll the run directory. Once the handoff arrives the script switches back to this terminal and closes the Design session tab (`ISS_DESIGN_KEEP_SESSION=1` keeps it open).
5. After the completion notification arrives, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
   - A todo item that implements a Spec always runs through `/implement-spec-split <spec number>` (several Specs: `/find-next`, which starts them through launch-wave). Never create the worktree, write the Brief, or call `codex-worker.sh` / `pi-worker.sh` yourself, whatever the handoff says about workers: the skill does the claim, phase marks, backend choice, review, and landing.
6. On exit code 5, tell the user the Design session is still waiting, then run the `design-session.sh --attach <run-dir> ...` command printed in stderr with the same background Bash parameters. Repeat after every exit code 5, with no limit. On any other non-zero exit, report the script's stderr and stop.
