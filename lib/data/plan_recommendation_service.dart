import 'dart:convert';
import 'dart:io';

import 'analysis_server.dart';
import 'recommendation_candidates.dart';

/// What came back, including the three ways nothing came back.
///
/// `noMatch`, `noCandidates`, and `unavailable` are kept apart because they mean
/// different things to a reader and call for different buttons. Nothing saved,
/// nothing that fits, and the server not answering are three situations, and
/// collapsing them is how a failure ends up looking like a considered result.
enum PlanRecommendationStatus { ready, noMatch, noCandidates, unavailable }

/// Something the reader saved, sitting inside a to-do that uses it.
///
/// Material rather than a task. "리쥬란 후기" is not something to do; it is what
/// you read while deciding what to buy, so it hangs under that decision instead
/// of standing beside it.
final class PlanTodoSavedItem {
  const PlanTodoSavedItem({
    required this.id,
    required this.name,
    required this.why,
  });

  /// The capture or product group in the reader's library. Checked against what
  /// was sent before it ever reaches here.
  final String id;

  /// Resolved when the answer arrived, so a card never has to reach back into a
  /// library that may have changed.
  final String name;

  /// Why it serves this particular to-do, in one sentence.
  final String why;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    if (why.isNotEmpty) 'why': why,
  };

  static PlanTodoSavedItem? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    return PlanTodoSavedItem(
      id: id,
      name: name,
      why: raw['why'] is String ? (raw['why']! as String).trim() : '',
    );
  }
}

/// One thing to do before a plan comes due.
///
/// Everything on it was decided by the model — what to do, how far ahead, why,
/// and whether to tick it by default. The only field the app owns is the date,
/// computed from [daysBefore] against the plan's own day, because a model asked
/// for a date will sometimes hand back a Tuesday that is a Wednesday.
final class PlanTodoSuggestion {
  const PlanTodoSuggestion({
    required this.title,
    required this.action,
    required this.daysBefore,
    required this.note,
    required this.selected,
    this.group = '',
    this.saved = const <PlanTodoSavedItem>[],
    this.done = false,
  });

  final String title;

  /// The name of the group this came in, and the only part of [PlanTodoGroup]
  /// that outlives the choosing.
  ///
  /// Carried on the to-do rather than kept as a structure around it: ticking
  /// one off addresses it by its position in a flat list, and so do the
  /// progress bar, the countdown, and the next-thing-to-do line. A nesting
  /// would have to be flattened again at every one of them.
  ///
  /// Empty for a plan made before to-dos knew what they belonged to, and for
  /// one written by hand.
  final String group;

  /// What the reader has to do: 예약, 구매, 보기, 준비.
  final String action;

  /// How many days before the plan's day this has to happen. Zero is the day
  /// itself.
  final int daysBefore;

  final String note;

  /// Whether it starts ticked on the review screen.
  final bool selected;

  /// What the reader already saved that serves this to-do. Usually empty, and
  /// that is a correct answer: a plan needs what it needs whether or not the
  /// reader happens to have kept something for it.
  final List<PlanTodoSavedItem> saved;

  /// Ticked off by the reader after the plan was made. Distinct from
  /// [selected], which only decided whether the row made it into the plan at
  /// all.
  final bool done;

  PlanTodoSuggestion copyWith({
    bool? done,
    List<PlanTodoSavedItem>? saved,
    String? group,
  }) => PlanTodoSuggestion(
    title: title,
    action: action,
    daysBefore: daysBefore,
    note: note,
    selected: selected,
    group: group ?? this.group,
    saved: saved ?? this.saved,
    done: done ?? this.done,
  );

  /// The day this is due, given the day the plan itself falls on.
  DateTime dueDate(DateTime planDate) => DateTime(
    planDate.year,
    planDate.month,
    planDate.day,
  ).subtract(Duration(days: daysBefore));

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'action': action,
    'daysBefore': daysBefore,
    if (note.isNotEmpty) 'note': note,
    if (group.isNotEmpty) 'group': group,
    if (saved.isNotEmpty)
      'saved': saved.map((one) => one.toJson()).toList(growable: false),
    if (done) 'done': true,
  };

  static PlanTodoSuggestion? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final title = raw['title'];
    if (title is! String || title.trim().isEmpty) return null;
    final saved = <PlanTodoSavedItem>[];
    for (final entry
        in raw['saved'] is List ? raw['saved']! as List : const []) {
      final item = PlanTodoSavedItem.fromJson(entry);
      if (item != null) saved.add(item);
    }
    return PlanTodoSuggestion(
      title: title.trim(),
      action: raw['action'] is String ? (raw['action']! as String).trim() : '',
      daysBefore: raw['daysBefore'] is int ? raw['daysBefore']! as int : 0,
      note: raw['note'] is String ? (raw['note']! as String).trim() : '',
      selected: raw['selected'] != false,
      group: raw['group'] is String ? (raw['group']! as String).trim() : '',
      saved: List<PlanTodoSavedItem>.unmodifiable(saved),
      done: raw['done'] == true,
    );
  }
}

/// To-dos that belong together, with the model's own words for why.
final class PlanTodoGroup {
  const PlanTodoGroup({
    required this.title,
    required this.note,
    required this.items,
  });

  final String title;
  final String note;
  final List<PlanTodoSuggestion> items;
}

