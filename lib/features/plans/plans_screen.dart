import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/plan_recommendation_service.dart';
import '../common/shell_menu_button.dart';

/// Presentation-only lifecycle used by [PlansScreen].
///
/// Domain plans can be mapped to this small view model without making the
/// screen depend on persistence or scheduling implementations.
enum PlanListStatus { active, upcoming, completed }

/// A display-ready plan row.
///
/// [triggerLabel] deliberately stays presentation-ready. The domain layer owns
/// timezone, recurrence, and geofence semantics; this screen only renders the
/// resulting explanation.
final class PlanListItem {
  const PlanListItem({
    required this.id,
    required this.title,
    required this.status,
    required this.triggerLabel,
    this.recurrenceLabel,
    this.sourceLabel,
    this.startsAt,
    this.endsAt,
    this.todos = const <PlanTodoSuggestion>[],
  });

  final String id;
  final String title;
  final PlanListStatus status;
  final String triggerLabel;
  final String? recurrenceLabel;
  final String? sourceLabel;

  /// The day the plan is for. Null for a plan with no time condition at all —
  /// a place-only plan waits for a place, not a date, and shows no countdown.
  final DateTime? startsAt;

  /// The last day of a plan that runs longer than one. Null for the rest.
  final DateTime? endsAt;

  /// What this plan turned into. Empty for plans made before the suggestion
  /// step existed, which simply show nothing extra.
  final List<PlanTodoSuggestion> todos;

  int get doneCount => todos.where((todo) => todo.done).length;

  /// How many days the plan covers, counting both ends. One when it is a day.
  int get dayCount {
    final start = startsAt;
    final end = endsAt;
    if (start == null || end == null) return 1;
    final days = DateUtils.dateOnly(
      end,
    ).difference(DateUtils.dateOnly(start)).inDays;
    return days < 1 ? 1 : days + 1;
  }

  /// Days until the plan's day, from [today]. Negative once it has passed.
  int? daysUntil(DateTime today) {
    final start = startsAt;
    if (start == null) return null;
    return DateUtils.dateOnly(
      start,
    ).difference(DateUtils.dateOnly(today)).inDays;
  }

  /// The next thing left to do, or null when everything is ticked off.
  PlanTodoSuggestion? get nextTodo {
    for (final todo in todos) {
      if (!todo.done) return todo;
    }
    return null;
  }

  /// The day this plan next needs attention.
  ///
  /// The soonest unticked to-do rather than the plan's own day, because that is
  /// what a reader has to act on. A wedding a month out with a dress to choose
  /// today comes before a trip in two weeks with nothing due yet.
  ///
  /// A plan with nothing left to do falls back to its own day — it is still
  /// coming, and once it is the nearest thing left it belongs at the top. Null
  /// for a plan with no date at all, which waits on a place, not a clock.
  DateTime? get nextDueAt {
    final start = startsAt;
    if (start == null) return null;
    DateTime? earliest;
    for (final todo in todos) {
      if (todo.done) continue;
      final due = todo.dueDate(start);
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    return earliest ?? DateUtils.dateOnly(start);
  }
}

/// Plan inbox, nearest first.
///
/// This widget intentionally does not own a controller. Integrators can map
/// domain plans to [PlanListItem] and rebuild this screen whenever the source
/// of truth changes.
///
/// One list, not sections. 활성 and 예정 were a distinction the screen made and
/// a reader did not — both are plans that have not happened yet, and the
/// countdown already says which is sooner. What is over left for 지난함, which
/// the header opens.
final class PlansScreen extends StatelessWidget {
  const PlansScreen({
    required this.plans,
    required this.onCreatePlan,
    this.onOpenPlan,
    this.onOpenPast,
    this.onOpenMenu,
    this.today,
    super.key,
  });

  final List<PlanListItem> plans;
  final VoidCallback onCreatePlan;
  final ValueChanged<PlanListItem>? onOpenPlan;

  /// Opens 지난함. The header offers it only once something is in there.
  final VoidCallback? onOpenPast;

