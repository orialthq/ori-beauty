import 'dart:convert';
import 'dart:io';

import 'package:ori_beauty/domain/tag_key.dart';

enum EvalDomain { food }

enum EvalKind {
  recipe,
  sauceRecipe,
  commerceProduct,
  productReview,
  menuComparison,
}

enum EvalCompleteness { complete, partial, conflicted, needsReview }

enum EvalScenario {
  recipePartialMixedText,
  recipeConflictedQuantity,
  recipeRatioUnits,
  recipePartialNoSteps,
  recipeGroupedSeasoning,
  recipeMissingTitle,
  commerceProduct,
  infographicRecipe,
  productReview,
  bilingualDuplicateRecipe,
  recipePartialSauceOnly,
  recipeUnitMissing,
  menuComparison,
  recipeSubstitution,
  recipeAffiliatePartial,
  sauceRecipeFractional,
  recipeUiNumberNoise,
}

extension EvalDomainWireName on EvalDomain {
  String get wireName => name;
}

extension EvalKindWireName on EvalKind {
  String get wireName => switch (this) {
    EvalKind.recipe => 'recipe',
    EvalKind.sauceRecipe => 'sauce_recipe',
    EvalKind.commerceProduct => 'commerce_product',
    EvalKind.productReview => 'product_review',
    EvalKind.menuComparison => 'menu_comparison',
  };
}

extension EvalCompletenessWireName on EvalCompleteness {
  String get wireName => switch (this) {
    EvalCompleteness.complete => 'complete',
    EvalCompleteness.partial => 'partial',
    EvalCompleteness.conflicted => 'conflicted',
    EvalCompleteness.needsReview => 'needs_review',
  };
}

extension EvalScenarioWireName on EvalScenario {
  String get wireName => switch (this) {
    EvalScenario.recipePartialMixedText => 'recipe_partial_mixed_text',
    EvalScenario.recipeConflictedQuantity => 'recipe_conflicted_quantity',
    EvalScenario.recipeRatioUnits => 'recipe_ratio_units',
    EvalScenario.recipePartialNoSteps => 'recipe_partial_no_steps',
    EvalScenario.recipeGroupedSeasoning => 'recipe_grouped_seasoning',
    EvalScenario.recipeMissingTitle => 'recipe_missing_title',
    EvalScenario.commerceProduct => 'commerce_product',
    EvalScenario.infographicRecipe => 'infographic_recipe',
    EvalScenario.productReview => 'product_review',
    EvalScenario.bilingualDuplicateRecipe => 'bilingual_duplicate_recipe',
    EvalScenario.recipePartialSauceOnly => 'recipe_partial_sauce_only',
    EvalScenario.recipeUnitMissing => 'recipe_unit_missing',
    EvalScenario.menuComparison => 'menu_comparison',
    EvalScenario.recipeSubstitution => 'recipe_substitution',
    EvalScenario.recipeAffiliatePartial => 'recipe_affiliate_partial',
    EvalScenario.sauceRecipeFractional => 'sauce_recipe_fractional',
    EvalScenario.recipeUiNumberNoise => 'recipe_ui_number_noise',
  };
}

/// Whether [value] looks like one tag rather than a sentence, a link or
/// nothing at all.
///
/// Deliberately permissive: the server owns the real tag rule. This only keeps
/// paragraphs and URLs out of the manifest, the vocabulary file, and — because
/// response tags that fail it are dropped before evaluation — the report.
bool isTagShaped(String value) {
  final length = value.runes.length;
  return value.trim() == value &&
      length >= 2 &&
      length <= 20 &&
      !RegExp(r'[#\n\r\t]').hasMatch(value) &&
      !value.contains('://');
}

final class EvalInput {
  const EvalInput({required this.imageFile, required this.mimeType});

  final String imageFile;
  final String mimeType;

  factory EvalInput.fromJson(Map<String, Object?> json, String path) {
    _rejectUnknownKeys(json, const {'imageFile', 'mimeType'}, path);
    final imageFile = _requiredString(json, 'imageFile', path);
    final mimeType = _requiredString(json, 'mimeType', path);

    validatePrivateRelativePath(imageFile, '$path.imageFile');
    if (!const {'image/jpeg', 'image/png', 'image/webp'}.contains(mimeType)) {
      throw FormatException('$path.mimeType is not an allowed image MIME.');
    }

    return EvalInput(imageFile: imageFile, mimeType: mimeType);
  }
}

