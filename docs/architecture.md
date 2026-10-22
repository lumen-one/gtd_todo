# 架构契约：分层、内核与接口

> 定位：这是写代码时对照的**合同**。结构、内核语义或接口变更必须先改本文件，再改代码。
>
> 题目包含三块：**分层与接口**（§0–§2、§4–§5）、**内核语义**（§3 领域模型与调度
> 算法）、**演进的约束**（§7 守卫、§11 局限）。内核语义写在这里而不是拆出去，是因为
> 这个 app 的架构主体就是那套调度算法——它没有别的家。
>
> 分工：**客户端层的需求见 [ui-interaction.md](ui-interaction.md)**——本文件为它提供
> 结构与插座，对接点 = §3.5 命令清单 + §4.3 送达策略 + §4.1 Scheduler 的 `reminderMode`
> + `buildTodayView` 的 `scheduleMode`（业务层排序口径）；结构冲突以本文件为准，
> 产品行为以 UI 文档为准。**未来方向（还没做、等条件的）见 [roadmap.md](roadmap.md)。**
>
> **存储形态（见 [formats/](formats/README.md)）**：任务数据是**双文档**——
> 人写人看的 `tasks.md`（**一个**文档、`# 标题` 分类、一行一条任务）
>
> + 内核属性文档 `.gtd/<任务id>.md`（应用算的：任务 id、工作强度、优先级、
>   时间裕度、剩余工作量）。两条文档靠**行指纹**对号，人是人类文档唯一作者。
>   **长期任务例外**：工作强度 = '长期'（三无任务的创建缺省）时，上面那些字段
>   全部缺行——这份文档只剩一个任务 id。
>
> **提醒模式（见 §3.1）**：默认**标准模式**——算法照常排出先后
> （时间裕度优先：`risk = f(slack)` **非线性**，`priority = risk × importance`），
> 但**不产出提醒**；个别任务可手动开提醒（metadata `remind`）。**完整模式** = 原方案，
> 算法判定该响的都响。模式是"**门槛**"不是"送达策略"：它决定任务**出不出声**
> （`TaskMetric.reminds` 与结果级的 `nextReminderAt`），与"什么时候允许打扰"
> （§4.3 的通知时间段）各管一段，两者串联而不是互相覆盖。
>
> **调度模式三档（见 §3.1）**：**完整 → 标准 → 无排序**，
> 逐级弱化算法替人做主的程度，一次只能选一个（不是两个独立开关）：
>
> - **标准（默认）**：算法照常排先后，但不产出提醒（个别任务可手动开 `remind`）；
> - **完整**：在标准之上把门槛也放开——算法判定该响的都响；
> - **无排序**：在标准之上把**排序**这一层也去掉——今日可推组的**成员不变**
>   （仍按"锚点落在今天 / 今天到期"准入），只有组内顺序改由人拖（`manual_order`）；
>   另把三无散件铺到今日页最底（⑥ 散件段），任务池只留单件搬回去的那些
>   （`loose_home`，[今日清单页](panels/today.md)）。
>
> 三档**都下沉不到内核**：`Scheduler.schedule` 只知道 `ReminderMode`（门槛），
> 排序是**业务层的查询口径**（`buildTodayView`）——裕度、风险、锚点与间隔、
> 逾期与不可行判定在任何一档里照算，算法没被拆掉，只是不再替人决定谁排前面。

**术语约定**：全文混用同义——**插座 = 端口 = 接口**；**插头 = 适配器 = 实现**；
**客户端** = 从外部调用核心的构件（UI、AI）。

---

## 0. 一句话总纲

**核心 + 插座 + 插头，换件不伤车。**

- **核心**（domain + application）：只讲产品概念（任务、截止期、裕度、提醒），不知道任何具体技术。
- **插座**：由核心定义形状，放在核心这一侧。
- **插头**：Markdown、SQLite、Slack 算法、安卓闹钟、AI……插到插座上的实现。

判断一个概念该不该进核心只有一条标准：**把它换掉，产品还成立吗？**
"裕度、截止期、提醒"成立 → 核心；"Markdown、侧滑栏、LLM"不成立 → 插座 + 插头。

插头有三个方向，规则各不同：

| 方向                 | 角色                       | 规则                                                     |
| -------------------- | -------------------------- | -------------------------------------------------------- |
| 被动的实现往上插     | 存储、算法、通知、闹钟     | 实现核心定义的接口，被注入进核心                         |
| 主动的客户端从外面调 | UI、AI                     | 只通过 Application 的公开 API 进来，产出只能是命令或提案 |
| 平台能力全走插座     | 选目录、精确闹钟、系统通知 | UI 里只见接口名，不见平台名                              |

---

## 1. 分层总览

```text
┌─ 客户端层（只出不进：只能"出"命令/提案，只能"进"状态与事件； ──┐
│            核心不向客户端暴露任何内部写通道）                    │
│   Flutter UI（每平台一个 shell + AppController 门面）  AI 助手  │
└─────────┬──────────────────────────────────┬──────────────────┘
          │       同一套 Application API       │
┌─────────┴──────────────────────────────────┴──────────────────┐
│  Application：TaskService —— 唯一写入口（正典表述见 §3.2 规则 A）│
│  + RoutineService（周期规则；生成的实例仍经 TaskService 写）      │
│  校验规则 → 变更状态 → 发领域事件 → 重锚调度                     │
└─────────┬──────────────────────────────────────────────────────┘
┌─────────┴──────────── Domain（宪法，纯 Dart）──────────────────┐
│  词汇表：Task · Routine · Mainline · ScheduleResult ·           │
│           WorkTimeRule · Clock · DomainEvent                    │
│  计算类插座：TaskRepository · TaskCodec · RoutineRepository ·   │
│              RoutineCodec · MainlineRepository · Scheduler      │
└────┬──────────────┬──────────────┬────────────────────────────┘
     ↑实现           ↑实现           ↑实现
  Markdown/       Slack 算法     （未来 SQLite/EDF/…）
  Memory+…
┌───────────────────────────────────────────────────────────────┐
│  交付类插座（application 定义）：NotificationPort ·            │
│  AlarmPort · FolderPickerPort · PermissionPort                │
└────┬──────────────┬──────────────┬────────────────────────────┘
     ↑实现           ↑实现           ↑实现
  Windows 弹窗    安卓精确闹钟     SAF/系统选目录
                + 系统通知渠道
                + 贴屏把手服务
```

三条依赖铁律：

1. **箭头只能指向更纯粹的层**：UI → Application → Domain；实现依赖接口，永远反向不成立。
2. **写路径唯一**（正典表述在 §3.2 规则 A，此处为引用）。
3. **时间必须注入**：核心不直接调 `DateTime.now()`，时钟从构造传入——这是算法可测试、可仿真的前提。

---

## 2. Import 矩阵（机器可验）

> 本节引用的 Task 等类型定义见 §3.1。

| 这一层的文件                    | 允许 import                        | 禁止 import                                                       |
| ------------------------------- | ---------------------------------- | ----------------------------------------------------------------- |
| `lib/domain/**`                 | 仅 domain 内部                     | flutter、dart:io、任何平台名                                      |
| `lib/scheduler/**`              | domain                             | repository 实现、ui、flutter                                      |
| `lib/repository/` 接口文件      | domain                             | 具体实现                                                          |
| `lib/repository/` 实现文件      | 接口、domain、dart:io              | flutter、scheduler                                                |
| `lib/application/**`            | domain + 各插座（**接口**）        | 任何具体实现（含默认实现的选择）、flutter                         |
| `lib/ui/**`（含 AppController） | application、domain 的**展示类型** | repository/scheduler 具体实现；直接改 Task 字段（见 §3.2 规则 A） |
| `lib/main.dart`                 | 一切（唯一组装点）                 | 业务逻辑                                                          |

- UI 允许 import domain 的**类型**（Task、ScheduleResult）做展示——有意选择的务实例外；
  代价（Task 字段变化会波及 UI）已知并接受。
- **"application 不得 import 具体实现"包含默认值**：`scheduler ?? const SlackScheduler()`
  这类默认选择属于组装点职责。默认实现的选择在 main.dart 组装点，
  `TaskService` 构造函数要求注入 `Scheduler` 接口；`test/architecture_test.dart`
  持续拦截此类回归。application 内部同目录相对 import（含 part 拆分）天然合法，
  不算越线。
