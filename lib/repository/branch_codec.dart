import '../domain/branch.dart';

/// `支线.md` 的编解码插座（附录 B.8）。
///
/// 与任务的双文档不同：支线**一个文件装全部支线**，正文就是数据，所以没有 sidecar、
/// 也没有行指纹——应用保存时按模型重写正文。
class BranchDecodeResult {
  final List<Branch> branches;
  final List<String> warnings;

  const BranchDecodeResult(this.branches, this.warnings);
}

abstract class BranchCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  /// 解析整篇（**永不抛异常**：认不出的行跳过）。
  BranchDecodeResult decode(String raw);

  /// 编码整篇（段序 = 卡片顺序，行序 = 任务顺序）。
  String encode(List<Branch> branches);
}
