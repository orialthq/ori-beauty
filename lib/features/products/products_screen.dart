import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_controller.dart';
import '../common/shell_menu_button.dart';
import 'all_tags_screen.dart';
import 'capture_framing.dart';
import 'saved_library_item.dart';
import 'tag_constellation.dart';

/// How many tags the filter row offers before sending the reader to the full
/// list. Tuned on screen rather than derived: it is the number that still fits
/// a thumb's reach, and the point of the cap is that this row never grows no
/// matter how large the library gets.
const _offeredTags = 8;

/// What survives the current filter.
///
/// Every picked tag has to be on the item, not any one of them. A plan widens
/// its scope because it is gathering candidates worth suggesting; a reader
/// looking through what they saved is trying to end up with fewer things.
List<SavedLibraryItem> visibleItems(
  List<SavedLibraryItem> items, {
  required List<String> selected,
  required bool untaggedOnly,
}) {
  if (untaggedOnly) {
    return items.where((item) => item.tags.isEmpty).toList(growable: false);
  }
  if (selected.isEmpty) {
    return items;
  }
  return items
      .where((item) => selected.every(item.hasTag))
      .toList(growable: false);
}

/// The tags worth offering next: the ones carried by what is on screen right
/// now, most used first, capped.
///
/// Anything missing from here would empty the screen, so it is never shown as
/// a choice. That is what keeps this row the same size at four captures and at
/// four hundred: it refills as the reader narrows instead of growing.
///
/// Nothing is stored as a parent of anything. 을지로 follows 맛집·카페 because
/// they sit on the same captures, which means an entry point is earned by use
/// rather than granted by being built in.
List<({String name, int count})> offeredTags(
  List<SavedLibraryItem> visible, {
  required List<String> selected,
  int limit = _offeredTags,
}) {
  final counts = <String, int>{};
  for (final item in visible) {
    for (final tag in item.tags) {
      if (selected.contains(tag.value)) continue;
      counts[tag.value] = (counts[tag.value] ?? 0) + 1;
    }
  }
  final names = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [
    for (final name in names.take(limit)) (name: name, count: counts[name]!),
  ];
}

/// The words the reader has been using lately.
///
/// Offered instead of the most used ones, and the difference matters. Most
/// used is stable to the point of being frozen — it would show the same broad
/// half dozen for the life of the library, which is the folder scheme again.
/// Recently used moves with what the reader is actually doing, and what a
/// person is trying to find again is usually something they were recently
/// interested in.
List<String> recentTags(List<SavedLibraryItem> items, {int limit = 8}) {
  final seen = <String>[];
  for (final item in items) {
    for (final tag in item.tags) {
      if (seen.contains(tag.value)) continue;
      seen.add(tag.value);
      if (seen.length >= limit) return seen;
    }
  }
  return seen;
}

/// 정리함: what the reader saved, with tags as the instrument that narrows it.
///
/// The tags used to be the screen. That worked while there were eight folders
/// and stopped working the moment tags replaced them: four captures already
/// make twelve tags, ten of them holding one thing each, so the list grew with
/// the library and the library is meant to grow.
///
/// So the saved things are the screen now, and the row above them is capped.
/// It offers the tags that sit on what is currently shown, which means it
/// refills as the reader narrows: pick 맛집·카페 and 스킨케어 leaves, because
/// tapping it would empty the screen. Nothing is stored as a parent of anything
/// — the order is counted, not declared, so an entry point is earned by being
/// used rather than granted by being built in.
final class ProductsScreen extends StatefulWidget {
  const ProductsScreen({required this.controller, this.onOpenMenu, super.key});

  final AppController controller;

  /// Opens the drawer. Every screen carries this now that the tab bar is gone.
  final VoidCallback? onOpenMenu;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _selected = <String>[];
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  var _untaggedOnly = false;
  var _view = LibraryView.grid;

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _toggle(String tag) {
    setState(() {
      _untaggedOnly = false;
      if (!_selected.remove(tag)) {
        _selected.add(tag);
      }
    });
  }

