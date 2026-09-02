import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test(
    'what the analysis tags is written the way the library writes it',
    () async {
      final temporaryRoot = await Directory.systemTemp.createTemp(
        'trun-on-spelling-',
      );
      addTearDown(() async {
        if (await temporaryRoot.exists()) {
          await temporaryRoot.delete(recursive: true);
        }
      });
      final incomingDirectory = Directory(
        '${temporaryRoot.path}${Platform.pathSeparator}'
        'incoming_share_attachments',
      );
      await incomingDirectory.create();
      final source = File(
        '${incomingDirectory.path}${Platform.pathSeparator}screen.jpg',
      );
      const imageBytes = [0xff, 0xd8, 0xff];
      await source.writeAsBytes(imageBytes, flush: true);

      final shares = InMemoryIncomingShareService();
      final controller = AppController(
        shares,
        const _TaggingAnalysis(['스킨 케어', '올리브영']),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      // The library already spells it one way.
      await controller.updateGroupTags(controller.groups.first.id, const [
        ContentTag(value: '스킨케어'),
      ]);

      shares.add(
        IncomingShare(
          id: 'share-screen',
          receivedAt: DateTime(2026, 9, 1),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-screen',
              filePath: source.path,
              mimeType: 'image/jpeg',
              byteSize: imageBytes.length,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'c').join(),
            ),
          ],
        ),
      );
      final capture = await _settled(controller, 'capture-share-screen');

      // The model said 스킨 케어. The library says 스킨케어, and the library
      // wins, so one word is one tag however the model spelled it this time.
      // A word the library has never seen keeps the spelling it arrived with.
      expect(capture.contentTags.map((tag) => tag.value), ['스킨케어', '올리브영']);
      expect(capture.contentTags.first.source, TagSource.ai);
    },
  );

  test('a library saved with two spellings comes back with one', () async {
    final snapshotStore = InMemoryAppSnapshotStore();
    final first = AppController(
      InMemoryIncomingShareService(),
      const _TaggingAnalysis(['멕시코 음식']),
      snapshotStore,
    );
    await first.initialize();
    for (final text in const ['타코 맛집', '부리또 맛집']) {
      final id = first.addManualInput(text);
      expect(await first.quickOrganize(id), isTrue);
    }
    expect(first.organizedCountForTag('멕시코 음식'), 2);
    first.dispose();

    // A snapshot from before spellings were joined: the same word, written
    // two ways on two captures. Nothing the app writes today produces this,
    // so it is planted by hand.
    final saved = snapshotStore.snapshot!;
    final last = saved.lastIndexOf('멕시코 음식');
    expect(last, greaterThan(saved.indexOf('멕시코 음식')));
    await snapshotStore.save(
      AppSnapshotCodec.decode(
        saved.replaceRange(last, last + '멕시코 음식'.length, '멕시코음식'),
      ),
    );
    expect(
      AppSnapshotCodec.decode(snapshotStore.snapshot!)
          .map(
            (capture) => capture.analysis?.structuredContent?.tags.single.value,
          )
          .toSet(),
      {'멕시코 음식', '멕시코음식'},
    );

    final second = AppController(
      InMemoryIncomingShareService(),
      const _TaggingAnalysis(['멕시코 음식']),
      snapshotStore,
    );
    addTearDown(second.dispose);
    await second.initialize();

    // Joined on the way in, and written back so it is joined next time too.
    expect(second.organizedCountForTag('멕시코 음식'), 2);
    expect(second.organizedCountForTag('멕시코음식'), 0);
    expect(snapshotStore.snapshot, isNot(contains('멕시코음식')));
  });

  test(
    'respelling a word is the one rename that keeps the typed spelling',
    () async {
      final controller = AppController(InMemoryIncomingShareService());
      addTearDown(controller.dispose);
      await controller.initialize();
      final groups = controller.groups;
      await controller.updateGroupTags(groups.first.id, const [
        ContentTag(value: '멕시코 음식'),
      ]);
      await controller.updateGroupTags(groups[1].id, const [
        ContentTag(value: '멕시코 음식'),
      ]);

      await controller.renameTag('멕시코 음식', '멕시코음식');

      // Typing another spelling of the same word cannot mean "merge into the
      // library's spelling" — that would be a no-op — so it means "spell it
      // this way", everywhere, as the reader's own.
      expect(controller.organizedCountForTag('멕시코 음식'), 0);
      expect(controller.organizedCountForTag('멕시코음식'), 2);
      expect(
        controller.tagsForGroup(groups.first.id).single.source,
        TagSource.user,
      );
    },
  );

  test('renaming onto a spelling of another word lands on that word', () async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();
    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '스킨케어'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '피부관리'),
    ]);

    await controller.renameTag('피부관리', '스킨 케어');

    expect(controller.organizedCountForTag('피부관리'), 0);
    expect(controller.organizedCountForTag('스킨 케어'), 0);
    expect(controller.organizedCountForTag('스킨케어'), 2);
  });

  test('the vocabulary is the library’s words with their counts', () async {
    final controller = AppController(InMemoryIncomingShareService());
    addTearDown(controller.dispose);
    await controller.initialize();
    final groups = controller.groups;
    await controller.updateGroupTags(groups.first.id, const [
      ContentTag(value: '스킨케어'),
      ContentTag(value: '올리브영'),
    ]);
    await controller.updateGroupTags(groups[1].id, const [
      ContentTag(value: '스킨케어'),
    ]);

    final vocabulary = controller.tagVocabulary;

    expect(vocabulary.first, (value: '스킨케어', count: 2));
    expect(vocabulary, contains((value: '올리브영', count: 1)));
  });
}

