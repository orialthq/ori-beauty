import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test(
    'clear persists first, keeps demos and gallery original, then removes managed copy',
    () async {
      final fixture = await _ImageFixture.create('clear-success');
      addTearDown(fixture.dispose);
      final store = InMemoryAppSnapshotStore();
      final incoming = InMemoryIncomingShareService()
        ..add(fixture.share('clear-success'));
      final controller = AppController(
        incoming,
        const BaselineContentAnalysisService(),
        store,
      );
      addTearDown(controller.dispose);
      final demoCount = controller.captures.length;
      await controller.initialize();
      final imported = controller.captures.firstWhere(
        (capture) => capture.raw.origin != CaptureOrigin.demo,
      );
      final managedCopy = File(imported.raw.attachments.single.filePath);
      expect(await managedCopy.exists(), isTrue);
      expect(controller.userCaptureCount, 1);

      expect(await controller.clearAllUserCaptures(), isTrue);

      expect(controller.userCaptureCount, 0);
      expect(controller.captures, hasLength(demoCount));
      expect(
        controller.captures.every(
          (capture) => capture.raw.origin == CaptureOrigin.demo,
        ),
        isTrue,
      );
      expect(AppSnapshotCodec.decode(store.snapshot!), isEmpty);
      expect(await managedCopy.exists(), isFalse);
      expect(await fixture.galleryOriginal.exists(), isTrue);
    },
  );

  test(
    'clear rolls all state back and keeps files when saving fails',
    () async {
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = originalDebugPrint);
      final fixture = await _ImageFixture.create('clear-rollback');
      addTearDown(fixture.dispose);
      final store = _ToggleSnapshotStore();
      final incoming = InMemoryIncomingShareService()
        ..add(fixture.share('clear-rollback'));
      final controller = AppController(
        incoming,
        const BaselineContentAnalysisService(),
        store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final imported = controller.captures.firstWhere(
        (capture) => capture.raw.origin != CaptureOrigin.demo,
      );
      final managedCopy = File(imported.raw.attachments.single.filePath);
      final captureCount = controller.captures.length;
      final groupCount = controller.groups.length;
      final durableSnapshot = store.snapshot;
      store.failWrites = true;

      expect(await controller.clearAllUserCaptures(), isFalse);

      expect(controller.captures, hasLength(captureCount));
      expect(controller.groups, hasLength(groupCount));
      expect(controller.userCaptureCount, 1);
      expect(controller.captureById(imported.raw.id), isNotNull);
      expect(store.snapshot, durableSnapshot);
      expect(await managedCopy.exists(), isTrue);
      expect(await fixture.galleryOriginal.exists(), isTrue);
    },
  );

  test('clear waits for an in-flight picker drain before deleting', () async {
    final fixture = await _ImageFixture.create('clear-during-drain');
    addTearDown(fixture.dispose);
    final store = _BlockingFirstSaveStore();
    final incoming = InMemoryIncomingShareService()
      ..add(fixture.share('clear-during-drain'));
    final controller = AppController(
      incoming,
      const BaselineContentAnalysisService(),
      store,
    );
    addTearDown(controller.dispose);

    final initializing = controller.initialize();
    await store.firstSaveStarted.future;
    final clearing = controller.clearAllUserCaptures();
    store.releaseFirstSave.complete();

    await initializing;
    expect(await clearing, isTrue);
    expect(controller.userCaptureCount, 0);
    expect(AppSnapshotCodec.decode(store.snapshot!), isEmpty);
    expect(await incoming.drainPending(), isEmpty);
  });
}

final class _ImageFixture {
  const _ImageFixture(this.root, this.galleryOriginal);

  static Future<_ImageFixture> create(String name) async {
    final root = await Directory.systemTemp.createTemp('trun-on-$name-');
    final incoming = Directory(
      '${root.path}${Platform.pathSeparator}incoming_share_attachments',
    );
    await incoming.create();
    final original = File(
      '${incoming.path}${Platform.pathSeparator}gallery-original.jpg',
    );
    await original.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9], flush: true);
    return _ImageFixture(root, original);
  }

  final Directory root;
  final File galleryOriginal;

  IncomingShare share(String id) => IncomingShare(
    id: id,
    receivedAt: DateTime.utc(2026, 9, 6),
    sharedText: '',
    discoveredUrl: null,
    mimeType: 'image/jpeg',
    shareKind: ShareKind.image,
    sourceDeletionAvailable: true,
    attachments: [
      IncomingAttachment(
        id: 'attachment-$id',
        filePath: galleryOriginal.path,
        mimeType: 'image/jpeg',
        byteSize: 4,
        sha256: List.filled(64, 'b').join(),
        width: 1,
        height: 1,
      ),
    ],
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
    if (failWrites) {
      throw StateError('simulated save failure');
    }
    return _delegate.save(captures, tagSenses: tagSenses);
  }
}

final class _BlockingFirstSaveStore implements AppSnapshotStore {
  final _delegate = InMemoryAppSnapshotStore();
  final firstSaveStarted = Completer<void>();
  final releaseFirstSave = Completer<void>();
  var _isFirstSave = true;

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
  }) async {
    if (_isFirstSave) {
      _isFirstSave = false;
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
    await _delegate.save(captures, tagSenses: tagSenses);
  }
}
