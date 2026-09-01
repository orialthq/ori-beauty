import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'analysis_server.dart';

/// Looks a saved place up on the web for tags a screenshot cannot carry.
///
/// A screenshot almost never shows a price, and rarely says who a place suits.
/// This pass searches for `상호명 + 지역` — the same query the map opens with —
/// and returns tags that each carry the page supporting them.
///
/// Every failure mode resolves to an empty result rather than an exception the
/// caller has to reason about. The enrichment is an optional extra on top of a
/// capture that is already saved and already useful.
abstract interface class PlaceEnrichmentService {
  Future<List<ContentTag>> enrich({required String name, String? searchArea});
}

final class RemotePlaceEnrichmentService implements PlaceEnrichmentService {
  const RemotePlaceEnrichmentService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 60),
  });

  /// Null until a build names one, which leaves the platform default to stand.
  final String? baseUrl;
  final Duration timeout;

  String get _serverUrl => baseUrl ?? defaultAnalysisBaseUrl();

  /// The two fields the server answers with. They used to be axes; a tag does
  /// not care which of them it arrived in.
  static const _fields = ['kind', 'access'];

  @override
  Future<List<ContentTag>> enrich({
    required String name,
    String? searchArea,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return const <ContentTag>[];
    }
    final endpoint = Uri.tryParse(_serverUrl)?.resolve('/v1/enrich-place');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      return const <ContentTag>[];
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'name': trimmedName,
          'searchArea': searchArea?.trim().isEmpty ?? true
              ? null
              : searchArea!.trim(),
        }),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <ContentTag>[];
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        return const <ContentTag>[];
      }
      return _tagsFrom(decoded);
    } on Object {
      // Offline, unreachable server, malformed reply: all the same outcome.
      return const <ContentTag>[];
    } finally {
      client.close(force: true);
    }
  }

  List<ContentTag> _tagsFrom(Map<String, Object?> json) {
    final tags = <ContentTag>[];
    for (final field in _fields) {
      final raw = json[field];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is! Map<String, Object?>) continue;
        final value = item['value'];
        final quote = item['quote'];
        final citations = item['citations'];
        // A web tag without a quoted sentence and a page to check it against is
        // indistinguishable from a guess.
        if (value is! String ||
            !isValidTagName(value) ||
            quote is! String ||
            quote.trim().isEmpty ||
            citations is! List) {
          continue;
        }
        final sources = citations
            .whereType<String>()
            .where((url) => url.startsWith('https://'))
            .toList(growable: false);
        if (sources.isEmpty) continue;
        final confidence = item['confidence'];
        tags.add(
          ContentTag(
            value: value,
            source: TagSource.web,
            confidence: confidence is num
                ? confidence.toDouble().clamp(0.0, 1.0)
                : 0.0,
            quotes: [quote.trim()],
            citations: sources,
          ),
        );
      }
    }
    return dedupedTags(tags);
  }
}

final class NoPlaceEnrichmentService implements PlaceEnrichmentService {
  const NoPlaceEnrichmentService();

  @override
  Future<List<ContentTag>> enrich({
    required String name,
    String? searchArea,
  }) async {
    return const <ContentTag>[];
  }
}
