/// 疑问笔记只读端口（ui-interaction.md §6.2 / §10 #6）：
/// 从 Obsidian vault 的指定 Markdown 文件**只读**提取一段正文显示。
/// App 对该文件零写入——frontmatter 一个字符都不动；它不是任务。
///
/// 提取规则（决议 1/19）：
/// - 显示 frontmatter 闭合 `---` 之后、到下一个 `---` 之间的正文段（非 YAML 本身）；
/// - 没有第二个 `---` → 取到文件末尾；
/// - 行内出现 `[[` 的整行屏蔽（过滤 wiki 链接行）；
/// - 文件未配置/找不到/过滤后为空 → 对应空态，由 UI 呈现。
enum NotesStatus { ok, notConfigured, notFound, empty }

class NotesReadResult {
  final NotesStatus status;

  /// 过滤后的正文行（status == ok 时非空有意义）。
  final List<String> lines;

  const NotesReadResult(this.status, {this.lines = const []});

  bool get isOk => status == NotesStatus.ok;
}

/// 实现方负责：读文件（只读）+ 按上述规则提取 + 行过滤。
/// UI 层只见接口名，不见平台名（§5.3）。
abstract class NotesReaderPort {
  Future<NotesReadResult> read();
}

/// 纯函数：从 Markdown 原文提取疑问笔记段（供实现复用，便于测试）。
NotesReadResult extractNotesSection(String raw) {
  final lines = raw.split('\n');
  var start = 0;
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        close = i;
        break;
      }
    }
    if (close < 0) return const NotesReadResult(NotesStatus.empty);
    start = close + 1;
  }
  var end = lines.length;
  for (var i = start; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      end = i;
      break;
    }
  }
  final visible = lines.sublist(start, end).where((l) => !l.contains('[[')).toList();
  // 文件末尾换行产生的尾随空行是读取噪音，不是内容
  while (visible.isNotEmpty && visible.last.trim().isEmpty) {
    visible.removeLast();
  }
  final hasContent = visible.any((l) => l.trim().isNotEmpty);
  if (!hasContent) return const NotesReadResult(NotesStatus.empty);
  return NotesReadResult(NotesStatus.ok, lines: List.unmodifiable(visible));
}
