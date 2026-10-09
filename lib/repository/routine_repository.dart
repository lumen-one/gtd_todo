import '../domain/routine.dart';

/// 周期规则仓储抽象（§4.1「RoutineRepository」座位）。
///
/// 与 TaskRepository 分开：规则不是任务，住在任务目录下独立的 `routines.md`
/// （决议 10：一条规则一个 frontmatter 条目，Obsidian 可直接看改），
/// TaskRepository/TaskCodec 不覆盖它。
abstract class RoutineRepository {
  Future<List<Routine>> loadAll();

  /// 整体写回（单文件；增删改都落在这里）。
  Future<void> saveAll(List<Routine> routines);

  /// 解析与合并告警。
  List<String> get warnings;
}
