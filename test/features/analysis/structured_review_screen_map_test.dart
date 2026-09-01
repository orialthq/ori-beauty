import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_reminder_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/analysis/structured_review_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.orialthq.ori_beauty/place_reminders/v1');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('calls onMapOpened only after the platform opens a map', (
    tester,
  ) async {
    final sequence = <String>[];
    _mockMapChannel(channel, onOpen: () => sequence.add('platform_opened'));
    final fixture = await _StructuredMapFixture.create();
    addTearDown(fixture.dispose);

    Future<void> onMapOpened({
      required MapProvider provider,
      required String captureId,
      String? planId,
    }) async {
      sequence.add('callback');
      expect(provider, MapProvider.naver);
      expect(captureId, fixture.captureId);
      expect(planId, 'plan-map');
    }

    await _pumpScreen(tester, fixture, onMapOpened: onMapOpened);
    await _openNaverMap(tester);

    expect(sequence, ['platform_opened', 'callback']);
  });

  testWidgets('does not call onMapOpened when the platform open fails', (
    tester,
  ) async {
    _mockMapChannel(channel, failOpen: true);
    final fixture = await _StructuredMapFixture.create();
    addTearDown(fixture.dispose);
    var callbackCount = 0;

    await _pumpScreen(
      tester,
      fixture,
      onMapOpened: ({required provider, required captureId, String? planId}) {
        callbackCount += 1;
      },
    );
    await _openNaverMap(tester);

    expect(callbackCount, 0);
    expect(find.text('지도를 열지 못했어요.'), findsOneWidget);
  });

  testWidgets('analytics callback failure is not shown as a map open failure', (
    tester,
  ) async {
    _mockMapChannel(channel);
    final fixture = await _StructuredMapFixture.create();
    addTearDown(fixture.dispose);

    await _pumpScreen(
      tester,
      fixture,
      onMapOpened:
          ({required provider, required captureId, String? planId}) async {
            throw StateError('analytics unavailable');
          },
    );
    await _openNaverMap(tester);

    expect(find.text('지도를 열지 못했어요.'), findsNothing);
  });
}

void _mockMapChannel(
  MethodChannel channel, {
  VoidCallback? onOpen,
  bool failOpen = false,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getMapProviders':
            return <Map<String, Object?>>[
              for (final provider in MapProvider.values)
                <String, Object?>{
                  'id': provider.id,
                  'appInstalled': provider == MapProvider.naver,
                  'available': provider == MapProvider.naver,
                },
            ];
          case 'openMapProvider':
            if (failOpen) {
              throw PlatformException(code: 'open_failed');
            }
            onOpen?.call();
            return <String, Object?>{'provider': 'naver', 'openedInApp': true};
        }
        return null;
      });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _StructuredMapFixture fixture, {
  required MapOpenedCallback onMapOpened,
}) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: StructuredReviewScreen(
        controller: fixture.controller,
        captureId: fixture.captureId,
        planId: 'plan-map',
        onMapOpened: onMapOpened,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openNaverMap(WidgetTester tester) async {
  final openMap = find.text('지도에서 보기');
  await tester.ensureVisible(openMap);
  await tester.tap(openMap);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('map-provider-naver')));
  await tester.pumpAndSettle();
}

final class _StructuredMapFixture {
  const _StructuredMapFixture(this.controller, this.captureId);

  final AppController controller;
  final String captureId;

  static Future<_StructuredMapFixture> create() async {
    final incoming = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'map-capture',
          receivedAt: DateTime.utc(2026, 8, 18),
          sharedText: '성수 맛집 서울 성동구 서울숲길 24',
          discoveredUrl: null,
        ),
      );
    final controller = AppController(incoming, const _PlaceAnalysisService());
    await controller.initialize();
    return _StructuredMapFixture(controller, 'capture-map-capture');
  }

  void dispose() => controller.dispose();
}

final class _PlaceAnalysisService implements ContentAnalysisService {
  const _PlaceAnalysisService();

  static const _baseline = BaselineContentAnalysisService();
  static const _structured = StructuredContentAnalysis(
    schemaVersion: '2.0',
    model: 'test-model',
    domain: ContentDomain.food,
    contentKind: ContentKind.place,
    tags: [ContentTag(value: '맛집')],
    completeness: StructuredCompleteness.complete,
    title: StructuredTitle(
      value: '성수 맛집',
      status: ObservedStatus.observed,
      confidence: 0.98,
      evidenceIds: [],
    ),
    place: StructuredPlace(
      name: '성수 맛집',
      address: '서울 성동구 서울숲길 24',
      searchArea: '성수',
      category: PlaceCategory.restaurant,
      confidence: 0.98,
      evidenceIds: [],
    ),
    summary: '저장한 맛집',
    evidence: [],
    ingredientGroups: [],
    steps: [],
    facts: [],
    conflicts: [],
    warnings: [],
  );

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) {
    final prepared = _baseline.prepareShare(share, origin: origin);
    return prepared.copyWith(
      status: CaptureStatus.needsReview,
      analysis: _analysisFor(prepared),
    );
  }

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) async =>
      _analysisFor(capture);

  static AnalysisRun _analysisFor(CaptureRecord capture) => AnalysisRun(
    id: 'analysis-${capture.raw.id}',
    inputId: capture.raw.id,
    normalizerVersion: capture.normalized.normalizerVersion,
    analyzerVersion: 'test-place-v1',
    status: AnalysisRunStatus.succeeded,
    completedAt: capture.raw.receivedAt,
    evidence: const [],
    productMentions: const [],
    statements: const [],
    disclosure: DisclosureObservation.unknown,
    structuredContent: _structured,
  );
}
