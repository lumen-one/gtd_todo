/// 灵感页只读态的 Markdown 呈现（ui-interaction.md §6.2 / panels/notes.md）。
///
/// 只认"速记本里真会用到"的那部分语法：行内强调 + 几种块级标记。表格、图片、
/// HTML 内嵌、Obsidian 的 `==高亮==` / `%%注释%%` 一概不认——原文什么样就显示什么样。
///
/// 这里是**纯函数、零 Flutter 依赖**：只回答"分几块、每块是什么、行内哪几段带样式"，
/// 具体长什么样由 UI 层决定。写回文件的永远是原文，解析结果不参与保存。
library;

/// 行内样式。粗体与斜体可叠加成 [boldItalic]；[code] 与 [link] 不参与叠加。
enum NotesSpanStyle { plain, bold, italic, boldItalic, strike, code, link }

/// 一段连续、共享同一样式的文字。
class NotesSpan {
  final String text;
  final NotesSpanStyle style;

  const NotesSpan(this.text, [this.style = NotesSpanStyle.plain]);

  @override
  String toString() => '${style.name}($text)';

  @override
  bool operator ==(Object other) =>
      other is NotesSpan && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);
}

/// 块的种类。段内保留手写的换行，不按 Markdown 的软换行合并成一行。
enum NotesBlockKind { paragraph, heading, bullet, ordered, quote, code }

/// 一个块：标题 / 列表项 / 引用 / 代码块 / 普通段落。
class NotesBlock {
  final NotesBlockKind kind;

  /// 标题的层级 1..6；列表与引用的缩进层级 0..3；其余为 0。
  final int level;

  /// 有序列表的序号（其余为 0）。
  final int number;

  final List<NotesSpan> spans;

  const NotesBlock(
    this.kind, {
    this.level = 0,
    this.number = 0,
    this.spans = const [],
  });

  @override
  String toString() => '${kind.name}[$level/$number] $spans';
}

/// 把正文段（已过滤 `[[` 行）切成块。
List<NotesBlock> parseNotesMarkdown(List<String> lines) {
  final blocks = <NotesBlock>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _fenceOf(line);
    if (fence != null) {
      i++;
      final body = <String>[];
      while (i < lines.length && !_isFenceClose(lines[i], fence)) {
        body.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 吃掉闭合围栏
      if (body.isNotEmpty) {
        blocks.add(NotesBlock(NotesBlockKind.code,
            spans: [NotesSpan(body.join('\n'))]));
      }
      continue;
    }

    final heading = _headingOf(line);
    if (heading != null) {
      blocks.add(NotesBlock(NotesBlockKind.heading,
          level: heading.$1, spans: parseNotesInline(heading.$2)));
      i++;
      continue;
    }

    final ordered = _orderedOf(line);
    if (ordered != null) {
      blocks.add(NotesBlock(NotesBlockKind.ordered,
          level: ordered.$1,
          number: ordered.$2,
          spans: parseNotesInline(ordered.$3)));
      i++;
      continue;
    }

    final bullet = _bulletOf(line);
    if (bullet != null) {
      blocks.add(NotesBlock(NotesBlockKind.bullet,
          level: bullet.$1, spans: parseNotesInline(bullet.$2)));
      i++;
      continue;
    }

    final quote = _quoteOf(line);
    if (quote != null) {
      blocks.add(NotesBlock(NotesBlockKind.quote,
          level: quote.$1, spans: parseNotesInline(quote.$2)));
      i++;
      continue;
    }

    // 普通段落：一直吞到空行或下一个块级标记。段内的换行原样保留。
    final para = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      if (para.isNotEmpty && _isBlockStart(lines[i])) break;
      para.add(lines[i]);
      i++;
    }
    blocks.add(NotesBlock(NotesBlockKind.paragraph,
        spans: parseNotesInline(para.join('\n'))));
  }

  return blocks;
}

/// 把一行文字切成带样式的段。
List<NotesSpan> parseNotesInline(String text) => _inline(text, 0);

const _escapes = r'\`*_~[]()!#|';

