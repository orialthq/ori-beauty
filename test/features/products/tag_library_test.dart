import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/products/saved_library_item.dart';

/// 정리함 lists tags and puts an item under every one it carries, which is where
/// overlap comes from. This exercises that grouping directly rather than through
/// the widget, so the rule stays pinned independently of layout.
List<MapEntry<String, List<SavedLibraryItem>>> groupByTag(
  List<SavedLibraryItem> items, {
  String untagged = '태그 없음',
}) {
  final grouped = <String, List<SavedLibraryItem>>{};
  for (final item in items) {
    if (item.tags.isEmpty) {
      grouped.putIfAbsent(untagged, () => []).add(item);
      continue;
    }
    for (final tag in item.tags) {
      grouped.putIfAbsent(tag.value, () => []).add(item);
    }
  }
  return grouped.entries.toList();
}

CaptureRecord _organizedCapture({
  required String id,
  required String title,
  required List<String> tags,
}) {
  final receivedAt = DateTime.utc(2026, 8, 7);
  return CaptureRecord(
    raw: RawCapture(
      id: id,
      transportEventId: id,
      receivedAt: receivedAt,
      origin: CaptureOrigin.androidShare,
      mimeType: 'image/png',
      rawText: title,
      rawUrl: null,
      semanticFingerprint: id,
      wasTruncated: false,
      originalLength: title.length,
      sourcePackage: 'Instagram',
    ),
    normalized: NormalizedInput(
      inputId: '$id-input',
      normalizerVersion: 'test',
      normalizedText: title,
      urls: const [],
      semanticFingerprint: id,
      completeness: MaterialCompleteness.complete,
      warnings: const [],
    ),
    status: CaptureStatus.organized,
    analysis: AnalysisRun(
      id: '$id-analysis',
      inputId: '$id-input',
      normalizerVersion: 'test',
      analyzerVersion: 'test',
      status: AnalysisRunStatus.succeeded,
      completedAt: receivedAt,
      evidence: const [],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      structuredContent: StructuredContentAnalysis(
        schemaVersion: '2.0',
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
        place: null,
        summary: '',
        evidence: const [],
        ingredientGroups: const [],
        steps: const [],
        facts: const [],
        conflicts: const [],
        warnings: const [],
      ),
    ),
  );
}

void main() {
  test('one capture lands under every tag it carries', () {
    final item = SavedLibraryItem.forCapture(
      _organizedCapture(
        id: 'ristorante',
        title: '리스토란테 오늘',
        tags: const ['파스타', '와인바', '성수'],
      ),
    );

    final byTag = Map.fromEntries(groupByTag([item]));

    // The whole point of the change: a pasta place that also pours wine is
    // reachable from either word, and from where it is.
    expect(byTag.keys, containsAll(['파스타', '와인바', '성수']));
    expect(byTag['파스타']!.single.title, '리스토란테 오늘');
    expect(byTag['와인바']!.single.title, '리스토란테 오늘');
  });

  test(
    'two captures meet under the tag they share and part under the rest',
    () {
      final items = [
        SavedLibraryItem.forCapture(
          _organizedCapture(
            id: 'a',
            title: '리스토란테 오늘',
            tags: const ['파스타', '성수'],
          ),
        ),
        SavedLibraryItem.forCapture(
          _organizedCapture(
            id: 'b',
            title: '파스타바 논나',
            tags: const ['파스타', '연남'],
          ),
        ),
      ];

      final byTag = Map.fromEntries(groupByTag(items));

      expect(byTag['파스타'], hasLength(2));
      expect(byTag['성수'], hasLength(1));
      expect(byTag['연남'], hasLength(1));
    },
  );

  test('a capture the analysis could not place is still reachable', () {
    final item = SavedLibraryItem.forCapture(
      _organizedCapture(id: 'c', title: '오스테리아 초이', tags: const []),
    );

    final byTag = Map.fromEntries(groupByTag([item]));

    // Nothing vanishes for having no tags. 분류 필요 was a folder; this is the
    // row that stands in for it.
    expect(byTag.keys, ['태그 없음']);
    expect(byTag['태그 없음']!.single.title, '오스테리아 초이');
  });

  test('a tag the reader added leads the ones the analysis proposed', () {
    final capture =
        _organizedCapture(
          id: 'd',
          title: '리스토란테 오늘',
          tags: const ['파스타', '와인바'],
        ).copyWith(
          tagOverride: const [
            ContentTag(value: '데이트', source: TagSource.user),
            ContentTag(value: '파스타'),
          ],
        );

    final item = SavedLibraryItem.forCapture(capture);

    expect(item.tags.first.value, '데이트');
    expect(item.tags.first.source, TagSource.user);
    expect(item.tags.map((tag) => tag.value), ['데이트', '파스타']);
  });

  test('a tag name is searchable text', () {
    final item = SavedLibraryItem.forCapture(
      _organizedCapture(id: 'e', title: '리스토란테 오늘', tags: const ['성수']),
    );

    expect(item.matches('성수'), isTrue);
    expect(item.matches('연남'), isFalse);
  });
}
