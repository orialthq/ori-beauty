import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'analysis_server.dart';

/// Two of the reader's words that are one word, and why.
///
/// [into] is the spelling that stays: the one more things are already filed
/// under. Merging goes that way so the larger pile is never renamed.
final class TagMerge {
  const TagMerge({
    required this.from,
    required this.into,
    required this.reason,
  });

  final String from;
  final String into;
  final String reason;
}

/// Reads the whole vocabulary and says which words are one word.
///
/// The reader's half of this is renaming a tag onto a name that exists. This is
/// the other half: a pass over every word at once, which is the only place a
/// pair like `멕시코 음식` and `멕시칸` can be noticed, because no single capture
/// ever shows both. It proposes; the reader merges. Nothing here rewrites a
/// tag on its own, and a tag the reader named is theirs whatever this thinks.
///
/// Every failure is an empty list. Suggestions are an extra on a screen that
/// works without them.
abstract interface class TagMergeService {
  Future<List<TagMerge>> suggest(List<TagVocabularyEntry> vocabulary);
}

final class RemoteTagMergeService implements TagMergeService {
  const RemoteTagMergeService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 45),
  });

  /// Null until a build names one, which leaves the platform default to stand.
  final String? baseUrl;
  final Duration timeout;

  String get _serverUrl => baseUrl ?? defaultAnalysisBaseUrl();

  @override
  Future<List<TagMerge>> suggest(List<TagVocabularyEntry> vocabulary) async {
    final words = vocabulary
        .where((entry) => entry.count > 0 && isValidTagName(entry.value))
        .take(300)
        .toList(growable: false);
    // One word has nothing to merge with.
    if (words.length < 2) return const <TagMerge>[];
    final endpoint = Uri.tryParse(_serverUrl)?.resolve('/v1/tag-merges');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      return const <TagMerge>[];
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'vocabulary': [
            for (final entry in words)
              {'value': entry.value, 'count': entry.count},
          ],
        }),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <TagMerge>[];
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return const <TagMerge>[];
      return _mergesFrom(decoded, {for (final entry in words) entry.value});
    } on Object {
      // Offline, unreachable server, malformed reply: all the same outcome.
      return const <TagMerge>[];
    } finally {
      client.close(force: true);
    }
  }

  /// Only pairs of words the library actually has. The server checks this
  /// too, but a suggestion to merge into a word that is not there would be
  /// acted on by renaming onto it, which is the one thing this must not cause.
  List<TagMerge> _mergesFrom(Map<String, Object?> json, Set<String> known) {
    final raw = json['merges'];
    if (raw is! List) return const <TagMerge>[];
    final merges = <TagMerge>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map<String, Object?>) continue;
      final from = item['from'];
      final into = item['into'];
      final reason = item['reason'];
      if (from is! String ||
          into is! String ||
          from == into ||
          !known.contains(from) ||
          !known.contains(into) ||
          !seen.add(from)) {
        continue;
      }
      merges.add(
        TagMerge(
          from: from,
          into: into,
          reason: reason is String ? reason.trim() : '',
        ),
      );
    }
    return merges;
  }
}

final class NoTagMergeService implements TagMergeService {
  const NoTagMergeService();

  @override
  Future<List<TagMerge>> suggest(List<TagVocabularyEntry> vocabulary) async {
    return const <TagMerge>[];
  }
}
