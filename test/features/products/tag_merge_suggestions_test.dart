import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/products/all_tags_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  testWidgets('the librarian proposes, and the reader merges or waves away', (
    tester,
  ) async {
    final librarian = _Librarian();
    final controller = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      null,
      null,
      const NoPlaceEnrichmentService(),
      librarian,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '스킨케어'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '피부관리'),
    ]);
    librarian.answer = const [
      TagMerge(from: '피부관리', into: '스킨케어', reason: '같은 뜻의 다른 말이에요.'),
      // A pair naming a word the library does not have must not be shown:
      // acting on it would rename onto a word that is not there.
      TagMerge(from: '없는말', into: '스킨케어', reason: ''),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: AllTagsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // The pass was shown the library's words and their counts, nothing else.
    expect(librarian.asked.map((entry) => entry.value), ['스킨케어', '피부관리']);
    expect(find.byKey(const Key('tag-merge-row-피부관리')), findsOneWidget);
    expect(find.byKey(const Key('tag-merge-row-없는말')), findsNothing);
    expect(find.text('같은 뜻의 다른 말이에요.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tag-merge-apply-피부관리')));
    await tester.pumpAndSettle();

    // Accepting is the same act as renaming: the smaller word joins the
    // larger, becomes the reader's own, and the row is gone because the word
    // is gone.
    expect(controller.organizedCountForTag('피부관리'), 0);
    expect(controller.organizedCountForTag('스킨케어'), 2);
    expect(find.byKey(const Key('tag-merge-row-피부관리')), findsNothing);
    expect(controller.tagsForGroup(groups[1].id).single.source, TagSource.user);
  });

  testWidgets('a waved-away suggestion stays away, and nothing is merged', (
    tester,
  ) async {
    final librarian = _Librarian()
      ..answer = const [
        TagMerge(from: '피부관리', into: '스킨케어', reason: '같은 뜻이에요.'),
      ];
    final controller = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      null,
      null,
      const NoPlaceEnrichmentService(),
      librarian,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '스킨케어'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '피부관리'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: AllTagsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tag-merge-dismiss-피부관리')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tag-merge-row-피부관리')), findsNothing);
    expect(controller.organizedCountForTag('피부관리'), 1);
    expect(controller.organizedCountForTag('스킨케어'), 1);
  });
}

final class _Librarian implements TagMergeService {
  List<TagMerge> answer = const [];
  List<TagVocabularyEntry> asked = const [];

  @override
  Future<List<TagMerge>> suggest(List<TagVocabularyEntry> vocabulary) async {
    asked = vocabulary;
    return answer;
  }
}
