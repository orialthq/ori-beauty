enum CaptureOrigin { androidShare, manual, portableTip, demo }

enum CaptureStatus {
  received,
  sourceLimited,
  analyzing,
  needsReview,
  organized,
  failed,
}

enum CaptureFilter { all, needsReview, organized, limitedOrFailed }

enum SourcePlatform { instagram, youtube, tiktok, x, web, textOnly }

enum MaterialCompleteness { complete, partial, linkOnly }

enum AnalysisRunStatus { succeeded, failed }

enum FieldOrigin { deterministicRule, catalogMatch, user }

enum EvidenceKind { sharedText, url, userInput, ocrText, imageRegion }

enum ShareKind { text, image }

enum ContentDomain { beauty, food, unknown }

/// Where a tag came from, so a suggestion is never mistaken for a decision, and
/// a web finding is never mistaken for something the screenshot showed.
///
/// The one field a later pass has to have: an AI tag can be rewritten when the
/// library learns that two names mean the same thing, and a tag the reader
/// typed never can.
enum TagSource { ai, user, web }

// `~` is allowed so a price band reads as 2~5만원 rather than 25만원.
final _tagNamePattern = RegExp(
  r'^[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+(?:[ ·ㆍ&/+~\-][가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+)*$',
);

/// Keeps AI and user-written tag names concise and safe to display.
String normalizeTagName(String value) {
  final collapsed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  final sanitized = collapsed
      .replaceAll(RegExp(r'[^0-9A-Za-z가-힣ㄱ-ㅎㅏ-ㅣ·ㆍ&/+~\- ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (sanitized.isEmpty) {
    return '기타';
  }
  final concise = String.fromCharCodes(sanitized.runes.take(20));
  return concise.runes.length < 2 ? '기타' : concise;
}

bool isValidTagName(String value) {
  final length = value.runes.length;
  return length >= 2 &&
      length <= 20 &&
      value == normalizeTagName(value) &&
      _tagNamePattern.hasMatch(value);
}

/// One word a capture is filed under.
///
/// Flat: there is no tag above or below another. A 을지로 국밥 capture carries
/// 맛집·카페, 국밥, 을지로 and 웨이팅 side by side, where the folder it used to
/// live in made it pick one of them and drop the rest.
///
/// Two tags are the same tag when their names match exactly. Deciding that
/// `스킨케어` and `스킨 케어` are one thing needs a corpus to measure, which the
/// library does not have yet; until then a near-duplicate is left standing
/// where it can be counted.
final class ContentTag {
  const ContentTag({
    required this.value,
    this.source = TagSource.ai,
    this.confidence = 1,
    this.evidenceIds = const [],
    this.quotes = const [],
    this.citations = const [],
  });

  factory ContentTag.fromJson(Map<String, Object?> json, String field) {
    _requireExactKeys(
      json,
      const {'value'},
      field,
      optional: const {
        'source',
        'confidence',
        'evidenceIds',
        'quotes',
        'citations',
      },
    );
    final value = _requiredString(json['value'], '$field.value');
    if (!isValidTagName(value)) {
      throw FormatException('Structured $field.value is not a reusable tag.');
    }
    return ContentTag(
      value: value,
      source: switch (json['source']) {
        'user' => TagSource.user,
        'web' => TagSource.web,
        _ => TagSource.ai,
      },
      confidence: json['confidence'] == null
          ? 1
          : _confidence(json['confidence'], '$field.confidence'),
      evidenceIds: _optionalStringList(
        json['evidenceIds'],
        '$field.evidenceIds',
      ),
      quotes: _optionalStringList(json['quotes'], '$field.quotes'),
      citations: _optionalStringList(json['citations'], '$field.citations'),
    );
  }

  final String value;
  final TagSource source;
  final double confidence;

  /// Which pieces of the screenshot this was read from.
  final List<String> evidenceIds;

  /// The text this tag was read from — menu lines on the screenshot, or the
  /// sentence a web page stated.
  final List<String> quotes;

  /// Pages a web tag came from. Empty for one read off the screen, which is
  /// backed by [evidenceIds] instead.
  final List<String> citations;

  ContentTag copyWith({TagSource? source}) => ContentTag(
    value: value,
    source: source ?? this.source,
    confidence: confidence,
    evidenceIds: evidenceIds,
    quotes: quotes,
    citations: citations,
  );

  Map<String, Object?> toJson() => {
    'value': value,
    'source': source.name,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
    'quotes': quotes,
    'citations': citations,
  };
}

/// [tags] with duplicates dropped, keeping the first of each name.
///
/// First wins because what the screenshot showed comes before what a later pass
/// added, and because a reader's own tag is placed ahead of the rest.
List<ContentTag> dedupedTags(Iterable<ContentTag> tags) {
  final seen = <String>{};
  return List<ContentTag>.unmodifiable([
    for (final tag in tags)
      if (seen.add(tag.value)) tag,
  ]);
}

enum ContentKind {
  beautyProduct,
  recipe,
  sauceRecipe,
  commerceProduct,
  productReview,
  menuComparison,
  place,
  unknown,
}

enum PlaceCategory {
  restaurant,
  cafe,
  beauty,
  shopping,
  lodging,
  activity,
  other,
}

enum StructuredCompleteness {
  complete,
  partial,
  conflicted,
  needsReview,
  unsupported,
}

enum ObservedStatus { observed, inferred, missing }

enum MissingField { brand, productName, category, amount }

enum StatementType {
  creatorClaim,
  usageExperience,
  usageMethod,
  drawback,
  disclosure,
}

enum DisclosureObservation {
  explicitlyObserved,
  notObservedInCapturedMaterial,
  unknown,
}

enum ReviewResolution { confirmed, corrected, unresolved, deferred }

enum ConfidenceBand { high, reviewRecommended, reviewRequired }

final class IncomingAttachment {
  const IncomingAttachment({
    required this.id,
    required this.filePath,
    required this.mimeType,
    required this.byteSize,
    required this.sha256,
    this.width,
    this.height,
  });

  factory IncomingAttachment.fromPlatformMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final filePath = map['filePath'];
    final mimeType = map['mimeType'];
    final byteSize = map['byteSize'];
    final sha256 = map['sha256'];
    if (id is! String ||
        id.isEmpty ||
        filePath is! String ||
        filePath.isEmpty ||
        mimeType is! String ||
        !mimeType.startsWith('image/') ||
        byteSize is! int ||
        byteSize <= 0 ||
        sha256 is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Incoming attachment is invalid.');
    }
    return IncomingAttachment(
      id: id,
      filePath: filePath,
      mimeType: mimeType,
      byteSize: byteSize,
      sha256: sha256,
      width: map['width'] as int?,
      height: map['height'] as int?,
    );
  }

  final String id;
  final String filePath;
  final String mimeType;
  final int byteSize;
  final int? width;
  final int? height;
  final String sha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'filePath': filePath,
    'mimeType': mimeType,
    'byteSize': byteSize,
    'width': width,
    'height': height,
    'sha256': sha256,
  };

  factory IncomingAttachment.fromJson(Map<String, Object?> json) {
    return IncomingAttachment.fromPlatformMap(json);
  }
}

