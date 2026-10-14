// 控制台仿真：不启动 Flutter，用注入时钟重放一遍核心循环，
// 验证"任务 + 截止时间 + 工作量 + 工作时间 + 用户行为 → 动态提醒"成立。
// 同时演示领域事件流（§3.3）。
//
// 运行：dart run example/simulation.dart
// ignore_for_file: avoid_print

import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String fmt(DateTime d) =>
    '${d.month}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}'
    '（周${['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}）';

void printSchedule(TaskService svc, String label) {
  final s = svc.lastSchedule!;
  print('── $label   时刻 ${fmt(s.computedAt)}');
  for (final m in s.items) {
    final t = svc.byId(m.taskId)!;
    final flag = m.displayStatus == TaskDisplayStatus.normal
        ? ''
        : ' <${m.displayStatus.name}>';
    print(
      '  ${t.title.padRight(10)} 剩余${t.remainingWork.toString().padLeft(4)}分'
      ' | 可用${m.availableMinutes.toString().padLeft(5)}'
      ' | 裕度${m.slackMinutes.toString().padLeft(5)}'
      ' | 风险${(m.risk * 100).toStringAsFixed(0).padLeft(3)}%'
      ' | 优先级${m.priority.toStringAsFixed(2).padLeft(6)}'
      ' | 间隔${(m.intervalMinutes?.toString() ?? '—').padLeft(4)}分'
      ' | 下次提醒${m.reminderAt == null ? '  —      ' : fmt(m.reminderAt!)}'
      '$flag',
    );
  }
  final next = svc.byId(s.nextTaskId ?? '');
  print('  ▶ 建议先做：${next?.title ?? '—'}'
      '    全局下次提醒：${s.nextReminderAt == null ? '—' : fmt(s.nextReminderAt!)}');
  if (s.infeasibleTaskIds.isNotEmpty) {
    print('  ⚠ 不可行：${s.infeasibleTaskIds.map((id) => svc.byId(id)?.title).join('、')}'
        ' —— 请改截止期 / 砍范围 / 加班');
  }
  print('');
}

Future<void> main() async {
  final repo = MemoryTaskRepository();
  var now = DateTime(2026, 10, 7, 15, 40); // 周三下午
  final svc = TaskService(
    repo: repo,
    // v1.9 默认算法 = 时间裕度优先（priority = risk × importance）。
    scheduler: const SlackPriorityScheduler(),
    workRule: WorkTimeRule.standard,
    // 仿真演示的是"动态提醒"这条链路，所以用完整模式（默认是标准模式 = 不提醒）。
    scheduleMode: ScheduleMode.full,
    clock: () => now,
  );
  final events = <DomainEvent>[];
  svc.events.listen(events.add);
  print('工作日历：周一至五 09:00-12:00、13:30-18:00（周末与午休不算工时）\n');

  final report = await svc.createTask(
    title: '写季度报告',
    deadline: DateTime(2026, 10, 8, 18, 0),
    estimatedWorkMinutes: 180,
    importance: 4,
  );
  await svc.createTask(
    title: '准备周会汇报',
    deadline: DateTime(2026, 10, 9, 18, 0),
    estimatedWorkMinutes: 60,
    importance: 2,
  );
  await svc.createTask(
    title: '整理任务模板',
    deadline: DateTime(2026, 10, 14, 18, 0),
    estimatedWorkMinutes: 45,
    importance: 1,
  );
  printSchedule(svc, 'T0 创建三个任务');

  now = now.add(const Duration(minutes: 30));
  await svc.refreshSchedule(origin: EventOrigin.system);
  printSchedule(svc, 'T1 半小时后重新看一眼（裕度变小，间隔变短）');

  await svc.snoozeTask(report.id, minutes: 60); // D8：自然时间
  printSchedule(svc, 'T2 推迟「写季度报告」60 分钟 → 宽松任务自动顶上');

  await svc.logWork(report.id, minutes: 30);
  printSchedule(svc, 'T3 给「写季度报告」干了 30 分钟 → 剩余减少、静默解除、间隔拉长');

  now = DateTime(2026, 10, 8, 17, 30); // 周四下班前半小时
  await svc.refreshSchedule(origin: EventOrigin.system);
  printSchedule(svc, 'T4 次日 17:30 —— 富余耗尽，进入临界/不可行升级');

  print('领域事件流（共 ${events.length} 条，前 8 条）：');
  for (final e in events.take(8)) {
    final title = svc.byId(e.taskId)?.title ?? '(全局)';
    print('  ${fmt(e.at)}  origin=${e.origin.name.padRight(6)} '
        '${e.type.name.padRight(19)} $title');
  }

  // 默认模式是**标准**（只排列不提醒）：同一批任务，一个"下一站"都没有，
  // 但顺序、锚点（今日清单准入）照旧——差别只在"出不出声"（决议 38）。
  await svc.updateScheduleMode(ScheduleMode.standard);
  printSchedule(svc, '切回默认的标准模式（只排列不提醒）');
}
