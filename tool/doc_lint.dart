import 'dart:io';

/// 文档门禁的检查逻辑；`tool/check_docs.dart` 只是它的命令行外壳。
///
/// 设计上**不碰磁盘**：文档内容由调用方用 [DocLint.add] 注入，"这个文件
/// 存在吗"由 [FileExists] 回调回答。真实运行时用磁盘实现，测试里换成假的，
/// 于是每条规则都能在内存里验证，不必在临时目录里造一堆文件。
///
/// 三条检查的共同前提是**先剥掉代码**：文档里教人写链接的示例
/// （`` `[x](y.md)` ``）不是链接。剥的时候用空行占位，行号才守恒。

/// 判断某个路径是否存在。默认走磁盘，测试里替换掉。
typedef FileExists = bool Function(String absolutePath);

bool _diskExists(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// 严重度：error 直接让进程 exit=1，warning 只在 `--strict` 下算失败。
enum LintSeverity { error, warning }

/// 一条问题。`file` 相对仓库根，`line` 从 1 开始。
class LintProblem {
  const LintProblem(this.file, this.line, this.severity, this.message);

  final String file;
  final int line;
  final LintSeverity severity;
  final String message;

  @override
  String toString() => '$file:$line ${severity.name} $message';
}

class DocLint {
  DocLint({required String root, FileExists? exists})
      : root = normalizePath(root),
        _exists = exists ?? _diskExists;

  /// 仓库根，已归一化（`/` 分隔，无 `.` 与多余 `..`）。
  final String root;

  final FileExists _exists;

  /// 归一化绝对路径 → 原文。用 Map 而不是 List，同一文件重复 add 时覆盖。
  final Map<String, String> _docs = {};

  /// 注入一份文档。`relPath` 相对 [root]，内容不做任何预处理。
  void add(String relPath, String content) {
    _docs[joinPath(root, relPath)] = content;
  }

  /// 注入文档的相对路径清单（按字典序）。
  List<String> get paths =>
      _docs.keys.map((p) => relativePath(root, p)).toList()..sort();

  /// 某份文档里提取到的章节号集合；文件不存在返回 null（调用方降级为警告）。
  Set<String>? chaptersOf(String relPath) =>
      _chaptersOf(joinPath(root, relPath));

  /// 跑全部检查，返回**按文件和行号排好序**的问题列表。
  ///
  /// 每次调用都新建缓存：同一个文件被引用十次也只解析一次标题，但两次
  /// `run()` 之间不会串味（测试里会反复调用）。
  List<LintProblem> run() {
    final problems = <LintProblem>[];
    final chapterCache = <String, Set<String>?>{};

    for (final entry in _docs.entries) {
      final abs = entry.key;
      final rel = relativePath(root, abs);
      final raw = entry.value;

      // 死链要剥行内代码（示例链接不算链接）；
      // 章节引用不能剥（`architecture.md` §3.4 里文件名就在代码里）。
      final text = stripCode(raw);
      final chapterText = stripCode(raw, inlineCode: false);

      problems.addAll(_checkLinks(rel, abs, text));
      problems.addAll(_checkChapters(rel, abs, chapterText, chapterCache));
      problems.addAll(_checkCodeLinks(rel, raw));
      problems.addAll(_checkStatusWords(rel, text));
    }

    problems.sort((a, b) {
      final byFile = a.file.compareTo(b.file);
      return byFile != 0 ? byFile : a.line.compareTo(b.line);
    });
    return problems;
  }

  // -------------------------------------------------------------- 内容与章节

  String? _contentOf(String absPath) {
    final injected = _docs[absPath];
    if (injected != null) return injected;
    if (!_exists(absPath)) return null;
    try {
      return File(absPath).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  Set<String>? _chaptersOf(String absPath) {
    final content = _contentOf(absPath);
    if (content == null) return null;
    return _headingRe
        .allMatches(stripCode(content))
        .map((m) => m.group(1)!)
        .toSet();
  }

  // ------------------------------------------------------------------ 死链

  List<LintProblem> _checkLinks(String rel, String abs, String text) {
    final problems = <LintProblem>[];
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

        final resolved = resolvePath(abs, target);
        if (!_exists(resolved)) {
          problems.add(LintProblem(rel, i + 1, LintSeverity.error,
              '死链：$raw → ${relativePath(root, resolved)}'));
        }
      }
    }
    return problems;
  }

  // -------------------------------------------------------------- 章节引用

  List<LintProblem> _checkChapters(String rel, String abs, String text,
      Map<String, Set<String>?> cache) {
    final problems = <LintProblem>[];
    final lines = text.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.contains('§')) continue;
      // 标题里的 § 多半是在说明（"（原 §6）"），不是引用。
      if (line.trimLeft().startsWith('#')) continue;

      for (final m in _sectionRefRe.allMatches(line)) {
        // 行内代码里的 § 是示例（"写法：`§3.5`"），不是引用。
        if (_insideInlineCode(line, m.start)) continue;

        final refs = [m.group(1)!, if (m.group(2) != null) m.group(2)!];
        final target = _targetFor(abs, line, m.start);
        final targetChapters =
            cache.putIfAbsent(target, () => _chaptersOf(target));

        if (targetChapters == null) {
          problems.add(LintProblem(rel, i + 1, LintSeverity.warning,
              '§${refs.join('–')} 的目标文件不存在，无法校验章节'));
          continue;
        }
        for (final ref in refs) {
          if (!targetChapters.contains(ref)) {
            final where = target == abs ? '本文档' : relativePath(root, target);
            problems.add(LintProblem(rel, i + 1, LintSeverity.error,
                '章节引用 §$ref 在 $where 里不存在'));
            continue;
          }
          if (target == abs && _aliasBefore(line, m.start) != null) {
            final alias = _aliasBefore(line, m.start)!;
            problems.add(LintProblem(rel, i + 1, LintSeverity.warning,
                '「$alias §$ref」按本文档解析了；指别的文件要写路径链接'));
          }
          // 指向"索引节"只在一种情况下算问题：句子还点名了节里的小部件
          //（"详见 §4.2 的边界表"）——那说明作者以为正文还在那儿。
          final after = line.substring(m.end).replaceAll('`', '');
          final claimsPart =
              RegExp(r'^[^\n]{0,3}(里那句|里那段|的边界表|的表格|的清单|那张表|的那条|的公式)')
                  .hasMatch(after);
          if (claimsPart && _isIndexStub(_sectionBodyOf(target, ref))) {
            final where = target == abs ? '本文档' : relativePath(root, target);
            problems.add(LintProblem(rel, i + 1, LintSeverity.warning,
                '§$ref 在 $where 里已是索引节（正文搬走了），那句/那张表不在那儿'));
          }
        }
      }
    }
    return problems;
  }

  /// 同一行里 `§` 前面**紧邻**的文件名决定目标；没有就查当前文件。
  ///
  /// 认三种写法，优先级从高到低：
  /// 1. 紧邻的 Markdown 链接：`[UI 文档](../ui-interaction.md) §9`；
  /// 2. 紧邻的纯文本文件名：`architecture.md §3.4`（反引号包裹也认）；
  /// 3. 都没有 → 当前文件。
  ///
  /// "紧邻"是必须的：`[任务池页](panels/pool.md) / §7.0` 里 §7.0 说的是
  /// **当前文件**，不是 pool.md——中间隔了 `/` 就不算指向它。
  String _targetFor(String abs, String line, int refIndex) {
    final before = line.substring(0, refIndex).replaceAll('`', '');

    final tightLink = RegExp(r'\]\(([^)]+\.md)(?:#[^)]*)?\)\s{0,2}$');
    final link = tightLink.firstMatch(before);
    if (link != null) return resolvePath(abs, link.group(1)!);

    final plainName = RegExp(r'([\w\-./]+\.md)\s{0,2}$');
    final name = plainName.firstMatch(before);
    if (name != null) return resolvePath(abs, name.group(1)!);

    return abs;
  }

  /// `§` 前面**紧贴**的是文档别名（"架构合同 §6"、"arch §5.1"）而不是路径——
  /// 这种写法会被解析成本文，指错文件也查不出来。
  ///
  /// 必须紧贴：`（先改 UI 文档再改 §3.1）` 里的 §3.1 说的是本文，隔了字就不算。
  String? _aliasBefore(String line, int refIndex) {
    final head = line.substring(0, refIndex).replaceAll('`', '').trimRight();
    for (final a in _docAliases) {
      if (head.endsWith(a) || head.endsWith('$a =') || head.endsWith('$a=')) {
        return a;
      }
    }
    return null;
  }

  /// 目标章节的正文（标题行之后，到下一个标题行之前）。
  String _sectionBodyOf(String absPath, String ref) {
    final content = _contentOf(absPath);
    if (content == null) return '';
    final lines = content.split('\n');
    final head = RegExp('^#{1,6}\\s+${RegExp.escape(ref)}(?:\\.|\\s|\$)');
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      if (head.hasMatch(lines[i].trimRight())) {
        start = i;
        break;
      }
    }
    if (start < 0) return '';
    final buf = <String>[];
    for (var i = start + 1; i < lines.length; i++) {
      if (_anyHeadingRe.hasMatch(lines[i])) break;
      buf.add(lines[i]);
    }
    return buf.join('\n');
  }

  /// "索引节"判据：正文很短，而且把活指给了别处（含链接）。
  /// 引用这种节多半是想引正文——正文已经搬走了，得改引用或改指向。
  bool _isIndexStub(String body) {
    final visible = body.replaceAll(RegExp(r'\s'), '');
    return visible.length < 400 && _linkRe.hasMatch(body);
  }

  // -------------------------------------------------------------- 代码块链接

  /// 围栏代码块里的 `[x](y.md)` 渲染成**字面文本**，既点不了也查不到——
  /// 它多半是拆文档换链接时留下的碎片。
  List<LintProblem> _checkCodeLinks(String rel, String raw) {
    final problems = <LintProblem>[];
    final lines = raw.split('\n');
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trimLeft();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        inFence = !inFence;
        continue;
      }
      if (!inFence) continue;
      if (_linkRe.hasMatch(lines[i])) {
        problems.add(LintProblem(rel, i + 1, LintSeverity.warning,
            '代码块里的链接渲染成字面文本，点不了：写进正文或去掉链接语法'));
      }
    }
    return problems;
  }

  // ------------------------------------------------------------------ 状态词

  List<LintProblem> _checkStatusWords(String rel, String text) {
    if (_isWordCheckExempt(rel)) return const [];
    final problems = <LintProblem>[];
    final lines = text.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final w in _historyWords) {
        if (line.contains(w)) {
          problems.add(LintProblem(rel, i + 1, LintSeverity.error,
              '叙述历史「$w」：正文只写现状，历史归 commit 与 decisions'));
          break; // 一行只报一次：近义词会同时命中（"这次改成" 包含 "这次改"）
        }
      }
      for (final w in _statusWords) {
        if (line.contains(w)) {
          problems.add(LintProblem(rel, i + 1, LintSeverity.warning,
              '状态标注「$w」：正文只写现状，计划归 roadmap'));
          break;
        }
      }
    }
    return problems;
  }

  /// 规则文件与外部参考会**引用**这些词（"正文不写'已实现'"），排除在外。
  bool _isWordCheckExempt(String rel) =>
      rel.endsWith('docs/AGENTS.md') || rel.contains('docs/references/');
}

