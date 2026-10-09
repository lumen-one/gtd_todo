import '../domain/task.dart';

class DecodeResult {
  final Task task;
  final List<String> warnings;

  const DecodeResult({required this.task, this.warnings = const []});
}

class EncodedTask {
  final Task task;

  /// 磁盘当前内容（保存前重读）；null = 新文件（全新序列化）。
  /// 字段级保真（§3.4）：未知字段、注释、正文按 originalRaw 原样保留，
  /// 应用只改写自己拥有的字段行。
  final String? originalRaw;

  /// 应用最后一次见到/写入的内容（D9 字段归属的**正文基准**）。
  /// "正文是否被显式修改" = task.description 与 baselineRaw 的 description 比对；
  /// 用 originalRaw 比对会把"任务对象落后于磁盘"误判为应用要改正文。
  /// null = 应用从未见过该文件 → 正文以磁盘为准。
  final String? baselineRaw;

  const EncodedTask({required this.task, this.originalRaw, this.baselineRaw});
}

/// 格式编解码插座：纯函数，无 IO。
/// "存哪"（TaskRepository）与"什么格式"（TaskCodec）分离。
abstract class TaskCodec {
  String get formatId;

  bool canDecode(String raw);

  /// 无法解码时抛 FormatException（由 repository 降级为 warning）。
  DecodeResult decode(String raw);

  String encode(EncodedTask input);
}
