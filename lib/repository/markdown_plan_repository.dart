import 'dart:io';

import '../domain/plan.dart';
import 'markdown_plan_codec.dart';
import 'plan_codec.dart';
import 'plan_repository.dart';

/// Markdown 实现：任务目录下单个 `编排.md`（附录 B.7）。
class MarkdownPlanRepository implements PlanRepository {
  final String dirPath;
  final PlanCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownPlanRepository(this.dirPath, {PlanCodec? codec})
      : codec = codec ?? MarkdownPlanCodec(),
        _file = File('$dirPath${Platform.pathSeparator}编排.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<DayPlan>> loadAll() async {
    _warnings.clear();
    if (!_file.existsSync()) return const [];
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.days;
    } catch (e) {
      _warnings.add('编排.md: $e');
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<DayPlan> days) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(codec.encode(days));
  }
}
