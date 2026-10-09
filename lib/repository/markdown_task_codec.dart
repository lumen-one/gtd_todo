import '../domain/task.dart';
import 'task_codec.dart';

/// Markdown + frontmatter 编解码实现（formatId: md-frontmatter/1）。
///
/// 格式规范（附录 B）：frontmatter 为平铺的 `key: value` 行，每行一个字段、
/// 标量值；不支持列表/嵌套/多行标量。
///
/// 分级保真（§3.4 防线一，本类的核心职责）：
/// - **正文：字节级保真**——只要 description 未被显式修改，正文逐字节原样；
/// - **frontmatter：字段级保真**——应用拥有的字段行原地改写，未知字段行、
///   注释行、空行、行顺序原样保留。
class MarkdownTaskCodec implements TaskCodec {
  /// 应用拥有的字段（附录 B 字段表），编码时原地改写。
  static const List<String> _ownedKeys = [
    'id',
    'title',
    'deadline',
    'estimated_work',
    'remaining_work',
    'importance',
    'status',
    'snoozed_until',
    'created',
  ];

  /// 应用自有 metadata 键登记表（附录 B / §3.4 防线二）：跟随任务对象
  /// 改写（值变则行变、键消失则行删）；其余未知键仍按字段级保真原样往返。
  static const List<String> _metadataKeys = [
    'type',              // flex / fixed / routine（§4.1 类型三分，缓冲带试水）
    'pinned',            // 插队标记（决议 9）
    'picked_for_today',  // 被挑散件标记（决议 8）
    'pool_order',        // 任务池显示序（决议 14）
    'routine',           // 周期实例所属规则 id（决议 12）
    'routine_date',      // 周期实例的发生日 yyyy-MM-dd（决议 12）
    'routine_remind',    // 规则设了响（决议 18：时点性提醒）
    'routine_skipped',   // 跳过的那一天 yyyy-MM-dd（决议 23）
    'point_fired',       // 已响过的那一次时点提醒（只到点响一次）
  ];

  @override
  String get formatId => 'md-frontmatter/1';

  @override
  bool canDecode(String raw) {
    final lines = raw.split('\n');
    return lines.isNotEmpty && lines.first.trim() == '---';
  }

