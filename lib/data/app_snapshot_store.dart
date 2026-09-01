import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/models.dart';

abstract interface class AppSnapshotStore {
  Future<List<PersistedCapture>> load();

  Future<void> save(List<PersistedCapture> captures);
}

abstract final class _AnalysisRunCodec {
  static Map<String, Object?> toJson(AnalysisRun analysis) {
    return {
      'id': analysis.id,
      'inputId': analysis.inputId,
      'normalizerVersion': analysis.normalizerVersion,
      'analyzerVersion': analysis.analyzerVersion,
      'status': analysis.status.name,
      'startedAtEpochMs': analysis.startedAt?.millisecondsSinceEpoch,
      'completedAtEpochMs': analysis.completedAt.millisecondsSinceEpoch,
      'attempt': analysis.attempt,
      'model': analysis.model,
      'failureCode': analysis.failureCode,
      'disclosure': analysis.disclosure.name,
      'evidence': analysis.evidence
          .map(
            (item) => {
              'id': item.id,
              'captureId': item.captureId,
              'kind': item.kind.name,
              'quote': item.quote,
              'startOffset': item.startOffset,
              'endOffset': item.endOffset,
              'attachmentId': item.attachmentId,
              'region': item.region,
            },
          )
          .toList(),
      'productMentions': analysis.productMentions
          .map(
            (item) => {
              'id': item.id,
              'brand': _fieldToJson(item.brand),
              'name': _fieldToJson(item.name),
              'category': _fieldToJson(item.category),
              'amount': _fieldToJson(item.amount),
              'overallConfidence': item.overallConfidence,
              'missingFields': item.missingFields
                  .map((field) => field.name)
                  .toList(),
            },
          )
          .toList(),
      'statements': analysis.statements
          .map(
            (item) => {
              'id': item.id,
              'captureId': item.captureId,
              'mentionId': item.mentionId,
              'type': item.type.name,
              'topic': item.topic,
              'originalExpression': item.originalExpression,
              'evidenceIds': item.evidenceIds,
            },
          )
          .toList(),
      'structuredContent': analysis.structuredContent?.toJson(),
    };
  }

