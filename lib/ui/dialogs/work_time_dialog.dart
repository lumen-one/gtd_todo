import 'package:flutter/material.dart';

import '../app_controller.dart';

String _mm(int minuteOfDay) {
  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

const List<String> _dayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// **工作时间**编辑（设置页 §9 第 13 条，v1.26）：哪几天算工作日 + 那几天的工作窗。
///
/// 这是 slack 的分母，不是外观偏好：改完 `available` 全变，所有锚点作废重算
/// （由 `TaskService.updateWorkRule` 负责，这里只管收集与校验）。
///
/// 两个入口共用一个面板：设置页「工作时间」、桌面标题栏的「工作时间规则」。
/// 校验口径与 `clampWorkDays` / `clampWorkWindows` 一致：一天不选不保存、
/// 一段不留不保存、`start < end` 否则当场拒绝改。
Future<void> showWorkTimeDialog(BuildContext context, AppController c) async {
  final days = {...c.settings.workDays};
  final windows = [
    for (final w in c.settings.workWindows) [w[0], w[1]]
  ];
  if (windows.isEmpty) windows.add([9 * 60, 12 * 60]);

  Future<void> pick(int index, bool isStart) async {
    final cur = windows[index][isStart ? 0 : 1];
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
    );
    if (t == null) return;
    final v = t.hour * 60 + t.minute;
    if (isStart ? v >= windows[index][1] : v <= windows[index][0]) return;
    windows[index][isStart ? 0 : 1] = v;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final canSave = days.isNotEmpty && windows.isNotEmpty;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('工作时间',
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '决定"还有多少可用工时"，也就是裕度的分母。改完所有提醒会重算。',
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text('哪几天上班', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        label: Text('周${_dayNames[i]}'),
                        selected: days.contains(i + 1),
                        onSelected: (on) => setSheet(() {
                          if (on) {
                            days.add(i + 1);
                          } else {
                            days.remove(i + 1);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('上班时间段（多段式）',
                    style: Theme.of(ctx).textTheme.labelLarge),
                for (var i = 0; i < windows.length; i++)
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            await pick(i, true);
                            setSheet(() {});
                          },
                          child: Text(_mm(windows[i][0])),
                        ),
                      ),
                      const Text('–'),
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            await pick(i, false);
                            setSheet(() {});
                          },
                          child: Text(_mm(windows[i][1])),
                        ),
                      ),
                      IconButton(
                        tooltip: '删掉这一段',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: windows.length <= 1
                            ? null
                            : () => setSheet(() => windows.removeAt(i)),
                      ),
                    ],
                  ),
                TextButton.icon(
                  onPressed: () {
                    if (windows.length >= 4) return;
                    setSheet(() {
                      final last = windows.last;
                      final start = last[1] < 18 * 60 ? last[1] : 18 * 60;
                      windows.add([start, (start + 120).clamp(0, 24 * 60)]);
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('加一段'),
                ),
                if (!canSave)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('至少选一天、留一段时间',
                        textAlign: TextAlign.center,
                        style: Theme.of(ctx)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(ctx).colorScheme.error)),
                  ),
                FilledButton(
                  onPressed: !canSave
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          final sorted = days.toList()..sort();
                          c.updateSettings(c.settings.copyWith(
                            workDays: sorted,
                            workWindows: [
                              for (final w in windows) [w[0], w[1]]
                            ],
                          ));
                        },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 摘要文案（设置页那一行的副标题）："周一至周五 · 09:00–12:00、13:30–18:00"。
String workTimeSummary(List<int> days, List<List<int>> windows) {
  final ws = windows.map((w) => '${_mm(w[0])}–${_mm(w[1])}').join('、');
  return '${describeWorkDays(days)} · $ws';
}

/// 工作日的人话写法：每天 / 周一至周五 / 逐个列。
String describeWorkDays(List<int> days) => switch (days.length) {
      7 => '每天',
      5 when const [1, 2, 3, 4, 5].every(days.contains) => '周一至周五',
      _ => days.map((d) => '周${_dayNames[d - 1]}').join('、'),
    };
