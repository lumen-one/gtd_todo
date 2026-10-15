import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../domain/task.dart';
import 'markdown_task_codec.dart';
import 'task_codec.dart';
import 'task_codec_registry.dart';
import 'task_document.dart';
import 'task_repository.dart';
import 'task_sidecar.dart';

/// **双文档** Markdown 实现（附录 B）。
///
/// 任务目录里的布局：
///
/// ```text
/// tasks/
/// ├── tasks.md            人类文档：# 标题分类 + 一行一条任务（Obsidian 看/改/共享）
/// ├── routines.md         周期规则（附录 B-2，独立文件，形态不变）
/// ├── .gtd/               内核属性文档目录（一个任务一个，应用自己写）
/// │   ├── <任务id>.md     任务id / 工作强度 / 优先级 / 时间裕度 / 剩余工作量
/// │   └── .trash/         软删除的内核属性文件（决议 15：Obsidian 可见可捞）
/// ├── settings.json
/// └── legacy-tasks/       迁移后的旧"一任务一文件"存档（只进不出）
/// ```
///
/// 归属划分（§3.4 分级保真的新形态）：
/// - **人类文档**：应用只改自己那一行（写入/打勾/补完成时刻），
///   其余行、标题、空行、正文一字不动；
/// - **内核属性文档**：应用全权拥有，人在 Obsidian 里也能看能改（字段级保真）。
///
/// 两条文档靠**行指纹**（[TaskDocumentCodec.digestOf]）重新对上号：
/// 用户在 Obsidian 里改标题/日期/备注 → 指纹变 → 内核认出"这一行被应用之外改过"
/// 并把人类那半边的字段同步过来（内核属性照旧保留）。
///
/// 迁移：目录里若只有旧的 `<id>.md` 任务文件而没有 `tasks.md`，首次读取会自动
/// 迁移（人类字段写成一行 + 内核属性写进 `.gtd/`），旧文件挪进 `legacy-tasks/`。
class MarkdownTaskRepository implements TaskRepository {
  /// 人类文档文件名（决议 36：所有任务记在这一个文档里，用标题分类）。
  static const String documentName = 'tasks.md';

  /// 内核属性文档目录名。
  static const String kernelDirName = '.gtd';

  /// 旧"一任务一文件"的存档目录名。
  static const String legacyDirName = 'legacy-tasks';

  /// `.gtd/` 里的**非任务文档**：操作流水 `log.md`（决议 37）。
  ///
  /// 内核属性扫描与文件监听都要跳过它——它只是观察手段，不是任务事实。
  /// 监听它还会自激成环：写日志 → 文件变化 → 重锚 → 又写日志。
  static const String logFileName = 'log.md';

  /// [path] 是否指向流水（不是任务数据）。
  static bool _isLogFile(String path) =>
      path.split(Platform.pathSeparator).last == logFileName;

  static const String _deletedPrefix = '<!-- gtd:deleted ';

  final String dirPath;
  final TaskDocumentCodec documentCodec;
  final TaskSidecarCodec sidecarCodec;
  final TaskCodecRegistry codecs;

  final Directory _dir;
  final List<String> _parseWarnings = [];
  final List<String> _notices = [];

  /// 每个任务最近一次"见到"的内核文档内容（D9 外部修改检测的基准）。
  final Map<String, String> _lastSeenSidecar = {};

  /// 最近一次读文档时记下的"行指纹 → 任务 id"（save 靠它定位要改的那一行）。
  final Map<String, String> _digestToId = {};

  /// 行指纹算不出来时的兜底路径：任务 id → 内核属性里的 digest。
  final Map<String, String> _idToDigest = {};

  final Random _random = Random();