  static AnalysisRun fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final inputId = json['inputId'];
    final completedAtEpochMs = json['completedAtEpochMs'];
    if (id is! String || inputId is! String || completedAtEpochMs is! int) {
      throw const FormatException('Persisted analysis fields are invalid.');
    }
    final structuredJson = json['structuredContent'];
    return AnalysisRun(
      id: id,
      inputId: inputId,
      normalizerVersion:
          json['normalizerVersion'] as String? ?? 'unknown-normalizer',
      analyzerVersion: json['analyzerVersion'] as String? ?? 'unknown-analyzer',
      status: _enumByName(
        AnalysisRunStatus.values,
        json['status'],
        AnalysisRunStatus.failed,
      ),
      startedAt: json['startedAtEpochMs'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              json['startedAtEpochMs']! as int,
            )
          : null,
      completedAt: DateTime.fromMillisecondsSinceEpoch(completedAtEpochMs),
      attempt: json['attempt'] as int? ?? 1,
      model: json['model'] as String?,
      failureCode: json['failureCode'] as String?,
      disclosure: _enumByName(
        DisclosureObservation.values,
        json['disclosure'],
        DisclosureObservation.unknown,
      ),
      evidence: _jsonMapList(json['evidence'])
          .map(
            (item) => EvidenceRef(
              id: item['id'] as String? ?? '',
              captureId: item['captureId'] as String? ?? inputId,
              kind: _enumByName(
                EvidenceKind.values,
                item['kind'],
                EvidenceKind.sharedText,
              ),
              quote: item['quote'] as String? ?? '',
              startOffset: item['startOffset'] as int?,
              endOffset: item['endOffset'] as int?,
              attachmentId: item['attachmentId'] as String?,
              region: item['region'] as String?,
            ),
          )
          .toList(growable: false),
      productMentions: _jsonMapList(
        json['productMentions'],
      ).map(_mentionFromJson).toList(growable: false),
      statements: _jsonMapList(json['statements'])
          .map(
            (item) => ContentStatement(
              id: item['id'] as String? ?? '',
              captureId: item['captureId'] as String? ?? inputId,
              mentionId: item['mentionId'] as String?,
              type: _enumByName(
                StatementType.values,
                item['type'],
                StatementType.creatorClaim,
              ),
              topic: item['topic'] as String? ?? '',
              originalExpression: item['originalExpression'] as String? ?? '',
              evidenceIds: _jsonStringList(item['evidenceIds']),
            ),
          )
          .toList(growable: false),
      structuredContent: structuredJson is Map<String, Object?>
          ? StructuredContentAnalysis.fromJson(structuredJson)
          : null,
    );
  }

  static Map<String, Object?> _fieldToJson(ExtractedField<String> field) => {
    'value': field.value,
    'confidence': field.confidence,
    'origin': field.origin.name,
    'evidenceIds': field.evidenceIds,
  };

  static ExtractedField<String> _fieldFromJson(Object? value) {
    final json = value is Map<String, Object?>
        ? value
        : const <String, Object?>{};
    return ExtractedField(
      value: json['value'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      origin: _enumByName(
        FieldOrigin.values,
        json['origin'],
        FieldOrigin.deterministicRule,
      ),
      evidenceIds: _jsonStringList(json['evidenceIds']),
    );
  }

  static ProductMention _mentionFromJson(Map<String, Object?> json) {
    return ProductMention(
      id: json['id'] as String? ?? '',
      brand: _fieldFromJson(json['brand']),
      name: _fieldFromJson(json['name']),
      category: _fieldFromJson(json['category']),
      amount: _fieldFromJson(json['amount']),
      overallConfidence: (json['overallConfidence'] as num?)?.toDouble() ?? 0,
      missingFields: _jsonStringList(json['missingFields'])
          .map(
            (name) => _enumByName(
              MissingField.values,
              name,
              MissingField.productName,
            ),
          )
          .toSet(),
    );
  }

  static List<Map<String, Object?>> _jsonMapList(Object? value) {
    return value is List<Object?>
        ? value.whereType<Map<String, Object?>>().toList(growable: false)
        : const [];
  }

  static List<String> _jsonStringList(Object? value) {
    return value is List<Object?>
        ? value.whereType<String>().toList(growable: false)
        : const [];
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? raw,
    T fallback,
  ) {
    if (raw is String) {
      for (final value in values) {
        if (value.name == raw) {
          return value;
        }
      }
    }
    return fallback;
  }
}

final class MethodChannelAppSnapshotStore implements AppSnapshotStore {
  const MethodChannelAppSnapshotStore();

  static const _channel = MethodChannel(
    'com.orialthq.ori_beauty/incoming_share/v1',
  );

  @override
  Future<List<PersistedCapture>> load() async {
    final snapshot = await _channel.invokeMethod<String>('loadAppSnapshot');
    if (snapshot == null || snapshot.isEmpty) {
      return const [];
    }
    return AppSnapshotCodec.decode(snapshot);
  }

  @override
  Future<void> save(List<PersistedCapture> captures) async {
    final saved = await _channel.invokeMethod<bool>(
      'saveAppSnapshot',
      AppSnapshotCodec.encode(captures),
    );
    if (saved != true) {
      throw StateError('The app snapshot was not saved.');
    }
  }
}

final class InMemoryAppSnapshotStore implements AppSnapshotStore {
  String? _snapshot;

  String? get snapshot => _snapshot;

  @override
  Future<List<PersistedCapture>> load() async {
    final snapshot = _snapshot;
    return snapshot == null ? const [] : AppSnapshotCodec.decode(snapshot);
  }

  @override
  Future<void> save(List<PersistedCapture> captures) async {
    _snapshot = AppSnapshotCodec.encode(captures);
  }
}

abstract final class AppSnapshotCodec {
  static const schemaVersion = 4;

  static String encode(List<PersistedCapture> captures) {
    return jsonEncode({
      'schemaVersion': schemaVersion,
      'captures': captures.map((capture) => capture.toJson()).toList(),
    });
  }

