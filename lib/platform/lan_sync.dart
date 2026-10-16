import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../application/sync.dart';

/// 局域网同步的纯 `dart:io` 实现（architecture.md §4.4）：HTTP 搬文件 + UDP 广播发现。
/// Windows / 安卓通用，不引第三方包；只被组装点（main.dart）引用，
/// application 层只见 [SyncPort]。
///
/// 角色分工：
/// - **主机**：HTTP 服务（manifest / file / push 三个端点）+ UDP 广播报站；
/// - **从机**：UDP 探询发现 → 接入主机 → 拉取（主机改过的）+ 推送（从机改过的）。
///
/// 本类**不碰 TaskService**：写完文件即由应用原有的 `watch() → refresh()` 链路重锚。
class LanSyncAdapter implements SyncPort {
  /// HTTP 服务端口（主机）与 UDP 广播端口（发现）。固定值，README 有说明。
  static const int httpPort = 49872;
  static const int udpPort = 49871;

  static const String _probeMagic = 'GTD_SYNC_PROBE';
  static const String _announceMagic = 'GTD_SYNC_HOST';
  static const Duration _announceEvery = Duration(seconds: 2);
  static const Duration _autoSyncEvery = Duration(minutes: 3);
  static const Duration _ioTimeout = Duration(seconds: 5);

  /// 同步范围内的根级文件。
  static const List<String> _rootFiles = ['tasks.md', 'routines.md'];

  /// 内核属性目录名（与 MarkdownTaskRepository 对齐；只同步顶层 `<id>.md`）。
  static const String _kernelDir = '.gtd';

  /// 不同步的内核目录成员：流水（append-only）、回收站（本地缓冲）、冲突存档。
  static const List<String> _kernelExcluded = ['log.md', '.trash', 'conflicts'];

  final String taskDir;

  /// 同步状态文件所在目录（应用支持目录，与 bootstrap.json 同层）。
  /// "上次握手清单"不能进任务目录——任务目录是要同步的内容本身。
  final String stateDir;

  SyncState _state = const SyncState.idle();
  final StreamController<SyncState> _changes =
      StreamController<SyncState>.broadcast();

  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _announceTimer;
  Timer? _autoSyncTimer;
  String _deviceName = '';

  /// 从机视角：当前接入的主机。
  SyncPeer? _host;

  /// 同步轮串行化（自动定时 + 手动按钮 + 回前台可能撞在一起）。
  Future<SyncOutcome> _roundChain = Future.value(const SyncOutcome());

  LanSyncAdapter({required this.taskDir, required this.stateDir});

  @override
  SyncState get state => _state;

  @override
  Stream<SyncState> get changes => _changes.stream;

  void _emit(SyncState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  // ------------------------------------------------------------------
  // 主机
  // ------------------------------------------------------------------

  @override
  Future<void> startHost(String deviceName) async {
    if (_state.role == SyncRole.host) return;
    await stop();
    _deviceName = deviceName;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
      _server!.listen(_handleRequest);
      await _startUdp(announce: true);
      _emit(const SyncState(role: SyncRole.host, running: true));
    } catch (e) {
      await _teardown();
      // 端口被占 / 防火墙拦住：不崩，把原因摆到设置页。
      _emit(SyncState(
          role: SyncRole.host, running: false, error: '主机启动失败：$e'));
    }
  }

