# 今日与池子查询

`buildTodayView()` / `buildPoolView()` 是 UI 与调度结果之间唯一的接口：UI 只消费
查询结果，不自己拼装。三种调度模式的差别全部在这两个函数的分支里。

> 本节从 [架构文档](../architecture.md) §4.1 的"新座位"搬出，口径未改。

**今日视图查询 `buildTodayView()` / 任务池查询 `buildPoolView()`**（application 层）：
聚合 ScheduleResult（可推/逾期）+ 固定时点组 + 例行实例 + 被挑散件 + 散件段
（仅无排序档）五种来源，UI 只消费查询结果；
计划段以 `PoolRow`（任务行 / 周期条目）按日期混排；
**`buildTodayView` 收 `ScheduleMode`**：**无排序**这一档换两件事——今日可推组改按
`Task.manualOrder`（无序号者按 id 升序沉末尾）、插队压顶那一层取消（顺序本身就由人定，
不需要补丁）；另返回 `loose`（全部三无散件，按 `pool_order` → 创建时间排，页底 ⑥）。
**可推组的成员不变**——三档都用提醒锚点筛"今天该看哪几件"（见 [今日清单页](../panels/today.md)）；
`buildPoolView` 收 `hideLoose`（由装配点按 `scheduleMode.isManual` 传）：
这一档不返回散件段，只留 `hiddenLooseCount` 给空状态文案；池子其余照旧是整理序
（`pool_order`），周期条目按发生日期混排在任何一档都一样。
