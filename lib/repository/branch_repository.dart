import '../domain/branch.dart';

/// 支线的存储插座（附录 B.8）：**一个文件装全部支线**，没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏行进 warnings）；写是整份重写——正文就是数据，不值得为它造
/// 一套行级补丁（与 `编排.md` / `主线.md` 同档）。
abstract class BranchRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  /// 全部支线（段序即返回顺序，本层不排序）。
  Future<List<Branch>> loadAll();

  /// 整份落盘。
  Future<void> saveAll(List<Branch> branches);
}
