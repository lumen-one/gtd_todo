# 文档规则与索引

这份文件是**动手改文档之前**看的：先查这件事该落哪一份，再照规则写。
只想找内容的人跳过"写作与改动规则"那节，直接查上面两张表。

三份东西分工不同，别混：

- 仓库根的 `README.md`：这是什么、怎么跑、怎么装。
- **本页**：文档放哪、怎么写、改哪一份。
- `architecture.md` / `ui-interaction.md`：正文。

一句话原则：**一份事实只有一个家**。定义只写在拥有它的那份里，别处一律改成链接。

## 什么时候动哪一份

| 位置 | 装什么 | 什么时候动它 |
|---|---|---|
| [`architecture.md`](architecture.md) | 分层、接口、领域模型与调度语义、插座清单、import 矩阵、架构守卫、已知局限 | 结构、内核语义或接口变更 |
| [`ui-interaction.md`](ui-interaction.md) | 入口、任务模型、创建流程、提醒系统、视觉、设置页、边界 | 交互需求变更 |
| [`panels/`](panels/README.md) | 侧边栏每个页面各自的规则（把手、今日、灵感、池子、日历、已完成、快记、主线、桌面） | 改某个页面的行为 |
| [`formats/`](formats/README.md) | 持久化契约：`tasks.md` / `.gtd/` / `routines.md` / `主线.md` | 改数据格式 |
| [`sockets/`](sockets/README.md) | 插座契约：每个插座的接口、适配器、引擎边界 | 加插座，或改某个插座的行为 |
| [`decisions/`](decisions/README.md) | 决策卡片：为什么这么做、当时否了什么、代价 | 做了一个半年后可能被重新质疑的取舍 |
| [`roadmap.md`](roadmap.md) | 未来方向：只差动手的、等触发条件的、已留插座未接的 | 想到新方向，或某个触发条件成立了 |
| [`references/`](references/) | 外部项目参考（不是本项目口径，别引用来改代码） | 基本不动 |

## 我要找 X

| 我想知道 | 去这里 |
|---|---|
| 改代码前先读什么 | `architecture.md` §0–§2 |
| 某个类型/字段什么意思 | `architecture.md` §3.1 词汇表 |
| 有哪些命令、各自的规则 | `architecture.md` §3.5 命令清单 |
| 加一个插座实现（存储 / 算法 / 通知 / 同步） | [`sockets/`](sockets/README.md) 总表 → 对应那页；接口草图在 `architecture.md` §4.1 |
| 两个引擎怎么分工、悬浮面板怎么装配 | [`sockets/delivery.md`](sockets/delivery.md) |
| 什么时候会响、为什么这一条被顺延 | [`sockets/reminder.md`](sockets/reminder.md) |
| 同步哪些文件、冲突了谁赢 | [`sockets/sync.md`](sockets/sync.md) |
| 某个面板怎么动 | `panels/` 下对应那一页 |
| 页序、默认打开哪页、面板头显示什么 | `panels/README.md` |
| 数据文件长什么样、怎么配对、怎么迁移 | `formats/` |
| 为什么这么设计、当时否了什么 | `decisions/` |
| 以后可能做什么、什么条件下做 | `roadmap.md` |
| 有哪些已知局限（登记在案、不是待办） | `architecture.md` §12 |
| 有意不做什么 | `ui-interaction.md` §13 |
| 要加功能，先改哪 | 契约在 `architecture.md` §3.5，交互在 `ui-interaction.md` §10 |
| 设置页有哪些项 | `ui-interaction.md` §9 |

## 写作与改动规则

1. **先改文档再改代码**。结构、接口、数据格式、交互的变更，先在对应文档里落定，
   再动实现——提交也按这个顺序拆笔，方便回滚。
2. **一份事实一个家**。发现同一句话在两处出现，改第二处为链接，不要两处一起维护。
3. **只写现状**。正文不写"已实现 / 计划中 / 这次改成了"：状态由代码和测试承载，
   历史归 commit，理由归 `decisions/`。真有边界要登记，写进 `architecture.md` §12 或 `ui-interaction.md` §13 的表格里。
   想写计划，去 `roadmap.md`。
4. **引用怎么写**。`§3.1` 这类编号只在**同一份文件内**使用，跨文件一律写路径链接：

   | 从哪到哪 | 写法 |
   |---|---|
   | `docs/` 根 → 子目录 | `[formats/sidecar.md](formats/sidecar.md)` |
   | 子目录 → 同目录 | `[今日清单页](today.md)` |
   | 子目录 → 正文 | `[UI 文档](../ui-interaction.md) §9 第 12 条` |
   | 子目录 → 另一子目录 | `[formats/mainline.md](../formats/mainline.md)` |

   编号只在文件内用：跨文件时一串 `§3.5` 不说明是哪份文件的第 3.5 节，读者得先猜；
   而文档一拆，编号就搬了家，引用会静默失效——链接至少点得进去、错了看得出来。

5. **什么时候写决策卡片**：见 [`decisions/README.md`](decisions/README.md)。
   一句话判据——这个取舍半年后可能被重新提出来。

6. **文档坏了 `flutter test` 会红**。`test/docs_test.dart` 扫全部文档，查三件事：
   死链、章节引用指不到东西、正文里出现"这次改成 / 已实现 / 【规划】"。
   不用记命令——跑测试就顺带查了。

   想只看文档（比全量测试快）：`dart run tool/check_docs.dart`，加 `--strict`
   时警告也算失败。

   改检查规则本身（`tool/doc_lint.dart`）时跑 `test/doc_lint_test.dart`——门禁
   自己也得被测，否则它只是"看起来在检查"。写新规则时先写反例（断言它会红），
   不然没法证明它不是永远绿。
