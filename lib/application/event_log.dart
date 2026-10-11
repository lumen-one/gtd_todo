import 'dart:async';

import '../domain/event.dart';
import '../domain/task.dart';

/// `log` 文档的写入插座（决议 37）：**append-only，一次一行**。
///
/// 位置：任务目录 `.gtd/log.md`（与内核属性文档同处"应用自己的那一半"）。
/// 这是纯追加的流水，人只读不改；应用从不重写历史行（连"整理格式"都不做）。
abstract class EventLogPort {
  /// 追加一行（不含换行）。
  Future<void> append(String line);
}

/// 事件流 → `log.md` 的订阅者（§3.3：**新增功能 = 新增订阅者，不改 TaskService**）。
///
/// 一行一条，形如：
///
/// ```text
/// - 2026-10-11 07:12  taskCreated        task-…0823zd9  user      写周报
/// - 2026-10-11 07:40  taskCompleted      task-…0823zd9  user      写周报
/// - 2026-10-11 08:00  scheduleReanchored —              system    —
/// ```
///
/// 设计口径：
/// - **只追加**：崩溃/并发导致的顺序错乱也只影响可读性，不影响任务数据；
/// - **失败不致命**：写日志失败只吞掉（记在内存里给诊断），绝不让它拖垮调度——
///   日志是观察手段，不是事实来源（事实在 `tasks.md` 与 `.gtd/<id>.md`）；
/// - **任务名尽力而为**：事件只有 taskId，标题从当时的任务表里查；
///   查不到（已删除）就留 `—`。
class EventLog {
  EventLog({required this.port, required this.tasks});

  final EventLogPort port;

  /// 标题查询（事件只带 taskId；标题从当时的任务表里查，查不到就留 `—`）。
  final List<Task> Function() tasks;
  final List<String> _failures = [];

  StreamSubscription<DomainEvent>? _sub;

  /// 最近的写入失败（诊断用；见类注释：不往外抛）。
  List<String> get failures => List.unmodifiable(_failures);

  /// 挂上事件流。重复调用只保留最后一个订阅。
  void attach(Stream<DomainEvent> events) {
    _sub?.cancel();
    _sub = events.listen((e) => unawaited(_write(e)));
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _write(DomainEvent e) async {
    try {
      await port.append(format(e));
    } catch (error) {
      _failures.add('${e.at}: $error');
      if (_failures.length > 20) _failures.removeAt(0);
    }
  }

  /// 一行日志的渲染（纯函数，便于测试）。
  String format(DomainEvent e) {
    final title = e.taskId.isEmpty ? null : _titleOf(e.taskId);
    return '- ${_fmt(e.at)}  '
        '${e.type.name.padRight(24)}'
        '${(e.taskId.isEmpty ? '—' : e.taskId).padRight(28)}'
        '${e.origin.name.padRight(10)}'
        '${title ?? '—'}';
  }

  String? _titleOf(String id) {
    for (final t in tasks()) {
      if (t.id == id) return t.title;
    }
    return null;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)} '
      '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}
