import '../domain/routine.dart';

/// 周期规则编解码（§4.1「RoutineCodec」座位）：纯函数、无 IO。
/// "存哪"（RoutineRepository）与"什么格式"（codec）分离，与 TaskCodec 同构。
///
/// 分级保真（§3.4 防线一）在规则文件上的等价物：
/// - 正文（规则备注）：未被显式修改时逐字节保留；
/// - frontmatter：应用拥有的字段（见实现类 `_ownedKeys`）原地改写，
///   未知字段、注释行、行顺序原样保留。
abstract class RoutineCodec {
  /// 如 'md-routine/1'。
  String get formatId;

  bool canDecode(String raw);

  RoutineDecodeResult decode(String raw);

  /// [originalRaw] = 磁盘当前内容（字段级保真的合并基准）；null = 全新文件。
  /// [routines] 里没有的旧条目会被移除（删除规则的语义）。
  String encode(List<Routine> routines, {String? originalRaw});
}

class RoutineDecodeResult {
  final List<Routine> routines;

  /// 宽容解析的告警（坏条目降级，不崩溃；流向同附录 B）。
  final List<String> warnings;

  const RoutineDecodeResult(this.routines, [this.warnings = const []]);
}
