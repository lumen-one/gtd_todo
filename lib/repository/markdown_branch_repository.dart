import 'dart:io';

import '../domain/branch.dart';
import 'branch_codec.dart';
import 'branch_repository.dart';
import 'markdown_branch_codec.dart';

/// Markdown 实现：任务目录下单个 `支线.md`（附录 B.8）。
class MarkdownBranchRepository implements BranchRepository {
  final String dirPath;
  final BranchCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownBranchRepository(this.dirPath, {BranchCodec? codec})
      : codec = codec ?? MarkdownBranchCodec(),
        _file = File('$dirPath${Platform.pathSeparator}支线.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<Branch>> loadAll() async {
    _warnings.clear();
    if (!_file.existsSync()) return const [];
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.branches;
    } catch (e) {
      _warnings.add('支线.md: $e');
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<Branch> branches) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(codec.encode(branches));
  }
}
