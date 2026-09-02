import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../analysis/structured_review_screen.dart';
import '../product/product_detail_screen.dart';

/// A display-safe, data-backed item in the organized library.
///
/// The app currently stores legacy product groups and newer structured
/// captures side by side. This adapter lets the archive and its child screens
/// present both without inventing placeholder content.
final class SavedLibraryItem {
  const SavedLibraryItem._({
    required this.id,
    required this.title,
    required this.cardTitle,
    required this.subtitle,
    required this.searchableText,
    required this.tags,
    required this.updatedAt,
    this.thumbnailPath,
    this.captureId,
    this.groupId,
  });

  factory SavedLibraryItem.forCapture(CaptureRecord capture) {
    final structured = capture.analysis!.structuredContent!;
    final title = structured.title.value?.trim();
    final place = structured.place?.name?.trim();
    final facts = structured.facts
        .map((fact) => '${fact.label} ${fact.value}')
        .join(' ');
    final tags = capture.contentTags;
    return SavedLibraryItem._(
      id: capture.raw.id,
      title: title == null || title.isEmpty ? '제목 없음' : title,
      // On a card the place's own name beats the caption it was posted under:
      // 화육계 is what the reader is trying to find again, 을지로 골목 숯불
      // 닭발집 is how somebody advertised it, and it does not fit anyway.
      cardTitle: place != null && place.isNotEmpty
          ? place
          : (title == null || title.isEmpty ? '제목 없음' : title),
      subtitle: structured.summary.trim(),
      searchableText: <String>[
        for (final tag in tags) tag.value,
        title ?? '',
        structured.summary,
        structured.place?.name ?? '',
        structured.place?.address ?? '',
        facts,
      ].join(' ').toLowerCase(),
      tags: tags,
      updatedAt: capture.raw.receivedAt,
      // The screenshot the reader took. It is the fastest way they will
      // recognize this again, faster than the title we gave it.
      thumbnailPath: capture.raw.attachments.isEmpty
          ? null
          : capture.raw.attachments.first.filePath,
      captureId: capture.raw.id,
    );
  }

  factory SavedLibraryItem.forGroup(
    ProductGroup group,
    AppController controller,
  ) {
    final tags = controller.tagsForGroup(group.id);
    final statements = group.statements
        .map(
          (statement) => '${statement.topic} ${statement.originalExpression}',
        )
        .join(' ');
    return SavedLibraryItem._(
      id: group.id,
      title: group.identity.name,
      cardTitle: group.identity.name,
      subtitle: <String>[
        group.identity.brand,
        group.identity.category,
        group.identity.amount,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      searchableText: <String>[
        for (final tag in tags) tag.value,
        group.identity.brand,
        group.identity.name,
        group.identity.category,
        group.identity.amount,
        statements,
      ].join(' ').toLowerCase(),
      tags: tags,
      updatedAt: group.updatedAt,
      groupId: group.id,
    );
  }

  final String id;
  final String title;

  /// The shortest name that still identifies this. Used where the picture is
  /// carrying most of the recognition and there is no room to spare.
  final String cardTitle;
  final String subtitle;
  final String searchableText;

  /// Every word this is filed under. A saved thing appears under each of them,
  /// which is what lets one capture sit in 레시피 and 건강·운동 at once.
  final List<ContentTag> tags;

  final DateTime updatedAt;

  /// The original screenshot, when there is one. Legacy product groups predate
  /// image capture and carry none, so the library draws them as type instead.
  final String? thumbnailPath;

  final String? captureId;
  final String? groupId;

  bool hasTag(String value) => tags.any((tag) => tag.value == value);

  bool matches(String query) => searchableText.contains(query.toLowerCase());
}

List<SavedLibraryItem> savedLibraryItems(AppController controller) {
  final items = <SavedLibraryItem>[
    for (final capture in controller.organizedStructuredCaptures)
      SavedLibraryItem.forCapture(capture),
    for (final group in controller.groups)
      SavedLibraryItem.forGroup(group, controller),
  ];
  items.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  return items;
}

void openSavedLibraryItem(
  BuildContext context, {
  required AppController controller,
  required SavedLibraryItem item,
}) {
  final captureId = item.captureId;
  final Route<void> route;
  if (captureId != null) {
    route = MaterialPageRoute<void>(
      builder: (_) =>
          StructuredReviewScreen(controller: controller, captureId: captureId),
    );
  } else {
    route = MaterialPageRoute<void>(
      builder: (_) =>
          ProductDetailScreen(controller: controller, groupId: item.groupId!),
    );
  }
  Navigator.of(context).push(route);
}
