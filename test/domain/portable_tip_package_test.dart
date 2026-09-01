import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/domain/portable_tip_package.dart';

void main() {
  group('PortableTipPackageCodec', () {
    test('round-trips the stable v1 format and public file contract', () {
      final package = _basicPackage();

      final encoded = PortableTipPackageCodec.encode(package);
      final decoded = PortableTipPackageCodec.decode(encoded);

      expect(PortableTipPackageCodec.fileExtension, 'trunon');
      expect(
        PortableTipPackageCodec.mimeType,
        'application/vnd.orialthq.trunon.tip+json',
      );
      expect(
        PortableTipPackageCodec.uniformTypeIdentifier,
        'com.orialthq.trunon.tip',
      );
      expect(decoded.packageId, 'tip-export-0001');
      expect(decoded.exportedAt, DateTime.utc(2026, 8, 5, 3));
      expect(decoded.title, '동묘집 철판쪽꾸미');
      expect(decoded.tags, ['맛집·카페', '한식']);
      expect(decoded.sections.single.kind, PortableTipSectionKind.facts);
      expect(decoded.facts.single.label, '영업시간');
      expect(decoded.facts.single.value, '11:00~21:00');
      expect(decoded.place?.address, '서울 종로구 종로52길 43-9');
      expect(decoded.source?.url, 'https://example.com/post/7');
      expect(decoded.message, '우리 주말에 같이 갈래?');
    });

    test('UTF-8 API round-trips Korean without platform dependencies', () {
      final bytes = PortableTipPackageCodec.encodeUtf8(_basicPackage());

      final decoded = PortableTipPackageCodec.decodeUtf8(bytes);

      expect(decoded.title, '동묘집 철판쪽꾸미');
      expect(bytes, isA<Uint8List>());
    });

    test('preserves actionable ingredient and step fields as typed JSON', () {
      final package = PortableTipPackage.create(
        packageId: 'typed-tip-0001',
        exportedAt: DateTime.utc(2026, 8, 5),
        title: '쪽꾸미 요리',
        summary: '양념과 조리 순서',
        tags: const ['레시피', '해물 요리'],
        ingredientGroups: [
          PortableTipIngredientGroup(
            name: '양념',
            ingredients: [
              PortableTipIngredient(
                name: '고추장',
                amount: '1',
                unit: '큰술',
                preparation: '잘 풀기',
                optional: false,
                originalText: '고추장 1큰술',
              ),
            ],
          ),
        ],
        steps: [
          PortableTipStep(
            order: 1,
            instruction: '10분 끓인다',
            durationSeconds: 600,
            temperature: '100℃',
          ),
        ],
      );

      final encoded = PortableTipPackageCodec.encode(package);
      final decoded = PortableTipPackageCodec.decode(encoded);
      final ingredient = decoded.ingredientGroups.single.ingredients.single;

      expect(ingredient.name, '고추장');
      expect(ingredient.amount, '1');
      expect(ingredient.unit, '큰술');
      expect(ingredient.preparation, '잘 풀기');
      expect(ingredient.optional, isFalse);
      expect(ingredient.originalText, '고추장 1큰술');
      expect(decoded.steps.single.durationSeconds, 600);
      expect(decoded.steps.single.temperature, '100℃');
      expect(encoded, isNot(contains('confidence')));
      expect(encoded, isNot(contains('evidenceIds')));
    });

    test('rejects unknown fields so raw or image data cannot be smuggled', () {
      final json = _jsonObject(_basicPackage());
      final tip = json['tip']! as Map<String, Object?>;
      tip['rawText'] = '비공개 OCR 원문';

      expect(
        () => PortableTipPackageCodec.decode(jsonEncode(json)),
        throwsFormatException,
      );
    });

    test('rejects an unknown schema version and invalid nested types', () {
      final wrongVersion = _jsonObject(_basicPackage())..['schemaVersion'] = 9;
      final wrongSummary = _jsonObject(_basicPackage());
      (wrongSummary['tip']! as Map<String, Object?>)['summary'] = 42;
      final wrongTags = _jsonObject(_basicPackage());
      (wrongTags['tip']! as Map<String, Object?>)['tags'] = true;

      expect(
        () => PortableTipPackageCodec.decode(jsonEncode(wrongVersion)),
        throwsFormatException,
      );
      expect(
        () => PortableTipPackageCodec.decode(jsonEncode(wrongSummary)),
        throwsFormatException,
      );
      expect(
        () => PortableTipPackageCodec.decode(jsonEncode(wrongTags)),
        throwsFormatException,
      );
    });

    test('rejects files beyond the portable package byte limit', () {
      final oversized = Uint8List(PortableTipLimits.maxPackageBytes + 1);

      expect(
        () => PortableTipPackageCodec.decodeUtf8(oversized),
        throwsFormatException,
      );
    });

    test('imports the same package under a fresh local id each time', () {
      final encoded = PortableTipPackageCodec.encode(_basicPackage());
      var sequence = 0;

      final first = PortableTipPackageCodec.import(
        encoded,
        createLocalId: () => 'local-tip-${++sequence}'.padRight(16, '0'),
        importedAt: DateTime.utc(2026, 8, 5, 4),
      );
      final second = PortableTipPackageCodec.import(
        encoded,
        createLocalId: () => 'local-tip-${++sequence}'.padRight(16, '0'),
      );

      expect(first.localId, isNot(second.localId));
      expect(first.localId, isNot(first.sourcePackageId));
      expect(first.sourcePackageId, 'tip-export-0001');
      expect(first.importedAt, DateTime.utc(2026, 8, 5, 4));
    });

    test('refuses an importer that reuses the sender package id', () {
      final encoded = PortableTipPackageCodec.encode(_basicPackage());

      expect(
        () => PortableTipPackageCodec.import(
          encoded,
          createLocalId: () => 'tip-export-0001',
        ),
        throwsFormatException,
      );
    });
  });

  group('portable field safety', () {
    test(
      'normalizes whitespace, controls, duplicates, and tracking URL data',
      () {
        final package = PortableTipPackage.create(
          packageId: 'safe-tip-0001',
          exportedAt: DateTime.utc(2026, 8, 5),
          title: '  주말\n  맛집\u0000  ',
          summary: '  방문   메뉴  ',
          tags: const ['맛집·카페', '  한식  '],
          notes: const ['  예약\n필수  ', '예약 필수'],
          source: PortableTipSource(
            label: ' Instagram ',
            url:
                'https://example.com/post/7?keep=yes&utm_source=share&igsh=secret#profile',
          ),
          message: '  우리\n같이 가자  ',
        );

        expect(package.title, '주말 맛집');
        expect(package.summary, '방문 메뉴');
        expect(package.notes, ['예약 필수']);
        expect(package.sections.single.items, ['예약 필수']);
        expect(package.source?.label, 'Instagram');
        expect(package.source?.url, 'https://example.com/post/7?keep=yes');
        expect(package.message, '우리 같이 가자');
      },
    );

    test('rejects unsafe source URLs and overlong text', () {
      expect(
        () => PortableTipSource(url: 'javascript:alert(1)'),
        throwsFormatException,
      );
      expect(
        () => PortableTipSource(url: 'https://user:secret@example.com/post'),
        throwsFormatException,
      );
      expect(
        () => PortableTipPackage.create(
          packageId: 'safe-tip-0002',
          exportedAt: DateTime.utc(2026, 8, 5),
          title: List.filled(PortableTipLimits.maxTitleRunes + 1, '가').join(),
          summary: '',
          tags: const ['기타'],
        ),
        throwsFormatException,
      );
    });

    test('rejects empty ingredient groups and invalid detail counts', () {
      expect(
        () => PortableTipIngredientGroup(name: '양념', ingredients: const []),
        throwsFormatException,
      );
      expect(
        () => PortableTipPackage.create(
          packageId: 'safe-tip-0003',
          exportedAt: DateTime.utc(2026, 8, 5),
          title: '제목',
          summary: '',
          tags: const ['기타'],
          steps: [
            PortableTipStep(order: 1, instruction: '하나'),
            PortableTipStep(order: 1, instruction: '둘'),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => PortableTipPackage.create(
          packageId: 'safe-tip-0004',
          exportedAt: DateTime.utc(2026, 8, 5),
          title: '제목',
          summary: '',
          tags: const ['기타'],
          notes: List.generate(
            PortableTipLimits.maxNotes + 1,
            (index) => '메모 $index',
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('explicit export selection', () {
    test(
      'exports only selected capture details and no private image/raw data',
      () {
        final capture = _structuredCapture();
        final analysis = capture.analysis!.structuredContent!;

        final package = PortableTipPackage.fromStructuredCapture(
          packageId: 'capture-tip-0001',
          exportedAt: DateTime.utc(2026, 8, 5),
          capture: capture,
          selectedFacts: [analysis.facts.first],
          selectedSteps: [analysis.steps.last],
          includePlace: true,
          includeSource: true,
          sourceLabel: 'Instagram',
          message: '이거 같이 먹자',
        );
        final encoded = PortableTipPackageCodec.encode(package);

        expect(package.sections, hasLength(2));
        expect(package.sections[0].items, ['영업시간: 11:00~21:00']);
        expect(package.sections[1].items, ['2. 10분 끓인다 (100℃ · 600초)']);
        expect(package.facts.single.label, '영업시간');
        expect(package.steps.single.durationSeconds, 600);
        expect(package.steps.single.temperature, '100℃');
        expect(encoded, isNot(contains('화장실 정보')));
        expect(encoded, isNot(contains('비공개 캡처 원문')));
        expect(encoded, isNot(contains('/private/screenshot.jpg')));
        expect(encoded, isNot(contains('capture-original-id')));
        expect(encoded, isNot(contains('attachment-original-id')));
        expect(package.source?.url, 'https://instagram.com/reel/abc');
      },
    );

    test(
      'keeps place and source out unless the user explicitly selects them',
      () {
        final package = PortableTipPackage.fromStructuredCapture(
          packageId: 'capture-tip-0002',
          exportedAt: DateTime.utc(2026, 8, 5),
          capture: _structuredCapture(),
        );

        expect(package.sections, isEmpty);
        expect(package.place, isNull);
        expect(package.source, isNull);
      },
    );

    test('a capture with no tags is sent with none', () {
      final package = PortableTipPackage.create(
        packageId: 'capture-tip-0003',
        exportedAt: DateTime.utc(2026, 8, 5),
        title: '분류 전 팁',
        summary: '',
        tags: const <String>[],
      );

      expect(package.tags, isEmpty);
      expect(PortableTipPackageCodec.encode(package), contains('"tags":[]'));
    });
  });
}

PortableTipPackage _basicPackage() {
  return PortableTipPackage.create(
    packageId: 'tip-export-0001',
    exportedAt: DateTime.utc(2026, 8, 5, 3),
    title: '동묘집 철판쪽꾸미',
    summary: '종로에서 철판쪽꾸미를 판는 한식당',
    tags: const ['맛집·카페', '한식'],
    facts: [PortableTipFact(label: '영업시간', value: '11:00~21:00')],
    place: PortableTipPlace(name: '동묘집', address: '서울 종로구 종로52길 43-9'),
    source: PortableTipSource(
      label: 'Instagram',
      url: 'https://example.com/post/7?utm_source=share#author',
    ),
    message: '우리 주말에 같이 갈래?',
  );
}

Map<String, Object?> _jsonObject(PortableTipPackage package) {
  return jsonDecode(PortableTipPackageCodec.encode(package))
      as Map<String, Object?>;
}

CaptureRecord _structuredCapture() {
  const attachment = IncomingAttachment(
    id: 'attachment-original-id',
    filePath: '/private/screenshot.jpg',
    mimeType: 'image/jpeg',
    byteSize: 1024,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );
  const facts = [
    AnalysisFact(
      label: '영업시간',
      value: '11:00~21:00',
      confidence: 0.9,
      evidenceIds: [],
    ),
    AnalysisFact(
      label: '화장실 정보',
      value: '가게 외부',
      confidence: 0.8,
      evidenceIds: [],
    ),
  ];
  const ingredientGroups = [
    IngredientGroup(
      name: '양념',
      ingredients: [
        RecipeIngredient(
          name: '고추장',
          amount: '1',
          unit: '큰술',
          preparation: null,
          optional: false,
          originalText: '고추장 1큰술',
          confidence: 0.9,
          evidenceIds: [],
        ),
      ],
    ),
  ];
  const steps = [
    RecipeStep(
      order: 1,
      instruction: '재료를 넣는다',
      durationSeconds: null,
      temperature: null,
      evidenceIds: [],
    ),
    RecipeStep(
      order: 2,
      instruction: '10분 끓인다',
      durationSeconds: 600,
      temperature: '100℃',
      evidenceIds: [],
    ),
  ];
  const structured = StructuredContentAnalysis(
    schemaVersion: '2.0',
    model: 'gpt-5.6-luna',
    domain: ContentDomain.food,
    contentKind: ContentKind.place,
    tags: [
      ContentTag(value: '맛집·카페'),
      ContentTag(value: '한식'),
    ],
    completeness: StructuredCompleteness.complete,
    title: StructuredTitle(
      value: '동묘집',
      status: ObservedStatus.observed,
      confidence: 0.9,
      evidenceIds: [],
    ),
    place: StructuredPlace(
      name: '동묘집',
      address: '서울 종로구',
      searchArea: null,
      category: PlaceCategory.restaurant,
      confidence: 0.9,
      evidenceIds: [],
    ),
    summary: '종로의 철판쪽꾸미 맛집',
    evidence: [],
    ingredientGroups: ingredientGroups,
    steps: steps,
    facts: facts,
    conflicts: [],
    warnings: [],
  );
  return CaptureRecord(
    raw: RawCapture(
      id: 'capture-original-id',
      transportEventId: 'transport-original-id',
      receivedAt: DateTime.utc(2026, 8, 5),
      origin: CaptureOrigin.androidShare,
      mimeType: 'image/jpeg',
      rawText: '비공개 캡처 원문',
      rawUrl: 'https://instagram.com/reel/abc?igsh=private',
      semanticFingerprint: 'private-fingerprint',
      wasTruncated: false,
      originalLength: 12,
      sourcePackage: 'com.instagram.android',
      attachments: const [attachment],
    ),
    normalized: const NormalizedInput(
      inputId: 'capture-original-id',
      normalizerVersion: 'test',
      normalizedText: '비공개 캡처 원문',
      urls: [],
      semanticFingerprint: 'private-fingerprint',
      completeness: MaterialCompleteness.complete,
      warnings: [],
    ),
    status: CaptureStatus.organized,
    analysis: AnalysisRun(
      id: 'analysis-original-id',
      inputId: 'capture-original-id',
      normalizerVersion: 'test',
      analyzerVersion: 'test',
      status: AnalysisRunStatus.succeeded,
      completedAt: DateTime.utc(2026, 8, 5),
      evidence: const [],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      structuredContent: structured,
    ),
  );
}
