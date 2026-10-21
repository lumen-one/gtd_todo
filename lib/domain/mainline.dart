/// 主线（ui-interaction.md §6.9；存储格式见 architecture.md 附录 B.6）。
///
/// 三层边界：**主线与任务池不相交**——行为链上的步骤不是 Task，不进调度、
/// 不占工时、不响提醒；主线的"记录"也不进 `.gtd/log.md`（那是全 App 的操作
/// 流水）。所以这一整个文件都是纯 Dart，不认识 TaskService，也不认识 Flutter。
///
/// 一条主线 = 标题 + 一串步骤（行为链）+ 若干段记录（日历上的"圈"）。
/// 归档 = [Mainline.completedAt] 有值，**只改状态、不删数据**。
library;

/// 同一天（只看年月日）。
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 取当天零点（记录与日期比较一律按"天"算）。
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// 行为链上的一步。
///
/// **完成状态由复选框来**（[done]），[doneAt] 只是完成时刻：人在 Obsidian 里
/// 手改 `- [x] 某步` 而不写 `完成` 时，这一步算完成、但不进自动流水
/// （没有时刻就归不到哪一天，不猜）。
class MainlineStep {
  final String title;

  final bool done;

  /// 完成时刻；null = 完成但没有时刻（手改复选框的情形）。
  final DateTime? doneAt;

  /// 写在这一步上的备注——用户的"手写 log"挂在这里，不另存一份按天的日记。
  final String note;

  const MainlineStep({
    required this.title,
    this.done = false,
    this.doneAt,
    this.note = '',
  });

  MainlineStep copyWith({
    String? title,
    bool? done,
    DateTime? doneAt,
    bool clearDoneAt = false,
    String? note,
  }) {
    return MainlineStep(
      title: title ?? this.title,
      done: done ?? this.done,
      doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
      note: note ?? this.note,
    );
  }

  @override
  String toString() => 'MainlineStep($title, done: $done, at: $doneAt)';
}

/// 一段记录 = 日历上的一个圈：**连续**日期 + 圈里那段文字。
///
/// 起止只到"天"，且自动归一：结束早于开始时对调（手改文件写反了也不丢）。
class MainlineLog {
  final DateTime start;
  final DateTime end;

  final String text;

  const MainlineLog._({required this.start, required this.end, this.text = ''});

  factory MainlineLog.range({
    required DateTime start,
    required DateTime end,
    String text = '',
  }) {
    final a = dayOf(start);
    final b = dayOf(end);
    return a.isAfter(b)
        ? MainlineLog._(start: b, end: a, text: text)
        : MainlineLog._(start: a, end: b, text: text);
  }

  /// 这一段覆盖 [day] 吗（含两端）。
  bool covers(DateTime day) {
    final d = dayOf(day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  /// 覆盖的天数（至少 1）。
  int get dayCount => end.difference(start).inDays + 1;

  MainlineLog copyWith({DateTime? start, DateTime? end, String? text}) =>
      MainlineLog.range(
        start: start ?? this.start,
        end: end ?? this.end,
        text: text ?? this.text,
      );

  @override
  String toString() => 'MainlineLog($start~$end, $text)';
}

/// 一条主线。
class Mainline {
  final String id;
  final String title;
  final DateTime created;

  /// 归档时刻；null = 在跑（**同时只有一条**在跑）。
  final DateTime? completedAt;

  final List<MainlineStep> steps;
  final List<MainlineLog> logs;

  Mainline({
    required this.id,
    required this.title,
    required this.created,
    this.completedAt,
    List<MainlineStep> steps = const [],
    List<MainlineLog> logs = const [],
  })  : steps = List.unmodifiable(steps),
        logs = List.unmodifiable(logs);

  /// 新建一条（[stepTitles] 可直接给几步空链）。
  factory Mainline.fresh({
    required String id,
    required String title,
    required DateTime created,
    List<String> stepTitles = const [],
  }) {
    return Mainline(
      id: id,
      title: title,
      created: created,
      steps: [for (final t in stepTitles) MainlineStep(title: t)],
    );
  }

  bool get isActive => completedAt == null;

  int get totalSteps => steps.length;

  int get doneSteps => steps.where((s) => s.done).length;

  /// 0–1；没有步骤时是 0（空链不是"完成"）。
  double get progress => totalSteps == 0 ? 0 : doneSteps / totalSteps;

  /// **空链不算勾完**——否则新建一条空主线就能直接归档。
  bool get isAllDone => steps.isNotEmpty && doneSteps == totalSteps;

  String get progressText => '$doneSteps/$totalSteps';

  /// 下一个该做的步骤下标（第一个没勾的）；全勾完 / 空链 → null。
  int? get nextStepIndex {
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].done) return i;
    }
    return null;
  }

  /// 那天勾掉的步骤（自动流水；要求有完成时刻）。
  List<MainlineStep> stepsDoneOn(DateTime day) => [
        for (final s in steps)
          if (s.doneAt != null && isSameDay(s.doneAt!, day)) s,
      ];

  /// 覆盖那天的圈。
  List<MainlineLog> logsCovering(DateTime day) =>
      [for (final l in logs) if (l.covers(day)) l];

  /// 那天有没有内容（勾过步骤 / 圈覆盖）——日历格子的小点用它。
  bool hasActivityOn(DateTime day) =>
      stepsDoneOn(day).isNotEmpty || logsCovering(day).isNotEmpty;

  /// 记录按起始日升序（日历、归档列表都按这个顺序读）。
  List<MainlineLog> get logsInOrder =>
      [...logs]..sort((a, b) => a.start.compareTo(b.start));

  Mainline copyWith({
    String? title,
    DateTime? completedAt,
    bool clearCompleted = false,
    List<MainlineStep>? steps,
    List<MainlineLog>? logs,
  }) {
    return Mainline(
      id: id,
      title: title ?? this.title,
      created: created,
      completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
      steps: steps ?? this.steps,
      logs: logs ?? this.logs,
    );
  }

  @override
  String toString() =>
      'Mainline($id, $title, $progressText, ${logs.length} logs)';
}