  MarkdownTaskRepository(
    this.dirPath, {
    TaskCodecRegistry? codecRegistry,
    TaskDocumentCodec? documentCodec,
    TaskSidecarCodec? sidecarCodec,
  })  : documentCodec = documentCodec ?? const TaskDocumentCodec(),
        sidecarCodec = sidecarCodec ?? const TaskSidecarCodec(),
        codecs = codecRegistry ??
            TaskCodecRegistry(
              const [MarkdownTaskCodec()],
              defaultFormatId: const MarkdownTaskCodec().formatId,
            ),
        _dir = Directory(dirPath) {
    if (!_dir.existsSync()) _dir.createSync(recursive: true);
  }

  @override
  List<String> get warnings => [..._parseWarnings, ..._notices];

  // ------------------------------------------------------------------
  // 路径
  // ------------------------------------------------------------------

  File get _docFile => File('${_dir.path}${Platform.pathSeparator}$documentName');

  Directory get _kernelDir =>
      Directory('${_dir.path}${Platform.pathSeparator}$kernelDirName');

  Directory get _trashDir =>
      Directory('${_kernelDir.path}${Platform.pathSeparator}.trash');

  Directory get _legacyDir =>
      Directory('${_dir.path}${Platform.pathSeparator}$legacyDirName');

  String _sidecarPathOf(String id) =>
      '${_kernelDir.path}${Platform.pathSeparator}$id.md';

  String _trashPathOf(String id) =>
      '${_trashDir.path}${Platform.pathSeparator}$id.md';

  // ------------------------------------------------------------------
  // 读：人类文档 + 内核属性 → Task
  // ------------------------------------------------------------------

