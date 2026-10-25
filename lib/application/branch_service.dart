import '../domain/branch.dart';
import '../repository/branch_repository.dart';

/// 支线的应用服务（ui-interaction.md §6.12）。
///
/// **与 TaskService 独立**：支线只是任务 id 的引用表，这里不重锚调度、不发领域
/// 事件、不碰 `.gtd/`。它只做三件事：读整份 `支线.md`、改一段、整份写回。
///
/// 每个命令都是"**先读盘 → 改那一段 → 整份写回**"：两个引擎（应用内 / 悬浮窗）
/// 可能同时写同一个文件，读一遍再改能把"另一个引擎刚写的别的段"带上，不至于被
/// 本地旧内存态抹掉（与主线、编排同一套理由）。
class BranchService {
  final BranchRepository repo;

  /// 任务 id → 实时标题。由组装点注入 `TaskService` 的查询，application 层不认
  /// `TaskService`；null 或查不到（任务被删了）时保留文件里那份原标题。
  final String? Function(String taskId)? titleOf;

  List<Branch> _branches = const [];

  BranchService({required this.repo, this.titleOf});

  /// 解析告警（诊断用）。
  List<String> get warnings => repo.warnings;

  /// 全部支线（段序即卡片顺序）。
  List<Branch> get branches => _branches;

  /// 读盘（启动 / 文件变更 / 回前台时调；幂等）。
  Future<void> load() async {
    _branches = await repo.loadAll();
  }

  /// 新建一条空支线（追加到末尾）。空名字不建。
  Future<void> addBranch(String name) => _mutate((list) {
        final title = name.trim();
        if (title.isEmpty) return list;
        return [...list, Branch(name: title)];
      });

  Future<void> renameBranch(int index, String name) => _mutate((list) {
        final title = name.trim();
        if (title.isEmpty || index < 0 || index >= list.length) return list;
        return [...list]..[index] = list[index].copyWith(name: title);
      });

  /// 删掉一条支线（只删分组，任务一件都不动）。
  Future<void> removeBranch(int index) => _mutate((list) {
        if (index < 0 || index >= list.length) return list;
        return [...list]..removeAt(index);
      });

  /// 把一件任务加进第 [index] 条支线；已经在里面就什么都不做。
  Future<void> addTask(int index, String taskId) => _mutate((list) {
        if (index < 0 || index >= list.length) return list;
        final branch = list[index];
        if (branch.contains(taskId)) return list;
        final entry = BranchEntry(
          taskId: taskId,
          title: titleOf?.call(taskId) ?? '',
        );
        return [...list]
          ..[index] = branch.copyWith(entries: [...branch.entries, entry]);
      });

  /// 从第 [index] 条支线里移掉一件任务（找不到就什么都不做）。
  Future<void> removeTask(int index, String taskId) => _mutate((list) {
        if (index < 0 || index >= list.length) return list;
        final branch = list[index];
        return [...list]
          ..[index] = branch.copyWith(entries: [
            for (final e in branch.entries)
              if (e.taskId != taskId) e,
          ]);
      });

  /// 整段重写（拖动改顺序走这里：一次落盘 + 一次通知）。**不排序**——拖出来的
  /// 就是顺序；已完成的沉底由界面分两段渲染，不改文件里的行序。
  Future<void> setEntries(int index, List<BranchEntry> entries) =>
      _mutate((list) {
        if (index < 0 || index >= list.length) return list;
        return [...list]..[index] = list[index].copyWith(entries: entries);
      });

  /// 读盘 → 换掉那一段 → 刷新标题 → 整份写回。
  Future<void> _mutate(List<Branch> Function(List<Branch>) change) async {
    final disk = await repo.loadAll();
    final next = [for (final b in change(disk)) _refreshTitles(b)];
    await repo.saveAll(next);
    _branches = next;
  }

  /// 标题按任务的实时值刷新；查不到的 id 保留文件里那份（失效引用还要显示原文）。
  Branch _refreshTitles(Branch branch) {
    final resolve = titleOf;
    if (resolve == null) return branch;
    return branch.copyWith(entries: [
      for (final e in branch.entries)
        e.copyWith(title: resolve(e.taskId) ?? e.title),
    ]);
  }
}
