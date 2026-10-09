import '../domain/reminder.dart';

/// 交付类插座（§4.2）：application 定义形状，平台适配器实现，组装点装配。
/// 适配器无自主权——只执行"取消旧的、挂新的"，不得自行重排或补挂。

/// 通知渠道：normal = 普通通知；alarm = 闹钟渠道（全屏 + 持续响铃，媒体静音压不住）。
/// 只对时点性提醒生效（不可推到点 + 设了响的周期任务）；可推的 Slack 软提醒永远 normal。
enum ReminderChannel { normal, alarm }

/// 平台权限（安卓为主）。被拒时调用方按 UI 文档 §11 降级。
enum PermissionKind {
  notifications,      // 通知
  exactAlarm,         // 精确闹钟（安卓 12+）
  batteryExemption,   // 电池优化白名单（Doze 会吞闹钟）
  overlayWindow,      // 悬浮侧边栏（SYSTEM_ALERT_WINDOW）
  showOnLockScreen,   // 全屏提醒（锁屏/上层显示）
  folderAccess,       // 任务目录（所有文件访问 或 SAF）
}

/// 通知上的快捷按钮（如 done / snooze1h）。
class NotificationAction {
  final String id;
  final String label;

  const NotificationAction({required this.id, required this.label});
}

/// 一次已呈现的提醒（桌面的"托盘"就是应用窗口：适配器回流给 UI 渲染）。
class ShownNotification {
  final ReminderEvent event;
  final List<NotificationAction> actions;
  final ReminderChannel channel;
  final bool fullScreen;

  const ShownNotification({
    required this.event,
    this.actions = const [],
    this.channel = ReminderChannel.normal,
    this.fullScreen = false,
  });
}

/// 闹钟到点时要交付的内容草案（§4.3）。
///
/// 桌面不需要它（到点后由应用程序自己 show）；**安卓需要**：系统闹钟到点时
/// 应用可能已被杀，原生接收器只能照着挂闹钟时留下的草案自己弹通知——
/// 因此 ReminderDispatcher 在 `scheduleNext` 时就要把标题/渠道/按钮定下来。
class ReminderDraft {
  final String taskId;
  final String title;
  final String? body;
  final ReminderChannel channel;
  final bool fullScreen;
  final List<NotificationAction> actions;

  const ReminderDraft({
    required this.taskId,
    required this.title,
    this.body,
    this.channel = ReminderChannel.normal,
    this.fullScreen = false,
    this.actions = const [],
  });
}

abstract class NotificationPort {
  /// 呈现一条提醒。安卓 = 系统通知（fullScreen 时走 full-screen intent）；
  /// 桌面 = 应用内弹窗（经 [shown] 回流）。[draft] 提供标题/正文等交付内容，
  /// 系统通知实现（没法自己查任务）用它渲染文案。
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,
    ReminderDraft? draft,
  });

  /// 已呈现的提醒流（UI 渲染用）。系统通知实现可返回空流（事件为空）。
  Stream<ShownNotification> get shown;
}

/// 系统闹钟插座。全局任一时刻只挂一个下一站闹钟（§4.3）。
abstract class AlarmPort {
  /// 挂下一站闹钟。[draft] 供"应用被杀时也能自己弹通知"的实现使用（安卓）。
  Future<void> scheduleNext(DateTime at, String taskId, {ReminderDraft? draft});

  Future<void> cancel();

  /// 到点事件（taskId）。安卓 = 系统闹钟回调转发；桌面 = Timer。
  Stream<String> get fired;
}

/// 目录/文件选择（安卓 SAF / 桌面系统选择器）。
abstract class FolderPickerPort {
  Future<String?> pickDirectory();
}

/// 权限申请与查询。
abstract class PermissionPort {
  /// 申请（必要时弹系统界面）；被拒返回 false，调用方优雅降级。
  Future<bool> ensure(PermissionKind kind);

  /// 只查询当前是否已授予（设置页展示用，不弹界面）。
  Future<bool> granted(PermissionKind kind);
}
