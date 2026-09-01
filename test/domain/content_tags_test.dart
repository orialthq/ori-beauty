import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/domain/models.dart';

Map<String, Object?> _tag(String value, {double confidence = 0.9}) => {
  'value': value,
  'confidence': confidence,
  'evidenceIds': const ['e1'],
};

Map<String, Object?> _analysis({
  String schemaVersion = '2.0',
  List<Map<String, Object?>>? tags,
  Map<String, Object?>? place,
}) => {
  'schemaVersion': schemaVersion,
  'model': 'gpt-5.6-luna',
  'domain': 'food',
  'contentKind': 'place',
  if (schemaVersion == '2.0')
    'tags': tags ?? const <Map<String, Object?>>[]
  else ...{
    'primaryCategory': 'restaurant_cafe',
    'categoryConfidence': 0.9,
    'subcategory': '파스타',
    'subcategoryConfidence': 0.9,
  },
  'completeness': 'complete',
  'title': {
    'value': '리스토란테 오늘',
    'status': 'observed',
    'confidence': 0.9,
    'evidenceIds': const ['e1'],
  },
  'place': place,
  'summary': '성수의 파스타집이에요.',
  'evidence': [
    {'id': 'e1', 'text': '리스토란테 오늘', 'region': 'image_text', 'confidence': 0.9},
  ],
  'ingredientGroups': const [],
  'steps': const [],
  'facts': const [],
  'conflicts': const [],
  'warnings': const [],
};

void main() {
  test('a capture carries as many tags as fit it', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(tags: [_tag('파스타'), _tag('와인바', confidence: 0.6), _tag('성수')]),
    );

    // A pasta place that also pours wine is both, and the reader reaches it
    // from either word. A folder made it pick one.
    expect(analysis.tags.map((tag) => tag.value), ['파스타', '와인바', '성수']);
    expect(analysis.tags.every((tag) => tag.source == TagSource.ai), isTrue);
  });

  test('drops a repeated name so one tag cannot list a capture twice', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(tags: [_tag('파스타'), _tag('파스타', confidence: 0.4)]),
    );

    expect(analysis.tags.map((tag) => tag.value), ['파스타']);
    // The first survives, so what was read first is what stands.
    expect(analysis.tags.single.confidence, 0.9);
  });

  test('rejects a name that is not reusable', () {
    expect(
      () => StructuredContentAnalysis.fromJson(
        _analysis(tags: [_tag('리스토란테 오늘 #맛집')]),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a capture the analysis could not place carries no tags', () {
    final analysis = StructuredContentAnalysis.fromJson(_analysis(tags: []));

    // Not an error. 분류 필요 used to be a folder, which made not knowing look
    // like a place to put things.
    expect(analysis.tags, isEmpty);
  });

  test('a capture stored under a folder and a subcategory opens as tags', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(schemaVersion: '1.3'),
    );

    // Both were words the capture was filed under; flattening them loses only
    // the shelf they stood on.
    expect(analysis.tags.map((tag) => tag.value), ['맛집·카페', '파스타']);
  });

  test('a folder the analysis was unsure of becomes no tag at all', () {
    final stored = _analysis(schemaVersion: '1.3')
      ..['categoryConfidence'] = 0.4;
    final analysis = StructuredContentAnalysis.fromJson(stored);

    // It used to land in 분류 필요 rather than name the folder.
    expect(analysis.tags.map((tag) => tag.value), ['파스타']);
  });

  test('the area a legacy capture was saved with becomes a tag', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(
        schemaVersion: '1.2',
        place: {
          'name': '리스토란테 오늘',
          'address': '서울 성동구 성수일로 10',
          'searchArea': '성수',
          'category': 'restaurant',
          'confidence': 0.9,
          'evidenceIds': const ['e1'],
        },
      ),
    );

    expect(analysis.tags.map((tag) => tag.value), contains('성수'));
  });

  test('tags a later pass found sit behind the ones already there', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(tags: [_tag('파스타')]),
    );

    final merged = analysis.withTags(const [
      ContentTag(value: '예약 가능', source: TagSource.web),
      // Already there: the same word must not appear twice just because two
      // sources agreed.
      ContentTag(value: '파스타', source: TagSource.web),
    ]);

    expect(merged.tags.map((tag) => tag.value), ['파스타', '예약 가능']);
    expect(merged.tags.first.source, TagSource.ai);
    expect(merged.tags.last.source, TagSource.web);
  });

  test('round-trips through a snapshot', () {
    final analysis = StructuredContentAnalysis.fromJson(
      _analysis(tags: [_tag('파스타'), _tag('성수')]),
    ).withTags(const [ContentTag(value: '예약 가능', source: TagSource.web)]);

    final restored = StructuredContentAnalysis.fromJson(analysis.toJson());

    expect(restored.tags.map((tag) => tag.value), ['파스타', '성수', '예약 가능']);
    expect(restored.tags.last.source, TagSource.web);
  });

  test('a migrated snapshot saved again is not migrated twice', () {
    final migrated = StructuredContentAnalysis.fromJson(
      _analysis(schemaVersion: '1.3'),
    );

    // Written back carrying the version it was analysed at, and the tags it was
    // flattened into. The folder fields are gone, so the migration must not run
    // again looking for them.
    final restored = StructuredContentAnalysis.fromJson(migrated.toJson());

    expect(restored.schemaVersion, '1.3');
    expect(restored.tags.map((tag) => tag.value), ['맛집·카페', '파스타']);
  });
}