- `main.dart` 是全项目唯一允许问"我现在是什么平台"的地方（组装时按平台挑插头），且不写业务逻辑。

---

## 3. Domain 设计

### 3.1 词汇表（所有人共享的类型）

| 类型 | 职责 |
| --- | --- |
| `Task` | 任务事实：id、title、**created（= 人类文档的「创建」，由人类文档持有）**、**deadline（可空：fixed=时点 / flex=截止 / null=散件）**、**estimatedWork（可表达'长期'：三无缺省，标记而非分钟数；长期任务同时没有 remainingWork 与 importance）**、remainingWork、importance、status、snoozedUntil、description、**tags**、**completedAt**、**remindEnabled（metadata `remind`，标准模式下的逐任务提醒开关）**、metadata；**不可变 + copyWith（由编译器强制写路径唯一）**；类型 TaskType 走 metadata 缓冲带 |
| `TaskType` | flex（可推）/ fixed（不可推）/ **routine（周期实例）**——三者的调度与完成语义不同 |
| `Routine` | 周期规则：频率（每天/每周 X）、时点、响不响、启用开关；**不是任务**（住在 `routines.md`），每天生成一个当天实例（TaskType.routine） |
| `Mainline` | 主线：当前在推进的一件大事（同时只有一条在跑）。行为链（`MainlineStep`）是它自己的步骤、**不是任务**；记录（`MainlineLog`）是一段连续日期 + 文字。住在 `tasks/主线.md`（[主线文件](formats/mainline.md)） |
| `MainlineStep` | 行为链的一步：标题、完成时刻（`doneAt`，null = 未完成）、写在这一步上的备注（手写 log 挂在这里） |
| `MainlineLog` | 记录（日历上的"圈"）：起始日 + 结束日（含）+ 文字；可跨周、可与别的圈重叠 |
| `RoutineOccurrence` | 一次具体发生（规则 + 时刻）：任务池计划段插入与日历打点用 |
| `TaskDocument` / `TaskLine` | 人类文档 `tasks.md` 的解析结果：整篇行数组 + 识别出的任务行（行号/小节/行指纹/人类那半边字段） |
| `TaskStatus` | pending / active / snoozed / completed / **overdue（派生，不写入存储）**；只增不改 |
| `WorkTimeRule` / `WorkWindow` | 工时日历：每周工作窗、节假日；`workMinutesBetween`、`addWorkMinutes`、`nextWindowStart`（「到下个工作窗」档位，§3.5）。**由设置驱动**（`work_days` / `work_windows`，设置页「工作时间」），装配时注入、改完经 `updateWorkRule` 换掉；`holidays` 字段留位未接线 |
| `Clock` | 当前时间 `DateTime now()`，构造注入（形态为 `DateTime Function()`） |
| `TaskMetric` | 单任务派生指标：available、slack、**risk（裕度的非线性函数）**、**priority（= risk × importance，排序键）**、urgency、displayStatus、interval、nextReminderAt（**提醒锚点，跨重锚沿用**，§3.1）、**reminds（当前模式下会不会出声）**；计算结果，不持久化 |
| `ScheduleResult` | 一次调度的输出：items（**已排序**：永远按调度优先级排，不知道有"无排序"这一回事）、nextTaskId、nextReminderAt（**下一站"会响"的提醒**，已过模式门槛）、infeasible/overdue 名单；所有算法的统一方言 |
| `ReminderMode` | 提醒**门槛**（内核方言）：**standard**（标准：只排列不提醒，逐任务可手动开）/ **full**（完整：算法判定该响的都响）。进 `Scheduler.schedule` 的入参 |
| `ScheduleMode` | **调度模式**（用户可见的三档，domain）：**full** / **standard**（默认）/ **manual**，逐级弱化算法替人做主的程度；由它派生**内核门槛**（`ScheduleMode.reminderMode`，给 `Scheduler.schedule`）与**业务层排序口径**（`isManual`：今日可推组是否改用手动序）。**定义在 domain（`domain/schedule.dart`），但只被 application 与 UI 消费，`Scheduler` 不认得它** |
| `ReminderEvent` | 到点提醒事件：firedAt + **taskId + kind（soft 软提醒 / point 时点提醒）** + 当时的调度快照 |
| `PointReminder` | 时点性提醒候选（不可推到点 + 设了响的周期实例）：到点时刻 + 目标任务；到点后 30 分钟内仍可补响（`pointReminderGrace`） |
| `DomainEvent` | 领域事件：type、taskId、at、**origin(user/ai/migration/system)** |

调度核心公式（**默认算法 `slack-priority.v1`「时间裕度优先」**，属 domain 词汇的一部分）：

```text
available = workMinutesBetween(now, deadline)      # 跳过休息时间
remaining = estimatedWork × remainingLoad          # = Task.remainingWork（工作分钟）
slack     = available − remaining                  # 时间裕度，唯一的压力表
urgency   = remaining / available                  # >1 → 按期不可行（派生，仍保留展示）
risk      = slack ≤ 0 ? 1 : exp(−(slack/τ)^γ)      # 【非线性】误期风险 ∈ (0,1]
priority  = risk × importance                      # 调度优先级 = 排序键（importance 缺省 3）
interval  = slack ≤ 0 ? minInterval
          : α·slack ≤ pivot ? clamp(α·slack, min, pivot)
          : pivot·(1 + log₂(α·slack / pivot))      # 提醒节奏（工作分钟），分两段
nextReminderAt = 沿用旧锚点（仍有效时）否则 addWorkMinutes(now, interval)
默认：τ=480（1 个工作日的裕度换 e⁻¹ 的风险）、γ=1、α=0.5、minInterval=30、pivot=480
```

- **`maxInterval` 是拐点不是硬顶**：`α·slack` 撞到 480 之前按裕度线性缩短；
  超过之后每翻一倍裕度加一个拐点（对数放缓）。硬顶会让"裕度 3 天"和"裕度 3 个月"
  的任务拿到同一个间隔 —— 也就是每件远期任务每天响一次，任务一多就是几十条通知。

- **锚点跨重锚沿用**（`TaskService._anchors`）：`schedule` 收一个
  `anchors: Map<taskId, DateTime>` 入参，同一件任务的
  `deadline` / `status` / `snoozedUntil` 没变就**沿用上次算出的锚点**，只有它自己
  变了（改期 / 推迟 / 恢复）或旧锚点已迟到超过 30 分钟才按 `now + interval` 重算。
  没有这一层的话，每条命令（哪怕与它无关）都会把它的提醒往后推一格：
  用户越勤快地完成小事、拖顺序，最该响的那件越响不起来（C2 只管住了 tick 那一路）。
  锚点是**计算结果**、不落盘，进程重启后重新起算。

- **'长期'不进这套公式**：工作强度 = '长期'的任务没有截止，本来就被 B1/B2
  挡在派生之外；把它们塞进公式只会逼出一个假装精确的 risk——那正是'长期'要避免的。

- **裕度优先**：谁的风险高谁排前面；`importance`（人的优先级，1–5，缺省 3）是**乘数**，
  让"重要的事"整体前移。乘数最多 5 倍，而 `risk` 从 1 掉到 1/e 只要 τ 分钟裕度
  ——所以它盖得过 τ 以内的裕度差，越往后越盖不动；**已经注定误期的（infeasible）
  不跟它比**，单独一档排在前面（见下面的排序）；

- **风险是非线性的**：线性 f 要给 slack 凭空规定"到哪算 0"、还会算出负数；
  指数族只要一个尺度 τ，且恒落在 (0,1]：**裕度还宽时催得少，裕度一薄就陡然变急**。
  γ>1 = 裕度充足时把风险压得更低（更平）、裕度一薄就迅速冲到 1（更陡）——
  "到点前才慌"的那类人；

排序：**四档**——`infeasible` → `normal` → `overdue` → `snoozed`；
前两档内按 **priority 降序**（deadline 升序、id 升序裁决），overdue 退出提醒循环。
不可行是"已经注定误期"，必须排在"还来得及"的前面等用户裁决（B2），
所以它单独一档，不靠 `risk` 去挤——`risk` 在 `slack ≤ 0` 处饱和成 1，
和"刚好贴线"分不开，再乘上 importance 还容易被重要任务压下去。

