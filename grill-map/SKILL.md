---
name: grill-map
description: 大模块 wayfinder 地图：用户说“开/推进一张地图”“重构大模块”“画 wayfinder 地图”“先到这”或输入 /grill-map 时，开启官方订阅上的 Design session；本技能只跳转、后台等待 handoff.md 再跳回。
---

# grill-map

1. Treat the user's map or idea as `TOPIC`.
2. Use the Write tool to save `TOPIC` verbatim in a new temporary topic file. Do not interpolate it through a shell command.
3. Run this Bash command with `run_in_background: true` and `timeout: 7500000ms` (the script wait cap is 7200000ms):
   `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh map --topic-file <topic-file> --timeout 7200`
4. Tell the user to switch to the Orca Claude Design session and continue there. Do not answer map questions or poll the run directory.
5. After the completion notification arrives, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
6. On a non-zero exit, report the script's stderr and stop.