// -------------------------------------------------------------- 从磁盘加载

/// 仓库根 = 从 [from]（默认当前工作目录）往上找 `pubspec.yaml` + `docs/`，
/// 最多五层；找不到就退回起点。
///
/// 判据是"有个 docs 目录的项目根"，不是平台或路径约定——这样从子目录里
/// 跑测试或脚本也能定位。
String findRepoRoot([String? from]) {
  final start = normalizePath(from ?? Directory.current.path);
  var dir = start;
  for (var i = 0; i < 5; i++) {
    if (File('$dir/pubspec.yaml').existsSync() &&
        Directory('$dir/docs').existsSync()) {
      return dir;
    }
    final parent = Directory(dir).parent.path;
    if (normalizePath(parent) == dir) break;
    dir = normalizePath(parent);
  }
  return start;
}

/// 检查范围：根 `README.md` + `docs/**/*.md`，按字典序。
///
/// `docs/references/` 也在内（它的死链照查），但不参与状态词检查——
/// 那是外部参考，不该按本项目的写作规矩要求。
List<String> collectMarkdown(String root) {
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

/// 读盘并把整个仓库的文档注入检查器。
///
/// 命令行（`check_docs.dart`）和文档守卫测试（`test/docs_test.dart`）都用
/// 这一份——收集规则只能有一处，否则 CLI 绿而测试红这种怪事迟早出现。
DocLint loadRepoDocs([String? root]) {
  final r = root == null ? findRepoRoot() : normalizePath(root);
  final lint = DocLint(root: r);
  for (final file in collectMarkdown(r)) {
    lint.add(relativePath(r, file), File(file).readAsStringSync());
  }
  return lint;
}

// -------------------------------------------------------------------- 文本处理

/// 去掉围栏代码块，**保留行号**（删掉的内容用空行占位）。
///
/// [inlineCode] 控制是否连行内代码一起剥掉。两种检查的需求相反：
/// - **死链**要剥：`` `[x](y.md)` `` 是教人写链接的示例，不是链接；
/// - **章节引用**不能剥：`` `architecture.md` §3.4 `` 里文件名就在行内代码中，
///   剥掉就找不到目标了。行内代码**内部**的 `§` 由 [_insideInlineCode] 另行判断。
String stripCode(String text, {bool inlineCode = true}) {
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

/// [index] 是否落在行内代码里（前面有奇数个反引号）。
bool _insideInlineCode(String line, int index) =>
    RegExp('`').allMatches(line.substring(0, index)).length.isOdd;

/// 归一化：反斜杠转 `/`，消掉 `.` 与可消的 `..`。纯字符串操作，不碰磁盘，
/// 所以虚拟路径（测试里的 `/repo/docs/a.md`）也能算对。
String normalizePath(String path) {
  final unified = path.replaceAll('\\', '/');
  final leadingSlash = unified.startsWith('/');
  final parts = <String>[];
  for (final seg in unified.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!leadingSlash) {
        parts.add('..');
      }
      // 绝对路径的 `/..` 就是 `/`，直接丢弃，不让 `..` 留在根上。
      continue;
    }
    parts.add(seg);
  }
  return (leadingSlash ? '/' : '') + parts.join('/');
}

