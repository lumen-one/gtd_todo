import 'dart:io';

import '../domain/routine.dart';
import 'markdown_routine_codec.dart';
import 'routine_codec.dart';
import 'routine_repository.dart';

/// Markdown 实现：任务目录下单个 `routines.md`（决议 10）。
/// 保存前重读磁盘内容作为字段级保真基准（D9 同款策略）。
class MarkdownRoutineRepository implements RoutineRepository {
  final String dirPath;
  final RoutineCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownRoutineRepository(this.dirPath, {RoutineCodec? codec})
      : codec = codec ?? MarkdownRoutineCodec(),
        _file = File('$dirPath${Platform.pathSeparator}routines.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<Routine>> loadAll() async {
    _warnings.clear();
    if (!_file.existsSync()) return const [];
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.routines;
    } catch (e) {
      _warnings.add('routines.md: $e');
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<Routine> routines) async {
    final original = _file.existsSync() ? await _file.readAsString() : null;
    final raw = codec.encode(routines, originalRaw: original);
    await _file.parent.create(recursive: true);
    await _file.writeAsString(raw);
  }
}