final class EvalExpectation {
  const EvalExpectation({
    required this.domain,
    required this.kind,
    required this.completeness,
    required this.allowedCompleteness,
    required this.requiredErrorCodes,
    required this.allowedErrorCodes,
    required this.forbiddenErrorCodes,
    this.expectedTags,
    this.forbiddenTags = const {},
  });

  final EvalDomain domain;
  final EvalKind kind;
  final EvalCompleteness completeness;
  final Set<EvalCompleteness> allowedCompleteness;
  final Set<String> requiredErrorCodes;
  final Set<String> allowedErrorCodes;
  final Set<String> forbiddenErrorCodes;

  /// The full set of tags the sample should carry, as the operator spelled
  /// them. `null` means the operator has not adjudicated tags for this sample,
  /// and no tag check is emitted at all — an absent expectation must not read
  /// as "expects no tags".
  final Set<String>? expectedTags;
  final Set<String> forbiddenTags;

  factory EvalExpectation.fromJson(Map<String, Object?> json, String path) {
    _rejectUnknownKeys(json, const {
      'domain',
      'kind',
      'completeness',
      'allowedCompleteness',
      'requiredErrorCodes',
      'allowedErrorCodes',
      'forbiddenErrorCodes',
      'expectedTags',
      'forbiddenTags',
    }, path);

    final requiredErrorCodes = _errorCodes(
      json['requiredErrorCodes'],
      '$path.requiredErrorCodes',
    );
    final allowedErrorCodes = _errorCodes(
      json['allowedErrorCodes'],
      '$path.allowedErrorCodes',
    );
    final forbiddenErrorCodes = _errorCodes(
      json['forbiddenErrorCodes'],
      '$path.forbiddenErrorCodes',
    );

    if (requiredErrorCodes.intersection(forbiddenErrorCodes).isNotEmpty) {
      throw FormatException(
        '$path cannot require and forbid the same error code.',
      );
    }
    if (allowedErrorCodes.intersection(forbiddenErrorCodes).isNotEmpty) {
      throw FormatException(
        '$path cannot allow and forbid the same error code.',
      );
    }

    final completeness = _parseCompleteness(
      _requiredString(json, 'completeness', path),
    );
    final allowedCompleteness = _completenessSet(
      json['allowedCompleteness'],
      '$path.allowedCompleteness',
    );
    if (allowedCompleteness.contains(completeness)) {
      throw FormatException(
        '$path.allowedCompleteness must not repeat completeness.',
      );
    }

    final expectedTags = json.containsKey('expectedTags')
        ? _tags(json['expectedTags'], '$path.expectedTags')
        : null;
    final forbiddenTags = json.containsKey('forbiddenTags')
        ? _tags(json['forbiddenTags'], '$path.forbiddenTags')
        : <String>{};
    if (expectedTags == null && forbiddenTags.isNotEmpty) {
      throw FormatException('$path.forbiddenTags requires expectedTags.');
    }
    if (expectedTags != null) {
      final expectedKeys = expectedTags.map(tagKey).toSet();
      if (forbiddenTags.map(tagKey).any(expectedKeys.contains)) {
        throw FormatException('$path cannot expect and forbid the same tag.');
      }
    }

    return EvalExpectation(
      domain: _parseDomain(_requiredString(json, 'domain', path)),
      kind: _parseKind(_requiredString(json, 'kind', path)),
      completeness: completeness,
      allowedCompleteness: allowedCompleteness,
      requiredErrorCodes: requiredErrorCodes,
      allowedErrorCodes: allowedErrorCodes,
      forbiddenErrorCodes: forbiddenErrorCodes,
      expectedTags: expectedTags,
      forbiddenTags: forbiddenTags,
    );
  }
}

final class EvalSample {
  const EvalSample({
    required this.sampleId,
    required this.scenario,
    required this.input,
    required this.expected,
  });

  final String sampleId;
  final EvalScenario scenario;
  final EvalInput input;
  final EvalExpectation expected;

  factory EvalSample.fromJson(Map<String, Object?> json, int index) {
    final path = 'samples[$index]';
    _rejectUnknownKeys(json, const {
      'sampleId',
      'scenario',
      'input',
      'expected',
    }, path);
    final sampleId = _requiredString(json, 'sampleId', path);
    if (!RegExp(r'^holdout-[0-9]{2}$').hasMatch(sampleId)) {
      throw FormatException(
        '$path.sampleId must use the opaque holdout-NN format.',
      );
    }

    return EvalSample(
      sampleId: sampleId,
      scenario: _parseScenario(_requiredString(json, 'scenario', path)),
      input: EvalInput.fromJson(
        _object(json['input'], '$path.input'),
        '$path.input',
      ),
      expected: EvalExpectation.fromJson(
        _object(json['expected'], '$path.expected'),
        '$path.expected',
      ),
    );
  }
}

