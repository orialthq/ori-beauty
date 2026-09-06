import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../data/place_reminder_service.dart';
import '../features/home/home_shell.dart';
import '../state/app_controller.dart';
import '../state/plan_controller.dart';

final class OriBeautyApp extends StatelessWidget {
  const OriBeautyApp({
    required this.controller,
    this.planController,
    this.placeReminderOpenInbox,
    super.key,
  });

  final AppController controller;
  final PlanController? planController;
  final PlaceReminderOpenInbox? placeReminderOpenInbox;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'luffi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: AppTheme.background,
          systemNavigationBarDividerColor: AppTheme.background,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarContrastEnforced: false,
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomeShell(
        controller: controller,
        planController: planController,
        placeReminderOpenInbox: placeReminderOpenInbox,
      ),
    );
  }
}
