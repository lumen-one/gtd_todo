/// 局域网同步插座（architecture.md §4.4）。
///
/// **定位**：同步器只是"又一个写文件的人"——它只负责把任务目录里的核心文件
/// 搬到对端，搬完由既有的 `watch() → refresh()` 链路重锚。这里因此**没有**
/// 任何文件 API：路径是字符串、内容是字节，`dart:io` 留给 platform 层实现。
///
/// 拓扑 = 主机/从机：一台起服务（主机），其余接入（从机）；双向同步，
/// 冲突由主机裁决（从机被覆盖的版本存档，见 [SyncConflict]）。
library;

import 'dart:async';

/// 同步角色。null（[SyncState.role]）= 未开启。
enum SyncRole { host, guest }

/// 局域网里发现的一台主机。
class SyncPeer {
  final String name;

  /// IPv4 地址（发现应答的源地址；手输 IP 时即用户填的）。
  final String address;

  /// 主机的 HTTP 端口。
  final int port;

  const SyncPeer({required this.name, required this.address, required this.port});

  /// "ip:port"——UI 展示与手输兜底用同一格式。
  String get endpoint => '$address:$port';

  @override
  bool operator ==(Object other) =>
      other is SyncPeer && other.endpoint == endpoint;

  @override
  int get hashCode => endpoint.hashCode;

  @override
  String toString() => '$name（$endpoint）';
}

/// 一次冲突：对端版本被主机覆盖，存档留在 `.gtd/conflicts/` 等人收拾。
class SyncConflict {
  /// 相对任务目录的路径（同步范围内的那个文件）。
  final String path;

  /// 存档位置（相对任务目录），如 `.gtd/conflicts/tasks.md.手机.2026-10-16T16-30-00.md`。
  final String archivePath;

  const SyncConflict({required this.path, required this.archivePath});

  @override
  String toString() => '$path → 存档 $archivePath';
}

/// 一轮同步的结果（手动同步 / 自动同步都返回它）。
class SyncOutcome {
  final int pulled;
  final int pushed;

  /// 镜像删除的数量（主机删了、从机跟着删）。
  final int deleted;

  final List<SyncConflict> conflicts;

  /// 非 null = 这轮失败了（网络断了、对端不是本应用等）。
  final String? error;

  const SyncOutcome({
    this.pulled = 0,
    this.pushed = 0,
    this.deleted = 0,
    this.conflicts = const [],
    this.error,
  });

  bool get ok => error == null;

  @override
  String toString() => ok
      ? '拉 $pulled / 推 $pushed / 删 $deleted'
          '${conflicts.isEmpty ? '' : ' / 冲突 ${conflicts.length}'}'
      : '失败：$error';
}

/// 同步状态（UI 只消费这个）。变化通过 [SyncPort.changes] 广播。
class SyncState {
  /// null = 没开同步（既不当主机也没接入）。
  final SyncRole? role;

  /// 主机的服务在听 / 从机已连上（连上后本端也起一个小服务收推送）。
  final bool running;

  /// 对端设备名：从机视角 = 主机名；主机视角 = 最近连上的从机名。
  final String? peerName;

  final DateTime? lastSyncAt;

  /// 最近几轮攒下的冲突（UI 提示"去 .gtd/conflicts/ 收拾"）。
  final List<SyncConflict> conflicts;

  final String? error;

  /// 正在发现 / 正在同步（UI 转圈用）。
  final bool busy;

  const SyncState({
    this.role,
    this.running = false,
    this.peerName,
    this.lastSyncAt,
    this.conflicts = const [],
    this.error,
    this.busy = false,
  });

  const SyncState.idle()
      : role = null,
        running = false,
        peerName = null,
        lastSyncAt = null,
        conflicts = const [],
        error = null,
        busy = false;

  SyncState copyWith({
    SyncRole? role,
    bool? running,
    String? peerName,
    DateTime? lastSyncAt,
    List<SyncConflict>? conflicts,
    String? error,
    bool? busy,
  }) {
    return SyncState(
      role: role ?? this.role,
      running: running ?? this.running,
      peerName: peerName ?? this.peerName,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      conflicts: conflicts ?? this.conflicts,
      error: error ?? this.error,
      busy: busy ?? this.busy,
    );
  }

  /// 设置页一行话摘要。
  String get summary {
    if (role == null) return '未开启';
    final who = role == SyncRole.host ? '主机' : '从机';
    final link = running ? (peerName == null ? '等待接入' : '已连接 $peerName') : '未连接';
    final last = lastSyncAt == null ? '尚未同步' : '上次同步 $lastSyncAt';
    return '$who · $link · $last';
  }
}

/// 同步插座（§4.4）。实现 = platform 层的局域网适配器（HTTP + UDP）。
abstract class SyncPort {
  SyncState get state;

  /// 状态变化广播（广播流，UI 订阅后 setState）。
  Stream<SyncState> get changes;

  /// 当主机：起 HTTP 服务 + UDP 广播报站。Windows 首次会弹防火墙对话框。
  Future<void> startHost(String deviceName);

  /// 扫局域网内的主机（UDP 广播探询 + 收集应答）。
  Future<List<SyncPeer>> discover({
    Duration timeout = const Duration(milliseconds: 1500),
  });

  /// 以从机身份接入指定主机，并立即同步一轮。
  Future<SyncOutcome> connectTo(SyncPeer peer, String deviceName);

  /// 手动触发一轮（主机 = 等待从机推；从机 = 拉取 + 推送）。
  Future<SyncOutcome> syncNow();

  /// 停止：服务下播 / 断开连接，状态回 [SyncState.idle]。
  Future<void> stop();
}
