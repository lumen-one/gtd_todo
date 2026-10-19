import 'dart:convert';

import '../domain/schedule.dart';

/// 把手热区宽度的取值区间（dp，§6.0 / §9 第 10 条）：手改 settings.json 改坏了
/// 也不越界，读进来一律夹到区间里。
const int minHandleHotWidth = 8;
const int defaultHandleHotWidth = 12;
const int maxHandleHotWidth = 20;

/// 把手热区宽度的**三档值**（细 / 标准 / 宽），设置页按这个顺序摆。
/// 档位怎么呈现是 UI 层的事，application 只认夹过界的数字。
const List<int> handleHotWidthOptions = [
  minHandleHotWidth,
  defaultHandleHotWidth,
  maxHandleHotWidth,
];

/// 把手热区宽度：缺字段 / 手改坏了都回默认，其余夹进区间。
int clampHandleHotWidth(Object? raw) {
  if (raw is! num) return defaultHandleHotWidth;
  return raw.toInt().clamp(minHandleHotWidth, maxHandleHotWidth).toInt();
}

/// 应用设置（ui-interaction.md §9）：调度模式、提醒时间段、定期挑、疑问笔记路径等。
/// application 只定义形状与缺省值；落盘走 [SettingsPort]（组装点装配，
/// 本期实现 = 任务目录下 settings.json，Obsidian 目录里多一个文件可接受）。
class AppSettings {
  /// 通知时间段（多段式，分钟数对 [start, end)，§7.2/决议 4）。
  /// 空 = 不限制（原样送达）。
  final List<List<int>> notificationWindows;

  /// **调度模式**（决议 43，v1.12）：**完整 / 标准 / 无排序**三档选一个，
  /// 逐级弱化算法替人做主的程度（无排序 = 标准的再弱化版）。默认标准。
  ///
  /// 落 settings.json 的 `schedule_mode`；旧字段 `reminder_mode` 仍可读
  /// （standard / full 两个值一个不落，见 [fromJson]）。
  ///
  /// 三档都只改"清单怎么排、出不出声"，与 [notificationWindows]
  /// （何时允许打扰）是**串联**关系，不是互斥。
  final ScheduleMode scheduleMode;

  /// 可选闹钟模式（决议 3/18）：只对时点性提醒生效。
  final bool alarmMode;

  /// 定期挑开关与间隔天数（决议 8，默认一天）。
  final bool pickEnabled;
  final int pickIntervalDays;

  /// 疑问笔记文件路径（§6.2）。
  final String? notesPath;

  /// 首次引导是否已看过（决议 21）。
  final bool guideSeen;

  /// 定期挑上次执行日期（yyyy-MM-dd）；手动挑过的日子自动挑让位。
  final String? lastPickDate;

  /// 周期任务是否在任务池计划段显示（§9 第 6 条 / 决议 27）。
  final bool routineShowInPool;

  /// 主题预设 id（§8：v1 橙主题为默认；其余预设只换强调色种子）。
  final String themePreset;

  /// 明暗模式（§8）：跟随系统 / 浅色 / 深黑，一组三选一。**默认跟随系统**。
  ///
  /// 与 [themePreset] 正交——预设换**强调色种子**，明暗换**中性底与明度**
  /// （深色底 = 暖深褐黑，不是纯黑）。落 settings.json 的 `theme_mode`；
  /// 老设置文件缺此键即默认值，向后兼容。
  ///
  /// 同 [themePreset]：application 只存稳定 id，枚举与 `ThemeMode` 映射在
  /// UI 层（ui/theme.dart 的 `AppThemeMode`）——设置形状不依赖 Flutter。
  final String themeMode;

  /// 侧边栏宽度（逻辑像素；可拖拽调整，松手落盘，口径见 ui-interaction.md §6.0）。
  /// null = 用默认公式 min(0.80 × 屏宽, 360)；老设置文件缺 `panel_width`
  /// 键即此态，向后兼容。
  final double? panelWidth;

  /// 侧边栏高度（逻辑像素；同 [panelWidth]）。null = 默认 0.85 × 可用高度
  /// （屏高 − 上下安全区 − 上下贴靠 inset）。
  final double? panelHeight;

