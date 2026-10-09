# 架构契约：分层与接口设计

> 版本：v1.6（修订记录见 §13）
> 定位：这是写代码时对照的**合同**。结构或接口变更必须先改本文件，再改代码。
>
> **标注约定（全文统一）**：
> - **【现状】** = v0 已实现且有测试覆盖；
> - **【规划】** = 已确认方向、未实现，落地前以本节契约为准；
> - **【待细化】** = 接口形状未定，实现前必须先补全本文件对应条款。
> 未标注的条目默认【规划】。"与代码同步"仅指标注为【现状】的范围。
>
> 分工：产品定位、调度数学与阶段规划见原《动态任务调度 Todo 设计文档》。**客户端层的
> 需求与决议见 docs/ui-interaction.md（v0.6，决议 1–35）**——本文件为它提供结构与插座，
> 对接点 = §3.5 命令清单 + §4.3 送达策略；结构冲突以本文件为准，产品行为以 UI 文档为准。
> 本文件接管原设计文档
> 结构章节（按名称引用）：「总体架构」「Repository 层」「Scheduler 层」「一个非常重要的
> 边界」「AI Provider」「时间系统必须独立」「推荐项目结构」。两者冲突时以本文件为准。

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

| 方向 | 角色 | 规则 |
|---|---|---|
| 被动的实现往上插 | 存储、算法、通知、闹钟 | 实现核心定义的接口，被注入进核心 |
| 主动的客户端从外面调 | UI、AI | 只通过 Application 的公开 API 进来，产出只能是命令或提案 |
| 平台能力全走插座 | 选目录、精确闹钟、系统通知 | UI 里只见接口名，不见平台名 |

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
│  + RoutineService（周期规则；生成的实例仍经 TaskService 写，v1.5）│
│  校验规则 → 变更状态 → 发领域事件 → 重锚调度                     │
└─────────┬──────────────────────────────────────────────────────┘
┌─────────┴──────────── Domain（宪法，纯 Dart）──────────────────┐
│  词汇表：Task · Routine · ScheduleResult · WorkTimeRule ·      │
│          Clock · DomainEvent                                  │
│  计算类插座：TaskRepository · TaskCodec · RoutineRepository ·   │
│              RoutineCodec · Scheduler                          │
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
3. **时间必须注入**：核心不直接调 `DateTime.now()`，时钟从构造传入——这是算法可测试、可仿真的前提。【现状】

---

## 2. Import 矩阵（机器可验）

> 本节引用的 Task 等类型定义见 §3.1。

| 这一层的文件 | 允许 import | 禁止 import |
|---|---|---|
| `lib/domain/**` | 仅 domain 内部 | flutter、dart:io、任何平台名 |
| `lib/scheduler/**` | domain | repository 实现、ui、flutter |
| `lib/repository/` 接口文件 | domain | 具体实现 |
| `lib/repository/` 实现文件 | 接口、domain、dart:io | flutter、scheduler |
| `lib/application/**` | domain + 各插座（**接口**） | 任何具体实现（含默认实现的选择）、flutter |
| `lib/ui/**`（含 AppController） | application、domain 的**展示类型** | repository/scheduler 具体实现；直接改 Task 字段（见 §3.2 规则 A） |
| `lib/main.dart` | 一切（唯一组装点） | 业务逻辑 |

- UI 允许 import domain 的**类型**（Task、ScheduleResult）做展示——有意选择的务实例外；
  代价（Task 字段变化会波及 UI）已知并接受，缓解见 §10 第 1 条。
- **"application 不得 import 具体实现"包含默认值**：`scheduler ?? const SlackScheduler()`
  这类默认选择属于组装点职责。~~已知违规~~ **已修复（v1.2）**：默认实现的选择移至
  main.dart 组装点，`TaskService` 构造函数要求注入 `Scheduler` 接口；
  `test/architecture_test.dart` 持续拦截此类回归。
- `main.dart` 是全项目唯一允许问"我现在是什么平台"的地方（组装时按平台挑插头），且不写业务逻辑。

---

## 3. Domain 设计

### 3.1 词汇表（所有人共享的类型）

| 类型 | 职责 | 状态 |
|---|---|---|
| `Task` | 任务事实：id、title、**deadline（可空：fixed=时点 / flex=截止 / null=散件，v1.4）**、estimatedWork、remainingWork、importance、status、snoozedUntil、description、metadata；**不可变 + copyWith（v1.2 起由编译器强制写路径唯一）**；类型 TaskType 走 metadata 缓冲带 | 现状 |
| `TaskType` | flex（可推）/ fixed（不可推）/ **routine（周期实例，v1.5）**——三者的调度与完成语义不同 | 现状 |
| `Routine` | 周期规则：频率（每天/每周 X）、时点、响不响、启用开关；**不是任务**（住在 `routines.md`），每天生成一个当天实例（TaskType.routine） | 现状 |
| `RoutineOccurrence` | 一次具体发生（规则 + 时刻）：任务池计划段插入与日历打点用 | 现状 |
| `TaskStatus` | pending / active / snoozed / completed / **overdue（派生，不写入存储）**；只增不改 | 现状 |
| `WorkTimeRule` / `WorkWindow` | 工时日历：每周工作窗、节假日；`workMinutesBetween`、`addWorkMinutes`、`nextWindowStart`（D8「到下个工作窗」） | 现状 |
| `Clock` | 当前时间 `DateTime now()`，构造注入【现状，形态为 `DateTime Function()`】 | 现状 |
| `TaskMetric` | 单任务派生指标：available、slack、urgency、displayStatus、interval、nextReminderAt；计算结果，不持久化【现状】 | 现状 |
| `ScheduleResult` | 一次调度的输出：items（已排序）、nextTaskId、nextReminderAt、infeasible/overdue 名单；所有算法的统一方言【现状】 | 现状 |
| `ReminderEvent` | 到点提醒事件：firedAt + **taskId + kind（soft 软提醒 / point 时点提醒）** + 当时的调度快照 | 现状 |
| `PointReminder` | 时点性提醒候选（不可推到点 + 设了响的周期实例）：到点时刻 + 目标任务；到点后 30 分钟内仍可补响（`pointReminderGrace`） | 现状 |
| `DomainEvent` | 领域事件：type、taskId、at、**origin(user/ai/migration/system)** | 现状 |

调度核心公式（第一版 SlackScheduler 的语义，属 domain 词汇的一部分）【现状】：

```text
available = workMinutesBetween(now, deadline)      # 跳过休息时间
slack     = available - remainingWork              # 裕度，唯一的压力表
urgency   = remainingWork / available              # >1 → 按期不可行
interval  = clamp(α·slack, minInterval, maxInterval)   # slack≤0 → minInterval
nextReminderAt = addWorkMinutes(now, interval)     # 结果自动落在工作窗内
默认：α=0.5，minInterval=30，maxInterval=480（工作分钟，即 1 个工作日）
```

排序：infeasible 与 normal 同池按 urgency 降序（importance 降序、deadline 升序裁决）；
overdue、snoozed 沉底；overdue 退出提醒循环。

### 3.2 核心规则（三类分开：不变量 / 派生规则 / 架构规则）

**不变量**（必须恒真；违反即 bug。守护方 = TaskService，现状见括号）：

- A1. `0 ≤ remainingWork ≤ estimatedWork`【现状：已守护——updateTask 缩减预估时同步 clamp】；
- A2. `estimatedWork ≥ 1`（创建与更新均校验，违反抛 ArgumentError）；
  **fixed 类型豁免**（允许 0，v1.4）【现状：已守护】；
- A3. `1 ≤ importance ≤ 5`【现状：构造时 clamp】；
- A4. `snoozed` 状态必须伴随未来的 `snoozedUntil`；到期自动回 `active`【现状】。

**派生规则**（由状态与时间计算，不写入存储）：

- B1. `deadline` 在过去且仍有剩余工时 → `overdue`，退出提醒循环；
  **无 deadline（散件）不参与派生**（v1.4）【现状】；