/// 目录 + 相对路径。注意和 [resolvePath] 的区别：这里的 `dir` 是**目录**，
/// 不再往上退一级——把 root 当文件传进来会少掉最后一段路径。
String joinPath(String dir, String rel) {
  if (rel.startsWith('/')) return normalizePath(rel);
  final d = normalizePath(dir);
  return normalizePath(d.isEmpty ? rel : '$d/$rel');
}

/// 相对路径解析：`fromFile` **所在目录** + `target`（所以 `fromFile` 是文件）。
String resolvePath(String fromFile, String target) {
  final norm = normalizePath(fromFile);
  if (target.startsWith('/')) return normalizePath(target);
  final idx = norm.lastIndexOf('/');
  final dir = idx < 0 ? '' : norm.substring(0, idx);
  return joinPath(dir, target);
}

/// 把绝对路径折回相对 [root] 的形式（用于报错信息）。
String relativePath(String root, String absolute) {
  final r = normalizePath(root);
  final a = normalizePath(absolute);
  if (r == '' || r == '.') return a;
  return a.startsWith('$r/') ? a.substring(r.length + 1) : a;
}

// ---------------------------------------------------------------- 匹配规则

final _linkRe = RegExp(r'\]\(([^)]+)\)');
final _headingRe = RegExp(r'^#+\s+(\d+(?:\.\d+)*)\.?\s', multiLine: true);

