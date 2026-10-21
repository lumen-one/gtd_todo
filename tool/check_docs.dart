import 'dart:io';

import 'doc_lint.dart';

/// 文档门禁的命令行外壳；检查规则本身在 `tool/doc_lint.dart`。
///
/// 运行：`dart run tool/check_docs.dart`
/// - `--strict`：警告也算失败（CI 用）
/// - `--dump-chapters`：打印每份文档提取到的章节号（调规则时用）
///
/// 三项检查：
/// - **死链**：`](path)` 指向的文件存在吗（相对当前文件解析）；
/// - **章节引用**：`§3.5` 在目标文件里真的有这一节吗；
/// - **状态词**：正文只写现状，不写"已实现 / 计划中 / 这次改成"。
void main(List<String> args) {
  final root = _repoRoot();
  final files = _collectMarkdown(root);
  final lint = DocLint(root: root);

  for (final file in files) {
    lint.add(relativePath(root, file), File(file).readAsStringSync());
  }

  if (args.contains('--dump-chapters')) {
    for (final path in lint.paths) {
      stdout.writeln('$path: ${lint.chaptersOf(path)}');
    }
    return;
  }

  final problems = lint.run();

  if (problems.isEmpty) {
    stdout.writeln('文档检查通过：${files.length} 个文件，无问题。');
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

  stdout.writeln(
      '\n合计：$errors 个错误，$warnings 个警告（${files.length} 个文件）。');

  if (errors > 0 || (args.contains('--strict') && warnings > 0)) {
    exitCode = 1;
  }
}

/// 仓库根 = 从当前工作目录往上找 `pubspec.yaml` + `docs/`，最多五层。
String _repoRoot() {
  var dir = Directory.current.path;
  for (var i = 0; i < 5; i++) {
    if (File('$dir/pubspec.yaml').existsSync() &&
        Directory('$dir/docs').existsSync()) {
      return normalizePath(dir);
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  return normalizePath(Directory.current.path);
}

/// 检查范围：根 `README.md` + `docs/**/*.md`。
///
/// `docs/references/` 也在内（死链照查），但它不参与状态词检查——
/// 那是外部参考，不该按本项目的写作规矩要求。
List<String> _collectMarkdown(String root) {
  final out = <String>[];
  final rootReadme = File('$root/README.md');
  if (rootReadme.existsSync()) out.add(normalizePath(rootReadme.path));

  final docs = Directory('$root/docs');
  if (!docs.existsSync()) return out;
  for (final e in docs.listSync(recursive: true)) {
    if (e is File && e.path.toLowerCase().endsWith('.md')) {
      out.add(normalizePath(e.path));
    }
  }
  out.sort();
  return out;
}
