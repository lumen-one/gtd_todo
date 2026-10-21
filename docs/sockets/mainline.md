# 主线插座

主线（行为链 + 记录）住在独立的 `主线.md` 里，一个文件装全部主线；步骤不是 Task。

**MainlineRepository / MainlineCodec**：主线（行为链 + 记录）存独立 `主线.md`，
**一个文件装全部主线**（在跑的 + 已归档）。与任务、周期两套完全不相交——步骤不是 Task，
不进调度、不占工时；归档 = `completed` 字段有值，只改状态不删数据。
实现：`domain/mainline.dart` + `repository/{mainline_codec,mainline_repository,
markdown_mainline_repository}.dart` + `application/mainline_service.dart`。
