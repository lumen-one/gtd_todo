# 动态任务调度 Todo

以 Markdown 为任务数据载体、以 Slack（裕度）驱动的本地任务提醒软件。
核心循环：**任务 + 截止时间 + 工作量 + 工作时间 + 用户行为 → 动态提醒**。
排序 = **时间裕度优先**（`risk × importance`）；调度分**完整 / 标准（默认）/ 无排序**三档（完整 = 排+响，标准 = 排+不响，无排序 = 不排+不响）。
Markdown 数据是**双文档**：人写人看的 `tasks.md`，内核算的 `.gtd/<id>.md`。

> 文档怎么找、改动落哪一份：见 [docs/AGENTS.md](docs/AGENTS.md)。
>
> 结构与接口契约（分层、插座、import 矩阵、架构守卫）见 [docs/architecture.md](docs/architecture.md)；
> 数据格式（`tasks.md` / `.gtd/` / `主线.md`）见 [docs/formats/](docs/formats/README.md)。
> UI 与交互需求（安卓悬浮侧边栏、创建流程、提醒呈现）见 [docs/ui-interaction.md](docs/ui-interaction.md)；
> 侧边栏各页面各自的规则见 [docs/panels/](docs/panels/README.md)。
> 结构或接口变更先改契约文档，再改代码。

## 运行

```bash
flutter run -d windows        # 桌面版（调试）
flutter run -d android        # 安卓版（调试）
flutter test                  # 全部单元测试（算法不依赖 UI，可独立验证）
dart run example/simulation.dart   # 控制台仿真：重放"创建→推迟→干活→临界"全流程
dart run tool/seed_tasks.dart      # 生成示例任务数据（tasks.md + .gtd/<id>.md）
```

Windows 版默认任务目录是相对路径 `tasks/`（相对进程工作目录，`flutter run` 时
即项目根）。要指到别处：设环境变量 `GTD_TASKS_DIR=<目录>`，或在应用内设置页 →
文件访问里改目录（写 `bootstrap.json`，重启生效）。

**打包成脱离开发环境的独立软件**（发给别人或日常自用）：

```bash
flutter build windows --release
```

产物 = `build/windows/x64/runner/Release/` 整个文件夹（`gtd_todo.exe` +
`flutter_windows.dll` + `data/` 等），原样拷到任何 Win10/11 即可双击运行，
不需要装 Flutter。注意两点：目标机要有 VC++ 运行库（缺了报缺
`vcruntime140.dll`，装 Visual C++ Redistributable）；任务数据不在这个文件夹里，
把 `tasks/` 一起拷走，或在目标机设 `GTD_TASKS_DIR` 指过去。

## 局域网同步（Windows ↔ 安卓）

同一网络内两台设备同步任务数据：一台当**主机**（通常 Windows），其余当**从机**
接入；双向同步，冲突由主机裁决——从机被覆盖的版本存档到 `.gtd/conflicts/`，
不丢数据。设置页 → 同步：开主机 / 扫局域网发现 / 手输 IP / 立即同步 / 看上次
同步时间与冲突提示。同步范围与冲突规则见 [docs/sockets/sync.md](docs/sockets/sync.md)。

注意：Windows 首次开主机会弹防火墙对话框，需允许**专用网络**入站（HTTP 49872
+ UDP 49871）；路由器若禁了广播，用手输 IP 兜底。

## 任务数据（Obsidian 可直接编辑）

任务存放在 `tasks/` 目录（可用环境变量 `GTD_TASKS_DIR` 覆盖；已加入 .gitignore 不入库，
`tool/seed_tasks.dart` 可重新生成样例）。
用 Obsidian 把本目录（或整个项目目录）作为 Vault 打开即可直接查看和修改。

**双文档：人写人看的归一个文档，内核算的归另一个文档。**

```text
tasks/
├── tasks.md          ← 人类文档：所有任务都在这里，# 标题分类，一行一条
├── 主线.md           ← 主线：行为链 + 日历上的记录（一个文件装全部主线，含已归档的）
└── .gtd/<任务id>.md   ← 内核属性文档：应用自己写（任务id/工作强度/优先级/时间裕度/剩余工作量；**长期任务只有 id**）
```

