import '../domain/mainline.dart';

/// `主线.md` 的编解码插座（附录 B.6）。
///
/// 与 Task 的双文档不同：主线**一个文件装全部**（在跑的 + 已归档），正文就是
/// 数据本身，所以没有 sidecar、也没有行指纹——应用保存时按模型重写正文。
class MainlineDecodeResult {
  final List<Mainline> mainlines;
  final List<String> warnings;

  const MainlineDecodeResult(this.mainlines, this.warnings);
}

abstract class MainlineCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  bool canDecode(String raw);

  /// 解析整篇（**永不抛异常**：坏条目记 warnings 后跳过）。
  MainlineDecodeResult decode(String raw);

  /// 编码整篇。[originalRaw] 用来做未知 frontmatter 行的字段级保真。
  String encode(List<Mainline> mainlines, {String? originalRaw});
}
