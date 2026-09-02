import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import '../domain/tag_key.dart';
import 'analysis_server.dart';

/// Fetches, for each tag, the words a person would type when looking for it.
///
/// The dictionary behind "매운거 finds 닭발". Asked once per tag, in batches,
/// in the background — never while the reader is typing, because typing is
/// answered from the stored copy. The mapping is one-way: these words lead to
/// the tag; the tag's name never expands to anything.
///
/// The answer is keyed by [tagKey] and includes an empty list for a tag the
/// model had nothing useful for, so that emptiness can be stored and the tag
/// not asked about again. Every failure is an empty map: the dictionary is an
/// extra on a search that works without it.
abstract interface class TagSenseService {
  Future<Map<String, List<String>>> senses(List<TagVocabularyEntry> tags);
}

final class RemoteTagSenseService implements TagSenseService {
  const RemoteTagSenseService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 60),
  });

  /// Null until a build names one, which leaves the platform default to stand.
  final String? baseUrl;
  final Duration timeout;

  String get _serverUrl => baseUrl ?? defaultAnalysisBaseUrl();

  @override
  Future<Map<String, List<String>>> senses(
    List<TagVocabularyEntry> tags,
  ) async {
    final words = tags
        .where((entry) => entry.count > 0 && isValidTagName(entry.value))
        .take(300)
        .toList(growable: false);
    if (words.isEmpty) return const {};
    final endpoint = Uri.tryParse(_serverUrl)?.resolve('/v1/tag-senses');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      return const {};
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'tags': [
            for (final entry in words)
              {'value': entry.value, 'count': entry.count},
          ],
        }),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const {};
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return const {};
      return _sensesFrom(decoded, {
        for (final entry in words) tagKey(entry.value),
      });
    } on Object {
      // Offline, unreachable server, malformed reply: all the same outcome.
      return const {};
    } finally {
      client.close(force: true);
    }
  }

  /// Only answers for tags that were asked about. The server enforces this
  /// too; here it protects the stored dictionary from a reply that would file
  /// words under tags the library does not have.
  Map<String, List<String>> _sensesFrom(
    Map<String, Object?> json,
    Set<String> asked,
  ) {
    final raw = json['senses'];
    if (raw is! List) return const {};
    final senses = <String, List<String>>{};
    for (final item in raw) {
      if (item is! Map<String, Object?>) continue;
      final tag = item['tag'];
      final words = item['words'];
      if (tag is! String || words is! List) continue;
      final key = tagKey(tag);
      if (!asked.contains(key) || senses.containsKey(key)) continue;
      senses[key] = List.unmodifiable([
        for (final word in words)
          if (word is String &&
              word.trim().isNotEmpty &&
              word.trim().runes.length <= 12)
            word.trim(),
      ]);
    }
    return senses;
  }
}

final class NoTagSenseService implements TagSenseService {
  const NoTagSenseService();

  @override
  Future<Map<String, List<String>>> senses(
    List<TagVocabularyEntry> tags,
  ) async {
    return const {};
  }
}
