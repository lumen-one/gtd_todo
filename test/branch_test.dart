import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/branch_service.dart';
import 'package:gtd_todo/domain/branch.dart';
import 'package:gtd_todo/repository/markdown_branch_codec.dart';
import 'package:gtd_todo/repository/memory_branch_repository.dart';

/// 支线（§6.12 / 附录 B.8）：格式往返 + 命令语义。
void main() {
  group('MarkdownBranchCodec', () {
    test('解析：段序与行序原样，标题与 id 分开', () {
      final r = MarkdownBranchCodec().decode('## 校招准备\n'
          '\n'
          '- 投一份简历 #[k3f9a2]\n'
          '- 刷完 DP 二十题 #[m8c1d4]\n'
          '\n'
          '## 副业\n'
          '\n'
          '- 写落地页 #[p2q7r1]\n');
      expect(r.warnings, isEmpty);
      expect(r.branches, hasLength(2));
      expect(r.branches[0].name, '校招准备');
      expect([for (final e in r.branches[0].entries) e.taskId],
          ['k3f9a2', 'm8c1d4']);
      expect(r.branches[0].entries[0].title, '投一份简历');
      expect(r.branches[1].name, '副业');
      expect(r.branches[1].entries.single.taskId, 'p2q7r1');
    });

    test('缺 #[id] 的条目行跳过并告警', () {
      final r =
          MarkdownBranchCodec().decode('## A\n\n- 没有引用的行\n- 有引用 #[x1]\n');
      expect(r.branches.single.entries, hasLength(1));
      expect(r.branches.single.entries.single.taskId, 'x1');
      expect(r.warnings, hasLength(1));
    });

    test('不属于任何支线的条目行跳过', () {
      final r = MarkdownBranchCodec().decode('- 孤零零 #[x1]\n');
      expect(r.branches, isEmpty);
      expect(r.warnings, isNotEmpty);
    });

    test('空段保留：刚建的支线还没有任务', () {
      final r = MarkdownBranchCodec()
          .decode('## 空线\n\n## 有线\n\n- a #[x1]\n');
      expect(r.branches, hasLength(2));
      expect(r.branches[0].isEmpty, isTrue);
      expect(r.branches[1].entries.single.taskId, 'x1');
    });

    test('往返：空段照样落标题，行序不变', () {
      final codec = MarkdownBranchCodec();
      final src = [
        Branch(name: '空线'),
        Branch(name: '有线', entries: const [
          BranchEntry(taskId: 'b', title: '先'),
          BranchEntry(taskId: 'a', title: '后'),
        ]),
      ];
      final out = codec.decode(codec.encode(src));
      expect([for (final b in out.branches) b.name], ['空线', '有线']);
      expect([for (final e in out.branches[1].entries) e.taskId], ['b', 'a']);
    });
  });

  group('BranchService', () {
    late MemoryBranchRepository repo;
    late Map<String, String> titles;
    late BranchService svc;

    setUp(() {
      repo = MemoryBranchRepository();
      titles = {};
      svc = BranchService(repo: repo, titleOf: (id) => titles[id]);
    });

    test('加任务按注入的查询填标题；同一件加两次不叠行', () async {
      titles['t1'] = '投简历';
      await svc.addBranch('校招');
      await svc.addTask(0, 't1');
      await svc.addTask(0, 't1');
      expect(svc.branches.single.entries, hasLength(1));
      expect(svc.branches.single.entries.single.title, '投简历');
    });

    test('落盘时按实时标题重写；查不到的 id 保留原标题', () async {
      titles['t1'] = '旧标题';
      await svc.addBranch('A');
      await svc.addTask(0, 't1');
      await svc.addTask(0, 'gone');

      titles['t1'] = '新标题';
      // 任何一条命令都会走一次"读 → 改 → 整份写回"，标题就在这一步刷新。
      await svc.setEntries(0, svc.branches.single.entries);
      final entries = svc.branches.single.entries;
      expect(entries[0].title, '新标题');
      expect(entries[1].title, '');
    });

    test('空名字不建，改名成空也不生效', () async {
      await svc.addBranch('   ');
      expect(svc.branches, isEmpty);
      await svc.addBranch('A');
      await svc.renameBranch(0, '  ');
      expect(svc.branches.single.name, 'A');
    });

    test('删支线只删分组（服务根本不认识任务）', () async {
      await svc.addBranch('A');
      await svc.addTask(0, 't1');
      await svc.removeBranch(0);
      expect(svc.branches, isEmpty);
    });

    test('setEntries 不排序：拖出来就是顺序', () async {
      await svc.addBranch('A');
      await svc.addTask(0, 'z');
      await svc.addTask(0, 'a');
      await svc.setEntries(0, const [
        BranchEntry(taskId: 'a', title: ''),
        BranchEntry(taskId: 'z', title: ''),
      ]);
      expect([for (final e in svc.branches.single.entries) e.taskId],
          ['a', 'z']);
    });

    test('移掉一件任务', () async {
      await svc.addBranch('A');
      await svc.addTask(0, 't1');
      await svc.addTask(0, 't2');
      await svc.removeTask(0, 't1');
      expect([for (final e in svc.branches.single.entries) e.taskId], ['t2']);
    });
  });
}
