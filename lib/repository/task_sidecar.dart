import '../domain/task.dart';
import 'task_codec.dart';

/// 内核属性文档（`tasks/.gtd/<任务id>.md`）的编解码：**纯函数、无 IO**。
///
/// 与人类文档（[TaskDocumentCodec] / `tasks.md`）分工明确：
///
/// | 谁写 | 住哪 | 内容 |
/// |---|---|---|
/// | 人（Obsidian、共享） | `tasks.md` 的一行 | 任务名 / 创建 / 结束 / 完成 / 备注 / 标签 |
/// | 内核（应用算的） | `.gtd/<id>.md` | 任务id / 工作强度 / 优先级 / 时间裕度 / 剩余工作量 |
///
/// 这样"人改人的、应用改应用的"落到文件层面就分开了（§3.4 分级保真的新形态）：
/// 应用**永不重写用户那行**（只在需要时原地改复选框或补齐字段），
/// 用户手写的行也永远不会被内核字段噪声污染。
///
/// 文件形状（frontmatter 平铺 `key: value`，与 routines.md 同风格）：
///
/// ```markdown
/// ---
/// id: task-001
/// digest: 3f2a91c4      # 人类文档里那一行的指纹（人改过 → 不一致 → 内核同步）
/// work_intensity: 120   # 工作强度 = 完成它需要的工时（工作分钟）
/// remaining_load: 0.75  # 剩余工作量（分数：乘以工作强度才是分钟）
/// priority: 3           # 优先级 1–5（与 importance 同一枚硬币）
/// time_slack: 210       # 时间裕度（工作分钟，计算结果；下次重锚时刷新）
/// status: active
/// completed_at: 2026-10-12T15:19
/// ---
///
/// 内核备注（可选，自由文本：调度解释、AI 理由……应用不改这一段）
/// ```
///
/// **'长期'任务例外（v1.17，D18 / ui 决议 46）**：工作强度 = '长期'（三无任务的
/// 创建缺省）时，这份文档**只剩 `id` 一行**——上面那些内核算出来的键全部缺行，
/// `digest` 也没有（两文档配对走附录 B.3 第 2/3 档），`status` / `completed_at`
/// 同样不落（完成态只认人类文档的 `[x]` / `完成 <时刻>`，D14）。'长期'不单独落
/// 一行：**没有 `work_intensity` 行就是长期**，因此不新增 metadata 键。
/// 应用自有的 metadata 键（[registeredMetaKeys]）照常跟随任务对象改写。
class TaskSidecarCodec {
  const TaskSidecarCodec();

  /// 内核属性文档的格式标识（附录 B.2 登记）。
  static const String formatId = 'md-taskkernel/1';

  /// 内核拥有的字段（编码时原地改写；`null` 值 → 整行移除）。
  static const List<String> ownedKeys = [
    'id',
    'digest',
    'work_intensity',
    'remaining_load',
    'priority',
    'time_slack',
    'status',
    'snoozed_until',
    'completed_at',
  ];

  /// 应用自有的 **metadata 键**（附录 B.2 登记表）：不是内核算出来的字段，
  /// 但同样是应用财产——编码时**跟随任务对象改写**（值变则行变、键消失则行删），
  /// 其余未知键仍原样往返（§3.4 字段级保真）。
  ///
  /// 漏掉这一条，"插队（决议 9）/ 池子显示序（决议 14）/ 挑到今日（决议 8）/
  /// 跳过今天（决议 23）/ 只到点响一次（决议 32）/ 类型转换（§3.5 updateTask）/
  /// 挂起进行（决议 47）"这些持久意图就会在命令自己的重锚里蒸发——
  /// TaskService 每个命令后都重读磁盘。
  static const List<String> registeredMetaKeys = [
    'type',
    'pinned',
    'picked_for_today',
    'pool_order',
    'routine',
    'routine_date',
    'routine_remind',
    'routine_skipped',
    'point_fired',
    'remind', // v1.9：逐任务提醒开关（标准模式下让这一件出声，决议 38）
    'manual_order', // v1.12：手动序（无排序模式下的显示序，决议 43 / D17）
    'in_progress', // v1.18：挂起进行标记（长期任务顶置今日页，决议 47 / D19）
    'loose_home', // 散件的家（无排序档：今日页 ⑥ ↔ 池子散件段）
  ];