- B2. `available < remainingWork` → `infeasible`，升级处理（改截止/砍范围/加班），
  不得静默；**fixed 不进调度**（走 AlarmPort 时点闹钟，v1.4）【现状】。

**架构规则**（对代码的约束）：

- C1.（**写路径唯一——正典表述**）Task 的任何字段变更只能发生在 TaskService 的命令
  方法内部；UI、AI、迁移一律通过命令，不得直接赋值。【现状：Task 不可变 + copyWith，
  由编译器强制（v1.2）】本文件其他位置（§0、§1 铁律 2、§6、D4）均为对此条的引用。
- C2. **防 Zeno**：`refreshSchedule()`（重锚间隔）只在事件发生时调用（用户命令、提醒
  到点、文件变更）；周期 tick 只做 `pollReminder()`——否则 nextReminderAt 每次重锚
  不断后移，提醒永远到不了【现状：已遵守，靠注释约定】。
- C3. **AI 无第二条写路径**：AI 的变更与人类点击走同一命令通道（详见 §6）【规划】。

### 3.3 领域事件（添加而不修改的钩子）【现状】

TaskService 每个命令完成后广播 `DomainEvent`（含 origin）。通知、同步、统计、AI 观察
全部做成订阅者。**新增功能 = 新增订阅者，不改 TaskService。**

### 3.4 升级三道防线（domain 演进的影响控制）

1. **分级保真**（正典表述，附录 B 与 §7 规则 4 均引用此条）：
   - **正文：字节级保真**——decode→encode 后与原文件逐字节一致；
   - **frontmatter：字段级保真**——应用拥有的字段（附录 B 字段表）由应用写；
     其余内容（未知字段、行顺序）原样保留。因此 frontmatter 内的注释、引号风格等
     "非字段信息"**不被承诺**（声明见附录 B：不支持注释）。
   - 裁决规则：任何条款与此分级冲突时，以本条为准。
2. **metadata 缓冲带**：实验性/AI 生成的新字段先住 metadata，稳定后转正为正式字段。
3. **显式迁移器**：破坏性变更走 `schema: N` 版本号 + 启动时备份 + 纯函数迁移 vN→vN+1。
   绝不悄悄改语义；字段只增不改，废弃先标记后迁移。

### 3.5 命令清单（正典）【现状，v1.4】

一切状态变更（用户 / AI / 迁移）走本清单的命令；**UI 动作 ↔ 命令** 的映射以此为准
（来源：ui-interaction.md §10，CommandKind 按 §6 由此生成）。

现状（v1.4，UI 文档落地后的全集）：

| 命令 | 语义 |
|---|---|
| `createTask` | 创建：deadline / estimatedWorkMinutes 可选；fixed 必须有截止且豁免 A2（工时可为 0），flex 缺省 30 分钟且必须 ≥ 1（A2）；类型走 metadata `type`（附录 B 登记表） |
| `completeTask` / `snoozeTask` / `snoozeUntil` / `snoozeToNextWindow` / `logWork` | 完成 / 推迟（D8 两档）/ 绝对档位推迟（明早 9 点、自选，决议 26）/ 记工时 |
| `updateTask` | 更新（含类型转换 fixed↔flex、清截止；fixed 必须有截止的合并后校验） |
| `pinToTop(taskId)` | 插队 = 持久意图记在任务（metadata `pinned`），保持到完成、栈式压顶；仅对可推组生效 |
| `pickForToday` / `returnToPool` | 挑散件到今日尾部（`picked_for_today` 标记，当日手动挑优先、尾部最多一件）/ 放回池子 |
| `setPoolOrder(taskId, order)` | 池子显示序（`pool_order`，仅整理无调度含义，重启保留） |
| `deleteTask` / `restoreTask` / `purgeTrash` | 软删除三件套：移入 `.trash/` / 从回收站恢复 / 清空回收（D11） |
| `refreshSchedule` | 重锚（C2：只在事件发生时调用） |
| **周期任务（v1.5）** | |
| `createRoutine` / `updateRoutine` / `deleteRoutine` / `setRoutineEnabled` | 规则增删改与启用开关（RoutineService，写 `routines.md`）；每次改动同步当天实例（决议 23：没有"编辑实例"） |
| `generateTodayInstances` | 每天生成当天实例（origin=system，幂等；启动/跨日/回前台触发，决议 5） |
| `skipRoutineToday(instanceId)` | 跳过今天：不完成、今日不再显示、次日再生（`routine_skipped`，决议 23） |
| `completeTask`（复用） | 例行实例"完成"走同一条命令；实例走软删除清理由删规则触发 |

领域事件相应扩充：taskPinned / taskPicked / taskRestored / trashPurged（v1.4）、
**routineCreated / routineUpdated / routineDeleted / routineInstanceGenerated /
routineSkipped（v1.5，taskId = 规则 id 或实例 id）**。

---

## 4. 插座清单

### 4.1 计算类插座（domain 定义）

```dart
/// 存取：只管生命周期，不管格式。【现状（v1.2 起异步化）】
abstract class TaskRepository {
  Future<List<Task>> loadAll();
  Future<Task?> getTask(String id);
  Future<void> save(Task task);
  Future<void> delete(String id);
  Stream<RepositoryEvent>? watch();   // 可选能力：null = 平台不支持监听（如 SAF）
                                      // 桌面实现 = dart:io Directory.watch + 300ms 去抖
  List<String> get warnings;          // 解析与合并告警（附录 B 流向）
}

/// 格式编解码：纯函数，无 IO。"存哪"（repository）与"什么格式"（codec）分离。【现状】
abstract class TaskCodec {
  String get formatId;                   // 'md-frontmatter/1'
  bool canDecode(String raw);
  DecodeResult decode(String raw);
  String encode(EncodedTask input);      // 遵守 §3.4 分级保真
}

/// 调度：纯函数、无 IO、时间注入、参数自描述。【现状】
abstract class Scheduler {
  String get id;                         // 'slack.v1'
  String get displayName;
  List<ParamSpec> get params;            // 设置页据此自动渲染；AI 只许在范围内调参
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
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
  final String? baselineRaw;   // 应用最后见到/写入的内容——D9 正文归属的比对基准
}
class ParamSpec { final String key, label, hint; final num min, max, defaultValue; }
class RepositoryEvent { final RepoChangeType type; final String path; final DateTime at; }
// 【待细化】RepositoryEvent 是否需要携带内容快照、细分 created/updated/deleted。
```

配套机制：

- **Codec 注册表**：按 `formatId` 挑 codec；旧格式的 codec 永远保留负责读旧文件【现状】。
- **Scheduler 注册表 + 影子运行**：当前选择存设置；切换算法无需迁移（nextReminder 是
  计算结果，重算即生效）；新算法可影子运行（只记日志对比）【现状】。

**UI 文档（v0.4/v0.5）带来的新座位**：

- **RoutineRepository / RoutineCodec**：周期规则存独立 `routines.md`（非 Task 文件，
  TaskRepository/TaskCodec 不覆盖；一条规则一个 frontmatter 条目，Obsidian 可改）；
  每天生成当天实例（origin=system），实例不占工时、不进 ScheduleResult 排序
  【现状（v1.5）：domain/routine.dart + repository/{routine_codec,routine_repository,
  markdown_routine_repository}.dart + application/routine_service.dart】；
- **NotesReaderPort**：疑问笔记**只读**（frontmatter 闭合后到下一个 `---` 的正文段、
  含 `[[` 的行屏蔽、对该文件零写入）【现状（v1.4）：application/notes_reader.dart
  定义接口与提取规则，platform/app_adapters.dart 落盘适配器】；
- **今日视图查询 `todayView()` / 任务池查询 `poolView()`**（application 层）：
  聚合 ScheduleResult（可推/逾期）+ 固定时点组 + 例行实例 + 被挑散件四种来源，
  UI 只消费查询结果（D12）【现状（v1.4）；v1.5 补：例行组落地，
  计划段以 `PoolRow`（任务行 / 周期条目）按日期混排，决议 27/14】；