final class EvalManifest {
  const EvalManifest({required this.schemaVersion, required this.samples});

  final int schemaVersion;
  final List<EvalSample> samples;

  factory EvalManifest.fromJsonString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Manifest is not valid JSON.');
    }
    return EvalManifest.fromJson(_object(decoded, 'manifest'));
  }

  factory EvalManifest.fromJson(Map<String, Object?> json) {
    _rejectUnknownKeys(json, const {'schemaVersion', 'samples'}, 'manifest');
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != 1) {
      throw const FormatException('manifest.schemaVersion must be 1.');
    }
    final rawSamples = json['samples'];
    if (rawSamples is! List<Object?>) {
      throw const FormatException('manifest.samples must be a list.');
    }
    final samples = [
      for (var index = 0; index < rawSamples.length; index++)
        EvalSample.fromJson(
          _object(rawSamples[index], 'samples[$index]'),
          index,
        ),
    ];

    final ids = <String>{};
    final scenarios = <EvalScenario>{};
    for (final sample in samples) {
      if (!ids.add(sample.sampleId)) {
        throw const FormatException('Manifest contains a duplicate sample ID.');
      }
      if (!scenarios.add(sample.scenario)) {
        throw const FormatException('Manifest contains a duplicate scenario.');
      }
    }

    return EvalManifest(schemaVersion: schemaVersion, samples: samples);
  }

  void validateFullHoldoutCoverage() {
    final expectedScenarios = EvalScenario.values.toSet();
    final actualScenarios = samples.map((sample) => sample.scenario).toSet();
    if (samples.length != expectedScenarios.length ||
        !actualScenarios.containsAll(expectedScenarios)) {
      throw const FormatException(
        'Manifest must cover each of the 17 holdout scenarios exactly once.',
      );
    }
  }
}

/// One entry of the vocabulary the reader's library already uses: a tag
/// spelling and how many captures carry it.
final class EvalVocabularyEntry {
  const EvalVocabularyEntry({required this.value, required this.count});

  final String value;
  final int count;

  Map<String, Object?> toJson() => {'value': value, 'count': count};
}

/// The `vocabulary` field sent with every analyze request: what the model is
/// told the library already says, so it reuses those words instead of coining
/// new ones.
///
/// Immutable so that the runner can hold the initial file for the report and
/// keep growing a separate copy as samples come back.
final class EvalVocabulary {
  EvalVocabulary(List<EvalVocabularyEntry> entries)
    : entries = List.unmodifiable(entries);

  const EvalVocabulary.empty() : entries = const [];

  /// The server's cap on `vocabulary`. Growing past it drops the least-used
  /// entries, the same way an app sending its top words would.
  static const maxEntries = 300;

  final List<EvalVocabularyEntry> entries;

  factory EvalVocabulary.fromJsonString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Vocabulary is not valid JSON.');
    }
    return EvalVocabulary.fromJson(decoded);
  }

  factory EvalVocabulary.fromJson(Object? json) {
    if (json is! List<Object?>) {
      throw const FormatException('vocabulary must be a list.');
    }
    if (json.length > maxEntries) {
      throw const FormatException(
        'vocabulary must not exceed $maxEntries entries.',
      );
    }
    final seen = <String>{};
    final entries = <EvalVocabularyEntry>[];
    for (var index = 0; index < json.length; index++) {
      final path = 'vocabulary[$index]';
      final entry = _object(json[index], path);
      _rejectUnknownKeys(entry, const {'value', 'count'}, path);
      final value = _requiredString(entry, 'value', path);
      if (!isTagShaped(value)) {
        throw FormatException('$path.value is not tag-shaped.');
      }
      final count = entry['count'];
      if (count is! int || count < 1) {
        throw FormatException('$path.count must be a positive integer.');
      }
      if (!seen.add(value)) {
        throw FormatException('$path.value repeats an earlier value.');
      }
      entries.add(EvalVocabularyEntry(value: value, count: count));
    }
    return EvalVocabulary(entries);
  }

  /// The vocabulary after one more capture carrying [values].
  ///
  /// Counts are per spelling, not per key: the point of the growing run is to
  /// see whether the model converges on one spelling when shown the library,
  /// and merging spellings here would hide exactly that. A value repeated
  /// within one capture still counts once — the count is captures, not
  /// mentions. Values that are not tag-shaped are dropped rather than sent
  /// back to the server. When the cap is exceeded the least-used entries go,
  /// oldest first among ties, and the survivors keep their order.
  EvalVocabulary grow(Iterable<String> values) {
    final counts = <String, int>{
      for (final entry in entries) entry.value: entry.count,
    };
    for (final value in values.toSet()) {
      if (isTagShaped(value)) {
        counts[value] = (counts[value] ?? 0) + 1;
      }
    }
    var merged = [
      for (final entry in counts.entries)
        EvalVocabularyEntry(value: entry.key, count: entry.value),
    ];
    if (merged.length > maxEntries) {
      final ranked = List.generate(merged.length, (index) => index)
        ..sort((a, b) {
          final byCount = merged[b].count.compareTo(merged[a].count);
          return byCount != 0 ? byCount : b.compareTo(a);
        });
      final kept = ranked.take(maxEntries).toList()..sort();
      merged = [for (final index in kept) merged[index]];
    }
    return EvalVocabulary(merged);
  }

  List<Map<String, Object?>> toJson() =>
      entries.map((entry) => entry.toJson()).toList(growable: false);
}

