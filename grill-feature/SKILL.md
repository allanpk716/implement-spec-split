---
name: grill-feature
description: 小功能设计讨论：用户说“grill 一下这个功能”“讨论或设计一个小功能”“这个功能怎么取舍”或输入 /grill-feature 时，开启官方 Opus Design session；本技能只跳转、阻塞等待 handoff.md 再跳回。
---

# grill-feature

1. Treat the user's remaining words as `TOPIC`.
2. Run `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh feature "$TOPIC"`.
3. Tell the user to switch to the Orca Claude Design session and continue there. Stay blocked on the script; do not answer design questions or poll the run directory.
4. On exit 0, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
5. On a non-zero exit, report the script's stderr and stop.
