# B.2 内核属性文档 `.gtd/<任务id>.md`

frontmatter 为**平铺的 `key: value` 行**（每行一个字段、标量值）；不支持列表、嵌套、
多行标量；注释行与未知字段行同属"非字段内容"，按**字段级保真原样保留**（[architecture.md](../architecture.md) §3.4）。
`---` 之后是**内核备注**（自由文本，应用不改）：

```markdown
---
id: task-001
digest: 7683b0bb       # 人类文档里那一行的指纹（连接键，见下）
work_intensity: 120    # 工作强度 = 完成它需要的工时（工作分钟）
remaining_load: 0.75   # 剩余工作量（分数：乘以工作强度才是分钟）
priority: 3            # 优先级 1–5（与 domain 的 importance 同一枚硬币）
time_slack: 210        # 时间裕度（工作分钟；计算结果，不落盘也能重算）
status: snoozed
snoozed_until: 2026-10-11T17:10   # 与 status: snoozed 配套（用户意图，持久化）
---

内核备注（可选）：调度解释、AI 留的理由……归内核，应用不主动改。
```

**完成态不许自相矛盾**：`completed_at` 只与 `status: completed`（或人类文档的 `[x]` /
`完成 <时刻>`）配套出现；`status: active` + `completed_at` 是非法状态，别照着写。

| 字段             | 类型                  | 说明                                                                                                       |
| ---------------- | --------------------- | ---------------------------------------------------------------------------------------------------------- |
| `id`             | string                | 唯一标识。格式 `task-<时间戳base36>-<随机尾巴>`；前缀定长，按 id 排序 ≈ 按创建先后                         |
| `digest`         | 8 位十六进制          | **连接键**：人类文档那一行的 FNV-1a 32 位指纹                                                              |
| `work_intensity` | int（工作分钟，≥0）   | 工作强度 = 完成它所需工时（domain 的 `estimatedWork`；开始型任务豁免为 0）                                 |
| `remaining_load` | 小数 0–1              | 剩余工作量（分数）。**分钟数 = work_intensity × remaining_load**，是算出来的，不单独存（避免两份数据打架） |
| `priority`       | int 1–5               | 优先级（domain 的 `importance`）                                                                           |
| `time_slack`     | int（工作分钟，可选） | 时间裕度 = 可用工时 − 剩余工时；调度算出来的，丢了也能重算，所以允许缺行                                   |
| `status`         | enum                  | pending / active / snoozed / completed（overdue 是派生，不写）                                             |
| `snoozed_until`  | ISO8601，可选         | 用户 snooze 意图（属事实，持久化）                                                                     |
| `completed_at`   | ISO8601，可选         | 完成时刻（与人类文档 `完成 <时刻>` 同步落一份）                                                            |
| `schema`         | int（规划）           | 迁移版本号，见 [架构文档](../architecture.md) §3.4 防线三                                                                                 |

**长期任务特例**：工作强度 = '长期'（三无任务的创建缺省）时，本文件只剩：

```markdown
---
id: task-004
---
```

`work_intensity` / `remaining_load` / `priority` / `time_slack` 全部缺行，`digest` 也没有
（两文档配对走 [matching.md](matching.md) 第 2/3 档）；`status` / `completed_at` 同样不落——**完成态只认人类文档**的
`[x]` / `完成 <时刻>`。'长期'不单独落一行：**没有 `work_intensity` 行就是长期**，
因此也**不为'长期'新增 metadata 键**（下方登记表里的 `in_progress` 是挂起标记、与"怎么表达
长期"无关）。与 routine 实例的"0 工时豁免"是两回事：
routine 到点发生、本来就不用估；长期是长期存在、估不出来。

**自有 metadata 键登记表**（[架构文档](../architecture.md) §3.4 防线二：应用自有键在此登记，编码时**跟随任务对象
改写**——值变则行变、键在 `Task.metadata` 里消失则整行删；其余未知键原样往返）。
实现载体 = `TaskSidecarCodec.registeredMetaKeys`；**漏登记这批键的写回，等于让
"插队 / 池序 / 跳过今天 / 只到点响一次 / 类型转换"这些持久意图在命令自己的重锚里
蒸发**。除上表内的字段外，还登记：

