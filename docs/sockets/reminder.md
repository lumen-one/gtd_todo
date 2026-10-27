# 送达策略与提醒协调者

两个问题分开答：**什么时候真正打扰用户**（`NotificationWindowRule`，与工时产能
解耦）和**单闹钟怎么协调两个提醒源**（`ReminderDispatcher`）。门槛放在算法与服务
那一层，协调者不必知道调度模式。

**NotificationWindowRule（通知时间段）**：与 WorkTimeRule（工时产能，domain）
**解耦**——slack 数学不动，"什么时候真正打扰用户"由它裁决，归 application 层。

- 多段式（默认 9:00–21:00 一段）；空段列表 = 不限制（原样送达）；
- 映射规则：nextReminderAt（或相对档位推算出的时刻）落在段内 → 原样；
  落在段外 → **顺延到下一时段开头（只顺延、不吞掉）**；
  绝对档位（明早 9 点 / 自选）原样响（见 ui-interaction.md）；
- 与工时窗口交集为空属用户自选配置：同样按顺延处理，不报错、不静默丢弃。

**ReminderDispatcher（单闹钟协调者）**：订阅 `scheduleReanchored` →
`alarm.cancel()` → 计算送达时刻（两个提醒源，见下）→ `alarm.scheduleNext()`（带草案）；
订阅 `alarm.fired` → `TaskService.pollReminder()` → `NotificationPort.show(...)`
（带 actions：完成 / 推迟1小时）→ 再排下一站（链路自续）。

**门槛在算法/服务那一层，协调者不必知道模式。** 标准模式下
`ScheduleResult.nextReminderAt` 为 null（除非有任务手动开了提醒），于是 `_reschedule()`
自然算不出软提醒那一站；时点提醒同理——`TaskService.nextPointReminder()` 按同一门槛过滤
（标准模式下只返回手动开了提醒的 fixed 与设了响的周期实例）。
"默认不打扰"因此不需要在通知实现里各写一遍 if，也不会出现"调度算出下一站、通知层再吞掉"
这种两处口径。

**两个提醒源**：

| 源               | 谁                            | 送达时刻                                          | 渠道                                  |
| ---------------- | ----------------------------- | ------------------------------------------------- | ------------------------------------- |
| **Slack 软提醒** | 截止型任务（flex + 截止）       | 经 NotificationWindowRule（段外顺延到下一段开头） | 永远普通通知                          |
| **时点性提醒**   | 开始型到点 + 设了响的周期实例 | 原样响（不受静默段限制）                 | 闹钟模式开 → alarm 渠道 + full-screen |

- 单闹钟取两者中更早的一个（`ScheduleResult.nextReminderAt` vs
  `TaskService.nextPointReminder()`）。**比的是"送达时刻"**：软提醒先按
  NotificationWindowRule 顺延、再参与比较——拿原始锚点去比，会把一个被顺延到
  次日上午的软提醒排在今晚的时点闹钟前面，那一晚的闹钟就会被跳过；
- **`pollReminder` 不可重入**：20 秒 tick 与闹钟回调会同时打进来，而软提醒没有
  `point_fired` 那样的幂等标记——上一次还在跑时这一次直接返回 null
  （少发一条，好过同一件事弹两次）；
- **只到点响一次**：响过写 metadata `point_fired`（持久），改期/推迟会清掉它；
  错过超过 30 分钟（`pointReminderGrace`）不再补响（已知局限见 [architecture.md](../architecture.md) §11）；
- 安卓的"应用被杀"路径：挂闹钟时留下 `ReminderDraft`，到点由原生接收器
  `ReminderReceiver` 自己弹通知（同一 taskId 的通知 id 相同 → Dart 侧再 show 时是替换，
  不会重复）；按钮点击走 `ActionReceiver` → 事件回传（应用不在则入队，启动后 `drainEvents` 补做）。