List<NotesSpan> _inline(String s, int depth) {
  if (s.isEmpty) return const [];
  // 病态嵌套（几十个未闭合定界符）不值得再递归下去
  if (depth > 6) return [NotesSpan(s)];

  final out = <NotesSpan>[];
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    out.add(NotesSpan(buf.toString()));
    buf.clear();
  }

  var i = 0;
  while (i < s.length) {
    final ch = s[i];

    // 反斜杠转义：\* \_ \` \] 等一律落字面
    if (ch == r'\' && i + 1 < s.length && _escapes.contains(s[i + 1])) {
      buf.write(s[i + 1]);
      i += 2;
      continue;
    }

    // 行内代码：内部不再解析任何标记
    if (ch == '`') {
      final end = s.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        out.add(NotesSpan(s.substring(i + 1, end), NotesSpanStyle.code));
        i = end + 1;
        continue;
      }
    }

    // 图片 ![alt](url)：那个 ! 不该留在页面上
    if (ch == '!' && i + 1 < s.length && s[i + 1] == '[') {
      final link = _linkAt(s, i + 1);
      if (link != null) {
        flush();
        out.addAll(_paint(_inline(link.$1, depth + 1), NotesSpanStyle.link));
        i = link.$2;
        continue;
      }
    }

    if (ch == '[') {
      final link = _linkAt(s, i);
      if (link != null) {
        flush();
        out.addAll(_paint(_inline(link.$1, depth + 1), NotesSpanStyle.link));
        i = link.$2;
        continue;
      }
    }

    // 双字符定界符：*** 粗斜 / ** 粗 / ~~ 删除线
    final pair = _pairAt(s, i);
    if (pair != null) {
      final end = _closeOf(s, i + pair.$1.length, pair.$1);
      if (end > 0) {
        flush();
        out.addAll(_paint(
            _inline(s.substring(i + pair.$1.length, end), depth + 1), pair.$2));
        i = end + pair.$1.length;
        continue;
      }
    }

    // 单字符定界符：* 与 _ 都算斜体。_ 夹在单词里不认（snake_case 不是斜体）
    if (ch == '*' || ch == '_') {
      if (ch == '_' && _isInWord(s, i)) {
        buf.write(ch);
        i++;
        continue;
      }
      final end = _closeOf(s, i + 1, ch);
      if (end > 0) {
        flush();
        out.addAll(
            _paint(_inline(s.substring(i + 1, end), depth + 1), NotesSpanStyle.italic));
        i = end + 1;
        continue;
      }
    }

    buf.write(ch);
    i++;
  }

  flush();
  return out;
}

/// `***` / `**` / `~~` 里当前位置命中的那一个，以及它带来的样式。
(String, NotesSpanStyle)? _pairAt(String s, int i) {
  if (s.startsWith('***', i)) {
    return ('***', NotesSpanStyle.boldItalic);
  }
  if (s.startsWith('**', i)) return ('**', NotesSpanStyle.bold);
  if (s.startsWith('~~', i)) return ('~~', NotesSpanStyle.strike);
  return null;
}

/// 找 [delim] 的闭合位置；找不到或内容为空/首尾贴空白时返回 -1。
///
/// "定界符内侧紧贴空格就不算强调"是防误伤的关键：`2 * 3 * 4` 里的星号两边都是
/// 空格，按这条规则不会把 " 3 " 变成斜体。
int _closeOf(String s, int from, String delim) {
  if (from >= s.length) return -1;
  if (_isBlank(s[from])) return -1;
  var cursor = from;
  while (true) {
    final close = s.indexOf(delim, cursor);
    if (close < 0) return -1;
    // 空内容，或撞上更长的同类定界符（`**` 里的第一个 `*`）：往后挪，别就地收
    if (close <= from || _isBlank(s[close - 1])) {
      cursor = close + 1;
      continue;
    }
    if (delim.length == 1 && close + 1 < s.length && s[close + 1] == delim) {
      cursor = close + 2;
      continue;
    }
    return close;
  }
}

/// `[文字](url)` 的 `[` 位置起解；返回 (文字, 收尾下标) 或 null。
/// 括号里的 url 不参与显示，所以只要求能找到配对的 `](` 和 `)`。
(String, int)? _linkAt(String s, int start) {
  var i = start + 1;
  while (i < s.length) {
    final ch = s[i];
    if (ch == r'\') {
      i += 2;
      continue;
    }
    if (ch == ']') break;
    i++;
  }
  if (i >= s.length || s[i] != ']') return null;
  final text = s.substring(start + 1, i);
  if (text.trim().isEmpty) return null;
  if (i + 1 >= s.length || s[i + 1] != '(') return null;
  final close = s.indexOf(')', i + 2);
  if (close < 0) return null;
  return (text, close + 1);
}