**无排序（第三档）**：这一层**完全不属于内核**——`Scheduler.schedule`
不收任何排序口径，`ScheduleResult.items` 在任何一档都按上面的排序键排。
`ScheduleMode.manual` 只让**业务层**（`buildTodayView`）不再采用这个顺序：
今日可推组改按 `manual_order`（metadata，没序号的按**id 升序**沉在末尾，
即"创建先后"作稳定裁决）。

关掉的只有**"今日清单里谁排前面"**这一件事：

- **成员不变**：可推组仍按"锚点落在今天 / 今天到期"准入（[今日清单页](panels/today.md)），
  无排序**不是**把所有有截止的任务都塞进今天；唯一新增的是页底 ⑥ 散件段——
  三无散件从任务池搬过来（`buildPoolView` 这一档只返回 `loose_home: pool` 的那些，
  `buildTodayView` 反过来只收没标 `pool` 的：同一件在无排序档只有一个家）。
  **这一档不跑定期挑**，⑤ 被挑散件随之不出现；
- **数学不变**：`slack` / `risk` / `priority` 照算，逾期（B1）与不可行（B2）判定、
  提醒锚点与间隔、提醒门槛（B4）**全部不变**——它们管"多久响一次""要不要升级"
  "出不出声"，不是"谁排前面"；
- **任务池的计划段不变**：池子本来就是手动整理序（`pool_order`），没有算法排序可言，
  周期条目按发生日期混排照旧；搬走的只有散件段。

**提醒门槛（两个模式）**：`reminderAllowed(task, mode)` 不成立时这一件**不出声**
——`TaskMetric.reminds = false`、`reminderAt = null`，于是 `ScheduleResult.nextReminderAt`
（下一站**会响**的提醒）取不到它，**标准模式下通常为 null**（= 没有下一站）：
单闹钟、通知链路、前台轮询全都自然安静，谁都不必各自判断模式。
而**锚点与间隔照算**：`TaskMetric.nextReminderAt` / `intervalMinutes` 不受门槛影响——
"今天该看哪几件"（今日清单准入）是调度问题，不是打扰问题。

**旧算法 `slack.v1` 保留在注册表里作对照**；与默认算法的差异只有**排序键**一处：
按 `urgency` 降序（importance 降序裁决）。`slackRisk` / `reminderInterval` /
锚点沿用 / 提醒门槛 / 四档排序全部共用同一份实现。

### 3.2 核心规则（三类分开：不变量 / 派生规则 / 架构规则）

**不变量**（必须恒真；违反即 bug。守护方 = TaskService，现状见括号）：

- A1. `0 ≤ remainingWork ≤ estimatedWork`（已守护——updateTask 缩减预估时同步 clamp）；
- A2. `estimatedWork ≥ 1`（创建与更新均校验，违反抛 ArgumentError）；
  **fixed 类型豁免**（允许 0）（已守护）；
  **长期豁免**：工作强度 = '长期'（三无缺省）时不校验——它本来就没有分钟数，
  A1 的 clamp 同理不适用（没有可夹的数）；
- A3. `1 ≤ importance ≤ 5`（**缺省 3**＝人的优先级，它同时是调度
  优先级的乘数）（构造时 clamp、缺省 3）；
  **长期任务豁免**：工作强度 = '长期'的任务**不设优先级**——没有"缺省 3"
  可言（同 A2 的 fixed 豁免先例）；
- A4. `snoozed` 状态必须伴随未来的 `snoozedUntil`；到期自动回 `active`。
  **定时触点**：`pollReminder()` 每轮先查有没有已到期的 snooze，有就先
  `refreshSchedule()`（写回 active 并重锚）。不能只等"下一站提醒到点"——
  标准档下 `nextReminderAt` 恒为 null，那条路走不到，被推迟的件会一直卡在
  `snoozed` 里不进清单、不参与排序。

**派生规则**（由状态与时间计算，不写入存储）：

- B1. `deadline` 在过去且仍有剩余工时 → `overdue`，退出提醒循环；
  **无 deadline（散件）不参与派生**；
- B2. `available < remainingWork` → `infeasible`，升级处理（改截止/砍范围/加班），
  不得静默；**fixed 不进调度**（走 AlarmPort 时点闹钟）。
- B3. `risk = f(slack)`（非线性，§3.1 公式）与 `priority = risk × importance` 都是
  **派生值**：算出来的排序键，**不写入任何文档**。内核属性文档里的
  `priority` 键始终指**人定的优先级**（= `Task.importance`），与调度优先级同名不同物。
- B4. **提醒门槛**：`reminderAllowed(task, mode) = mode == full || task.reminderRequested`
  （= metadata `remind`，或周期实例的规则设了响）。不满足时这一件 `reminds = false`、
  `reminderAt` 为 null（**锚点与间隔照算**，只是 `ScheduleResult.nextReminderAt` 取不到它），
  也不进 `nextPointReminder()`——"不出声"在调度结果里就是**事实**（null），
  下游不需要各自判断模式。
- B5. **手动序是用户意图**：`manual_order`（metadata，非负整数序号）
  = 人拖出来的顺序，**持久化在任务上**；与 `pinned`（插队）、`pool_order`（池子整理）
  同属"人的意图"一类，和 B3 的调度优先级正好相反——后者不落盘、换算法即变。手动序
  **只在无排序档（`ScheduleMode.manual`）参与比较**：标准/完整两档下它原样躺在
  metadata 里不生效，切档不迁移、不改写任何数据（视图重算即可）。

**架构规则**（对代码的约束）：

- C1.（**写路径唯一——正典表述**）Task 的任何字段变更只能发生在 TaskService 的命令
  方法内部；UI、AI、迁移一律通过命令，不得直接赋值。（Task 不可变 + copyWith，
  由编译器强制））本文件其他位置（§0、§1 铁律 2、§6）均为对此条的引用。
- C2. **防 Zeno**：重锚只在事件发生时调用（用户命令、提醒到点、文件变更）；周期 tick
  只做 `pollReminder()`——否则 nextReminderAt 每次重锚不断后移，提醒永远到不了
  （已遵守，且可验证——锚点表让它落地）。重锚**分两条**：命令走 `recomputeSchedule`
  （当前内存态，不读盘），外部改动走 `refreshSchedule`（先 `loadAll` 从盘回流再重算）。
  **两条都会重算间隔，但不会重新决定锚点**：`TaskService._anchors` 把上次的锚点
  按任务存着，`Scheduler.schedule(anchors:)` 收到就沿用（判据见 §3.1 的"锚点跨重锚沿用"）。
  于是"命令 → 重算"与"文件监听 → 再重算一次"都不会把别人的提醒往后推。
  锚点作废只有三种情形：这件任务的输入变了、它真的响过一次（`pollReminder` 软分支
  先删再重算）、或旧锚点迟到超过 30 分钟（算错过）。
- C3. **AI 无第二条写路径**：AI 的变更与人类点击走同一命令通道（详见 §6）。

### 3.3 领域事件（添加而不修改的钩子）

TaskService 每个命令完成后广播 `DomainEvent`（含 origin）。通知、同步、统计、AI 观察、
**操作流水（`EventLog`）**全部做成订阅者。**新增功能 = 新增订阅者，不改 TaskService。**

### 3.4 升级三道防线（domain 演进的影响控制）

1. **分级保真**（正典表述，[formats/](formats/README.md) 与 §7 规则 4 均引用此条）。
   任务数据是**两个文档**，保真因此分两层：

   | 文档                       | 谁写                 | 保真级别                                                                                                             |
   | -------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------- |
   | `tasks.md`（人类文档）     | 人（Obsidian、共享） | **行级保真**：应用只改写它自己那一行（写入/打勾/补完成时刻），**其余行、标题、空行、正文一字不动**；且**永不重排行** |
   | `.gtd/<id>.md`（内核属性） | 应用                 | **字段级保真**：应用拥有的字段（[formats/sidecar.md](formats/sidecar.md) 内核字段表）原地改写；注释行、未知字段、内核备注、行顺序原样保留              |
   | `routines.md`              | 设置页 + 人          | 字段级保真（同上，一条规则一个条目）                                                                                 |

   两条文档的**连接键是行指纹**（`digest`，见 [formats/](formats/README.md)）：应用把"自己写的那一行"的指纹
   记在内核属性文档里。指纹相等 = 没人动过；指纹不等 = 人在 Obsidian 里改了那一行，
   内核按**归属**合并（人写的那半边——任务名/创建/结束/完成/备注/标签——以文档为准，
   内核那半边——工作强度/优先级/时间裕度/剩余工作量——原样保留）。
   **裁决规则**：任何条款与此分级冲突时，以本条为准。
   **旧格式（一任务一文件）的保真承诺不变**，由只读兼容 codec 承担（见 §4.1）。