- **SettingsPort**：应用设置（通知时间段、定期挑、疑问笔记路径、主题预设、
  周期任务是否进池等）的存取端口【现状（v1.4）：application/settings.dart +
  platform 落盘实现】；**v1.5 起设置文件仍在任务目录 `settings.json`**，
  但"任务目录是哪个"改存应用支持目录的 `bootstrap.json`（`BootstrapPort`），
  否则改目录会把设置本身弄丢。

### 4.2 交付类插座（application 定义）【接口 + 桌面适配器 + 安卓适配器现状（v1.5）】

```dart
enum ReminderChannel { normal, alarm }   // alarm = 闹钟渠道：全屏 + 持续响铃（决议 3/18）
enum PermissionKind {
  notifications, exactAlarm, batteryExemption,
  overlayWindow,        // 悬浮侧边栏（SYSTEM_ALERT_WINDOW）
  showOnLockScreen,     // 全屏提醒（锁屏/上层显示）
  folderAccess,         // 任务目录（所有文件访问 或 SAF）
}

class NotificationAction { final String id; final String label; }  // 如 done / snooze1h

/// 交付内容草案（v1.5）：挂闹钟时就把"到点交付什么"定下来。
/// 桌面不需要（到点由应用自己 show）；安卓需要——系统闹钟到点时应用可能已被杀，
/// 原生接收器只能照这份草案自己弹通知。
class ReminderDraft {
  final String taskId; final String title; final String? body;
  final ReminderChannel channel; final bool fullScreen;
  final List<NotificationAction> actions;
}

abstract class NotificationPort {
  Future<void> show(ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,        // full-screen intent（闹钟模式）
    ReminderDraft? draft,           // 系统通知实现用它渲染文案
  });
  /// 桌面的"托盘"就是应用窗口：适配器把 show 回流给 UI 渲染弹窗；
  /// 系统通知实现返回空流（安卓的按钮/点击走原生事件回传，见 4.3）。
  Stream<ShownNotification> get shown;
}

abstract class AlarmPort {
  /// 全局唯一闹钟。[draft] 供"应用被杀时也能自己弹通知"的实现使用。
  Future<void> scheduleNext(DateTime at, String taskId, {ReminderDraft? draft});
  Future<void> cancel();
  Stream<String> get fired;    // 到点（安卓=系统闹钟回调；桌面=Timer）
}

abstract class FolderPickerPort { Future<String?> pickDirectory(); }  // SAF / 桌面选择器

abstract class PermissionPort {
  Future<bool> ensure(PermissionKind kind);   // 申请（必要时弹系统界面）
  Future<bool> granted(PermissionKind kind);  // 只查询（设置页展示，不弹界面）
}
```

桌面适配器（`lib/platform/desktop_adapters.dart`【现状】）：`TimerAlarmPort`（前台 Timer，
系统闹钟在桌面的等价物）、`StreamNotificationPort`（应用内弹窗回流）、
`GrantedPermissionPort`、`UnavailableFolderPickerPort`。

安卓适配器（`lib/platform/android_adapters.dart` + `android/…/gtd/` 原生侧【现状，v1.5】）：
`AndroidAlarmPort` / `AndroidNotificationPort`（系统精确闹钟 AlarmManager + 通知渠道
`gtd_normal`/`gtd_alarm`/`gtd_overlay` + 通知按钮 + full-screen intent）、
`AndroidPermissionPort`（permission_handler + 原生全屏 intent/悬浮窗查询）、
`AndroidFolderPickerPort`（所有文件访问 + 系统目录选择器）；
原生侧另有 `OverlayHandleService`（贴屏把手，前台服务 + WindowManager）。
`platform/` 不受 §2 矩阵约束（组装点装配），但不得被 domain/scheduler/application import。

**系统级悬浮面板（v1.6，第二个 Flutter 引擎）**：文档 §0 的产品定位是"日常操作发生在
悬浮侧边栏里，App 主体几乎不开"，所以把手拖出必须**在当前 App 上方就地展开面板**，
而不是跳进应用。实现：

| 层 | 位置 | 职责 |
|---|---|---|
| 原生命令/事件通道 | `gtd/overlay`（MethodChannel） | `notifyReady` / `collapse` / `expand` / `openApp{target,routineId}` ↔ 原生 `state{expanded,dockedRight}` |
| 第二个引擎入口 | `lib/overlay_main.dart`（DartEntrypoint `overlayMain`） | 装配**同一套** domain/application（自己的实例）+ 悬浮面板宿主 `OverlayPanelShell` |
| 面板本体 | `lib/ui/panels/side_panel.dart` | `SidePanel` / `PanelActions` / `PanelPrivacyBar` / `PanelOnboardDialog`：**应用内壳与悬浮窗共用同一份** |
| 窗口 | 原生 `OverlayHandleService` | 全屏**透明** `TYPE_APPLICATION_OVERLAY` 窗口承载引擎的 FlutterView；展开时隐藏原生把手 |

边界（写死，避免两个引擎打架）：
1. **交付类插座只在主引擎装配**：全局单闹钟归主引擎那一份，悬浮引擎不起
   ReminderDispatcher（两个引擎各自挂闹钟会互相覆盖）；
2. **写路径仍然唯一**：悬浮面板的命令同样走它自己的 `TaskService`（C1 不变），
   两个引擎之间的状态同步走**文件**——两边都 `watch()` 任务目录（与"Obsidian 手改
   回流"同一条通路），并发写由 D9 的字段归属合并兜底；
3. **进应用的唯一入口**是面板头部的『设置』与实例菜单的『编辑规则』
   （`openApp{target,routineId}`），其余交互全部就地完成。

**单闹钟职责归属（条款有主语）**：全局任一时刻只挂一个下一站闹钟。调用方 =
application 层的 **ReminderDispatcher**（见 §4.3）。装配点负责把 AlarmPort 注入。
**适配器无自主权**：只执行"取消旧的、挂新的"，不得自行重排或补挂。

### 4.3 送达策略与提醒协调者【现状（接口 + 桌面适配器）；安卓适配器待设备阶段】

**NotificationWindowRule（通知时间段，D10）**：与 WorkTimeRule（工时产能，domain）
**解耦**——slack 数学不动，"什么时候真正打扰用户"由它裁决，归 application 层。

- 多段式（默认 9:00–21:00 一段）；空段列表 = 不限制（原样送达）；
- 映射规则：nextReminderAt（或相对档位推算出的时刻）落在段内 → 原样；
  落在段外 → **顺延到下一时段开头（只顺延、不吞掉）**；
  绝对档位（明早 9 点 / 自选）原样响（ui-interaction.md 决议 26）；
- 与工时窗口交集为空属用户自选配置：同样按顺延处理，不报错、不静默丢弃。

**ReminderDispatcher（单闹钟协调者）**：订阅 `scheduleReanchored` →
`alarm.cancel()` → 计算送达时刻（两个提醒源，见下）→ `alarm.scheduleNext()`（带草案）；
订阅 `alarm.fired` → `TaskService.pollReminder()` → `NotificationPort.show(...)`
（带 actions：完成 / 推迟1小时）→ 再排下一站（链路自续）。

**两个提醒源（v1.5）**：

| 源 | 谁 | 送达时刻 | 渠道 |
|---|---|---|---|
| **Slack 软提醒** | 可推任务（flex + 截止） | 经 NotificationWindowRule（段外顺延到下一段开头） | 永远普通通知 |
| **时点性提醒** | 不可推到点 + 设了响的周期实例 | 原样响（不受静默段限制，决议 26） | 闹钟模式开 → alarm 渠道 + full-screen |

- 单闹钟取两者中更早的一个（`ScheduleResult.nextReminderAt` vs
  `TaskService.nextPointReminder()`）；
- **只到点响一次**：响过写 metadata `point_fired`（持久），改期/推迟会清掉它；
  错过超过 30 分钟（`pointReminderGrace`）不再补响（已知局限见 §12）；
- 安卓的"应用被杀"路径：挂闹钟时留下 `ReminderDraft`，到点由原生接收器
  `ReminderReceiver` 自己弹通知（同一 taskId 的通知 id 相同 → Dart 侧再 show 时是替换，
  不会重复）；按钮点击走 `ActionReceiver` → 事件回传（应用不在则入队，启动后 `drainEvents` 补做）。

