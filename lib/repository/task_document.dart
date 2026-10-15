import '../domain/task.dart';

/// 一个字段在行内的位置：`start` = 关键字起点，`bodyStart` = 值起点。
typedef Anchor = ({String key, int start, int bodyStart});

/// 一个解析出来的时间戳 + 它后面紧跟的文本。
class _Stamp {
  const _Stamp({required this.at, required this.rest, required this.hasTime});

  final DateTime at;

  /// 时间戳后面紧跟的剩余文本（可能是没写「备注」标记的散文）。
  final String rest;

  /// 行里是否写了时刻（`2026-10-11` vs `2026-10-11,7:00`）。
  final bool hasTime;
}

/// 人类文档（`tasks.md`）的格式编解码：**纯函数、无 IO**。
///
/// 存储形态（ui-interaction.md §4.3，architecture.md 附录 B）：
/// 所有任务记在**同一个 `tasks.md`** 里，用 `# 标题` 分类，一条任务 = 一行复选框：
///
/// ```markdown
/// # 工作
///
/// - [ ] 写周报 创建 2026-10-11,7:00 结束 2026-10-12,18:00 这是备注。 ##工作 ##汇报
/// - [x] 交房租 创建 2026-10-01,9:00 完成 2026-10-01,9:30 ##生活
/// ```
///
/// **这个文件归人所有**：应用只在需要时改写**它自己那一行**（写入/打勾/加
/// 完成时刻），其余行、标题、空行、正文一字不动。内核属性（任务 id、工作强度、
/// 优先级、时间裕度、剩余工作量）住在另一个文档里（见 [TaskSidecarCodec]），
/// 所以这里的每一行都是 Obsidian 里读得懂、可共享的自然语言。
///
/// 行格式（关键字锚定，字段顺序自由）：
///
/// ```text
/// - [ ] 任务名 创建 <日期,时间> 结束 <日期,时间> 完成 <日期,时间> 备注… ##标签1 ##标签2
/// ```
///
/// - **就是任务行的判定**：行首为 `- [ ]` / `- [x]` 复选框，且行内含 `创建`
///   关键字（创建日期必填——它是"这是一条任务"的锚点，也是内核分配 id 的依据）；
/// - `[x]` = 完成，`[ ]` = 未完成；`完成 <时刻>` 只记录完成时间，不算完成标记
///   （打勾才是，避免与"备注里提到完成"混淆）；
/// - `##标签` 只认**行尾**连续的 `##xxx` 段（正则 `(?:\s*##[^\s#]+)+\s*$`），
///   因此文档里真正的 `## 小节标题`（`#` 后有空格、独占一行）不会被误当标签；
/// - 关键字用"字面量 + 后随空白/结尾"匹配，所以备注里出现"完成"二字不会破坏解析；
/// - 解析宽容：认不出创建日期的行**不改动**，仅进 warnings。
class TaskDocumentCodec {
  const TaskDocumentCodec();

  /// 人类文档的格式标识（附录 B 登记）。
  static const String formatId = 'md-taskdoc/1';

  static const String createKeyword = '创建';
  static const String endKeyword = '结束';
  static const String doneKeyword = '完成';
  static const String noteKeyword = '备注';

  /// 标签段：行尾一组 `##xxx`（`#` 后允许无空格，照决议 36 的样例）。
  static final RegExp _tagTail = RegExp(r'(?:\s*##[^\s#]+)+\s*$');

  /// 复选框行：`- [ ]` / `* [x]` / `+ [X]`（后随空白）。
  static final RegExp _checkbox = RegExp(r'^\s*[-*+]\s*\[([ xX])\]\s*');

  /// ATX 标题行（`#`/`##`…）：任务行从不是标题，标题行也从不是任务。
  static final RegExp _heading = RegExp(r'^\s{0,3}#{1,6}(?:\s|$)');

  /// 围栏代码块边界（``` 或 ~~~）：里面的示例行不算任务。
  static final RegExp _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

  // ------------------------------------------------------------------
  // 解析
  // ------------------------------------------------------------------

