/// 领域模型：任务（不可变，§3.2 规则 C1）。
///
/// 任何字段变更只能通过 [copyWith] 生成新实例，且只能发生在
/// TaskService 的命令方法内部——"写路径唯一"由类型系统强制。
/// Markdown 只是存储格式（见 repository/），这里是系统的核心事实。
/// 纯 Dart，不依赖 Flutter / IO。
enum TaskStatus { pending, active, snoozed, completed, overdue }

/// 任务类型三分（ui-interaction.md §4.1、决议 5/12）：
/// - [fixed] 开始型（开始型）：会议、约定、车票——有确切日期时间，不需估工时；
/// - [flex]  截止型（软任务）：写论文、回邮件——靠投入时间完成；无截止 = 三无散件；
/// - [routine] 周期任务的当天实例：不占工时、不进调度、默认不响
///   （响不响由规则决定，见 metadata `routine_remind`）；完成/跳过按 status 判定。
///
/// 落地走 metadata 缓冲带（§3.4 防线二）：frontmatter 键 `type`，值
/// `fixed` / `flex` / `routine`；缺省 [flex]（三无 = flex 且无截止）。
enum TaskType { flex, fixed, routine }

class Task {
  Task({
    required this.id,
    required this.title,
    this.deadline,
    this.description = '',
    int? estimatedWork,
    int? remainingWork,
    this.importance = 3,
    this.status = TaskStatus.pending,
    this.snoozedUntil,
    List<String>? tags,
    Map<String, String>? metadata,
    DateTime? created,
    this.completedAt,
  })  : estimatedWork = estimatedWork,
        remainingWork = remainingWork ?? estimatedWork,
        tags = List.unmodifiable(tags ?? const <String>[]),
        metadata = metadata ?? const {},
        created = created ?? DateTime.now();

  final String id;
  final String title;

  /// 正文自由内容（Markdown 里 frontmatter 之后的全部内容）。
  /// 归人类所有：应用只在 description 被显式命令修改时才改写正文。
  final String description;

  /// 截止时间（墙钟时刻）。可空（ui-interaction.md §10 #2）：
  /// fixed = 时点；flex = 截止；null = 散件（无截止、永不提醒）。
  final DateTime? deadline;

  /// 预计需要的工作时间（工作分钟）。**null = '长期'**（v1.17，D18 / ui 决议 46）：
  /// 三无任务（截止型 + 无截止 + 不提醒）的创建缺省——'长期'是标记而非分钟数，
  /// 标长期 = 不估工时、不设优先级、没有时间裕度与剩余工作量，内核属性文档
  /// 只剩 id 一行（'长期'不单独落一行：没有 work_intensity 行就是长期）。
  /// fixed 豁免 A2，允许 0；有截止的 flex 必须 ≥ 1（缺省 30 分钟）。
  final int? estimatedWork;

  /// 当前剩余工作时间（工作分钟）。动态调度最重要的数据。
  /// '长期'任务同样没有（null）——没有预估可对账，A1 的 clamp 也不适用。
  final int? remainingWork;

  /// 人的优先级 1–5（缺省 3，A3），与 deadline 分开对待。
  /// '长期'任务**不设优先级**（null）——没有"缺省 3"可言（A3 对长期豁免）。
  final int? importance;

  final TaskStatus status;

  /// 用户 snooze 的"不要早于该时刻再提醒"。这是用户意图，属于事实，
  /// 因此持久化到 frontmatter；而 nextReminder 是计算结果，不持久化。
  final DateTime? snoozedUntil;

  /// 标签（人类文档行尾的 `##标签`，也是分类归属：`##工作` 归入 `# 工作` 小节）。
  /// ui-interaction.md §4.3：更多的标签 = 更多的属性；内核不解释标签语义。
  final List<String> tags;

  /// 未知 frontmatter 字段 + 应用自有 metadata 键（附录 B.2 登记表：
  /// type / pinned / picked_for_today / pool_order / remind），§3.4 字段级保真的载体。
  final Map<String, String> metadata;