2. **metadata 缓冲带**：实验性/AI 生成的新字段先住 metadata，稳定后转正为正式字段。
   转正先例：`tags` / `completedAt` 由人类文档字段升为 `Task` 正式字段。

3. **显式迁移器**：破坏性变更走 `schema: N` 版本号 + 启动时备份 + 纯函数迁移 vN→vN+1。
   绝不悄悄改语义；字段只增不改，废弃先标记后迁移。
   **一次性形态迁移**（旧"一任务一文件" → 双文档）不属于此列：目录里若只有
   旧文件而没有 `tasks.md`，首次读取自动迁移，旧文件原样挪进 `legacy-tasks/` 存档
   （**只进不出，可人工回捞**），不删数据。

### 3.5 命令清单（正典）

一切状态变更（用户 / AI / 迁移）走本清单的命令；**UI 动作 ↔ 命令** 的映射以此为准
（CommandKind 按 §6 由此生成）。

实现上 `lib/application/task_service.dart` 按子域拆 part（`task_service/` 下：回收站 /
周期实例同步 / 四种排序，extension 挂在同一库上），命令清单与 API 不变。

现状（全集）：

| 命令                                                                             | 语义                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `createTask`                                                                     | 创建：deadline / estimatedWorkMinutes 可选；fixed 必须有截止且豁免 A2（工时可为 0），**flex 无截止（三无）缺省工作强度 = '长期'（豁免 A2/A3）**，flex 有截止缺省 30 分钟且必须 ≥ 1（A2）；类型走 metadata `type`（[formats/sidecar.md](formats/sidecar.md) 登记表） |
| `completeTask` / `snoozeTask` / `snoozeUntil` / `snoozeToNextWindow` / `logWork` | 完成 / 推迟（两档）/ 绝对档位推迟（明早 9 点、自选）/ 记工时。**完成命令顺手清掉挂起标记 `in_progress`**（挂起保持到完成或主动取消）                                                                             |
| `updateTask`                                                                     | 更新（含类型转换 fixed↔flex、清截止；fixed 必须有截止的合并后校验）。**清截止不自动改写工作强度**：'长期' ↔ 数字工时都在编辑里显式设，不悄悄改语义（§3.4 防线三）                                                          |
| `pinToTop(taskId)`                                                               | 插队 = 持久意图记在任务（metadata `pinned`），保持到完成、栈式压顶；仅对可推组生效，**且无排序档下不生效**（那一档顺序整体由 `manual_order` 定，见 B5）                                                                            |
| `setTaskReminder(taskId, enabled)`                                               | **逐任务提醒开关**：写 metadata `remind`；标准模式下这是让单个任务出声的**唯一**手段，完整模式下无意义（本来就全响）                                                                                                        |
| `pickForToday` / `returnToPool`                                                  | 挑散件到今日尾部（`picked_for_today` 标记，当日手动挑优先、尾部最多一件）/ 放回池子                                                                                                                                                      |
| `setLooseHome(taskId, home)`                                                     | 散件的家（metadata `loose_home`）：`pool` = 住池子散件段、`today` = 住今日页 ⑥（删键）。**只在无排序档参与分区**，切档不迁移；互逆的两个菜单动作共用这一条 |
| `setPoolOrder(taskId, order)`                                                    | 池子显示序（`pool_order`，仅整理无调度含义，重启保留）；**单条改序**——一次手势要改整段时走下一条                                                                                                                                         |
| `setPoolOrders(taskIds)`                                                         | 池子显示序的**整段重编号**（0 连续）：一次拖动手势 = 一次落盘 + 一个事件 + 一次重算                                                                                                                                                      |
| `setPinnedStack(taskIds)`                                                        | 插队栈的**整段重写**：按给定顺序决定谁压最上面（越靠上 `pinned` 时刻越新）；同样一次落盘 + 一次重算                                                                                                                                      |
| `setManualOrder(taskIds)`                                                        | **手动序**：按给定顺序整段重编 `manual_order`（从 0 连续编号）；只在无排序档参与今日清单的顺序，其余两档下原样保留                                                                                                         |
| `setInProgress(taskId, enabled)`                                                 | **挂起进行开关**：写/删 metadata `in_progress`（值 = 挂起时刻 ISO）。**仅'长期'任务可挂**（有截止的归调度管）；取消不受此限（'转正'后也要能取消）。保持到完成或主动取消，不按天过期                           |
| `setInProgressStack(taskIds)`                                                    | 挂起组的**整段重写**：按给定顺序决定谁排最顶（越靠上 `in_progress` 时刻越新）；同样一次落盘 + 一次重算（§3.5 通用约束）                                                                                                                  |
| `updateScheduleMode(mode)`                                                       | **调度模式**三档切换（**full** / **standard** 默认 / **manual**）：同时决定给内核的门槛与业务层的顺序口径；只重算，不动任何任务数据、无迁移                                                                                              |
| `updateWorkRule(rule)`                                                           | **换工时日历**（设置页「工作时间」）：校验后替换 `workRule`、清空锚点表（产能变了旧锚点没有意义）并重算。不动任何任务数据                                                                                                        |
| `deleteTask` / `restoreTask` / `purgeTrash`                                      | 软删除三件套：移入 `.gtd/.trash/` / 从回收站恢复 / 清空回收                                                                                                                                                                       |
| `completeTasks` / `deleteTasks` / `restoreTasks`（ids） | **批量版本**（选择模式用）：完成 / 软删除 / 撤销一批。**一次手势 = 一个事件 + 一次重算**（下文通用约束）：内存态整体换终态 → 发一个事件（复用 `taskCompleted` / `taskDeleted` / `taskRestored`，taskId = 首个生效的）→ 逐条落盘（回收站的文件搬移本来就是逐条 IO）→ 重算。逐条调单条命令 = N 件任务触发 N 次全量重算，清单一条条闪。`completeTasks` 跳过已完成项（幂等：不改写人写在 Obsidian 里的完成时刻） |
| `recomputeSchedule` / `refreshSchedule`                                          | 重锚（C2）两条：前者用**当前内存态**重算（**命令走这条，不读盘**）；后者先 `loadAll` 从盘回流再重算（文件监听 / 回前台 / 启动 / `restoreTask` / 提醒到点走这条）                                                                         |
| **周期任务**                                                             |                                                                                                                                                                                                                                          |
| `createRoutine` / `updateRoutine` / `deleteRoutine` / `setRoutineEnabled`        | 规则增删改与启用开关（RoutineService，写 `routines.md`）；每次改动同步当天实例（没有"编辑实例"）                                                                                                                                |
| `generateTodayInstances`                                                         | 每天生成当天实例（origin=system，幂等；启动/跨日/回前台触发）                                                                                                                                                                    |
| `skipRoutineToday(instanceId)`                                                   | 跳过今天：不完成、今日不再显示、次日再生（`routine_skipped`）                                                                                                                                                                   |
| `completeTask`（复用）                                                           | 例行实例"完成"走同一条命令；实例走软删除清理由删规则触发                                                                                                                                                                                 |

领域事件相应扩充：taskPinned / taskPicked / taskRestored / trashPurged、
**routineCreated / routineUpdated / routineDeleted / routineInstanceGenerated /
routineSkipped（taskId = 规则 id 或实例 id）**、**taskReminderSet（逐任务提醒开关）**、**manualOrderChanged / scheduleModeChanged（手动序改写与调度模式切换，订阅者只需重算视图）**、**poolOrderChanged（池子整理序整段改写）**、**taskInProgressSet（挂起进行开关与挂起组整段重写，订阅者只需重算视图）**、
**looseHomeChanged（散件在两个家之间搬家，订阅者只需重算视图）**。