/// 给一组段叠一层样式。
List<NotesSpan> _paint(List<NotesSpan> spans, NotesSpanStyle base) => [
      for (final sp in spans) NotesSpan(sp.text, _merge(sp.style, base)),
    ];

NotesSpanStyle _merge(NotesSpanStyle existing, NotesSpanStyle base) {
  // 代码自带视觉，外面套什么都不认
  if (existing == NotesSpanStyle.code) return existing;
  // 链接与删除线由外层说了算：`[**粗**](url)` 显示成链接，粗细让位
  if (base == NotesSpanStyle.link) return NotesSpanStyle.link;
  if (base == NotesSpanStyle.strike) return NotesSpanStyle.strike;
  // 反过来，里面已经是链接/删除线的，外层粗体不覆盖它的颜色与划线
  if (existing == NotesSpanStyle.link || existing == NotesSpanStyle.strike) {
    return existing;
  }
  final bold = base == NotesSpanStyle.bold ||
      base == NotesSpanStyle.boldItalic ||
      existing == NotesSpanStyle.bold ||
      existing == NotesSpanStyle.boldItalic;
  final italic = base == NotesSpanStyle.italic ||
      base == NotesSpanStyle.boldItalic ||
      existing == NotesSpanStyle.italic ||
      existing == NotesSpanStyle.boldItalic;
  if (bold && italic) return NotesSpanStyle.boldItalic;
  if (bold) return NotesSpanStyle.bold;
  if (italic) return NotesSpanStyle.italic;
  return existing;
}

bool _isBlank(String ch) => ch == ' ' || ch == '\t' || ch == '\u3000';

/// `_` 两侧都是词字符时不当作斜体定界符（`snake_case_name` 原样显示）。
bool _isInWord(String s, int i) =>
    i > 0 && i + 1 < s.length && _isWordChar(s.codeUnitAt(i - 1)) && _isWordChar(s.codeUnitAt(i + 1));

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    (c >= 0x4e00 && c <= 0x9fff);

String? _fenceOf(String line) {
  final t = line.trimLeft();
  if (t.startsWith('```')) return '```';
  if (t.startsWith('~~~')) return '~~~';
  return null;
}

bool _isFenceClose(String line, String fence) {
  final t = line.trim();
  return t.startsWith(fence) && t.substring(fence.length).trim().isEmpty;
}

(int, String)? _headingOf(String line) {
  final m = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*))?$').firstMatch(line.trimRight());
  if (m == null) return null;
  var text = (m.group(2) ?? '').trim();
  text = text.replaceFirst(RegExp(r'\s+#+$'), ''); // `## 标题 ##` 的收尾井号
  return (m.group(1)!.length, text);
}

(int, int, String)? _orderedOf(String line) {
  final m = RegExp(r'^(\s*)(\d{1,9})[.)](?:[ \t]+(.*))?$').firstMatch(line.trimRight());
  if (m == null) return null;
  return (
    _indentLevel(m.group(1)!),
    int.parse(m.group(2)!),
    (m.group(3) ?? '').trimRight(),
  );
}

(int, String)? _bulletOf(String line) {
  final m = RegExp(r'^(\s*)[-*+](?:[ \t]+(.*))?$').firstMatch(line.trimRight());
  if (m == null) return null;
  return (_indentLevel(m.group(1)!), (m.group(2) ?? '').trimRight());
}

(int, String)? _quoteOf(String line) {
  final m = RegExp(r'^(\s*)(>+)[ \t]?(.*)$').firstMatch(line.trimRight());
  if (m == null) return null;
  return (m.group(2)!.length.clamp(1, 3), m.group(3)!);
}

bool _isBlockStart(String line) =>
    _fenceOf(line) != null ||
    _headingOf(line) != null ||
    _orderedOf(line) != null ||
    _bulletOf(line) != null ||
    _quoteOf(line) != null;

/// 两空格一档（tab 算两格）。四空格缩进会落到第 2 层——比标准 Markdown 深一档，
/// 但速记本里够用，且比"4 空格 = 代码块"那套更贴近直觉。
int _indentLevel(String leading) {
  var spaces = 0;
  for (final c in leading.codeUnits) {
    spaces += c == 9 ? 2 : 1;
  }
  return (spaces ~/ 2).clamp(0, 3);
}
