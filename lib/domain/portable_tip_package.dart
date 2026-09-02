import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// A small, platform-neutral package for moving selected Trun On information
/// between Android and iOS.
///
/// The format deliberately has no field for screenshots, attachment paths,
/// OCR evidence, raw captured text, source package names, fingerprints, or the
/// original capture id. Callers must explicitly pass every detail that should
/// leave the device.
final class PortableTipPackage {
  PortableTipPackage._({
    required this.packageId,
    required this.exportedAt,
    required this.title,
    required this.summary,
    required this.tags,
    required this.facts,
    required this.ingredientGroups,
    required this.steps,
    required this.notes,
    required this.place,
    required this.source,
    required this.message,
  });

  factory PortableTipPackage.create({
    required String packageId,
    required DateTime exportedAt,
    required String title,
    required String summary,
    required Iterable<String> tags,
    Iterable<PortableTipFact> facts = const [],
    Iterable<PortableTipIngredientGroup> ingredientGroups = const [],
    Iterable<PortableTipStep> steps = const [],
    Iterable<String> notes = const [],
    PortableTipPlace? place,
    PortableTipSource? source,
    String? message,
  }) {
    final safePackageId = _validatedId(packageId, 'packageId');
    final exportedAtEpochMs = exportedAt.millisecondsSinceEpoch;
    if (exportedAtEpochMs < 0 ||
        exportedAtEpochMs > PortableTipLimits.maxEpochMilliseconds) {
      throw const FormatException('Portable tip timestamp is invalid.');
    }
    final safeFacts = _uniqueBy(
      facts,
      (fact) => '${fact.label}\u0000${fact.value}',
    );
    final safeGroups = ingredientGroups.toList(growable: false);
    final safeSteps = steps.toList(growable: false);
    final safeNotes = _sanitizedUniqueTextList(
      notes,
      field: 'note',
      maxRunes: PortableTipLimits.maxItemRunes,
    );
    if (safeFacts.length > PortableTipLimits.maxFacts ||
        safeGroups.length > PortableTipLimits.maxIngredientGroups ||
        safeSteps.length > PortableTipLimits.maxSteps ||
        safeNotes.length > PortableTipLimits.maxNotes) {
      throw const FormatException('Portable tip has too many detail items.');
    }
    final stepOrders = safeSteps.map((step) => step.order).toSet();
    if (stepOrders.length != safeSteps.length) {
      throw const FormatException('Portable tip has duplicate step orders.');
    }
    final ingredientCount = safeGroups.fold<int>(
      0,
      (count, group) => count + group.ingredients.length,
    );
    final itemCount =
        safeFacts.length +
        ingredientCount +
        safeSteps.length +
        safeNotes.length;
    if (itemCount > PortableTipLimits.maxTotalItems) {
      throw const FormatException('Portable tip has too many detail items.');
    }

    return PortableTipPackage._(
      packageId: safePackageId,
      exportedAt: exportedAt.toUtc(),
      title: _requiredText(
        title,
        field: 'title',
        maxRunes: PortableTipLimits.maxTitleRunes,
      ),
      summary:
          _optionalText(
            summary,
            field: 'summary',
            maxRunes: PortableTipLimits.maxSummaryRunes,
          ) ??
          '',
      tags: List.unmodifiable(_safeTagNames(tags)),
      facts: List.unmodifiable(safeFacts),
      ingredientGroups: List.unmodifiable(safeGroups),
      steps: List.unmodifiable(safeSteps),
      notes: List.unmodifiable(safeNotes),
      place: place,
      source: source,
      message: _optionalText(
        message,
        field: 'message',
        maxRunes: PortableTipLimits.maxMessageRunes,
      ),
    );
  }

