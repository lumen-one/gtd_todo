import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/ui/panel_pages.dart';

/// 页序表（ui-interaction.md §6.0 / §9 第 12 条）：页名、页序、默认页与页码
/// 都从 [PanelPage] 派生，这里钉住"派生关系"本身。
void main() {
  group('页序表', () {
    test('页序：疑问笔记 → 今日清单 → 任务池 → 已完成', () {
      expect(PanelPage.values.map((p) => p.label).toList(),
          ['疑问笔记', '今日清单', '任务池', '已完成']);
    });

    test('页 id 与页一一对应，往返不丢', () {
      for (final page in PanelPage.values) {
        expect(panelPageFromId(page.name), page);
      }
    });

    test('缺键 / 手改坏了都回落今日清单', () {
      expect(panelPageFromId(null), PanelPage.today);
      expect(panelPageFromId(''), PanelPage.today);
      expect(panelPageFromId('Yesterday'), PanelPage.today);
    });

    test('default_page：默认今日清单，落盘往返不丢，老文件缺键回落', () {
      expect(AppSettings.defaults.defaultPage, 'today');
      expect(AppSettings.fromJson(const {}).defaultPage, 'today');
      expect(defaultPanelPageIndex(AppSettings.defaults),
          PanelPage.today.index);

      final s = AppSettings.defaults.copyWith(defaultPage: 'completed');
      final back = decodeSettings(encodeSettings(s));
      expect(back.defaultPage, 'completed');
      expect(defaultPanelPageIndex(back), PanelPage.completed.index);
    });
  });
}
