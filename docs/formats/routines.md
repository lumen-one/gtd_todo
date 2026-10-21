# B.5 旧格式兼容与 `routines.md`

**旧格式：一任务一文件的 frontmatter**（`formatId = md-frontmatter/1`）**只读兼容**。
目录里若只有旧文件而**没有** `tasks.md`，首次读取自动迁移：

1. 每条旧任务 → 人类文档一行（`- [ ] … 创建 …`）+ `.gtd/<id>.md` 一份内核属性；
2. 旧文件**原样挪进** `legacy-tasks/` 存档（**只进不出**，可人工回捞，不删数据）；
3. 迁移后 `tasks.md` 存在，不会重复迁移。

```markdown
---
id: task-001
title: 完成 Agent 调度论文阅读
deadline: 2026-10-08T18:00
estimated_work: 120
remaining_work: 90
importance: 3
status: active
created: 2026-10-07T15:30
type: fixed
---

正文随便写：背景、拆解、进展流水……应用永不改动这一段。
```

**回归测试**：`test/markdown_task_repository_test.dart`「迁移」组 +
「人类文档里别人的内容一字不动」组。

## `routines.md`（周期规则文件）

与任务文件同目录的**独立文件**（TaskRepository/TaskCodec 不覆盖它），
**一条规则一个 frontmatter 条目**，条目之间用 `---` 分隔；条目正文是规则备注，
归人所有（应用只在规则备注被显式修改时改写它）：

```markdown
---
id: routine-1a2b
title: 晨跑
freq: weekly          # daily | weekly
weekdays: 1,3,5       # weekly 时的星期（1=周一 … 7=周日，逗号分隔标量）
time: 07:00           # 可选；缺行 = 不限时刻
remind: true          # 响不响（true 必须有时刻）
enabled: true         # 启用开关
created: 2026-10-07T09:00
---

备注随便写：应用不改这一段（未知字段、注释、行顺序同样原样保留）。
```

- 解析宽容：缺 id/title 的条目记入 warnings 并跳过，不崩溃；
- 删除规则 = 从本文件移除该条目 + 清掉未完成的当天实例（已完成的历史留在 `.gtd/`）；
- 规则的当天实例是**普通任务**（下段），所以完成/跳过状态都落在任务这一侧，
  规则文件保持干净；
- **实例在双文档形态下的落点**：人类文档里一行（`- [ ] 晨跑 创建 …`，
  带 `##例行` 之类标签）+ `.gtd/<规则id>-<yyyy-MM-dd>.md`（含 `type: routine`、
  `routine`、`routine_date` 等登记键）。实例 id 仍是 `<规则id>-<yyyy-MM-dd>`。

| `routines.md` 字段 | 类型         | 说明                                      |
| ------------------ | ------------ | ----------------------------------------- |
| `id`               | string       | 唯一标识，时间戳+随机尾巴，同毫秒创建不撞 |
| `title`            | string       | 任务名                                    |
| `freq`             | enum         | daily / weekly                            |
| `weekdays`         | 逗号分隔标量 | weekly 时的星期（1=周一 … 7=周日）        |
| `time`             | HH:mm，可选  | 缺行 = 不限时刻                           |
| `remind`           | bool         | 响不响（true 必须有时刻）        |
| `enabled`          | bool         | 启用开关                                  |
| `created`          | ISO8601      | 创建时间                                  |
| `schema`           | int（规划）  | 迁移版本号，见 [架构文档](../architecture.md) §3.4 防线三                |

