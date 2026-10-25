/// 灵感端口（ui-interaction.md §6.2 / §10 #6）：
/// 从 Obsidian vault 的指定 Markdown 文件**读写**一段正文。
/// 只动正文段——frontmatter 与其他段落一个字符都不改；它不是任务。
///
/// 提取规则（决议 1/19）：
/// - 正文段 = frontmatter 闭合 `---` 之后、到下一个 `---` 之间的行（不是 YAML 本身）；
/// - 没有第二个 `---` → 取到文件末尾；
/// - **显示**时行内出现 `[[` 的整行屏蔽（过滤 wiki 链接行）；
/// - 文件未配置/找不到/过滤后为空 → 对应空态，由 UI 呈现。
///
/// 写入规则（v1.29，从只读改为可编辑）：
/// - 只替换正文段，frontmatter 与其余行**逐行原样保留**；
/// - 换行风格（CRLF/LF）与"是否以换行结尾"沿用原文件，不整篇重排；
/// - 编辑器的初值是正文段去掉被屏蔽的 `[[` 行（与只读态同一批），保存时按原行号
///   插回——看不见的行不能在保存时被悄悄抹掉；
/// - frontmatter 未闭合（正文段边界本身不确定）→ 拒绝写入。
enum NotesStatus { ok, notConfigured, notFound, empty }

/// 写入结果：除 ok 外都要让 UI 说清"为什么没存上"（§6.2）。
enum NotesWriteStatus { ok, notConfigured, notFound, failed }

class NotesReadResult {
  final NotesStatus status;

  /// 过滤后的显示行（status == ok 时非空有意义）。
  final List<String> lines;

  /// 正文段**完整**原文行（未过滤 `[[` 行）：编辑态输入框的初值。
  final List<String> bodyLines;

  /// 能否编辑：文件已配置且存在、正文段边界可识别。
  /// frontmatter 未闭合的文件虽然也显示 empty，但这里为 false（写不了）。
  final bool canEdit;

  const NotesReadResult(
    this.status, {
    this.lines = const [],
    this.bodyLines = const [],
    this.canEdit = false,
  });

  bool get isOk => status == NotesStatus.ok;
}

/// 实现方负责：读文件 + 按上述规则提取 + 行过滤；以及把编辑结果写回正文段。
/// UI 层只见接口名，不见平台名（§5.3）。
abstract class NotesPort {
  Future<NotesReadResult> read();

  /// 用 [body] 替换正文段；返回值说明是否真的落盘。
  Future<NotesWriteStatus> write(String body);
}

/// 纯函数：从 Markdown 原文提取灵感正文段（供实现复用，便于测试）。
NotesReadResult extractNotesSection(String raw) {
  final lines = _splitLines(raw);
  final range = _sectionRange(lines);
  if (range == null) return const NotesReadResult(NotesStatus.empty);
  final (start, end) = range;
  final body = _trimTrailingBlank(lines.sublist(start, end));
  final visible =
      _trimTrailingBlank(body.where((l) => !l.contains('[[')).toList());
  final bodyLines = List<String>.unmodifiable(body);
  if (!visible.any((l) => l.trim().isNotEmpty)) {
    return NotesReadResult(NotesStatus.empty,
        bodyLines: bodyLines, canEdit: true);
  }
  return NotesReadResult(NotesStatus.ok,
      lines: List.unmodifiable(visible), bodyLines: bodyLines, canEdit: true);
}

/// 编辑态草稿：正文段里"只读态看不见的行"（含 `[[`）不进编辑框，保存时按原行号
/// 插回——眼不见的行既然不给改，也不该在保存时被悄悄抹掉（§6.2）。
class NotesDraft {
  /// 编辑框初值：正文段去掉屏蔽行。
  final String text;

  /// 被扣掉的行及其在正文段里的行号（**升序**，见 [buildNotesDraft]）。
  final List<({int index, String line})> hidden;

  const NotesDraft(this.text, {this.hidden = const []});

  /// 把编辑结果还原成正文段：按行切开，屏蔽行按原行号插回（超出新行数就落到
  /// 末尾）。
  ///
  /// 多条一起插时升序逐个插入即可：前面插回的那几条正好补回被扣掉的位次，
  /// 后面那条的原行号仍然指向它该在的位置。
  String merge(String edited) {
    final text = edited.replaceAll('\r\n', '\n');
    // 全清空时按"零行"算：否则那一天空白会夹在插回的屏蔽行之间。
    final lines = text.trim().isEmpty ? <String>[] : text.split('\n');
    for (final h in hidden) {
      lines.insert(h.index > lines.length ? lines.length : h.index, h.line);
    }
    return lines.join('\n');
  }
}

/// 纯函数：由正文段原文生成编辑草稿。
///
/// 屏蔽谓词与只读态同一份（`contains('[[')`）——编辑态与只读态看到的必须是
/// 同一批行，否则"看不见的行"两头对不上。
NotesDraft buildNotesDraft(List<String> bodyLines) {
  final hidden = <({int index, String line})>[];
  final kept = <String>[];
  for (var i = 0; i < bodyLines.length; i++) {
    if (bodyLines[i].contains('[[')) {
      hidden.add((index: i, line: bodyLines[i]));
    } else {
      kept.add(bodyLines[i]);
    }
  }
  return NotesDraft(_trimTrailingBlank(kept).join('\n'), hidden: hidden);
}

/// 纯函数：把 [body] 写进 Markdown 原文的正文段，其余部分逐行原样保留。
///
/// 返回 null = 正文段边界不可识别（frontmatter 只有开头没有闭合），调用方拒绝写入
/// ——那时"该替换哪几行"本身没有答案，硬写只会把文件结构写坏。
String? applyNotesSection(String raw, String body) {
  final eol = raw.contains('\r\n') ? '\r\n' : '\n';
  final endsWithNewline = raw.endsWith('\n');
  final lines = _splitLines(raw);
  // split 出来的尾部空串只是"文件以换行结尾"的副产物，不是一行内容
  if (endsWithNewline) lines.removeLast();

  final range = _sectionRange(lines);
  if (range == null) return null;
  final (start, end) = range;

  final newBody = _trimTrailingBlank(body.replaceAll('\r\n', '\n').split('\n'));
  final merged = <String>[
    ...lines.sublist(0, start),
    ...newBody,
    // 后面还有 `---`：中间留一个空行，否则那一行会被 Markdown 当成 setext 标题
    if (end < lines.length) '',
    ...lines.sublist(end),
  ];
  return merged.join(eol) + (endsWithNewline ? eol : '');
}

/// 按行拆分并统一掉行尾 `\r`：CRLF 文件的 `\r` 留在行内容里，显示与编辑都会出怪字符。
List<String> _splitLines(String raw) => [
      for (final line in raw.split('\n'))
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    ];

/// 正文段的行区间 `[start, end)`；frontmatter 未闭合 → null。
(int, int)? _sectionRange(List<String> lines) {
  var start = 0;
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        close = i;
        break;
      }
    }
    if (close < 0) return null;
    start = close + 1;
  }
  var end = lines.length;
  for (var i = start; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      end = i;
      break;
    }
  }
  return (start, end);
}

/// 去掉尾部空行：文件末尾换行、段尾空行都是排版噪音，不是内容。
List<String> _trimTrailingBlank(List<String> lines) {
  final out = [...lines];
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out;
}
