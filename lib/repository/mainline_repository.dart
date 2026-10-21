import '../domain/mainline.dart';

/// 主线的存储插座（附录 B.6）：**一个文件装全部**，没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏条目进 warnings）；写是整份重写——主线只有一两条、
/// 正文就是数据，不值得为它造一套行级补丁。
abstract class MainlineRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  Future<List<Mainline>> loadAll();

  /// 整份落盘（调用方保证顺序：在跑在前、已归档按完成时刻倒序）。
  Future<void> saveAll(List<Mainline> mainlines);
}