**主线**（`主线.md`，侧边栏顶栏第二行那一条）：一件正在推进的大事 = 一串**行为链**
（勾完文字加横线）+ 日历上**手动拖选连续日期圈出来、往里写文字**的记录。行为链上的
步骤**不是任务**——不进任务池、不占工时、不参与调度；勾完点『完成主线』归档，
整条留在同一个文件里可只读回看。格式见 [docs/formats/mainline.md](docs/formats/mainline.md)。

**人类文档**（`tasks.md`）：人写六个属性——任务名、创建日期、结束日期、完成日期、
备注、标签。**更多的标签 = 更多的属性**：

```markdown
# 工作

- [ ] 任务名 创建 2026-10-11,07:00 结束 2026-10-12,18:00 这是备注。 ##这是标签1 ##这是标签2
- [x] 交房租 创建 2026-10-01,09:00 完成 2026-10-01,09:30 ##生活
```

**内核属性文档**（`.gtd/<任务id>.md`）：应用算出来的那半边（行指纹、工作强度、
优先级、时间裕度、剩余工作量），一个任务一份。字段与写法见
[docs/formats/](docs/formats/README.md)。

约定（详见 [docs/formats/](docs/formats/README.md)）：

- **应用只改人类文档里自己那一行**（插入/打勾/补完成时刻），其余行、标题、空行、
  正文**一字不动**，而且**永不重排行**；
- 人在 Obsidian 里改名/改日期/加删行都能生效：两条文档靠行指纹配对，
  人写的那半边以文档为准，内核那半边（工时/优先级/裕度/剩余量）原样保留；
- **人类文档里不出现任何内核字段**（没有 id、没有裕度、没有优先级噪声）；
- **三无任务默认'长期'**：工作强度是"长期"标记而非分钟数——不估工时、
  不设优先级、没有裕度，内核属性文档里只有一个任务 id；有截止的可推任务仍必须给数字工时；
- **挂起进行**：长期任务可『挂起进行』——顶置在今日页最顶的挂起组
  （无编号、组内可上下拖动调序），保持到完成或主动取消，不按天过期；标记落 metadata
  `in_progress`，完成命令顺手清除；
- `log`（操作流水）单独一个文档：`tasks/.gtd/log.md`，append-only；
- 软删除 = 内核属性文件移入 `.gtd/.trash/` + 那一行用 `%%…%%` 注释掉（可捞回）；
- 旧的"一任务一文件"格式仍可读：目录里若只有旧文件而没有 `tasks.md`，
  首次读取会自动迁移，旧文件原样挪进 `legacy-tasks/` 存档（不删数据）。

## 调度模型（时间裕度优先 + 调度模式三档）

对每个未完成任务（全部换算成"工作分钟"，跳过午休/夜间/周末）。
**工作时间**（哪几天上班、每天几段）在设置页改，它就是这个换算的分母：
默认周一至周五 09:00–12:00、13:30–18:00；改完所有提醒按新日历重算，
不迁移、不改写任何任务数据。

```text
available = WorkTime(now, deadline)            # 距截止的真实可用工时
slack     = available - 剩余工时                # 裕度，唯一的压力表
risk      = slack ≤ 0 ? 1 : exp(-(slack/τ)^γ)  # 非线性误期风险 ∈ (0,1]，τ=480、γ=1
priority  = risk × importance                  # 调度优先级 = 排序键（优先级缺省 3）
interval  = clamp(α * slack, min, pivot)       # 下次提醒间隔，α=0.5, min=30, pivot=480
          = pivot * (1 + log₂(α*slack/pivot))  # 裕度超过 pivot 后按对数放缓
nextReminderAt = 沿用上次锚点（任务自身没变时）否则 addWorkMinutes(now, interval)
```

