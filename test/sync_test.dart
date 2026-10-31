import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/sync.dart';

/// SyncPort 模型的单测（§4.4）：UI 只消费这些值，摘要文案要对。
void main() {
  group('SyncPeer', () {
    test('endpoint 与相等性按 ip:port', () {
      const a = SyncPeer(name: '客厅Windows', address: '192.168.1.5', port: 49872);
      const b = SyncPeer(name: '另一个名字', address: '192.168.1.5', port: 49872);
      const c = SyncPeer(name: '客厅Windows', address: '192.168.1.6', port: 49872);
      expect(a.endpoint, '192.168.1.5:49872');
      expect(a, b); // 同名不同名也算同一台（endpoint 相同）
      expect(a, isNot(c));
      expect(a.toString(), contains('192.168.1.5:49872'));
    });
  });

  group('SyncState.summary', () {
    test('未开启', () {
      expect(const SyncState.idle().summary, '未开启');
    });

    test('主机等待接入', () {
      const s = SyncState(role: SyncRole.host, running: true);
      expect(s.summary, contains('主机'));
      expect(s.summary, contains('等待接入'));
      expect(s.summary, contains('尚未同步'));
    });

    test('从机已连接 + 上次同步', () {
      final s = SyncState(
        role: SyncRole.guest,
        running: true,
        peerName: '客厅Windows',
        lastSyncAt: DateTime(2026, 10, 16, 16, 30),
      );
      expect(s.summary, contains('从机'));
      expect(s.summary, contains('已连接 客厅Windows'));
      expect(s.summary, contains('上次同步'));
    });

    test('copyWith 只改传入的字段', () {
      const s = SyncState(role: SyncRole.host, running: true);
      final next = s.copyWith(busy: true);
      expect(next.busy, true);
      expect(next.role, SyncRole.host);
      expect(next.running, true);
    });
  });

  group('SyncOutcome', () {
    test('ok 轮次摘要带冲突数', () {
      const o = SyncOutcome(
        pulled: 2,
        pushed: 1,
        deleted: 1,
        conflicts: [SyncConflict(path: 'tasks.md', archivePath: '.gtd/conflicts/x')],
      );
      expect(o.ok, true);
      expect(o.toString(), '拉 2 / 推 1 / 删 1 / 冲突 1');
    });

    test('失败轮次', () {
      const o = SyncOutcome(error: '连不上');
      expect(o.ok, false);
      expect(o.toString(), '失败：连不上');
    });
  });
}
