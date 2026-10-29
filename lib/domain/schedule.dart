import 'dart:math' as math;

import 'task.dart';

/// **调度模式**（ui-interaction.md §7.0 / 决定卡 mode-as-information-depth）：
/// 用户可见的**两档**，一次只能选一个——它们是**一条信息深度的谱系**：
/// 上一档多问一样属性，多换一种能力。
///
/// - [manual] **无排序（新装默认）**：只问标题与日期。不跑调度算法，今日截止型组
///   只收"今天到期"的、顺序由人拖（`manual_order`），提醒是两站时点提醒
///   （`T − manual_lead_minutes` 与 `T`）。没有裕度、风险、不可行判定，也不做工时对账；
/// - [standard] **标准**：问工时。算法排先后，提醒按裕度节奏响。
///
/// **重要度不是档位**：它是标准档里的一个设置开关（`AppSettings.askImportance`），
/// 关掉时排序乘数取 1、表单里也不出现；打开即原来的"完整档"。以前它是一档，
/// 但两档之间那时只差这一处，等于拿一个表单开关冒充一个档位（2026-10-29 修订二）。
///
/// 两档都**不筛提醒**：有时间的任务一律提醒，响不响是任务自己的 metadata `remind`。
///
/// 两档都**不改任务数据**：档位是查询口径与算法入参，切档只重算，不迁移。
enum ScheduleMode {
  standard,
  manual;

  /// 设置落盘的稳定写法（缺省 [standard]）。
  ///
  /// 兜底不跟新装默认走：认不出的值只会出现在**已经存在**的设置文件里，
  /// 那种情况下把人的清单悄悄改成手动序比"保持原样"更糟。新装没有文件，
  /// 直接拿 `AppSettings.defaults`（无排序），不经过这里。
  ///
  /// 旧的 `full` 也落在这里（标准）——`AppSettings.fromJson` 另外把
  /// 『问重要度』一并打开，老用户的表单行为因此不变。
  static ScheduleMode byName(String? name) => switch (name) {
        'manual' => ScheduleMode.manual,
        _ => ScheduleMode.standard,
      };

  /// 无排序档：不跑调度、今日截止型组只认"今天到期"、顺序走手动序。
  bool get isManual => this == ScheduleMode.manual;
}

/// 手动序比较器（D17）：无排序模式下今日截止型组唯一的顺序来源。
///
/// 有 [manualOrder] 的按序号升序；没有的**沉在末尾**，用 id 升序裁决
/// （id 前缀定长 ≈ 创建先后，保证新任务从末尾开始、顺序稳定不抖）。
int compareManualOrder(Task a, Task b) {
  final oa = a.manualOrder;
  final ob = b.manualOrder;
  if (oa != null && ob != null) {
    final byOrder = oa.compareTo(ob);
    if (byOrder != 0) return byOrder;
  } else if (oa != null) {
    return -1;
  } else if (ob != null) {
    return 1;
  }
  return a.id.compareTo(b.id);
}

/// 风险尺度默认值 τ：1 个工作日（480 工作分钟）的额外裕度把风险压到 1/e。
const double defaultRiskScaleMinutes = 480;

/// 风险陡度默认值 γ：1 = 纯指数；γ>1 = 前半段更平、临界更陡。
const double defaultRiskGamma = 1;

/// 间隔拐点默认值：`α·slack` 撞到它之前按裕度线性缩短，撞到之后按对数放缓。
const int defaultIntervalPivotMinutes = 480;

/// 锚点沿用的宽限（v1.25）：旧锚点不早于 `now − 该时长` 才沿用，
/// 迟到更多视为"错过"（应用长时间没运行），按 `now + interval` 重算。
const Duration anchorCarryGrace = Duration(minutes: 30);

/// 锚点沿用（v1.25，C2 的另一半）：旧锚点不早于 `now − [anchorCarryGrace]`
/// 就原样沿用，否则返回 null 让调用方按 `now + interval` 重算。
///
/// 为什么要沿用：`nextReminderAt` 每次重锚都用 `now` 起算的话，任何一条命令
/// （哪怕与这件任务无关）都会把它的提醒往后推一格——用户越勤快地完成小事，
/// 最该响的那件越响不起来。
DateTime? carriedAnchor(DateTime? previous, DateTime now) {
  if (previous == null) return null;
  if (previous.isBefore(now.subtract(anchorCarryGrace))) return null;
  return previous;
}

/// 提醒锚点的**截止上限**：锚点排到截止之后没有行动价值——那一响的时候任务已经
/// 逾期，`schedulable` 转 false，此后不再提醒。夹到截止，保证"设了时间"至少响一次。
///
/// 三种情况会算出晚于截止的锚点：截止前来不及准备（裕度薄）、工时超过剩余可用
/// 时间（不可行）、锚点跨到非工作日。三种都不该把提醒推到逾期之后。
DateTime anchorWithinDeadline(DateTime anchor, DateTime deadline) =>
    anchor.isAfter(deadline) ? deadline : anchor;

