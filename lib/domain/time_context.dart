/// 时间系统：跳过休息时间的工时日历。
///
/// "现实时间"不等于"工作时间"。所有调度计算（可用工时、间隔、snooze）
/// 都在这套日历上进行，结果的墙钟时刻永远落在工作窗内。
/// 纯 Dart，不依赖 Flutter / IO。
class WorkWindow {
  /// 当天自 00:00 起的分钟数，[start, end)。
  final int startMinute;
  final int endMinute;

  const WorkWindow(this.startMinute, this.endMinute);
}

class WorkTimeRule {
  /// key 为 DateTime.monday..sunday（1..7）。
  final Map<int, List<WorkWindow>> weekly;

  /// 节假日（未来支持），按日期匹配，忽略时刻。
  final List<DateTime> holidays;

  const WorkTimeRule({required this.weekly, this.holidays = const []});

  /// 默认规则：周一至周五 09:00-12:00、13:30-18:00。
  static const WorkTimeRule standard = WorkTimeRule(weekly: {
    DateTime.monday: [WorkWindow(9 * 60, 12 * 60), WorkWindow(13 * 60 + 30, 18 * 60)],
    DateTime.tuesday: [WorkWindow(9 * 60, 12 * 60), WorkWindow(13 * 60 + 30, 18 * 60)],
    DateTime.wednesday: [WorkWindow(9 * 60, 12 * 60), WorkWindow(13 * 60 + 30, 18 * 60)],
    DateTime.thursday: [WorkWindow(9 * 60, 12 * 60), WorkWindow(13 * 60 + 30, 18 * 60)],
    DateTime.friday: [WorkWindow(9 * 60, 12 * 60), WorkWindow(13 * 60 + 30, 18 * 60)],
  });

  bool isWorkDay(DateTime d) {
    if (holidays.any((h) =>
        h.year == d.year && h.month == d.month && h.day == d.day)) {
      return false;
    }
    return weekly[d.weekday]?.isNotEmpty ?? false;
  }

  /// [a, b) 之间的可工作分钟数。
  int workMinutesBetween(DateTime a, DateTime b) {
    if (!b.isAfter(a)) return 0;
    var minutes = 0;
    var day = DateTime(a.year, a.month, a.day);
    final lastDay = DateTime(b.year, b.month, b.day);
    while (!day.isAfter(lastDay)) {
      final windows = weekly[day.weekday];
      if (isWorkDay(day) && windows != null) {
        for (final w in windows) {
          final ws = day.add(Duration(minutes: w.startMinute));
          final we = day.add(Duration(minutes: w.endMinute));
          final s = a.isAfter(ws) ? a : ws;
          final e = b.isBefore(we) ? b : we;
          if (e.isAfter(s)) minutes += e.difference(s).inMinutes;
        }
      }
      day = day.add(const Duration(days: 1));
    }
    return minutes;
  }

  /// [t] 之后（若 t 正处于某工作窗内，则该窗结束后）的下一个工作窗开始时刻。
  /// 用于 D8 的"到下个工作窗"snooze 语义。
  DateTime nextWindowStart(DateTime t) {
    var day = DateTime(t.year, t.month, t.day);
    for (var scanned = 0; scanned < 3660; scanned++) {
      final windows = (weekly[day.weekday] ?? const <WorkWindow>[]).toList();
      if (isWorkDay(day) && windows.isNotEmpty) {
        windows.sort((a, b) => a.startMinute.compareTo(b.startMinute));
        for (final w in windows) {
          final ws = day.add(Duration(minutes: w.startMinute));
          if (ws.isAfter(t)) return ws;
          // t 在本窗内或本窗已过 → 继续找后面的窗
        }
      }
      day = day.add(const Duration(days: 1));
    }
    return t; // 兜底：规则里没有工作窗
  }

  /// 从 t 起消耗 [minutes] 个工作分钟后的墙钟时刻。
  /// 结果自动落在工作窗内（落在休息时间会被推进到下一个工作窗）。
  DateTime addWorkMinutes(DateTime t, int minutes) {
    if (minutes <= 0) return t;
    var remaining = minutes;
    var day = DateTime(t.year, t.month, t.day);
    // 防御：规则里一个工作窗都没有时避免死循环（约 10 年）。
    var daysScanned = 0;
    while (daysScanned < 3660) {
      final windows = weekly[day.weekday];
      if (isWorkDay(day) && windows != null) {
        for (final w in windows) {
          final ws = day.add(Duration(minutes: w.startMinute));
          final we = day.add(Duration(minutes: w.endMinute));
          final start = t.isAfter(ws) ? t : ws;
          final avail = we.difference(start).inMinutes;
          if (avail <= 0) continue;
          if (remaining <= avail) {
            return start.add(Duration(minutes: remaining));
          }
          remaining -= avail;
        }
      }
      day = day.add(const Duration(days: 1));
      daysScanned++;
    }
    return day;
  }
}