  /// Opens the drawer. Every screen carries this now that the tab bar is gone.
  final VoidCallback? onOpenMenu;

  /// The day countdowns are measured against. Defaults to now; tests pin it so
  /// a D-day does not change under them overnight.
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    final ongoing = _ongoing(now);
    final dueCount = _dueByTodayCount(ongoing, now);
    final pastCount = plans.length - ongoing.length;

    return Theme(
      data: AppTheme.plansTheme(Theme.of(context)),
      child: ColoredBox(
        color: AppTheme.planCanvas,
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            key: const PageStorageKey('plans-screen'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                sliver: SliverToBoxAdapter(
                  child: _PlansHeader(
                    onOpenMenu: onOpenMenu,
                    onCreatePlan: onCreatePlan,
                    pastCount: pastCount,
                    onOpenPast: onOpenPast,
                  ),
                ),
              ),
              if (_alertLabel(ongoing.length, dueCount) case final label?)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _AlertHeaderDelegate(
                    label: label,
                    urgent: dueCount > 0,
                  ),
                ),
              if (plans.isEmpty)
                const SliverPadding(
                  padding: EdgeInsets.fromLTRB(22, 20, 22, 0),
                  sliver: SliverToBoxAdapter(child: _FirstPlanNotice()),
                ),
              // No heading over it any more. 지난 계획 moved to its own tab, and
              // a lone 진행 중 was naming the only thing on the screen.
              ..._section(
                key: const Key('plans-ongoing-section'),
                plans: ongoing,
                now: now,
                // Only the nearest plan is filled in. Two filled cards next to
                // each other stop meaning "this one".
                heroIndex: 0,
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 44)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _section({
    required Key key,
    required List<PlanListItem> plans,
    required DateTime now,
    int? heroIndex,
  }) {
    if (plans.isEmpty) return const <Widget>[];
    return <Widget>[
      SliverPadding(
        key: key,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
        sliver: SliverList.separated(
          itemCount: plans.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => _PlanCard(
            plan: plans[index],
            today: now,
            hero: index == heroIndex,
            onTap: onOpenPlan == null ? null : () => onOpenPlan!(plans[index]),
          ),
        ),
      ),
    ];
  }

  /// Everything not finished, ordered by what needs doing soonest.
  ///
  /// By [PlanListItem.nextDueAt] rather than by the plan's own day, so the plan
  /// with work due today sits above one that merely happens sooner. Ties fall
  /// back to the plan's day, and a plan with no date at all — it waits on a
  /// place, not a clock — sits after every plan that has one.
  List<PlanListItem> _ongoing(DateTime now) {
    final result = plans
        .where((plan) => plan.status != PlanListStatus.completed)
        .toList();
    result.sort((first, second) {
      final firstDue = first.nextDueAt;
      final secondDue = second.nextDueAt;
      if (firstDue == null || secondDue == null) {
        if (firstDue == null && secondDue == null) return 0;
        return firstDue == null ? 1 : -1;
      }
      final byDue = firstDue.compareTo(secondDue);
      if (byDue != 0) return byDue;
      final firstDays = first.daysUntil(now) ?? 1 << 30;
      final secondDays = second.daysUntil(now) ?? 1 << 30;
      return firstDays.compareTo(secondDays);
    });
    return List<PlanListItem>.unmodifiable(result);
  }

  /// To-dos that were due today or earlier and are still unticked.
  ///
  /// Overdue counts as due: a reader who missed yesterday needs it in the same
  /// number, not filed away as no longer relevant.
  static int _dueByTodayCount(List<PlanListItem> plans, DateTime now) {
    final today = DateUtils.dateOnly(now);
    var count = 0;
    for (final plan in plans) {
      final startsAt = plan.startsAt;
      if (startsAt == null) continue;
      for (final todo in plan.todos) {
        if (todo.done) continue;
        if (!todo.dueDate(startsAt).isAfter(today)) count += 1;
      }
    }
    return count;
  }

  static String? _alertLabel(int ongoingCount, int dueCount) {
    if (ongoingCount == 0) return null;
    final running = '계획 $ongoingCount개 진행 중';
    return dueCount == 0 ? running : '$dueCount개가 오늘까지 · $running';
  }
}

final class _PlansHeader extends StatelessWidget {
  const _PlansHeader({
    required this.onCreatePlan,
    required this.pastCount,
    required this.onOpenPast,
    required this.onOpenMenu,
  });