> **一次用户手势 = 一个事件 + 一次重算；落盘排在事件之后**。
>
> ① **整段重编号不能拆成 N 次单条写**：第 k 条写完时只有前 k 个序号是新的，那个半
> 成品顺序会被立刻渲染出来，清单就在几个位置之间来回跳。所以批量落盘、内存态先
> 整体换成终态再发事件，第一次重建就是最终顺序。
>
> ② **光批量还不够**：事件是 UI 刷新的唯一触发器（UI 侧就一句
> `events.listen((_) => notifyListeners())`），把落盘排在事件之前，等于让"界面看到
> 新顺序"去等 N×2 次文件写 + 一次全量回读；那几帧里列表仍是旧顺序，条目先弹回
> 原位再跳过去——闪动的另一半。**顺序是持久数据（该落盘），但"算出显示顺序"不该
> 依赖盘**：命令一律"换内存态 → 发事件 → 落盘 → 用内存态重算"，只有外部
> 改动才真的回读。
>
> 落盘失败**只记不抛**（`TaskService.persistFailures`）：内存态已是界面看到的终态，
> 抛出只会让命令半途而废、UI 停在更不一致的地方。**代价**——界面状态会领先于盘
> 一小段窗口（写失败则持续到下次从盘回流），已登记为 §11 的已知局限。

---

## 4. 插座清单

### 4.1 计算类插座（domain 定义）

```dart
/// 存取：只管生命周期，不管格式。
abstract class TaskRepository {
  Future<List<Task>> loadAll();
  Future<Task?> getTask(String id);
  Future<void> save(Task task);
  Future<void> delete(String id);
  Stream<RepositoryEvent>? watch();   // 可选能力：null = 平台不支持监听（如 SAF）
                                      // 桌面实现 = dart:io Directory.watch + 300ms 去抖
  List<String> get warnings;          // 解析与合并告警（流向见 formats/README.md）
}

/// 格式编解码：纯函数，无 IO。"存哪"（repository）与"什么格式"（codec）分离。
/// 双文档各有专用形状，本接口只剩**旧格式只读兼容**这一位：
///   - 旧"一任务一文件"（`md-frontmatter/1`，格式见 formats/routines.md）= 唯一的 TaskCodec 实现；
///   - 内核属性文档走 TaskSidecarCodec（下），人类文档走 TaskDocumentCodec（下）
///     ——两者都**不是** TaskCodec：一个要多带 digest 接线与登记键写回，
///     一个处理的是"一篇多任务文档里的某一行"，不是"一个文件"。
abstract class TaskCodec {
  String get formatId;                   // 'md-frontmatter/1'（旧格式只读）
  bool canDecode(String raw);
  DecodeResult decode(String raw);
  String encode(EncodedTask input);      // 遵守 §3.4 分级保真
}

/// 调度：纯函数、无 IO、时间注入、参数自描述。
abstract class Scheduler {
  String get id;                         // 'slack-priority.v1'（默认）/ 'slack.v1'（旧，保留）
  String get displayName;                // '时间裕度优先' / '裕度几何递减'
  List<ParamSpec> get params;            // 设置页据此自动渲染；AI 只许在范围内调参
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
    ReminderMode reminderMode = ReminderMode.standard,   // 提醒门槛
    Map<String, DateTime> anchors = const {},            // 锚点表（§3.1 的"跨重锚沿用"）
    // 没有 sortMode 是**故意的**：内核那份排序还服务于 nextTask /
    // 提醒锚点等计算，排序是业务层的查询口径，下沉到这里会让它出现在所有算法的实现里。
  });
}
```

配套小型类型（接口草图的一部分，非"裸奔"）：

```dart
class DecodeResult {
  final Task task;
  final List<String> warnings;
}
class EncodedTask {
  final Task task;
  final String? originalRaw;   // 磁盘当前内容；null = 新文件
  final String? baselineRaw;   // 应用最后见到/写入的内容——正文归属的比对基准
}
class ParamSpec { final String key, label, hint; final num min, max, defaultValue; }
class RepositoryEvent { final RepoChangeType type; final String path; final DateTime at; }
// 未定：RepositoryEvent 是否需要携带内容快照、细分 created/updated/deleted。
```

配套机制：

- **Codec 注册表**：按 `formatId` 挑 codec；旧格式的 codec 永远保留负责读旧文件。

**双文档的三个构件（正典见 [formats/](formats/README.md)）**：

```dart
/// 人类文档 tasks.md：一个文档、# 标题分类、一行一条任务。
/// 纯函数、无 IO；文件里的每一行原样持有（行级保真的载体）。
class TaskDocumentCodec {
  static const String formatId = 'md-taskdoc/1';
  // 行格式的关键词（创建 / 结束 / 完成 / 备注）与各列语义不在此重复：
  // 正典见 formats/tasks-md.md 的行格式表。

  TaskDocument parse(String raw);               // 永不抛：坏行进 warnings
  static String encodeLine(Task task);          // 任务 → 一行（唯一行格式真相）
  static String digestFor(Task task);           // 该行的行指纹
  static String digestOf(String lineContent);   // FNV-1a 32 位，纯 Dart 无依赖
}

/// 内核属性文档 .gtd/<id>.md：任务 id / 工作强度 / 优先级 / 时间裕度 /
/// 剩余工作量 + digest（连接键）。
/// 长期任务例外：只有 id 一行——上面那些键全部缺行，
/// digest 也没有（配对走 formats/matching.md 第 2/3 档）。
/// 注意：它**不是** TaskCodec 实现（多了 digest 接线 + 登记键写回，见上）。
class TaskSidecarCodec {
  static const String formatId = 'md-taskkernel/1';
  // 键的**全集**（内核自有 9 个 + 应用 metadata 12 个）与各自语义见
  // formats/sidecar.md 的登记表——这里不复制列表，因为漏登记
  // 一批键的写回，等于让用户手写的那几行下次保存时消失。
  // 此处只留改写规则：内核键原地改写（`null` → 整行移除）；metadata 键跟随
  // 任务对象改写（值变则行变、键消失则整行删）；其余未知键原样往返。
}

/// 双文档仓储：读 = 人类文档 ∩ 内核属性（按行指纹配对；长期任务没有指纹，
/// 走 formats/matching.md 第 2/3 档）；
/// 写 = 内核属性先落盘，再只改人类文档里那一行。
class MarkdownTaskRepository implements TaskRepository { /* … */ }
```

- **`TaskDocumentCodec` 为什么要独立成一个类型**：它编解码的对象是"**一篇多任务文档
  里的某一行**"，不是"一个文件"。硬塞进 `TaskCodec`（一文件一任务）会把 `originalRaw`
  的语义搞混——所以内核属性文档与人类文档各走专用 codec（`TaskSidecarCodec` /
  `TaskDocumentCodec`），`TaskCodec` 只留给旧格式的只读兼容；
  两者共用一个 repository 做归属合并。
- **行指纹（digest）登记**：见 [formats/](formats/README.md)。它是"外部修改检测"在双文档形态下的实现——
  比 mtime 可靠（同分钟两次改动也分得开），也比"重新渲染一遍再比"可靠
  （内核属性文档本来就不含任务名，重新渲染必然不等）。
- **Scheduler 注册表**：当前选择存设置；切换算法无需迁移（nextReminder 是
  计算结果，重算即生效）。
  注册的是**两个**算法：`slack-priority.v1`（**默认**，时间裕度优先，公式见 §3.1）
  与 `slack.v1`（旧，裕度几何递减，留作对照）；默认由组装点（main.dart）挑，设置页暂不提供切换入口。
  **"无排序"不进注册表**：它不是第三个算法，`sortMode` 也不是 `schedule` 的
  入参——这一档改的是"清单按什么顺序展示"，属业务层查询（见下条）。注册表里
  仍然只有那两个 `id`。

**UI 文档带来的新座位**：下面每个座位都有独立实现与独立契约页，改其中一个
不必读完整节。

| 座位 | 定义层 | 契约页 |
|---|---|---|
| 周期任务 | domain（`RoutineRepository` / `RoutineCodec`） | [routine.md](sockets/routine.md) |
| 主线 | domain（`MainlineRepository` / `MainlineCodec`） | [mainline.md](sockets/mainline.md) |
| 灵感 / 设置 / 操作流水 | application（`NotesPort` / `SettingsPort` / `EventLogPort`） | [app-ports.md](sockets/app-ports.md) |
| 今日与池子查询 | application（`buildTodayView` / `buildPoolView`） | [views.md](sockets/views.md) |

### 4.2 交付类插座（application 定义）

