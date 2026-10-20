import 'dart:io';

import 'package:flutter/material.dart';

import 'application/event_log.dart';
import 'application/notification_window.dart';
import 'application/reminder_dispatcher.dart';
import 'application/routine_service.dart';
import 'application/task_service.dart';
import 'domain/time_context.dart';
import 'platform/android_adapters.dart';
import 'platform/app_adapters.dart';
import 'platform/desktop_adapters.dart';
import 'platform/lan_sync.dart';
import 'repository/markdown_routine_repository.dart';
import 'repository/markdown_task_repository.dart';
import 'scheduler/scheduler_registry.dart';
import 'scheduler/slack_priority_scheduler.dart';
import 'scheduler/slack_scheduler.dart';
import 'ui/app_controller.dart';
import 'ui/shells/android_shell.dart';
import 'ui/shells/desktop_shell.dart';
import 'ui/theme.dart';

/// **不要删这一行**：系统级悬浮面板跑在原生前台服务的第二个 Flutter 引擎里，
/// 入口是 `overlay_main.dart` 的 `overlayMain`（@pragma('vm:entry-point')）。
/// Dart 只编译从 main.dart **可达**的库——这里 export 一下，那个库才会进 kernel；
/// 否则原生侧解析 entrypoint 会直接失败：
/// `Dart_LookupLibrary: library 'package:gtd_todo/overlay_main.dart' not found`。
/// （原生两种解析形式都试：先显式库 URI，再纯函数名——export 让两者都成立。）
export 'overlay_main.dart';

