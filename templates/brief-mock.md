<!--
Mock Brief template (Design session, before to-spec).
Copy it into <run dir>/brief.md, fill every <...>, and delete this comment.
Run codex-worker.sh WITHOUT --read-only and WITHOUT --mcp; the worker only writes under <run dir>/mock/.
Afterwards the Design session reads only mock/manifest.json and calls mockit_submit once with its paths;
it does not open screenshots or HTML.
-->

# Mock：<一句话主题>

## 目标

为下面的界面/交互取舍做 <N> 个可交互的 HTML 候选页面，供用户在手机上对比拍板。你只负责做页面和自检，不负责提交，也不评判哪个更好。

## 方向卡

- **要比的点**：<用户要靠看来决定的问题，例如"筛选放顶部常驻还是收进抽屉">
- **共同前提**：<所有候选都必须一致的部分：数据、文案、品牌色、现有页面结构>
- **候选 A <短名>**：<差异要点，2~4 行>
- **候选 B <短名>**：<差异要点>
- <更多候选，最多 6 个；候选之间要拉开差异，不要只改配色>

参考现有界面：<仓库内相关文件路径，或"无">

## 产出（全部写在 `<run dir>/mock/` 下，别处一个文件都不要改）

1. 每个候选一个**独立的单文件 HTML**：`mock/<字母>-<短名>.html`。CSS/JS 内联，不依赖外网和构建；用假数据把页面填满；不要用 `?variant=` 切换候选，也不要画手机外框。
2. 自检脚本 `mock/check.mjs`：用本机已装的 Playwright（`import { chromium } from '/opt/homebrew/lib/node_modules/@playwright/cli/node_modules/playwright-core/index.mjs'`，已验证能无头启动），按 390×844 的手机视口逐页打开 `file://` 地址，断言以下几点：
   - body 的可见文字超过 50 个字符，且页面上不出现 `<html`、`<script`、`import ` 这类源码文本；
   - `document.documentElement.scrollWidth <= 390`，即没有横向溢出；
   - 方向卡里每个候选的关键交互（<列出要点得通的按钮或手势>）能点通，点完后预期元素可见；
   - 控制台没有报错。
   每页打印一行 `PASS|FAIL <文件> <原因>`；有任何 FAIL 就以非 0 退出。可以顺手存截图，但截图只给人工排错用，不是验收依据。
3. `mock/manifest.json`：
   ```json
   {"title": "<主题>", "variants": [{"label": "A <短名>", "path": "<绝对路径>"}]}
   ```

## 验收

`node <run dir>/mock/check.mjs` 退出码为 0，全部 PASS。跑不过就修页面，直到通过。

## 禁止

- 不要 commit，不要改 `<run dir>/mock/` 以外的任何文件。
- 不要安装或升级依赖；Playwright 不可用就停下来，在报告里说明。
- 不要递归删除目录（不要用 `rm -rf`）。

## 报告（result.md，不超过 30 行）

逐页给出 PASS/FAIL 结果、manifest.json 的路径，以及偏离方向卡的地方和原因。
