// Opt-in visual preview, deliberately outside test/ so normal tests never write
// files. Run: flutter test tool/preview/render_luffi_preview.dart
// Uses only demo fixtures and never submits an image for analysis.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/batch_content_analysis_service.dart';
import 'package:ori_beauty/data/content_analysis_service.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/data/place_enrichment_service.dart';
import 'package:ori_beauty/data/tag_merge_service.dart';
import 'package:ori_beauty/data/tag_sense_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/home/home_shell.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Flutter widget tests otherwise render placeholder rectangles. The local
    // system fonts provide legible previews; phone typography may differ.
    for (final entry in {
      'Roboto': [
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/Roboto-Black.ttf',
      ],
      'MaterialIcons': [
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ],
      'Apple SD Gothic Neo': ['/System/Library/Fonts/AppleSDGothicNeo.ttc'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        final bytes = await File(path).readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  testWidgets(
    'render luffi home and analysis choices',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
        InMemoryIncomingShareService(),
        const BaselineContentAnalysisService(),
        null,
        null,
        const NoPlaceEnrichmentService(),
        const NoTagMergeService(),
        const NoTagSenseService(),
        null,
        _NoNetworkBatchService(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      const surfaceKey = Key('preview-surface');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          builder: (context, child) => RepaintBoundary(
            key: surfaceKey,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.noScaling,
                padding: const EdgeInsets.only(top: 24, bottom: 24),
                viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
              ),
              child: child!,
            ),
          ),
          home: HomeShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _save(tester, surfaceKey, 'home.png');
      await tester.tap(find.byTooltip('콘텐츠 추가'));
      await tester.pumpAndSettle();
      expect(find.text('절약해서 정리'), findsOneWidget);
      expect(find.text('바로 정리'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _save(tester, surfaceKey, 'analysis-modes.png');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

ThemeData _previewTheme() {
  final base = AppTheme.dark;
  // In production, Android supplies the Korean fallback for standalone button
  // styles. Explicitly substitute the loaded Korean face in the test renderer.
  ButtonStyle withKorean(ButtonStyle style) => style.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (states) => (style.textStyle?.resolve(states) ?? const TextStyle())
          .copyWith(fontFamily: 'Apple SD Gothic Neo'),
    ),
  );
  return base.copyWith(
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: withKorean(base.outlinedButtonTheme.style!),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: withKorean(base.filledButtonTheme.style!),
    ),
    textButtonTheme: TextButtonThemeData(
      style: withKorean(base.textButtonTheme.style!),
    ),
  );
}

Future<void> _save(WidgetTester tester, Key key, String filename) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = Directory('artifacts/luffi-preview');
    await output.create(recursive: true);
    await File(
      '${output.path}/$filename',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('Rendered ${output.path}/$filename');
  });
}

final class _NoNetworkBatchService implements BatchContentAnalysisService {
  @override
  Future<List<BatchAnalysisResponse>> poll(List<String> requestIds) async => [];

  @override
  Future<BatchAnalysisResponse> submit(
    CaptureRecord capture, {
    required String requestId,
  }) => throw StateError('Preview must not submit images.');
}
