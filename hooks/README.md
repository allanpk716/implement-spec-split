# delegate-guard hook

`delegate-guard.js` 是 Claude Code 的 `PreToolUse` hook，用于拦截超过 10 行的源码修改，让这类工作改由外部 codex worker 处理。文档和配置类文件、10 行以内的小改动会放行；输入异常时也按放行处理，避免 hook 卡住会话。

## 注册

完整的安装步骤（含全局分工规则）见 [docs/setup.md](../docs/setup.md) 第 3 阶段。把 `<you>` 换成你的用户名；macOS / Linux 换成脚本的绝对路径。在 `~/.claude/settings.json` 中加入：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "node C:/Users/<you>/.claude/skills/implement-spec-split/hooks/delegate-guard.js",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

若 `settings.json` 已有 `hooks.PreToolUse`，把上面的 matcher 配置合并到现有数组中即可。

## 例外开关

如需临时允许主模型直接修改源码，可在 `<home>/.claude/state/allow-direct-edit` 写入未来的 ISO 8601 时间或 epoch 秒，例如 `2026-01-01T00:00:00Z`。时间过期或内容无法解析时例外无效。

## 测试

```text
node hooks/test-delegate-guard.js
```

测试会逐项打印 PASS/FAIL，最后输出汇总和 20 次运行的中位耗时；有任何失败时退出码为非 0。