通知、闹钟、权限、目录选择四类 Port，桌面与安卓两套适配器，以及系统级悬浮面板
（第二个 Flutter 引擎）的层职责与引擎边界——见 [sockets/delivery.md](sockets/delivery.md)。

"`EventLog` 只在主引擎挂"的理由（两个引擎会把同一件事记两遍）也写在
那份契约的边界表里。

### 4.3 送达策略与提醒协调者

`NotificationWindowRule`（什么时候真正打扰用户）与 `ReminderDispatcher`（单闹钟
怎么协调两个提醒源）：见 [sockets/reminder.md](sockets/reminder.md)。

### 4.4 同步类插座（application 定义）

局域网同步的契约、拓扑、范围裁决与冲突规则：见 [sockets/sync.md](sockets/sync.md)。

装配只在主引擎（`main.dart`）——悬浮引擎没有写入职责，主机服务也只需一份。

---

## 5. UI 与平台

### 5.1 双层拆分：交互意图 vs 平台呈现

- **交互意图是跨平台的**：用户能做的动作全集 = TaskService 的命令集合。核心不知道"侧滑栏"存在。
- **平台呈现按平台组装**：

```text
lib/ui/
├── shells/       android_shell.dart / desktop_shell.dart
│                 ← 抽屉、返回键、状态栏、窗口标题栏……平台差异全在这
├── panels/       today_panel.dart / notes_panel.dart /
│                 pool_panel.dart / completed_panel.dart（已完成页）/
│                 settings_panel.dart（设置页壳；权限节与周期节在
│                 settings_permissions.dart / settings_routines.dart）/
│                 side_panel.dart（安卓壳 / 悬浮面板 / 桌面壳共用同一份）/
│                 panel_pages.dart（页序 / 页名 / 默认页的唯一来源）
│                 ← 功能面板，平台无关，只被 shell 摆放
├── dialogs/      创建对话框（**类型+日期档位按钮、默认三无**）/
│                 编辑表单 / 推迟档位 / 日历 /
│                 task_detail_sheet.dart（详情卡，只读展示件）/
│                 routine_edit_dialog.dart（周期规则）/
│                 settings_windows_dialog.dart / settings_notes_path_dialog.dart（设置页弹窗）
│                 ← §5.1 shells 之下，panels 与共享 widgets 的辅助件，平台无关
├── overlay/      overlay_bridge.dart（悬浮引擎的原生通道桥）/
│                 overlay_panel_shell.dart（悬浮面板宿主壳）
│                 ← 系统级悬浮面板的 Dart 侧（§4.2），入口在 lib/overlay_main.dart
├── widgets/      任务行 / 提醒监听 / 长按菜单（共享小组件）
├── app_controller.dart   ← 见 5.2
└── theme.dart    主题预设（默认橙）+ 明暗三选一（跟随系统/浅色/深黑，§8）
```

安卓壳（应用内形态）：设置页为主体 + 贴屏把手/拖出面板 + **四页左右横翻**
+ Drawer 兜底（同一套 panels）。**系统级悬浮面板** = 原生
`OverlayHandleService`（SYSTEM_ALERT_WINDOW + 前台服务 + 第二个 Flutter 引擎）：
把手拖出 → **同一个面板就地在当前 App 上方展开**（透明 overlay 窗口），
只有『设置 / 编辑规则』才把用户送进应用（详见 [sockets/delivery.md](sockets/delivery.md) 的边界表）。
**生命周期归服务、不归 Activity**：把手与悬浮面板住在 `OverlayHandleService`
（前台服务，`stopWithTask=false` + `START_STICKY`）。从最近任务划掉卡片只销毁
`MainActivity`，服务与悬浮引擎继续活着——把手照旧贴边、面板照常展开、命令照常
写盘（它有自己的 `TaskService`）。服务被系统回收后由 `START_STICKY` 重建，从原生
prefs 恢复停靠侧、y 与开关；手机关机重启后由 `BootReceiver` 按同一份 `enabled`
标记拉回来（用户没开过把手就不拉）。划掉卡片仍有代价：主引擎随 Activity 一并
销毁，提醒链不再重锚（§11）。
**显示规则**：应用在前台时系统把手与悬浮面板都收起（此时用应用内把手与面板），
离开应用才显示——**每个场景恰好一个把手、一份面板**；把手**只竖向移动**、永远贴边，
停靠侧与 y 持久化，旋屏后重新贴边。
**把手的形态与它占的那条边**：贴边**可见**的不再是一块 26×72dp 的橙色
圆角条（→ 10×88dp 白色 55% →）而是 **6×72dp、白色 35% 不透明的细条**，应用内把手用
同一套参数。**可起手的区域比白条大得多**：窗口本身是 **12×200dp 的透明热区**（宽是设置项
`handle_hot_width`：细 8 / 标准 12 / 宽 20，两处把手共用），白条
贴在热区靠屏幕边缘那一侧、竖直居中——白条缩细之后没有这块热区就摁不准。200dp 取的是
系统"每边最多兑现 200dp 手势排除"的配额上限，正好用满（再多系统也不认），**竖向不开放
调节**。热区是透明 overlay 窗口，**它盖住的触摸归把手**，底下的 App 收不到，这是"好抓"
要付的代价，且这层**做不到"点按透过、拖动照旧"**——Android 按**手势**挑窗口，一次
DOWN…UP 要么整个归把手、要么整个归底下的 App，没有"识别成点击就退还"这回事，能调的
只有面积（所以默认宽从 28dp 收到 12dp 并交成设置项）。代价的另一半用
"**拖动用热区、长按只认白条**（白条外扩 10dp）"来收——点按不是入口，
两处把手都只认拖动：朝屏内累计拖过 72dp 或快甩 ≥500 逻辑 px/s 才展开。
把手视图在 attach 之后对自己调 `setSystemGestureExclusionRects`（声明的是热区整块），
把自己从系统返回手势的边缘带里
抠出来（这是 `OverlayHandleService` 的职责，属平台呈现，不进 UI 层）。
**把手的竖向位置可上锁**（设置项 `handle_locked`）：上锁后拖拽不再改变 y，长按换边
仍可用；锁定意图存在 `settings.json`，执行在原生（把手位置本身是原生 prefs），
系统级与应用内两个把手一致。
**面板窗口刻意不声明排除区**——那里从边缘起的横向返回恰好等于收起面板。
**把手拖出头的第二档是快记**（[快记](panels/quick-note.md)）：过 0.45 × 屏宽后拐离水平即
把把手窗口就地变成跟手方块，松手弹输入条、直接写一条三无任务。它只多三条**单向下行
事件**（start / cancel / open），任务落库仍走 Dart 侧同一条 `createTask`，不新增数据通路。
**桌面壳（Windows）= 常驻左侧栏 + 主体设置页**：`desktop_shell.dart` 用
`SidePanel` 摆**与安卓完全同一套**四页（灵感 / 今日清单 / 任务池 / 已完成）+
面板头的第二行主线 + 主线覆盖页，右边一整栏是同一份 `SettingsPanel`。桌面窗口
常驻，所以**没有"进出"这一维**：没有贴屏把手、没有遮罩与滑入动画、没有抽屉兜底、
没有尺寸拖拽（窗口大小就是尺寸来源），面板头的『设置』图标也不显示（设置页就在
旁边）。**提醒回流两个壳都挂 `ReminderListener`**——桌面的"托盘"就是应用窗口
（§4.2），不挂这一层 `StreamNotificationPort` 发出的事件就没人渲染。窗口窄于
720 逻辑像素时退回单栏：只摆面板，设置页从标题栏
那颗『设置』按钮 push 成独立页面。交互细节见 [桌面布局](panels/desktop.md)。
**设置页里只属于悬浮壳的项**（权限引导 / 贴屏把手 / 把手与面板尺寸 / 闹钟渠道）
在桌面上**整行不渲染**，判据是组装点注入的 `ShellCapabilities` 能力表
（`lib/application/shell_capabilities.dart`）——UI 读表、不问平台，与 §5.3 的口诀一致。

安卓 shell 用 Drawer 摆面板，Windows shell 用侧边栏摆**同样的面板**。
布局上允许 `Platform.isAndroid` 分支——那是摆法不同；能力差异必须走插座。
桌面已知局限（窄窗口不折叠栏、鼠标按住横拖不翻页）记在本文 §11。

