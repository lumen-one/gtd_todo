part of '../task_service.dart';

/// 回收站子域（D11）：软删除 / 恢复 / 清空 / 回收清单。
///
/// 以 extension 形式挂在 [TaskService] 上（part of 同一库），调用方所见 API
/// 与拆分前完全一致；static 成员仍在主文件的类体内。
extension TaskServiceTrash on TaskService {
  /// 删除 = 软删除（D11）：内核属性文件移入 `.gtd/.trash/`、人类文档那一行注释掉，
  /// Obsidian 可见可捞；撤销走 [restoreTask]。
  Future<void> deleteTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    _require(id);
    await repo.moveToTrash(id);
    _tasks = _tasks.where((t) => t.id != id).toList();
    _emit(DomainEventType.taskDeleted, id, origin);
    await recomputeSchedule(origin: origin);
  }

  /// 从回收站恢复（撤销窗口 / 设置页回收列表）。
  Future<void> restoreTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    await repo.restore(id);
    // 这里必须读盘：回收站里的任务不在内存 `_tasks` 中（v1.16 起命令默认
    // 不再回读，只有这种"盘上有、内存里没有"的情况才需要）。
    await refreshSchedule(origin: origin);
    _emit(DomainEventType.taskRestored, id, origin);
  }

  /// 清空回收站（真删，仅设置页显式触发）。
  Future<void> purgeTrash({EventOrigin origin = EventOrigin.user}) async {
    await repo.purgeTrash();
    _emit(DomainEventType.trashPurged, '', origin);
  }

  /// 回收站清单（查询，不经缓存）。
  Future<List<Task>> loadTrash() => repo.loadTrash();
}