final class IncomingShare {
  const IncomingShare({
    required this.id,
    required this.receivedAt,
    required this.sharedText,
    required this.discoveredUrl,
    this.sourcePackage,
    this.mimeType = 'text/plain',
    this.wasTruncated = false,
    this.originalLength,
    this.shareKind = ShareKind.text,
    this.attachments = const [],
    this.sourceDeletionAvailable = false,
  });

  factory IncomingShare.fromPlatformMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final receivedAtEpochMs = map['receivedAtEpochMs'];
    final sharedText = map['sharedText'];

    if (id is! String || id.isEmpty) {
      throw const FormatException('Incoming share id is missing.');
    }
    if (receivedAtEpochMs is! int) {
      throw const FormatException('Incoming share timestamp is invalid.');
    }
    if (sharedText is! String) {
      throw const FormatException('Incoming share text is invalid.');
    }

    final rawUrl = map['discoveredUrl'];
    final rawOriginalLength = map['originalLength'];
    final rawAttachments = map['attachments'];
    final attachments = rawAttachments is List<Object?>
        ? rawAttachments
              .whereType<Map<Object?, Object?>>()
              .map(IncomingAttachment.fromPlatformMap)
              .toList(growable: false)
        : const <IncomingAttachment>[];
    final rawShareKind = map['shareKind'];
    final shareKind =
        rawShareKind == ShareKind.image.name || attachments.isNotEmpty
        ? ShareKind.image
        : ShareKind.text;

    return IncomingShare(
      id: id,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(receivedAtEpochMs),
      sharedText: sharedText,
      discoveredUrl: rawUrl is String ? rawUrl : extractFirstUrl(sharedText),
      sourcePackage: map['sourcePackage'] as String?,
      mimeType: map['mimeType'] as String? ?? 'text/plain',
      wasTruncated: map['wasTruncated'] as bool? ?? false,
      originalLength: rawOriginalLength is int
          ? rawOriginalLength
          : sharedText.length,
      shareKind: shareKind,
      attachments: attachments,
      sourceDeletionAvailable: map['sourceDeletionAvailable'] == true,
    );
  }

  final String id;
  final DateTime receivedAt;
  final String sharedText;
  final String? discoveredUrl;
  final String? sourcePackage;
  final String mimeType;
  final bool wasTruncated;
  final int? originalLength;
  final ShareKind shareKind;
  final List<IncomingAttachment> attachments;
  final bool sourceDeletionAvailable;

  static String? extractFirstUrl(String text) {
    final match = RegExp(r'https?://[^\s]+').firstMatch(text);
    return match?.group(0)?.replaceFirst(RegExp(r'''[),.!?'"]+$'''), '');
  }
}

final class RawCapture {
  const RawCapture({
    required this.id,
    required this.transportEventId,
    required this.receivedAt,
    required this.origin,
    required this.mimeType,
    required this.rawText,
    required this.rawUrl,
    required this.semanticFingerprint,
    required this.wasTruncated,
    required this.originalLength,
    this.sourcePackage,
    this.userNote,
    this.attachments = const [],
  });

  final String id;
  final String transportEventId;
  final DateTime receivedAt;
  final CaptureOrigin origin;
  final String mimeType;

  /// Immutable user-provided material. Normalization never mutates this value.
  final String rawText;
  final String? rawUrl;
  final String semanticFingerprint;
  final bool wasTruncated;
  final int originalLength;
  final String? sourcePackage;
  final String? userNote;
  final List<IncomingAttachment> attachments;
}

final class NormalizedUrl {
  const NormalizedUrl({
    required this.rawValue,
    required this.canonicalValue,
    required this.platform,
  });

  final String rawValue;
  final String canonicalValue;
  final SourcePlatform platform;
}

final class NormalizedInput {
  const NormalizedInput({
    required this.inputId,
    required this.normalizerVersion,
    required this.normalizedText,
    required this.urls,
    required this.semanticFingerprint,
    required this.completeness,
    required this.warnings,
  });

  final String inputId;
  final String normalizerVersion;
  final String normalizedText;
  final List<NormalizedUrl> urls;
  final String semanticFingerprint;
  final MaterialCompleteness completeness;
  final List<String> warnings;
}

final class EvidenceRef {
  const EvidenceRef({
    required this.id,
    required this.captureId,
    required this.kind,
    required this.quote,
    this.startOffset,
    this.endOffset,
    this.attachmentId,
    this.region,
  });

  final String id;
  final String captureId;
  final EvidenceKind kind;
  final String quote;
  final int? startOffset;
  final int? endOffset;
  final String? attachmentId;
  final String? region;
}

final class ExtractedField<T> {
  const ExtractedField({
    required this.value,
    required this.confidence,
    required this.origin,
    required this.evidenceIds,
  }) : assert(confidence >= 0 && confidence <= 1);

