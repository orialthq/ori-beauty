import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/plan_recommendation_service.dart';
import 'package:ori_beauty/features/plans/plans_screen.dart';

/// Pinned so a countdown does not change under the test overnight.
final _today = DateTime(2026, 8, 20);

PlanTodoSuggestion _todo(
  String title, {
  int daysBefore = 0,
  bool done = false,
  List<PlanTodoSavedItem> saved = const <PlanTodoSavedItem>[],
}) {
  return PlanTodoSuggestion(
    title: title,
    action: '준비',
    daysBefore: daysBefore,
    note: '',
    selected: true,
    saved: saved,
    done: done,
  );
}

Widget _screen(
  List<PlanListItem> plans, {
  VoidCallback? onCreatePlan,
  ValueChanged<PlanListItem>? onOpenPlan,
  VoidCallback? onOpenPast,
}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      body: PlansScreen(
        plans: plans,
        today: _today,
        onCreatePlan: onCreatePlan ?? () {},
        onOpenPlan: onOpenPlan,
        onOpenPast: onOpenPast ?? () {},
      ),
    ),
  );
}

void main() {
  testWidgets('splits what is left from what is over, nearest plan first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var createPressed = false;
    PlanListItem? opened;
    final plans = [
      // Deliberately out of order: the screen sorts by what needs doing next,
      // not by the order it was handed the list.
      PlanListItem(
        id: 'tokyo',
        title: '도쿄 4박',
        status: PlanListStatus.upcoming,
        triggerLabel: '10월 10일 오전 09:00',
        startsAt: DateTime(2026, 10, 10, 9),
        endsAt: DateTime(2026, 10, 14),
        todos: <PlanTodoSuggestion>[_todo('항공권 알아보기', daysBefore: 30)],
      ),
      PlanListItem(
        id: 'danang',
        title: '베트남 다낭',
        status: PlanListStatus.upcoming,
        triggerLabel: '9월 3일 오전 08:00',
        startsAt: DateTime(2026, 9, 3, 8),
        endsAt: DateTime(2026, 9, 7),
        todos: <PlanTodoSuggestion>[
          _todo('숙소 예약하기', daysBefore: 20, done: true),
          _todo(
            '먹을 곳 정하기',
            daysBefore: 5,
            saved: const <PlanTodoSavedItem>[
              PlanTodoSavedItem(id: 'cap-1', name: '다낭 미케비치 호텔', why: ''),
              PlanTodoSavedItem(id: 'cap-2', name: '반쎄오 맛집', why: ''),
            ],
          ),
        ],
      ),
      PlanListItem(
        id: 'jeju',
        title: '제주 가족여행',
        status: PlanListStatus.completed,
        triggerLabel: '7월 4일 다녀옴',
        startsAt: DateTime(2026, 7, 4),
      ),
    ];

    await tester.pumpWidget(
      _screen(
        plans,
        onCreatePlan: () => createPressed = true,
        onOpenPlan: (plan) => opened = plan,
      ),
    );

    expect(find.text('계획함'), findsOneWidget);
    expect(find.byKey(const Key('plans-ongoing-section')), findsOneWidget);
    // What is over lives in 지난함 now, and with one section left there is
    // nothing for a heading to tell apart.
    expect(find.text('진행 중'), findsNothing);
    expect(find.text('지난 계획'), findsNothing);
    expect(find.byKey(const Key('plan-card-jeju')), findsNothing);

    // 다낭 is 14 days out and 도쿄 is 51.
    expect(find.text('D-14'), findsOneWidget);
    expect(find.text('D-51'), findsOneWidget);

    // A plan that spans days says so; the rest keep the domain's own label.
    expect(find.text('9.3 – 9.7 · 5일간'), findsOneWidget);
    expect(find.text('10.10 – 10.14 · 5일간'), findsOneWidget);

    expect(find.text('1 / 2 완료'), findsOneWidget);
    expect(find.text('다음 · 먹을 곳 정하기'), findsOneWidget);

    // 다낭's next to-do is due 8.29 and 도쿄's 9.10, so 다낭 leads and is filled.
    final cards = tester.widgetList<Material>(
      find.byKey(const Key('plan-card-danang')),
    );
    expect(cards.single.color, Colors.transparent);

    await tester.tap(find.byKey(const Key('plans-create-button')));
    expect(createPressed, isTrue);

    await tester.tap(find.byKey(const Key('plan-card-danang')));
    expect(opened?.id, 'danang');
  });

  testWidgets('counts what is due today in the pinned banner', (tester) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final plans = [
      PlanListItem(
        id: 'wedding',
        title: '친구 결혼식',
        status: PlanListStatus.upcoming,
        triggerLabel: '9월 2일 오후 12:00',
        startsAt: DateTime(2026, 9, 2, 12),
        todos: <PlanTodoSuggestion>[
          // Due 13 days before 9.2 — that is today.
          _todo('원피스 정하기', daysBefore: 13),
          // Overdue, and still counted: a missed day does not stop mattering.
          _todo('축의금 준비', daysBefore: 20),
          _todo('미용실 예약', daysBefore: 2),
          _todo('이미 끝난 일', daysBefore: 13, done: true),
        ],
      ),
    ];

    await tester.pumpWidget(_screen(plans));

    expect(find.text('2개가 오늘까지 · 계획 1개 진행 중'), findsOneWidget);
    expect(find.text('1 / 4 완료'), findsOneWidget);
  });

  testWidgets('a plan waiting on a place shows no countdown', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const plans = [
      PlanListItem(
        id: 'commute',
        title: '퇴근길에 장보기',
        status: PlanListStatus.active,
        triggerLabel: '회사에서 나갈 때',
      ),
    ];

    await tester.pumpWidget(_screen(plans));

    expect(find.text('회사에서 나갈 때'), findsOneWidget);
    expect(find.textContaining('D-'), findsNothing);
    // Nothing is due, so the banner only reports what is running.
    expect(find.text('계획 1개 진행 중'), findsOneWidget);
  });

  testWidgets('the plan with work due soonest leads, not the nearest one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final plans = [
      PlanListItem(
        id: 'trip',
        title: '베트남 다낭',
        status: PlanListStatus.upcoming,
        // Happens sooner — 14 days out.
        triggerLabel: '9월 3일 오전 08:00',
        startsAt: DateTime(2026, 9, 3, 8),
        // But nothing to do for another 9 days.
        todos: <PlanTodoSuggestion>[_todo('짐 싸기', daysBefore: 5)],
      ),
      PlanListItem(
        id: 'wedding',
        title: '친구 결혼식',
        status: PlanListStatus.upcoming,
        // Happens later — 31 days out.
        triggerLabel: '9월 20일 오후 12:00',
        startsAt: DateTime(2026, 9, 20, 12),
        // But the dress has to be chosen today.
        todos: <PlanTodoSuggestion>[_todo('원피스 정하기', daysBefore: 31)],
      ),
    ];

    await tester.pumpWidget(_screen(plans));

    final weddingY = tester
        .getTopLeft(find.byKey(const Key('plan-card-wedding')))
        .dy;
    final tripY = tester.getTopLeft(find.byKey(const Key('plan-card-trip'))).dy;
    expect(weddingY, lessThan(tripY), reason: '오늘 할 일이 있는 계획이 위로 와야 합니다');

    // And the one on top is the filled card.
    expect(
      tester.widget<Material>(find.byKey(const Key('plan-card-wedding'))).color,
      Colors.transparent,
    );
  });

  testWidgets('a plan with everything ticked falls back to its own day', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final plans = [
      PlanListItem(
        id: 'later',
        title: '나중 계획',
        status: PlanListStatus.upcoming,
        triggerLabel: '9월 20일',
        startsAt: DateTime(2026, 9, 20),
        todos: <PlanTodoSuggestion>[_todo('아직 남음', daysBefore: 25)],
      ),
      PlanListItem(
        id: 'ready',
        title: '준비 끝난 계획',
        status: PlanListStatus.upcoming,
        triggerLabel: '8월 25일',
        startsAt: DateTime(2026, 8, 25),
        todos: <PlanTodoSuggestion>[_todo('다 함', daysBefore: 3, done: true)],
      ),
    ];

    await tester.pumpWidget(_screen(plans));

    // 8.25 beats the other plan's to-do due 8.26, so being ready does not
    // push a plan down the list.
    final readyY = tester
        .getTopLeft(find.byKey(const Key('plan-card-ready')))
        .dy;
    final laterY = tester
        .getTopLeft(find.byKey(const Key('plan-card-later')))
        .dy;
    expect(readyY, lessThan(laterY));
  });

  testWidgets('the progress bar is actually drawn, one segment per to-do', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final plans = [
      PlanListItem(
        id: 'trip',
        title: '베트남 다낭',
        status: PlanListStatus.upcoming,
        triggerLabel: '9월 3일 오전 08:00',
        startsAt: DateTime(2026, 9, 3, 8),
        todos: <PlanTodoSuggestion>[
          for (var index = 0; index < 6; index += 1)
            _todo('할 일 $index', done: index < 2),
        ],
      ),
    ];

    await tester.pumpWidget(_screen(plans));

    final finder = find.descendant(
      of: find.byKey(const Key('plan-card-trip')),
      matching: find.byType(DecoratedBox),
    );
    final widgets = tester.widgetList<DecoratedBox>(finder).toList();
    final boxes = tester.renderObjectList<RenderBox>(finder).toList();

    var segments = 0;
    for (var index = 0; index < widgets.length; index += 1) {
      final decoration = widgets[index].decoration;
      if (decoration is! BoxDecoration || decoration.color == null) continue;
      // A childless DecoratedBox under a loose cross-axis constraint collapses
      // to zero height and paints nothing, and no finder-based assertion can
      // see that. The height is the whole point of this test.
      expect(boxes[index].size.height, 5.0, reason: '진행바 칸이 그려지지 않았습니다');
      segments += 1;
    }

    expect(segments, 6, reason: '할 일 하나에 칸 하나');
  });

  testWidgets('the door to 지난함 counts what is behind it, or is not there', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final live = PlanListItem(
      id: 'live',
      title: '성수 저녁 약속',
      status: PlanListStatus.upcoming,
      triggerLabel: '8월 25일 오후 07:00',
      startsAt: DateTime(2026, 8, 25, 19),
    );
    final over = PlanListItem(
      id: 'jeju',
      title: '제주 가족여행',
      status: PlanListStatus.completed,
      triggerLabel: '7월 4일 다녀옴',
      startsAt: DateTime(2026, 7, 4, 10),
    );

    // Nothing is over, so the header does not offer a way to an empty screen.
    await tester.pumpWidget(_screen(<PlanListItem>[live]));
    expect(find.byKey(const Key('plans-past-button')), findsNothing);

    var openedPast = false;
    await tester.pumpWidget(
      _screen(<PlanListItem>[live, over], onOpenPast: () => openedPast = true),
    );

    final door = find.byKey(const Key('plans-past-button'));
    expect(door, findsOneWidget);
    expect(find.descendant(of: door, matching: find.text('1')), findsOneWidget);
    // It stays a door: what is over is not on this screen.
    expect(find.text('제주 가족여행'), findsNothing);

    await tester.tap(door);
    expect(openedPast, isTrue);
  });

  testWidgets('shows a useful empty state without requiring a controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_screen(const <PlanListItem>[]));

    expect(find.text('첫 계획을 만들어 보세요'), findsOneWidget);
    expect(find.byKey(const Key('plans-ongoing-section')), findsNothing);
  });
}
