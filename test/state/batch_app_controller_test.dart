import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/batch_content_analysis_service.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/remote_content_analysis_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/data/tag_sense_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test(
    '75 images get durable distinct receipts without waiting for results',
    () async {
      final store = InMemoryAppSnapshotStore();
      final batch = _BatchService(
        onSubmit: (id) async {
          expect(
            (await store.load()).any((item) => item.batchRequestId == id),
            isTrue,
          );
        },
      );
      final inbox = InMemoryIncomingShareService();
      for (var i = 0; i < 75; i++) {
        inbox.add(_image(i));
      }
      final controller = _controller(inbox, store, batch);
      addTearDown(controller.dispose);
      expect(controller.selectedAnalysisMode, CaptureAnalysisMode.batch);
      await controller.initialize();
      await _until(() => batch.submitted.length == 75 && batch.active == 0);
      expect(batch.submitted.toSet(), hasLength(75));
      expect(batch.maximumActive, lessThanOrEqualTo(10));
      expect(controller.pendingBatchCount, 75);
      expect((await inbox.drainPending()), isEmpty);
      expect(
        (await store.load()).every(
          (item) => item.analysisMode == CaptureAnalysisMode.batch,
        ),
        isTrue,
      );
    },
  );

  test('restored accepted tasks poll without another submission', () async {
    final store = InMemoryAppSnapshotStore();
    final batch = _BatchService();
    final first = _controller(
      InMemoryIncomingShareService()..add(_image(0)),
      store,
      batch,
    );
    await first.initialize();
    await _until(() => batch.submitted.length == 1 && batch.active == 0);
    await first.refreshBatchAnalysis();
    final requestId = batch.submitted.single;
    first.dispose();
    final restored = _controller(InMemoryIncomingShareService(), store, batch);
    addTearDown(restored.dispose);
    await restored.initialize();
    await restored.refreshBatchAnalysis();
    expect(batch.submitted, [requestId]);
    expect(restored.pendingBatchCount, 1);
    restored.retryAnalysis('capture-batch-0');
    await Future<void>.delayed(Duration.zero);
    expect(batch.submitted, [requestId]);
  });

  test(
    'ambiguous upload resolves by receipt without an instant fallback',
    () async {
      final batch = _BatchService()..loseUploadResponse = true;
      final controller = _controller(
        InMemoryIncomingShareService()..add(_image(0)),
        InMemoryAppSnapshotStore(),
        batch,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _until(() => batch.submitted.isNotEmpty && batch.active == 0);
      await controller.refreshBatchAnalysis();
      expect(batch.submitted, hasLength(1));
      expect(
        controller.captureById('capture-batch-0')!.batchStatus,
        'in_progress',
      );
      expect(controller.pendingBatchCount, 1);
    },
  );

  test('missing accepted receipt is held instead of recreated', () async {
    final batch = _BatchService();
    final controller = _controller(
      InMemoryIncomingShareService()..add(_image(0)),
      InMemoryAppSnapshotStore(),
      batch,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await _until(() => batch.submitted.isNotEmpty && batch.active == 0);
    batch.status = 'missing';
    await controller.refreshBatchAnalysis();
    expect(batch.submitted, hasLength(1));
    expect(
      controller.captureById('capture-batch-0')!.batchStatus,
      'submission_unknown',
    );
  });

  test(
    'out-of-order completion maps to the correct capture and survives restart',
    () async {
      final batch = _BatchService();
      final store = InMemoryAppSnapshotStore();
      final controller = _controller(
        InMemoryIncomingShareService()
          ..add(_image(0))
          ..add(_image(1)),
        store,
        batch,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _until(() => batch.submitted.length == 2 && batch.active == 0);
      batch.status = 'completed';
      await controller.refreshBatchAnalysis();
      for (var i = 0; i < 2; i++) {
        final capture = controller.captureById('capture-batch-$i')!;
        expect(capture.status, CaptureStatus.needsReview);
        expect(
          capture.analysis!.structuredContent!.title.value,
          capture.batchRequestId,
        );
      }
      expect(
        (await store.load()).every((item) => item.batchStatus == 'completed'),
        isTrue,
      );
    },
  );

  test(
    'expired job becomes retryable failure and explicit retry uses fresh receipt',
    () async {
      final batch = _BatchService();
      final controller = _controller(
        InMemoryIncomingShareService()..add(_image(0)),
        InMemoryAppSnapshotStore(),
        batch,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _until(() => batch.submitted.isNotEmpty && batch.active == 0);
      batch.status = 'expired';
      await controller.refreshBatchAnalysis();
      expect(
        controller.captureById('capture-batch-0')!.analysis!.failureCode,
        'batch_expired',
      );
      controller.retryAnalysis('capture-batch-0');
      await _until(() => batch.submitted.length == 2 && batch.active == 0);
      expect(batch.submitted.toSet(), hasLength(2));
    },
  );

  test('deleted task is not resurrected by an in-flight result', () async {
    final batch = _BatchService();
    final controller = _controller(
      InMemoryIncomingShareService()..add(_image(0)),
      InMemoryAppSnapshotStore(),
      batch,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await _until(() => batch.submitted.isNotEmpty && batch.active == 0);
    batch.status = 'completed';
    batch.pollGate = Completer<void>();
    final pending = controller.refreshBatchAnalysis();
    await controller.deleteCapture('capture-batch-0');
    batch.pollGate!.complete();
    await pending;
    expect(controller.captureById('capture-batch-0'), isNull);
  });

  test('failed durable write never submits a paid task', () async {
    final batch = _BatchService();
    final controller = _controller(
      InMemoryIncomingShareService()..add(_image(0)),
      _FailingStore(),
      batch,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(batch.submitted, isEmpty);
  });

  testWidgets('transient pre-upload save failure retries the same durable task', (
    tester,
  ) async {
    final store = _ControlledStore(
      beforeSave: (attempt) async {
        if (attempt == 2) throw StateError('temporary disk failure');
      },
    );
    final batch = _BatchService()..status = 'missing';
    final controller = _controller(
      InMemoryIncomingShareService()..add(_image(0)),
      store,
      batch,
    );
    try {
      await controller.initialize();
      await tester.pump();
      final requestId = controller.captureById('capture-batch-0')!.batchRequestId;
      expect(store.saveAttempts, 2);
      expect(batch.submitted, isEmpty);
      expect((await store.load()).single.batchRequestId, requestId);

      // No user interaction or restart: the scheduled status check first confirms
      // that no server task exists, then retries the original durable identity.
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(batch.submitted, [requestId]);
      expect((await store.load()).single.batchStatus, 'queued');
    } finally {
      controller.dispose();
    }
  });

  test(
    'deletion during pre-upload persistence prevents a new submission',
    () async {
      final saveGate = Completer<void>();
      final store = _ControlledStore(
        beforeSave: (attempt) async {
          if (attempt == 2) await saveGate.future;
        },
      );
      final batch = _BatchService();
      final controller = _controller(
        InMemoryIncomingShareService()..add(_image(0)),
        store,
        batch,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _until(() => store.saveAttempts == 2);
      final deletion = controller.deleteCapture('capture-batch-0');
      expect(controller.captureById('capture-batch-0'), isNull);
      saveGate.complete();
      expect(await deletion, isTrue);
      expect(batch.submitted, isEmpty);
      expect(await store.load(), isEmpty);
    },
  );
}

AppController _controller(
  IncomingShareService inbox,
  AppSnapshotStore store,
  _BatchService batch,
) => AppController(
  inbox,
  const BaselineContentAnalysisService(),
  store,
  null,
  const NoPlaceEnrichmentService(),
  const NoTagMergeService(),
  const NoTagSenseService(),
  null,
  batch,
);

IncomingShare _image(int i) => IncomingShare(
  id: 'batch-$i',
  receivedAt: DateTime(2026, 9, 6),
  sharedText: '',
  discoveredUrl: null,
  mimeType: 'image/png',
  shareKind: ShareKind.image,
  attachments: [
    IncomingAttachment(
      id: 'image-$i',
      filePath: '/virtual/image-$i.png',
      mimeType: 'image/png',
      byteSize: 3,
      width: 1,
      height: 1,
      sha256: i.toRadixString(16).padLeft(64, '0'),
    ),
  ],
);

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 400; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (predicate()) return;
  }
  fail('Controller did not settle');
}

final class _BatchService implements BatchContentAnalysisService {
  _BatchService({this.onSubmit});
  final Future<void> Function(String)? onSubmit;
  final submitted = <String>[];
  String status = 'in_progress';
  bool loseUploadResponse = false;
  int active = 0;
  int maximumActive = 0;
  Completer<void>? pollGate;

  @override
  Future<BatchAnalysisResponse> submit(
    CaptureRecord capture, {
    required String requestId,
  }) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await onSubmit?.call(requestId);
      submitted.add(requestId);
      if (loseUploadResponse) {
        throw const AnalysisServiceException('analysis_timed_out');
      }
      return BatchAnalysisResponse(requestId: requestId, status: 'queued');
    } finally {
      active--;
    }
  }

  @override
  Future<List<BatchAnalysisResponse>> poll(List<String> requestIds) async {
    await pollGate?.future;
    return [
      for (final id in requestIds.reversed)
        BatchAnalysisResponse(
          requestId: id,
          status: status,
          result: status != 'completed'
              ? null
              : StructuredContentAnalysis(
                  schemaVersion: '2.1',
                  model: 'gpt-5.6-luna',
                  domain: ContentDomain.food,
                  contentKind: ContentKind.recipe,
                  tags: const [],
                  completeness: StructuredCompleteness.complete,
                  title: StructuredTitle(
                    value: id,
                    status: ObservedStatus.observed,
                    confidence: 1,
                    evidenceIds: const [],
                  ),
                  place: null,
                  summary: '테스트',
                  evidence: const [],
                  ingredientGroups: const [],
                  steps: const [],
                  facts: const [],
                  conflicts: const [],
                  warnings: const [],
                ),
        ),
    ];
  }
}

final class _FailingStore implements AppSnapshotStore {
  @override
  Future<List<PersistedCapture>> load() async => [];
  @override
  Future<Map<String, List<String>>> loadTagSenses() async => {};
  @override
  Future<void> save(
    List<PersistedCapture> captures, {
    Map<String, List<String>> tagSenses = const {},
  }) async {
    throw StateError('disk unavailable');
  }
}

final class _ControlledStore implements AppSnapshotStore {
  _ControlledStore({required this.beforeSave});

  final Future<void> Function(int attempt) beforeSave;
  final _delegate = InMemoryAppSnapshotStore();
  var saveAttempts = 0;

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
    await beforeSave(++saveAttempts);
    await _delegate.save(captures, tagSenses: tagSenses);
  }
}
