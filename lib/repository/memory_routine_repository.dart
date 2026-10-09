import '../domain/routine.dart';
import 'routine_repository.dart';

/// 内存实现（测试与仿真用）。
class MemoryRoutineRepository implements RoutineRepository {
  List<Routine> _routines;

  MemoryRoutineRepository([List<Routine> initial = const []])
      : _routines = [...initial];

  @override
  List<String> get warnings => const [];

  @override
  Future<List<Routine>> loadAll() async => List.unmodifiable(_routines);

  @override
  Future<void> saveAll(List<Routine> routines) async {
    _routines = [...routines];
  }
}
