part of '../task_service.dart';

/// 周期实例子域（决议 5/12/23）：当天实例的生成 / 同步 / 清理 / 跳过。
///
/// 以 extension 形式挂在 [TaskService] 上（part of 同一库），调用方所见 API
/// 与拆分前完全一致；确定性 id 的 static [TaskService.routineInstanceId]
/// 仍在主文件的类体内（extension 无法承载 static）。
extension TaskServiceRoutine on TaskService {
  /// 生成某规则在 [day] 的当天实例（幂等：已存在则原样返回）。
  /// 实例不占工时（estimatedWork = 0，A2 由 routine 类型豁免），
  /// 不进 ScheduleResult 排序（SlackScheduler 过滤非 flex）。
  Future<Task> createRoutineInstance(
    Routine routine,
    DateTime day, {
    EventOrigin origin = EventOrigin.system,
  }) async {
    final mark = TaskService._dayMark(day);
    final id = TaskService.routineInstanceId(routine.id, mark);
    final existing = byId(id);
    if (existing != null) return existing;

    final task = Task(
      id: id,
      title: routine.title,
      description: routine.description,
      deadline: routine.occurrenceAt(day),
      estimatedWork: 0,
      remainingWork: 0,
      created: now(),
      metadata: Map.unmodifiable({
        'type': 'routine',
        'routine': routine.id,
        'routine_date': mark,
        if (routine.remind) 'routine_remind': 'true',
      }),
    );
    _tasks = [..._tasks, task];
    _emit(DomainEventType.routineInstanceGenerated, task.id, origin);
    await _saveAll([task]);
    await recomputeSchedule(origin: origin);
    return task;
  }

  /// 规则改动后同步今日实例（决议 23：改规则即改实例；不提供"编辑实例"）。
  /// - 规则停用 / 今天不发生 → 未完成的今日实例移入回收站；
  /// - 今天发生 → 有则刷新标题/备注/时刻，无则生成。
  Future<void> syncRoutineForDay(
    Routine routine,
    DateTime day, {
    EventOrigin origin = EventOrigin.system,
  }) async {
    final mark = TaskService._dayMark(day);
    final id = TaskService.routineInstanceId(routine.id, mark);
    final existing = byId(id);
    if (!routine.enabled || !routine.occursOn(day)) {
      if (existing != null && !existing.isCompleted) {
        await deleteTask(id, origin: origin);
      }
      return;
    }
    if (existing == null) {
      await createRoutineInstance(routine, day, origin: origin);
      return;
    }
    if (existing.isCompleted) return; // 完成即消，次日再生（决议 5）
    final deadline = routine.occurrenceAt(day);
    final meta = Map<String, String>.from(existing.metadata);
    if (routine.remind) {
      meta['routine_remind'] = 'true';
    } else {
      meta.remove('routine_remind');
    }
    // 内容没变就不落盘：文件 watch（主引擎/悬浮引擎/Obsidian 三方都在看）会
    // 因为无谓的写入互相触发，形成"写 → 事件 → 同步 → 再写"的回环。
    final unchanged = existing.title == routine.title &&
        existing.description == routine.description &&
        existing.deadline == deadline &&
        existing.routineRemind == routine.remind;
    if (unchanged) return;
    final updated = existing.copyWith(
      title: routine.title,
      description: routine.description,
      deadline: deadline,
      clearDeadline: deadline == null,
      metadata: Map.unmodifiable(meta),
    );
    await _persist(updated, origin, DomainEventType.routineUpdated);
  }

  /// 规则删除：连带清掉它未完成的今日实例（已完成的历史保留）。
  Future<void> removeRoutineInstances(String routineId,
      {EventOrigin origin = EventOrigin.system}) async {
    final mine = _tasks
        .where((t) =>
            t.type == TaskType.routine &&
            t.routineId == routineId &&
            !t.isCompleted)
        .map((t) => t.id)
        .toList();
    for (final id in mine) {
      await deleteTask(id, origin: origin);
    }
  }

  /// "跳过今天"（决议 23）：不完成、今日不再显示，次日再生。
  Future<Task> skipRoutineToday(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (cur.type != TaskType.routine) {
      throw ArgumentError('只有周期实例可以"跳过今天"');
    }
    final mark = cur.routineDate ?? TaskService._dayMark(now());
    final updated =
        TaskService._withMeta(cur, (m) => {...m, 'routine_skipped': mark});
    await _persist(updated, origin, DomainEventType.routineSkipped);
    return updated;
  }
}
