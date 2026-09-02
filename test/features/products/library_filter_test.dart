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

  test('a second spelling of a word lands on the first', () async {
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

    // Not two tags waiting for the reader to notice: one word, spelled the
    // way the library already spelled it. There was never a decision here.
    expect(controller.organizedCountForTag('멕시코 음식'), 2);
    expect(controller.organizedCountForTag('멕시코음식'), 0);
  });

  test(
    'renaming a tag onto a different word that exists merges the two',
    () async {
      final controller = AppController(InMemoryIncomingShareService());
      addTearDown(controller.dispose);
      await controller.initialize();

      final groups = controller.groups;
      await controller.updateGroupTags(groups.first.id, const [
        ContentTag(value: '멕시코 음식'),
      ]);
      await controller.updateGroupTags(groups[1].id, const [
        ContentTag(value: '멕시칸'),
      ]);
      expect(controller.organizedCountForTag('멕시코 음식'), 1);
      expect(controller.organizedCountForTag('멕시칸'), 1);

      await controller.renameTag('멕시칸', '멕시코 음식');

      // One word holding both, not an error and not a third tag. Spellings are
      // joined on the way in; two different words that mean one thing is a
      // judgement, and the reader is the one who makes it.
      expect(controller.organizedCountForTag('멕시칸'), 0);
      expect(controller.organizedCountForTag('멕시코 음식'), 2);
    },
  );

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

  testWidgets(
    'a star goes where the finger takes it, and its neighbours follow',
    (tester) async {
      await _pumpSky(tester, terms: const []);
      final sky = tester.state<TagConstellationState>(
        find.byType(TagConstellation),
      );
      final hubBefore = sky.debugPositionOf('tag:맛집·카페')!;
      final starBefore = sky.debugPositionOf('item:a')!;
      final onScreen = sky.debugScreenPositionOf('tag:맛집·카페')!;

      await tester.dragFrom(onScreen, const Offset(120, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The word went right, a good part of the way the finger did — the hand
      // is the only thing that moves a held star, and once let go the springs
      // take a little of it back.
      final hubAfter = sky.debugPositionOf('tag:맛집·카페')!;
      expect(hubAfter.dx - hubBefore.dx, greaterThan(30));
      // And the thing filed under it came along, because it is on a spring.
      final starAfter = sky.debugPositionOf('item:a')!;
      expect(starAfter.dx, greaterThan(starBefore.dx));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a held star stays under the finger while the sky is still new', (
    tester,
  ) async {
    // A fresh sky is still fitting itself to the screen every frame. Holding
    // a star has to switch that off, or each frame re-centres the whole sky
    // around the star and the hand sees the sky slide instead of the star
    // come along — which reads as "dragging does nothing".
    await _pumpSky(tester, terms: const []);
    final sky = tester.state<TagConstellationState>(
      find.byType(TagConstellation),
    );
    final start = sky.debugScreenPositionOf('tag:맛집·카페')!;

    final finger = await tester.startGesture(start);
    await finger.moveBy(const Offset(40, 0));
    await tester.pump();
    await finger.moveBy(const Offset(80, 20));
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final under = sky.debugScreenPositionOf('tag:맛집·카페')!;
    final fingerAt = start + const Offset(120, 20);
    expect((under - fingerAt).distance, lessThan(2));

    await finger.up();
    await tester.pump();
  });

  testWidgets('a finger on empty sky moves the sky, not the stars', (
    tester,
  ) async {
    await _pumpSky(tester, terms: const []);
    final sky = tester.state<TagConstellationState>(
      find.byType(TagConstellation),
    );
    final before = {for (final id in _nodeIds) id: sky.debugPositionOf(id)!};
    final onScreenBefore = sky.debugScreenPositionOf('tag:스킨케어')!;

    await tester.dragFrom(const Offset(4, 4), const Offset(80, 40));
    await tester.pump();

    // Nothing in the sky's own coordinates changed; the camera did. Less than
    // the whole drag, because the first little way is spent deciding it is a
    // drag at all.
    for (final id in _nodeIds) {
      expect(sky.debugPositionOf(id), before[id], reason: id);
    }
    final moved = sky.debugScreenPositionOf('tag:스킨케어')! - onScreenBefore;
    expect(moved.dx, greaterThan(40));
    expect(moved.dy, greaterThan(20));
    expect(moved.dx / moved.dy, closeTo(2, 0.05));
  });

  testWidgets('asking for a word swells it and gathers what hangs off it', (
    tester,
  ) async {
    await _pumpSky(tester, terms: const []);
    final sky = tester.state<TagConstellationState>(
      find.byType(TagConstellation),
    );
    final restSize = sky.debugSizeOf('tag:맛집·카페')!;
    double apart(String item) =>
        (sky.debugPositionOf(item)! - sky.debugPositionOf('tag:맛집·카페')!)
            .distance;
    final aBefore = apart('item:a');
    final bBefore = apart('item:b');

    await _pumpSky(tester, terms: const ['맛집']);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // The word is most of the way to double, and the two places under it
    // have drawn in. That is what a search looks like here: not a shorter
    // list, a bigger shape.
    expect(sky.debugSizeOf('tag:맛집·카페'), greaterThan(restSize * 1.6));
    expect(apart('item:a'), lessThan(aBefore));
    expect(apart('item:b'), lessThan(bBefore));
    // What was not asked for stays its size.
    expect(sky.debugSizeOf('tag:스킨케어'), 5 + 5 * 1.0);

    await _pumpSky(tester, terms: const []);
    for (var frame = 0; frame < 240; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Let go of the word and it breathes back out, and once nothing is
    // moving the sky stops drawing.
    expect(sky.debugSizeOf('tag:맛집·카페'), closeTo(restSize, 0.05));
    expect(sky.debugIsTicking, isFalse);
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

  testWidgets('an asked tag offers its companions, and a tap stacks them', (
    tester,
  ) async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();

    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '후암동'),
      ContentTag(value: '카페'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '후암동'),
      ContentTag(value: '혼밥'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          backgroundColor: AppTheme.background,
          body: ProductsScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('library-view-toggle')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('library-sky-search')), '후암동');
    await tester.pump();

    // The word is a finished tag, so completion has nothing to say — the row
    // holds what the search leads on to, each chip naming what carried it.
    expect(find.byKey(const Key('library-sky-suggestion-카페')), findsOneWidget);
    expect(find.byKey(const Key('library-sky-suggestion-혼밥')), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-sky-suggestion-카페')));
    await tester.pump();

    // Added, not swapped: the reader is narrowing 후암동, not leaving it.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('library-sky-search')))
          .controller!
          .text,
      '후암동 카페',
    );

    // And the row moves on with the search: nothing carries both 후암동 and
    // 카페 besides the one place, so 혼밥 has stopped being an answer.
    expect(find.byKey(const Key('library-sky-suggestion-혼밥')), findsNothing);

    // A companion has no dictionary entry behind it, so there is nothing to
    // strike out and a long press opens no forget dialog.
    await tester.enterText(find.byKey(const Key('library-sky-search')), '후암동');
    await tester.pump();
    await tester.longPress(find.byKey(const Key('library-sky-suggestion-혼밥')));
    await tester.pump();
    expect(find.byKey(const Key('sense-forget-dialog')), findsNothing);
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

/// Every star and word in [_library], by the ids the sky gives them.
const _nodeIds = [
  'tag:맛집·카페',
  'tag:을지로',
  'tag:문래',
  'tag:스킨케어',
  'item:a',
  'item:b',
  'item:c',
  'item:d',
];

/// The sky over [_library], left long enough to settle.
///
/// Forgets the layout an earlier test left behind when it opens a fresh sky,
/// because the sky remembers between visits on purpose and a test that
/// inherited a dragged-about layout would be testing the last test.
Future<void> _pumpSky(
  WidgetTester tester, {
  required List<String> terms,
}) async {
  if (find.byType(TagConstellation).evaluate().isEmpty) {
    debugForgetConstellation();
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        backgroundColor: AppTheme.background,
        body: TagConstellation(
          items: _library(),
          terms: terms,
          onOpenItem: (_) {},
          onToggleTag: (_) {},
        ),
      ),
    ),
  );
  for (var frame = 0; frame < 200; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
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
