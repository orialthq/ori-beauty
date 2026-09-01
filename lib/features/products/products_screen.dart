import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_controller.dart';
import '../common/shell_menu_button.dart';
import 'saved_library_item.dart';
import 'tag_contents_screen.dart';

/// 정리함: every tag in the library, most used first.
///
/// There is no folder to open and no child to find inside it. What a reader
/// arrives with is a word — 스킨케어, 을지로 — and the list answers it by
/// putting the words they use most at the top. The count beside each is what
/// tells two similar words apart, and it is also the table a later pass will
/// read to decide which of them mean the same thing.
final class ProductsScreen extends StatelessWidget {
  const ProductsScreen({required this.controller, this.onOpenMenu, super.key});

  final AppController controller;

  /// Opens the drawer. Every screen carries this now that the tab bar is gone.
  final VoidCallback? onOpenMenu;

  void _open(BuildContext context, String? tag) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TagContentsScreen(controller: controller, tag: tag),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final items = savedLibraryItems(controller);
        final counts = controller.tagCounts;
        final untagged = items.where((item) => item.tags.isEmpty).length;

        return ListView(
          key: const PageStorageKey('products'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            40 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            ShellHeader(
              onOpenMenu: onOpenMenu,
              title: '정리함',
              actions: [_SavedCount(total: items.length)],
            ),
            const SizedBox(height: 12),
            if (untagged > 0) ...[
              _UntaggedRow(count: untagged, onTap: () => _open(context, null)),
              const SizedBox(height: 18),
            ],
            if (counts.isEmpty)
              const _Empty()
            else
              for (final entry in counts) ...[
                _TagRow(
                  name: entry.tag.value,
                  count: entry.count,
                  onTap: () => _open(context, entry.tag.value),
                ),
                const SizedBox(height: 8),
              ],
          ],
        );
      },
    );
  }
}

/// How much is in here, beside the name rather than under it.
final class _SavedCount extends StatelessWidget {
  const _SavedCount({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        '$total 저장됨',
        style: const TextStyle(
          color: AppTheme.muted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

final class _TagRow extends StatelessWidget {
  const _TagRow({required this.name, required this.count, required this.onTap});

  final String name;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('tag-row-$name'),
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: '$name $count개',
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 58),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    Text(
                      '$count',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.subtle,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the analysis could not name.
///
/// 분류 필요 used to be a folder, which made not knowing look like a place to
/// put things. It is the absence of tags now, and this row is how a reader
/// finds what is waiting for one.
final class _UntaggedRow extends StatelessWidget {
  const _UntaggedRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('tag-row-untagged'),
      color: AppTheme.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.caution.withValues(alpha: 0.46)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Icon(
                  Icons.help_outline_rounded,
                  color: AppTheme.caution,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '태그가 없는 것 $count개',
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: AppTheme.caution,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '아직 정리한 게 없어요',
              style: TextStyle(
                color: AppTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '콘텐츠를 확인하고 정리하면 붙은 태그가 여기 모여요.',
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
