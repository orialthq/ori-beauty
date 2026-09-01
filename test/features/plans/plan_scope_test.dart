import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/features/plans/plan_editor_screen.dart';

const _sources = <PlanSourceOption>[
  PlanSourceOption(captureId: 'c1', title: '에어리 선 플루이드', tags: ['뷰티', '스킨케어']),
  PlanSourceOption(captureId: 'c2', title: '리쥬란 후기', tags: ['뷰티', '스킨케어']),
  PlanSourceOption(captureId: 'c3', title: '향수 레이어링', tags: ['뷰티', '향수']),
  PlanSourceOption(captureId: 'c4', title: '화육계 을지로', tags: ['맛집·카페', '한식']),
];

Widget _editor({PlanDraft? initialDraft, ValueChanged<PlanDraft>? onSave}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: PlanEditorScreen(
      sources: _sources,
      initialDraft:
          initialDraft ??
          PlanDraft(
            title: '올리브영 가기',
            triggerKind: PlanDraftTriggerKind.time,
            recurrence: PlanDraftRecurrence.once,
            scheduledAt: DateTime(2027, 8, 21, 19, 30),
          ),
      onSave: onSave,
      popOnSave: false,
    ),
  );
}

void _sizeForForm(WidgetTester tester) {
  // Tall enough that the whole form builds in one pass.
  tester.view.physicalSize = const Size(430, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('planScopeMatches', () {
    test('an empty scope is everywhere, not nowhere', () {
      expect(planScopeMatches(const <String>[], const ['레시피']), isTrue);
    });

    test('any one of several tags is enough', () {
      const scope = ['향수', '맛집·카페'];
      expect(planScopeMatches(scope, const ['뷰티', '향수']), isTrue);
      expect(planScopeMatches(scope, const ['뷰티', '스킨케어']), isFalse);
      expect(planScopeMatches(scope, const ['맛집·카페', '한식']), isTrue);
      expect(planScopeMatches(scope, const ['쇼핑']), isFalse);
    });

    test('a saved thing with no tags is only found by an empty scope', () {
      expect(planScopeMatches(const <String>[], const <String>[]), isTrue);
      expect(planScopeMatches(const ['뷰티'], const <String>[]), isFalse);
    });
  });

  testWidgets('picking a tag narrows what will be searched', (tester) async {
    _sizeForForm(tester);

    PlanDraft? saved;
    await tester.pumpWidget(_editor(onSave: (draft) => saved = draft));

    // Nothing chosen searches the whole library.
    expect(find.text('어디서든'), findsOneWidget);
    expect(find.text('저장한 것 4개'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-scope-field')));
    await tester.pumpAndSettle();

    // Every tag with something under it, most used first.
    expect(find.byKey(const Key('plan-scope-tag-뷰티')), findsOneWidget);
    expect(find.byKey(const Key('plan-scope-tag-스킨케어')), findsOneWidget);
    expect(find.byKey(const Key('plan-scope-tag-한식')), findsOneWidget);
    // Nothing is filed under this one.
    expect(find.byKey(const Key('plan-scope-tag-레시피')), findsNothing);

    await tester.tap(find.byKey(const Key('plan-scope-tag-스킨케어')));
    await tester.pumpAndSettle();

    // Picking does not close the sheet — more can be picked.
    expect(find.byKey(const Key('plan-scope-done')), findsOneWidget);
    expect(find.textContaining('2개에서 찾아요'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-scope-done')));
    await tester.pumpAndSettle();

    expect(find.text('스킨케어'), findsOneWidget);
    expect(find.text('저장한 것 2개'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scopes, const ['스킨케어']);
  });

  testWidgets('several tags widen the search rather than narrowing it', (
    tester,
  ) async {
    _sizeForForm(tester);

    PlanDraft? saved;
    await tester.pumpWidget(_editor(onSave: (draft) => saved = draft));

    await tester.tap(find.byKey(const Key('plan-scope-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-scope-tag-향수')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-scope-tag-한식')));
    await tester.pumpAndSettle();

    // One thing carries 향수 and one carries 한식; a plan wants both.
    expect(find.textContaining('2개에서 찾아요'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-scope-done')));
    await tester.pumpAndSettle();

    expect(find.text('향수 외 1개'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scopes, const ['향수', '한식']);
  });

  testWidgets('a tag picked again is unpicked', (tester) async {
    _sizeForForm(tester);

    PlanDraft? saved;
    await tester.pumpWidget(_editor(onSave: (draft) => saved = draft));

    await tester.tap(find.byKey(const Key('plan-scope-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-scope-tag-뷰티')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-scope-tag-뷰티')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-scope-done')));
    await tester.pumpAndSettle();

    expect(find.text('어디서든'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scopes, isEmpty);
  });

  testWidgets('a scope whose tag no longer exists is dropped', (tester) async {
    _sizeForForm(tester);

    PlanDraft? saved;
    await tester.pumpWidget(
      _editor(
        initialDraft: PlanDraft(
          title: '올리브영 가기',
          triggerKind: PlanDraftTriggerKind.time,
          recurrence: PlanDraftRecurrence.once,
          scheduledAt: DateTime(2027, 8, 21, 19, 30),
          // Nothing carries this any more. A plan promising to search it would
          // promise a search over nothing.
          scopes: const ['영양제', '향수'],
        ),
        onSave: (draft) => saved = draft,
      ),
    );

    expect(find.text('향수'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-editor-save')));
    await tester.pump();

    expect(saved?.scopes, const ['향수']);
  });
}
