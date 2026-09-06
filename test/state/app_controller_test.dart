import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  late InMemoryIncomingShareService service;
  late AppController controller;

  setUp(() {
    service = InMemoryIncomingShareService();
    controller = AppController(service);
  });

  tearDown(() {
    controller.dispose();
  });

  test('keeps duplicate transport delivery idempotent', () async {
    final before = controller.captures.length;
    final share = IncomingShare(
      id: 'same-transport-id',
      receivedAt: DateTime(2026, 7, 31),
      sharedText: '리프온 카밍 앰플 40ml가 촉촉하다고 했어요.',
      discoveredUrl: null,
    );
    service
      ..add(share)
      ..add(share);

    await controller.initialize();

    expect(controller.captures, hasLength(before + 1));
    expect(
      controller.captures
          .where(
            (capture) => capture.raw.transportEventId == 'same-transport-id',
          )
          .length,
      1,
    );
  });

  test('announces an incoming capture and resets the content filter', () async {
    await controller.initialize();
    controller.setFilter(CaptureFilter.organized);
    final captureAdded = controller.incomingCaptureAdded.first;

    service.add(
      IncomingShare(
        id: 'share-opened-screenshot',
        receivedAt: DateTime(2026, 7, 31),
        sharedText: '스크린샷에서 바로 가져온 콘텐츠',
        discoveredUrl: null,
      ),
    );

    final batch = await captureAdded;
    final captureId = batch.primaryCaptureId;

    expect(controller.filter, CaptureFilter.all);
    expect(
      controller.captureById(captureId)?.raw.transportEventId,
      'share-opened-screenshot',
    );
  });

  test('announces one UI event for one multi-capture drain', () async {
    service
      ..add(
        IncomingShare(
          id: 'picker-batch-first',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '첫 번째 사진',
          discoveredUrl: null,
        ),
      )
      ..add(
        IncomingShare(
          id: 'picker-batch-second',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '두 번째 사진',
          discoveredUrl: null,
        ),
      );
    final announcements = <IncomingCaptureBatch>[];
    final subscription = controller.incomingCaptureAdded.listen(
      announcements.add,
    );
    addTearDown(subscription.cancel);

    await controller.initialize();

    expect(announcements, hasLength(1));
    final announcement = announcements.single;
    expect(announcement.captureIds, hasLength(2));
    expect(
      announcement.captureIds
          .map(controller.captureById)
          .whereType<CaptureRecord>()
          .map((capture) => capture.raw.transportEventId),
      ['picker-batch-first', 'picker-batch-second'],
    );
    expect(
      controller
          .captureById(announcement.primaryCaptureId)
          ?.raw
          .transportEventId,
      'picker-batch-second',
    );
  });

  test(
    'user confirmation merges another source into an exact product',
    () async {
      final before = controller
          .groupById('group-baumlab-pore-balance')!
          .sourceCount;
      final captureId = controller.addManualInput(
        '바움랩 포어 밸런스 세럼 30ml. 모공이 신경 쓰일 때 가볍다고 소개했어요.',
      );

      await controller.confirmAndOrganize(
        captureId: captureId,
        identity: const ConfirmedProductIdentity(
          brand: '바움랩',
          name: '포어 밸런스 세럼',
          category: '세럼',
          amount: '30mL',
        ),
        tags: const [
          ContentTag(value: '쇼핑', source: TagSource.user),
          ContentTag(value: '스킨케어', source: TagSource.user),
        ],
      );

      expect(
        controller.captureById(captureId)?.status,
        CaptureStatus.organized,
      );
      expect(
        controller.groupById('group-baumlab-pore-balance')?.sourceCount,
        before + 1,
      );
      // Everything filed under one product shares one set of tags.
      expect(
        controller
            .capturesForGroup('group-baumlab-pore-balance')
            .every((capture) => capture.hasTag('쇼핑') && capture.hasTag('스킨케어')),
        isTrue,
      );
    },
  );

  test(
    'an unresolved native share remains visible and is acknowledged',
    () async {
      service.add(
        IncomingShare(
          id: 'share-unresolved',
          receivedAt: DateTime(2026, 7, 31),
          sharedText: 'https://example.com/unknown',
          discoveredUrl: 'https://example.com/unknown',
        ),
      );
      await controller.initialize();

      final capture = controller.captures.firstWhere(
        (item) => item.raw.transportEventId == 'share-unresolved',
      );
      await controller.keepUnresolved(capture.raw.id);

      expect(controller.captureById(capture.raw.id), isNotNull);
      expect(
        controller.captureById(capture.raw.id)?.review?.resolution,
        ReviewResolution.unresolved,
      );
      expect(await service.drainPending(), isEmpty);
    },
  );

  test(
    'acknowledges a native share after durable save before review',
    () async {
      final snapshotStore = InMemoryAppSnapshotStore();
      final nativeService = InMemoryIncomingShareService()
        ..add(
          IncomingShare(
            id: 'share-durable-before-review',
            receivedAt: DateTime(2026, 7, 31),
            sharedText: '저장 후 확인할 콘텐츠',
            discoveredUrl: null,
          ),
        );
      final durableController = AppController(
        nativeService,
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      addTearDown(durableController.dispose);

      await durableController.initialize();

      final capture = durableController.captures.firstWhere(
        (item) => item.raw.transportEventId == 'share-durable-before-review',
      );
      expect(capture.review, isNull);
      expect(snapshotStore.snapshot, contains('share-durable-before-review'));
      expect(await nativeService.drainPending(), isEmpty);
    },
  );

  test('restores a confirmed organization after app restart', () async {
    final snapshotStore = InMemoryAppSnapshotStore();
    final firstService = InMemoryIncomingShareService();
    final firstController = AppController(
      firstService,
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    await firstController.initialize();
    final captureId = firstController.addManualInput(
      '오로라랩 워터리 선 세럼 50ml. 가볍고 촉촉했어요.',
    );
    await firstController.confirmAndOrganize(
      captureId: captureId,
      identity: const ConfirmedProductIdentity(
        brand: '오로라랩',
        name: '워터리 선 세럼',
        category: '선케어',
        amount: '50mL',
      ),
      tags: const [
        ContentTag(value: '쇼핑', source: TagSource.user),
        ContentTag(value: '스킨케어', source: TagSource.user),
      ],
    );
    final firstCapture = firstController.captureById(captureId)!;
    await firstController.updateGroupTags(firstCapture.groupId!, const [
      ContentTag(value: '쇼핑', source: TagSource.user),
      ContentTag(value: '선케어', source: TagSource.user),
    ]);
    firstController.dispose();

    final secondService = InMemoryIncomingShareService();
    final secondController = AppController(
      secondService,
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    addTearDown(secondController.dispose);
    await secondController.initialize();

    final restored = secondController.captureById(captureId);
    expect(restored?.status, CaptureStatus.organized);
    expect(restored?.review?.confirmedIdentity?.brand, '오로라랩');
    expect(restored?.contentTags.map((tag) => tag.value), ['쇼핑', '선케어']);
    expect(
      secondController.tagsForGroup(restored!.groupId!).map((t) => t.value),
      ['쇼핑', '선케어'],
    );
    expect(secondController.groupById(restored.groupId!)?.sourceCount, 1);
  });

  test("keeps the reader's own tags when analysis is retried", () async {
    final captureId = controller.addManualInput(
      '바움랩 포어 밸런스 세럼 30ml. 촉촉하다고 소개했어요.',
    );
    await controller.updateCaptureTags(captureId, const [
      ContentTag(value: '집중 보습', source: TagSource.user),
    ]);

    controller.retryAnalysis(captureId);

    final retried = controller.captureById(captureId)!;
    expect(retried.tagOverride?.single.value, '집중 보습');
    expect(retried.contentTags.single.source, TagSource.user);
  });

  test(
    'deletes a capture from the durable snapshot and restored state',
    () async {
      final snapshotStore = InMemoryAppSnapshotStore();
      final firstController = AppController(
        InMemoryIncomingShareService(),
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      await firstController.initialize();
      final captureId = firstController.addManualInput(
        '데이라이트 에어리 선 플루이드 50ml. 가볍게 발려요.',
      );
      await firstController.updateCaptureTags(captureId, const [
        ContentTag(value: '선케어', source: TagSource.user),
      ]);

      expect(await firstController.deleteCapture(captureId), isTrue);
      expect(firstController.captureById(captureId), isNull);
      expect(
        AppSnapshotCodec.decode(snapshotStore.snapshot!).where(
          (capture) => 'capture-${capture.transportEventId}' == captureId,
        ),
        isEmpty,
      );
      expect(await firstController.deleteCapture(captureId), isFalse);
      firstController.dispose();

      final restoredController = AppController(
        InMemoryIncomingShareService(),
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      addTearDown(restoredController.dispose);
      await restoredController.initialize();

      expect(restoredController.captureById(captureId), isNull);
    },
  );

  test(
    'quick organizes legacy content and rebuilds product groups on delete',
    () async {
      final snapshotStore = InMemoryAppSnapshotStore();
      final quickController = AppController(
        InMemoryIncomingShareService(),
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      addTearDown(quickController.dispose);
      await quickController.initialize();
      const existingGroupId = 'group-baumlab-pore-balance';
      final sourceCountBefore = quickController
          .groupById(existingGroupId)!
          .sourceCount;
      final captureId = quickController.addManualInput(
        '바움랩 포어 밸런스 세럼 30ml. 모공이 신경 쓰일 때 가벼워요.',
      );

      expect(quickController.canQuickOrganize(captureId), isTrue);
      expect(await quickController.quickOrganize(captureId), isTrue);
      expect(
        quickController.captureById(captureId)?.status,
        CaptureStatus.organized,
      );
      expect(quickController.captureById(captureId)?.groupId, existingGroupId);
      expect(
        quickController.groupById(existingGroupId)?.sourceCount,
        sourceCountBefore + 1,
      );
      expect(
        AppSnapshotCodec.decode(snapshotStore.snapshot!).single.status,
        CaptureStatus.organized,
      );

      expect(await quickController.deleteCapture(captureId), isTrue);
      final rebuilt = quickController.groupById(existingGroupId)!;
      expect(rebuilt.sourceCount, sourceCountBefore);
      expect(rebuilt.sourceCaptureIds, isNot(contains(captureId)));
      expect(
        rebuilt.statements.where(
          (statement) => statement.captureId == captureId,
        ),
        isEmpty,
      );

      final soleSourceId = quickController.addManualInput(
        '데이라이트 에어리 선 플루이드 50ml. 백탁이 적고 가벼워요.',
      );
      expect(await quickController.quickOrganize(soleSourceId), isTrue);
      final soleGroupId = quickController.captureById(soleSourceId)!.groupId!;
      expect(quickController.groupById(soleGroupId)?.sourceCaptureIds, [
        soleSourceId,
      ]);

      expect(await quickController.deleteCapture(soleSourceId), isTrue);
      expect(quickController.groupById(soleGroupId), isNull);
    },
  );

  test(
    'quick organizes structured content into the organized library',
    () async {
      final snapshotStore = InMemoryAppSnapshotStore();
      final structuredController = AppController(
        InMemoryIncomingShareService(),
        const _StructuredAnalysisService(),
        snapshotStore,
      );
      addTearDown(structuredController.dispose);
      await structuredController.initialize();
      final captureId = structuredController.addManualInput('두부조림 레시피 이미지');

      expect(structuredController.canQuickOrganize(captureId), isTrue);
      expect(await structuredController.quickOrganize(captureId), isTrue);

      final organized = structuredController.captureById(captureId)!;
      expect(organized.status, CaptureStatus.organized);
      expect(organized.contentTags.map((tag) => tag.value), ['밑반찬']);
      expect(
        structuredController.organizedStructuredCaptures.map(
          (capture) => capture.raw.id,
        ),
        contains(captureId),
      );
      expect(
        AppSnapshotCodec.decode(snapshotStore.snapshot!).single.status,
        CaptureStatus.organized,
      );
    },
  );

  test(
    'rolls back capture and group deletion when durable save fails',
    () async {
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = originalDebugPrint);
      final snapshotStore = _ToggleAppSnapshotStore();
      final rollbackController = AppController(
        InMemoryIncomingShareService(),
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      addTearDown(rollbackController.dispose);
      await rollbackController.initialize();
      final captureId = rollbackController.addManualInput(
        '데이라이트 에어리 선 플루이드 50ml. 가볍게 발려요.',
      );
      expect(await rollbackController.quickOrganize(captureId), isTrue);
      final groupId = rollbackController.captureById(captureId)!.groupId!;
      snapshotStore.failWrites = true;

      expect(await rollbackController.deleteCapture(captureId), isFalse);
      expect(rollbackController.captureById(captureId), isNotNull);
      expect(
        rollbackController.groupById(groupId)?.sourceCaptureIds,
        contains(captureId),
      );
    },
  );

  test(
    'acknowledges a durably saved pending share recovered before review',
    () async {
      final snapshotStore = InMemoryAppSnapshotStore();
      final share = IncomingShare(
        id: 'share-crash-gap',
        receivedAt: DateTime(2026, 7, 31),
        sharedText: '오로라랩 워터리 선 세럼 50ml. 가볍다고 했어요.',
        discoveredUrl: null,
      );
      final firstService = InMemoryIncomingShareService()..add(share);
      final firstController = AppController(
        firstService,
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      await firstController.initialize();
      final originalCapture = firstController.captures.firstWhere(
        (item) => item.raw.transportEventId == share.id,
      );
      expect(originalCapture.review, isNull);
      firstController.dispose();

      final recoveredPendingService = InMemoryIncomingShareService()
        ..add(share);
      final restoredController = AppController(
        recoveredPendingService,
        const BaselineContentAnalysisService(),
        snapshotStore,
      );
      addTearDown(restoredController.dispose);
      await restoredController.initialize();

      expect(await recoveredPendingService.drainPending(), isEmpty);
      expect(
        restoredController.captures.where(
          (item) => item.raw.transportEventId == share.id,
        ),
        hasLength(1),
      );
      expect(
        restoredController.captures
            .firstWhere((item) => item.raw.transportEventId == share.id)
            .review,
        isNull,
      );
    },
  );

  test('does not acknowledge a native share when durable save fails', () async {
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    final nativeService = InMemoryIncomingShareService();
    final failingController = AppController(
      nativeService,
      const BaselineContentAnalysisService(),
      const _FailingAppSnapshotStore(),
    );
    addTearDown(failingController.dispose);
    nativeService.add(
      IncomingShare(
        id: 'share-save-failure',
        receivedAt: DateTime(2026, 7, 31),
        sharedText: 'https://example.com/still-pending',
        discoveredUrl: 'https://example.com/still-pending',
      ),
    );
    await failingController.initialize();

    expect(
      failingController.captures.where(
        (item) => item.raw.transportEventId == 'share-save-failure',
      ),
      isEmpty,
    );
    expect(await nativeService.drainPending(), hasLength(1));
  });

  test('retains an incoming image outside the native ack directory', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'ori-image-retention-',
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
      '${incomingDirectory.path}${Platform.pathSeparator}source.jpg',
    );
    await source.writeAsBytes([0xff, 0xd8, 0xff], flush: true);

    final snapshotStore = InMemoryAppSnapshotStore();
    final imageService = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'share-image',
          receivedAt: DateTime(2026, 7, 31),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          sourceDeletionAvailable: true,
          attachments: [
            IncomingAttachment(
              id: 'attachment-1',
              filePath: source.path,
              mimeType: 'image/jpeg',
              byteSize: 3,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'a').join(),
            ),
          ],
        ),
      );
    final imageController = AppController(
      imageService,
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    addTearDown(imageController.dispose);

    await imageController.initialize();

    final capture = imageController.captures.firstWhere(
      (item) => item.raw.transportEventId == 'share-image',
    );
    final retainedPath = capture.raw.attachments.single.filePath;
    expect(retainedPath, contains('ori_library_attachments'));
    expect(retainedPath, isNot(source.path));
    expect(await File(retainedPath).readAsBytes(), [0xff, 0xd8, 0xff]);
    expect(snapshotStore.snapshot, contains('ori_library_attachments'));
    expect(await imageService.drainPending(), isEmpty);
    expect(imageController.canDeleteSharedSource(capture.raw.id), isTrue);

    await imageController.keepSharedSource(capture.raw.id);
    expect(imageController.canDeleteSharedSource(capture.raw.id), isFalse);
  });

  test(
    'deletes an unreferenced retained image but keeps shared and source originals',
    () async {
      final temporaryRoot = await Directory.systemTemp.createTemp(
        'ori-image-deletion-',
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
      final firstSource = File(
        '${incomingDirectory.path}${Platform.pathSeparator}first.jpg',
      );
      final secondSource = File(
        '${incomingDirectory.path}${Platform.pathSeparator}second.jpg',
      );
      const imageBytes = [0xff, 0xd8, 0xff];
      await firstSource.writeAsBytes(imageBytes, flush: true);
      await secondSource.writeAsBytes(imageBytes, flush: true);
      final sha256 = List.filled(64, 'c').join();
      final imageService = _RecordingIncomingShareService()
        ..add(
          IncomingShare(
            id: 'share-image-first',
            receivedAt: DateTime(2026, 8, 6),
            sharedText: '',
            discoveredUrl: null,
            mimeType: 'image/jpeg',
            shareKind: ShareKind.image,
            sourceDeletionAvailable: true,
            attachments: [
              IncomingAttachment(
                id: 'attachment-first',
                filePath: firstSource.path,
                mimeType: 'image/jpeg',
                byteSize: imageBytes.length,
                width: 1,
                height: 1,
                sha256: sha256,
              ),
            ],
          ),
        )
        ..add(
          IncomingShare(
            id: 'share-image-second',
            receivedAt: DateTime(2026, 8, 6),
            sharedText: '',
            discoveredUrl: null,
            mimeType: 'image/jpeg',
            shareKind: ShareKind.image,
            sourceDeletionAvailable: true,
            attachments: [
              IncomingAttachment(
                id: 'attachment-second',
                filePath: secondSource.path,
                mimeType: 'image/jpeg',
                byteSize: imageBytes.length,
                width: 1,
                height: 1,
                sha256: sha256,
              ),
            ],
          ),
        );
      final imageController = AppController(
        imageService,
        const BaselineContentAnalysisService(),
        InMemoryAppSnapshotStore(),
      );
      addTearDown(imageController.dispose);

      await imageController.initialize();

      final firstCapture = imageController.captures.firstWhere(
        (capture) => capture.raw.transportEventId == 'share-image-first',
      );
      final secondCapture = imageController.captures.firstWhere(
        (capture) => capture.raw.transportEventId == 'share-image-second',
      );
      final retainedPath = firstCapture.raw.attachments.single.filePath;
      expect(secondCapture.raw.attachments.single.filePath, retainedPath);

      expect(await imageController.deleteCapture(firstCapture.raw.id), isTrue);
      expect(await File(retainedPath).exists(), isTrue);
      expect(await firstSource.exists(), isTrue);
      expect(await secondSource.exists(), isTrue);

      expect(await imageController.deleteCapture(secondCapture.raw.id), isTrue);
      expect(await File(retainedPath).exists(), isFalse);
      expect(await firstSource.exists(), isTrue);
      expect(await secondSource.exists(), isTrue);
      expect(
        imageService.keptTransportIds,
        containsAll(['share-image-first', 'share-image-second']),
      );
      expect(imageService.deletedTransportIds, isEmpty);
    },
  );

  test('keeps a native image pending when retained size is invalid', () async {
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'ori-image-invalid-retention-',
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
      '${incomingDirectory.path}${Platform.pathSeparator}source.jpg',
    );
    await source.writeAsBytes([0xff, 0xd8, 0xff], flush: true);
    final imageService = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'share-invalid-image-size',
          receivedAt: DateTime(2026, 7, 31),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-invalid-size',
              filePath: source.path,
              mimeType: 'image/jpeg',
              byteSize: 4,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'b').join(),
            ),
          ],
        ),
      );
    final imageController = AppController(
      imageService,
      const BaselineContentAnalysisService(),
      InMemoryAppSnapshotStore(),
    );
    addTearDown(imageController.dispose);

    await imageController.initialize();

    expect(
      imageController.captures.where(
        (capture) => capture.raw.transportEventId == 'share-invalid-image-size',
      ),
      isEmpty,
    );
    expect(await imageService.drainPending(), hasLength(1));
  });

  test('one invalid image does not block the rest of a picker batch', () async {
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'ori-image-batch-retention-',
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
    final invalidSource = File(
      '${incomingDirectory.path}${Platform.pathSeparator}invalid.jpg',
    );
    final validSource = File(
      '${incomingDirectory.path}${Platform.pathSeparator}valid.jpg',
    );
    await invalidSource.writeAsBytes([0xff, 0xd8, 0xff], flush: true);
    await validSource.writeAsBytes([0xff, 0xd8, 0xff], flush: true);

    final snapshotStore = InMemoryAppSnapshotStore();
    final imageService = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'share-batch-invalid',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-batch-invalid',
              filePath: invalidSource.path,
              mimeType: 'image/jpeg',
              byteSize: 4,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'd').join(),
            ),
          ],
        ),
      )
      ..add(
        IncomingShare(
          id: 'share-batch-valid',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-batch-valid',
              filePath: validSource.path,
              mimeType: 'image/jpeg',
              byteSize: 3,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'e').join(),
            ),
          ],
        ),
      );
    final imageController = AppController(
      imageService,
      const BaselineContentAnalysisService(),
      snapshotStore,
    );
    addTearDown(imageController.dispose);

    await imageController.initialize();

    expect(
      imageController.captures.where(
        (capture) => capture.raw.transportEventId == 'share-batch-invalid',
      ),
      isEmpty,
    );
    expect(
      imageController.captures.where(
        (capture) => capture.raw.transportEventId == 'share-batch-valid',
      ),
      hasLength(1),
    );
    expect((await imageService.drainPending()).map((share) => share.id), [
      'share-batch-invalid',
    ]);
    expect(snapshotStore.snapshot, contains('share-batch-valid'));
    expect(snapshotStore.snapshot, isNot(contains('share-batch-invalid')));
  });

  test('acknowledge failure does not leave a saved image analyzing', () async {
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'ori-image-ack-failure-',
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
    final source = File('${incomingDirectory.path}/source.jpg');
    await source.writeAsBytes([0xff, 0xd8, 0xff], flush: true);
    final imageService = _RecordingIncomingShareService()
      ..failAcknowledge = true
      ..add(
        IncomingShare(
          id: 'share-ack-failure',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '',
          discoveredUrl: null,
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-ack-failure',
              filePath: source.path,
              mimeType: 'image/jpeg',
              byteSize: 3,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'f').join(),
            ),
          ],
        ),
      );
    final imageController = AppController(
      imageService,
      const _StructuredAnalysisService(),
      InMemoryAppSnapshotStore(),
    );
    addTearDown(imageController.dispose);

    await imageController.initialize();
    await _waitUntil(() {
      final capture = imageController.captures.where(
        (item) => item.raw.transportEventId == 'share-ack-failure',
      );
      return capture.isNotEmpty &&
          capture.single.status != CaptureStatus.analyzing;
    });

    final capture = imageController.captures.firstWhere(
      (item) => item.raw.transportEventId == 'share-ack-failure',
    );
    expect(capture.status, CaptureStatus.needsReview);
    expect(capture.analysis?.structuredContent, isNotNull);
    expect(await imageService.drainPending(), hasLength(1));

    expect(await imageController.clearAllUserCaptures(), isFalse);
    expect(imageController.captureById(capture.raw.id), isNotNull);
    expect(await imageService.drainPending(), hasLength(1));

    imageService.failAcknowledge = false;
    expect(await imageController.clearAllUserCaptures(), isTrue);
    expect(imageController.userCaptureCount, 0);
    expect(await imageService.drainPending(), isEmpty);
  });

  test(
    'a blocked analysis does not block the next pending-share drain',
    () async {
      final temporaryRoot = await Directory.systemTemp.createTemp(
        'ori-image-analysis-queue-',
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
      final firstSource = File('${incomingDirectory.path}/first.jpg');
      final secondSource = File('${incomingDirectory.path}/second.jpg');
      await firstSource.writeAsBytes([0xff, 0xd8, 0xff], flush: true);
      await secondSource.writeAsBytes([0xff, 0xd8, 0xfe], flush: true);

      IncomingShare imageShare(String id, File source, String hashCharacter) =>
          IncomingShare(
            id: id,
            receivedAt: DateTime(2026, 9, 6),
            sharedText: '',
            discoveredUrl: null,
            mimeType: 'image/jpeg',
            shareKind: ShareKind.image,
            attachments: [
              IncomingAttachment(
                id: 'attachment-$id',
                filePath: source.path,
                mimeType: 'image/jpeg',
                byteSize: 3,
                width: 1,
                height: 1,
                sha256: List.filled(64, hashCharacter).join(),
              ),
            ],
          );

      final imageService = _RecordingIncomingShareService()
        ..add(imageShare('share-queue-first', firstSource, '1'));
      final analysisService = _GateFirstAnalysisService();
      final imageController = AppController(
        imageService,
        analysisService,
        InMemoryAppSnapshotStore(),
      );
      addTearDown(imageController.dispose);

      await imageController.initialize();
      await _waitUntil(() => analysisService.analysisCalls == 1);
      imageService.add(imageShare('share-queue-second', secondSource, '2'));
      await _waitUntil(
        () => imageController.captures.any(
          (capture) =>
              capture.raw.transportEventId == 'share-queue-second' &&
              capture.status != CaptureStatus.analyzing,
        ),
      );

      expect(await imageService.drainPending(), isEmpty);
      expect(
        imageController.captures
            .where(
              (capture) => capture.raw.transportEventId == 'share-queue-second',
            )
            .single
            .status,
        CaptureStatus.needsReview,
      );
      expect(analysisService.analysisCalls, 2);

      analysisService.releaseFirst();
      await _waitUntil(
        () => imageController.captures
            .where((capture) => capture.raw.origin != CaptureOrigin.demo)
            .every((capture) => capture.status != CaptureStatus.analyzing),
      );
      expect(analysisService.analysisCalls, 2);
    },
  );

  test(
    'a 75-image batch is durable and acknowledged before a bounded FIFO analysis pool',
    () async {
      IncomingShare imageShare(int index) => IncomingShare(
        id: 'picker-batch-$index',
        receivedAt: DateTime(2026, 9, 6, 12, 0, index),
        sharedText: '',
        discoveredUrl: null,
        mimeType: 'image/jpeg',
        shareKind: ShareKind.image,
        attachments: [
          IncomingAttachment(
            id: 'picker-attachment-$index',
            filePath: '/virtual-gallery/picker-$index.jpg',
            mimeType: 'image/jpeg',
            byteSize: 3,
            width: 1,
            height: 1,
            sha256: index.toRadixString(16).padLeft(64, '0'),
          ),
        ],
      );

      final imageService = _RecordingIncomingShareService();
      for (var index = 0; index < 75; index += 1) {
        imageService.add(imageShare(index));
      }
      final snapshotStore = InMemoryAppSnapshotStore();
      String? snapshotAtFirstAnalysis;
      var pendingCountAtFirstAnalysis = -1;
      var acknowledgeCallsAtFirstAnalysis = -1;
      final analysisService = _GatedConcurrentAnalysisService(
        onStart: (_) {
          snapshotAtFirstAnalysis ??= snapshotStore.snapshot;
          if (pendingCountAtFirstAnalysis == -1) {
            pendingCountAtFirstAnalysis = imageService.pendingCount;
            acknowledgeCallsAtFirstAnalysis = imageService.acknowledgeCallCount;
          }
        },
      );
      final imageController = AppController(
        imageService,
        analysisService,
        snapshotStore,
      );
      addTearDown(imageController.dispose);
      final announcements = <IncomingCaptureBatch>[];
      final subscription = imageController.incomingCaptureAdded.listen(
        announcements.add,
      );
      addTearDown(subscription.cancel);

      await imageController.initialize();

      expect(analysisService.startedCaptureIds, [
        for (var index = 0; index < 10; index++) 'capture-picker-batch-$index',
      ]);
      expect(analysisService.activeCount, 10);
      expect(
        analysisService.maxActiveCount,
        AppController.maxConcurrentCaptureAnalyses,
      );
      expect(pendingCountAtFirstAnalysis, 0);
      expect(acknowledgeCallsAtFirstAnalysis, 1);
      expect(imageService.acknowledgedTransportIds, hasLength(75));
      final initiallyPersisted = AppSnapshotCodec.decode(
        snapshotAtFirstAnalysis!,
      );
      expect(initiallyPersisted, hasLength(75));
      expect(
        initiallyPersisted.every(
          (capture) => capture.status == CaptureStatus.analyzing,
        ),
        isTrue,
      );
      expect(announcements, hasLength(1));
      expect(announcements.single.captureIds, hasLength(75));

      // Requeueing an already active item must not start a duplicate request.
      imageController.retryAnalysis('capture-picker-batch-0');
      await Future<void>.delayed(Duration.zero);
      expect(
        analysisService.startedCaptureIds.where(
          (id) => id == 'capture-picker-batch-0',
        ),
        hasLength(1),
      );

      // Whichever worker finishes first, the next waiting id starts first.
      analysisService.release('capture-picker-batch-1');
      await _waitUntil(() => analysisService.startedCaptureIds.length == 11);
      expect(analysisService.startedCaptureIds.last, 'capture-picker-batch-10');
      expect(analysisService.activeCount, 10);

      analysisService.releaseAll();
      await _waitUntil(() => imageController.analyzingCount == 0);

      expect(analysisService.startedCaptureIds, hasLength(75));
      expect(analysisService.startedCaptureIds.toSet(), hasLength(75));
      expect(analysisService.maxActiveCount, 10);
      expect(analysisService.activeCount, 0);
      expect(announcements, hasLength(1));
      expect(
        imageController.captures
            .where((capture) => capture.raw.origin != CaptureOrigin.demo)
            .every((capture) => capture.status == CaptureStatus.needsReview),
        isTrue,
      );
      final finallyPersisted = await snapshotStore.load();
      expect(finallyPersisted, hasLength(75));
      expect(
        finallyPersisted.every(
          (capture) => capture.status == CaptureStatus.needsReview,
        ),
        isTrue,
      );
    },
  );

  test(
    'place enrichment is a one-worker FIFO that skips stale work and survives failure',
    () async {
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = originalDebugPrint);
      final imageService = _RecordingIncomingShareService();
      for (var index = 0; index < 6; index += 1) {
        imageService.add(
          IncomingShare(
            id: 'place-batch-$index',
            receivedAt: DateTime(2026, 9, 6, 13, 0, index),
            sharedText: index == 2 ? '장소가 없는 콘텐츠' : '장소 $index',
            discoveredUrl: null,
          ),
        );
      }
      final analysisService = _ImmediatePlaceAnalysisService(
        noPlaceCaptureIds: const {'capture-place-batch-2'},
      );
      final enrichmentService = _GatedPlaceEnrichmentService();
      final imageController = AppController(
        imageService,
        analysisService,
        InMemoryAppSnapshotStore(),
        null,
        enrichmentService,
      );
      addTearDown(imageController.dispose);

      await imageController.initialize();
      await _waitUntil(
        () =>
            imageController.analyzingCount == 0 &&
            enrichmentService.startedNames.length == 1,
      );

      // The optional lookup is blocked, but all six primary analyses have
      // already persisted and released the three analysis workers.
      expect(analysisService.startedCaptureIds, hasLength(6));
      expect(enrichmentService.startedNames, ['장소 0']);
      expect(enrichmentService.activeCount, 1);
      expect(
        enrichmentService.maxActiveCount,
        AppController.maxConcurrentPlaceEnrichments,
      );

      // A retry of the active capture must not enqueue its place twice.
      imageController.retryAnalysis('capture-place-batch-0');
      await _waitUntil(() => analysisService.startedCaptureIds.length == 7);
      await _waitUntil(
        () =>
            imageController.captureById('capture-place-batch-0')?.status !=
            CaptureStatus.analyzing,
      );
      expect(enrichmentService.startedNames, ['장소 0']);

      // The next queued capture is removed before its turn, while capture 2
      // has no place at all. Neither may call the enrichment service.
      expect(
        await imageController.deleteCapture('capture-place-batch-1'),
        isTrue,
      );
      enrichmentService.fail('장소 0');
      await _waitUntil(() => enrichmentService.startedNames.length == 2);
      expect(enrichmentService.startedNames, ['장소 0', '장소 3']);
      expect(enrichmentService.activeCount, 1);

      enrichmentService.releaseAll();
      await _waitUntil(
        () =>
            enrichmentService.startedNames.length == 4 &&
            enrichmentService.activeCount == 0,
      );
      await _waitUntil(
        () =>
            [
              'capture-place-batch-3',
              'capture-place-batch-4',
              'capture-place-batch-5',
            ].every(
              (captureId) => imageController
                  .captureById(captureId)!
                  .contentTags
                  .any((tag) => tag.value == '웹 보강'),
            ),
      );

      expect(enrichmentService.startedNames, ['장소 0', '장소 3', '장소 4', '장소 5']);
      expect(enrichmentService.settledNames, hasLength(4));
      expect(enrichmentService.maxActiveCount, 1);
      expect(imageController.captureById('capture-place-batch-1'), isNull);
      expect(
        imageController
            .captureById('capture-place-batch-2')!
            .contentTags
            .any((tag) => tag.value == '웹 보강'),
        isFalse,
      );
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 400; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for the asynchronous controller operation.');
}

final class _StructuredAnalysisService implements ContentAnalysisService {
  const _StructuredAnalysisService();

  static const _baseline = BaselineContentAnalysisService();
  static const _structured = StructuredContentAnalysis(
    schemaVersion: '2.0',
    model: 'gpt-5.6-luna',
    domain: ContentDomain.food,
    contentKind: ContentKind.recipe,
    tags: [ContentTag(value: '밑반찬')],
    completeness: StructuredCompleteness.complete,
    title: StructuredTitle(
      value: '두부조림',
      status: ObservedStatus.observed,
      confidence: 0.95,
      evidenceIds: [],
    ),
    place: null,
    summary: '간단한 두부조림 레시피',
    evidence: [],
    ingredientGroups: [],
    steps: [],
    facts: [],
    conflicts: [],
    warnings: [],
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
      capture.analysis ?? _analysisFor(capture);

  static AnalysisRun _analysisFor(CaptureRecord capture) => AnalysisRun(
    id: 'analysis-${capture.raw.transportEventId}',
    inputId: capture.raw.id,
    normalizerVersion: capture.normalized.normalizerVersion,
    analyzerVersion: 'test-structured-v1',
    status: AnalysisRunStatus.succeeded,
    completedAt: capture.raw.receivedAt,
    evidence: const [],
    productMentions: const [],
    statements: const [],
    disclosure: DisclosureObservation.unknown,
    structuredContent: _structured,
  );
}

final class _GateFirstAnalysisService implements ContentAnalysisService {
  static const _baseline = BaselineContentAnalysisService();
  final Completer<AnalysisRun> _firstAnalysis = Completer<AnalysisRun>();
  CaptureRecord? _firstCapture;
  var analysisCalls = 0;

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.analyzeShare(share, origin: origin);

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) {
    analysisCalls += 1;
    if (analysisCalls == 1) {
      _firstCapture = capture;
      return _firstAnalysis.future;
    }
    return Future<AnalysisRun>.value(
      _StructuredAnalysisService._analysisFor(capture),
    );
  }

  void releaseFirst() {
    final capture = _firstCapture;
    if (capture != null && !_firstAnalysis.isCompleted) {
      _firstAnalysis.complete(_StructuredAnalysisService._analysisFor(capture));
    }
  }
}

final class _GatedConcurrentAnalysisService implements ContentAnalysisService {
  _GatedConcurrentAnalysisService({this.onStart});

  static const _baseline = BaselineContentAnalysisService();
  final void Function(CaptureRecord capture)? onStart;
  final List<String> startedCaptureIds = [];
  final Map<String, ({CaptureRecord capture, Completer<AnalysisRun> gate})>
  _inFlight = {};
  var activeCount = 0;
  var maxActiveCount = 0;
  var _releaseImmediately = false;

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) {
    startedCaptureIds.add(capture.raw.id);
    activeCount += 1;
    if (activeCount > maxActiveCount) {
      maxActiveCount = activeCount;
    }
    onStart?.call(capture);
    final gate = Completer<AnalysisRun>();
    _inFlight[capture.raw.id] = (capture: capture, gate: gate);
    if (_releaseImmediately) {
      gate.complete(_StructuredAnalysisService._analysisFor(capture));
    }
    return gate.future.whenComplete(() {
      activeCount -= 1;
      _inFlight.remove(capture.raw.id);
    });
  }

  void release(String captureId) {
    final pending = _inFlight[captureId];
    if (pending == null || pending.gate.isCompleted) return;
    pending.gate.complete(
      _StructuredAnalysisService._analysisFor(pending.capture),
    );
  }

  void releaseAll() {
    _releaseImmediately = true;
    for (final captureId in _inFlight.keys.toList(growable: false)) {
      release(captureId);
    }
  }
}

