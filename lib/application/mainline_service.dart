import 'dart:math';

import '../domain/mainline.dart';
import '../repository/mainline_repository.dart';

/// 主线的应用服务（ui-interaction.md §6.9）。
///
/// **与 TaskService 完全独立**：行为链步骤不是任务，这里不重锚调度、不发领域
/// 事件、不碰 `.gtd/`。它只做三件事：读整份 `主线.md`、改一条、整份写回。
///
/// 每个命令都是"**先读盘 → 改那一条 → 整份写回**"：两个引擎（应用内 / 悬浮窗）
/// 可能同时写同一个文件，读一遍再改能把"别人刚改的另一条主线"带上，不至于被
/// 本地旧内存态抹掉。代价是每次命令多读一次小文件，可以接受。
class MainlineService {
  final MainlineRepository repo;
  final DateTime Function() _clock;

  List<Mainline> _items = const [];

  MainlineService({required this.repo, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// 解析告警（诊断用）。
  List<String> get warnings => repo.warnings;

  /// 全部主线：在跑的在前（最多一条），已归档的按完成时刻从新到旧。
  List<Mainline> get mainlines => _items;

  /// 当前在跑的那一条；没有 → null（顶栏显示『＋ 新建主线』）。
  Mainline? get active {
    for (final m in _items) {
      if (m.isActive) return m;
    }
    return null;
  }

  /// 已归档的主线（新→旧）。
  List<Mainline> get archived => [for (final m in _items) if (!m.isActive) m];

  Mainline? byId(String id) {
    for (final m in _items) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 读盘（启动 / 文件变更 / 回前台时调；幂等）。
  Future<void> load() async {
    _items = _sort(await repo.loadAll());
  }

  /// 新建一条主线并开始跑（同时只有一条在跑，所以调用方应先确认 [active] 为空）。
  Future<Mainline> create({
    required String title,
    List<String> steps = const [],
  }) async {
    final name = _requireTitle(title);
    final now = _clock();
    final disk = await repo.loadAll();
    final id = _newId(now, {for (final m in disk) m.id});
    final draft = Mainline.fresh(
      id: id,
      title: name,
      created: now,
      stepTitles: [
        for (final s in steps)
          if (s.trim().isNotEmpty) s.trim(),
      ],
    );
    await _write([...disk, draft]);
    return draft;
  }

  /// 改名。
  Future<void> rename(String id, String title) =>
      _mutate(id, (m) => m.copyWith(title: _requireTitle(title)));

  /// 整条行为链一次写入（编辑态保存走这里；顺序、完成状态都由调用方给全）。
  Future<void> setSteps(String id, List<MainlineStep> steps) =>
      _mutate(id, (m) => m.copyWith(steps: _normalizeSteps(steps)));

  /// 勾选 / 取消勾选某一步。勾上记完成时刻，取消把时刻一并清掉。
  Future<void> toggleStep(String id, int index, {required bool done}) =>
      _mutate(id, (m) {
        final steps = [...m.steps];
        if (index < 0 || index >= steps.length) return m;
        steps[index] = done
            ? steps[index].copyWith(done: true, doneAt: _clock())
            : steps[index].copyWith(done: false, clearDoneAt: true);
        return m.copyWith(steps: steps);
      });

  /// 改某一步的名字 / 备注（点文字那个对话框）。
  Future<void> updateStep(
    String id,
    int index, {
    String? title,
    String? note,
  }) =>
      _mutate(id, (m) {
        final steps = [...m.steps];
        if (index < 0 || index >= steps.length) return m;
        steps[index] = steps[index].copyWith(
          title: title?.trim(),
          note: note,
        );
        return m.copyWith(steps: _normalizeSteps(steps));
      });

  /// 追加一步（末尾）。
  Future<void> addStep(String id, String title) => _mutate(id, (m) {
        final t = title.trim();
        if (t.isEmpty) return m;
        return m.copyWith(steps: [...m.steps, MainlineStep(title: t)]);
      });

  /// 加一段记录（日历上拖选一段 → 写文字）。
  Future<void> addLog(
    String id, {
    required DateTime start,
    required DateTime end,
    String text = '',
  }) =>
      _mutate(id, (m) => m.copyWith(logs: [
            ...m.logs,
            MainlineLog.range(start: start, end: end, text: text),
          ]));

  /// 改一段记录（文字 / 起止日期）。
  Future<void> updateLog(
    String id,
    int index, {
    DateTime? start,
    DateTime? end,
    String? text,
  }) =>
      _mutate(id, (m) {
        final logs = [...m.logsInOrder];
        if (index < 0 || index >= logs.length) return m;
        logs[index] = logs[index].copyWith(
          start: start,
          end: end,
          text: text,
        );
        return m.copyWith(logs: logs);
      });

  /// 删一段记录。
  Future<void> removeLog(String id, int index) => _mutate(id, (m) {
        final logs = [...m.logsInOrder];
        if (index < 0 || index >= logs.length) return m;
        logs.removeAt(index);
        return m.copyWith(logs: logs);
      });

  /// 归档：**行为链必须全部勾完**（空链也不行，见 [Mainline.isAllDone]）。
  ///
  /// 只改状态与归档时刻，数据一行不删——归档后可只读查看。
  Future<void> complete(String id) => _mutate(id, (m) {
        if (!m.isActive) return m;
        if (!m.isAllDone) {
          throw StateError('行为链还没勾完，不能归档');
        }
        return m.copyWith(completedAt: _clock());
      });

  // ---------- 内部 ----------

  Future<void> _write(List<Mainline> next) async {
    final sorted = _sort(next);
    await repo.saveAll(sorted);
    _items = sorted;
  }

  Future<Mainline> _mutate(
    String id,
    Mainline Function(Mainline) change,
  ) async {
    final disk = await repo.loadAll();
    final next = <Mainline>[];
    Mainline? changed;
    for (final m in disk) {
      if (m.id == id) {
        changed = change(m); // 抛异常时不落盘（归档的前提校验靠它）
        next.add(changed);
      } else {
        next.add(m);
      }
    }
    if (changed == null) throw StateError('没有这条主线：$id');
    await _write(next);
    return changed;
  }

  /// 在跑的在前；已归档的按完成时刻从新到旧（没有完成时刻的垫底）。
  static List<Mainline> _sort(List<Mainline> items) {
    final active = [for (final m in items) if (m.isActive) m];
    final archived = [for (final m in items) if (!m.isActive) m]
      ..sort((a, b) {
        final x = a.completedAt;
        final y = b.completedAt;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
    return [...active, ...archived];
  }

  static List<MainlineStep> _normalizeSteps(List<MainlineStep> steps) => [
        for (final s in steps)
          if (s.title.trim().isNotEmpty)
            s.copyWith(title: s.title.trim(), note: s.note.trim()),
      ];

  static String _requireTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) {
      throw ArgumentError.value(title, 'title', '主线名不能为空');
    }
    return t;
  }

  /// `ml-20261021-4f2a`：日期便于人读，尾巴防撞（同毫秒建两条也不重）。
  String _newId(DateTime now, Set<String> taken) {
    final rnd = Random();
    final day = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    for (var i = 0; i < 64; i++) {
      final tail = rnd.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
      final id = 'ml-$day-$tail';
      if (!taken.contains(id)) return id;
    }
    return 'ml-$day-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  }
}