  Future<void> _startUdp({required bool announce}) async {
    _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    _udp!.broadcastEnabled = true;
    _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _udp!.receive();
      if (dg == null) return;
      if (utf8.decode(dg.data) == _probeMagic) {
        _udp!.send(utf8.encode(_announcePayload()), dg.address, dg.port);
      }
    });
    if (announce) {
      _announceTimer =
          Timer.periodic(_announceEvery, (_) => _broadcastAnnounce());
      _broadcastAnnounce();
    }
  }

  String _announcePayload() =>
      '$_announceMagic\x1f${_sanitizeName(_deviceName)}\x1f$httpPort';

  void _broadcastAnnounce() {
    try {
      _udp?.send(utf8.encode(_announcePayload()),
          InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {
      // 某些网络禁广播：从机还有手输 IP 兜底（connectTo）。
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/manifest') {
        await _replyJson(
            req, {'name': _sanitizeName(_deviceName), 'files': _manifestJson()});
      } else if (req.method == 'GET' && path == '/file') {
        await _serveFile(req, req.uri.queryParameters['path'] ?? '');
      } else if (req.method == 'POST' && path == '/push') {
        await _handlePush(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      // 单次请求出错不该带走服务：回 500，连接照常。
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {
        // 对端可能已经断了
      }
    }
  }

  Future<void> _serveFile(HttpRequest req, String rel) async {
    final file = _safeFile(rel);
    if (file == null || !file.existsSync()) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final bytes = await file.readAsBytes();
    req.response.headers.contentType = ContentType.binary;
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  /// 从机推送：带 `baseSha`（从机动手前那一版的指纹）。主机照收的条件 =
  /// 主机没有这个文件，或主机当前版本 == baseSha（只有从机改过）；
  /// 主机也改过 → 从机版本在**主机侧**存档到 `.gtd/conflicts/`，主机版本不动，
  /// 从机随后拉主机版本收敛（从机自己也会在本地存一份，见 [_round]）。
  Future<void> _handlePush(HttpRequest req) async {
    final body = await _readBody(req);
    final guestName = _sanitizeName((body['guest'] as String?) ?? '从机');
    final files = (body['files'] as List<Object?>?) ?? const [];
    final results = <Map<String, Object?>>[];
    for (final raw in files) {
      final entry = (raw as Map<String, Object?>?) ?? const {};
      final rel = (entry['path'] as String?) ?? '';
      final target = _safeFile(rel);
      if (target == null) {
        results.add({'path': rel, 'status': 'rejected'});
        continue;
      }
      final content = base64Decode((entry['content'] as String?) ?? '');
      final incomingSha = (entry['sha'] as String?) ?? _hashBytes(content);
      final baseSha = entry['baseSha'] as String?;
      final mtimeMs = (entry['mtime'] as num?)?.toInt();

      if (!target.existsSync()) {
        await _writePreservingMtime(target, content, mtimeMs);
        results.add({'path': rel, 'status': 'applied'});
        continue;
      }
      final hostSha = _hashFile(target);
      if (hostSha == incomingSha) {
        // 已经是同一份：不重写（重写只会白白触发一次文件监听）。
        results.add({'path': rel, 'status': 'applied'});
        continue;
      }
      if (hostSha == baseSha) {
        // 只有从机改过 → 照收。
        await _writePreservingMtime(target, content, mtimeMs);
        results.add({'path': rel, 'status': 'applied'});
        continue;
      }
      // 双方都改过：不静默覆盖，主机侧存档等人收拾。
      final archive = await _archiveConflict(rel, guestName, content);
      results.add({'path': rel, 'status': 'conflict', 'archive': archive});
    }
    _emit(_state.copyWith(
      peerName: guestName,
      lastSyncAt: DateTime.now(),
      error: null,
    ));
    await _replyJson(req, {'results': results});
  }

  // ------------------------------------------------------------------
  // 从机
  // ------------------------------------------------------------------

  @override
  Future<List<SyncPeer>> discover({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    _emit(_state.copyWith(busy: true, error: null));
    final found = <String, SyncPeer>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final parts = utf8.decode(dg.data).split('\x1f');
        if (parts.length != 3 || parts[0] != _announceMagic) return;
        final peer = SyncPeer(
          name: parts[1],
          address: dg.address.address,
          port: int.tryParse(parts[2]) ?? httpPort,
        );
        found[peer.endpoint] = peer;
      });
      final probeBytes = utf8.encode(_probeMagic);
      final target = InternetAddress('255.255.255.255');
      final ticker =
          Timer.periodic(const Duration(milliseconds: 400), (_) {
        try {
          socket!.send(probeBytes, target, udpPort);
        } catch (_) {
          // 广播被禁：等手动 IP
        }
      });
      await Future<void>.delayed(timeout);
      ticker.cancel();
      await sub.cancel();
    } catch (e) {
      _emit(_state.copyWith(busy: false, error: '扫描失败：$e'));
      return const [];
    } finally {
      socket?.close();
    }
    _emit(_state.copyWith(busy: false));
    return found.values.toList();
  }

  @override
  Future<SyncOutcome> connectTo(SyncPeer peer, String deviceName) async {
    _deviceName = deviceName;
    _host = peer;
    final outcome = await syncNow();
    if (outcome.ok) {
      _autoSyncTimer?.cancel();
      _autoSyncTimer = Timer.periodic(_autoSyncEvery, (_) => syncNow());
    }
    return outcome;
  }

  @override
  Future<SyncOutcome> syncNow() {
    final host = _host;
    if (host == null) {
      return Future.value(const SyncOutcome(error: '尚未连接主机'));
    }
    // 串行化：上一轮没跑完，这一轮排队（手动按钮连点只触发一轮）。
    final next = _roundChain.then((_) => _round(host));
    _roundChain = next.catchError((_) => const SyncOutcome());
    return next;
  }

  /// 一轮同步：拉主机改过的 → 推从机改过的 → 冲突收敛 → 镜像删除。
  Future<SyncOutcome> _round(SyncPeer host) async {
    _emit(_state.copyWith(
      role: SyncRole.guest,
      busy: true,
      error: null,
      peerName: host.name,
    ));
    try {
      final hostFiles = _parseManifest(await _getJson(host, '/manifest'));
      final local = _scanLocal();
      final last = _loadLastManifest(host.endpoint);

      var pulled = 0;
      var pushed = 0;
      var deleted = 0;
      final conflicts = <SyncConflict>[];

      // 1) 拉取：主机有、本地没有或本地没改过（本地这份就是上次握手时的版本）。
      for (final entry in hostFiles.entries) {
        final path = entry.key;
        final h = entry.value;
        final l = local[path];
        if (l == null) {
          // 本地没有：主机也没变过 = 本地删的（尊重本地删除，不复活）。
          if (last[path] == h.sha) continue;
        } else if (l.sha == h.sha) {
          continue; // 已经一致
        } else if (last[path] != l.sha) {
          continue; // 本地也改过 → 走推送，让主机裁决
        }
        await _pullFile(host, path, h);
        local[path] = h; // 拉完即收敛：本地版本 = 主机版本
        pulled++;
      }

      // 2) 推送：本地有、且**从机改过**——指纹既不同于上次握手版本，
      //    也不同于主机当前版本（后者说明上一步已拉平，不用回推）。
      final pushList = <Map<String, Object?>>[];
      final pushedBytes = <String, List<int>>{};
      for (final entry in local.entries) {
        final path = entry.key;
        if (last[path] == entry.value.sha) continue; // 没改过
        final hostSha = hostFiles[path]?.sha;
        if (hostSha != null && hostSha == entry.value.sha) continue; // 已拉平
        final bytes = await File('$taskDir/$path').readAsBytes();
        pushedBytes[path] = bytes;
        pushList.add({
          'path': path,
          'sha': entry.value.sha,
          'mtime': entry.value.mtime,
          'baseSha': last[path],
          'content': base64Encode(bytes),
        });
      }
      if (pushList.isNotEmpty) {
        pushed = pushList.length;
        final resp =
            await _postJson(host, '/push', {'guest': _deviceName, 'files': pushList});
        for (final raw in (resp['results'] as List<Object?>?) ?? const []) {
          final r = (raw as Map<String, Object?>?) ?? const {};
          final status = r['status'] as String?;
          if (status == 'applied') continue;
          if (status == 'conflict') {
            // 主机赢：从机本地也存一份档（主机侧已存，但被覆盖的是从机用户的
            // 改动，得让他在自己设备上捡得回来），再拉主机版本收敛。
            final path = r['path'] as String;
            final bytes = pushedBytes[path];
            if (bytes != null) {
              await _archiveConflict(path, _sanitizeName(_deviceName), bytes);
            }
            final h = hostFiles[path] ?? (await _reloadEntry(host, path));
            if (h != null) await _pullFile(host, path, h);
            conflicts.add(SyncConflict(
                path: path, archivePath: (r['archive'] as String?) ?? ''));
            continue;
          }
          // rejected：路径不被同步范围接受，本地文件原样保留。
        }
      }

      // 3) 镜像删除：上次清单有、这次主机没有 = 主机删了。
      for (final path in last.keys) {
        if (hostFiles.containsKey(path)) continue;
        final f = File('$taskDir/$path');
        if (f.existsSync()) {
          f.deleteSync();
          deleted++;
        }
      }

      _saveLastManifest(host.endpoint, _convergedManifest(hostFiles));
      final outcome = SyncOutcome(
          pulled: pulled,
          pushed: pushed,
          deleted: deleted,
          conflicts: conflicts);
      _emit(_state.copyWith(
        role: SyncRole.guest,
        running: true,
        peerName: host.name,
        lastSyncAt: DateTime.now(),
        busy: false,
        error: null,
      ));
      return outcome;
    } catch (e) {
      _emit(_state.copyWith(
          role: SyncRole.guest, running: false, busy: false, error: '$e'));
      return SyncOutcome(error: '$e');
    }
  }

  /// 拉一个文件：内容照写，mtime 保留主机那份（跨设备时钟不可靠，
  /// 但"下次比较时两边看到同一个 mtime"能让参考值稳定）。
  Future<void> _pullFile(SyncPeer host, String path, _Entry h) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('http://${host.address}:${host.port}'
              '/file?path=${Uri.encodeQueryComponent(path)}'))
          .timeout(_ioTimeout);
      final resp = await req.close().timeout(_ioTimeout);
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('拉取 $path 失败：HTTP ${resp.statusCode}');
      }
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final target = File('$taskDir/$path');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes);
      try {
        target.setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(h.mtime));
      } catch (_) {
        // 文件系统不许改 mtime 就算了：内容已经是对的
      }
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------------
  // 停止
  // ------------------------------------------------------------------

  @override
  Future<void> stop() async {
    _announceTimer?.cancel();
    _autoSyncTimer?.cancel();
    _announceTimer = null;
    _autoSyncTimer = null;
    _host = null;
    await _teardown();
    _emit(const SyncState.idle());
  }

  Future<void> _teardown() async {
    try {
      await _server?.close(force: true);
    } catch (_) {
      // 已经关了
    }
    _server = null;
    _udp?.close();
    _udp = null;
  }

  // ------------------------------------------------------------------
  // 清单与状态文件
  // ------------------------------------------------------------------

  Map<String, Object?> _manifestJson() {
    final out = <String, Object?>{};
    for (final e in _scanLocal().entries) {
      out[e.key] = {
        'sha': e.value.sha,
        'mtime': e.value.mtime,
        'size': e.value.size,
      };
    }
    return out;
  }

  Map<String, _Entry> _parseManifest(Map<String, dynamic> json) {
    final out = <String, _Entry>{};
    final files = (json['files'] as Map<String, Object?>?) ?? const {};
    for (final e in files.entries) {
      final v = (e.value as Map<String, Object?>?) ?? const {};
      out[e.key] = _Entry(
        sha: (v['sha'] as String?) ?? '',
        mtime: (v['mtime'] as num?)?.toInt() ?? 0,
        size: (v['size'] as num?)?.toInt() ?? 0,
      );
    }
    return out;
  }

  /// 本地同步范围内的文件（相对路径用 `/`，跨平台一致）。
  Map<String, _Entry> _scanLocal() {
    final out = <String, _Entry>{};
    void add(File f, String rel) {
      final st = f.statSync();
      out[rel] = _Entry(
        sha: _hashBytes(f.readAsBytesSync()),
        mtime: st.modified.millisecondsSinceEpoch,
        size: st.size,
      );
    }

    for (final name in _rootFiles) {
      final f = File('$taskDir/$name');
      if (f.existsSync()) add(f, name);
    }
    final kernel = Directory('$taskDir/$_kernelDir');
    if (kernel.existsSync()) {
      for (final entity in kernel.listSync()) {
        if (entity is! File) continue; // .trash/ conflicts/ 等子目录不递归
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.md')) continue;
        if (_kernelExcluded.contains(name)) continue;
        add(entity, '$_kernelDir/$name');
      }
    }
    return out;
  }

  /// 收敛后的"上次握手清单"：一律以**当前磁盘**为准（拉取/推送/镜像删除
  /// 都已完成），主机清单里本地已删的记主机版本（下次不会再拉复活）。
  Map<String, String> _convergedManifest(Map<String, _Entry> hostFiles) {
    final out = <String, String>{};
    for (final path in {...hostFiles.keys, ..._scanLocal().keys}) {
      final f = File('$taskDir/$path');
      if (f.existsSync()) {
        out[path] = _hashBytes(f.readAsBytesSync());
      } else {
        out[path] = hostFiles[path]?.sha ?? '';
      }
    }
    return out;
  }

  Map<String, String> _loadLastManifest(String endpoint) {
    try {
      final f = File('$stateDir/sync-state.json');
      if (!f.existsSync()) return const {};
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final hosts = (json['hosts'] as Map<String, Object?>?) ?? const {};
      final mine = (hosts[endpoint] as Map<String, Object?>?) ?? const {};
      return mine.map((k, v) => MapEntry(k, (v as String?) ?? ''));
    } catch (_) {
      return const {}; // 坏状态文件当作第一次握手
    }
  }

  void _saveLastManifest(String endpoint, Map<String, String> manifest) {
    try {
      final f = File('$stateDir/sync-state.json');
      final json = <String, Object?>{
        'hosts': {endpoint: manifest},
      };
      // 保留别的主机的记录（换过主机的用户不该丢历史）。
      if (f.existsSync()) {
        final old = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        final hosts = (old['hosts'] as Map<String, Object?>?) ?? const {};
        json['hosts'] = {...hosts, endpoint: manifest};
      }
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    } catch (_) {
      // 状态文件写不了不影响同步正确性：退化成"每轮都重新比一遍"
    }
  }

  // ------------------------------------------------------------------
  // 路径安全与工具
  // ------------------------------------------------------------------

  /// 推送/拉取只接受同步范围内的相对路径（防目录穿越）。
  File? _safeFile(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.contains('..')) return null;
    final parts = rel.split('/');
    if (parts.length == 1) {
      return _rootFiles.contains(rel) ? File('$taskDir/$rel') : null;
    }
    if (parts.length != 2) return null; // 只到 .gtd/<name>.md 一层
    if (parts[0] != _kernelDir) return null;
    if (!parts[1].endsWith('.md')) return null;
    if (_kernelExcluded.contains(parts[1])) return null;
    return File('$taskDir/$rel');
  }

  Future<Map<String, dynamic>> _readBody(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> _replyJson(HttpRequest req, Map<String, Object?> body) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(const JsonEncoder().convert(body));
    await req.response.close();
  }

  Future<Map<String, dynamic>> _getJson(SyncPeer peer, String path) async {
    final client = HttpClient();
    try {
      final url = Uri.parse('http://${peer.address}:${peer.port}$path');
      final req = await client.getUrl(url).timeout(_ioTimeout);
      final resp = await req.close().timeout(_ioTimeout);
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final body =
          await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
      SyncPeer peer, String path, Map<String, Object?> body) async {
    final client = HttpClient();
    try {
      final url = Uri.parse('http://${peer.address}:${peer.port}$path');
      final req = await client.postUrl(url).timeout(_ioTimeout);
      req.headers.contentType = ContentType.json;
      req.write(const JsonEncoder().convert(body));
      final resp = await req.close().timeout(_ioTimeout);
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final text = await resp.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// 冲突存档：`.gtd/conflicts/<flat>.<设备名>.<时刻>.md`（flat = 路径的 / 换 _）。
  /// `.gtd/` 的扫描不递归（markdown_task_repository），这里不会被当成任务文件。
  Future<String> _archiveConflict(
      String rel, String deviceName, List<int> content) async {
    final dir = Directory('$taskDir/$_kernelDir/conflicts');
    dir.createSync(recursive: true);
    final now = DateTime.now();
    final stamp = '${now.year}${_two(now.month)}${_two(now.day)}'
        '-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final flat = rel.replaceAll('/', '_');
    final name = '$flat.$deviceName.$stamp.md';
    File('${dir.path}/$name').writeAsBytesSync(content);
    return '$_kernelDir/conflicts/$name';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 设备名进文件名/广播：去掉分隔符与奇怪字符，截断。
  static String _sanitizeName(String name) {
    final cleaned =
        name.replaceAll(RegExp(r'[\\/:*?"<>|\x1f]'), '_').trim();
    final out = cleaned.isEmpty ? '设备' : cleaned;
    return out.length > 24 ? out.substring(0, 24) : out;
  }

  Future<void> _writePreservingMtime(
      File target, List<int> content, int? mtimeMs) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(content);
    if (mtimeMs != null) {
      try {
        target.setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(mtimeMs));
      } catch (_) {
        // 不许改 mtime 就算了
      }
    }
  }

  /// 内容指纹：FNV-1a 64 位，纯 Dart 无依赖，与 task_document.dart 的行指纹
  /// 同一风格（那里 32 位够行内去重；这里要比整份文件，上 64 位）。
  /// 不是安全哈希，只做"这一版和那一版是否相同"的裁决。
  static String _hashBytes(List<int> bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h = (h ^ b) * 0x100000001b3;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  static String _hashFile(File f) => _hashBytes(f.readAsBytesSync());

  Future<_Entry?> _reloadEntry(SyncPeer host, String path) async {
    final manifest = _parseManifest(await _getJson(host, '/manifest'));
    return manifest[path];
  }
}

/// 同步范围内一个文件的版本标识：内容指纹 + mtime + 大小。
class _Entry {
  final String sha;
  final int mtime;
  final int size;

  const _Entry({required this.sha, required this.mtime, required this.size});
}
