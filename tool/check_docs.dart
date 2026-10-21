import 'dart:io';

/// 文档门禁：死链、章节引用、状态词。
/// 运行：`dart run tool/check_docs.dart`
/// 加 `--strict` 时警告也算失败（用于 CI）。
///
/// 三项检查的分工：
/// - **死链**：`](path)` 指向的文件存在吗（相对当前文件解析）；
/// - **章节引用**：`§3.5` 在目标文件里真的有这一节吗——同一行里 `§` 前面最近的
///   `.md` 链接决定目标，没有链接就查当前文件；
/// - **状态词**：正文只写现状，不写"已实现 / 计划中 / 这次改成"。
///
/// 最关键的一条实现细节：**先剥掉代码块与行内代码再检查**。文档里教人写链接的
/// 示例（`` `[x](y.md)` ``）不是链接，检查器把它们当死链报出来，人就再也不会看它。
void main(List<String> args) {
  final strict = args.contains('--strict');
  final root = _repoRoot();
  final files = _collectMarkdown(root);

  final problems = <_Problem>[];
  final chapters = <String, Set<String>?>{};

  if (args.contains('--dump-chapters')) {
    for (final file in files) {
      stdout.writeln('${_rel(root, file)}: ${_chaptersOf(file)}');
    }
    return;
  }



  for (final file in files) {
    final rel = _rel(root, file);
    final raw = File(file).readAsStringSync();
    final text = _stripCode(raw);
    // 章节检查保留行内代码：`architecture.md` §3.4 里文件名就在代码里。
    final chapterText = _stripCode(raw, inlineCode: false);

    problems.addAll(_checkLinks(rel, file, text, root));
    problems.addAll(_checkChapters(rel, file, chapterText, root, chapters));
    problems.addAll(_checkStatusWords(rel, text));
  }

  final errors = problems.where((p) => p.severity == _Severity.error).length;
  final warnings = problems.length - errors;

  if (problems.isEmpty) {
    stdout.writeln('文档检查通过：${files.length} 个文件，无问题。');
    return;
  }

  problems.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });

  var currentFile = '';
  for (final p in problems) {
    if (p.file != currentFile) {
      currentFile = p.file;
      stdout.writeln('\n$currentFile');
    }
    final tag = p.severity == _Severity.error ? '错误' : '警告';
    stdout.writeln('  ${p.line.toString().padLeft(4)}  $tag  ${p.message}');
  }

  stdout.writeln('\n合计：$errors 个错误，$warnings 个警告'
      '（${files.length} 个文件）。');
  if (errors > 0 || (strict && warnings > 0)) {
    exitCode = 1;
  }
}

// ---------------------------------------------------------------- 采集文件

