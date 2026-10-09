import 'dart:async';

import '../domain/event.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';
import 'delivery.dart';
import 'notification_window.dart';
import 'task_service.dart';

/// 单闹钟协调者（§4.3）：全局任一时刻只挂一个下一站闹钟。
///
/// 流向：TaskService 重锚（scheduleReanchored）→ alarm.cancel() →
/// 计算送达时刻 → alarm.scheduleNext()；
/// alarm.fired → TaskService.pollReminder() → NotificationPort.show(...)。
/// 适配器无自主权：只执行"取消旧的、挂新的"。
///
/// 两个提醒源（v1.5）：
/// - **Slack 软提醒**（可推任务）：经 [windows] 送达策略（段外顺延到下一段开头）；
/// - **时点性提醒**（不可推到点 + 设了响的周期实例，决议 3/18）：原样响，
///   不受静默段限制；[alarmMode] 打开时升级为闹钟渠道（全屏 + 持续响铃）。
class ReminderDispatcher {
  final TaskService service;
  final AlarmPort alarm;
  final NotificationPort notifications;

  /// 通知时间段（设置页编辑后经装配点同步，§4.3）。
  NotificationWindowRule windows;

  /// 闹钟模式（决议 18：只对时点性提醒生效；可推的 Slack 软提醒永远普通通知）。
  bool alarmMode;

  static const List<NotificationAction> defaultActions = [
    NotificationAction(id: 'done', label: '完成'),
    NotificationAction(id: 'snooze1h', label: '推迟 1 小时'),
  ];

  StreamSubscription<DomainEvent>? _events;
  StreamSubscription<String>? _fires;

  ReminderDispatcher({
    required this.service,
    required this.alarm,
    required this.notifications,
    this.windows = NotificationWindowRule.defaultRule,
    this.alarmMode = false,
  });

  /// 设置页改了送达策略：换规则并按新规则重挂下一站闹钟。
  Future<void> updateWindows(NotificationWindowRule rule) async {
    windows = rule;
    await _reschedule();
  }

  /// 设置页改了闹钟模式：重挂下一站闹钟（渠道与全屏随之改变）。
  Future<void> updateAlarmMode(bool enabled) async {
    alarmMode = enabled;
    await _reschedule();
  }

  Future<void> start() async {
    _events ??= service.events.listen((e) {
      if (e.type == DomainEventType.scheduleReanchored) {
        _reschedule();
      }
    });
    _fires ??= alarm.fired.listen((_) => _onFired());
    await _reschedule();
  }

  Future<void> dispose() async {
    await _events?.cancel();
    await _fires?.cancel();
    await alarm.cancel();
  }

  Future<void> _reschedule() async {
    final s = service.lastSchedule;
    await alarm.cancel();
    if (s == null) return;

    final point = service.nextPointReminder();
    final softAt = s.nextReminderAt;
    final softId = s.nextReminderTaskId;

    DateTime? at;
    String? taskId;
    var fullScreen = false;
    if (softAt != null &&
        softId != null &&
        (point == null || !point.at.isBefore(softAt))) {
      at = softAt; // 软提醒：经送达策略（段外顺延）
      taskId = softId;
      at = windows.resolveDelivery(at);
    } else if (point != null) {
      at = point.at; // 时点性提醒：原样响（决议 26）
      taskId = point.taskId;
      fullScreen = alarmMode;
    }
    if (at == null || taskId == null) return;

    final task = service.byId(taskId);
    // 挂闹钟时就把"到点要交付什么"定下来：安卓应用被杀时由系统闹钟
    // 自己弹通知（原生接收器照着这份草案渲染）。
    await alarm.scheduleNext(
      at,
      taskId,
      draft: ReminderDraft(
        taskId: taskId,
        title: task?.title ?? '该做这件事了',
        body: _bodyOf(task),
        channel: fullScreen ? ReminderChannel.alarm : ReminderChannel.normal,
        fullScreen: fullScreen,
        actions: defaultActions,
      ),
    );
  }

  Future<void> _onFired() async {
    final event = await service.pollReminder();
    if (event == null) {
      // 到点但已无到期任务（竞态）：重排一次即可
      await _reschedule();
      return;
    }
    final fullScreen = event.kind == ReminderKind.point && alarmMode;
    final channel =
        fullScreen ? ReminderChannel.alarm : ReminderChannel.normal;
    final task = service.byId(event.taskId);
    await notifications.show(
      event,
      actions: defaultActions,
      channel: channel,
      fullScreen: fullScreen,
      draft: ReminderDraft(
        taskId: event.taskId,
        title: task?.title ?? '该做这件事了',
        body: _bodyOf(task),
        channel: channel,
        fullScreen: fullScreen,
        actions: defaultActions,
      ),
    );
    await _reschedule(); // 链路自续：排下一站（防 Zeno：只在事件里重排）
  }

  String? _bodyOf(Task? task) {
    if (task == null) return null;
    final d = task.deadline;
    if (task.type == TaskType.flex && task.remainingWork > 0) {
      return d == null
          ? '剩余约 ${task.remainingWork} 分钟'
          : '截止 ${_fmt(d)} · 剩余约 ${task.remainingWork} 分钟';
    }
    if (d != null) {
      return task.type == TaskType.fixed ? '固定时点 ${_fmt(d)}' : '到点 ${_fmt(d)}';
    }
    return null;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) =>
      '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}
