import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/plan_recommendation_service.dart';
import 'package:ori_beauty/data/place_reminder_service.dart';
import 'package:ori_beauty/data/trigger_plan_store.dart';
import 'package:ori_beauty/data/trigger_scheduler.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/domain/trigger_models.dart';
import 'package:ori_beauty/features/analysis/analysis_review_screen.dart';
import 'package:ori_beauty/features/analysis/structured_review_screen.dart';
import 'package:ori_beauty/features/home/home_shell.dart';
import 'package:ori_beauty/features/plans/past_plans_screen.dart';
import 'package:ori_beauty/features/plans/plan_editor_screen.dart';
import 'package:ori_beauty/features/plans/plans_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';
import 'package:ori_beauty/state/plan_controller.dart';

void main() {
  testWidgets('reaches 계획함 with no tab bar left to reach it by', (
    tester,
  ) async {
    // Every screen moved behind the menu. The bar that used to carry four of
    // them is gone, and 지난함 — never on it — is in the same list now.
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);

    await _pumpHomeShell(tester, fixture);

    expect(find.byType(NavigationBar), findsNothing);

    await _openPlans(tester);

    expect(find.byType(PlansScreen), findsOneWidget);
    expect(
      find.byKey(const PageStorageKey<String>('plans-screen')),
      findsOneWidget,
    );
  });

  testWidgets('a prompt sent from home opens 계획 만들기 with it as the title', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);

    await _pumpHomeShell(tester, fixture);

    await tester.enterText(
      find.byKey(const Key('home-prompt-field')),
      '성수에서 저장한 식당 가보기',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-prompt-send')));
    await tester.pumpAndSettle();

    // The same editor the 계획함 button opens, on its first question rather
    // than on a plan being edited.
    expect(find.byType(PlanEditorScreen), findsOneWidget);
    expect(find.text('계획 만들기'), findsOneWidget);
    expect(find.text('성수에서 저장한 식당 가보기'), findsOneWidget);
  });

  testWidgets('the menu opens a drawer that reaches every screen', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);

    await _pumpHomeShell(tester, fixture);
    await tester.tap(find.byKey(const Key('shell-menu-button')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('luffi')),
      findsOneWidget,
    );
    // The four the tab bar carries, plus the two that only ever had doors.
    for (final label in ['홈', '공유함', '정리함', '계획함', '콘텐츠', '지난함']) {
      expect(find.byKey(Key('drawer-item-$label')), findsOneWidget);
    }
    expect(find.text('개발 도구'), findsOneWidget);
    expect(find.text('콘텐츠 전체 백업(ZIP)'), findsOneWidget);
    expect(find.text('가져온 콘텐츠 전체 삭제'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer-item-계획함')));
    await tester.pumpAndSettle();

    expect(find.byType(PlansScreen), findsOneWidget);
    // It closes behind itself rather than staying over what it opened.
    expect(find.byKey(const Key('drawer-item-계획함')), findsNothing);
  });

  testWidgets('finishing a plan opens the door to 지난함 and puts it behind it', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);
    // 지난함 opens on the month it is opened in, so the plan has to live there.
    // Pinning it to a fixed month made this pass until that month went by.
    final now = DateTime.now();
    final plan = await fixture.createPlan(
      at: DateTime.utc(now.year, now.month, 19, 17),
    );

    await _pumpHomeShell(tester, fixture);
    await _openPlans(tester);

    // Nothing is over yet, so there is no door to a screen with nothing on it.
    expect(find.byKey(const Key('plans-past-button')), findsNothing);

    fixture.scheduler.emitOutcomes(<NativeTriggerOutcome>[
      NativeTriggerOutcome(
        eventId: 'done-1',
        ruleId: plan.id,
        kind: NativeTriggerOutcomeKind.done,
        occurredAt: DateTime.utc(2026, 8, 19, 18),
      ),
    ]);
    await tester.pumpAndSettle();

    final door = find.byKey(const Key('plans-past-button'));
    expect(door, findsOneWidget);
    // The count is what says what the button is for.
    expect(find.descendant(of: door, matching: find.text('1')), findsOneWidget);
    // And it left 계획함 on its way there.
    expect(find.byKey(Key('plan-card-${plan.id}')), findsNothing);

    await tester.tap(door);
    await tester.pumpAndSettle();

    expect(find.byType(PastPlansScreen), findsOneWidget);
    expect(find.text('저장한 맛집 방문하기'), findsOneWidget);
  });

  testWidgets('a to-do falls on the same day on the card and behind it', (
    tester,
  ) async {
    // The shell hands the detail screen the day every deadline counts back
    // from. Taking it off the trigger put this screen a whole day ahead of the
    // card that opened it, for any lead long enough to cross midnight.
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);
    await fixture.planController.create(
      PlanDraft(
        title: '성수 저녁 약속',
        triggerKind: PlanDraftTriggerKind.time,
        recurrence: PlanDraftRecurrence.once,
        scheduledAt: DateTime.utc(2026, 8, 31, 19),
        leadTime: PlanLeadTime.oneDay,
      ),
      todos: const <PlanTodoSuggestion>[
        PlanTodoSuggestion(
          title: '자리 예약하기',
          action: '예약',
          daysBefore: 3,
          note: '',
          selected: true,
        ),
      ],
    );

    await _pumpHomeShell(tester, fixture);
    await _openPlans(tester);

    // The card counts back from the 31st, so the plan itself must too.
    expect(find.text('8/28'), findsNothing);
    await tester.tap(find.byKey(const Key('plan-card-plan-ui')));
    await tester.pumpAndSettle();
    expect(find.text('8/28'), findsOneWidget);
    expect(find.text('8/27'), findsNothing);
  });

  testWidgets('opens the plan creation flow from the HomeShell plans tab', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);

    await _pumpHomeShell(tester, fixture);

    await _openPlans(tester);
    await tester.tap(find.byKey(const Key('plans-create-button')));
    await tester.pumpAndSettle();

    expect(find.byType(PlanEditorScreen), findsOneWidget);
    expect(find.byKey(const Key('plan-title-field')), findsOneWidget);
    expect(find.byKey(const Key('plan-editor-save')), findsOneWidget);
  });

  testWidgets(
    'records sourceOpened only after a plan action opens linked content',
    (tester) async {
      final fixture = await _HomeShellPlansFixture.create();
      addTearDown(fixture.dispose);
      final target = fixture.appController.captures.firstWhere(
        (capture) => capture.status != CaptureStatus.analyzing,
      );
      final plan = await fixture.createPlan(sourceCaptureId: target.raw.id);

      await _pumpHomeShell(tester, fixture);
      await _openPlanActions(tester, plan.id);

      final openSource = find.text('연결된 콘텐츠 보기');
      expect(
        find.ancestor(of: openSource, matching: find.byType(SafeArea)),
        findsWidgets,
      );
      await tester.tap(openSource);
      await tester.pumpAndSettle();

      _expectCaptureDetail(target, tester);
      final event = _interactionEvents(
        fixture,
        plan.id,
        TriggerPlanEventKind.sourceOpened,
      ).single;
      expect(event.metadata['captureId'], target.raw.id);
      expect(event.metadata['source'], 'plan_actions');
      expect(event.metadata['planId'], plan.id);
    },
  );

  testWidgets('does not record sourceOpened for an ordinary recent item open', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);
    final target = fixture.appController.captures
        .take(3)
        .firstWhere((capture) => capture.status != CaptureStatus.analyzing);
    final plan = await fixture.createPlan(sourceCaptureId: target.raw.id);

    await _pumpHomeShell(tester, fixture);
    // Through the drawer's 콘텐츠, which is where the list moved when home kept
    // nothing but the box.
    await tester.tap(find.byKey(const Key('shell-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-item-콘텐츠')));
    await tester.pumpAndSettle();
    final row = find.byKey(Key('capture-card-${target.raw.id}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    _expectCaptureDetail(target, tester);
    expect(
      _interactionEvents(fixture, plan.id, TriggerPlanEventKind.sourceOpened),
      isEmpty,
    );
  });

  testWidgets(
    'notification navigation records sourceOpened with native open identity',
    (tester) async {
      final fixture = await _HomeShellPlansFixture.create();
      addTearDown(fixture.dispose);
      final target = fixture.appController.captures.firstWhere(
        (capture) => capture.status != CaptureStatus.analyzing,
      );
      final plan = await fixture.createPlan(sourceCaptureId: target.raw.id);

      await _pumpHomeShell(tester, fixture);
      final open = NativeTriggerOpen(
        eventId: 'native-open-1',
        ruleId: plan.id,
        destinationId: target.raw.id,
        occurredAt: DateTime.utc(2026, 8, 18, 12, 1),
      );
      fixture.scheduler.emitOpen(open);
      await tester.pumpAndSettle();
      fixture.scheduler.emitOpen(open);
      await tester.pumpAndSettle();

      _expectCaptureDetail(target, tester);
      final event = _interactionEvents(
        fixture,
        plan.id,
        TriggerPlanEventKind.sourceOpened,
      ).single;
      expect(event.metadata['source'], 'notification');
      expect(event.metadata['nativeOpenEventId'], 'native-open-1');
      expect(event.metadata, isNot(contains('deliveryId')));
      expect(event.metadata, isNot(contains('eventKey')));
    },
  );

  testWidgets('not interested records feedback before pausing the plan', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);
    final plan = await fixture.createPlan();

    await _pumpHomeShell(tester, fixture);
    await _openPlanActions(tester, plan.id);
    final notInterested = find.text('이런 알림 그만 받기');
    await tester.ensureVisible(notInterested);
    await tester.tap(notInterested);
    await tester.pumpAndSettle();

    expect(
      fixture.planController.planById(plan.id)?.lifecycle,
      PlanLifecycle.paused,
    );
    final kinds = fixture.planController
        .recordById(plan.id)!
        .events
        .map((event) => event.kind)
        .toList();
    expect(kinds, contains(TriggerPlanEventKind.notInterested));
    expect(
      kinds.indexOf(TriggerPlanEventKind.notInterested),
      lessThan(kinds.indexOf(TriggerPlanEventKind.paused)),
    );
  });

  testWidgets('visit result choices record three distinct interactions', (
    tester,
  ) async {
    final fixture = await _HomeShellPlansFixture.create();
    addTearDown(fixture.dispose);
    final plan = await fixture.createPlan();

    await _pumpHomeShell(tester, fixture);
    for (final (label, kind) in [
      ('다녀왔어요', TriggerPlanEventKind.visitConfirmed),
      ('안 갔어요', TriggerPlanEventKind.didNotVisit),
      ('아직 몰라요', TriggerPlanEventKind.visitUnknown),
    ]) {
      await _openPlanActions(tester, plan.id);
      await tester.tap(find.text('방문 결과 남기기'));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(of: find.text(label), matching: find.byType(SafeArea)),
        findsWidgets,
      );
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(_interactionEvents(fixture, plan.id, kind), hasLength(1));
    }
  });
}

