import 'dart:async';

import '../domain/event.dart';
import '../domain/plan.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';
import 'delivery.dart';
import 'notification_window.dart';
import 'plan_service.dart';
import 'task_service.dart';

/// 单闹钟协调者（§4.3）：全局任一时刻只挂一个下一站闹钟。
///
/// 流向：TaskService 重锚（scheduleReanchored）/ PlanService 变更（changes）→
/// alarm.cancel() → 计算送达时刻 → alarm.scheduleNext()；
/// alarm.fired → （编排那一站直接弹）TaskService.pollReminder() →
/// NotificationPort.show(...)。
///
/// 适配器无自主权：只执行"取消旧的、挂新的"。
///
/// 三个提醒源：
/// - **Slack 软提醒**（截止型任务）：经 [windows] 送达策略（段外顺延到下一段开头）；
/// - **时点性提醒**（开始型到点 + 设了响的周期实例 + 无排序档的两站）：原样响，
///   不受静默段限制；[alarmMode] 打开时升级为闹钟渠道（全屏 + 持续响铃），
///   覆盖掉它本该走的那条通知栏投递；
/// - **编排条目**（`编排.md` 里有时间的一行）：准点发一条静音消息，没有按钮、不进
///   闹钟模式、不套送达策略——它说的是"到我打算动手的点了"，不是催办
///   （决定卡 2026-10-29-plan-reminder）。
///
/// **渠道只看两件事**：这条是不是时点提醒（能不能升级成闹钟）+ 任务自己的
/// metadata `remind`（有声 / 静音）。调度模式不参与——三档都提醒。编排条目例外：
/// 它恒静音，没有『响铃』这一档。
class ReminderDispatcher {
  final TaskService service;
  final AlarmPort alarm;
  final NotificationPort notifications;

  /// 编排（第三个提醒源）。null = 不挂编排提醒（未装配的壳 / 测试）。
  final PlanService? plans;

  /// 通知时间段（设置页编辑后经装配点同步，§4.3）。
  NotificationWindowRule windows;

  /// 闹钟模式（决议 18：只对时点性提醒生效；截止型的 Slack 软提醒永远普通通知）。
  bool alarmMode;

  static const List<NotificationAction> defaultActions = [
    NotificationAction(id: 'done', label: '完成'),
    NotificationAction(id: 'snooze1h', label: '推迟 1 小时'),
  ];

  StreamSubscription<DomainEvent>? _events;
  StreamSubscription<FiredAlarm>? _fires;
  StreamSubscription<void>? _planChanges;

  /// 这一次挂的是编排那一站吗（不是就不碰任务）。
  PlanReminder? _planStation;

