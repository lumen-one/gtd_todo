import '../domain/plan.dart';
import 'plan_codec.dart';

/// `编排.md` 编解码（formatId: `md-plan/1`，格式见 docs/formats/plan.md）。
///
/// 文件结构：**一天一段**，段标题是 `### yyyy-MM-dd`（`##` 也认），段内一行一条：
///
/// ```markdown
/// ### 2026-10-22
///
/// - 08:30 晨会
/// - 09:30 项目评审
/// - 12:30 午餐休息
/// - 临时插进来的事
/// ```
///
/// 行序就是顺序，编码时**不按时刻重排**。**正文不保真**：不属于日期段或条目行的
/// 自由文字保存时消失（局限登记在 B.7）。解析永不抛异常：认不出的行直接跳过。
class MarkdownPlanCodec implements PlanCodec {
  @override
  String get formatId => 'md-plan/1';

  /// 条目行：`- ` / `* ` 开头。`- [ ]` 这种复选框行不认——那不是编排。
  static final RegExp _bullet = RegExp(r'^[-*]\s+(.*)$');

  /// 时刻锚点：行首的 `H:mm` / `HH:mm`，后面必须还有标题。
  static final RegExp _time = RegExp(r'^(\d{1,2}):(\d{2})\s+(\S.*)$');

  @override
  PlanDecodeResult decode(String raw) {
    final entries = <String, List<PlanEntry>>{};
    final dayOf = <String, DateTime>{};
    final warnings = <String>[];
    String? currentKey;

    for (final line in raw.split('\n')) {
      final text = line.replaceAll('\r', '').trim();
      if (text.isEmpty) continue;

      if (text.startsWith('#')) {
        final day = _parseDayHeading(text);
        currentKey = day == null ? null : planDayKey(day);
        if (day != null && currentKey != null) {
          entries.putIfAbsent(currentKey, () => []);
          dayOf[currentKey] = day;
        }
        continue;
      }

      // 段外的自由文字：忽略（保存时消失，B.7 已登记）。
      final key = currentKey;
      if (key == null) continue;

      final bullet = _bullet.firstMatch(text);
      if (bullet == null) continue;
      final entry = _parseEntry(bullet.group(1)!.trim());
      if (entry == null) {
        warnings.add('编排.md: 跳过空条目');
        continue;
      }
      entries[key]!.add(entry);
    }

    final days = [
      for (final e in entries.entries) DayPlan(day: dayOf[e.key]!, entries: e.value),
    ]..sort((a, b) => b.day.compareTo(a.day));
    return PlanDecodeResult(days, warnings);
  }

  @override
  String encode(List<DayPlan> days) {
    final sorted = [...days]..sort((a, b) => b.day.compareTo(a.day));
    final out = StringBuffer();
    for (final d in sorted) {
      if (d.entries.isEmpty) continue; // 空的一天不落行，文件不留空段
      out.write('### ${planDayKey(d.day)}\n\n');
      for (final e in d.entries) {
        final time = e.timeText;
        final title = _oneLine(e.title);
        out.write(time == null ? '- $title\n' : '- $time $title\n');
      }
      out.write('\n');
    }
    final text = out.toString().trimRight();
    return text.isEmpty ? '' : '$text\n';
  }

  // ---------- 内部 ----------

  /// `### 2026-10-22` → 当天零点；标题不是日期就返回 null。
  static DateTime? _parseDayHeading(String line) {
    final text = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// 一行条目 → 一条编排。时刻越界（`25:00`）按"没有时刻"处理，原文留在标题里。
  static PlanEntry? _parseEntry(String body) {
    if (body.isEmpty) return null;
    final m = _time.firstMatch(body);
    if (m != null) {
      final hour = int.parse(m.group(1)!);
      final minute = int.parse(m.group(2)!);
      if (hour <= 23 && minute <= 59) {
        return PlanEntry(
          minutesOfDay: hour * 60 + minute,
          title: m.group(3)!.trim(),
        );
      }
    }
    return PlanEntry(title: body);
  }

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}
