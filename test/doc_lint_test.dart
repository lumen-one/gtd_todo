import 'package:flutter_test/flutter_test.dart';

import '../tool/doc_lint.dart';

/// 文档门禁自己的测试。
///
/// 门禁的价值全在"该报的时候真的会报"，而这一条只能靠测试保证——
/// 一个永远绿的检查器等于没写。所以每个规则都要有反例（断言它会红），
/// 不只有正例（断言它不会瞎报）。
///
/// 全部用例都在内存里跑：`DocLint` 不碰磁盘，"文件存在吗"由注入的
/// `exists` 回答，所以不需要在临时目录里造文件。
void main() {
  // ------------------------------------------------------------------ 死链

  group('死链', () {
    test('同目录相对路径能解析', () {
      final lint = _lint({
        'docs/a.md': '[乙](b.md)',
        'docs/b.md': '# 乙',
      });
      expect(lint.run(), isEmpty);
    });

    test('../ 能上跳一级', () {
      final lint = _lint({
        'docs/panels/a.md': '[架构](../architecture.md)',
        'docs/architecture.md': '# 架构',
      });
      expect(lint.run(), isEmpty);
    });

    test('指向不存在的文件报错误', () {
      final lint = _lint({'docs/a.md': '见 [乙](nope.md)。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.error);
      expect(p.line, 1);
      expect(p.message, contains('nope.md'));
    });

    test('行内代码里的链接是示例，不算死链', () {
      final lint = _lint({'docs/a.md': '写法：`[乙](nope.md)` 这样。'});
      expect(lint.run(), isEmpty);
    });

    test('围栏代码块里的链接不算死链（但会提示点不了）', () {
      // 剥代码是为了不误报死链；代码块里真写链接另有一条专门的提示。
      final lint = _lint({'docs/a.md': '```\n[乙](nope.md)\n```'});
      final problems = lint.run();
      expect(problems, hasLength(1));
      expect(problems.single.severity, LintSeverity.warning);
    });

    test('http / mailto / 纯锚点都跳过', () {
      final lint = _lint({
        'docs/a.md': '[一](https://x.com) [二](mailto:a@b.c) [三](#某节)',
      });
      expect(lint.run(), isEmpty);
    });

    test('带锚点的链接只校验文件名部分', () {
      final lint = _lint({
        'docs/a.md': '[乙](b.md#某节)',
        'docs/b.md': '# 乙',
      });
      expect(lint.run(), isEmpty);
    });
  });

  // -------------------------------------------------------------- 自指链接

  group('自指链接', () {
    // 反例来自真事：拆文档时把"附录 B.6"机械换成了本文件名，
    // `[主线文件](mainline.md)` 写在 mainline.md 里，点进去还是这一页。
    test('链到自己报错误', () {
      final lint = _lint({'docs/a.md': '- 存储：一个文件装全部（[主线文件](a.md)）。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.error);
      expect(p.line, 1);
      expect(p.message, contains('自指'));
    });

    test('绕一圈回到自己也算：./ 与 ../ 都归一化', () {
      final lint = _lint({
        'docs/panels/a.md': '[一](./a.md) 与 [二](../panels/a.md)',
      });
      expect(lint.run(), hasLength(2));
      expect(lint.run().every((p) => p.severity == LintSeverity.error), isTrue);
    });

    test('带锚点的自指是冗余，降一档警告', () {
      final lint = _lint({'docs/a.md': '[局限](a.md#已知局限)'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
      expect(p.message, contains('(#'));
    });

    test('指别的文件不报（正例）', () {
      final lint = _lint({
        'docs/a.md': '[格式](formats/f.md)',
        'docs/formats/f.md': '# 格式',
      });
      expect(lint.run(), isEmpty);
    });

    test('行内代码里的自指示例不算', () {
      final lint = _lint({'docs/a.md': '写法：`[本文](a.md)` 不要这样。'});
      expect(lint.run(), isEmpty);
    });
  });

  // -------------------------------------------------------------- 章节引用

  group('章节引用', () {
    test('本文档里存在的章节不报', () {
      final lint = _lint({'docs/a.md': '## 3.1 甲\n\n见 §3.1。'});
      expect(lint.run(), isEmpty);
    });

    test('本文档里不存在的章节报错，并指出是本文档', () {
      final lint = _lint({'docs/a.md': '## 3.1 甲\n\n见 §3.5。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.error);
      expect(p.message, contains('本文档'));
    });

    test('§ 前面紧邻的裸文件名决定目标', () {
      final lint = _lint({
        'docs/a.md': '见 architecture.md §12。',
        'docs/architecture.md': '## 12 局限',
      });
      expect(lint.run(), isEmpty);
    });

    test('反引号包起来的文件名也认', () {
      final lint = _lint({
        'docs/a.md': '见 `architecture.md` §12。',
        'docs/architecture.md': '## 12 局限',
      });
      expect(lint.run(), isEmpty);
    });

    test('§ 前面紧邻的链接决定目标', () {
      final lint = _lint({
        'docs/a.md': '见 [UI](ui-interaction.md) §9。',
        'docs/ui-interaction.md': '## 9 边界',
      });
      expect(lint.run(), isEmpty);
    });

    test('中间隔了斜杠就不算指向那个文件', () {
      // "见 [池](panels/pool.md) / §7.0" 里的 §7.0 说的是**本文档**，
      // 本文档没有 7.0，所以要报错——若误判成 pool.md 就会漏报。
      final lint = _lint({
        'docs/a.md': '见 [池](panels/pool.md) / §7.0。',
        'docs/panels/pool.md': '## 7.0 分组',
      });
      final p = lint.run().single;
      expect(p.message, contains('本文档'));
    });

    test('跨行的文件名不算（只扫单行）', () {
      // 链接在上一行、§ 在下一行：解析不到目标，退回本文档。
      // 这是刻意的：宁可报错让人把引用写在同一行，也不要猜错目标。
      final lint = _lint({
        'docs/a.md': '见 [架构](architecture.md)\n§4.4。',
        'docs/architecture.md': '## 4.4 乙',
      });
      final p = lint.run().single;
      expect(p.message, contains('本文档'));
    });

    test('范围引用的两个端点都校验', () {
      final ok = _lint({'docs/a.md': '## 0 甲\n## 2 乙\n\n见 §0–§2。'});
      expect(ok.run(), isEmpty);

      final bad = _lint({'docs/a.md': '## 0 甲\n\n见 §0–§2。'});
      final p = bad.run().single;
      expect(p.message, contains('§2'));
    });

    test('行内代码里的 § 是示例，不算引用', () {
      final lint = _lint({'docs/a.md': '写法：`§3.5` 这样。'});
      expect(lint.run(), isEmpty);
    });

    test('标题行里的 § 是说明，不算引用', () {
      final lint = _lint({'docs/a.md': '## 3 甲（原 §6）\n'});
      expect(lint.run(), isEmpty);
    });

    test('目标文件不存在时降级为警告', () {
      final lint = _lint({'docs/a.md': '见 gone.md §3。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
      expect(p.message, contains('目标文件不存在'));
    });
  });

  // ---------------------------------------------------------------- 状态词

  group('状态词', () {
    test('叙述历史报错误', () {
      final lint = _lint({'docs/a.md': '这次改成只取活跃任务。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.error);
    });

    test('状态标注只报警告', () {
      final lint = _lint({'docs/a.md': '该能力已实现。'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
    });

    test('一行同时命中近义词时只报一次', () {
      // "这次改成" 包含 "这次改"，不 break 就会报两遍。
      final lint = _lint({'docs/a.md': '这次改成别的写法了。'});
      expect(lint.run().length, 1);
    });

    test('规则文件豁免（它本来就在引用这些词）', () {
      final lint = _lint({'docs/AGENTS.md': '正文不写"已实现"这种标注。'});
      expect(lint.run(), isEmpty);
    });

    test('外部参考豁免', () {
      final lint = _lint({'docs/references/x.md': '已实现，计划中。'});
      expect(lint.run(), isEmpty);
    });

    test('方括号状态标记也报（【现状】/【待细化：…】）', () {
      // 这套标记 2026-10-21 已从文档里整套删掉：逐行标"现状"等于没标，
      // 而"未标注默认规划"会让整份文档默认过期。词表留在这里防回潮。
      for (final s in ['该节【现状】。', '字段【待细化：清单】。', '【已落地】的规则。']) {
        final p = _lint({'docs/a.md': s}).run().single;
        expect(p.severity, LintSeverity.warning, reason: s);
      }
    });

    test('开头的引用块也照查（撤掉了 20 行豁免）', () {
      // 豁免过：它让一份文档的整个开头（版本历史、"落地进度"）整段绕过检查。
      final lint = _lint({'docs/a.md': '> 落地进度：已实现。\n'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
    });

    test('打勾清单（✅）算状态标注', () {
      final lint = _lint({'docs/a.md': '1. 二期：任务池 + 日历弹窗；✅\n'});
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
    });
  });

  // -------------------------------------------------------------- 引用的坑

  group('引用的坑', () {
    test('文档别名紧贴 § 时报（会被解析成本文）', () {
      // "架构合同 §6" 不写文件名：本文恰好也有 §6，于是查得通，指错也看不出来。
      final lint = _lint({
        'docs/a.md': '回滚见 架构合同 §6。\n\n## 6. 别的节\n',
      });
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
      expect(p.message, contains('架构合同'));
    });

    test('别名不紧贴不算（隔了字说的是本文）', () {
      final lint = _lint({
        'docs/a.md': '（先改 UI 文档再改 §6）\n\n## 6. 别的节\n',
      });
      expect(lint.run(), isEmpty);
    });

    test('指到索引节并点名小部件时报', () {
      // 内容搬走之后只剩三行索引，但引用还写着"§4.2 的边界表"。
      final lint = _lint({
        'docs/a.md': '详见 b.md §4.2 的边界表。\n',
        'docs/b.md': '# 乙\n\n## 4. 插座\n\n### 4.2 交付类\n\n见 [交付](c.md)。\n',
        'docs/c.md': '# 丙',
      });
      final p = lint.run().single;
      expect(p.message, contains('索引节'));
    });

    test('只提章节、不点名小部件时不报', () {
      final lint = _lint({
        'docs/a.md': '详见 b.md §4.2。\n',
        'docs/b.md': '# 乙\n\n## 4. 插座\n\n### 4.2 交付类\n\n见 [交付](c.md)。\n',
        'docs/c.md': '# 丙',
      });
      expect(lint.run(), isEmpty);
    });

    test('代码块里的链接报（渲染成字面文本，点不了）', () {
      final lint = _lint({
        'docs/a.md': '```dart\n// 见 [格式](b.md)\n```\n',
        'docs/b.md': '# 乙',
      });
      final p = lint.run().single;
      expect(p.severity, LintSeverity.warning);
      expect(p.line, 2);
    });

    test('正文里的链接不误报', () {
      final lint = _lint({
        'docs/a.md': '见 [格式](b.md)。\n',
        'docs/b.md': '# 乙',
      });
      expect(lint.run(), isEmpty);
    });
  });

  // ------------------------------------------------------------ 行号守恒

  group('行号守恒', () {
    test('代码块占用行号，后面的报错行号不偏移', () {
      // stripCode 用空行占位而不是整段删除；整段删除的话这里会报第 3 行。
      final lint = _lint({
        'docs/a.md': '# 甲\n\n```dart\nvar x = 1;\n```\n\n正文见 [y](nope.md)。',
      });
      final p = lint.run().single;
      expect(p.line, 7);
    });
  });

  // ------------------------------------------------------------ 章节提取

  group('章节提取', () {
    test('只认数字开头的标题', () {
      final lint = _lint({
        'docs/a.md': '## 3 甲\n### 3.1 乙\n## 附录 B\n',
      });
      expect(lint.chaptersOf('docs/a.md'), {'3', '3.1'});
    });

    test('代码块里的标题不算章节', () {
      final lint = _lint({'docs/a.md': '```\n## 9 假的\n```\n'});
      expect(lint.chaptersOf('docs/a.md'), isEmpty);
    });
  });

  // -------------------------------------------------------------- 路径工具

  group('路径工具', () {
    test('joinPath 把第一个参数当目录，不往上退一级', () {
      // 这条是重构时真踩过的：把 root 当文件传进去，路径会少掉一层目录，
      // 于是 26 个文件报出 178 条假死链。
      expect(joinPath('/repo', 'docs/a.md'), '/repo/docs/a.md');
      expect(joinPath('/repo/docs', 'a.md'), '/repo/docs/a.md');
    });

    test('resolvePath 把第一个参数当文件，取它的父目录', () {
      expect(resolvePath('/repo/docs/a.md', 'b.md'), '/repo/docs/b.md');
      expect(
          resolvePath('/repo/docs/a.md', '../x.md'), '/repo/x.md');
    });

    test('normalizePath 处理反斜杠、点与多余的上跳', () {
      expect(normalizePath(r'C:\a\b\..\c.md'), 'C:/a/c.md');
      expect(normalizePath('/repo/./docs//a.md'), '/repo/docs/a.md');
      expect(normalizePath('/a/../../b.md'), '/b.md');
    });

    test('relativePath 输出相对仓库根的形式', () {
      expect(relativePath('/repo', '/repo/docs/a.md'), 'docs/a.md');
      expect(relativePath('/repo', '/other/a.md'), '/other/a.md');
    });
  });
}

/// 造一个全内存的检查器：`exists` 只认这次注入过的文档。
DocLint _lint(Map<String, String> docs) {
  final known = docs.keys.map((rel) => joinPath('/repo', rel)).toSet();
  final lint = DocLint(root: '/repo', exists: known.contains);
  docs.forEach(lint.add);
  return lint;
}