### 5.2 AppController（UI 层内的门面）

```dart
/// ui/ 层内的薄胶水（ChangeNotifier）：
/// - 对上：UI 的唯一入口——UI 只看见它的命令/查询，不透传 TaskService；
/// - 对下：转发命令给 TaskService，把状态/事件转成 notifyListeners。
/// 它不是架构层，是 ui/ 的内部构件；不出现在核心任何一层。
```

UI 仅经 AppController 访问，守卫规则 2 拦截回归。

### 5.3 口诀与组装点

**UI 里只出现接口名，不出现平台名。**
安卓想调什么 API 都可以，唯一的问题是"从哪个文件里调"——答案永远是：适配器。
新平台 = 新 shell + 若干插头，panels 与核心原样复用。
`main.dart`（未来 `bootstrap/`）按平台选 shell、选全部插头、注入 TaskService，
并决定任务目录来源（环境变量 / 设置持久化 / SAF）。

---

## 6. AI 接口：分级授权，单一命令通道

**本节只留契约约束；分级授权、类型定义与提案流程的设计草案在
[roadmap.md](roadmap.md) 的「附录：AI 接口设计草案」——那是设计，不进契约。**

已经生效的两条：

- **写路径唯一**（§3.2 C1）是 AI 权限模型的地基：C1 只是约定时，那套分级授权
  同步降级为约定，不承诺任何强制。
- **AI 无第二条写路径**（§3.2 C3）：AI 的变更与人类点击走同一命令通道。

---

## 7. 架构守卫（让规则变成会跑的测试）

`test/architecture_test.dart` 扫描源文件 import，断言 §2 矩阵，三条起步规则：

1. `domain/**`、`scheduler/**`、`application/**` 不得 import `package:flutter` 与 `dart:io`；
2. `ui/**` 不得 import 任何 repository/scheduler **实现**；
3. `repository/**` 不得 import `scheduler/**`，反之亦然；
   `application/**` 不得 import 任何**具体实现**（含默认实现的选择，见 §2 第二段）。

行为守卫：

4. **分级保真测试**（以本文 §3.4 防线 1 为准）：分两个文档断言——
   人类文档 `tasks.md` **行级保真**（应用只改自己那一行，其余行/标题/空行/正文
   一字不动，且永不重排行）；内核属性文档 **字段级保真**（内核字段原地改写，
   注释行、未知字段、行顺序原样保留），**登记的 metadata 键跟随任务对象改写**
   （值变则行变、键消失则行删）。

谁越线，`flutter test` 直接红。架构从"设计意图"变成"验收标准"。

---

## 8. 升级影响对照表（可维护性验收标准）

| 未来的变化                | 要动的地方                                                    | 不用动的                         |
| ------------------------- | ------------------------------------------------------------- | -------------------------------- |
| Task 加字段（如 tags）    | metadata 试水 → 转正（转正伴随 Task/codec/UI 的**等价扩展**） | 旧文件（分级保真保着）、核心逻辑 |
| 换/加调度算法             | 注册一个新 Scheduler                                          | UI、通知、存储、Task             |
| Markdown 格式升级或换存储 | 新 codec / 新 repository 实现                                 | domain、算法、UI                 |
| 安卓文件监听不可用        | 安卓 adapter 返回 `watch() = null`                            | 其他所有代码                     |
| 加 AI 助手                | 一个 AiProvider 实现 + 提案列表 UI                            | 核心调度、存储                   |
| 加系统通知 / 换渠道       | 一个 NotificationPort / AlarmPort 实现                        | Scheduler、TaskService           |
| 上新平台（iOS/Linux）     | 新 shell + 若干插头 + 组装分支                                | panels、domain、算法             |

验收表述：**多数变化以新增文件为主**；"要动"列中允许的既有文件改动限于等价扩展/搬移
（不改行为），回归范围以"不用动"列为准。

---

## 9. 角色工作集（改东西时各自只需看到什么）

| 角色               | 需要看到                                           | 产出                     | 无需接触         |
| ------------------ | -------------------------------------------------- | ------------------------ | ---------------- |
| 算法作者           | domain 词汇表 + Scheduler 接口 + 一个现有算法参考  | 新算法文件 + 注册 + 测试 | UI、存储、平台   |
| UI 作者            | AppController 命令/查询 + 展示类型 + shells/panels | 面板与 shell             | 调度内部、存储   |
| 存储作者           | TaskCodec / TaskRepository 接口 + 保真测试         | codec / repository 实现  | 算法、UI         |
| 平台适配者（安卓） | 插座清单 + 组装点 + android/ 配置                  | 插头实现 + manifest      | 核心逻辑         |
| AI 作者            | SystemSnapshot + Proposal + applyCommands 入口     | AiProvider 实现          | 调度器内部、存储 |

工作集 = 自己的新文件 + 一页接口；交叉视图被 §2 矩阵挡住。

---

## 10. 现状与差距

已成立：domain/scheduler/application 零平台依赖；接口与实现分离（§2 矩阵由守卫测试拦截）；通知已是接口；时间可注入；ScheduleResult 不落盘；snoozed_until 持久化；
局域网文件同步（[sockets/sync.md](sockets/sync.md)，主机/从机 + 文件级搬动）；测试覆盖跨日历/临界/逾期场景。

**剩余差距：AI L2**（§6，`AiProvider` 已定义；设置页只做"展示 + 拒绝"）。

---

## 11. 已知局限（记录在案，非待办）

