# 动态任务调度 Todo

以 Markdown 为任务数据载体、以 Slack（裕度）驱动的本地任务提醒软件。
核心循环：**任务 + 截止时间 + 工作量 + 工作时间 + 用户行为 → 动态提醒**。
排序 = **时间裕度优先**（`risk × importance`）；提醒分**标准（默认，只排列不提醒）/ 完整**两种模式。
Markdown 数据是**双文档**：人写人看的 `tasks.md`，内核算的 `.gtd/<id>.md`。

> 结构与接口契约（分层、插座、import 矩阵、演进路线、文件格式）见 [docs/architecture.md](docs/architecture.md)。
> UI 与交互需求（安卓悬浮侧边栏、创建手势、提醒呈现）见 [docs/ui-interaction.md](docs/ui-interaction.md)。
> 结构或接口变更先改契约文档，再改代码。

## 运行

```bash
flutter run -d windows        # 桌面版
flutter test                  # 全部单元测试（算法不依赖 UI，可独立验证）
dart run example/simulation.dart   # 控制台仿真：重放"创建→推迟→干活→临界"全流程
dart run tool/seed_tasks.dart      # 生成示例任务数据（tasks.md + .gtd/<id>.md）
```

## 任务数据（Obsidian 可直接编辑）

任务存放在 `tasks/` 目录（可用环境变量 `GTD_TASKS_DIR` 覆盖）。
用 Obsidian 把本目录（或整个项目目录）作为 Vault 打开即可直接查看和修改。

**双文档：人写人看的归一个文档，内核算的归另一个文档。**

```text
tasks/
├── tasks.md          ← 人类文档：所有任务都在这里，# 标题分类，一行一条
└── .gtd/<任务id>.md   ← 内核属性文档：应用自己写（任务id/工作强度/优先级/时间裕度/剩余工作量）
```

**人类文档**（`tasks.md`）：人写六个属性——任务名、创建日期、结束日期、完成日期、
备注、标签。**更多的标签 = 更多的属性**：

```markdown
# 工作

- [ ] 任务名 创建 2026-10-11,07:00 结束 2026-10-12,18:00 这是备注。 ##这是标签1 ##这是标签2
- [x] 交房租 创建 2026-10-01,09:00 完成 2026-10-01,09:30 ##生活
```

**内核属性文档**（`.gtd/<任务id>.md`）：应用根据已有属性补上/算出的那部分：

```markdown
---
id: task-001
digest: 7683b0bb       # 行指纹：把这一条和 tasks.md 里那一行对上号
work_intensity: 120    # 工作强度（完成它需要的工时，工作分钟）
remaining_load: 0.75   # 剩余工作量（分数，乘以工作强度才是分钟）
priority: 3            # 优先级 1–5
time_slack: 210        # 时间裕度（工作分钟）
status: active
---
```

约定（详见 [docs/architecture.md](docs/architecture.md) 附录 B）：

- **应用只改人类文档里自己那一行**（插入/打勾/补完成时刻），其余行、标题、空行、
  正文**一字不动**，而且**永不重排行**；
- 人在 Obsidian 里改名/改日期/加删行都能生效：两条文档靠行指纹配对，
  人写的那半边以文档为准，内核那半边（工时/优先级/裕度/剩余量）原样保留；
- **人类文档里不出现任何内核字段**（没有 id、没有裕度、没有优先级噪声）；
- `log`（操作流水）单独一个文档：`tasks/.gtd/log.md`，append-only；
- 软删除 = 内核属性文件移入 `.gtd/.trash/` + 那一行用 `%%…%%` 注释掉（可捞回）；
- 旧的"一任务一文件"格式仍可读：目录里若只有旧文件而没有 `tasks.md`，
  首次读取会自动迁移，旧文件原样挪进 `legacy-tasks/` 存档（不删数据）。

## 调度模型（时间裕度优先 + 两种提醒模式）

对每个未完成任务（全部换算成"工作分钟"，跳过午休/夜间/周末）：

```text
available = WorkTime(now, deadline)            # 距截止的真实可用工时
slack     = available - 剩余工时                # 裕度，唯一的压力表
risk      = slack ≤ 0 ? 1 : exp(-(slack/τ)^γ)  # 非线性误期风险 ∈ (0,1]，τ=480、γ=1
priority  = risk × importance                  # 调度优先级 = 排序键（重要度缺省 3）
interval  = clamp(α * slack, min, max)         # 下次提醒间隔，α=0.5, min=30, max=480
nextReminderAt = addWorkMinutes(now, interval)
```

- **两种提醒模式**（设置页可切，**默认标准模式**）：
  - **标准模式**：只排列不提醒——算法照常算先后，但**不出声**；想被推着走的事，
    在编辑表单里给那一件开『提醒我』；
  - **完整模式**：原方案，凡算法判定该响的都响。
  模式不改清单的分组与顺序，只决定"要不要出声"。
- **裕度优先**：裕度越薄风险越高、越排在前面；**重要度（1–5，缺省 3）是乘数**，
  让重要的事整体前移，却盖不过已经贴住截止的事；
- **为什么风险是非线性的**：线性要给裕度"到哪算 0"凭空定量纲、还会算出负值；
  指数族只要一个尺度 τ，且"裕度还宽时催得少、一薄就陡然变急"正是想要的手感。
  旧算法 `slack.v1`（urgency 排序）留在注册表里做对照；
- 推迟不用特殊处理：时间流逝 → slack 变小 → 间隔自动缩短、风险升高、排序前移；
- 干活（logWork）→ 剩余工时减小 → 间隔自动变长、风险下降；
- `available < 剩余工时` → 按期不可行，升级提示改截止/砍范围；
- 已过截止 → overdue，退出提醒循环；
- snooze 到期自动回到 active，重新参与调度。

`risk`/`priority` 都是算出来的，**不落盘、不进人类文档**（顺序本身就是表达）。
注意同名不同物：算法里的 `priority` 是**调度优先级**（输出），而内核属性文档里的
`priority` 键是**人定的优先级**（= `importance`，缺省 3，是输入）。

## 架构

```text
lib/
├── domain/       纯 Dart：Task / Schedule / TimeContext / Reminder / DomainEvent
├── repository/   TaskRepository 接口 + 双文档 Markdown 实现（人类文档 + 内核属性文档）+ Memory 实现
├── scheduler/    Scheduler 接口 + SlackPriorityScheduler（默认：时间裕度优先）
│                 + SlackScheduler（旧口径，留作对照）+ 注册表 / 影子运行
├── application/  TaskService：用户行为 → 重新调度 → 产出 ScheduleResult
│                 + 周期任务 / 今日视图 / 送达策略 / EventLog（log.md 订阅者）
├── platform/     平台适配器（安卓原生 / 桌面 / 设置与引导落盘）——只有组装点 import
└── ui/           Flutter 界面 + AppController（薄胶水）
```

依赖铁律：箭头只能指向更纯粹的层；Markdown / 算法 / 通知都是"朝上插"进接口的实现；
Scheduler 不依赖 UI、Markdown、Notification，时间由外部注入，因此可以无 UI 重放测试。

注意：不要在周期 tick 里无条件调用 `refreshSchedule()`（会不断重锚导致提醒永远到不了）；
只有"事件发生"（操作、提醒到点、文件变更）才重锚。
