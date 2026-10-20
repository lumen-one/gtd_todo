import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

/// 时间裕度优先（v1.9 默认算法，决议 39 / D16）：
/// `risk = f(slack)` **非线性**、`priority = risk × importance`，
/// 以及两个提醒模式（D15）对"会不会出声"的门槛。
void main() {
  const rule = WorkTimeRule.standard;
  const scheduler = SlackPriorityScheduler();
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00（工作窗 13:30–18:00）

  Task task({
    required String id,
    required DateTime? deadline,
    int remaining = 60,
    int estimated = 60,
    int importance = 3,
    TaskStatus status = TaskStatus.active,
    DateTime? snoozedUntil,
    Map<String, String> metadata = const {},
  }) =>
      Task(
        id: id,
        title: id,
        deadline: deadline,
        estimatedWork: estimated,
        remainingWork: remaining,
        importance: importance,
        status: status,
        snoozedUntil: snoozedUntil,
        metadata: metadata,
        created: DateTime(2026, 10, 7, 15, 0),
      );

  DateTime wed(int h, int m) => DateTime(2026, 10, 7, h, m);

  // ---------- 风险函数（非线性） ----------

  group('risk = f(slack)：非线性', () {
    test('贴住截止 → 1；多出 τ 分钟 → 1/e；2τ → 1/e²（乘法式衰减）', () {
      expect(slackRisk(0), 1);
      expect(slackRisk(-30), 1, reason: '已经贴住或超过截止，风险封顶');
      expect(slackRisk(480), closeTo(math.exp(-1), 1e-9));
      expect(slackRisk(960), closeTo(math.exp(-2), 1e-9));
      expect(slackRisk(960), closeTo(slackRisk(480) * slackRisk(480), 1e-12),
          reason: '等比例衰减（f(2τ)=f(τ)²）是指数族的指纹——线性函数做不到');
    });

    test('单调递减且恒为正（永远不会算出 0 或负风险）', () {
      expect(slackRisk(60), greaterThan(slackRisk(120)));
      expect(slackRisk(120), greaterThan(slackRisk(480)));
      expect(slackRisk(480), greaterThan(slackRisk(4800)));
      expect(slackRisk(4800), greaterThan(0));
    });

    test('γ 调形状：裕度充足时压得更低（更平）、裕度一薄就冲得更快（更陡）', () {
      // slack = τ/2：γ=2 的风险更高（离临界近，冲得快）
      expect(slackRisk(240, gamma: 2), closeTo(math.exp(-0.25), 1e-9));
      expect(slackRisk(240, gamma: 2), greaterThan(slackRisk(240)));
      // slack = 2τ：γ=2 的风险更低（裕度充足，压得更平）
      expect(slackRisk(960, gamma: 2), closeTo(math.exp(-4), 1e-9));
      expect(slackRisk(960, gamma: 2), lessThan(slackRisk(960)));
      // 在 slack = τ 处两者相交（(slack/τ)^γ 恒为 1）
      expect(slackRisk(480, gamma: 2), closeTo(slackRisk(480), 1e-12));
    });
  });

  // ---------- 调度优先级 = risk × importance ----------

  group('priority = risk × importance', () {
    test('同截止同剩余 → 风险相同，优先级按重要度成比例', () {
      final r = scheduler.schedule(
        tasks: [
          task(id: 'hi', deadline: wed(18, 0), importance: 5),
          task(id: 'lo', deadline: wed(18, 0), importance: 1),
        ],
        now: now,
        workRule: rule,
      );
      final hi = r.metricOf('hi')!;
      final lo = r.metricOf('lo')!;
      expect(hi.risk, closeTo(lo.risk, 1e-12));
      expect(hi.priority, closeTo(lo.priority * 5, 1e-12));
      expect(r.nextTaskId, 'hi', reason: '同样紧，重要的在前');
    });

    test('裕度薄的小事仍排在重要的宽松任务前面（risk→1 时乘数盖不过）', () {
      final r = scheduler.schedule(
        tasks: [
          task(id: 'tight', deadline: wed(17, 0), remaining: 55, importance: 1),
          task(
            id: 'roomy',
            deadline: DateTime(2026, 10, 14, 18, 0),
            remaining: 60,
            importance: 5,
          ),
        ],
        now: now,
        workRule: rule,
      );
      expect(r.metricOf('tight')!.slackMinutes, 5);
      expect(r.metricOf('tight')!.priority,
          greaterThan(r.metricOf('roomy')!.priority));
      expect(r.nextTaskId, 'tight');
    });

    test('不可行单独一档：重要度最低也排在"还来得及"的前面（v1.25）', () {
      final r = scheduler.schedule(
        tasks: [
          task(id: 'infeasible', deadline: wed(17, 0), remaining: 90, importance: 1),
          task(id: 'tight', deadline: wed(18, 0), remaining: 53, importance: 5),
        ],
        now: now,
        workRule: rule,
      );
      expect(r.metricOf('infeasible')!.displayStatus,
          TaskDisplayStatus.infeasible);
      // 同池比较时 tight 的调度优先级更高（4.35 vs 1.00）——所以要靠档位而不是 priority
      expect(r.metricOf('tight')!.priority,
          greaterThan(r.metricOf('infeasible')!.priority));
      expect(r.items.first.taskId, 'infeasible');
      expect(r.nextTaskId, 'infeasible', reason: '已注定误期的事先等用户裁决');
    });
  });

  // ---------- 提醒门槛（两个模式） ----------

  group('提醒门槛（D15）', () {
    test('门槛判据：完整模式恒真；标准模式只看"是否被显式要求"', () {
      final plain = task(id: 'p', deadline: wed(18, 0));
      final asked =
          task(id: 'q', deadline: wed(18, 0), metadata: {'remind': 'true'});
      final routine = task(id: 'r',
          deadline: wed(18, 0), metadata: {'routine_remind': 'true'});

      expect(plain.reminderRequested, isFalse);
      expect(asked.reminderRequested, isTrue);
      expect(routine.reminderRequested, isTrue, reason: '规则设了响也是"被要求"');

      expect(reminderAllowed(plain, ReminderMode.full), isTrue);
      expect(reminderAllowed(plain, ReminderMode.standard), isFalse);
      expect(reminderAllowed(asked, ReminderMode.standard), isTrue);
      expect(reminderAllowed(routine, ReminderMode.standard), isTrue);
    });

    test('默认（标准模式）：顺序与锚点照算，但下一站为空 = 不出声', () {
      final r = scheduler.schedule(
        tasks: [task(id: 'a', deadline: wed(18, 0))],
        now: now,
        workRule: rule,
      );
      final m = r.metricOf('a')!;
      expect(r.nextTaskId, 'a', reason: '排列照给');
      expect(m.nextReminderAt, wed(16, 30),
          reason: '锚点照算——今日清单准入用的是它');
      expect(m.intervalMinutes, 30, reason: '节奏也照算（0.5 × slack 60）');
      expect(m.reminds, isFalse);
      expect(m.reminderAt, isNull, reason: '锚点 ∩ 门槛 = 不出声');
      expect(r.nextReminderAt, isNull);
      expect(r.nextReminderTaskId, isNull);
    });

    test('标准模式 + 这一件开了提醒 → 只有它出声；顺序不受影响', () {
      final r = scheduler.schedule(
        tasks: [
          task(id: 'quiet', deadline: wed(18, 0)),
          task(id: 'loud',
              deadline: wed(18, 0), metadata: {'remind': 'true'}),
        ],
        now: now,
        workRule: rule,
      );
      expect(r.metricOf('quiet')!.reminds, isFalse);
      expect(r.metricOf('loud')!.reminds, isTrue);
      expect(r.nextReminderAt, wed(16, 30));
      expect(r.nextReminderTaskId, 'loud');
      // 两者风险/优先级完全相同 → 顺序由 deadline/id 裁决，与门槛无关
      expect(
        r.metricOf('quiet')!.priority,
        closeTo(r.metricOf('loud')!.priority, 1e-12),
      );
    });

    test('完整模式：该响的都响，下一站取最早的一个', () {
      final r = scheduler.schedule(
        tasks: [
          task(id: 'a', deadline: wed(18, 0)), // 锚点 16:30
          task(id: 'c', deadline: DateTime(2026, 10, 8, 18, 0)), // 锚点更晚
        ],
        now: now,
        workRule: rule,
        reminderMode: ReminderMode.full,
      );
      expect(r.metricOf('a')!.reminds, isTrue);
      expect(r.metricOf('c')!.reminds, isTrue);
      expect(r.nextReminderAt, wed(16, 30));
      expect(r.nextReminderTaskId, 'a');
    });
  });

  // ---------- 派生状态与过滤（与旧算法一致） ----------

  test('逾期退出提醒循环；不可行进名单；snooze 沉底且不出声', () {
    final r = scheduler.schedule(
      tasks: [
        task(id: 'overdue', deadline: wed(15, 0), remaining: 30),
        task(id: 'infeasible', deadline: wed(17, 0), remaining: 90),
        task(
          id: 'snoozed',
          deadline: wed(18, 0),
          status: TaskStatus.snoozed,
          snoozedUntil: wed(17, 0),
        ),
      ],
      now: now,
      workRule: rule,
      reminderMode: ReminderMode.full,
    );
    expect(r.overdueTaskIds, ['overdue']);
    expect(r.metricOf('overdue')!.reminderAt, isNull);
    expect(r.infeasibleTaskIds, ['infeasible']);
    expect(r.metricOf('snoozed')!.reminds, isFalse,
        reason: '推到未来 → 现在不该响');
    expect(r.items.last.taskId, 'snoozed', reason: 'snooze 沉底');
    expect(r.nextTaskId, 'infeasible');
  });

  test('不进调度的三类：固定时点 / 散件 / 周期实例', () {
    final r = scheduler.schedule(
      tasks: [
        task(
          id: 'fixed',
          deadline: wed(18, 0),
          remaining: 0,
          estimated: 0,
          metadata: {'type': 'fixed'},
        ),
        task(id: 'loose', deadline: null),
        task(
          id: 'routine',
          deadline: wed(18, 0),
          remaining: 0,
          estimated: 0,
          metadata: {'type': 'routine', 'routine_remind': 'true'},
        ),
      ],
      now: now,
      workRule: rule,
      reminderMode: ReminderMode.full,
    );
    expect(r.items, isEmpty);
    expect(r.nextTaskId, isNull);
    expect(r.nextReminderAt, isNull);
  });

  test('参数自描述：公式里每个可调量都有 ParamSpec（τ 与 γ 在内）', () {
    final keys = scheduler.params.map((p) => p.key).toList();
    expect(
      keys,
      containsAll([
        'alpha',
        'minIntervalMinutes',
        'maxIntervalMinutes',
        'riskScaleMinutes',
        'riskGamma',
      ]),
    );
    expect(scheduler.id, 'slack-priority.v1');
    expect(scheduler.displayName, '时间裕度优先');
  });
}