  @override
  DecodeResult decode(String raw) {
    final lines = raw.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') {
      throw const FormatException('缺少 frontmatter（首行应为 ---）');
    }
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        close = i;
        break;
      }
    }
    if (close < 0) throw const FormatException('frontmatter 未闭合');

    final meta = <String, String>{};
    final unknown = <String, String>{};
    for (var i = 1; i < close; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = line.indexOf(':');
      if (idx <= 0) continue; // 注释行或无冒号行：不是字段，编码时按原样保留
      var value = line.substring(idx + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      final key = line.substring(0, idx).trim();
      if (_ownedKeys.contains(key)) {
        meta[key] = value;
      } else {
        unknown[key] = value;
      }
    }

    final id = meta['id'];
    final title = meta['title'];
    final deadlineStr = meta['deadline'];
    if (id == null || id.isEmpty) throw const FormatException('缺少 id');
    if (title == null || title.isEmpty) {
      throw const FormatException('缺少 title');
    }
    // deadline 可空（ui-interaction.md §10 #2）：行缺失 = 散件（无截止）。
    final deadline = deadlineStr == null ? null : DateTime.tryParse(deadlineStr);
    if (deadlineStr != null && deadline == null) {
      throw FormatException('deadline 无法解析: $deadlineStr');
    }

    final body = lines.skip(close + 1).join('\n');
    final description = body.replaceFirst(RegExp(r'^\n+'), '').trimRight();

    final task = Task(
      id: id,
      title: title,
      deadline: deadline,
      description: description,
      estimatedWork: int.tryParse(meta['estimated_work'] ?? '') ?? 0,
      remainingWork: int.tryParse(meta['remaining_work'] ?? '') ??
          int.tryParse(meta['estimated_work'] ?? '') ??
          0,
      importance: int.tryParse(meta['importance'] ?? '') ?? 3,
      status: TaskStatus.values.firstWhere(
        (s) => s.name == (meta['status'] ?? 'pending'),
        orElse: () => TaskStatus.pending,
      ),
      snoozedUntil: meta['snoozed_until'] != null
          ? DateTime.tryParse(meta['snoozed_until']!)
          : null,
      created: DateTime.tryParse(meta['created'] ?? '') ?? DateTime.now(),
      metadata: Map.unmodifiable(unknown),
    );
    return DecodeResult(task: task);
  }

  @override
  String encode(EncodedTask input) {
    final t = input.task;
    final raw = input.originalRaw;
    if (raw == null || !canDecode(raw)) return _serializeFresh(t);

    final lines = raw.split('\n');
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        close = i;
        break;
      }
    }
    if (close < 0) return _serializeFresh(t);

    // 正文归属判定（D9）：以 baselineRaw（应用最后见到/写入的内容）为基准，
    // 而不是磁盘当前内容——任务对象可能落后于磁盘，磁盘正文默认保留。
    var bodyChanged = false;
    if (input.baselineRaw != null && canDecode(input.baselineRaw!)) {
      try {
        final baseline = decode(input.baselineRaw!);
        bodyChanged = baseline.task.description != t.description;
      } on FormatException {
        bodyChanged = false;
      }
    }

    final front = <String>[];
    final written = <String>{};
    for (var i = 1; i < close; i++) {
      final line = lines[i];
      final idx = line.indexOf(':');
      final key = idx > 0 ? line.substring(0, idx).trim() : null;
      if (key != null && _ownedKeys.contains(key)) {
        final value = _fieldValue(t, key);
        if (value == null) continue; // 如 deadline/snoozed_until 为空 → 整行移除
        final cr = line.endsWith('\r') ? '\r' : '';
        front.add('$key: $value$cr');
        written.add(key);
      } else if (key != null && _metadataKeys.contains(key)) {
        // 应用自有 metadata 键：跟随任务对象改写/删除（登记表见附录 B）
        final value = t.metadata[key];
        if (value == null) continue;
        final cr = line.endsWith('\r') ? '\r' : '';
        front.add('$key: $value$cr');
        written.add(key);
      } else {
        front.add(line); // 未知字段/注释/空行：原样保留（含行尾 \r）
      }
    }
    for (final key in _ownedKeys) {
      if (written.contains(key)) continue;
      final value = _fieldValue(t, key);
      if (value == null) continue;
      front.add('$key: $value');
    }
    for (final key in _metadataKeys) {
      if (written.contains(key)) continue;
      final value = t.metadata[key];
      if (value == null) continue;
      front.add('$key: $value');
    }

    // closing '---' 与正文之间必须补换行（lines.skip(close+1) 不含该换行）
    final bodyPart = bodyChanged ? '${t.description}\n' : lines.skip(close + 1).join('\n');
    return '---\n${front.join('\n')}\n---\n$bodyPart';
  }

  /// 应用拥有的字段取值；null 表示该字段应从文件中移除（仅 snoozed_until）。
  String? _fieldValue(Task t, String key) {
    switch (key) {
      case 'id':
        return t.id;
      case 'title':
        return t.title.replaceAll('\n', ' ');
      case 'deadline':
        return t.deadline == null ? null : fmtDateTime(t.deadline!);
      case 'estimated_work':
        return '${t.estimatedWork}';
      case 'remaining_work':
        return '${t.remainingWork}';
      case 'importance':
        return '${t.importance}';
      case 'status':
        return t.status.name;
      case 'snoozed_until':
        return t.snoozedUntil == null ? null : fmtDateTime(t.snoozedUntil!);
      case 'created':
        return fmtDateTime(t.created);
      default:
        return null;
    }
  }

  /// 全新文件（磁盘上还没有）：写正式字段 + **应用自有 metadata 键**
  /// （附录 B 登记表）。少了这一步，新建任务的 type/pinned/routine… 会在
  /// 落盘时丢失，重新加载后退化成普通 flex 任务（实现期实测到的 bug）。
  String _serializeFresh(Task t) {
    final b = StringBuffer('---\n');
    for (final key in _ownedKeys) {
      final value = _fieldValue(t, key);
      if (value == null) continue;
      b.writeln('$key: $value');
    }
    for (final key in _metadataKeys) {
      final value = t.metadata[key];
      if (value == null) continue;
      b.writeln('$key: $value');
    }
    b.writeln('---');
    b.writeln(t.description);
    return b.toString();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String fmtDateTime(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
      'T${_two(d.hour)}:${_two(d.minute)}';
}
