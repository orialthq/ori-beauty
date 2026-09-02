import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/remote_content_analysis_service.dart';
import 'package:ori_beauty/domain/models.dart';

void main() {
  late HttpServer server;
  late Map<String, Object?> received;
  late File screenshot;

  setUp(() async {
    received = const {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      // The request is what is under test, not the answer.
      request.response
        ..statusCode = 503
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': {
              'code': 'UPSTREAM_UNAVAILABLE',
              'message': 'x',
              'retryable': true,
            },
          }),
        );
      await request.response.close();
    });
    final root = await Directory.systemTemp.createTemp('trun-on-vocab-');
    addTearDown(() => root.delete(recursive: true));
    screenshot = File('${root.path}${Platform.pathSeparator}screen.jpg');
    await screenshot.writeAsBytes(const [0xff, 0xd8, 0xff], flush: true);
  });

  tearDown(() => server.close(force: true));

  CaptureRecord capture() =>
      const BaselineContentAnalysisService().prepareShare(
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
              filePath: screenshot.path,
              mimeType: 'image/jpeg',
              byteSize: 3,
              width: 1,
              height: 1,
              sha256: List.filled(64, 'c').join(),
            ),
          ],
        ),
      );

  test('the library’s words go with the screenshot, most used first', () async {
    final service = RemoteContentAnalysisService(
      baseUrl: 'http://127.0.0.1:${server.port}',
      vocabulary: () => const [
        (value: '스킨케어', count: 3),
        (value: '올리브영', count: 1),
        // Never a name the library could not use.
        (value: '#', count: 5),
      ],
    );

    await expectLater(
      service.analyze(capture()),
      throwsA(isA<AnalysisServiceException>()),
    );

    expect(received['vocabulary'], [
      {'value': '스킨케어', 'count': 3},
      {'value': '올리브영', 'count': 1},
    ]);
    // Only the words. Which capture carries which is not the model's to know.
    expect(received.keys, unorderedEquals(['image', 'capture', 'vocabulary']));
  });

  test('a build with no library sends no vocabulary at all', () async {
    final service = RemoteContentAnalysisService(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );

    await expectLater(
      service.analyze(capture()),
      throwsA(isA<AnalysisServiceException>()),
    );

    expect(received.containsKey('vocabulary'), isFalse);
  });

  test('the list is cut where the server cuts it', () async {
    final service = RemoteContentAnalysisService(
      baseUrl: 'http://127.0.0.1:${server.port}',
      vocabulary: () => [
        for (var index = 0; index < 400; index++)
          (value: '태그$index', count: 400 - index),
      ],
    );

    await expectLater(
      service.analyze(capture()),
      throwsA(isA<AnalysisServiceException>()),
    );

    expect(
      received['vocabulary'],
      hasLength(RemoteContentAnalysisService.maxVocabulary),
    );
  });
}
