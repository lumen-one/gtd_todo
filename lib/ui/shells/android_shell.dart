import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/calendar_dialog.dart';
import '../panel_pages.dart';
import '../panels/completed_panel.dart';
import '../panels/notes_panel.dart';
import '../panels/pool_panel.dart';
import '../panels/side_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/today_panel.dart';
import '../theme.dart';
import '../widgets/panel_dock.dart';
import '../widgets/reminder_listener.dart';
import '../widgets/task_selection.dart';

/// 安卓壳（§5.1 shells / ui-interaction.md §6）：
/// - App 主体 = 设置页（"App 主体几乎不开"）；
/// - 四页清单只在**抽屉**里（左侧滑或 AppBar 菜单呼出），页序见 `ui/panel_pages.dart`；
/// - **侧边栏本体只有系统级悬浮面板那一套**：贴屏把手恒开（`docs/panels/handle.md`），
///   App 内不再有自己的一份把手与滑出面板。系统把手在应用前台时收起，这段在应用里的
///   时间由抽屉接上——每个场景恰好一个入口。
class AndroidShell extends StatefulWidget {
  final AppController controller;

  const AndroidShell({super.key, required this.controller});

  @override
  State<AndroidShell> createState() => _AndroidShellState();
}

class _AndroidShellState extends State<AndroidShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 抽屉的起手页（页序号）：平时 = 设置的默认页（§9 第 12 条），点通知定位 =
  /// 定位目标页。
  int _drawerPage = 0;

  /// 每开一次抽屉 +1：抽屉子树靠它换 key 重建，**每次开都从起手页开始**。
  /// 不给 key 的话 `DefaultTabController` 的 state 会跨开合留着，第二次开还停在
  /// 上次翻到的那页，设置里的默认页就形同虚设。
  int _drawerSeq = 0;

  // 装配点/原生把手的请求（AppController 计数器）：打开抽屉、关抽屉。
  int _seenOpenRequest = 0;
  int _seenCloseRequest = 0;

  @override
  void initState() {
    super.initState();
    _drawerPage = defaultPanelPageIndex(widget.controller.settings);
    widget.controller.addListener(_onChange);
    _seenOpenRequest = widget.controller.panelOpenRequest;
    _seenCloseRequest = widget.controller.panelCloseRequest;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  /// 控制器把它当"事件总线"用：原生把手的降级打开 / 点通知定位 → 开抽屉；
  /// 『编辑规则』 → 关抽屉并留在设置页；通知按钮 → toast 反馈。
  void _onChange() {
    if (!mounted) return;
    final c = widget.controller;
    setState(() {});
    if (c.panelCloseRequest != _seenCloseRequest) {
      _seenCloseRequest = c.panelCloseRequest;
      _closeDrawer();
    }
    if (c.panelOpenRequest != _seenOpenRequest) {
      _seenOpenRequest = c.panelOpenRequest;
      // 定位请求是一次性的；`focusedTaskId` 会一直留着给高亮，拿它判"这次是定位"
      // 会让此后每次打开都跳回上次那条。
      final locate = c.consumeLocateRequest();
      _openDrawer(locate: locate);
    }
    final notice = c.consumeNotice();
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      });
    }
  }

  /// 打开抽屉。落哪一页：定位进来落目标页，其余落设置里的默认页（§9 第 12 条）
  /// ——点通知定位时按定位目标走，不被默认页盖掉。
  void _openDrawer({bool locate = false}) {
    final target = locate
        ? widget.controller.focusPage
        : defaultPanelPageIndex(widget.controller.settings);
    setState(() {
      _drawerPage = target;
      _drawerSeq++;
    });
    // 抽屉是 Scaffold 的：等这一帧把新的起手页装进树里再开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scaffoldKey.currentState?.openDrawer();
    });
  }

  void _closeDrawer() {
    // 覆盖页开着就先收它（§6.9 / §6.11）：返回键不该一步把面板从覆盖页里抽走
    widget.controller.closeMainline();
    widget.controller.closePlan();
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ReminderListener(
      controller: controller,
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          title: const Text('GTD Todo'),
          leading: IconButton(
            tooltip: '菜单',
            icon: const Icon(Icons.menu),
            onPressed: _openDrawer,
          ),
        ),
        drawer: _DrawerFallback(
          key: ValueKey(_drawerSeq),
          controller: controller,
          initialPage: _drawerPage,
        ),
        body: SettingsPanel(controller: controller),
        // 右下角不摆『侧边栏』按钮（§6.0）：抽屉与把手已经各管一个场景。
      ),
    );
  }
}

/// App 内的四页面板（§6 / §11 的兜底形态）：左侧滑或 AppBar 菜单呼出。
///
/// 有状态是因为多选（§10#23）：抽屉与悬浮面板是同一份功能的两条入口，
/// 选择模式也得有一份自己的临时态（保留到抽屉关掉为止——每次开都是新的一份）。
class _DrawerFallback extends StatefulWidget {
  final AppController controller;

