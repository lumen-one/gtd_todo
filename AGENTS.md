# AGENTS.md：改这个仓库之前

给 coding agent 和改代码的人看的入口。产品是什么、怎么用见 [README.md](README.md)；
**文档怎么放、某件事该改哪一份**见 [docs/AGENTS.md](docs/AGENTS.md)。

## 跑起来

```bash
flutter run -d windows              # 桌面版
flutter run -d android              # 安卓版
flutter test                        # 全部测试
dart run example/simulation.dart    # 控制台仿真：重放"创建→推迟→干活→临界"全流程
dart run tool/seed_tasks.dart       # 生成样例任务（tasks.md + .gtd/<id>.md）
```

算法、命令、仓储都不依赖 UI，可以单文件跑测试；界面测试必须 `pumpAndSettle()`，裸
`pump` 不会触发重建。

## 打包 Windows

```bash
flutter build windows --release
```

产物是 `build/windows/x64/runner/Release/` 整个文件夹（`qixing.exe` +
`flutter_windows.dll` + `data/`），原样拷到 Win10/11 就能双击，目标机不需要 Flutter，
但要有 VC++ 运行库（缺了报 `vcruntime140.dll`）。

任务数据不在那个文件夹里。默认是相对路径 `tasks/`（相对进程工作目录，`flutter run`
时即项目根）；指到别处用环境变量 `GTD_TASKS_DIR`，或在应用设置页 → 文件访问里改
（写 `bootstrap.json`，重启生效）。

## 代码怎么分层

```text
lib/
├── domain/       纯 Dart：Task / Routine / Mainline / Plan / Schedule / Reminder / DomainEvent
├── repository/   TaskRepository 接口 + 双文档 Markdown 实现 + Memory 实现
├── scheduler/    Scheduler 接口 + SlackPriorityScheduler（默认）+ 旧口径对照 + 注册表
├── application/  TaskService（命令 → 重锚 → ScheduleResult，按子域拆 part）
│                 + 周期 / 今日视图 / 送达 / 编排 / 主线 / 同步 / EventLog
├── platform/     平台适配器（安卓原生、桌面、局域网同步）——只有组装点 import
└── ui/           Flutter 界面 + AppController（薄胶水）+ overlay/（悬浮面板引擎侧）
```

箭头只能指向更纯粹的层。Markdown、算法、通知都是"朝上插"进接口的实现；`Scheduler`
不认 UI、Markdown、通知，时间由外部注入——这是它能在无 UI 下重放的原因。
import 矩阵由 `test/architecture_test.dart` 守着，改跨层引用会直接红。

## 两个会踩的约定

- **不要在周期 tick 里无条件 `refreshSchedule()`**：它每次都会重锚，提醒永远到不了。
  只有"事件发生"（操作 / 提醒到点 / 文件变更）才重锚，而且分两条：命令走
  `recomputeSchedule()`（用当前内存态，不读盘），`refreshSchedule()` 只留给文件监听、
  回前台、启动、提醒到点。
- **锚点跨重锚沿用**：任务自身的截止 / 状态 / 推迟没变时，已经定下的提醒时刻原样保留。
  去掉这层，用户每完成一件小事都会把别人的提醒往后推一格。

## 两个引擎

安卓侧有两个入口共用同一份数据和同一套 UI：`MainActivity` 里的主引擎，和悬浮面板服务
（`overlay_main.dart`）里的那份。**两个壳都必须挂 `ReminderListener`**——漏掉的那个到点
不会弹。桌面壳是 `main.dart` + 常驻左栏，设置页按壳能力表（`application/shell_capabilities.dart`）
裁剪。

## 出 release

1. 改 `pubspec.yaml` 的 `version`（`1.0.0+1` 里 `+1` 是 versionCode，每次发版必须加）。
2. 构建：`flutter build apk --release --split-per-abi`，产物在 `build/app/outputs/flutter-apk/`
   三个按架构拆的包（十来兆一个，比通用包小一多半）。
3. 打标签并推送：`git tag -a v1.0.0 -m "…" && git push origin main --tags`。
4. 到 GitHub Releases 挂附件（网页点，或用 API `POST /repos/<owner>/<repo>/releases` 再往
   `uploads.github.com` 传二进制）。

**签名**：`android/key.properties` 指向 `android/app/gtd-release.jks`，两个文件都不入库。
丢了这个密钥，装过包的人就再也收不到覆盖升级——只能卸载重装，而任务数据在应用私有目录里，
卸载即清空。密钥和口令自己留一份在仓库之外。

## 文档

改动顺序固定：**先改契约文档，再改代码**，提交也按这个顺序拆笔。

- 结构、接口、内核语义：[docs/architecture.md](docs/architecture.md)
- 交互与需求：[docs/ui-interaction.md](docs/ui-interaction.md)
- 每页各自的规则：[docs/panels/](docs/panels/README.md)
- 数据格式：[docs/formats/](docs/formats/README.md)
- 插座契约（存储 / 调度 / 通知 / 同步）：[docs/sockets/](docs/sockets/README.md)
- 为什么这么做、当时否了什么：[docs/decisions/](docs/decisions/README.md)

文档由 `test/docs_test.dart` 检查（死链、指空的章节引用、正文里的状态词与版本号），
改完跑 `dart run tool/check_docs.dart --strict`。
