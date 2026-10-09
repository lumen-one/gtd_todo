import '../domain/routine.dart';
import 'routine_codec.dart';

/// routines.md 编解码（formatId: md-routine/1）。
///
/// 文件结构：**一条规则一个 frontmatter 条目**，条目之间用 `---` 分隔，
/// 条目正文（`---` 之后到下一个条目开始之前）是规则备注，归人所有：
///
/// ```markdown
/// ---
/// id: routine-1a2b
/// title: 晨跑
/// freq: weekly
/// weekdays: 1,3,5
/// time: 07:00
/// remind: true
/// enabled: true
/// created: 2026-10-07T09:00
/// ---
///
/// 备注随便写，应用不改这一段。
/// ```
///
/// 与 MarkdownTaskCodec 同样遵守分级保真：应用拥有的字段行原地改写，
/// 未知字段/注释/行顺序/正文原样保留；列表不参与（weekdays 是逗号分隔的标量）。
class MarkdownRoutineCodec implements RoutineCodec {
  /// 应用拥有的字段（编码时原地改写或补写）。
  static const List<String> _ownedKeys = [
    'id',
    'title',
    'freq',
    'weekdays',
    'time',
    'remind',
    'enabled',
    'created',
  ];

  @override
  String get formatId => 'md-routine/1';

  @override
  bool canDecode(String raw) => raw.contains('---');

  @override
  RoutineDecodeResult decode(String raw) {
    final routines = <Routine>[];
    final warnings = <String>[];
    for (final block in _parse(raw)) {
      final id = block.fields['id']?.trim();
      final title = block.fields['title']?.trim();
      if (id == null || id.isEmpty) {
        warnings.add('routines.md: 跳过缺少 id 的条目');
        continue;
      }
      if (title == null || title.isEmpty) {
        warnings.add('routines.md: $id 缺少 title，已跳过');
        continue;
      }
      final weekdays = (block.fields['weekdays'] ?? '')
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .where((d) => d >= 1 && d <= 7)
          .toSet()
          .toList()
        ..sort();
      routines.add(Routine(
        id: id,
        title: title,
        description: block.body.trim(),
        frequency: block.fields['freq'] == 'weekly'
            ? RoutineFrequency.weekly
            : RoutineFrequency.daily,
        weekdays: weekdays,
        minuteOfDay: _parseTime(block.fields['time']),
        remind: block.fields['remind'] == 'true',
        enabled: block.fields['enabled'] != 'false',
        created: DateTime.tryParse(block.fields['created'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        extra: Map.unmodifiable({
          for (final e in block.fields.entries)
            if (!_ownedKeys.contains(e.key)) e.key: e.value,
        }),
      ));
    }
    return RoutineDecodeResult(routines, warnings);
  }

  @override
  String encode(List<Routine> routines, {String? originalRaw}) {
    final blocks = <String, _Block>{};
    if (originalRaw != null) {
      for (final b in _parse(originalRaw)) {
        final id = b.fields['id']?.trim();
        if (id != null && id.isNotEmpty) blocks[id] = b;
      }
    }
    final out = StringBuffer();
    for (final r in routines) {
      final b = blocks[r.id];
      final front = <String>[];
      final written = <String>{};
      if (b != null) {
        for (final line in b.frontLines) {
          final key = _keyOf(line);
          if (key != null && _ownedKeys.contains(key)) {
            final v = _value(r, key);
            if (v == null) continue; // 如 time/weekdays 被清空 → 整行移除
            front.add(_withCr('$key: $v', line));
            written.add(key);
          } else {
            front.add(line); // 未知字段/注释/空行：原样保留
          }
        }
      }
      for (final key in _ownedKeys) {
        if (written.contains(key)) continue;
        final v = _value(r, key);
        if (v == null) continue;
        front.add('$key: $v');
      }
      final body = b == null || b.body.trim() != r.description
          ? (r.description.isEmpty ? '\n' : '${r.description}\n')
          : '${b.bodyRaw}\n';
      out.write('---\n${front.join('\n')}\n---\n$body');
    }
    return out.toString();
  }

  // ---------- 内部 ----------

  /// 解析出全部条目（宽容：坏块忽略，由调用方记告警）。
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
      // 正文：到下一个"条目起点"为止——起点判定 = 该 --- 之后（到下一条 ---
      // 或文件末尾）出现了 id: 字段。这样正文里的水平线不会被误判。
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

  /// 去掉行尾 \r（原行带 CRLF 时保持同样的行尾风格）。
  static String _withCr(String value, String original) =>
      original.endsWith('\r') ? '$value\r' : value;

  static int? _parseTime(String? text) {
    if (text == null) return null;
    final parts = text.trim().split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return h * 60 + m;
  }

  String? _value(Routine r, String key) {
    switch (key) {
      case 'id':
        return r.id;
      case 'title':
        return r.title.replaceAll('\n', ' ');
      case 'freq':
        return r.frequency.name;
      case 'weekdays':
        if (r.frequency != RoutineFrequency.weekly) return null;
        final sorted = [...r.weekdays]..sort();
        return sorted.join(',');
      case 'time':
        return r.hasTime ? r.timeText : null;
      case 'remind':
        return r.remind ? 'true' : 'false';
      case 'enabled':
        return r.enabled ? 'true' : 'false';
      case 'created':
        return _fmtDateTime(r.created);
      default:
        return null;
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtDateTime(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
      'T${_two(d.hour)}:${_two(d.minute)}';
}

class _Block {
  final List<String> frontLines;
  final Map<String, String> fields;
  final List<String> bodyLines;

  const _Block(this.frontLines, this.fields, this.bodyLines);

  String get body => bodyLines.join('\n').trim();

  /// 正文原文（保留行数与行尾，用于未改动时逐字节回写）。
  String get bodyRaw => bodyLines.join('\n').trimRight();
}
