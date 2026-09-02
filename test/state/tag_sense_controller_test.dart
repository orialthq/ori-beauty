import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/data/tag_sense_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/domain/tag_key.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test('a new tag gets its sense words asked for, once, ever', () async {
    final dictionary = _Dictionary({
      tagKey('닭발'): ['매운', '야식'],
      tagKey('을지로'): [],
    });
    final snapshotStore = InMemoryAppSnapshotStore();
    final controller = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      snapshotStore,
      null,
      const NoPlaceEnrichmentService(),
      const NoTagMergeService(),
      dictionary,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.updateGroupTags(controller.groups.first.id, const [
      ContentTag(value: '닭발'),
      ContentTag(value: '을지로'),
    ]);
    await pumpEventQueue();

    expect(controller.tagSenses[tagKey('닭발')], ['매운', '야식']);
    // The empty answer is stored too — asked, nothing useful — so the tag is
    // never asked about again.
    expect(controller.tagSenses[tagKey('을지로')], isEmpty);
    final askedSoFar = dictionary.calls.length;

    await controller.updateGroupTags(controller.groups[1].id, const [
      ContentTag(value: '닭발'),
    ]);
    await pumpEventQueue();

    expect(dictionary.calls.length, askedSoFar);

    // And the dictionary survives a restart without being asked for again.
    final revived = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    addTearDown(revived.dispose);
    await revived.initialize();
    expect(revived.tagSenses[tagKey('닭발')], ['매운', '야식']);
  });

  test('a struck-out sense word stays out', () async {
    final snapshotStore = InMemoryAppSnapshotStore();
    final controller = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      snapshotStore,
      null,
      const NoPlaceEnrichmentService(),
      const NoTagMergeService(),
      _Dictionary({
        tagKey('닭발'): ['매운', '데이트'],
      }),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateGroupTags(controller.groups.first.id, const [
      ContentTag(value: '닭발'),
    ]);
    await pumpEventQueue();

    await controller.removeTagSense('닭발', '데이트');

    expect(controller.tagSenses[tagKey('닭발')], ['매운']);
    // Persisted with the word gone: the reader's judgement outlives the
    // session, and the shortened entry still counts as answered.
    final revived = AppController(
      InMemoryIncomingShareService(),
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    addTearDown(revived.dispose);
    await revived.initialize();
    expect(revived.tagSenses[tagKey('닭발')], ['매운']);
  });

  test('an old snapshot simply has no dictionary yet', () {
    final captures = AppSnapshotCodec.decode(AppSnapshotCodec.encode(const []));
    expect(captures, isEmpty);
    // A v4-era snapshot: no tagSenses field at all.
    expect(
      AppSnapshotCodec.decodeTagSenses('{"schemaVersion":4,"captures":[]}'),
      isEmpty,
    );
    // And a v5 one carries it back out.
    final senses = AppSnapshotCodec.decodeTagSenses(
      AppSnapshotCodec.encode(
        const [],
        tagSenses: {
          '닭발': ['매운'],
        },
      ),
    );
    expect(senses, {
      '닭발': ['매운'],
    });
  });
}

/// A dictionary service that answers from a fixed table and keeps the bill.
///
/// Like the real server, it answers every tag it was asked about — with an
/// empty list where the table has nothing — because an unanswered tag is
/// retried and this fixture is for testing that answered ones are not.
final class _Dictionary implements TagSenseService {
  _Dictionary(this.table);

  final Map<String, List<String>> table;
  final calls = <List<TagVocabularyEntry>>[];

  @override
  Future<Map<String, List<String>>> senses(
    List<TagVocabularyEntry> tags,
  ) async {
    calls.add(tags);
    return {
      for (final entry in tags)
        tagKey(entry.value): table[tagKey(entry.value)] ?? const [],
    };
  }
}
