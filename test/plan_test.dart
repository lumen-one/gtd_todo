import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/plan_service.dart';
import 'package:qixing/domain/plan.dart';
import 'package:qixing/repository/markdown_plan_codec.dart';
import 'package:qixing/repository/memory_plan_repository.dart';

/// 今日编排（§6.11 / 附录 B.7）：格式往返 + 命令语义。
void main() {
  group('MarkdownPlanCodec', () {
    const sample = '### 2026-10-22\n'
        '\n'
        '- 08:30 晨会\n'
        '- 9:05 项目评审\n'
        '- 12:30 午餐休息\n'
        '- 临时插进来的事\n'
        '\n'
        '### 2026-10-21\n'
        '\n'
        '- 09:00 晨会\n';

    test('解析人工写的文件：时刻补零、没有时刻、多天', () {
      final result = MarkdownPlanCodec().decode(sample);
      expect(result.warnings, isEmpty);
      expect(result.days, hasLength(2));

      final today = result.days.first;
      expect(planDayKey(today.day), '2026-10-22');
      expect(today.entries, hasLength(4));
      expect(today.entries[0].timeText, '08:30');
      expect(today.entries[0].title, '晨会');
      expect(today.entries[1].timeText, '09:05'); // `9:05` 写成两位
      expect(today.entries[3].timeText, isNull);
      expect(today.entries[3].title, '临时插进来的事');

      expect(planDayKey(result.days[1].day), '2026-10-21');
    });

    test('时刻越界按"没有时刻"处理，原文留在标题里', () {
      final result = MarkdownPlanCodec().decode('### 2026-10-22\n\n- 25:00 加班\n');
      final entry = result.days.single.entries.single;
      expect(entry.minutesOfDay, isNull);
      expect(entry.title, '25:00 加班');
    });

    test('段外的自由文字与复选框行都不认', () {
      final result = MarkdownPlanCodec().decode(
        '随手一句\n'
        '\n'
        '- [ ] 不是编排\n'
        '\n'
        '### 2026-10-22\n'
        '\n'
        '- 08:00 晨会\n',
      );
      final entries = result.days.single.entries;
      expect(entries, hasLength(1));
      expect(entries.single.title, '晨会');
    });

    test('同一天允许重复标题（不去重）', () {
      final result = MarkdownPlanCodec()
          .decode('### 2026-10-22\n\n- 12:30 午餐休息\n- 12:30 午餐休息\n');
      expect(result.days.single.entries, hasLength(2));
    });

    test('编码：日子新→旧、行序不变、空的一天不落段', () {
      final raw = MarkdownPlanCodec().encode([
        DayPlan(
          day: DateTime(2026, 10, 21),
          entries: [const PlanEntry(title: 'B', minutesOfDay: 9 * 60)],
        ),
        DayPlan(
          day: DateTime(2026, 10, 22),
          entries: [
            const PlanEntry(title: 'A', minutesOfDay: 8 * 60 + 30),
            const PlanEntry(title: '没有时刻'),
          ],
        ),
        DayPlan(day: DateTime(2026, 10, 20)),
      ]);
      expect(
        raw,
        '### 2026-10-22\n'
        '\n'
        '- 08:30 A\n'
        '- 没有时刻\n'
        '\n'
        '### 2026-10-21\n'
        '\n'
        '- 09:00 B\n',
      );
    });

    test('往返：解码 → 编码 → 解码，条目一模一样', () {
      final codec = MarkdownPlanCodec();
      final first = codec.decode(sample);
      final again = codec.decode(codec.encode(first.days));
      expect(
        [for (final d in again.days) planDayKey(d.day)],
        [for (final d in first.days) planDayKey(d.day)],
      );
      expect(
        [
          for (final e in again.days.first.entries)
            '${e.timeText ?? '-'}|${e.title}'
        ],
        [
          for (final e in first.days.first.entries)
            '${e.timeText ?? '-'}|${e.title}'
        ],
      );
    });
  });

  group('PlanService', () {
    final today = DateTime(2026, 10, 22);
    final yesterday = DateTime(2026, 10, 21);

    test('追加 / 改 / 删 / 整日重写，别的日子不受影响', () async {
      final repo = MemoryPlanRepository([
        DayPlan(
          day: yesterday,
          entries: [const PlanEntry(title: '昨天的事', minutesOfDay: 9 * 60)],
        ),
      ]);
      final svc = PlanService(repo: repo);
      await svc.load();

      await svc.addEntry(today, const PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30));
      await svc.addEntry(today, const PlanEntry(title: '评审', minutesOfDay: 9 * 60 + 30));
      expect([for (final e in svc.entriesFor(today)) e.title], ['晨会', '评审']);

      await svc.updateEntry(today, 0, const PlanEntry(title: '晨会改', minutesOfDay: 8 * 60));
      expect(svc.entriesFor(today).first.title, '晨会改');

      await svc.setEntries(today, [...svc.entriesFor(today).reversed]);
      expect([for (final e in svc.entriesFor(today)) e.title], ['评审', '晨会改']);

      await svc.removeEntry(today, 0);
      await svc.removeEntry(today, 0);
      expect(svc.entriesFor(today), isEmpty);
      expect(svc.entriesFor(yesterday).single.title, '昨天的事');

      // 空的一天不落段：文件里只剩昨天
      final disk = await repo.loadAll();
      expect(disk, hasLength(1));
      expect(planDayKey(disk.single.day), '2026-10-21');
    });

    test('空标题不落地', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: '   ', minutesOfDay: 600));
      expect(svc.entriesFor(today), isEmpty);
    });

    test('改时刻即整轴归位：按时刻升序，没有时刻的沉到最后', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: 'A', minutesOfDay: 600));
      await svc.addEntry(today, const PlanEntry(title: 'B', minutesOfDay: 660));
      await svc.addEntry(today, const PlanEntry(title: 'C'));

      // A 从 10:00 推到 11:40：跑到 B 后面，无时刻的 C 仍在末尾。
      await svc.updateEntry(today, 0, const PlanEntry(title: 'A', minutesOfDay: 700));
      expect([for (final e in svc.entriesFor(today)) e.title], ['B', 'A', 'C']);

      // 清掉 B 的时刻：它也沉到末尾，且排在 C 之后（原来的先后不变）。
      await svc.updateEntry(
          today, 0, const PlanEntry(title: 'B', minutesOfDay: null));
      expect([for (final e in svc.entriesFor(today)) e.title], ['A', 'B', 'C']);
    });

    test('新增也归位：手选一个更早的时刻不会落地成倒挂', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: '下午', minutesOfDay: 14 * 60));
      await svc.addEntry(today, const PlanEntry(title: '早上', minutesOfDay: 9 * 60));
      expect([for (final e in svc.entriesFor(today)) e.title], ['早上', '下午']);
    });

    test('同一时刻保持原相对顺序', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: 'A', minutesOfDay: 540));
      await svc.addEntry(today, const PlanEntry(title: 'B', minutesOfDay: 540));
      await svc.addEntry(today, const PlanEntry(title: 'C', minutesOfDay: 480));

      expect([for (final e in svc.entriesFor(today)) e.title], ['C', 'A', 'B']);
    });

    test('只改标题不重排：拖动落下的顺序留着', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: 'A', minutesOfDay: 540));
      await svc.addEntry(today, const PlanEntry(title: 'B', minutesOfDay: 600));
      // 拖动走 setEntries：整份按落好的顺序写，不再排一次。
      await svc.setEntries(today, [...svc.entriesFor(today).reversed]);

      await svc.updateEntry(today, 0, const PlanEntry(title: 'B 改名', minutesOfDay: 600));
      expect([for (final e in svc.entriesFor(today)) e.title], ['B 改名', 'A']);
    });

    test('两个引擎各持一个服务：改自己那天不会抹掉别人刚写的另一天', () async {
      final repo = MemoryPlanRepository();
      final a = PlanService(repo: repo);
      final b = PlanService(repo: repo);
      await a.load();
      await b.load();

      await a.addEntry(today, const PlanEntry(title: '今天', minutesOfDay: 600));
      // b 的内存态里还没有今天，但命令先读盘，所以不会把它写掉。
      await b.addEntry(yesterday, const PlanEntry(title: '昨天', minutesOfDay: 600));

      final disk = await repo.loadAll();
      expect(disk, hasLength(2));
      expect([for (final d in disk) planDayKey(d.day)], ['2026-10-22', '2026-10-21']);
      expect(disk.first.entries.single.title, '今天');
    });

    test('落盘不换对象：拖出来的顺序换了位，条目还是原来那几个', () async {
      final svc = PlanService(repo: MemoryPlanRepository());
      await svc.load();
      await svc.addEntry(today, const PlanEntry(title: '晨会', minutesOfDay: 8 * 60));
      await svc.addEntry(today, const PlanEntry(title: '评审', minutesOfDay: 9 * 60));

      final before = svc.entriesFor(today);
      await svc.setEntries(today, [before[1], before[0]]);
      final after = svc.entriesFor(today);
      // 列表按对象身份做行 key：每落一次盘就造一批新对象，拖动松手那一格会被
      // 当成新行重建（落下动画白做）。
      expect(identical(after.first, before[1]), isTrue);
      expect(identical(after.last, before[0]), isTrue);

      // 带空白的标题仍然被规整——那种才需要造新对象。
      await svc.setEntries(today, [
        const PlanEntry(title: '  评审  ', minutesOfDay: 9 * 60),
      ]);
      expect(svc.entriesFor(today).single.title, '评审');
    });
  });

  group('拖动落位：时刻对齐到邻居', () {
    PlanEntry e(String title, int? minutes) =>
        PlanEntry(title: title, minutesOfDay: minutes);
    List<String> times(List<PlanEntry> list) =>
        [for (final x in list) x.timeText ?? '—'];

    test('取上方那一条的时刻', () {
      // 原序 14:30 / 16:16 / 18:30，把 18:30 拖到 14:30 与 16:16 之间。
      final next = [e('A', 870), e('C', 1110), e('B', 976)];
      final out = alignPlanEntryTime(next, 1);
      expect(times(out), ['14:30', '14:30', '16:16']);
      expect([for (final x in out) x.title], ['A', 'C', 'B']);
    });

    test('拖到最前：上方没有，取下一条的时刻', () {
      final out = alignPlanEntryTime([e('B', 976), e('A', 870)], 0);
      expect(times(out), ['14:30', '14:30']);
    });

    test('上方是"没有时刻"的条目：跳过它继续往上找', () {
      final next = [e('A', 870), e('X', null), e('C', 1110)];
      expect(times(alignPlanEntryTime(next, 2)), ['14:30', '—', '14:30']);
    });

    test('整条轴都没有时刻：原样不动', () {
      final next = [e('A', null), e('B', null)];
      expect(identical(alignPlanEntryTime(next, 1), next), isTrue);
    });

    test('已经同刻：不造新对象（列表按身份做行 key）', () {
      final next = [e('A', 870), e('B', 870)];
      expect(identical(alignPlanEntryTime(next, 1), next), isTrue);
    });

    test('下标越界：原样返回', () {
      final next = [e('A', 870)];
      expect(identical(alignPlanEntryTime(next, 3), next), isTrue);
    });
  });
}
