import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../domain/models.dart';

/// One tag, as a chip.
///
/// No colour of its own. Tags are unbounded, so a palette would either repeat
/// or be computed from the name, and a colour that means nothing is worse than
/// none. What a chip does say is where the tag came from: a web finding is
/// marked, because it was never on the screenshot.
final class TagChip extends StatelessWidget {
  const TagChip({
    required this.tag,
    this.onTap,
    this.onRemove,
    this.selected = false,
    super.key,
  });

  final ContentTag tag;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? AppTheme.primary : AppTheme.ink;
    final label = Padding(
      padding: EdgeInsets.fromLTRB(13, 0, onRemove == null ? 13 : 7, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tag.source == TagSource.web) ...[
            const Icon(Icons.public_rounded, size: 13, color: AppTheme.subtle),
            const SizedBox(width: 5),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              tag.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink,
                fontSize: 13,
                height: 1.3,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    return Material(
      key: Key('tag-chip-${tag.value}'),
      color: selected ? AppTheme.primarySoft : AppTheme.fill,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTap == null)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Center(child: label),
            )
          else
            InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 34),
                child: Center(child: label),
              ),
            ),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              child: Semantics(
                button: true,
                label: '${tag.value} 태그 빼기',
                child: const SizedBox(
                  width: 28,
                  height: 34,
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: AppTheme.subtle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A capture's tags, and the way to change them.
///
/// Adding and removing rather than picking from a list: there is no list to
/// pick from. Whatever the reader types becomes a tag, and the same name typed
/// twice is the same tag.
final class TagEditor extends StatelessWidget {
  const TagEditor({
    required this.tags,
    required this.onChanged,
    this.emptyLabel = '아직 태그가 없어요',
    super.key,
  });

  final List<ContentTag> tags;
  final ValueChanged<List<ContentTag>> onChanged;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              emptyLabel,
              style: const TextStyle(
                color: AppTheme.subtle,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in tags)
              TagChip(
                tag: tag,
                onTap: () => _rename(context, tag),
                onRemove: () => onChanged([
                  for (final kept in tags)
                    if (kept.value != tag.value) kept,
                ]),
              ),
            _AddTagChip(onTap: () => _add(context)),
          ],
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final typed = await showTagNameDialog(context, title: '태그 달기');
    if (typed == null) return;
    if (tags.any((tag) => tag.value == typed)) return;
    onChanged([...tags, ContentTag(value: typed, source: TagSource.user)]);
  }

  Future<void> _rename(BuildContext context, ContentTag tag) async {
    final typed = await showTagNameDialog(
      context,
      title: '태그 고치기',
      initial: tag.value,
    );
    if (typed == null || typed == tag.value) return;
    onChanged(
      dedupedTags([
        for (final kept in tags)
          if (kept.value == tag.value)
            ContentTag(
              value: typed,
              // The reader named it, whoever suggested it first.
              source: TagSource.user,
              confidence: kept.confidence,
              evidenceIds: kept.evidenceIds,
              quotes: kept.quotes,
              citations: kept.citations,
            )
          else
            kept,
      ]),
    );
  }
}

final class _AddTagChip extends StatelessWidget {
  const _AddTagChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '태그 달기',
      child: Material(
        key: const Key('tag-add'),
        color: Colors.transparent,
        shape: const StadiumBorder(side: BorderSide(color: AppTheme.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            height: 34,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 15, color: AppTheme.muted),
                  SizedBox(width: 5),
                  Text(
                    '태그',
                    style: TextStyle(
                      color: AppTheme.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
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

/// Types a tag name, and refuses one the library could not use.
///
/// The rules are the ones the subcategory carried before it: two to twenty
/// characters, letters and digits with a few separators. Long enough to mean
/// something, short enough to sit on a chip.
Future<String?> showTagNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TagNameDialog(title: title, initial: initial),
  );
}

final class _TagNameDialog extends StatefulWidget {
  const _TagNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_TagNameDialog> createState() => _TagNameDialogState();
}

final class _TagNameDialogState extends State<_TagNameDialog> {
  late final _field = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _confirm() {
    final normalized = normalizeTagName(_field.text);
    if (!isValidTagName(normalized) || _field.text.trim().isEmpty) {
      setState(() => _error = '2~20자로 짧게 적어 주세요.');
      return;
    }
    Navigator.pop(context, normalized);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      title: Text(widget.title),
      content: TextField(
        key: const Key('tag-name-field'),
        controller: _field,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: '예: 스킨케어, 을지로, 웨이팅',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('확인')),
      ],
    );
  }
}
