import 'package:flutter/material.dart';

import '../../application/sync.dart';
import '../app_controller.dart';

/// 设置页「同步」区（architecture.md §4.4）：主机/从机拓扑。
///
/// - **主机**：开关 + 等待接入提示（Windows 首次开会弹防火墙，需放行专用网络）；
/// - **从机**：扫描发现 → 点一台接入；广播被禁时手输 IP 兜底；
/// - **冲突**：只提示去哪收拾（`.gtd/conflicts/`），不自动删任何东西。
class SettingsSyncSection extends StatefulWidget {
  final AppController controller;

  const SettingsSyncSection({super.key, required this.controller});

  @override
  State<SettingsSyncSection> createState() => _SettingsSyncSectionState();
}

class _SettingsSyncSectionState extends State<SettingsSyncSection> {
  List<SyncPeer> _peers = const [];
  bool _scanning = false;

  AppController get _c => widget.controller;

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final peers = await _c.discoverSyncHosts();
    if (!mounted) return;
    setState(() {
      _peers = peers;
      _scanning = false;
    });
    if (peers.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没发现主机：确认两台设备在同一网络，或用手输 IP')));
    }
  }

  Future<void> _connect(SyncPeer peer) async {
    final outcome = await _c.connectSyncHost(peer);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(outcome.ok
          ? '已同步：$outcome'
          : '连接失败：${outcome.error ?? '未知错误'}'),
    ));
  }

  Future<void> _manualIp() async {
    final ctrl = TextEditingController();
    final peer = await showDialog<SyncPeer>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手输主机地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('形如 192.168.1.5:49872（冒号后是主机的 HTTP 端口）',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '地址:端口'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              final idx = text.lastIndexOf(':');
              final port = idx > 0 ? int.tryParse(text.substring(idx + 1)) : null;
              final address = idx > 0 ? text.substring(0, idx) : text;
              if (address.isEmpty || port == null) return;
              Navigator.of(ctx).pop(SyncPeer(
                  name: address, address: address, port: port));
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (peer != null) await _connect(peer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _c.syncState;
    final isHost = s.role == SyncRole.host;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('同步状态'),
          subtitle: Text(s.summary),
          trailing: s.busy
              ? const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
        ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(s.error!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error))),
              ],
            ),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.dns_outlined),
          title: const Text('当主机'),
          subtitle: Text(isHost && s.running
              ? '服务中：等待从机接入（防火墙需放行专用网络）'
              : '开一台当服务端，另一台来连它'),
          value: isHost,
          onChanged: (v) =>
              v ? _c.startSyncHost() : _c.stopSync(),
        ),
        if (!isHost) ...[
          ListTile(
            leading: const Icon(Icons.radar),
            title: const Text('扫描局域网'),
            subtitle: Text(_peers.isEmpty ? '尚未发现主机' : '发现 ${_peers.length} 台'),
            trailing: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(onPressed: _scan, child: const Text('扫描')),
          ),
          for (final peer in _peers)
            ListTile(
              leading: const Icon(Icons.lan_outlined),
              title: Text(peer.name),
              subtitle: Text(peer.endpoint),
              trailing: const Icon(Icons.login),
              onTap: () => _connect(peer),
            ),
          ListTile(
            leading: const Icon(Icons.edit_location_alt_outlined),
            title: const Text('手输主机地址'),
            subtitle: const Text('广播被禁用时的兜底'),
            onTap: _manualIp,
          ),
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: const Text('立即同步'),
            subtitle: Text(s.running ? '拉取主机改动 + 推送本机改动' : '尚未接入主机'),
            enabled: s.running,
            onTap: () async {
              final outcome = await _c.syncNow();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(outcome.ok ? '已同步：$outcome' : '同步失败：${outcome.error}')));
              }
            },
          ),
        ],
        if (s.conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${s.conflicts.length} 个文件两端都改过：主机版本已生效，'
                    '你的版本存在任务目录 .gtd/conflicts/，请人工收拾',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '同步范围：tasks.md、routines.md、.gtd/<任务id>.md；'
            '回收站、流水、设置不跨设备。接入状态不记忆，重开应用需重新连接。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
