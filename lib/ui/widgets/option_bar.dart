import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 设置页的**选项组**（ui-interaction.md §9"选项组怎么排"）：等分格子，
/// 一行放不下就**均衡**折行。
///
/// 为什么不是 `Wrap` + `ChoiceChip`：`Wrap` 按次序填，四颗会折成 3 + 1——最后
/// 一颗孤零零挂在左边，看着像掉出来的。这里先按格子最小宽算出"一行放得下几个"，
/// 再让行数 × 每行个数**尽量相等**（四个放三个 → 2 + 2），末行不足的槽位用空白
/// 补齐，于是每行格子一样宽，整块像一个网格。
///
/// 为什么统一成按钮而不是三套控件：原先这一页并存 `Row + Expanded`（宁可压扁
/// 不折行）、`Wrap + ChoiceChip`（随便折）、`SegmentedButton`（超宽直接溢出），
/// 同一类选择三种长相、三种宽度策略。现在都走这里。
class OptionBar<T> extends StatelessWidget {
  /// 选项：值 + 标签。标签是**可见的那几个字**，长文案放副标题。
  final List<(T, String)> options;

  final T selected;

  final ValueChanged<T> onChanged;

  /// 可选的小色点（主题预设用）：色点本身就是标识，光靠两个字认「墨蓝」和
  /// 「梅紫」不如看一眼色。选中态给色点描白边——实心底就是当前强调色，撞上
  /// 同色预设时只有白边能分开。
  final Color? Function(T value)? swatch;

  const OptionBar({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.swatch,
  });

  /// 格与格之间、行与行之间。
  static const double _gap = 8;

  /// 格子内左右留白。比 M3 按钮默认的 16 小：窄屏上这每边 6dp × 2 × 4 格
  /// 就是一行放不放得下四个的分界。
  static const double _hPad = 10;

  static const double _cellHeight = 38;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final style =
        theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14);
    final scaler = MediaQuery.textScalerOf(context);

    // 最小格宽 = 最长那个标签 + 两侧留白。按**实测**而不是写死一个数：这一页的
    // 标签从两个字到四个字都有，写死要么挤掉四个字的、要么白占地方。
    final widest = options.fold<double>(0, (w, o) {
      final dotAndGap = swatch == null ? 0.0 : 16.0;
      return math.max(w, _labelWidth(o.$2, style, scaler) + dotAndGap);
    });
    final minCell = widest + _hPad * 2 + 2;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fit = ((width + _gap) / (minCell + _gap))
            .floor()
            .clamp(1, options.length);

        // 均衡：先由"一行最多几个"推出行数，再把总数平分到各行（向上取整，
        // 余数落在末行）。四个在只能放三个时 → 行数 2、每行 2。
        final rowCount = (options.length / fit).ceil();
        final perRow = (options.length / rowCount).ceil();

        final rows = <Widget>[];
        for (var start = 0; start < options.length; start += perRow) {
          final end = math.min(start + perRow, options.length);
          rows.add(Padding(
            padding: EdgeInsets.only(top: rows.isEmpty ? 0 : _gap),
            child: Row(
              children: [
                for (var i = start; i < end; i++) ...[
                  if (i > start) const SizedBox(width: _gap),
                  Expanded(child: _cell(context, options[i], style)),
                ],
                // 末行不满：空槽也占一份宽度，否则最后那几个会被拉宽，跟上一行
                // 对不齐（3 + 1 之所以难看，一半是这个原因）。
                for (var i = end; i < start + perRow; i++) ...[
                  const SizedBox(width: _gap),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ],
            ),
          ));
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      },
    );
  }

  Widget _cell(BuildContext context, (T, String) option, TextStyle style) {
    final (value, label) = option;
    final theme = Theme.of(context);
    final on = value == selected;
    final dot = swatch?.call(value);

    return Semantics(
      button: true,
      selected: on,
      child: Material(
        color: on ? AppColors.accent : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: on
                ? AppColors.accent
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.9),
          ),
        ),
        child: InkWell(
          onTap: () => onChanged(value),
          child: SizedBox(
            height: _cellHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _hPad),
              child: Center(
                // 兜底：真到了比最小格还窄的地步（桌面 240dp 左栏的四等分），
                // 宁可字小一点，也不要省略号或溢出。
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dot != null) ...[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                            border: on
                                ? Border.all(color: Colors.white, width: 1.4)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: style.copyWith(
                          color: on
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurface,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static double _labelWidth(String label, TextStyle style, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: scaler,
    )..layout();
    return tp.width;
  }
}
