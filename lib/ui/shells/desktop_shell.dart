import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/calendar_dialog.dart';
import '../panel_pages.dart';
import '../panels/settings_panel.dart';
import '../panels/side_panel.dart';
import '../widgets/reminder_listener.dart';

/// 桌面壳（Windows，ui-interaction.md §6.10 / architecture.md §5.1）。
///
/// **同一套面板，换个摆法**：桌面窗口一直开着，"展开 / 收起面板"这件事本身不
/// 存在——[SidePanel] 从贴屏滑入的浮层改成**左侧常驻一栏**，右边一整栏是同一份
/// [SettingsPanel]（安卓的"App 主体 = 设置页"在桌面上就是右边这片）。
///
/// 所以这里没有：贴屏把手、遮罩、滑入/滑出动画、尺寸拖拽、抽屉兜底、首次引导、
/// 返回键那两步收。四页顺序、面板头第二行的主线、主线覆盖页、右下角双钮都在
/// [SidePanel] 里，两个平台共用（页序仍只由 `PanelPage` 派生）。
///
/// **提醒回流必须挂** [ReminderListener]：桌面的"托盘"就是应用窗口
/// （architecture.md §4.2），`StreamNotificationPort` 只是把事件推给控制器，
/// 不挂这一层就没人渲染——旧桌面壳漏了这一步，到点什么都不弹（v1.32 修掉）。
class DesktopShell extends StatefulWidget {
  final AppController controller;

  const DesktopShell({super.key, required this.controller});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

/// 窄于这个宽度就退回单栏（§6.10）：两栏在 700 出头时左栏只剩 220、
/// 右栏挤成一条，不如让面板占满，设置页从标题栏进。
const double _kNarrowWidth = 720;

/// 桌面左栏宽度的上下限（§6.10）：不跟窗口线性缩放——0.8 × 窗口宽在 1600 的
/// 窗口上就是一块 1280 的面板；32% 起步、夹在 [240, 420] 里。
const double _kMinPanelWidth = 240;
const double _kMaxPanelWidth = 420;

/// 当前窗口该给侧边栏多宽（逻辑像素）。
double desktopPanelWidth(double screenWidth) =>
    (screenWidth * 0.32).clamp(_kMinPanelWidth, _kMaxPanelWidth);

class _DesktopShellState extends State<DesktopShell> {
  /// 面板自己的页控制器：起始页仍是设置项 `default_page`（§9 第 12 条）——
  /// 桌面上不"展开落页"，但换个窗口重开时落在哪一页该与手机一致。
  late final PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(
      initialPage: defaultPanelPageIndex(widget.controller.settings),
    );
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _openSettingsPage() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: SettingsPanel(controller: widget.controller),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final size = MediaQuery.of(context).size;
    final narrow = size.width < _kNarrowWidth;

    final panel = SidePanel(
      controller: controller,
      pageCtrl: _pageCtrl,
      onOpenCalendar: () => showCalendarDialog(context, controller),
    );

    return ReminderListener(
      controller: controller,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('动态任务调度 Todo'),
          actions: [
            // 单栏形态下设置页没地方摆，退回"标题栏进独立页"（§6.10）；
            // 两栏形态下设置页就在右边，标题栏不必重复一颗（旧桌面壳的
            // 设置 / 工作时间规则两颗按钮都撤了）。
            if (narrow)
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettingsPage,
              ),
            IconButton(
              tooltip: '重新调度',
              icon: const Icon(Icons.refresh),
              onPressed: controller.refresh,
            ),
          ],
        ),
        body: narrow
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  // 单栏也不铺满整个宽窗口：清单行太长反而难读。
                  child: SizedBox(
                    width: (size.width - 16).clamp(240.0, 520.0),
                    child: panel,
                  ),
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
                    child: SizedBox(
                      width: desktopPanelWidth(size.width),
                      child: panel,
                    ),
                  ),
                  const VerticalDivider(width: 1, thickness: 0.6),
                  Expanded(child: SettingsPanel(controller: controller)),
                ],
              ),
      ),
    );
  }
}
