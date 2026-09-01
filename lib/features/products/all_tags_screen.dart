import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_controller.dart';
import '../common/tag_ui.dart';

/// The nineteen Hangul leading consonants, with the tensed ones folded into
/// the plain one they are written from. A reader looking for 빵 looks under ㅂ.
const _leadingConsonants = [
  'ㄱ', 'ㄱ', 'ㄴ', 'ㄷ', 'ㄷ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅂ', 'ㅅ', //
  'ㅅ', 'ㅇ', 'ㅈ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

/// Which section a tag files under.
///
/// Hangul syllables are composed, so the letter a reader would look under has
/// to be computed out of the code point rather than read off the front of the
/// string.
String tagSectionOf(String value) {
  if (value.isEmpty) return '#';
  final code = value.runes.first;
  if (code >= 0xAC00 && code <= 0xD7A3) {
    return _leadingConsonants[(code - 0xAC00) ~/ (21 * 28)];
  }
  final upper = value[0].toUpperCase();
  return RegExp(r'^[A-Z]$').hasMatch(upper) ? upper : '#';
}

/// Every tag in the library, and the place to put two of them together.
///
/// The long tail lives here rather than on 정리함, which is the whole point of
/// capping the row there: a list of hundreds is a real thing that needs a real
/// screen, and that screen is not the one you open to look at what you saved.
///
/// Renaming is the reader's half of the deduplication problem. The analysis
/// will keep producing 멕시코 음식 and 멕시코음식 until something merges them,
/// and until an automatic pass can judge that, the person who saved both can.
final class AllTagsScreen extends StatefulWidget {
  const AllTagsScreen({
    required this.controller,
    this.selected = const [],
    super.key,
  });

  final AppController controller;

  /// What 정리함 is currently filtering by, marked so the reader can see it.
  final List<String> selected;

  @override
  State<AllTagsScreen> createState() => _AllTagsScreenState();
}

class _AllTagsScreenState extends State<AllTagsScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _rename(String from, int count) async {
    final typed = await showTagNameDialog(
      context,
      title: '태그 고치기',
      initial: from,
    );
    if (typed == null || typed == from || !mounted) return;

    // Landing on a name that already exists is a merge, not a mistake. Say so
    // with the number it will become, because that number is the only way to
    // tell a merge from a rename before it happens.
    final existing = widget.controller.tagCounts
        .where((entry) => entry.tag.value == typed)
        .firstOrNull;
    if (existing != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('tag-merge-dialog'),
          backgroundColor: AppTheme.surfaceRaised,
          title: const Text('태그 합치기'),
          content: Text(
            '$from $count개가 $typed에 합쳐져요.\n'
            '합치면 $typed 하나로 ${existing.count + count}개가 됩니다.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            TextButton(
              key: const Key('tag-merge-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('합치기'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await widget.controller.renameTag(from, typed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('모든 태그'),
      ),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final query = _query.text.trim().toLowerCase();
          final counts = widget.controller.tagCounts
              .where(
                (entry) =>
                    query.isEmpty ||
                    entry.tag.value.toLowerCase().contains(query),
              )
              .toList(growable: false);
          // Alphabetical here, not by count. 정리함 answers "what do I use
          // most"; this screen answers "where is the word", and for that the
          // only useful order is the one a reader can predict.
          final sorted = counts.toList()
            ..sort((a, b) => a.tag.value.compareTo(b.tag.value));

          final rows = <Widget>[];
          String? section;
          for (final entry in sorted) {
            final letter = tagSectionOf(entry.tag.value);
            if (letter != section) {
              section = letter;
              rows.add(_SectionHeader(letter: letter));
            }
            rows.add(
              _TagRow(
                name: entry.tag.value,
                count: entry.count,
                active: widget.selected.contains(entry.tag.value),
                onRename: () => _rename(entry.tag.value, entry.count),
              ),
            );
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: TextField(
                  key: const Key('tag-search-field'),
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(color: AppTheme.ink, fontSize: 15),
                  decoration: InputDecoration(
                    hintText: '태그 이름으로 찾기',
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: AppTheme.subtle,
                      size: 20,
                    ),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('tag-search-clear'),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: AppTheme.subtle,
                              size: 18,
                            ),
                            onPressed: () {
                              _query.clear();
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const Center(
                        child: Text(
                          '그런 이름의 태그는 없어요.',
                          style: TextStyle(color: AppTheme.muted, fontSize: 14),
                        ),
                      )
                    : ListView(
                        key: const PageStorageKey('all-tags'),
                        padding: EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          32 + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        children: rows,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        letter,
        style: const TextStyle(
          color: AppTheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

final class _TagRow extends StatelessWidget {
  const _TagRow({
    required this.name,
    required this.count,
    required this.active,
    required this.onRename,
  });

  final String name;
  final int count;
  final bool active;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('all-tags-row-$name'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? AppTheme.primary : AppTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.subtle,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            key: Key('all-tags-rename-$name'),
            onPressed: onRename,
            icon: const Icon(
              Icons.edit_outlined,
              size: 17,
              color: AppTheme.muted,
            ),
            tooltip: '$name 이름 고치기',
          ),
        ],
      ),
    );
  }
}