  @override
  Future<List<Task>> loadAll() async {
    _parseWarnings.clear();
    _digestToId.clear();
    _idToDigest.clear();

    if (!_docFile.existsSync()) {
      // 目录里只有旧格式的任务文件 → 首次读取时迁移
      final legacy = _legacyTaskFiles();
      if (legacy.isNotEmpty) {
        final migrated = await _migrateLegacy(legacy);
        _notices.add('已把 ${migrated.length} 个旧格式任务迁移进 $documentName'
            '（内核属性移入 $kernelDirName/，旧文件移入 $legacyDirName/ 存档）');
      }
    }

    final raw = _docFile.existsSync() ? await _docFile.readAsString() : '';
    final document = documentCodec.parse(raw);
    _parseWarnings.addAll(document.warnings);

    final sidecars = await _loadSidecarIndex();
    final lines = document.tasks;

    // ---- 把文档里的行与内核属性文档对上号（三档降级）----
    //
    // 档 1：行指纹相等 —— 最可靠，也是稳态（应用自己刚写过的行）。
    // 档 2：任务名相等 —— 首次迁移（内核属性文档还没有指纹）与"人只改了
    //        创建/结束/备注"的场合。
    // 档 3：位置配对 —— 两边剩下的数量**恰好相等**时，按创建先后一一配对。
    //        这覆盖"人在 Obsidian 里把任务名也改了"（指纹和名字都变了），
    //        代价是顺序假设：数量相等就默认是一一对应。数量不等时宁可不认领
    //        （新行当新任务处理），因为猜错会悄悄挪动内核属性。
    // **'长期'任务没有 digest**（v1.17，D18）：它的稳态配对走第 2/3 档
    // （任务名 / 位置）——改名且数量不等时按新任务接管并提示，不静默。
    final byDigest = <String, Task>{};
    for (final s in sidecars.values) {
      final digest = s.metadata['digest'];
      if (digest != null && digest.isNotEmpty) {
        byDigest.putIfAbsent(digest, () => s);
      }
    }

    final claimed = List<Task?>.filled(lines.length, null);
    final usedIds = <String>{};

    void claim(int index, Task sidecar) {
      if (claimed[index] != null || usedIds.contains(sidecar.id)) return;
      claimed[index] = sidecar;
      usedIds.add(sidecar.id);
    }

    for (var i = 0; i < lines.length; i++) {
      final byMark = byDigest[lines[i].digest];
      if (byMark != null) claim(i, byMark);
    }
    for (var i = 0; i < lines.length; i++) {
      if (claimed[i] != null) continue;
      final sameTitle = sidecars.values
          .where((s) => s.title.isNotEmpty && s.title == lines[i].title);
      for (final s in sameTitle) {
        if (!usedIds.contains(s.id)) {
          claim(i, s);
          break;
        }
      }
    }
    final freeLines = [
      for (var i = 0; i < lines.length; i++)
        if (claimed[i] == null) i,
    ]..sort((a, b) => lines[a].created.compareTo(lines[b].created));
    final freeSidecars = sidecars.values
        .where((s) => !usedIds.contains(s.id))
        .toList()
      // 按 id 排序 ≈ 按创建先后（id 前缀是时间戳，附录 B.2）。sidecar 没有
      // created 字段，拿读取时间排序等于随机——'长期'任务没有指纹（D18），
      // 稳态配对全靠这一档，顺序必须确定。
      ..sort((a, b) => a.id.compareTo(b.id));
    if (freeLines.length == freeSidecars.length && freeLines.isNotEmpty) {
      for (var k = 0; k < freeLines.length; k++) {
        claim(freeLines[k], freeSidecars[k]);
      }
    }

    // ---- 合并 + 落盘判定 ----
    final tasks = <Task>[];
    final changed = <Task>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      var sidecar = claimed[i];
      if (sidecar == null) {
        sidecar = Task(
          id: _allocateId(usedIds),
          title: line.title,
          created: line.created,
          // 新接管的行按**创建缺省**给工作强度（v1.17，D18，与 createTask
          // 同一套口径）：无截止（三无）→ '长期'；有截止 → 30 分钟（A2）。
          estimatedWork: line.deadline == null ? null : 30,
          importance: line.deadline == null ? null : 3,
        );
        usedIds.add(sidecar.id);
        claimed[i] = sidecar;
        _notices.add('${sidecar.id}: 发现新的任务行，已由内核接管并建立属性文档');
      }

      final merged = _merge(line: line, id: sidecar.id, sidecar: sidecar);
      tasks.add(merged);
      _digestToId[line.digest] = sidecar.id;
      _idToDigest[sidecar.id] = line.digest;

      // 需要落盘：新接管（没有属性文档 / 指纹为空）或人类那一行被改过。
      // 比对基准必须是**文档里那一行的指纹**（line.digest），不能拿 sidecar
      // 重新渲染一遍——sidecar 本来就不含任务名，渲染出来的行必然不同。
      final stored = sidecar.metadata['digest'];
      if (stored != line.digest) {
        // 指纹非空却没对上 = 这一行在应用之外被改过（人写的半边赢，
        // 内核属性保留）；全新接管不算"外部修改"。
        if (stored != null && stored.isNotEmpty) {
          _notices.add('${sidecar.id}: 任务行在应用之外被修改，已按归属合并'
              '（人写的那半边以文档为准，内核属性保留）');
        }
        changed.add(merged);
      }
    }

    for (final task in changed) {
      try {
        await _writeSidecar(task, digest: _idToDigest[task.id] ?? '');
      } on Object catch (e) {
        _parseWarnings.add('${task.id}: 内核属性写入失败 $e');
      }
    }

    // 属性文档还在、人类文档里的行却没了：只提示不删数据（文件即备份，
    // 删不删由人决定；回收站里也可能正躺着一条）。
    final orphans = sidecars.keys.where((id) => !usedIds.contains(id)).toList();
    if (orphans.isNotEmpty) {
      _notices.add('${orphans.length} 个任务在内核属性目录里还有记录，'
          '但 $documentName 里已找不到对应的行（属性文件保留未动）');
    }

