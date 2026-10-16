import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/sync.dart';
import 'package:gtd_todo/platform/lan_sync.dart';

/// LanSyncAdapter 的回环集成测试（architecture.md §4.4）：
/// 主机与从机都跑在本机（127.0.0.1），发现走手填 peer（广播在测试环境不可靠），
/// 搬文件的协议与真机完全同一条。
void main() {
  late Directory root;
  late Directory hostDir;
  late Directory guestDir;
  late LanSyncAdapter host;
  late LanSyncAdapter guest;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lan_sync_test');
    hostDir = Directory('${root.path}/host');
    guestDir = Directory('${root.path}/guest');
    for (final d in [hostDir, guestDir]) {
      d.createSync(recursive: true);
    }
    host = LanSyncAdapter(taskDir: hostDir.path, stateDir: '${root.path}/hs');
    guest = LanSyncAdapter(taskDir: guestDir.path, stateDir: '${root.path}/gs');
  });

  tearDown(() async {
    await host.stop();
    await guest.stop();
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Windows 上文件刚写完可能删不掉：测试数据在临时目录，无妨
    }
  });

  File seed(Directory dir, String rel, String content) {
    final f = File('${dir.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  String read(Directory dir, String rel) =>
      File('${dir.path}/$rel').readAsStringSync();

  Future<SyncOutcome> connect() =>
      guest.connectTo(const SyncPeer(name: '客厅Windows', address: '127.0.0.1',
          port: LanSyncAdapter.httpPort), '测试手机');

  test('从机接入：拉取主机全部核心文件，流水不同步', () async {
    seed(hostDir, 'tasks.md', '# 工作\n- [ ] 写周报\n');
    seed(hostDir, 'routines.md', '# 周期\n');
    seed(hostDir, '.gtd/task-001.md', 'id: task-001\n');
    seed(hostDir, '.gtd/log.md', '流水不该同步\n');
    seed(hostDir, 'settings.json', '{"theme_mode":"dark"}');

    await host.startHost('客厅Windows');
    final outcome = await connect();

    expect(outcome.ok, true);
    expect(outcome.pulled, 3);
    expect(read(guestDir, 'tasks.md'), '# 工作\n- [ ] 写周报\n');
    expect(File('${guestDir.path}/.gtd/task-001.md').existsSync(), true);
    // 不同步：流水、设置（设备相关）
    expect(File('${guestDir.path}/.gtd/log.md').existsSync(), false);
    expect(File('${guestDir.path}/settings.json').existsSync(), false);
    // 状态摆到 UI 看得见的地方
    expect(guest.state.role, SyncRole.guest);
    expect(guest.state.running, true);
    expect(guest.state.peerName, '客厅Windows');
    expect(guest.state.lastSyncAt, isNotNull);
  });

  test('双向：从机改动推给主机，主机改动拉回从机', () async {
    seed(hostDir, 'tasks.md', '# host\n');
    await host.startHost('客厅Windows');
    await connect();

    // 从机改 → 主机收
    seed(guestDir, 'tasks.md', '# guest edit\n');
    var outcome = await guest.syncNow();
    expect(outcome.ok, true);
    expect(outcome.pushed, 1);
    expect(read(hostDir, 'tasks.md'), '# guest edit\n');

    // 主机改 → 从机收
    seed(hostDir, 'routines.md', 'r1\n');
    outcome = await guest.syncNow();
    expect(outcome.pulled, 1);
    expect(read(guestDir, 'routines.md'), 'r1\n');

    // 第三轮：两边都没动 → 零搬运（不反复触发文件监听）
    outcome = await guest.syncNow();
    expect(outcome.pulled, 0);
    expect(outcome.pushed, 0);
    expect(outcome.deleted, 0);
  });

  test('双改冲突：主机赢，从机本地存档，不静默丢数据', () async {
    seed(hostDir, 'tasks.md', 'common\n');
    await host.startHost('客厅Windows');
    await connect(); // 收敛到 common

    seed(hostDir, 'tasks.md', 'host version\n');
    seed(guestDir, 'tasks.md', 'guest version\n');
    final outcome = await guest.syncNow();

    expect(outcome.conflicts.length, 1);
    expect(read(guestDir, 'tasks.md'), 'host version\n'); // 主机赢
    // 从机用户在自己设备上捡得回来
    final guestArchives =
        Directory('${guestDir.path}/.gtd/conflicts').listSync();
    expect(guestArchives.length, 1);
    expect(File(guestArchives.first.path).readAsStringSync(), 'guest version\n');
    // 主机侧也存了一份（Obsidian 里可见）
    expect(Directory('${hostDir.path}/.gtd/conflicts').listSync().length, 1);

    // 再同步一轮：不再重复存档（已收敛）
    final again = await guest.syncNow();
    expect(again.conflicts, isEmpty);
    expect(
        Directory('${guestDir.path}/.gtd/conflicts').listSync().length, 1);
  });

  test('镜像删除：主机删了，从机跟着删', () async {
    seed(hostDir, 'tasks.md', 'x\n');
    seed(hostDir, '.gtd/task-001.md', 'id: task-001\n');
    await host.startHost('客厅Windows');
    await connect();

    File('${hostDir.path}/.gtd/task-001.md').deleteSync();
    final outcome = await guest.syncNow();
    expect(outcome.deleted, 1);
    expect(File('${guestDir.path}/.gtd/task-001.md').existsSync(), false);
  });

  test('本地主动删的任务不会被主机复活', () async {
    seed(hostDir, 'tasks.md', 'x\n');
    seed(hostDir, '.gtd/task-001.md', 'id: task-001\n');
    await host.startHost('客厅Windows');
    await connect();

    // 从机侧"删除"（真机上 = 移入 .trash + 注释行；测试直接删文件等效）
    File('${guestDir.path}/.gtd/task-001.md').deleteSync();
    final outcome = await guest.syncNow();
    expect(outcome.pulled, 0);
    expect(File('${guestDir.path}/.gtd/task-001.md').existsSync(), false);
  });

  test('推送路径穿越被拒', () async {
    await host.startHost('客厅Windows');
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(
          'http://127.0.0.1:${LanSyncAdapter.httpPort}/push'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'guest': '坏从机',
        'files': [
          {
            'path': '../evil.md',
            'sha': 'x',
            'baseSha': null,
            'content': base64Encode(utf8.encode('evil'))
          },
          {
            'path': 'settings.json', // 同步范围外
            'sha': 'x',
            'baseSha': null,
            'content': base64Encode(utf8.encode('{}'))
          },
        ],
      }));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      final results = (jsonDecode(text) as Map<String, dynamic>)['results']
          as List<dynamic>;
      expect((results[0] as Map)['status'], 'rejected');
      expect((results[1] as Map)['status'], 'rejected');
      expect(File('${root.path}/evil.md').existsSync(), false);
    } finally {
      client.close(force: true);
    }
  });

  test('主机未启动时从机同步报错不崩', () async {
    final outcome = await connect();
    expect(outcome.ok, false);
    expect(outcome.error, isNotNull);
    expect(guest.state.running, false);
  });
}
