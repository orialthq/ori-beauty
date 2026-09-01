import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../common/shell_menu_button.dart';
import '../../state/app_controller.dart';

/// What other people sent, waiting to be decided on.
///
/// Its reason for existing is the line at the top: a received thing does not
/// join 정리함 by arriving. Before this screen there was nowhere for one to
/// wait — a sheet opened over whatever the reader was doing, and dismissing it
/// threw the thing away.
final class SharedInboxScreen extends StatelessWidget {
  const SharedInboxScreen({
    required this.entries,
    required this.onOpen,
    this.onOpenMenu,
    super.key,
  });

  final List<SharedTipEntry> entries;
  final ValueChanged<SharedTipEntry> onOpen;

  /// Opens the drawer. Every screen carries this now that the tab bar is gone.
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.background,
      child: SafeArea(
        bottom: false,
        child: ListView(
          key: const PageStorageKey('shared-inbox'),
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 44),
          children: [
            ShellHeader(onOpenMenu: onOpenMenu, title: '공유함'),
            const SizedBox(height: 14),
            const _Explainer(),
            const SizedBox(height: 20),
            if (entries.isEmpty)
              const _Empty()
            else
              for (final entry in entries) ...[
                _SharedCard(entry: entry, onTap: () => onOpen(entry)),
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

final class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '받은 건 정리함에 바로 섞이지 않아요. 여기서 '),
              TextSpan(
                text: '고른 것만',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(text: ' 내 쪽으로 분류됩니다.'),
            ],
          ),
          style: TextStyle(
            color: AppTheme.muted,
            fontSize: 14,
            height: 1.55,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

final class _SharedCard extends StatelessWidget {
  const _SharedCard({required this.entry, required this.onTap});

  final SharedTipEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tip = entry.tip;
    final tags = tip.tags;
    final filedAs = tags.isEmpty ? '태그 없음' : tags.join(' · ');
    return Material(
      key: Key('shared-tip-${entry.transportId}'),
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: '${tip.title}, $filedAs, ${_ago(tip.exportedAt)}',
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // The sender's name would sit here, and cannot yet: a
                      // package carries no idea of who sent it.
                      Expanded(
                        child: Text(
                          '$filedAs · ${_ago(tip.exportedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.muted,
                            fontSize: 13.5,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tip.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 22,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                  if (tip.summary.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      tip.summary.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.subtle,
                        fontSize: 13.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                  if (tip.message case final message?
                      when message.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '“${message.trim()}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 13,
                        height: 1.4,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Rounded down to the day. The exact minute someone exported a tip is not
  /// something anyone reads a list for.
  static String _ago(DateTime value) {
    final now = DateTime.now();
    final days = DateUtils.dateOnly(
      now,
    ).difference(DateUtils.dateOnly(value)).inDays;
    return switch (days) {
      <= 0 => '오늘',
      1 => '어제',
      < 7 => '$days일 전',
      < 30 => '${days ~/ 7}주 전',
      _ => '${value.month}월 ${value.day}일',
    };
  }
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(18, 22, 18, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '아직 받은 게 없어요',
              style: TextStyle(
                color: AppTheme.ink,
                fontSize: 16,
                height: 1.35,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '누군가 Trun On에서 정리한 걸 보내면 여기에 쌓여요.',
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