  final VoidCallback onCreatePlan;
  final int pastCount;
  final VoidCallback? onOpenPast;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ShellHeader(
      onOpenMenu: onOpenMenu,
      title: '계획함',
      ink: AppTheme.planInk,
      actions: [
        // Only once there is something behind it: a clock face means little on
        // its own, and the count is what says what the button is for. With
        // nothing there it would open an empty screen and explain nothing.
        if (pastCount > 0 && onOpenPast != null)
          Semantics(
            button: true,
            label: '지난함, 지난 계획 $pastCount개',
            child: Material(
              key: const Key('plans-past-button'),
              color: Colors.transparent,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpenPast,
                child: SizedBox(
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.history_rounded,
                          color: AppTheme.planMuted,
                          size: 19,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '$pastCount',
                          style: const TextStyle(
                            color: AppTheme.planInk,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        Semantics(
          button: true,
          label: '계획 추가',
          child: Material(
            key: const Key('plans-create-button'),
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onCreatePlan,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.add_rounded,
                  color: AppTheme.planInk,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one line that says what needs attention, kept in view while the list
/// scrolls under it.
///
/// Pinned because it is the only part of this screen that is about *today*.
/// Scrolled away it would be a header a reader has to go back up for.
final class _AlertHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _AlertHeaderDelegate({required this.label, required this.urgent});

  final String label;
  final bool urgent;

  static const _height = 82.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // A pinned header takes its paint extent from the child's own height, so
    // the child has to be exactly [_height] or the sliver reports a geometry
    // it cannot paint.
    return SizedBox(
      height: _height,
      child: ColoredBox(
        color: AppTheme.planCanvas,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: urgent ? AppTheme.planAlertSurface : AppTheme.planSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: urgent ? AppTheme.planAlertBorder : AppTheme.planBorder,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: urgent ? AppTheme.planAlert : AppTheme.planSubtle,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: urgent ? AppTheme.planAlert : AppTheme.planMuted,
                        fontSize: 14,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_AlertHeaderDelegate oldDelegate) =>
      label != oldDelegate.label || urgent != oldDelegate.urgent;
}

/// Shown only when there is not a single plan yet.
final class _FirstPlanNotice extends StatelessWidget {
  const _FirstPlanNotice();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.planSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.planBorder),
      ),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '첫 계획을 만들어 보세요',
              style: TextStyle(
                color: AppTheme.planInk,
                fontSize: 17,
                height: 1.35,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '언제 어디서 할지 정하면, 저장해둔 것 중에 쓸 만한 걸 골라 담아 드려요.',
              style: TextStyle(
                color: AppTheme.planMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One plan, as a card.
///
/// The nearest one is [hero]: filled with the accent gradient rather than
/// outlined, so a reader's eye lands on the plan that is actually next before
/// reading a single word.
final class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.today,
    required this.hero,
    this.onTap,
  });

  final PlanListItem plan;
  final DateTime today;
  final bool hero;
  final VoidCallback? onTap;

  bool get _past => plan.status == PlanListStatus.completed;

  Color get _ink => hero
      ? AppTheme.planHeroInk
      : (_past ? AppTheme.planMuted : AppTheme.planInk);

  Color get _muted => hero
      ? AppTheme.planHeroMuted
      : (_past ? AppTheme.planSubtle : AppTheme.planMuted);

  @override
  Widget build(BuildContext context) {
    final nextTodo = plan.nextTodo;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  plan.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.7,
                  ),
                ),
              ),
              if (_countdownLabel() case final countdown?) ...[
                const SizedBox(width: 14),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    countdown,
                    style: TextStyle(
                      color: _ink,
                      fontSize: 27,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text(
            _subtitle(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (plan.todos.isNotEmpty) ...[
            const SizedBox(height: 17),
            _ProgressSegments(
              total: plan.todos.length,
              done: plan.doneCount,
              hero: hero,
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${plan.doneCount} / ${plan.todos.length} 완료',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (nextTodo != null) ...[
            const SizedBox(height: 15),
            Divider(
              height: 1,
              color: hero
                  ? AppTheme.planProgressTrackOnHero
                  : AppTheme.planBorder,
            ),
            const SizedBox(height: 13),
            Text(
              // The group first when there is one. A to-do out of its group
              // reads as a fragment — 원피스 정하기 is a different errand under
              // 하객룩 than under 이사 준비, and the card has no other way to
              // say which.
              '다음 · ${_nextLabel(nextTodo)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _ink,
                fontSize: 14,
                height: 1.35,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ],
      ),
    );

    return Material(
      key: Key('plan-card-${plan.id}'),
      color: hero ? Colors.transparent : AppTheme.planSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: hero
            ? BorderSide.none
            : const BorderSide(color: AppTheme.planBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: hero
            ? const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.planHeroStart, AppTheme.planHeroEnd],
                ),
              )
            : const BoxDecoration(),
        child: onTap == null
            ? Semantics(label: _semanticsLabel(), child: content)
            : InkWell(
                onTap: onTap,
                child: Semantics(
                  button: true,
                  label: _semanticsLabel(),
                  child: ExcludeSemantics(child: content),
                ),
              ),
      ),
    );
  }

  /// `완료` for a plan that is over, a countdown for one with a date, and
  /// nothing at all for a plan waiting on a place — there is no day to count to.
  String? _countdownLabel() {
    if (_past) return '완료';
    final days = plan.daysUntil(today);
    if (days == null) return null;
    if (days == 0) return 'D-DAY';
    return days > 0 ? 'D-$days' : 'D+${-days}';
  }

  /// The span when there is one, and otherwise whatever the domain already
  /// worked out about when or where this fires.
  String _subtitle() {
    final start = plan.startsAt;
    final end = plan.endsAt;
    if (start != null && end != null && plan.dayCount > 1) {
      return '${_shortDate(start)} – ${_shortDate(end)} · ${plan.dayCount}일간';
    }
    return plan.triggerLabel;
  }

  String _semanticsLabel() {
    return <String>[
      plan.title,
      ?_countdownLabel(),
      _subtitle(),
      if (plan.todos.isNotEmpty)
        '할 일 ${plan.todos.length}개 중 ${plan.doneCount}개 완료',
      if (plan.nextTodo case final next?) '다음 ${_nextLabel(next)}',
    ].join(', ');
  }

  static String _nextLabel(PlanTodoSuggestion todo) =>
      todo.group.isEmpty ? todo.title : '${todo.group} · ${todo.title}';

  static String _shortDate(DateTime value) => '${value.month}.${value.day}';
}

/// One segment per to-do, filled left to right.
///
/// A single bar would say how far along a plan is; segments also say how many
/// pieces it is in, which is what tells a fourteen-step trip apart from a
/// two-step errand at a glance.
final class _ProgressSegments extends StatelessWidget {
  const _ProgressSegments({
    required this.total,
    required this.done,
    required this.hero,
  });

  final int total;
  final int done;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final filled = hero
        ? AppTheme.planProgressDoneOnHero
        : AppTheme.planProgressDone;
    final track = hero
        ? AppTheme.planProgressTrackOnHero
        : AppTheme.planProgressTrack;

    return SizedBox(
      height: 5,
      child: Row(
        // Stretch, not the default centre. A childless DecoratedBox under a
        // loose cross-axis constraint takes the smallest height allowed, which
        // is zero — the segments were laid out and coloured correctly and drew
        // nothing at all.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < total; index += 1) ...[
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: index < done ? filled : track,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            if (index != total - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}