  final T? value;
  final double confidence;
  final FieldOrigin origin;
  final List<String> evidenceIds;

  ConfidenceBand get confidenceBand {
    if (confidence >= 0.85) {
      return ConfidenceBand.high;
    }
    if (confidence >= 0.6) {
      return ConfidenceBand.reviewRecommended;
    }
    return ConfidenceBand.reviewRequired;
  }
}

final class ProductMention {
  const ProductMention({
    required this.id,
    required this.brand,
    required this.name,
    required this.category,
    required this.amount,
    required this.overallConfidence,
    required this.missingFields,
  }) : assert(overallConfidence >= 0 && overallConfidence <= 1);

  final String id;
  final ExtractedField<String> brand;
  final ExtractedField<String> name;
  final ExtractedField<String> category;
  final ExtractedField<String> amount;
  final double overallConfidence;
  final Set<MissingField> missingFields;

  ConfidenceBand get confidenceBand {
    if (overallConfidence >= 0.85) {
      return ConfidenceBand.high;
    }
    if (overallConfidence >= 0.6) {
      return ConfidenceBand.reviewRecommended;
    }
    return ConfidenceBand.reviewRequired;
  }

  bool get canGroupAutomatically =>
      overallConfidence >= 0.85 && missingFields.isEmpty;
}

final class ContentStatement {
  const ContentStatement({
    required this.id,
    required this.captureId,
    required this.mentionId,
    required this.type,
    required this.topic,
    required this.originalExpression,
    required this.evidenceIds,
  });

  final String id;
  final String captureId;
  final String? mentionId;
  final StatementType type;
  final String topic;
  final String originalExpression;
  final List<String> evidenceIds;
}

final class AnalysisRun {
  const AnalysisRun({
    required this.id,
    required this.inputId,
    required this.normalizerVersion,
    required this.analyzerVersion,
    required this.status,
    required this.completedAt,
    required this.evidence,
    required this.productMentions,
    required this.statements,
    required this.disclosure,
    this.failureCode,
    this.model,
    this.startedAt,
    this.attempt = 1,
    this.structuredContent,
  });

  final String id;
  final String inputId;
  final String normalizerVersion;
  final String analyzerVersion;
  final AnalysisRunStatus status;
  final DateTime completedAt;
  final List<EvidenceRef> evidence;
  final List<ProductMention> productMentions;
  final List<ContentStatement> statements;
  final DisclosureObservation disclosure;
  final String? failureCode;
  final String? model;
  final DateTime? startedAt;
  final int attempt;
  final StructuredContentAnalysis? structuredContent;
}

final class StructuredTitle {
  const StructuredTitle({
    required this.value,
    required this.status,
    required this.confidence,
    required this.evidenceIds,
  }) : assert(confidence >= 0 && confidence <= 1);

  factory StructuredTitle.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'value',
      'status',
      'confidence',
      'evidenceIds',
    }, 'title');
    final value = _nullableString(json['value'], 'title.value');
    final status = _observedStatus(json['status']);
    if ((status == ObservedStatus.missing && value != null) ||
        (status != ObservedStatus.missing && value == null)) {
      throw const FormatException('Structured title status is inconsistent.');
    }
    return StructuredTitle(
      value: value,
      status: status,
      confidence: _confidence(json['confidence'], 'title.confidence'),
      evidenceIds: _strictStringList(json['evidenceIds'], 'title.evidenceIds'),
    );
  }

  final String? value;
  final ObservedStatus status;
  final double confidence;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => {
    'value': value,
    'status': status.name,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
  };
}

final class StructuredEvidence {
  const StructuredEvidence({
    required this.id,
    required this.text,
    required this.region,
    required this.confidence,
  }) : assert(confidence >= 0 && confidence <= 1);

  factory StructuredEvidence.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'id',
      'text',
      'region',
      'confidence',
    }, 'evidence');
    final region = _requiredString(json['region'], 'evidence.region');
    if (!const {
      'image_text',
      'caption',
      'overlay',
      'product_panel',
      'menu',
      'unknown',
    }.contains(region)) {
      throw const FormatException('Structured evidence.region is invalid.');
    }
    return StructuredEvidence(
      id: _requiredString(json['id'], 'evidence.id'),
      text: _requiredString(json['text'], 'evidence.text'),
      region: region,
      confidence: _confidence(json['confidence'], 'evidence.confidence'),
    );
  }

  final String id;
  final String text;
  final String region;
  final double confidence;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'region': region,
    'confidence': confidence,
  };
}

final class RecipeIngredient {
  const RecipeIngredient({
    required this.name,
    required this.amount,
    required this.unit,
    required this.preparation,
    required this.optional,
    required this.originalText,
    required this.confidence,
    required this.evidenceIds,
  }) : assert(confidence >= 0 && confidence <= 1);

  factory RecipeIngredient.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'name',
      'amount',
      'unit',
      'preparation',
      'optional',
      'originalText',
      'confidence',
      'evidenceIds',
    }, 'ingredient');
    final optional = json['optional'];
    if (optional is! bool) {
      throw const FormatException('Structured ingredient.optional is invalid.');
    }
    return RecipeIngredient(
      name: _requiredString(json['name'], 'ingredient.name'),
      amount: _nullableString(json['amount'], 'ingredient.amount'),
      unit: _nullableString(json['unit'], 'ingredient.unit'),
      preparation: _nullableString(
        json['preparation'],
        'ingredient.preparation',
      ),
      optional: optional,
      originalText: _requiredString(
        json['originalText'],
        'ingredient.originalText',
      ),
      confidence: _confidence(json['confidence'], 'ingredient.confidence'),
      evidenceIds: _strictStringList(
        json['evidenceIds'],
        'ingredient.evidenceIds',
      ),
    );
  }

  final String name;
  final String? amount;
  final String? unit;
  final String? preparation;
  final bool optional;
  final String originalText;
  final double confidence;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => {
    'name': name,
    'amount': amount,
    'unit': unit,
    'preparation': preparation,
    'optional': optional,
    'originalText': originalText,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
  };
}

