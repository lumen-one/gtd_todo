import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';

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

  // 传入完整文件名（含 .md）
  File file(String name) => File('${tmp.path}/$name');

  Task makeTask() => Task(
        id: 'task-001',
        title: '完成 Agent 调度论文阅读',
        deadline: DateTime(2026, 10, 8, 18, 0),
        estimatedWork: 120,
        remainingWork: 90,
        importance: 3,
        status: TaskStatus.active,
        created: DateTime(2026, 10, 7, 15, 30),
        description: '# 任务说明\n\n- 阅读论文\n- 写总结\n',
      );

  test('保存后能读回来，字段一致', () async {
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
  });

  test('幂等：应用自己写的文件，读进来再存回去逐字节不变', () async {
    await repo.save(makeTask());
    final raw1 = file('task-001.md').readAsStringSync();

    final loaded = (await repo.loadAll()).single;
    await repo.save(loaded.copyWith(remainingWork: 80));
    final raw2 = file('task-001.md').readAsStringSync();

    final loaded2 = (await repo.loadAll()).single;
    await repo.save(loaded2);
    final raw3 = file('task-001.md').readAsStringSync();

    expect(raw2, isNot(raw1)); // remaining_work 变了
    expect(raw3, raw2); // 无变化的保存 = 逐字节不变
  });

  test('字段级保真：手写文件里的未知字段、注释、正文原样保留', () async {
    file('task-001.md').writeAsStringSync('''
---
# 用户的备注：别动这行
id: task-001
title: 完成论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
priority: high
status: active
created: 2026-10-07T15:30
---

# 任务说明

- 阅读论文
''');
    final loaded = (await repo.loadAll()).single;
    expect(loaded.metadata['priority'], 'high'); // 未知字段进 metadata

    // 应用只改自己的字段
    await repo.save(loaded.copyWith(remainingWork: 80));
    final raw = file('task-001.md').readAsStringSync();

    expect(raw, contains('remaining_work: 80')); // 应用字段更新
    expect(raw, contains('# 用户的备注：别动这行')); // 注释保留
    expect(raw, contains('priority: high')); // 未知字段保留
    expect(raw.indexOf('# 用户的备注'), lessThan(raw.indexOf('id: task-001'))); // 行顺序保留
    expect(raw, contains('- 阅读论文')); // 正文保留
  });

  test('D9 外部合并：Obsidian 端的修改不会被应用覆盖', () async {
    file('task-001.md').writeAsStringSync('''
---
id: task-001
title: 完成论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
priority: high
status: active
created: 2026-10-07T15:30
---

- 阅读论文
''');
    final loaded = (await repo.loadAll()).single;

    // 模拟用户在 Obsidian 里改了未知字段、机读字段、并加了正文
    final external = file('task-001.md').readAsStringSync()
        .replaceFirst('priority: high', 'priority: urgent')
        .replaceFirst('remaining_work: 90', 'remaining_work: 999')
        .replaceFirst('- 阅读论文', '- 阅读论文\n- 外部新增的行');
    file('task-001.md').writeAsStringSync(external);

    // 应用保存 remaining_work: 50
    await repo.save(loaded.copyWith(remainingWork: 50));
    final raw = file('task-001.md').readAsStringSync();

    expect(raw, contains('remaining_work: 50')); // 应用拥有的字段：应用赢
    expect(raw, contains('priority: urgent')); // 未知字段：外部赢（字段归属合并）
    expect(raw, contains('- 外部新增的行')); // 正文：外部赢（未被显式命令不改）
    expect(repo.warnings.any((w) => w.contains('外部修改')), isTrue); // 有提示
  });

  test('snoozed_until：持久化，清除后从文件中移除', () async {
    final snoozed = makeTask()
        .copyWith(status: TaskStatus.snoozed, snoozedUntil: DateTime(2026, 10, 7, 17, 10));
    await repo.save(snoozed);
    expect(file('task-001.md').readAsStringSync(), contains('snoozed_until:'));

    await repo.save(snoozed.copyWith(clearSnooze: true));
    expect(file('task-001.md').readAsStringSync(), isNot(contains('snoozed_until')));
  });

  test('坏文件不崩溃，降级为 warning', () async {
    file('broken.md').writeAsStringSync('这不是一个任务文件');
    await repo.save(makeTask());
    final loaded = await repo.loadAll();
    expect(loaded, hasLength(1));
    expect(repo.warnings, hasLength(1));
    expect(repo.warnings.first, contains('broken.md'));
  });

  test('桌面实现支持文件监听（可选能力）', () {
    expect(repo.watch, isNotNull);
  });
}
