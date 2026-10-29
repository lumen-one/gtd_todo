import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/plan_service.dart';
import 'package:gtd_todo/domain/plan.dart';
import 'package:gtd_todo/repository/memory_plan_repository.dart';

/// 编排的第三个提醒源（决定卡 2026-10-29-plan-reminder）：
/// `PlanService.nextReminder` 只递**严格晚于现在**的最早一条。
void main() {
  final now = DateTime(2026, 10, 7, 16, 0);

  DayPlan day(int dayOfMonth, List<PlanEntry> entries) =>
      DayPlan(day: DateTime(2026, 10, dayOfMonth), entries: entries);

  Future<PlanService> started(List<DayPlan> days) async {
    final svc = PlanService(repo: MemoryPlanRepository(days));
    await svc.load();
    return svc;
  }

  test('取严格晚于现在的最早一条，过点的不补响', () async {
    final svc = await started([
      day(7, const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60),
        PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
        PlanEntry(title: '写周报', minutesOfDay: 18 * 60),
      ]),
    ]);

    final next = svc.nextReminder(now)!;
    expect(next.title, '项目评审');
    expect(next.at, DateTime(2026, 10, 7, 17, 0));
    expect(next.id, 'plan|2026-10-07|1020');
  });

  test('今天的都过完了 → 排明天的', () async {
    final svc = await started([
      day(7, const [PlanEntry(title: '晨会', minutesOfDay: 8 * 60)]),
      day(8, const [PlanEntry(title: '评审', minutesOfDay: 9 * 60)]),
    ]);

    final next = svc.nextReminder(now)!;
    expect(next.title, '评审');
    expect(next.at, DateTime(2026, 10, 8, 9, 0));
  });

  test('没有时刻的条目不提醒', () async {
    final svc = await started([
      day(7, const [PlanEntry(title: '临时插进来的事')]),
    ]);
    expect(svc.nextReminder(now), isNull);
  });

  test('同一分钟多条共用一个站点（标题取文件里的第一条）', () async {
    final svc = await started([
      day(7, const [
        PlanEntry(title: '早餐', minutesOfDay: 18 * 60),
        PlanEntry(title: '出门', minutesOfDay: 18 * 60),
      ]),
    ]);

    final next = svc.nextReminder(now)!;
    expect(next.id, 'plan|2026-10-07|1080');
    expect(next.title, '早餐');
  });

  test('命令与读盘都发变更信号（单闹钟靠它重挂）', () async {
    final svc = await started(const []);
    var signals = 0;
    final sub = svc.changes.listen((_) => signals++);

    await svc.load();
    await svc.addEntry(
      DateTime(2026, 10, 7),
      const PlanEntry(title: '会议', minutesOfDay: 17 * 60),
    );
    await Future<void>.delayed(Duration.zero);

    expect(signals, 2, reason: 'load 一次 + addEntry 一次');
    expect(svc.nextReminder(now)!.title, '会议');
    await sub.cancel();
  });

  test('提醒 id 能认出来，任务 id 不会误判', () {
    expect(isPlanReminderId('plan|2026-10-07|1020'), isTrue);
    expect(isPlanReminderId('task-001'), isFalse);
  });
}