  /// 起手页（页序号）：平时 = 设置的默认页，点通知定位 = 定位目标页。
  final int initialPage;

  const _DrawerFallback({
    super.key,
    required this.controller,
    required this.initialPage,
  });

  @override
  State<_DrawerFallback> createState() => _DrawerFallbackState();
}

class _DrawerFallbackState extends State<_DrawerFallback> {
  final TaskSelection _selection = TaskSelection();

  AppController get controller => widget.controller;

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 四页与悬浮面板同序同源（`ui/panel_pages.dart`），起手页由宿主给。
    final pages = PanelPage.values;
    return Drawer(
      // 与悬浮面板同一个宽度设置（`panel_width`，安装默认 240）
      width: panelWidthFor(
          controller.settings, MediaQuery.of(context).size.width),
      // 底色跟面板本体一个值（§8）：Drawer 默认吃 M3 的 `surfaceContainerLow`
      // （被种子色染过一层），而页面内容是纸白——SafeArea 露出的状态栏那条 +
      // `appBar` 槽里的页名条就压在抽屉底色上，与下面的内容区肉眼有色差
      // （真机截图确认：上 255,242,236 / 下 250,247,242）。
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      // 系统栏留白：抽屉里装的是**它自己的 Scaffold**，而 `appBar` 槽里塞的
      // 是裸 `TabBar`——那不是 AppBar，没人替它避让状态栏。之前不包这一层，
      // 四个页名直接压在状态栏的时钟与信号栏底下（OPPO 真机反馈：展开页与
      // 手机顶部栏重叠），页内容也跟着抬到最顶、右下角双钮压在导航栏上。
      child: SafeArea(
        child: DefaultTabController(
          length: pages.length,
          initialIndex: widget.initialPage.clamp(0, pages.length - 1),
          child: Scaffold(
            appBar: TabBar(
              // 四页都是三到四个字，抽屉最窄可到 240dp：不滚动会让标签互相挤。
              isScrollable: true,
              // 左对齐页内容（§8）：可滚动标签的默认对齐是 `startOffset`——
              // 那 52dp 是给 AppBar 左侧头像留位的，抽屉里没有头像，留着就是
              // 页名条左边一截空当（比下面的日期行缩进 50dp 还多）。
              tabAlignment: TabAlignment.start,
              // 18dp = 四页页内容的左右留白：页名左缘与日期行/标题左缘对齐。
              labelPadding: const EdgeInsets.symmetric(horizontal: 18),
              tabs: [for (final page in pages) Tab(text: page.label)],
              labelColor: AppColors.accent,
            ),
            body: TabBarView(
              children: [
                for (final page in pages)
                  _withActions(context, page, switch (page) {
                    PanelPage.notes => NotesPanel(controller: controller),
                    PanelPage.today =>
                      TodayPanel(controller: controller, selection: _selection),
                    PanelPage.pool =>
                      PoolPanel(controller: controller, selection: _selection),
                    PanelPage.completed => CompletedPanel(
                        controller: controller, selection: _selection),
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一页 = 页内容 + 右下角双钮（§6.1）：抽屉里也照摆一份，规则与面板一致
  /// （灵感页不摆、列表上滑藏钮）。
  ///
  /// Hero 标签带上页名——四页同时在 widget 树里（TabBarView 会保留相邻页），
  /// 同一棵树里不能有两个同标签的 Hero。
  Widget _withActions(BuildContext context, PanelPage page, Widget body) =>
      _DockPage(
        controller: controller,
        selection: _selection,
        onOpenCalendar: () => showCalendarDialog(context, controller),
        heroTagPrefix: 'drawer-${page.name}',
        withDock: page != PanelPage.notes,
        child: body,
      );
}

/// 抽屉里"一页 + 双钮"的组合：每页自己一份藏钮开关（TabBarView 四页同时活着，
/// 各自的滚动不能互相牵连）。
class _DockPage extends StatefulWidget {
  final AppController controller;
  final TaskSelection selection;
  final VoidCallback onOpenCalendar;
  final String heroTagPrefix;

  /// false = 这一页不摆双钮（灵感页）。
  final bool withDock;

  final Widget child;

  const _DockPage({
    required this.controller,
    required this.selection,
    required this.onOpenCalendar,
    required this.heroTagPrefix,
    required this.withDock,
    required this.child,
  });

  @override
  State<_DockPage> createState() => _DockPageState();
}

class _DockPageState extends State<_DockPage> {
  final ValueNotifier<bool> _dockHidden = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _dockHidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        DockScrollListener(hidden: _dockHidden, child: widget.child),
        if (widget.withDock)
          PanelDock(
            controller: widget.controller,
            selection: widget.selection,
            onOpenCalendar: widget.onOpenCalendar,
            heroTagPrefix: widget.heroTagPrefix,
            hidden: _dockHidden,
          ),
      ]);
}
