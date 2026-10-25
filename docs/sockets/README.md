# 插座契约

一个插座 = 一组接口定义 + 它的适配器 + 它的行为契约。这页只做索引：哪个插座
归哪一类、定义在哪一层、契约在哪一页。

[架构文档](../architecture.md) §4 只留接口草图与分工，细节都在这里——改一个
插座时不必读完整份架构文档。

| 类 | 插座 | 定义层 | 契约页 |
|---|---|---|---|
| 计算 | `TaskRepository` / `TaskCodec` / `Scheduler` | domain | [架构文档](../architecture.md) §4.1（接口草图） |
| 计算 | 周期任务 | domain | [routine.md](routine.md) |
| 计算 | 主线 | domain | [mainline.md](mainline.md) |
| 计算 | 支线（任务分组） | domain | [branch.md](branch.md) |
| 计算 | 灵感 / 设置 / 操作流水 | application | [app-ports.md](app-ports.md) |
| 计算 | 今日与池子查询 | application | [views.md](views.md) |
| 交付 | 通知 / 闹钟 / 权限 / 目录选择 + 两平台适配器 | application | [delivery.md](delivery.md) |
| 交付 | 送达策略与提醒协调者 | application | [reminder.md](reminder.md) |
| 同步 | 局域网同步 | application | [sync.md](sync.md) |

## 三条不变的边界

1. **接口在里层，实现在 `platform/`**：domain 与 application 只定义抽象类，不 import
   `dart:io` 与 `package:flutter`（[架构文档](../architecture.md) §2 矩阵）。
2. **只在主引擎装配**：闹钟、通知、操作流水、同步都只有一份；悬浮引擎（第二个
   Flutter 引擎）不挂，否则同一件事会做两遍。见 [delivery.md](delivery.md) 的边界表。
3. **数据一致靠文件**：两个引擎、两个设备之间都不同步内存态，靠 `watch()` →
   `refresh()` 这条既有链路重锚。
