import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/main.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';

void main() {
  testWidgets('任务列表能显示 Markdown 里的任务', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_widget_test');
    addTearDown(() {
      // Windows 下偶发 errno=32（索引器/杀毒瞬时占用），清理失败可忽略
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final repo = MarkdownTaskRepository(tmp.path);
    final svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 16, 0),
    );
    // testWidgets 运行在 FakeAsync 区：真实文件 IO 必须包进 runAsync，否则挂死
    await tester.runAsync(() async {
      await repo.save(Task(
        id: 'task-100',
        title: '写周报',
        deadline: DateTime(2026, 10, 9, 18, 0),
        estimatedWork: 60,
        created: DateTime(2026, 10, 7, 15, 0),
      ));
      await svc.refreshSchedule();
    });

    await tester.pumpWidget(GtdTodoApp(
      controller: AppController(service: svc, taskDir: tmp.path),
    ));

    expect(find.text('动态任务调度 Todo'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    expect(find.textContaining('下次提醒'), findsWidgets);
  });
}
