import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/delivery.dart';
import 'package:gtd_todo/application/notification_window.dart';
import 'package:gtd_todo/application/reminder_dispatcher.dart';
import 'package:gtd_todo/application/routine_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/reminder.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_routine_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 时点性提醒（决议 3/18/26）：开始型到点 + 设了响的周期实例，
/// 原样响、不受静默段限制、可选闹钟模式；只到点响一次。
class _FakeAlarm implements AlarmPort {
  DateTime? scheduledAt;
  String? taskId;
  ReminderDraft? draft;
  final _fired = StreamController<FiredAlarm>.broadcast();

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
  Stream<FiredAlarm> get fired => _fired.stream;
}

class _FakeNotifications implements NotificationPort {
  final shownList = <ShownNotification>[];

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
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
      // 本文件测"到点响不响"，所以用**完整模式**；标准模式（默认）的门槛
      // 由 task_service_test 覆盖。
      scheduleMode: ScheduleMode.full,
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

    test('fixed 到点：原样响（不因静默段顺延）；没开响铃 → 静音渠道', () async {
      await start();
      await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 15, 0), // 静默段内
      );
      await Future<void>.delayed(Duration.zero);
      expect(alarm.scheduledAt, DateTime(2026, 10, 7, 15, 0));
      expect(alarm.draft!.title, '例会');
      expect(alarm.draft!.channel, ReminderChannel.silent,
          reason: '缺 metadata remind = 静音，但提醒照发');
      expect(alarm.draft!.actions.map((a) => a.id), ['done', 'snooze1h']);
    });

    test('开了响铃 → 有声渠道（声与震动挂在渠道上）', () async {
      await start();
      final t = await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 15, 0),
      );
      await svc.setTaskReminder(t.id, enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(alarm.draft!.channel, ReminderChannel.ring);
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

    test('闹钟模式不影响 Slack 软提醒（永远走通知栏渠道）', () async {
      await start(alarmMode: true);
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 18, 0),
        estimatedWorkMinutes: 60,
      );
      await Future<void>.delayed(Duration.zero);
      // 软提醒：nextReminderAt 落在静默段 → 顺延到下一时段开头
      expect(alarm.draft!.channel, isNot(ReminderChannel.alarm),
          reason: '闹钟模式只管时点提醒');
      expect(alarm.draft!.fullScreen, isFalse);
    });
  });

  // 无排序档不跑调度（决定卡 mode-as-information-depth）：截止型与开始型共用
  // 一套**两站**时点提醒（`T − 提前量` 与 `T`），复用同一条链的幂等与补响宽限。
  group('无排序档：两站时点提醒（提前一站 + 到点一站）', () {
    test('第一站 = 截止 − 提前量；响铃开关不影响发不发', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final t = await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      final point = svc.nextPointReminder()!;
      expect(point.taskId, t.id);
      expect(point.at, DateTime(2026, 10, 7, 17, 30));
      expect(t.ringEnabled, isFalse, reason: '没开响铃，但照样是候选');
    });

    test('提前量可改，改完时刻跟着走', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 17, 30));
      await svc.updateManualLead(60);
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 17, 0));
    });

    test('两站依次响：提前站响完还有到点站，到点站响完就没有了', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final t = await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      now = DateTime(2026, 10, 7, 17, 30);
      var event = await svc.pollReminder();
      expect(event, isNotNull);
      expect(event!.kind, ReminderKind.point);
      expect(event.taskId, t.id);
      expect(svc.byId(t.id)!.pointFiredMark,
          DateTime(2026, 10, 7, 17, 30).toIso8601String(),
          reason: '已响的那一站按时刻落盘，两站靠先后推进区分');
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 18, 0),
          reason: '到点那一站还在');

      now = DateTime(2026, 10, 7, 18, 0);
      event = await svc.pollReminder();
      expect(event!.taskId, t.id);
      expect(svc.nextPointReminder(), isNull, reason: '两站都响过了');
    });

    test('到点前已完成：到点那一站不响', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final t = await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      now = DateTime(2026, 10, 7, 17, 40);
      await svc.completeTask(t.id);
      expect(svc.nextPointReminder(), isNull);
    });

    test('推迟优先：推到截止之后，到点那一站不再响', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final t = await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      now = DateTime(2026, 10, 7, 17, 30);
      await svc.snoozeTask(t.id, minutes: 60); // 推到 18:30
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 18, 30));

      now = DateTime(2026, 10, 7, 18, 30);
      final event = await svc.pollReminder();
      expect(event!.taskId, t.id, reason: '推迟那一刻照响');
      expect(svc.nextPointReminder(), isNull,
          reason: '截止那一站已被越过（推迟 = 这一件的最后一次）');
    });

    test('推迟到截止之前：到点那一站照响', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final t = await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      now = DateTime(2026, 10, 7, 17, 30);
      await svc.snoozeTask(t.id, minutes: 10); // 推到 17:40
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 17, 40));
      now = DateTime(2026, 10, 7, 17, 40);
      await svc.pollReminder();
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 18, 0),
          reason: '还没到截止，到点那一站仍然有效');
    });

    test('开始型也走两站；已经逾期的截止型不补响', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.createTask(
          title: '逾期了', deadline: DateTime(2026, 10, 7, 9, 0));
      final meeting = await svc.createTask(
          title: '开会',
          type: TaskType.fixed,
          deadline: DateTime(2026, 10, 7, 11, 0));
      final point = svc.nextPointReminder()!;
      expect(point.taskId, meeting.id);
      expect(point.at, DateTime(2026, 10, 7, 10, 30),
          reason: '开始型同样提前 30 分钟先响一站');
    });

    test('周期实例：这一档也只看规则的"设了响"，且只有到点一站', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await routines.create(title: '晨跑', minuteOfDay: 7 * 60); // 不响
      expect(svc.nextPointReminder(), isNull, reason: '规则没设响就不排站');

      await routines.create(title: '吃药', minuteOfDay: 20 * 60, remind: true);
      expect(svc.nextPointReminder()!.at, DateTime(2026, 10, 7, 20, 0),
          reason: '周期实例不吃提前量，只到点响一次');
    });

    test('不产出软提醒：lastSchedule 是空结果', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.createTask(
          title: '写周报', deadline: DateTime(2026, 10, 7, 18, 0));
      expect(svc.lastSchedule!.items, isEmpty);
      expect(svc.lastSchedule!.nextReminderAt, isNull);
    });
  });
}
