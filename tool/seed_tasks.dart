import 'dart:io';

import 'package:qixing/domain/task.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/repository/task_document.dart';

/// 一次性工具：按照应用的格式生成示例任务数据（`tasks.md` + `.gtd/*.md`）。
/// 运行：`dart run tool/seed_tasks.dart`
///
/// 做法：先让 [MarkdownTaskRepository] 自己写（内核属性文档的形状由它决定，
/// 免得手写跑偏），再按标签把小节标题与人类那行组装成最终文档。
void main() async {
  final tasks = <Task>[
    Task(
      id: 'task-001',
      title: '完成 Agent 调度论文阅读',
      deadline: DateTime(2026, 10, 8, 23, 59),
      estimatedWork: 120,
      remainingWork: 0,
      importance: 3,
      status: TaskStatus.completed,
      created: DateTime(2026, 10, 7, 15, 30),
      completedAt: DateTime(2026, 10, 8, 21, 40),
      description: '阅读论文并整理笔记。',
      tags: const ['学习', '示例'],
    ),
    Task(
      id: 'task-002',
      title: '准备周五周会汇报',
      deadline: DateTime(2026, 10, 9, 23, 59),
      estimatedWork: 60,
      remainingWork: 30,
      importance: 2,
      status: TaskStatus.active,
      created: DateTime(2026, 10, 7, 15, 32),
      description: '整理本周进展，准备 10 页幻灯片。',
      tags: const ['工作', '示例'],
    ),
    Task(
      id: 'task-003',
      title: '整理 Obsidian 任务模板',
      deadline: DateTime(2026, 10, 14, 23, 59),
      estimatedWork: 45,
      remainingWork: 0,
      importance: 1,
      status: TaskStatus.completed,
      created: DateTime(2026, 10, 7, 15, 34),
      completedAt: DateTime(2026, 10, 12, 15, 19),
      description: '把字段约定写成模板，方便以后手动建任务。',
      tags: const ['工作', '示例'],
    ),
  ];

  final dir = Directory('tasks')..createSync(recursive: true);
  final repo = MarkdownTaskRepository(dir.path);
  for (final t in tasks) {
    await repo.save(t);
  }

  // 按第一个标签分组，模拟应用"新任务落到对应小节"的写法
  final sections = <String, List<Task>>{};
  for (final t in tasks) {
    sections.putIfAbsent(t.tags.first, () => []).add(t);
  }

  final doc = StringBuffer()
    ..writeln('# 任务')
    ..writeln()
    ..writeln('所有任务都在**这一个文档**里，用 `# 标题` 分类，一条任务一行。')
    ..writeln('行格式：`- [ ] 任务名 创建 <日期,时间> 结束 <日期,时间> '
        '完成 <日期,时间> 备注… ##标签`')
    ..writeln()
    ..writeln('内核属性（任务 id、工作强度、优先级、时间裕度、剩余工作量）在'
        '同目录的 `.gtd/<任务id>.md` 里，由应用维护。')
    ..writeln('这个文档归人所有：应用只改它自己写的那一行，其余内容一字不动。')
    ..writeln();

  for (final entry in sections.entries) {
    doc
      ..writeln('# ${entry.key}')
      ..writeln();
    for (final t in entry.value) {
      doc.writeln(TaskDocumentCodec.encodeLine(t));
    }
    doc.writeln();
  }

  File('${dir.path}/tasks.md').writeAsStringSync(doc.toString());

  stdout.writeln('已写入 ${dir.path}/tasks.md 与 ${tasks.length} 个内核属性文档');
  for (final t in tasks) {
    stdout.writeln('--- ${t.id}.md ---\n'
        '${File('${dir.path}/.gtd/${t.id}.md').readAsStringSync()}');
  }
  // 立刻用应用自己的读取路径验一遍：不应有任何告警
  final check = MarkdownTaskRepository(dir.path);
  final loaded = await check.loadAll();
  stdout.writeln('读回 ${loaded.length} 条；warnings=${check.warnings}');
}
