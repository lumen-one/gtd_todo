import 'dart:async';

import 'package:flutter/material.dart';

import 'application/mainline_service.dart';
import 'application/plan_service.dart';
import 'application/routine_service.dart';
import 'application/task_service.dart';
import 'domain/time_context.dart';
import 'platform/app_adapters.dart';
import 'repository/markdown_mainline_repository.dart';
import 'repository/markdown_plan_repository.dart';
import 'repository/markdown_routine_repository.dart';
import 'repository/markdown_task_repository.dart';
import 'scheduler/slack_priority_scheduler.dart';
import 'ui/app_controller.dart';
import 'ui/overlay/overlay_bridge.dart';
import 'ui/overlay/overlay_panel_shell.dart';
import 'ui/theme.dart';

// UI 类已迁入 ui/overlay/；这里 re-export 保持原有 import 面不变
// （main.dart 的 `export 'overlay_main.dart'` 与 overlay 链路测试都依赖它）。
export 'ui/overlay/overlay_bridge.dart';
export 'ui/overlay/overlay_panel_shell.dart';

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
    // 工时日历同样是设置项：先按默认值起来，bootstrap 读完设置后换掉（v1.26）。
    workRule: WorkTimeRule.standard,
  );
  await service.refreshSchedule();

  final routines = RoutineService(
    repo: MarkdownRoutineRepository(resolved.taskDir),
    tasks: service,
  );
  await routines.load();

  // 主线（§6.9）：悬浮面板也能看行为链、圈记录、勾步骤——与主引擎同一份
  // `主线.md`，各持一个服务实例（写路径仍是"读整份 → 改一条 → 整份写回"）。
  final mainlines = MainlineService(
    repo: MarkdownMainlineRepository(resolved.taskDir),
  );
  await mainlines.load();

  // 今日编排（§6.11）：同一份 `编排.md`，各持一个服务实例（写路径仍是
  // "读整份 → 改一天 → 整份写回"，两个引擎同时改按后写者胜）。
  final plans = PlanService(
    repo: MarkdownPlanRepository(resolved.taskDir),
  );
  await plans.load();

  final controller = AppController(
    service: service,
    taskDir: resolved.taskDir,
    routineService: routines,
    mainlineService: mainlines,
    planService: plans,
    settingsPort: FileSettingsPort(resolved.taskDir),
    bootstrapPort: resolved.bootstrap,
    // 调度模式也要跟上（面板不装交付插座，但清单的"排什么顺序、会不会响"口径
    // 两边必须一致——决议 43）。
    onScheduleModeChanged: (mode) => service.updateScheduleMode(mode),
    // 工时日历同理：面板算的"今天该看哪几件"必须和主引擎用同一份分母。
    onWorkRuleChanged: (rule) => service.updateWorkRule(rule),
  );
  controller.notesPort =
      FileNotesPort(() => controller.settings.notesPath);
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
    // ListenableBuilder 监听控制器：设置里改主题预设 / 明暗（主引擎写
    // settings.json → 文件监听触发本引擎 bootstrap）要**立刻**反映到悬浮
    // 面板上。原先 MaterialApp 不监听——预设切换要等引擎重启才生效，
    // 与 _assembleOverlayCore 里"主题改完应当立刻反映"的注释不符。
    // core 还没装配好（_core == null）时没什么可听的，直接建。
    if (core == null) return _buildApp(null);
    return ListenableBuilder(
      listenable: core.controller,
      builder: (context, _) => _buildApp(core),
    );
  }

  Widget _buildApp(_OverlayCore? core) {
    final preset = core?.controller.themePreset ?? AppThemePreset.orange;
    final mode = core?.controller.themeMode ?? ThemeMode.system;
    AppColors.applyPreset(preset);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 窗口是透明的：面板下面是用户当前所在的 App。
      color: Colors.transparent,
      theme: buildAppTheme(Brightness.light, preset: preset),
      darkTheme: buildAppTheme(Brightness.dark, preset: preset),
      themeMode: mode,
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
