import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/settings.dart';
import '../../domain/schedule.dart';
import '../app_controller.dart';
import '../dialogs/settings_notes_path_dialog.dart';
import '../dialogs/settings_windows_dialog.dart';
import '../dialogs/work_time_dialog.dart';
import '../panel_pages.dart';
import '../theme.dart';
import 'settings_permissions.dart';
import 'settings_routines.dart';
import 'settings_sync.dart';
// panelWidthFor / panelAvailableHeight：固定尺寸时要用它们把"此刻生效"的宽高
// 算成数字（§6.0）。
import 'side_panel.dart';

/// 反馈用的 QQ：『关于』卡里点整行就把它复制走。
const String _feedbackQq = '3110741060';

/// 仓库地址（§9 第 14 条）：与 QQ 同一套做法——点整行复制，不引 `url_launcher`。
/// 行尾不写『点一下复制』：一长串地址再缀四个字，窄栏里必然折成第二行。
const String _repoUrl = 'https://github.com/lumen-one/gtd_todo';

String _mm(int minuteOfDay) {  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// 两档调度模式的说明（决议 43 + 决定卡 mode-as-information-depth 的 10-29 修订二）：
/// 标准 → 无排序，**逐级弱化**算法替人做主的程度，所以它们是一组二选一，
/// 不是两个互不相干的开关。
///
/// 界面上只留半句（"谁排前后 / 出不出声"），细化解释不去挤窄屏——两档的差别
/// 用户切一下就体会到了。
String _modeHint(ScheduleMode mode) => switch (mode) {
      ScheduleMode.standard => '标准：排先后，提醒按裕度节奏',
      ScheduleMode.manual => '无排序：不排，截止前与截止各提醒一次',
    };

/// 无排序档提前量的四个常用落点（分钟）：15 分 / 半小时 / 1 小时 / 2 小时。
/// 落盘存分钟数，这里只是四个快捷值——设置文件被手改成别的数也照用。
const List<int> _leadOptions = [15, 30, 60, 120];

String _leadLabel(int minutes) => minutes % 60 == 0
    ? '${minutes ~/ 60} 小时'
    : '$minutes 分';

/// 二选一按钮（选中=实心，其余=描边）：比 SegmentedButton 放得下三个字以上的标签，
/// 也不会在窄面板里被挤成省略号。
Widget _modeButton(AppController c, AppSettings s, ScheduleMode mode) {
  final label = switch (mode) {
    ScheduleMode.standard => '标准',
    ScheduleMode.manual => '无排序',
  };
  final selected = s.scheduleMode == mode;
  final onPressed = () => c.updateSettings(s.copyWith(scheduleMode: mode));
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: selected
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label)),
  );
}

/// 热区宽度的取舍一句话（§6.0）：白条只有 6dp 宽，能起手靠的是外面这块透明热区；
/// 选的是"好抓"与"不挡路"的折中点——热区盖住的触摸归把手，底下的界面收不到。
String _hotWidthHint(int dp) => switch (dp) {
      minHandleHotWidth => '细（${minHandleHotWidth}dp）：最不挡路，起手要贴边',
      defaultHandleHotWidth =>
        '标准（${defaultHandleHotWidth}dp）：好抓与不挡路的折中',
      _ => '宽（${maxHandleHotWidth}dp）：最好抓，边上那一竖条更挡路',
    };

/// 三选一按钮（同 [_modeButton]：选中=实心，其余=描边）。
Widget _hotWidthButton(AppController c, AppSettings s, int dp) {
  final label = switch (dp) {
    minHandleHotWidth => '细',
    defaultHandleHotWidth => '标准',
    _ => '宽',
  };
  final onPressed = () => c.setHandleHotWidth(dp);
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: s.handleHotWidth == dp
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label)),
  );
}

