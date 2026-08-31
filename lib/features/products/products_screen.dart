import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../common/content_folder_ui.dart';
import '../common/shell_menu_button.dart';
import 'saved_library_item.dart';
import 'subcategory_deck_screen.dart';

final class ProductsScreen extends StatefulWidget {
  const ProductsScreen({required this.controller, this.onOpenMenu, super.key});

  final AppController controller;

  /// Opens the drawer. Every screen carries this now that the tab bar is gone.
  final VoidCallback? onOpenMenu;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

final class _ProductsScreenState extends State<ProductsScreen> {
  ContentFolder _selectedFolder = ContentFolder.beauty;

  void _openSubcategories({String? initialSubcategory, ContentFolder? folder}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubcategoryDeckScreen(
          controller: widget.controller,
          folder: folder ?? _selectedFolder,
          initialSubcategory: initialSubcategory,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final items = savedLibraryItems(widget.controller);
        final itemsByFolder = <ContentFolder, List<SavedLibraryItem>>{
          for (final folder in defaultContentFolders) folder: [],
        };
        for (final item in items) {
          itemsByFolder[item.folder]?.add(item);
        }
        final needsClassificationCount = items
            .where((item) => item.folder == ContentFolder.needsClassification)
            .length;

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
              onOpenMenu: widget.onOpenMenu,
              title: '정리함',
              actions: [_SavedCount(total: items.length)],
            ),
            if (needsClassificationCount > 0) ...[
              const SizedBox(height: 14),
              _NeedsClassificationBanner(
                count: needsClassificationCount,
                onTap: () => _openSubcategories(
                  folder: ContentFolder.needsClassification,
                ),
              ),
            ],
            const SizedBox(height: 24),
            _FolderStack(
              selected: _selectedFolder,
              itemsByFolder: itemsByFolder,
              onSelected: (folder) {
                setState(() => _selectedFolder = folder);
              },
              onOpenSubcategories: ({initialSubcategory}) =>
                  _openSubcategories(initialSubcategory: initialSubcategory),
              onOpenItem: (item) => openSavedLibraryItem(
                context,
                controller: widget.controller,
                item: item,
              ),
            ),
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

final class _NeedsClassificationBanner extends StatelessWidget {
  const _NeedsClassificationBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final folder = ContentFolder.needsClassification;
    return Material(
      key: const Key('folder-needsClassification'),
      color: AppTheme.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: folder.color.withValues(alpha: 0.46)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              children: [
                Icon(folder.icon, color: folder.color, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '분류가 필요한 콘텐츠 $count개',
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        '눌러서 세부 분류를 확인해요',
                        style: TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

final class _FolderStack extends StatefulWidget {
  const _FolderStack({
    required this.selected,
    required this.itemsByFolder,
    required this.onSelected,
    required this.onOpenSubcategories,
    required this.onOpenItem,
  });

  final ContentFolder selected;
  final Map<ContentFolder, List<SavedLibraryItem>> itemsByFolder;
  final ValueChanged<ContentFolder> onSelected;
  final void Function({String? initialSubcategory}) onOpenSubcategories;
  final ValueChanged<SavedLibraryItem> onOpenItem;

  @override
  State<_FolderStack> createState() => _FolderStackState();
}

final class _FolderStackState extends State<_FolderStack> {
  static const _itemExtent = 62.0;

  late int _centeredIndex;
  late FixedExtentScrollController _wheelController;

  @override
  void initState() {
    super.initState();
    _centeredIndex = _folderIndex(widget.selected);
    _wheelController = FixedExtentScrollController(initialItem: _centeredIndex);
  }

  @override
  void didUpdateWidget(covariant _FolderStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIndex = _folderIndex(widget.selected);
    if (nextIndex == _centeredIndex) {
      return;
    }
    _centeredIndex = nextIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_wheelController.hasClients) {
        return;
      }
      _wheelController.animateToItem(
        nextIndex,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _wheelController.dispose();
    super.dispose();
  }

  int _folderIndex(ContentFolder folder) {
    final index = defaultContentFolders.indexOf(folder);
    return index < 0 ? 0 : index;
  }

  void _handleWheelChange(int index) {
    if (index == _centeredIndex) {
      return;
    }
    setState(() => _centeredIndex = index);
    widget.onSelected(defaultContentFolders[index]);
  }

  void _selectIndex(int index) {
    final boundedIndex = index.clamp(0, defaultContentFolders.length - 1);
    if (boundedIndex != _centeredIndex) {
      setState(() => _centeredIndex = boundedIndex);
      widget.onSelected(defaultContentFolders[boundedIndex]);
    }
    _wheelController.animateToItem(
      boundedIndex,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _moveBy(int amount) {
    var nextIndex = _centeredIndex + amount;
    if (nextIndex < 0) {
      nextIndex = defaultContentFolders.length - 1;
    } else if (nextIndex >= defaultContentFolders.length) {
      nextIndex = 0;
    }
    _selectIndex(nextIndex);
  }

  @override
  Widget build(BuildContext context) {
    final folder = defaultContentFolders[_centeredIndex];
    final items = widget.itemsByFolder[folder] ?? const <SavedLibraryItem>[];
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final wheelDiameter = textScale > 1.3 ? 304.0 : 284.0;

    return Column(
      children: [
        Semantics(
          label: '상위 폴더 룰렛, ${folder.label} 선택됨',
          child: Center(
            child: SizedBox.square(
              dimension: wheelDiameter,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    key: const Key('folder-roulette'),
                    duration: const Duration(milliseconds: 240),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          folder.color.withValues(alpha: 0.2),
                          AppTheme.surfaceRaised,
                          AppTheme.surface,
                        ],
                        stops: const [0, 0.62, 1],
                      ),
                      border: Border.all(
                        color: folder.color.withValues(alpha: 0.56),
                        width: 1.4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: folder.color.withValues(alpha: 0.13),
                          blurRadius: 28,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  ClipOval(
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('top-folder-wheel'),
                      controller: _wheelController,
                      itemExtent: _itemExtent,
                      diameterRatio: 1.35,
                      perspective: 0.0045,
                      squeeze: 0.94,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: _handleWheelChange,
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: defaultContentFolders.length,
                        builder: (context, index) {
                          final option = defaultContentFolders[index];
                          return _RouletteFolderOption(
                            key: Key('folder-${option.name}'),
                            folder: option,
                            count: widget.itemsByFolder[option]?.length ?? 0,
                            selected: index == _centeredIndex,
                            onTap: () => _selectIndex(index),
                          );
                        },
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: Container(
                      height: _itemExtent + 4,
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: folder.color.withValues(alpha: 0.9),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 13),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _WheelStepButton(
              tooltip: '이전 폴더',
              icon: Icons.keyboard_arrow_up_rounded,
              onPressed: () => _moveBy(-1),
            ),
            const SizedBox(width: 18),
            SizedBox(
              width: 92,
              child: Column(
                children: [
                  Text(
                    folder.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_centeredIndex + 1} / ${defaultContentFolders.length}',
                    style: const TextStyle(
                      color: AppTheme.subtle,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            _WheelStepButton(
              tooltip: '다음 폴더',
              icon: Icons.keyboard_arrow_down_rounded,
              onPressed: () => _moveBy(1),
            ),
          ],
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: _FolderDetailCard(
            key: Key('folder-detail-${folder.name}'),
            folder: folder,
            items: items,
            onOpenSubcategories: widget.onOpenSubcategories,
            onOpenItem: widget.onOpenItem,
          ),
        ),
      ],
    );
  }
}

final class _RouletteFolderOption extends StatelessWidget {
  const _RouletteFolderOption({
    required this.folder,
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final ContentFolder folder;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${folder.label} 폴더, $count개',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: const BoxConstraints(minHeight: 48),
              margin: const EdgeInsets.symmetric(horizontal: 28, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 19),
              decoration: BoxDecoration(
                color: selected ? folder.color : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      folder.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF1B100C)
                            : AppTheme.muted,
                        fontSize: selected ? 18 : 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFF1B100C)
                          : AppTheme.subtle,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _WheelStepButton extends StatelessWidget {
  const _WheelStepButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      color: AppTheme.ink,
      iconSize: 25,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        backgroundColor: AppTheme.surfaceRaised,
        side: const BorderSide(color: AppTheme.border),
      ),
    );
  }
}

final class _FolderDetailCard extends StatelessWidget {
  const _FolderDetailCard({
    required this.folder,
    required this.items,
    required this.onOpenSubcategories,
    required this.onOpenItem,
    super.key,
  });

  final ContentFolder folder;
  final List<SavedLibraryItem> items;
  final void Function({String? initialSubcategory}) onOpenSubcategories;
  final ValueChanged<SavedLibraryItem> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final subcategoryCounts = <String, int>{};
    for (final item in items) {
      subcategoryCounts.update(
        item.subcategory,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final subcategories = subcategoryCounts.entries.toList()
      ..sort((left, right) {
        final countOrder = right.value.compareTo(left.value);
        return countOrder != 0 ? countOrder : left.key.compareTo(right.key);
      });

    return Container(
      decoration: BoxDecoration(
        color: folder.color,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: folder.color.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  folder.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1B100C),
                    fontSize: 27,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B100C).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${items.length}',
                  style: const TextStyle(
                    color: Color(0xFF1B100C),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (items.isEmpty)
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: _EmptyFolderMessage(folder: folder),
              ),
            )
          else ...[
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: subcategories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (context, index) {
                  final entry = subcategories[index];
                  return _SubcategoryChip(
                    key: Key('subcategory-${entry.key}'),
                    label: entry.key,
                    count: entry.value,
                    onTap: () =>
                        onOpenSubcategories(initialSubcategory: entry.key),
                  );
                },
              ),
            ),
            const SizedBox(height: 11),
            _RecentItemRow(
              item: items.first,
              onTap: () => onOpenItem(items.first),
            ),
            const SizedBox(height: 17),
            _OpenSubcategoriesButton(
              folder: folder,
              subcategoryCount: subcategories.length,
              onTap: () => onOpenSubcategories(),
            ),
          ],
        ],
      ),
    );
  }
}

final class _SubcategoryChip extends StatelessWidget {
  const _SubcategoryChip({
    required this.label,
    required this.count,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B100C).withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                '$label $count',
                style: const TextStyle(
                  color: Color(0xFF1B100C),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _RecentItemRow extends StatelessWidget {
  const _RecentItemRow({required this.item, required this.onTap});

  final SavedLibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B100C).withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.bookmark_rounded,
                  size: 18,
                  color: Color(0xFF1B100C),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF1B100C),
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: Color(0xFF1B100C),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _OpenSubcategoriesButton extends StatelessWidget {
  const _OpenSubcategoriesButton({
    required this.folder,
    required this.subcategoryCount,
    required this.onTap,
  });

  final ContentFolder folder;
  final int subcategoryCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('open-subcategories-${folder.name}'),
      color: const Color(0xFF24100A),
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '세부 분류 열기 · $subcategoryCount',
                    style: TextStyle(
                      color: folder.color,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: folder.color,
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _EmptyFolderMessage extends StatelessWidget {
  const _EmptyFolderMessage({required this.folder});

  final ContentFolder folder;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          folder.icon,
          size: 38,
          color: const Color(0xFF1B100C).withValues(alpha: 0.64),
        ),
        const SizedBox(height: 14),
        Text(
          '${folder.label} 폴더가 비어 있어요',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF1B100C),
            fontSize: 18,
            height: 1.35,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}