final class _ImmediatePlaceAnalysisService implements ContentAnalysisService {
  _ImmediatePlaceAnalysisService({this.noPlaceCaptureIds = const {}});

  static const _baseline = BaselineContentAnalysisService();
  final Set<String> noPlaceCaptureIds;
  final List<String> startedCaptureIds = [];

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) => _baseline.prepareShare(share, origin: origin);

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) async {
    startedCaptureIds.add(capture.raw.id);
    final suffix = capture.raw.transportEventId.split('-').last;
    final hasPlace = !noPlaceCaptureIds.contains(capture.raw.id);
    final placeName = hasPlace ? '장소 $suffix' : null;
    final structured = StructuredContentAnalysis(
      schemaVersion: '2.0',
      model: 'test-place-model',
      domain: hasPlace ? ContentDomain.food : ContentDomain.unknown,
      contentKind: hasPlace ? ContentKind.place : ContentKind.unknown,
      tags: const [ContentTag(value: '저장')],
      completeness: StructuredCompleteness.complete,
      title: StructuredTitle(
        value: placeName ?? '장소 없음',
        status: ObservedStatus.observed,
        confidence: 0.9,
        evidenceIds: const [],
      ),
      place: hasPlace
          ? StructuredPlace(
              name: placeName,
              address: null,
              searchArea: null,
              category: PlaceCategory.restaurant,
              confidence: 0.9,
              evidenceIds: const [],
            )
          : null,
      summary: '테스트 분석',
      evidence: const [],
      ingredientGroups: const [],
      steps: const [],
      facts: const [],
      conflicts: const [],
      warnings: const [],
    );
    return AnalysisRun(
      id: 'analysis-${capture.raw.transportEventId}',
      inputId: capture.raw.id,
      normalizerVersion: capture.normalized.normalizerVersion,
      analyzerVersion: 'test-place-v1',
      status: AnalysisRunStatus.succeeded,
      completedAt: capture.raw.receivedAt,
      evidence: const [],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      structuredContent: structured,
    );
  }
}

