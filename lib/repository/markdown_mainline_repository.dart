import 'dart:io';

import '../domain/mainline.dart';
import 'mainline_codec.dart';
import 'mainline_repository.dart';
import 'markdown_mainline_codec.dart';

/// Markdown 实现：任务目录下单个 `主线.md`（附录 B.6）。
///
/// 保存前重读磁盘内容做"未知字段保真"的基准（与 routines.md 同一套策略）。
class MarkdownMainlineRepository implements MainlineRepository {
  final String dirPath;
  final MainlineCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownMainlineRepository(this.dirPath, {MainlineCodec? codec})
      : codec = codec ?? MarkdownMainlineCodec(),
        _file = File('$dirPath${Platform.pathSeparator}主线.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<Mainline>> loadAll() async {
    _warnings.clear();
    if (!_file.existsSync()) return const [];
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.mainlines;
    } catch (e) {
      _warnings.add('主线.md: $e');
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<Mainline> mainlines) async {
    final original = _file.existsSync() ? await _file.readAsString() : null;
    final raw = codec.encode(mainlines, originalRaw: original);
    await _file.parent.create(recursive: true);
    await _file.writeAsString(raw);
  }
}
