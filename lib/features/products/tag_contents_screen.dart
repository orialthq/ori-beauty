import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_controller.dart';
import 'saved_library_item.dart';

/// Everything filed under one tag.
///
/// Rebuilt from the controller rather than handed a list, so retagging
/// something from its own page takes it off this one without a trip back out.
final class TagContentsScreen extends StatelessWidget {
  const TagContentsScreen({
    required this.controller,
    required this.tag,
    super.key,
  });

  final AppController controller;

  /// The tag to show, or null for the things carrying none at all.
  final String? tag;

  String get _title => tag ?? '태그 없음';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        title: Text(_title),
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final items = savedLibraryItems(controller)
              .where(
                (item) => tag == null ? item.tags.isEmpty : item.hasTag(tag!),
              )
              .toList(growable: false);

          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '여기 있던 게 없어졌어요.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 14),
                ),
              ),
            );
          }

          return ListView.separated(
            key: const PageStorageKey('tag-contents'),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _ItemRow(
              item: items[index],
              onTap: () => openSavedLibraryItem(
                context,
                controller: controller,
                item: items[index],
              ),
            ),
          );
        },
      ),
    );
  }
}

final class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onTap});

  final SavedLibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Its other tags, so a reader can see what else this thing is filed under
    // without opening it. The one they came in by is left off: it is the title
    // of the screen they are on.
    final others = item.tags.map((tag) => tag.value).toList(growable: false);

    return Material(
      key: Key('tag-item-${item.id}'),
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.ink,
                        fontSize: 15,
                        height: 1.35,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (item.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (others.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        others.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.subtle,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.subtle),
            ],
          ),
        ),
      ),
    );
  }
}
