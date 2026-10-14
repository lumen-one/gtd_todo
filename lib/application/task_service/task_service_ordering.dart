part of '../task_service.dart';

/// 排序子域：池子显示序 / 插队栈 / 挂起组 / 手动序的整段重编号。
///
/// 以 extension 形式挂在 [TaskService] 上（part of 同一库），调用方所见 API
/// 与拆分前完全一致。
extension TaskServiceOrdering on TaskService {
  /// 池子显示序（决议 14）：仅整理无调度含义，重启保留。
  Future<Task> setPoolOrder(String id, {required int order,
      EventOrigin origin = EventOrigin.user}) async {
    final updated = TaskService._withMeta(
        _require(id), (m) => {...m, 'pool_order': '$order'});
    await _persist(updated, origin, DomainEventType.taskUpdated);
    return updated;
  }

  /// 池子显示序的**整段重编号**（决议 14）：一次拖动手势会打乱整段，所以按
  /// [orderedIds] 的顺序一次性写 0..n-1。
  ///
  /// **必须批量**：逐条调 [setPoolOrder] 会放大成 N 次读盘，更糟的是每写一条就
  /// 重锚一次、发一次事件——第 k 条写完时只有前 k 个序号是新的，那个半成品顺序
  /// 会被立刻渲染出来，清单就在几个位置之间来回跳，最后才停（"闪动"的真因）。
  /// 这里照 [setManualOrder] 的形状：批量落盘 → 整体换 `_tasks` → 一个事件 →
  /// 一次重锚。
  Future<List<Task>> setPoolOrders(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null) continue;
      updated.add(TaskService._withMeta(cur, (m) => {...m, 'pool_order': '$i'}));
    }
    return _persistBatch(updated, DomainEventType.poolOrderChanged, origin);
  }

  /// 插队栈的**整段重写**（决议 9：后插在上，保持到完成）：按 [orderedIds] 的
  /// 顺序决定谁压在最上面，只针对可推任务（决议 11）。
  ///
  /// 时刻按目标顺序**递减 1 毫秒**：一次手势里逐条写会让它们落在同一毫秒上，
  /// 而插队件按 `pinned` 字符串排序——并列时 `sort` 没有稳定依据，落位变成随机
  /// （表现为"闪完之后停在别处"）。批量落盘的理由同 [setPoolOrders]。
  Future<List<Task>> setPinnedStack(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final base = now();
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null || cur.type != TaskType.flex) continue;
      updated.add(TaskService._withMeta(cur, (m) => {
            ...m,
            'pinned': base.subtract(Duration(milliseconds: i)).toIso8601String(),
          }));
    }
    return _persistBatch(updated, DomainEventType.taskPinned, origin);
  }

  /// 挂起组的**整段重写**（v1.18，决议 47）：按 [orderedIds] 的顺序决定谁排最顶
  /// （越靠上 `in_progress` 时刻越新 = 后挂在上）。只对**已挂起**的任务生效——
  /// '转正'后仍占挂位的也照常重写（取消前它还在组里）。
  ///
  /// 时刻按目标顺序**递减 1 毫秒**（同 [setPinnedStack]）：一次手势里逐条写会让
  /// 它们落在同一毫秒上，而组内按 ISO 串排序——并列时 `sort` 没有稳定依据，
  /// 落位变成随机。批量落盘的理由同 [setPoolOrders]。
  Future<List<Task>> setInProgressStack(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final base = now();
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null || cur.inProgressAt == null) continue;
      updated.add(TaskService._withMeta(cur, (m) => {
            ...m,
            'in_progress':
                base.subtract(Duration(milliseconds: i)).toIso8601String(),
          }));
    }
    return _persistBatch(updated, DomainEventType.taskInProgressSet, origin);
  }

  /// 手动序（v1.12，决议 43 / D17）：按 [orderedIds] 的顺序整段重编号（从 0 连续），
  /// 只在无排序模式下参与排序；自动模式下这些序号原样保留、只是不生效。
  ///
  /// 一次拖动手势会重编整段，所以这里**批量落盘后再重锚一次**（不像 [setPoolOrder]
  /// 那样每写一条就重锚一次——那会放大成 N 次读盘）。
  Future<List<Task>> setManualOrder(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null) continue;
      updated
          .add(TaskService._withMeta(cur, (m) => {...m, 'manual_order': '$i'}));
    }
    return _persistBatch(updated, DomainEventType.manualOrderChanged, origin);
  }
}
