import '../domain/mainline.dart';
import 'mainline_codec.dart';

/// `主线.md` 编解码（formatId: `md-mainline/1`，格式见 architecture.md 附录 B.6）。
///
/// 文件结构：**一条主线一个 frontmatter 块**，块与块之间是正文：
///
/// ```markdown
/// ---
/// id: ml-20261021-4f2a
/// title: 论文冲刺
/// created: 2026-10-18T09:00
/// ---
///
/// ### 行为链
///
/// - [ ] 列提纲
/// - [x] 写第三章 完成 2026-10-19,21:30 备注：卡了两小时
///
/// ### 记录
///
/// - 2026-10-19 ~ 2026-10-21 连续三天都在写第三章
///
/// ### 月记
///
/// - 2026-10 这个月把第三章写完
/// ```
///
/// 保真：应用拥有的 frontmatter 字段**原地改写**，未知字段/注释/空行原样保留
/// （与 routines.md 同档）。**正文不保真**——它本身就是数据，保存时按模型重写
/// （局限登记在 B.6）。解析永不抛异常：坏条目记告警后跳过。
///
/// 月记（`### 月记`）与记录的分工见 `docs/decisions/2026-10-25-mainline-month-note.md`：
/// 月记不覆盖任何一天，所以它单独一段、单独一行格式。
class MarkdownMainlineCodec implements MainlineCodec {
  /// 应用拥有的 frontmatter 字段。
  static const List<String> _ownedKeys = ['id', 'title', 'created', 'completed'];

  @override
  String get formatId => 'md-mainline/1';

  @override
  bool canDecode(String raw) => raw.contains('---');

