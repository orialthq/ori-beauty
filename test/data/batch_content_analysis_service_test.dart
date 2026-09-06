import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/batch_content_analysis_service.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/remote_content_analysis_service.dart';
import 'package:ori_beauty/domain/models.dart';

const _requestA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _requestB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late HttpServer server;
  late File screenshot;
  late RemoteBatchContentAnalysisService service;
  late List<(String, Map<String, Object?>)> received;
  late Object? reply;
  late int statusCode;

  setUp(() async {
    received = [];
    reply = {'requestId': _requestA, 'status': 'queued'};
    statusCode = HttpStatus.accepted;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received.add((
        request.uri.path,
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, Object?>,
      ));
      request.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await request.response.close();
    });
    final root = await Directory.systemTemp.createTemp('luffi-batch-test-');
    addTearDown(() => root.delete(recursive: true));
    screenshot = File('${root.path}/screen.jpg');
    await screenshot.writeAsBytes(const [0xff, 0xd8, 0xff], flush: true);
    service = RemoteBatchContentAnalysisService(
      baseUrl: 'http://127.0.0.1:${server.port}',
      vocabulary: () => const [
        (value: '스킨케어', count: 3),
        (value: '#', count: 5),
        (value: '숨김', count: 0),
      ],
    );
  });

  tearDown(() => server.close(force: true));

  CaptureRecord capture({int byteSize = 3}) =>
      const BaselineContentAnalysisService().prepareShare(
        IncomingShare(
          id: 'share-screen',
          receivedAt: DateTime(2026, 9, 1),
          sharedText: '',
          discoveredUrl: 'https://instagram.com/p/private-post?token=secret',
          sourcePackage: 'com.instagram.android',
          mimeType: 'image/jpeg',
          shareKind: ShareKind.image,
          attachments: [
            IncomingAttachment(
              id: 'attachment-screen',
              filePath: screenshot.path,
              mimeType: 'image/jpeg',
              byteSize: byteSize,
              width: 1,
              height: 1,
              sha256: _requestA,
            ),
          ],
        ),
      );

  Matcher errorCode(String code) => throwsA(
    isA<AnalysisServiceException>().having((error) => error.code, 'code', code),
  );

  test(
    'submission carries the same bounded input as instant analysis',
    () async {
      final record = capture();
      final task = await service.submit(record, requestId: _requestA);
      expect(task.requestId, _requestA);
      expect(task.status, 'queued');
      final (path, body) = received.single;
      expect(path, '/v1/analysis-tasks');
      expect(body.keys, unorderedEquals(['requestId', 'input']));
      expect(body['requestId'], _requestA);
      final input = body['input']! as Map<String, Object?>;
      expect(input['image'], {'mimeType': 'image/jpeg', 'base64': '/9j/'});
      expect(input['vocabulary'], [
        {'value': '스킨케어', 'count': 3},
      ]);
      expect((input['capture']! as Map)['sourceUrl'], 'https://instagram.com');
      expect(jsonEncode(body), isNot(contains('private-post')));
      expect(jsonEncode(body), isNot(contains('secret')));

      statusCode = 503;
      reply = {
        'error': {'code': 'UPSTREAM_UNAVAILABLE', 'retryable': true},
      };
      final instant = RemoteContentAnalysisService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        vocabulary: service.vocabulary,
      );
      await expectLater(
        instant.analyze(record),
        errorCode('analysis_service_unavailable'),
      );
      expect(received.last.$1, '/v1/analyze');
      expect(received.last.$2, input);
    },
  );

  test(
    'poll correlates out-of-order results and maps image evidence',
    () async {
      reply = {
        'tasks': [
          {'requestId': _requestB, 'status': 'in_progress'},
          {'requestId': _requestA, 'status': 'completed', 'result': _result()},
        ],
      };
      statusCode = 200;
      final tasks = await service.poll([_requestA, _requestB]);
      expect(received.single.$1, '/v1/analysis-tasks/status');
      expect(received.single.$2, {
        'requestIds': [_requestA, _requestB],
      });
      expect(tasks.map((task) => task.requestId), [_requestA, _requestB]);
      final record = capture().copyWith(
        analysisMode: CaptureAnalysisMode.batch,
        batchRequestId: _requestA,
      );
      final run = tasks.first.toAnalysisRun(record);
      expect(run.id, 'analysis-batch-$_requestA');
      expect(run.inputId, record.raw.id);
      expect(run.model, 'gpt-5.6-luna');
      expect(run.status, AnalysisRunStatus.succeeded);
      expect(run.evidence.single.captureId, record.raw.id);
      expect(run.evidence.single.attachmentId, 'attachment-screen');
      expect(run.evidence.single.kind, EvidenceKind.imageRegion);
      expect(run.evidence.single.quote, '저장한 레시피');
      expect(run.evidence.single.region, 'overlay');
      expect(
        () => tasks.first.toAnalysisRun(
          record.copyWith(batchRequestId: _requestB),
        ),
        errorCode('invalid_analysis_response'),
      );
    },
  );

  test('missing and terminal errors remain explicit task states', () async {
    reply = {
      'tasks': [
        {
          'requestId': _requestA,
          'status': 'missing',
          'error': {'code': 'TASK_NOT_FOUND', 'retryable': true},
        },
        {
          'requestId': _requestB,
          'status': 'failed',
          'error': {'code': 'INVALID_MODEL_RESPONSE', 'retryable': false},
        },
      ],
    };
    final tasks = await service.poll([_requestA, _requestB]);
    expect(tasks.first.errorCode, 'batch_task_missing');
    expect(tasks.first.retryable, isTrue);
    expect(tasks.last.errorCode, 'invalid_analysis_response');
    expect(tasks.last.retryable, isFalse);
  });

  test(
    'unknown state, malformed error and unexpected model are rejected',
    () async {
      for (final task in [
        {'requestId': _requestA, 'status': 'waiting_maybe'},
        {'requestId': _requestA, 'status': 'completed'},
        {'requestId': _requestA, 'status': 'queued', 'result': _result()},
        {
          'requestId': _requestA,
          'status': 'failed',
          'error': {'code': 'FAILED', 'retryable': 'yes'},
        },
        {
          'requestId': _requestA,
          'status': 'completed',
          'result': _result()..['model'] = 'portable-tip-v1',
        },
        {
          'requestId': _requestA,
          'status': 'completed',
          'result': _result()..remove('warnings'),
        },
      ]) {
        reply = task;
        await expectLater(
          service.submit(capture(), requestId: _requestA),
          errorCode('invalid_analysis_response'),
        );
      }
    },
  );

  test('no malformed correlation can replace a different capture', () async {
    reply = {'requestId': _requestB, 'status': 'queued'};
    await expectLater(
      service.submit(capture(), requestId: _requestA),
      errorCode('invalid_analysis_response'),
    );
    for (final tasks in [
      <Object?>[],
      [
        {'requestId': _requestA, 'status': 'queued'},
      ],
      [
        {'requestId': _requestA, 'status': 'queued'},
        {'requestId': _requestA, 'status': 'queued'},
      ],
      [
        {'requestId': _requestA, 'status': 'queued'},
        {'requestId': 'c' * 64, 'status': 'queued'},
      ],
    ]) {
      reply = {'tasks': tasks};
      await expectLater(
        service.poll([_requestA, _requestB]),
        errorCode('invalid_analysis_response'),
      );
    }
  });

  test(
    'invalid IDs and too many poll tasks fail before any HTTP call',
    () async {
      expect(await service.poll([]), isEmpty);
      for (final ids in [
        ['A' * 64],
        ['short'],
        [_requestA, _requestA],
        [for (var i = 0; i < 101; i++) i.toRadixString(16).padLeft(64, '0')],
      ]) {
        await expectLater(
          service.poll(ids),
          errorCode('invalid_batch_request_ids'),
        );
      }
      expect(received, isEmpty);
    },
  );

  test('100 status requests are supported without image uploads', () async {
    final ids = [
      for (var i = 0; i < 100; i++) i.toRadixString(16).padLeft(64, '0'),
    ];
    reply = {
      'tasks': [
        for (final id in ids) {'requestId': id, 'status': 'submitted'},
      ],
    };
    expect(await service.poll(ids), hasLength(100));
    expect(received.single.$2.keys, ['requestIds']);
  });

  test('changed or oversized source never gets uploaded', () async {
    await expectLater(
      service.submit(capture(byteSize: 4), requestId: _requestA),
      errorCode('source_file_changed'),
    );
    await expectLater(
      service.submit(
        capture(byteSize: 12 * 1024 * 1024 + 1),
        requestId: _requestA,
      ),
      errorCode('image_too_large'),
    );
    await screenshot.delete();
    await expectLater(
      service.submit(capture(), requestId: _requestA),
      errorCode('source_file_missing'),
    );
    expect(received, isEmpty);
  });

  test('idempotency conflict stays a non-retryable error', () async {
    statusCode = 409;
    reply = {
      'error': {'code': 'REQUEST_ID_CONFLICT', 'retryable': false},
    };
    await expectLater(
      service.submit(capture(), requestId: _requestA),
      throwsA(
        isA<AnalysisServiceException>()
            .having((e) => e.code, 'code', 'batch_request_conflict')
            .having((e) => e.retryable, 'retryable', isFalse),
      ),
    );
  });

  test(
    'snapshot keeps batch identity, image, tags, and dictionary across restart',
    () {
      final record = capture().copyWith(
        analysisMode: CaptureAnalysisMode.batch,
        batchRequestId: _requestA,
        batchStatus: 'pending_upload',
        tagOverride: const [ContentTag(value: '내 태그', source: TagSource.user)],
      );
      final saved = AppSnapshotCodec.encode(
        [PersistedCapture.fromRecord(record, null)],
        tagSenses: const {
          '내 태그': ['내가 고른 태그'],
        },
      );
      final restored = AppSnapshotCodec.decode(saved).single;
      expect(restored.analysisMode, CaptureAnalysisMode.batch);
      expect(restored.batchRequestId, _requestA);
      expect(restored.batchStatus, 'pending_upload');
      expect(
        restored.attachments.single.toJson(),
        record.raw.attachments.single.toJson(),
      );
      expect(restored.tagOverride!.single.source, TagSource.user);
      expect(restored.tagOverride!.single.value, '내 태그');
      expect(AppSnapshotCodec.decodeTagSenses(saved), {
        '내 태그': ['내가 고른 태그'],
      });
      final cleared = record.copyWith(
        analysisMode: CaptureAnalysisMode.instant,
        clearBatchRequest: true,
      );
      expect(cleared.batchRequestId, isNull);
      expect(cleared.batchStatus, isNull);
      expect(cleared.analysisMode, CaptureAnalysisMode.instant);
      expect(cleared.tagOverride, same(record.tagOverride));
    },
  );

  test(
    'legacy snapshot reads instant and rejects malformed stored task IDs',
    () {
      final legacy = PersistedCapture.fromRecord(capture(), null).toJson()
        ..remove('analysisMode')
        ..remove('batchRequestId')
        ..remove('batchStatus');
      for (final version in [1, 2, 3, 4, 5]) {
        final restored = AppSnapshotCodec.decode(
          jsonEncode({
            'schemaVersion': version,
            'captures': [legacy],
          }),
        ).single;
        expect(restored.analysisMode, CaptureAnalysisMode.instant);
        expect(restored.batchRequestId, isNull);
        expect(restored.batchStatus, isNull);
      }
      expect(
        () =>
            PersistedCapture.fromJson({...legacy, 'batchRequestId': 'invalid'}),
        throwsFormatException,
      );
    },
  );
}

Map<String, Object?> _result() => {
  'schemaVersion': '2.1',
  'model': 'gpt-5.6-luna',
  'domain': 'food',
  'contentKind': 'recipe',
  'tags': <Object?>[],
  'completeness': 'partial',
  'title': {
    'value': '저장한 레시피',
    'status': 'observed',
    'confidence': 0.98,
    'evidenceIds': ['e1'],
  },
  'place': null,
  'summary': '사진에서 읽은 레시피예요.',
  'evidence': [
    {'id': 'e1', 'text': '저장한 레시피', 'region': 'overlay', 'confidence': 0.99},
  ],
  'ingredientGroups': <Object?>[],
  'steps': <Object?>[],
  'facts': <Object?>[],
  'conflicts': <Object?>[],
  'warnings': <Object?>[],
};
