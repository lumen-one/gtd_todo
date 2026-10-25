import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../application/branch_service.dart';
import '../application/delivery.dart';
import '../application/mainline_service.dart';
import '../application/notification_window.dart';
import '../application/notes_reader.dart';
import '../application/plan_service.dart';
import '../application/routine_service.dart';
import '../application/settings.dart';
import '../application/shell_capabilities.dart';
import '../application/sync.dart';
import '../application/task_service.dart';
import '../application/today_view.dart';
import '../domain/branch.dart';
import '../domain/event.dart';
import '../domain/mainline.dart';
import '../domain/plan.dart';
import '../domain/reminder.dart';
import '../domain/routine.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import 'panel_pages.dart';
import 'theme.dart';

/// 编排那块覆盖页的两个视图（ui-interaction.md §6.11 / §6.12）。
///
/// 同一块壳、两套互不相干的数据：时间轴（编排）与文件夹（支线）。落哪个视图由
/// **入口**决定——今日页到顶下拉落 [plan]，日期行右端那颗按钮落 [branch]；
/// 页头切换只改这一次打开，下次进来重新按入口算。
enum ArrangeView { plan, branch }

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

  /// 主线服务（ui-interaction.md §6.9；null = 未装配，顶栏不显示主线那一行）。
  ///
  /// 与 [service] 完全并列、互不依赖：行为链步骤不是任务，主线不参与调度。
  final MainlineService? mainlineService;

  /// 编排服务（ui-interaction.md §6.11；null = 未装配，下拉不进）。
  ///
  /// 同样与 [service] 并列：编排条目不是任务，不参与调度、不响提醒。
  final PlanService? planService;

  /// 支线服务（ui-interaction.md §6.12；null = 未装配，日期行那颗按钮不出现）。
  ///
  /// 第五份数据（`支线.md`），与 [service] / 主线 / 编排都不相交：条目是任务的
  /// id 引用，但服务本身不认识任务——标题由 [BranchService.titleOf] 注入。
  final BranchService? branchService;

  final String taskDir;

  /// 灵感端口（读写那篇 Markdown 的正文段；null = 未装配，UI 显示未接入）。
  /// 由装配点在构造后赋值（路径 getter 依赖本实例的设置）。
  NotesPort? notesPort;

  /// 设置存取端口（null = 未装配，全部用默认值）。
  final SettingsPort? settingsPort;

  /// 引导配置端口（任务目录选择用；null = 不可改目录）。
  final BootstrapPort? bootstrapPort;

  /// 权限插座（设置页"权限引导"用；null = 未装配，桌面视为已授予）。
  final PermissionPort? permissions;

  /// 目录选择插座（null = 平台不支持）。
  final FolderPickerPort? folderPicker;

  /// 壳能力表（§9 开头）：设置页据此裁掉"这套壳没有的东西"。
  ///
  /// 默认 [ShellCapabilities.overlayShell]——沿用能力俱全的那一侧，免得测试与
  /// 未来的新宿主在没填表时少看到几项；桌面由组装点显式传 `plainWindow`。
  final ShellCapabilities caps;

  /// 同步插座（§4.4；null = 未装配，设置页"同步"区显示未接入）。
  SyncPort? _sync;
  String _deviceName = '这台设备';

  /// 装配点注入的回调：通知时间段变化时同步给 ReminderDispatcher（§4.3）。
  final void Function(NotificationWindowRule rule)? onWindowsChanged;

  /// 装配点注入的回调：闹钟模式变化时同步给 ReminderDispatcher（决议 18）。
  final void Function(bool alarmMode)? onAlarmModeChanged;

  /// 装配点注入的回调：调度模式（完整/标准/无排序）变化时同步给 TaskService
  /// （v1.9 / D15 / 决议 43）。它改的是调度入参与查询口径——重锚之后
  /// "下一站会响的提醒"与清单顺序随之变，任务数据一行不动。
  final void Function(ScheduleMode scheduleMode)? onScheduleModeChanged;

  /// 装配点注入的回调：**工时日历**变化时同步给 TaskService（v1.26）。
  /// 它是 slack 的分母，改完要把锚点表整张作废——所以只能在指纹真的变了时调，
  /// 不能跟着每次设置保存都推一遍。
  final void Function(WorkTimeRule rule)? onWorkRuleChanged;

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

  /// 本次打开请求是通知定位（见 [consumeLocateRequest]）。
  bool _openRequestLocates = false;
  String? _settingsFocusRoutineId;
  int _panelCloseRequest = 0;

  ReminderEvent? get lastReminder => _lastReminder;

  AppSettings get settings => _settings;

  bool get settingsLoaded => _settingsLoaded;

  /// 同步状态（设置页"同步"区消费；未装配 = 未开启）。
  SyncState get syncState => _sync?.state ?? const SyncState.idle();

  /// 装配同步插座并订阅状态变化（main() 调；测试里不装）。
  /// [deviceName] = 本机名（进 UDP 广播与冲突存档文件名，由装配点从 dart:io 取）。
  void attachSync(SyncPort port, String deviceName) {
    _sync = port;
    _deviceName = deviceName;
    port.changes.listen((_) => notifyListeners());
  }

  /// 当主机（设备名进 UDP 广播与冲突存档文件名）。
  Future<void> startSyncHost() async {
    await _sync?.startHost(_deviceName);
    notifyListeners();
  }

  /// 扫局域网内的主机（设置页"同步"区的手动发现按钮）。
  Future<List<SyncPeer>> discoverSyncHosts() =>
      _sync?.discover() ?? Future.value(const []);

  /// 接入主机并立即同步一轮。
  Future<SyncOutcome> connectSyncHost(SyncPeer peer) async {
    final out = await _sync?.connectTo(peer, _deviceName) ??
        const SyncOutcome(error: '同步未装配');
    notifyListeners();
    return out;
  }

  /// 手动同步一轮（主机 = 无从机可推时是无操作；从机 = 拉 + 推）。
  Future<SyncOutcome> syncNow() async {
    final out = await _sync?.syncNow() ?? const SyncOutcome();
    notifyListeners();
    return out;
  }

  /// 停止同步（下播 / 断开）。
  Future<void> stopSync() async {
    await _sync?.stop();
    notifyListeners();
  }

  List<Task> get trashTasks => _trash;

  NotesReadResult? get notes => _notes;

  /// 主题预设（§8/§9 第 7 条）。
  AppThemePreset get themePreset => AppThemePreset.fromId(_settings.themePreset);

  /// 明暗模式（§8/§9 第 7 条）→ MaterialApp 的 themeMode。
  /// 缺省跟随系统（设置缺键 / 值不认识时）。
  ThemeMode get themeMode => AppThemeMode.fromId(_settings.themeMode).themeMode;

  /// 待消费的提示（一次性 toast）。
  String? get pendingNotice => _pendingNotice;

  /// 需要高亮定位的任务 id（消费后清空）。
  String? get focusedTaskId => _focusedTaskId;

  /// 定位请求应翻到哪一页（页序号，页序见 `ui/panel_pages.dart`）。
  int get focusPage => _focusPage;

  /// 展开后默认停在哪一页（设置项 `default_page`；缺键 / 认不出的 id 回落今日清单）。
  PanelPage get defaultPanelPage => panelPageFromId(_settings.defaultPage);

  /// 设置页选『展开后默认页面』（§9 第 12 条）：只落设置，不改当前这一页
  /// ——用户可能正看着某一页，改设置不必当场跳走。
  Future<void> setDefaultPage(PanelPage page) async {
    if (page.name == _settings.defaultPage) return;
    await updateSettings(_settings.copyWith(defaultPage: page.name));
  }

  /// 侧边栏打开请求计数器（增量为"请求打开"；把手拖出/点通知都走它）。
  int get panelOpenRequest => _panelOpenRequest;

  /// 主线覆盖页是否打开（§6.9）。
  ///
  /// 状态放控制器而不是覆盖页自己的 State 里：两个宿主（安卓壳 / 悬浮窗壳）都
  /// 挂了 `PopScope` 处理返回键，覆盖页再挂一个的话，返回键会**同时**触发两个
  /// 回调（同一条路由上的 PopScope 全部收到通知），面板会跟着一起收起。
  /// 所以统一由宿主问一句"主线开着吗"来裁决。
  bool _mainlineOpen = false;

  bool get mainlineOpen => _mainlineOpen;

  void openMainline() {
    if (_mainlineOpen) return;
    _mainlineOpen = true;
    notifyListeners();
  }

  /// 覆盖页注入的"能不能直接关"（编辑态要先问一句再说）。返回 false = 先别关。
  Future<bool> Function()? mainlineCloseGuard;

  /// 上滑退出的跟手行程（逻辑像素 = 从"全开"往上推掉了多少）。
  ///
  /// 与编排那对 notifier 同一套：拖动时每帧在变，不能走 [notifyListeners]
  /// （会把整棵面板包括行为链一起重建）。
  final ValueNotifier<double> mainlineExit = ValueNotifier<double>(0);

  /// 手指还按着（false = 已松手，该补满或弹回）。
  final ValueNotifier<bool> mainlineExiting = ValueNotifier<bool>(false);

  void pullMainlineExit(double px) {
    if (!_mainlineOpen || px <= 0) return;
    mainlineExiting.value = true;
    mainlineExit.value = (mainlineExit.value + px).clamp(0.0, 4000.0);
  }

  /// 松手：推过阈值或向上快甩（dy < −500 px/s）才关，否则弹回。
  Future<void> settleMainlineExit(double velocityY) async {
    if (!mainlineExiting.value) return;
    final enough = mainlineExit.value >= planPullThreshold || velocityY < -500;
    mainlineExiting.value = false;
    if (enough) await closeMainline();
    // 关成了由覆盖层的退场动画接手；没关成（编辑态守卫拦下）就弹回原位。
    if (_mainlineOpen) mainlineExit.value = 0;
  }

  /// 关掉覆盖页。宿主（返回键 / 收起面板）与覆盖页自己的『返回』都走这里，
  /// 编辑态由 [mainlineCloseGuard] 决定留不留。
  Future<void> closeMainline() async {
    if (!_mainlineOpen) return;
    final guard = mainlineCloseGuard;
    if (guard != null && !await guard()) return;
    _mainlineOpen = false;
    mainlineExit.value = 0;
    mainlineExiting.value = false;
    notifyListeners();
  }

  // ---- 今日编排（§6.11）----

  /// 编排覆盖页开着吗。与 [mainlineOpen] 同一套理由：状态在控制器，宿主的返回键
  /// 与覆盖页自己都问这一句（同一条路由上两个 `PopScope` 会各收一次）。
  bool _planOpen = false;

  bool get planOpen => _planOpen;

  /// 这次打开落在哪个视图（页头切换会改它；关闭后保留，下次打开由入口重设）。
  ArrangeView _arrangeView = ArrangeView.plan;

  ArrangeView get arrangeView => _arrangeView;

  /// 页头切换（编排 ↔ 支线）：只换这一页里显示什么，不动数据、不改开合。
  void showArrangeView(ArrangeView view) {
    if (_arrangeView == view) return;
    _arrangeView = view;
    notifyListeners();
  }

  /// 这次打开要不要跳过进场动画（= 面板自己正滑进来，覆盖页得第一帧就在）。
  ///
  /// 只有"面板展开即落编排"要跳过：那时底下露着今日清单，播 200ms 动画就成了
  /// "先给清单、再切成编排"。点日期行按钮打开支线是另一回事——面板早已在屏幕上，
  /// 不播动画等于凭空出现。
  bool _planEnterInstant = false;

  bool get planEnterInstant => _planEnterInstant;

  /// 下拉跟手的行程（逻辑像素，0 = 完全藏起来）。**单独一个 notifier**：拖动时
  /// 每帧都在变，走 [notifyListeners] 会把整棵面板（含可能很长的清单）一起重建。
  final ValueNotifier<double> planPull = ValueNotifier<double>(0);

  /// 手指还按着（false = 已松手，覆盖页该补满或弹回）。
  final ValueNotifier<bool> planDragging = ValueNotifier<bool>(false);

  /// 上滑退出的跟手行程（= 从"全开"往上推掉了多少），与 [planPull] 同一个轴：
  /// 进是露出量增加，出是露出量减少，两边共用 `_PlanReveal` 的同一个进度。
  final ValueNotifier<double> planExit = ValueNotifier<double>(0);

  /// 手指还按着（false = 已松手，该补满或弹回）。
  final ValueNotifier<bool> planExiting = ValueNotifier<bool>(false);

  /// 拉到多少算数（与把手的阈值同一个数字，§6.0）。
  static const double planPullThreshold = 72;

  /// 今日页在顶部继续下拉时喂进来的行程（只加正的）。
  void pullPlan(double px) {
    if (_planOpen || px <= 0) return;
    planDragging.value = true;
    planPull.value = (planPull.value + px).clamp(0.0, 4000.0);
  }

  /// 松手：拉过阈值、或向下快甩（dy > 500 px/s，与把手同档）就补满，否则弹回。
  void settlePlan(double velocityY) {
    // 普通滚动结束也会走到这里（每次 ScrollEndNotification）：没在拉就直接走开。
    if (!planDragging.value && planPull.value == 0) return;
    final enough = planPull.value >= planPullThreshold || velocityY > 500;
    planDragging.value = false;
    if (enough) {
      openPlan();
    } else {
      planPull.value = 0;
    }
  }

  void openPlan() {
    if (_planOpen) {
      planPull.value = 0;
      planDragging.value = false;
      // 开在支线视图上时，"落编排"就是切回来。
      if (_arrangeView != ArrangeView.plan) {
        _arrangeView = ArrangeView.plan;
        notifyListeners();
      }
      return;
    }
    // 先立旗再松手：`_PlanReveal` 在"松手"的那一刻决定往哪边补。
    _arrangeView = ArrangeView.plan;
    _planEnterInstant = true;
    _planOpen = true;
    planPull.value = 0;
    planDragging.value = false;
    notifyListeners();
  }

  /// 从今日页日期行打开支线视图（§6.12）：与 [openPlan] 共用同一块覆盖页，
  /// 只是落在另一个视图。面板早已在屏幕上，所以**不跳过进场动画**——不然那
  /// 一整页是凭空出现的。
  void openBranch() {
    if (branchService == null) return;
    _arrangeView = ArrangeView.branch;
    if (_planOpen) {
      notifyListeners();
      return;
    }
    _planEnterInstant = false;
    _planOpen = true;
    planPull.value = 0;
    planDragging.value = false;
    notifyListeners();
  }

  void closePlan() {
    if (!_planOpen) {
      planPull.value = 0;
      planDragging.value = false;
      planExit.value = 0;
      planExiting.value = false;
      return;
    }
    _planOpen = false;
    planPull.value = 0;
    planDragging.value = false;
    planExit.value = 0;
    planExiting.value = false;
    notifyListeners();
  }

  /// 编排页时间轴滚到底后继续上滑（逻辑像素，只加正的）。
  void pullPlanExit(double px) {
    if (!_planOpen || px <= 0) return;
    planExiting.value = true;
    planExit.value = (planExit.value + px).clamp(0.0, 4000.0);
  }

  /// 松手：推过阈值或向上快甩（dy < −500 px/s）就关，否则弹回。
  void settlePlanExit(double velocityY) {
    if (!planExiting.value) return;
    final enough = planExit.value >= planPullThreshold || velocityY < -500;
    planExiting.value = false;
    if (enough) {
      closePlan();
    } else {
      planExit.value = 0;
    }
  }

  /// 今天已经有编排就直接展开它（§6.11）——等于替用户把"到顶再下拉"做了一遍。
  /// 返回是否展开（测试与宿主都读它）。
  ///
  /// **调用时机是"开面板之前"**：宿主要先调它、再让面板露面。反过来（面板先开、
  /// 帧后再亮）露出的第一帧是今日清单，随后才被覆盖页盖住——看着就是"先给清单、
  /// 再切成编排"。跟手拉开那一路同理，起手那一拍就得调。
  ///
  /// 三个条件缺一不可：装配了编排、**设置里的默认页就是今日清单**（默认页是别的
  /// 页时不触发，那一页才是打开面板要看的东西）、今天确实有条目。空的一天不进：
  /// 那正是要去写的时候，先盖一层空轴只会挡路。
  ///
  /// **每次展开只亮一次**：亮过之后 `planOpen` 就是 true，同一轮里再调直接返回；
  /// 收起面板会 [closePlan]，下次拉出来再亮一遍。不需要额外记"今天亮过没有"。
  bool landOnPlanForToday({DateTime? today}) {
    if (_planOpen || planService == null) return false;
    if (defaultPanelPage != PanelPage.today) return false;
    if (planEntriesFor(today ?? DateTime.now()).isEmpty) return false;
    openPlan();
    return true;
  }

  /// 定位到设置页某条周期规则（决议 23：实例菜单的『编辑规则』）。
  String? get settingsFocusRoutineId => _settingsFocusRoutineId;

  /// 关闭侧边栏请求计数器（跳设置页时用）。
  int get panelCloseRequest => _panelCloseRequest;

  // ---- 关于（ui-interaction.md §9 第 14 条）----

  String? _appVersion;

  /// 形如 `1.2.0 (4)`；还没读到 → null（界面显示占位）。
  String? get appVersion => _appVersion;

  /// 装配点注入：读**安装包自己的版本**（安卓原生 `PackageManager`）。
  /// null = 这套壳不读（桌面那张关于卡整块不摆，也不去问平台）。
  ///
  /// 回的是 (versionName, versionCode) 两截事实；拼成 `1.2.0 (4)` 的规则留在
  /// [loadAppVersion]——格式属于界面，不散到原生去。
  Future<({String version, String build})?> Function()? appVersionReader;

  /// 从**安装包自己的元数据**读版本号（安卓 `versionName` / `versionCode`）。它由
  /// `flutter build` 从 `pubspec.yaml` 的 `version:` 灌进包里，所以源码里不写死版本号，
  /// 也不会出现"界面写着 1.2.0、装的是 1.3.0"。
  ///
  /// **不走 `package_info_plus`**：那个插件的安卓 Gradle 脚本自己 apply 了 Kotlin
  /// Gradle Plugin，而 AGP 9 起 Kotlin 内置、Flutter 往后会禁掉这条路（构建时也会
  /// 打一条 KGP 警告）。版本号本来就是我们自己原生里的几行，不值得为它引一个插件。
  ///
  /// 幂等：读到一次就不再问平台。没接插座的壳（桌面 / 测试）与读失败都留 null，
  /// 界面显示占位——不算错误。
  Future<void> loadAppVersion() async {
    if (_appVersion != null) return;
    final read = appVersionReader;
    if (read == null) return;
    try {
      final info = await read();
      if (info == null || info.version.isEmpty) return;
      final build = info.build.trim();
      _appVersion = build.isEmpty ? info.version : '${info.version} ($build)';
      notifyListeners();
    } catch (_) {
      // 原生没实现（老版本 / 误装配）：留 null，界面显示占位。
    }
  }

  AppController({
    required this.service,
    required this.taskDir,
    this.routineService,
    this.mainlineService,
    this.planService,
    this.branchService,
    this.settingsPort,
    this.bootstrapPort,
    this.permissions,
    this.folderPicker,
    this.caps = ShellCapabilities.overlayShell,
    this.onWindowsChanged,
    this.onAlarmModeChanged,
    this.onScheduleModeChanged,
    this.onWorkRuleChanged,
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
    try {
      await mainlineService?.load();
    } catch (_) {
      // 主线读失败不阻塞启动：顶栏显示『＋ 新建主线』，下次 refresh 再试
    }
    try {
      await planService?.load();
    } catch (_) {
      // 编排读失败不阻塞启动：今日页照样能下拉，只是时间轴先空着
    }
    try {
      await branchService?.load();
    } catch (_) {
      // 支线读失败不阻塞启动：日期行按钮照常，列表先空着
    }
  }

  /// 回到前台：SAF 无文件监听时靠它回流（附录 B），同时补当天的实例，
  /// 并把系统级把手的真实开关状态同步回设置页。
  Future<void> onResumed() async {
    await refresh();
    await syncRoutineInstances();
    await refreshOverlayHandleState();
    await syncNow(); // 回前台补一轮同步（§4.4；未接入主机时是无操作）
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
    // 工时日历同理：装配时用的是默认规则，这里换成用户设置的那份。
    onWorkRuleChanged?.call(_settings.workRule);
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    final previous = _settings;
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
    // 工时只在指纹变了时推：它会清空锚点表，跟着每次保存都推等于把提醒全部重排
    if (next.workSignature != previous.workSignature) {
      onWorkRuleChanged?.call(next.workRule);
    }
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
    planPull.dispose();
    planDragging.dispose();
    planExit.dispose();
    planExiting.dispose();
    mainlineExit.dispose();
    mainlineExiting.dispose();
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
        // 无排序档散件按 `loose_home` 分家：池子只收搬过来的那些。
        splitLoose: _settings.scheduleMode.isManual,
      );

  /// 已完成归档（ui 文档 §6.7 已完成页）：今天/昨天/更早三组。
  /// 与调度模式无关（存档不参与排序），所以这里不传 scheduleMode。
  CompletedView get completedView => buildCompletedView(
        tasks: service.tasks,
        now: DateTime.now(),
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

  /// 灵感正文（读；状态里带编辑初值与可编辑标记）。
  Future<void> refreshNotes() async {
    final port = notesPort;
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

  /// 保存灵感正文（§6.2）：只换正文段，frontmatter 与其他段落不动。
  /// 返回 true = 真落盘；false 时由调用方给提示（UI 只知道"没存上"）。
  Future<bool> saveNotes(String body) async {
    final port = notesPort;
    if (port == null) return false;
    final status = await port.write(body);
    // 无论成败都重读：失败时页面也不能停在"看起来存了"的旧内容上。
    await refreshNotes();
    return status == NotesWriteStatus.ok;
  }

  // ---- 主线（ui-interaction.md §6.9）----

  /// 主线是否接入（未装配的宿主 / 老测试为 false：顶栏不渲染第二行）。
  bool get hasMainline => mainlineService != null;

  List<Mainline> get mainlines => mainlineService?.mainlines ?? const [];

  /// 当前在跑的那一条（顶栏第二行显示的就是它）；没有 → null。
  Mainline? get activeMainline => mainlineService?.active;

  Mainline? mainlineById(String id) => mainlineService?.byId(id);

  List<Mainline> get archivedMainlines => mainlineService?.archived ?? const [];

  /// 新建主线（创建后自动成为"当前主线"）。
  Future<Mainline?> createMainline(
    String title, {
    List<String> steps = const [],
  }) async {
    final svc = mainlineService;
    if (svc == null) return null;
    final created = await svc.create(title: title, steps: steps);
    notifyListeners();
    return created;
  }

  Future<void> renameMainline(String id, String title) =>
      _mainlineCommand((svc) => svc.rename(id, title));

  /// 编辑态一次保存整条行为链（改名 + 顺序 + 步骤文字一起写）。
  Future<void> setMainlineSteps(String id, List<MainlineStep> steps) =>
      _mainlineCommand((svc) => svc.setSteps(id, steps));

  Future<void> toggleMainlineStep(String id, int index, {required bool done}) =>
      _mainlineCommand((svc) => svc.toggleStep(id, index, done: done));

  Future<void> updateMainlineStep(
    String id,
    int index, {
    String? title,
    String? note,
  }) =>
      _mainlineCommand(
          (svc) => svc.updateStep(id, index, title: title, note: note));

  Future<void> addMainlineStep(String id, String title) =>
      _mainlineCommand((svc) => svc.addStep(id, title));

  /// 记录（日历上的圈）：拖选一段连续日期后写文字。
  Future<void> addMainlineLog(
    String id, {
    required DateTime start,
    required DateTime end,
    String text = '',
  }) =>
      _mainlineCommand((svc) =>
          svc.addLog(id, start: start, end: end, text: text));

  /// 改一段记录：按内容（起止日 + 原文）定位，不传下标——中间多一条别人的圈就
  /// 会改错（见 `MainlineLogRef`）。已经不在时会抛错，由界面提示。
  Future<void> updateMainlineLog(
    String id,
    MainlineLogRef ref, {
    DateTime? start,
    DateTime? end,
    String? text,
  }) =>
      _mainlineCommand((svc) =>
          svc.updateLog(id, ref, start: start, end: end, text: text));

  Future<void> removeMainlineLog(String id, MainlineLogRef ref) =>
      _mainlineCommand((svc) => svc.removeLog(id, ref));

  /// 月记：一个月一句（记录页切到月视图时写；空文本 = 删掉这个月那条）。
  Future<void> setMainlineMonthNote(
    String id,
    int year,
    int month,
    String text,
  ) =>
      _mainlineCommand((svc) => svc.setMonthNote(id, year, month, text));

  /// 归档（行为链必须全勾完；没勾完会抛 StateError，由 UI 提示）。
  Future<void> completeMainline(String id) =>
      _mainlineCommand((svc) => svc.complete(id));

  Future<void> _mainlineCommand(
      Future<void> Function(MainlineService svc) op) async {
    final svc = mainlineService;
    if (svc == null) return;
    await op(svc);
    notifyListeners();
  }

  // ---- 今日编排（§6.11）----

  bool get hasPlan => planService != null;

  /// 某一天的编排条目（行序就是顺序）；未装配 → 空表。
  List<PlanEntry> planEntriesFor(DateTime day) =>
      planService?.entriesFor(day) ?? const [];

  Future<void> addPlanEntry(DateTime day, PlanEntry entry) =>
      _planCommand((svc) => svc.addEntry(day, entry));

  Future<void> updatePlanEntry(DateTime day, int index, PlanEntry next) =>
      _planCommand((svc) => svc.updateEntry(day, index, next));

  Future<void> removePlanEntry(DateTime day, int index) =>
      _planCommand((svc) => svc.removeEntry(day, index));

  /// 整日重写（拖动改顺序）。
  Future<void> setPlanEntries(DateTime day, List<PlanEntry> entries) =>
      _planCommand((svc) => svc.setEntries(day, entries));

  Future<void> _planCommand(Future<void> Function(PlanService svc) op) async {
    final svc = planService;
    if (svc == null) return;
    await op(svc);
    notifyListeners();
  }

  // ---- 支线（§6.12）----

  /// 支线是否接入（未装配 → 日期行那颗按钮不出现）。
  bool get hasBranches => branchService != null;

  List<Branch> get branches => branchService?.branches ?? const [];

  /// 某条支线里的条目（文件里的行序；已完成的不在这儿沉底——那是渲染的事）。
  List<BranchEntry> branchEntries(int index) {
    final list = branches;
    if (index < 0 || index >= list.length) return const [];
    return list[index].entries;
  }

  /// 这条支线里的任务；查不到的 id 给 null（界面按失效引用显示，不删行）。
  List<Task?> branchTasks(int index) => [
        for (final e in branchEntries(index)) taskById(e.taskId),
      ];

  /// 这件任务挂在哪几条支线上（候选框右侧标注用；可以有好几条）。
  List<String> branchNamesOf(String taskId) => [
        for (final b in branches)
          if (b.contains(taskId)) b.name,
      ];

  Future<void> addBranch(String name) =>
      _branchCommand((svc) => svc.addBranch(name));

  Future<void> renameBranch(int index, String name) =>
      _branchCommand((svc) => svc.renameBranch(index, name));

  /// 删一条支线：只删分组，任务一件都不动。
  Future<void> removeBranch(int index) =>
      _branchCommand((svc) => svc.removeBranch(index));

  Future<void> addTaskToBranch(int index, String taskId) =>
      _branchCommand((svc) => svc.addTask(index, taskId));

  Future<void> removeTaskFromBranch(int index, String taskId) =>
      _branchCommand((svc) => svc.removeTask(index, taskId));

  /// 整段重写（拖动改顺序）。
  Future<void> setBranchEntries(int index, List<BranchEntry> entries) =>
      _branchCommand((svc) => svc.setEntries(index, entries));

  Future<void> _branchCommand(
      Future<void> Function(BranchService svc) op) async {
    final svc = branchService;
    if (svc == null) return;
    await op(svc);
    notifyListeners();
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

  /// 灵感文件（§6.2）：系统选择器挑一个 Markdown；取消/平台不支持 → null，
  /// 此时设置页保留手输兜底。
  Future<String?> pickNotesFile() async {
    final port = folderPicker;
    if (port == null) return null;
    return port.pickFile(
      dialogTitle: '选择灵感文件（Markdown）',
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

  /// 装配点注入：把手位置上锁（安卓原生；桌面无此能力 = null）。
  Future<bool> Function(bool locked)? handleLockControl;

  /// 把手位置上锁（§6.0）：锁上后竖向拖动不再改变把手高度。
  ///
  /// 先推给原生（系统级把手），再落 settings.json——两边都写：原生自己管把手位置，
  /// 服务可能在 Dart 起来之前就被拉起，不能只靠通道补投。
  Future<void> setHandleLocked(bool locked) async {
    await handleLockControl?.call(locked);
    await updateSettings(_settings.copyWith(handleLocked: locked));
  }

  /// 固定侧边栏大小（§6.0 / §9 第 11 条）：把此刻生效的宽高冻成数字一起落盘。
  ///
  /// 宽高由 UI 层算好传进来——只有它知道当前屏宽与可用高度，冻的才是"此刻
  /// 看到的那块"；锁上后换屏宽、横竖屏都不再按默认公式变。纯 Dart 侧的事：
  /// 悬浮窗是全屏透明窗口、面板尺寸由 [ResizablePanel] 自持，不必过通道。
  Future<void> lockPanelSize({required double width, required double height}) =>
      updateSettings(_settings.copyWith(
        panelWidth: width,
        panelHeight: height,
        panelSizeLocked: true,
      ));

  /// 解锁面板尺寸：只清开关，冻住的数值留着——解锁后还能从那个尺寸接着拖。
  Future<void> unlockPanelSize() =>
      updateSettings(_settings.copyWith(panelSizeLocked: false));

  /// 装配点注入：把手热区宽度（安卓原生；桌面无此能力 = null）。
  Future<bool> Function(int widthDp)? handleHotWidthControl;

  /// 把手热区宽度（§6.0 / §9 第 10 条）：与 [setHandleLocked] 同一套路——先推给
  /// 原生（系统级把手的窗口宽度和手势排除区都要跟着改），再落 settings.json。
  /// 应用内把手不需要通道：它就在这个 isolate 里读设置重建。
  Future<void> setHandleHotWidth(int widthDp) async {
    await handleHotWidthControl?.call(widthDp);
    await updateSettings(_settings.copyWith(handleHotWidth: widthDp));
  }

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
    // 无排序档不跑：散件本来就整段在今日页 ⑥，再挑一件只是同一堆里换个位置。
    // 不记 `last_pick_date`——切回标准/完整档时按间隔照常挑（不会因为"这几周
    // 没挑过"而记账错乱）。
    if (s.scheduleMode.isManual) return;
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

  Future<void> refresh() async {
    // 主线也在这条通路上重读：文件监听只知道"目录里有 .md 变了"，
    // 主引擎与悬浮引擎都靠它把 `主线.md` 的改动捞回来。
    try {
      await mainlineService?.load();
    } catch (_) {
      // 读失败保留上次内存态（顶栏宁可不更新，也别闪成空）
    }
    // 编排同理（`编排.md` 与 `主线.md` 是同一类：整份由应用维护）。
    try {
      await planService?.load();
    } catch (_) {
      // 读失败保留上次内存态
    }
    // 支线同理（`支线.md` 也是整份由应用维护的那一类）。
    try {
      await branchService?.load();
    } catch (_) {
      // 读失败保留上次内存态
    }
    await service.refreshSchedule();
  }

  Future<void> complete(String id) => service.completeTask(id);

  /// 恢复未完成（撤销一次完成；已完成页与详情卡的兜底动作，ui 文档 §6.7）。
  Future<void> reopenTask(String id) => service.reopenTask(id);

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

  /// 散件的家（无排序档）：`pool` = 搬到池子散件段，`false` = 搬回今日页 ⑥。
  Future<void> setLooseHome(String id, {required bool pool}) =>
      service.setLooseHome(id, pool: pool);

  /// 池子拖拽后的整段重排（决议 14：顺序持久化）。批量落盘 + 一次重锚——
  /// 逐条写会让中间态被渲染出来，表现为清单闪动。
  Future<void> setPoolOrders(List<String> orderedIds) =>
      service.setPoolOrders(orderedIds);

  /// 今日可推组拖拽落位（标准/完整档，决议 9）：整段重写插队时刻，一次落盘。
  Future<void> setPinnedStack(List<String> orderedIds) =>
      service.setPinnedStack(orderedIds);

  /// 挂起进行开关（v1.18 决议 47）：长期任务顶置今日页最顶的挂起组；
  /// 保持到完成或主动取消，不按天过期（完成命令顺手清标记）。
  Future<void> setInProgress(String id, {required bool enabled}) =>
      service.setInProgress(id, enabled: enabled);

  /// 挂起组拖拽后的整段重排（决议 47）：整段重写挂起时刻，一次落盘。
  Future<void> setInProgressStack(List<String> orderedIds) =>
      service.setInProgressStack(orderedIds);

  /// 无排序模式下的拖动定序（决议 43）：整段重编 manual_order，重启保留；
  /// 自动模式下这些序号原样保留、只是不生效。
  Future<void> setManualOrder(List<String> orderedIds) =>
      service.setManualOrder(orderedIds);

  Future<void> deleteTask(String id) => service.deleteTask(id);

  /// 批量命令（多选，ui 文档 §10#23）：一次落盘一个事件一次重算，
  /// 不逐条转发单条命令（那会让清单一条条闪）。
  Future<void> completeTasks(List<String> ids) => service.completeTasks(ids);

  Future<void> deleteTasks(List<String> ids) => service.deleteTasks(ids);

  Future<void> restoreTasks(List<String> ids) async {
    await service.restoreTasks(ids);
    await refreshTrash();
  }

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
    bool clearWork = false,
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
      clearWork: clearWork,
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

  /// 点通知正文 → 定位（§7.2 定位边界：今日高亮 / 池子高亮 / 已完成页高亮 /
  /// 已删除 toast）。
  void locateTask(String taskId) {
    final task = taskById(taskId);
    if (task == null) {
      _pendingNotice = '已删除，可在回收找回';
    } else if (task.isCompleted) {
      // 已完成 → 跳已完成页定位高亮（§6.7）：不再是一句"该任务已完成"的死路 toast。
      _focusedTaskId = taskId;
      _focusPage = PanelPage.completed.index;
      _openRequestLocates = true;
      _panelOpenRequest++;
      _pendingNotice = '已定位到「${task.title}」（已完成）';
    } else {
      final inToday = todayView;
      final inTodayList = [
        ...inToday.inProgress,
        ...inToday.overdue,
        ...inToday.fixed,
        ...inToday.pinned,
        ...inToday.flex,
        ...inToday.routines,
        if (inToday.picked != null) inToday.picked!,
      ].any((t) => t.id == taskId);
      _focusedTaskId = taskId;
      _focusPage = inTodayList ? PanelPage.today.index : PanelPage.pool.index;
      _openRequestLocates = true;
      _panelOpenRequest++;
      _pendingNotice = '已定位到「${task.title}」';
    }
    notifyListeners();
  }

  /// 本次"打开面板"的请求是不是通知定位触发的。
  ///
  /// **读一次即清**：`focusedTaskId` 会一直留着给条目高亮（没有 clearFocus 的调用点），
  /// 拿它判"这次是定位"会让此后每次打开都跳回上次那条。
  bool consumeLocateRequest() {
    final locating = _openRequestLocates;
    _openRequestLocates = false;
    return locating;
  }

  /// 把手拖出（系统级悬浮窗）→ 打开面板。
  void requestOpenPanel() {
    _openRequestLocates = false;
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
