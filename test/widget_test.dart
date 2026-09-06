import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/app/ori_beauty_app.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/data/incoming_share_service.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/product/product_detail_screen.dart';
import 'package:ori_beauty/state/app_controller.dart';

void main() {
  testWidgets('renders the luffi home and organized library navigation', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'luffi');
    expect(find.byKey(const Key('home-luffi-brand')), findsOneWidget);
    expect(find.byKey(const Key('shell-menu-button')), findsOneWidget);
    expect(find.byKey(const Key('home-prompt-field')), findsOneWidget);
    expect(find.textContaining('TODAY'), findsNothing);
    expect(find.textContaining('READY TO SAVE'), findsNothing);
    expect(find.textContaining('오늘 들어온 걸'), findsNothing);
    expect(find.text('CAPTURE INBOX'), findsNothing);
    expect(find.text('들어온 내용을 확인하고 정리해요'), findsNothing);
    expect(find.text('발견만으로는 달라지지 않으니까.'), findsNothing);
    expect(find.text('정리된 내용을 확인하고 폴더에 넣어 두세요.'), findsNothing);
    expect(find.text('정리된 내용을 확인하고 저장해 주세요.'), findsNothing);
    // The next-step card and the category roulette left home; the box that
    // starts a plan took the space they were using.
    expect(find.text('1개만 확인하면 끝'), findsNothing);
    expect(
      find.byKey(const PageStorageKey('home-category-roulette')),
      findsNothing,
    );
    expect(find.byKey(const Key('home-inbox-card')), findsNothing);
    expect(find.byKey(const Key('home-library-card')), findsNothing);
    expect(find.text('들어온 것'), findsNothing);
    expect(find.text('최근 들어온 것'), findsNothing);
    expect(find.text('정리함 보기'), findsNothing);
    // Home keeps nothing but the box: no list of the newest, and no row
    // standing in for one. 콘텐츠 is in the drawer.
    expect(find.text('최근 콘텐츠'), findsNothing);
    expect(find.byKey(const Key('home-content-door')), findsNothing);
    // The tab bar is gone; every screen is behind the menu now.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('공유함'), findsNothing);
    expect(find.text('INPUT → 정리'), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(find.text('비교'), findsNothing);
    expect(find.text('내 기준'), findsNothing);

    await _openContentList(tester);
    expect(
      find.text(
        '전체 ${controller.captures.length}개  ·  '
        '정리 완료 ${controller.organizedCount}개  ·  '
        '분석 중 ${controller.analyzingCount}개',
      ),
      findsNothing,
    );

    // The list is pushed over the shell now, so come back out before reaching
    // for the tab bar underneath it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _openLibrary(tester);

    expect(find.text('정리함'), findsWidgets);
    expect(find.text('A R C H I V E'), findsNothing);
    expect(find.byKey(const Key('library-search-field')), findsNothing);

    // Tags are the instrument now, not the screen: they sit in a row above
    // what the reader saved rather than standing in front of it.
    final tag = controller.tagCounts.first.tag.value;
    expect(find.byKey(Key('library-filter-$tag')), findsOneWidget);

    final recentItem = find.text('카밍 앰플').last;
    await tester.ensureVisible(recentItem);
    await tester.pumpAndSettle();
    await tester.tap(recentItem);
    await tester.pumpAndSettle();

    expect(find.text('콘텐츠에서 나온 이야기'), findsOneWidget);
    expect(find.byKey(const Key('content-tag-editor')), findsOneWidget);
    expect(find.textContaining('사용자 확인 완료'), findsNothing);
    expect(find.textContaining('베이스라인'), findsNothing);
  });

  testWidgets('collapses and expands long saved source text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: ProductDetailScreen(
          controller: controller,
          groupId: 'group-baumlab-pore-balance',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sourceToggle = find.byKey(
      const ValueKey('source-toggle-capture-demo-baum-1'),
    );
    await tester.scrollUntilVisible(
      sourceToggle,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    final rawSource = find.byKey(
      const ValueKey('source-raw-capture-demo-baum-1'),
    );
    final collapsedText = tester.widget<Text>(rawSource);
    expect(collapsedText.maxLines, 3);
    expect(collapsedText.overflow, TextOverflow.ellipsis);

    await tester.tap(sourceToggle);
    await tester.pumpAndSettle();

    expect(tester.widget(rawSource), isA<SelectableText>());
    expect(find.text('접기'), findsWidgets);
  });

  testWidgets('a tag narrows the library where it stands', (tester) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    await _openLibrary(tester);

    final tags = controller.tagCounts;
    expect(tags, isNotEmpty);
    final busiest = tags.first;
    final chip = find.byKey(Key('library-filter-${busiest.tag.value}'));
    expect(chip, findsOneWidget);

    final total =
        controller.organizedStructuredCaptures.length +
        controller.groups.length;
    expect(find.text('$total 저장됨'), findsOneWidget);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    // No page is pushed. The header counts what the tag kept, which is the
    // whole feedback the reader gets that the tap did something.
    expect(find.text('${busiest.count} / $total'), findsOneWidget);
  });

  testWidgets('the archive is a list of tags, not a tree of folders', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    await _openLibrary(tester);

    // The folder roulette and the subcategory deck went with the folders.
    expect(find.byKey(const Key('folder-roulette')), findsNothing);
    expect(find.byKey(const Key('top-folder-wheel')), findsNothing);
    expect(find.byKey(const Key('library-search-field')), findsNothing);
    expect(find.text('정리함'), findsWidgets);
  });

  testWidgets('content filters use distinct selected colors', (tester) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await _openContentList(tester);

    final cases = <(String, Color)>[
      ('전체 ${controller.captures.length}', AppTheme.primary),
      ('확인 필요 ${controller.needsReviewCount}', AppTheme.caution),
      ('정리 완료 ${controller.organizedCount}', AppTheme.positive),
      ('내용 부족 ${controller.limitedOrFailedCount}', AppTheme.negative),
    ];
    for (final (label, color) in cases) {
      final filter = find.text(label);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(filter).style?.color, color);
    }
  });

  testWidgets('long press offers contextual organize and delete actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await _openContentList(tester);

    await tester.longPress(find.text('데이라이트 에어리 선 플루이드'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-action-organize')), findsOneWidget);
    expect(find.byKey(const Key('capture-action-delete')), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    final organizedItem = find.text('리프온 카밍 앰플');
    await tester.ensureVisible(organizedItem);
    await tester.pumpAndSettle();
    await tester.longPress(organizedItem);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-action-organize')), findsNothing);
    final deleteAction = find.byKey(const Key('capture-action-delete'));
    expect(deleteAction, findsOneWidget);
    final logicalScreenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      logicalScreenHeight - tester.getBottomRight(deleteAction).dy,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('manual input stays above Galaxy navigation and keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);

    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('콘텐츠 추가'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-input-safe-area')), findsOneWidget);
    expect(find.byKey(const Key('manual-input-scroll')), findsOneWidget);
    final input = tester.widget<TextField>(find.byType(TextField).last);
    expect(input.autofocus, isFalse);

    final submit = find.widgetWithText(FilledButton, '내용 분석하기');
    expect(915 - tester.getBottomRight(submit).dy, greaterThanOrEqualTo(48));

    await tester.tap(find.byType(TextField).last);
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byKey(const Key('manual-input-scroll')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(submit).dy, lessThanOrEqualTo(915 - 340));
  });

  testWidgets(
    'mobile platforms offer an in-app screenshot picker above the tip import',
    (tester) async {
      final service = InMemoryIncomingShareService()
        ..capturePickerAccepts = true;
      final controller = AppController(service);
      addTearDown(controller.dispose);

      await tester.pumpWidget(OriBeautyApp(controller: controller));
      await controller.initialize();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('콘텐츠 추가'));
      await tester.pumpAndSettle();

      final picker = find.widgetWithText(OutlinedButton, '갤러리에서 사진 여러 장 가져오기');
      final tipImport = find.widgetWithText(OutlinedButton, '받은 팁 파일 가져오기');
      expect(picker, findsOneWidget);
      expect(tipImport, findsOneWidget);
      expect(
        tester.getTopLeft(picker).dy,
        lessThan(tester.getTopLeft(tipImport).dy),
      );

      await tester.tap(picker);
      await tester.pumpAndSettle();

      expect(service.presentCapturePickerCount, 1);
      // An accepted image is already queued, so the sheet closes and the
      // pending drain surfaces it the same way a share does.
      expect(find.byKey(const Key('manual-input-safe-area')), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'a cancelled mobile picker keeps the add sheet open',
    (tester) async {
      final service = InMemoryIncomingShareService()
        ..capturePickerAccepts = false;
      final controller = AppController(service);
      addTearDown(controller.dispose);

      await tester.pumpWidget(OriBeautyApp(controller: controller));
      await controller.initialize();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('콘텐츠 추가'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(OutlinedButton, '갤러리에서 사진 여러 장 가져오기'),
      );
      await tester.pumpAndSettle();

      expect(service.presentCapturePickerCount, 1);
      expect(find.byKey(const Key('manual-input-safe-area')), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets('incomplete content can be deleted from its detail screen', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    final captureId = controller.addManualInput('오늘 다시 보고 싶은 짧은 메모');
    await tester.pumpAndSettle();
    await _openContentList(tester);

    await tester.tap(find.text('제품을 특정하지 못했어요').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-capture-detail')), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-capture-detail')));
    await tester.pumpAndSettle();
    expect(find.text('이 콘텐츠를 삭제할까요?'), findsOneWidget);
    expect(find.textContaining('갤러리 원본은 그대로'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-capture-delete')));
    await tester.pumpAndSettle();

    expect(controller.captureById(captureId), isNull);
    expect(find.text('콘텐츠'), findsWidgets);
  });

  testWidgets('reviews extracted fields and organizes a capture', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    await _openContentList(tester);

    await tester.tap(find.text('데이라이트 에어리 선 플루이드'));
    await tester.pumpAndSettle();

    expect(find.text('이렇게 정리했어요'), findsOneWidget);
    expect(find.text('저장하기 전에 잘못 읽힌 부분만 확인해 주세요.'), findsOneWidget);
    expect(find.textContaining('정규화된 URL'), findsNothing);
    expect(find.textContaining('신뢰도'), findsNothing);

    final tagEditor = find.byKey(const Key('content-tag-editor'));
    await tester.scrollUntilVisible(
      tagEditor,
      220,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(tagEditor, findsOneWidget);

    // A word the reader adds themselves, alongside whatever the analysis said.
    await tester.tap(find.byKey(const Key('tag-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tag-name-field')), '선케어');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    final amountField = find
        .byKey(const ValueKey('analysis-field-용량·규격'))
        .first;
    await tester.enterText(amountField, '50mL');
    final organizeButton = find.widgetWithText(FilledButton, '정리함에 저장');
    await tester.ensureVisible(organizeButton);
    await tester.pumpAndSettle();
    await tester.tap(organizeButton);
    await tester.pumpAndSettle();

    expect(
      controller.captureById('capture-demo-daylight-review')?.status,
      CaptureStatus.organized,
    );
    expect(
      controller
          .captureById('capture-demo-daylight-review')
          ?.contentTags
          .map((tag) => tag.value),
      contains('선케어'),
    );
    expect(find.text('콘텐츠'), findsWidgets);
  });

  testWidgets('incoming Android share is preserved in content list', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);
    service.add(
      IncomingShare(
        id: 'share-android',
        receivedAt: DateTime(2026, 7, 31),
        sharedText: '리프온 카밍 앰플 40ml가 촉촉하다고 했어요.',
        discoveredUrl: null,
      ),
    );

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    // A share is announced on home now, and the list is a tap away.
    await _openContentList(tester);
    expect(find.text('리프온 카밍 앰플 40ml가 촉촉하다고 했어요.'), findsOneWidget);
    final capture = controller.captures.firstWhere(
      (item) => item.raw.transportEventId == 'share-android',
    );
    expect(capture.status, CaptureStatus.needsReview);
    expect(await service.drainPending(), isEmpty);
  });

  testWidgets('URL-only share explains that a screenshot is needed', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'share-link-only',
          receivedAt: DateTime(2026, 8, 1),
          sharedText: 'https://www.instagram.com/reel/example/',
          discoveredUrl: 'https://www.instagram.com/reel/example/',
        ),
      );
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    expect(find.text('링크를 저장했어요'), findsWidgets);
    expect(find.textContaining('게시물 내용은 전달되지 않았어요'), findsWidgets);

    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    await _openContentList(tester);
    await tester.tap(find.text('링크를 저장했어요').first);
    await tester.pumpAndSettle();

    expect(find.text('링크는 저장했어요'), findsOneWidget);
    expect(find.text('스크린샷으로 이어서 저장하기'), findsOneWidget);
    expect(find.textContaining('캡처 미리보기의 공유 버튼'), findsOneWidget);
  });

  testWidgets('an incoming screenshot is announced on home', (tester) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    await _openLibrary(tester);
    expect(find.text('정리함'), findsWidgets);

    service.add(
      IncomingShare(
        id: 'share-screenshot-open',
        receivedAt: DateTime(2026, 7, 31),
        sharedText: '방금 연 스크린샷',
        discoveredUrl: null,
      ),
    );
    await tester.pumpAndSettle();

    // A share used to yank the reader to the 콘텐츠 tab. There is no such tab
    // now, so it lands on home and the banner announces it there.
    expect(find.byKey(const Key('shell-menu-button')), findsOneWidget);
    expect(find.text('정리가 준비됐어요'), findsOneWidget);
    expect(find.text('탭해서 내용을 확인해 주세요'), findsOneWidget);

    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('정리가 준비됐어요'), findsNothing);

    // The row itself lives in the list, which is a tap away rather than a tab.
    await _openContentList(tester);
    expect(find.text('방금 연 스크린샷'), findsNothing);
    final compactSummary = find.text('저장한 내용의 세부 정보를 확인해 주세요.');
    expect(compactSummary, findsOneWidget);
    expect(tester.widget<Text>(compactSummary).maxLines, 2);
  });

  testWidgets('a multi-photo import is announced once and opens the list', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    service
      ..add(
        IncomingShare(
          id: 'picker-ui-first',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '첫 번째 갤러리 사진',
          discoveredUrl: null,
        ),
      )
      ..add(
        IncomingShare(
          id: 'picker-ui-second',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '두 번째 갤러리 사진',
          discoveredUrl: null,
        ),
      );
    await tester.pumpAndSettle();

    expect(find.text('콘텐츠 2개를 가져왔어요'), findsOneWidget);
    expect(find.byKey(const Key('incoming-capture-dismiss')), findsOneWidget);
    expect(
      controller.captures.map((capture) => capture.raw.transportEventId),
      containsAll(['picker-ui-first', 'picker-ui-second']),
    );

    await tester.tap(find.text('콘텐츠 2개를 가져왔어요'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '콘텐츠'), findsOneWidget);
    expect(find.byKey(const Key('incoming-capture-dismiss')), findsNothing);
  });

  testWidgets('a coalesced import keeps each external source choice', (
    tester,
  ) async {
    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    service
      ..add(
        IncomingShare(
          id: 'external-source-first',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '첫 번째 외부 공유',
          discoveredUrl: null,
          sourceDeletionAvailable: true,
        ),
      )
      ..add(
        IncomingShare(
          id: 'external-source-second',
          receivedAt: DateTime(2026, 9, 6),
          sharedText: '두 번째 외부 공유',
          discoveredUrl: null,
          sourceDeletionAvailable: true,
        ),
      );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '갤러리에 두기'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '갤러리에 두기'));
    await tester.pumpAndSettle();

    // The second source still gets its own decision even though the home
    // banner and route reset were coalesced into one batch announcement.
    expect(find.widgetWithText(FilledButton, '갤러리에 두기'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '갤러리에 두기'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '갤러리에 두기'), findsNothing);
    expect(find.text('콘텐츠 2개를 가져왔어요'), findsOneWidget);
  });

  testWidgets('gallery source choice clears the Android system inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    final service = InMemoryIncomingShareService()
      ..add(
        IncomingShare(
          id: 'share-with-source-choice',
          receivedAt: DateTime(2026, 8, 5),
          sharedText: '갤러리 원본 선택 테스트',
          discoveredUrl: null,
          sourceDeletionAvailable: true,
        ),
      );
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    final deleteAction = find.widgetWithText(TextButton, '갤러리 원본 삭제');
    expect(deleteAction, findsOneWidget);
    final safeArea = tester.widget<SafeArea>(
      find.ancestor(of: deleteAction, matching: find.byType(SafeArea)).first,
    );
    expect(safeArea.bottom, isTrue);
    expect(safeArea.maintainBottomViewPadding, isTrue);
    expect(
      find.ancestor(
        of: deleteAction,
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(
      915 - tester.getBottomRight(deleteAction).dy,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.widgetWithText(FilledButton, '갤러리에 두기'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Android back returns to home before arming app exit',
    (tester) async {
      final service = InMemoryIncomingShareService();
      final controller = AppController(service);
      addTearDown(controller.dispose);

      await tester.pumpWidget(OriBeautyApp(controller: controller));
      await controller.initialize();
      await tester.pumpAndSettle();

      await _openLibrary(tester);
      expect(find.text('정리함'), findsWidgets);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shell-menu-button')), findsOneWidget);
      expect(find.text('한 번 더 누르면 앱을 종료해요.'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('한 번 더 누르면 앱을 종료해요.'), findsOneWidget);
      expect(
        tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
        isTrue,
      );

      await tester.pump(const Duration(seconds: 2));
      expect(
        tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
        isFalse,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android share flow returns to the source app from home',
    (tester) async {
      const navigationChannel = MethodChannel(
        'com.orialthq.ori_beauty/app_navigation/v1',
      );
      var returnRequested = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(navigationChannel, (call) async {
            if (call.method == 'returnToPreviousApp') {
              returnRequested = true;
              return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(navigationChannel, null),
      );

      final service = InMemoryIncomingShareService();
      final controller = AppController(service);
      addTearDown(controller.dispose);

      await tester.pumpWidget(OriBeautyApp(controller: controller));
      await controller.initialize();
      await tester.pumpAndSettle();

      service.add(
        IncomingShare(
          id: 'share-return-to-source',
          receivedAt: DateTime(2026, 8, 5),
          sharedText: '인스타그램에서 보낸 캡처',
          discoveredUrl: null,
        ),
      );
      await tester.pumpAndSettle();

      // The share lands on home already, so one back is the whole journey
      // out — it used to take two because a tab sat in between.
      expect(find.byKey(const Key('shell-menu-button')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(returnRequested, isTrue);
      expect(find.text('한 번 더 누르면 앱을 종료해요.'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('core screens remain usable at 150 percent text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final service = InMemoryIncomingShareService();
    final controller = AppController(service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(OriBeautyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _openContentList(tester);
    expect(tester.takeException(), isNull);

    // Back out of the pushed list before reaching for the tab bar under it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _openLibrary(tester);
    expect(tester.takeException(), isNull);
  });
}

/// 콘텐츠 is no longer a tab; home's 전체 보기 is the door.
/// Opens 정리함 the only way there is now: through the drawer.
Future<void> _openLibrary(WidgetTester tester) async {
  await _openDrawer(tester);
  await tester.tap(find.byKey(const Key('drawer-item-정리함')));
  await tester.pumpAndSettle();
}

Future<void> _openDrawer(WidgetTester tester) async {
  // An arriving capture is announced across the top of home, over the row the
  // menu sits in. A reader has to put it away before reaching the menu, and so
  // does this.
  final banner = find.byKey(const Key('incoming-capture-dismiss'));
  if (banner.evaluate().isNotEmpty) {
    await tester.tap(banner);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('shell-menu-button')));
  await tester.pumpAndSettle();
}

Future<void> _openContentList(WidgetTester tester) async {
  await _openDrawer(tester);
  await tester.tap(find.byKey(const Key('drawer-item-콘텐츠')));
  await tester.pumpAndSettle();
}
