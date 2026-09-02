import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/domain/tag_key.dart';
import 'package:ori_beauty/features/products/sense_match.dart';

void main() {
  test('a sense word answers the inflections a person actually types', () {
    // Two-way prefix stands in for morphology: 매운거 starts with 매운, and
    // 조용 starts 조용한. No suffix list to maintain, nothing to guess.
    expect(senseWordMatches('매운', '매운거'), isTrue);
    expect(senseWordMatches('조용한', '조용'), isTrue);
    expect(senseWordMatches('매운', '매운'), isTrue);
    // Two characters of overlap or nothing: 매 alone is not a question yet.
    expect(senseWordMatches('매운', '매'), isFalse);
    expect(senseWordMatches('야식', '먹고싶다'), isFalse);
  });

  test('a tag is findable by its leading consonants', () {
    expect(chosungOf('닭발'), 'ㄷㅂ');
    expect(chosungOf('카페·디저트'), 'ㅋㅍ·ㄷㅈㅌ');
    expect(isChosungQuery('ㄷㅂ'), isTrue);
    expect(isChosungQuery('닭ㅂ'), isFalse);
    expect(tagNameMatches('닭발', 'ㄷㅂ'), isTrue);
    expect(tagNameMatches('닭발', '닭'), isTrue);
    expect(tagNameMatches('닭발', 'ㅅㅅ'), isFalse);
  });

  test('typed words reach tags through the dictionary, one way only', () {
    const vocabulary = [
      (value: '닭발', count: 5),
      (value: '국·찌개', count: 3),
      (value: '스킨케어', count: 2),
    ];
    final senses = {
      tagKey('닭발'): ['매운', '야식', '술안주'],
      tagKey('국·찌개'): ['얼큰한', '매운'],
      tagKey('스킨케어'): ['피부', '보습'],
    };

    final hits = senseHits(
      terms: const ['매운거'],
      vocabulary: vocabulary,
      senses: senses,
    );

    // Both spicy tags answer, most used first, each saying which word
    // carried it. 스킨케어 stays out of it.
    expect(hits, [
      (name: '닭발', via: '매운', term: '매운거'),
      (name: '국·찌개', via: '매운', term: '매운거'),
    ]);
  });

  test('a word that is a tag name asks for that tag and nothing more', () {
    const vocabulary = [(value: '닭발', count: 5), (value: '야식', count: 3)];
    final senses = {
      // 닭발 appearing among 야식's senses must not make typing 닭발 light
      // 야식: the mapping is word → tag, never tag → tag.
      tagKey('야식'): ['닭발', '밤에'],
    };

    expect(
      senseHits(terms: const ['닭발'], vocabulary: vocabulary, senses: senses),
      isEmpty,
    );
  });

  test('an asked tag names the tags filed alongside it, most shared first', () {
    const vocabulary = [
      (value: '후암동', count: 3),
      (value: '카페', count: 3),
      (value: '혼밥', count: 1),
      (value: '맛집', count: 2),
    ];
    const filings = [
      ['후암동', '카페'],
      ['후암동', '카페', '혼밥'],
      ['후암동', '맛집'],
      // A filing without 후암동 says nothing about 후암동.
      ['카페', '맛집'],
    ];

    final hits = companionHits(
      terms: const ['후암동'],
      filings: filings,
      vocabulary: vocabulary,
    );

    // 카페 shares two saved things, the other two share one each — and the
    // tie between them keeps vocabulary order. The asked tag never suggests
    // itself, and every count is a filing, not a guess.
    expect(hits.map((hit) => hit.name), ['카페', '혼밥', '맛집']);
    expect(hits.first.via, '후암동');
    // No typed word to replace: accepting a companion adds to the search.
    expect(hits.first.term, isNull);
  });

  test('a half-typed word gets completion, not companions', () {
    const vocabulary = [(value: '후암동', count: 2), (value: '카페', count: 2)];
    const filings = [
      ['후암동', '카페'],
    ];

    // 후암 is still being spelled; neighbours of a question not yet asked
    // would be noise on top of the name completion already offered.
    expect(
      companionHits(
        terms: const ['후암'],
        filings: filings,
        vocabulary: vocabulary,
      ),
      isEmpty,
    );
  });

  test('two asked tags share companions only where both hold', () {
    const vocabulary = [
      (value: '후암동', count: 2),
      (value: '카페', count: 2),
      (value: '혼밥', count: 1),
      (value: '맛집', count: 1),
    ];
    const filings = [
      ['후암동', '카페', '혼밥'],
      ['후암동', '맛집'],
      ['카페', '맛집'],
    ];

    // Words multiply in the sky, so what leads on from them multiplies the
    // same way: only the filing carrying both 후암동 and 카페 speaks.
    expect(
      companionHits(
        terms: const ['후암동', '카페'],
        filings: filings,
        vocabulary: vocabulary,
      ).map((hit) => hit.name),
      ['혼밥'],
    );
  });
}