---

## 5. UI 与平台

### 5.1 双层拆分：交互意图 vs 平台呈现

- **交互意图是跨平台的**：用户能做的动作全集 = TaskService 的命令集合。核心不知道"侧滑栏"存在。
- **平台呈现按平台组装**：

```text
lib/ui/
├── shells/       android_shell.dart / desktop_shell.dart
│                 ← 抽屉、返回键、状态栏、窗口标题栏……平台差异全在这
├── panels/       task_list_panel.dart / today_panel.dart / notes_panel.dart /
│                 pool_panel.dart / settings_panel.dart
│                 ← 功能面板，平台无关，只被 shell 摆放
├── dialogs/      创建对话框（长按滑档位）/ 编辑表单 / 推迟档位 / 日历 /
│                 quick_dump_dialog.dart（堆三无）/ routine_edit_dialog.dart（周期规则）
│                 ← §5.1 shells 之下，panels 与共享 widgets 的辅助件，平台无关
├── widgets/      任务行 / 提醒监听 / 长按菜单（共享小组件）
├── app_controller.dart   ← 见 5.2
└── theme.dart    主题预设（默认橙；只换强调色种子，§8）
```

安卓壳（v1.4 落地，应用内形态）：设置页为主体 + 贴屏把手/拖出面板 + 三页竖翻 +
隐私过头 + Drawer 兜底（同一套 panels）。**系统级悬浮面板**（v1.6）= 原生
`OverlayHandleService`（SYSTEM_ALERT_WINDOW + 前台服务 + 第二个 Flutter 引擎）：
把手拖出 → **同一个面板就地在当前 App 上方展开**（透明 overlay 窗口），
只有『设置 / 编辑规则』才把用户送进应用（详见 §4.2 的边界表）。
**显示规则**：应用在前台时系统把手与悬浮面板都收起（此时用应用内把手与面板），
离开应用才显示——**每个场景恰好一个把手、一份面板**；把手**只竖向移动**、永远贴边，
停靠侧与 y 持久化，旋屏后重新贴边（ui-interaction.md 决议 34/35）。
桌面壳沿用 TaskListPanel，设置页（周期任务/主题/权限）以独立页面打开。

安卓 shell 用 Drawer 摆面板，Windows shell 用侧边栏摆**同样的面板**。
布局上允许 `Platform.isAndroid` 分支——那是摆法不同；能力差异必须走插座。

### 5.2 AppController（UI 层内的门面）【现状，形态待收紧】

```dart
/// ui/ 层内的薄胶水（ChangeNotifier）：
/// - 对上：UI 的唯一入口——UI 只看见它的命令/查询，不透传 TaskService；
/// - 对下：转发命令给 TaskService，把状态/事件转成 notifyListeners。
/// 它不是架构层，是 ui/ 的内部构件；不出现在核心任何一层。
```

现状缺口已收紧（v1.2）：UI 仅经 AppController 访问，守卫规则 2 拦截回归。

### 5.3 口诀与组装点

**UI 里只出现接口名，不出现平台名。**
安卓想调什么 API 都可以，唯一的问题是"从哪个文件里调"——答案永远是：适配器。
新平台 = 新 shell + 若干插头，panels 与核心原样复用。
`main.dart`（未来 `bootstrap/`）按平台选 shell、选全部插头、注入 TaskService，
并决定任务目录来源（环境变量 / 设置持久化 / SAF）。

---

## 6. AI 接口：分级授权，单一命令通道【本节全部规划】

四级权限，默认只开 L0/L1：

| 等级 | 能力 | 机制 |
|---|---|---|
| L0 读 | 看任务、调度结果、参数 | `SystemSnapshot`（只读投影） |
| L1 提案 | 估工时、拆任务、建议改截止 | 产出 `Proposal`，进 UI 待确认列表，**人确认后才执行** |
| L2 软控制 | 微调调度参数 | 只许改 `params` 声明范围内的值；记事件（origin=ai）；可见、可拒绝 |
| L3 硬控制 | 换算法、改规则 | 默认锁死，永不自动执行 |

类型定义：

```dart
abstract class AiProvider {
  String get id;
  /// 每个快照返回的提案数不得超过 proposalCap（上限值【待细化】，
  /// 接口按此约束实现方）。
  Future<List<Proposal>> propose(SystemSnapshot snapshot);
}

/// Command = 一次参数化的 UserAction（§3.2 规则 C1 的命令封装）。
/// 【待细化】CommandKind 与 payload 字段，落地 AI 前补全。
class Command { final CommandKind kind; final String taskId; final Map<String, Object?> payload; }

class Proposal {
  ProposalKind kind;        // estimate / decompose / retune / suggestDeadline
  String rationale;         // 给人看的理由
  List<Command> commands;
  ProposalStatus status;    // pending / approved / rejected / expired
}

class SystemSnapshot {
  final List<TaskView> tasks;          // 只读投影，非可变 Task
  final ScheduleResult schedule;
  final String activeSchedulerId;
  final Map<String, num> schedulerParams;
  final DateTime generatedAt;
}
// 裁剪规则：不含正文 description 全文与 metadata 自由字段，
// 除非 Provider 声明需要并在快照请求中显式开启。【待细化：TaskView 字段清单】

/// 提案确认入口（与人类点击共用同一命令通道）：
/// TaskService.applyCommands(List<Command>, {required EventOrigin origin})【规划】
```

**承诺边界（有机制的才承诺）**：

| 声明 | 机制 | 状态 |
|---|---|---|
| AI 变更可审计、可追溯 | `DomainEvent.origin = ai` 进事件流 | 随事件流落地【规划】 |
| AI 污染面上限 | 写路径唯一（§3.2 C1）成立 + 提案须人工确认 + 提案数受 proposalCap 约束 | 依赖 C1 强制化与守卫落地 |
| 回滚 | 逆命令机制 | **未设计，不承诺**；落地前 UI 只提供"拒绝"，不提供"回滚" |

前提声明：以上全部依赖 §3.2 C1 的强制化；C1 仅为约定时，本节保证同步降级为约定。

---

## 7. 架构守卫（让规则变成会跑的测试）【规则 1–3 已落地（v1.2）：test/architecture_test.dart】

`test/architecture_test.dart` 扫描源文件 import，断言 §2 矩阵，三条起步规则：

1. `domain/**`、`scheduler/**`、`application/**` 不得 import `package:flutter` 与 `dart:io`；
2. `ui/**` 不得 import 任何 repository/scheduler **实现**；
3. `repository/**` 不得 import `scheduler/**`，反之亦然；
   `application/**` 不得 import 任何**具体实现**（含默认实现的选择，见 §2 已知违规）。

行为守卫：

4. **分级保真测试**（正典 = §3.4 防线 1）：正文逐字节保真；frontmatter 字段级保真
   （未知字段、行顺序保留）。——取代 v1.0 中"整文件逐字节保真"的过强表述，
   两者冲突的裁决规则见 §3.4。
5. ~~Task 字段赋值的文本扫描~~ **已退役（v1.2）**：被 §10 第 1 条（Task 不可变 + copyWith）取代
   ——结构上不可能违规后，弱守卫没有存在价值。

谁越线，`flutter test` 直接红。架构从"设计意图"变成"验收标准"。

---

## 8. 升级影响对照表（可维护性验收标准）

| 未来的变化 | 要动的地方 | 不用动的 |
|---|---|---|
| Task 加字段（如 tags） | metadata 试水 → 转正（转正伴随 Task/codec/UI 的**等价扩展**） | 旧文件（分级保真保着）、核心逻辑 |
| 换/加调度算法 | 注册一个新 Scheduler | UI、通知、存储、Task |
| Markdown 格式升级或换存储 | 新 codec / 新 repository 实现 | domain、算法、UI |
| 安卓文件监听不可用 | 安卓 adapter 返回 `watch() = null` | 其他所有代码 |
| 加 AI 助手 | 一个 AiProvider 实现 + 提案列表 UI | 核心调度、存储 |
| 加系统通知 / 换渠道 | 一个 NotificationPort / AlarmPort 实现 | Scheduler、TaskService |
| 上新平台（iOS/Linux） | 新 shell + 若干插头 + 组装分支 | panels、domain、算法 |

