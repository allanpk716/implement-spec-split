# Progress board 页面定稿（票 #12）

`board.sh render`（票 #13）的页面规格。2026-11-19 经 mockit 提交 `2rmi6u` 由用户在手机上选定方案 A「卡片」（浅色 iOS 设置页风格），未选的是 B「终端密排」和 C「仪表盘」。

- `home.html`：首页（仓库卡片列表）
- `repo.html`：仓库页（以 oa-helper 为例）

两页数据是写死的 mock：本机真实快照，外加几处为展示补的假状态（demo-parked、Spec #70 中断、迷雾地图、散 Spec #80、stalled worker）。render 照这里的布局和样式生成，数据来自快照。

## 用户批注（必须在 render 中落实）

> 我希望有进度百分比，比如多少张地图的百分比，spec、ticket 一次类推也得有百分比显示。

即：首页每张卡片和仓库页的计数区，地图、Spec、Ticket 三项都显示完成百分比（已关闭 / 总数；总数为 0 时显示「—」），不只 Ticket 一项。mock 里只有 Ticket 有进度条，render 时三项都要有。
