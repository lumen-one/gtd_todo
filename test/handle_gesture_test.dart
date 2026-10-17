import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';
import 'package:gtd_todo/ui/shells/android_shell.dart';

/// 把手手势与热区宽度设置（ui-interaction.md §6.0 / §9 第 10 条）。
///
/// v1.21 的口径：**展开只认拖动**——点按（含"蹭一下"）不再展开，朝屏内拖过
/// 72dp（或快甩）才展开；热区宽度是设置项，两处把手共用同一个值。
/// 面板左边缘：展开时落在屏内（x=6），收起时整块滑出屏外（右或左，看停靠侧）。
double panelLeft(WidgetTester tester) =>
    tester.getRect(find.byType(ResizablePanel)).left;

/// 装一次安卓壳（把手里唯一会走真实 IO 的是设置装载，这里给的是内存 port）。
Future<AppController> pumpShell(WidgetTester tester,
    {bool panelSizeLocked = false}) async {
  final svc = TaskService(
    repo: MemoryTaskRepository(),
    scheduler: const SlackScheduler(),
    workRule: WorkTimeRule.standard,
    clock: () => DateTime(2026, 10, 7, 10, 0),
  );
  final controller = AppController(
    service: svc,
    taskDir: 'ignored',
    settingsPort: _MemorySettingsPort(
      // guideSeen：否则首次展开会弹引导对话框，干扰几何断言。
      AppSettings.defaults.copyWith(
          guideSeen: true, panelSizeLocked: panelSizeLocked),
    ),
  );
  // 固定一块 400×800 的逻辑屏面：把手的几何（热区 200dp 高、白条竖直居中）
  // 由此推出，断言才好写死。
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(controller.bootstrap);
  await tester.pumpWidget(MaterialApp(home: AndroidShell(controller: controller)));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('把手热区宽度设置', () {
    test('缺省 12dp；三档值与夹取范围一致', () {
      expect(AppSettings.defaults.handleHotWidth, 12);
      expect(handleHotWidthOptions, [8, 12, 20]);
      expect(minHandleHotWidth, 8);
      expect(maxHandleHotWidth, 20);
    });

    test('落 json 的 handle_hot_width；缺键回默认、越界夹回区间', () {
      final s = AppSettings.defaults.copyWith(handleHotWidth: 20);
      expect(decodeSettings(encodeSettings(s)).handleHotWidth, 20);

      // 老设置文件没有这个键 → 默认档，不报错。
      expect(decodeSettings('{}').handleHotWidth, 12);
      // 手改坏了：太小 / 太大 / 不是数字，一律夹回区间或回默认。
      expect(decodeSettings('{"handle_hot_width": 1}').handleHotWidth, 8);
      expect(decodeSettings('{"handle_hot_width": 999}').handleHotWidth, 20);
      expect(decodeSettings('{"handle_hot_width": "wide"}').handleHotWidth, 12);
    });
  });

  group('应用内把手手势', () {
    /// 把手白条上的一点（右边停靠：贴着屏右缘；热区 200dp 高、白条竖直居中）。
    const barCenter = Offset(400 - 3, 180 + 100);

    testWidgets('点按把手不展开（v1.21：点按不再是入口）', (tester) async {
      await pumpShell(tester);
      final closed = panelLeft(tester);
      expect(closed, greaterThan(0), reason: '先确认初始是收起态（滑出到屏外右侧）');

      await tester.tapAt(barCenter);
      await tester.pumpAndSettle();

      expect(panelLeft(tester), closed, reason: '点按过后面板仍在屏外');
    });

    testWidgets('蹭一下不算：横拖 30dp 不展开', (tester) async {
      await pumpShell(tester);
      final closed = panelLeft(tester);

      // 300ms 拖 30dp ≈ 100 逻辑 px/s：远低于快甩阈值（只可能靠距离判定），
      // 又比长按的 500ms 快——慢过它就被判成长按换边了（Flutter 的触摸
      // slop 是 18dp，30dp 够在长按到期前脱离）。
      await tester.timedDragFrom(
        barCenter,
        const Offset(-30, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();

      expect(panelLeft(tester), closed);
    });

    testWidgets('朝屏内拖过 72dp 才展开', (tester) async {
      await pumpShell(tester);
      final closed = panelLeft(tester);

      // 300ms 拖 100dp ≈ 333 逻辑 px/s（低于快甩阈值）：判展开靠的是 72dp 距离。
      await tester.timedDragFrom(
        barCenter,
        const Offset(-100, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();

      expect(panelLeft(tester), lessThan(closed), reason: '面板滑进屏内');
    });

    testWidgets('长按换边：停靠侧翻到左边（收起态的落点跟着翻）', (tester) async {
      await pumpShell(tester);
      expect(panelLeft(tester), greaterThan(0), reason: '初始停靠右侧');

      await tester.longPressAt(barCenter);
      await tester.pumpAndSettle();

      expect(panelLeft(tester), lessThan(0), reason: '换边后收起态滑到屏外左侧');
    });
  });

  group('尺寸固定后面板跟手推出收起', () {
    /// 面板内侧竖把手（12dp 宽那条）：固定后它不再改宽，改管收起。
    ///
    /// 屏缘那条把手的热区（12×200）与长按靶（12×92）也是 12dp 宽，所以
    /// 用"高度不设"把它俩排除掉——只有面板内这条是贴着面板高的。
    Finder innerGrip() => find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 12 && w.height == null);

    /// 展开面板，返回展开位的左缘——测试环境里屏面逻辑尺寸不听
    /// `setSurfaceSize` 的，所以断言只认相对位移（跟既有几条一致）。
    Future<double> pumpOpen(WidgetTester tester) async {
      final controller = await pumpShell(tester, panelSizeLocked: true);
      controller.requestOpenPanel();
      await tester.pumpAndSettle();
      final open = panelLeft(tester);
      expect(open, greaterThan(0), reason: '先确认已经展开（左缘落在屏内）');
      return open;
    }

    testWidgets('拖过面板宽的一半：松手滑出屏外收起', (tester) async {
      final open = await pumpOpen(tester);

      // 判定只看距离：朝屏外推过面板宽的一半即缩回（推 300dp，扣掉触摸
      // slop 也远过一半）。停靠右侧 = 往右推出去，所以左缘是往大走。
      await tester.drag(innerGrip(), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(panelLeft(tester), greaterThan(open), reason: '面板被推出屏外');
    });

    testWidgets('没过半：松手回弹到展开位', (tester) async {
      final open = await pumpOpen(tester);

      await tester.drag(innerGrip(), const Offset(40, 0));
      await tester.pumpAndSettle();

      expect(panelLeft(tester), closeTo(open, 0.5), reason: '不够一半，原地弹回');
    });

    testWidgets('回弹后还能接着拖（把手仍在原位）', (tester) async {
      final open = await pumpOpen(tester);

      await tester.drag(innerGrip(), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(panelLeft(tester), closeTo(open, 0.5));

      // 第二次拖够距离：面板照旧收起——第一次回弹没把状态留在半路。
      await tester.drag(innerGrip(), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(panelLeft(tester), greaterThan(open));
    });
  });
}

/// 内存版 SettingsPort：测试里不碰磁盘（bootstrap 只用它读一次）。
class _MemorySettingsPort implements SettingsPort {
  AppSettings current;

  _MemorySettingsPort(this.current);

  @override
  Future<AppSettings> load() async => current;

  @override
  Future<void> save(AppSettings settings) async {
    current = settings;
  }
}
