import '../application/settings.dart';

/// 侧边栏的四个页面（ui-interaction.md §6.0）。
///
/// **页序只在这里定义**：枚举的声明顺序就是横滑顺序，`index` 就是页序号。
/// 页名、页序圆点、PageView 顺序、展开后的默认页、通知定位的页码，全部从这张
/// 表派生——页序再改一次，只动这几行的先后，别去改散落各处的数字（v1.24 就是
/// 为了这一条把 `第 N 页` 的写法清掉的）。
enum PanelPage {
  notes('疑问笔记'),
  today('今日清单'),
  pool('任务池'),
  completed('已完成');

  /// 面板头显示的页名（也是圆点与默认页设置里的标签）。
  final String label;

  const PanelPage(this.label);
}

/// 页的稳定 id → 页：`settings.json` 的 `default_page` 存的就是 [PanelPage.name]。
///
/// 缺键、手改坏了（写了不认识的 id）都回落到**今日清单**。回落放在 UI 层是
/// 有意的：application 只存字符串，不认识"页"是什么（同 themePreset / themeMode）。
PanelPage panelPageFromId(String? id) {
  for (final page in PanelPage.values) {
    if (page.name == id) return page;
  }
  return PanelPage.today;
}

/// 展开后默认停在哪一页（设置项，§9 第 12 条）。
int defaultPanelPageIndex(AppSettings settings) =>
    panelPageFromId(settings.defaultPage).index;