  /// 解析整篇文档。永不抛异常：认不出的行降级进 warnings。
  TaskDocument parse(String raw) {
    final lines = raw.split('\n');
    final docTasks = <TaskLine>[];
    final warnings = <String>[];
    var section = '';
    String? fence;
    // 同一篇文档里出现两个相同的"行指纹"→ 无法判断内核属性该归谁
    final digests = <String, int>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fenceMark = _fence.firstMatch(line);
      if (fenceMark != null) {
        final marker = fenceMark.group(1)!;
        if (fence == null) {
          fence = marker[0];
        } else if (marker[0] == fence) {
          fence = null;
        }
        continue;
      }
      if (fence != null) continue; // 代码块内原样跳过

      if (_heading.hasMatch(line)) {
        section = line.trim().replaceFirst(RegExp(r'^#+\s*'), '').trim();
        continue;
      }

      final box = _checkbox.firstMatch(line);
      if (box == null) continue;

      final content = line.substring(box.end).trim();
      if (content.isEmpty) continue;

      if (_findKeyword(rest: content, keyword: createKeyword) < 0) {
        // 认不出创建日期：不敢猜 id，也不改这一行。
        warnings.add('第 ${i + 1} 行: 任务行缺少「$createKeyword <日期,时间>」，'
            '已按普通待办忽略（本行不会被改动）');
        continue;
      }
      try {
        final parsed = _parseContent(content, completed: box.group(1) != ' ');
        final digest = digestOf(content);
        final dup = digests[digest];
        if (dup != null) {
          warnings.add('第 ${i + 1} 行: 与第 $dup 行内容完全相同，'
              '两条任务无法区分（内核属性会归给先出现的那条）；'
              '改掉标题或创建时间即可分开');
          continue;
        }
        digests[digest] = i + 1;
        docTasks.add(TaskLine(
          index: i,
          section: section,
          content: content,
          digest: digest,
          completed: parsed.completed,
          title: parsed.title,
          created: parsed.created,
          deadline: parsed.deadline,
          completedAt: parsed.completedAt,
          description: parsed.description,
          tags: parsed.tags,
        ));
      } catch (e) {
        warnings.add('第 ${i + 1} 行: $e');
      }
    }