final class IngredientGroup {
  const IngredientGroup({required this.name, required this.ingredients});

  factory IngredientGroup.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {'name', 'ingredients'}, 'ingredientGroup');
    return IngredientGroup(
      name: _requiredString(json['name'], 'ingredientGroup.name'),
      ingredients: _strictMapList(
        json['ingredients'],
        'ingredientGroup.ingredients',
      ).map(RecipeIngredient.fromJson).toList(growable: false),
    );
  }

  final String name;
  final List<RecipeIngredient> ingredients;

  Map<String, Object?> toJson() => {
    'name': name,
    'ingredients': ingredients.map((item) => item.toJson()).toList(),
  };
}

final class RecipeStep {
  const RecipeStep({
    required this.order,
    required this.instruction,
    required this.durationSeconds,
    required this.temperature,
    required this.evidenceIds,
  });

  factory RecipeStep.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'order',
      'instruction',
      'durationSeconds',
      'temperature',
      'evidenceIds',
    }, 'step');
    final order = json['order'];
    final durationSeconds = json['durationSeconds'];
    if (order is! int || order < 1) {
      throw const FormatException('Structured step.order is invalid.');
    }
    if (durationSeconds != null &&
        (durationSeconds is! int || durationSeconds < 0)) {
      throw const FormatException(
        'Structured step.durationSeconds is invalid.',
      );
    }
    return RecipeStep(
      order: order,
      instruction: _requiredString(json['instruction'], 'step.instruction'),
      durationSeconds: durationSeconds as int?,
      temperature: _nullableString(json['temperature'], 'step.temperature'),
      evidenceIds: _strictStringList(json['evidenceIds'], 'step.evidenceIds'),
    );
  }

  final int order;
  final String instruction;
  final int? durationSeconds;
  final String? temperature;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => {
    'order': order,
    'instruction': instruction,
    'durationSeconds': durationSeconds,
    'temperature': temperature,
    'evidenceIds': evidenceIds,
  };
}

final class AnalysisFact {
  const AnalysisFact({
    required this.label,
    required this.value,
    required this.confidence,
    required this.evidenceIds,
  }) : assert(confidence >= 0 && confidence <= 1);

  factory AnalysisFact.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'label',
      'value',
      'confidence',
      'evidenceIds',
    }, 'fact');
    return AnalysisFact(
      label: _requiredString(json['label'], 'fact.label'),
      value: _requiredString(json['value'], 'fact.value'),
      confidence: _confidence(json['confidence'], 'fact.confidence'),
      evidenceIds: _strictStringList(json['evidenceIds'], 'fact.evidenceIds'),
    );
  }

  final String label;
  final String value;
  final double confidence;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => {
    'label': label,
    'value': value,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
  };
}

final class AnalysisConflict {
  const AnalysisConflict({
    required this.field,
    required this.details,
    required this.evidenceIds,
  });

  factory AnalysisConflict.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'field',
      'details',
      'evidenceIds',
    }, 'conflict');
    return AnalysisConflict(
      field: _requiredString(json['field'], 'conflict.field'),
      details: _requiredString(json['details'], 'conflict.details'),
      evidenceIds: _strictStringList(
        json['evidenceIds'],
        'conflict.evidenceIds',
      ),
    );
  }

  final String field;
  final String details;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => {
    'field': field,
    'details': details,
    'evidenceIds': evidenceIds,
  };
}

final class StructuredPlace {
  const StructuredPlace({
    required this.name,
    required this.address,
    required this.searchArea,
    required this.category,
    required this.confidence,
    required this.evidenceIds,
  });

  factory StructuredPlace.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const {'name', 'address', 'category', 'confidence', 'evidenceIds'},
      'place',
      // Added after the first captures were stored; those snapshots fall back to
      // deriving an area from the address.
      optional: const {'searchArea'},
    );
    return StructuredPlace(
      name: _nullableString(json['name'], 'place.name'),
      address: _nullableString(json['address'], 'place.address'),
      searchArea: _nullableString(json['searchArea'], 'place.searchArea'),
      category: _placeCategory(json['category']),
      confidence: _confidence(json['confidence'], 'place.confidence'),
      evidenceIds: _strictStringList(json['evidenceIds'], 'place.evidenceIds'),
    );
  }

  final String? name;
  final String? address;

  /// The words to search alongside the shop name, exactly as a person would type
  /// them: `성수`, `가로수길`, `홍대`. Read from the capture rather than derived,
  /// so a colloquial area beats the administrative district it sits in.
  final String? searchArea;

  final PlaceCategory? category;
  final double confidence;
  final List<String> evidenceIds;

  bool get hasAddress => address?.trim().isNotEmpty == true;

  Map<String, Object?> toJson() => {
    'name': name,
    'address': address,
    'searchArea': searchArea,
    'category': category?.name,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
  };
}

final class StructuredContentAnalysis {
  const StructuredContentAnalysis({
    required this.schemaVersion,
    required this.model,
    required this.domain,
    required this.contentKind,
    required this.tags,
    required this.completeness,
    required this.title,
    required this.place,
    required this.summary,
    required this.evidence,
    required this.ingredientGroups,
    required this.steps,
    required this.facts,
    required this.conflicts,
    required this.warnings,
  });