  void _toggleUntagged() {
    setState(() {
      _untaggedOnly = !_untaggedOnly;
      _selected.clear();
    });
  }

  void _switchView() {
    setState(() {
      _view = _view == LibraryView.grid
          ? LibraryView.constellation
          : LibraryView.grid;
      _query.clear();
    });
  }

  /// What to offer while the reader is in the search box.
  ///
  /// Half-typed, it completes the word. Empty, it shows what they have been
  /// using lately. Either way it appears only once they have asked for it by
  /// tapping into the field — a row of tags standing permanently over the sky
  /// would be a short list on top of a complete one, and would clutter the one
  /// screen whose whole point is that it is uncluttered.
  List<String> _suggestions(List<SavedLibraryItem> items, List<String> terms) {
    final text = _query.text;
    final partial = text.endsWith(' ') || text.isEmpty ? '' : terms.last;
    final names = <String>[];
    for (final entry in widget.controller.tagCounts) {
      names.add(entry.tag.value);
    }
    if (partial.isEmpty) {
      return [
        for (final tag in recentTags(items, limit: 24))
          if (!terms.contains(tag.toLowerCase())) tag,
      ].take(8).toList(growable: false);
    }
    return [
      for (final name in names)
        if (name.toLowerCase().contains(partial) &&
            name.toLowerCase() != partial)
          name,
    ].take(8).toList(growable: false);
  }

  /// Adds or removes one word from what the reader is asking the sky.
  ///
  /// Tapping writes into the same box that typing does, so a star tapped and a
  /// word typed stack the same way. Two of them multiply.
  void _toggleTerm(String tag) {
    final text = _query.text;
    final terms = constellationTerms(text);
    final lower = tag.toLowerCase();
    // A half-typed word is replaced by the one that was picked rather than
    // left behind next to it: 오뎅 followed by a tap on 오뎅바 means 오뎅바.
    final typing = text.isEmpty || text.endsWith(' ') ? '' : terms.last;
    final kept = [
      for (final term in terms)
        if (term != lower && term != typing) term,
    ];
    final had = terms.contains(lower);
    setState(() {
      _query.text = had ? kept.join(' ') : [...kept, tag].join(' ');
      _query.selection = TextSelection.collapsed(offset: _query.text.length);
    });
  }

  /// Carries what the sky is lit by back into the grid.
  ///
  /// The two views answer different questions — the constellation shows what
  /// the library is shaped like, the grid gets you to one thing — so the
  /// crossing between them has to be one tap.
  void _openLitInGrid(List<String> tags) {
    if (tags.isEmpty) return;
    setState(() {
      _untaggedOnly = false;
      _selected
        ..clear()
        ..addAll(tags);
      _query.clear();
      _view = LibraryView.grid;
    });
  }

  /// Drops selections that no longer exist, so a rename or a merge made in the
  /// full tag list does not leave this screen filtering on a dead word.
  void _pruneSelection(Set<String> living) {
    _selected.removeWhere((tag) => !living.contains(tag));
  }