| 键                 | 语义                                                                                                                                                                                                                                                                    | 来源                            |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `type`             | 任务类型：`fixed`（开始型）/ `flex`（截止型，缺省不写）/ `routine`（周期实例）                                                                                                                                                                                      | [UI 文档](../ui-interaction.md) §4.1            |
| `pinned`           | 插队标记：持久意图，保持到完成，栈式压顶（仅截止型组；**无排序档下不生效**，顺序由 `manual_order` 整体定），值 = 插队时刻                                                                                                                                        | [今日清单页](../panels/today.md)      |
| `picked_for_today` | 被挑散件标记（当日有效，值 = yyyy-MM-dd；手动挑过则当日自动挑让位）                                                                                                                                                                                                     | [任务池页](../panels/pool.md)           |
| `loose_home`       | 散件的家：`pool` = 住任务池散件段（缺省不写 = 住今日页 ⑥ 散件段）。**只在无排序档参与**分区，切档不迁移，长期有效（不是当日标记）                                                                                                                              | [今日清单页](../panels/today.md) / [任务池页](../panels/pool.md) |
| `pool_order`       | 任务池显示序（仅整理，无调度含义，重启保留）                                                                                                                                                                                                                            | [UI 文档](../ui-interaction.md)                  |
| `routine`          | 周期实例所属规则 id                                                                                                                                                                                                                                                     | [UI 文档](../ui-interaction.md)                  |
| `routine_date`     | 周期实例的发生日（yyyy-MM-dd；今日清单按它筛『例行组』）                                                                                                                                                                                                                | [UI 文档](../ui-interaction.md)                  |
| `routine_remind`   | 该实例的规则设了响（时点性提醒，只写 `true`）                                                                                                                                                                                                                           | [UI 文档](../ui-interaction.md)                  |
| `routine_skipped`  | 被"跳过今天"的那一天（yyyy-MM-dd；不完成、当天不再显示）                                                                                                                                                                                                                | [UI 文档](../ui-interaction.md)                  |
| `point_fired`      | 已响过的那一站时点提醒（值 = 那一站的时刻 ISO；无排序档两站靠先后推进，改期后清除）                                                                                                                                                                                      | 每一站只响一次     |
| `remind` | **逐任务响铃开关**（表单上的『响铃』：只写 `true`，关掉即删键）。提醒照发，它只决定走有声渠道还是静音渠道；缺键 = 静音 | [UI 文档](../ui-interaction.md) §7.0 |
| `manual_order`     | **手动序**（**无排序档**下今日截止型组的显示序，非负整数；拖动一次整段重编号）。标准档下**保留但不生效**，切档不迁移                                                                                                                                                    | [今日清单页](../panels/today.md) |
| `in_progress`      | **挂起进行标记**：长期任务顶置今日页最顶的挂起组（无编号、组内可拖）。持久意图，**保持到完成或主动取消、不按天过期**（`completeTask` 顺手清除）；值 = 挂起时刻 ISO，组内按时刻降序（后挂在上），拖动整段重写时刻。**仅'长期'任务可挂**（取消不限） | [今日清单页](../panels/today.md) |

- **解析宽容**：坏文件降级进 `warnings`，不崩溃。**warnings 流向**：现暂存于
  `repo.warnings` 仅供诊断；目标形态 = 进领域事件流 + UI"待整理"清单；
- 未知字段必须无损往返（载体 = `DecodeResult.task.metadata`）。
- **调度优先级与 risk 不落盘**：上表的 `priority` 键是**人定的优先级**
  （= `Task.importance`，缺省 3）；`risk × importance` 算出来的**调度优先级**是一次
  计算的输出，换算法/换 τ 即变，写进文件只会产生需要同步的脏数据。同理，
  `time_slack` 允许缺行（丢了也能重算）。

