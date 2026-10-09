import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/delivery.dart';
import 'package:gtd_todo/application/notification_window.dart';
import 'package:gtd_todo/application/reminder_dispatcher.dart';
import 'package:gtd_todo/application/routine_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/reminder.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_routine_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 时点性提醒（决议 3/18/26）：不可推到点 + 设了响的周期实例，
/// 原样响、不受静默段限制、可选闹钟模式；只到点响一次。
class _FakeAlarm implements AlarmPort {
  DateTime? scheduledAt;
  String? taskId;
  ReminderDraft? draft;
  final _fired = StreamController<String>.broadcast();

  @override
  Future<void> scheduleNext(DateTime at, String id,
      {ReminderDraft? draft}) async {
    scheduledAt = at;
    taskId = id;
    this.draft = draft;
  }

  @override
  Future<void> cancel() async {}

  @override
  Stream<String> get fired => _fired.stream;
}

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
        event: event, actions: actions, channel: channel, fullScreen: fullScreen));
  }

  @override
  Stream<ShownNotification> get shown => const Stream.empty();
}

void main() {
  late MemoryTaskRepository repo;
  late TaskService svc;
  late RoutineService routines;
  late _FakeAlarm alarm;
  late _FakeNotifications notifications;
  var now = DateTime(2026, 10, 7, 10, 0); // 周三 10:00

  setUp(() async {
    now = DateTime(2026, 10, 7, 10, 0);
    repo = MemoryTaskRepository();
    svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
    routines = RoutineService(
      repo: MemoryRoutineRepository(),
      tasks: svc,
      clock: () => now,
    );
    await routines.load();
    alarm = _FakeAlarm();
    notifications = _FakeNotifications();
  });

  test('fixed：到点是候选；到点后 pollReminder 产出 point 事件并记 point_fired',
      () async {
    final meeting = await svc.createTask(
      title: '部门例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 14, 0),
    );
    final candidate = svc.nextPointReminder()!;
    expect(candidate.taskId, meeting.id);
    expect(candidate.at, DateTime(2026, 10, 7, 14, 0));

    now = DateTime(2026, 10, 7, 14, 0);
    final event = await svc.pollReminder();
    expect(event!.kind, ReminderKind.point);
    expect(event.taskId, meeting.id);
    expect(svc.byId(meeting.id)!.pointFiredMark,
        DateTime(2026, 10, 7, 14, 0).toIso8601String());
    expect(svc.nextPointReminder(), isNull, reason: '只到点响一次');
  });

  test('fixed：到点后 snooze = 推后本次提醒，事件时刻（deadline）不变（决议 23）',
      () async {
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 14, 0),
    );
    now = DateTime(2026, 10, 7, 14, 0); // 到点
    await svc.snoozeTask(meeting.id, minutes: 30);
    final t = svc.byId(meeting.id)!;
    expect(t.deadline, DateTime(2026, 10, 7, 14, 0), reason: '事件时刻不变');
    expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 14, 30),
        reason: '提醒取"推迟到"的时刻');

    // 事件前的小睡不影响未来的到点（snoozedUntil 早于 deadline）
    final other = await svc.createTask(
      title: '晚会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 20, 0),
    );
    await svc.snoozeTask(other.id, minutes: 30);
    final candidates =
        [svc.nextPointReminder()!.taskId, meeting.id];
    expect(candidates, contains(meeting.id));
    expect(svc.byId(other.id)!.pointReminderAt, DateTime(2026, 10, 7, 20, 0));
  });

  test('改期清掉已响标记：改到新时刻会重新响', () async {
    final task = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 14, 0),
    );
    now = DateTime(2026, 10, 7, 14, 0);
    await svc.pollReminder();
    await svc.updateTask(task.id, deadline: DateTime(2026, 10, 7, 16, 0));
    expect(svc.byId(task.id)!.pointFiredMark, isNull);
    expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 16, 0));
  });

  test('错过太久（超过补响宽限）不再响', () async {
    await svc.createTask(
      title: '早会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 9, 0),
    );
    now = DateTime(2026, 10, 7, 10, 0); // 已过 60 分钟 > 30 分钟宽限
    expect(svc.nextPointReminder(), isNull);
  });

  test('周期实例：设了响才进时点提醒（不占工时、不进软提醒）', () async {
    await routines.create(title: '晨跑', minuteOfDay: 7 * 60); // 不响
    expect(svc.nextPointReminder(), isNull);
    await svc.refreshSchedule();
    expect(svc.lastSchedule!.nextReminderAt, isNull, reason: '不占工时、不软提醒');

    await routines.create(title: '吃药', minuteOfDay: 20 * 60, remind: true);
    expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 20, 0));
  });

  group('ReminderDispatcher：送达策略与渠道（决议 18/26）', () {
    Future<ReminderDispatcher> start({bool alarmMode = false}) async {
      final d = ReminderDispatcher(
        service: svc,
        alarm: alarm,
        notifications: notifications,
        windows: const NotificationWindowRule(
            [NotificationWindow(9 * 60, 12 * 60)]), // 静默段 12:00 之后
        alarmMode: alarmMode,
      );
      await d.start();
      return d;
    }

    test('fixed 到点：原样响（不因静默段顺延）；普通渠道 + 按钮草案', () async {
      await start();
      await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 15, 0), // 静默段内
      );
      await Future<void>.delayed(Duration.zero);
      expect(alarm.scheduledAt, DateTime(2026, 10, 7, 15, 0));
      expect(alarm.draft!.title, '例会');
      expect(alarm.draft!.channel, ReminderChannel.normal);
      expect(alarm.draft!.actions.map((a) => a.id), ['done', 'snooze1h']);
    });

    test('闹钟模式：时点提醒升级为全屏闹钟渠道', () async {
      await start(alarmMode: true);
      await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 15, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(alarm.draft!.channel, ReminderChannel.alarm);
      expect(alarm.draft!.fullScreen, isTrue);
    });

    test('闹钟模式不影响 Slack 软提醒（永远是普通通知）', () async {
      await start(alarmMode: true);
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 18, 0),
        estimatedWorkMinutes: 60,
      );
      await Future<void>.delayed(Duration.zero);
      // 软提醒：nextReminderAt 落在静默段 → 顺延到下一时段开头
      expect(alarm.draft!.channel, ReminderChannel.normal);
      expect(alarm.draft!.fullScreen, isFalse);
    });
  });
}
