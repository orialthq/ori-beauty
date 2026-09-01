import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/domain/models.dart';

/// Feeds a verbatim server reply through the client parser.
///
/// The two ends of this contract live in different languages, so a field the
/// server renamed shows up here as silently missing tags rather than a failure.
/// This test is the tripwire for that.
const _serverReply = r'''
{
  "matchedName": "화육계",
  "kind": [
    {
      "value": "닭발",
      "confidence": 0.98,
      "quote": "닭발 전문점",
      "citations": ["https://food.job.or.kr/4421"]
    }
  ],
  "access": [
    {
      "value": "예약 가능",
      "confidence": 0.9,
      "quote": "네이버 예약으로 자리를 잡을 수 있다",
      "citations": ["https://www.diningcode.com/profile.php?rid=C3Y92XRMvN0z"]
    },
    {
      "value": "웨이팅 있음",
      "confidence": 0.82,
      "quote": "저녁에는 늘 줄이 길다",
      "citations": ["https://a.example.com/1", "https://b.example.com/2"]
    }
  ]
}
''';

void main() {
  test('a verbatim server reply survives the client parser', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain();
      request.response.headers.contentType = ContentType.json;
      request.response.write(_serverReply);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final service = RemotePlaceEnrichmentService(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final tags = await service.enrich(name: '화육계', searchArea: '을지로');

    // Both fields the server answers with land in one flat list. Which of them
    // a tag arrived in is not something the library keeps any more.
    expect(tags.map((tag) => tag.value), ['닭발', '예약 가능', '웨이팅 있음']);
    expect(tags.every((tag) => tag.source == TagSource.web), isTrue);
    expect(tags.first.citations, isNotEmpty);
    expect(tags.first.quotes, ['닭발 전문점']);
  });
}
