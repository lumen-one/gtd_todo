import 'package:flutter/material.dart';

/// 视觉规范（ui-interaction.md §8）：橙做强调色 + 中性底（纸白/深灰双模式）。
/// 橙只给关键元素：编号、确认键、"今日会响"徽标、裕度告急、逾期标记。
///
/// 主题预设（§9 第 7 条，v1.5 落地）：预设只换**强调色种子**与中性底，
/// 语义色（逾期橙红、时间徽标橙）保持不变——它们是状态语义，不是装饰。
/// 组件大量使用 `AppColors.accent`（进程内当前强调色，由装配点按设置
/// 在启动与切换时调用 [AppColors.applyPreset]），切换后整体重建即可生效。
enum AppThemePreset {
  orange('orange', '橙', Color(0xFFEF6C00)),
  ink('ink', '墨蓝', Color(0xFF1E5AA8)),
  moss('moss', '苔绿', Color(0xFF2E7D50)),
  plum('plum', '梅紫', Color(0xFF8E3B7A));

  const AppThemePreset(this.id, this.label, this.seed);

  final String id;
  final String label;
  final Color seed;

  static AppThemePreset fromId(String? id) => AppThemePreset.values.firstWhere(
        (p) => p.id == id,
        orElse: () => AppThemePreset.orange,
      );
}

/// 明暗模式（§8）：**跟随系统（默认）/ 浅色 / 深黑**，一组三选一。
///
/// 与 [AppThemePreset] 正交：预设换**强调色种子**，明暗换**中性底与明度**。
/// 设置里存 id（`settings.json` 的 `theme_mode`），枚举与 [themeMode] 映射
/// 都在这里——application 层只看见字符串，同 [AppThemePreset] 的模式。
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深黑');

  const AppThemeMode(this.id, this.label);

  final String id;
  final String label;

  static AppThemeMode fromId(String? id) => AppThemeMode.values.firstWhere(
        (m) => m.id == id,
        orElse: () => AppThemeMode.system,
      );

  /// 映射成 Flutter 的 ThemeMode（两个引擎的 MaterialApp 消费它）。
  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };
}

class AppColors {
  /// 当前强调色（主题预设的种子）；默认橙。
  static Color accent = AppThemePreset.orange.seed;

  /// 主橙（默认强调色的别名，历史代码与语义色参照用）。
  static const Color orange = Color(0xFFEF6C00);

  /// 逾期橙红（比主橙更红）——状态语义，不随预设变化。
  static const Color overdue = Color(0xFFD84315);

  /// 逾期橙红的**暗色提亮变体**（§8）：同一个"逾期"语义，在深色底上换亮一档，
  /// 把小字徽标的对比度从约 3.4:1 拉到约 5.5:1。语义色"不随预设变"与
  /// "随明暗提亮"是两回事——前者防装饰性漂移，后者保可读性。
  static const Color overdueOnDark = Color(0xFFFF7043);

  /// 当前明暗下的逾期色：徽标 / 圆点 / 组头统一走这里，别直接引 [overdue]。
  static Color overdueFor(Brightness brightness) =>
      brightness == Brightness.dark ? overdueOnDark : overdue;

  /// 开始型的时间徽标橙——状态语义，不随预设变化。
  static const Color timeBadge = Color(0xFFF57C00);

  /// 已完成蓝（§8）：日历上"这天有已经干完的"那颗点。它要跟橙点同屏并存，
  /// 所以不能取强调色，也不能取灰（灰在日历上跟"这天没事"太接近）。
  static const Color done = Color(0xFF3F7FA6);

  /// 已完成蓝的暗色提亮变体：与 [overdueOnDark] 同一个理由（保可读性）。
  static const Color doneOnDark = Color(0xFF7FB3D5);

  /// 当前明暗下的已完成色：日历的点与当天列表走这里。
  static Color doneFor(Brightness brightness) =>
      brightness == Brightness.dark ? doneOnDark : done;

  /// 纸白底。
  static const Color paper = Color(0xFFFAF7F2);

  /// 深灰底。
  static const Color darkSurface = Color(0xFF1E1B18);

  static const Color darkCard = Color(0xFF2A2622);

  /// 应用主题预设（装配点在启动与设置变更时调用）。
  static void applyPreset(AppThemePreset preset) => accent = preset.seed;
}

ThemeData buildAppTheme(Brightness brightness,
    {AppThemePreset preset = AppThemePreset.orange}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: preset.seed,
    brightness: brightness,
  );
  final isDark = brightness == Brightness.dark;
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: isDark ? AppColors.darkSurface : AppColors.paper,
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? AppColors.darkCard : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: EdgeInsets.zero,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: preset.seed,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    // 暗色一致性（§8）：AppBar 与 scaffold 同底——M3 默认给 AppBar 一层
    // surfaceTint，暗底下会染出种子色、和内容区分层；浅色保持现状不动。
    appBarTheme: isDark
        ? const AppBarTheme(
            backgroundColor: AppColors.darkSurface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          )
        : null,
    // 暗色：弹窗 / bottom sheet 用卡色（darkCard），与 Card 同一层——
    // 默认的 surface 比卡还暗，对话框会"沉"进背景。
    dialogTheme: isDark
        ? const DialogThemeData(backgroundColor: AppColors.darkCard)
        : null,
    bottomSheetTheme: isDark
        ? const BottomSheetThemeData(backgroundColor: AppColors.darkCard)
        : null,
  );
}

/// 编号样式：大而醒目（强调色），今日清单的主视觉锚点。
TextStyle numberStyle(TextTheme t) =>
    (t.titleLarge ?? const TextStyle()).copyWith(
      color: AppColors.accent,
      fontWeight: FontWeight.w800,
      fontSize: 18,
    );

/// 一次性淡入 + 轻微上移：空态、刚浮出来的按钮块用它。
///
/// 只是一段 260ms 的出现动画，不需要控制器与状态——TweenAnimationBuilder
/// 自己把 0→1 跑一遍就结束，页面来回切时重建即重播。
class FadeIn extends StatelessWidget {
  final Widget child;

  /// 起始位移（dp）：淡入的同时从下方 [offset] 处归位。
  final double offset;

  const FadeIn({super.key, required this.child, this.offset = 8});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * offset),
            child: child,
          ),
        ),
        child: child,
      );
}

/// 对话框进出：从 0.94 倍缩放 + 淡入（220ms 缓出）。
///
/// 系统默认的 showDialog 只有遮罩渐显，对话框本体是硬切；给一点缩放之后
/// "它是从页面上长出来的"，而不是"贴在屏幕上"。所有自绘对话框统一走这里，
/// 免得各写一套过渡。
Future<T?> showScaledDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) => builder(context),
      transitionBuilder: (context, animation, _, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
