import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/batch_content_analysis_service.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/data/tag_sense_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/inbox/inbox_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'analysis choices fit a 360px phone at ${scale * 100}% text size',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final controller = _controller();
        addTearDown(controller.dispose);
        await controller.initialize();
        await _pumpInput(tester, controller, scale);

        expect(controller.selectedAnalysisMode, CaptureAnalysisMode.batch);
        expect(find.text('절약해서 정리'), findsOneWidget);
        expect(find.textContaining('50% 절약'), findsOneWidget);
        expect(find.textContaining('최대 24시간'), findsOneWidget);
        expect(find.textContaining('최대 10장 동시 분석'), findsOneWidget);
        expect(tester.takeException(), isNull);

        final instant = find.text('바로 정리');
        await tester.ensureVisible(instant);
        await tester.pumpAndSettle();
        await tester.tap(instant);
        await tester.pump();
        expect(controller.selectedAnalysisMode, CaptureAnalysisMode.instant);
        _expectSelected(tester, '바로 정리');

        final batch = find.text('절약해서 정리');
        await tester.ensureVisible(batch);
        await tester.pumpAndSettle();
        await tester.tap(batch);
        await tester.pump();
        expect(controller.selectedAnalysisMode, CaptureAnalysisMode.batch);
        _expectSelected(tester, '절약해서 정리');

        final picker = find.widgetWithText(
          OutlinedButton,
          '갤러리에서 사진 여러 장 가져오기',
        );
        await tester.ensureVisible(picker);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(picker);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(360));
        expect(bounds.bottom, lessThanOrEqualTo(800));
        expect(find.textContaining('한 번에 최대 100장'), findsOneWidget);
        expect(find.textContaining('갤러리 원본은 그대로'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}

void _expectSelected(WidgetTester tester, String label) {
  final option = find.ancestor(
    of: find.text(label),
    matching: find.byType(InkWell),
  );
  expect(
    find.descendant(
      of: option,
      matching: find.byIcon(Icons.check_circle_rounded),
    ),
    findsOneWidget,
  );
}

Future<void> _pumpInput(
  WidgetTester tester,
  AppController controller,
  double scale,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => InboxScreen.openManualInput(context, controller),
            child: const Text('추가 열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('추가 열기'));
  await tester.pumpAndSettle();
}

AppController _controller() => AppController(
  InMemoryIncomingShareService(),
  const BaselineContentAnalysisService(),
  null,
  null,
  const NoPlaceEnrichmentService(),
  const NoTagMergeService(),
  const NoTagSenseService(),
  null,
  _UnusedBatchService(),
);

final class _UnusedBatchService implements BatchContentAnalysisService {
  @override
  Future<List<BatchAnalysisResponse>> poll(List<String> requestIds) async => [];

  @override
  Future<BatchAnalysisResponse> submit(
    CaptureRecord capture, {
    required String requestId,
  }) =>
      throw StateError('Selecting an analysis mode must not submit an image.');
}
