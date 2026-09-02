import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/core/app_theme.dart';
import 'package:ori_beauty/domain/models.dart';
import 'package:ori_beauty/features/common/tag_ui.dart';

void main() {
  testWidgets('a tag shows what it was read from, and a guess says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TagEditor(
            tags: const [
              ContentTag(
                value: '성수',
                confidence: 0.9,
                quotes: ['성수동 2가', '서울숲'],
                facet: TagFacet.area,
              ),
              ContentTag(value: '데이트', confidence: 0.3, quotes: ['가게 이름']),
              ContentTag(value: '내가 단 것', source: TagSource.user),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    // The words behind a tag sit under the chips, so a claim about the
    // screenshot can be checked without opening the screenshot.
    expect(find.byKey(const Key('tag-evidence-성수')), findsOneWidget);
    expect(find.textContaining('"성수동 2가" · "서울숲"'), findsOneWidget);
    // A tag that could only be hung on the shop's name is marked as a guess;
    // one read off the screen is not.
    expect(find.byKey(const Key('tag-weak-데이트')), findsOneWidget);
    expect(find.byKey(const Key('tag-weak-성수')), findsNothing);
    // The reader's own tag has nothing to show for itself, and needs nothing.
    expect(find.byKey(const Key('tag-evidence-내가 단 것')), findsNothing);
    expect(find.byKey(const Key('tag-weak-내가 단 것')), findsNothing);
  });
}
