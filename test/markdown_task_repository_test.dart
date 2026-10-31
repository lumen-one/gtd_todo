import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/repository/task_document.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// 双文档存储（决议 36）的验收测试：
/// - 人类文档 `tasks.md`：一行一条任务，应用只改自己那一行；
/// - 内核属性文档 `.gtd/<id>.md`：任务id / 工作强度 / 优先级 / 时间裕度 / 剩余工作量。
void main() {
  late Directory tmp;
  late MarkdownTaskRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gtd_repo_test');
    repo = MarkdownTaskRepository(tmp.path);
  });

  tearDown(() {
    // Windows 下偶发 errno=32（索引器/杀毒瞬时占用），清理失败可忽略
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File doc() => File('${tmp.path}/tasks.md');
  File kernel(String id) => File('${tmp.path}/.gtd/$id.md');

  Task makeTask() => Task(
        id: 'task-001',
        title: '完成 Agent 调度论文阅读',
        deadline: DateTime(2026, 10, 8, 18, 0),
        estimatedWork: 120,
        remainingWork: 90,
        importance: 3,
        status: TaskStatus.active,
        created: DateTime(2026, 10, 7, 15, 30),
        description: '阅读论文并整理笔记。',
        tags: const ['工作'],
      );

  // ------------------------------------------------------------------
  // 人类文档的读
  // ------------------------------------------------------------------

  group('人类文档（tasks.md）', () {
    test('解析样例行：任务名 / 创建 / 结束 / 完成 / 备注 / 标签', () {
      const raw = '# 工作\n'
          '\n'
          '- [ ] 任务名 创建 2026-10-11,7:00 结束 2026-10-12,18:00 这是备注。 ##这是标签1 ##这是标签2\n';
      final doc = const TaskDocumentCodec().parse(raw);
      expect(doc.warnings, isEmpty);
      expect(doc.tasks, hasLength(1));
      final t = doc.tasks.single;
      expect(t.title, '任务名');
      expect(t.created, DateTime(2026, 10, 11, 7, 0));
      expect(t.deadline, DateTime(2026, 10, 12, 18, 0));
      expect(t.completed, isFalse);
      expect(t.description, '这是备注。');
      expect(t.tags, ['这是标签1', '这是标签2']);
      expect(t.section, '工作');
    });

    test('复选框 [x] 与「完成」时刻都认，且 `##` 小节标题不会被当标签', () {
      const raw = '## 生活\n'
          '- [x] 交房租 创建 2026-10-01,9:00 完成 2026-10-01,9:30 ##生活\n';
      final t = const TaskDocumentCodec().parse(raw).tasks.single;
      expect(t.completed, isTrue);
      expect(t.completedAt, DateTime(2026, 10, 1, 9, 30));
      expect(t.tags, ['生活']);
      expect(t.section, '生活');
    });

    test('备注里的「完成」二字（后无空白）不破坏字段切分', () {
      const raw = '- [ ] 写总结 创建 2026-10-11,7:00 备注 完成后交给组长 ##工作\n';
      final t = const TaskDocumentCodec().parse(raw).tasks.single;
      expect(t.title, '写总结');
      expect(t.description, '完成后交给组长');
      expect(t.completedAt, isNull);
    });

    test('缺「创建」关键字的复选框行：不改动、进 warnings', () {
      const raw = '# 工作\n\n- [ ] 随手记一笔\n- [ ] 正常任务 创建 2026-10-11,7:00\n';
      final doc = const TaskDocumentCodec().parse(raw);
      expect(doc.tasks, hasLength(1));
      expect(doc.tasks.single.title, '正常任务');
      expect(doc.warnings, hasLength(1));
      expect(doc.warnings.single, contains('缺少'));
    });

    test('围栏代码块里的示例行不算任务', () {
      const raw = '- [ ] 真的任务 创建 2026-10-11,7:00\n'
          '\n'
          '```markdown\n'
          '- [ ] 示例任务 创建 2026-10-11,7:00\n'
          '```\n';
      final doc = const TaskDocumentCodec().parse(raw);
      expect(doc.tasks, hasLength(1));
      expect(doc.tasks.single.title, '真的任务');
    });

    test('行渲染 → 解析 往返稳定（人看到的行 = 内核指纹的输入）', () {
      final task = makeTask();
      final line = TaskDocumentCodec.encodeLine(task);
      expect(line, startsWith('- [ ] 完成 Agent 调度论文阅读 创建 2026-10-07,15:30'));
      expect(line, contains('结束 2026-10-08,18:00'));
      expect(line, contains('备注 阅读论文并整理笔记。'));
      expect(line, endsWith('##工作'));

      final parsed = const TaskDocumentCodec().parse(line).tasks.single;
      expect(parsed.title, task.title);
      expect(parsed.created, task.created);
      expect(parsed.deadline, task.deadline);
      expect(parsed.description, task.description);
      expect(parsed.tags, task.tags);
      expect(parsed.digest, TaskDocumentCodec.digestFor(task));
    });

    test('没有「结束」的散件、只写日期的「结束」', () {
      const raw = '- [ ] 收拾房间 创建 2026-10-11,7:00 ##生活\n'
          '- [ ] 交报告 创建 2026-10-11,7:00 结束 2026-10-15 ##工作\n';
      final doc = const TaskDocumentCodec().parse(raw);
      expect(doc.tasks[0].deadline, isNull);
      expect(doc.tasks[1].deadline, DateTime(2026, 10, 15, 23, 59));
    });
  });

  // ------------------------------------------------------------------
  // 双文档的读回与写回
  // ------------------------------------------------------------------

  test('保存后能读回来：人类那半 + 内核那半都在', () async {
    await repo.save(makeTask());
    final loaded = await repo.loadAll();
    expect(loaded, hasLength(1));
    final t = loaded.single;
    expect(t.id, 'task-001');
    expect(t.title, '完成 Agent 调度论文阅读');
    expect(t.deadline, DateTime(2026, 10, 8, 18, 0));
    expect(t.estimatedWork, 120);
    expect(t.remainingWork, 90);
    expect(t.importance, 3);
    expect(t.status, TaskStatus.active);
    expect(t.description, '阅读论文并整理笔记。');
    expect(t.tags, ['工作']);
    expect(t.created, DateTime(2026, 10, 7, 15, 30));
  });

  test('两个文档各就各位：人写的那行干净，内核属性在 .gtd/', () async {
    await repo.save(makeTask());

    final human = doc().readAsStringSync();
    expect(human, contains('- [ ] 完成 Agent 调度论文阅读 创建 2026-10-07,15:30'));
    // 内核字段一个都不许出现在人类文档里
    for (final key in ['work_intensity', 'priority', 'time_slack', 'digest']) {
      expect(human, isNot(contains(key)));
    }

    final side = kernel('task-001').readAsStringSync();
    expect(side, contains('id: task-001'));
    expect(side, contains('work_intensity: 120'));
    expect(side, contains('priority: 3'));
    expect(side, contains('remaining_load: 0.75')); // 90 / 120
    expect(side, contains('digest: '));
  });

  test('幂等：自己的文件读进来再存回去逐字节不变', () async {
    await repo.save(makeTask());
    final human1 = doc().readAsStringSync();
    final side1 = kernel('task-001').readAsStringSync();

    final loaded = (await repo.loadAll()).single;
    await repo.save(loaded.copyWith(remainingWork: 80));
    final side2 = kernel('task-001').readAsStringSync();

    final loaded2 = (await repo.loadAll()).single;
    await repo.save(loaded2);
    expect(doc().readAsStringSync(), human1); // 无变化的人类文档：一字不动
    expect(kernel('task-001').readAsStringSync(), side2);
    expect(side2, isNot(side1)); // remaining_load 变了
  });

  test('人类文档里别人的内容（标题、空行、正文、其它待办）一字不动', () async {
    const raw = '# 工作\n'
        '\n'
        '这是我自己写的一段说明，应用别动。\n'
        '\n'
        '- [ ] 完成论文阅读 创建 2026-10-7,15:30 结束 2026-10-8,18:00 ##工作\n'
        '\n'
        '## 随手记\n'
        '\n'
        '- [ ] 买菜\n'
        '\n'
        '<!-- 我自己的注释 -->\n';
    doc().writeAsStringSync(raw);

    final loaded = (await repo.loadAll()).single;
    await repo.save(loaded.copyWith(remainingWork: 10));

    final after = doc().readAsStringSync();
    expect(after, contains('这是我自己写的一段说明，应用别动。'));
    expect(after, contains('## 随手记'));
    expect(after, contains('- [ ] 买菜'));
    expect(after, contains('<!-- 我自己的注释 -->'));
    expect(after.indexOf('这是我自己写的一段说明'), lessThan(after.indexOf('完成论文阅读')));
    // 除自己那一行之外，人类文档逐行不变（行数、空行、顺序都不动）
    final before = raw.split('\n');
    final now = after.split('\n');
    expect(now.length, before.length);
    final differing = [
      for (var i = 0; i < before.length; i++)
        if (before[i] != now[i]) i,
    ];
    expect(differing, hasLength(1));
    expect(before[differing.single], contains('完成论文阅读'));
    expect(now[differing.single], contains('完成论文阅读'));
  });

  test('内核属性文档的字段级保真：注释与未知字段原样保留', () async {
    Directory('${tmp.path}/.gtd').createSync(recursive: true);
    kernel('task-001').writeAsStringSync('''
---
# 用户给内核文档写的备注：别动
id: task-001
work_intensity: 120
remaining_load: 0.75
priority: 3
ai_note: 这是 AI 留的字段
status: active
---
''');
    doc().writeAsStringSync(
        '- [ ] 完成论文阅读 创建 2026-10-7,15:30 结束 2026-10-8,18:00 ##工作\n');

    final loaded = (await repo.loadAll()).single;
    expect(loaded.metadata['ai_note'], '这是 AI 留的字段');

    await repo.save(loaded.copyWith(remainingWork: 30));
    final raw = kernel('task-001').readAsStringSync();
    expect(raw, contains('remaining_load: 0.25'));
    expect(raw, contains('# 用户给内核文档写的备注：别动'));
    expect(raw, contains('ai_note: 这是 AI 留的字段'));
    expect(raw.indexOf('# 用户给内核文档写的备注'), lessThan(raw.indexOf('id: task-001')));
  });

  test('D9：人在 Obsidian 里改任务行 → 内核认领并同步（内核属性保留）', () async {
    await repo.save(makeTask());
    // 模拟用户在 Obsidian 里改写任务名、结束日期、备注
    final raw = doc()
        .readAsStringSync()
        .replaceFirst('完成 Agent 调度论文阅读', '完成 Agent 调度综述')
        .replaceFirst('结束 2026-10-08,18:00', '结束 2026-10-09,18:00');
    doc().writeAsStringSync(raw);

    final reloaded = MarkdownTaskRepository(tmp.path);
    final loaded = (await reloaded.loadAll()).single;

    expect(loaded.id, 'task-001'); // 还是同一条任务
    expect(loaded.title, '完成 Agent 调度综述'); // 人写的：人赢
    expect(loaded.deadline, DateTime(2026, 10, 9, 18, 0));
    expect(loaded.estimatedWork, 120); // 内核属性：原样保留
    expect(loaded.remainingWork, 90);
    expect(reloaded.warnings.any((w) => w.contains('应用之外被修改')), isTrue);
  });

  test('人在 Obsidian 里新增一行 → 内核自动接管并分配任务 id', () async {
    doc().writeAsStringSync('# 生活\n'
        '\n'
        '- [ ] 买菜 创建 2026-10-11,8:00 ##生活\n');
    final loaded = (await repo.loadAll()).single;
    expect(loaded.title, '买菜');
    expect(loaded.id, startsWith('task-'));
    expect(kernel(loaded.id).existsSync(), isTrue);
    expect(repo.warnings.any((w) => w.contains('已由内核接管')), isTrue);
    // 人类文档不动
    expect(doc().readAsStringSync(),
        '# 生活\n\n- [ ] 买菜 创建 2026-10-11,8:00 ##生活\n');
  });

  test('内核属性目录还在、行被人删了：保留数据 + 提示，不崩', () async {
    await repo.save(makeTask());
    doc().writeAsStringSync('# 工作\n');
    final reloaded = MarkdownTaskRepository(tmp.path);
    expect(await reloaded.loadAll(), isEmpty);
    expect(kernel('task-001').existsSync(), isTrue);
    expect(reloaded.warnings.any((w) => w.contains('找不到对应的行')), isTrue);
  });

  test('新任务按标签追加到对应小节', () async {
    doc().writeAsStringSync('# 工作\n\n- [ ] 旧任务 创建 2026-10-1,9:00 ##工作\n');
    await repo.save(Task(
      id: 'task-002',
      title: '新任务',
      created: DateTime(2026, 10, 11, 9, 0),
      tags: const ['工作'],
    ));
    final lines = doc().readAsStringSync().split('\n');
    expect(lines[0], '# 工作');
    expect(lines[2], contains('旧任务'));
    expect(lines[3], contains('新任务'));
  });

  test('坏的内核属性文档不崩溃，降级为 warning', () async {
    await repo.save(makeTask());
    File('${tmp.path}/.gtd/broken.md').writeAsStringSync('这不是内核属性文档');
    final loaded = await repo.loadAll();
    expect(loaded, hasLength(1));
    expect(repo.warnings.any((w) => w.contains('broken.md')), isTrue);
  });

  test('snoozed_until：持久化在内核属性里，清除后移除该行', () async {
    final snoozed = makeTask().copyWith(
      status: TaskStatus.snoozed,
      snoozedUntil: DateTime(2026, 10, 7, 17, 10),
    );
    await repo.save(snoozed);
    expect(kernel('task-001').readAsStringSync(), contains('snoozed_until:'));
    expect(doc().readAsStringSync(), isNot(contains('snoozed_until')));

    await repo.save(snoozed.copyWith(clearSnooze: true));
    expect(kernel('task-001').readAsStringSync(), isNot(contains('snoozed_until')));
  });

  test('完成：打勾 + 落完成时刻，两边一致', () async {
    await repo.save(makeTask());
    final loaded = (await repo.loadAll()).single;
    final done = loaded.copyWith(
      status: TaskStatus.completed,
      completedAt: DateTime(2026, 10, 12, 15, 19),
    );
    await repo.save(done);

    expect(doc().readAsStringSync(),
        contains('- [x] 完成 Agent 调度论文阅读'));
    expect(doc().readAsStringSync(), contains('完成 2026-10-12,15:19'));
    expect(kernel('task-001').readAsStringSync(),
        contains('completed_at: 2026-10-12T15:19'));

    final reread = (await repo.loadAll()).single;
    expect(reread.isCompleted, isTrue);
    expect(reread.completedAt, DateTime(2026, 10, 12, 15, 19));
  });

  test('命令链路回归：completeTask 落完成时刻（人类文档 + 内核属性），重读仍在',
      () async {
    var now = DateTime(2026, 10, 12, 15, 19);
    TaskService service() => TaskService(
          repo: MarkdownTaskRepository(tmp.path),
          scheduler: const SlackScheduler(),
          workRule: WorkTimeRule.standard,
          clock: () => now,
        );

    final svc = service();
    final a = await svc.createTask(
      title: '写周报',
      estimatedWorkMinutes: 60,
      deadline: DateTime(2026, 10, 13, 18, 0),
    );
    await svc.completeTask(a.id);

    final human = doc().readAsStringSync();
    expect(human, contains('- [x] 写周报'));
    expect(human, contains('完成 2026-10-12,15:19'),
        reason: 'ui 文档 §6.1：完成后那一行原地打勾并补完成时刻');
    expect(kernel(a.id).readAsStringSync(),
        contains('completed_at: 2026-10-12T15:19'));

    // 重复完成（人连点两次）不该把已经记下的时刻冲掉
    now = DateTime(2026, 10, 12, 20, 0);
    await svc.completeTask(a.id);
    expect(doc().readAsStringSync(), contains('完成 2026-10-12,15:19'));

    final svc2 = service();
    await svc2.refreshSchedule();
    expect(svc2.byId(a.id)!.completedAt, DateTime(2026, 10, 12, 15, 19));
    expect(svc2.warnings, isEmpty, reason: '完成时刻落定后行指纹不该再漂移');
  });

  test('命令链路回归：logWork 干完即完成，同样落完成时刻', () async {
    var now = DateTime(2026, 10, 12, 16, 0);
    final svc = TaskService(
      repo: MarkdownTaskRepository(tmp.path),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
    final a = await svc.createTask(
      title: '整理笔记',
      estimatedWorkMinutes: 30,
      deadline: DateTime(2026, 10, 13, 18, 0),
    );
    now = DateTime(2026, 10, 12, 16, 5);
    await svc.logWork(a.id, minutes: 30);

    expect(svc.byId(a.id)!.status, TaskStatus.completed);
    expect(doc().readAsStringSync(), contains('完成 2026-10-12,16:05'),
        reason: '干完即完成也是完成，不能只打勾不记时刻');
    expect(kernel(a.id).readAsStringSync(),
        contains('completed_at: 2026-10-12T16:05'));
  });

  test('软删除：内核文件进 .gtd/.trash/，人类文档那行被注释掉', () async {
    await repo.save(makeTask());
    await repo.loadAll();
    await repo.moveToTrash('task-001');

    expect(kernel('task-001').existsSync(), isFalse);
    expect(File('${tmp.path}/.gtd/.trash/task-001.md').existsSync(), isTrue);
    final human = doc().readAsStringSync();
    expect(human, contains('<!-- gtd:deleted task-001 -->'));
    expect(human, contains('%%- [ ] 完成 Agent 调度论文阅读'));
    expect(human, contains('完成 Agent 调度论文阅读')); // 内容还在，可捞

    // 被注释掉的行不算任务
    expect(await repo.loadAll(), isEmpty);

    final trash = await repo.loadTrash();
    expect(trash.map((t) => t.title), ['完成 Agent 调度论文阅读']);

    await repo.restore('task-001');
    expect(kernel('task-001').existsSync(), isTrue);
    expect(doc().readAsStringSync(), isNot(contains('gtd:deleted')));
    expect((await repo.loadAll()).single.title, '完成 Agent 调度论文阅读');
  });

  test('迁移：旧「一任务一文件」自动转双文档，旧文件进 legacy-tasks/', () async {
    File('${tmp.path}/task-001.md').writeAsStringSync('''
---
id: task-001
title: 完成论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
importance: 4
status: active
created: 2026-10-07T15:30
---
''');

    final loaded = (await repo.loadAll()).single;
    expect(loaded.id, 'task-001');
    expect(loaded.title, '完成论文阅读');
    expect(loaded.importance, 4);
    expect(doc().existsSync(), isTrue);
    expect(doc().readAsStringSync(), contains('- [ ] 完成论文阅读 创建 2026-10-07,15:30'));
    expect(kernel('task-001').readAsStringSync(), contains('work_intensity: 120'));
    // 旧文件不再被当成任务，且挪进了存档目录
    expect(File('${tmp.path}/task-001.md').existsSync(), isFalse);
    expect(File('${tmp.path}/legacy-tasks/task-001.md').existsSync(), isTrue);
    expect(repo.warnings.any((w) => w.contains('迁移')), isTrue);
  });

  test('桌面实现支持文件监听（可选能力）', () {
    expect(repo.watch, isNotNull);
  });

  // ------------------------------------------------------------------
  // 应用自有 metadata 键的写回（附录 B.2 登记表）
  //
  // 这些键是"持久意图"（插队 / 池序 / 跳过今天 / 只响一次 / 类型转换）。
  // v1.7 换 TaskSidecarCodec 时它们一度被当成"未知字段原样保留"：
  // 值变不写、键新不写 —— 而 TaskService 每个命令后都重读磁盘，
  // 于是命令刚返回，意图就没了。本组是那次的回归护栏。
  // ------------------------------------------------------------------

  group('应用自有 metadata 键落盘（附录 B.2）', () {
    test('type 键：写了要落盘，转回 flex 要整行移除', () async {
      final flex = makeTask();
      await repo.save(flex);
      expect(kernel('task-001').readAsStringSync(), isNot(contains('type:')));

      final fixed = flex.copyWith(metadata: const {'type': 'fixed'});
      await repo.save(fixed);
      expect(kernel('task-001').readAsStringSync(), contains('type: fixed'));
      expect((await repo.loadAll()).single.type, TaskType.fixed);

      await repo.save(fixed.copyWith(metadata: const {}));
      expect(kernel('task-001').readAsStringSync(), isNot(contains('type:')));
      expect((await repo.loadAll()).single.type, TaskType.flex);
    });

    test('pinned / pool_order：值变则行变、键消失则行删，读回还在', () async {
      final t = makeTask();
      await repo.save(t);

      await repo.save(t.copyWith(metadata: const {
        'pinned': '2026-10-11T09:00:00.000',
        'pool_order': '2',
      }));
      final raw = kernel('task-001').readAsStringSync();
      expect(raw, contains('pinned: 2026-10-11T09:00:00.000'));
      expect(raw, contains('pool_order: 2'));

      final reloaded = (await repo.loadAll()).single;
      expect(reloaded.pinnedAt, '2026-10-11T09:00:00.000');
      expect(reloaded.poolOrder, 2);

      await repo.save(reloaded.copyWith(metadata: const {'pool_order': '7'}));
      final raw2 = kernel('task-001').readAsStringSync();
      expect(raw2, isNot(contains('pinned:')));
      expect(raw2, contains('pool_order: 7'));
    });

    test('remind：逐任务提醒开关（v1.9）落盘、读回，关掉即删行', () async {
      final t = makeTask();
      await repo.save(t);
      expect(kernel('task-001').readAsStringSync(), isNot(contains('remind:')));

      await repo.save(t.copyWith(metadata: const {'remind': 'true'}));
      expect(kernel('task-001').readAsStringSync(), contains('remind: true'));
      expect((await repo.loadAll()).single.ringEnabled, isTrue,
          reason: '漏登记这个键，开关会在命令自己的重读里蒸发');

      await repo.save(t);
      expect(kernel('task-001').readAsStringSync(), isNot(contains('remind:')));
      expect((await repo.loadAll()).single.ringEnabled, isFalse);
    });

    test('manual_order：手动序（v1.12 决议 43）落盘、读回，换号即改行', () async {
      final t = makeTask();
      await repo.save(t);
      expect(kernel('task-001').readAsStringSync(),
          isNot(contains('manual_order:')));

      await repo.save(t.copyWith(metadata: const {'manual_order': '0'}));
      expect(kernel('task-001').readAsStringSync(), contains('manual_order: 0'));
      expect((await repo.loadAll()).single.manualOrder, 0,
          reason: '漏登记这个键，手动序会在命令自己的重读里蒸发');

      await repo.save(t.copyWith(metadata: const {'manual_order': '3'}));
      final raw2 = kernel('task-001').readAsStringSync();
      expect(raw2, contains('manual_order: 3'));
      expect(raw2, isNot(contains('manual_order: 0')));
    });

    test('周期实例键与 point_fired 落盘并读回', () async {
      final inst = makeTask().copyWith(metadata: const {
        'type': 'routine',
        'routine': 'routine-1a2b',
        'routine_date': '2026-10-11',
        'routine_remind': 'true',
        'routine_skipped': '2026-10-11',
        'point_fired': '2026-10-11T07:00',
      });
      await repo.save(inst);

      final reloaded = (await repo.loadAll()).single;
      expect(reloaded.type, TaskType.routine);
      expect(reloaded.routineId, 'routine-1a2b');
      expect(reloaded.routineDate, '2026-10-11');
      expect(reloaded.routineRemind, isTrue);
      expect(reloaded.isRoutineSkippedOn('2026-10-11'), isTrue);
      expect(reloaded.pointFiredMark, '2026-10-11T07:00');
    });

    test('改写登记键时不碰未知字段与注释行（字段级保真照旧）', () async {
      await repo.save(makeTask());
      final raw = kernel('task-001').readAsStringSync();
      kernel('task-001')
          .writeAsStringSync(raw.replaceFirst('---\n', '---\n# 手写注释\nmood: 好\n'));

      final reloaded = (await repo.loadAll()).single;
      expect(reloaded.metadata['mood'], '好');
      await repo.save(reloaded.copyWith(metadata: {
        ...reloaded.metadata,
        'pinned': '2026-10-11T09:00:00.000',
      }));

      final after = kernel('task-001').readAsStringSync();
      expect(after, contains('# 手写注释'));
      expect(after, contains('mood: 好'));
      expect(after, contains('pinned: 2026-10-11T09:00:00.000'));
    });

    test('命令链路回归：插队经 TaskService 落盘，重载后仍在', () async {
      TaskService service() => TaskService(
            repo: MarkdownTaskRepository(tmp.path),
            scheduler: const SlackScheduler(),
            workRule: WorkTimeRule.standard,
            clock: () => DateTime(2026, 10, 11, 9, 0),
          );

      final svc = service();
      final a = await svc.createTask(
        title: '写周报',
        estimatedWorkMinutes: 60,
        deadline: DateTime(2026, 10, 13, 18, 0),
      );
      await svc.pinToTop(a.id);
      expect(svc.byId(a.id)!.pinnedAt, isNotNull, reason: '命令自己的重锚不该吃掉插队');

      final svc2 = service();
      await svc2.refreshSchedule();
      expect(svc2.byId(a.id)!.pinnedAt, isNotNull, reason: '重启后插队仍在（决议 9）');
    });

    test('操作流水 log.md 不被当成内核属性文档（决议 37）', () async {
      Directory('${tmp.path}/.gtd').createSync(recursive: true);
      File('${tmp.path}/.gtd/log.md').writeAsStringSync(
          '# 操作流水（应用自动追加，只增不改）\n\n'
          '- 2026-10-11 07:12:05  taskCreated  task-1  user  写周报\n');

      expect(await repo.loadAll(), isEmpty);
      expect(repo.warnings, isEmpty, reason: '流水不是"解析不了的属性文档"');
    });

    test('文件监听忽略流水写入（否则"写日志 → 重锚 → 再写日志"自激）', () async {
      Directory('${tmp.path}/.gtd').createSync(recursive: true);
      final log = File('${tmp.path}/.gtd/log.md')
        ..writeAsStringSync('# 操作流水\n');
      final got = <String>[];
      final sub = repo.watch()!.listen((e) => got.add(e.path));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      log.writeAsStringSync(
          '- 2026-10-11 07:00:00  taskCreated  task-1  user  T\n',
          mode: FileMode.append);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got, isEmpty, reason: '流水不是任务数据');

      // 对照组：任务数据变化必须照旧触发（证明监听本身是活的）
      doc().writeAsStringSync('- [ ] T 创建 2026-10-11,7:00\n');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got, isNotEmpty);
      await sub.cancel();
    });
  });
}