/// 任意标题行（用来切章节正文，不要求带编号）。
final _anyHeadingRe = RegExp(r'^#{1,6}\s');

/// 文档别名：写在 `§` 前面时，人以为它指那份文档，检查器却只能按本文档解析。
const _docAliases = ['架构合同', '架构文档', 'arch', 'UI 文档', 'ui 文档', '格式文档', '正典'];

/// 单个引用，或范围引用 `§0–§2` / `§3.4-§3.5`。范围一次产生两个编号。
final _sectionRefRe =
    RegExp(r'§\s*(\d+(?:\.\d+)*)(?:\s*[–—\-~]\s*§?\s*(\d+(?:\.\d+)*))?');

/// 硬禁用：叙述"曾经是什么样"，正文只写现状。
const _historyWords = [
  '这次改成',
  '这次改',
  '本次修改',
  '本次改',
  '历史遗留',
];

/// 软提示：状态标注。正文只写现状，状态由代码与测试承载。
///
/// 方括号式的状态标记（`【现状】`/`【规划】`/`【待细化】`）一律提示：它们会被
/// 逐行复制成噪音（一张 20 行的表每行都标"现状"等于没标），而且"未标注默认规划"
/// 这类约定会让整份文档默认处于过期状态。要说明某节是设计草案，用一句散文说一次。
const _statusWords = [
  '已实现',
  '未实现',
  '【规划',
  '【现状',
  '【待细化',
  '【已落地',
  '【本节全部',
  '计划中',
  '待定',
  '尚未',
  '✅',
];