验收表述：**多数变化以新增文件为主**；"要动"列中允许的既有文件改动限于等价扩展/搬移
（不改行为），回归范围以"不用动"列为准。

---

## 9. 角色工作集（改东西时各自只需看到什么）

| 角色 | 需要看到 | 产出 | 无需接触 |
|---|---|---|---|
| 算法作者 | domain 词汇表 + Scheduler 接口 + 一个现有算法参考 | 新算法文件 + 注册 + 测试 | UI、存储、平台 |
| UI 作者 | AppController 命令/查询 + 展示类型 + shells/panels | 面板与 shell | 调度内部、存储 |
| 存储作者 | TaskCodec / TaskRepository 接口 + 保真测试 | codec / repository 实现 | 算法、UI |
| 平台适配者（安卓） | 插座清单 + 组装点 + android/ 配置 | 插头实现 + manifest | 核心逻辑 |
| AI 作者 | SystemSnapshot + Proposal + applyCommands 入口 | AiProvider 实现 | 调度器内部、存储 |

工作集 = 自己的新文件 + 一页接口；交叉视图被 §2 矩阵挡住。

---

## 10. 现状与差距（v0 基线 → 目标，按优先级）

已成立【现状】：domain/scheduler/application 零平台依赖；接口与实现分离（一处已知违规，
见 §2）；通知已是接口；时间可注入；ScheduleResult 不落盘；snoozed_until 持久化；
23 个测试含跨日历/临界/逾期场景。

**进度（2026-10-08）：第 1–8 条已完成；第 9 条接口/桌面侧完成；第 10 条（UI 文档落地）
完成；第 11 条（安卓交付适配器 + 周期任务 + 主题预设）完成。** 各条目：

1. **Task 不可变 + copyWith**：字段全 final，变更 = 经 TaskService 生成新实例；
   "写路径唯一"（C1）从约定变编译器强制；顺带修复 A1/A2 两个已知 bug ✅
2. **领域事件流**：TaskService 增加 `Stream<DomainEvent>`（含 origin）；✅
3. **UI 只读门面**：AppController 摆出查询，UI 不再透传 `controller.service`；✅
4. **架构守卫测试落地**（§7 规则 1–3）+ 修复 SlackScheduler 具体类 import 违规
   （默认实现的选择移到组装点）；✅
5. **TaskRepository 异步化**：同步签名会卡安卓主线程、装不进 SAF——安卓的前置条件；✅
6. **TaskCodec 拆出** + 注册表 + 分级保真测试（§4.1 / §3.4）；✅
7. **写冲突策略（D9）+ watch() 桌面实现**：保存前重读 + 按字段归属合并 +
   与"应用最后见到的内容"精确比对检测外部修改（v1.2 实现时弃用 mtime 猜测）；
   watch = dart:io Directory.watch + 300ms 去抖，无第三方依赖；✅
8. **Scheduler ParamSpec 自描述** + 注册表 + 影子运行；✅
9. **交付类插座补齐**（AlarmPort/FolderPickerPort/PermissionPort）+ ui/shells 分层——
   **完成（v1.5）**：接口（application/delivery.dart）、ReminderDispatcher 协调者、
   NotificationWindowRule、桌面适配器与桌面 shell 分层已实现并测试；
   **安卓适配器落地**：系统精确闹钟（AlarmManager + 原生接收器，应用被杀也能弹通知）、
   通知渠道 normal/alarm、通知快捷按钮（完成/推迟 1 小时）、全屏闹钟（full-screen intent）、
   权限引导（通知/精确闹钟/电池白名单/悬浮窗/锁屏显示/所有文件访问）、
   任务目录选择器、系统级贴屏把手（前台服务 + WindowManager）。
   实机验证（API 37 模拟器）：精确闹钟按时触发 → 通知带按钮 → 点"完成"写回任务文件。
10. **UI 文档（v0.4）落地**：**完成（v1.4）**——命令集扩展（§3.5，全部落地）、
    deadline 可空 + fixed/flex 类型（metadata 缓冲带，B1/B2 与 A2 的豁免同步落地）、
    NotesReaderPort / 今日视图 / 任务池视图（§4.1）、软删除三件套（D11）、
    设置端口（settings.json）、安卓 shell（应用内悬浮侧边栏 + Drawer 兜底）。
11. **UI 文档剩余项（v1.5）**：**完成**——周期任务全链路（规则 routines.md + 当天实例
    + 设置页管理 + 今日『例行组』+ 池子计划段插入 + 日历打点只读）、主题预设（4 套强调色）、
    时点性提醒（不可推到点 + 设了响的周期实例，含闹钟模式与静默段豁免）。
    剩余（明确记录）：跨 App 的系统级**面板本体**（Flutter 常驻悬浮窗）、AI L2。

1→4 是一次纯内部小迭代；5–7 是存储改造；8 是算法层升级；9 起进入多平台。

---

## 11. 决策记录（为什么是这样）

| # | 决策 | 理由 |
|---|---|---|
| D1 | nextReminder 是计算结果，不持久化；snoozed_until 是用户意图，持久化 | 前者换算法即重锚、无需迁移；后者是事实，重启不丢 |
| D2 | maxInterval = 480（1 个工作日）而非 2 小时 | 裕度再大也会被拉回固定间隔 = 退化成"固定提醒"，与设计目标矛盾 |
| D3 | 只在事件发生时重锚（防 Zeno，§3.2 C2） | 周期重锚会让提醒永远到不了点；移动端"单闹钟 + 事件驱动"恰好契合 |
| D4 | AI 只经命令通道（§3.2 C3、§6） | 幻觉的污染面 = 一条待确认提案；可审计；可拔除 |
| D5 | 机读进 frontmatter，正文归人；应用只重写机读字段（附录 B、§3.4） | 用户手写内容（含未知字段）永不被应用毁掉 |
| D6 | repository 接口异步化（目标形态） | 安卓主线程 IO 卡顿；SAF 天生异步；越晚改波及越大 |
| D7 | overdue 是派生状态，不写入存储 | 随时间自然成立/消失，持久化反而产生脏数据 |
| D8 | snooze 语义分两档：≤120 分钟按**自然时间**；更长或跨休息时段提供显式选项"到下个工作窗" | v0 的纯工作分钟语义（周五傍晚推 30 分 → 下周一早）与 UI 文案"推迟30分"的 natural 预期冲突；语义必须写进合同，UI 文案同步改 |
| D9 | 写冲突策略：保存前重读文件 + **按字段归属合并**（应用拥有的字段 vs 人类/未知内容各写各的）+ 外部修改提示（检测方式 = 与应用最后见到的内容精确比对，比 mtime 粒度可靠；正文归属以 baselineRaw 为基准） | 单写者 last-writer-wins 会丢 Obsidian 端对机读字段的修改；分级保真（§3.4）与 D9 是同一机制的两面 |
| D10 | 通知时间段是 application 层的**送达策略**（§4.3），与 WorkTimeRule（domain，工时产能）解耦；落在静默段只**顺延到下一时段开头（不吞掉）**；绝对档位原样响 | 两日历概念混进 slack 数学会污染产能计算；"何时打扰用户"是送达礼貌，不是产能 |
| D11 | 删除 = 软删除：移入任务目录 `.trash/` 子目录（Obsidian 可见可捞）+ 撤销 toast + 设置『清空回收』 | Obsidian 共存场景下真删文件不可逆；"文件即备份"原则下回收站是自然延伸 |
| D12 | 今日清单聚合查询放 application（`todayView()`），UI 只消费查询结果 | 四种来源的聚合是查询不是渲染；守住"UI 不含逻辑"（原则 3） |

---

## 12. 已知局限（记录在案，非待办）