    return TaskDocument(
      lines: lines,
      tasks: docTasks,
      warnings: warnings,
      hadTrailingNewline: raw.endsWith('\n'),
    );
  }

  /// 行指纹：**只看人写的部分**（复选框状态不计），用于把内核属性文件与
  /// 文档里的行重新对上号——用户在 Obsidian 里改标题/日期/备注后，指纹变了，
  /// 内核据此识别"这一行被外部改过"并同步回内核属性。
  ///
  /// 用 FNV-1a 32 位：纯 Dart、无依赖、同一输入跨平台稳定。
  static String digestOf(String content) {
    var hash = 0x811c9dc5;
    final units = content.trim().codeUnits;
    for (final unit in units) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
      hash ^= (unit >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  _ParsedLine _parseContent(String content, {required bool completed}) {
    // 1) 剥掉行尾标签段，剩下的部分才做字段切分
    final tags = <String>[];
    final tagMatch = _tagTail.firstMatch(content);
    var rest = content;
    if (tagMatch != null) {
      for (final m in RegExp(r'##([^\s#]+)').allMatches(tagMatch.group(0)!)) {
        final tag = m.group(1)!.trim();
        if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
      }
      rest = content.substring(0, tagMatch.start).trimRight();
    }

    // 2) 关键字定位：**以「创建」为锚点，只往后严格按序扫**。
    //
    // 为什么不能"全文找关键字"：任务名里天然会出现「完成」（"完成论文阅读"），
    // 全文扫描会把任务名当成完成时刻。锚定「创建」之后按
    // 结束 → 完成 → 备注 的顺序严格前进，就同时拿到了两个好处：
    // - 任务名里的关键字不参与识别（它们在「创建」之前）；
    // - 备注里出现"完成"二字也不会被当成字段（备注是最后一个、且只往后扫）。
    final createAt = _findKeyword(rest: rest, keyword: createKeyword);
    if (createAt < 0) {
      throw const FormatException('$createKeyword <日期,时间>');
    }
    final createMark =
        (key: createKeyword, start: createAt, bodyStart: createAt + createKeyword.length);

    final title = rest.substring(0, createAt).trim();
    if (title.isEmpty) {
      throw const FormatException('任务名称为空（「$createKeyword」前应有任务名）');
    }

    // 备注是"到行尾"的兜底；其余字段止于下一个字段关键字
    final endMark = _markAfter(rest, createMark,
        keyword: endKeyword, nextKeywords: const [doneKeyword, noteKeyword]);
    final doneMark = _markAfter(rest, endMark ?? createMark,
        keyword: doneKeyword, nextKeywords: const [noteKeyword]);
    final noteMark = _markAfter(rest, doneMark ?? endMark ?? createMark,
        keyword: noteKeyword, nextKeywords: const []);

    String? slice(Anchor? mark, {required bool toEnd}) {
      if (mark == null) return null;
      var end = rest.length;
      if (!toEnd) {
        for (final other in [endMark, doneMark, noteMark]) {
          if (other != null && other.start > mark.start && other.start < end) {
            end = other.start;
          }
        }
      }
      return rest.substring(mark.bodyStart, end).trim();
    }

    // 创建日期是必填字段（入口已确认关键字存在），坏值直接抛
    final DateTime created =
        _parseStampRequired(slice(createMark, toEnd: false)!, createKeyword);

    // 只写日期的"结束"：缺"结束时刻"就是当天 23:59（与旧格式"只有截止日期"
    // 的手感一致，也不至于提前判逾期）
    final endText = slice(endMark, toEnd: false);
    final endStamp = _parseStampAt(endText);
    // 只写日期（没写时刻）→ 当天 23:59
    final deadline = endStamp == null
        ? null
        : (endStamp.hasTime
            ? endStamp.at
            : DateTime(endStamp.at.year, endStamp.at.month, endStamp.at.day, 23, 59));

    final doneText = slice(doneMark, toEnd: false);
    final doneStamp = _parseStampAt(doneText);
    final completedAt = doneStamp?.at;
    // 写了完成时刻 = 完成意图（写入时会把复选框补成 [x]）
    if (completedAt != null) completed = true;

    // 备注：显式「备注」字段优先；没有这个标记时，接受"最后一个日期字段
    // 后面直接跟的散文"——这是决议 36 样例行的形态（`结束 <时刻> 这是备注。`），
    // 比"多写一个字就整行认不出、任务凭空消失"要安全得多。
    final explicitNote = slice(noteMark, toEnd: true);
    var noteText = explicitNote;
    if (noteText == null || noteText.isEmpty) {
      noteText = doneStamp?.rest ?? endStamp?.rest ?? '';
    }

    return _ParsedLine(
      completed: completed,
      title: title,
      created: created,
      deadline: deadline,
      completedAt: completedAt,
      description: noteText,
      tags: tags,
    );
  }

  /// 在 [after] 之后找 [keyword]，且它必须出现在 [nextKeywords] 里任何一个之前
  /// （保证字段顺序：结束 → 完成 → 备注，不会互相抢位）。找不到返回 null。
  static Anchor? _markAfter(
    String rest,
    Anchor after, {
    required String keyword,
    required List<String> nextKeywords,
  }) {
    final at = _findKeyword(rest: rest, keyword: keyword, from: after.bodyStart);
    if (at < 0) return null;
    for (final next in nextKeywords) {
      final nextAt = _findKeyword(rest: rest, keyword: next, from: after.bodyStart);
      if (nextAt >= 0 && nextAt < at) return null;
    }
    return (key: keyword, start: at, bodyStart: at + keyword.length);
  }

  /// 在 [rest] 里找 [keyword]，要求其后是空白或行尾；返回起始下标，找不到 -1。
  /// 用 startsWith 逐位试，避免在正则里拼中文与 `\s|\$` 的转义陷阱。
  static int _findKeyword({
    required String rest,
    required String keyword,
    int from = 0,
  }) {
    for (var i = from; i + keyword.length <= rest.length; i++) {
      if (_keywordAt(rest, i, keyword)) return i;
    }
    return -1;
  }

  static bool _keywordAt(String rest, int at, String keyword) {
    if (!rest.startsWith(keyword, at)) return false;
    final after = at + keyword.length;
    return after >= rest.length || _isSpace(rest.codeUnitAt(after));
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

  /// 解析 `2026-10-11,7:00` / `2026-10-11 07:00` / `2026-10-11`。
  /// 返回时刻 + **紧跟在后面的剩余文本**（可能是没写「备注」标记的散文）。
  /// 值本身认不出（空串或坏值）返回 null。
  static _Stamp? _parseStampAt(String? text) {
    final raw = text?.trim() ?? '';
    if (raw.isEmpty) return null;
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[,\s]+(\d{1,2}):(\d{2}))?')
        .firstMatch(raw);
    if (m == null) return null;
    final date = DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
    final at = m.group(4) == null
        ? date
        : DateTime(date.year, date.month, date.day, int.parse(m.group(4)!),
            int.parse(m.group(5)!));
    return _Stamp(
      at: at,
      rest: raw.substring(m.end).trim(),
      hasTime: m.group(4) != null,
    );
  }

  /// 解析必填时间戳：认不出就抛（由 [parse] 降级为 warning）。
  DateTime _parseStampRequired(String text, String field) {
    final stamp = _parseStampAt(text);
    if (stamp == null) {
      throw FormatException('$field 后面没有可识别的日期（形如 2026-10-11,7:00）');
    }
    return stamp.at;
  }

  // ------------------------------------------------------------------
  // 渲染
  // ------------------------------------------------------------------

  /// 把任务渲染成一行（不含换行）。这是**唯一**的行格式真相：
  /// 人看到的、内核指纹算的，都是这一行。
  ///
  /// 复选框只认**显式完成**（status=completed 或落过完成时刻），**不认**
  /// `Task.isCompleted` 里那条"flex 的剩余工时为 0 即算干完"的派生判断——
  /// 那条是调度/统计语义，不是"用户打了勾"。若把它写进复选框，一次
  /// 读→写往返就会把 `- [ ]` 变成 `- [x]`，行指纹随之改变、人类的意图被篡改。
  static String encodeLine(Task task) {
    final done =
        task.status == TaskStatus.completed || task.completedAt != null;
    final b = StringBuffer(done ? '- [x] ' : '- [ ] ');
    b.write(task.title.replaceAll(RegExp(r'\s+'), ' ').trim());
    b.write(' $createKeyword ${fmtStamp(task.created)}');
    if (task.deadline != null) {
      b.write(' $endKeyword ${fmtStamp(task.deadline!)}');
    }
    if (task.completedAt != null) {
      b.write(' $doneKeyword ${fmtStamp(task.completedAt!)}');
    }
    final note = task.description.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (note.isNotEmpty) b.write(' $noteKeyword $note');
    for (final tag in task.tags) {
      final clean = tag.trim().replaceAll(RegExp(r'\s+'), '-');
      if (clean.isNotEmpty) b.write(' ##$clean');
    }
    return b.toString();
  }

  /// 行内容（不含复选框）→ [TaskDocumentCodec.digestOf] 的输入。
  /// 内核属性文件里的 `digest` 与此对应。
  static String digestFor(Task task) {
    final line = encodeLine(task);
    final box = _checkbox.firstMatch(line);
    final content = box == null ? line.trim() : line.substring(box.end).trim();
    return digestOf(content);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 人类可读时间戳：`2026-10-11,07:00`（小时补零，跟日期格调一致）。
  static String fmtStamp(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
      ',${_two(d.hour)}:${_two(d.minute)}';
}

/// 解析结果：整篇文档 + 识别出的任务行 + 告警。
class TaskDocument {
  const TaskDocument({
    required this.lines,
    required this.tasks,
    required this.warnings,
    required this.hadTrailingNewline,
  });

  /// 原文按 `\n` 切分（未做行尾归一，写入时原样拼回）。
  final List<String> lines;
  final List<TaskLine> tasks;
  final List<String> warnings;
  final bool hadTrailingNewline;

  /// 拼回文本（逐行保真：没被显式改写过的行一个字符都不动）。
  ///
  /// 注意 `split('\n')` 已经把"结尾换行"体现成**最后一个空元素**，所以这里
  /// 只在"原文以换行结尾、却被切掉了那个空元素"时补回一个——否则每写一次
  /// 就多出一个空行（实现期实测踩到）。
  String join([List<String>? override]) {
    final body = (override ?? lines).join('\n');
    if (!hadTrailingNewline) return body;
    return body.endsWith('\n') ? body : '$body\n';
  }
}

/// 文档里的一条任务行（人写的那一半）。
class TaskLine {
  const TaskLine({
    required this.index,
    required this.section,
    required this.content,
    required this.digest,
    required this.completed,
    required this.title,
    required this.created,
    required this.deadline,
    required this.completedAt,
    required this.description,
    required this.tags,
  });

  /// 在 [TaskDocument.lines] 中的行号。
  final int index;

  /// 所属 `# 小节` 名（无标题时为空串）。
  final String section;

  /// 行内容（复选框之后的部分，原样）。
  final String content;

  /// [TaskDocumentCodec.digestOf] 的结果。
  final String digest;

  final bool completed;
  final String title;
  final DateTime created;
  final DateTime? deadline;
  final DateTime? completedAt;
  final String description;
  final List<String> tags;
}

class _ParsedLine {
  const _ParsedLine({
    required this.completed,
    required this.title,
    required this.created,
    required this.deadline,
    required this.completedAt,
    required this.description,
    required this.tags,
  });

  final bool completed;
  final String title;
  final DateTime created;
  final DateTime? deadline;
  final DateTime? completedAt;
  final String description;
  final List<String> tags;
}