  /// Builds a package from a structured capture. The caller supplies exact
  /// fact, ingredient-group, and step subsets; empty iterables export nothing
  /// from that section. Place and source are opt-in as well.
  factory PortableTipPackage.fromStructuredCapture({
    required String packageId,
    required DateTime exportedAt,
    required CaptureRecord capture,
    Iterable<AnalysisFact> selectedFacts = const [],
    Iterable<IngredientGroup> selectedIngredientGroups = const [],
    Iterable<RecipeStep> selectedSteps = const [],
    Iterable<String> notes = const [],
    bool includePlace = false,
    bool includeSource = false,
    String? sourceLabel,
    String? message,
  }) {
    final analysis = capture.analysis?.structuredContent;
    if (analysis == null) {
      throw StateError('A structured capture is required to export a tip.');
    }
    final place = analysis.place;
    final hasPlace =
        place?.name?.trim().isNotEmpty == true ||
        place?.address?.trim().isNotEmpty == true;
    final title = analysis.title.value?.trim();
    return PortableTipPackage.create(
      packageId: packageId,
      exportedAt: exportedAt,
      title: title == null || title.isEmpty ? '제목 없음' : title,
      summary: analysis.summary,
      tags: capture.contentTags.map((tag) => tag.value),
      facts: selectedFacts.map(PortableTipFact.fromAnalysisFact),
      ingredientGroups: selectedIngredientGroups.map(
        PortableTipIngredientGroup.fromIngredientGroup,
      ),
      steps: selectedSteps.map(PortableTipStep.fromRecipeStep),
      notes: notes,
      place: includePlace && hasPlace
          ? PortableTipPlace(name: place!.name, address: place.address)
          : null,
      source: includeSource && capture.raw.rawUrl != null
          ? PortableTipSource(label: sourceLabel, url: capture.raw.rawUrl!)
          : null,
      message: message,
    );
  }

  /// Supports the legacy product detail path without exporting source capture
  /// ids. Only [selectedStatements] become package notes.
  factory PortableTipPackage.fromProductGroup({
    required String packageId,
    required DateTime exportedAt,
    required ProductGroup group,
    required Iterable<String> tags,
    Iterable<ContentStatement> selectedStatements = const [],
    String? message,
  }) {
    final identity = group.identity;
    final summary = <String>[
      identity.brand,
      identity.category,
      identity.amount,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return PortableTipPackage.create(
      packageId: packageId,
      exportedAt: exportedAt,
      title: identity.name,
      summary: summary,
      tags: tags,
      notes: selectedStatements.map(
        (statement) => statement.topic.trim().isEmpty
            ? statement.originalExpression
            : '${statement.topic}: ${statement.originalExpression}',
      ),
      message: message,
    );
  }

  final String packageId;
  final DateTime exportedAt;
  final String title;
  final String summary;

  /// What the sender had this filed under, by name.
  ///
  /// Names only: the receiver's library keeps its own record of where a tag
  /// came from, and a tag arriving from someone else has no evidence in *this*
  /// reader's captures to point at.
  final List<String> tags;
  final List<PortableTipFact> facts;
  final List<PortableTipIngredientGroup> ingredientGroups;
  final List<PortableTipStep> steps;
  final List<String> notes;
  final PortableTipPlace? place;
  final PortableTipSource? source;
  final String? message;

  /// Presentation-only sections for cards and previews. Structured values
  /// remain available in [facts], [ingredientGroups], and [steps].
  List<PortableTipSection> get sections => List.unmodifiable([
    if (facts.isNotEmpty)
      PortableTipSection._(
        kind: PortableTipSectionKind.facts,
        title: '알아둘 점',
        items: facts.map((fact) => fact.displayText).toList(),
      ),
    if (ingredientGroups.isNotEmpty)
      PortableTipSection._(
        kind: PortableTipSectionKind.ingredients,
        title: '재료',
        items: [
          for (final group in ingredientGroups)
            for (final ingredient in group.ingredients)
              '[${group.name}] ${ingredient.displayText}',
        ],
      ),
    if (steps.isNotEmpty)
      PortableTipSection._(
        kind: PortableTipSectionKind.steps,
        title: '방법',
        items: steps.map((step) => step.displayText).toList(),
      ),
    if (notes.isNotEmpty)
      PortableTipSection._(
        kind: PortableTipSectionKind.notes,
        title: '메모',
        items: notes,
      ),
  ]);
}

enum PortableTipSectionKind { facts, ingredients, steps, notes }

/// Read-only, derived card content. This is not the transport representation.
final class PortableTipSection {
  const PortableTipSection._({
    required this.kind,
    required this.title,
    required this.items,
  });

