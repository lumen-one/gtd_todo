import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/notes_reader.dart';
import '../application/settings.dart';

/// 任务目录解析（**装配点与悬浮窗引擎共用**）：
/// 环境变量 `GTD_TASKS_DIR` > 引导配置（应用支持目录 `bootstrap.json`）> 平台默认。
///
/// 悬浮窗跑在原生前台服务的第二个 Flutter 引擎里，必须和主引擎指向同一个目录，
/// 否则两个引擎会各写各的文件。
Future<({String taskDir, FileBootstrapPort bootstrap})> resolveTaskDir() async {
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
  return (taskDir: taskDir, bootstrap: bootstrap);
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
