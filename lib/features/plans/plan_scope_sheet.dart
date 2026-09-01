import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'plan_editor_screen.dart';

/// What the reader settled on in the scope sheet.
///
/// Wrapped rather than returning a bare list, because "search everywhere" and
/// "the reader dismissed the sheet" are different answers and both would come
/// back as an empty list otherwise.
final class PlanScopeChoice {
  const PlanScopeChoice(this.scopes);

  final List<String> scopes;
}

/// Picks the tags a plan searches under.
///
/// One flat list, most used first, because that is the shape the library has:
/// there is no parent to open and no child to find inside it. The count beside
/// each name is what tells a reader which of two similar words their things
/// actually went under.
Future<PlanScopeChoice?> showPlanScopeSheet(
  BuildContext context, {
  required List<PlanSourceOption> sources,
  required List<String> selected,
}) {
  return showModalBottomSheet<PlanScopeChoice>(
    context: context,
    backgroundColor: AppTheme.planSurface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PlanScopeSheet(sources: sources, selected: selected),
  );
}

final class _PlanScopeSheet extends StatefulWidget {
  const _PlanScopeSheet({required this.sources, required this.selected});

  final List<PlanSourceOption> sources;
  final List<String> selected;

  @override
  State<_PlanScopeSheet> createState() => _PlanScopeSheetState();
}

final class _PlanScopeSheetState extends State<_PlanScopeSheet> {
  late var _scopes = widget.selected;

  /// How many saved things the current picks cover between them.
  int get _count =>
      widget.sources.where((one) => planScopeMatches(_scopes, one.tags)).length;

  /// Every tag in the library with something under it, most used first. Ties
  /// fall back to the name so the list does not shuffle.
  List<({String name, int count})> get _tags {
    final counts = <String, int>{};
    for (final source in widget.sources) {
      for (final tag in source.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final names = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return [for (final name in names) (name: name, count: counts[name]!)];
  }

  void _toggle(String tag) {
    setState(() {
      _scopes = _scopes.contains(tag)
          ? <String>[
              for (final one in _scopes)
                if (one != tag) one,
            ]
          : <String>[..._scopes, tag];
    });
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '어디서 찾을까요?',
              style: TextStyle(
                color: AppTheme.planInk,
                fontSize: 20,
                height: 1.3,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _scopes.isEmpty
                  ? '고르지 않으면 저장한 것 전부에서 찾아요.'
                  : '고른 태그 중 하나라도 붙은 것 $_count개에서 찾아요.',
              style: const TextStyle(
                color: AppTheme.planMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  '아직 태그가 붙은 게 없어요.',
                  style: TextStyle(color: AppTheme.planSubtle, fontSize: 14),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: tags.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) => _Choice(
                    label: tags[index].name,
                    count: tags[index].count,
                    selected: _scopes.contains(tags[index].name),
                    onTap: () => _toggle(tags[index].name),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            // Picking does not close the sheet, so there has to be a way out
            // that means "done" rather than "cancel".
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('plan-scope-done'),
                onPressed: () =>
                    Navigator.pop(context, PlanScopeChoice(_scopes)),
                child: const Text('선택 완료'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('plan-scope-tag-$label'),
      color: selected ? AppTheme.planMauveSoft : AppTheme.fill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? AppTheme.planMauve : AppTheme.planBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          selected: selected,
          label: '$label, 저장한 것 $count개',
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 19,
                      color: selected
                          ? AppTheme.planMauve
                          : AppTheme.planSubtle,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? AppTheme.planMauve
                              : AppTheme.planInk,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '$count',
                      style: const TextStyle(
                        color: AppTheme.planSubtle,
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
      ),
    );
  }
}

/// The row on the editor that says what the plan will search.
final class PlanScopeField extends StatelessWidget {
  const PlanScopeField({
    required this.scopes,
    required this.count,
    required this.onTap,
    super.key,
  });

  final List<String> scopes;
  final int count;
  final VoidCallback onTap;

  /// One tag is named outright; several by the first and a count.
  String get _label {
    if (scopes.isEmpty) return '어디서든';
    return scopes.length == 1
        ? scopes.single
        : '${scopes.first} 외 ${scopes.length - 1}개';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.planSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.planBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: '찾을 범위 $_label, 저장한 것 $count개',
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 66),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.sell_outlined,
                      size: 20,
                      color: AppTheme.planMuted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.planInk,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '저장한 것 $count개',
                            style: const TextStyle(
                              color: AppTheme.planSubtle,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.planSubtle,
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
