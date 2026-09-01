import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/recommendation_candidates.dart';
import 'package:ori_beauty/domain/models.dart';

CaptureRecord _capture({
  required String id,
  String? title,
  String? placeName,
  String? searchArea,
  List<String> tags = const ['맛집·카페'],
  DateTime? receivedAt,
  bool analyzed = true,
}) {
  final saved = receivedAt ?? DateTime.utc(2026, 8, 7);

  return CaptureRecord(
    raw: RawCapture(
      id: id,
      transportEventId: id,
      receivedAt: saved,
      origin: CaptureOrigin.androidShare,
      mimeType: 'image/png',
      rawText: title ?? id,
      rawUrl: null,
      semanticFingerprint: id,
      wasTruncated: false,
      originalLength: 10,
      sourcePackage: 'Instagram',
    ),
    normalized: NormalizedInput(
      inputId: '$id-input',
      normalizerVersion: 'test',
      normalizedText: title ?? id,
      urls: const [],
      semanticFingerprint: id,
      completeness: MaterialCompleteness.complete,
      warnings: const [],
    ),
    status: CaptureStatus.organized,
    tagOverride: [for (final tag in tags) ContentTag(value: tag)],
    analysis: AnalysisRun(
      id: '$id-analysis',
      inputId: '$id-input',
      normalizerVersion: 'test',
      analyzerVersion: 'test',
      status: AnalysisRunStatus.succeeded,
      completedAt: saved,
      evidence: const [],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      structuredContent: analyzed
          ? StructuredContentAnalysis(
              schemaVersion: '1.3',
              model: 'gpt-5.6-luna',
              domain: ContentDomain.food,
              contentKind: ContentKind.place,
              tags: [for (final tag in tags) ContentTag(value: tag)],
              completeness: StructuredCompleteness.complete,
              title: StructuredTitle(
                value: title,
                status: ObservedStatus.observed,
                confidence: 0.9,
                evidenceIds: const ['e1'],
              ),
              place: placeName == null && searchArea == null
                  ? null
                  : StructuredPlace(
                      name: placeName,
                      address: null,
                      searchArea: searchArea,
                      category: PlaceCategory.restaurant,
                      confidence: 0.9,
                      evidenceIds: const ['e1'],
                    ),
              summary: '',
              evidence: const [],
              ingredientGroups: const [],
              steps: const [],
              facts: const [],
              conflicts: const [],
              warnings: const [],
            )
          : null,
    ),
  );
}

void main() {
  test('a capture that was never analysed is left out', () {
    final candidates = candidatesFromCaptures([
      _capture(id: 'unread', title: '무언가', analyzed: false),
      _capture(id: 'read', placeName: '화육계'),
    ]);

    expect(candidates.map((one) => one.id), ['read']);
  });

  test('a capture with no name at all is left out', () {
    final candidates = candidatesFromCaptures([_capture(id: 'nameless')]);

    expect(candidates, isEmpty);
  });

  test("the place's own name beats the caption it was posted under", () {
    final candidates = candidatesFromCaptures([
      _capture(id: 'a', title: '을지로 닭발 맛집 추천', placeName: '화육계'),
    ]);

    expect(candidates.single.name, '화육계');
  });

  test('the area rides along, and stays null when there is none', () {
    final candidates = candidatesFromCaptures([
      _capture(id: 'placed', placeName: '화육계', searchArea: '을지로'),
      _capture(id: 'recipe', title: '토마토 파스타', tags: const ['레시피', '파스타']),
    ]);

    expect(candidates[0].area, '을지로');
    expect(candidates[1].area, isNull);
  });

  test('a candidate carries every tag the capture is filed under', () {
    final candidates = candidatesFromCaptures([
      _capture(
        id: 'a',
        placeName: '화육계',
        tags: const ['맛집·카페', '닭발', '술집', '예약 가능'],
      ),
    ]);

    expect(candidates.single.tags, ['맛집·카페', '닭발', '술집', '예약 가능']);
  });

  test(
    'the same shop saved three times becomes one candidate that says so',
    () {
      final candidates = candidatesFromCaptures([
        _capture(
          id: 'first',
          placeName: '화육계',
          searchArea: '을지로',
          receivedAt: DateTime.utc(2026, 6, 1),
        ),
        _capture(
          id: 'second',
          placeName: '화 육계',
          receivedAt: DateTime.utc(2026, 7, 1),
        ),
        _capture(
          id: 'newest',
          placeName: '화육계',
          searchArea: '을지로3가',
          tags: const ['닭발'],
          receivedAt: DateTime.utc(2026, 8, 1),
        ),
      ]);

      expect(candidates.length, 1);
      expect(candidates.single.saveCount, 3);
      // The newest screenshot speaks for the group.
      expect(candidates.single.id, 'newest');
      expect(candidates.single.area, '을지로3가');
      expect(candidates.single.lastSavedAt, DateTime.utc(2026, 8, 1));
    },
  );

  test('the same name saved twice is one thing, whatever it is tagged', () {
    // The folder used to be part of the key, so one shop filed two ways became
    // two candidates. Tags are not exclusive, so the name is the whole key.
    final candidates = candidatesFromCaptures([
      _capture(id: 'shop', placeName: '연남 소금집'),
      _capture(id: 'again', placeName: '연남 소금집', tags: const ['레시피']),
    ]);

    expect(candidates.length, 1);
    expect(candidates.single.saveCount, 2);
  });

  test('order is left exactly as it came in', () {
    final candidates = candidatesFromCaptures([
      _capture(id: 'c', placeName: '셋'),
      _capture(id: 'a', placeName: '하나'),
      _capture(id: 'b', placeName: '둘'),
    ]);

    expect(candidates.map((one) => one.id), ['c', 'a', 'b']);
  });

  test('the wire shape drops what is missing', () {
    final candidates = candidatesFromCaptures([
      _capture(
        id: 'recipe',
        title: '토마토 파스타',
        tags: const ['레시피', '파스타'],
        receivedAt: DateTime.utc(2026, 8, 1),
      ),
    ]);

    expect(candidates.single.toJson(), {
      'id': 'recipe',
      'name': '토마토 파스타',
      'tags': ['레시피', '파스타'],
      'saveCount': 1,
      'lastSavedAt': '2026-08-01T00:00:00.000Z',
    });
  });

  test('a filed product becomes a candidate the same shape as a capture', () {
    // The 정리함 tab is captures *and* product groups. Reading only captures is
    // why "올리브영에서 뭐 사지" once went out with an empty shelf.
    final candidate = candidateFromGroup(
      ProductGroup(
        id: 'group-1',
        identity: const ConfirmedProductIdentity(
          brand: '라운드랩',
          name: '자작나무 수분 크림',
          category: '크림',
          amount: '80ml',
        ),
        sourceCaptureIds: const ['a', 'b'],
        statements: const [],
        updatedAt: DateTime.utc(2026, 8, 18),
        colorValue: 0xFF000000,
      ),
      tags: const ['뷰티', '수분크림'],
    );

    expect(candidate.id, 'group-1');
    expect(candidate.name, '자작나무 수분 크림');
    expect(candidate.tags, ['뷰티', '수분크림', '라운드랩', '크림', '80ml']);
    // Two captures filed under it is the reader saving it twice.
    expect(candidate.saveCount, 2);
    expect(candidate.area, isNull);
  });
}
