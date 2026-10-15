import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/settings_panel.dart';
import 'package:gtd_todo/ui/theme.dart';

/// 暗黑模式契约（ui-interaction.md §8 / §10 #20）：明暗三选一落
/// `settings.json` 的 `theme_mode`，缺省跟随系统；枚举与 ThemeMode 映射在
/// UI 层；语义色只有逾期橙红随明暗提亮，其余不变。
void main() {
  group('AppSettings.themeMode', () {
    test('默认跟随系统（老设置文件缺键即此值）', () {
      expect(AppSettings.defaults.themeMode, 'system');
      expect(AppSettings.fromJson(const {}).themeMode, 'system');
    });

    test('JSON 往返保留 theme_mode', () {
      for (final mode in const ['system', 'light', 'dark']) {
        final s = AppSettings.defaults.copyWith(themeMode: mode);
        expect(decodeSettings(encodeSettings(s)).themeMode, mode);
      }
    });

    test('未知值原样存、映射处回落（与 themePreset 同款约定）', () {
      // 设置层只存 id 不做 sanitize；认不出来的值由 AppThemeMode.fromId
      // 回落 system（见下一组）。两条兜底加起来才"不炸"。
      expect(AppSettings.fromJson(const {'theme_mode': '蓝天'}).themeMode, '蓝天');
      expect(AppThemeMode.fromId('蓝天'), AppThemeMode.system);
    });

    test('copyWith 不动其他字段', () {
      final s = AppSettings.defaults.copyWith(themeMode: 'dark');
      expect(s.themePreset, 'orange'); // 预设与明暗正交
    });
  });

  group('AppThemeMode', () {
    test('id 映射，未知回落 system', () {
      expect(AppThemeMode.fromId('system'), AppThemeMode.system);
      expect(AppThemeMode.fromId('light'), AppThemeMode.light);
      expect(AppThemeMode.fromId('dark'), AppThemeMode.dark);
      expect(AppThemeMode.fromId(null), AppThemeMode.system);
      expect(AppThemeMode.fromId('nope'), AppThemeMode.system);
    });

    test('映射 Flutter ThemeMode', () {
      expect(AppThemeMode.system.themeMode, ThemeMode.system);
      expect(AppThemeMode.light.themeMode, ThemeMode.light);
      expect(AppThemeMode.dark.themeMode, ThemeMode.dark);
    });
  });

  group('buildAppTheme', () {
    test('浅色 = 纸白底 + 白卡', () {
      final t = buildAppTheme(Brightness.light);
      expect(t.scaffoldBackgroundColor, AppColors.paper);
      expect(t.cardTheme.color, Colors.white);
    });

    test('深色 = 暖深褐黑底 + 深卡（不是纯黑）', () {
      final t = buildAppTheme(Brightness.dark);
      expect(t.scaffoldBackgroundColor, AppColors.darkSurface);
      expect(t.cardTheme.color, AppColors.darkCard);
      expect(AppColors.darkSurface, const Color(0xFF1E1B18));
    });

    test('深色：AppBar 与 scaffold 同底、弹窗用卡色', () {
      final t = buildAppTheme(Brightness.dark);
      expect(t.appBarTheme.backgroundColor, AppColors.darkSurface);
      expect(t.dialogTheme.backgroundColor, AppColors.darkCard);
      expect(t.bottomSheetTheme.backgroundColor, AppColors.darkCard);
    });

    test('强调色种子决定 filledButton 底色（预设正交于明暗）', () {
      // backgroundColor 在这个 Flutter 版本是 WidgetStateMapper，取 any 态的值。
      Color? btnBg(ThemeData t) => t.filledButtonTheme.style?.backgroundColor
          ?.resolve(const <WidgetState>{});
      final light = buildAppTheme(Brightness.light, preset: AppThemePreset.ink);
      final dark = buildAppTheme(Brightness.dark, preset: AppThemePreset.ink);
      expect(btnBg(light), AppThemePreset.ink.seed);
      expect(btnBg(dark), AppThemePreset.ink.seed);
    });
  });

  group('语义色（§8：不随预设变，逾期橙红随明暗提亮）', () {
    test('逾期橙红：浅色原值、暗色提亮变体', () {
      expect(AppColors.overdueFor(Brightness.light), AppColors.overdue);
      expect(AppColors.overdueFor(Brightness.dark), AppColors.overdueOnDark);
      expect(AppColors.overdueOnDark, isNot(AppColors.overdue));
    });

    test('时间徽标橙不随明暗变（暗底对比度已达标）', () {
      // 它是 const，两种明暗同一个值——这里锁住"不为暗色另设变体"的口径。
      expect(AppColors.timeBadge, const Color(0xFFF57C00));
    });
  });

  group('设置页：明暗三选一（§9 第 7 条）', () {
    testWidgets('点「深黑」→ 设置的 themeMode 立即切到 dark', (tester) async {
      final svc = TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => DateTime(2026, 10, 15, 9, 0),
      );
      final controller = AppController(service: svc, taskDir: '/tmp/tasks');
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPanel(controller: controller)),
      ));
      await tester.pumpAndSettle();

      // 没 bootstrap 过 = 出厂默认：跟随系统。
      expect(controller.settings.themeMode, 'system');
      expect(controller.themeMode, ThemeMode.system);

      // 主题节在设置列表下方（ListView 懒加载）：滚到可见再点。
      final target = find.text('深黑');
      await tester.scrollUntilVisible(target, 240,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();

      // 切换立即生效：控制器（进而两个引擎的 MaterialApp）立刻读到暗色。
      expect(controller.settings.themeMode, 'dark');
      expect(controller.themeMode, ThemeMode.dark);
    });
  });
}
