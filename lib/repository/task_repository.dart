import '../domain/task.dart';

/// 文件变更事件类型。【待细化】后续按需细分 created/updated/deleted。
enum RepoChangeType { changed }

class RepositoryEvent {
  final RepoChangeType type;
  final String path;
  final DateTime at;

  const RepositoryEvent(this.type, this.path, this.at);
}

/// 任务仓储抽象。UI 和 Scheduler 永远不直接读写 Markdown，
/// 它们只认识这个接口。Markdown 只是第一种实现。
abstract class TaskRepository {
  Future<List<Task>> loadAll();

  Future<Task?> getTask(String id);

  Future<void> save(Task task);

  Future<void> delete(String id);

  // ---- 软删除三件套（D11：删除 = 移入内核属性目录的 .trash/，可捞回）----

  /// 移入回收站。双文档形态下 = 内核属性文件移入 `.gtd/.trash/` +
  /// 人类文档里那一行用 `%%…%%` 注释掉（内容原样保留，Obsidian 可见可捞）。
  Future<void> moveToTrash(String id);

  /// 回收站里的任务（忽略 .trash 之外的任何东西）。
  Future<List<Task>> loadTrash();

  /// 从回收站恢复。
  Future<void> restore(String id);

  /// 清空回收站（真删，仅设置页显式触发）。
  Future<void> purgeTrash();

  /// 可选能力：文件监听。null = 平台/实现不支持（如安卓 SAF），
  /// 调用方降级为"回到前台时刷新"。
  Stream<RepositoryEvent>? watch();

  /// 解析与合并告警（流向见 docs/architecture.md 附录 B）。
  List<String> get warnings;
}