| 局限 | 说明 | 触发重新评估的时机 |
|---|---|---|
| 扁平目录，无项目/层级/标签 | 一任务一文件的 v1 约定 | 任务量或组织需求上来时（将同时动 repository、codec、组装点） |
| holidays 仅支持具体日期 | 不支持每年重复的节假日 | 需要长期日历规则时 |
| frontmatter 注释 ~~不保留~~ | **v1.2 已解决**：注释行属"非字段内容"，按字段级保真原样保留（codec 用原始行合并实现） | —（已关闭） |
| 双开实例未处理 | 桌面双开 = 文件级 last-writer-wins，D9 缓解但不消除 | 出现真实双开需求时（实例锁或单一常驻进程） |
| **提醒链路的"跨天自续"**（v1.5） | 应用被杀且用户长时间不打开时：安卓会在到点弹出通知，但**下一站闹钟要等应用再启动才重挂**（Dart 侧才有时序数学）；且错过超过 30 分钟的时点提醒不再补响 | 出现"连续多日不打开应用也要准点提醒"的需求时（把重锚搬进原生/后台 isolate） |
| **悬浮面板不跑提醒调度**（v1.6） | 悬浮引擎（第二个 isolate）只做交互与展示，不装配 ReminderDispatcher（避免两个引擎抢同一个全局闹钟）。因此"只有悬浮面板活着"时也不重锚下一站闹钟 | 与上一条一并处理：把调度搬进原生或让两个引擎协商单一调度者 |
| **两引擎并发写**（v1.6） | 应用内壳与悬浮面板各有自己的 TaskService；同步靠文件 watch + D9 字段归属合并，同一次编辑同时发生在两边时理论上可丢一侧（窗口极小） | 出现真实丢失案例时（引入跨引擎的单一写入者或文件锁） |
| **系统级悬浮面板本体**（v1.5 → **v1.6 已落地**） | 把手拖出即在当前 App 上方就地展开面板（第二个 Flutter 引擎 + 透明 overlay 窗口，复用同一份 panels）；进应用只走『设置 / 编辑规则』 | —（已落地；新局限见上两条关于调度与并发写的行） |
| 周期实例按天物化成任务文件（v1.5） | 每天一个 `routine-<规则id>-<日期>.md`（Obsidian 可见、完成/跳过都有地方落）；规则多时目录文件数会增长，需靠回收站/手工清理历史 | 目录膨胀到影响浏览时（改为归档子目录或按需生成） |
| 主题预设只换强调色（v1.5） | 状态语义色（逾期橙红、时间徽标橙）固定不随预设变；不是完整主题包 | 需要夜间配色/完整主题包时（§8 的"最后做"项） |

---

## 13. 修订记录（append-only）

- **v1.0**（2026-10-07）：初版基线，与 v0 代码结构同步。
- **v1.1**（2026-10-07）：吸收两轮外部审查。主要变更——
  分级保真取代"整文件逐字节保真"并与附录 B 互引（原两条款冲突，裁决规则归 §3.4）；
  §3.2 由"不变量"改为三类"核心规则"并补 A1/A2 两个已知 bug；新增术语等价声明与
  UserAction/Command/SystemSnapshot/DecodeResult/EncodedTask/ParamSpec/RepositoryEvent
  定义（未定处标【待细化】）；AppController 入图并入 §5.2；全文加【现状/规划/待细化】
  标注、头部同步声明改为按标注范围；frontmatter 语法规范化（平铺 key: value）；warnings
  流向补全；单闹钟职责归属（§4.2）；§6"白送"改写为承诺/前提/未承诺三栏；正典条款 +
  互引（写路径唯一 → §3.2 C1）；外部文档引用改按名称；§2 前向引用加注；新增 D8/D9、
  §12 已知局限、本修订记录；§10 增补第 7 条（写冲突 + watch）并升级第 1 条。
- **v1.2**（2026-10-07）：§10 第 1–8 条实现落地（40 个测试全绿）。要点——
  Task 不可变 + copyWith（C1 编译器强制，A1/A2 修复）；领域事件流上线（含 origin）；
  repository 异步化 + watch()；TaskCodec 拆出 + 注册表 + 影子运行；
  架构守卫测试落地（§7 规则 1–3，SlackScheduler 具体类违规同步修复）；
  **实现期发现的契约缺陷两处**：① D9 的正文归属基准不能拿磁盘内容与任务对象比对
  （对象可能落后于磁盘，会把外部修改误判为应用改动）——EncodedTask 增加
  `baselineRaw`（应用最后见到的内容）作为基准；② 编码合并丢失 `---` 与正文间的
  换行导致文件损坏——补回分隔换行。另：frontmatter 注释改判为"保留"（字段级保真
  覆盖非字段内容，原始行合并天然实现），§12 相应行关闭；D8 落地为
  `snoozeTask(minutes)`（自然时间）+ `snoozeToNextWindow()`（跳到下个工作窗）；
  widget 测试中真实文件 IO 必须包 `tester.runAsync`（FakeAsync 区会挂死），
  已在测试注释中说明。
- **v1.3**（2026-10-07）：对接 docs/ui-interaction.md（v0.4，客户端需求与决议 1–28）。
  新增 **§3.5 命令清单**（正典；含 UI 文档带来的命令扩展规划：createTask 签名改造 /
  pinToTop / pickForToday / setPoolOrder / 软删除三件套）与 **§4.3 送达策略与提醒协调者**
  （D10：NotificationWindowRule 与 WorkTimeRule 解耦、段外只顺延不吞掉、绝对档位原样响、
  交集为空按顺延处理）；§4.2 交付插座定稿（NotificationPort 增加 actions / channel /
  fullScreen，PermissionKind 扩悬浮窗与锁屏显示，AlarmPort 增加 fired 流），
  接口移入 application/delivery.dart（v0 的 notification/ 目录删除）；
  §4.1 登记 Routine / NotesReaderPort / 今日视图（D12）座位；附录 B 增加 metadata 键
  登记表与软删除（D11）；§10 第 9 条标记部分完成（接口 + ReminderDispatcher +
  NotificationWindowRule + 桌面适配器 + 桌面 shell 分层已实现并测试），
  新增第 10 条（UI 文档落地）。
  实现备注：桌面提醒链路改为 闹钟(Timer) → pollReminder → NotificationPort → UI 弹窗
  回流；原 20 秒 tick 降级为前台兜底轮询。
- **v1.4**（2026-10-07）：ui-interaction.md（v0.4）落地为代码——安卓 UI 阶段完成。
  要点——
  ① **§3.5 规划表全部转现状**：createTask 签名改造（deadline/工时可选、fixed 豁免
  A2、isCompleted 按 status）、pinToTop / pickForToday / returnToPool / setPoolOrder、
  软删除三件套（TaskRepository 增加 moveToTrash/loadTrash/restore/purgeTrash，
  Markdown 实现落 `tasks/.trash/` 子目录，loadAll 天然忽略）；新增
  snoozeUntil（绝对档位，决议 26）；事件流扩充 taskPinned/taskPicked/taskRestored/
  trashPurged。
  ② **Task**：deadline 可空（copyWith 增加 clearDeadline）、TaskType（fixed/flex）
  走 metadata `type` 键（附录 B 登记表 +type）；isCompleted 对 fixed 仅按 status
  判定；SlackScheduler 过滤 fixed 与无截止 flex（B1/B2 同步收窄）。
  ③ **codec**：应用自有 metadata 键（type/pinned/picked_for_today/pool_order）登记
  后**跟随任务对象写回**（值变则行变、键消失则行删），未知键仍原样往返——
  实现期发现的契约缺口：v1.3 的 metadata 是只读透传，无法承载需要持久化的
  应用自有键，本版补齐（§3.4 防线二的"写回"语义明确化）。
  ④ **application**：today_view.dart（buildTodayView/buildPoolView，D12）、
  notes_reader.dart（NotesReaderPort + 提取纯函数）、settings.dart（SettingsPort +
  AppSettings，落 tasks/settings.json）；ReminderDispatcher.windows 可由设置页
  经 updateWindows 更新（§4.3 送达策略运行时可改）。
  ⑤ **UI**：橙主题（§8）；今日清单（分组连续编号/逾期置顶/固定时点组/插队栈式/
  被挑散件弱化）、任务池（横线两段/拖拽整理持久化）、疑问笔记（只读提取）、
  创建对话框（长按滑档位 + 二分 + 点按降级三无）、堆三无、编辑展开表单（决议 17）、
  推迟档位菜单（决议 16/26）、日历弹窗（同弹窗下滑当天列表）、设置页（多段时段
  编辑/定期挑/回收站）；安卓壳（应用内悬浮侧边栏：把手/三页竖翻/重手势/隐私
  过头/Drawer 兜底/首次引导）。
  ⑥ **架构守卫**：66 个测试全绿（新增 android_ui_contract_test 15 个）；
  中文路径迁移已执行（附录 A），android/ 平台补建，Gradle 走 dl.google.com +
  阿里云镜像链。
  剩余：系统通知/精确闹钟/悬浮窗的安卓原生适配器（设备阶段）、周期任务（三期）、
  AI L2（三期）。