/// 仓库根 = 本脚本所在目录的上一级；从当前工作目录往上找不到就退回脚本位置。
String _repoRoot() {
  var dir = Directory.current.path;
  for (var i = 0; i < 5; i++) {
    if (File('$dir/pubspec.yaml').existsSync() &&
        Directory('$dir/docs').existsSync()) {
      return _norm(dir);
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  return _norm(Directory.current.path);
}

/// 检查范围：`README.md` + `docs/**/*.md`；`docs/references/` 是外部参考，不参与
/// 状态词检查（但它自己的死链仍要查）。
List<String> _collectMarkdown(String root) {
  final out = <String>[];
  final rootReadme = File('$root/README.md');
  if (rootReadme.existsSync()) out.add(_norm(rootReadme.path));

  final docs = Directory('$root/docs');
  if (!docs.existsSync()) return out;
  for (final e in docs.listSync(recursive: true)) {
    if (e is File && e.path.toLowerCase().endsWith('.md')) {
      out.add(_norm(e.path));
    }
  }
  out.sort();
  return out;
}

// ---------------------------------------------------------------- 剥代码

/// 去掉围栏代码块，**保留行号**（删掉的内容用空行占位）。
///
/// [inlineCode] 控制是否连行内代码一起剥掉。两种检查的需求相反：
/// - **死链**要剥：`` `[x](y.md)` `` 是教人写链接的示例，不是链接；
/// - **章节引用**不能剥：`` `architecture.md` §3.4 `` 里文件名就在行内代码中，
///   剥掉就找不到目标了。行内代码**内部**的 `§` 另行判断为示例。
String _stripCode(String text, {bool inlineCode = true}) {
  final out = <String>[];
  var inFence = false;
  for (final line in text.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      out.add('');
      continue;
    }
    if (inFence) {
      out.add('');
      continue;
    }
    out.add(inlineCode ? line.replaceAll(RegExp(r'`[^`]*`'), '') : line);
  }
  return out.join('\n');
}

/// `index` 是否落在行内代码里（前面有奇数个反引号）。
bool _insideInlineCode(String line, int index) {
  final before = line.substring(0, index);
  return RegExp('`').allMatches(before).length.isOdd;
}

// ---------------------------------------------------------------- 死链

final _linkRe = RegExp(r'\]\(([^)]+)\)');

List<_Problem> _checkLinks(
    String rel, String abs, String text, String root) {
  final problems = <_Problem>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final m in _linkRe.allMatches(lines[i])) {
      final raw = m.group(1)!.trim();
      if (raw.isEmpty) continue;
      if (raw.startsWith('http') ||
          raw.startsWith('https') ||
          raw.startsWith('mailto:') ||
          raw.startsWith('#')) {
        continue;
      }
      final target = raw.split('#').first;
      if (target.isEmpty) continue;

      final resolved = _resolve(abs, target);
      if (FileSystemEntity.typeSync(resolved) ==
          FileSystemEntityType.notFound) {
        problems.add(_Problem(
          rel,
          i + 1,
          _Severity.error,
          '死链：$raw → ${_rel(root, resolved)}',
        ));
      }
    }
  }
  return problems;
}

/// 相对路径解析：`fromFile` 所在目录 + `target`，处理 `.` 与 `..`。
String _resolve(String fromFile, String target) {
  final dir = File(fromFile).parent.path;
  return _norm('$dir/$target');
}

String _norm(String path) {
  final unified = path.replaceAll('\\', '/');
  final leadingSlash = unified.startsWith('/');
  final parts = <String>[];
  for (final seg in unified.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else {
        parts.add('..');
      }
      continue;
    }
    parts.add(seg);
  }
  return (leadingSlash ? '/' : '') + parts.join('/');
}

String _rel(String root, String abs) {
  final r = _norm(root);
  final a = _norm(abs);
  return a.startsWith('$r/') ? a.substring(r.length + 1) : a;
}

// ---------------------------------------------------------------- 章节引用

final _headingRe = RegExp(r'^#+\s+(\d+(?:\.\d+)*)\.?\s', multiLine: true);

/// 单个引用，或范围引用 `§0–§2` / `§3.4-§3.5`。范围一次产生两个编号。
final _sectionRefRe = RegExp(
    r'§\s*(\d+(?:\.\d+)*)(?:\s*[–—\-~]\s*§?\s*(\d+(?:\.\d+)*))?');

/// 文档开头的标注约定定义行（`> - **【现状】** = ...`）。它是**定义**不是**使用**。
final _definitionRe = RegExp(r'^>\s*-\s*\*\*【[^】]+】\*\*\s*=');
final _mdLinkRe = RegExp(r'\]\(([^)]+\.md)(?:#[^)]*)?\)');

List<_Problem> _checkChapters(String rel, String abs, String text, String root,
    Map<String, Set<String>?> cache) {
  final problems = <_Problem>[];
  final lines = text.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.contains('§')) continue;
    // 标题里的 § 多半是说明（"（原 §6）"），不是引用。
    if (line.trimLeft().startsWith('#')) continue;

    for (final m in _sectionRefRe.allMatches(line)) {
      // 行内代码里的 § 是示例（"写法：`§3.5`"），不是引用。
      if (_insideInlineCode(line, m.start)) continue;

      final refs = [m.group(1)!, if (m.group(2) != null) m.group(2)!];
      final target = _targetFor(abs, line, m.start);
      final targetChapters = cache.putIfAbsent(target, () => _chaptersOf(target));

      if (targetChapters == null) {
        problems.add(_Problem(
          rel,
          i + 1,
          _Severity.warning,
          '§${refs.join('–')} 的目标文件不存在，无法校验章节',
        ));
        continue;
      }
      for (final ref in refs) {
        if (!targetChapters.contains(ref)) {
          final where = target == abs ? '本文档' : _rel(root, target);
          problems.add(_Problem(
            rel,
            i + 1,
            _Severity.error,
            '章节引用 §$ref 在 $where 里不存在',
          ));
        }
      }
    }
  }
  return problems;
}

