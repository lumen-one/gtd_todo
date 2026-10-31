import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/application/today_view.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/repository/task_codec.dart';
import 'package:qixing/repository/task_sidecar.dart';
import 'package:qixing/scheduler/slack_priority_scheduler.dart';

/// '长期'任务（v1.17 / D18 / ui 决议 46）的验收测试：
///
/// - 三无任务（截止型 + 无截止 + 不提醒）创建时工作强度**缺省'长期'**——
///   '长期'是标记而非分钟数，**不是新任务类型**（类型仍是 fixed/flex）；
/// - 长期任务没有工作强度数值、优先级、时间裕度、剩余工作量，
///   内核属性文档 `.gtd/<id>.md` **只有一个任务 id**；
/// - A1/A2/A3 对长期任务全部豁免（同 fixed 豁免 A2 的先例）；
/// - 有截止的 flex 仍必须给数字工时（缺省 30 分钟且 ≥ 1，进 slack 数学）；
/// - '长期'是**创建缺省不是不变量**：清截止不自动改写工作强度，
///   长期 ↔ 数字工时都在编辑里显式设（§3.4 防线三）；
/// - 长期任务没有 digest → 两文档配对降到附录 B.3 第 2/3 档（任务名/位置），
///   改名且数量不等时按新任务接管并提示（代价已登记 arch §12）。
void main() {
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00
  final soon = DateTime(2026, 10, 8, 18, 0); // 次日 18:00 截止

  // ------------------------------------------------------------------
  // 创建缺省（决议 46 / §3.5 createTask）
  // ------------------------------------------------------------------

  group('创建缺省', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    test('三无（flex 无截止）→ 缺省"长期"：三项缺位，类型没变', () async {
      final t = await svc.createTask(title: '学一门外语');
      expect(t.type, TaskType.flex); // '长期'不是新任务类型
      expect(t.isLongTerm, isTrue);
      expect(t.estimatedWork, isNull);
      expect(t.remainingWork, isNull);
      expect(t.importance, isNull);
      expect(t.deadline, isNull);
    });

    test('flex 有截止 → 缺省 30 分钟且 ≥ 1（A2），优先级缺省 3', () async {
      final t = await svc.createTask(title: '写周报', deadline: soon);
      expect(t.isLongTerm, isFalse);
      expect(t.estimatedWork, 30);
      expect(t.remainingWork, 30);
      expect(t.importance, 3);
    });

    test('fixed → 工时 0（豁免 A2 的老口径不变，与"长期"是两回事）', () async {
      final t = await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: soon,
      );
      expect(t.estimatedWork, 0);
      expect(t.isLongTerm, isFalse);
    });

    test('A2 仍守护有截止的 flex：0 分钟被拒绝', () {
      expectLater(
        svc.createTask(
          title: '零工时',
          deadline: soon,
          estimatedWorkMinutes: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  // ------------------------------------------------------------------
  // 不变量豁免与命令边界（§3.2 A1/A2/A3 / D18）
  // ------------------------------------------------------------------

  group('不变量豁免与命令边界', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    test('显式设"长期"不抛（A2/A3 豁免），也不带出优先级缺省 3', () async {
      final a = await svc.createTask(title: '写周报', deadline: soon);
      final t = await svc.updateTask(a.id, clearWork: true);
      expect(t.isLongTerm, isTrue);
      expect(t.estimatedWork, isNull);
      expect(t.remainingWork, isNull);
      expect(t.importance, isNull); // 没有"缺省 3"可言
    });

    test('logWork 对长期抛 ArgumentError（没有预估可对账）', () async {
      final a = await svc.createTask(title: '学外语');
      expect(a.isLongTerm, isTrue);
      expectLater(
        svc.logWork(a.id, minutes: 30),
        throwsArgumentError,
      );
    });

    test('completeTask 对长期不写 remainingWork（保持缺位）', () async {
      final a = await svc.createTask(title: '学外语');
      final t = await svc.completeTask(a.id);
      expect(t.isCompleted, isTrue);
      expect(t.isLongTerm, isTrue);
      expect(t.remainingWork, isNull); // 不是 0——没有这个数
      expect((await repo.getTask(a.id))!.remainingWork, isNull);
    });
  });

  // ------------------------------------------------------------------
  // '长期'是创建缺省，不是不变量（§3.4 防线三）
  // ------------------------------------------------------------------

  group('“长期”是创建缺省，不是不变量', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    test('清截止不自动改写工作强度：30 分钟还是 30 分钟', () async {
      final a = await svc.createTask(title: '写周报', deadline: soon);
      final t = await svc.updateTask(a.id, clearDeadline: true);
      expect(t.deadline, isNull);
      expect(t.estimatedWork, 30); // 不悄悄改语义
      expect(t.importance, 3);
      expect(t.isLongTerm, isFalse);
    });

    test('长期只补截止仍长期（不悄悄补 30 分钟）', () async {
      final a = await svc.createTask(title: '学外语');
      final t = await svc.updateTask(a.id, deadline: soon);
      expect(t.deadline, soon);
      expect(t.isLongTerm, isTrue);
    });

    test('转正 = 换具体工时：补剩余量与优先级缺省 3', () async {
      final a = await svc.createTask(title: '学外语');
      final t = await svc.updateTask(a.id, estimatedWorkMinutes: 60);
      expect(t.isLongTerm, isFalse);
      expect(t.estimatedWork, 60);
      expect(t.remainingWork, 60); // 新预估 = 全新剩余
      expect(t.importance, 3); // A3 缺省
    });

    test('转正可顺带显式定优先级', () async {
      final a = await svc.createTask(title: '学外语');
      final t = await svc.updateTask(
        a.id,
        deadline: soon,
        estimatedWorkMinutes: 60,
        importance: 5,
      );
      expect(t.estimatedWork, 60);
      expect(t.importance, 5);
    });
  });

  // ------------------------------------------------------------------
  // 内核属性文档只有 id 一行（附录 B.2 长期任务特例）
  // ------------------------------------------------------------------

  group('内核属性文档只有 id 一行', () {
    late Directory tmp;
    late MarkdownTaskRepository repo;
    late TaskService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gtd_long_term_test');
      repo = MarkdownTaskRepository(tmp.path);
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File doc() => File('${tmp.path}/tasks.md');
    File kernel(String id) => File('${tmp.path}/.gtd/$id.md');

    test('保存后 .gtd/<id>.md 只有 id：内核字段与 digest 全缺行', () async {
      final t = await svc.createTask(title: '学一门外语');
      final side = kernel(t.id).readAsStringSync();
      expect(side, contains('id: ${t.id}'));
      for (final key in const [
        'work_intensity',
        'remaining_load',
        'priority',
        'time_slack',
        'digest',
        'status',
        'completed_at',
      ]) {
        expect(side, isNot(contains(key)), reason: '$key 不该出现在长期任务的内核文档里');
      }
    });

    test('重读仍是长期、同 id（稳态配对，没有指纹也能认领）', () async {
      final t = await svc.createTask(title: '学一门外语');
      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = (await reloaded.loadAll()).single;
      expect(loaded.id, t.id);
      expect(loaded.isLongTerm, isTrue);
      expect(loaded.title, '学一门外语');
    });

    test('完成态只落人类文档：sidecar 不写 status/completed_at', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.completeTask(t.id);

      final human = doc().readAsStringSync();
      expect(human, contains('- [x] 学一门外语'));
      expect(human, contains('完成 2026-10-07,16:00')); // D14：只认人类文档
      final side = kernel(t.id).readAsStringSync();
      expect(side, isNot(contains('status')));
      expect(side, isNot(contains('completed_at')));

      final reloaded = MarkdownTaskRepository(tmp.path);
      expect((await reloaded.loadAll()).single.isCompleted, isTrue);
    });

    test('codec：decode 只有 id 的 sidecar → 长期；encode 长期 → 只有 id',
        () {
      const codec = TaskSidecarCodec();
      final t = codec.decode('---\nid: task-777\n---\n').task;
      expect(t.id, 'task-777');
      expect(t.isLongTerm, isTrue);
      expect(t.importance, isNull);
      expect(t.metadata.containsKey('digest'), isFalse);

      final long = Task(
        id: 'task-888',
        title: 'x',
        created: now,
        estimatedWork: null,
        importance: null,
      );
      expect(codec.encode(EncodedTask(task: long, originalRaw: null)).trim(),
          '---\nid: task-888\n---');

      // 数字工时 → 长期的退化：原有内核行全部移除（null → 整行移除）
      final numeric = Task(
        id: 'task-888',
        title: 'x',
        deadline: soon,
        estimatedWork: 60,
        remainingWork: 30,
        importance: 4,
        status: TaskStatus.active,
        created: now,
      );
      final full = codec.encode(EncodedTask(task: numeric, originalRaw: null));
      expect(full, contains('work_intensity: 60'));
      final degraded =
          codec.encode(EncodedTask(task: numeric.copyWith(clearWork: true), originalRaw: full));
      expect(degraded.trim(), '---\nid: task-888\n---');
    });

    test('登记的 metadata 键照常跟随（长期不是"什么都不写"）', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.setPoolOrder(t.id, order: 2);
      final side = kernel(t.id).readAsStringSync();
      expect(side, contains('id: ${t.id}'));
      expect(side, contains('pool_order: 2'));
      expect(side, isNot(contains('work_intensity')));
    });
  });

  // ------------------------------------------------------------------
  // 两文档配对降级（附录 B.3 第 2/3 档）
  // ------------------------------------------------------------------

  group('配对降级（无 digest → 第 2/3 档）', () {
    late Directory tmp;
    late MarkdownTaskRepository repo;
    late TaskService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gtd_long_term_pair_test');
      repo = MarkdownTaskRepository(tmp.path);
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File doc() => File('${tmp.path}/tasks.md');
    File kernel(String id) => File('${tmp.path}/.gtd/$id.md');

    test('改名且两边剩余数量相等：第 3 档位置配对，还是同一条任务', () async {
      final t = await svc.createTask(title: '买菜');
      doc().writeAsStringSync(
          doc().readAsStringSync().replaceFirst('买菜', '买才'));

      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = (await reloaded.loadAll()).single;
      expect(loaded.id, t.id); // 数量相等 → 一一配对，不猜不换
      expect(loaded.title, '买才'); // 人写的：人赢
      expect(loaded.isLongTerm, isTrue); // 内核属性（只有 id）原样保留
    });

    test('改名且数量不等：按新任务接管并提示，旧属性文件留在 .gtd/', () async {
      final t = await svc.createTask(title: '买菜');
      // Obsidian 里：改名 + 新增一行手写任务（没有属性文档）→ 数量不等
      doc().writeAsStringSync(
        '${doc().readAsStringSync().replaceFirst('买菜', '买才')}'
        '- [ ] 新念头 创建 2026-10-07,16:05\n',
      );

      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = await reloaded.loadAll();
      expect(loaded, hasLength(2));
      expect(loaded.every((x) => x.id != t.id), isTrue,
          reason: '改名且数量不等 → 按新任务接管，分到新 id');
      expect(kernel(t.id).existsSync(), isTrue,
          reason: '旧 id 的属性文件保留，等人工处理（arch §12 局限）');
      expect(reloaded.warnings.any((w) => w.contains('找不到对应的行')), isTrue,
          reason: '不静默：要提示');
    });
  });

  // ------------------------------------------------------------------
  // 调度数学一行未动（D18）：长期不进 slack 公式
  // ------------------------------------------------------------------

  group('调度数学一行未动', () {
    const scheduler = SlackPriorityScheduler();
    final rule = WorkTimeRule.standard;

    test('长期不进公式：无截止不进，"截止+长期"中间态也不进', () {
      final plain = Task(
        id: 'plain',
        title: '普通',
        deadline: soon,
        estimatedWork: 60,
        remainingWork: 60,
        importance: 3,
        created: now,
      );
      final longNoDeadline = Task(
        id: 'long1',
        title: '长期·无截止',
        created: now,
        estimatedWork: null,
        importance: null,
      );
      final longWithDeadline = Task(
        id: 'long2',
        title: '长期·带截止（补截止未换工时的中间态）',
        deadline: soon,
        created: now,
        estimatedWork: null,
        importance: null,
      );

      final r = scheduler.schedule(
        tasks: [plain, longNoDeadline, longWithDeadline],
        now: now,
        workRule: rule,
      );
      expect(r.items.map((m) => m.taskId), ['plain']);
      expect(r.metricOf('long1'), isNull);
      expect(r.metricOf('long2'), isNull);
    });

    test('视图口径：长期进池子散件段，不进今日清单', () {
      final long = Task(
        id: 'l',
        title: '长期',
        created: now,
        estimatedWork: null,
        importance: null,
      );
      final pool = buildPoolView(tasks: [long], now: now);
      expect(pool.loose.single.id, 'l');

      final today = buildTodayView(tasks: [long], schedule: null, now: now);
      expect(today.isEmpty, isTrue);
    });
  });
}