final class EvalCheck {
  const EvalCheck({
    required this.name,
    required this.passed,
    required this.expected,
    required this.actual,
    this.gating = true,
    this.metrics,
  });

  final String name;
  final bool passed;
  final Object? expected;
  final Object? actual;

  /// Whether a failure of this check fails the sample. A non-gating check is
  /// a number that must stay visible without being a verdict: an extra tag the
  /// operator did not list is not wrong once the library's words outgrow the
  /// manifest.
  final bool gating;

  /// Numeric companions to [passed], e.g. precision and recall in 0..1.
  final Map<String, num>? metrics;

  Map<String, Object?> toJson() => {
    'name': name,
    'passed': passed,
    'gating': gating,
    'expected': expected,
    'actual': actual,
    if (metrics != null) 'metrics': metrics,
  };
}

/// One tag as the backend returned it, reduced to what the eval reads.
final class EvalResponseTag {
  const EvalResponseTag({required this.value, required this.confidence});

  final String value;

  /// `null` when the backend sent no usable number, which the vocabulary
  /// health counts as weak: a tag that cannot say how sure it is has no
  /// business being filed under.
  final double? confidence;

  String get key => tagKey(value);
}

/// The evaluation of one backend call for one sample.
final class EvalRunResult {
  const EvalRunResult({
    required this.checks,
    required this.tags,
    this.runnerErrorCode,
  });

  const EvalRunResult.runnerFailure(String runnerErrorCode)
    : this(checks: const [], tags: const [], runnerErrorCode: runnerErrorCode);

  final List<EvalCheck> checks;

  /// The tags the backend returned. Kept for reproducibility and vocabulary
  /// health; never serialised, so tag values stay out of the report unless
  /// the operator opted a sample in through `expectedTags`.
  final List<EvalResponseTag> tags;
  final String? runnerErrorCode;

  bool get passed =>
      runnerErrorCode == null &&
      checks.where((check) => check.gating).every((check) => check.passed);

  Set<String> get tagKeys => tags.map((tag) => tag.key).toSet();

  Map<String, Object?> toJson() => {
    'passed': passed,
    if (runnerErrorCode != null) 'runnerErrorCode': runnerErrorCode,
    'checks': checks.map((check) => check.toJson()).toList(growable: false),
  };
}

final class EvalSampleResult {
  EvalSampleResult({
    required this.sampleId,
    required this.scenario,
    required List<EvalRunResult> runs,
  }) : runs = List.unmodifiable(runs) {
    if (runs.isEmpty) {
      throw ArgumentError.value(runs, 'runs', 'must contain at least one run');
    }
  }

  factory EvalSampleResult.runnerFailure(
    EvalSample sample,
    String runnerErrorCode,
  ) {
    return EvalSampleResult(
      sampleId: sample.sampleId,
      scenario: sample.scenario,
      runs: [EvalRunResult.runnerFailure(runnerErrorCode)],
    );
  }

  final String sampleId;
  final EvalScenario scenario;

  /// Every call made for this sample, in order. The first run is the one the
  /// vocabulary health and the growing vocabulary read from; the others exist
  /// to show whether the first was luck.
  final List<EvalRunResult> runs;

  bool get passed => runs.every((run) => run.passed);
  List<EvalCheck> get checks => runs.first.checks;
  String? get runnerErrorCode => runs.first.runnerErrorCode;

