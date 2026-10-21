# 周期任务插座

周期规则住在独立的 `routines.md` 里，不混进 `tasks.md`；每天生成当天实例。

> 本节从 [架构文档](../architecture.md) §4.1 的"新座位"搬出，口径未改。

**RoutineRepository / RoutineCodec**：周期规则存独立 `routines.md`（非 Task 文件，
TaskRepository/TaskCodec 不覆盖；一条规则一个 frontmatter 条目，Obsidian 可改）；
每天生成当天实例（origin=system），实例不占工时、不进 ScheduleResult 排序
（实现：`domain/routine.dart` + `repository/{routine_codec,routine_repository,
markdown_routine_repository}.dart` + `application/routine_service.dart`）。