  /// 应用拥有的键 = 内核字段 + 登记的 metadata 键（这两类都要改写，不是"未知"）。
  static bool _isAppOwned(String key) =>
      ownedKeys.contains(key) || registeredMetaKeys.contains(key);

  bool canDecode(String raw) {
    final lines = raw.split('\n');
    return lines.isNotEmpty && lines.first.trim() == '---';
  }

  /// 解析内核属性文档。缺 id 抛 [FormatException]（由 repository 降级为 warning）。
  DecodeResult decode(String raw) {
    final lines = raw.split('\n');
    if (!canDecode(raw)) {
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
      if (line.trim().isEmpty) continue;
      final idx = line.indexOf(':');
      if (idx <= 0) continue; // 注释行：不是字段，编码时原样保留
      final key = line.substring(0, idx).trim();
      var value = line.substring(idx + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      if (ownedKeys.contains(key)) {
        meta[key] = value;
      } else {
        unknown[key] = value;
      }
    }

    final id = meta['id'];
    if (id == null || id.isEmpty) throw const FormatException('缺少 id');

    final body = lines.skip(close + 1).join('\n').replaceFirst(RegExp(r'^\n+'), '').trimRight();

    final intensityRaw = meta['work_intensity'];
    // '长期'不单独落一行：没有 work_intensity 行就是长期（v1.17，D18）——
    // estimatedWork / remainingWork / importance 三项全部缺位。
    final intensity =
        intensityRaw == null ? null : (int.tryParse(intensityRaw) ?? 0);
    final load = double.tryParse(meta['remaining_load'] ?? '');
    final priority = int.tryParse(meta['priority'] ?? '');

    // digest 是内核与人类文档对号的钥匙，必须回传给调用方（repository 靠它
    // 判断"行被外部改过没有"），所以它要留在 metadata 里——
    // 它不是"任务事实"，是两条文档之间的接线。
    final digest = meta['digest'];

    return DecodeResult(
      task: Task(
        id: id,
        // 任务名/创建/结束/完成/备注/标签都在人类文档那一行里（由 repository
        // 合并进来），这里只装内核属性。
        title: meta['title'] ?? '',
        estimatedWork: intensity,
        remainingWork: intensity == null
            ? null
            : (load == null || intensity <= 0
                ? intensity
                : (load * intensity).round().clamp(0, intensity)),
        // '长期'不设优先级（A3 豁免，D18）；非长期缺 priority 行按缺省 3。
        importance: intensity == null
            ? null
            : (priority == null ? 3 : (priority < 1 ? 1 : (priority > 5 ? 5 : priority))),
        status: TaskStatus.values.firstWhere(
          (s) => s.name == (meta['status'] ?? 'pending'),
          orElse: () => TaskStatus.pending,
        ),
        snoozedUntil: meta['snoozed_until'] == null
            ? null
            : DateTime.tryParse(meta['snoozed_until']!),
        completedAt: meta['completed_at'] == null
            ? null
            : DateTime.tryParse(meta['completed_at']!),
        metadata: Map.unmodifiable({
          if (digest != null && digest.isNotEmpty) 'digest': digest,
          ...unknown,
        }),
        description: body,
      ),
    );
  }

  /// 编码。没有 [EncodedTask.originalRaw]（或它认不出）时全新序列化。
  /// 有原文时按字段级保真合并：内核字段原地改写，注释/未知字段/内核备注原样保留。
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

    final front = <String>[];
    final written = <String>{};
    for (var i = 1; i < close; i++) {
      final line = lines[i];
      final idx = line.indexOf(':');
      final key = idx > 0 ? line.substring(0, idx).trim() : null;
      if (key != null && _isAppOwned(key)) {
        final value = fieldValue(t, key, digest: _digestField(t));
        if (value == null) continue; // 如 snoozed_until 为空 → 整行移除
        final cr = line.endsWith('\r') ? '\r' : '';
        front.add('$key: $value$cr');
        written.add(key);
      } else {
        front.add(line); // 注释/未知字段/空行：原样保留
      }
    }
    for (final key in [...ownedKeys, ...registeredMetaKeys]) {
      if (written.contains(key)) continue;
      final value = fieldValue(t, key, digest: _digestField(t));
      if (value == null) continue;
      front.add('$key: $value');
    }

    final bodyPart = lines.skip(close + 1).join('\n');
    return '---\n${front.join('\n')}\n---\n$bodyPart';
  }

