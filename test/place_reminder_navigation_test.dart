import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/app/ori_beauty_app.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_reminder_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/analysis/analysis_review_screen.dart';
import 'package:ori_beauty/features/analysis/structured_review_screen.dart';
import 'package:ori_beauty/features/products/products_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  testWidgets(
    'a cold-start place reminder opens the exact saved content and acks it',
    (tester) async {
      final controller = AppController(InMemoryIncomingShareService());
      addTearDown(controller.dispose);
      final target = controller.captures.firstWhere(
        (capture) => capture.status != CaptureStatus.analyzing,
      );
      final inbox = InMemoryPlaceReminderOpenInbox([target.raw.id]);
      addTearDown(inbox.close);

      await tester.pumpWidget(
        OriBeautyApp(controller: controller, placeReminderOpenInbox: inbox),
      );
      await tester.pumpAndSettle();

      _expectCaptureDetail(target, tester);
      expect(inbox.acknowledged, contains(target.raw.id));
    },
  );

  testWidgets('a warm place reminder opens the exact saved content', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();
    final target = controller.captures.firstWhere(
      (capture) => capture.status != CaptureStatus.analyzing,
    );
    final inbox = InMemoryPlaceReminderOpenInbox();
    addTearDown(inbox.close);

    await tester.pumpWidget(
      OriBeautyApp(controller: controller, placeReminderOpenInbox: inbox),
    );
    await tester.pumpAndSettle();
    inbox.emit(target.raw.id);
    await tester.pumpAndSettle();

    _expectCaptureDetail(target, tester);
    expect(inbox.acknowledged, contains(target.raw.id));
  });

  testWidgets('a deleted place reminder falls back to the library and acks', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    final inbox = InMemoryPlaceReminderOpenInbox(['capture-already-deleted']);
    addTearDown(inbox.close);

    await tester.pumpWidget(
      OriBeautyApp(controller: controller, placeReminderOpenInbox: inbox),
    );
    await tester.pumpAndSettle();

    expect(find.text('이미 삭제된 콘텐츠예요. 정리함으로 이동했어요.'), findsOneWidget);
    // By what is on screen rather than by which index is lit. There is no bar
    // left to read an index off: the fallback simply lands the reader in 정리함.
    expect(find.byType(ProductsScreen), findsOneWidget);
    expect(inbox.acknowledged, contains('capture-already-deleted'));
  });
}

void _expectCaptureDetail(CaptureRecord capture, WidgetTester tester) {
  if (capture.analysis?.structuredContent != null) {
    expect(find.byType(StructuredReviewScreen), findsOneWidget);
  } else {
    expect(find.byType(AnalysisReviewScreen), findsOneWidget);
  }
}