  ReminderDispatcher({
    required this.service,
    required this.alarm,
    required this.notifications,
    this.plans,
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
    // 编排变了就重挂：代理不到这一层，条目加了/改了时刻这边不会自己知道。
    _planChanges ??= plans?.changes.listen((_) => _reschedule());
    _fires ??= alarm.fired.listen(_onFired);
    await _reschedule();
  }

  Future<void> dispose() async {
    await _events?.cancel();
    await _fires?.cancel();
    await _planChanges?.cancel();
    await alarm.cancel();
  }

  Future<void> _reschedule() async {
    final s = service.lastSchedule;
    await alarm.cancel();
    _planStation = null;
    // 无排序档没有软提醒（不跑裕度），也不产出派生量；`s` 为 null 时只挂时点。
    // 那一档的截止型任务本身就走时点提醒这条链（截止前一次，见 nextPointReminder）。
    final manual = service.isManualSort;
    final point = service.nextPointReminder();
    final softAt = manual ? null : s?.nextReminderAt;
    final softId = manual ? null : s?.nextReminderTaskId;
    // 先按送达策略把软提醒的**实际送达时刻**算出来，再和时点提醒比早晚（v1.26）。
    // 拿没顺延的原始时刻去比，会把一个被顺延到次日上午的软提醒排在今晚的
    // 时点闹钟前面——那一晚的闹钟就被跳过了。
    final softDelivery = softAt == null ? null : windows.resolveDelivery(softAt);
    // 编排这一源只递未来的时刻，没有"送达策略"可言（静音，不挑时段）。
    final plan = plans?.nextReminder(service.now());

    DateTime? at;
    String? taskId;
    var pointFired = false;
    // 撞在同一时刻时按 编排 → 软提醒 → 时点 排：编排先占站点，到点那一刻照样会
    // `pollReminder`，任务那一条不会丢（反过来就会丢掉编排那一条）。
    if (plan != null &&
        (softDelivery == null || !plan.at.isAfter(softDelivery)) &&
        (point == null || !plan.at.isAfter(point.at))) {
      at = plan.at;
      taskId = plan.id;
      _planStation = plan;
    } else if (softDelivery != null &&
        softId != null &&
        (point == null || !point.at.isBefore(softDelivery))) {
      at = softDelivery; // 软提醒：已按送达策略顺延
      taskId = softId;
    } else if (point != null) {
      at = point.at; // 时点性提醒：原样响（决议 26）
      taskId = point.taskId;
      pointFired = true;
    }
    if (at == null || taskId == null) return;

    final station = _planStation;
    final task = station == null ? service.byId(taskId) : null;
    final fullScreen = pointFired && alarmMode;
    final channel =
        station != null ? ReminderChannel.silent : _channelFor(task, point: pointFired);
    // 挂闹钟时就把"到点要交付什么"定下来：安卓应用被杀时由系统闹钟
    // 自己弹通知（原生接收器照着这份草案渲染）。
    await alarm.scheduleNext(
      at,
      taskId,
      draft: ReminderDraft(
        taskId: taskId,
        title: station?.title ?? task?.title ?? '该做这件事了',
        body: station == null ? _bodyOf(task) : _planBody(station),
        channel: channel,
        fullScreen: fullScreen,
        actions: station == null ? defaultActions : const [],
      ),
    );
  }

  /// 闹钟到点。**投递只做一次**：安卓的原生接收器在回调之前就已经照着挂
  /// 闹钟时的草案弹了通知（应用被杀也照弹），所以 `delivered` 为真时这里
  /// 只记账并排下一站；再 show 一次就是同 id 替换 + 重新响铃，通知时刻被刷成
  /// "现在"——用户看到的就是"这条提醒晚了十几分钟"。
  ///
  /// 编排那一站不经过 `pollReminder`（那不是任务，没有可记账的状态）：照草案弹完就
  /// 排下一站。**同一时刻的任务提醒不受影响**——poll 照跑，撞在同一分钟时两条都到。
  Future<void> _onFired(FiredAlarm firing) async {
    final planStation = isPlanReminderId(firing.taskId) &&
            _planStation?.id == firing.taskId
        ? _planStation
        : null;
    if (planStation != null && !firing.delivered) {
      await _showPlan(planStation);
    }
    final event = await service.pollReminder();
    // delivered 说的是"刚起来的那一站已经弹过了"，不是"这一趟什么都别弹"：
    // 编排那一站弹过了，同时到点的任务提醒还没弹，所以只在任务自己那一站上跳过。
    if (event != null && !(firing.delivered && planStation == null)) {
      await _showTask(event);
    }
    await _reschedule(); // 链路自续：排下一站（防 Zeno：只在事件里重排）
  }

  Future<void> _showTask(ReminderEvent event) async {
    final point = event.kind == ReminderKind.point;
    final fullScreen = point && alarmMode;
    final task = service.byId(event.taskId);
    final channel = _channelFor(task, point: point);
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
  }

  /// 编排条目：一条消息，没有按钮、不接闹钟模式（即使设置里开着）。
  Future<void> _showPlan(PlanReminder station) async {
    final draft = ReminderDraft(
      taskId: station.id,
      title: station.title,
      body: _planBody(station),
      channel: ReminderChannel.silent,
    );
    await notifications.show(
      ReminderEvent(
        firedAt: service.now(),
        taskId: station.id,
        kind: ReminderKind.point,
      ),
      channel: ReminderChannel.silent,
      draft: draft,
    );
  }

  /// 一条提醒走哪个渠道：**闹钟模式只对时点提醒生效**，其余看任务自己的
  /// 『响铃』（metadata `remind`，缺键 = 静音）。任务查不到时按静音走——
  /// 没有主人的提醒不该吵人。
  ReminderChannel _channelFor(Task? task, {required bool point}) {
    if (point && alarmMode) return ReminderChannel.alarm;
    return (task?.ringEnabled ?? false)
        ? ReminderChannel.ring
        : ReminderChannel.silent;
  }

  String? _bodyOf(Task? task) {
    if (task == null) return null;
    final d = task.deadline;
    if (task.type == TaskType.flex) {
      // 无排序档不问工时，报"剩余 N 分钟"是拿缺省 30 分钟编出来的——只报截止。
      if (service.isManualSort) {
        return d == null ? null : '截止 ${_fmt(d)}';
      }
      // '长期'任务没有剩余工时（D18），也不会走到提醒链路（无截止 → 无锚点）；
      // ?? 0 只是让展示文案对空值安全。
      final remaining = task.remainingWork ?? 0;
      if (remaining > 0) {
        return d == null
            ? '剩余约 $remaining 分钟'
            : '截止 ${_fmt(d)} · 剩余约 $remaining 分钟';
      }
    }
    if (d != null) {
      return task.type == TaskType.fixed ? '开始 ${_fmt(d)}' : '到点 ${_fmt(d)}';
    }
    return null;
  }

  /// 编排条目的正文：只报"哪天几点"，不写"剩余"这一类调度量（条目没有工时）。
  static String _planBody(PlanReminder station) =>
      '编排 ${_fmt(station.at)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) =>
      '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}
