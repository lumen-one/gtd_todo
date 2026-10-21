# application 层的小端口

三个只管一件事的端口：灵感读写、设置存取、操作流水。它们不是子系统，但各有独立的
落盘适配器与失败模式，所以从 [架构文档](../architecture.md) §4.1 的插座清单里分出来单独登记。

## 灵感读写

**NotesPort**：灵感页（原"疑问笔记"）的**读写**端口。读 = 取 frontmatter 闭合后到
下一个 `---` 的正文段（含 `[[` 的行只由显示层屏蔽）；写 = 用新内容替换**同一区间**，
**frontmatter 与正文段前后的一切逐行原样保留**，连文件原有的换行风格（CRLF/LF）与
"是否以换行结尾"也照旧。写是"读—改—写"，不做锁、不做合并（同时在改以本次为准）；
frontmatter 未闭合时正文段的边界本身不确定，直接拒绝写入。
实现：`application/notes_reader.dart` 定义接口与两个纯函数
（`extractNotesSection` 提取 / `applyNotesSection` 只换正文段），
`platform/app_adapters.dart` 落盘适配器。

## 设置

**SettingsPort**：应用设置（通知时间段、定期挑、灵感文件路径（设置键仍是 `notes_path`）、主题预设与
明暗模式、周期任务是否进池等）的存取端口（实现：`application/settings.dart` +
`platform/` 落盘）；设置文件仍在任务目录 `settings.json`，
但"任务目录是哪个"改存应用支持目录的 `bootstrap.json`（`BootstrapPort`），
否则改目录会把设置本身弄丢。

## 操作流水

**EventLogPort**：操作流水的**只追加**落盘插座——
`application/event_log.dart` 定义 `EventLogPort` + `EventLog` 订阅者，
落盘任务目录 `.gtd/log.md`（append-only，应用从不重写历史行）
（`platform/app_adapters.dart` 的 `FileEventLogPort`）。
**只在主引擎装配**（两个引擎都挂会把同一件事记两遍，理由同 [delivery.md](delivery.md) 的边界 1）；
`.gtd/log.md` **不是内核属性文档**——内核属性扫描与文件监听都要跳过它，
否则每次读盘都会多出一条"属性文档无法解析"的假警告，
监听它更会自激成环（写日志 → 文件变化 → 重锚 → 又写日志）。
