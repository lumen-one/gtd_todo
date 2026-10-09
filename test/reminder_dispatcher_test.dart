import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/delivery.dart';
import 'package:gtd_todo/application/notification_window.dart';
import 'package:gtd_todo/application/reminder_dispatcher.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/reminder.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/platform/desktop_adapters.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 假闹钟：记录预约，测试里手动触发 fired。
class _FakeAlarm implements AlarmPort {
  DateTime? scheduledAt;
  String? taskId;
  ReminderDraft? draft;
  int cancels = 0;
  final _fired = StreamController<String>.broadcast();

  @override
  Future<void> scheduleNext(DateTime at, String id,
      {ReminderDraft? draft}) async {
    scheduledAt = at;
    taskId = id;
    this.draft = draft;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Stream<String> get fired => _fired.stream;

  void fire() {
    _fired.add(taskId ?? '');
  }
}

/// 假通知端口：记录 show 调用。
class _FakeNotifications implements NotificationPort {
  final shownList = <ShownNotification>[];

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    shownList.add(ShownNotification(
      event: event,
      actions: actions,
      channel: channel,
      fullScreen: fullScreen,
    ));
  }

  @override
  Stream<ShownNotification> get shown => const Stream.empty();
}

void main() {
  late MemoryTaskRepository repo;
  late TaskService svc;
  late _FakeAlarm alarm;
  late _FakeNotifications notifications;
  var now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  setUp(() {
    repo = MemoryTaskRepository();
    now = DateTime(2026, 10, 7, 16, 0);
    svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
    alarm = _FakeAlarm();
    notifications = _FakeNotifications();
  });

  Future<ReminderDispatcher> startDispatcher({
    NotificationWindowRule windows = NotificationWindowRule.defaultRule,
  }) async {
    final d = ReminderDispatcher(
      service: svc,
      alarm: alarm,
      notifications: notifications,
      windows: windows,
    );
    await d.start();
    return d;
  }

  test('重锚 → 挂唯一闹钟；默认送达窗口内原样时刻', () async {
    final d = await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0), // 2h 后
      estimatedWorkMinutes: 60,
    );
    // nextReminderAt = 16:30（默认窗口 9:00-21:00 内 → 原样）
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));
    expect(alarm.taskId, isNotNull);
    expect(alarm.cancels, greaterThanOrEqualTo(1));
    expect(d, isNotNull);
  });

  test('nextReminderAt 落在静默段 → 顺延到段首（不吞掉）', () async {
    // 用只有晚间段的窗口：nextReminderAt=16:30 落在段外 → 顺延到 19:00
    const evening = NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 19, 0));
  });

  test('闹钟到点 → pollReminder → NotificationPort.show 带 actions', () async {
    await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 16, 30); // 到点
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(1));
    expect(notifications.shownList.first.event.schedule.nextTaskId, isNotNull);
    expect(
      notifications.shownList.first.actions.map((a) => a.id),
      containsAll(['done', 'snooze1h']),
    );
  });

  test('到点但任务已不due（竞态）→ 重排而非误报', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    final scheduledBefore = alarm.scheduledAt;

    // 闹钟到点前任务已完成 → pollReminder 返回 null → 重新排程
    await svc.completeTask(a.id);
    now = scheduledBefore!.add(const Duration(minutes: 1));
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty);
  });

  test('TimerAlarmPort 冒烟：过期时刻立即触发', () async {
    final port = TimerAlarmPort();
    final fired = port.fired.first.timeout(const Duration(seconds: 2));
    await port.scheduleNext(DateTime.now().subtract(const Duration(minutes: 1)), 't1');
    expect(await fired, 't1');
    await port.cancel();
  });
}
