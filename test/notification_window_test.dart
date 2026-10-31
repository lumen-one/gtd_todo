import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/notification_window.dart';

void main() {
  group('NotificationWindowRule（D10 送达策略）', () {
    // 默认规则：9:00-21:00
    const rule = NotificationWindowRule.defaultRule;

    test('落在段内 → 原样送达', () {
      final t = DateTime(2026, 10, 7, 10, 5); // 周三 10:05
      expect(rule.resolveDelivery(t), t);
    });

    test('段前 → 顺延到段首', () {
      final t = DateTime(2026, 10, 7, 7, 30);
      expect(rule.resolveDelivery(t), DateTime(2026, 10, 7, 9, 0));
    });

    test('段后 → 顺延到次日段首', () {
      final t = DateTime(2026, 10, 7, 22, 0);
      expect(rule.resolveDelivery(t), DateTime(2026, 10, 8, 9, 0));
    });

    test('段末边界（端点互斥）→ 顺延', () {
      final t = DateTime(2026, 10, 7, 21, 0);
      expect(rule.resolveDelivery(t), DateTime(2026, 10, 8, 9, 0));
    });

    test('多段式：抠掉午睡/饭点', () {
      const multi = NotificationWindowRule([
        NotificationWindow(9 * 60, 12 * 60),
        NotificationWindow(14 * 60, 18 * 60),
      ]);
      final lunch = DateTime(2026, 10, 7, 12, 30);
      expect(multi.resolveDelivery(lunch), DateTime(2026, 10, 7, 14, 0));
      final evening = DateTime(2026, 10, 7, 18, 30);
      expect(multi.resolveDelivery(evening), DateTime(2026, 10, 8, 9, 0));
    });

    test('空段列表 = 不限制（原样送达）', () {
      const always = NotificationWindowRule.always;
      final night = DateTime(2026, 10, 7, 3, 0);
      expect(always.resolveDelivery(night), night);
    });
  });
}