  final DateTime created;

  /// 完成时刻（人类文档的 `完成 <日期,时间>`；内核同时落 completed_at）。
  /// null = 未完成。任务名/创建/结束/完成/备注/标签六项里唯一带时间戳的完成态。
  final DateTime? completedAt;

  /// 类型（metadata 缓冲带读取，见 [TaskType]）。
  TaskType get type {
    switch (metadata['type']) {
      case 'fixed':
        return TaskType.fixed;
      case 'routine':
        return TaskType.routine;
      default:
        return TaskType.flex;
    }
  }

  /// 周期实例所属规则 id（决议 12）；null = 普通任务。
  String? get routineId => metadata['routine'];

  /// 周期实例的发生日（yyyy-MM-dd）；null = 非实例。
  String? get routineDate => metadata['routine_date'];

  /// 规则是否设了响（决议 18：时点性提醒，到点走系统闹钟）。
  bool get routineRemind => metadata['routine_remind'] == 'true';

  /// **逐任务响铃开关**（metadata `remind`，界面上的『响铃』）：提醒照发，它只决定
  /// 这条提醒走有声渠道还是静音渠道，不改顺序、不改提醒时刻。
  ///
  /// **缺键 = 静音**：旧版本只在人主动开提醒时才写 `true`，那个意图就照静音延续；
  /// 静音只是没声音，横幅与通知栏照旧（§3.2 规则 B4）。
  bool get ringEnabled => metadata['remind'] == 'true';

  /// 跳过标记（决议 23「跳过今天」）：值 = 被跳过的发生日 yyyy-MM-dd。
  String? get routineSkippedDate => metadata['routine_skipped'];

  /// 该实例在 [mark]（yyyy-MM-dd）这一天被跳过（不完成，今日不再显示）。
  bool isRoutineSkippedOn(String mark) => routineSkippedDate == mark;

  /// 时点性提醒的到点时刻（开始型到点 / 设了响的周期实例）：
  /// 事件时刻 = deadline，被 snooze 时取"推迟到"的时刻（决议 23/26）。
  DateTime? get pointReminderAt {
    if (type == TaskType.flex) return null;
    if (type == TaskType.routine && !routineRemind) return null;
    final d = deadline;
    if (d == null) return null;
    final s = snoozedUntil;
    if (s != null && s.isAfter(d)) return s;
    return d;
  }

  /// 插队标记（值 = 插队时刻 ISO 串，栈式排序用）；null = 未插队。
  String? get pinnedAt => metadata['pinned'];

  /// **挂起进行标记**（v1.18，ui 决议 47；值 = 挂起时刻 ISO 串，组内降序 = 后挂在上）；
  /// null = 今天没挂着。**挂起是每天一挂**：点一下（今天做过）就删掉它，
  /// 次日靠 [inProgressDailyDate] 自动回挂（见 `docs/decisions/2026-10-31-suspend-daily-habit.md`）。
  String? get inProgressAt => metadata['in_progress'];

  /// **每日回挂标记**（值 = 最近一次"今天做过"的日期 yyyy-MM-dd）：有它 = 这件长期
  /// 散件每天都回到挂起组；同时也是"同一天里点掉又重启不会当天跳回来"的凭据。
  String? get inProgressDailyDate => metadata['in_progress_daily'];

  /// 有没有资格挂起（决议 47 的判据）：**'长期'（没估工时）且没有截止**的散件。
  /// 有了日期或换成数字工时就归调度管——命令层此刻清标记，视图与菜单按它判断。
  bool get canBeInProgress =>
      type == TaskType.flex && deadline == null && isLongTerm && !isCompleted;

  /// **有效的挂起**：标记在、且这件现在仍有资格挂。
  ///
  /// 视图与菜单一律按它判断，不能只看 [inProgressAt]：失去资格的件如果还占着挂起位，
  /// 会既进不了挂起组、又被挡在逾期/截止型组之外——谁都不显示它。
  bool get isInProgress => inProgressAt != null && canBeInProgress;

