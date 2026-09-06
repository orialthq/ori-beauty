import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/development_backup_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/data/tag_sense_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test(
    'restore replaces only user content and saves the backup snapshot',
    () async {
      final fixture = await _RestoreFixture.create();
      addTearDown(fixture.dispose);
      final store = InMemoryAppSnapshotStore();
      await store.save([fixture.persisted('old-content')]);
      final controller = fixture.controller(store);
      addTearDown(controller.dispose);
      await controller.initialize();
      final demoCount = controller.captures.length - 1;

      final plan = await fixture.planFor('restored-content');
      final result = await controller.restoreDevelopmentBackup(plan);

      expect(result.captureCount, 1);
      expect(controller.userCaptureCount, 1);
      expect(controller.captures, hasLength(demoCount + 1));
      expect(controller.captureById('capture-old-content'), isNull);
      expect(controller.captureById('capture-restored-content'), isNotNull);
      expect(
        controller.captures.where(
          (capture) => capture.raw.origin == CaptureOrigin.demo,
        ),
        hasLength(demoCount),
      );
      expect(
        AppSnapshotCodec.decode(store.snapshot!).single.transportEventId,
        'restored-content',
      );
    },
  );

  test(
    'restore rolls memory and installed files back when saving fails',
    () async {
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = originalDebugPrint);
      final fixture = await _RestoreFixture.create();
      addTearDown(fixture.dispose);
      final store = _ToggleSnapshotStore();
      await store.save([fixture.persisted('old-content')]);
      final controller = fixture.controller(store);
      addTearDown(controller.dispose);
      await controller.initialize();
      final durableSnapshot = store.snapshot;
      store.failWrites = true;

      final plan = await fixture.planFor('failed-restore');
      await expectLater(
        controller.restoreDevelopmentBackup(plan),
        throwsA(
          isA<DevelopmentBackupRestoreException>().having(
            (error) => error.code,
            'code',
            'snapshot_save_failed',
          ),
        ),
      );

      expect(controller.userCaptureCount, 1);
      expect(controller.captureById('capture-old-content'), isNotNull);
      expect(controller.captureById('capture-failed-restore'), isNull);
      expect(store.snapshot, durableSnapshot);
    },
  );
}

final class _RestoreFixture {
  const _RestoreFixture(this.root, this.backupService);

  static Future<_RestoreFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'luffi-controller-restore-',
    );
    return _RestoreFixture(
      root,
      DevelopmentBackupService(
        restoreDirectoryProvider: () async => Directory(
          '${root.path}${Platform.pathSeparator}restored-attachments',
        ),
      ),
    );
  }

  final Directory root;
  final DevelopmentBackupService backupService;

  PersistedCapture persisted(String id) {
    final record = const BaselineContentAnalysisService().analyzeShare(
      IncomingShare(
        id: id,
        receivedAt: DateTime.utc(2026, 9, 6),
        sharedText: '$id에 대한 저장 내용',
        discoveredUrl: null,
        mimeType: 'text/plain',
        shareKind: ShareKind.text,
      ),
      origin: CaptureOrigin.manual,
    );
    return PersistedCapture.fromRecord(record, null);
  }

  Future<DevelopmentBackupRestorePlan> planFor(String id) async {
    final archive = await backupService.createArchive(
      captures: [persisted(id)],
      tagSenses: const {},
      outputDirectory: root,
    );
    return backupService.inspectArchive(archive);
  }

  AppController controller(AppSnapshotStore store) => AppController(
    InMemoryIncomingShareService(),
    const BaselineContentAnalysisService(),
    store,
    null,
    const NoPlaceEnrichmentService(),
    const NoTagMergeService(),
    const NoTagSenseService(),
    backupService,
  );

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _ToggleSnapshotStore implements AppSnapshotStore {
  final _delegate = InMemoryAppSnapshotStore();
  bool failWrites = false;

  String? get snapshot => _delegate.snapshot;

  @override
  Future<List<PersistedCapture>> load() => _delegate.load();

  @override
  Future<Map<String, List<String>>> loadTagSenses() =>
      _delegate.loadTagSenses();

  @override
  Future<void> save(
    List<PersistedCapture> captures, {
    Map<String, List<String>> tagSenses = const {},
  }) {
    if (failWrites) throw StateError('simulated save failure');
    return _delegate.save(captures, tagSenses: tagSenses);
  }
}