/// 同一行里 `§` 前面最近的**文件名**决定目标；没有就查当前文件。
///
/// 认三种写法，优先级从高到低：
/// 1. 紧邻的 Markdown 链接：`[UI 文档](../ui-interaction.md) §9`；
/// 2. 紧邻的纯文本文件名：`architecture.md §3.4`（反引号包裹也认）；
/// 3. 都没有 → 当前文件。
///
/// "紧邻"这条是必须的：`[任务池页](panels/pool.md) / §7.0` 里 §7.0 说的是**当前文件**，
/// 不是 pool.md——中间隔了 `/` 就不算指向它。
String _targetFor(String abs, String line, int refIndex) {
  final before = line.substring(0, refIndex).replaceAll('`', '');

  final tightLink = RegExp(r'\]\(([^)]+\.md)(?:#[^)]*)?\)\s{0,2}$');
  final link = tightLink.firstMatch(before);
  if (link != null) return _resolve(abs, link.group(1)!);

  final plainName = RegExp(r'([\w\-./]+\.md)\s{0,2}$');
  final name = plainName.firstMatch(before);
  if (name != null) return _resolve(abs, name.group(1)!);

  return abs;
}

Set<String>? _chaptersOf(String file) {
  final f = File(file);
  if (!f.existsSync()) return null;
  final text = _stripCode(f.readAsStringSync());
  return _headingRe
      .allMatches(text)
      .map((m) => m.group(1)!)
      .toSet();
}

// ---------------------------------------------------------------- 状态词

/// 硬禁用：叙述"曾经是什么样"，正文只写现状。
const _historyWords = [
  '这次改成',
  '这次改',
  '本次修改',
  '本次改',
  '历史遗留',
];

/// 软提示：状态标注。与"只写现状"冲突，但项目里仍有一套【现状】/【规划】约定，
/// 所以只提示不判错——清干净之前它一直是噪音。
const _statusWords = [
  '已实现',
  '未实现',
  '【规划】',
  '【待细化】',
  '计划中',
  '待定',
  '尚未',
];

/// 规则文件与外部参考会**引用**这些词（"正文不写'已实现'"），排除在外。
bool _isWordCheckExempt(String rel) =>
    rel.endsWith('docs/AGENTS.md') || rel.contains('docs/references/');

List<_Problem> _checkStatusWords(String rel, String text) {
  if (_isWordCheckExempt(rel)) return const [];
  final problems = <_Problem>[];
  final lines = text.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // 文档开头"标注约定"的定义行：它在**定义**这些词，不是在用。
    // 定义段可能跨几行，所以开头 20 行内的引用块整体跳过。
    if (_definitionRe.hasMatch(line)) continue;
    if (i < 20 && line.trimLeft().startsWith('>')) continue;

    for (final w in _historyWords) {
      if (line.contains(w)) {
        problems.add(_Problem(
          rel,
          i + 1,
          _Severity.error,
          '叙述历史「$w」：正文只写现状，历史归 commit 与 decisions',
        ));
        break; // 一行只报一次：近义词会同时命中（"这次改成" 包含 "这次改"）
      }
    }
    for (final w in _statusWords) {
      if (line.contains(w)) {
        problems.add(_Problem(
          rel,
          i + 1,
          _Severity.warning,
          '状态标注「$w」：正文只写现状，计划归 roadmap',
        ));
        break;
      }
    }
  }
  return problems;
}

// ---------------------------------------------------------------- 输出模型

enum _Severity { error, warning }

class _Problem {
  final String file;
  final int line;
  final _Severity severity;
  final String message;

  const _Problem(this.file, this.line, this.severity, this.message);
}
