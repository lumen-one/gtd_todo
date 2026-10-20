import 'dart:math' as math;

import 'task.dart';

/// 提醒模式（ui-interaction.md §7.0、architecture.md D15）：
///
/// - [standard] **标准（默认）**：只排列不提醒——算法照常排出先后，但不给任务
///   产出"下一站"；只有显式开了提醒的任务（metadata `remind`）例外；
/// - [full] **完整**：现在的原方案——凡算法判定该响的都响。
///
/// 这是"**门槛**"不是"送达策略"：门槛决定**要不要**出声
/// （`nextReminderAt` 为 null 就是不出声），送达策略（NotificationWindowRule）
/// 决定出声时**什么时候**允许打扰；两者串联（D10 + D15）。
enum ReminderMode {
  standard,
  full;

  /// JSON/设置里的稳定写法（app 设置落盘用）。
  static ReminderMode byName(String? name) => switch (name) {
        'full' => ReminderMode.full,
        _ => ReminderMode.standard,
      };
}

/// **调度模式**（ui-interaction.md §7.0 / 决议 43，v1.12）：用户可见的**三档**，
/// 一次只能选一个——它们是**一条逐级弱化的谱系**，不是两个正交开关：
///
/// - [full] **完整**：算法排先后，且算法判定该响的都响；
/// - [standard] **标准（默认）**：算法仍排先后，但默认不出声——
///   只有显式开了『提醒我』的那一件才响；
/// - [manual] **无排序**：**标准的再弱化版**——标准那一套全保留（含不出声），
///   再把"算法排先后"这一层也去掉，今日可推组的顺序由人拖出来。
///
/// 无排序**不是**"把所有任务都塞进今天"：今日可推组的**成员与标准模式完全一致**
/// （仍按"提醒锚点落在今天 / 今天到期"准入），变的只有组内顺序。
/// 同样不动 `slack` / `risk` / `priority`、提醒锚点与间隔、逾期与不可行判定——
/// 它们管"多久响一次""要不要升级"，与"谁排前面"是两件事。
enum ScheduleMode {
  full,
  standard,
  manual;

  /// 设置落盘的稳定写法（缺省 [standard]：忘记传参数时得到的是现在这套行为）。
  static ScheduleMode byName(String? name) => switch (name) {
        'full' => ScheduleMode.full,
        'manual' => ScheduleMode.manual,
        _ => ScheduleMode.standard,
      };

  /// 映射成内核的**提醒门槛**：只有完整档放行，标准与无排序都是"只排列不提醒"。
  ReminderMode get reminderMode =>
      this == ScheduleMode.full ? ReminderMode.full : ReminderMode.standard;

  /// 是否关掉排序（今日可推组改用手动序）。
  bool get isManual => this == ScheduleMode.manual;
}

/// 手动序比较器（D17）：无排序模式下今日可推组唯一的顺序来源。
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

/// 该任务在 [mode] 下是否**允许出声**（architecture.md §3.2 规则 B4 的正典实现）。
///
/// 完整模式 = 恒真；标准模式 = 这一件被显式要求提醒过（[Task.reminderRequested]：
/// metadata `remind`，或周期实例的规则设了响——那也是人对这一件开了口）。
bool reminderAllowed(Task task, ReminderMode mode) =>
    mode == ReminderMode.full || task.reminderRequested;

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
  /// 它**不问模式**——"今天该看哪几件"是调度问题（今日清单准入用它），
  /// "会不会出声"看 [reminds]（v1.9）。
  final DateTime? nextReminderAt;

  /// 在当前提醒模式下，这件事**会不会出声**（提醒门槛，D15）。
  final bool reminds;

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
    this.reminds = false,
    this.intervalMinutes,
  });

  /// 真正**会响**的时刻 = 门槛 ∩ 锚点；不出声 → null。
  DateTime? get reminderAt => reminds ? nextReminderAt : null;
}

/// 展示/排序用的派生状态。注意 overdue 是派生事实，不要求写入存储。
enum TaskDisplayStatus { normal, infeasible, overdue, snoozed }

class ScheduleResult {
  final DateTime computedAt;

  /// 已按优先级排序：不可行 > 普通（**调度优先级**高在前）> 逾期 > 已推迟。
  final List<TaskMetric> items;

  /// 当前最值得做的任务。
  final String? nextTaskId;

  /// 全局**下一站会响的提醒**（最早的各任务 [TaskMetric.reminderAt]）。
  ///
  /// 标准模式下通常为 null（没有任务被显式要求提醒，或开了提醒的都还没到点）——
  /// 单闹钟、前台轮询、通知链路据此天然安静，不必各自判断模式（D15）。
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
