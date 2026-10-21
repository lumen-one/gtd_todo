import '../domain/plan.dart';

/// 编排的存储插座（附录 B.7）：**一个文件装所有日子**，没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏行进 warnings）；写是整份重写——正文就是数据，不值得为它造
/// 一套行级补丁（与 `主线.md` 同档）。
abstract class PlanRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  /// 全部日子（调用方保证新→旧，本层不排序）。
  Future<List<DayPlan>> loadAll();

  /// 整份落盘。
  Future<void> saveAll(List<DayPlan> days);
}