  /// 内核字段取值；null = 该字段应从文件中移除。
  ///
  /// [digest] 由 repository 传（它才知道人类文档里那一行的指纹）；
  /// 缺省时从任务自身渲染，等于"这一行没被外部改过"。
  ///
  /// **'长期'任务（v1.17，D18）只写 `id` 一行**：下面这些内核算出来的键
  /// （含 digest / status / completed_at / snoozed_until）全部返回 null →
  /// 整行移除；完成态只认人类文档（D14），配对走附录 B.3 第 2/3 档。
  String? fieldValue(Task t, String key, {String? digest}) {
    final long = t.isLongTerm;
    switch (key) {
      case 'id':
        return t.id;
      case 'digest':
        return long ? null : digest;
      case 'work_intensity':
        return long ? null : '${t.estimatedWork}';
      case 'remaining_load':
        return long ? null : fmtLoad(t);
      case 'priority':
        return long ? null : '${t.importance ?? 3}';
      case 'time_slack':
        return t.metadata['time_slack'];
      case 'status':
        return long ? null : t.status.name;
      case 'snoozed_until':
        if (long) return null;
        return t.snoozedUntil == null ? null : fmtDateTime(t.snoozedUntil!);
      case 'completed_at':
        if (long) return null;
        return t.completedAt == null ? null : fmtDateTime(t.completedAt!);
      default:
        // 登记的应用自有 metadata 键（附录 B.2）：值直接取自任务对象；
        // 键在 metadata 里消失 → 返回 null → 整行移除（"键消失则行删"）。
        return registeredMetaKeys.contains(key) ? t.metadata[key] : null;
    }
  }

  static String? _digestField(Task t) => t.metadata['digest'];

  /// 全新文件：写全部内核字段（值为 null 的跳过）+ 未知 metadata 键。
  String _serializeFresh(Task t) {
    final b = StringBuffer('---\n');
    for (final key in ownedKeys) {
      final value = fieldValue(t, key, digest: _digestField(t));
      if (value == null) continue;
      b.writeln('$key: $value');
    }
    for (final entry in t.metadata.entries) {
      if (ownedKeys.contains(entry.key)) continue;
      b.writeln('${entry.key}: ${entry.value}');
    }
    b.writeln('---');
    return b.toString();
  }

  /// 剩余工作量（分数）。`remaining_work`（分钟）换算回归一化值：
  /// 工作强度为 0（开始型任务豁免工时）或 **'长期'（无工时，D18）**时保持 0，
  /// 避免除零与空值。
  static String fmtLoad(Task t) {
    final est = t.estimatedWork;
    if (est == null || est <= 0) return '0';
    final load = (t.remainingWork ?? est) / est;
    final clamped = load < 0 ? 0.0 : (load > 1 ? 1.0 : load);
    // 三位小数足够（0.001 × 480 分钟 ≈ 半分钟），且好读
    var text = clamped.toStringAsFixed(3);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    }
    return text.isEmpty ? '0' : text;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String fmtDateTime(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
      'T${_two(d.hour)}:${_two(d.minute)}';
}
