import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';

/// 参数自描述（§4.1）：算法声明自己的参数，设置页据此自动渲染；
/// AI（L2）只允许在 [min, max] 范围内调参。
class ParamSpec {
  final String key;
  final String label;
  final String hint;
  final num min;
  final num max;
  final num defaultValue;

  const ParamSpec({
    required this.key,
    required this.label,
    required this.hint,
    required this.min,
    required this.max,
    required this.defaultValue,
  });
}

/// 调度器抽象。可替换（SlackPriorityScheduler / SlackScheduler / EDF / LST / AI-assisted ...）。
///
/// 原则：Scheduler 不依赖 UI、Markdown、Notification；纯计算、无 IO；
/// 时间从外部注入，因此可以在不启动 Flutter 的情况下做单元测试
/// 和"推迟序列"重放仿真。
abstract class Scheduler {
  String get id;

  String get displayName;

  List<ParamSpec> get params;

  /// [anchors] 是**锚点表**（v1.25，C2 的另一半）：调用方（TaskService）把上次算出的
  /// 锚点按任务 id 存着，这里能沿用就沿用——`nextReminderAt` 只在这件任务自己变了
  /// 或旧锚点迟到太多时才重算。没有它的话，每条命令都会把别人的提醒往后推一格。
  /// 算法本身仍然无状态：锚点是**入参**，不是内部字段。
  ///
  /// [weightImportance]：排序键要不要乘 `Task.importance`（缺省 true）。
  /// 设置里的『问重要度』关掉时传 false——乘数取 1，整个维度不参与排序，
  /// 已存的值原样留着。这是**算法参数**（和工时日历、锚点同级），不是调度模式：
  /// 两档之间谁排前面仍然只由这里算，"不排序"那一档压根不调用本方法。
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
    Map<String, DateTime> anchors = const {},
    bool weightImportance = true,
  });
}

/// 旧算法 [SlackScheduler] 的可调参数（不要硬编码在算法内部）。
class SlackSchedulerConfig {
  /// 每次提醒消耗剩余裕度的比例。0.5 = 每轮提醒吃掉一半 slack。
  final double alpha;

  /// 最小提醒间隔（工作分钟）：低于这个时长的提醒没有行动价值。
  final int minIntervalMinutes;

  /// 间隔拐点（工作分钟）：`α·slack` 撞到它之前线性缩短，撞到之后按对数放缓
  /// （每翻一倍裕度加一个拐点）。默认 1 个工作日（480 分钟）。
  final int maxIntervalMinutes;

  const SlackSchedulerConfig({
    this.alpha = 0.5,
    this.minIntervalMinutes = 30,
    this.maxIntervalMinutes = 480,
  });
}
