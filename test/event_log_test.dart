import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/event_log.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/event.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/platform/app_adapters.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/repository/task_document.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// 决议 37：`log` 数据单独一个文档（`.gtd/log.md`），append-only。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('gtd_log_test'));
  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File logFile(String dir) => File('$dir/.gtd/log.md');

  test('一行格式：时间 / 事件 / 任务id / origin / 任务名', () {
    final log = EventLog(
      port: _CollectingPort(),
      tasks: () => [
        Task(id: 'task-1', title: '写周报', created: DateTime(2026, 10, 11)),
      ],
    );
    final line = log.format(DomainEvent(
      type: DomainEventType.taskCompleted,
      taskId: 'task-1',
      at: DateTime(2026, 10, 11, 7, 12, 5),
      origin: EventOrigin.user,
    ));
    expect(line, startsWith('- 2026-10-11 07:12:05'));
    expect(line, contains('taskCompleted'));
    expect(line, contains('task-1'));
    expect(line, contains('user'));
    expect(line, endsWith('写周报'));
  });

  test('查不到任务名（已删除）时留 —，无任务的事件也留 —', () {
    final log = EventLog(port: _CollectingPort(), tasks: () => const []);
    expect(
      log.format(DomainEvent(
        type: DomainEventType.taskDeleted,
        taskId: 'gone-1',
        at: DateTime(2026, 10, 11, 9, 0),
        origin: EventOrigin.user,
      )),
      endsWith('—'),
    );
    expect(
      log.format(DomainEvent(
        type: DomainEventType.scheduleReanchored,
        taskId: '',
        at: DateTime(2026, 10, 11, 9, 0),
        origin: EventOrigin.system,
      )),
      contains('—'),
    );
  });

  test('落盘：表头只写一次，之后纯追加', () async {
    final port = FileEventLogPort(tmp.path);
    await port.append('- a');
    await port.append('- b');
    final raw = logFile(tmp.path).readAsStringSync();
    expect(raw, startsWith('# 操作流水'));
    expect(raw, contains('- a\n- b\n'));
    expect(raw.split('# 操作流水').length, 2); // 表头只出现一次
  });

  test('订阅 TaskService 事件流：命令真的写进 log.md', () async {
    final repo = MemoryTaskRepository();
    final svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 11, 7, 0),
    );
    final port = FileEventLogPort(tmp.path);
    final log = EventLog(port: port, tasks: () => svc.tasks)
      ..attach(svc.events);

    await svc.createTask(title: '写周报', estimatedWorkMinutes: 60);
    await log.detach();
    await port.drain(); // 等最后几行真的落盘

    final raw = logFile(tmp.path).readAsStringSync();
    expect(raw, contains('taskCreated'));
    expect(raw, contains('写周报'));
    expect(log.failures, isEmpty);
  });

  test('写日志失败不致命：只记 failures，不往外抛（日志不是事实来源）', () async {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 11, 7, 0),
    );
    final log = EventLog(port: _FailingPort(), tasks: () => svc.tasks)
      ..attach(svc.events);
    await svc.createTask(title: '写周报', estimatedWorkMinutes: 60);
    await Future<void>.delayed(Duration.zero);
    await log.detach();
    expect(log.failures, isNotEmpty);
  });

  test('人类文档格式不受影响：log.md 不会被当成内核属性文档或任务行', () {
    // log.md 是自由文本流水，没有 frontmatter 也没有复选框行
    const raw = '# 操作流水（应用自动追加，只增不改）\n\n'
        '- 2026-10-11 07:12:05  taskCreated  task-1  user  写周报\n';
    final parsed = const TaskDocumentCodec().parse(raw);
    expect(parsed.tasks, isEmpty);
    expect(parsed.warnings, isEmpty); // 标题行不算任务，也不算坏行
  });
}

class _CollectingPort implements EventLogPort {
  final List<String> lines = [];

  @override
  Future<void> append(String line) async => lines.add(line);
}

class _FailingPort implements EventLogPort {
  @override
  Future<void> append(String line) async => throw const FileSystemException('磁盘满');
}