  factory StructuredContentAnalysis.fromJson(Map<String, Object?> json) {
    final normalizedJson = Map<String, Object?>.of(json);
    final declaredVersion = normalizedJson['schemaVersion'];
    normalizedJson.putIfAbsent('place', () => null);
    // Everything a capture used to be filed under — one folder, one
    // subcategory, four axes of labels — is one flat list of tags now. A
    // snapshot written before that is walked up through the versions it missed
    // and then flattened, so a reader's library survives the change without
    // being analysed again.
    //
    // Only when `tags` is missing: an old snapshot re-saved after this carries
    // the version it was analysed at and the tags it was flattened into.
    if (!normalizedJson.containsKey('tags')) {
      if (declaredVersion == '1.0') {
        normalizedJson.putIfAbsent(
          'primaryCategory',
          () => _legacyPrimaryCategory(normalizedJson),
        );
        normalizedJson.putIfAbsent(
          'categoryConfidence',
          () => _legacyCategoryConfidence(normalizedJson),
        );
      }
      if (declaredVersion == '1.0' || declaredVersion == '1.1') {
        normalizedJson.putIfAbsent(
          'subcategory',
          () => _legacySubcategory(normalizedJson),
        );
        normalizedJson.putIfAbsent(
          'subcategoryConfidence',
          () => _legacySubcategoryConfidence(normalizedJson),
        );
      }
      if (declaredVersion == '1.0' ||
          declaredVersion == '1.1' ||
          declaredVersion == '1.2') {
        normalizedJson.putIfAbsent('axes', () => _legacyAxes(normalizedJson));
      }
      normalizedJson['axes'] = _migratedAxes(normalizedJson['axes']);
      normalizedJson['tags'] = _tagsFromFiledFields(normalizedJson);
      for (final retired in const [
        'primaryCategory',
        'categoryConfidence',
        'subcategory',
        'subcategoryConfidence',
        'axes',
      ]) {
        normalizedJson.remove(retired);
      }
    }
    _requireExactKeys(normalizedJson, const {
      'schemaVersion',
      'model',
      'domain',
      'contentKind',
      'tags',
      'completeness',
      'title',
      'place',
      'summary',
      'evidence',
      'ingredientGroups',
      'steps',
      'facts',
      'conflicts',
      'warnings',
    }, 'analysis');
    final schemaVersion = _requiredString(
      normalizedJson['schemaVersion'],
      'analysis.schemaVersion',
    );
    final model = _requiredString(normalizedJson['model'], 'analysis.model');
    if (!const {
          '1.0',
          '1.1',
          '1.2',
          '1.3',
          '1.4',
          '1.5',
          '2.0',
        }.contains(schemaVersion) ||
        !const {'gpt-5.6-luna', 'portable-tip-v1'}.contains(model)) {
      throw const FormatException(
        'Structured analysis version or model is unsupported.',
      );
    }
    final result = StructuredContentAnalysis(
      schemaVersion: schemaVersion,
      model: model,
      domain: _contentDomain(normalizedJson['domain']),
      contentKind: _contentKind(normalizedJson['contentKind']),
      tags: dedupedTags([
        for (
          var index = 0;
          index < _strictMapList(normalizedJson['tags'], 'tags').length;
          index++
        )
          ContentTag.fromJson(
            _strictMapList(normalizedJson['tags'], 'tags')[index],
            'tags[$index]',
          ),
      ]),
      completeness: _structuredCompleteness(normalizedJson['completeness']),
      title: StructuredTitle.fromJson(
        _requiredMap(normalizedJson['title'], 'title'),
      ),
      place: normalizedJson['place'] == null
          ? null
          : StructuredPlace.fromJson(
              _requiredMap(normalizedJson['place'], 'place'),
            ),
      summary: _stringAllowEmpty(normalizedJson['summary'], 'analysis.summary'),
      evidence: _strictMapList(
        normalizedJson['evidence'],
        'analysis.evidence',
      ).map(StructuredEvidence.fromJson).toList(growable: false),
      ingredientGroups: _strictMapList(
        normalizedJson['ingredientGroups'],
        'analysis.ingredientGroups',
      ).map(IngredientGroup.fromJson).toList(growable: false),
      steps: _strictMapList(
        normalizedJson['steps'],
        'analysis.steps',
      ).map(RecipeStep.fromJson).toList(growable: false),
      facts: _strictMapList(
        normalizedJson['facts'],
        'analysis.facts',
      ).map(AnalysisFact.fromJson).toList(growable: false),
      conflicts: _strictMapList(
        normalizedJson['conflicts'],
        'analysis.conflicts',
      ).map(AnalysisConflict.fromJson).toList(growable: false),
      warnings: _strictStringList(
        normalizedJson['warnings'],
        'analysis.warnings',
      ),
    );
    result._validateEvidenceReferences();
    return result;
  }

  /// A copy carrying tags a later pass found, added behind the ones already
  /// here rather than displacing them.
  ///
  /// What the screenshot showed keeps its place at the front, and an incoming
  /// tag whose name is already present is dropped: the same word must never
  /// appear twice on one capture just because two sources agreed.
  StructuredContentAnalysis withTags(List<ContentTag> found) =>
      StructuredContentAnalysis(
        schemaVersion: schemaVersion,
        model: model,
        domain: domain,
        contentKind: contentKind,
        tags: dedupedTags([...tags, ...found]),
        completeness: completeness,
        title: title,
        place: place,
        summary: summary,
        evidence: evidence,
        ingredientGroups: ingredientGroups,
        steps: steps,
        facts: facts,
        conflicts: conflicts,
        warnings: warnings,
      );

  final String schemaVersion;
  final String model;
  final ContentDomain domain;
  final ContentKind contentKind;

  /// Every word this capture is filed under, flat and in the order the
  /// analysis gave them.
  final List<ContentTag> tags;
  final StructuredCompleteness completeness;
  final StructuredTitle title;
  final StructuredPlace? place;
  final String summary;
  final List<StructuredEvidence> evidence;
  final List<IngredientGroup> ingredientGroups;
  final List<RecipeStep> steps;
  final List<AnalysisFact> facts;
  final List<AnalysisConflict> conflicts;
  final List<String> warnings;

  bool get isRecipe =>
      contentKind == ContentKind.recipe ||
      contentKind == ContentKind.sauceRecipe;