  /// Mean pairwise Jaccard similarity of the tag-key sets across runs, in
  /// 0..1. `null` with a single run, or when any run did not reach the
  /// backend — a missing set says nothing about the model's consistency.
  double? get tagReproducibility {
    if (runs.length < 2 || runs.any((run) => run.runnerErrorCode != null)) {
      return null;
    }
    final keySets = runs.map((run) => run.tagKeys).toList(growable: false);
    var total = 0.0;
    var pairs = 0;
    for (var a = 0; a < keySets.length; a++) {
      for (var b = a + 1; b < keySets.length; b++) {
        total += _jaccard(keySets[a], keySets[b]);
        pairs++;
      }
    }
    return total / pairs;
  }

  Map<String, Object?> toJson() => {
    'sampleId': sampleId,
    'scenario': scenario.wireName,
    'passed': passed,
    'runs': runs.length,
    'tagReproducibility': tagReproducibility,
    if (runnerErrorCode != null) 'runnerErrorCode': runnerErrorCode,
    'checks': checks.map((check) => check.toJson()).toList(growable: false),
    if (runs.length > 1)
      'extraRuns': [
        for (var index = 1; index < runs.length; index++)
          {'run': index + 1, ...runs[index].toJson()},
      ],
  };
}

/// Counts describing the tag set as a whole, read from the first run of every
/// sample that reached the backend. Counts only: tag values never appear here,
/// because the aggregate is the file most likely to be shared.
final class EvalVocabularyHealth {
  const EvalVocabularyHealth({
    required this.samples,
    required this.tags,
    required this.distinctKeys,
    required this.singletonKeys,
    required this.spellingVariants,
    required this.weakTags,
  });

  factory EvalVocabularyHealth.fromResults(Iterable<EvalSampleResult> results) {
    final firstRuns = results
        .map((result) => result.runs.first)
        .where((run) => run.runnerErrorCode == null)
        .toList(growable: false);
    final samplesPerKey = <String, int>{};
    final spellingsPerKey = <String, Set<String>>{};
    var tags = 0;
    var weakTags = 0;
    for (final run in firstRuns) {
      for (final key in run.tagKeys) {
        samplesPerKey[key] = (samplesPerKey[key] ?? 0) + 1;
      }
      for (final tag in run.tags) {
        tags++;
        spellingsPerKey.putIfAbsent(tag.key, () => {}).add(tag.value);
        if (tag.confidence == null || tag.confidence! < 0.5) {
          weakTags++;
        }
      }
    }
    return EvalVocabularyHealth(
      samples: firstRuns.length,
      tags: tags,
      distinctKeys: samplesPerKey.length,
      singletonKeys: samplesPerKey.values.where((n) => n == 1).length,
      spellingVariants: spellingsPerKey.values
          .where((spellings) => spellings.length > 1)
          .length,
      weakTags: weakTags,
    );
  }

  final int samples;
  final int tags;
  final int distinctKeys;

  /// Keys that appear on exactly one sample. A library where most words are
  /// used once is a library of labels, not of folders.
  final int singletonKeys;

  /// Keys that arrived under more than one spelling — the `멕시코 음식` /
  /// `멕시코음식` count the vocabulary is meant to drive to zero.
  final int spellingVariants;

  /// Tags with confidence below 0.5, or with none at all.
  final int weakTags;

  double get singletonRatio =>
      distinctKeys == 0 ? 0 : singletonKeys / distinctKeys;
  double get meanTagsPerSample => samples == 0 ? 0 : tags / samples;

  Map<String, Object?> toJson() => {
    'samples': samples,
    'tags': tags,
    'distinctKeys': distinctKeys,
    'singletonKeys': singletonKeys,
    'singletonRatio': singletonRatio,
    'meanTagsPerSample': meanTagsPerSample,
    'spellingVariants': spellingVariants,
    'weakTags': weakTags,
  };
}

final class EvalAggregate {
  const EvalAggregate({
    required this.generatedAt,
    required this.results,
    this.repeat = 1,
    this.initialVocabulary,
    this.vocabularyGrown = false,
  });

  final DateTime generatedAt;
  final List<EvalSampleResult> results;
  final int repeat;

  /// The vocabulary the run started from, so the report can say how many
  /// words the model was shown — not which.
  final EvalVocabulary? initialVocabulary;
  final bool vocabularyGrown;

  int get passedCount => results.where((result) => result.passed).length;
  int get failedCount => results.length - passedCount;

