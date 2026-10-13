import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../application/delivery.dart';
import '../application/notification_window.dart';
import '../application/notes_reader.dart';
import '../application/routine_service.dart';
import '../application/settings.dart';
import '../application/task_service.dart';
import '../application/today_view.dart';
import '../domain/event.dart';
import '../domain/reminder.dart';
import '../domain/routine.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import 'theme.dart';

String _dayMark(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// ui/ 层内的薄门面（§5.2）：
/// - 对上：UI 的唯一入口——UI 只看见这里的命令/查询，不透传 TaskService；
/// - 对下：转发命令给 TaskService / RoutineService；领域事件与通知回流
///   → notifyListeners。
/// 它不是架构层，是 ui/ 的内部构件；不出现在核心任何一层。
class AppController extends ChangeNotifier {
  final TaskService service;
  final RoutineService? routineService;
  final String taskDir;

  /// 疑问笔记只读端口（null = 未装配，UI 显示未接入）。
  /// 由装配点在构造后赋值（路径 getter 依赖本实例的设置）。
  NotesReaderPort? notesReader;

  /// 设置存取端口（null = 未装配，全部用默认值）。
  final SettingsPort? settingsPort;

  /// 引导配置端口（任务目录选择用；null = 不可改目录）。
  final BootstrapPort? bootstrapPort;

  /// 权限插座（设置页"权限引导"用；null = 未装配，桌面视为已授予）。
  final PermissionPort? permissions;

  /// 目录选择插座（null = 平台不支持）。
  final FolderPickerPort? folderPicker;

  /// 装配点注入的回调：通知时间段变化时同步给 ReminderDispatcher（§4.3）。
  final void Function(NotificationWindowRule rule)? onWindowsChanged;

  /// 装配点注入的回调：闹钟模式变化时同步给 ReminderDispatcher（决议 18）。
  final void Function(bool alarmMode)? onAlarmModeChanged;

  /// 装配点注入的回调：调度模式（完整/标准/无排序）变化时同步给 TaskService
  /// （v1.9 / D15 / 决议 43）。它改的是调度入参与查询口径——重锚之后
  /// "下一站会响的提醒"与清单顺序随之变，任务数据一行不动。
  final void Function(ScheduleMode scheduleMode)? onScheduleModeChanged;

  ReminderEvent? _lastReminder;
  StreamSubscription<DomainEvent>? _sub;
  StreamSubscription<DomainEvent>? _routineSub;
  StreamSubscription<ShownNotification>? _notifSub;
  Timer? _timer;
  bool _ticking = false;

  AppSettings _settings = AppSettings.defaults;
  bool _settingsLoaded = false;
  List<Task> _trash = const [];
  NotesReadResult? _notes;
  bool _notesLoading = false;
  String? _lastGenerationMark;

  /// 通知按钮 / 点通知定位（§7.2 定位边界）产生的待办提示与定位请求。
  String? _pendingNotice;
  String? _focusedTaskId;
  int _focusPage = 0;
  int _panelOpenRequest = 0;
  String? _settingsFocusRoutineId;
  int _panelCloseRequest = 0;

  ReminderEvent? get lastReminder => _lastReminder;

  AppSettings get settings => _settings;

  bool get settingsLoaded => _settingsLoaded;

  List<Task> get trashTasks => _trash;

  NotesReadResult? get notes => _notes;

  /// 主题预设（§8/§9 第 7 条）。
  AppThemePreset get themePreset => AppThemePreset.fromId(_settings.themePreset);

  /// 待消费的提示（一次性 toast）。
  String? get pendingNotice => _pendingNotice;

  /// 需要高亮定位的任务 id（消费后清空）。
  String? get focusedTaskId => _focusedTaskId;

  /// 定位请求应翻到哪一页（0=今日，2=池子）。
  int get focusPage => _focusPage;

  /// 侧边栏打开请求计数器（增量为"请求打开"；把手拖出/点通知都走它）。
  int get panelOpenRequest => _panelOpenRequest;

  /// 定位到设置页某条周期规则（决议 23：实例菜单的『编辑规则』）。
  String? get settingsFocusRoutineId => _settingsFocusRoutineId;

  /// 关闭侧边栏请求计数器（跳设置页时用）。
  int get panelCloseRequest => _panelCloseRequest;

  AppController({
    required this.service,
    required this.taskDir,
    this.routineService,
    this.settingsPort,
    this.bootstrapPort,
    this.permissions,
    this.folderPicker,
    this.onWindowsChanged,
    this.onAlarmModeChanged,
    this.onScheduleModeChanged,
    Stream<ShownNotification>? notificationSurface,
  }) {
    _sub = service.events.listen((_) => notifyListeners());
    _routineSub = routineService?.events.listen((_) => notifyListeners());
    // 桌面：NotificationPort 的"托盘"就是本应用窗口，回流渲染成弹窗。
    _notifSub = notificationSurface?.listen((shown) {
      _lastReminder = shown.event;
      notifyListeners();
    });
  }

  /// 由 main() 调用（测试里不启动，避免挂起 Timer 干扰测试）。
  void startTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  /// 启动时装配：读设置 + 周期实例生成 + 定期挑（system 订阅者语义）。
  Future<void> bootstrap() async {
    await _loadSettings();
    await syncRoutineInstances();
    await maybePickForToday();
  }

  /// 回到前台：SAF 无文件监听时靠它回流（附录 A），同时补当天的实例，
  /// 并把系统级把手的真实开关状态同步回设置页。
  Future<void> onResumed() async {
    await refresh();
    await syncRoutineInstances();
    await refreshOverlayHandleState();
  }

  Future<void> _loadSettings() async {
    final port = settingsPort;
    if (port == null) return;
    try {
      _settings = await port.load();
    } catch (_) {
      _settings = AppSettings.defaults;
    }
    _settingsLoaded = true;
    // 调度模式来自设置：装载完就同步给 TaskService（默认标准 = 只排列不提醒）。
    onScheduleModeChanged?.call(_settings.scheduleMode);
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    _settings = next;
    AppColors.applyPreset(AppThemePreset.fromId(next.themePreset));
    notifyListeners();
    try {
      await settingsPort?.save(next);
    } catch (_) {
      // 设置写盘失败：内存态继续生效，下次保存再试
    }
    onWindowsChanged?.call(notificationWindowRule);
    onAlarmModeChanged?.call(next.alarmMode);
    onScheduleModeChanged?.call(next.scheduleMode);
  }

  /// 调度模式（决议 43）：完整 / 标准（默认）/ 无排序。
  ScheduleMode get scheduleMode => _settings.scheduleMode;

  /// 派生：给内核的提醒门槛（编辑表单的提示文案、清单头的状态句用它）。
  ReminderMode get reminderMode => _settings.scheduleMode.reminderMode;

  /// 无排序 = 关掉算法排序（顺序全手动拖）。UI 用它决定拖拽是"定序"还是"插队"。
  bool get isManualSort => _settings.scheduleMode.isManual;

  /// §4.3：当前送达策略（默认 9:00–21:00 一段；空 = 不限制）。
  NotificationWindowRule get notificationWindowRule => NotificationWindowRule(
      _settings.notificationWindows
          .map((w) => NotificationWindow(w[0], w[1]))
          .toList());

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _routineSub?.cancel();
    _notifSub?.cancel();
    super.dispose();
  }

  /// 周期 tick：只做提醒轮询与跨日检查（C2：内部到点才会重锚）。
  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await syncRoutineInstancesIfNewDay();
      final event = await service.pollReminder();
      if (event != null) {
        _lastReminder = event;
        notifyListeners();
      }
    } finally {
      _ticking = false;
    }
  }

  // ---- 今日清单 / 任务池聚合查询（D12：UI 只消费查询结果）----

  TodayView get todayView => buildTodayView(
        tasks: service.tasks,
        schedule: service.lastSchedule,
        now: DateTime.now(),
        scheduleMode: _settings.scheduleMode,
      );

  PoolView get poolView => buildPoolView(
        tasks: service.tasks,
        now: DateTime.now(),
        routineOccurrences: upcomingOccurrences(),
        routineShowInPool: _settings.routineShowInPool,
      );

  /// 计划段/日历要用的周期发生（决议 24/27）。
  ///
  /// 计划段只需要**每条规则的下一次发生**（决议 27 的"下一次发生日期"；
  /// 每日规则若展开 30 天会把池子冲垮），且不含当天（当天实例归今日清单）。
  List<RoutineOccurrence> upcomingOccurrences() {
    final rs = routineService;
    if (rs == null) return const [];
    final now = DateTime.now();
    final out = <RoutineOccurrence>[];
    for (final r in rs.routines) {
      if (!r.enabled) continue;
      final at = r.nextOccurrence(now, includeToday: false);
      if (at != null) out.add(RoutineOccurrence(routine: r, at: at));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// 日历打点用：某一天有哪些周期发生（含当天）。
  List<RoutineOccurrence> occurrencesOn(DateTime day) =>
      routineService?.occurrences(from: day, days: 1) ?? const [];

  /// 回收站清单（查询后缓存到 _trash）。
  Future<void> refreshTrash() async {
    try {
      _trash = await service.loadTrash();
    } catch (_) {
      _trash = const [];
    }
    notifyListeners();
  }

  /// 疑问笔记（只读；对该文件零写入）。
  Future<void> refreshNotes() async {
    final port = notesReader;
    if (port == null) {
      _notes = const NotesReadResult(NotesStatus.notConfigured);
      notifyListeners();
      return;
    }
    if (_notesLoading) return;
    _notesLoading = true;
    try {
      _notes = await port.read();
    } catch (_) {
      _notes = const NotesReadResult(NotesStatus.notFound);
    } finally {
      _notesLoading = false;
      notifyListeners();
    }
  }

  // ---- 周期任务（决议 5/12/23）----

  List<Routine> get routines => routineService?.routines ?? const [];

  Routine? routineById(String id) => routineService?.byId(id);

  /// 每天零点生成当天实例（决议 5）；幂等，启动/回到前台/跨日都可调。
  Future<void> syncRoutineInstances() async {
    final rs = routineService;
    if (rs == null) return;
    _lastGenerationMark = _dayMark(DateTime.now());
    try {
      await rs.generateTodayInstances();
    } catch (_) {
      // 生成失败不阻塞启动；下一次 tick 会再试
    }
  }

  /// tick 里的跨日检查：日期变了才生成（不做无谓的写盘）。
  Future<void> syncRoutineInstancesIfNewDay() async {
    final mark = _dayMark(DateTime.now());
    if (_lastGenerationMark == mark) return;
    await syncRoutineInstances();
    notifyListeners();
  }

  Future<void> addRoutine(Routine draft) async {
    await routineService?.create(
      title: draft.title,
      description: draft.description,
      frequency: draft.frequency,
      weekdays: draft.weekdays,
      minuteOfDay: draft.minuteOfDay,
      remind: draft.remind,
      enabled: draft.enabled,
    );
  }

  Future<void> updateRoutine(String id, Routine next) async {
    await routineService?.update(
      id,
      title: next.title,
      description: next.description,
      frequency: next.frequency,
      weekdays: next.weekdays,
      minuteOfDay: next.minuteOfDay,
      clearTime: !next.hasTime,
      remind: next.remind,
      enabled: next.enabled,
    );
  }

  Future<void> deleteRoutine(String id) => routineService?.delete(id) ?? Future.value();

  Future<void> setRoutineEnabled(String id, bool enabled) =>
      routineService?.setEnabled(id, enabled) ?? Future.value();

  /// 例行实例"跳过今天"（决议 23：不完成、今日不再显示）。
  Future<void> skipRoutineToday(String instanceId) =>
      service.skipRoutineToday(instanceId);

  // ---- 设置页：权限与任务目录 ----

  Future<bool> permissionGranted(PermissionKind kind) async =>
      await permissions?.granted(kind) ?? true;

  /// 申请一项权限；返回申请后的状态（被拒 = false，UI 按 §11 降级）。
  Future<bool> ensurePermission(PermissionKind kind) async {
    final ok = await permissions?.ensure(kind) ?? true;
    notifyListeners();
    return ok;
  }

  /// 选择任务目录：写 bootstrap.json，提示重启生效（仓储在装配时绑定目录）。
  Future<String?> pickTaskDir() async {
    final picked = await folderPicker?.pickDirectory();
    if (picked == null || picked.trim().isEmpty) return null;
    await bootstrapPort?.save(BootstrapConfig(taskDir: picked));
    return picked;
  }

  /// 直接指定任务目录（手输路径，无选择器时的兜底）。
  Future<void> setTaskDir(String dir) async {
    await bootstrapPort?.save(BootstrapConfig(taskDir: dir));
  }

  /// 疑问笔记文件（§6.2）：系统选择器挑一个 Markdown；取消/平台不支持 → null，
  /// 此时设置页保留手输兜底。
  Future<String?> pickNotesFile() async {
    final port = folderPicker;
    if (port == null) return null;
    return port.pickFile(
      dialogTitle: '选择疑问笔记（Markdown）',
      allowedExtensions: const ['md', 'markdown'],
    );
  }

  /// 贴屏把手（系统级悬浮窗）；返回是否成功（无权限 = false → 抽屉兜底）。
  Future<bool> setOverlayHandle(bool enabled) async {
    final ok = await overlayHandleControl?.call(enabled) ?? false;
    _overlayHandleEnabled = ok && enabled;
    notifyListeners();
    return ok;
  }

  bool _overlayHandleEnabled = false;

  /// 系统级把手是否开着（开着时应用内把手不隐藏——两者分工：应用在前台
  /// 由应用内把手负责，退到后台由系统把手负责，原生侧自动切换）。
  bool get overlayHandleEnabled => _overlayHandleEnabled;

  /// 装配点注入：查询把手真实状态（安卓原生；桌面无此能力 = null）。
  Future<bool> Function()? overlayHandleState;

  /// 启动/回前台时同步把手真实状态（设置页开关据此显示，避免与系统不一致）。
  Future<void> refreshOverlayHandleState() async {
    final query = overlayHandleState;
    if (query == null) return;
    try {
      final enabled = await query();
      if (enabled == _overlayHandleEnabled) return;
      _overlayHandleEnabled = enabled;
      notifyListeners();
    } catch (_) {
      // 原生不可用：保持现值
    }
  }

  /// 装配点注入：把手开关（安卓原生；桌面无此能力 = null）。
  Future<bool> Function(bool enabled)? overlayHandleControl;

  // ---- 定期挑（决议 8：每天独立随机；手动挑过的日子自动挑让位）----

  Future<void> maybePickForToday() async {
    final s = _settings;
    if (!s.pickEnabled) return;
    final mark = _dayMark(DateTime.now());
    if (s.lastPickDate != null) {
      final last = DateTime.tryParse('${s.lastPickDate!}T00:00:00');
      if (last != null) {
        final elapsed =
            DateTime.tryParse('${mark}T00:00:00')!.difference(last).inDays;
        if (elapsed < s.pickIntervalDays) return;
      }
    }
    // 今日已有被挑件（手动挑过）→ 自动挑让位，只记账。
    final already =
        service.tasks.any((t) => !t.isCompleted && t.pickedForDate == mark);
    if (already) {
      await updateSettings(s.copyWith(lastPickDate: mark));
      return;
    }
    final pool = service.tasks
        .where((t) =>
            !t.isCompleted && t.type == TaskType.flex && t.deadline == null)
        .toList();
    if (pool.isEmpty) return;
    final pick = pool[Random().nextInt(pool.length)];
    await service.pickForToday(pick.id, origin: EventOrigin.system);
    await updateSettings(_settings.copyWith(lastPickDate: mark));
  }

  // ---- 只读查询 ----

  ScheduleResult? get schedule => service.lastSchedule;

  List<Task> get tasks => service.tasks;

  Task? taskById(String id) => service.byId(id);

  WorkTimeRule get workRule => service.workRule;

  List<String> get warnings => service.warnings;

  String? get nextTaskTitle {
    final id = service.lastSchedule?.nextTaskId;
    return id == null ? null : service.byId(id)?.title;
  }

  int get infeasibleCount => service.lastSchedule?.infeasibleTaskIds.length ?? 0;

  // ---- 命令（转发；UI 刷新由领域事件驱动）----

  Future<void> refresh() => service.refreshSchedule();

  Future<void> complete(String id) => service.completeTask(id);

  Future<void> snooze(String id, {required int minutes}) =>
      service.snoozeTask(id, minutes: minutes);

  /// 绝对档位推迟（明早 9 点 / 自选；决议 26：原样响）。
  Future<void> snoozeUntil(String id, {required DateTime until}) =>
      service.snoozeUntil(id, until: until);

  Future<void> snoozeToNextWindow(String id) =>
      service.snoozeToNextWindow(id);

  Future<void> logWork(String id, {required int minutes}) =>
      service.logWork(id, minutes: minutes);

  Future<void> pinToTop(String id) => service.pinToTop(id);

  /// 逐任务提醒开关（v0.9 决议 38）：标准模式下让这一件出声。
  Future<void> setTaskReminder(String id, {required bool enabled}) =>
      service.setTaskReminder(id, enabled: enabled);

  Future<void> pickForToday(String id) => service.pickForToday(id);

  Future<void> returnToPool(String id) => service.returnToPool(id);

  /// 池子拖拽后的整段重排（决议 14：顺序持久化）。批量落盘 + 一次重锚——
  /// 逐条写会让中间态被渲染出来，表现为清单闪动。
  Future<void> setPoolOrders(List<String> orderedIds) =>
      service.setPoolOrders(orderedIds);

  /// 今日可推组拖拽落位（标准/完整档，决议 9）：整段重写插队时刻，一次落盘。
  Future<void> setPinnedStack(List<String> orderedIds) =>
      service.setPinnedStack(orderedIds);

  /// 无排序模式下的拖动定序（决议 43）：整段重编 manual_order，重启保留；
  /// 自动模式下这些序号原样保留、只是不生效。
  Future<void> setManualOrder(List<String> orderedIds) =>
      service.setManualOrder(orderedIds);

  Future<void> deleteTask(String id) => service.deleteTask(id);

  Future<void> restoreTask(String id) async {
    await service.restoreTask(id);
    await refreshTrash();
  }

  Future<void> purgeTrash() async {
    await service.purgeTrash();
    await refreshTrash();
  }

  Future<Task> createTask({
    required String title,
    TaskType type = TaskType.flex,
    DateTime? deadline,
    int? estimatedWorkMinutes,
    int importance = 3,
    String description = '',
  }) {
    return service.createTask(
      title: title,
      type: type,
      deadline: deadline,
      estimatedWorkMinutes: estimatedWorkMinutes,
      importance: importance,
      description: description,
    );
  }

  Future<Task> updateTask(
    String id, {
    String? title,
    DateTime? deadline,
    bool clearDeadline = false,
    int? estimatedWorkMinutes,
    int? importance,
    String? description,
    TaskType? type,
  }) {
    return service.updateTask(
      id,
      title: title,
      deadline: deadline,
      clearDeadline: clearDeadline,
      estimatedWorkMinutes: estimatedWorkMinutes,
      importance: importance,
      description: description,
      type: type,
    );
  }

  void clearReminder() {
    _lastReminder = null;
    notifyListeners();
  }

  /// 通知上的"完成"等快捷动作（§7.2；安卓按钮/被杀后补做都走这里）。
  Future<void> handleReminderAction(String actionId, String taskId) async {
    final task = taskById(taskId);
    if (task == null) {
      _pendingNotice = '已删除，可在回收找回';
      notifyListeners();
      return;
    }
    switch (actionId) {
      case 'done':
        await complete(task.id);
        _pendingNotice = '已从通知完成「${task.title}」';
      case 'snooze1h':
        await snooze(task.id, minutes: 60);
        _pendingNotice = '已推迟 1 小时「${task.title}」';
    }
    notifyListeners();
  }

  /// 点通知正文 → 定位（§7.2 定位边界：今日高亮 / 池子高亮 / 已完成 toast /
  /// 已删除 toast）。
  void locateTask(String taskId) {
    final task = taskById(taskId);
    if (task == null) {
      _pendingNotice = '已删除，可在回收找回';
    } else if (task.isCompleted) {
      _pendingNotice = '该任务已完成';
    } else {
      final inToday = todayView;
      final inTodayList = [
        ...inToday.overdue,
        ...inToday.fixed,
        ...inToday.pinned,
        ...inToday.flex,
        ...inToday.routines,
        if (inToday.picked != null) inToday.picked!,
      ].any((t) => t.id == taskId);
      _focusedTaskId = taskId;
      _focusPage = inTodayList ? 0 : 2;
      _panelOpenRequest++;
      _pendingNotice = '已定位到「${task.title}」';
    }
    notifyListeners();
  }

  /// 把手拖出（系统级悬浮窗）→ 打开面板。
  void requestOpenPanel() {
    _panelOpenRequest++;
    notifyListeners();
  }

  String? consumeNotice() {
    final n = _pendingNotice;
    _pendingNotice = null;
    return n;
  }

  void clearFocus() {
    if (_focusedTaskId == null) return;
    _focusedTaskId = null;
    notifyListeners();
  }

  /// 悬浮窗把用户送进应用（"打开设置"）：关掉应用内面板、露出设置页主体。
  void openSettingsPage() {
    _panelCloseRequest++;
    notifyListeners();
  }

  /// 侧边栏里点『编辑规则』：关面板 + 设置页定位到该规则（决议 23）。
  ///
  /// 悬浮窗宿主（系统级面板）不是应用主体，本地没有设置页可翻——
  /// 装配点给它注入 [onOpenSettingsRequested]，改成"打开应用并定位"。
  void focusRoutineInSettings(String routineId) {
    _settingsFocusRoutineId = routineId;
    _panelCloseRequest++;
    notifyListeners();
    onOpenSettingsRequested?.call(routineId);
  }

  /// 装配点注入：悬浮窗宿主要求"打开应用设置页并定位到该规则"。
  void Function(String routineId)? onOpenSettingsRequested;

  void clearSettingsFocus() {
    if (_settingsFocusRoutineId == null) return;
    _settingsFocusRoutineId = null;
    notifyListeners();
  }
}
