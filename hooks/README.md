# delegate-guard hook

`delegate-guard.js` 是 Claude Code 的 `PreToolUse` hook，用于拦截超过阈值（默认 10 行）的源码修改，让这类工作改由外部 codex worker 处理。文档和配置类文件、阈值以内的小改动会放行；输入异常时也按放行处理，避免 hook 卡住会话。

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

## 配置

阈值优先级为项目配置、环境变量、默认值：

1. 从 hook payload 的 `cwd` 开始逐级向上查找 `.claude/delegate-guard.json`，最多 20 级，找到第一个就停止。文件可配置：
   - `{"enabled": false}`：该项目完全不拦截；
   - `{"limit": 30}`：项目阈值为 30，必须是正整数；
   - 两个字段可同时使用。文件无法解析或字段非法时忽略该文件并继续按后续规则判定。
2. 环境变量 `DELEGATE_GUARD_LIMIT`：正整数，默认 10；非法值按未设置处理。
3. 默认值 10。

`DELEGATE_GUARD_HOME` 可指定例外开关和日志使用的 home 目录；未设置时使用 `os.homedir()`。

拒绝提示默认为中文。设置 `DELEGATE_GUARD_LANG=en` 时使用英文提示；其他值按中文处理。

环境变量可以写进 `~/.claude/settings.json` 的 `env` 字段，对所有会话生效，例如：

```json
{
  "env": {
    "DELEGATE_GUARD_LIMIT": "20",
    "DELEGATE_GUARD_LANG": "en"
  }
}
```

例外开关仍然优先于项目配置。hook 内部异常或项目配置非法时仍会放行，并向 `<home>/.claude/state/delegate-guard.log` 追加一行日志；`<home>` 来自 `DELEGATE_GUARD_HOME` 或系统 home。日志超过 1MB 时会先清空再写入，写日志失败不影响 hook 结果。

## 例外开关

如需临时允许主模型直接修改源码，可在 `<home>/.claude/state/allow-direct-edit` 写入未来的 ISO 8601 时间或 epoch 秒，例如 `2026-01-01T00:00:00Z`。时间过期或内容无法解析时例外无效。

## 测试

```text
node hooks/test-delegate-guard.js
```

测试会逐项打印 PASS/FAIL，最后输出汇总和 20 次运行的中位耗时；有任何失败时退出码为非 0。
