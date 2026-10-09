import 'dart:async';
import 'dart:io';

import '../domain/task.dart';
import 'markdown_task_codec.dart';
import 'task_codec.dart';
import 'task_codec_registry.dart';
import 'task_repository.dart';

/// Markdown 文件夹实现。
///
/// 关键约定（附录 B / D9）：
/// - 一个任务一个 `.md` 文件，放在 [dirPath] 下；
/// - 保存前**重读磁盘文件**作为 originalRaw 交给 codec 做字段归属合并——
///   Obsidian 端对未知字段/正文的修改不会被应用覆盖；
/// - 外部 mtime 变化记入 notices 提示；
/// - 文件监听用 dart:io 的 Directory.watch（无第三方依赖），带 300ms 去抖，
///   不支持时返回 null；
/// - 解析宽容：坏文件不崩溃，记入 warnings。
class MarkdownTaskRepository implements TaskRepository {
  final String dirPath;
  final TaskCodecRegistry codecs;
  final Directory _dir;
  final List<String> _parseWarnings = [];
  final List<String> _notices = [];

  /// 每个任务最近一次"见到"的文件内容（load 或 save 时记录）。
  /// D9 外部修改检测：保存时与磁盘现读内容精确比对，不靠 mtime 猜。
  final Map<String, String> _lastSeenRaw = {};

  MarkdownTaskRepository(this.dirPath, {TaskCodecRegistry? codecRegistry})
      : codecs = codecRegistry ??
            TaskCodecRegistry(
              [MarkdownTaskCodec()],
              defaultFormatId: MarkdownTaskCodec().formatId,
            ),
        _dir = Directory(dirPath) {
    if (!_dir.existsSync()) _dir.createSync(recursive: true);
  }

  @override
  List<String> get warnings => [..._parseWarnings, ..._notices];

  @override
  Future<List<Task>> loadAll() async {
    _parseWarnings.clear();
    final tasks = <Task>[];
    if (!_dir.existsSync()) return tasks;
    for (final entity in _dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      try {
        final raw = await entity.readAsString();
        final codec = codecs.codecFor(raw);
        if (codec == null) {
          _parseWarnings.add('$name: 无法识别的任务格式');
          continue;
        }
        final result = codec.decode(raw);
        tasks.add(result.task);
        _lastSeenRaw[result.task.id] = raw;
      } catch (e) {
        _parseWarnings.add('$name: $e');
      }
    }
    tasks.sort((a, b) => a.created.compareTo(b.created));
    return tasks;
  }

  @override
  Future<Task?> getTask(String id) async {
    final f = File(_path(id));
    if (!f.existsSync()) return null;
    try {
      final raw = await f.readAsString();
      final codec = codecs.codecFor(raw);
      if (codec == null) return null;
      final result = codec.decode(raw);
      _lastSeenRaw[id] = raw;
      return result.task;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(Task task) async {
    final f = File(_path(task.id));
    final exists = f.existsSync();
    String? originalRaw;
    var external = false;
    if (exists) {
      originalRaw = await f.readAsString();
      final seen = _lastSeenRaw[task.id];
      external = seen != null && seen != originalRaw;
    }
    final codec =
        (originalRaw != null ? codecs.codecFor(originalRaw) : null) ??
            codecs.defaultCodec;
    final raw = codec.encode(EncodedTask(
      task: task,
      originalRaw: originalRaw,
      baselineRaw: _lastSeenRaw[task.id],
    ));
    await f.writeAsString(raw);
    _lastSeenRaw[task.id] = raw;
    if (external) {
      _pushNotice('${task.id}: 文件在加载后被外部修改，已按字段归属合并');
    }
  }

  @override
  Future<void> delete(String id) async {
    final f = File(_path(id));
    if (f.existsSync()) await f.delete();
    _lastSeenRaw.remove(id);
  }

  // ---- 软删除三件套（D11）：.trash/ 子目录，Obsidian 可见可捞 ----

  Directory get _trashDir =>
      Directory('${_dir.path}${Platform.pathSeparator}.trash');

  File _trashPath(String id) =>
      File('${_trashDir.path}${Platform.pathSeparator}$id.md');

  @override
  Future<void> moveToTrash(String id) async {
    final f = File(_path(id));
    if (!f.existsSync()) return;
    if (!_trashDir.existsSync()) _trashDir.createSync(recursive: true);
    await f.rename(_trashPath(id).path);
    _lastSeenRaw.remove(id);
  }

  @override
  Future<List<Task>> loadTrash() async {
    final tasks = <Task>[];
    if (!_trashDir.existsSync()) return tasks;
    for (final entity in _trashDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      try {
        final raw = await entity.readAsString();
        final codec = codecs.codecFor(raw);
        if (codec == null) continue;
        tasks.add(codec.decode(raw).task);
      } catch (_) {
        // 回收站里的坏文件：跳过，不影响主列表
      }
    }
    tasks.sort((a, b) => a.created.compareTo(b.created));
    return tasks;
  }

  @override
  Future<void> restore(String id) async {
    final f = _trashPath(id);
    if (!f.existsSync()) return;
    await f.rename(_path(id));
  }

  @override
  Future<void> purgeTrash() async {
    if (!_trashDir.existsSync()) return;
    await for (final entity in _trashDir.list()) {
      if (entity is File) await entity.delete();
    }
  }

  @override
  Stream<RepositoryEvent>? watch() {
    StreamController<RepositoryEvent>? out;
    StreamSubscription<FileSystemEvent>? sub;
    Timer? debouncer;
    try {
      final src = _dir.watch(
        events: FileSystemEvent.create |
            FileSystemEvent.modify |
            FileSystemEvent.delete |
            FileSystemEvent.move,
      );
      out = StreamController<RepositoryEvent>.broadcast();
      sub = src.listen(
        (e) {
          if (!e.path.endsWith('.md')) return;
          debouncer?.cancel();
          debouncer = Timer(const Duration(milliseconds: 300), () {
            if (out != null && !out.isClosed) {
              out.add(RepositoryEvent(RepoChangeType.changed, e.path, DateTime.now()));
            }
          });
        },
        onError: (_) {
          // 文件系统监听持续报错（目录被删等）：静默关闭，调用方走手动刷新
          debouncer?.cancel();
          sub?.cancel();
          if (out != null && !out.isClosed) out.close();
        },
      );
      out.onCancel = () {
        debouncer?.cancel();
        sub?.cancel();
      };
      return out.stream;
    } catch (_) {
      return null; // 平台不支持 → 调用方降级
    }
  }

  void _pushNotice(String message) {
    _notices.add(message);
    if (_notices.length > 50) _notices.removeAt(0);
  }

  String _path(String id) => '${_dir.path}${Platform.pathSeparator}$id.md';
}
