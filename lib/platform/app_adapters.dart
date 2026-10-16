import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/event_log.dart';
import '../application/notes_reader.dart';
import '../application/settings.dart';

/// 任务目录解析（**装配点与悬浮窗引擎共用**）：
/// 环境变量 `GTD_TASKS_DIR` > 引导配置（应用支持目录 `bootstrap.json`）> 平台默认。
///
/// 悬浮窗跑在原生前台服务的第二个 Flutter 引擎里，必须和主引擎指向同一个目录，
/// 否则两个引擎会各写各的文件。
Future<({String taskDir, String supportDir, FileBootstrapPort bootstrap})>
    resolveTaskDir() async {
  final supportDir = (await getApplicationSupportDirectory()).path;
  final bootstrap = FileBootstrapPort(supportDir);
  final boot = await bootstrap.load();
  var taskDir = Platform.environment['GTD_TASKS_DIR'] ?? boot.taskDir ?? '';
  if (taskDir.isEmpty) {
    taskDir = Platform.isAndroid
        ? '${(await getApplicationDocumentsDirectory()).path}'
            '${Platform.pathSeparator}tasks'
        : 'tasks';
  }
  return (taskDir: taskDir, supportDir: supportDir, bootstrap: bootstrap);
}

/// 设置落盘适配器：任务目录下 settings.json（人类可读，可手改）。
/// 装配点装配；application 只见 SettingsPort 接口。
class FileSettingsPort implements SettingsPort {
  final File _file;

  FileSettingsPort(String dirPath)
      : _file = File('$dirPath${Platform.pathSeparator}settings.json');

  @override
  Future<AppSettings> load() async {
    if (!_file.existsSync()) return AppSettings.defaults;
    try {
      return decodeSettings(await _file.readAsString());
    } catch (_) {
      return AppSettings.defaults; // 坏文件不崩溃，回默认值
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _file.parent.create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await _file.writeAsString(enc.convert(settings.toJson()));
  }
}

/// 引导配置落盘适配器：应用文档目录下 bootstrap.json（任务目录尚未确定时
/// 就要读它，所以不能放在任务目录里）。
class FileBootstrapPort implements BootstrapPort {
  final File _file;

  FileBootstrapPort(String dirPath)
      : _file = File('$dirPath${Platform.pathSeparator}bootstrap.json');

  @override
  Future<BootstrapConfig> load() async {
    if (!_file.existsSync()) return const BootstrapConfig();
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map<String, Object?>) return BootstrapConfig.fromJson(json);
      return const BootstrapConfig();
    } catch (_) {
      return const BootstrapConfig();
    }
  }

  @override
  Future<void> save(BootstrapConfig config) async {
    await _file.parent.create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await _file.writeAsString(enc.convert(config.toJson()));
  }
}

/// 疑问笔记只读适配器：路径由设置注入（getter 形式，设置改动即时生效）。
/// 对该文件**零写入**——只读 + 提取（§6.2）。
class FileNotesReaderPort implements NotesReaderPort {
  final String? Function() pathGetter;

  const FileNotesReaderPort(this.pathGetter);

  @override
  Future<NotesReadResult> read() async {
    final path = pathGetter();
    if (path == null || path.trim().isEmpty) {
      return const NotesReadResult(NotesStatus.notConfigured);
    }
    final f = File(path);
    if (!f.existsSync()) return const NotesReadResult(NotesStatus.notFound);
    final raw = await f.readAsString();
    return extractNotesSection(raw);
  }
}

/// `log` 文档落盘适配器（决议 37）：任务目录 `.gtd/log.md`，**append-only**。
///
/// 只做追加：文件不存在时先写一个表头，之后每行一条。应用**从不重写**已有的行
/// （连"整理格式"都不做），所以这份流水可以放心当历史看。
///
/// **串行化**：事件是接连来的，而"建表头 + 追加"是两步异步 IO。并发跑会两个
/// 调用同时看到"文件不存在"→ 写两遍表头，甚至互相插队（实现期实测踩到）。
/// 所以这里把写入串成一条链：上一个写完才轮到下一个。
class FileEventLogPort implements EventLogPort {
  final File _file;
  Future<void> _chain = Future<void>.value();

  FileEventLogPort(String dirPath)
      : _file = File('$dirPath${Platform.pathSeparator}.gtd'
            '${Platform.pathSeparator}log.md');

  @override
  Future<void> append(String line) {
    final next = _chain.then((_) => _append(line));
    // 链路本身不因单次失败而断掉（错误由 EventLog 收进 failures）
    _chain = next.catchError((_) {});
    return next;
  }

  /// 等已排队的追加全部落盘（测试与"退出前冲刷"用）。
  Future<void> drain() => _chain;

  Future<void> _append(String line) async {
    await _file.parent.create(recursive: true);
    if (!_file.existsSync()) {
      await _file.writeAsString('# 操作流水（应用自动追加，只增不改）\n\n');
    }
    await _file.writeAsString('$line\n', mode: FileMode.append);
  }
}
