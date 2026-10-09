import 'package:flutter/material.dart';

import '../../domain/routine.dart';
import '../theme.dart';

/// 周期任务规则的创建/编辑对话框（ui-interaction.md §9 第 2 条、决议 10/23）。
/// 规则的增删改与"响不响"都在这里；实例是临时的，没有"编辑实例"。
Future<Routine?> showRoutineEditDialog(
  BuildContext context, {
  Routine? initial,
}) {
  return showDialog<Routine>(
    context: context,
    builder: (_) => _RoutineEditDialog(initial: initial),
  );
}

class _RoutineEditDialog extends StatefulWidget {
  final Routine? initial;

  const _RoutineEditDialog({this.initial});

  @override
  State<_RoutineEditDialog> createState() => _RoutineEditDialogState();
}

class _RoutineEditDialogState extends State<_RoutineEditDialog> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  late RoutineFrequency _freq;
  late Set<int> _weekdays;
  late bool _remind;
  TimeOfDay? _time;
  String? _error;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _title = TextEditingController(text: r?.title ?? '');
    _desc = TextEditingController(text: r?.description ?? '');
    _freq = r?.frequency ?? RoutineFrequency.daily;
    _weekdays = {...?r?.weekdays};
    _remind = r?.remind ?? false;
    final m = r?.minuteOfDay;
    _time = m == null ? null : TimeOfDay(hour: m ~/ 60, minute: m % 60);
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? '新建周期任务' : '编辑周期任务'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '标题',
                hintText: '例：晨跑 / 周报',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _desc,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: '备注（选填，进实例正文）',
              ),
            ),
            const SizedBox(height: 14),
            Text('频率', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<RoutineFrequency>(
              segments: const [
                ButtonSegment(value: RoutineFrequency.daily, label: Text('每天')),
                ButtonSegment(value: RoutineFrequency.weekly, label: Text('每周')),
              ],
              selected: {_freq},
              onSelectionChanged: (v) => setState(() => _freq = v.first),
            ),
            if (_freq == RoutineFrequency.weekly) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text('周${weekdayLabels[d - 1]}'),
                      selected: _weekdays.contains(d),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _weekdays.add(d);
                        } else {
                          _weekdays.remove(d);
                        }
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('指定时刻'),
              subtitle: Text(_time == null
                  ? '不限时刻（当天任意时候做）'
                  : '每天 ${_time!.hour.toString().padLeft(2, '0')}:'
                      '${_time!.minute.toString().padLeft(2, '0')}'),
              value: _time != null,
              onChanged: (on) => setState(() {
                _time = on
                    ? const TimeOfDay(hour: 9, minute: 0)
                    : null;
                if (!on) _remind = false;
              }),
            ),
            if (_time != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text('改时刻（${_time!.hour.toString().padLeft(2, '0')}:'
                      '${_time!.minute.toString().padLeft(2, '0')}）'),
                  onPressed: () async {
                    final t = await showTimePicker(
                        context: context, initialTime: _time!);
                    if (t != null) setState(() => _time = t);
                  },
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('到点提醒'),
              subtitle: Text(_time == null
                  ? '先指定时刻才能响（决议 18：时点性提醒）'
                  : '到点响一次；可选闹钟模式（全屏 + 持续响铃）'),
              value: _remind,
              onChanged: _time == null
                  ? null
                  : (on) => setState(() => _remind = on),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    if (_freq == RoutineFrequency.weekly && _weekdays.isEmpty) {
      setState(() => _error = '每周频率至少要选一天');
      return;
    }
    final base = widget.initial;
    final draft = Routine(
      id: base?.id ?? '',
      title: title,
      description: _desc.text.trim(),
      frequency: _freq,
      weekdays: _weekdays.toList()..sort(),
      minuteOfDay: _time == null ? null : _time!.hour * 60 + _time!.minute,
      remind: _remind,
      enabled: base?.enabled ?? true,
      created: base?.created ?? DateTime.now(),
      extra: base?.extra ?? const {},
    );
    try {
      draft.validate();
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
      return;
    }
    Navigator.of(context).pop(draft);
  }
}

/// 规则行（设置页）与实例标签共用的文案。
String routineSubtitle(Routine r) {
  final parts = <String>[
    r.frequencyText,
    r.timeText,
    if (r.remind) '到点提醒',
  ];
  return parts.join(' · ');
}

/// 规则行的强调色（预设切换后仍可读）。
Color routineAccent() => AppColors.accent;
