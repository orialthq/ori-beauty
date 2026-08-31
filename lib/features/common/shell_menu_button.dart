import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// The top row every screen wears: the way out on the left, the screen's name
/// in the middle, whatever it offers on the right.
///
/// The tab bar used to say where a reader was, and every screen could spend a
/// heading on its own name. With the bar gone the name belongs up here, small,
/// where it sits in the same place on every screen and costs no room.
final class ShellHeader extends StatelessWidget {
  const ShellHeader({
    required this.onOpenMenu,
    this.title,
    this.actions = const <Widget>[],
    this.ink,
    super.key,
  });

  /// Opens the drawer. Null where there is no drawer to open, which is how a
  /// screen is pumped on its own in tests.
  final VoidCallback? onOpenMenu;

  /// The screen's name. Null on home, which says what it is in the middle of
  /// the screen instead.
  final String? title;

  final List<Widget> actions;

  /// For the plan screens, which paint from their own token names.
  final Color? ink;

  static const height = 56.0;

  @override
  Widget build(BuildContext context) {
    final tint = ink ?? AppTheme.ink;
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const Key('shell-menu-button'),
              tooltip: '메뉴',
              onPressed: onOpenMenu,
              style: IconButton.styleFrom(foregroundColor: tint),
              icon: const Icon(Icons.menu_rounded),
            ),
          ),
          if (title case final title?)
            Align(
              // Centred on the row rather than laid out between the two sides,
              // so it stays put whatever the screen keeps on its right.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 104),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tint,
                    fontSize: 17,
                    height: 1.2,
                    letterSpacing: -0.3,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ],
      ),
    );
  }
}