  void _validateEvidenceReferences() {
    final ids = evidence.map((item) => item.id).toList(growable: false);
    if (ids.toSet().length != ids.length) {
      throw const FormatException(
        'Structured analysis has duplicate evidence ids.',
      );
    }
    final validIds = ids.toSet();
    final references = <String>[
      ...title.evidenceIds,
      ...?place?.evidenceIds,
      for (final group in ingredientGroups)
        for (final ingredient in group.ingredients) ...ingredient.evidenceIds,
      for (final step in steps) ...step.evidenceIds,
      for (final fact in facts) ...fact.evidenceIds,
      for (final conflict in conflicts) ...conflict.evidenceIds,
    ];
    if (references.any((id) => !validIds.contains(id))) {
      throw const FormatException(
        'Structured analysis references unknown evidence.',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'model': model,
    'domain': domain.name,
    'contentKind': switch (contentKind) {
      ContentKind.beautyProduct => 'beauty_product',
      ContentKind.sauceRecipe => 'sauce_recipe',
      ContentKind.commerceProduct => 'commerce_product',
      ContentKind.productReview => 'product_review',
      ContentKind.menuComparison => 'menu_comparison',
      ContentKind.place => 'place',
      _ => contentKind.name,
    },
    'tags': tags.map((tag) => tag.toJson()).toList(),
    'completeness': switch (completeness) {
      StructuredCompleteness.needsReview => 'needs_review',
      _ => completeness.name,
    },
    'title': title.toJson(),
    'place': place?.toJson(),
    'summary': summary,
    'evidence': evidence.map((item) => item.toJson()).toList(),
    'ingredientGroups': ingredientGroups.map((item) => item.toJson()).toList(),
    'steps': steps.map((item) => item.toJson()).toList(),
    'facts': facts.map((item) => item.toJson()).toList(),
    'conflicts': conflicts.map((item) => item.toJson()).toList(),
    'warnings': warnings,
  };
}

List<Map<String, Object?>> _strictMapList(Object? value, String field) {
  if (value is! List<Object?>) {
    throw FormatException('Structured $field is invalid.');
  }
  final result = <Map<String, Object?>>[];
  for (final item in value) {
    if (item is! Map<String, Object?>) {
      throw FormatException('Structured $field item is invalid.');
    }
    result.add(item);
  }
  return result;
}

Map<String, Object?> _requiredMap(Object? value, String field) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw FormatException('Structured analysis $field is invalid.');
}

List<String> _strictStringList(Object? value, String field) {
  if (value is! List<Object?> ||
      value.any((item) => item is! String || item.trim().isEmpty)) {
    throw FormatException('Structured $field is invalid.');
  }
  return value.cast<String>().toList(growable: false);
}

double _confidence(Object? value, String field) {
  if (value is! num || value < 0 || value > 1) {
    throw FormatException('Structured $field is invalid.');
  }
  return value.toDouble();
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Structured $field is invalid.');
  }
  return value;
}

String _stringAllowEmpty(Object? value, String field) {
  if (value is! String) {
    throw FormatException('Structured $field is invalid.');
  }
  return value;
}

List<String> _optionalStringList(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List) {
    throw FormatException('Structured $field is invalid.');
  }
  return List.unmodifiable(
    value.map((item) {
      if (item is! String) {
        throw FormatException('Structured $field is invalid.');
      }
      return item;
    }),
  );
}

String? _nullableString(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _requiredString(value, field);
}

/// Rejects unknown fields and missing required ones.
///
/// [optional] exists so a field added after a release can be read back from
/// snapshots written before it existed. Unknown keys are still refused, so the
/// contract stays closed.
void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String field, {
  Set<String> optional = const {},
}) {
  final allowed = {...expected, ...optional};
  if (json.keys.any((key) => !allowed.contains(key)) ||
      expected.any((key) => !json.containsKey(key))) {
    throw FormatException('Structured $field has unexpected fields.');
  }
}

ContentDomain _contentDomain(Object? value) {
  return switch (value) {
    'beauty' => ContentDomain.beauty,
    'food' => ContentDomain.food,
    'unknown' => ContentDomain.unknown,
    _ => throw const FormatException('Structured analysis.domain is invalid.'),
  };
}

ContentKind _contentKind(Object? value) {
  return switch (value) {
    'beauty_product' => ContentKind.beautyProduct,
    'recipe' => ContentKind.recipe,
    'sauce_recipe' => ContentKind.sauceRecipe,
    'commerce_product' => ContentKind.commerceProduct,
    'product_review' => ContentKind.productReview,
    'menu_comparison' => ContentKind.menuComparison,
    'place' => ContentKind.place,
    'unknown' => ContentKind.unknown,
    _ => throw const FormatException(
      'Structured analysis.contentKind is invalid.',
    ),
  };
}

/// The tags an older analysis was already carrying, under other names.
///
/// The folder it sat in, the subcategory it was given, and every axis label
/// were each a word the capture is filed under. Flattening them loses nothing
/// but the shelf they stood on.
List<Map<String, Object?>> _tagsFromFiledFields(Map<String, Object?> json) {
  final tags = <Map<String, Object?>>[];

  // A folder the analysis was not sure of is left out. It used to put the
  // capture in 분류 필요 rather than name it, and a capture with no tags is how
  // that reads now.
  final folderConfidence = json['categoryConfidence'];
  final folder = _folderTagName(json['primaryCategory']);
  if (folder != null && folderConfidence is num && folderConfidence >= 0.72) {
    tags.add({
      'value': folder,
      'source': 'ai',
      'confidence': folderConfidence.toDouble(),
    });
  }

  final subcategory = json['subcategory'];
  if (subcategory is String && isValidTagName(subcategory)) {
    final confidence = json['subcategoryConfidence'];
    tags.add({
      'value': subcategory,
      'source': 'ai',
      if (confidence is num) 'confidence': confidence.toDouble(),
    });
  }

  final axes = json['axes'];
  if (axes is Map<String, Object?>) {
    for (final labels in axes.values) {
      if (labels is! List<Object?>) continue;
      for (final label in labels) {
        if (label is! Map<String, Object?>) continue;
        final value = label['value'];
        if (value is! String || !isValidTagName(value)) continue;
        tags.add({
          'value': value,
          'source': label['source'] is String ? label['source'] : 'ai',
          if (label['confidence'] != null) 'confidence': label['confidence'],
          if (label['evidenceIds'] != null) 'evidenceIds': label['evidenceIds'],
          if (label['quotes'] != null) 'quotes': label['quotes'],
          if (label['citations'] != null) 'citations': label['citations'],
        });
      }
    }
  }
  return tags;
}