- **调度模式三档**（设置页可切，**默认标准**，一组逐级弱化）：
  - **完整**：排列 + 提醒——凡算法判定该响的都响；
  - **标准**：只排列不提醒——算法照常算先后，但**不出声**；想被推着走的事，
    在编辑表单里给那一件开『提醒我』；
  - **无排序**：标准的再弱化版——今天该看哪几件仍由算法挑，只是这几件的先后
    全由人手动拖。
  完整 / 标准两档不改清单的分组与顺序，只决定"要不要出声"；无排序档改的是
  今日可推组的先后，**成员不变**（仍按锚点准入）。
- **排序四档**：不可行 → 普通（按调度优先级降序）→ 逾期 → 已推迟。不可行是
  "已经注定误期"，单独一档等用户裁决（改截止 / 砍范围 / 加班）；
- **裕度优先**：裕度越薄风险越高、越排在前面；**优先级（1–5，缺省 3）是乘数**，
  让重要的事整体前移。乘数最多 5 倍，裕度差出 480 分钟以上时它就盖不动了；
- **锚点不会因为别的操作被推后**：每条命令都会重算调度，但一件任务的
  截止 / 推迟状态没变时，它已经定下的提醒时刻原样保留——否则你越勤快地
  完成小事，最该响的那件越响不起来；
- **为什么风险是非线性的**：线性要给裕度"到哪算 0"凭空定量纲、还会算出负值；
  指数族只要一个尺度 τ，且"裕度还宽时催得少、一薄就陡然变急"正是想要的手感。
  旧算法 `slack.v1`（urgency 排序）留在注册表里做对照；
- 间隔上限是**拐点不是硬顶**：裕度超过 480 工作分钟后按对数放缓（每翻一倍加
  一个工作日），远期任务不会天天响；
- 推迟不用特殊处理：时间流逝 → slack 变小 → 间隔自动缩短、风险升高、排序前移；
- 干活（logWork）→ 剩余工时减小 → 间隔自动变长、风险下降；
- `available < 剩余工时` → 按期不可行，升级提示改截止/砍范围；
- 已过截止 → overdue，退出提醒循环；
- snooze 到期自动回到 active，重新参与调度（`pollReminder` 每轮先查有没有
  到期的 snooze，有就重锚——标准档下"下一站"恒为空，光等它等不到）。

`risk`/`priority` 都是算出来的，**不落盘、不进人类文档**（顺序本身就是表达）。
注意同名不同物：算法里的 `priority` 是**调度优先级**（输出），而内核属性文档里的
`priority` 键是**人定的优先级**（= `importance`，缺省 3，是输入）。

## 架构

```text
lib/
├── domain/       纯 Dart：Task / Routine / Mainline / Schedule / TimeContext / Reminder / DomainEvent
├── repository/   TaskRepository 接口 + 双文档 Markdown 实现（人类文档 + 内核属性文档）+ Memory 实现
├── scheduler/    Scheduler 接口 + SlackPriorityScheduler（默认：时间裕度优先）
│                 + SlackScheduler（旧口径，留作对照）+ 注册表
├── application/  TaskService：用户行为 → 重新调度 → 产出 ScheduleResult
│                 （按子域拆 part：task_service/ 下回收站 / 周期实例同步 / 四种排序）
│                 + 周期任务 / 今日视图 / 送达策略 / EventLog（log.md 订阅者）
├── platform/     平台适配器（安卓原生 / 桌面 / 设置与引导落盘）——只有组装点 import
└── ui/           Flutter 界面 + AppController（薄胶水）+ overlay/（悬浮面板引擎侧）
```

依赖铁律：箭头只能指向更纯粹的层；Markdown / 算法 / 通知都是"朝上插"进接口的实现；
Scheduler 不依赖 UI、Markdown、Notification，时间由外部注入，因此可以无 UI 重放测试。

注意：不要在周期 tick 里无条件调用 `refreshSchedule()`（会不断重锚导致提醒永远到不了）；
只有"事件发生"（操作、提醒到点、文件变更）才重锚。重锚分两条：命令重算走
`recomputeSchedule()`（当前内存态，不读盘），`refreshSchedule()` 只留给文件监听 /
回前台 / 启动 / 提醒到点。
