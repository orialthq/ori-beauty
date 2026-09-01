import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/features/plans/plan_editor_screen.dart';

void main() {
  testWidgets('creates a combined time and location draft with a source', (
    tester,
  ) async {
    // Tall enough that the whole form builds: the editor grew a notification
    // row, and a lazily-built list does not create what it cannot show.
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scheduledAt = DateTime(2027, 8, 21, 19, 30);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          sources: const [
            PlanSourceOption(
              captureId: 'capture-1',
              title: '성수 맛집 캡처',
              tags: ['맛집·카페', '한식'],
              subtitle: '식당 세 곳을 정리한 콘텐츠',
            ),
          ],
          initialDraft: PlanDraft(
            title: '',
            triggerKind: PlanDraftTriggerKind.timeAndLocation,
            recurrence: PlanDraftRecurrence.weekly,
            scheduledAt: scheduledAt,
            locationQuery: '',
            sourceCaptureId: 'capture-1',
          ),
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('plan-title-field')),
      '금요일에 성수 맛집 가기',
    );
    await tester.ensureVisible(find.byKey(const Key('plan-location-field')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('plan-location-field')),
      '성수역 3번 출구',
    );

    // Simulate an open keyboard: the fixed save action must remain usable.
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved!.title, '금요일에 성수 맛집 가기');
    expect(saved!.triggerKind, PlanDraftTriggerKind.timeAndLocation);
    expect(saved!.scheduledAt, scheduledAt);
    expect(saved!.locationQuery, '성수역 3번 출구');
    expect(saved!.recurrence, PlanDraftRecurrence.weekly);
    expect(saved!.sourceCaptureId, 'capture-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches between time and location fields and validates input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    // A new plan starts with a time and the offer of a place. There is no
    // "what kind of plan is this?" step to answer first.
    expect(find.byKey(const Key('plan-date-picker')), findsOneWidget);
    expect(find.byKey(const Key('plan-location-field')), findsNothing);
    expect(find.byKey(const Key('plan-add-place')), findsOneWidget);
    // Time cannot be removed while it is the only thing holding the plan up.
    expect(find.byKey(const Key('plan-remove-time')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('plan-add-place')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-add-place')));
    await tester.pumpAndSettle();

    // Both on is 시간 + 장소; now either can go.
    expect(find.byKey(const Key('plan-date-picker')), findsOneWidget);
    expect(find.byKey(const Key('plan-location-field')), findsOneWidget);
    expect(find.byKey(const Key('plan-remove-time')), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-remove-time')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-date-picker')), findsNothing);
    expect(find.byKey(const Key('plan-add-time')), findsOneWidget);
    expect(find.byKey(const Key('plan-location-field')), findsOneWidget);
    // And now the place is the only thing left, so it cannot go either.
    expect(find.byKey(const Key('plan-remove-place')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();
    expect(saved, isNull);
    expect(find.text('계획 제목을 입력해 주세요.'), findsOneWidget);
    expect(find.text('알림을 받을 장소를 입력해 주세요.'), findsOneWidget);
    expect(find.byKey(const Key('plan-no-source-notice')), findsOneWidget);
  });

  testWidgets('the kind is read off the fields, not chosen', (tester) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('plan-title-field')),
      '성수 저녁 약속',
    );

    // Time only.
    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();
    expect(saved?.triggerKind, PlanDraftTriggerKind.time);

    // Add a place: both on means 시간 + 장소, with nothing extra to declare.
    await tester.ensureVisible(find.byKey(const Key('plan-add-place')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-add-place')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('plan-location-field')),
      '성수역 3번 출구',
    );
    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();
    expect(saved?.triggerKind, PlanDraftTriggerKind.timeAndLocation);
    expect(saved?.locationQuery, '성수역 3번 출구');

    // Take the time back out and it is a place plan.
    await tester.ensureVisible(find.byKey(const Key('plan-remove-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-remove-time')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();
    expect(saved?.triggerKind, PlanDraftTriggerKind.location);
    expect(saved?.scheduledAt, isNull);
  });

  testWidgets('carries a multi-day span through to the draft', (tester) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          initialDraft: PlanDraft(
            title: '베트남 다낭',
            triggerKind: PlanDraftTriggerKind.time,
            recurrence: PlanDraftRecurrence.once,
            scheduledAt: DateTime(2027, 8, 16, 9),
          ),
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    // A one-day plan says only its date, with no span anywhere on the form.
    expect(find.text('날짜'), findsOneWidget);
    expect(find.textContaining('일간'), findsNothing);

    // The date row is the only place a span is expressed: a second tap in the
    // calendar closes the run.
    await tester.ensureVisible(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();

    // One month at a time, not a full-screen scroll through every month.
    expect(find.text('2027년 8월'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-date-day-16')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-day-20')));
    await tester.pumpAndSettle();
    expect(find.text('5일간'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-date-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('5일간'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scheduledAt, DateTime(2027, 8, 16, 9));
    expect(saved?.endsAt, DateTime(2027, 8, 20));
    expect(saved?.dayCount, 5);
  });

  testWidgets('a span can run past the end of a month', (tester) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          initialDraft: PlanDraft(
            title: '연말 여행',
            triggerKind: PlanDraftTriggerKind.time,
            recurrence: PlanDraftRecurrence.once,
            scheduledAt: DateTime(2027, 8, 30, 9),
          ),
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plan-date-day-30')));
    await tester.pumpAndSettle();

    // Turning the page does not drop the run in progress.
    await tester.tap(find.byKey(const Key('plan-date-next-month')));
    await tester.pumpAndSettle();
    expect(find.text('2027년 9월'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-date-day-2')));
    await tester.pumpAndSettle();
    expect(find.text('4일간'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-date-confirm')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scheduledAt, DateTime(2027, 8, 30, 9));
    expect(saved?.endsAt, DateTime(2027, 9, 2));
    expect(saved?.dayCount, 4);
  });

  testWidgets('tapping one day and confirming is still a one-day plan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          initialDraft: PlanDraft(
            title: '저녁 약속',
            triggerKind: PlanDraftTriggerKind.time,
            recurrence: PlanDraftRecurrence.once,
            scheduledAt: DateTime(2027, 8, 16, 19),
          ),
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-day-18')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-date-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('날짜'), findsOneWidget);
    expect(find.textContaining('일간'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    // The clock time survives a date change.
    expect(saved?.scheduledAt, DateTime(2027, 8, 18, 19));
    expect(saved?.endsAt, isNull);
  });

  testWidgets('a repeating plan cannot span days', (tester) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PlanDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PlanEditorScreen(
          initialDraft: PlanDraft(
            title: '매주 장보기',
            triggerKind: PlanDraftTriggerKind.time,
            recurrence: PlanDraftRecurrence.once,
            scheduledAt: DateTime(2027, 8, 16, 9),
            endsAt: DateTime(2027, 8, 20),
          ),
          onSave: (draft) => saved = draft,
          popOnSave: false,
        ),
      ),
    );

    expect(find.text('5일간'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('plan-recurrence-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-recurrence-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('매주').last);
    await tester.pumpAndSettle();

    // "매주 화요일, 5일간" is not a thing the rest of the flow could act on, so
    // the span goes with the one-off it belonged to.
    expect(find.text('5일간'), findsNothing);
    expect(find.text('날짜'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('plan-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.endsAt, isNull);
  });
}
