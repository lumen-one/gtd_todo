import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/notes_reader.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/application/today_view.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_codec.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/repository/task_codec.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// ui-interaction.md v0.4 落地的行为测试（契约 §3.5 规划表 + 决议 8/9/13/25）。
void main() {
  TaskService makeService({DateTime Function()? clock}) {
    return TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: clock ?? () => DateTime(2026, 10, 7, 10, 0), // 周三上午
    );
  }

  group('createTask 签名改造（fixed / flex / 三无）', () {
    test('fixed：必须有截止、估工时可为 0（A2 豁免）、出生不判完成', () async {
      final svc = makeService();
      final t = await svc.createTask(
        title: '部门例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 14, 0),
      );
      expect(t.type, TaskType.fixed);
      expect(t.estimatedWork, 0);
      expect(t.isCompleted, isFalse, reason: 'fixed 仅按 status 判完成');
      expect(t.metadata['type'], 'fixed');

      await expectLater(
        svc.createTask(title: '坏数据', type: TaskType.fixed),
        throwsArgumentError,
      );
    });

    test('三无：flex 无截止，不进 ScheduleResult', () async {
      final svc = makeService();
      await svc.createTask(title: '收拾抽屉', estimatedWorkMinutes: 30);
      await svc.refreshSchedule();
      expect(svc.lastSchedule!.items, isEmpty);
      final t = svc.tasks.single;
      expect(t.type, TaskType.flex);
      expect(t.metadata.containsKey('type'), isFalse,
          reason: 'flex 是缺省类型，不写 type 键');
    });

    test('flex 工时缺省：有截止 30 分钟、三无「长期」；0 工时仍拒绝（A2）', () async {
      final svc = makeService();
      // 三无（截止型无截止）→ 缺省「长期」：估不出来就不写（D18，v1.17）。
      final longTerm = await svc.createTask(title: '回邮件');
      expect(longTerm.estimatedWork, isNull,
          reason: '三无缺省「长期」，estimatedWork 为 null');
      expect(longTerm.isLongTerm, isTrue);
      // 有截止的 flex 仍必须给数字工时：缺省 30 分钟。
      final withDeadline = await svc.createTask(
          title: '回邮件', deadline: DateTime(2026, 10, 8, 18, 0));
      expect(withDeadline.estimatedWork, 30);
      // 显式 0：flex 必须 ≥ 1（A2），「长期」没有分钟数可校验是另一回事。
      await expectLater(
        svc.createTask(title: '坏数据', estimatedWorkMinutes: 0),
        throwsArgumentError,
      );
    });
  });

  group('插队 / 挑散件 / 池子排序（决议 8/9/14）', () {
    test('pinToTop：写 pinned 元数据；仅截止型生效', () async {
      final svc = makeService();
      final a = await svc.createTask(title: 'A', estimatedWorkMinutes: 60,
          deadline: DateTime(2026, 10, 14, 18, 0));
      final fixed = await svc.createTask(
          title: 'F', type: TaskType.fixed,
          deadline: DateTime(2026, 10, 14, 18, 0));

      final pinned = await svc.pinToTop(a.id);
      expect(pinned.pinnedAt, isNotNull);
      await expectLater(svc.pinToTop(fixed.id), throwsArgumentError);
    });

    test('pickForToday / returnToPool：当日标记生效与放回', () async {
      final svc = makeService();
      final t = await svc.createTask(title: '散件甲');
      final picked = await svc.pickForToday(t.id);
      expect(picked.pickedForDate, '2026-10-07');

      final returned = await svc.returnToPool(t.id);
      expect(returned.pickedForDate, isNull);
    });

    test('setPoolOrder：显示序持久化', () async {
      final svc = makeService();
      final t = await svc.createTask(title: '散件乙');
      final ordered = await svc.setPoolOrder(t.id, order: 3);
      expect(ordered.poolOrder, 3);
    });
  });

  group('软删除三件套（D11）', () {
    test('删除 → 回收站 → 恢复 → 清空', () async {
      final svc = makeService();
      final t = await svc.createTask(title: '要删的');
      await svc.deleteTask(t.id);
      expect(svc.byId(t.id), isNull);

      final trash = await svc.loadTrash();
      expect(trash.single.id, t.id);

      await svc.restoreTask(t.id);
      expect(svc.byId(t.id), isNotNull);
      expect((await svc.loadTrash()), isEmpty);

      await svc.deleteTask(t.id);
      await svc.purgeTrash();
      expect((await svc.loadTrash()), isEmpty);
      expect(svc.byId(t.id), isNull);
    });
  });

  group('今日视图聚合（D12 / 决议 11/25）', () {
    test('分组：逾期置顶、fixed 升序、插队栈式、被挑散件尾部', () async {
      final svc = makeService(clock: () => DateTime(2026, 10, 7, 12, 0));
      // 逾期（昨天截止）
      final overdue = await svc.createTask(
          title: '逾期件',
          deadline: DateTime(2026, 10, 6, 18, 0),
          estimatedWorkMinutes: 30);
      // 今天到点的 fixed 两件（顺序故意乱建）
      final fixedB = await svc.createTask(
          title: '例会B', type: TaskType.fixed,
          deadline: DateTime(2026, 10, 7, 16, 0));
      final fixedA = await svc.createTask(
          title: '例会A', type: TaskType.fixed,
          deadline: DateTime(2026, 10, 7, 14, 0));
      // 明天截止的截止型（今天会响：slack 小）
      final flex = await svc.createTask(
          title: '写周报',
          deadline: DateTime(2026, 10, 8, 18, 0),
          estimatedWorkMinutes: 480);
      // 散件，挑到今日
      final loose = await svc.createTask(title: '挑中的散件');
      await svc.pickForToday(loose.id);
      // 插队件
      final pinned = await svc.pinToTop(flex.id);

      final view = buildTodayView(
          tasks: svc.tasks,
          schedule: svc.lastSchedule,
          now: DateTime(2026, 10, 7, 12, 0));

      expect(view.overdue.map((t) => t.id), [overdue.id]);
      expect(view.fixed.map((t) => t.id), [fixedA.id, fixedB.id],
          reason: '按时间点升序');
      expect(view.pinned.single.id, pinned.id);
      expect(view.picked!.id, loose.id);

      // 池子分段：逾期件保留在计划段标橙（决议 2），今天的开始型不进池子
      final pool = buildPoolView(
          tasks: svc.tasks, now: DateTime(2026, 10, 7, 12, 0));
      expect(pool.plan.map((t) => t.id), contains(overdue.id));
      expect(pool.plan.map((t) => t.id),
          isNot(contains(fixedA.id)), reason: '今天到点的任务归今日清单');
      expect(pool.plan.map((t) => t.id), contains(flex.id),
          reason: '明天截止的任务在计划段');
      expect(pool.loose.map((t) => t.id), isNot(contains(loose.id)),
          reason: '被挑走的散件只在今日⑤出现，不重复进池子（决议 8）');
    });

    test('无截止散件不进今日；被挑走的散件不重复出现在池子散件段', () async {
      final svc = makeService();
      final loose = await svc.createTask(title: '散件丙');
      final view = buildTodayView(
          tasks: svc.tasks, schedule: svc.lastSchedule,
          now: DateTime(2026, 10, 7, 12, 0));
      expect(view.isEmpty, isTrue);

      final pool = buildPoolView(tasks: svc.tasks,
          now: DateTime(2026, 10, 7, 12, 0));
      expect(pool.loose.map((t) => t.id), [loose.id]);

      await svc.pickForToday(loose.id);
      final pool2 = buildPoolView(tasks: svc.tasks,
          now: DateTime(2026, 10, 7, 12, 0));
      expect(pool2.loose, isEmpty,
          reason: '今日尾部最多一件；被挑走的不重复显示');
    });
  });

  group('codec：应用自有 metadata 键写回 + deadline 可空往返', () {
    test('pinned/pool_order 行随任务对象改写与删除', () {
      final codec = MarkdownTaskCodec();
      final t = Task(
        id: 'task-x',
        title: 'T',
        estimatedWork: 30,
        created: DateTime(2026, 10, 7, 9, 0),
        deadline: DateTime(2026, 10, 8, 18, 0),
      );
      final raw1 = codec.encode(EncodedTask(task: t));
      expect(raw1, isNot(contains('pinned:')));

      final pinned = t.copyWith(
          metadata: {'pinned': '2026-10-07T10:00:00.000', 'pool_order': '2'});
      final raw2 = codec.encode(EncodedTask(task: pinned, originalRaw: raw1));
      expect(raw2, contains('pinned: 2026-10-07T10:00:00.000'));
      expect(raw2, contains('pool_order: 2'));

      final cleared = pinned.copyWith(metadata: const {'pool_order': '2'});
      final raw3 = codec.encode(EncodedTask(task: cleared, originalRaw: raw2));
      expect(raw3, isNot(contains('pinned:')));
      expect(raw3, contains('pool_order: 2'),
          reason: '未清除的键保留');
    });

    test('未知字段与注释行仍按字段级保真原样保留', () {
      final codec = MarkdownTaskCodec();
      final raw = '---\n'
          'id: task-y\n'
          'title: T\n'
          '# 手写注释\n'
          'mood: 好\n'
          'deadline: 2026-10-08T18:00\n'
          'estimated_work: 30\n'
          '---\n'
          '正文\n';
      final decoded = codec.decode(raw);
      expect(decoded.task.metadata['mood'], '好');
      final re = codec.encode(EncodedTask(
          task: decoded.task.copyWith(title: 'T2'), originalRaw: raw));
      expect(re, contains('# 手写注释'));
      expect(re, contains('mood: 好'));
    });

    test('无 deadline 任务：decode 无 deadline 行 → null；encode 省略该行', () {
      final codec = MarkdownTaskCodec();
      final t = Task(
        id: 'task-z',
        title: '散件',
        estimatedWork: 30,
        created: DateTime(2026, 10, 7, 9, 0),
      );
      final raw = codec.encode(EncodedTask(task: t));
      expect(raw, isNot(contains('deadline')));
      final back = codec.decode(raw).task;
      expect(back.deadline, isNull);
      expect(back.remainingWork, 30);
    });
  });

  group('灵感正文读写（决议 1/19；v1.29 从只读改为可编辑）', () {
    test('frontmatter 之后到下一个 --- 之间的正文；[[ 行屏蔽', () {
      const raw = '---\ntitle: 灵感\n---\n'
          '第一段想法。\n'
          '[[某任务]] 相关行被屏蔽\n'
          '第二段想法。\n'
          '---\n'
          '后面不是正文\n';
      final r = extractNotesSection(raw);
      expect(r.status, NotesStatus.ok);
      expect(r.lines, ['第一段想法。', '第二段想法。']);
    });

    test('无第二个 --- → 取到文件末尾；全被过滤 → empty', () {
      const raw1 = '---\n---\n只有一段\n';
      expect(extractNotesSection(raw1).lines, ['只有一段']);

      const raw2 = '---\n---\n[[全是链接]]\n';
      expect(extractNotesSection(raw2).status, NotesStatus.empty);
    });

    test('编辑初值带被屏蔽的行——保存一次不能把它们抹掉', () {
      const raw = '---\nt: 灵感\n---\n第一段\n[[某任务]]\n第二段\n';
      final r = extractNotesSection(raw);
      expect(r.bodyLines, ['第一段', '[[某任务]]', '第二段']);
      expect(r.lines, ['第一段', '第二段']);
      expect(r.canEdit, isTrue);
    });

    test('写入只换正文段：frontmatter 与后面的段落逐行原样', () {
      const raw = '---\ntitle: x\n---\n旧的一行\n---\n后面的段落\n';
      final next = applyNotesSection(raw, '新的一行\n第二行');
      expect(next, '---\ntitle: x\n---\n新的一行\n第二行\n\n---\n后面的段落\n');
      expect(extractNotesSection(next!).lines, ['新的一行', '第二行']);
    });

    test('CRLF 文件保存后仍是 CRLF；末尾换行状态照旧', () {
      const raw = '---\r\ntitle: x\r\n---\r\n旧\r\n';
      expect(applyNotesSection(raw, '新'), '---\r\ntitle: x\r\n---\r\n新\r\n');
    });

    test('没有 frontmatter 的文件：整篇就是正文段', () {
      expect(applyNotesSection('想到一件事\n', '想到了两件事\n再一件'),
          '想到了两件事\n再一件\n');
    });

    test('frontmatter 未闭合 → 拒写，也不给编辑（边界本身不确定）', () {
      const raw = '---\ntitle: 坏的\n正文\n';
      expect(applyNotesSection(raw, '新'), isNull);
      final r = extractNotesSection(raw);
      expect(r.status, NotesStatus.empty);
      expect(r.canEdit, isFalse);
    });
  });

  group('设置编解码', () {
    test('roundtrip：多段时段 + 定期挑 + 笔记路径', () {
      const s = AppSettings(
        notificationWindows: [[540, 720], [840, 1080]],
        alarmMode: true,
        pickEnabled: true,
        pickIntervalDays: 3,
        notesPath: '/vault/疑问笔记.md',
        guideSeen: true,
      );
      final back = decodeSettings(encodeSettings(s));
      expect(back.notificationWindows, s.notificationWindows);
      expect(back.alarmMode, isTrue);
      expect(back.pickIntervalDays, 3);
      expect(back.notesPath, s.notesPath);
    });

    test('调度模式：新装默认无排序，两档与开关往返不丢（v1.12 由 reminderMode 改名）', () {
      expect(AppSettings.defaults.scheduleMode, ScheduleMode.manual,
          reason: '新装默认无排序：算法不排先后、也不出声');
      const standard = AppSettings(
          scheduleMode: ScheduleMode.standard, askImportance: true);
      final back = decodeSettings(encodeSettings(standard));
      expect(back.scheduleMode, ScheduleMode.standard);
      expect(back.askImportance, isTrue);
      // 老设置文件没有这个键 → 落到标准模式（不因为缺键而变成手动序）
      final legacy = AppSettings.fromJson(const {'alarm_mode': true});
      expect(legacy.scheduleMode, ScheduleMode.standard);
      expect(legacy.askImportance, isFalse);
      // 更老的文件里写着 full（当时那一档）：落标准 + 打开『问重要度』
      final old = AppSettings.fromJson(const {'schedule_mode': 'full'});
      expect(old.scheduleMode, ScheduleMode.standard);
      expect(old.askImportance, isTrue);
    });

    test('把手上锁：默认不锁，往返不丢，老文件缺键 = 不锁', () {
      expect(AppSettings.defaults.handleLocked, isFalse);
      expect(AppSettings.fromJson(const {}).handleLocked, isFalse);

      final locked = AppSettings.defaults.copyWith(handleLocked: true);
      expect(locked.handleLocked, isTrue);
      expect(decodeSettings(encodeSettings(locked)).handleLocked, isTrue);
      // 上锁不动别的字段（与侧边栏宽高、主题各管一段）。
      expect(locked.panelWidth, defaultPanelWidth);
      expect(locked.themeMode, 'system');
    });

    test('把手热区宽度：缺省 12dp，三档值与夹取范围一致，越界夹回', () {
      expect(AppSettings.defaults.handleHotWidth, defaultHandleHotWidth);
      expect(handleHotWidthOptions, [8, 12, 20]);
      expect(minHandleHotWidth, 8);
      expect(maxHandleHotWidth, 20);

      final s = AppSettings.defaults.copyWith(handleHotWidth: 20);
      expect(decodeSettings(encodeSettings(s)).handleHotWidth, 20);
      // 老设置文件没有这个键 → 默认档，不报错。
      expect(decodeSettings('{}').handleHotWidth, 12);
      // 手改坏了：太小 / 太大 / 不是数字，一律夹回区间或回默认。
      expect(decodeSettings('{"handle_hot_width": 1}').handleHotWidth, 8);
      expect(decodeSettings('{"handle_hot_width": 999}').handleHotWidth, 20);
      expect(decodeSettings('{"handle_hot_width": "wide"}').handleHotWidth, 12);
    });

    test('侧边栏宽高：拖拽持久化往返，老文件缺键抬到安装默认值', () {
      const s = AppSettings(panelWidth: 512, panelHeight: 640);
      final back = decodeSettings(encodeSettings(s));
      expect(back.panelWidth, 512);
      expect(back.panelHeight, 640);
      // 老设置文件没有这些键 → 抬到 240 × 425（与"新装"同一个落点）
      final legacy = AppSettings.fromJson(const {'alarm_mode': true});
      expect(legacy.panelWidth, defaultPanelWidth);
      expect(legacy.panelHeight, defaultPanelHeight);
    });
  });
}