  final PortableTipSectionKind kind;
  final String title;
  final List<String> items;
}

final class PortableTipFact {
  factory PortableTipFact({required String label, required String value}) {
    return PortableTipFact._(
      label: _requiredText(
        label,
        field: 'fact.label',
        maxRunes: PortableTipLimits.maxLabelRunes,
      ),
      value: _requiredText(
        value,
        field: 'fact.value',
        maxRunes: PortableTipLimits.maxItemRunes,
      ),
    );
  }

  factory PortableTipFact.fromAnalysisFact(AnalysisFact fact) {
    return PortableTipFact(label: fact.label, value: fact.value);
  }

  const PortableTipFact._({required this.label, required this.value});

  final String label;
  final String value;

  String get displayText => '$label: $value';
}

final class PortableTipIngredientGroup {
  factory PortableTipIngredientGroup({
    required String name,
    required Iterable<PortableTipIngredient> ingredients,
  }) {
    final safeIngredients = _uniqueBy(
      ingredients,
      (ingredient) => jsonEncode([
        ingredient.name,
        ingredient.amount,
        ingredient.unit,
        ingredient.preparation,
        ingredient.optional,
        ingredient.originalText,
      ]),
    );
    if (safeIngredients.isEmpty ||
        safeIngredients.length > PortableTipLimits.maxIngredientsPerGroup) {
      throw const FormatException(
        'Portable tip ingredient group size is invalid.',
      );
    }
    return PortableTipIngredientGroup._(
      name: _requiredText(
        name,
        field: 'ingredientGroup.name',
        maxRunes: PortableTipLimits.maxLabelRunes,
      ),
      ingredients: List.unmodifiable(safeIngredients),
    );
  }

  factory PortableTipIngredientGroup.fromIngredientGroup(
    IngredientGroup group,
  ) {
    return PortableTipIngredientGroup(
      name: group.name,
      ingredients: group.ingredients.map(PortableTipIngredient.fromRecipe),
    );
  }

  const PortableTipIngredientGroup._({
    required this.name,
    required this.ingredients,
  });

  final String name;
  final List<PortableTipIngredient> ingredients;
}

final class PortableTipIngredient {
  factory PortableTipIngredient({
    required String name,
    String? amount,
    String? unit,
    String? preparation,
    required bool optional,
    required String originalText,
  }) {
    return PortableTipIngredient._(
      name: _requiredText(
        name,
        field: 'ingredient.name',
        maxRunes: PortableTipLimits.maxLabelRunes,
      ),
      amount: _optionalText(
        amount,
        field: 'ingredient.amount',
        maxRunes: PortableTipLimits.maxShortValueRunes,
      ),
      unit: _optionalText(
        unit,
        field: 'ingredient.unit',
        maxRunes: PortableTipLimits.maxShortValueRunes,
      ),
      preparation: _optionalText(
        preparation,
        field: 'ingredient.preparation',
        maxRunes: PortableTipLimits.maxShortValueRunes,
      ),
      optional: optional,
      originalText: _requiredText(
        originalText,
        field: 'ingredient.originalText',
        maxRunes: PortableTipLimits.maxItemRunes,
      ),
    );
  }

  factory PortableTipIngredient.fromRecipe(RecipeIngredient ingredient) {
    return PortableTipIngredient(
      name: ingredient.name,
      amount: ingredient.amount,
      unit: ingredient.unit,
      preparation: ingredient.preparation,
      optional: ingredient.optional,
      originalText: ingredient.originalText,
    );
  }

  const PortableTipIngredient._({
    required this.name,
    required this.amount,
    required this.unit,
    required this.preparation,
    required this.optional,
    required this.originalText,
  });

  final String name;
  final String? amount;
  final String? unit;
  final String? preparation;
  final bool optional;
  final String originalText;

  String get displayText => originalText;
}

final class PortableTipStep {
  factory PortableTipStep({
    required int order,
    required String instruction,
    int? durationSeconds,
    String? temperature,
  }) {
    if (order < 1 ||
        durationSeconds != null &&
            (durationSeconds < 0 ||
                durationSeconds > PortableTipLimits.maxDurationSeconds)) {
      throw const FormatException('Portable tip step values are invalid.');
    }
    return PortableTipStep._(
      order: order,
      instruction: _requiredText(
        instruction,
        field: 'step.instruction',
        maxRunes: PortableTipLimits.maxItemRunes,
      ),
      durationSeconds: durationSeconds,
      temperature: _optionalText(
        temperature,
        field: 'step.temperature',
        maxRunes: PortableTipLimits.maxShortValueRunes,
      ),
    );
  }