  /// 侧边栏尺寸是否**固定**（§6.0 / §9 第 11 条）。true = 两条改尺寸的把手
  /// 撤掉（底边那条不渲染、内侧竖条换成跟手收起把手），宽高按 [panelWidth] /
  /// [panelHeight] 的现值走，不再随屏宽/横竖屏按默认公式变。
  ///
  /// 落 settings.json 的 `panel_size_locked`，默认不锁。锁上时 UI 层会把此刻
  /// 生效的宽高算成数字写进 [panelWidth] / [panelHeight]（"固定当前的"——
  /// 之前没拖过的话就是把默认公式的结果冻住）；解锁只清这个开关，数值留着。
  ///
  /// 与 [handleLocked] 是两件事：一个锁**把手的竖向位置**，一个锁**面板宽高**。
  final bool panelSizeLocked;

  /// 把手位置是否**上锁**（§6.0）。true = 把手钉在当前高度，竖向拖动不再改变它
  /// （长按换左右边、横拖拉开、点按展开都照旧）。默认不锁。
  ///
  /// 落 settings.json 的 `handle_locked`；系统级把手与应用内把手一起锁。
  final bool handleLocked;

  /// 侧边栏展开后默认停在哪一页（§6.0 / §9 第 12 条）。默认今日清单。
  ///
  /// 存页的**稳定 id**（`today` / `notes` / `pool` / `completed`），与页序无关
  /// ——页序再调一次，旧设置仍指向同一页。application 只存字符串，认不出这个
  /// id 时由 UI 层回落今日清单（同 [themePreset] / [themeMode] 的老规矩）。
  final String defaultPage;

  /// **把手热区宽度**（dp，§6.0 / §9 第 10 条）：白条只有 6dp 宽，能起手靠的是
  /// 外面这块透明热区。选的就是"好抓"与"不挡路"的折中点——热区是 overlay 窗口
  /// （系统级）或设置页留白上的一层（应用内），它盖住的触摸归把手，越宽越好抓、
  /// 越挡路。两处把手共用同一个值。
  ///
  /// 落 settings.json 的 `handle_hot_width`；缺省 [defaultHandleHotWidth]，
  /// 读取时夹在 [minHandleHotWidth, maxHandleHotWidth] 之间（手改坏了也不越界）。
  /// **高度不是设置项**：200dp 是系统"每边最多兑现 200dp 手势排除"的配额上限，
  /// 调小只是自损竖拖起手的容错。
  final int handleHotWidth;

  const AppSettings({
    this.notificationWindows = const [[9 * 60, 21 * 60]],
    this.scheduleMode = ScheduleMode.standard,
    this.alarmMode = false,
    this.pickEnabled = false,
    this.pickIntervalDays = 1,
    this.notesPath,
    this.guideSeen = false,
    this.lastPickDate,
    this.routineShowInPool = true,
    this.themePreset = 'orange',
    this.themeMode = 'system',
    this.panelWidth,
    this.panelHeight,
    this.panelSizeLocked = false,
    this.handleLocked = false,
    this.defaultPage = 'today',
    this.handleHotWidth = defaultHandleHotWidth,
  });

  static const AppSettings defaults = AppSettings();

  AppSettings copyWith({
    List<List<int>>? notificationWindows,
    ScheduleMode? scheduleMode,
    bool? alarmMode,
    bool? pickEnabled,
    int? pickIntervalDays,
    String? notesPath,
    bool? guideSeen,
    String? lastPickDate,
    bool? routineShowInPool,
    String? themePreset,
    String? themeMode,
    double? panelWidth,
    double? panelHeight,
    bool? panelSizeLocked,
    bool? handleLocked,
    String? defaultPage,
    int? handleHotWidth,
    bool clearNotesPath = false,
    bool clearLastPickDate = false,
    bool clearPanelWidth = false,
    bool clearPanelHeight = false,
  }) {
    return AppSettings(
      notificationWindows: notificationWindows ?? this.notificationWindows,
      scheduleMode: scheduleMode ?? this.scheduleMode,
      alarmMode: alarmMode ?? this.alarmMode,
      pickEnabled: pickEnabled ?? this.pickEnabled,
      pickIntervalDays: pickIntervalDays ?? this.pickIntervalDays,
      notesPath: clearNotesPath ? null : (notesPath ?? this.notesPath),
      guideSeen: guideSeen ?? this.guideSeen,
      lastPickDate:
          clearLastPickDate ? null : (lastPickDate ?? this.lastPickDate),
      routineShowInPool: routineShowInPool ?? this.routineShowInPool,
      themePreset: themePreset ?? this.themePreset,
      themeMode: themeMode ?? this.themeMode,
      panelWidth: clearPanelWidth ? null : (panelWidth ?? this.panelWidth),
      panelHeight: clearPanelHeight ? null : (panelHeight ?? this.panelHeight),
      panelSizeLocked: panelSizeLocked ?? this.panelSizeLocked,
      handleLocked: handleLocked ?? this.handleLocked,
      defaultPage: defaultPage ?? this.defaultPage,
      handleHotWidth: handleHotWidth ?? this.handleHotWidth,
    );
  }