  static List<PersistedCapture> decode(String snapshot) {
    final decoded = jsonDecode(snapshot);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Unsupported app snapshot schema.');
    }
    final decodedVersion = decoded['schemaVersion'];
    if (decodedVersion != 1 &&
        decodedVersion != 2 &&
        decodedVersion != 3 &&
        decodedVersion != schemaVersion) {
      throw const FormatException('Unsupported app snapshot schema.');
    }
    final captures = decoded['captures'];
    if (captures is! List<Object?>) {
      throw const FormatException('App snapshot captures are invalid.');
    }
    return captures
        .map((item) {
          if (item is! Map<String, Object?>) {
            throw const FormatException('Persisted capture is invalid.');
          }
          return PersistedCapture.fromJson(item);
        })
        .toList(growable: false);
  }
}

final class PersistedCapture {
  const PersistedCapture({
    required this.transportEventId,
    required this.receivedAt,
    required this.origin,
    required this.sharedText,
    required this.discoveredUrl,
    required this.sourcePackage,
    required this.mimeType,
    required this.wasTruncated,
    required this.originalLength,
    required this.status,
    required this.reviewId,
    required this.reviewResolution,
    required this.reviewedAt,
    required this.confirmedIdentity,
    required this.groupId,
    this.tagOverride,
    this.attachments = const [],
    this.analysis,
  });

  factory PersistedCapture.fromRecord(
    CaptureRecord capture,
    ProductGroup? group,
  ) {
    return PersistedCapture(
      transportEventId: capture.raw.transportEventId,
      receivedAt: capture.raw.receivedAt,
      origin: capture.raw.origin,
      sharedText: capture.raw.rawText,
      discoveredUrl: capture.raw.rawUrl,
      sourcePackage: capture.raw.sourcePackage,
      mimeType: capture.raw.mimeType,
      wasTruncated: capture.raw.wasTruncated,
      originalLength: capture.raw.originalLength,
      status: capture.status,
      reviewId: capture.review?.id,
      reviewResolution: capture.review?.resolution,
      reviewedAt: capture.review?.reviewedAt,
      confirmedIdentity: capture.review?.confirmedIdentity ?? group?.identity,
      groupId: capture.groupId,
      tagOverride: capture.tagOverride,
      attachments: capture.raw.attachments,
      analysis: capture.analysis,
    );
  }

  factory PersistedCapture.fromJson(Map<String, Object?> json) {
    final transportEventId = json['transportEventId'];
    final receivedAtEpochMs = json['receivedAtEpochMs'];
    final sharedText = json['sharedText'];
    final originalLength = json['originalLength'];
    if (transportEventId is! String ||
        receivedAtEpochMs is! int ||
        sharedText is! String ||
        originalLength is! int) {
      throw const FormatException('Persisted capture fields are invalid.');
    }

    final identityJson = json['confirmedIdentity'];
    final rawAttachments = json['attachments'];
    final rawAnalysis = json['analysis'];
    return PersistedCapture(
      transportEventId: transportEventId,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(receivedAtEpochMs),
      origin: _enumByName(
        CaptureOrigin.values,
        json['origin'],
        CaptureOrigin.manual,
      ),
      sharedText: sharedText,
      discoveredUrl: json['discoveredUrl'] as String?,
      sourcePackage: json['sourcePackage'] as String?,
      mimeType: json['mimeType'] as String? ?? 'text/plain',
      wasTruncated: json['wasTruncated'] as bool? ?? false,
      originalLength: originalLength,
      status: _enumByName(
        CaptureStatus.values,
        json['status'],
        CaptureStatus.needsReview,
      ),
      reviewId: json['reviewId'] as String?,
      reviewResolution: json['reviewResolution'] == null
          ? null
          : _enumByName(
              ReviewResolution.values,
              json['reviewResolution'],
              ReviewResolution.deferred,
            ),
      reviewedAt: json['reviewedAtEpochMs'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              json['reviewedAtEpochMs']! as int,
            )
          : null,
      confirmedIdentity: identityJson is Map<String, Object?>
          ? ConfirmedProductIdentity(
              brand: identityJson['brand'] as String? ?? '',
              name: identityJson['name'] as String? ?? '',
              category: identityJson['category'] as String? ?? '',
              amount: identityJson['amount'] as String? ?? '',
            )
          : null,
      groupId: json['groupId'] as String?,
      tagOverride: _tagOverrideFromJson(json),
      attachments: rawAttachments is List<Object?>
          ? rawAttachments
                .whereType<Map<String, Object?>>()
                .map(IncomingAttachment.fromJson)
                .toList(growable: false)
          : const [],
      analysis: rawAnalysis is Map<String, Object?>
          ? _AnalysisRunCodec.fromJson(rawAnalysis)
          : null,
    );
  }

