import 'package:flutter/material.dart';

import '../../domain/branch.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 『归到支线』（panels/branch.md『从任务这一侧归堆』）：长按菜单点进来，
/// 一个可见状态的勾选清单。
///
/// **勾选而不是单选**：一件任务本来就能同时挂在几条线上（支线文件里每条线各
/// 存一份引用），所以这里一勾一放、再点一下拿出来，顺手把"从这条线挪走"也
/// 做了——不必先回支线页。
Future<void> showBranchPickSheet(
    BuildContext context, AppController controller, Task task) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BranchPickSheet(controller: controller, task: task),
  );
}

class BranchPickSheet extends StatefulWidget {
  final AppController controller;
  final Task task;

  const BranchPickSheet(
      {super.key, required this.controller, required this.task});

  @override
  State<BranchPickSheet> createState() => _BranchPickSheetState();
}

class _BranchPickSheetState extends State<BranchPickSheet> {
  /// 底部『新建一条支线』的输入框开着。
  bool _creating = false;

  final TextEditingController _name = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branches = widget.controller.branches;
    final hint = theme.colorScheme.onSurfaceVariant;

    return SafeArea(
      child: Padding(
        // 键盘起来时整个 sheet 往上让（与编辑表单同一招）。
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('归到支线',
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        // 标题只留一行：长按是从某一件任务上进来的，得让人
                        // 确认自己按的是哪一件。
                        Text(
                          widget.task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: hint),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (branches.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Text(
                  '还没有支线。在下面新建一条，这件任务会直接放进去。',
                  style: theme.textTheme.bodySmall?.copyWith(color: hint),
                ),
              )
            else
              ConstrainedBox(
                // 支线多了不能顶满整屏：这一层只放清单，新建入口要一直看得见。
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: branches.length,
                  itemBuilder: (context, i) => _tile(theme, i, branches[i]),
                ),
              ),
            const Divider(height: 1),
            _creating ? _createRow(theme) : _newRow(theme),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _tile(ThemeData theme, int index, Branch branch) {
    final on = branch.contains(widget.task.id);
    return CheckboxListTile(
      value: on,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(branch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${branch.entries.length} 件',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      // 勾上 = 加进去，取消 = 拿出来。两个方向都在这一下里。
      onChanged: (v) => v == true
          ? widget.controller.addTaskToBranch(index, widget.task.id)
          : widget.controller.removeTaskFromBranch(index, widget.task.id),
    );
  }

  Widget _newRow(ThemeData theme) => ListTile(
        leading: Icon(Icons.create_new_folder_outlined, color: AppColors.accent),
        title: const Text('新建一条支线…'),
        onTap: () {
          setState(() {
            _creating = true;
            _name.clear();
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focus.requestFocus();
          });
        },
      );

  Widget _createRow(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                focusNode: _focus,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(hintText: '这条线叫什么'),
                onSubmitted: (_) => _create(),
              ),
            ),
            IconButton(
              tooltip: '建这条线',
              icon: const Icon(Icons.check),
              onPressed: _create,
            ),
            IconButton(
              tooltip: '取消',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _creating = false),
            ),
          ],
        ),
      );

  /// 建一条线，并把这件任务直接放进去——从"这件任务该归到哪"出发的人，
  /// 十有八九要的就是这一下。建完留在原地：可能还想勾别的线。
  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _creating = false);
      return;
    }
    await widget.controller.addBranch(name);
    final index = widget.controller.branches.length - 1;
    await widget.controller.addTaskToBranch(index, widget.task.id);
    if (!mounted) return;
    _name.clear();
    setState(() => _creating = false);
    FocusScope.of(context).unfocus();
  }
}