/// 设置页（ui-interaction.md §9，暂定 App 唯一主体页面）：
/// 1. 权限引导〔悬浮壳〕；2. 任务目录；3. 侧边栏（**展开后默认页面** /
/// 固定把手位置〔悬浮壳〕 / 固定侧边栏大小〔悬浮壳〕 /
/// 把手热区宽度〔悬浮壳〕 / 重看首次引导〔悬浮壳〕）；
/// 4. 周期任务管理（routines.md）；5. **工作时间（工作日 + 工作窗，slack 的分母）**；
/// 6. 提醒与排序（**调度模式两档：标准/无排序** + 『问重要度』开关 + AI 编排入口位 +
/// 时间段多段式 + 闹钟模式〔悬浮壳〕）；
/// 7. 定期挑；8. 灵感文件路径；9. 周期任务在任务池的显示开关；
/// 10. 主题（**明暗三选一：跟随系统/浅色/深黑** + 强调色预设）；
/// 11. 回收站；12. 同步（§4.4：主机/从机，局域网文件同步）；13. 关于（版本号 + 反馈）。
///
/// 标〔悬浮壳〕的项按 `AppController.caps` 整行裁掉（§9 开头）：桌面上它们
/// 没有对应物，留着只会点了个没反应。
class SettingsPanel extends StatefulWidget {
  final AppController controller;

