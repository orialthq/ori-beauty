import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/sharing/share_tip_screen.dart';

void main() {
  testWidgets('gift card stays within its 4:5 frame at the selection limit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ShareTipScreen(capture: _denseCapture()),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      '이번 주말에 다 같이 가보고 각자 먹고 싶은 메뉴도 하나씩 골라보자!',
    );
    expect(find.byKey(const Key('share-letter-field')), findsOneWidget);
    expect(find.byKey(const Key('share-card-mascot')), findsOneWidget);
    final mascotBadge = tester.widget<Container>(
      find.byKey(const Key('share-card-mascot-badge')),
    );
    final mascotDecoration = mascotBadge.decoration! as BoxDecoration;
    expect(mascotDecoration.shape, BoxShape.circle);
    expect(mascotDecoration.border, isNull);
    final mascotZoom = tester.widget<Transform>(
      find.byKey(const Key('share-card-mascot-zoom')),
    );
    expect(mascotZoom.transform.getMaxScaleOnAxis(), greaterThan(1));
    expect(find.text('툭.'), findsOneWidget);
    expect(find.text('흥, 이거나 봐.'), findsOneWidget);
    expect(find.text('Trun On 오리가 던졌어요'), findsOneWidget);
    expect(find.text('카드 보내고 지도 링크 이어 보내기'), findsOneWidget);
    expect(find.text('지도 링크만 보내기'), findsOneWidget);
    expect(find.textContaining('이미지 카드와 지도 링크는 따로도'), findsOneWidget);
    expect(find.textContaining('제목과 요약은 기본으로'), findsNothing);
    expect(find.textContaining('핵심 정보 6개까지 고를 수 있어요'), findsNothing);
    expect(find.textContaining('원본 캡처와 OCR 근거'), findsNothing);

    final scrollView = find.byType(SingleChildScrollView);
    await tester.drag(scrollView, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(8));
    for (final label in ['대기', '추천']) {
      final choice = find.text(label);
      await tester.tap(choice);
      await tester.pumpAndSettle();
    }

    await tester.fling(scrollView, const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    final preview = find.byKey(const Key('share-card-preview'));
    expect(preview, findsOneWidget);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .descendant(of: preview, matching: find.byType(RepaintBoundary))
          .first,
    );
    final image = await boundary.toImage(pixelRatio: 3);
    expect(image.width, 1080);
    expect(image.height, 1350);
    image.dispose();
    await tester.fling(scrollView, const Offset(0, 2000), 3000);
    await tester.pumpAndSettle();
    expect(find.text('친구에게 건넬 카드'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gift card export fills its frame with opaque folder color', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = _denseCapture();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ShareTipScreen(capture: capture),
      ),
    );
    await tester.pump();

    final backgroundFinder = find.byKey(
      const Key('share-card-export-background'),
    );
    expect(backgroundFinder, findsOneWidget);
    expect(tester.getSize(backgroundFinder), const Size(360, 450));
    final background = tester.widget<ColoredBox>(backgroundFinder);
    expect(
      background.color,
      AppTheme.primary,
      reason: 'The exported PNG frame must not leave transparent corners.',
    );
  });
}

CaptureRecord _denseCapture() {
  const facts = [
    AnalysisFact(
      label: '대표 메뉴',
      value: '철판쭈꾸미와 볶음밥',
      confidence: 1,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '영업시간',
      value: '매일 11:00~22:00',
      confidence: 1,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '가격',
      value: '1인분 15,000원',
      confidence: 1,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '대기',
      value: '주말에는 예약 권장',
      confidence: 1,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '추천',
      value: '마지막 볶음밥 필수',
      confidence: 1,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '주차',
      value: '인근 공영주차장 이용',
      confidence: 1,
      evidenceIds: [],
    ),
  ];
  const structured = StructuredContentAnalysis(
    schemaVersion: '2.0',
    model: 'gpt-5.6-luna',
    domain: ContentDomain.food,
    contentKind: ContentKind.place,
    tags: [ContentTag(value: '한식')],
    completeness: StructuredCompleteness.complete,
    title: StructuredTitle(
      value: '친구들과 꼭 같이 가보고 싶은 종로 철판쭈꾸미 맛집',
      status: ObservedStatus.observed,
      confidence: 1,
      evidenceIds: [],
    ),
    place: StructuredPlace(
      name: '동묘집',
      address: '서울 종로구 종로52길 43-9',
      searchArea: null,
      category: PlaceCategory.restaurant,
      confidence: 1,
      evidenceIds: [],
    ),
    summary: '매콤한 철판쭈꾸미와 볶음밥을 함께 즐길 수 있는 곳으로 주말 모임에 잘 어울려요.',
    evidence: [],
    ingredientGroups: [],
    steps: [],
    facts: facts,
    conflicts: [],
    warnings: [],
  );
  final receivedAt = DateTime.utc(2026, 8, 5);
  return CaptureRecord(
    raw: RawCapture(
      id: 'share-card-capture',
      transportEventId: 'share-card-transport',
      receivedAt: receivedAt,
      origin: CaptureOrigin.androidShare,
      mimeType: 'image/png',
      rawText: 'raw screenshot text',
      rawUrl: 'https://www.instagram.com/reel/example/?igsh=sample',
      semanticFingerprint: 'share-card-fingerprint',
      wasTruncated: false,
      originalLength: 19,
      sourcePackage: 'Instagram',
    ),
    normalized: const NormalizedInput(
      inputId: 'share-card-input',
      normalizerVersion: 'test',
      normalizedText: 'normalized screenshot text',
      urls: [],
      semanticFingerprint: 'share-card-fingerprint',
      completeness: MaterialCompleteness.complete,
      warnings: [],
    ),
    status: CaptureStatus.organized,
    analysis: AnalysisRun(
      id: 'share-card-analysis',
      inputId: 'share-card-input',
      normalizerVersion: 'test',
      analyzerVersion: 'test',
      status: AnalysisRunStatus.succeeded,
      completedAt: receivedAt,
      evidence: const [],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      structuredContent: structured,
    ),
  );
}
