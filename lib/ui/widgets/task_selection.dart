import 'package:flutter/foundation.dart';

/// 多选（选择模式）的临时态（ui 文档 §10#23）：**整块面板一份，跨页保留**。
///
/// 纯 UI 状态——不进 [AppController]、不落盘、不跨引擎；面板收起后跟着 State 一起
/// 没，选中不会带到下一次会话。集合里存的是任务 id，**不缓存任务本体**：
/// "哪几件还能完成"由调用方拿 controller.tasks 现算（已完成页选中的东西不能再完成）。
class TaskSelection extends ChangeNotifier {
  bool _selecting = false;
  final Set<String> _ids = <String>{};

  bool get selecting => _selecting;

  /// 已选件数（含已完成的，用于"删除"那颗）。
  int get count => _ids.length;

  bool contains(String id) => _ids.contains(id);

  /// 已选 id 的快照——动作执行前后集合会被清空，调用方先把 List 拿走。
  List<String> get selectedIds => List.unmodifiable(_ids);

  /// 长按菜单里点『多选』：进选择模式，把刚长按的那条一并选上。
  void begin(String id) {
    _selecting = true;
    _ids
      ..clear()
      ..add(id);
    notifyListeners();
  }

  void toggle(String id) {
    if (!_selecting) return;
    if (!_ids.remove(id)) _ids.add(id);
    notifyListeners();
  }

  /// 退出（点『取消』，或批量动作已发出）。翻页**不**调它：选中跨页保留。
  void cancel() {
    if (!_selecting && _ids.isEmpty) return;
    _selecting = false;
    _ids.clear();
    notifyListeners();
  }
}
