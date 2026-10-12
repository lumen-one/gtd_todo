import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'application/routine_service.dart';
import 'application/task_service.dart';
import 'domain/time_context.dart';
import 'platform/app_adapters.dart';
import 'repository/markdown_routine_repository.dart';
import 'repository/markdown_task_repository.dart';
import 'scheduler/slack_priority_scheduler.dart';
import 'ui/app_controller.dart';
import 'ui/dialogs/calendar_dialog.dart';
import 'ui/panels/side_panel.dart';
import 'ui/theme.dart';

/// 系统级悬浮面板的入口（§6.0 / ui-interaction.md §0）。
///
/// 这条链路跑在**原生前台服务的第二个 Flutter 引擎**里（原生侧
/// `OverlayHandleService`，DartEntrypoint = `overlayMain`），窗口是全屏透明的
/// overlay：把手拖出 → 面板浮在**当前 App 上方**就地展开，日常操作不必离开
/// 当前 App；只有"编辑规则 / 打开设置"才把用户带进应用本体。
///
/// 与主引擎的分工（重要）：
/// - **同一份任务目录、同一个 domain/application 核心**，只是第二个实例；
///   命令仍然全部走 TaskService（写路径唯一，C1）；
/// - 交付类插座（闹钟/通知）**不在这里装配**：全局单闹钟归主引擎那一份，
///   两个引擎各挂一个闹钟会互相覆盖；
/// - 数据同步靠文件：两边都 watch 任务目录，谁改了文件另一边就重载
///   （与"Obsidian 手改回流"是同一条通路）。
///
/// panels 本体与应用内壳**共用同一份**（ui/panels/side_panel.dart），
/// 宿主只负责容器：应用内 = 滑入面板，这里 = 悬浮窗口。
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OverlayRoot());
}

/// 原生 ↔ 悬浮面板的事件/命令通道（窗口显隐、收起、进应用）。
class OverlayBridge {
  static const MethodChannel channel = MethodChannel('gtd/overlay');

  final StreamController<OverlayWindowState> _states =
      StreamController<OverlayWindowState>.broadcast();

  /// 原生侧的面板状态（展开/收起 + 把手停靠侧）。
  Stream<OverlayWindowState> get states => _states.stream;

  OverlayBridge() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'state' && call.arguments is Map) {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _states.add(OverlayWindowState(
          expanded: m['expanded'] == true,
          dockedRight: m['dockedRight'] != false,
        ));
      }
      return null;
    });
  }

  /// 告知原生"面板侧已就绪"（之后原生才会投递状态）。
  Future<void> notifyReady() async {
    await _invoke('notifyReady');
  }

  /// 收起悬浮面板（窗口隐藏，把手重新出现）。
  Future<void> collapse() async {
    await _invoke('collapse');
  }

  /// **进应用**：打开应用本体（设置页），可选定位到某条周期规则。
  Future<void> openApp({String target = 'settings', String? routineId}) async {
    await _invoke('openApp', {'target': target, 'routineId': routineId});
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await channel.invokeMethod<Object?>(method, args);
    } catch (_) {
      // 原生不可用（桌面/老版本）：面板退化为"进应用"，不崩。
    }
  }
}

class OverlayWindowState {
  final bool expanded;
  final bool dockedRight;

  const OverlayWindowState({required this.expanded, required this.dockedRight});
}

/// 悬浮面板需要的核心（第二个引擎自己的实例）。
class _OverlayCore {
  final AppController controller;
  final StreamSubscription<dynamic>? watchSub;

  const _OverlayCore(this.controller, this.watchSub);

  void dispose() {
    watchSub?.cancel();
    controller.dispose();
  }
}

/// 装配悬浮面板的核心：与 main.dart 同一套目录/仓储/服务（只是不装交付插座）。
Future<_OverlayCore> _assembleOverlayCore() async {
  final resolved = await resolveTaskDir();
  final repo = MarkdownTaskRepository(resolved.taskDir);
  final service = TaskService(
    repo: repo,
    scheduler: const SlackPriorityScheduler(), // 与主引擎同一默认算法（v1.9）
    workRule: WorkTimeRule.standard,
  );
  await service.refreshSchedule();

  final routines = RoutineService(
    repo: MarkdownRoutineRepository(resolved.taskDir),
    tasks: service,
  );
  await routines.load();

  final controller = AppController(
    service: service,
    taskDir: resolved.taskDir,
    routineService: routines,
    settingsPort: FileSettingsPort(resolved.taskDir),
    bootstrapPort: resolved.bootstrap,
    // 提醒模式也要跟上（面板不装交付插座，但清单的"会不会响"口径要与主引擎一致）。
    onReminderModeChanged: (mode) => service.updateReminderMode(mode),
  );
  controller.notesReader =
      FileNotesReaderPort(() => controller.settings.notesPath);
  await controller.bootstrap(); // 读设置 + 当天实例 + 定期挑（幂等）

  // Obsidian / 主引擎改了文件 → 面板即时刷新；顺带重读设置（主题、笔记路径
  // 这些在设置页改完应当立刻反映到悬浮面板上）。
  final sub = repo.watch()?.listen((_) => controller.bootstrap());
  return _OverlayCore(controller, sub);
}

class _OverlayRoot extends StatefulWidget {
  const _OverlayRoot();

