import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/evals/eval_core.dart';
import '../../tool/evals/local_backend_client.dart';

void main() {
  late EvalManifest manifest;

  setUpAll(() async {
    manifest = EvalManifest.fromJsonString(
      await File('tool/evals/manifest.template.json').readAsString(),
    );
  });

  test('template covers all 17 private holdout scenarios', () {
    expect(manifest.samples, hasLength(17));
    expect(manifest.samples.map((sample) => sample.sampleId).toSet(), {
      for (var index = 1; index <= 17; index++)
        'holdout-${index.toString().padLeft(2, '0')}',
    });
    expect(() => manifest.validateFullHoldoutCoverage(), returnsNormally);
  });

  test(
    'deterministic mock backend produces an aggregate pass report',
    () async {
      final backend = _DeterministicBackend();
      final aggregate = await EvalRunner(
        backend: backend,
        now: () => DateTime.utc(2026, 8, 1, 3, 4, 5),
      ).run(manifest, Directory('.'));

      expect(aggregate.passedCount, 17);
      expect(aggregate.failedCount, 0);
      expect(backend.requestedIds, [
        for (var index = 1; index <= 17; index++)
          'holdout-${index.toString().padLeft(2, '0')}',
      ]);
      expect(aggregate.toJson()['generatedAt'], '2026-08-01T03:04:05.000Z');
      expect(
        aggregate.toPrettyJson(),
        isNot(contains(_DeterministicBackend.privateResponseMarker)),
      );
    },
  );

  test('classification and error invariants fail independently', () {
    final sample = manifest.samples.firstWhere(
      (candidate) =>
          candidate.scenario == EvalScenario.recipeConflictedQuantity,
    );
    final result = evaluateResponse(sample, {
      'analysis': {
        'domain': 'food',
        'contentKind': 'recipe',
        'completeness': 'complete',
        'errors': [
          {'code': 'raw_content_exposed', 'message': 'not copied to report'},
          {'code': 'account_private_marker'},
        ],
        'rawText': _DeterministicBackend.privateResponseMarker,
      },
    });

    expect(result.passed, isFalse);
    expect(
      result.checks.firstWhere((check) => check.name == 'completeness').passed,
      isFalse,
    );
    expect(
      result.checks
          .firstWhere((check) => check.name == 'forbidden_error_codes')
          .passed,
      isFalse,
    );
    expect(
      result.toJson().toString(),
      isNot(contains(_DeterministicBackend.privateResponseMarker)),
    );
    expect(result.toJson().toString(), isNot(contains('not copied to report')));
    expect(
      result.toJson().toString(),
      isNot(contains('account_private_marker')),
    );
    expect(result.toJson().toString(), contains('unrecognized_error_code'));
  });

  test('adjudicated completeness boundary accepts either safe state', () {
    final sample = manifest.samples.firstWhere(
      (candidate) => candidate.scenario == EvalScenario.recipeRatioUnits,
    );

    final result = evaluateResponse(sample, {
      'analysis': {
        'domain': 'food',
        'contentKind': 'recipe',
        'completeness': 'partial',
        'errors': const <Object?>[],
      },
    });

    expect(result.passed, isTrue);
    expect(
      result.checks
          .firstWhere((check) => check.name == 'completeness')
          .expected,
      ['complete', 'partial'],
    );
  });

  test('runner sanitizes backend exception codes', () async {
    final aggregate = await EvalRunner(
      backend: const _LeakyErrorBackend(),
      now: () => DateTime.utc(2026, 8, 1),
    ).run(manifest, Directory('.'), onlySampleIds: {'holdout-01'});

    expect(aggregate.failedCount, 1);
    expect(aggregate.results.single.runnerErrorCode, 'runner_backend_error');
    expect(aggregate.toPrettyJson(), isNot(contains('account_private_marker')));
  });

  test('manifest rejects inline content and unsafe paths', () {
    final base = _singleSampleJson();
    final sample =
        (base['samples']! as List<Object?>).single as Map<String, Object?>;
    final input = sample['input']! as Map<String, Object?>;
    input['sharedText'] = 'synthetic private content';

    expect(() => EvalManifest.fromJson(base), throwsA(isA<FormatException>()));

    final unsafe = _singleSampleJson();
    final unsafeSample =
        (unsafe['samples']! as List<Object?>).single as Map<String, Object?>;
    final unsafeInput = unsafeSample['input']! as Map<String, Object?>;
    unsafeInput['imageFile'] = '../private.jpg';

    expect(
      () => EvalManifest.fromJson(unsafe),
      throwsA(isA<FormatException>()),
    );
  });

  test('local backend client refuses non-loopback and credential URLs', () {
    expect(
      () => LocalBackendClient(
        endpoint: Uri.parse('https://example.com/v1/analyze'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LocalBackendClient(
        endpoint: Uri.parse(
          'http://localhost:8080/v1/analyze?api_key=synthetic',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  group('expected tags in the manifest', () {
    test('accepts tag-shaped expected and forbidden tags', () {
      final sample = _sampleWithTags(
        expectedTags: ['국·찌개', '레시피'],
        forbiddenTags: ['성수'],
      );
      expect(sample.expected.expectedTags, {'국·찌개', '레시피'});
      expect(sample.expected.forbiddenTags, {'성수'});
    });

    test('leaves tag expectations absent by default', () {
      final sample = EvalManifest.fromJson(_singleSampleJson()).samples.single;
      expect(sample.expected.expectedTags, isNull);
      expect(sample.expected.forbiddenTags, isEmpty);
    });

    test('rejects values that are not tag-shaped', () {
      for (final bad in [
        '가',
        '가' * 21,
        '#레시피',
        'https://example.com',
        ' 레시피',
        '레시피\n본문',
      ]) {
        expect(
          () => _sampleWithTags(expectedTags: [bad]),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
      }
    });

    test('rejects one tag under two spellings, and expected-and-forbidden', () {
      expect(
        () => _sampleWithTags(expectedTags: ['멕시코 음식', '멕시코음식']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => _sampleWithTags(expectedTags: ['레시피'], forbiddenTags: ['레시피']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => _sampleWithTags(forbiddenTags: ['성수']),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('tag checks', () {
    final sample = _sampleWithTags(
      expectedTags: ['국·찌개', '레시피'],
      forbiddenTags: ['성수'],
    );

    test('are skipped entirely without expectedTags', () {
      final plain = EvalManifest.fromJson(_singleSampleJson()).samples.single;
      final result = evaluateResponse(
        plain,
        _analysis(
          plain,
          tags: [
            {'value': '아무말', 'confidence': 0.9},
          ],
        ),
      );
      expect(
        result.checks.map((check) => check.name),
        isNot(contains('tags_')),
      );
      expect(result.toJson().toString(), isNot(contains('아무말')));
    });

    test('compare by tag key and gate on recall and forbidden only', () {
      final result = evaluateResponse(
        sample,
        _analysis(
          sample,
          tags: [
            {'value': '국 찌개', 'confidence': 0.9},
            {'value': '레시피', 'confidence': 0.8},
            {'value': '집밥', 'confidence': 0.7},
          ],
        ),
      );

      final recall = _check(result, 'tags_recall');
      final forbidden = _check(result, 'tags_forbidden');
      final precision = _check(result, 'tags_precision');
      expect(recall.passed, isTrue);
      expect(recall.gating, isTrue);
      expect(recall.expected, ['국찌개', '레시피']);
      expect(recall.actual, ['국찌개', '레시피', '집밥']);
      expect(forbidden.passed, isTrue);
      expect(precision.passed, isFalse);
      expect(precision.gating, isFalse);
      expect(precision.metrics!['precision'], closeTo(2 / 3, 1e-9));
      expect(precision.metrics!['recall'], 1.0);
      expect(result.passed, isTrue, reason: 'precision does not gate');
      expect(precision.toJson()['metrics'], {
        'precision': closeTo(2 / 3, 1e-9),
        'recall': 1.0,
      });
    });

    test('fail on a missing expected tag', () {
      final result = evaluateResponse(
        sample,
        _analysis(
          sample,
          tags: [
            {'value': '레시피', 'confidence': 0.8},
          ],
        ),
      );
      expect(_check(result, 'tags_recall').passed, isFalse);
      expect(_check(result, 'tags_precision').passed, isTrue);
      expect(_check(result, 'tags_precision').metrics!['recall'], 0.5);
      expect(result.passed, isFalse);
    });

    test('fail on a forbidden tag under any spelling', () {
      final result = evaluateResponse(
        sample,
        _analysis(
          sample,
          tags: [
            {'value': '국·찌개', 'confidence': 0.9},
            {'value': '레시피', 'confidence': 0.8},
            {'value': '성 수', 'confidence': 0.6},
          ],
        ),
      );
      expect(_check(result, 'tags_recall').passed, isTrue);
      expect(_check(result, 'tags_forbidden').passed, isFalse);
      expect(result.passed, isFalse);
    });

    test('ignore malformed tag entries and long values', () {
      final result = evaluateResponse(
        sample,
        _analysis(
          sample,
          tags: [
            {'value': '국·찌개', 'confidence': 0.9},
            {'value': '레시피'},
            {'value': 'SYNTHETIC ' * 4, 'confidence': 0.9},
            'not-an-object',
            {'confidence': 0.9},
          ],
        ),
      );
      expect(result.tags.map((tag) => tag.value), ['국·찌개', '레시피']);
      expect(result.tags.last.confidence, isNull);
      expect(_check(result, 'tags_precision').passed, isTrue);
      expect(result.toJson().toString(), isNot(contains('SYNTHETIC')));
    });
  });

  group('repeat runs', () {
    test('sample passes only if every run passes', () async {
      final backend = _ScriptedTagBackend({
        'holdout-01': [
          [('레시피', 0.9)],
          [('레시피', 0.9)],
          [('레시피', 0.9), ('성수', 0.9)],
        ],
      });
      final aggregate =
          await EvalRunner(
            backend: backend,
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-01'},
            repeat: 3,
          );

      final result = aggregate.results.single;
      expect(result.runs, hasLength(3));
      expect(result.runs.map((run) => run.passed), [true, true, false]);
      expect(result.passed, isFalse);
      final json = result.toJson();
      expect(json['runs'], 3);
      expect((json['extraRuns']! as List<Object?>).length, 2);
      expect(
        ((json['extraRuns']! as List<Object?>).last as Map<String, Object?>)
            .containsKey('run'),
        isTrue,
      );
    });

    test('reproducibility is the mean pairwise Jaccard of tag keys', () async {
      final backend = _ScriptedTagBackend({
        'holdout-01': [
          [('레시피', 0.9), ('국·찌개', 0.8)],
          [('레시피', 0.9), ('국찌개', 0.8)],
          [('레시피', 0.9), ('집밥', 0.8)],
        ],
      });
      final aggregate =
          await EvalRunner(
            backend: backend,
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-01'},
            repeat: 3,
          );

      // Pairs: (1,2) = 1, (1,3) = 1/3, (2,3) = 1/3.
      final result = aggregate.results.single;
      expect(result.tagReproducibility, closeTo(5 / 9, 1e-9));
      expect(aggregate.tagReproducibility, closeTo(5 / 9, 1e-9));
      final totals = aggregate.toJson()['totals']! as Map<String, Object?>;
      expect(totals['tagReproducibility'], closeTo(5 / 9, 1e-9));
      expect(aggregate.toJson()['repeat'], 3);
    });

    test('reproducibility is null for one run or a failed run', () async {
      final single = await EvalRunner(
        backend: _ScriptedTagBackend({
          'holdout-01': [
            [('레시피', 0.9)],
          ],
        }),
        now: () => DateTime.utc(2026, 8, 1),
      ).run(_taggedManifest(), Directory('.'), onlySampleIds: {'holdout-01'});
      expect(single.results.single.tagReproducibility, isNull);
      expect(single.tagReproducibility, isNull);

      final failing =
          await EvalRunner(
            backend: _ScriptedTagBackend({
              'holdout-01': [
                [('레시피', 0.9)],
                null,
              ],
            }),
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-01'},
            repeat: 2,
          );
      expect(failing.results.single.tagReproducibility, isNull);
      expect(failing.results.single.passed, isFalse);
      expect(
        (failing.toJson()['totals']!
            as Map<String, Object?>)['tagReproducibility'],
        isNull,
      );
    });

    test('identical empty tag sets count as fully reproducible', () async {
      final aggregate =
          await EvalRunner(
            backend: _ScriptedTagBackend({
              'holdout-01': [[], []],
            }),
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(expectedTags: []),
            Directory('.'),
            onlySampleIds: {'holdout-01'},
            repeat: 2,
          );
      expect(aggregate.results.single.tagReproducibility, 1.0);
      expect(aggregate.results.single.passed, isTrue);
    });
  });

  group('vocabulary health', () {
    test('counts keys, singletons, spellings and weak tags', () async {
      final backend = _ScriptedTagBackend({
        'holdout-02': [
          [('멕시코 음식', 0.9), ('레시피', 0.9)],
        ],
        'holdout-03': [
          [('멕시코음식', 0.4), ('레시피', 0.8)],
        ],
        'holdout-04': [
          [('성수', 0.95)],
        ],
      });
      final aggregate =
          await EvalRunner(
            backend: backend,
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-02', 'holdout-03', 'holdout-04'},
          );

      final vocabulary =
          aggregate.toJson()['vocabulary']! as Map<String, Object?>;
      expect(vocabulary['sent'], isFalse);
      expect(vocabulary['grown'], isFalse);
      expect(vocabulary['initialEntries'], 0);
      expect(vocabulary['samples'], 3);
      expect(vocabulary['tags'], 5);
      expect(vocabulary['distinctKeys'], 3);
      expect(vocabulary['singletonKeys'], 1);
      expect(vocabulary['singletonRatio'], closeTo(1 / 3, 1e-9));
      expect(vocabulary['meanTagsPerSample'], closeTo(5 / 3, 1e-9));
      expect(vocabulary['spellingVariants'], 1);
      expect(vocabulary['weakTags'], 1);

      final report = aggregate.toPrettyJson();
      expect(report, isNot(contains('멕시코')));
      expect(report, isNot(contains('성수')));
    });

    test('reads only the first run and skips failed samples', () async {
      final backend = _ScriptedTagBackend({
        'holdout-01': [
          [('레시피', 0.9)],
          [('레시피', 0.9), ('집밥', 0.2)],
        ],
        'holdout-02': [null, null],
      });
      final aggregate =
          await EvalRunner(
            backend: backend,
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-01', 'holdout-02'},
            repeat: 2,
          );
      final health = EvalVocabularyHealth.fromResults(aggregate.results);
      expect(health.samples, 1);
      expect(health.tags, 1);
      expect(health.weakTags, 0);
      expect(health.singletonRatio, 1.0);
    });

    test('is all zeros with no successful sample', () {
      final health = EvalVocabularyHealth.fromResults(const []);
      expect(health.singletonRatio, 0);
      expect(health.meanTagsPerSample, 0);
    });
  });

  group('vocabulary', () {
    test('file validation', () {
      expect(
        EvalVocabulary.fromJsonString(
          '[{"value": "레시피", "count": 3}]',
        ).entries.single.count,
        3,
      );
      for (final bad in [
        '{"value": "레시피"}',
        '[{"value": "레시피"}]',
        '[{"value": "레시피", "count": 0}]',
        '[{"value": "레시피", "count": 1.5}]',
        '[{"value": "레시피", "count": "1"}]',
        '[{"value": "가", "count": 1}]',
        '[{"value": "${'가' * 21}", "count": 1}]',
        '[{"value": "레시피", "count": 1, "note": "x"}]',
        '[{"value": "레시피", "count": 1}, {"value": "레시피", "count": 1}]',
        'not json',
      ]) {
        expect(
          () => EvalVocabulary.fromJsonString(bad),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
      }
      final tooMany = [
        for (var index = 0; index < 301; index++)
          {'value': 'tag-${index.toString().padLeft(3, '0')}', 'count': 1},
      ];
      expect(
        () => EvalVocabulary.fromJson(tooMany),
        throwsA(isA<FormatException>()),
      );
      expect(
        EvalVocabulary.fromJson(tooMany.sublist(1)).entries,
        hasLength(300),
      );
    });

    test('path must be relative and inside the project', () {
      expect(
        () => validatePrivateRelativePath('../vocab.json', 'x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validatePrivateRelativePath('/etc/vocab.json', 'x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validatePrivateRelativePath('file:///vocab.json', 'x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validatePrivateRelativePath('tool/evals/local/vocab.json', 'x'),
        returnsNormally,
      );
    });

    test('grow counts captures per spelling and drops non-tags', () {
      final grown = EvalVocabulary.fromJson([
        {'value': '레시피', 'count': 2},
      ]).grow(['레시피', '레시피', '멕시코 음식', '멕시코음식', 'x', 'SYNTHETIC ' * 4]);
      expect(grown.toJson(), [
        {'value': '레시피', 'count': 3},
        {'value': '멕시코 음식', 'count': 1},
        {'value': '멕시코음식', 'count': 1},
      ]);
    });

    test('grow drops the least-used, oldest first, at the cap', () {
      final full = EvalVocabulary.fromJson([
        {'value': 'rare-old', 'count': 1},
        for (var index = 1; index < EvalVocabulary.maxEntries; index++)
          {'value': 'tag-${index.toString().padLeft(3, '0')}', 'count': 2},
      ]);
      final grown = full.grow(['fresh', 'tag-001']);
      expect(grown.entries, hasLength(EvalVocabulary.maxEntries));
      expect(
        grown.entries.map((entry) => entry.value),
        isNot(contains('rare-old')),
      );
      expect(grown.entries.last.value, 'fresh');
      expect(grown.entries.first.value, 'tag-001');
      expect(grown.entries.first.count, 3);
    });

    test('grows in run order from the first run only', () async {
      final backend = _ScriptedTagBackend({
        'holdout-01': [
          [('레시피', 0.9), ('국·찌개', 0.9)],
          [('집밥', 0.9)],
        ],
        'holdout-02': [
          [('레시피', 0.9)],
          [('레시피', 0.9)],
        ],
        'holdout-03': [
          [('성수', 0.9)],
          [('성수', 0.9)],
        ],
      });
      final seed = EvalVocabulary.fromJson([
        {'value': '카페', 'count': 5},
      ]);
      final aggregate =
          await EvalRunner(
            backend: backend,
            now: () => DateTime.utc(2026, 8, 1),
          ).run(
            _taggedManifest(),
            Directory('.'),
            onlySampleIds: {'holdout-01', 'holdout-02', 'holdout-03'},
            repeat: 2,
            vocabulary: seed,
            growVocabulary: true,
          );

      expect(backend.receivedVocabularies, [
        // Both runs of one sample see the same vocabulary.
        [('카페', 5)],
        [('카페', 5)],
        [('카페', 5), ('레시피', 1), ('국·찌개', 1)],
        [('카페', 5), ('레시피', 1), ('국·찌개', 1)],
        [('카페', 5), ('레시피', 2), ('국·찌개', 1)],
        [('카페', 5), ('레시피', 2), ('국·찌개', 1)],
      ]);
      final vocabulary =
          aggregate.toJson()['vocabulary']! as Map<String, Object?>;
      expect(vocabulary['sent'], isTrue);
      expect(vocabulary['grown'], isTrue);
      expect(vocabulary['initialEntries'], 1);
      expect(aggregate.toPrettyJson(), isNot(contains('카페')));
    });

    test(
      'grows from empty without a file and skips failed first runs',
      () async {
        final backend = _ScriptedTagBackend({
          'holdout-01': [null],
          'holdout-02': [
            [('레시피', 0.9)],
          ],
          'holdout-03': [
            [('레시피', 0.9)],
          ],
        });
        await EvalRunner(
          backend: backend,
          now: () => DateTime.utc(2026, 8, 1),
        ).run(
          _taggedManifest(),
          Directory('.'),
          onlySampleIds: {'holdout-01', 'holdout-02', 'holdout-03'},
          growVocabulary: true,
        );
        expect(backend.receivedVocabularies, [
          <(String, int)>[],
          <(String, int)>[],
          [('레시피', 1)],
        ]);
      },
    );
  });
}

EvalCheck _check(EvalRunResult result, String name) =>
    result.checks.firstWhere((check) => check.name == name);

Map<String, Object?> _analysis(
  EvalSample sample, {
  required List<Object?> tags,
}) {
  return {
    'analysis': {
      'domain': sample.expected.domain.wireName,
      'contentKind': sample.expected.kind.wireName,
      'completeness': sample.expected.completeness.wireName,
      'errors': const <Object?>[],
      'tags': tags,
    },
  };
}

/// A one-sample manifest whose `expected` block carries the given tags; the
/// helper validates through the same path as a real manifest.
EvalSample _sampleWithTags({
  List<String>? expectedTags,
  List<String>? forbiddenTags,
}) {
  final json = _singleSampleJson();
  final sample =
      (json['samples']! as List<Object?>).single as Map<String, Object?>;
  final expected = sample['expected']! as Map<String, Object?>;
  if (expectedTags != null) {
    expected['expectedTags'] = expectedTags;
  }
  if (forbiddenTags != null) {
    expected['forbiddenTags'] = forbiddenTags;
  }
  return EvalManifest.fromJson(json).samples.single;
}

/// A full 17-scenario manifest whose first sample carries [expectedTags] and
/// whose other samples carry none, so tag values only reach the report through
/// that one sample's checks.
EvalManifest _taggedManifest({List<String>? expectedTags}) {
  final scenarios = EvalScenario.values;
  return EvalManifest.fromJson({
    'schemaVersion': 1,
    'samples': <Object?>[
      for (var index = 0; index < scenarios.length; index++)
        <String, Object?>{
          'sampleId': 'holdout-${(index + 1).toString().padLeft(2, '0')}',
          'scenario': scenarios[index].wireName,
          'input': <String, Object?>{
            'imageFile':
                'holdout-${(index + 1).toString().padLeft(2, '0')}.jpg',
            'mimeType': 'image/jpeg',
          },
          'expected': <String, Object?>{
            'domain': 'food',
            'kind': 'recipe',
            'completeness': 'partial',
            'requiredErrorCodes': <Object?>[],
            'allowedErrorCodes': <Object?>[],
            'forbiddenErrorCodes': <Object?>['raw_content_exposed'],
            if (index == 0) 'expectedTags': expectedTags ?? ['레시피'],
            if (index == 0) 'forbiddenTags': <Object?>['성수'],
          },
        },
    ],
  });
}

final class _DeterministicBackend implements EvalBackend {
  static const privateResponseMarker = 'SYNTHETIC_PRIVATE_RESPONSE_MARKER';

  final requestedIds = <String>[];

  @override
  Future<Map<String, Object?>> analyze(
    EvalSample sample,
    Directory dataDirectory, {
    EvalVocabulary? vocabulary,
  }) async {
    requestedIds.add(sample.sampleId);
    return {
      'analysis': {
        'domain': sample.expected.domain.wireName,
        'contentKind': sample.expected.kind.wireName,
        'completeness': sample.expected.completeness.wireName,
        'errors': [
          for (final code in sample.expected.requiredErrorCodes) {'code': code},
        ],
        'rawText': privateResponseMarker,
        'accountName': privateResponseMarker,
      },
    };
  }
}

/// Returns, per sample, a scripted tag set for each successive call; a `null`
/// script entry fails that call. Records the vocabulary each call received.
final class _ScriptedTagBackend implements EvalBackend {
  _ScriptedTagBackend(this.script);

  final Map<String, List<List<(String, double)>?>> script;
  final receivedVocabularies = <List<(String, int)>>[];
  final _calls = <String, int>{};

  @override
  Future<Map<String, Object?>> analyze(
    EvalSample sample,
    Directory dataDirectory, {
    EvalVocabulary? vocabulary,
  }) async {
    receivedVocabularies.add([
      for (final entry in vocabulary?.entries ?? const <EvalVocabularyEntry>[])
        (entry.value, entry.count),
    ]);
    final call = _calls[sample.sampleId] ?? 0;
    _calls[sample.sampleId] = call + 1;
    final tags = script[sample.sampleId]?[call];
    if (tags == null) {
      throw const EvalBackendException('backend_http_500');
    }
    return _analysis(
      sample,
      tags: [
        for (final (value, confidence) in tags)
          {'value': value, 'confidence': confidence},
      ],
    );
  }
}

final class _LeakyErrorBackend implements EvalBackend {
  const _LeakyErrorBackend();

  @override
  Future<Map<String, Object?>> analyze(
    EvalSample sample,
    Directory dataDirectory, {
    EvalVocabulary? vocabulary,
  }) {
    throw const EvalBackendException('account_private_marker');
  }
}

Map<String, Object?> _singleSampleJson() {
  return {
    'schemaVersion': 1,
    'samples': <Object?>[
      <String, Object?>{
        'sampleId': 'holdout-01',
        'scenario': 'recipe_partial_mixed_text',
        'input': <String, Object?>{
          'imageFile': 'holdout-01.jpg',
          'mimeType': 'image/jpeg',
        },
        'expected': <String, Object?>{
          'domain': 'food',
          'kind': 'recipe',
          'completeness': 'partial',
          'allowedCompleteness': <Object?>[],
          'requiredErrorCodes': <Object?>[],
          'allowedErrorCodes': <Object?>[],
          'forbiddenErrorCodes': <Object?>['raw_content_exposed'],
        },
      },
    ],
  };
}