- **v1.5**（2026-10-08）：**安卓交付适配器 + 周期任务 + 主题预设落地，真机（模拟器）验证通过。**
  要点——
  ① **周期任务全链路**（决议 5/10/12/23/27）：domain/routine.dart（频率/时点/响不响/
  启用 + 纯函数发生计算）、repository/{routine_codec,routine_repository,
  markdown_routine_repository,memory_routine_repository}.dart（`routines.md`，一条规则
  一个 frontmatter 条目，字段级保真：未知字段/注释/正文原样）、application/routine_service.dart
  （规则增删改 + 当天实例生成/同步 + 发生查询，独立事件流）、TaskType 增加 **routine**
  （A2 豁免、仅按 status 判完成、不进 Slack 调度）、实例落 metadata
  `routine`/`routine_date`/`routine_remind`/`routine_skipped`；UI：设置页周期任务管理
  （增删改/启用/响不响/是否进池）、今日清单 ④『例行组』（连续编号，菜单=完成/跳过今天/
  编辑规则/删除规则，无推迟）、任务池计划段按"下一次发生"与任务混排（`PoolRow`）、
  日历打点 + 只读 + 跳『编辑规则』。
  ② **时点性提醒**（决议 3/18/26，v1.4 遗留缺口）：`PointReminder` + 
  `TaskService.nextPointReminder()`（不可推到点 + 设了响的周期实例；snooze 取
  max(deadline, snoozedUntil)；`point_fired` 保证只响一次；30 分钟补响宽限）、
  `ReminderEvent` 增加 `taskId` + `kind`、ReminderDispatcher 双源单闹钟（软提醒走
  送达策略、时点提醒原样响且可升闹钟渠道）。
  ③ **安卓适配器与原生侧**（§4.2/§4.3）：`android_adapters.dart`（MethodChannel
  `gtd/native` + 事件回流 `gtd/native/events`）+ Kotlin（MethodChannel 桥/通知渠道与
  带按钮通知/精确闹钟接收器/通知动作接收器/贴屏把手前台服务）；权限引导走
  permission_handler + 原生全屏 intent；任务目录选择走"所有文件访问 + 系统选择器"；
  目录引导值移入应用支持目录 `bootstrap.json`（`BootstrapPort`）。
  ④ **主题预设**（§8/§9 第 7 条）：4 套强调色种子（橙/墨蓝/苔绿/梅紫），状态语义色不变；
  `AppColors.accent` 由装配点按设置应用，切换即整体重建。
  ⑤ **实现期发现的契约缺口两处**：**(a)** `MarkdownTaskCodec._serializeFresh` 全新文件
  只写正式字段、**丢 metadata**——新建的 fixed/routine 任务落盘后重新加载会退化成普通
  flex（甚至因 0 工时被判定完成而消失）；模拟器实测抓到（例行组不显示），已修并加
  落盘回归测试；**(b)** 计划段若按 30 天展开周期发生会把池子冲垮且与今日清单重复，
  契约明确为"**每条规则只显示下一次发生，且不含当天**"。
  ⑥ **验证**：`flutter analyze` 干净；**92 个测试全绿**（新增 routine_test 18 个含落盘回归、
  point_reminder_test 8 个）；API 37 模拟器实测：权限引导状态、主题切换、系统级把手在其他
  App 上方可见、精确闹钟按时触发（`alarm fired taskId=… posted=true`）、通知带
  『完成/推迟 1 小时』按钮、点『完成』→ 任务文件 `status: completed`（写路径唯一生效）、
  今日清单例行组编号 4、池子计划段周期条目按日期插入。
  ⑦ **系统级把手的实测修订**（同一轮反馈后收紧，见 ui-interaction.md 决议 34）：
  把手的显示/停靠契约落地为——应用在前台隐藏（有应用内把手，不再盖住自己的面板）、
  只竖向移动且 x 恒贴边（斜拖不会被带离边缘）、停靠侧与 y 持久化（服务重启回原位）、
  旋屏重新贴边；并把"把手真实开关状态"新增为原生查询方法 `isOverlayHandleEnabled`，
  设置页开关据此显示，不再靠本地假设。
  剩余：跨 App 系统级**面板本体**（Flutter 常驻悬浮窗）、AI L2；局限见 §12。
- **v1.6**（2026-10-08）：**系统级悬浮面板本体落地**（用户实测反馈：把手拖出不该跳进应用）。
  要点——
  ① **第二个 Flutter 引擎**（`lib/overlay_main.dart`，DartEntrypoint `overlayMain`）跑在
  `OverlayHandleService` 里，全屏**透明** `TYPE_APPLICATION_OVERLAY` 窗口承载它的
  FlutterView：把手拖出 → 面板**在当前 App 上方就地展开**，日常操作不再离开当前 App。
  ② **panels 抽成一份共用**：新增 `lib/ui/panels/side_panel.dart`
  （`SidePanel` / `PanelActions` / `PanelPrivacyBar` / `PanelOnboardDialog` / `FloatingPanel`），
  应用内壳与悬浮窗宿主共用——落实 §5.1"panels 平台无关、只被 shell 摆放"。
  ③ **新通道 `gtd/overlay`**（§4.2 表）：`notifyReady` / `collapse` / `expand` /
  `openApp{target,routineId}` ↔ `state{expanded,dockedRight}`；进应用的唯一入口是
  面板头『设置』与实例菜单『编辑规则』（后者经 `AppController.onOpenSettingsRequested`
  转成 `openApp`）。
  ④ **边界写死**（§4.2）：交付类插座只在主引擎装配（单闹钟不抢）；写路径仍唯一
  （悬浮面板走自己的 TaskService，两引擎靠文件 watch + D9 合并同步）。
  ⑤ **契约缺口一处**：原实现只支持"把手 → 打开应用"，无法表达"就地展开"，
  故新增 `gtd/overlay` 通道与 `openApp` 语义；旧的 `overlayHandleOpened → 打开应用面板`
  只在原生降级（引擎/窗口创建失败）时使用。
  ⑥ **实现期发现并修掉的两个真 bug**（都会让功能完全不可用，已记入本版）：
  **(a) 把手从来没被创建**——`onStartCommand` 对 `ACTION_HOST_FOREGROUND/BACKGROUND`
  提前 return，而服务冷启动收到的第一个 intent 恰好就是它，于是 `addHandle()` 永远
  走不到（v1.5 就带进来的缺陷）；
  **(b) 第二个引擎的入口不在 kernel 里**——Dart 只编译从 `main.dart` **可达**的库，
  `overlay_main.dart` 没人引用 → 原生日志
  `Dart_LookupLibrary: library 'package:gtd_todo/overlay_main.dart' not found`；
  修法是 `main.dart` 里 `export 'overlay_main.dart';`（本文件 §5.1 依赖的那条组装规则，
  加注释防误删）。
  ⑦ **透明与 inset 的实测结论**：`FlutterSurfaceView(context, true)` +
  `PixelFormat.TRANSLUCENT` + `setZOrderOnTop` 在全屏 overlay 窗口里透明生效
  （无需退化为 TextureView）；**不要**用 `FLAG_LAYOUT_NO_LIMITS`
  （加了会把 `MediaQuery.padding` 归零、面板顶到状态栏底下），保留 `FLAG_LAYOUT_IN_SCREEN`
  即可拿到真实 inset。
  ⑧ **测试**：`flutter analyze` 干净；**97 个测试全绿**（新增 overlay_panel_test 4 个）。
  ⑨ **模拟器实测（独立复验，截图见 `docs/verify/`）**：
  `overlay entrypoint launched: library=package:gtd_todo/overlay_main.dart function=overlayMain`
  → 点把手后 `topResumedActivity` 仍是 nexuslauncher（**没跳进应用**）、面板浮在桌面之上
  且桌面壁纸/图标透过 25% 遮罩可见（`flow-2_panel_over_launcher.png`）→
  面板内「+」可弹创建对话框、**输入法正常升起**（`flow-6_dialog_typed.png`）→
  在面板里新建的任务真的落盘（`task-…md`，写路径唯一）→ 点遮罩收起、把手回来 →
  点面板齿轮才进应用并停在设置页（`flow-9_openapp_settings.png`）。
  新增局限：悬浮引擎不跑提醒调度、两引擎并发写（均见 §12）。