  @override
  State<_OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<_OverlayRoot> {
  final OverlayBridge _bridge = OverlayBridge();
  _OverlayCore? _core;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _assemble();
  }

  Future<void> _assemble() async {
    try {
      final core = await _assembleOverlayCore();
      if (!mounted) {
        core.dispose();
        return;
      }
      wireOverlaySettingsNavigation(core.controller, _bridge);
      setState(() => _core = core);
      await _bridge.notifyReady();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _core?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = _core;
    final preset = core?.controller.themePreset ?? AppThemePreset.orange;
    AppColors.applyPreset(preset);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 窗口是透明的：面板下面是用户当前所在的 App。
      color: Colors.transparent,
      theme: buildAppTheme(Brightness.light, preset: preset),
      home: _error != null
          ? _OverlayErrorCard(
              message: '$_error',
              onOpenApp: () => _bridge.openApp(target: 'settings'),
              onClose: () => _bridge.collapse(),
            )
          : core == null
              ? const SizedBox.shrink()
              : OverlayPanelShell(controller: core.controller, bridge: _bridge),
    );
  }
}

/// 悬浮面板装配失败时也要给用户一条出路（而不是一片空白）。
class _OverlayErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onOpenApp;
  final VoidCallback onClose;

  const _OverlayErrorCard({
    required this.message,
    required this.onOpenApp,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: AppColors.overdue),
                const SizedBox(height: 8),
                const Text('悬浮面板没能加载任务目录'),
                const SizedBox(height: 4),
                Text(message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: onClose, child: const Text('收起')),
                    FilledButton(
                        onPressed: onOpenApp, child: const Text('打开应用')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮面板的宿主：展开 = 画遮罩 + 面板；收起 = 什么都不画（只剩原生把手）。
class OverlayPanelShell extends StatefulWidget {
  final AppController controller;
  final OverlayBridge bridge;

  const OverlayPanelShell({
    super.key,
    required this.controller,
    required this.bridge,
  });

  @override
  State<OverlayPanelShell> createState() => _OverlayPanelShellState();
}

class _OverlayPanelShellState extends State<OverlayPanelShell> {
  final PageController _pageCtrl = PageController();
  StreamSubscription<OverlayWindowState>? _stateSub;

  bool _expanded = true; // 原生 notifyReady 后会立刻纠正
  bool _dockedRight = true;
  bool _privacy = false;

  static const double _pageFlingVelocity = 1200;
  static const double _pageDragRatio = 0.38;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _stateSub = widget.bridge.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _expanded = s.expanded;
        _dockedRight = s.dockedRight;
        if (!s.expanded) _privacy = false;
      });
      if (s.expanded) _maybeOnboard();
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _c.removeListener(_onChange);
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _collapse() async {
    setState(() {
      _expanded = false;
      _privacy = false;
    });
    await widget.bridge.collapse();
  }

  void _maybeOnboard() {
    if (_c.settings.guideSeen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _c.settings.guideSeen) return;
      await showDialog<void>(
          context: context, builder: (_) => const PanelOnboardDialog());
      await _c.updateSettings(_c.settings.copyWith(guideSeen: true));
    });
  }

  Future<void> _privacySubmit(String text) async {
    final title = text.trim();
    if (title.isEmpty) return;
    await _c.createTask(title: title);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已静默入池'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  void _onPageDragEnd(DragEndDetails d, double accum, double height) {
    final v = d.velocity.pixelsPerSecond.dy;
    if (v < -_pageFlingVelocity || accum < -height * _pageDragRatio) {
      _pageBy(1);
    } else if (v > _pageFlingVelocity || accum > height * _pageDragRatio) {
      _pageBy(-1);
    }
  }

  void _pageBy(int delta) {
    if (!_pageCtrl.hasClients) return;
    final page = (_pageCtrl.page ?? 0).round().clamp(0, 2);
    final target = page + delta;
    if (target < 0 || target > 2) return;
    _pageCtrl.animateToPage(target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    if (!_expanded) return const SizedBox.shrink();
    final height = MediaQuery.of(context).size.height - 40;
    // 透明 Scaffold：SnackBar / 对话框有宿主，背景仍是"下面的 App"。
    // PopScope：面板是全屏窗口，系统返回键应该"收起面板"而不是穿透到下面的 App。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _collapse();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: FloatingPanel(
          controller: _c,
          pageCtrl: _pageCtrl,
          onPageDragEnd: (d, accum) => _onPageDragEnd(d, accum, height),
          onCollapse: _collapse,
          onPrivacy: () => setState(() => _privacy = true),
          privacy: _privacy,
          onPrivacySubmit: _privacySubmit,
          onOpenCalendar: () => showCalendarDialog(context, _c),
          onOpenSettings: () => widget.bridge.openApp(target: 'settings'),
          dockLeft: !_dockedRight,
        ),
      ),
    );
  }
}

/// 悬浮面板里点『编辑规则』时：把用户带进应用的设置页并定位该规则
/// （悬浮窗没有设置页，装配点在 [_OverlayRoot] 装配后接上这条线）。
void wireOverlaySettingsNavigation(
    AppController controller, OverlayBridge bridge) {
  controller.onOpenSettingsRequested = (routineId) async {
    await bridge.openApp(target: 'settings', routineId: routineId);
    await bridge.collapse();
  };
}
