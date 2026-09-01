import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/products/all_tags_screen.dart';
import 'package:ori_beauty/features/products/products_screen.dart';
import 'package:ori_beauty/features/products/saved_library_item.dart';
import 'package:ori_beauty/features/products/tag_constellation.dart';
import 'package:ori_beauty/state/app_controller.dart';

/// A library shaped the way the filter row has to answer to: two places that
/// share 맛집·카페 and differ underneath it, and a third thing filed somewhere
/// unrelated. Reading this off the demo data would make the test say whatever
/// the demo data happened to say.
List<SavedLibraryItem> _library() => [
  _item('a', '화육계', const ['맛집·카페', '을지로']),
  _item('b', '모에루', const ['맛집·카페', '문래']),
  _item('c', '카밍 앰플', const ['스킨케어']),
  _item('d', '이름 없는 캡처', const []),
];

void main() {
  test('the row offers what fits, not everything there is', () {
    final items = _library();

    final atRest = offeredTags(
      visibleItems(items, selected: const [], untaggedOnly: false),
      selected: const [],
    );
    // Most used first, so the busiest word leads.
    expect(atRest.first.name, '맛집·카페');
    expect(atRest.first.count, 2);
    expect(atRest.map((offer) => offer.name), contains('스킨케어'));

    final narrowed = offeredTags(
      visibleItems(items, selected: const ['맛집·카페'], untaggedOnly: false),
      selected: const ['맛집·카페'],
    );

    // The row refills with the two places under it. 스킨케어 is gone because
    // tapping it would empty the screen, and a choice that leads nowhere is
    // not a choice. This is what keeps the row one size at any library size.
    expect(narrowed.map((offer) => offer.name), ['문래', '을지로']);
    expect(narrowed.map((offer) => offer.name), isNot(contains('스킨케어')));
    expect(narrowed.map((offer) => offer.name), isNot(contains('맛집·카페')));
  });

  test('two tags narrow rather than widen', () {
    final items = _library();

    expect(
      visibleItems(
        items,
        selected: const ['맛집·카페'],
        untaggedOnly: false,
      ).map((item) => item.title),
      ['화육계', '모에루'],
    );

    // Both, not either. The plan screen widens because it is gathering
    // candidates worth suggesting; a reader browsing wants fewer things.
    expect(
      visibleItems(
        items,
        selected: const ['맛집·카페', '을지로'],
        untaggedOnly: false,
      ).map((item) => item.title),
      ['화육계'],
    );
    expect(
      visibleItems(items, selected: const ['을지로', '문래'], untaggedOnly: false),
      isEmpty,
    );
  });

  test('having no tag is a filter like any other', () {
    final items = _library();

    expect(
      visibleItems(
        items,
        selected: const [],
        untaggedOnly: true,
      ).map((item) => item.title),
      ['이름 없는 캡처'],
    );
  });

  test('the row is capped however many tags the library holds', () {
    final crowded = [
      for (var index = 0; index < 40; index++)
        _item('item-$index', '캡처 $index', ['공통', '태그$index']),
    ];

    final offers = offeredTags(
      visibleItems(crowded, selected: const [], untaggedOnly: false),
      selected: const [],
    );

    expect(offers.length, lessThanOrEqualTo(8));
    // The one that would actually narrow anything still leads it.
    expect(offers.first.name, '공통');
    expect(offers.first.count, 40);
  });

  testWidgets('the library draws what was saved, with the tags above it', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    final groups = controller.groups;
    expect(groups, hasLength(greaterThanOrEqualTo(2)));
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '스킨케어'),
    ]);
    await controller.updateGroupTags(groups[1].id, const []);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          backgroundColor: AppTheme.background,
          body: ProductsScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-filter-스킨케어')), findsOneWidget);
    expect(find.byKey(const Key('library-filter-untagged')), findsOneWidget);
    expect(find.byKey(const Key('library-all-tags')), findsOneWidget);
    expect(find.text('${groups.length} 저장됨'), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-filter-스킨케어')));
    await tester.pumpAndSettle();

    // Nothing was pushed. The header count is the whole feedback that the tap
    // did something, so it has to be right.
    expect(find.text('1 / ${groups.length}'), findsOneWidget);
  });

  test('renaming a tag onto a name that exists merges the two', () async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '멕시코 음식'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '멕시코음식'),
    ]);
    expect(controller.organizedCountForTag('멕시코 음식'), 1);
    expect(controller.organizedCountForTag('멕시코음식'), 1);

    await controller.renameTag('멕시코 음식', '멕시코음식');

    // One word holding both, not an error and not a third tag. Until an
    // automatic pass can judge that these are the same, the reader can.
    expect(controller.organizedCountForTag('멕시코 음식'), 0);
    expect(controller.organizedCountForTag('멕시코음식'), 2);
  });

  test('a renamed tag becomes the reader’s own', () async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    final group = controller.groups.first;
    await controller.updateGroupTags(group.id, const [
      ContentTag(value: '멕시코 음식'),
    ]);
    await controller.renameTag('멕시코 음식', '멕시코음식');

    final renamed = controller.tagsForGroup(group.id).single;
    expect(renamed.value, '멕시코음식');
    // The reader has said what this is called. A later automatic pass reads
    // the source and leaves it alone.
    expect(renamed.source, TagSource.user);
  });

  test('renaming to the same name changes nothing', () async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    final group = controller.groups.first;
    await controller.updateGroupTags(group.id, const [
      ContentTag(value: '스킨케어'),
    ]);
    await controller.renameTag('스킨케어', '스킨케어');

    expect(controller.tagsForGroup(group.id).single.source, TagSource.ai);
  });

  test('the constellation hangs captures off words, not off each other', () {
    final items = _library();

    final edges = constellationEdges(items);

    // Four captures, three of them sharing 맛집·카페. Joined to each other that
    // would already be three lines from one tag alone and a complete graph as
    // the library grows; hung off the word it is one line each.
    expect(edges.where((edge) => edge.tag == '맛집·카페'), hasLength(2));
    expect(
      edges.map((edge) => '${edge.item}→${edge.tag}'),
      containsAll(['a→맛집·카페', 'a→을지로', 'b→문래', 'c→스킨케어']),
    );
    // Nothing filed anywhere draws no line at all, which is how an untagged
    // capture shows up as a star adrift rather than as a warning.
    expect(edges.where((edge) => edge.item == 'd'), isEmpty);
  });

  testWidgets('the constellation paints a real library without complaint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          backgroundColor: AppTheme.background,
          body: TagConstellation(
            items: _library(),
            terms: const [],
            onOpenItem: (_) {},
            onToggleTag: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TagConstellation), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('two words in the sky multiply, they do not add', () {
    final items = _library();

    // One word is a neighbourhood.
    expect(
      items.where((item) => itemAnswers(item, constellationTerms('맛집'))),
      hasLength(2),
    );
    // Two are a shop. Either-of would have kept both and answered nothing.
    expect(
      items
          .where((item) => itemAnswers(item, constellationTerms('맛집 을지로')))
          .map((item) => item.title),
      ['화육계'],
    );
    // Words that cannot both be true leave the sky dark rather than lighting
    // everything they touch.
    expect(
      items.where((item) => itemAnswers(item, constellationTerms('을지로 문래'))),
      isEmpty,
    );
    // Nothing typed asks nothing, so everything stays lit.
    expect(
      items.where((item) => itemAnswers(item, constellationTerms('  '))),
      hasLength(items.length),
    );
  });

  test('a half-typed word resolves to the tag it can only mean', () {
    const names = ['맛집·카페', '을지로', '문래', '스킨케어'];

    expect(resolveTerms(constellationTerms('을지'), names), ['을지로']);
    expect(resolveTerms(constellationTerms('을지 맛집'), names), ['을지로', '맛집·카페']);
    // An exact name wins over anything it is a prefix of.
    expect(resolveTerms(constellationTerms('문래'), const ['문래', '문래동 카페']), [
      '문래',
    ]);
    // Ambiguous is dropped rather than guessed: the grid filters on exact
    // names and a wrong guess there says nothing on its way past.
    expect(resolveTerms(constellationTerms('ㅇ'), names), isEmpty);
    expect(resolveTerms(constellationTerms('없는말'), names), isEmpty);
  });

  test('the words offered are the ones lately used, not the biggest', () {
    final items = _library();

    // _library is newest first, so this walks the library in the order the
    // reader last touched it.
    expect(recentTags(items, limit: 3), ['맛집·카페', '을지로', '문래']);

    // Most used would have put 맛집·카페 first for the life of the library and
    // never moved. Recently used moves with what the reader is doing, which is
    // the point: it answers "무슨 말을 쓰고 있었지" rather than naming folders.
    expect(recentTags(items).contains('스킨케어'), isTrue);
    expect(recentTags(items, limit: 2), hasLength(2));
  });

  test('the same library twice is recognised as the same library', () {
    // The screen above rebuilds this list from the controller on every frame,
    // so it is never the same object twice. Testing identity instead of
    // contents rebuilt the whole graph on every keystroke and threw the layout
    // back to its starting places, which is what made the sky thrash.
    expect(identical(_library(), _library()), isFalse);
    expect(sameLibrary(_library(), _library()), isTrue);

    // Real changes still count as changes.
    final retagged = [
      _item('a', '화육계', const ['맛집·카페', '을지로', '술집']),
      ..._library().skip(1),
    ];
    expect(sameLibrary(_library(), retagged), isFalse);
    expect(sameLibrary(_library(), _library().take(3).toList()), isFalse);
    expect(
      sameLibrary(_library(), [
        _item('z', '다른 곳', const ['맛집·카페', '을지로']),
        ..._library().skip(1),
      ]),
      isFalse,
    );
  });

  test('a tag files under the letter it is written from', () {
    expect(tagSectionOf('맛집·카페'), 'ㅁ');
    expect(tagSectionOf('을지로'), 'ㅇ');
    // Tensed consonants fold into the plain one they are written from: a
    // reader looking for 빵집 looks under ㅂ.
    expect(tagSectionOf('빵집'), 'ㅂ');
    expect(tagSectionOf('cafe'), 'C');
    expect(tagSectionOf('1인분'), '#');
  });
}

SavedLibraryItem _item(String id, String title, List<String> tags) {
  final receivedAt = DateTime.utc(2026, 8, 7);
  return SavedLibraryItem.forCapture(
    CaptureRecord(
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
    ),
  );
}
