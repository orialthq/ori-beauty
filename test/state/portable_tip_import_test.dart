import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/portable_tip_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/domain/portable_tip_package.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  test(
    'previews a received tip before saving and acknowledges after save',
    () async {
      final shares = InMemoryIncomingShareService();
      final inbox = InMemoryPortableTipInbox();
      final controller = AppController(
        shares,
        const BaselineContentAnalysisService(),
        InMemoryAppSnapshotStore(),
        inbox,
      );
      addTearDown(controller.dispose);
      final tip = _tip('tip-received-0001');
      inbox.add(
        PortableTipPackageCodec.encode(tip),
        transportId: 'transport-received-0001',
      );
      final received = Completer<String>();
      controller.portableTipReceived.listen(received.complete);

      await controller.initialize();
      final transportId = await received.future;

      expect(controller.pendingPortableTip(transportId)?.title, '동묘집');
      expect(
        controller.captures.where(
          (capture) => capture.raw.origin == CaptureOrigin.portableTip,
        ),
        isEmpty,
      );

      final captureId = await controller.acceptPortableTip(transportId);
      final imported = controller.captureById(captureId!);

      expect(imported?.raw.origin, CaptureOrigin.portableTip);
      expect(imported?.status, CaptureStatus.organized);
      expect(imported?.analysis?.model, 'portable-tip-v1');
      expect(
        imported?.analysis?.structuredContent?.facts
            .singleWhere((fact) => fact.label == '대표 메뉴')
            .value,
        '철판쭈꾸미',
      );
      expect(await inbox.pending(), isEmpty);
    },
  );

  test('discarding a received tip does not create organized content', () async {
    final shares = InMemoryIncomingShareService();
    final inbox = InMemoryPortableTipInbox();
    final controller = AppController(
      shares,
      const BaselineContentAnalysisService(),
      InMemoryAppSnapshotStore(),
      inbox,
    );
    addTearDown(controller.dispose);
    inbox.add(
      PortableTipPackageCodec.encode(_tip('tip-discard-0001')),
      transportId: 'transport-discard-0001',
    );
    final received = Completer<String>();
    controller.portableTipReceived.listen(received.complete);

    await controller.initialize();
    final transportId = await received.future;
    await controller.discardPortableTip(transportId);

    expect(
      controller.captures.where(
        (capture) => capture.raw.origin == CaptureOrigin.portableTip,
      ),
      isEmpty,
    );
    expect(await inbox.pending(), isEmpty);
  });

  test('stages only one pending copy of the same package id', () async {
    final shares = InMemoryIncomingShareService();
    final inbox = InMemoryPortableTipInbox();
    final controller = AppController(
      shares,
      const BaselineContentAnalysisService(),
      InMemoryAppSnapshotStore(),
      inbox,
    );
    addTearDown(controller.dispose);
    final encoded = PortableTipPackageCodec.encode(_tip('tip-duplicate-0001'));
    inbox
      ..add(encoded, transportId: 'transport-duplicate-0001')
      ..add(encoded, transportId: 'transport-duplicate-0002');
    final receivedIds = <String>[];
    final subscription = controller.portableTipReceived.listen(receivedIds.add);
    addTearDown(subscription.cancel);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(receivedIds, ['transport-duplicate-0001']);
    expect(await inbox.pending(), hasLength(1));
    expect(
      () => controller.stagePortableTip(encoded),
      throwsA(isA<FormatException>()),
    );

    await controller.acceptPortableTip(receivedIds.single);
    expect(await inbox.pending(), isEmpty);
  });

  test('a received tip waits in 공유함 instead of joining the library', () async {
    final shares = InMemoryIncomingShareService();
    final inbox = InMemoryPortableTipInbox();
    final controller = AppController(
      shares,
      const BaselineContentAnalysisService(),
      InMemoryAppSnapshotStore(),
      inbox,
    );
    addTearDown(controller.dispose);
    inbox.add(
      PortableTipPackageCodec.encode(_tip('tip-inbox-0001')),
      transportId: 'transport-inbox-0001',
    );
    inbox.add(
      PortableTipPackageCodec.encode(_older('tip-inbox-0002')),
      transportId: 'transport-inbox-0002',
    );
    final received = <String>[];
    controller.portableTipReceived.listen(received.add);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    // The claim the tab makes: arriving is not the same as being kept.
    expect(controller.sharedInbox.length, 2);
    expect(
      controller.captures.where(
        (capture) => capture.raw.origin == CaptureOrigin.portableTip,
      ),
      isEmpty,
    );
    // Newest first, by when the sender exported it.
    expect(controller.sharedInbox.first.tip.packageId, 'tip-inbox-0001');
    expect(controller.sharedInbox.last.tip.packageId, 'tip-inbox-0002');

    // Anything still undecided stays in the native inbox, which is what hands
    // it back after a restart without any of this being written down.
    expect(await inbox.pending(), hasLength(2));

    final entry = controller.sharedInbox.first;
    await controller.acceptPortableTip(entry.transportId);
    expect(controller.sharedInbox.length, 1);
    expect(controller.sharedInbox.single.tip.packageId, 'tip-inbox-0002');

    await controller.discardPortableTip(
      controller.sharedInbox.single.transportId,
    );
    expect(controller.sharedInbox, isEmpty);
    expect(await inbox.pending(), isEmpty);
  });
}

PortableTipPackage _tip(String id) {
  return PortableTipPackage.create(
    packageId: id,
    exportedAt: DateTime.utc(2026, 8, 5),
    title: '동묘집',
    summary: '철판쭈꾸미가 소개된 종로 맛집',
    tags: const ['맛집·카페', '한식'],
    facts: [PortableTipFact(label: '대표 메뉴', value: '철판쭈꾸미')],
    place: PortableTipPlace(name: '동묘집', address: '서울 종로구 종로52길'),
    message: '이번 주말에 같이 갈래?',
  );
}

PortableTipPackage _older(String id) {
  return PortableTipPackage.create(
    packageId: id,
    exportedAt: DateTime.utc(2026, 8, 1),
    title: '겨울 코트',
    summary: '아우터 후보',
    tags: const ['쇼핑', '아우터'],
  );
}
