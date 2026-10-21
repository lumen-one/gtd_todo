import '../domain/plan.dart';
import 'plan_repository.dart';

/// 内存实现（测试与仿真用；不落盘）。
class MemoryPlanRepository implements PlanRepository {
  List<DayPlan> _days;
  final List<String> _warnings = [];

  MemoryPlanRepository([List<DayPlan> initial = const []])
      : _days = List.of(initial);

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<DayPlan>> loadAll() async => List.of(_days);

  @override
  Future<void> saveAll(List<DayPlan> days) async {
    _days = List.of(days);
  }
}