  factory PortableTipStep.fromRecipeStep(RecipeStep step) {
    return PortableTipStep(
      order: step.order,
      instruction: step.instruction,
      durationSeconds: step.durationSeconds,
      temperature: step.temperature,
    );
  }

  const PortableTipStep._({
    required this.order,
    required this.instruction,
    required this.durationSeconds,
    required this.temperature,
  });

  final int order;
  final String instruction;
  final int? durationSeconds;
  final String? temperature;

  String get displayText {
    final qualifiers = <String>[
      ?temperature,
      if (durationSeconds != null) '$durationSeconds초',
    ];
    final suffix = qualifiers.isEmpty ? '' : ' (${qualifiers.join(' · ')})';
    return '$order. $instruction$suffix';
  }
}

final class PortableTipPlace {
  factory PortableTipPlace({String? name, String? address}) {
    final safeName = _optionalText(
      name,
      field: 'place.name',
      maxRunes: PortableTipLimits.maxPlaceNameRunes,
    );
    final safeAddress = _optionalText(
      address,
      field: 'place.address',
      maxRunes: PortableTipLimits.maxAddressRunes,
    );
    if (safeName == null && safeAddress == null) {
      throw const FormatException('Portable tip place must not be empty.');
    }
    return PortableTipPlace._(name: safeName, address: safeAddress);
  }

  const PortableTipPlace._({required this.name, required this.address});

  final String? name;
  final String? address;
}

final class PortableTipSource {
  factory PortableTipSource({String? label, required String url}) {
    return PortableTipSource._(
      label: _optionalText(
        label,
        field: 'source.label',
        maxRunes: PortableTipLimits.maxSourceLabelRunes,
      ),
      url: _safeSourceUrl(url),
    );
  }

  const PortableTipSource._({required this.label, required this.url});

  final String? label;
  final String url;
}

/// An imported tip always owns a fresh local id. [sourcePackageId] is retained
/// only for duplicate detection and is never used as the local storage id.
final class ImportedPortableTip {
  const ImportedPortableTip({
    required this.localId,
    required this.sourcePackageId,
    required this.importedAt,
    required this.tip,
  });

  final String localId;
  final String sourcePackageId;
  final DateTime importedAt;
  final PortableTipPackage tip;
}

abstract final class PortableTipLimits {
  static const maxPackageBytes = 64 * 1024;
  static const maxEpochMilliseconds = 8640000000000000;
  static const maxTitleRunes = 120;
  static const maxTags = 12;
  static const maxSummaryRunes = 500;
  static const maxMessageRunes = 280;
  static const maxLabelRunes = 60;
  static const maxShortValueRunes = 80;
  static const maxItemRunes = 500;
  static const maxFacts = 24;
  static const maxIngredientGroups = 12;
  static const maxIngredientsPerGroup = 24;
  static const maxSteps = 32;
  static const maxNotes = 24;
  static const maxTotalItems = 64;
  static const maxDurationSeconds = 24 * 60 * 60;
  static const maxPlaceNameRunes = 120;
  static const maxAddressRunes = 240;
  static const maxSourceLabelRunes = 60;
  static const maxSourceUrlRunes = 2048;
}

final class UnsupportedPortableTipVersionException extends FormatException {
  const UnsupportedPortableTipVersionException(this.receivedVersion)
    : super('이 팁은 더 최신 버전의 Trun On에서 만들었어요. 앱을 업데이트해 주세요.');

  final Object? receivedVersion;
}

/// Codec contract shared by Android and iOS file handlers.
///
/// Unknown JSON fields are rejected so future clients cannot accidentally
/// treat private/raw payloads as v1 tips.
abstract final class PortableTipPackageCodec {
  static const format = 'com.orialthq.trunon.portable-tip';
  static const schemaVersion = 2;

  /// Version 1 filed a tip under one category and one subcategory. Those are
  /// two tags, so a tip a friend sent before this still opens.
  static const supportedVersions = {1, 2};
  static const fileExtension = 'trunon';
  static const mimeType = 'application/vnd.orialthq.trunon.tip+json';
  static const uniformTypeIdentifier = 'com.orialthq.trunon.tip';

