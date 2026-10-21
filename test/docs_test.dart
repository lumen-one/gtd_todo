import 'package:flutter_test/flutter_test.dart';

import '../tool/doc_lint.dart';

/// 文档守卫（`docs/AGENTS.md` 第 6 条）：文档坏了 `flutter test` 直接红。
///
/// 和 `architecture_test.dart` 是同一类东西——架构越线、文档指向不存在的
/// 文件，都不该等到"有人想起来"才被发现。规则本身在 `tool/doc_lint.dart`，
/// 那边有自己的测试（`doc_lint_test.dart`）；这里只负责把规则套到真实文档上。
///
/// 两条断言分开放，是为了失败时信息聚焦：死链和状态词是两种毛病，
/// 修法也不同。
void main() {
  late List<String> paths;
  late List<LintProblem> problems;

  setUpAll(() {
    final lint = loadRepoDocs();
    paths = lint.paths;
    problems = lint.run();
  });

  test('找得到文档（否则下面两条是假绿）', () {
    // loadRepoDocs 定位不到仓库根时会静默返回空集合，那时后面的断言全过
    // 但什么也没检查。这条是防"检查器空转"的。
    expect(paths.length, greaterThan(10),
        reason: '只找到 ${paths.length} 份文档，仓库根可能没找对');
  });

  test('没有死链，也没有指空的章节引用', () {
    final errors = problems
        .where((p) => p.severity == LintSeverity.error)
        .toList();
    if (errors.isEmpty) return;
    fail('${errors.length} 处需要先修：\n${_format(errors)}');
  });

  test('正文不写状态词', () {
    // 单独一条：警告混在错误里会被忽略，"这里加了【规划】"值得单独报一次。
    final warnings = problems
        .where((p) => p.severity == LintSeverity.warning)
        .toList();
    if (warnings.isEmpty) return;
    fail('${warnings.length} 处状态标注：\n${_format(warnings)}');
  });
}

String _format(List<LintProblem> problems) =>
    problems.map((p) => '  ${p.file}:${p.line}  ${p.message}').join('\n');
