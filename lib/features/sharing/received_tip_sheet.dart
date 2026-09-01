import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../domain/portable_tip_package.dart';

enum ReceivedTipDecision { save, discard }

Future<ReceivedTipDecision> showReceivedTipSheet(
  BuildContext context,
  PortableTipPackage tip,
) async {
  return await showModalBottomSheet<ReceivedTipDecision>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        useSafeArea: true,
        builder: (_) => _ReceivedTipSheet(tip: tip),
      ) ??
      ReceivedTipDecision.discard;
}

final class _ReceivedTipSheet extends StatelessWidget {
  const _ReceivedTipSheet({required this.tip});

  final PortableTipPackage tip;

  @override
  Widget build(BuildContext context) {
    final sections = tip.sections;
    final placeText = [
      tip.place?.name,
      tip.place?.address,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          6,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.primarySoft,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.redeem_rounded,
                    color: AppTheme.primary,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '받은 팁',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tip.tags.isEmpty ? '태그 없음' : tip.tags.join(' · '),
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (tip.message case final message?) ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                decoration: BoxDecoration(
                  color: AppTheme.primarySoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '“$message”',
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 15,
                    height: 1.45,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text(tip.title, style: Theme.of(context).textTheme.headlineMedium),
            if (tip.summary.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                tip.summary,
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
            if (placeText.isNotEmpty) ...[
              const SizedBox(height: 16),
              _PreviewRow(
                icon: Icons.location_on_outlined,
                label: '장소',
                value: placeText,
              ),
            ],
            if (tip.source case final source?) ...[
              const SizedBox(height: 12),
              _PreviewRow(
                icon: Icons.link_rounded,
                label: source.label ?? '원문',
                value: source.url,
              ),
            ],
            if (sections.isNotEmpty) ...[
              const SizedBox(height: 18),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppTheme.surfaceRaised,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    for (
                      var sectionIndex = 0;
                      sectionIndex < sections.length;
                      sectionIndex++
                    ) ...[
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sections[sectionIndex].title,
                              style: const TextStyle(
                                color: AppTheme.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (final item in sections[sectionIndex].items)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(top: 7),
                                      child: Icon(
                                        Icons.circle,
                                        size: 4,
                                        color: AppTheme.subtle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        item,
                                        style: const TextStyle(
                                          color: AppTheme.ink,
                                          fontSize: 14,
                                          height: 1.42,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (sectionIndex != sections.length - 1)
                        const Divider(indent: 16, endIndent: 16),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.pop(context, ReceivedTipDecision.save),
                icon: const Icon(Icons.bookmark_add_rounded),
                label: const Text('정리함에 저장'),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () =>
                    Navigator.pop(context, ReceivedTipDecision.discard),
                child: const Text('받지 않기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.primary, size: 19),
        const SizedBox(width: 9),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label  ',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                TextSpan(text: value),
              ],
            ),
            style: const TextStyle(
              color: AppTheme.ink,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
