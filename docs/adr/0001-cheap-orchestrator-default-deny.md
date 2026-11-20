# 便宜 Orchestrator：白名单默认禁止，判断一律上交

为降低成本，主会话和规格会话的 Orchestrator 改由 glm-5.3-flash 驱动（`claude-flash`）。flash 只做白名单内的事：跑脚本并按退出码或状态字段分支、读短的结构化输出、照现成文本写票、转述已备好选项的问题、启动会话/子代理/Opus review、无冲突合并与 commit、逐条执行 findings。白名单外一律上交：源码修改和大量阅读交给 glm-5.3 子代理（flash 一行源码都不写，有 hook 硬拦），结论性判断（根因、取舍、审核结论、能否落地、是否停车）交给 Opus review，需要讨论的开 Design session，对外动作问用户。拿不准交给谁时默认上交 Opus。flash 汇报结论必须注明出自哪份报告，Opus 不可用时停下，不降级。

## Considered Options

- **flash 自己做小判断、小改动（沿用"≤10 行自己改"）**：否决。flash 容易过度自信，小判断出错会在后续波次放大，省下的钱不够抵返工。
- **黑名单（列出禁止事项）**：否决。漏列的情况会被 flash 当作允许；白名单默认禁止，漏列时只是多花一次 Opus。
- **在 GLM 会话里开 `opus` 子代理做审核**：否决。在 GLM 会话里 opus 档映射到 glm-5.3，这样的审核是假的，所以 Opus review 必须在会话外调用官方订阅。

## Consequences

- 规格会话由 launch-wave 以 OpenClaude 槽位（`claude-flash`）启动，不再占用订阅的 Opus Orchestrator；订阅额度只花在 Design session（grill → to-spec → to-tickets）和 Opus review 上。
- Design session 自己 commit 并 push 文档改动（用户已预先授权），flash 不负责推送。