| 局限                                             | 说明                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | 触发重新评估的时机                                                                                                                                              |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 扁平目录，无项目/层级                            | 约定：分类靠人类文档的 `# 标题` 与 `##标签`，不建子目录                                                                                                                                                                                                                                                                                                                                                                                                                                         | 任务量或组织需求上来时（将同时动 repository、codec、组装点）                                                                                                    |
| holidays 仅支持具体日期                          | 不支持每年重复的节假日                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | 需要长期日历规则时                                                                                                                                              |
| 双开实例未处理                                   | 桌面双开 = 文件级 last-writer-wins，字段归属合并缓解但不消除                                                                                                                                                                                                                                                                                                                                                                                                                                                | 出现真实双开需求时（实例锁或单一常驻进程）                                                                                                                      |
| **人类文档是单文件**                     | 所有任务共写一个 `tasks.md`：任务量大时单文件变长（Obsidian 侧仍是普通文档）；两引擎/双开并发改同一行理论上可丢一侧。**未采用"一任务一文件"或"单文件内核索引"**的理由见 [为什么是双文档](formats/README.md)                                                                                                                                                                                                                                                                                                              | 单文档超过数千行、或出现真实并发丢写时（改为按分类分文件 / 引入行级锁）                                                                                         |
| **行指纹的三种失配**                     | 指纹不等时按"任务名 → 位置配对"降级认领。若人在 Obsidian 里**同时**改名、增删行，位置配对可能把内核属性配到相邻任务上                                                                                                                                                                                                                                                                                                                                                                              | 出现真实错配案例时（人写一个稳定 id 进行内，例如 `^task-001`；代价是文档变脏）                                                                                  |
| **提醒链只在主引擎里**                   | `ReminderDispatcher` 装配在 `MainActivity` 的引擎上，**Activity 一销毁它就不在了**：划掉任务卡片后，悬浮把手与面板照常（它们在服务里，§5.1），但下一站闹钟不再重挂；到点仍由原生接收器照 draft 弹一次，错过超过 30 分钟的提醒不再补响。开机同理——`BootReceiver` 只恢复把手，系统重启会清空 `AlarmManager`，重挂要等下一次打开应用                                                                                                                                                                  | 出现"划掉卡片后提醒照旧"或"重启后不开应用也要准点提醒"时（把主引擎从 Activity 挪到服务/缓存引擎，或到点起一次性后台引擎重锚）                                   |
| **悬浮面板不跑提醒调度**                 | 悬浮引擎（第二个 isolate）只做交互与展示，不装配 ReminderDispatcher（避免两个引擎抢同一个全局闹钟）。因此"只有悬浮面板活着"时也不重锚下一站闹钟                                                                                                                                                                                                                                                                                                                                                    | 与上一条一并处理：把调度搬进原生或让两个引擎协商单一调度者                                                                                                      |
| **两引擎并发写**                         | 应用内壳与悬浮面板各有自己的 TaskService；同步靠文件 watch + 字段归属合并，同一次编辑同时发生在两边时理论上可丢一侧（窗口极小）                                                                                                                                                                                                                                                                                                                                                                 | 出现真实丢失案例时（引入跨引擎的单一写入者或文件锁）                                                                                                            |
| **系统手势排除区只给了把手**            | 面板是全屏 overlay 窗口，**没有**声明 `setSystemGestureExclusionRects`：从边缘起手的横向手势仍可能被系统判成返回（结果 = 收起面板，语义恰好一致，见 ui-interaction.md）。不给面板加排除区的理由：每边排除区有系统竖向上限（约 200dp），整条边保护不住；加满会丢掉"边缘 = 返回"这个自然退出口。把手只有一小块、在配额内，独占它就够了                                                                                                                                                       | 用户抱怨"贴着边缘滚清单误触返回"（→ 改为整条边声明，接受系统上限）；或某个 ROM 不认把手那份排除区导致横拖打开失效（→ 退化到点按兜底）             |
| 周期实例按天物化成任务文件               | 每天一份：人类文档里一行（`- [ ] 晨跑 创建 …`，Obsidian 可见）+ 内核属性文档 `.gtd/<规则id>-<yyyy-MM-dd>.md`（完成/跳过都有地方落）；规则多时目录文件数会增长，需靠回收站/手工清理历史                                                                                                                                                                                                                                                                                                             | 目录膨胀到影响浏览时（改为归档子目录或按需生成）                                                                                                                |
| 主题只换强调色与明暗                     | 明暗三选一可用（跟随系统/浅色/深黑，默认跟随系统；深色底为暖深褐黑，逾期橙红暗色下提亮）；仍**不是完整主题包**——字体、密度、圆角体系不随主题变                                                                                                                                                                                                                                                                                                                                                                                                                                   | 需要完整主题包（换密度/字号/圆角等系统性视觉）时                                                                                                                    |
| **标准模式下不会自动提醒**               | 默认模式只排列不提醒：没手动开提醒的任务，只有清单顺序在推着你，错过截止不会有声音。这是**产品选择不是缺陷**（改设置或给那一件开提醒即可）                                                                                                                                                                                                                                                                                                                                                         | "忘了"成为主诉时（考虑按截止逼近度自动升级为提醒，或首次创建时问一句要不要响）                                                                                  |
| **风险的尺度 τ 是全局的**                | 同一个 τ（默认 1 个工作日）套在所有任务上："三天后交"和"三小时后交"用同一个尺度；个人对"紧"的感受只能靠调 τ/γ 或改 importance 表达                                                                                                                                                                                                                                                                                                                                                                 | 出现"同一批任务需要不同压力尺度"的真实需求时（按标签/分类配尺度）                                                                                               |
| **旧算法只在注册表里留着**               | `slack.v1` 保留是为了对照；设置页**没有**"换算法"入口（要改得动组装点）。这符合 §8"换/加算法 = 注册一个新 Scheduler"，但用户当下无法自选                                                                                                                                                                                                                                                                                                                                                 | 需要"用户自选算法"时（设置里补一个选择器；注册表与 `params` 都已就绪）                                                                                          |
| **标准/完整两档的差别只在"要不要出声"**  | 顺序、分组、编号、今日清单准入在这两档下**完全一样**（`TaskMetric.nextReminderAt` 是锚点，不受门槛影响），所以标准模式不会"少看到事"，只会"少听到响"（第三档"无排序"连顺序也交还给人，见本节后两条）                                                                                                                                                                                                                                                                                     | 若将来要求标准模式也改动清单构成（例如"没开提醒的都不进今日"），先改 [今日清单页](panels/today.md) 与 `buildTodayView`                                                                   |
| **手动序只覆盖被拖过的那一段**          | 拖动一次就对当前今天的 flex 组整段重编号；没排过序的任务没有 `manual_order` → 按 id 升序沉在末尾，新任务同样从末尾开始                                                                                                                                                                                                                                                                                                                                                                             | 出现"新任务要能插到中间"的需求时（创建后给它一个"插到某件之前"的入口，本质仍是写一个序号）                                                                      |
| **无排序只管今日的 flex 组与页底散件段** | 逾期组仍置顶、固定时点组仍按时刻升序（时刻就是序）、例行组仍按当天发生时刻；页底 ⑥ 只认 `pool_order`（拖动即整理序），`manual_order` 对它无效；任务池只剩计划段按整理序、周期条目按发生日期混排——散件按 `loose_home` 分家，两页不重复显示（同一件事只有一个显示位置）。这一档不跑定期挑，⑤ 不出现 | 要求固定时点组或周期条目也能随手拖时（先改 UI 文档再改 §3.1）；散件在无排序档需要独立于整理序的另一套顺序时（先想清楚两套序号谁先谁后）          |
| **界面状态领先于盘**                    | 命令改成"换内存态 → **发事件** → 落盘 → 用内存态重算"：事件是 UI 刷新的唯一触发器，把它提到落盘之前，界面就不必等 N 次文件写（拖动闪动由此消失）。代价是命令返回前那一段窗口里，**界面显示的状态盘上还没生效**；落盘失败（权限被撤、盘满、目录被移走）时，这个不一致会一直持续到下一次从盘回流（文件监听 / 回前台 / 重启），表现为"看着改好了、重启回退"。失败**只记不抛**（否则命令半途而废、UI 停在更不一致的地方），唯一查口是 `TaskService.persistFailures`（`<taskId>: <错误>`），目前不接 UI | 出现真实的写失败反馈（设置页给一处"未落盘"提示）；或要求"写成功才推进界面"——那等于把事件退回落盘之后、闪动会回来，正确做法是乐观更新 + 失败回滚，而不是调回顺序 |
| **长期任务没有行指纹**                  | 工作强度 = '长期'的任务内核属性文档只有 `id`，没有 `digest`：两文档配对降到 B.3 第 2/3 档（任务名/位置）。人在 Obsidian 里**改名且两边剩余数量不等**时，这一行会被当新任务接管（分到新 id），旧 id 的属性文件留在 `.gtd/` 里并附提示——表现为"改名后多出一条、旧条目还在"                                                                                                                                                                                                                           | 出现真实的改名丢任务案例时（给长期任务也写上 `digest`——它就一行、不算"属性"；或人在人类文档里写稳定 id 进行内，例如 `^task-001`）                               |
| **局域网同步的时钟与并发**              | 跨设备 mtime 只作同轮参考，方向主要靠内容指纹清单（见 [sockets/sync.md](sockets/sync.md)），时钟偏差不会导致反向覆盖，但可能让某一侧"永远显得更新"而每轮多推一次；两个从机同轮推同一文件按到达顺序覆盖（与"双开实例"同级）；`.trash` / `log.md` / `settings.json` 不跨设备——一台删的任务，另一台的回收站里没有，只能主机恢复                                                                                                                                                                                                                       | 出现真实并发丢写时（引入按文件的时间戳向量或单一写入者）；要求回收站也跨设备时（把 `.trash` 纳入同步范围并规定镜像删除的恢复路径）                          |
| **桌面窄窗口不折叠侧边栏**               | Windows 窗口窄于 720 逻辑像素时退回单栏（只摆面板，设置页从标题栏按钮 push 成独立页）；再窄到约 480 以下，面板按 240dp 下限渲染、右侧留白被吃掉，不自动折叠成抽屉                                                                                                                                                                                                                                                                                     | 需要在很小的窗口里长期干活时（做可折叠栏 / 面板抽屉化）                                                                                                         |
| **桌面鼠标按住横拖不翻页**               | `PageView` 在桌面上只接触摸 / 触控板 / 触控笔的拖动（Flutter 滚动视图默认的 dragDevices 不含 mouse）；翻页靠页序圆点或触控板横扫                                                                                                                                                                                                                                                                                                                     | 出现"鼠标拖不动页"的抱怨时（在桌面壳包一层放开 mouse 的 ScrollBehavior，注意别连带影响列表纵向滚动）                                                          |

---

## 附录 B：Markdown 文件格式约定（索引）

正典见 [`formats/`](formats/README.md)：目录布局与"为什么双文档"、`tasks.md`、
`.gtd/<id>.md`、配对与软删除、旧格式兼容与 `routines.md`、`主线.md` 六块。
改格式（字段、行语法、配对规则、迁移路径）先改那个目录，再改代码。