/// Opens 계획함 the only way there is: through the menu.
Future<void> _openPlans(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('shell-menu-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('drawer-item-계획함')));
  await tester.pumpAndSettle();
}

Future<void> _openPlanActions(WidgetTester tester, String planId) async {
  // A previous round may have left the plan's own page on top of the shell.
  // Neither 계획함 nor home's menu on screen means something is pushed over
  // both, so come back down to the shell first.
  while (find.byType(PlansScreen).evaluate().isEmpty &&
      find.byKey(const Key('shell-menu-button')).evaluate().isEmpty) {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }
  if (find.byType(PlansScreen).evaluate().isEmpty) {
    await _openPlans(tester);
  }
  final card = find.byKey(Key('plan-card-$planId'));
  await tester.ensureVisible(card);
  await tester.tap(card);
  await tester.pumpAndSettle();
  // Tapping a plan now opens its own page. The actions live behind the overflow
  // button there rather than firing straight off the card.
  await tester.tap(find.byKey(const Key('plan-detail-actions')));
  await tester.pumpAndSettle();
}

List<TriggerPlanEvent> _interactionEvents(
  _HomeShellPlansFixture fixture,
  String planId,
  TriggerPlanEventKind kind,
) => fixture.planController
    .recordById(planId)!
    .events
    .where((event) => event.kind == kind)
    .toList(growable: false);

void _expectCaptureDetail(CaptureRecord capture, WidgetTester tester) {
  if (capture.analysis?.structuredContent != null) {
    expect(find.byType(StructuredReviewScreen), findsOneWidget);
  } else {
    expect(find.byType(AnalysisReviewScreen), findsOneWidget);
  }
}

Future<void> _pumpHomeShell(
  WidgetTester tester,
  _HomeShellPlansFixture fixture,
) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: HomeShell(
        controller: fixture.appController,
        planController: fixture.planController,
        placeReminderOpenInbox: fixture.placeReminderOpenInbox,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _HomeShellPlansFixture {
  _HomeShellPlansFixture._({
    required this.appController,
    required this.planController,
    required this.placeReminderOpenInbox,
    required this.scheduler,
  });

  final AppController appController;
  final PlanController planController;
  final InMemoryPlaceReminderOpenInbox placeReminderOpenInbox;
  final _TestTriggerScheduler scheduler;

  static Future<_HomeShellPlansFixture> create() async {
    final appController = AppController(InMemoryIncomingShareService());
    final scheduler = _TestTriggerScheduler();
    final planController = PlanController(
      store: InMemoryTriggerPlanStore(),
      scheduler: scheduler,
      clock: () => DateTime.utc(2026, 8, 18, 9),
      idFactory: (_) => 'plan-ui',
      closeSchedulerOnDispose: false,
    );
    final placeReminderOpenInbox = InMemoryPlaceReminderOpenInbox();
    await Future.wait([
      appController.initialize(),
      planController.initialize(),
    ]);
    return _HomeShellPlansFixture._(
      appController: appController,
      planController: planController,
      placeReminderOpenInbox: placeReminderOpenInbox,
      scheduler: scheduler,
    );
  }

  Future<Plan> createPlan({String? sourceCaptureId, DateTime? at}) {
    return planController.create(
      PlanDraft(
        title: '저장한 맛집 방문하기',
        triggerKind: PlanDraftTriggerKind.time,
        recurrence: PlanDraftRecurrence.daily,
        scheduledAt: at ?? DateTime.utc(2026, 8, 19, 17),
        sourceCaptureId: sourceCaptureId,
      ),
    );
  }

  Future<void> dispose() async {
    planController.dispose();
    appController.dispose();
    await scheduler.close();
    await placeReminderOpenInbox.close();
  }
}

final class _TestTriggerScheduler implements TriggerScheduler {
  final _openedController = StreamController<NativeTriggerOpen>.broadcast();
  final _outcomesController =
      StreamController<List<NativeTriggerOutcome>>.broadcast();

  @override
  Stream<NativeTriggerOpen> get opened => _openedController.stream;

  @override
  Stream<List<NativeTriggerOutcome>> get outcomesChanged =>
      _outcomesController.stream;

  @override
  Stream<List<NativeTriggerOpen>> get opensChanged =>
      const Stream<List<NativeTriggerOpen>>.empty();

  void emitOpen(NativeTriggerOpen open) => _openedController.add(open);

  void emitOutcomes(List<NativeTriggerOutcome> outcomes) =>
      _outcomesController.add(outcomes);

  @override
  Future<ResolvedTriggerLocation?> resolveLocation(String query) async => null;

  @override
  Future<NativeTriggerOperationResult> schedulePlan(
    Plan plan, {
    bool resetState = false,
  }) async => const NativeTriggerOperationResult(
    status: 'registered',
    persisted: true,
    notificationPermissionGranted: true,
  );

  @override
  Future<NativeTriggerCancelResult> cancelPlan(String planId) async =>
      NativeTriggerCancelResult(id: planId, removed: true);

  @override
  Future<NativeTriggerSyncReport> syncPlans(
    Iterable<Plan> plans, {
    Set<String> resetStateIds = const <String>{},
  }) async => NativeTriggerSyncReport(
    status: 'registered',
    storedRuleCount: plans.length,
  );

  @override
  Future<List<NativeTriggerRegistration>> registeredPlans() async => const [];

  @override
  Future<NativeTriggerOperationResult> resetPlan(String planId) async =>
      const NativeTriggerOperationResult(status: 'registered');

  @override
  Future<NativeTriggerSyncReport> restore() async =>
      const NativeTriggerSyncReport(status: 'registered');

  @override
  Future<List<NativeTriggerOutcome>> pendingOutcomes() async => const [];

  @override
  Future<bool> acknowledgeOutcomes(Iterable<String> eventIds) async => true;

  @override
  Future<List<NativeTriggerOpen>> pendingOpens() async => const [];

  @override
  Future<bool> acknowledgeOpens(Iterable<String> eventIds) async => true;

  @override
  Future<void> close() async {
    await _openedController.close();
    await _outcomesController.close();
  }
}