final class _GatedPlaceEnrichmentService implements PlaceEnrichmentService {
  final List<String> startedNames = [];
  final List<String> settledNames = [];
  final Map<String, Completer<List<ContentTag>>> _inFlight = {};
  var activeCount = 0;
  var maxActiveCount = 0;
  var _releaseImmediately = false;

  @override
  Future<List<ContentTag>> enrich({required String name, String? searchArea}) {
    startedNames.add(name);
    activeCount += 1;
    if (activeCount > maxActiveCount) {
      maxActiveCount = activeCount;
    }
    final gate = Completer<List<ContentTag>>();
    _inFlight[name] = gate;
    if (_releaseImmediately) {
      gate.complete(_result);
    }
    return gate.future.whenComplete(() {
      activeCount -= 1;
      settledNames.add(name);
      _inFlight.remove(name);
    });
  }

  void fail(String name) {
    final gate = _inFlight[name];
    if (gate == null || gate.isCompleted) return;
    gate.completeError(StateError('simulated place enrichment failure'));
  }

  void releaseAll() {
    _releaseImmediately = true;
    for (final gate in _inFlight.values.toList(growable: false)) {
      if (!gate.isCompleted) gate.complete(_result);
    }
  }

  static const _result = [ContentTag(value: '웹 보강', source: TagSource.web)];
}

