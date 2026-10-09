/// 通知时间段（§4.3 / D10）：application 层的**送达策略**。
///
/// 与 WorkTimeRule（domain，工时产能）严格解耦：slack 数学的 nextReminderAt
/// 永远锚在工作窗内；本规则只裁决"这个时刻能不能真正打扰用户"——
/// 落在静默段 → 顺延到下一时段开头（只顺延、不吞掉）；
/// 绝对档位（明早 9 点 / 自选）不经本规则、原样响。
class NotificationWindow {
  /// 当天自 00:00 起的分钟数，[start, end)。
  final int startMinute;
  final int endMinute;

  const NotificationWindow(this.startMinute, this.endMinute)
      : assert(startMinute >= 0 && startMinute < 24 * 60),
        assert(endMinute > startMinute && endMinute <= 24 * 60);

  bool contains(int minuteOfDay) =>
      minuteOfDay >= startMinute && minuteOfDay < endMinute;
}

class NotificationWindowRule {
  /// 按 startMinute 升序（调用方保证）。
  final List<NotificationWindow> windows;

  const NotificationWindowRule(this.windows);

  /// UI 文档决议 4：默认一段 9:00–21:00。
  static const NotificationWindowRule defaultRule =
      NotificationWindowRule([NotificationWindow(9 * 60, 21 * 60)]);

  /// 不限制：全天生效（空段列表的语义）。
  static const NotificationWindowRule always =
      NotificationWindowRule([]);

  /// [t] 的送达时刻：空规则 → 原样；t 落在段内 → 原样；
  /// 段外 → 顺延到下一个时段开头（可能跨天）。D10：只顺延、不吞掉。
  DateTime resolveDelivery(DateTime t) {
    if (windows.isEmpty) return t;
    final minuteOfDay = t.hour * 60 + t.minute;
    final day = DateTime(t.year, t.month, t.day);
    for (var i = 0; i < 3660; i++) {
      final d = day.add(Duration(days: i));
      for (final w in windows) {
        if (i == 0) {
          if (w.contains(minuteOfDay)) return t;
          if (w.startMinute <= minuteOfDay) continue; // 今天的段已过
        }
        final ws = d.add(Duration(minutes: w.startMinute));
        if (ws.isAfter(t)) return ws;
      }
    }
    return t; // 兜底，不可达
  }
}