/// 组装点（§5.3）：全项目唯一允许问"当前是什么平台"和挑选具体实现的地方。
/// 平台能力全部走插座：安卓 = 原生适配器（系统闹钟/通知/权限/目录选择），
/// 桌面 = Timer 闹钟 + 应用内弹窗回流。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final isAndroid = Platform.isAndroid;

  // 任务目录与引导配置：与悬浮窗引擎共用同一份解析（platform/app_adapters.dart）。
  final resolved = await resolveTaskDir();
  final taskDir = resolved.taskDir;
  final bootstrap = resolved.bootstrap;
  final repo = MarkdownTaskRepository(taskDir);

  // 局域网同步（§4.4）：纯 dart:io 实现，**只挂主引擎**（悬浮引擎没有写入
  // 职责，主机服务也只需一份）。"上次握手清单"放应用支持目录——任务目录
  // 本身是要同步的内容，不能把同步状态也同步过去。
  final sync = LanSyncAdapter(taskDir: taskDir, stateDir: resolved.supportDir);

  // 具体算法在这里选择（application 不 import 具体实现，§2）。
  // v1.9：**默认 = 时间裕度优先**（`priority = risk × importance`）；旧 `slack.v1`
  // 一起注册，供对照与影子运行用。
  final registry = SchedulerRegistry(
    schedulers: [const SlackPriorityScheduler(), const SlackScheduler()],
    defaultId: SlackPriorityScheduler.defaultId,
  );

  final service = TaskService(
    repo: repo,
    scheduler: registry.defaultScheduler,
    // 工时日历是设置项（v1.26），而设置是异步读的：先按默认值起来，
    // `controller.bootstrap()` 读完设置后经 onWorkRuleChanged 换成用户那份。
    workRule: WorkTimeRule.standard,
  );
  await service.refreshSchedule();

  // 周期任务规则（routines.md，决议 10）与当天实例生成（决议 5）。
  final routineService = RoutineService(
    repo: MarkdownRoutineRepository(taskDir),
    tasks: service,
  );
  await routineService.load();
  await routineService.generateTodayInstances();

  // 交付层（§4.2/§4.3）：安卓走自建原生适配器；桌面用前台适配器
  // （Timer 闹钟 + 应用内弹窗回流）。
  final bridge = isAndroid ? AndroidNativeBridge() : null;
  final alarm = bridge != null ? AndroidAlarmPort(bridge) : TimerAlarmPort();
  final notifications = bridge != null
      ? AndroidNotificationPort(bridge, lookup: service.byId)
      : StreamNotificationPort();
  final permissions =
      bridge != null ? AndroidPermissionPort(bridge) : GrantedPermissionPort();
  final folderPicker = bridge != null
      ? AndroidFolderPickerPort(permissions as AndroidPermissionPort)
      : DesktopFolderPickerPort();

  late final ReminderDispatcher dispatcher;
  final controller = AppController(
    service: service,
    taskDir: taskDir,
    routineService: routineService,
    settingsPort: FileSettingsPort(taskDir),
    bootstrapPort: bootstrap,
    permissions: permissions,
    folderPicker: folderPicker,
    onWindowsChanged: (rule) => dispatcher.updateWindows(rule),
    onAlarmModeChanged: (mode) => dispatcher.updateAlarmMode(mode),
    onScheduleModeChanged: (mode) => service.updateScheduleMode(mode),
    onWorkRuleChanged: (rule) => service.updateWorkRule(rule),
    notificationSurface: notifications.shown,
  );
  // 疑问笔记路径随设置实时生效（对该文件零写入）。
  controller.notesReader =
      FileNotesReaderPort(() => controller.settings.notesPath);
  // 局域网同步（§4.4）：本机名进 UDP 广播与冲突存档文件名。
  controller.attachSync(sync, Platform.localHostname);
  // 系统级贴屏把手（安卓原生；桌面无此能力）。
  controller.overlayHandleControl =
      bridge == null ? null : (enabled) => bridge.setOverlayHandle(enabled);
  controller.overlayHandleState =
      bridge == null ? null : () => bridge.isOverlayHandleEnabled();
  // 把手位置上锁（§6.0）：桌面无系统级把手 = null，设置项只落 settings.json。
  controller.handleLockControl =
      bridge == null ? null : (locked) => bridge.setHandleLocked(locked);
  // 把手热区宽度（§6.0 / §9 第 10 条）：同上，桌面 = null。
  controller.handleHotWidthControl =
      bridge == null ? null : (dp) => bridge.setHandleHotWidth(dp);

  dispatcher = ReminderDispatcher(
    service: service,
    alarm: alarm,
    notifications: notifications,
    windows: NotificationWindowRule.defaultRule,
  );

  // 原生事件回流：通知按钮（含应用被杀后补做）、点通知定位、把手拖出、
  // 悬浮面板的"进应用"请求。
  bridge?.events.listen((event) {
    switch (event['type']) {
      case 'action':
        controller.handleReminderAction(
          event['actionId'] as String? ?? '',
          event['taskId'] as String? ?? '',
        );
      case 'notificationTap':
        controller.locateTask(event['taskId'] as String? ?? '');
      case 'overlayHandleOpened':
        // 悬浮面板已就地展开（系统级面板）；这里的旧路径只在原生降级时才用。
        controller.requestOpenPanel();
      case 'openSettings':
        controller.openSettingsPage();
      case 'focusRoutine':
        final id = event['routineId'] as String? ?? '';
        if (id.isNotEmpty) controller.focusRoutineInSettings(id);
    }
  });

  await controller.bootstrap(); // 设置 + 周期实例 + 定期挑（system 订阅者语义）
  await dispatcher.start();
  await dispatcher.updateWindows(controller.notificationWindowRule);
  await dispatcher.updateAlarmMode(controller.settings.alarmMode);

  // 操作流水（决议 37）：`log` 数据单独一个文档 `.gtd/log.md`，append-only。
  // 走事件流订阅者（§3.3），不碰 TaskService。
  //
  // **只在主引擎挂**：悬浮面板跑在第二个引擎里，两个引擎都挂会把同一件事记两遍
  // （§4.2 的边界精神——交付/观察类构件归主引擎）。
  EventLog(
    port: FileEventLogPort(taskDir),
    tasks: () => service.tasks,
  ).attach(service.events);
  AppColors.applyPreset(controller.themePreset);
  await bridge?.markReady(); // 取回应用被杀期间入队的事件
  await controller.refreshOverlayHandleState(); // 设置页开关显示真实状态

  controller.startTicking(); // 前台兜底轮询（C2：只在到点后重锚 + 跨日生成）
  // Obsidian 手改实时回流（事件驱动重锚）；watch() 返回 null 时
  // （安卓 SAF 等）降级为"回到前台刷新"。
  repo.watch()?.listen((_) => controller.refresh());

  // 回到前台：刷新 + 补当天周期实例（附录 B 的降级路径）。
  final lifecycle = _LifecycleBridge(controller);
  WidgetsBinding.instance.addObserver(lifecycle);

  runApp(GtdTodoApp(controller: controller));
}

/// 生命周期桥：回到前台刷新（附录 B：SAF 无文件监听时的降级）+ 补当天实例。
class _LifecycleBridge with WidgetsBindingObserver {
  final AppController controller;

  _LifecycleBridge(this.controller);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.onResumed();
    }
  }
}

class GtdTodoApp extends StatelessWidget {
  final AppController controller;

  const GtdTodoApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    // 主题预设 / 明暗模式切换 → 整体重建（AppColors.accent 是进程内当前强调色；
    // themeMode 直接读设置，深色底与语义色都在 ThemeData 里）。
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preset = controller.themePreset;
        AppColors.applyPreset(preset);
        return MaterialApp(
          title: '动态任务调度 Todo',
          theme: buildAppTheme(Brightness.light, preset: preset),
          darkTheme: buildAppTheme(Brightness.dark, preset: preset),
          themeMode: controller.themeMode,
          home: Platform.isAndroid
              ? AndroidShell(controller: controller)
              : DesktopShell(controller: controller),
        );
      },
    );
  }
}
