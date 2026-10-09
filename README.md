# 动态任务调度 Todo

以 Markdown 为任务数据载体、以 Slack（裕度）驱动的本地任务提醒软件。
核心循环：**任务 + 截止时间 + 工作量 + 工作时间 + 用户行为 → 动态提醒**。

> 结构与接口契约（分层、插座、import 矩阵、演进路线）见 [docs/architecture.md](docs/architecture.md)。
> UI 与交互需求（安卓悬浮侧边栏、创建手势、提醒呈现）见 [docs/ui-interaction.md](docs/ui-interaction.md)。
> 结构或接口变更先改契约文档，再改代码。

## 运行

```bash
flutter run -d windows        # 桌面版
flutter test                  # 全部单元测试（算法不依赖 UI，可独立验证）
dart run example/simulation.dart   # 控制台仿真：重放"创建→推迟→干活→临界"全流程
```

## 任务数据（Obsidian 可直接编辑）

任务存放在 `tasks/` 目录（可用环境变量 `GTD_TASKS_DIR` 覆盖），一任务一个 `.md` 文件。
用 Obsidian 把本目录（或整个项目目录）作为 Vault 打开即可直接查看和修改。

约定：**机读字段进 frontmatter，正文归用户，应用只重写 frontmatter，永不碰正文。**

```markdown
---
id: task-001
title: 完成 Agent 调度论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
importance: 3
status: active
snoozed_until: 2026-10-07T17:10   # 可选
created: 2026-10-07T15:30
---

正文随便写：背景、拆解、进展流水……
```

## 调度模型（第一版 SlackScheduler）

对每个未完成任务（全部换算成"工作分钟"，跳过午休/夜间/周末）：

```text
available = WorkTime(now, deadline)        # 距截止的真实可用工时
slack     = available - remainingWork      # 裕度，唯一的压力表
urgency   = remainingWork / available      # 紧急度，多任务排序依据
interval  = clamp(α * slack, min, max)     # 下次提醒间隔，α=0.5, min=30, max=480
nextReminderAt = addWorkMinutes(now, interval)
```

- 推迟不用特殊处理：时间流逝 → slack 变小 → 间隔自动缩短；
- 干活（logWork）→ remainingWork 减小 → 间隔自动变长；
- `urgency > 1`（available < remaining）→ 按期不可行，升级提示改截止/砍范围；
- 已过截止 → overdue，退出提醒循环；
- snooze 到期自动回到 active，重新参与调度。

## 架构

```text
lib/
├── domain/       纯 Dart：Task / Schedule / TimeContext / Reminder
├── repository/   TaskRepository 接口 + Markdown 实现 + Memory 实现
├── scheduler/    Scheduler 接口 + SlackScheduler（可替换：EDF / LST / AI…）
├── application/  TaskService：用户行为 → 重新调度 → 产出 ScheduleResult
├── notification/ NotificationService 接口（实现：UI 弹窗 / 未来系统通知）
└── ui/           Flutter 界面 + AppController（薄胶水）
```

依赖铁律：箭头只能指向更纯粹的层；Markdown / 算法 / 通知都是"朝上插"进接口的实现；
Scheduler 不依赖 UI、Markdown、Notification，时间由外部注入，因此可以无 UI 重放测试。

注意：不要在周期 tick 里无条件调用 `refreshSchedule()`（会不断重锚导致提醒永远到不了）；
只有"事件发生"（操作、提醒到点、文件变更）才重锚。