/// The Korean name of a folder, which is what a reader always saw. The wire
/// names are what the snapshots stored.
String? _folderTagName(Object? wireName) => switch (wireName) {
  'beauty' => '뷰티',
  'health_fitness' => '건강·운동',
  'restaurant_cafe' => '맛집·카페',
  'recipe' => '레시피',
  'shopping' => '쇼핑',
  'travel_place' => '여행·장소',
  'life_tip' => '생활·팁',
  'other' => '기타',
  _ => null,
};

String _legacyPrimaryCategory(Map<String, Object?> json) {
  final kind = json['contentKind'];
  if (kind == 'recipe' || kind == 'sauce_recipe') {
    return 'recipe';
  }
  final place = json['place'];
  final placeCategory = place is Map<String, Object?>
      ? place['category']
      : null;
  if (placeCategory == 'restaurant' || placeCategory == 'cafe') {
    return 'restaurant_cafe';
  }
  if (placeCategory == 'lodging' || placeCategory == 'activity') {
    return 'travel_place';
  }
  if (placeCategory == 'beauty' || json['domain'] == 'beauty') {
    return 'beauty';
  }
  if (placeCategory == 'shopping') {
    return 'shopping';
  }
  if (kind == 'menu_comparison') {
    return 'restaurant_cafe';
  }
  if (json['domain'] == 'food') {
    return 'shopping';
  }
  return 'other';
}

double _legacyCategoryConfidence(Map<String, Object?> json) {
  return _legacyPrimaryCategory(json) == 'other' ? 0 : 1;
}

/// Rebuilds axes for a capture stored before they existed.
///
/// Only what the older record actually held is carried over: the single
/// subcategory becomes the one kind label, and a place area becomes the one
/// location label. The remaining axes stay empty rather than being guessed from
/// content nobody classified that way.
Map<String, Object?> _legacyAxes(Map<String, Object?> json) {
  Map<String, Object?> label(String value, Object? confidence) => {
    'value': value,
    'confidence': confidence is num ? confidence.toDouble() : 0.0,
    'evidenceIds': const <String>[],
  };

  final kind = <Map<String, Object?>>[];
  final subcategory = json['subcategory'];
  if (subcategory is String && isValidTagName(subcategory)) {
    kind.add(label(subcategory, json['subcategoryConfidence']));
  }

  final location = <Map<String, Object?>>[];
  final place = json['place'];
  final area = place is Map<String, Object?> ? place['searchArea'] : null;
  if (area is String && isValidTagName(area)) {
    location.add(
      label(area, place is Map<String, Object?> ? place['confidence'] : 0),
    );
  }

  return {
    'kind': kind,
    'location': location,
    'access': const <Map<String, Object?>>[],
    'savedReason': const <Map<String, Object?>>[],
  };
}

/// Carries a stored capture across every axis change so far.
///
/// 상황 and 가격대 went in 1.4, 인원 in 1.5. Each was dropped rather than
/// remapped: nothing in a 데이트, a 2~5만원, or a 단체 가능 says whether the place
/// takes bookings. Retired labels are discarded and any new axis starts empty,
/// filling on the next web lookup.
///
/// 인원 in particular was not wrong, it was useless — 단체 가능 came back true for
/// all ten shops it was measured on, and a label on every card cannot filter.
///
/// Dropping beats refusing to load. A capture the reader saved is theirs, and
/// losing its title and photo to a schema change they never asked for would be
/// the worse failure.
Map<String, Object?> _migratedAxes(Object? stored) {
  const empty = <Map<String, Object?>>[];
  if (stored is! Map<String, Object?>) {
    return {
      'kind': empty,
      'location': empty,
      'access': empty,
      'savedReason': empty,
    };
  }
  return {
    for (final axis in const ['kind', 'location', 'access', 'savedReason'])
      axis: stored[axis] ?? empty,
  };
}

String _legacySubcategory(Map<String, Object?> json) {
  final kind = json['contentKind'];
  if (kind == 'sauce_recipe') {
    return '소스·양념';
  }
  if (kind == 'recipe') {
    return '요리';
  }

  final place = json['place'];
  final placeCategory = place is Map<String, Object?>
      ? place['category']
      : null;
  final placeSubcategory = switch (placeCategory) {
    'restaurant' => '식당',
    'cafe' => '카페·디저트',
    'beauty' => '뷰티숍',
    'shopping' => '쇼핑 장소',
    'lodging' => '숙소',
    'activity' => '체험',
    'other' => '장소',
    _ => null,
  };
  if (placeSubcategory != null) {
    return placeSubcategory;
  }

  final title = json['title'];
  final titleValue = title is Map<String, Object?>
      ? title['value'] as String?
      : null;
  if (json['domain'] == 'beauty' || kind == 'beauty_product') {
    return _legacyProductSubcategory(
      titleValue,
      preserveUnrecognizedCategory: false,
    );
  }
  if (kind == 'menu_comparison') {
    return '메뉴';
  }
  if (kind == 'commerce_product' || kind == 'product_review') {
    return '상품';
  }
  if (json['domain'] == 'food') {
    return '식품';
  }
  return '기타';
}

double _legacySubcategoryConfidence(Map<String, Object?> json) {
  return _legacySubcategory(json) == '기타' ? 0 : 0.6;
}