  const SettingsPanel({super.key, required this.controller});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _c.refreshTrash();
    // 版本号是异步从安装包元数据里读的，进设置页时问一次就够（幂等）。
    // 桌面上没有这张卡，也就不必去问平台。
    if (_c.caps.about) _c.loadAppVersion();
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = _c.settings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 40),
      children: [
        // 权限只对"贴屏悬浮壳"有意义：桌面窗口不需要悬浮窗/精确闹钟/电池白名单，
        // 插座本身也是"默认已授予"（§9 开头那张能力表）。
        if (_c.caps.permissionPrompts)
          _SectionCard('权限引导', [SettingsPermissionsSection(controller: _c)]),

        _SectionCard('任务目录', _taskDirSection(s)),

        _SectionCard('侧边栏', _panelSection(s)),

        _SectionCard('同步', [SettingsSyncSection(controller: _c)]),

        _SectionCard('工作时间', _workTimeSection(s)),

        _SectionCard('提醒与排序', _reminderSection(s)),

        _SectionCard('周期任务', [
          SettingsRoutinesSection(controller: _c),
          SwitchListTile(
            secondary: const Icon(Icons.view_list_outlined),
            title: const Text('在任务池计划段显示'),
            subtitle: const Text('按下一次发生日期插入计划段'),
            value: s.routineShowInPool,
            onChanged: (v) =>
                _c.updateSettings(s.copyWith(routineShowInPool: v)),
          ),
        ]),

        _SectionCard('定期挑', _pickSection(s)),

        _SectionCard('灵感', [_notesSection(s)]),

        _SectionCard('主题', _themeSection(s)),

        _SectionCard('回收站', [_trashSection()]),

        if (_c.caps.about) _SectionCard('关于', _aboutSection()),
      ],
    );
  }

  // ---------- 分区构建 ----------

  List<Widget> _taskDirSection(AppSettings s) => [
        ListTile(
          leading: const Icon(Icons.folder),
          title: const Text('任务目录'),
          subtitle: Text(_c.taskDir),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editTaskDir(context),
        ),
      ];

  /// 侧边栏区：默认页面 + 把手与尺寸（都只改"面板长什么样、停在哪儿"，
  /// 不动任何任务数据）。
  ///
  /// **按壳能力表裁剪**（§9 开头）：把手、把手参数、可拖尺寸、首次拖出引导
  /// 都只属于贴屏悬浮壳；桌面上整行不渲染，这一区只剩默认页面一项。
  List<Widget> _panelSection(AppSettings s) => [
        // 四选一（§9 第 12 条）。四个标签都是三到四个字，面板最窄 240dp 的
        // 四等分按钮会把"已完成"挤成省略号，所以用可换行的 chip。
        ListTile(
          leading: const Icon(Icons.tab_unselected_outlined),
          title: const Text('展开后默认页面'),
          // 桌面上没有"展开"这一步：它是重新打开窗口时左栏落在哪一页（§6.10）。
          subtitle: Text(_c.caps.systemHandle
              ? '拖动把手展开时落在这一页；点通知定位时按定位目标走'
              : '重新打开窗口时左栏落在这一页；点通知定位时按定位目标走'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final page in PanelPage.values)
                  ChoiceChip(
                    label: Text(page.label),
                    selected: _c.defaultPanelPage == page,
                    onSelected: (_) => _c.setDefaultPage(page),
                  ),
              ],
            ),
          ),
        ),
        if (_c.caps.handleTuning)
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: const Text('固定把手位置'),
            subtitle: const Text('上锁后把手不再跟着拖动上下移动；长按换边仍可用'),
            value: s.handleLocked,
            onChanged: (v) => _c.setHandleLocked(v),
          ),
        if (_c.caps.resizablePanel)
          SwitchListTile(
            secondary: const Icon(Icons.lock_reset),
            title: const Text('固定侧边栏大小'),
            subtitle: const Text(
                '按当前宽高锁住，不再能拖动改；改宽那条把手改成跟手推出收起'),
            value: s.panelSizeLocked,
            onChanged: (v) => v ? _lockPanelSize(context) : _c.unlockPanelSize(),
          ),
        if (_c.caps.handleTuning) ...[
          ListTile(
            leading: const Icon(Icons.swipe_right_alt),
            title: const Text('把手热区宽度'),
            subtitle: Text(_hotWidthHint(s.handleHotWidth)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Row(
              children: [
                // 三档由窄到宽：越宽越好抓，边上那一竖条也越挡路（§6.0）。
                for (final dp in handleHotWidthOptions)
                  Expanded(child: _hotWidthButton(_c, s, dp)),
              ],
            ),
          ),
        ],
        if (_c.caps.panelGuide)
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('重看首次引导'),
            onTap: () => _c.updateSettings(s.copyWith(guideSeen: false)),
          ),
      ];

  List<Widget> _reminderSection(AppSettings s) => [
        ListTile(
          leading: const Icon(Icons.tune_outlined),
          title: const Text('调度模式'),
          subtitle: Text(_modeHint(s.scheduleMode)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: [
              // 两档由强到弱：算法介入程度依次递减，一次只能选一个。
              // 不是三格——以前那第三格"完整"只是"标准 + 问重要度"，现在由下面
              // 那个开关表达，位置则留给 AI 编排（它不是一档，见下方占位条目）。
              for (final mode in ScheduleMode.values)
                Expanded(child: _modeButton(_c, s, mode)),
            ],
          ),
        ),
        // 『问重要度』（§7.0）：只在标准档出现——无排序档不跑公式，问了没处用。
        // 关掉时整个维度不参与：新建与编辑表单都不出现那一行，排序乘数取 1。
        if (s.scheduleMode == ScheduleMode.standard)
          SwitchListTile(
            secondary: const Icon(Icons.priority_high),
            title: const Text('问重要度'),
            subtitle: const Text('新建多问一项 1–5，并把它当排序乘数；关掉时按 1 算'),
            value: s.askImportance,
            onChanged: (v) => _c.updateSettings(s.copyWith(askImportance: v)),
          ),
        // 无排序档的提前量（§7.1）：这一档不跑裕度，两站提醒 = 这个值与任务时刻。
        // 只在无排序档出现——标准档按裕度节奏多次响，与它无关。
        if (s.scheduleMode.isManual)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('提前多久提醒（截止型与开始型同一套）',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in _leadOptions)
                      ChoiceChip(
                        showCheckmark: false,
                        label: Text(_leadLabel(m)),
                        selected: s.manualLeadMinutes == m,
                        onSelected: (_) => _c.updateSettings(
                            s.copyWith(manualLeadMinutes: m)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        // **AI 编排的入口位**（§9 第 9 条）：不可点，只写用途。位置留着、形状
        // 不承诺——它做的是记习惯、估工时、改截止、调参数，排在调度之上，不是
        // 第三档排序算法。做成灰的一条而不是第三颗模式按钮，就是为了不暗示
        // "选了它就不按裕度排了"。
        const ListTile(
          enabled: false,
          leading: Icon(Icons.auto_awesome_outlined),
          title: Text('AI 编排'),
          subtitle: Text('以后在这儿：记住你的习惯、自动估工时、语音改清单'),
        ),
        // 全屏闹钟是安卓的通知渠道；桌面到点只有应用内弹窗（§7.2）。
        // 它**覆盖**那一条本该走的通知栏投递，其余提醒照旧横幅 + 通知栏。
        if (_c.caps.alarmChannel)
          SwitchListTile(
            secondary: const Icon(Icons.alarm),
            title: const Text('闹钟模式'),
            subtitle: const Text('开始型到点用全屏闹钟覆盖通知栏；其余一律通知栏 + 横幅'),
            value: s.alarmMode,
            onChanged: (v) => _c.updateSettings(s.copyWith(alarmMode: v)),
          ),
        ListTile(
          leading: const Icon(Icons.timelapse),
          title: const Text('通知时间段（截止型任务）'),
          subtitle: Text(s.notificationWindows.isEmpty
              ? '不限制（全天送达）'
              : s.notificationWindows
                  .map((w) => '${_mm(w[0])}–${_mm(w[1])}')
                  .join('、')),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => showSettingsWindowsDialog(context, _c),
        ),
      ];

  List<Widget> _workTimeSection(AppSettings s) => [
        ListTile(
          leading: const Icon(Icons.work_outline),
          title: const Text('工作日与工作窗'),
          subtitle: Text(workTimeSummary(s.workDays, s.workWindows)),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => showWorkTimeDialog(context, _c),
        ),
      ];

  List<Widget> _pickSection(AppSettings s) => [
        SwitchListTile(
          secondary: const Icon(Icons.shuffle),
          title: const Text('每天从散件段挑一件'),
          subtitle: const Text('附到今日清单尾部，不响提醒'),
          value: s.pickEnabled,
          onChanged: (v) => _c.updateSettings(s.copyWith(pickEnabled: v)),
        ),
        if (s.pickEnabled)
          ListTile(
            leading: const Icon(Icons.update),
            title: const Text('间隔'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 天')),
                ButtonSegment(value: 3, label: Text('3 天')),
                ButtonSegment(value: 7, label: Text('7 天')),
              ],
              selected: {s.pickIntervalDays},
              onSelectionChanged: (v) =>
                  _c.updateSettings(s.copyWith(pickIntervalDays: v.first)),
            ),
          ),
      ];

  Widget _notesSection(AppSettings s) => ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('灵感文件路径'),
        subtitle: Text(s.notesPath ?? '未配置'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => showSettingsNotesPathDialog(context, _c),
      );

  List<Widget> _themeSection(AppSettings s) => [
        // 明暗三选一（§8）：与强调色预设正交——预设换种子，明暗换中性底。
        // 默认跟随系统；切换立即生效（两个引擎都读同一份 settings.json）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<AppThemeMode>(
              segments: const [
                ButtonSegment(
                    value: AppThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: AppThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: AppThemeMode.dark, label: Text('深黑')),
              ],
              selected: {AppThemeMode.fromId(s.themeMode)},
              onSelectionChanged: (v) =>
                  _c.updateSettings(s.copyWith(themeMode: v.first.id)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            children: [
              for (final preset in AppThemePreset.values)
                ChoiceChip(
                  // 选中只靠底色（§9 第 7 条）：默认那颗勾画在色点上，压掉的正
                  // 是这个预设自己——色点本身就是标识，不必再叠一层。
                  showCheckmark: false,
                  avatar: CircleAvatar(backgroundColor: preset.seed, radius: 8),
                  label: Text(preset.label),
                  selected: s.themePreset == preset.id,
                  onSelected: (_) =>
                      _c.updateSettings(s.copyWith(themePreset: preset.id)),
                ),
            ],
          ),
        ),
      ];

  Widget _trashSection() => ListTile(
        leading: const Icon(Icons.delete_sweep_outlined),
        title: Text('清空回收（${_c.trashTasks.length} 件）'),
        subtitle: const Text('删除的任务先进回收站，可捞回'),
        onTap: _c.trashTasks.isEmpty ? null : () => _purgeTrash(context),
      );

  // ---------- 关于（§9 第 14 条）----------

  /// 版本号由 [AppController.loadAppVersion] 从安装包元数据读回（安卓 versionName /
  /// versionCode），源码里不写死：升级只改 `pubspec.yaml`。
  List<Widget> _aboutSection() => [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('版本'),
          subtitle: Text(_c.appVersion ?? '读取中…'),
        ),
        ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: const Text('反馈'),
          subtitle: const Text('QQ $_feedbackQq'),
          onTap: _copyFeedback,
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('GitHub'),
          subtitle: const Text(_repoUrl),
          onTap: _copyRepoUrl,
        ),
      ];

  Future<void> _copyFeedback() async {
    await Clipboard.setData(const ClipboardData(text: _feedbackQq));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制 QQ：$_feedbackQq')));
  }

  Future<void> _copyRepoUrl() async {
    await Clipboard.setData(const ClipboardData(text: _repoUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制仓库地址：$_repoUrl')));
  }

  // ---------- 面板尺寸固定（§6.0 / §9 第 11 条）----------

  /// 固定 = 把**此刻生效**的宽高冻成数字：设置页拿得到屏宽与可用高度，冻的
  /// 才是用户眼下看到的那块（没拖过 = 冻住默认公式的结果）。之后换屏宽、
  /// 横竖屏都不再自适应——这正是"固定"要的意思。
  Future<void> _lockPanelSize(BuildContext context) async {
    final mq = MediaQuery.of(context);
    await _c.lockPanelSize(
      width: panelWidthFor(_c.settings, mq.size.width),
      height: panelHeightFor(_c.settings, panelAvailableHeight(context)),
    );
  }

  // ---------- 对话框 ----------

  Future<void> _editTaskDir(BuildContext context) async {
    final ctrl = TextEditingController(text: _c.taskDir);
    // isScrollControlled + viewInsets：底部弹窗不会自己给键盘让位，少了这两样
    // 输入框正好落在键盘底下（跟编辑任务表单同一招，见 edit_task_sheet.dart）。
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('任务目录', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('改动需重启应用生效',
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(labelText: '目录路径'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('用系统选择器挑一个目录'),
                  onPressed: () async {
                    final picked = await _c.pickTaskDir();
                    if (!ctx.mounted) return;
                    if (picked == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                          content: Text('未选择目录（或缺少"所有文件访问"权限）')));
                      return;
                    }
                    ctrl.text = picked;
                  },
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    final dir = ctrl.text.trim();
                    Navigator.of(ctx).pop();
                    if (dir.isEmpty || dir == _c.taskDir) return;
                    await _c.setTaskDir(dir);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已保存，重启应用后生效')));
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _purgeTrash(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('将真正删除回收站里的文件，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await _c.purgeTrash();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('回收站已清空')));
      }
    }
  }
}

/// 分区 = 橙色小标题 + 一张装着本区所有行的 Card。
///
/// 改卡片化的理由：设置页有八个区、三十来行，原来全平铺成一条长列表，只靠
/// 橙色标题分段——滚起来分不清哪几行属于哪一区。卡片让"区"成为看得见的块。
class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
            child: Text(title,
                style: theme.textTheme.labelLarge?.copyWith(
                    color: AppColors.accent, fontWeight: FontWeight.w700)),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}