  static String encode(PortableTipPackage package) {
    final encoded = jsonEncode(_toJson(package));
    _validateByteSize(utf8.encode(encoded).length);
    return encoded;
  }

  static Uint8List encodeUtf8(PortableTipPackage package) {
    return Uint8List.fromList(utf8.encode(encode(package)));
  }

  static PortableTipPackage decode(String contents) {
    _validateByteSize(utf8.encode(contents).length);
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Portable tip root must be an object.');
    }
    return _fromJson(decoded);
  }

  static PortableTipPackage decodeUtf8(Uint8List bytes) {
    _validateByteSize(bytes.length);
    return decode(utf8.decode(bytes, allowMalformed: false));
  }

  static ImportedPortableTip import(
    String contents, {
    required String Function() createLocalId,
    DateTime? importedAt,
  }) {
    return _importDecoded(
      decode(contents),
      createLocalId: createLocalId,
      importedAt: importedAt,
    );
  }

  static ImportedPortableTip importUtf8(
    Uint8List bytes, {
    required String Function() createLocalId,
    DateTime? importedAt,
  }) {
    return _importDecoded(
      decodeUtf8(bytes),
      createLocalId: createLocalId,
      importedAt: importedAt,
    );
  }

  static ImportedPortableTip _importDecoded(
    PortableTipPackage tip, {
    required String Function() createLocalId,
    DateTime? importedAt,
  }) {
    final localId = _validatedId(createLocalId(), 'localId');
    if (localId == tip.packageId) {
      throw const FormatException('Imported tip must receive a new local id.');
    }
    return ImportedPortableTip(
      localId: localId,
      sourcePackageId: tip.packageId,
      importedAt: (importedAt ?? DateTime.now()).toUtc(),
      tip: tip,
    );
  }

  static Map<String, Object?> _toJson(PortableTipPackage package) => {
    'format': format,
    'schemaVersion': schemaVersion,
    'packageId': package.packageId,
    'exportedAtEpochMs': package.exportedAt.millisecondsSinceEpoch,
    'tip': {
      'title': package.title,
      'summary': package.summary,
      'tags': package.tags,
      'details': {
        'facts': [
          for (final fact in package.facts)
            {'label': fact.label, 'value': fact.value},
        ],
        'ingredientGroups': [
          for (final group in package.ingredientGroups)
            {
              'name': group.name,
              'ingredients': [
                for (final ingredient in group.ingredients)
                  {
                    'name': ingredient.name,
                    'amount': ingredient.amount,
                    'unit': ingredient.unit,
                    'preparation': ingredient.preparation,
                    'optional': ingredient.optional,
                    'originalText': ingredient.originalText,
                  },
              ],
            },
        ],
        'steps': [
          for (final step in package.steps)
            {
              'order': step.order,
              'instruction': step.instruction,
              'durationSeconds': step.durationSeconds,
              'temperature': step.temperature,
            },
        ],
        'notes': package.notes,
      },
      'place': package.place == null
          ? null
          : {'name': package.place!.name, 'address': package.place!.address},
      'source': package.source == null
          ? null
          : {'label': package.source!.label, 'url': package.source!.url},
      'message': package.message,
    },
  };

