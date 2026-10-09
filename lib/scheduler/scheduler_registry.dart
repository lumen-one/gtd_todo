import 'scheduler.dart';

/// 算法注册表（§4.1）：当前选择持久化在设置（规划），切换算法无需迁移——
/// nextReminder 是计算结果，重算即生效。
class SchedulerRegistry {
  final Map<String, Scheduler> _byId = {};
  final String defaultId;

  SchedulerRegistry({required List<Scheduler> schedulers, required this.defaultId}) {
    for (final s in schedulers) {
      if (_byId.containsKey(s.id)) {
        throw ArgumentError('重复的算法 id: ${s.id}');
      }
      _byId[s.id] = s;
    }
    if (!_byId.containsKey(defaultId)) {
      throw ArgumentError('defaultId 未注册: $defaultId');
    }
  }

  Scheduler get defaultScheduler => _byId[defaultId]!;

  Scheduler? byId(String id) => _byId[id];

  List<Scheduler> get all => List.unmodifiable(_byId.values);

  void register(Scheduler scheduler) {
    if (_byId.containsKey(scheduler.id)) {
      throw ArgumentError('重复的算法 id: ${scheduler.id}');
    }
    _byId[scheduler.id] = scheduler;
  }
}