String _legacyProductSubcategory(
  String? category, {
  bool preserveUnrecognizedCategory = true,
}) {
  final normalized = category?.toLowerCase().trim() ?? '';
  if (RegExp(r'세럼|앰플|토너|스킨|에센스|크림|로션|선케어|선크림|클렌|마스크|패드').hasMatch(normalized)) {
    return '스킨케어';
  }
  if (RegExp(r'메이크업|립|틴트|파운데이션|쿠션|컨실러|블러셔|아이섀도|마스카라').hasMatch(normalized)) {
    return '메이크업';
  }
  if (RegExp(r'헤어|샴푸|트리트먼트|바디|바디워시').hasMatch(normalized)) {
    return '헤어·바디';
  }
  if (normalized.contains('네일')) {
    return '네일';
  }
  if (normalized.contains('향수') || normalized.contains('퍼퓸')) {
    return '향수';
  }
  if (normalized.isEmpty || !preserveUnrecognizedCategory) {
    return '뷰티';
  }
  return normalizeTagName(category!);
}

PlaceCategory? _placeCategory(Object? value) {
  return switch (value) {
    null => null,
    'restaurant' => PlaceCategory.restaurant,
    'cafe' => PlaceCategory.cafe,
    'beauty' => PlaceCategory.beauty,
    'shopping' => PlaceCategory.shopping,
    'lodging' => PlaceCategory.lodging,
    'activity' => PlaceCategory.activity,
    'other' => PlaceCategory.other,
    _ => throw const FormatException('Structured place.category is invalid.'),
  };
}

StructuredCompleteness _structuredCompleteness(Object? value) {
  return switch (value) {
    'complete' => StructuredCompleteness.complete,
    'partial' => StructuredCompleteness.partial,
    'conflicted' => StructuredCompleteness.conflicted,
    'needs_review' => StructuredCompleteness.needsReview,
    'unsupported' => StructuredCompleteness.unsupported,
    _ => throw const FormatException(
      'Structured analysis.completeness is invalid.',
    ),
  };
}

ObservedStatus _observedStatus(Object? value) {
  return switch (value) {
    'observed' => ObservedStatus.observed,
    'inferred' => ObservedStatus.inferred,
    'missing' => ObservedStatus.missing,
    _ => throw const FormatException('Structured title.status is invalid.'),
  };
}

final class ConfirmedProductIdentity {
  const ConfirmedProductIdentity({
    required this.brand,
    required this.name,
    required this.category,
    required this.amount,
  });

  final String brand;
  final String name;
  final String category;
  final String amount;

  String get identityKey =>
      [brand, name, category, amount].map(_normalizeIdentityPart).join('|');

  static String _normalizeIdentityPart(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9가-힣]'), '');
  }
}

final class UserReview {
  const UserReview({
    required this.id,
    required this.captureId,
    required this.analysisRunId,
    required this.resolution,
    required this.reviewedAt,
    this.candidateId,
    this.confirmedIdentity,
  });

  final String id;
  final String captureId;
  final String analysisRunId;
  final ReviewResolution resolution;
  final DateTime reviewedAt;
  final String? candidateId;
  final ConfirmedProductIdentity? confirmedIdentity;
}

final class CaptureRecord {
  const CaptureRecord({
    required this.raw,
    required this.normalized,
    required this.status,
    required this.analysis,
    this.review,
    this.groupId,
    this.tagOverride,
  });

  final RawCapture raw;
  final NormalizedInput normalized;
  final CaptureStatus status;
  final AnalysisRun? analysis;
  final UserReview? review;
  final String? groupId;

  /// The tags the reader settled on, when they have touched them.
  ///
  /// Null means they have not, and the analysis's own tags stand. Kept beside
  /// the analysis rather than written into it, so a correction never overwrites
  /// what the model actually said.
  final List<ContentTag>? tagOverride;

  ProductMention? get primaryMention {
    final mentions = analysis?.productMentions;
    return mentions == null || mentions.isEmpty ? null : mentions.first;
  }

  /// Every word this capture is filed under.
  ///
  /// Empty is a real answer: a capture the analysis could not place carries no
  /// tags, which is what 분류 필요 used to say by putting it in a folder named
  /// after not knowing.
  List<ContentTag> get contentTags {
    final override = tagOverride;
    if (override != null) return dedupedTags(override);

    final structured = analysis?.structuredContent;
    if (structured != null) return structured.tags;

    // A capture from before the analyser read images at all. Its product
    // category is the one word it ever had.
    final mention = primaryMention;
    if (mention != null) {
      return dedupedTags([
        ContentTag(
          value: _legacyProductSubcategory(mention.category.value),
          confidence: mention.category.confidence,
        ),
      ]);
    }
    return const <ContentTag>[];
  }

  bool hasTag(String value) => contentTags.any((tag) => tag.value == value);

  CaptureRecord copyWith({
    CaptureStatus? status,
    AnalysisRun? analysis,
    UserReview? review,
    String? groupId,
    List<ContentTag>? tagOverride,
  }) {
    return CaptureRecord(
      raw: raw,
      normalized: normalized,
      status: status ?? this.status,
      analysis: analysis ?? this.analysis,
      review: review ?? this.review,
      groupId: groupId ?? this.groupId,
      tagOverride: tagOverride ?? this.tagOverride,
    );
  }
}

final class ProductGroup {
  const ProductGroup({
    required this.id,
    required this.identity,
    required this.sourceCaptureIds,
    required this.statements,
    required this.updatedAt,
    required this.colorValue,
  });

  final String id;
  final ConfirmedProductIdentity identity;
  final List<String> sourceCaptureIds;
  final List<ContentStatement> statements;
  final DateTime updatedAt;
  final int colorValue;

  int get sourceCount => sourceCaptureIds.length;

  ProductGroup addSource({
    required String captureId,
    required List<ContentStatement> sourceStatements,
    required DateTime at,
  }) {
    final sourceIds = {...sourceCaptureIds, captureId}.toList(growable: false);
    final statementIds = statements.map((statement) => statement.id).toSet();

    return ProductGroup(
      id: id,
      identity: identity,
      sourceCaptureIds: sourceIds,
      statements: [
        ...statements,
        ...sourceStatements.where(
          (statement) => !statementIds.contains(statement.id),
        ),
      ],
      updatedAt: at,
      colorValue: colorValue,
    );
  }
}