  Map<String, Object?> toJson() => {
        'notification_windows': notificationWindows,
        'schedule_mode': scheduleMode.name,
        'alarm_mode': alarmMode,
        'pick_enabled': pickEnabled,
        'pick_interval_days': pickIntervalDays,
        if (notesPath != null) 'notes_path': notesPath,
        'guide_seen': guideSeen,
        if (lastPickDate != null) 'last_pick_date': lastPickDate,
        'routine_show_in_pool': routineShowInPool,
        'theme_preset': themePreset,
        'theme_mode': themeMode,
        if (panelWidth != null) 'panel_width': panelWidth,
        if (panelHeight != null) 'panel_height': panelHeight,
        'panel_size_locked': panelSizeLocked,
        'handle_locked': handleLocked,
        'default_page': defaultPage,
        'handle_hot_width': handleHotWidth,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final windows = (json['notification_windows'] as List<Object?>?)
        ?.map((w) => (w as List<Object?>).map((e) => (e as num).toInt()).toList())
        .where((w) => w.length == 2 && w[0] < w[1])
        .toList();
    return AppSettings(
      notificationWindows:
          windows == null || windows.isEmpty ? const [[9 * 60, 21 * 60]] : windows,
      // 兼容 v1.11 及更早的 reminder_mode：只有 standard / full 两个值，
      // 正好是三档里的前两档；没有 manual 这个旧值，不会撞车。
      scheduleMode: ScheduleMode.byName((json['schedule_mode'] ??
              json['reminder_mode']) as String?),
      alarmMode: json['alarm_mode'] == true,
      pickEnabled: json['pick_enabled'] == true,
      pickIntervalDays: (json['pick_interval_days'] as num?)?.toInt() ?? 1,
      notesPath: json['notes_path'] as String?,
      guideSeen: json['guide_seen'] == true,
      lastPickDate: json['last_pick_date'] as String?,
      routineShowInPool: json['routine_show_in_pool'] != false,
      themePreset: (json['theme_preset'] as String?) ?? 'orange',
      themeMode: (json['theme_mode'] as String?) ?? 'system',
      panelWidth: (json['panel_width'] as num?)?.toDouble(),
      panelHeight: (json['panel_height'] as num?)?.toDouble(),
      panelSizeLocked: json['panel_size_locked'] == true,
      handleLocked: json['handle_locked'] == true,
      defaultPage: (json['default_page'] as String?) ?? 'today',
      handleHotWidth: clampHandleHotWidth(json['handle_hot_width']),
    );
  }
}

/// 引导配置（"先有鸡还是先有蛋"）：任务目录本身是可选的，所以"任务目录是
/// 哪个"不能存在任务目录下的 settings.json，而是存在应用文档目录的
/// bootstrap.json（[BootstrapPort]，组装点在读取任何设置之前先读它）。
class BootstrapConfig {
  final String? taskDir;

  const BootstrapConfig({this.taskDir});

  Map<String, Object?> toJson() => {if (taskDir != null) 'task_dir': taskDir};

  factory BootstrapConfig.fromJson(Map<String, Object?> json) =>
      BootstrapConfig(taskDir: json['task_dir'] as String?);
}

abstract class BootstrapPort {
  Future<BootstrapConfig> load();

  Future<void> save(BootstrapConfig config);
}

abstract class SettingsPort {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// JSON 编解码助手（供实现复用与测试）。
String encodeSettings(AppSettings s) => jsonEncode(s.toJson());

AppSettings decodeSettings(String raw) =>
    AppSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