  Future<void> _openAllTags() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AllTagsScreen(
          controller: widget.controller,
          selected: List<String>.unmodifiable(_selected),
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
        _pruneSelection({
          for (final item in items)
            for (final tag in item.tags) tag.value,
        });
        final untagged = items.where((item) => item.tags.isEmpty).length;
        final visible = visibleItems(
          items,
          selected: _selected,
          untaggedOnly: _untaggedOnly,
        );
        final offers = offeredTags(visible, selected: _selected);
        final filtered = _untaggedOnly || _selected.isNotEmpty;
        final sky = _view == LibraryView.constellation;
        final terms = constellationTerms(_query.text);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: ShellHeader(
                onOpenMenu: widget.onOpenMenu,
                title: '정리함',
                actions: [
                  _ViewToggle(view: _view, onTap: _switchView),
                  const SizedBox(width: 4),
                  _SavedCount(
                    shown: visible.length,
                    total: items.length,
                    filtered: filtered && !sky,
                  ),
                ],
              ),
            ),
            if (sky)
              _SkySearch(
                controller: _query,
                focusNode: _queryFocus,
                suggestions: _suggestions(items, terms),
                onChanged: (_) => setState(() {}),
                onPick: _toggleTerm,
                onOpenAll: _openAllTags,
              )
            else
              _FilterRow(
                selected: _selected,
                offers: offers,
                untagged: untagged,
                untaggedOnly: _untaggedOnly,
                onToggle: _toggle,
                onToggleUntagged: _toggleUntagged,
                onOpenAll: _openAllTags,
              ),
            Expanded(
              child: sky
                  ? TagConstellation(
                      key: const Key('library-constellation'),
                      items: items,
                      terms: terms,
                      onOpenItem: _open,
                      onToggleTag: _toggleTerm,
                    )
                  : _Grid(
                      items: items,
                      visible: visible,
                      selected: _selected,
                      onOpen: _open,
                      onTagTap: _toggle,
                    ),
            ),
            if (sky && terms.isNotEmpty)
              _FocusBar(
                terms: terms,
                count: items.where((item) => itemAnswers(item, terms)).length,
                onOpen: () => _openLitInGrid(
                  resolveTerms(terms, {
                    for (final item in items)
                      for (final tag in item.tags) tag.value,
                  }),
                ),
              ),
          ],
        );
      },
    );
  }

  void _open(SavedLibraryItem item) {
    openSavedLibraryItem(context, controller: widget.controller, item: item);
  }
}

/// The two ways to look at the same library.
enum LibraryView {
  /// Photographs in a grid. What you open to find one thing.
  grid,

  /// The graph. What you open to see what you have and how it hangs together.
  constellation,
}

/// The saved things, newest first.
final class _Grid extends StatelessWidget {
  const _Grid({
    required this.items,
    required this.visible,
    required this.selected,
    required this.onOpen,
    required this.onTagTap,
  });

  final List<SavedLibraryItem> items;
  final List<SavedLibraryItem> visible;
  final List<String> selected;
  final void Function(SavedLibraryItem item) onOpen;
  final void Function(String tag) onTagTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _Empty();
    if (visible.isEmpty) return const _NoMatch();
    return GridView.builder(
      key: const PageStorageKey('products'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        40 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 4 / 5,
      ),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final item = visible[index];
        return _LibraryCard(
          item: item,
          aspectRatio: 4 / 5,
          titleSize: 16,
          maxTags: 2,
          selected: selected,
          onOpen: () => onOpen(item),
          onTagTap: onTagTap,
        );
      },
    );
  }
}