  @override
  MainlineDecodeResult decode(String raw) {
    final mainlines = <Mainline>[];
    final warnings = <String>[];
    for (final block in _parse(raw)) {
      final id = block.fields['id']?.trim();
      final title = block.fields['title']?.trim();
      if (id == null || id.isEmpty) {
        warnings.add('主线.md: 跳过缺少 id 的条目');
        continue;
      }
      if (title == null || title.isEmpty) {
        warnings.add('主线.md: $id 缺少 title，已跳过');
        continue;
      }
      final steps = <MainlineStep>[];
      final logs = <MainlineLog>[];
      final monthNotes = <MainlineMonthNote>[];
      var mode = _Section.other;
      for (final line in block.bodyLines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final section = _sectionOf(t);
        if (section != null) {
          mode = section;
          continue;
        }
        if (t.startsWith('#')) {
          mode = _Section.other; // 人加的别的小标题：这一段不认
          continue;
        }
        if (mode == _Section.steps && t.startsWith('- [')) {
          steps.add(_parseStep(t));
        } else if (mode == _Section.logs && t.startsWith('- ')) {
          final log = _parseLog(t);
          if (log != null) logs.add(log);
        } else if (mode == _Section.months && t.startsWith('- ')) {
          final note = _parseMonthNote(t);
          if (note != null) {
            // 手写重复行时后者为准（一个月只留一条）
            monthNotes.removeWhere((n) => n.isFor(note.year, note.month));
            monthNotes.add(note);
          }
        }
      }
      mainlines.add(Mainline(
        id: id,
        title: title,
        created: _parseIso(block.fields['created']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        completedAt: _parseIso(block.fields['completed']),
        steps: steps,
        logs: logs,
        months: monthNotes,
      ));
    }
    return MainlineDecodeResult(mainlines, warnings);
  }

  @override
  String encode(List<Mainline> mainlines, {String? originalRaw}) {
    final blocks = <String, _Block>{};
    if (originalRaw != null) {
      for (final b in _parse(originalRaw)) {
        final id = b.fields['id']?.trim();
        if (id != null && id.isNotEmpty) blocks[id] = b;
      }
    }
    final out = StringBuffer();
    for (var i = 0; i < mainlines.length; i++) {
      final m = mainlines[i];
      final b = blocks[m.id];
      final front = <String>[];
      final written = <String>{};
      if (b != null) {
        for (final line in b.frontLines) {
          final key = _keyOf(line);
          if (key != null && _ownedKeys.contains(key)) {
            final value = _value(m, key);
            if (value == null) continue; // completed 被清 → 整行移除
            front.add(_withCr('$key: $value', line));
            written.add(key);
          } else {
            front.add(line); // 未知字段 / 注释 / 空行：原样保留
          }
        }
      }
      for (final key in _ownedKeys) {
        if (written.contains(key)) continue;
        final value = _value(m, key);
        if (value == null) continue;
        front.add('$key: $value');
      }
      out.write('---\n${front.join('\n')}\n---\n');
      out.write('\n### 行为链\n\n');
      for (final s in m.steps) {
        out.write('${_encodeStep(s)}\n');
      }
      out.write('\n### 记录\n\n');
      for (final l in m.logsInOrder) {
        out.write('${_encodeLog(l)}\n');
      }
      // 一个月都没写就不留空段：老文件保存后形状不变。
      if (m.months.isNotEmpty) {
        out.write('\n### 月记\n\n');
        for (final n in m.monthsInOrder) {
          out.write('${_encodeMonthNote(n)}\n');
        }
      }
      if (i != mainlines.length - 1) out.write('\n');
    }
    return out.toString();
  }

  // ---------- 行级编解码 ----------

  static String _encodeStep(MainlineStep s) {
    final b = StringBuffer('- [${s.done ? 'x' : ' '}] ${_oneLine(s.title)}');
    final at = s.doneAt;
    if (at != null) b.write(' 完成 ${_fmtDateTime(at)}');
    if (s.note.trim().isNotEmpty) b.write(' 备注：${_oneLine(s.note)}');
    return b.toString();
  }

  static String _encodeLog(MainlineLog l) {
    final head = isSameDay(l.start, l.end)
        ? _fmtDate(l.start)
        : '${_fmtDate(l.start)} ~ ${_fmtDate(l.end)}';
    final text = _oneLine(l.text).trim();
    return text.isEmpty ? '- $head' : '- $head $text';
  }

  static String _encodeMonthNote(MainlineMonthNote n) {
    final head = '${n.year.toString().padLeft(4, '0')}-${_two(n.month)}';
    final text = _oneLine(n.text).trim();
    return text.isEmpty ? '- $head' : '- $head $text';
  }

  /// 一行复选框 → 步骤。字段从右往左剥：先 `备注：`，再 `完成 <时刻>`，
  /// 剩下的全是标题（标题里带空格、带"完成"字样都不影响，因为锚点在最右）。
  static MainlineStep _parseStep(String line) {
    final m = RegExp(r'^-\s*\[( |x|X)\]\s*(.*)$').firstMatch(line);
    if (m == null) return const MainlineStep(title: '');
    var rest = m.group(2)!.trim();
    var note = '';
    final noteIdx = rest.lastIndexOf('备注：');
    if (noteIdx >= 0) {
      note = rest.substring(noteIdx + 3).trim();
      rest = rest.substring(0, noteIdx).trim();
    }
    DateTime? doneAt;
    final doneIdx = rest.lastIndexOf(' 完成 ');
    if (doneIdx >= 0) {
      final tail = rest.substring(doneIdx + 4).trim();
      final token = tail.split(RegExp(r'\s+')).first;
      doneAt = _parseMoment(token);
      if (doneAt != null) rest = rest.substring(0, doneIdx).trim();
    }
    return MainlineStep(
      title: rest,
      done: m.group(1)!.toLowerCase() == 'x',
      doneAt: doneAt,
      note: note,
    );
  }

  /// 一行记录 → 圈。行首必须是日期，否则算人写的自由文字（忽略）。
  static MainlineLog? _parseLog(String line) {
    final m = RegExp(
      r'^-\s*(\d{4}-\d{2}-\d{2})(?:\s*~\s*(\d{4}-\d{2}-\d{2}))?\s*(.*)$',
    ).firstMatch(line);
    if (m == null) return null;
    final start = _parseDate(m.group(1)!);
    final end = _parseDate(m.group(2) ?? m.group(1)!);
    if (start == null || end == null) return null;
    return MainlineLog.range(start: start, end: end, text: m.group(3)!.trim());
  }

  /// 一行月记 → 月记。行首必须是 `年-月`（两位数月份），否则忽略。
  ///
  /// 与 [_parseLog] 的日期行不撞：那边要完整的 `年-月-日`，`2026-10` 匹配不上。
  static MainlineMonthNote? _parseMonthNote(String line) {
    final m =
        RegExp(r'^-\s*(\d{4})-(\d{1,2})\s*(.*)$').firstMatch(line);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    return MainlineMonthNote(
      year: year,
      month: month,
      text: m.group(3)!.trim(),
    );
  }

  // ---------- frontmatter ----------

  String? _value(Mainline m, String key) {
    switch (key) {
      case 'id':
        return m.id;
      case 'title':
        return _oneLine(m.title);
      case 'created':
        return _fmtIso(m.created);
      case 'completed':
        final at = m.completedAt;
        return at == null ? null : _fmtIso(at);
      default:
        return null;
    }
  }

  // ---------- 结构解析 ----------

  static List<_Block> _parse(String raw) {
    final lines = raw.split('\n');
    final blocks = <_Block>[];
    var i = 0;
    while (i < lines.length) {
      if (lines[i].trim() != '---') {
        i++;
        continue;
      }
      final fmStart = i + 1;
      var j = fmStart;
      while (j < lines.length && lines[j].trim() != '---') {
        j++;
      }
      if (j >= lines.length) break; // 未闭合：忽略尾部
      final frontLines = lines.sublist(fmStart, j);
      final fields = <String, String>{};
      for (final line in frontLines) {
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        var v = line.substring(idx + 1).trim();
        if (v.length >= 2 &&
            ((v.startsWith('"') && v.endsWith('"')) ||
                (v.startsWith("'") && v.endsWith("'")))) {
          v = v.substring(1, v.length - 1);
        }
        fields[line.substring(0, idx).trim()] = v;
      }
      final bodyLines = <String>[];
      var k = j + 1;
      while (k < lines.length) {
        if (lines[k].trim() == '---' && _startsNewBlock(lines, k + 1)) break;
        bodyLines.add(lines[k]);
        k++;
      }
      blocks.add(_Block(frontLines, fields, bodyLines));
      i = k;
    }
    return blocks;
  }

  static bool _startsNewBlock(List<String> lines, int from) {
    for (var i = from; i < lines.length && lines[i].trim() != '---'; i++) {
      if (lines[i].trimLeft().startsWith('id:')) return true;
    }
    return false;
  }

  static String? _keyOf(String line) {
    final idx = line.indexOf(':');
    if (idx <= 0) return null;
    return line.substring(0, idx).trim();
  }

  /// 小标题 → 段落；认不出的返回 null（交给调用方判断"是不是别人的标题"）。
  static _Section? _sectionOf(String trimmedLine) {
    if (!trimmedLine.startsWith('#')) return null;
    final text = trimmedLine.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (text.startsWith('行为链')) return _Section.steps;
    if (text.startsWith('月记')) return _Section.months;
    if (text.startsWith('记录')) return _Section.logs;
    return null;
  }

  // ---------- 格式化 ----------

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  /// 与 `tasks.md` 同一写法：`2026-10-19,21:30`。
  static String _fmtDateTime(DateTime d) =>
      '${_fmtDate(d)},${_two(d.hour)}:${_two(d.minute)}';

  static String _fmtIso(DateTime d) =>
      '${_fmtDate(d)}T${_two(d.hour)}:${_two(d.minute)}';

  static DateTime? _parseDate(String text) {
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }

  /// `2026-10-19,21:30` / `2026-10-19 21:30` / `2026-10-19`（= 当天 00:00）。
  static DateTime? _parseMoment(String token) {
    final m = RegExp(
      r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[, ](\d{1,2}):(\d{2}))?$',
    ).firstMatch(token.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final h = int.tryParse(m.group(4) ?? '0') ?? 0;
    final mi = int.tryParse(m.group(5) ?? '0') ?? 0;
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
    return DateTime(y, mo, d, h, mi);
  }

  static DateTime? _parseIso(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    return DateTime.tryParse(text.trim().replaceFirst(' ', 'T'));
  }

  /// 去掉行尾 \r（原行带 CRLF 时保持同样的行尾风格）。
  static String _withCr(String value, String original) =>
      original.endsWith('\r') ? '$value\r' : value;
}

enum _Section { steps, logs, months, other }

class _Block {
  final List<String> frontLines;
  final Map<String, String> fields;
  final List<String> bodyLines;

  const _Block(this.frontLines, this.fields, this.bodyLines);

  String get body => bodyLines.join('\n').trim();
}