    tasks.sort((a, b) => a.created.compareTo(b.created));
    return tasks;
  }

  @override
  Future<Task?> getTask(String id) async {
    for (final t in await loadAll()) {
      if (t.id == id) return t;
    }
    return _readSidecar(id); // 行已被删但属性还在：仍可读出来兜底
  }

  /// 合并两半：人类文档给"写的部分"，内核属性给"算的部分"。
  /// `digest`（两条文档之间的接线）不进最终 Task。
  ///
  /// '长期'任务（v1.17，D18）：sidecar 缺 `work_intensity` 行 → 三项缺位原样
  /// 带进合并结果——**不补数字缺省**，那会把"估不出来"伪装成 30 分钟。
  Task _merge({required TaskLine line, required String id, Task? sidecar}) {
    final metadata = <String, String>{
      if (sidecar != null)
        for (final e in sidecar.metadata.entries)
          if (e.key != 'digest') e.key: e.value,
    };
    return Task(
      id: id,
      title: line.title,
      description: line.description,
      deadline: line.deadline,
      estimatedWork: sidecar?.estimatedWork,
      remainingWork: sidecar?.remainingWork,
      importance: sidecar?.importance,
      // 人类文档的复选框是完成态的最终真相
      status: line.completed
          ? TaskStatus.completed
          : (sidecar?.status ?? TaskStatus.pending),
      snoozedUntil: sidecar?.snoozedUntil,
      created: line.created,
      completedAt: line.completedAt,
      tags: line.tags,
      metadata: metadata,
    );
  }

  /// 写完内核文档后，把新的行指纹记回任务（保存时要用）。
  Task _withDigest(Task task, String digest) => task.copyWith(
        metadata: {...task.metadata, 'digest': digest},
      );

  // ------------------------------------------------------------------
  // 写：内核属性先落盘，再改人类文档里那一行
  // ------------------------------------------------------------------

  @override
  Future<void> save(Task task) async {
    final document = await _readDocument(documentCodec);
    final digest = TaskDocumentCodec.digestFor(task);
    final index = _findLine(document, task.id);

    // 内核属性（自己的文档）先写：它才是权威副本
    await _writeSidecar(task, digest: digest);

    // 人类文档：只动自己那一行；没有就按标签追加
    if (index != null) {
      final replacement = TaskDocumentCodec.encodeLine(task);
      final old = document.lines[index];
      final cr = old.endsWith('\r') ? '\r' : '';
      if (old != '$replacement$cr') {
        await _writeDocument(document, index, '$replacement$cr');
      }
      _digestToId.remove(
        document.tasks.firstWhere((l) => l.index == index).digest,
      );
    } else {
      await _appendLine(task);
    }

    _digestToId[digest] = task.id;
    _idToDigest[task.id] = digest;
  }

  @override
  Future<void> delete(String id) async {
    final f = File(_sidecarPathOf(id));
    if (f.existsSync()) await f.delete();
    _lastSeenSidecar.remove(id);
    _idToDigest.remove(id);
    _digestToId.removeWhere((_, v) => v == id);
  }

  // ---- 软删除三件套（D11）：内核文件进 .gtd/.trash/，人类文档那一行注释掉 ----

  @override
  Future<void> moveToTrash(String id) async {
    final f = File(_sidecarPathOf(id));
    if (!f.existsSync()) return;
    if (!_trashDir.existsSync()) _trashDir.createSync(recursive: true);
    await f.rename(_trashPathOf(id));
    _lastSeenSidecar.remove(id);

    // 人类文档里那一行 → 注释掉（Obsidian 阅读模式下看不见，源文件里可捞回）。
    // 用 Obsidian 原生的 `%%…%%` 行内注释，不碰复选框语法本身。
    final document = await _readDocument(documentCodec);
    final index = _findLine(document, id);
    if (index == null) {
      _notices.add('$id: 已移入回收站，但 $documentName 里没有找到对应的行');
      return;
    }
    final line = document.lines[index];
    if (line.trimLeft().startsWith('%%')) return;
    final indent = line.substring(0, line.length - line.trimLeft().length);
    await _writeDocument(
      document,
      index,
      '$indent$_deletedPrefix$id --> %%${line.trim()}%%',
    );
  }

  @override
  Future<List<Task>> loadTrash() async {
    final tasks = <Task>[];
    if (!_trashDir.existsSync()) return tasks;
    for (final entity in _trashDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final sidecar = await _readSidecarFrom(entity.path);
      if (sidecar != null) tasks.add(sidecar);
    }
    // 人类文档里被注释掉的那行才是"人看到的名字"，合并回来再返回
    final document = await _readDocument(documentCodec);
    final deleted = <String>[];
    for (final line in document.lines) {
      if (!line.contains(_deletedPrefix)) continue;
      final at = line.indexOf('%%');
      final end = line.lastIndexOf('%%');
      if (at < 0 || end <= at) continue;
      deleted.add(line.substring(at + 2, end).trim());
    }
    if (deleted.isNotEmpty) {
      // 回收站里任务与"被注释掉的行"都按创建先后排，一一对应；
      // 数量不等时宁可不合并（保留内核属性原文），也不猜错。
      final lines = documentCodec.parse(deleted.join('\n')).tasks;
      if (lines.length == tasks.length) {
        for (var i = 0; i < tasks.length; i++) {
          tasks[i] = _merge(line: lines[i], id: tasks[i].id, sidecar: tasks[i]);
        }
      }
    }
    tasks.sort((a, b) => a.created.compareTo(b.created));
    return tasks;
  }

  @override
  Future<void> restore(String id) async {
    final f = File(_trashPathOf(id));
    if (f.existsSync()) {
      await _kernelDir.create(recursive: true);
      await f.rename(_sidecarPathOf(id));
    }
    final document = await _readDocument(documentCodec);
    final index = document.lines.indexWhere(
      (l) => l.contains(_deletedPrefix) && l.contains(id),
    );
    if (index < 0) return;
    final restored = _restoreDeletedLine(document.lines[index]);
    if (restored == null) return;
    final old = document.lines[index];
    final indent = old.substring(0, old.length - old.trimLeft().length);
    await _writeDocument(document, index, '$indent$restored');
  }

  @override
  Future<void> purgeTrash() async {
    if (_trashDir.existsSync()) {
      for (final entity in _trashDir.listSync()) {
        if (entity is File) await entity.delete();
      }
    }
    // 人类文档里被注释掉的删除行：一并真删
    final document = await _readDocument(documentCodec);
    final kept =
        document.lines.where((l) => !l.contains(_deletedPrefix)).toList();
    if (kept.length != document.lines.length) {
      await _docFile.writeAsString(document.join(kept));
    }
  }

  @override
  Stream<RepositoryEvent>? watch() {
    StreamController<RepositoryEvent>? out;
    final subs = <StreamSubscription<FileSystemEvent>>[];
    Timer? debouncer;
    try {
      out = StreamController<RepositoryEvent>.broadcast();
      void emit() {
        if (out != null && !out.isClosed) {
          out.add(RepositoryEvent(
              RepoChangeType.changed, _dir.path, DateTime.now()));
        }
      }

      void listenDir(Directory dir) {
        if (!dir.existsSync()) return;
        final src = dir.watch(
          events: FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.delete |
              FileSystemEvent.move,
        );
        subs.add(src.listen(
          (e) {
            if (_isLogFile(e.path)) return; // 流水写入不算"任务目录变了"
            if (!e.path.endsWith('.md') && !e.path.endsWith('.json')) return;
            debouncer?.cancel();
            debouncer = Timer(const Duration(milliseconds: 300), emit);
          },
          onError: (_) {
            // 文件系统监听持续报错（目录被删等）：静默，调用方走手动刷新
            debouncer?.cancel();
          },
        ));
      }

      listenDir(_dir);
      listenDir(_kernelDir);
      out.onCancel = () {
        debouncer?.cancel();
        for (final s in subs) {
          s.cancel();
        }
      };
      return out.stream;
    } catch (_) {
      return null; // 平台不支持 → 调用方降级
    }
  }

  // ------------------------------------------------------------------
  // 内部：人类文档
  // ------------------------------------------------------------------

  Future<TaskDocument> _readDocument(TaskDocumentCodec codec) async {
    final raw = _docFile.existsSync() ? await _docFile.readAsString() : '';
    return codec.parse(raw);
  }

  Future<void> _writeDocument(
    TaskDocument document,
    int index,
    String replacement,
  ) async {
    final lines = List<String>.from(document.lines);
    lines[index] = replacement;
    await _docFile.writeAsString(document.join(lines));
  }

  /// 新任务追加到"第一个标签对应的小节"末尾；没有这个小节就补一个小节。
  /// 这是**有意的最小策略**：位置只在新任务落地时决定一次，之后不再重排
  /// （人在 Obsidian 里怎么摆就怎么摆，应用不抢方向盘）。
  Future<void> _appendLine(Task task) async {
    final document = await _readDocument(documentCodec);
    final lines = List<String>.from(document.lines);
    final line = TaskDocumentCodec.encodeLine(task);
    final section = task.tags.isEmpty ? null : task.tags.first;

    var insertAt = -1;
    if (section != null) {
      for (var i = 0; i < lines.length; i++) {
        final heading = lines[i].trim();
        if (heading != '# $section' && heading != '## $section') continue;
        insertAt = i + 1;
        for (var j = i + 1; j < lines.length; j++) {
          final t = lines[j].trim();
          if (t.startsWith('#')) break;
          if (t.isEmpty) continue;
          insertAt = j + 1;
        }
        break;
      }
    }

    if (insertAt >= 0) {
      lines.insert(insertAt, line);
      await _docFile.writeAsString(document.join(lines));
      return;
    }

    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    lines.add('');
    if (section != null) {
      lines.add('# $section');
      lines.add('');
    }
    lines.add(line);
    await _docFile.parent.create(recursive: true);
    await _docFile.writeAsString('${lines.join('\n')}\n');
  }

  /// 任务 id 在人类文档里的行号；找不到返回 null。
  int? _findLine(TaskDocument document, String id) {
    final digest = _idToDigest[id];
    if (digest != null) {
      for (final l in document.tasks) {
        if (l.digest == digest) return l.index;
      }
    }
    // 指纹表过期（任务对象在我们的手之外变了）：拿属性文档里的 digest 认
    final stored = _lastSeenSidecar[id];
    if (stored != null) {
      final match = RegExp(r'^digest:\s*(\S+)\s*$', multiLine: true)
          .firstMatch(stored);
      final mark = match?.group(1);
      if (mark != null) {
        for (final l in document.tasks) {
          if (l.digest == mark) return l.index;
        }
      }
    }
    return null;
  }

  /// `<!-- gtd:deleted <id> --> %%<原行>%%` → `<原行>`；认不出返回 null。
  static String? _restoreDeletedLine(String line) {
    final start = line.indexOf('%%');
    final end = line.lastIndexOf('%%');
    if (start < 0 || end <= start) return null;
    final body = line.substring(start + 2, end).trim();
    return body.isEmpty ? null : body;
  }

  // ------------------------------------------------------------------
  // 内部：内核属性文档
  // ------------------------------------------------------------------

  Future<Map<String, Task>> _loadSidecarIndex() async {
    final out = <String, Task>{};
    if (!_kernelDir.existsSync()) return out;
    for (final entity in _kernelDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == logFileName) continue; // 流水不是内核属性文档（决议 37）
      final task = await _readSidecarFrom(entity.path);
      if (task == null) {
        _parseWarnings.add('$kernelDirName/$name: 内核属性文档无法解析，已忽略');
        continue;
      }
      if (out.containsKey(task.id)) {
        _parseWarnings
            .add('$kernelDirName/$name: 任务 id ${task.id} 重复，已忽略该文件');
        continue;
      }
      out[task.id] = task;
    }
    return out;
  }

  Future<Task?> _readSidecar(String id) => _readSidecarFrom(_sidecarPathOf(id));

  Future<Task?> _readSidecarFrom(String path) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final raw = await f.readAsString();
      final decoded = sidecarCodec.decode(raw).task;
      _lastSeenSidecar[decoded.id] = raw;
      // digest 是"两条文档之间的接线"，不是任务事实，所以它留在 metadata 里
      // 供匹配使用（_merge 会把它挡在最终 Task 之外，_writeSidecar 会把它写回）。
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// 写内核属性文档。传 [digest] 则记入行指纹（内核据此与人类文档对号）。
  /// **'长期'任务例外**（v1.17，D18）：codec 对长期任务不写 digest 与任何
  /// 内核算出来的字段，文档只剩 id 一行（+ 登记的 metadata 键）。
  Future<void> _writeSidecar(Task task, {String? digest}) async {
    final path = _sidecarPathOf(task.id);
    final file = File(path);
    final originalRaw = file.existsSync() ? await file.readAsString() : null;
    final marked = digest == null || digest.isEmpty
        ? task
        : _withDigest(task, digest);
    final raw = sidecarCodec.encode(
      EncodedTask(task: marked, originalRaw: originalRaw),
    );
    // 内容没变就不落盘。'长期'任务的内核文档没有 digest，loadAll 每轮都会
    // 判定"指纹不等"走进来（v1.17，D18）——无脑重写会触发文件监听 → 重锚 →
    // 再重写的自激循环；顺带也省掉其它任务的无谓写入。
    if (originalRaw == raw) {
      _lastSeenSidecar[task.id] = raw;
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(raw);
    _lastSeenSidecar[task.id] = raw;
  }

  // ------------------------------------------------------------------
  // 内部：迁移
  // ------------------------------------------------------------------

  /// 目录里符合旧格式（一任务一文件、带 id/title 的 frontmatter）的候选文件。
  List<File> _legacyTaskFiles() {
    final out = <File>[];
    for (final entity in _dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == documentName) continue;
      final raw = entity.readAsStringSync();
      final codec = codecs.codecFor(raw);
      if (codec == null || !codec.canDecode(raw)) continue;
      if (!raw.contains('id:') || !raw.contains('title:')) continue;
      out.add(entity);
    }
    return out;
  }

  Future<List<Task>> _migrateLegacy(List<File> files) async {
    final tasks = <Task>[];
    for (final f in files) {
      try {
        final raw = f.readAsStringSync();
        final codec = codecs.codecFor(raw);
        if (codec == null) continue;
        tasks.add(codec.decode(raw).task);
      } catch (e) {
        _parseWarnings.add(
            '${f.path.split(Platform.pathSeparator).last}: 迁移失败 $e');
      }
    }
    tasks.sort((a, b) => a.created.compareTo(b.created));

    final b = StringBuffer();
    for (final t in tasks) {
      b.writeln(TaskDocumentCodec.encodeLine(t));
    }
    await _docFile.parent.create(recursive: true);
    await _docFile.writeAsString(b.toString());
    for (final t in tasks) {
      await _writeSidecar(t, digest: TaskDocumentCodec.digestFor(t));
    }

    await _legacyDir.create(recursive: true);
    for (final f in files) {
      try {
        final name = f.path.split(Platform.pathSeparator).last;
        await f.rename('${_legacyDir.path}${Platform.pathSeparator}$name');
      } catch (_) {
        // 挪不动就留着：tasks.md 已存在，下次 loadAll 不会再迁移
      }
    }
    return tasks;
  }

  /// 任务 id：`task-<时间戳>-<随机尾巴>`。固定长度的前缀天然按创建先后排序，
  /// 随机尾巴保证同毫秒创建不撞。
  String _allocateId(Set<String> used) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    for (var i = 0; i < 1000; i++) {
      final tail = _random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
      final id = 'task-$stamp-$tail';
      if (used.contains(id)) continue;
      if (File(_sidecarPathOf(id)).existsSync()) continue;
      return id;
    }
    throw StateError('无法分配任务 id');
  }
}