  static PortableTipPackage _fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'format',
      'schemaVersion',
      'packageId',
      'exportedAtEpochMs',
      'tip',
    }, 'root');
    if (json['format'] != format) {
      throw const FormatException('Unsupported portable tip format.');
    }
    final version = json['schemaVersion'];
    if (!supportedVersions.contains(version)) {
      throw UnsupportedPortableTipVersionException(version);
    }
    final exportedAtEpochMs = json['exportedAtEpochMs'];
    if (exportedAtEpochMs is! int ||
        exportedAtEpochMs < 0 ||
        exportedAtEpochMs > PortableTipLimits.maxEpochMilliseconds) {
      throw const FormatException('Portable tip timestamp is invalid.');
    }
    final tip = _requiredMap(json['tip'], 'tip');
    _requireExactKeys(tip, {
      'title',
      'summary',
      if (version == 1) ...{'category', 'subcategory'} else 'tags',
      'details',
      'place',
      'source',
      'message',
    }, 'tip');
    final details = _requiredMap(tip['details'], 'details');
    _requireExactKeys(details, const {
      'facts',
      'ingredientGroups',
      'steps',
      'notes',
    }, 'details');
    final packageId = _stringValue(json['packageId'], 'packageId');
    final title = _stringValue(tip['title'], 'title');
    final summary = _stringValue(tip['summary'], 'summary');
    final tags = version == 1
        ? <String>[
            ?_categoryTagName(tip['category']),
            _stringValue(tip['subcategory'], 'subcategory'),
          ]
        : _stringList(tip['tags'], 'tags');

    return PortableTipPackage.create(
      packageId: packageId,
      exportedAt: DateTime.fromMillisecondsSinceEpoch(
        exportedAtEpochMs,
        isUtc: true,
      ),
      title: title,
      summary: summary,
      tags: tags,
      facts: _mapList(details['facts'], 'facts').map(_factFromJson),
      ingredientGroups: _mapList(
        details['ingredientGroups'],
        'ingredientGroups',
      ).map(_ingredientGroupFromJson),
      steps: _mapList(details['steps'], 'steps').map(_stepFromJson),
      notes: _stringList(details['notes'], 'notes'),
      place: tip['place'] == null ? null : _placeFromJson(tip['place']),
      source: tip['source'] == null ? null : _sourceFromJson(tip['source']),
      message: _nullableStringValue(tip['message'], 'message'),
    );
  }

  static PortableTipFact _factFromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {'label', 'value'}, 'fact');
    return PortableTipFact(
      label: _stringValue(json['label'], 'fact.label'),
      value: _stringValue(json['value'], 'fact.value'),
    );
  }

  static PortableTipIngredientGroup _ingredientGroupFromJson(
    Map<String, Object?> json,
  ) {
    _requireExactKeys(json, const {'name', 'ingredients'}, 'ingredientGroup');
    return PortableTipIngredientGroup(
      name: _stringValue(json['name'], 'ingredientGroup.name'),
      ingredients: _mapList(
        json['ingredients'],
        'ingredients',
      ).map(_ingredientFromJson),
    );
  }

  static PortableTipIngredient _ingredientFromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'name',
      'amount',
      'unit',
      'preparation',
      'optional',
      'originalText',
    }, 'ingredient');
    final optional = json['optional'];
    if (optional is! bool) {
      throw const FormatException('Portable tip ingredient is invalid.');
    }
    return PortableTipIngredient(
      name: _stringValue(json['name'], 'ingredient.name'),
      amount: _nullableStringValue(json['amount'], 'ingredient.amount'),
      unit: _nullableStringValue(json['unit'], 'ingredient.unit'),
      preparation: _nullableStringValue(
        json['preparation'],
        'ingredient.preparation',
      ),
      optional: optional,
      originalText: _stringValue(
        json['originalText'],
        'ingredient.originalText',
      ),
    );
  }

  static PortableTipStep _stepFromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const {
      'order',
      'instruction',
      'durationSeconds',
      'temperature',
    }, 'step');
    final order = json['order'];
    final duration = json['durationSeconds'];
    if (order is! int || duration != null && duration is! int) {
      throw const FormatException('Portable tip step is invalid.');
    }
    return PortableTipStep(
      order: order,
      instruction: _stringValue(json['instruction'], 'step.instruction'),
      durationSeconds: duration as int?,
      temperature: _nullableStringValue(
        json['temperature'],
        'step.temperature',
      ),
    );
  }

  static PortableTipPlace _placeFromJson(Object? value) {
    final json = _requiredMap(value, 'place');
    _requireExactKeys(json, const {'name', 'address'}, 'place');
    return PortableTipPlace(
      name: _nullableStringValue(json['name'], 'place.name'),
      address: _nullableStringValue(json['address'], 'place.address'),
    );
  }

  static PortableTipSource _sourceFromJson(Object? value) {
    final json = _requiredMap(value, 'source');
    _requireExactKeys(json, const {'label', 'url'}, 'source');
    return PortableTipSource(
      label: _nullableStringValue(json['label'], 'source.label'),
      url: _stringValue(json['url'], 'source.url'),
    );
  }

  static void _validateByteSize(int size) {
    if (size <= 0 || size > PortableTipLimits.maxPackageBytes) {
      throw const FormatException('Portable tip file size is invalid.');
    }
  }
}

