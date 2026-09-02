import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/domain/tag_key.dart';

void main() {
  test('a word is the same word however it is spelled', () {
    // Spacing, separators and case are ways of writing, not meanings.
    expect(tagKey('스킨케어'), tagKey('스킨 케어'));
    expect(tagKey('카페·디저트'), tagKey('카페 디저트'));
    expect(tagKey('카페·디저트'), tagKey('카페/디저트'));
    expect(tagKey('2~5만원'), tagKey('2-5만원'));
    expect(tagKey('Vegan'), tagKey('vegan'));
    // Two different words stay two words. Deciding they mean one thing is a
    // judgement, and the key does not make judgements.
    expect(tagKey('카페'), isNot(tagKey('커피숍')));
    expect(tagKey('카페'), isNot(tagKey('카페·디저트')));
  });

  test('deduping keeps the first spelling of each word', () {
    final tags = dedupedTags(const [
      ContentTag(value: '스킨케어', source: TagSource.user),
      ContentTag(value: '스킨 케어'),
      ContentTag(value: '을지로'),
    ]);

    expect(tags.map((tag) => tag.value), ['스킨케어', '을지로']);
    // The reader's own came first and stays the reader's own.
    expect(tags.first.source, TagSource.user);
  });

  test('a tag arriving in another spelling is written the library way', () {
    final adopted = adoptedSpellings(
      const [
        ContentTag(
          value: '스킨 케어',
          confidence: 0.7,
          quotes: ['수분 크림'],
          facet: TagFacet.kind,
        ),
        ContentTag(value: '새로운말'),
      ],
      {tagKey('스킨케어'): '스킨케어'},
    );

    expect(adopted.map((tag) => tag.value), ['스킨케어', '새로운말']);
    // Only the spelling changed. What the tag knows about itself did not.
    expect(adopted.first.confidence, 0.7);
    expect(adopted.first.quotes, ['수분 크림']);
    expect(adopted.first.facet, TagFacet.kind);
    expect(adopted.first.source, TagSource.ai);
  });

  test('a tag carries the slot it was filled from, and can do without one', () {
    final filed = ContentTag.fromJson(const {
      'value': '성수',
      'source': 'ai',
      'confidence': 0.9,
      'evidenceIds': ['e1'],
      'quotes': ['성수동 2가'],
      'citations': <String>[],
      'facet': 'area',
    }, 'tag');
    expect(filed.facet, TagFacet.area);
    expect(filed.toJson()['facet'], 'area');

    // A tag from before slots existed, or one the reader typed, has none, and
    // neither the snapshot nor the model needs it to.
    final bare = ContentTag.fromJson(const {'value': '성수'}, 'tag');
    expect(bare.facet, isNull);
    expect(bare.toJson().containsKey('facet'), isFalse);
    expect(
      ContentTag.fromJson(const {'value': '성수', 'facet': 'shelf'}, 'tag').facet,
      isNull,
    );
  });

  test('a tag the analysis could only hang on a name is a weak one', () {
    // 0.4 is where the analysis is told to put a tag it could only support
    // with the shop's name, so it must read as weak; a tag read off the menu
    // must not, and the reader's own is never a guess whatever its number.
    expect(const ContentTag(value: '데이트', confidence: 0.4).isWeak, isTrue);
    expect(const ContentTag(value: '닭발', confidence: 0.9).isWeak, isFalse);
    expect(
      const ContentTag(
        value: '데이트',
        confidence: 0.4,
        source: TagSource.user,
      ).isWeak,
      isFalse,
    );
  });

  test('an analysis written under schema 2.1 is read', () {
    final analysis = StructuredContentAnalysis.fromJson({
      'schemaVersion': '2.1',
      'model': 'gpt-5.6-luna',
      'domain': 'food',
      'contentKind': 'place',
      'tags': [
        {
          'value': '맛집·카페',
          'source': 'ai',
          'confidence': 0.95,
          'evidenceIds': ['e1'],
          'quotes': ['닭발', '계란말이'],
          'citations': <String>[],
          'facet': 'field',
        },
        {
          'value': '을지로',
          'source': 'ai',
          'confidence': 0.9,
          'evidenceIds': ['e2'],
          'quotes': ['을지로3가'],
          'citations': <String>[],
          'facet': 'area',
        },
      ],
      'completeness': 'complete',
      'title': {
        'value': '화육계',
        'status': 'observed',
        'confidence': 0.98,
        'evidenceIds': ['e1'],
      },
      'place': {
        'name': '화육계',
        'address': null,
        'searchArea': '을지로',
        'category': 'restaurant',
        'confidence': 0.9,
        'evidenceIds': ['e2'],
      },
      'summary': '을지로의 닭발집이에요.',
      'evidence': [
        {'id': 'e1', 'text': '화육계', 'region': 'overlay', 'confidence': 0.99},
        {'id': 'e2', 'text': '을지로3가', 'region': 'caption', 'confidence': 0.9},
      ],
      'ingredientGroups': <Object?>[],
      'steps': <Object?>[],
      'facts': <Object?>[],
      'conflicts': <Object?>[],
      'warnings': <Object?>[],
    });

    expect(analysis.schemaVersion, '2.1');
    expect(analysis.tags.map((tag) => tag.facet), [
      TagFacet.field,
      TagFacet.area,
    ]);
  });
}