final class _RecordingIncomingShareService implements IncomingShareService {
  final _pendingController = StreamController<void>.broadcast();
  final _shares = <IncomingShare>[];
  final keptTransportIds = <String>[];
  final deletedTransportIds = <String>[];
  final acknowledgedTransportIds = <String>[];
  var acknowledgeCallCount = 0;

  int get pendingCount => _shares.length;

  void add(IncomingShare share) {
    _shares.add(share);
    _pendingController.add(null);
  }

  @override
  Stream<void> get pendingChanged => _pendingController.stream;

  @override
  Future<List<IncomingShare>> drainPending() async => List.of(_shares);

  var presentCapturePickerCount = 0;
  var capturePickerAccepts = false;
  var failAcknowledge = false;

  @override
  Future<CapturePickerResult> presentCapturePicker() async {
    presentCapturePickerCount += 1;
    return capturePickerAccepts
        ? const CapturePickerResult(
            selectedCount: 1,
            importedCount: 1,
            rejectedCount: 0,
          )
        : const CapturePickerResult.cancelled();
  }

  @override
  Future<void> acknowledge(Iterable<String> ids) async {
    acknowledgeCallCount += 1;
    if (failAcknowledge) {
      throw StateError('simulated acknowledge failure');
    }
    final acknowledged = ids.toSet();
    acknowledgedTransportIds.addAll(acknowledged);
    _shares.removeWhere((share) => acknowledged.contains(share.id));
  }

  @override
  Future<SharedSourceDeletionResult> deleteSharedSource(
    String transportId,
  ) async {
    deletedTransportIds.add(transportId);
    return SharedSourceDeletionResult.deleted;
  }

  @override
  Future<void> keepSharedSource(String transportId) async {
    keptTransportIds.add(transportId);
  }

  @override
  Future<void> dispose() => _pendingController.close();
}

final class _ToggleAppSnapshotStore implements AppSnapshotStore {
  final _delegate = InMemoryAppSnapshotStore();
  bool failWrites = false;

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
      throw StateError('simulated durable write failure');
    }
    return _delegate.save(captures, tagSenses: tagSenses);
  }
}

final class _FailingAppSnapshotStore implements AppSnapshotStore {
  const _FailingAppSnapshotStore();

  @override
  Future<List<PersistedCapture>> load() async => const [];

  @override
  Future<Map<String, List<String>>> loadTagSenses() async => const {};

  @override
  Future<void> save(
    List<PersistedCapture> captures, {
    Map<String, List<String>> tagSenses = const {},
  }) async {
    throw StateError('simulated durable write failure');
  }
}
