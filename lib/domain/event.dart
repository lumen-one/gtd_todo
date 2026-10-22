/// 领域事件（§3.3）：TaskService 每个命令完成后广播。
/// 通知、同步、统计、AI 观察全部做成订阅者——新增功能 = 新增订阅者。
enum EventOrigin { user, ai, migration, system }

enum DomainEventType {
  taskCreated,
  taskUpdated,
  taskCompleted,
  taskReopened,  // 恢复未完成（撤销一次完成；ui 文档 §6.7 已完成页）
  taskSnoozed,
  workLogged,
  taskDeleted,
  taskPinned,     // 插队（持久意图，保持到完成；ui 文档决议 9）
  taskPicked,     // 挑到今日（散件附今日尾部；决议 8/13）
  taskRestored,   // 软删除恢复（D11）
  trashPurged,    // 清空回收站（D11）
  taskReminderSet, // 逐任务提醒开关（v1.9 决议 38：标准模式下让这一件出声）
  manualOrderChanged, // 手动序改写（v1.12 决议 43：无排序模式下的拖动定序）
  poolOrderChanged,   // 池子整理序整段改写（决议 14：一次拖动批量落盘）
  taskInProgressSet,  // 挂起进行开关 / 挂起组整段重写（v1.18 决议 47：长期任务顶置今日页）
  looseHomeChanged,   // 散件在两个家之间搬家（无排序档：今日页 ⑥ ↔ 池子散件段）
  scheduleModeChanged, // 调度模式切换（v1.12 决议 43：只重算视图，不动数据）
  scheduleReanchored,
  // ---- 周期任务（决议 5/10/12/23）----
  routineCreated,           // 规则新建（taskId = 规则 id）
  routineUpdated,           // 规则修改（含启用开关）
  routineDeleted,           // 规则删除
  routineInstanceGenerated, // 当天实例生成（origin=system，决议 5）
  routineSkipped,           // 实例"跳过今天"（决议 23）
}

class DomainEvent {
  final DomainEventType type;
  final String taskId;
  final DateTime at;
  final EventOrigin origin;

  const DomainEvent({
    required this.type,
    required this.taskId,
    required this.at,
    required this.origin,
  });

  @override
  String toString() =>
      'DomainEvent(${type.name}, task=$taskId, origin=${origin.name}, $at)';
}
