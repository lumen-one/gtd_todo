# 局域网同步

同一网络内两台设备同步任务数据。同步器只是"又一个写文件的人"——只搬文件，写完由
既有的 `watch() → refresh()` 链路重锚，内核、调度、UI 数据流零改动。

装配点在 `main.dart`——只有主引擎挂同步器。

**局域网同步**：同一网络内的两台设备（Windows + 安卓）同步任务数据。同步器只是
"**又一个写文件的人**"——它只搬文件，写完由既有的 `watch() → refresh()` 链路重锚，
内核、调度、UI 数据流零改动（与悬浮窗第二引擎同一条边界精神：数据一致靠文件，
不靠共享内存态）。

```dart
/// 同步：只管"把文件搬到对端"，不管文件里是什么。
abstract class SyncPort {
  SyncState get state;                    // 角色 / 连接 / 上次同步 / 冲突存档
  Stream<SyncState> get changes;          // 状态广播（UI 订阅）

  Future<void> startHost(String deviceName);                        // 当主机
  Future<List<SyncPeer>> discover({Duration timeout});              // 扫局域网内的主机
  Future<SyncOutcome> connectTo(SyncPeer peer, String deviceName);  // 接入并同步
  Future<SyncOutcome> syncNow();                                    // 手动同步一次
  Future<void> stop();
}
```

**拓扑 = 主机/从机**（不做无主机 P2P）：一台（通常 Windows）起服务，其余接入；
双向同步，冲突由主机裁决。主机 = HTTP 服务（manifest / file / push 三个端点）
+ UDP 广播报站；从机 = 探询发现 → 连主机 → 双向搬文件；发现失败时支持手输 IP 兜底。

**同步范围 = 核心任务数据**：`tasks.md`、`routines.md`、`主线.md`、`.gtd/<任务id>.md`。
**不同步**：`.gtd/log.md`（append-only，双写必乱序）、`.gtd/.trash/`（回收站是
本地操作缓冲，不跨设备）、`.gtd/conflicts/`（冲突存档，本地人工收拾）、
`settings.json`（设备相关：面板宽高 / 把手位置 / 主题档位）、`legacy-tasks/`（存档）。

**方向裁决 = 逐文件比指纹**：从机存一份"上次握手时主机的清单"（path → 内容指纹）。
主机清单里有的文件，指纹不同 → 拉取；只在从机本地有的文件，或指纹与上次清单
不同（从机改过）→ 推送；主机清单里**消失**的路径 = 主机删了 → 从机本地一并删
（镜像删除，恢复由主机回收站负责）。跨设备 mtime 只作同轮参考，不作长期依据。

**冲突 = 主机覆盖 + 从机版本存档**：推送带 `baseSha`（从机动手前那一版的指纹）。
主机照收的条件 = 主机当前版本 == baseSha（只有从机改过）；主机也改过 → 不静默
覆盖，从机版本存档到 `.gtd/conflicts/<相对路径>.<设备名>.<时刻>`，从机随即拉取
主机版本收敛（不会每轮重复存档）。UI 提示人工收拾。

**已知取舍**（记录在案，见 [architecture.md](../architecture.md) §11）：跨设备时钟可能偏差，mtime 参考值会骗人；主机
同时只应对一个从机的推送（两个从机同轮推同一文件按到达顺序覆盖，与"双开实例"
同级的已知局限）。

**装配**：只在主引擎挂（`main.dart`），悬浮引擎不挂（它没有写入职责，主机服务
也只需一份）。Windows 首次当主机会弹防火墙对话框，需允许专用网络入站。
