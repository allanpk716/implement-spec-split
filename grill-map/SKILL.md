---
name: grill-map
description: 大模块 wayfinder 地图：用户说“开/推进一张地图”“重构大模块”“画 wayfinder 地图”“先到这”或输入 /grill-map 时，开启官方 Opus Design session；本技能只跳转、阻塞等待 handoff.md 再跳回。
---

# grill-map

1. Treat the user's map or idea as `TOPIC`.
2. Run `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh map "$TOPIC"`.
3. Tell the user to switch to the Orca Claude Design session and continue there. Stay blocked on the script; do not answer map questions or poll the run directory.
4. On exit 0, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
5. On a non-zero exit, report the script's stderr and stop.