---

## 附录 A：安卓平台备忘（人话版）

| 黑话 | 人话 | 对架构的含义 |
|---|---|---|
| 沙盒 | 每个 app 一个带锁私人储物柜，别的 app 默认看不见 | "Obsidian 直接改文件"需要先取得文件夹访问许可 |
| 所有文件访问 vs SAF | 全屋钥匙（个人用省事，监听可用）vs 临时门卡（商店合规，但没"门铃"= 不能监听文件变化） | FolderPickerPort 两种实现；SAF 下 watch()=null → 降级为回前台刷新 |
| 后台冻结 / Doze | app 退后台会被系统冻结，Timer 停摆 | 提醒改由 AlarmPort 预约系统闹钟，到点由系统唤醒 |
| 精确闹钟权限 / 电池白名单 | 安卓 12+ 准点响铃要单独授权；省电模式会推迟闹钟 | PermissionPort 的职责范围 |
| 中文路径 | 部分开发/构建工具遇非 ASCII 路径出错（本项目已实测：分析器崩溃；Gradle 有前科） | 多平台开发建议项目挪纯 ASCII 路径。**状态：已执行（v1.4，2026-10-07）**——工作副本已复制到 `C:\Users\zzz\dev\gtd_todo`（纯 ASCII），并补建 `android/` 平台；原中文路径目录保留为旧快照（含迁移说明），分析与构建一律在新路径进行。另：本机 maven.google.com 不可达，`android/` 构建已配置 dl.google.com 官方 CDN + 阿里云镜像链 |

## 附录 B：Markdown 文件格式约定

**格式规范**：frontmatter 为**平铺的 `key: value` 行**（每行一个字段、标量值）；
不支持列表、嵌套、多行标量；注释行与未知字段行同属"非字段内容"，按字段级保真**原样保留**（§3.4）。
正文为自由 Markdown，享受字节级保真（正典见 §3.4 防线 1）。

- 一任务一个 `.md`，文件名 = `{id}.md`，集中在一个目录；
- **机读字段进 frontmatter，正文归人；应用只写机读字段，永不碰正文与其余内容**（D5）；
- 解析宽容：坏文件降级进 `warnings`，不崩溃。**warnings 流向**：v0 暂存于
  `repo.warnings` 仅供诊断；目标形态 = 进领域事件流 + UI"待整理"清单【规划】；
- 未知 frontmatter 字段必须无损往返（载体 = DecodeResult.unknownFields）。
- **软删除**：删除任务移入 `tasks/.trash/` 子目录（文件原样保留，Obsidian 可见可捞），
  `loadAll` 忽略该子目录；设置提供『清空回收』【规划，D11】。

**自有 metadata 键登记表**（§3.4 防线二：应用自有键在此登记，编码时跟随任务对象
改写/删除；其余未知键原样往返）【现状，v1.4 建立 / v1.5 扩充】：

| 键 | 语义 | 来源 |
|---|---|---|
| `type` | 任务类型：`fixed`（不可推）/ `flex`（可推，缺省不写）/ `routine`（周期实例，v1.5） | ui 文档 §4.1 / §10#1 |
| `pinned` | 插队标记：持久意图，保持到完成，栈式压顶（仅可推组），值 = 插队时刻 | ui 文档 §6.1 / 决议 9 |
| `picked_for_today` | 被挑散件标记（当日有效，值 = yyyy-MM-dd；手动挑过则当日自动挑让位） | ui 文档 §6.3 / 决议 8 |
| `pool_order` | 任务池显示序（仅整理，无调度含义，重启保留） | ui 文档决议 14 |
| `routine` | 周期实例所属规则 id | ui 文档决议 12 |
| `routine_date` | 周期实例的发生日（yyyy-MM-dd；今日清单按它筛『例行组』） | ui 文档决议 12 |
| `routine_remind` | 该实例的规则设了响（时点性提醒，只写 `true`） | ui 文档决议 18 |
| `routine_skipped` | 被"跳过今天"的那一天（yyyy-MM-dd；不完成、当天不再显示） | ui 文档决议 23 |
| `point_fired` | 已响过的那一次时点提醒（值 = 当时的到点时刻 ISO；改期/推迟后清除） | v1.5 实现（只到点响一次） |

**全新文件的写回**（v1.5 修正）：磁盘上还没有该任务文件时，编码必须写正式字段
**加上登记表里有值的 metadata 键**——否则新建的 fixed/routine 任务落盘后重新加载会
退化成普通 flex（0 工时 → 直接判完成而消失）。回归测试：
`test/routine_test.dart`「落盘回归」组。

### 附录 B-2：`routines.md`（周期规则文件）

与任务文件同目录的**独立文件**（TaskRepository/TaskCodec 不覆盖它），
**一条规则一个 frontmatter 条目**，条目之间用 `---` 分隔；条目正文是规则备注，
归人所有（应用只在规则备注被显式修改时改写它）：

```markdown
---
id: routine-1a2b
title: 晨跑
freq: weekly          # daily | weekly
weekdays: 1,3,5       # weekly 时的星期（1=周一 … 7=周日，逗号分隔标量）
time: 07:00           # 可选；缺行 = 不限时刻
remind: true          # 响不响（决议 18；true 必须有时刻）
enabled: true         # 启用开关
created: 2026-10-07T09:00
---

备注随便写：应用不改这一段（未知字段、注释、行顺序同样原样保留）。
```

- 解析宽容：缺 id/title 的条目记入 warnings 并跳过，不崩溃；
- 删除规则 = 从本文件移除该条目 + 清掉未完成的当天实例（已完成的历史留在任务目录）；
- 规则的当天实例是**普通任务文件**（`<规则id>-<yyyy-MM-dd>.md`，类型 `routine`），
  所以完成/跳过状态都落在任务这一侧，规则文件保持干净。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 唯一标识，时间戳+随机尾巴，同毫秒创建不撞 |
| `title` | string | 任务名 |
| `deadline` | ISO8601 本地时间，**可空** | 截止时刻（fixed=时点 / flex=截止 / 缺省行=散件） |
| `estimated_work` | int（分钟，≥1；fixed 豁免允许 0） | 预估工时（见 §3.2 A2） |
| `remaining_work` | int（分钟） | 剩余工时，调度的核心输入 |
| `importance` | int 1–5 | 重要度，与 deadline 分开对待 |
| `status` | enum | pending / active / snoozed / completed（overdue 派生，可不写） |
| `snoozed_until` | ISO8601，可选 | 用户 snooze 意图，持久化；语义见 D8 |
| `created` | ISO8601 | 创建时间 |
| `schema` | int（规划） | 迁移版本号，见 §3.4 防线三 |

示例：

```markdown
---
id: task-001
title: 完成 Agent 调度论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
importance: 3
status: active
created: 2026-10-07T15:30
type: fixed
---

正文随便写：背景、拆解、进展流水……应用永不改动这一段。
```
