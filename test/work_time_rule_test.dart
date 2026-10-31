import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/domain/time_context.dart';

void main() {
  // 2026-10-07 是周三。规则：周一至周五 09:00-12:00、13:30-18:00。
  const rule = WorkTimeRule.standard;

  group('workMinutesBetween（跳过休息时间）', () {
    test('同一天，跨午后窗口', () {
      final a = DateTime(2026, 10, 7, 16, 0); // 周三
      final b = DateTime(2026, 10, 7, 18, 0);
      expect(rule.workMinutesBetween(a, b), 120);
    });

    test('午休时间不算工时', () {
      final a = DateTime(2026, 10, 7, 12, 0);
      final b = DateTime(2026, 10, 7, 13, 30);
      expect(rule.workMinutesBetween(a, b), 0);
    });

    test('跨周末：周五16:00 → 周一10:00 = 3 小时', () {
      final a = DateTime(2026, 10, 9, 16, 0); // 周五
      final b = DateTime(2026, 10, 12, 10, 0); // 周一
      expect(rule.workMinutesBetween(a, b), 180); // 周五2h + 周一1h
    });
  });

  group('addWorkMinutes（结果永远落在工作窗内）', () {
    test('当天窗口不够，顺延到次日早晨', () {
      final t = DateTime(2026, 10, 7, 17, 45); // 周三，距下班15分钟
      expect(rule.addWorkMinutes(t, 30), DateTime(2026, 10, 8, 9, 15));
    });

    test('跨周末顺延', () {
      final t = DateTime(2026, 10, 9, 17, 45); // 周五
      expect(rule.addWorkMinutes(t, 30), DateTime(2026, 10, 12, 9, 15));
    });

    test('恰好用尽窗口时返回窗口结束时刻', () {
      final t = DateTime(2026, 10, 7, 16, 0);
      expect(rule.addWorkMinutes(t, 120), DateTime(2026, 10, 7, 18, 0));
    });

    test('从休息时间起算，自动跳到下一个工作窗', () {
      final t = DateTime(2026, 10, 10, 15, 0); // 周六
      expect(rule.addWorkMinutes(t, 60), DateTime(2026, 10, 12, 10, 0)); // 周一
    });
  });

  group('nextWindowStart（D8「到下个工作窗」语义）', () {
    test('上班前 → 当天第一个窗', () {
      final t = DateTime(2026, 10, 7, 8, 0); // 周三
      expect(rule.nextWindowStart(t), DateTime(2026, 10, 7, 9, 0));
    });

    test('窗内 → 跳过当前窗，取下一个窗', () {
      final t = DateTime(2026, 10, 7, 10, 0); // 上午窗内
      expect(rule.nextWindowStart(t), DateTime(2026, 10, 7, 13, 30));
    });

    test('窗界（午休起点）→ 午后窗', () {
      final t = DateTime(2026, 10, 7, 12, 0);
      expect(rule.nextWindowStart(t), DateTime(2026, 10, 7, 13, 30));
    });

    test('下班后 → 次日上班', () {
      final t = DateTime(2026, 10, 7, 18, 30); // 周三晚
      expect(rule.nextWindowStart(t), DateTime(2026, 10, 8, 9, 0));
    });

    test('周五傍晚 → 下周一（跳过周末）', () {
      final t = DateTime(2026, 10, 9, 17, 45); // 周五
      expect(rule.nextWindowStart(t), DateTime(2026, 10, 12, 9, 0));
    });
  });
}
