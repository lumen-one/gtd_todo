import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/delivery.dart';
import 'package:gtd_todo/application/notification_window.dart';
import 'package:gtd_todo/application/plan_service.dart';
import 'package:gtd_todo/application/reminder_dispatcher.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/plan.dart';
import 'package:gtd_todo/domain/reminder.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/platform/desktop_adapters.dart';
import 'package:gtd_todo/repository/memory_plan_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 假闹钟：记录预约，测试里手动触发 fired。
class _FakeAlarm implements AlarmPort {
  DateTime? scheduledAt;
  String? taskId;
  ReminderDraft? draft;
  int cancels = 0;
  final _fired = StreamController<FiredAlarm>.broadcast();

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
  Stream<FiredAlarm> get fired => _fired.stream;

  /// 触发一次到点。[delivered] = 系统侧已经弹过通知（安卓原生接收器）。
  void fire({bool delivered = false}) {
    _fired.add(FiredAlarm(taskId ?? '', delivered: delivered));
  }
}

/// 假通知端口：记录 show 调用。
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
      event: event,
      actions: actions,
      channel: channel,
      fullScreen: fullScreen,
      draft: draft,
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
      // 本文件测的是"响了之后的送达链路"，所以用**完整模式**；
      // 标准模式（默认）的门槛另有 task_service_test / slack_priority_scheduler_test 覆盖。
      scheduleMode: ScheduleMode.full,
      clock: () => now,
    );
    alarm = _FakeAlarm();
    notifications = _FakeNotifications();
  });

  Future<ReminderDispatcher> startDispatcher({
    NotificationWindowRule windows = NotificationWindowRule.defaultRule,
    PlanService? plans,
  }) async {
    final d = ReminderDispatcher(
      service: svc,
      alarm: alarm,
      notifications: notifications,
      plans: plans,
      windows: windows,
    );
    await d.start();
    return d;
  }

  /// 编排（第三个提醒源）：一天里排几条，挂进分发器。
  Future<PlanService> startPlans(List<PlanEntry> entries, {int day = 7}) async {
    final plans = PlanService(
      repo: MemoryPlanRepository([
        DayPlan(day: DateTime(2026, 10, day), entries: entries),
      ]),
    );
    await plans.load();
    return plans;
  }

  test('编排条目占站点：准点、静音、没有按钮（不吃通知时间段）', () async {
    // 晚间窗口 19:00–21:00：软提醒会被顺延，编排条目原样响。
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(windows: evening, plans: plans);

    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 0));
    expect(isPlanReminderId(alarm.taskId!), isTrue);
    expect(alarm.draft!.title, '项目评审');
    expect(alarm.draft!.body, '编排 10-07 17:00');
    expect(alarm.draft!.channel, ReminderChannel.silent);
    expect(alarm.draft!.actions, isEmpty, reason: '能推迟的是任务，编排只排不做');
  });

  test('编排到点 → 一条静音消息，然后排下一条', () async {
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
      PlanEntry(title: '写周报', minutesOfDay: 18 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 17, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(1));
    final shown = notifications.shownList.first;
    expect(shown.channel, ReminderChannel.silent);
    expect(shown.actions, isEmpty);
    expect(shown.draft!.title, '项目评审', reason: '条目没有任务可查，只能照草案渲染');
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 18, 0),
        reason: '响完这一站就排下一条');
  });

  test('编排与任务撞在同一刻：编排占站点，到点两条都弹', () async {
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 0),
    );
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    final planId = alarm.taskId!;
    expect(isPlanReminderId(planId), isTrue, reason: '同一刻编排先占站点');

    now = DateTime(2026, 10, 7, 17, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final ids = notifications.shownList.map((s) => s.event.taskId).toList();
    expect(ids, containsAll(<String>[planId, meeting.id]));
  });

  test('编排条目改时刻 → 重挂下一站（变更信号）', () async {
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 0));

    await plans.addEntry(
      DateTime(2026, 10, 7),
      const PlanEntry(title: '提前的评审', minutesOfDay: 16 * 60 + 30),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));
    expect(alarm.draft!.title, '提前的评审');
  });

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

  test('顺延之后的软提醒不能挤掉更早的时点闹钟（比早晚要用送达时刻）', () async {
    // 软提醒锚点 16:30，被晚间窗口顺延到 19:00；时点提醒在 18:00。
    // 拿未顺延的 16:30 去比，会选中软提醒 → 今晚的闹钟被跳过。
    const evening = NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    final soft = await svc.createTask(
      title: '软提醒',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);

    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 18, 0));
    expect(alarm.taskId, meeting.id, reason: '时点提醒更早，先挂它');
    expect(alarm.taskId, isNot(soft.id));
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
    expect(notifications.shownList.first.event.schedule!.nextTaskId, isNotNull);
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

  // 无排序档不跑调度（决定卡 mode-as-information-depth）：提醒是两站时点型
  // （提前一站 + 到点一站），所以它不吃通知时间段，也不按裕度节奏推下一轮。
  test('无排序档先挂提前那一站：即使落在静默段也原样响', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    // 截止前 30 分钟 = 17:30，在晚间段之外——这一档不走送达策略
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 30));
    expect(alarm.taskId, a.id);
    expect(alarm.draft!.body, '截止 10-07 18:00', reason: '不问工时就不报剩余');
  });

  // 投递只做一次（§4.3）：安卓原生接收器在回调之前就弹过通知了。
  test('原生已投递时不 show：只记账 + 重排', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 30));

    // 应用被杀时原生弹过这一条，事件等下次启动 drainEvents 才补到 Dart
    now = DateTime(2026, 10, 7, 17, 55);
    alarm.fire(delivered: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty,
        reason: '同 id 再投一次不是"无害替换"：会重新响铃、把通知时刻刷成现在');
    expect(svc.byId(a.id)!.pointFiredMark,
        DateTime(2026, 10, 7, 17, 30).toIso8601String(),
        reason: '幂等标记照样要落下，否则下次还会再响');
  });

  test('系统没弹成（权限被拒 / 桌面 Timer）时由 Dart 补投', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    now = DateTime(2026, 10, 7, 17, 30);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifications.shownList, hasLength(1));
  });

  test('无排序档：提前站早于创建 → 整站不排，只挂截止站', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await svc.updateManualLead(60);
    await startDispatcher();
    // 现在 16:00，截止 16:40：lead = 15:40 已经是过去 → 取截止 16:40
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 16, 40),
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 40));
    expect(alarm.taskId, a.id);
  });

  test('TimerAlarmPort 冒烟：过期时刻立即触发', () async {
    final port = TimerAlarmPort();
    final fired = port.fired.first.timeout(const Duration(seconds: 2));
    await port.scheduleNext(DateTime.now().subtract(const Duration(minutes: 1)), 't1');
    expect((await fired).taskId, 't1');
    await port.cancel();
  });
}