/// Grid or sky. Two states, one button, no menu.
final class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onTap});

  final LibraryView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sky = view == LibraryView.constellation;
    return Semantics(
      button: true,
      label: sky ? '격자로 보기' : '별자리로 보기',
      child: Material(
        key: const Key('library-view-toggle'),
        color: sky ? AppTheme.primarySoft : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              sky ? Icons.auto_awesome_rounded : Icons.grid_view_rounded,
              size: 19,
              color: sky ? AppTheme.primary : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The one piece of chrome over the sky: a box to type in, a door to the full
/// list of words, and — only while the reader is in the box — a few words to
/// pick from.
///
/// The suggestions are hidden the rest of the time on purpose. Standing them
/// permanently above the sky would put a list of eight back on top of a map of
/// three hundred: it would neither cover the library nor leave the view alone.
final class _SkySearch extends StatelessWidget {
  const _SkySearch({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.onChanged,
    required this.onPick,
    required this.onOpenAll,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> suggestions;
  final ValueChanged<String> onChanged;
  final void Function(String tag) onPick;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('library-sky-search'),
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(color: AppTheme.ink, fontSize: 15),
                  decoration: const InputDecoration(
                    hintText: '태그로 불 켜기 · 띄어 쓰면 겹칩니다',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppTheme.subtle,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                key: const Key('library-sky-all-tags'),
                onPressed: onOpenAll,
                child: const Text(
                  '모든 태그',
                  style: TextStyle(
                    color: AppTheme.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        ListenableBuilder(
          listenable: focusNode,
          builder: (context, _) {
            if (!focusNode.hasFocus || suggestions.isEmpty) {
              return const SizedBox(height: 12);
            }
            return SizedBox(
              height: 50,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                children: [
                  for (final tag in suggestions) ...[
                    Material(
                      key: Key('library-sky-suggestion-$tag'),
                      color: AppTheme.fill,
                      shape: const StadiumBorder(
                        side: BorderSide(color: AppTheme.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onPick(tag),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Center(
                            child: Text(
                              tag,
                              style: const TextStyle(
                                color: AppTheme.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// What one tap on a star turned up, and the door back to the grid.
final class _FocusBar extends StatelessWidget {
  const _FocusBar({
    required this.terms,
    required this.count,
    required this.onOpen,
  });

  final List<String> terms;
  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Material(
        key: const Key('library-focus-bar'),
        color: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${terms.join(' · ')} $count개',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Text(
                  '격자로 보기',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.primary,
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

/// How much is in here, and how much of it the current filter kept.
final class _SavedCount extends StatelessWidget {
  const _SavedCount({
    required this.shown,
    required this.total,
    required this.filtered,
  });

  final int shown;
  final int total;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        filtered ? '$shown / $total' : '$total 저장됨',
        style: TextStyle(
          color: filtered ? AppTheme.primary : AppTheme.muted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The capped row of tags: what is already picked, then what is worth picking
/// next, then the door to all of them.
final class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.offers,
    required this.untagged,
    required this.untaggedOnly,
    required this.onToggle,
    required this.onToggleUntagged,
    required this.onOpenAll,
  });

  final List<String> selected;
  final List<({String name, int count})> offers;
  final int untagged;
  final bool untaggedOnly;
  final void Function(String tag) onToggle;
  final VoidCallback onToggleUntagged;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        children: [
          for (final tag in selected) ...[
            _Chip(
              key: Key('library-filter-$tag'),
              label: tag,
              picked: true,
              onTap: () => onToggle(tag),
            ),
            const SizedBox(width: 8),
          ],
          // Not having a tag is a filter like any other rather than a warning
          // banner of its own: one row, one way of thinking about it.
          if (untagged > 0 && selected.isEmpty) ...[
            _Chip(
              key: const Key('library-filter-untagged'),
              label: '태그 없음',
              count: untagged,
              picked: untaggedOnly,
              caution: true,
              onTap: onToggleUntagged,
            ),
            const SizedBox(width: 8),
          ],
          if (!untaggedOnly)
            for (final offer in offers) ...[
              _Chip(
                key: Key('library-filter-${offer.name}'),
                label: offer.name,
                count: offer.count,
                onTap: () => onToggle(offer.name),
              ),
              const SizedBox(width: 8),
            ],
          _Chip(
            key: const Key('library-all-tags'),
            label: '모든 태그',
            trailing: Icons.chevron_right_rounded,
            onTap: onOpenAll,
          ),
        ],
      ),
    );
  }
}

final class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.onTap,
    this.count,
    this.picked = false,
    this.caution = false,
    this.trailing,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final int? count;
  final bool picked;
  final bool caution;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = caution ? AppTheme.caution : AppTheme.primary;
    // A picked chip is filled with the accent and reads in the near-black
    // behind it, which is the loudest thing on a dark screen and the only way
    // to see at a glance why the grid is shorter than it was.
    final background = picked
        ? accent
        : (caution ? AppTheme.accentSoft : AppTheme.fill);
    final ink = picked ? AppTheme.background : AppTheme.ink;

    return Material(
      color: background,
      shape: StadiumBorder(
        side: BorderSide(
          color: picked
              ? accent
              : (caution
                    ? AppTheme.caution.withValues(alpha: 0.46)
                    : AppTheme.border),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 0, trailing == null ? 14 : 8, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.1,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(
                    color: picked
                        ? AppTheme.background.withValues(alpha: 0.62)
                        : AppTheme.subtle,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (picked) ...[
                const SizedBox(width: 5),
                Icon(Icons.close_rounded, size: 14, color: ink),
              ],
              if (trailing != null)
                Icon(trailing, size: 18, color: AppTheme.subtle),
            ],
          ),
        ),
      ),
    );
  }
}

/// One saved thing, drawn as the screenshot it came from.
///
/// The picture carries the recognition and the type carries the certainty, so
/// the name sits on the image rather than under it and the image is not asked
/// to be decorative.
final class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.item,
    required this.aspectRatio,
    required this.titleSize,
    required this.selected,
    required this.maxTags,
    required this.onOpen,
    required this.onTagTap,
  });

  final SavedLibraryItem item;
  final double aspectRatio;
  final double titleSize;
  final List<String> selected;
  final int maxTags;
  final VoidCallback onOpen;
  final void Function(String tag) onTagTap;

  @override
  Widget build(BuildContext context) {
    // The tags it is filed under, minus the ones that got the reader here.
    // Those are already lit up in the row above.
    final others = [
      for (final tag in item.tags)
        if (!selected.contains(tag.value)) tag.value,
    ];
    final path = item.thumbnailPath;

    return Material(
      key: Key('library-card-${item.id}'),
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          AspectRatio(
            aspectRatio: aspectRatio,
            child: path == null
                ? _TypeGround(item: item)
                : Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    alignment: captureCrop(aspectRatio),
                    errorBuilder: (_, _, _) => _TypeGround(item: item),
                  ),
          ),
          // The name has to read over whatever the photograph happens to be,
          // so the scrim is a real one: nothing at the top, most of the way to
          // solid at the bottom.
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x730B0B0D),
                    Color(0xF20B0B0D),
                  ],
                  stops: [0.38, 0.68, 1],
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.cardTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.ink,
                    fontSize: titleSize,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  // Tappable, so the reader can narrow from what they are
                  // looking at instead of hunting for the same word in a list.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in others.take(maxTags))
                        _CardTag(
                          key: Key('library-card-tag-${item.id}-$tag'),
                          label: tag,
                          onTap: () => onTagTap(tag),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onOpen),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tag as it appears on a card: quiet enough not to fight the name, solid
/// enough to read over a photograph.
final class _CardTag extends StatelessWidget {
  const _CardTag({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.ink.withValues(alpha: 0.14),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.ink,
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// What a card stands on when there is no screenshot behind it.
///
/// The legacy beauty groups predate image capture. A grey box would read as a
/// failure, so this is set as type on purpose: the brand small, the name large,
/// a rule in the app's own green.
final class _TypeGround extends StatelessWidget {
  const _TypeGround({required this.item});

  final SavedLibraryItem item;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(width: 26, height: 2, color: AppTheme.primary),
            const SizedBox(height: 10),
            Expanded(
              child: Text(
                item.subtitle.isEmpty ? '저장한 제품' : item.subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.subtle,
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 40, 20, 40),
      child: Center(
        child: Text(
          '고른 태그가 전부 붙은 건 없어요.',
          style: TextStyle(color: AppTheme.muted, fontSize: 14),
        ),
      ),
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: DecoratedBox(
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
                '콘텐츠를 확인하고 정리하면 여기에 모여요.',
                style: TextStyle(
                  color: AppTheme.muted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
