import 'dart:io';

import 'doc_lint.dart';

/// 文档门禁的命令行外壳；检查规则在 `tool/doc_lint.dart`。
///
/// 平时用不着它——`flutter test` 会通过 `test/docs_test.dart` 自动检查。
/// 这个命令用在两种场合：只想查文档（比全量测试快），以及看明细。
///
/// - `--strict`：警告也算失败
/// - `--dump-chapters`：打印每份文档提取到的章节号（调规则时用）
void main(List<String> args) {
  final lint = loadRepoDocs();
  final count = lint.paths.length;

  if (args.contains('--dump-chapters')) {
    for (final path in lint.paths) {
      stdout.writeln('$path: ${lint.chaptersOf(path)}');
    }
    return;
  }

  final problems = lint.run();

  if (problems.isEmpty) {
    stdout.writeln('文档检查通过：$count 个文件，无问题。');
    return;
  }

  var currentFile = '';
  for (final p in problems) {
    if (p.file != currentFile) {
      currentFile = p.file;
      stdout.writeln('\n$currentFile');
    }
    final tag = p.severity == LintSeverity.error ? '错误' : '警告';
    stdout.writeln('  ${p.line.toString().padLeft(4)}  $tag  ${p.message}');
  }

  final errors =
      problems.where((p) => p.severity == LintSeverity.error).length;
  final warnings = problems.length - errors;

  stdout.writeln('\n合计：$errors 个错误，$warnings 个警告（$count 个文件）。');

  if (errors > 0 || (args.contains('--strict') && warnings > 0)) {
    exitCode = 1;
  }
}
