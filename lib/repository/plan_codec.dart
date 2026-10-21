import '../domain/plan.dart';

/// `编排.md` 的编解码插座（附录 B.7）。
///
/// 与任务的双文档不同：编排**一个文件装所有日子**，正文就是数据本身，所以没有
/// sidecar、也没有行指纹——应用保存时按模型重写正文。
class PlanDecodeResult {
  final List<DayPlan> days;
  final List<String> warnings;

  const PlanDecodeResult(this.days, this.warnings);
}

abstract class PlanCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  /// 解析整篇（**永不抛异常**：认不出的行跳过）。
  PlanDecodeResult decode(String raw);

  /// 编码整篇（日子按新→旧）。
  String encode(List<DayPlan> days);
}