  /// Mean of the per-sample reproducibility over the samples that have one.
  double? get tagReproducibility {
    final values = results
        .map((result) => result.tagReproducibility)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  Map<String, Object?> toJson() {
    final byScenario = <String, Object?>{};
    for (final scenario in EvalScenario.values) {
      final scenarioResults = results
          .where((result) => result.scenario == scenario)
          .toList(growable: false);
      if (scenarioResults.isEmpty) {
        continue;
      }
      byScenario[scenario.wireName] = {
        'total': scenarioResults.length,
        'passed': scenarioResults.where((result) => result.passed).length,
        'failed': scenarioResults.where((result) => !result.passed).length,
      };
    }

    return {
      'schemaVersion': 1,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'repeat': repeat,
      'totals': {
        'samples': results.length,
        'passed': passedCount,
        'failed': failedCount,
        'tagReproducibility': tagReproducibility,
      },
      'byScenario': byScenario,
      'vocabulary': {
        'sent': initialVocabulary != null || vocabularyGrown,
        'grown': vocabularyGrown,
        'initialEntries': initialVocabulary?.entries.length ?? 0,
        ...EvalVocabularyHealth.fromResults(results).toJson(),
      },
      'results': results
          .map((result) => result.toJson())
          .toList(growable: false),
    };
  }

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

abstract interface class EvalBackend {
  Future<Map<String, Object?>> analyze(
    EvalSample sample,
    Directory dataDirectory, {
    EvalVocabulary? vocabulary,
  });
}

final class EvalBackendException implements Exception {
  const EvalBackendException(this.code);

  final String code;
}

final class EvalRunner {
  const EvalRunner({required this.backend, this.now = DateTime.now});

  final EvalBackend backend;
  final DateTime Function() now;

  /// Every sample is analysed [repeat] times. With [growVocabulary] the
  /// vocabulary starts from [vocabulary] (or empty) and, once all of a
  /// sample's runs are done, takes on that sample's first-run tags — after,
  /// not between, so the repeats of one sample are the same request and the
  /// reproducibility number measures the model, not the growing input.
  Future<EvalAggregate> run(
    EvalManifest manifest,
    Directory dataDirectory, {
    Set<String>? onlySampleIds,
    int repeat = 1,
    EvalVocabulary? vocabulary,
    bool growVocabulary = false,
  }) async {
    if (repeat < 1) {
      throw ArgumentError.value(repeat, 'repeat', 'must be at least 1');
    }
    manifest.validateFullHoldoutCoverage();
    final results = <EvalSampleResult>[];
    var current =
        vocabulary ?? (growVocabulary ? const EvalVocabulary.empty() : null);

    for (final sample in manifest.samples) {
      if (onlySampleIds != null && !onlySampleIds.contains(sample.sampleId)) {
        continue;
      }
      final runs = <EvalRunResult>[];
      for (var index = 0; index < repeat; index++) {
        runs.add(await _analyzeOnce(sample, dataDirectory, current));
      }
      results.add(
        EvalSampleResult(
          sampleId: sample.sampleId,
          scenario: sample.scenario,
          runs: runs,
        ),
      );
      final firstRun = runs.first;
      if (growVocabulary && firstRun.runnerErrorCode == null) {
        current = current!.grow(firstRun.tags.map((tag) => tag.value));
      }
    }

    if (onlySampleIds != null) {
      final knownIds = manifest.samples
          .map((sample) => sample.sampleId)
          .toSet();
      if (!knownIds.containsAll(onlySampleIds)) {
        throw const FormatException('Requested sample ID is not in manifest.');
      }
    }

    return EvalAggregate(
      generatedAt: now(),
      results: results,
      repeat: repeat,
      initialVocabulary: vocabulary,
      vocabularyGrown: growVocabulary,
    );
  }

  Future<EvalRunResult> _analyzeOnce(
    EvalSample sample,
    Directory dataDirectory,
    EvalVocabulary? vocabulary,
  ) async {
    try {
      final response = await backend.analyze(
        sample,
        dataDirectory,
        vocabulary: vocabulary,
      );
      return evaluateResponse(sample, response);
    } on EvalBackendException catch (error) {
      return EvalRunResult.runnerFailure(_safeRunnerErrorCode(error.code));
    } on Object {
      return const EvalRunResult.runnerFailure('runner_unexpected_error');
    }
  }
}

EvalRunResult evaluateResponse(
  EvalSample sample,
  Map<String, Object?> response,
) {
  final nestedAnalysis = response['analysis'];
  final analysis = nestedAnalysis is Map<Object?, Object?>
      ? _object(nestedAnalysis, 'response.analysis')
      : response;
  final actualDomain = _safeWireValue(analysis['domain']);
  final actualKind = _safeWireValue(
    analysis['contentKind'] ?? analysis['kind'],
  );
  final actualCompleteness = _safeWireValue(analysis['completeness']);
  final expected = sample.expected;
  final acceptedCompleteness = {
    expected.completeness,
    ...expected.allowedCompleteness,
  }.map((value) => value.wireName).toSet();
  final knownErrorCodes = {
    ...expected.requiredErrorCodes,
    ...expected.allowedErrorCodes,
    ...expected.forbiddenErrorCodes,
    'malformed_error_code',
    'malformed_error_response',
  };
  final actualErrors = _responseErrorCodes(analysis['errors'])
      .map(
        (code) =>
            knownErrorCodes.contains(code) ? code : 'unrecognized_error_code',
      )
      .toSet();
  final requiredMissing = expected.requiredErrorCodes.difference(actualErrors);
  final forbiddenPresent = expected.forbiddenErrorCodes.intersection(
    actualErrors,
  );
  final acceptedErrors = {
    ...expected.requiredErrorCodes,
    ...expected.allowedErrorCodes,
  };
  final unexpectedErrors = actualErrors.difference(acceptedErrors);
  final tags = _responseTags(analysis['tags']);

  return EvalRunResult(
    tags: tags,
    checks: [
      EvalCheck(
        name: 'domain',
        passed: actualDomain == expected.domain.wireName,
        expected: expected.domain.wireName,
        actual: actualDomain,
      ),
      EvalCheck(
        name: 'kind',
        passed: actualKind == expected.kind.wireName,
        expected: expected.kind.wireName,
        actual: actualKind,
      ),
      EvalCheck(
        name: 'completeness',
        passed: acceptedCompleteness.contains(actualCompleteness),
        expected: _sorted(acceptedCompleteness),
        actual: actualCompleteness,
      ),
      EvalCheck(
        name: 'required_error_codes',
        passed: requiredMissing.isEmpty,
        expected: _sorted(expected.requiredErrorCodes),
        actual: _sorted(actualErrors),
      ),
      EvalCheck(
        name: 'forbidden_error_codes',
        passed: forbiddenPresent.isEmpty,
        expected: _sorted(expected.forbiddenErrorCodes),
        actual: _sorted(actualErrors),
      ),
      EvalCheck(
        name: 'unexpected_error_codes',
        passed: unexpectedErrors.isEmpty,
        expected: _sorted(acceptedErrors),
        actual: _sorted(actualErrors),
      ),
      if (expected.expectedTags case final expectedTags?)
        ..._tagChecks(expectedTags, expected.forbiddenTags, tags),
    ],
  );
}

/// The three tag checks, compared by [tagKey] so that a spelling the operator
/// did not anticipate is not a miss.
///
/// Recall and the forbidden list gate; precision does not. The library's
/// words outgrow any manifest, so a fitting tag the operator did not list is
/// not a failure — but the number has to stay visible, or "file under every
/// fitting word" quietly becomes "file under every word".
List<EvalCheck> _tagChecks(
  Set<String> expectedTags,
  Set<String> forbiddenTags,
  List<EvalResponseTag> tags,
) {
  final expectedKeys = expectedTags.map(tagKey).toSet();
  final forbiddenKeys = forbiddenTags.map(tagKey).toSet();
  final actualKeys = tags.map((tag) => tag.key).toSet();
  final hits = actualKeys.intersection(expectedKeys);
  final recall = expectedKeys.isEmpty ? 1.0 : hits.length / expectedKeys.length;
  final precision = actualKeys.isEmpty ? 1.0 : hits.length / actualKeys.length;
  final actual = _sorted(actualKeys);
  return [
    EvalCheck(
      name: 'tags_recall',
      passed: expectedKeys.difference(actualKeys).isEmpty,
      expected: _sorted(expectedKeys),
      actual: actual,
    ),
    EvalCheck(
      name: 'tags_forbidden',
      passed: forbiddenKeys.intersection(actualKeys).isEmpty,
      expected: _sorted(forbiddenKeys),
      actual: actual,
    ),
    EvalCheck(
      name: 'tags_precision',
      passed: actualKeys.difference(expectedKeys).isEmpty,
      gating: false,
      expected: _sorted(expectedKeys),
      actual: actual,
      metrics: {'precision': precision, 'recall': recall},
    ),
  ];
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty && b.isEmpty) {
    return 1;
  }
  return a.intersection(b).length / a.union(b).length;
}

EvalDomain _parseDomain(String value) {
  return EvalDomain.values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw const FormatException(
      'Expected domain contains an unsupported enum.',
    ),
  );
}

