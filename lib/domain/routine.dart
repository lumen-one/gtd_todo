/// 周期任务规则（ui-interaction.md §1/§7.1、决议 5/10/12/27）。
///
/// 规则不是任务：它住在任务目录下独立的 `routines.md`（一条规则一个
/// frontmatter 条目，Obsidian 可直接看改），每天由应用生成**当天实例**
/// （实例才是 Task，见 TaskType.routine）。规则本身：
/// - **不占工时**、不进 ScheduleResult 排序（决议 5）；
/// - 响不响单独设置（`remind`）：设了响 = 时点性提醒，到点走系统闹钟；
/// - 纯 Dart，不依赖 Flutter / IO。
library;

/// 频率（决议 5：每天 / 每周 X）。
enum RoutineFrequency { daily, weekly }

/// 星期常量（1 = 周一 … 7 = 周日，与 Dart `DateTime.weekday` 一致）。
const List<String> weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 一次具体发生（决议 24/27）：任务池计划段插入、日历打点都用它。
class RoutineOccurrence {
  final Routine routine;
  final DateTime at;

  const RoutineOccurrence({required this.routine, required this.at});
}

class Routine {
  final String id;
  final String title;

  /// 备注（生成实例时进实例正文，Obsidian 里可读）。
  final String description;

  final RoutineFrequency frequency;

  /// weekly 的星期集合（1–7，升序去重）；daily 忽略。
  final List<int> weekdays;

  /// 当天发生时刻（分钟数 0–1439）；null = 不限时刻。
  final int? minuteOfDay;

  /// 响不响（§7.1：周期任务响不响单独设置）。true 时 [minuteOfDay] 必须存在。
  final bool remind;

  /// 启用开关（暂停后不再生成实例，规则保留）。
  final bool enabled;

  final DateTime created;

  /// 未知 frontmatter 字段（§3.4 字段级保真的载体：原样往返）。
  final Map<String, String> extra;

  const Routine({
    required this.id,
    required this.title,
    this.description = '',
    this.frequency = RoutineFrequency.daily,
    this.weekdays = const [],
    this.minuteOfDay,
    this.remind = false,
    this.enabled = true,
    required this.created,
    this.extra = const {},
  });

  /// 契约校验（RoutineService 在写入前调用，违反抛 ArgumentError）。
  void validate() {
    if (title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', '周期任务标题不能为空');
    }
    if (frequency == RoutineFrequency.weekly && weekdays.isEmpty) {
      throw ArgumentError.value(weekdays, 'weekdays', '每周频率必须选至少一天');
    }
    final m = minuteOfDay;
    if (m != null && (m < 0 || m > 1439)) {
      throw ArgumentError.value(m, 'minuteOfDay', '时刻必须在 0–1439 分钟内');
    }
    if (remind && m == null) {
      throw ArgumentError('设了响的周期任务必须有时刻（到点才响）');
    }
  }

  bool get hasTime => minuteOfDay != null;

  /// 时点性提醒（到点响一次，决议 18）。
  bool get isPointReminder => remind && minuteOfDay != null;

  String get timeText {
    final m = minuteOfDay;
    if (m == null) return '不限时刻';
    final h = (m ~/ 60).toString().padLeft(2, '0');
    final mm = (m % 60).toString().padLeft(2, '0');
    return '$h:$mm';
  }

  String get frequencyText {
    switch (frequency) {
      case RoutineFrequency.daily:
        return '每天';
      case RoutineFrequency.weekly:
        final sorted = [...weekdays]..sort();
        return '每周${sorted.map((d) => weekdayLabels[d - 1]).join('、')}';
    }
  }

  /// 该规则在 [day] 是否发生（不含 enabled 判定之外的其它约束）。
  bool occursOn(DateTime day) {
    if (!enabled) return false;
    switch (frequency) {
      case RoutineFrequency.daily:
        return true;
      case RoutineFrequency.weekly:
        return weekdays.contains(day.weekday);
    }
  }

  /// 该规则在 [day] 的发生时刻；不限时刻 → null。
  DateTime? occurrenceAt(DateTime day) {
    final m = minuteOfDay;
    if (m == null) return null;
    return DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
  }

  /// [from] 当天（含，由 [includeToday] 决定）起的下一次发生时刻。
  /// 不限时刻的规则返回当天零点。找不到（如一年内无匹配）返回 null。
  DateTime? nextOccurrence(DateTime from, {bool includeToday = true}) {
    if (!enabled) return null;
    var day = DateTime(from.year, from.month, from.day);
    if (!includeToday) day = day.add(const Duration(days: 1));
    for (var i = 0; i < 366; i++) {
      if (occursOn(day)) return occurrenceAt(day) ?? day;
      day = DateTime(day.year, day.month, day.day + 1);
    }
    return null;
  }

  Routine copyWith({
    String? title,
    String? description,
    RoutineFrequency? frequency,
    List<int>? weekdays,
    int? minuteOfDay,
    bool clearTime = false,
    bool? remind,
    bool? enabled,
    Map<String, String>? extra,
  }) {
    return Routine(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      frequency: frequency ?? this.frequency,
      weekdays: weekdays ?? this.weekdays,
      minuteOfDay: clearTime ? null : (minuteOfDay ?? this.minuteOfDay),
      remind: remind ?? this.remind,
      enabled: enabled ?? this.enabled,
      created: created,
      extra: extra ?? this.extra,
    );
  }
}