/// 提醒间隔（工作分钟，domain 词汇的一部分，§3.1 公式）：**分两段**。
///
/// ```text
/// slack ≤ 0            → minInterval
/// α·slack ≤ pivot      → clamp(α·slack, min, pivot)
/// α·slack > pivot      → pivot × (1 + log₂(α·slack / pivot))
/// ```
///
/// 第一段是"每轮吃掉剩余裕度的一半"的几何递减；第二段是防"远期任务天天响"：
/// 硬顶会让裕度 3 天和裕度 3 个月的任务拿到同一个间隔，那等于给每件远期任务
/// 挂了个每日固定提醒。对数段让"每翻一倍裕度加一个拐点"，远期任务自然稀疏，
/// 且仍然随裕度**单调**（不会因为截断而让两件不同的任务同频）。
int reminderInterval(
  int slackMinutes, {
  double alpha = 0.5,
  int minIntervalMinutes = 30,
  int pivotMinutes = defaultIntervalPivotMinutes,
}) {
  if (slackMinutes <= 0) return minIntervalMinutes;
  final pivot = pivotMinutes < minIntervalMinutes ? minIntervalMinutes : pivotMinutes;
  final raw = alpha * slackMinutes;
  if (raw <= pivot) {
    return raw.round().clamp(minIntervalMinutes, pivot).toInt();
  }
  final doubled = math.log(raw / pivot) / math.ln2; // log₂(raw / pivot)
  final grown = pivot * (1 + doubled);
  // 兜底上限（16 个拐点 ≈ 17 个工作日）：防极端 deadline 让间隔大到"再也不响"。
  return grown.round().clamp(minIntervalMinutes, pivot * 16).toInt();
}

/// 风险函数（domain 词汇的一部分，§3.1 公式、D16）：**时间裕度 → 误期风险**（0,1]。
///
/// `risk = slack ≤ 0 ? 1 : exp(−(slack/τ)^γ)`
///
/// **非线性是刻意的**：线性要给 slack 凭空规定"到哪算 0"，还会算出负风险；
/// 指数族只要一个尺度 [scaleMinutes]，恒落在 (0,1]，而且"裕度还宽时催得少、
/// 裕度一薄就陡然变急"正是想要的手感。
double slackRisk(
  int slackMinutes, {
  double scaleMinutes = defaultRiskScaleMinutes,
  double gamma = defaultRiskGamma,
}) {
  if (slackMinutes <= 0) return 1;
  final scale = scaleMinutes <= 0 ? defaultRiskScaleMinutes : scaleMinutes;
  final x = slackMinutes / scale;
  final shaped = gamma == 1 ? x : math.pow(x, gamma).toDouble();
  final risk = math.exp(-shaped);
  if (risk.isNaN) return 1;
  return risk < 0 ? 0 : (risk > 1 ? 1 : risk);
}

/// 调度结果的数据类型（Scheduler 的输出，Application/UI 的输入）。
/// 纯数据，不包含任何 IO。
class TaskMetric {
  final String taskId;
  final TaskDisplayStatus displayStatus;

  /// 截止前剩余可工作分钟数。
  final int availableMinutes;

  /// slack = available - remaining，可为负。
  final int slackMinutes;

  /// 误期风险 `risk = f(slack)` ∈ (0,1]（**非线性**，v1.9 / D16）。
  final double risk;

  /// **调度优先级** = `risk × importance`（排序键，v1.9 / D16）。
  ///
  /// 派生值、不落盘；与内核属性文档里的 `priority` 键（**人定的优先级** =
  /// [Task.importance]）**同名不同物**：一个是输出，一个是输入（§3.2 B3）。
  final double priority;

  /// urgency = remaining / available。>1 表示按期已不可行。
  /// v1.9 起只是展示用（排序键换成了 [priority]），仍保留在派生指标里。
  final double urgency;

  /// **提醒锚点**：算法算出的"下一次该看它"的时刻（墙钟）；逾期为 null。
  ///
  /// 它只管"什么时候发"——响不响铃是任务自己的 metadata `remind`，在送达时
  /// 挑渠道（`ReminderChannel` 的 ring / silent），不进派生指标。
  final DateTime? nextReminderAt;

  /// 本次锚定的提醒间隔（工作分钟）。
  final int? intervalMinutes;

  const TaskMetric({
    required this.taskId,
    required this.displayStatus,
    required this.availableMinutes,
    required this.slackMinutes,
    required this.risk,
    required this.priority,
    required this.urgency,
    this.nextReminderAt,
    this.intervalMinutes,
  });
}

/// 展示/排序用的派生状态。注意 overdue 是派生事实，不要求写入存储。
enum TaskDisplayStatus { normal, infeasible, overdue, snoozed }

class ScheduleResult {
  final DateTime computedAt;

  /// 已按优先级排序：不可行 > 普通（**调度优先级**高在前）> 逾期 > 已推迟。
  final List<TaskMetric> items;

  /// 当前最值得做的任务。
  final String? nextTaskId;

  /// 全局**下一站提醒**（最早的各任务 [TaskMetric.nextReminderAt]）。
  ///
  /// 三档都产出；响不响在送达时才分（挑渠道），不在这里筛。
  final DateTime? nextReminderAt;
  final String? nextReminderTaskId;

  final List<String> infeasibleTaskIds;
  final List<String> overdueTaskIds;

  const ScheduleResult({
    required this.computedAt,
    required this.items,
    this.nextTaskId,
    this.nextReminderAt,
    this.nextReminderTaskId,
    this.infeasibleTaskIds = const [],
    this.overdueTaskIds = const [],
  });

  TaskMetric? metricOf(String taskId) {
    for (final m in items) {
      if (m.taskId == taskId) return m;
    }
    return null;
  }
}