  /// 被挑散件标记（当日有效，值 = yyyy-MM-dd）；null = 未被挑。
  String? get pickedForDate => metadata['picked_for_today'];

  /// 池子显示序（仅整理无调度含义）；null = 未整理过。
  int? get poolOrder => int.tryParse(metadata['pool_order'] ?? '');

  /// 散件的家（metadata `loose_home`）：`true` = 住任务池散件段，缺省 = 住今日页
  /// ⑥ 散件段。**只在无排序档参与分区**（标准档散件照旧全在池子，标记保留
  /// 但不生效，切档不迁移）；长期有效，不是当日标记。
  bool get looseHomeIsPool => metadata['loose_home'] == 'pool';

  /// 手动序（v1.12 决议 43 / D17）：无排序模式下人拖出来的顺序，持久化在任务上；
  /// null = 没排过序（沉在末尾）。自动模式下原样保留、**不参与排序**。
  int? get manualOrder => int.tryParse(metadata['manual_order'] ?? '');

  /// 已响过的**那一站**时点提醒（值 = 那一站的 ISO 串）。
  /// 用于「每一站只响一次」的幂等判定：无排序档两站（`T − 提前量` / `T`）靠先后
  /// 推进区分；改期后值不再匹配 → 会重新响。
  String? get pointFiredMark => metadata['point_fired'];

  /// 工作强度 = **'长期'**（v1.17，D18 / ui 决议 46）：三无任务的创建缺省。
  /// '长期'不是分钟数、也不是新任务类型（类型仍是 fixed/flex）——标长期的任务
  /// 不估工时、不设优先级、没有时间裕度与剩余工作量，内核属性文档只有 id 一行，
  /// 完成态只认人类文档的 `[x]` / `完成 <时刻>`（D14）。A1/A2/A3 对它全部豁免。
  bool get isLongTerm => estimatedWork == null;

  /// 完成判定（§3.5 规划表）：fixed / routine 仅按 status 判定（0 工时也不允许
  /// 出生即完成）；flex 保留 remainingWork ≤ 0 的语义（logWork 干完即完成）；
  /// **'长期'任务没有 remainingWork**，只认 status 与 [completedAt]
  /// （人类文档复选框是最终真相，D14）。
  /// [completedAt] 是人类文档复选框 `[x]` 的落地形态，同样算完成。
  bool get isCompleted {
    final remaining = remainingWork; // 局部别名：公有字段不能被空提升
    return status == TaskStatus.completed ||
        completedAt != null ||
        (type == TaskType.flex && remaining != null && remaining <= 0);
  }

  /// [clearSnooze] / [clearDeadline] / [clearCompletedAt] 用于把可空字段置回
  /// null（copyWith 的普通 null 参数表示"保持原值"，无法表达清除）。
  /// [clearWork] 是'长期'的形态：estimatedWork / remainingWork / importance
  /// 三项一起置 null（估不出来 → 没有工时、没有剩余、没有优先级；D18）。
  /// 反过来说：给'长期'任务设数字工时时，三项要一起给（remainingWork 取新预估、
  /// importance 缺省 3）——这个转换在 TaskService.updateTask 里显式做。
  Task copyWith({
    String? title,
    String? description,
    DateTime? deadline,
    int? estimatedWork,
    int? remainingWork,
    int? importance,
    TaskStatus? status,
    DateTime? snoozedUntil,
    bool clearSnooze = false,
    bool clearDeadline = false,
    List<String>? tags,
    Map<String, String>? metadata,
    DateTime? created,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    bool clearWork = false,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      deadline: clearDeadline ? null : (deadline ?? this.deadline),
      estimatedWork: clearWork ? null : (estimatedWork ?? this.estimatedWork),
      remainingWork: clearWork ? null : (remainingWork ?? this.remainingWork),
      importance: clearWork ? null : (importance ?? this.importance),
      status: status ?? this.status,
      snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
      tags: tags ?? this.tags,
      metadata: metadata ?? this.metadata,
      created: created ?? this.created,
      completedAt:
          clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }
}
