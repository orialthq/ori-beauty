import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/features/inbox/inbox_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  testWidgets(
    'multiple gallery import shows its limit, busy state, and partial result',
    (tester) async {
      final service = InMemoryIncomingShareService()
        ..capturePickerDelay = const Duration(seconds: 1)
        ..capturePickerResult = const CapturePickerResult(
          selectedCount: 3,
          importedCount: 2,
          rejectedCount: 1,
        );
      final controller = AppController(service);
      addTearDown(controller.dispose);
      await controller.initialize();
      await _pumpPickerHost(tester, controller);

      expect(find.text('갤러리에서 사진 여러 장 가져오기'), findsOneWidget);
      expect(find.textContaining('한 번에 최대 100장'), findsOneWidget);
      expect(find.textContaining('갤러리 원본은 그대로'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(OutlinedButton, '갤러리에서 사진 여러 장 가져오기'),
      );
      await tester.pump();
      expect(find.text('사진을 가져오는 중…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(service.presentCapturePickerCount, 1);
      expect(find.byKey(const Key('manual-input-safe-area')), findsNothing);
      expect(find.text('사진 2장을 가져왔어요. 1장은 가져오지 못했어요.'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'cancelling multiple gallery import keeps the add sheet open',
    (tester) async {
      final service = InMemoryIncomingShareService();
      final controller = AppController(service);
      addTearDown(controller.dispose);
      await controller.initialize();
      await _pumpPickerHost(tester, controller);

      await tester.tap(
        find.widgetWithText(OutlinedButton, '갤러리에서 사진 여러 장 가져오기'),
      );
      await tester.pumpAndSettle();

      expect(service.presentCapturePickerCount, 1);
      expect(find.byKey(const Key('manual-input-safe-area')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'too-many platform failure explains the 100-image cap and keeps the sheet',
    (tester) async {
      final service = InMemoryIncomingShareService()
        ..capturePickerError = PlatformException(
          code: 'capture_picker_too_many',
        );
      final controller = AppController(service);
      addTearDown(controller.dispose);
      await controller.initialize();
      await _pumpPickerHost(tester, controller);

      await tester.tap(
        find.widgetWithText(OutlinedButton, '갤러리에서 사진 여러 장 가져오기'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('manual-input-safe-area')), findsOneWidget);
      expect(find.text('사진은 한 번에 최대 100장까지 선택할 수 있어요.'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

Future<void> _pumpPickerHost(
  WidgetTester tester,
  AppController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-content-input'),
            onPressed: () => InboxScreen.openManualInput(context, controller),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-content-input')));
  await tester.pumpAndSettle();
}
