/// 支线（ui-interaction.md §6.12；存储格式见 docs/formats/branch.md）。
///
/// 支线与任务、周期、主线、编排四套都不相交：条目只是任务的 id，没有完成态、不进
/// 调度、不占工时、不响提醒。勾选与改期都落在任务本身上，所以这里连 `Task` 都不认识。
library;

/// 支线里的一行：指向一个任务。
///
/// [title] 是读盘时的快照（文件里那行也写着它，给人读）；界面显示与落盘都以任务的
/// 实时标题为准，所以它可能过期，**不当身份用**。
class BranchEntry {
  final String taskId;

  final String title;

  const BranchEntry({required this.taskId, required this.title});

  BranchEntry copyWith({String? title}) =>
      BranchEntry(taskId: taskId, title: title ?? this.title);

  @override
  String toString() => 'BranchEntry($taskId, $title)';
}

/// 一条支线 = 名字 + 有序的任务引用。
///
/// 段序就是卡片在界面上的先后，行序就是任务的先后；拖动只改行序，不排序。
class Branch {
  final String name;

  final List<BranchEntry> entries;

  Branch({required this.name, List<BranchEntry> entries = const []})
      : entries = List.unmodifiable(entries);

  bool get isEmpty => entries.isEmpty;

  /// 这条线里有没有这个任务。一条线里只出现一次；不同支线之间允许重复。
  bool contains(String taskId) => entries.any((e) => e.taskId == taskId);

  Branch copyWith({String? name, List<BranchEntry>? entries}) => Branch(
        name: name ?? this.name,
        entries: entries ?? this.entries,
      );

  @override
  String toString() => 'Branch($name, ${entries.length} 条)';
}
