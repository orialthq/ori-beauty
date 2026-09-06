import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.orialthq.ori_beauty/incoming_share/v1');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('capture picker returns the platform selection counts', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object?>{
            'selectedCount': 4,
            'importedCount': 3,
            'rejectedCount': 1,
          };
        });
    final service = MethodChannelIncomingShareService();
    addTearDown(service.dispose);

    final result = await service.presentCapturePicker();
    expect(result.selectedCount, 4);
    expect(result.importedCount, 3);
    expect(result.rejectedCount, 1);
    expect(result.wasCancelled, isFalse);
    expect(receivedCall?.method, 'presentCapturePicker');
    expect(receivedCall?.arguments, isNull);
  });

  test(
    'capture picker treats a null platform response as cancellation',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'presentCapturePicker');
            return null;
          });
      final service = MethodChannelIncomingShareService();
      addTearDown(service.dispose);

      final result = await service.presentCapturePicker();
      expect(result.selectedCount, 0);
      expect(result.importedCount, 0);
      expect(result.rejectedCount, 0);
      expect(result.wasCancelled, isTrue);
    },
  );

  test(
    'capture picker accepts the previous boolean platform response',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => true);
      final service = MethodChannelIncomingShareService();
      addTearDown(service.dispose);

      final result = await service.presentCapturePicker();
      expect(result.selectedCount, 1);
      expect(result.importedCount, 1);
      expect(result.rejectedCount, 0);
    },
  );

  test('capture result accepts exactly 100 selected images', () {
    final result = CapturePickerResult.fromPlatformValue({
      'selectedCount': CapturePickerResult.maxSelectionCount,
      'importedCount': 99,
      'rejectedCount': 1,
    });

    expect(result.selectedCount, 100);
  });

  test('capture result rejects malformed or inconsistent platform maps', () {
    final invalidValues = <Object?>[
      'not a map',
      const <String, Object?>{'selectedCount': 1, 'importedCount': 1},
      const <String, Object?>{
        'selectedCount': -1,
        'importedCount': 0,
        'rejectedCount': 0,
      },
      const <String, Object?>{
        'selectedCount': 2,
        'importedCount': 1,
        'rejectedCount': 0,
      },
      const <String, Object?>{
        'selectedCount': 101,
        'importedCount': 101,
        'rejectedCount': 0,
      },
      const <String, Object?>{
        'selectedCount': 1.0,
        'importedCount': 1,
        'rejectedCount': 0,
      },
    ];

    for (final value in invalidValues) {
      expect(
        () => CapturePickerResult.fromPlatformValue(value),
        throwsFormatException,
        reason: 'value: $value',
      );
    }
  });
}
