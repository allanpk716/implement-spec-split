---
name: grill-map
description: 大模块 wayfinder 地图：用户说“开/推进一张地图”“重构大模块”“画 wayfinder 地图”“先到这”或输入 /grill-map 时，开启官方订阅上的 Design session；本技能只跳转、后台等待 handoff.md 再跳回。
---

# grill-map

1. Treat the user's map or idea as `TOPIC`.
2. Use the Write tool to save `TOPIC` verbatim in a new temporary topic file. Do not interpolate it through a shell command.
3. Run this Bash command with `run_in_background: true` and `timeout: 7500000ms` (the script wait cap is 7200000ms):
   `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh map --topic-file <topic-file> --timeout 7200`
4. Tell the user to switch to the Orca Claude Design session and continue there. Do not answer map questions or poll the run directory. The script closes the Design session tab once the handoff arrives (`ISS_DESIGN_KEEP_SESSION=1` keeps it open).
5. After the completion notification arrives, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
   - A todo item that implements a Spec always runs through `/implement-spec-split <spec number>` (several Specs: `/find-next`, which starts them through launch-wave). Never create the worktree, write the Brief, or call `codex-worker.sh` / `pi-worker.sh` yourself, whatever the handoff says about workers: the skill does the claim, phase marks, backend choice, review, and landing.
6. On a non-zero exit, report the script's stderr and stop.
