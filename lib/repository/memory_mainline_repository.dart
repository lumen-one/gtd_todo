import '../domain/mainline.dart';
import 'mainline_repository.dart';

/// 内存实现（测试与仿真用；不发时不落盘）。
class MemoryMainlineRepository implements MainlineRepository {
  List<Mainline> _items;
  final List<String> _warnings = [];

  MemoryMainlineRepository([List<Mainline> initial = const []])
      : _items = List.of(initial);

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<Mainline>> loadAll() async => List.of(_items);

  @override
  Future<void> saveAll(List<Mainline> mainlines) async {
    _items = List.of(mainlines);
  }
}