final class PlanRecommendation {
  const PlanRecommendation({
    required this.status,
    this.groups = const <PlanTodoGroup>[],
    this.todoCount = 0,
    this.attachedCount = 0,
    this.failureCode,
  });

  const PlanRecommendation.unavailable(String this.failureCode)
    : status = PlanRecommendationStatus.unavailable,
      groups = const <PlanTodoGroup>[],
      todoCount = 0,
      attachedCount = 0;

  final PlanRecommendationStatus status;
  final List<PlanTodoGroup> groups;

  /// How many to-dos the plan came to, and how many saved things ended up
  /// inside them. The second can exceed the library's size: one product can
  /// serve both deciding and buying.
  final int todoCount;
  final int attachedCount;

  /// Why the call could not run. Null unless [status] is `unavailable`.
  final String? failureCode;

  List<PlanTodoSuggestion> get allItems => <PlanTodoSuggestion>[
    for (final group in groups) ...group.items,
  ];
}

abstract interface class PlanRecommendationService {
  /// Never throws. Every failure comes back as `unavailable`, so nothing a
  /// reader is in the middle of can be lost to a network.
  Future<PlanRecommendation> recommend({
    required String planTitle,
    String? planArea,
    DateTime? scheduledAt,
    required List<RecommendationCandidate> candidates,
  });
}

final class RemotePlanRecommendationService
    implements PlanRecommendationService {
  const RemotePlanRecommendationService({
    this.baseUrl,
    // Measured at six to eight seconds for a plan the size of a wedding.
    // Thirty leaves room for a slow answer without leaving a reader watching a
    // spinner for a minute.
    this.timeout = const Duration(seconds: 30),
    // Separate on purpose. A server that cannot be reached at all fails here,
    // and that is the common failure while developing — the Mac's address
    // changed, the phone is on another network, the server is not running.
    // Waiting the full timeout for it made a dead path look like a slow one.
    this.connectTimeout = const Duration(seconds: 8),
  });

  /// Null until a build names one, which leaves the platform default to stand.
  final String? baseUrl;
  final Duration timeout;
  final Duration connectTimeout;

  String get _serverUrl => baseUrl ?? defaultAnalysisBaseUrl();

  @override
  Future<PlanRecommendation> recommend({
    required String planTitle,
    String? planArea,
    DateTime? scheduledAt,
    required List<RecommendationCandidate> candidates,
  }) async {
    final endpoint = Uri.tryParse(
      _serverUrl,
    )?.resolve('/v1/plan-recommendation');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      return const PlanRecommendation.unavailable('invalid_server_url');
    }

    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final request = await client.postUrl(endpoint).timeout(connectTimeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'plan': <String, Object?>{
            'title': planTitle,
            if (planArea != null && planArea.trim().isNotEmpty)
              'area': planArea.trim(),
            if (scheduledAt != null)
              'scheduledAt': scheduledAt.toUtc().toIso8601String(),
          },
          'candidates': candidates
              .map((candidate) => candidate.toJson())
              .toList(growable: false),
        }),
      );

      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != 200) {
        return PlanRecommendation.unavailable('http_${response.statusCode}');
      }
      return _parse(body);
    } on Object {
      // Offline, DNS, a refused connection, a body that never arrived. The
      // caller cannot act on which.
      return const PlanRecommendation.unavailable('unreachable');
    } finally {
      client.close(force: true);
    }
  }

  static PlanRecommendation _parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const PlanRecommendation.unavailable('malformed_response');
    }
    if (decoded is! Map<String, Object?>) {
      return const PlanRecommendation.unavailable('malformed_response');
    }

    switch (decoded['status']) {
      case 'no_candidates':
        return const PlanRecommendation(
          status: PlanRecommendationStatus.noCandidates,
        );
      case 'no_match':
        return const PlanRecommendation(
          status: PlanRecommendationStatus.noMatch,
        );
      case 'ready':
        final groups = <PlanTodoGroup>[];
        for (final raw
            in decoded['groups'] is List
                ? decoded['groups']! as List
                : const []) {
          if (raw is! Map<String, Object?>) continue;
          final title = raw['title'] is String
              ? (raw['title']! as String).trim()
              : '할 일';
          final items = <PlanTodoSuggestion>[];
          for (final entry
              in raw['items'] is List ? raw['items']! as List : const []) {
            final item = PlanTodoSuggestion.fromJson(entry);
            // Stamped here so the name survives being chosen. What reaches the
            // plan is a flat list of to-dos, and the group it came in is not
            // written anywhere else on the way.
            if (item != null) items.add(item.copyWith(group: title));
          }
          if (items.isEmpty) continue;
          groups.add(
            PlanTodoGroup(
              title: title,
              note: raw['note'] is String
                  ? (raw['note']! as String).trim()
                  : '',
              items: List<PlanTodoSuggestion>.unmodifiable(items),
            ),
          );
        }
        if (groups.isEmpty) {
          return const PlanRecommendation(
            status: PlanRecommendationStatus.noMatch,
          );
        }
        return PlanRecommendation(
          status: PlanRecommendationStatus.ready,
          groups: List<PlanTodoGroup>.unmodifiable(groups),
          todoCount: decoded['todoCount'] is int
              ? decoded['todoCount']! as int
              : 0,
          attachedCount: decoded['attachedCount'] is int
              ? decoded['attachedCount']! as int
              : 0,
        );
      default:
        return const PlanRecommendation.unavailable('malformed_response');
    }
  }
}
