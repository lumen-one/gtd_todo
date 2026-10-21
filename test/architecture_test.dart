import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 架构守卫（docs/architecture.md §2 / §7）：
/// import 矩阵不是纸面约定——谁越线，flutter test 直接红。
///
/// 白名单即契约：application 允许的 import 清单对应"核心插座"，
/// 新增插座接口文件时需同步更新这里（并在 architecture.md §4.1 登记）。
void main() {
  test('架构守卫：import 矩阵', () {
    final violations = <String>[];

    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel =
          e.path.replaceAll('\\', '/').split('/lib/').last;
      if (rel == 'main.dart') continue; // 组装点豁免（§2）

      final lines = e.readAsLinesSync();
      for (final line in lines) {
        final m =
            RegExp("""^\\s*import\\s+['"](.+?)['"]""").firstMatch(line);
        if (m == null) continue;
        final imp = m.group(1)!;
        final where = 'lib/$rel → "$imp"';

        // 规则 1：核心三层零平台依赖
        if (rel.startsWith('domain/') ||
            rel.startsWith('scheduler/') ||
            rel.startsWith('application/')) {
          if (imp.startsWith('dart:io') || imp.startsWith('package:flutter')) {
            violations.add(where);
          }
        }

        // 规则 2：ui 不碰 repository / scheduler（接口与实现都不行）
        if (rel.startsWith('ui/')) {
          if (imp.contains('repository/') || imp.contains('scheduler/')) {
            violations.add(where);
          }
        }

        // 规则 3：repository 与 scheduler 互不依赖
        if (rel.startsWith('repository/') && imp.contains('scheduler/')) {
          violations.add(where);
        }
        if (rel.startsWith('scheduler/') && imp.contains('repository/')) {
          violations.add(where);
        }

        // 规则 3b：application 只许 import 插座接口，不许 import 任何具体实现
        if (rel.startsWith('application/')) {
          // 同目录相对 import（'delivery.dart' 这种无斜杠形式）只能落在
          // application/ 内部，天然合法；
          // repository/scheduler 侧按插座接口文件逐个登记（新增插座需同步此处
          // 并在 architecture.md §4.1 登记）。
          final isSiblingRelative = !imp.contains('/') &&
              !imp.startsWith('dart:') &&
              !imp.startsWith('package:');
          final allowed = (imp.startsWith('dart:') && !imp.startsWith('dart:io')) ||
              imp.contains('/domain/') ||
              imp.contains('/application/') ||
              isSiblingRelative ||
              imp.endsWith('repository/task_repository.dart') ||
              imp.endsWith('repository/routine_repository.dart') ||
              imp.endsWith('repository/mainline_repository.dart') ||
              imp.endsWith('scheduler/scheduler.dart');
          if (!allowed) violations.add(where);
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
