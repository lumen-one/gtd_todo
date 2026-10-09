import 'package:flutter/material.dart';

/// 视觉规范（ui-interaction.md §8）：橙做强调色 + 中性底（纸白/深灰双模式）。
/// 橙只给关键元素：编号、确认键、"今日会响"徽标、裕度告急、逾期标记。
///
/// 主题预设（§9 第 7 条，v1.5 落地）：预设只换**强调色种子**与中性底，
/// 语义色（逾期橙红、时间徽标橙）保持不变——它们是状态语义，不是装饰。
/// 组件大量使用 `AppColors.accent`（进程内当前强调色，由装配点按设置
/// 在启动与切换时调用 [AppColors.applyPreset]），切换后整体重建即可生效。
enum AppThemePreset {
  orange('orange', '橙（默认）', Color(0xFFEF6C00)),
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

class AppColors {
  /// 当前强调色（主题预设的种子）；默认橙。
  static Color accent = AppThemePreset.orange.seed;

  /// 主橙（默认强调色的别名，历史代码与语义色参照用）。
  static const Color orange = Color(0xFFEF6C00);

  /// 逾期橙红（比主橙更红）——状态语义，不随预设变化。
  static const Color overdue = Color(0xFFD84315);

  /// 固定时点的时间徽标橙——状态语义，不随预设变化。
  static const Color timeBadge = Color(0xFFF57C00);

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
  );
}

/// 编号样式：大而醒目（强调色），今日清单的主视觉锚点。
TextStyle numberStyle(TextTheme t) =>
    (t.titleLarge ?? const TextStyle()).copyWith(
      color: AppColors.accent,
      fontWeight: FontWeight.w800,
      fontSize: 18,
    );
