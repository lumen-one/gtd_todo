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
    /// 装一次安卓壳（把手里唯一会走真实 IO 的是设置装载，这里给的是内存 port）。
    Future<AppController> pumpShell(WidgetTester tester) async {
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
          AppSettings.defaults.copyWith(guideSeen: true),
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

    /// 面板左边缘：展开时落在屏内，收起时整块滑出屏外（右或左，看停靠侧）。
    double panelLeft(WidgetTester tester) =>
        tester.getRect(find.byType(ResizablePanel)).left;

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
