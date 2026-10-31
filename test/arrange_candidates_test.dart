import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/today_view.dart';
import 'package:qixing/domain/task.dart';

/// 编排 / 支线的候选来源（panels/plan.md『添加、拖动、编辑』）：
/// **不截断**——曾经两页各带一个"最多六条"，挂起件一多就把别的任务全挤出去。
void main() {
  Task task(String id, String title) =>
      Task(id: id, title: title, estimatedWork: 30, created: DateTime(2026, 10, 1));

  final suspended = [
    for (var i = 0; i < 8; i++) task('ip$i', '挂起的长期任务 $i'),
  ];
  final today = TodayView(
    day: DateTime(2026, 10, 7),
    inProgress: suspended,
    flex: [task('f1', '今天要交的')],
    routines: [task('r1', '晨跑')],
    picked: task('p1', '被挑的散件'),
    loose: [task('l1', '散件 A')],
  );
  final pool = PoolView(
    plan: [task('pl1', '下周的评审')],
    loose: [task('pl2', '池子散件')],
  );

  test('候选覆盖全部来源，不被六条截断', () {
    final out = arrangeCandidates(today: today, pool: pool);
    expect(out.map((t) => t.id), [
      ...suspended.map((t) => t.id),
      'f1',
      'r1',
      'p1',
      'l1',
      'pl1',
      'pl2',
    ]);
    expect(out.length, 14);
  });

  test('挂起组排在最前（今天该做的先出现）', () {
    final out = arrangeCandidates(today: today, pool: pool);
    expect(out.first.title, '挂起的长期任务 0');
  });

  test('支线不要例行实例：它们明天就不在', () {
    final out = arrangeCandidates(
      today: today,
      pool: pool,
      includeRoutines: false,
    );
    expect(out.map((t) => t.id), isNot(contains('r1')));
  });

  test('输入框里的字按标题筛，不分大小写、可清空', () {
    expect(filterCandidates(arrangeCandidates(today: today, pool: pool), '池子')
        .map((t) => t.id), ['pl2']);
    expect(
      filterCandidates(arrangeCandidates(today: today, pool: pool), '挂起').length,
      8,
    );
    expect(
      filterCandidates(arrangeCandidates(today: today, pool: pool), '  ').length,
      14,
    );
  });
}