String _validatedId(String value, String field) {
  final safe = _sanitizeSingleLine(value);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$').hasMatch(safe)) {
    throw FormatException('Portable tip $field is invalid.');
  }
  return safe;
}

String _requiredText(
  String? value, {
  required String field,
  required int maxRunes,
}) {
  final safe = _optionalText(value, field: field, maxRunes: maxRunes);
  if (safe == null) {
    throw FormatException('Portable tip $field is required.');
  }
  return safe;
}

String? _optionalText(
  String? value, {
  required String field,
  required int maxRunes,
}) {
  if (value == null) {
    return null;
  }
  final safe = _sanitizeSingleLine(value);
  if (safe.isEmpty) {
    return null;
  }
  if (safe.runes.length > maxRunes) {
    throw FormatException('Portable tip $field is too long.');
  }
  return safe;
}

String _sanitizeSingleLine(String value) {
  return value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _safeSourceUrl(String value) {
  final safe = _requiredText(
    value,
    field: 'source.url',
    maxRunes: PortableTipLimits.maxSourceUrlRunes,
  );
  final uri = Uri.tryParse(safe);
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Portable tip source URL is invalid.');
  }
  final filteredQuery = Map<String, String>.of(uri.queryParameters)
    ..removeWhere((key, _) {
      final lower = key.toLowerCase();
      return lower.startsWith('utm_') ||
          const {'fbclid', 'gclid', 'igsh', 'igshid'}.contains(lower);
    });
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: filteredQuery.isEmpty ? null : filteredQuery,
  ).toString();
}

List<T> _uniqueBy<T>(Iterable<T> values, String Function(T) keyOf) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (seen.add(keyOf(value))) value,
  ];
}

List<String> _sanitizedUniqueTextList(
  Iterable<String> values, {
  required String field,
  required int maxRunes,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final safe = _requiredText(value, field: field, maxRunes: maxRunes);
    if (seen.add(safe)) {
      result.add(safe);
    }
  }
  return result;
}

/// Tag names, trimmed to what a chip can carry and to what the format allows.
List<String> _safeTagNames(Iterable<String> values) {
  final seen = <String>{};
  final safe = <String>[];
  for (final value in values) {
    final normalized = normalizeTagName(value);
    if (!isValidTagName(normalized) || !seen.add(normalized)) continue;
    if (safe.length >= PortableTipLimits.maxTags) break;
    safe.add(normalized);
  }
  return safe;
}

/// The Korean name of a version 1 category. `other` carried no meaning worth
/// sending on, and neither did a tip the sender never placed.
String? _categoryTagName(Object? wireName) => switch (wireName) {
  'beauty' => '뷰티',
  'health_fitness' => '건강·운동',
  'restaurant_cafe' => '맛집·카페',
  'recipe' => '레시피',
  'shopping' => '쇼핑',
  'travel_place' => '장소',
  'life_tip' => '생활·팁',
  _ => null,
};

Map<String, Object?> _requiredMap(Object? value, String field) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw FormatException('Portable tip $field is invalid.');
}

List<Map<String, Object?>> _mapList(Object? value, String field) {
  if (value is! List<Object?> ||
      value.any((item) => item is! Map<String, Object?>)) {
    throw FormatException('Portable tip $field is invalid.');
  }
  return value.cast<Map<String, Object?>>();
}

List<String> _stringList(Object? value, String field) {
  if (value is! List<Object?> || value.any((item) => item is! String)) {
    throw FormatException('Portable tip $field is invalid.');
  }
  return value.cast<String>();
}

String _stringValue(Object? value, String field) {
  if (value is String) {
    return value;
  }
  throw FormatException('Portable tip $field is invalid.');
}

String? _nullableStringValue(Object? value, String field) {
  if (value == null || value is String) {
    return value as String?;
  }
  throw FormatException('Portable tip $field is invalid.');
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String field,
) {
  if (json.length != expected.length ||
      json.keys.any((key) => !expected.contains(key))) {
    throw FormatException('Portable tip $field has unexpected fields.');
  }
}