EvalKind _parseKind(String value) {
  return EvalKind.values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw const FormatException(
      'Expected kind contains an unsupported enum.',
    ),
  );
}

EvalCompleteness _parseCompleteness(String value) {
  return EvalCompleteness.values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw const FormatException(
      'Expected completeness contains an unsupported enum.',
    ),
  );
}

EvalScenario _parseScenario(String value) {
  return EvalScenario.values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () =>
        throw const FormatException('Scenario contains an unsupported enum.'),
  );
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('$path must be an object.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings.');
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}

void _rejectUnknownKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String path,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('$path has unsupported field "$key".');
    }
  }
}

String _requiredString(Map<String, Object?> json, String key, String path) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$path.$key must be a non-empty string.');
  }
  return value;
}

Set<String> _errorCodes(Object? value, String path) {
  if (value is! List<Object?>) {
    throw FormatException('$path must be a list.');
  }
  final result = <String>{};
  for (final item in value) {
    if (item is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(item)) {
      throw FormatException('$path contains an invalid error code.');
    }
    result.add(item);
  }
  return result;
}

/// Tags as the operator wrote them. Two spellings of one key are rejected
/// rather than merged, because a manifest that lists both has not decided
/// what it expects.
Set<String> _tags(Object? value, String path) {
  if (value is! List<Object?>) {
    throw FormatException('$path must be a list.');
  }
  final result = <String>{};
  final keys = <String>{};
  for (final item in value) {
    if (item is! String || !isTagShaped(item)) {
      throw FormatException('$path contains a value that is not tag-shaped.');
    }
    if (!keys.add(tagKey(item))) {
      throw FormatException('$path lists one tag under two spellings.');
    }
    result.add(item);
  }
  return result;
}