  final String transportEventId;
  final DateTime receivedAt;
  final CaptureOrigin origin;
  final String sharedText;
  final String? discoveredUrl;
  final String? sourcePackage;
  final String mimeType;
  final bool wasTruncated;
  final int originalLength;
  final CaptureStatus status;
  final String? reviewId;
  final ReviewResolution? reviewResolution;
  final DateTime? reviewedAt;
  final ConfirmedProductIdentity? confirmedIdentity;
  final String? groupId;

  /// The tags the reader settled on, when they have touched them.
  final List<ContentTag>? tagOverride;
  final List<IncomingAttachment> attachments;
  final AnalysisRun? analysis;

  IncomingShare toIncomingShare() {
    return IncomingShare(
      id: transportEventId,
      receivedAt: receivedAt,
      sharedText: sharedText,
      discoveredUrl: discoveredUrl,
      sourcePackage: sourcePackage,
      mimeType: mimeType,
      wasTruncated: wasTruncated,
      originalLength: originalLength,
      shareKind: attachments.isEmpty ? ShareKind.text : ShareKind.image,
      attachments: attachments,
    );
  }

  Map<String, Object?> toJson() {
    final identity = confirmedIdentity;
    return {
      'transportEventId': transportEventId,
      'receivedAtEpochMs': receivedAt.millisecondsSinceEpoch,
      'origin': origin.name,
      'sharedText': sharedText,
      'discoveredUrl': discoveredUrl,
      'sourcePackage': sourcePackage,
      'mimeType': mimeType,
      'wasTruncated': wasTruncated,
      'originalLength': originalLength,
      'status': status.name,
      'reviewId': reviewId,
      'reviewResolution': reviewResolution?.name,
      'reviewedAtEpochMs': reviewedAt?.millisecondsSinceEpoch,
      'confirmedIdentity': identity == null
          ? null
          : {
              'brand': identity.brand,
              'name': identity.name,
              'category': identity.category,
              'amount': identity.amount,
            },
      'groupId': groupId,
      'tagOverride': tagOverride?.map((tag) => tag.toJson()).toList(),
      'attachments': attachments.map((item) => item.toJson()).toList(),
      'analysis': analysis == null ? null : _AnalysisRunCodec.toJson(analysis!),
    };
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? raw,
    T fallback,
  ) {
    if (raw is! String) {
      return fallback;
    }
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return fallback;
  }
}

/// The reader's own tags, or the folder and subcategory they used to be.
///
/// A snapshot written before tags existed carries the two overrides a reader
/// could set then. Both were the reader's decision, so both come back as tags
/// they chose rather than as the analysis's suggestions.
List<ContentTag>? _tagOverrideFromJson(Map<String, Object?> json) {
  final stored = json['tagOverride'];
  if (stored is List<Object?>) {
    return dedupedTags([
      for (final entry in stored)
        if (entry is Map<String, Object?>) ContentTag.fromJson(entry, 'tag'),
    ]);
  }

  final legacy = <ContentTag>[];
  final folder = _legacyFolderTagName(json['folderOverride']);
  if (folder != null) {
    legacy.add(ContentTag(value: folder, source: TagSource.user));
  }
  final subcategory = json['subcategoryOverride'];
  if (subcategory is String) {
    final normalized = normalizeTagName(subcategory);
    if (isValidTagName(normalized)) {
      legacy.add(ContentTag(value: normalized, source: TagSource.user));
    }
  }
  return legacy.isEmpty ? null : dedupedTags(legacy);
}

/// The Korean name of a folder a reader had moved a capture into. Its enum name
/// is what the snapshot stored; 분류 필요 was the absence of a decision, so it
/// becomes no tag at all.
String? _legacyFolderTagName(Object? name) => switch (name) {
  'beauty' => '뷰티',
  'healthFitness' => '건강·운동',
  'restaurantCafe' => '맛집·카페',
  'recipe' => '레시피',
  'shopping' => '쇼핑',
  'travelPlace' => '여행·장소',
  'lifeTip' => '생활·팁',
  'other' => '기타',
  _ => null,
};
