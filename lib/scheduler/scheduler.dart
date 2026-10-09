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
    required this.min,
    required this.max,
    required this.defaultValue,
    this.hint = '',
  });
}

/// 调度器抽象。可替换（SlackScheduler / EDF / LST / AI-assisted ...）。
///
/// 原则：Scheduler 不依赖 UI、Markdown、Notification；纯计算、无 IO；
/// 时间从外部注入，因此可以在不启动 Flutter 的情况下做单元测试
/// 和"推迟序列"重放仿真。
abstract class Scheduler {
  String get id;

  String get displayName;

  List<ParamSpec> get params;

  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
  });
}

/// SlackScheduler 的可调参数（不要硬编码在算法内部）。
class SlackSchedulerConfig {
  /// 每次提醒消耗剩余裕度的比例。0.5 = 每轮提醒吃掉一半 slack。
  final double alpha;

  /// 最小提醒间隔（工作分钟）：低于这个时长的提醒没有行动价值。
  final int minIntervalMinutes;

  /// 最大提醒间隔（工作分钟）：裕度再大也不能退化成"几小时一响的固定提醒"。
  /// 默认 1 个工作日（480 分钟）。
  final int maxIntervalMinutes;

  const SlackSchedulerConfig({
    this.alpha = 0.5,
    this.minIntervalMinutes = 30,
    this.maxIntervalMinutes = 480,
  });
}