Set<EvalCompleteness> _completenessSet(Object? value, String path) {
  if (value == null) {
    return {};
  }
  if (value is! List<Object?>) {
    throw FormatException('$path must be a list.');
  }
  final result = <EvalCompleteness>{};
  for (final item in value) {
    if (item is! String) {
      throw FormatException('$path contains an invalid completeness value.');
    }
    result.add(_parseCompleteness(item));
  }
  return result;
}

Set<String> _responseErrorCodes(Object? value) {
  if (value == null) {
    return {};
  }
  if (value is! List<Object?>) {
    return {'malformed_error_response'};
  }
  final result = <String>{};
  for (final item in value) {
    final code = switch (item) {
      final String value => value,
      final Map<Object?, Object?> value when value['code'] is String =>
        value['code']! as String,
      _ => 'malformed_error_response',
    };
    if (RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(code)) {
      result.add(code);
    } else {
      result.add('malformed_error_code');
    }
  }
  return result;
}

/// The response's `tags`, keeping only entries whose `value` is tag-shaped.
/// Anything else — a missing list, a sentence, a number — is dropped, so that
/// what reaches the report is at most a word.
List<EvalResponseTag> _responseTags(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  final result = <EvalResponseTag>[];
  for (final item in value) {
    if (item is! Map<Object?, Object?>) {
      continue;
    }
    final tagValue = item['value'];
    if (tagValue is! String || !isTagShaped(tagValue)) {
      continue;
    }
    final confidence = item['confidence'];
    result.add(
      EvalResponseTag(
        value: tagValue,
        confidence: confidence is num ? confidence.toDouble() : null,
      ),
    );
  }
  return result;
}

String? _safeWireValue(Object? value) {
  if (value is String &&
      RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(value)) {
    return value;
  }
  return null;
}

String _safeRunnerErrorCode(String value) {
  const allowed = {
    'image_missing',
    'image_too_large',
    'shared_text_missing',
    'shared_text_too_large',
    'shared_text_invalid_utf8',
    'unsafe_local_path',
    'backend_unreachable',
    'backend_request_failed',
    'backend_response_too_large',
    'backend_response_invalid_json',
    'backend_response_invalid_shape',
  };
  if (allowed.contains(value) ||
      RegExp(r'^backend_http_[1-5][0-9]{2}$').hasMatch(value)) {
    return value;
  }
  return 'runner_backend_error';
}

List<String> _sorted(Iterable<String> values) {
  return values.toList(growable: false)..sort();
}

/// Rejects absolute paths, drive letters, `..` segments and URLs. The manifest
/// applies it to sample files and the CLI to the vocabulary file, so that
/// every file the tool opens sits under the project — where `tool/evals/local/`
/// is already ignored by git.
void validatePrivateRelativePath(String value, String path) {
  final normalized = value.replaceAll(r'\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[a-zA-Z]:/').hasMatch(normalized) ||
      normalized.split('/').contains('..') ||
      Uri.tryParse(value)?.hasScheme == true) {
    throw FormatException('$path must be a relative local path.');
  }
}
