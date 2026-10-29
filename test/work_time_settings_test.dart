import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/settings_panel.dart';
import 'package:gtd_todo/ui/theme.dart';

/// **工作时间可编辑**（ui-interaction.md §9 第 13 条，v1.26）。
///
/// 它是 slack 的分母，不是外观偏好：设置层的清洗、规则构造、以及
/// "改完必须清锚点重算"三处都要钉住。
void main() {
  group('设置编解码（work_days / work_windows）', () {
    test('缺键 = 周一至周五 + 两段（09:00–12:00、13:30–18:00）', () {
      final s = AppSettings.fromJson(const {});
      expect(s.workDays, [1, 2, 3, 4, 5]);
      expect(s.workWindows, [
        [9 * 60, 12 * 60],
        [13 * 60 + 30, 18 * 60],
      ]);
    });

    test('往返不丢：周六上班 + 单段', () {
      final s = AppSettings.defaults.copyWith(
        workDays: [1, 2, 3, 4, 5, 6],
        workWindows: [
          [9 * 60, 18 * 60]
        ],
      );
      final back = decodeSettings(encodeSettings(s));
      expect(back.workDays, [1, 2, 3, 4, 5, 6]);
      expect(back.workWindows, [
        [9 * 60, 18 * 60]
      ]);
    });

    test('清洗：非法工作日 / 非法窗口一律回落默认，不炸也不算出空日历', () {
      expect(AppSettings.fromJson(const {'work_days': []}).workDays, defaultWorkDays);
      expect(AppSettings.fromJson(const {'work_days': [0, 8, 'x']}).workDays,
          defaultWorkDays);
      expect(
          AppSettings.fromJson(const {
            'work_windows': [
              [600, 540]
            ]
          }).workWindows,
          defaultWorkWindows,
          reason: 'start ≥ end 的区间不认');
      expect(
          AppSettings.fromJson(const {
            'work_windows': [
              [600, 700],
              [540, 720]
            ]
          }).workWindows,
          [
            [540, 720],
            [600, 700],
          ],
          reason: '只丢坏的那一段，并按开始时间排序');
    });

    test('工作日去重升序', () {
      final s = AppSettings.fromJson(const {
        'work_days': [3, 1, 3, 5]
      });
      expect(s.workDays, [1, 3, 5]);
    });

    test('workSignature 只认内容，不认顺序', () {
      final a = AppSettings.defaults.copyWith(workWindows: [
        [540, 720],
        [810, 1080],
      ]);
      final b = AppSettings.defaults.copyWith(workWindows: [
        [810, 1080],
        [540, 720],
      ]);
      expect(a.workSignature, b.workSignature, reason: '顺序不该触发重算');
      expect(
        a.copyWith(workDays: [1, 2, 3, 4, 5, 6]).workSignature,
        isNot(a.workSignature),
        reason: '多上一天班是实打实的变化',
      );
    });
  });

  group('WorkTimeRule.fromSettings', () {
    test('只给选中的那几天排窗，其余天不工作', () {
      final rule = WorkTimeRule.fromSettings([6], [
        [9 * 60, 12 * 60]
      ]);
      expect(rule.isWorkDay(DateTime(2026, 10, 10)), isTrue, reason: '周六');
      expect(rule.isWorkDay(DateTime(2026, 10, 9)), isFalse, reason: '周五');
      expect(rule.workMinutesBetween(DateTime(2026, 10, 10, 9, 0),
          DateTime(2026, 10, 10, 12, 0)), 180);
    });

    test('空天数 / 空窗口 → 回落 standard（不能算出零产能的日历）', () {
      expect(WorkTimeRule.fromSettings(const [], const []).signature,
          WorkTimeRule.standard.signature);
      expect(
          WorkTimeRule.fromSettings(const [1], const []).signature,
          WorkTimeRule.standard.signature);
    });

    test('signature 与窗口书写顺序无关', () {
      final a = WorkTimeRule.fromSettings(const [1], const [
        [540, 720],
        [810, 1080],
      ]);
      final b = WorkTimeRule.fromSettings(const [1], const [
        [810, 1080],
        [540, 720],
      ]);
      expect(a.signature, b.signature);
    });
  });

  group('TaskService.updateWorkRule', () {
    late DateTime now;
    late TaskService svc;

    setUp(() {
      now = DateTime(2026, 10, 9, 17, 0); // 周五 17:00，默认规则只剩 1 小时
      svc = TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackPriorityScheduler(),
        clock: () => now,
      );
    });

    test('周六也算上班 → 同一件任务从"不可行"变回"可行"，任务数据一行不动', () async {
      final t = await svc.createTask(
        title: '周六中午交',
        deadline: DateTime(2026, 10, 10, 12, 0),
        estimatedWorkMinutes: 180,
      );
      expect(svc.lastSchedule!.metricOf(t.id)!.displayStatus,
          TaskDisplayStatus.infeasible,
          reason: '周五只剩 60 分钟，却要 180 分钟');

      await svc.updateWorkRule(WorkTimeRule.fromSettings(
        [1, 2, 3, 4, 5, 6],
        [
          [9 * 60, 12 * 60],
          [13 * 60 + 30, 18 * 60],
        ],
      ));

      final m = svc.lastSchedule!.metricOf(t.id)!;
      expect(m.displayStatus, TaskDisplayStatus.normal);
      expect(m.availableMinutes, 240, reason: '周五 60 + 周六上午 180');
      expect(m.slackMinutes, 60);
      // 工时是设置，不是任务：
      expect(svc.byId(t.id)!.deadline, DateTime(2026, 10, 10, 12, 0));
      expect(svc.byId(t.id)!.remainingWork, 180);
    });

    test('换日历会清空锚点表（旧锚点对应旧产能，不能沿用）', () async {
      final t = await svc.createTask(
        title: 'A',
        deadline: DateTime(2026, 10, 10, 12, 0),
        estimatedWorkMinutes: 180,
      );
      final before = svc.lastSchedule!.metricOf(t.id)!.nextReminderAt!;
      expect(before, DateTime(2026, 10, 9, 17, 30));

      now = DateTime(2026, 10, 9, 17, 20); // 仍在 30 分钟宽限内
      await svc.updateWorkRule(WorkTimeRule.fromSettings(
        [1, 2, 3, 4, 5, 6],
        [
          [9 * 60, 12 * 60],
          [13 * 60 + 30, 18 * 60],
        ],
      ));

      final after = svc.lastSchedule!.metricOf(t.id)!.nextReminderAt!;
      expect(after, isNot(before),
          reason: '若沿用旧锚点会停在 17:30 —— 那是按旧产能算的');
      expect(after, DateTime(2026, 10, 9, 17, 50));
    });

    test('同样的日历再推一次：不重算（指纹没变）', () async {
      await svc.createTask(
        title: 'A',
        deadline: DateTime(2026, 10, 10, 12, 0),
        estimatedWorkMinutes: 60,
      );
      final before = svc.lastSchedule;
      await svc.updateWorkRule(WorkTimeRule.standard);
      expect(identical(svc.lastSchedule, before), isTrue);
    });
  });

  group('设置页入口（§9 第 13 条）', () {
    testWidgets('点「工作日与工作窗」→ 勾周六 → 保存，控制器与 service 都跟上',
        (tester) async {
      final svc = TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackPriorityScheduler(),
        clock: () => DateTime(2026, 10, 15, 9, 0),
      );
      final controller = AppController(
        service: svc,
        taskDir: '/tmp/tasks',
        onWorkRuleChanged: (rule) => svc.updateWorkRule(rule),
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: SettingsPanel(controller: controller)),
      ));
      await tester.pumpAndSettle();

      final tile = find.text('工作日与工作窗');
      await tester.scrollUntilVisible(tile, 240,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('周一至周五 · 09:00–12:00、13:30–18:00'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.tap(find.text('周六'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(controller.settings.workDays, [1, 2, 3, 4, 5, 6]);
      expect(svc.workRule.isWorkDay(DateTime(2026, 10, 17)), isTrue,
          reason: '周六（10-17）进了工时日历');
    });
  });
}