/// Waits for the drain the share service kicked off to reach the capture.
Future<CaptureRecord> _settled(AppController controller, String id) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final capture = controller.captureById(id);
    if (capture != null && capture.status != CaptureStatus.analyzing) {
      return capture;
    }
  }
  throw StateError('$id never finished analysing');
}

/// An analysis that tags whatever it is shown with the same words.
final class _TaggingAnalysis implements ContentAnalysisService {
  const _TaggingAnalysis(this.tags);

  final List<String> tags;

  static const _baseline = BaselineContentAnalysisService();

  StructuredContentAnalysis get _structured => StructuredContentAnalysis(
    schemaVersion: '2.1',
    model: 'gpt-5.6-luna',
    domain: ContentDomain.beauty,
    contentKind: ContentKind.unknown,
    tags: [
      for (final tag in tags)
        ContentTag(value: tag, confidence: 0.9, quotes: const ['수분 크림']),
    ],
    completeness: StructuredCompleteness.complete,
    title: const StructuredTitle(
      value: '수분 크림',
      status: ObservedStatus.observed,
      confidence: 0.95,
      evidenceIds: [],
    ),
    place: null,
    summary: '수분 크림이에요.',
    evidence: const [],
    ingredientGroups: const [],
    steps: const [],
    facts: const [],
    conflicts: const [],
    warnings: const [],
  );

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) {
    final prepared = _baseline.prepareShare(share, origin: origin);
    return prepared.copyWith(
      status: CaptureStatus.needsReview,
      analysis: _analysisFor(prepared),
    );
  }

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) async =>
      _analysisFor(capture);

  AnalysisRun _analysisFor(CaptureRecord capture) => AnalysisRun(
    id: 'analysis-${capture.raw.transportEventId}',
    inputId: capture.raw.id,
    normalizerVersion: capture.normalized.normalizerVersion,
    analyzerVersion: 'test-tagging-v1',
    status: AnalysisRunStatus.succeeded,
    completedAt: capture.raw.receivedAt,
    evidence: const [],
    productMentions: const [],
    statements: const [],
    disclosure: DisclosureObservation.unknown,
    structuredContent: _structured,
  );
}
