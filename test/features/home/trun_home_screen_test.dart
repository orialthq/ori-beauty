import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/features/home/trun_home_screen.dart';
import 'package:ori_beauty/features/plans/plan_editor_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  Future<void> pumpHome(
    WidgetTester tester, {
    required AppController controller,
    ValueChanged<PlanDraft>? onSubmitPlan,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TrunHomeScreen(onAdd: () {}, onSubmitPlan: onSubmitPlan),
        ),
      ),
    );
  }

  testWidgets('a sent prompt becomes the title of a new plan', (tester) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    PlanDraft? submitted;
    await pumpHome(
      tester,
      controller: controller,
      onSubmitPlan: (draft) => submitted = draft,
    );
    await tester.pumpAndSettle();

    // Nothing typed yet, so there is nothing to send.
    await tester.tap(find.byKey(const Key('home-prompt-send')));
    await tester.pump();
    expect(submitted, isNull);

    // Trimmed on the way out: a trailing newline is not part of the title.
    await tester.enterText(
      find.byKey(const Key('home-prompt-field')),
      '  성수에서 저장한 식당 가보기 \n',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-prompt-send')));
    await tester.pumpAndSettle();

    expect(submitted?.title, '성수에서 저장한 식당 가보기');
    // Nothing else was said, so the draft carries no conditions of its own.
    expect(submitted?.scheduledAt, isNull);
    expect(submitted?.locationQuery, isNull);
    expect(submitted?.scopes, isEmpty);
    expect(submitted?.recurrence, PlanDraftRecurrence.once);
    // Cleared, so coming back does not show the sentence that made the plan.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('home-prompt-field')))
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('the box does not offer to send when plans are unavailable', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    await pumpHome(tester, controller: controller);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('home-prompt-field')),
      '성수에서 저장한 식당 가보기',
    );
    await tester.pump();

    final send = tester.widget<Material>(
      find.byKey(const Key('home-prompt-send')),
    );
    expect(send.color, AppTheme.fill);
  });

  testWidgets('a condition added from + rides along with the prompt', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    PlanDraft? submitted;
    await pumpHome(
      tester,
      controller: controller,
      onSubmitPlan: (draft) => submitted = draft,
    );
    await tester.pumpAndSettle();

    // Nothing is on the screen until it is asked for.
    expect(find.byKey(const Key('home-prompt-chip-place')), findsNothing);

    await tester.tap(find.byKey(const Key('home-prompt-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('장소'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '성수역');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-prompt-chip-place')), findsOneWidget);
    expect(find.text('성수역'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('home-prompt-field')),
      '성수에서 저장한 식당 가보기',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-prompt-send')));
    await tester.pumpAndSettle();

    expect(submitted?.locationQuery, '성수역');
    // A place and no date is a plan that waits on a place, not a clock.
    expect(submitted?.triggerKind, PlanDraftTriggerKind.location);
    expect(submitted?.scheduledAt, isNull);
    // The conditions are cleared with the sentence that carried them.
    expect(find.byKey(const Key('home-prompt-chip-place')), findsNothing);
  });

  testWidgets('a condition can be taken off the prompt again', (tester) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    PlanDraft? submitted;
    await pumpHome(
      tester,
      controller: controller,
      onSubmitPlan: (draft) => submitted = draft,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-prompt-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('장소'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '성수역');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('home-prompt-chip-place')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-prompt-chip-place')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('home-prompt-field')),
      '성수에서 저장한 식당 가보기',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-prompt-send')));
    await tester.pumpAndSettle();

    expect(submitted?.locationQuery, isNull);
    expect(submitted?.triggerKind, PlanDraftTriggerKind.time);
  });
}
