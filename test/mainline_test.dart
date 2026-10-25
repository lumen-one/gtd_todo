import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/mainline_service.dart';
import 'package:gtd_todo/domain/mainline.dart';
import 'package:gtd_todo/repository/markdown_mainline_codec.dart';
import 'package:gtd_todo/repository/memory_mainline_repository.dart';

/// 主线（§6.9 / 附录 B.6）：格式往返 + 命令语义。
void main() {
  group('MarkdownMainlineCodec', () {
    const sample = '''---
id: ml-20261018-aaaa
title: 论文冲刺
created: 2026-10-18T09:00
owner: me
---

### 行为链

- [ ] 列提纲
- [x] 写第三章 完成 2026-10-19,21:30 备注：卡了两小时，后来用番茄钟推过去
- [x] 通读一遍

### 记录

- 2026-10-19 ~ 2026-10-21 连续三天都在写第三章
- 2026-10-20
''';

    test('解析人工写的文件：步骤、完成时刻、备注、单日/跨日圈', () {
      final result = MarkdownMainlineCodec().decode(sample);
      expect(result.warnings, isEmpty);
      expect(result.mainlines, hasLength(1));
      final m = result.mainlines.single;
      expect(m.id, 'ml-20261018-aaaa');
      expect(m.title, '论文冲刺');
      expect(m.created, DateTime(2026, 10, 18, 9));
      expect(m.isActive, isTrue);
      expect(m.steps, hasLength(3));
      expect(m.steps[0].done, isFalse);
      expect(m.steps[1].done, isTrue);
      expect(m.steps[1].doneAt, DateTime(2026, 10, 19, 21, 30));
      expect(m.steps[1].note, '卡了两小时，后来用番茄钟推过去');
      expect(m.steps[2].done, isTrue);
      expect(m.steps[2].doneAt, isNull); // 手勾但没写时刻
      expect(m.doneSteps, 2);
      expect(m.isAllDone, isFalse);
      expect(m.nextStepIndex, 0);
      expect(m.logs, hasLength(2));
      expect(m.logs[0].start, DateTime(2026, 10, 19));
      expect(m.logs[0].end, DateTime(2026, 10, 21));
      expect(m.logs[0].dayCount, 3);
      expect(m.logs[1].text, isEmpty);
      expect(m.logs[1].dayCount, 1);
      // 自动流水只认"有完成时刻"的那一步
      expect(m.stepsDoneOn(DateTime(2026, 10, 19)), hasLength(1));
      expect(m.hasActivityOn(DateTime(2026, 10, 21)), isTrue);
    });

    test('往返：未知 frontmatter 字段保留，正文按模型重写', () {
      final codec = MarkdownMainlineCodec();
      final first = codec.decode(sample).mainlines.single;
      final encoded = codec.encode([first], originalRaw: sample);
      expect(encoded, contains('owner: me'));
      expect(encoded.contains('completed:'), isFalse);
      final again = codec.decode(encoded).mainlines.single;
      expect(again.title, first.title);
      expect(again.steps.length, first.steps.length);
      expect(again.steps[1].note, first.steps[1].note);
      expect(again.logs[0].end, first.logs[0].end);
    });

    test('归档：completed 有值、排序在跑的在前', () {
      final codec = MarkdownMainlineCodec();
      final a = Mainline(
        id: 'ml-a',
        title: '旧主线',
        created: DateTime(2026, 9, 1),
        completedAt: DateTime(2026, 9, 30, 18),
      );
      final b = Mainline(
        id: 'ml-b',
        title: '当前主线',
        created: DateTime(2026, 10, 1),
      );
      final raw = codec.encode([b, a]);
      final decoded = codec.decode(raw);
      expect(decoded.mainlines.map((m) => m.id), ['ml-b', 'ml-a']);
      expect(decoded.mainlines.last.completedAt, DateTime(2026, 9, 30, 18));
      expect(decoded.mainlines.last.isActive, isFalse);
    });

    test('月记：一条一行，手写重复行以后者为准，往返不丢', () {
      const raw = '''---
id: ml-m
title: 论文
created: 2026-10-01T09:00
---

### 行为链

- [ ] 列提纲

### 记录

- 2026-10-19 单天一条

### 月记

- 2026-10 这个月在写第三章
- 2026-09 九月在找资料
- 2026-10 十月改口了
''';
      final codec = MarkdownMainlineCodec();
      final m = codec.decode(raw).mainlines.single;
      expect(m.months, hasLength(2), reason: '同一个月只留一条');
      expect(m.monthNoteOf(2026, 10)?.text, '十月改口了');
      expect(m.monthsInOrder.map((n) => n.month), [9, 10]);
      // 月记不参与"哪天有内容"的判定
      expect(m.hasActivityOn(DateTime(2026, 10, 21)), isFalse);

      final encoded = codec.encode([m]);
      expect(encoded, contains('### 月记'));
      expect(encoded, contains('- 2026-10 十月改口了'));
      expect(codec.decode(encoded).mainlines.single.months, hasLength(2));
    });

    test('没有月记：保存后不留 `### 月记` 空段', () {
      final codec = MarkdownMainlineCodec();
      final m = codec.decode(sample).mainlines.single;
      expect(codec.encode([m]), isNot(contains('### 月记')));
    });

    test('宽容：缺 id / 未闭合 frontmatter 不抛异常', () {
      final codec = MarkdownMainlineCodec();
      final result = codec.decode('''
---
title: 没有 id
created: 2026-10-01T09:00
---

- [ ] x

---
id: ml-half
title: 没闭合
''');
      expect(result.mainlines, isEmpty);
      expect(result.warnings, isNotEmpty);
    });
  });

  group('MainlineService', () {
    test('创建 → 勾选记时刻 → 取消清时刻', () async {
      final now = DateTime(2026, 10, 21, 9);
      final repo = MemoryMainlineRepository();
      final svc = MainlineService(repo: repo, clock: () => now);
      final m = await svc.create(title: '论文', steps: ['列提纲', '写第三章']);
      expect(svc.active?.id, m.id);
      expect(svc.mainlines, hasLength(1));
      expect(svc.mainlines.single.steps, hasLength(2));

      await svc.toggleStep(m.id, 1, done: true);
      expect(svc.byId(m.id)!.steps[1].doneAt, now);
      expect(svc.byId(m.id)!.progressText, '1/2');

      await svc.toggleStep(m.id, 1, done: false);
      expect(svc.byId(m.id)!.steps[1].done, isFalse);
      expect(svc.byId(m.id)!.steps[1].doneAt, isNull);
    });

    test('归档必须全勾完；归档后 active 为空、数据仍在', () async {
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => DateTime(2026, 10, 21, 18, 0),
      );
      final m = await svc.create(title: '论文', steps: ['a', 'b']);
      await expectLater(svc.complete(m.id), throwsStateError);

      await svc.toggleStep(m.id, 0, done: true);
      await svc.toggleStep(m.id, 1, done: true);
      await svc.complete(m.id);

      expect(svc.active, isNull);
      expect(svc.archived, hasLength(1));
      expect(svc.byId(m.id)!.completedAt, DateTime(2026, 10, 21, 18));
      expect(svc.byId(m.id)!.steps, hasLength(2));
    });

    test('空链不算勾完（不能凭空归档）', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '空主线');
      expect(svc.byId(m.id)!.isAllDone, isFalse);
      await expectLater(svc.complete(m.id), throwsStateError);
    });

    test('整链重写保留完成状态（拖动排序不把勾掉的状态丢掉）', () async {
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => DateTime(2026, 10, 21, 9),
      );
      final m = await svc.create(title: '论文', steps: ['a', 'b', 'c']);
      await svc.toggleStep(m.id, 0, done: true);

      final steps = svc.byId(m.id)!.steps;
      await svc.setSteps(m.id, [steps[2], steps[0], steps[1]]);
      final after = svc.byId(m.id)!;
      expect(after.steps.map((s) => s.title), ['c', 'a', 'b']);
      expect(after.steps[1].done, isTrue);
      expect(after.steps[1].doneAt, DateTime(2026, 10, 21, 9));
    });

    test('记录：加 / 改 / 删；起止写反自动对调', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 19), text: '三天');
      final log = svc.byId(m.id)!.logs.single;
      expect(log.start, DateTime(2026, 10, 19));
      expect(log.end, DateTime(2026, 10, 21));

      await svc.updateLog(m.id, 0, text: '改过');
      expect(svc.byId(m.id)!.logs.single.text, '改过');

      await svc.removeLog(m.id, 0);
      expect(svc.byId(m.id)!.logs, isEmpty);
    });

    test('月记：一个月一条，再写就是改；空文本删掉这条', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');

      await svc.setMonthNote(m.id, 2026, 10, '这个月在写第三章');
      await svc.setMonthNote(m.id, 2026, 10, '改过');
      expect(svc.byId(m.id)!.months, hasLength(1));
      expect(svc.byId(m.id)!.monthNoteOf(2026, 10)!.text, '改过');

      await svc.setMonthNote(m.id, 2026, 9, '九月在找资料');
      expect(svc.byId(m.id)!.monthsInOrder.map((n) => n.month), [9, 10]);

      await svc.setMonthNote(m.id, 2026, 10, '   ');
      expect(svc.byId(m.id)!.months, hasLength(1));
      expect(svc.byId(m.id)!.monthNoteOf(2026, 10), isNull);
    });

    test('落盘 → 新实例读回（仓储是唯一事实来源）', () async {      final repo = MemoryMainlineRepository();
      final one = MainlineService(repo: repo);
      final m = await one.create(title: '论文', steps: ['a']);
      await one.addLog(m.id,
          start: DateTime(2026, 10, 19), end: DateTime(2026, 10, 20), text: '写');

      final two = MainlineService(repo: repo);
      await two.load();
      expect(two.active?.title, '论文');
      expect(two.active?.logs.single.text, '写');
    });

    test('两条归档主线按完成时刻从新到旧', () async {
      var now = DateTime(2026, 10, 1, 9);
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => now,
      );
      final a = await svc.create(title: 'A', steps: ['x']);
      await svc.toggleStep(a.id, 0, done: true);
      await svc.complete(a.id);

      now = DateTime(2026, 10, 5, 9);
      final b = await svc.create(title: 'B', steps: ['y']);
      await svc.toggleStep(b.id, 0, done: true);
      await svc.complete(b.id);

      expect(svc.archived.map((m) => m.title), ['B', 'A']);
      expect(svc.active, isNull);
    });
  });
}
