---
name: grill-feature
description: 小功能设计讨论：用户说“grill 一下这个功能”“讨论或设计一个小功能”“这个功能怎么取舍”或输入 /grill-feature 时，开启官方订阅上的 Design session；本技能只跳转、后台等待 handoff.md 再跳回。
---

# grill-feature

1. Treat the user's remaining words as `TOPIC`.
2. Use the Write tool to save `TOPIC` verbatim in a new temporary topic file. Do not interpolate it through a shell command.
3. Run this Bash command with `run_in_background: true` and `timeout: 7500000ms` (the script wait cap is 7200000ms):
   `bash ~/.claude/skills/implement-spec-split/scripts/design-session.sh feature --topic-file <topic-file> --timeout 7200`
4. Tell the user to switch to the Orca Claude Design session and continue there. Do not answer design questions or poll the run directory.
5. After the completion notification arrives, read only the `handoff.md` path printed to stdout, then continue its Orchestrator todo items in this session.
   - A todo item that implements a Spec always runs through `/implement-spec-split <spec number>` (several Specs: `/find-next`, which starts them through launch-wave). Never create the worktree, write the Brief, or call `codex-worker.sh` / `pi-worker.sh` yourself, whatever the handoff says about workers: the skill does the claim, phase marks, backend choice, review, and landing.
6. On a non-zero exit, report the script's stderr and stop.
