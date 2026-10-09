import 'dart:async';
import 'dart:math';

import '../domain/event.dart';
import '../domain/routine.dart';
import '../repository/routine_repository.dart';
import 'task_service.dart';

/// 周期任务的 application 层协调者（§4.1 RoutineRepository/RoutineCodec 座位）。
///
/// 职责：
/// - 规则的增删改查（唯一写入口，校验在这里守护：Routine.validate）；
/// - **当天实例的生成与同步**（决议 5/12/23）：规则改动后实例跟着变，
///   实例本身不是独立的编辑对象；
/// - 计划段/日历要用的发生时刻查询（决议 24/27）。
///
/// 规则不是 Task：它有自己的仓储与事件流（DomainEvent.taskId = 规则 id），
/// 但生成的实例是 Task，写路径仍走 TaskService（C1）。
class RoutineService {
  final RoutineRepository repo;
  final TaskService tasks;
  final DateTime Function() now;

  final StreamController<DomainEvent> _events =
      StreamController<DomainEvent>.broadcast();

  List<Routine> _routines = [];
  bool _loaded = false;

  RoutineService({
    required this.repo,
    required this.tasks,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;

  /// 规则事件流（routineCreated/Updated/Deleted）。
  Stream<DomainEvent> get events => _events.stream;

  List<String> get warnings => repo.warnings;

  List<Routine> get routines => List.unmodifiable(_routines);

  bool get loaded => _loaded;

  Routine? byId(String id) {
    for (final r in _routines) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    _routines = [...await repo.loadAll()];
    _loaded = true;
  }

  // ---------- 命令 ----------

  Future<Routine> create({
    required String title,
    String description = '',
    RoutineFrequency frequency = RoutineFrequency.daily,
    List<int> weekdays = const [],
    int? minuteOfDay,
    bool remind = false,
    bool enabled = true,
    EventOrigin origin = EventOrigin.user,
  }) async {
    final routine = Routine(
      id: 'routine-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '-${Random().nextInt(0x10000).toRadixString(36).padLeft(4, '0')}',
      title: title,
      description: description,
      frequency: frequency,
      weekdays: _normalizeWeekdays(weekdays),
      minuteOfDay: minuteOfDay,
      remind: remind,
      enabled: enabled,
      created: now(),
    );
    routine.validate();
    _routines = [..._routines, routine];
    await _save();
    _emit(DomainEventType.routineCreated, routine.id, origin);
    await tasks.syncRoutineForDay(routine, now(), origin: origin);
    return routine;
  }

  Future<Routine> update(
    String id, {
    String? title,
    String? description,
    RoutineFrequency? frequency,
    List<int>? weekdays,
    int? minuteOfDay,
    bool clearTime = false,
    bool? remind,
    bool? enabled,
    EventOrigin origin = EventOrigin.user,
  }) async {
    final cur = _require(id);
    final next = cur.copyWith(
      title: title,
      description: description,
      frequency: frequency,
      weekdays: weekdays == null ? null : _normalizeWeekdays(weekdays),
      minuteOfDay: minuteOfDay,
      clearTime: clearTime,
      remind: remind,
      enabled: enabled,
    );
    next.validate();
    _routines = [for (final r in _routines) r.id == id ? next : r];
    await _save();
    _emit(DomainEventType.routineUpdated, id, origin);
    await tasks.syncRoutineForDay(next, now(), origin: origin);
    return next;
  }

  Future<Routine> setEnabled(String id, bool enabled,
      {EventOrigin origin = EventOrigin.user}) async {
    final next = _require(id).copyWith(enabled: enabled);
    _routines = [for (final r in _routines) r.id == id ? next : r];
    await _save();
    _emit(DomainEventType.routineUpdated, id, origin);
    await tasks.syncRoutineForDay(next, now(), origin: origin);
    return next;
  }

  /// 删除规则（决议 23：需确认，从 routines.md 移除）；连带清掉未完成的
  /// 今日实例（已完成的历史留在任务目录里）。
  Future<void> delete(String id, {EventOrigin origin = EventOrigin.user}) async {
    _require(id);
    _routines = _routines.where((r) => r.id != id).toList();
    await _save();
    _emit(DomainEventType.routineDeleted, id, origin);
    await tasks.removeRoutineInstances(id, origin: origin);
  }

  /// 决议 5：每天清零后生成当天实例。幂等——启动 / 跨日 / 回到前台都可调用。
  Future<int> generateTodayInstances(
      {EventOrigin origin = EventOrigin.system}) async {
    final day = now();
    var created = 0;
    for (final r in _routines) {
      if (!r.enabled || !r.occursOn(day)) continue;
      final existed = tasks.byId(TaskService.routineInstanceId(r.id, _mark(day)));
      await tasks.syncRoutineForDay(r, day, origin: origin);
      if (existed == null) created++;
    }
    return created;
  }

  // ---------- 查询（计划段 / 日历）----------

  /// [from] 起 [days] 天内的全部发生（按时刻升序）；决议 27 的插入顺序来源。
  /// [includeToday] = false 时跳过当天（任务池计划段只要明天及以后）。
  List<RoutineOccurrence> occurrences({
    required DateTime from,
    int days = 30,
    bool includeToday = true,
  }) {
    final out = <RoutineOccurrence>[];
    var day = DateTime(from.year, from.month, from.day);
    if (!includeToday) day = DateTime(day.year, day.month, day.day + 1);
    for (var i = 0; i < days; i++) {
      for (final r in _routines) {
        if (!r.occursOn(day)) continue;
        out.add(RoutineOccurrence(routine: r, at: r.occurrenceAt(day) ?? day));
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  void dispose() {
    _events.close();
  }

  // ---------- 内部 ----------

  Future<void> _save() => repo.saveAll(_routines);

  Routine _require(String id) {
    final r = byId(id);
    if (r == null) throw StateError('周期规则不存在: $id');
    return r;
  }

  void _emit(DomainEventType type, String routineId, EventOrigin origin) {
    if (_events.isClosed) return;
    _events.add(DomainEvent(
        type: type, taskId: routineId, at: now(), origin: origin));
  }

  static List<int> _normalizeWeekdays(List<int> days) {
    final set = days.where((d) => d >= 1 && d <= 7).toSet().toList()..sort();
    return List.unmodifiable(set);
  }

  static String _mark(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
}
