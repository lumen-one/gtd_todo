import '../domain/branch.dart';
import 'branch_repository.dart';

/// 内存实现（测试与仿真用；不落盘）。
class MemoryBranchRepository implements BranchRepository {
  List<Branch> _branches;
  final List<String> _warnings = [];

  MemoryBranchRepository([List<Branch> initial = const []])
      : _branches = List.of(initial);

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<Branch>> loadAll() async => List.of(_branches);

  @override
  Future<void> saveAll(List<Branch> branches) async {
    _branches = List.of(branches);
  }
}
