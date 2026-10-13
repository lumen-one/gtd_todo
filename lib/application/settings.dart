import 'dart:convert';

import '../domain/schedule.dart';

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
    bool clearNotesPath = false,
    bool clearLastPickDate = false,
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
