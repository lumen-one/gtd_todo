# 文档地图

三份东西分工不同，别混：

- 仓库根的 `README.md`：这是什么、怎么跑、怎么装。
- **本页**：文档怎么找、改动该落到哪一份。
- `architecture.md` / `ui-interaction.md`：正文。

一句话原则：**一份事实只有一个家**。定义只写在拥有它的那份里，别处一律改成链接。

## 目录

| 位置 | 装什么 | 什么时候动它 |
|---|---|---|
| [`architecture.md`](architecture.md) | 分层、接口、插座、import 矩阵、架构守卫、已知局限 | 结构或接口变更 |
| [`ui-interaction.md`](ui-interaction.md) | 入口、任务模型、创建流程、提醒系统、视觉、设置页、边界 | 交互需求变更 |
| [`panels/`](panels/README.md) | 侧边栏每个页面各自的规则（把手、今日、灵感、池子、日历、已完成、快记、主线、桌面） | 改某个页面的行为 |
| [`formats/`](formats/README.md) | 持久化契约：`tasks.md` / `.gtd/` / `routines.md` / `主线.md` | 改数据格式 |
| [`decisions/`](decisions/README.md) | 决策卡片：为什么这么做、当时否了什么、代价 | 做了一个半年后可能被重新质疑的取舍 |
| [`roadmap.md`](roadmap.md) | 未来方向：只差动手的、等触发条件的、已留插座未接的 | 想到新方向，或某个触发条件成立了 |
| [`references/`](references/) | 外部项目参考（不是本项目口径，别引用来改代码） | 基本不动 |

正文里的写法：`§3.1` 这类编号只在**同一份文件内**使用。跨文件一律写路径链接，例如
`[formats/sidecar.md](formats/sidecar.md)`。

## 我要找 X

| 我想知道 | 去这里 |
|---|---|
| 改代码前先读什么 | `architecture.md` §0–§2 |
| 某个类型/字段什么意思 | `architecture.md` §3.1 词汇表 |
| 有哪些命令、各自的规则 | `architecture.md` §3.5 命令清单 |
| 加一个插座实现（存储 / 算法 / 通知 / 同步） | `architecture.md` §4 对应那一类 |
| 某个面板怎么动 | `panels/` 下对应那一页 |
| 页序、默认打开哪页、面板头显示什么 | `panels/README.md` |
| 数据文件长什么样、怎么配对、怎么迁移 | `formats/` |
| 为什么这么设计、当时否了什么 | `decisions/` |
| 以后可能做什么、什么条件下做 | `roadmap.md` |
| 有哪些已知局限（登记在案、不是待办） | `architecture.md` §12 |
| 有意不做什么 | `ui-interaction.md` §13 |
| 要加功能，先改哪 | 契约在 `architecture.md` §3.5，交互在 `ui-interaction.md` §10 |
| 设置页有哪些项 | `ui-interaction.md` §9 |

## 三条纪律

1. **先改文档再改代码**。结构、接口、数据格式、交互的变更，先在对应文档里落定，
   再动实现——提交也按这个顺序拆笔，方便回滚。
2. **一份事实一个家**。发现同一句话在两处出现，改第二处为链接，不要两处一起维护。
3. **只写现状**。正文不写"已实现 / 计划中 / 这次改成了"：状态由代码和测试承载，
   历史归 commit，理由归 `decisions/`。真有边界要登记，写进 §12 或 §13 的表格里。
