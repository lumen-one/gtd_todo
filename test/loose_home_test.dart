import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 散件的家（metadata `loose_home`）：无排序档把 ⑥ 里的单件搬进任务池散件段，
/// 长期有效、切档不迁移（分区口径在 [buildTodayView] / [buildPoolView]，
/// 见 `schedule_mode_test.dart`）。
void main() {
  late Directory tmp;
  late TaskService svc;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gtd_loose_home');
    svc = TaskService(
      repo: MarkdownTaskRepository(tmp.path),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
    );
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('搬到池子写 loose_home，搬回今日删键；两次都真的落盘', () async {
    final events = <DomainEventType>[];
    final sub = svc.events.listen((e) => events.add(e.type));
    addTearDown(sub.cancel);

    final t = await svc.createTask(title: '收拾房间');
    expect(t.looseHomeIsPool, isFalse);

    await svc.setLooseHome(t.id, pool: true);
    expect(svc.byId(t.id)!.looseHomeIsPool, isTrue);
    // 换个 service 从盘读回来：登记表漏了这个键的话，"搬回来"那一步删不掉
    // 文件里那一行（删键后下次读回来又出现），这里会红。
    expect((await MarkdownTaskRepository(tmp.path).getTask(t.id))!
        .looseHomeIsPool, isTrue);

    await svc.setLooseHome(t.id, pool: false);
    expect(svc.byId(t.id)!.looseHomeIsPool, isFalse);
    expect((await MarkdownTaskRepository(tmp.path).getTask(t.id))!
        .looseHomeIsPool, isFalse);

    // 每条命令后面还会跟一条 scheduleReanchored，这里只数搬家事件本身。
    expect(events.where((e) => e == DomainEventType.looseHomeChanged),
        hasLength(2));
  });
}
