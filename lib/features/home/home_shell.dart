import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../data/external_app_navigation_service.dart';
import '../../data/incoming_share_service.dart';
import '../../data/place_reminder_service.dart';
import '../../data/plan_recommendation_service.dart';
import '../../data/recommendation_candidates.dart';
import '../../data/trigger_plan_store.dart';
import '../../domain/models.dart';
import '../../domain/trigger_models.dart';
import '../../state/app_controller.dart';
import '../../state/plan_controller.dart';
import '../analysis/analysis_review_screen.dart';
import '../analysis/structured_review_screen.dart';
import '../inbox/inbox_screen.dart';
import '../plans/past_plans_screen.dart';
import '../plans/plan_detail_screen.dart';
import '../plans/plan_editor_screen.dart';
import '../plans/plan_suggestion_screen.dart';
import '../plans/plans_screen.dart';
import '../product/product_detail_screen.dart';
import '../products/products_screen.dart';
import '../sharing/received_tip_sheet.dart';
import '../sharing/shared_inbox_screen.dart';
import 'trun_home_screen.dart';

final class HomeShell extends StatefulWidget {
  const HomeShell({
    required this.controller,
    this.planController,
    this.placeReminderOpenInbox,
    super.key,
  });

  final AppController controller;
  final PlanController? planController;
  final PlaceReminderOpenInbox? placeReminderOpenInbox;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

final class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver {
  static const _exitConfirmationWindow = Duration(seconds: 2);

  var _tab = _HomeTab.home;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  IncomingCaptureBatch? _incomingCaptureBatch;
  var _exitArmed = false;
  var _canReturnToSourceApp = false;
  var _returningToSourceApp = false;
  var _planOpenInFlight = false;
  var _developmentDataActionInFlight = false;
  Timer? _exitConfirmationTimer;
  late StreamSubscription<IncomingCaptureBatch> _incomingCaptureSubscription;
  late StreamSubscription<String> _portableTipSubscription;
  late StreamSubscription<String> _placeReminderOpenSubscription;
  late final PlaceReminderOpenInbox _placeReminderOpenInbox;
  late final bool _ownsPlaceReminderOpenInbox;
  final Set<String> _activePlaceReminderOpenIds = {};
  Future<void> _sourceChoiceTail = Future<void>.value();
  Future<void> _portableTipChoiceTail = Future<void>.value();
  Future<void> _placeReminderOpenTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsPlaceReminderOpenInbox = widget.placeReminderOpenInbox == null;
    _placeReminderOpenInbox =
        widget.placeReminderOpenInbox ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? MethodChannelPlaceReminderOpenInbox()
            : InMemoryPlaceReminderOpenInbox());
    _listenForIncomingCaptures();
    _listenForPortableTips();
    _placeReminderOpenSubscription = _placeReminderOpenInbox.opened.listen(
      _queuePlaceReminderOpen,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_drainPendingPlaceReminderOpens());
    });
    widget.planController?.addListener(_handlePlanControllerChanged);
    if (widget.planController != null) {
      unawaited(_initializePlans());
    }
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_incomingCaptureSubscription.cancel());
      unawaited(_portableTipSubscription.cancel());
      _listenForIncomingCaptures();
      _listenForPortableTips();
    }
    if (oldWidget.planController != widget.planController) {
      oldWidget.planController?.removeListener(_handlePlanControllerChanged);
      widget.planController?.addListener(_handlePlanControllerChanged);
      if (widget.planController != null) {
        unawaited(_initializePlans());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final controller = widget.planController;
    if (controller == null) return;
    if (controller.isInitialized) {
      unawaited(controller.refreshScheduling());
    } else {
      unawaited(_initializePlans());
    }
  }

  Future<void> _initializePlans() async {
    final controller = widget.planController;
    if (controller == null) return;
    try {
      await controller.initialize();
      if (!mounted || controller != widget.planController) return;
      setState(() {});
      _queuePendingPlanOpen();
    } catch (error, stackTrace) {
      debugPrint('Plan initialization failed: $error\n$stackTrace');
      if (mounted) _showMessage('계획을 불러오지 못했어요.');
    }
  }

  void _handlePlanControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _queuePendingPlanOpen();
  }

  void _queuePendingPlanOpen() {
    final controller = widget.planController;
    if (controller?.pendingOpen == null || _planOpenInFlight) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_routePendingPlanOpen());
    });
  }

  Future<void> _routePendingPlanOpen() async {
    final planController = widget.planController;
    if (planController == null ||
        planController.pendingOpen == null ||
        _planOpenInFlight) {
      return;
    }
    _planOpenInFlight = true;
    try {
      await widget.controller.initialize();
      if (!mounted || planController != widget.planController) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final pendingOpen = planController.pendingOpen!;
      final planId = pendingOpen.ruleId;
      final captureId = planController.pendingSourceCaptureId;
      planController.consumePendingOpen();
      Navigator.of(context).popUntil((route) => route.isFirst);
      _exitConfirmationTimer?.cancel();
      final capture = captureId == null
          ? null
          : widget.controller.captureById(captureId);
      setState(() {
        _tab = capture == null ? _HomeTab.plans : _HomeTab.library;
        _exitArmed = false;
        _canReturnToSourceApp = false;
      });
      if (capture != null) {
        _openCapture(
          capture,
          planContext: _PlanCaptureOpenContext(
            planId: planId,
            origin: _PlanCaptureOpenOrigin.notification,
            nativeOpenEventId: pendingOpen.eventId,
          ),
        );
      } else if (captureId != null) {
        _showMessage('연결된 콘텐츠가 없어 계획함으로 이동했어요.');
      }
    } finally {
      _planOpenInFlight = false;
      _queuePendingPlanOpen();
    }
  }

  /// An arrival lands in 공유함 rather than in a sheet over whatever the reader
  /// was doing.
  ///
  /// Deciding on the spot was the only option while nothing held a received tip;
  /// dismissing the sheet lost it. Now it waits, which is what the tab is for.
  void _listenForPortableTips() {
    _portableTipSubscription = widget.controller.portableTipReceived.listen((
      _,
    ) {
      if (!mounted) return;
      setState(() {
        _tab = _HomeTab.shared;
        _exitArmed = false;
        _canReturnToSourceApp = true;
        _returningToSourceApp = false;
      });
      _exitConfirmationTimer?.cancel();
      Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  Future<void> _drainPendingPlaceReminderOpens() async {
    final captureIds = await _placeReminderOpenInbox.pending();
    for (final captureId in captureIds) {
      _queuePlaceReminderOpen(captureId);
    }
  }

  void _queuePlaceReminderOpen(String captureId) {
    final normalized = captureId.trim();
    if (normalized.isEmpty || !_activePlaceReminderOpenIds.add(normalized)) {
      return;
    }
    _placeReminderOpenTail = _placeReminderOpenTail
        .then((_) => _routePlaceReminderOpen(normalized))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Place reminder navigation failed: $error\n$stackTrace');
        })
        .whenComplete(() => _activePlaceReminderOpenIds.remove(normalized));
  }

  Future<void> _routePlaceReminderOpen(String captureId) async {
    // initialize() is shared, so this waits for durable snapshot restoration
    // even when the notification cold-started the app before the first frame.
    await widget.controller.initialize();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    Navigator.of(context).popUntil((route) => route.isFirst);
    final capture = widget.controller.captureById(captureId);
    setState(() {
      _tab = _HomeTab.library;
      _exitArmed = false;
      _canReturnToSourceApp = false;
    });
    _exitConfirmationTimer?.cancel();

    if (capture == null) {
      _showMessage('이미 삭제된 콘텐츠예요. 정리함으로 이동했어요.');
    } else {
      _openCapture(capture);
    }
    await _placeReminderOpenInbox.acknowledge([captureId]);
  }

  /// The 콘텐츠 list, pushed rather than switched to.
  ///
  /// It stopped being a tab; this is the door home opens for it.
  void _openContentList() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('콘텐츠')),
          body: InboxScreen(controller: widget.controller),
        ),
      ),
    );
  }

  void _openSharedTip(SharedTipEntry entry) {
    _portableTipChoiceTail = _portableTipChoiceTail.then(
      (_) => _showPortableTip(entry.transportId),
    );
  }

  Future<void> _showPortableTip(String transportId) async {
    if (!mounted) return;
    final tip = widget.controller.pendingPortableTip(transportId);
    if (tip == null) return;
    final decision = await showReceivedTipSheet(context, tip);
    if (!mounted) return;
    if (decision == ReceivedTipDecision.discard) {
      await widget.controller.discardPortableTip(transportId);
      if (mounted) _showMessage('받은 팁을 저장하지 않았어요.');
      return;
    }
    final captureId = await widget.controller.acceptPortableTip(transportId);
    if (!mounted) return;
    if (captureId == null) {
      _showMessage('팁을 저장하지 못했어요. 다시 시도해 주세요.');
      return;
    }
    final capture = widget.controller.captureById(captureId);
    if (capture == null) return;
    setState(() {
      _tab = _HomeTab.library;
      _canReturnToSourceApp = true;
      _exitArmed = false;
    });
    _openCapture(capture);
  }

  void _listenForIncomingCaptures() {
    _incomingCaptureSubscription = widget.controller.incomingCaptureAdded
        .listen((batch) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            setState(() {
              // 콘텐츠 is no longer a tab. Home is where a just-arrived
              // capture is announced, and its top action opens the list.
              _tab = _HomeTab.home;
              _incomingCaptureBatch = batch;
              _exitArmed = false;
              _canReturnToSourceApp = true;
              _returningToSourceApp = false;
            });
            _exitConfirmationTimer?.cancel();
            Navigator.of(context).popUntil((route) => route.isFirst);
            // External image shares can each own a deletable gallery source.
            // Keep those decisions item-by-item even though navigation and the
            // arrival banner are deliberately coalesced for this transaction.
            for (final captureId in batch.captureIds) {
              if (widget.controller.canDeleteSharedSource(captureId)) {
                _sourceChoiceTail = _sourceChoiceTail.then(
                  (_) => _showSourceChoice(captureId),
                );
              }
            }
          });
        });
  }

  Future<void> _showSourceChoice(String captureId) async {
    if (!mounted || !widget.controller.canDeleteSharedSource(captureId)) {
      return;
    }
    final shouldDelete = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => const _SourceImageChoiceSheet(),
    );
    if (!mounted) return;

    if (shouldDelete != true) {
      await widget.controller.keepSharedSource(captureId);
      if (mounted) _showMessage('갤러리 원본을 그대로 두었어요.');
      return;
    }
    final result = await widget.controller.deleteSharedSource(captureId);
    if (!mounted) return;
    _showMessage(switch (result) {
      SharedSourceDeletionResult.deleted => '갤러리 원본을 삭제했어요.',
      SharedSourceDeletionResult.kept => '갤러리 원본을 그대로 두었어요.',
      SharedSourceDeletionResult.unavailable =>
        '이 이미지의 원본은 Trun On에서 삭제할 수 없어요.',
      SharedSourceDeletionResult.failed => '갤러리 원본을 삭제하지 못했어요.',
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _shareDevelopmentBackup() async {
    if (_developmentDataActionInFlight) return;
    _developmentDataActionInFlight = true;
    try {
      _showMessage('백업 ZIP을 준비하고 있어요.');
      await widget.controller.shareDevelopmentBackup();
    } catch (error, stackTrace) {
      debugPrint('Development backup failed: $error\n$stackTrace');
      if (mounted) _showMessage('백업 파일을 만들지 못했어요. 다시 시도해 주세요.');
    } finally {
      _developmentDataActionInFlight = false;
    }
  }

  Future<void> _confirmAndClearUserCaptures() async {
    if (_developmentDataActionInFlight) return;
    final count = widget.controller.userCaptureCount;
    if (count == 0) {
      _showMessage('삭제할 가져온 콘텐츠가 없어요.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('가져온 콘텐츠를 모두 삭제할까요?'),
        content: Text(
          '데모를 제외한 콘텐츠 $count개와 Trun On이 보관한 이미지 사본이 '
          '삭제돼요. 갤러리 원본과 계획함의 계획은 그대로 남아요. '
          '되돌릴 수 없으니 필요하면 먼저 백업 ZIP을 '
          '내보내 주세요. 현재 앱에서는 ZIP을 바로 복원하는 '
          '기능은 제공하지 않아요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          TextButton(
            key: const Key('confirm-clear-user-captures'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.planNegative),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _developmentDataActionInFlight = true;
    try {
      final cleared = await widget.controller.clearAllUserCaptures();
      if (!mounted) return;
      if (!cleared) {
        _showMessage('정리하지 못해 콘텐츠나 원본을 건드리지 않았어요.');
        return;
      }
      setState(() => _incomingCaptureBatch = null);
      _showMessage('가져온 콘텐츠 $count개를 삭제했어요. 계획은 그대로예요.');
    } finally {
      _developmentDataActionInFlight = false;
    }
  }

  bool get _handlesSystemBack =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The tabs on show, in order.
  ///
  /// 계획함 only exists when a plan controller was handed in, so a position in
  /// this list is not a fixed number. Everything addresses tabs by name and
  /// converts here, which is what stopped a reordering from silently sending
  /// notifications to the wrong screen.
  List<_HomeTab> get _tabs => <_HomeTab>[
    _HomeTab.home,
    _HomeTab.shared,
    _HomeTab.library,
    if (widget.planController != null) _HomeTab.plans,
  ];

  int get _selectedIndex {
    final index = _tabs.indexOf(_tab);
    return index < 0 ? 0 : index;
  }

  void _selectTab(_HomeTab tab) => _selectDestination(_tabs.indexOf(tab));

  void _selectDestination(int index) {
    if (index < 0 || index >= _tabs.length) return;
    if (_selectedIndex == index) {
      if (_exitArmed) {
        _exitConfirmationTimer?.cancel();
        setState(() => _exitArmed = false);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      return;
    }
    setState(() {
      _tab = _tabs[index];
      _exitArmed = false;
    });
    _exitConfirmationTimer?.cancel();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  Future<void> _handleSystemBack() async {
    if (_tab != _HomeTab.home) {
      _exitConfirmationTimer?.cancel();
      setState(() {
        _tab = _HomeTab.home;
        _exitArmed = false;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      return;
    }

    if (_canReturnToSourceApp) {
      if (_returningToSourceApp) return;
      setState(() => _returningToSourceApp = true);
      final returned = await const ExternalAppNavigationService()
          .returnToPreviousApp();
      if (!mounted) return;
      setState(() {
        _canReturnToSourceApp = false;
        _returningToSourceApp = false;
      });
      if (returned) return;
    }

    _exitConfirmationTimer?.cancel();
    setState(() => _exitArmed = true);
    _exitConfirmationTimer = Timer(_exitConfirmationWindow, () {
      if (mounted) {
        setState(() => _exitArmed = false);
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('한 번 더 누르면 앱을 종료해요.'),
          duration: _exitConfirmationWindow,
        ),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.planController?.removeListener(_handlePlanControllerChanged);
    _exitConfirmationTimer?.cancel();
    unawaited(_incomingCaptureSubscription.cancel());
    unawaited(_portableTipSubscription.cancel());
    unawaited(_placeReminderOpenSubscription.cancel());
    if (_ownsPlaceReminderOpenInbox) {
      unawaited(_placeReminderOpenInbox.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final planController = widget.planController;
    final sharedCount = widget.controller.sharedInbox.length;
    // 콘텐츠 is not here any more. It is the workshop — raw captures and their
    // processing state — and home already leads with the one action it exists
    // for. A tab it barely earned went to 공유함, which has nowhere else to be.
    final screens = <Widget>[
      for (final tab in _tabs)
        switch (tab) {
          _HomeTab.home => TrunHomeScreen(
            onAdd: () =>
                InboxScreen.openManualInput(context, widget.controller),
            onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
            onSubmitPlan: planController == null
                ? null
                : (draft) => unawaited(_openPlanEditor(prefill: draft)),
            planSources: _planSources(),
          ),
          _HomeTab.library => ProductsScreen(
            controller: widget.controller,
            onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          _HomeTab.shared => SharedInboxScreen(
            entries: widget.controller.sharedInbox,
            onOpen: _openSharedTip,
            onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          _HomeTab.plans => PlansScreen(
            plans: planController != null && planController.isInitialized
                ? _planItems(planController)
                : const <PlanListItem>[],
            onCreatePlan: _openPlanEditor,
            onOpenPlan: _openPlanDetail,
            onOpenPast: _openPastPlans,
            onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        },
    ];

    final showingPlans = planController != null && _tab == _HomeTab.plans;
    final systemUiStyle = showingPlans
        ? const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: AppTheme.planSurface,
            systemNavigationBarDividerColor: AppTheme.planSurface,
            systemNavigationBarIconBrightness: Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          )
        : const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: AppTheme.background,
            systemNavigationBarDividerColor: AppTheme.background,
            systemNavigationBarIconBrightness: Brightness.light,
            systemNavigationBarContrastEnforced: false,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: PopScope<void>(
        canPop: !_handlesSystemBack || _exitArmed,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _handlesSystemBack) {
            unawaited(_handleSystemBack());
          }
        },
        child: Scaffold(
          key: _scaffoldKey,
          drawerEnableOpenDragGesture: false,
          drawer: _HomeDrawer(
            tabs: _tabs,
            current: _tab,
            sharedCount: sharedCount,
            onSelect: _selectTab,
            onOpenContents: _openContentList,
            onOpenPast: planController == null ? null : _openPastPlans,
            onBackupContents: _shareDevelopmentBackup,
            onClearContents: _confirmAndClearUserCaptures,
          ),
          body: Stack(
            children: [
              // Bottom included now that nothing sits under the screens. The
              // tab bar used to hold them clear of the home indicator.
              SafeArea(
                child: IndexedStack(index: _selectedIndex, children: screens),
              ),
              SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, -0.12),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: _incomingCaptureBatch == null
                        ? const SizedBox.shrink()
                        : Padding(
                            key: ValueKey(
                              _incomingCaptureBatch!.primaryCaptureId,
                            ),
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                            child: _IncomingCaptureCard(
                              controller: widget.controller,
                              captureId:
                                  _incomingCaptureBatch!.primaryCaptureId,
                              captureCount:
                                  _incomingCaptureBatch!.captureIds.length,
                              onDismiss: () {
                                setState(() => _incomingCaptureBatch = null);
                              },
                              onOpen: () =>
                                  _openIncomingCaptures(_incomingCaptureBatch!),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<PlanListItem> _planItems(PlanController controller) {
    return controller.items
        .map((item) {
          final plan = controller.planById(item.id);
          final sourceId = plan?.metadata['sourceCaptureId'];
          final capture = sourceId is String
              ? widget.controller.captureById(sourceId)
              : null;
          return PlanListItem(
            id: item.id,
            title: item.title,
            status: item.status,
            triggerLabel: item.triggerLabel,
            recurrenceLabel: item.recurrenceLabel,
            sourceLabel: capture == null
                ? item.sourceLabel
                : _captureTitle(capture),
            startsAt: item.startsAt,
            endsAt: item.endsAt,
            todos: item.todos,
          );
        })
        .toList(growable: false);
  }

  List<PlanSourceOption> _planSources() {
    return widget.controller.captures.reversed
        .map(
          (capture) => PlanSourceOption(
            captureId: capture.raw.id,
            title: _captureTitle(capture),
            tags: [for (final tag in capture.contentTags) tag.value],
            subtitle: capture.contentTags.isEmpty
                ? '태그 없음'
                : capture.contentTags.map((tag) => tag.value).join(' · '),
          ),
        )
        .toList(growable: false);
  }

  String _captureTitle(CaptureRecord capture) {
    final structured = capture.analysis?.structuredContent?.title.value?.trim();
    if (structured != null && structured.isNotEmpty) return structured;

    final mention = capture.primaryMention?.name.value?.trim();
    if (mention != null && mention.isNotEmpty) return mention;

    final normalized = capture.normalized.normalizedText
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isNotEmpty) {
      return normalized.length <= 42
          ? normalized
          : '${normalized.substring(0, 42).trimRight()}…';
    }
    final tag = capture.contentTags.firstOrNull?.value;
    return tag == null ? '제목 없는 콘텐츠' : '$tag 콘텐츠';
  }

  /// Step two of making a plan: break it into to-dos and let the reader keep
  /// what they want.
  ///
  /// Returns the kept to-dos, an empty list when there was nothing to show, or
  /// null when the reader backed out — which cancels the whole plan, since the
  /// plan does not exist yet.
  ///
  /// A failure here never costs a plan. The server being down leaves the reader
  /// with the plan they typed and nothing extra, which is worth saying out loud
  /// rather than passing off as "no to-dos found".
  Future<List<PlanTodoSuggestion>?> _suggestTodos(PlanDraft draft) async {
    // Both halves of what the 정리함 tab shows. Analysed captures carry places;
    // product groups carry things the reader confirmed and filed. A plan like
    // "올리브영에서 뭐 사지" is entirely about the second half, and reading only
    // the first is why an early build sent no candidates at all.
    //
    // An empty library is still not a reason to skip the call: the plan simply
    // comes back filled in by the model, and the screen labels which is which.
    //
    // The reader's chosen scope fences this off before the call. Sending the
    // whole library made the answer worse and dearer as the library grew, and
    // which folder a thing is in is something they know and the model guesses.
    // Reducing is the app's job; choosing inside what is left is the model's.
    final controller = widget.controller;
    final scopes = draft.scopes;
    final candidates = <RecommendationCandidate>[
      ...candidatesFromCaptures(
        controller.captures.where(
          (capture) => planScopeMatches(scopes, [
            for (final tag in capture.contentTags) tag.value,
          ]),
        ),
      ),
      for (final group in controller.groups)
        if (planScopeMatches(scopes, [
          for (final tag in controller.tagsForGroup(group.id)) tag.value,
        ]))
          candidateFromGroup(
            group,
            tags: [
              for (final tag in controller.tagsForGroup(group.id)) tag.value,
            ],
          ),
    ];

    final planDate = draft.scheduledAt ?? DateTime.now();
    final recommendation = await _withProgress(
      () => const RemotePlanRecommendationService().recommend(
        planTitle: draft.title,
        planArea: draft.locationQuery,
        scheduledAt: draft.scheduledAt,
        candidates: candidates,
      ),
    );
    if (!mounted) return const <PlanTodoSuggestion>[];

    switch (recommendation.status) {
      case PlanRecommendationStatus.ready:
        return PlanSuggestionScreen.open(
          context,
          planTitle: draft.title,
          planDate: planDate,
          recommendation: recommendation,
        );
      case PlanRecommendationStatus.noMatch:
        _showMessage('저장한 것 중에는 이 계획에 쓸 게 없었어요.');
        return const <PlanTodoSuggestion>[];
      case PlanRecommendationStatus.noCandidates:
        return const <PlanTodoSuggestion>[];
      case PlanRecommendationStatus.unavailable:
        _showMessage(_unavailableMessage(recommendation.failureCode));
        return const <PlanTodoSuggestion>[];
    }
  }

  /// Why the to-dos could not be fetched, in words a reader can act on.
  ///
  /// The codes were already being carried and thrown away. "할 일을 찾지 못했어요"
  /// reads the same whether the Mac moved to a new address or the server
  /// returned a 500, and only one of those is worth checking the Wi-Fi over.
  static String _unavailableMessage(String? failureCode) {
    const tail = ' 계획은 그대로 만들어요.';
    return switch (failureCode) {
      'unreachable' || 'invalid_server_url' =>
        '분석 서버에 연결하지 못했어요. 서버가 켜져 있고 같은 Wi-Fi인지 확인해 주세요.$tail',
      'malformed_response' => '서버 응답을 읽지 못했어요.$tail',
      final code? when code.startsWith('http_') =>
        '서버가 오류를 돌려줬어요 (${code.substring(5)}).$tail',
      _ => '할 일을 찾지 못했어요.$tail',
    };
  }

  /// Runs [work] behind a modal barrier the reader cannot dismiss into a
  /// half-made plan.
  Future<T> _withProgress<T>(Future<T> Function() work) async {
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Theme(
        data: AppTheme.plansTheme(Theme.of(dialogContext)),
        child: const PopScope(canPop: false, child: _PlanProgress()),
      ),
    );
    try {
      return await work();
    } finally {
      if (navigator.canPop()) navigator.pop();
    }
  }

  /// Makes a plan, from the tab's own button or from what was typed on home.
  ///
  /// [prefill] fills the editor's fields and changes nothing else. Everything
  /// after it — the questions, the to-do suggestion, the saving — is the one
  /// flow the 계획함 button has always used.
  Future<void> _openPlanEditor({PlanDraft? prefill}) async {
    final controller = widget.planController;
    if (controller == null) return;
    if (!controller.isInitialized) {
      await _initializePlans();
      if (!mounted || !controller.isInitialized) return;
    }

    final draft = await PlanEditorScreen.open(
      context,
      sources: _planSources(),
      prefill: prefill,
    );
    if (!mounted || draft == null) return;

    final usesLocation = draft.triggerKind != PlanDraftTriggerKind.time;
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    var notificationGranted = true;
    if (isAndroid) {
      const reminderService = PlaceReminderService();
      notificationGranted = await reminderService
          .requestNotificationPermission();
      if (usesLocation) {
        await reminderService.requestForegroundPermission();
      }
      if (!mounted) return;
    }

    final todos = await _suggestTodos(draft);
    if (!mounted) return;
    // Backing out of the suggestion screen backs out of the whole plan. The
    // plan does not exist yet, so there is nothing half-made left behind.
    if (todos == null) return;

    try {
      final plan = await controller.create(draft, todos: todos);
      if (!mounted) return;
      setState(() => _tab = _HomeTab.plans);

      if (isAndroid && usesLocation) {
        final permissionState = await const PlaceReminderService().getState(
          plan.id,
        );
        if (!mounted) return;
        if (!permissionState.foregroundGranted ||
            !permissionState.backgroundGranted) {
          await _showLocationPermissionGuide(permissionState);
        }
      }
      if (!mounted) return;
      if (!notificationGranted) {
        _showMessage('계획은 저장했어요. 알림 권한을 켜면 제때 알려드릴게요.');
      } else if (controller.lastError != null) {
        _showMessage('계획은 저장했지만 알림 설정을 마치지 못했어요.');
        controller.clearLastError();
      } else {
        _showMessage('계획을 저장했어요. 조건이 맞으면 알려드릴게요.');
      }
    } on PlanLocationResolutionException {
      if (mounted) {
        _showMessage('장소를 찾지 못했어요. 주소를 조금 더 정확히 입력해 주세요.');
      }
    } catch (error, stackTrace) {
      debugPrint('Plan creation failed: $error\n$stackTrace');
      if (mounted) _showMessage('계획을 저장하지 못했어요. 다시 시도해 주세요.');
    }
  }

  Future<void> _showLocationPermissionGuide(PlaceReminderState state) async {
    final needsForeground = !state.foregroundGranted;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: AppTheme.plansTheme(Theme.of(dialogContext)),
        child: AlertDialog(
          backgroundColor: AppTheme.planSurface,
          surfaceTintColor: Colors.transparent,
          title: Text(needsForeground ? '위치 허용이 필요해요' : '항상 허용으로 바꿔 주세요'),
          content: Text(
            needsForeground
                ? '장소에 도착했을 때 알려드리려면 위치를 허용해 주세요. 계획은 안전하게 저장해 뒀어요.'
                : '앱을 닫아도 알려드리려면 위치 권한을 ${state.backgroundPermissionLabel}으로 바꿔 주세요. 계획은 저장해 뒀어요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('나중에'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('설정 열기'),
            ),
          ],
        ),
      ),
    );
    if (openSettings == true && mounted) {
      await const PlaceReminderService().openBackgroundLocationSettings();
    }
  }

  /// Opens 지난함 over 계획함 rather than beside it in the tab bar.
  ///
  /// A tab is for somewhere a reader goes daily. Looking back is deliberate and
  /// occasional, and it is reached from the tab whose finished plans it holds —
  /// the same push 콘텐츠 takes from home.
  ///
  /// Rebuilt from the controller like the plan page, so finishing a plan while
  /// this is open puts it on the calendar without a trip back out.
  Future<void> _openPastPlans() async {
    final controller = widget.planController;
    if (controller == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: controller,
          builder: (_, _) => PastPlansScreen(
            plans: controller.isInitialized
                ? _planItems(controller)
                : const <PlanListItem>[],
            onOpenPlan: _openPlanDetail,
          ),
        ),
      ),
    );
  }

  /// Opens a plan's own page: its to-dos, and a way into the plan's actions.
  ///
  /// Rebuilt from the controller on every change rather than held as a
  /// snapshot, so ticking a to-do updates the page it was ticked on.
  Future<void> _openPlanDetail(PlanListItem item) async {
    final controller = widget.planController;
    if (controller == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => AnimatedBuilder(
          animation: controller,
          builder: (_, _) {
            final current = controller.items
                .where((one) => one.id == item.id)
                .firstOrNull;
            // Deleted from the actions sheet while this page was open.
            if (current == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(routeContext).canPop()) {
                  Navigator.of(routeContext).pop();
                }
              });
              return const SizedBox.shrink();
            }
            return PlanDetailScreen(
              title: current.title,
              triggerLabel: current.triggerLabel,
              planDate: _planDateOf(current.id),
              todos: current.todos,
              onToggle: (index, done) =>
                  unawaited(controller.setTodoDone(current.id, index, done)),
              onOpenActions: () => unawaited(_openPlanActions(current)),
              onOpenSaved: (saved) =>
                  _openSavedFromPlan(routeContext, saved.id),
            );
          },
        ),
      ),
    );
  }

  /// Opens whatever a plan's to-do points at.
  ///
  /// The 정리함 tab is two kinds of thing — analysed captures and confirmed
  /// product groups — and a to-do can carry either. Looking only for a capture
  /// is why an early build told the reader a product it had just named was not
  /// in their library.
  void _openSavedFromPlan(BuildContext routeContext, String savedId) {
    final controller = widget.controller;
    final capture = controller.captureById(savedId);
    if (capture != null) {
      Navigator.of(routeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => StructuredReviewScreen(
            controller: controller,
            captureId: savedId,
          ),
        ),
      );
      return;
    }
    final group = controller.groupById(savedId);
    if (group != null) {
      Navigator.of(routeContext).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ProductDetailScreen(controller: controller, groupId: savedId),
        ),
      );
      return;
    }
    // Deleted since the plan was made. The library moving on without the plan
    // is not an error, but staying silent would read as a dead tap.
    _showMessage('정리함에서 지워진 것 같아요.');
  }

  /// The day the plan is about, which every to-do's deadline counts back from.
  ///
  /// Not the condition: that holds when the alarm goes off, and a lead of a day
  /// or more would put every deadline on this screen a day or more ahead of the
  /// same deadline on the card that opened it.
  DateTime? _planDateOf(String planId) {
    final plan = widget.planController?.planById(planId);
    return plan == null ? null : PlanController.planStartsAt(plan);
  }

  Future<void> _openPlanActions(PlanListItem item) async {
    final controller = widget.planController;
    final plan = controller?.planById(item.id);
    if (controller == null || plan == null) return;

    final sourceId = plan.metadata['sourceCaptureId'];
    final hasSource = sourceId is String && sourceId.trim().isNotEmpty;
    final action = await showModalBottomSheet<_PlanMenuAction>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppTheme.planSurface,
      builder: (sheetContext) => Theme(
        data: AppTheme.plansTheme(Theme.of(sheetContext)),
        child: _PlanActionsSheet(plan: plan, hasSource: hasSource),
      ),
    );
    if (!mounted || action == null) return;

    try {
      switch (action) {
        case _PlanMenuAction.openSource:
          final capture = sourceId is String
              ? widget.controller.captureById(sourceId)
              : null;
          if (capture == null) {
            _showMessage('연결된 콘텐츠를 찾지 못했어요.');
          } else {
            setState(() => _tab = _HomeTab.library);
            _openCapture(
              capture,
              planContext: _PlanCaptureOpenContext(
                planId: plan.id,
                origin: _PlanCaptureOpenOrigin.planActions,
              ),
            );
          }
        case _PlanMenuAction.pause:
          await controller.pause(plan.id);
          if (mounted) _showMessage('계획을 잠시 멈췄어요.');
        case _PlanMenuAction.resume:
          await controller.resume(plan.id);
          if (mounted) _showMessage('계획을 다시 시작했어요.');
        case _PlanMenuAction.snooze:
          await controller.snooze(plan.id, delay: const Duration(minutes: 30));
          if (mounted) _showMessage('30분 뒤에 다시 알려드릴게요.');
        case _PlanMenuAction.complete:
          await controller.complete(plan.id);
          if (mounted) _showMessage('완료한 계획으로 옮겼어요.');
        case _PlanMenuAction.notInterested:
          await controller.recordInteraction(
            plan.id,
            TriggerPlanEventKind.notInterested,
            const <String, Object?>{'source': 'plan_actions'},
          );
          await controller.pause(plan.id);
          if (mounted) _showMessage('이런 알림은 그만 보낼게요.');
        case _PlanMenuAction.visitResult:
          final result = await _showVisitResultSheet(plan);
          if (result == null) return;
          await controller.recordInteraction(
            plan.id,
            result.eventKind,
            const <String, Object?>{'source': 'plan_actions_visit_result'},
          );
          if (mounted) _showMessage('방문 결과를 남겼어요.');
        case _PlanMenuAction.delete:
          final confirmed = await _confirmPlanDelete(plan.title);
          if (confirmed == true) {
            await controller.delete(plan.id);
            if (mounted) _showMessage('계획을 삭제했어요.');
          }
      }
    } catch (error, stackTrace) {
      debugPrint('Plan action failed: $error\n$stackTrace');
      if (mounted) _showMessage('처리하지 못했어요. 다시 시도해 주세요.');
    }
  }

  Future<_VisitResult?> _showVisitResultSheet(Plan plan) {
    return showModalBottomSheet<_VisitResult>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppTheme.planSurface,
      builder: (sheetContext) => Theme(
        data: AppTheme.plansTheme(Theme.of(sheetContext)),
        child: _VisitResultSheet(planTitle: plan.title),
      ),
    );
  }

  Future<bool?> _confirmPlanDelete(String title) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: AppTheme.plansTheme(Theme.of(dialogContext)),
        child: AlertDialog(
          backgroundColor: AppTheme.planSurface,
          surfaceTintColor: Colors.transparent,
          title: const Text('이 계획을 삭제할까요?'),
          content: Text('“$title” 알림과 기록이 함께 삭제돼요.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.planNegative,
              ),
              child: const Text('삭제'),
            ),
          ],
        ),
      ),
    );
  }

  void _openIncomingCaptures(IncomingCaptureBatch batch) {
    if (batch.captureIds.length > 1) {
      setState(() => _incomingCaptureBatch = null);
      _openContentList();
      return;
    }
    final captureId = batch.primaryCaptureId;
    final capture = widget.controller.captureById(captureId);
    if (capture == null) {
      setState(() => _incomingCaptureBatch = null);
      return;
    }
    if (capture.status == CaptureStatus.analyzing) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('이미지를 정리하고 있어요. 잠시만 기다려 주세요.')),
        );
      return;
    }

    setState(() => _incomingCaptureBatch = null);
    _openCapture(capture);
  }

  void _openCapture(
    CaptureRecord capture, {
    _PlanCaptureOpenContext? planContext,
  }) {
    if (capture.status == CaptureStatus.analyzing) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('이미지를 정리하고 있어요. 잠시만 기다려 주세요.')),
        );
      return;
    }
    if (capture.analysis?.structuredContent != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StructuredReviewScreen(
            controller: widget.controller,
            captureId: capture.raw.id,
            planId: planContext?.planId,
            onMapOpened: planContext == null
                ? null
                : ({required provider, required captureId, planId}) async {
                    final controller = widget.planController;
                    if (controller == null || planId == null) return;
                    await controller.recordInteraction(
                      planId,
                      TriggerPlanEventKind.mapOpened,
                      <String, Object?>{
                        'provider': provider.id,
                        'captureId': captureId,
                        'planId': planId,
                        'source': planContext.origin.analyticsSource,
                        if (planContext.nativeOpenEventId != null)
                          'nativeOpenEventId': planContext.nativeOpenEventId!,
                      },
                    );
                  },
          ),
        ),
      );
      if (planContext != null) {
        unawaited(_recordSourceOpened(capture, planContext));
      }
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnalysisReviewScreen(
          controller: widget.controller,
          captureId: capture.raw.id,
        ),
      ),
    );
    if (planContext != null) {
      unawaited(_recordSourceOpened(capture, planContext));
    }
  }

  Future<void> _recordSourceOpened(
    CaptureRecord capture,
    _PlanCaptureOpenContext planContext,
  ) async {
    final metadata = <String, Object?>{
      'captureId': capture.raw.id,
      'planId': planContext.planId,
      'source': planContext.origin.analyticsSource,
      if (planContext.nativeOpenEventId != null)
        'nativeOpenEventId': planContext.nativeOpenEventId!,
    };
    final controller = widget.planController;
    if (controller == null) return;
    await _recordPlanInteraction(
      controller,
      planContext.planId,
      TriggerPlanEventKind.sourceOpened,
      metadata,
    );
  }

  Future<void> _recordPlanInteraction(
    PlanController controller,
    String planId,
    TriggerPlanEventKind kind,
    Map<String, Object?> metadata,
  ) async {
    try {
      await controller.recordInteraction(planId, kind, metadata);
    } on Object catch (error, stackTrace) {
      debugPrint(
        'Plan interaction recording failed '
        '(${kind.name}, $planId): $error\n$stackTrace',
      );
    }
  }
}

/// The bar that slides in from the left.
///
/// Everywhere the app goes, in one list. The tab bar still carries the four a
/// reader visits daily; this also holds the two that only ever had doors — 콘텐츠
/// and 지난함 — so there is one place that answers "what else is in here".
final class _HomeDrawer extends StatelessWidget {
  const _HomeDrawer({
    required this.tabs,
    required this.current,
    required this.sharedCount,
    required this.onSelect,
    required this.onOpenContents,
    required this.onOpenPast,
    required this.onBackupContents,
    required this.onClearContents,
  });

  final List<_HomeTab> tabs;
  final _HomeTab current;
  final int sharedCount;
  final ValueChanged<_HomeTab> onSelect;
  final VoidCallback onOpenContents;
  final VoidCallback onBackupContents;
  final VoidCallback onClearContents;

  /// Null when there are no plans at all, and then the drawer does not offer a
  /// door to what is behind them.
  final VoidCallback? onOpenPast;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The wordmark lives here now. It left home's own header when the
            // menu took that corner, and a drawer is where an app's name can
            // sit without spending a row of the screen behind it.
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 26, 24, 22),
              // Shrunk rather than clipped: at a large text size the name and
              // its badge are wider than a drawer.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Text(
                      'TRUN ON',
                      style: TextStyle(
                        color: AppTheme.ink,
                        fontSize: 20,
                        letterSpacing: -0.6,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(width: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.primarySoft,
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          'BETA',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 11,
                            letterSpacing: 0.6,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final tab in tabs)
                    _DrawerItem(
                      icon: _tabIcon(tab),
                      label: _tabLabel(tab),
                      badge: tab == _HomeTab.shared ? sharedCount : 0,
                      selected: tab == current,
                      onTap: () {
                        Navigator.of(context).pop();
                        onSelect(tab);
                      },
                    ),
                  const Divider(height: 26, indent: 16, endIndent: 16),
                  _DrawerItem(
                    icon: Icons.inbox_rounded,
                    label: '콘텐츠',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenContents();
                    },
                  ),
                  if (onOpenPast case final openPast?)
                    _DrawerItem(
                      icon: Icons.history_rounded,
                      label: '지난함',
                      onTap: () {
                        Navigator.of(context).pop();
                        openPast();
                      },
                    ),
                  if (kDebugMode) ...[
                    const Divider(height: 26, indent: 16, endIndent: 16),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 2, 16, 10),
                      child: Text(
                        '개발 도구',
                        style: TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _DrawerItem(
                      icon: Icons.archive_outlined,
                      label: '콘텐츠 전체 백업(ZIP)',
                      onTap: () {
                        Navigator.of(context).pop();
                        onBackupContents();
                      },
                    ),
                    _DrawerItem(
                      icon: Icons.delete_sweep_outlined,
                      label: '가져온 콘텐츠 전체 삭제',
                      onTap: () {
                        Navigator.of(context).pop();
                        onClearContents();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _tabLabel(_HomeTab tab) => switch (tab) {
    _HomeTab.home => '홈',
    _HomeTab.library => '정리함',
    _HomeTab.shared => '공유함',
    _HomeTab.plans => '계획함',
  };

  static IconData _tabIcon(_HomeTab tab) => switch (tab) {
    _HomeTab.home => Icons.home_rounded,
    _HomeTab.library => Icons.bookmark_rounded,
    _HomeTab.shared => Icons.move_to_inbox_rounded,
    _HomeTab.plans => Icons.notifications_rounded,
  };
}

final class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? AppTheme.primary : AppTheme.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        key: Key('drawer-item-$label'),
        color: selected ? AppTheme.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected ? AppTheme.primary : AppTheme.muted,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: ink,
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w700,
                      ),
                    ),
                  ),
                  if (badge > 0)
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        color: AppTheme.accent,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(
                        dimension: 22,
                        child: Center(
                          child: Text(
                            '$badge',
                            style: const TextStyle(
                              color: Color(0xFF1A0B08),
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
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

enum _PlanMenuAction {
  openSource,
  pause,
  resume,
  snooze,
  complete,
  notInterested,
  visitResult,
  delete,
}

enum _PlanCaptureOpenOrigin {
  notification('notification'),
  planActions('plan_actions');

  const _PlanCaptureOpenOrigin(this.analyticsSource);

  final String analyticsSource;
}

final class _PlanCaptureOpenContext {
  const _PlanCaptureOpenContext({
    required this.planId,
    required this.origin,
    this.nativeOpenEventId,
  });

  final String planId;
  final _PlanCaptureOpenOrigin origin;
  final String? nativeOpenEventId;
}

enum _VisitResult {
  confirmed(TriggerPlanEventKind.visitConfirmed),
  didNotVisit(TriggerPlanEventKind.didNotVisit),
  unknown(TriggerPlanEventKind.visitUnknown);

  const _VisitResult(this.eventKind);

  final TriggerPlanEventKind eventKind;
}

final class _PlanActionsSheet extends StatelessWidget {
  const _PlanActionsSheet({required this.plan, required this.hasSource});

  final Plan plan;
  final bool hasSource;

  bool get _canPause =>
      plan.lifecycle == PlanLifecycle.active ||
      plan.lifecycle == PlanLifecycle.fired;

  bool get _canResume =>
      plan.lifecycle == PlanLifecycle.paused ||
      plan.lifecycle == PlanLifecycle.draft;

  bool get _canSnooze =>
      plan.lifecycle != PlanLifecycle.completed &&
      plan.lifecycle != PlanLifecycle.expired;

  bool get _canComplete =>
      plan.lifecycle != PlanLifecycle.completed &&
      plan.lifecycle != PlanLifecycle.expired;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            const Text(
              '계획을 관리하거나 연결된 내용을 다시 볼 수 있어요.',
              style: TextStyle(
                color: AppTheme.planMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.planCanvas,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.planBorder),
              ),
              child: Column(
                children: [
                  if (hasSource)
                    _PlanActionTile(
                      icon: Icons.article_outlined,
                      label: '연결된 콘텐츠 보기',
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.openSource),
                    ),
                  _PlanActionTile(
                    icon: Icons.how_to_reg_outlined,
                    label: '방문 결과 남기기',
                    onTap: () =>
                        Navigator.pop(context, _PlanMenuAction.visitResult),
                  ),
                  if (_canPause)
                    _PlanActionTile(
                      icon: Icons.pause_circle_outline_rounded,
                      label: '잠시 멈추기',
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.pause),
                    ),
                  if (_canResume)
                    _PlanActionTile(
                      icon: Icons.play_circle_outline_rounded,
                      label: '다시 시작하기',
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.resume),
                    ),
                  if (_canSnooze)
                    _PlanActionTile(
                      icon: Icons.snooze_rounded,
                      label: '30분 뒤에 다시 알리기',
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.snooze),
                    ),
                  if (_canComplete)
                    _PlanActionTile(
                      icon: Icons.check_circle_outline_rounded,
                      label: '완료로 표시',
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.complete),
                    ),
                  if (_canSnooze)
                    _PlanActionTile(
                      icon: Icons.notifications_off_outlined,
                      label: '이런 알림 그만 받기',
                      destructive: true,
                      onTap: () =>
                          Navigator.pop(context, _PlanMenuAction.notInterested),
                    ),
                  _PlanActionTile(
                    icon: Icons.delete_outline_rounded,
                    label: '계획 삭제',
                    destructive: true,
                    showDivider: false,
                    onTap: () => Navigator.pop(context, _PlanMenuAction.delete),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _VisitResultSheet extends StatelessWidget {
  const _VisitResultSheet({required this.planTitle});

  final String planTitle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('방문 결과', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            Text(
              '“$planTitle”에 대한 결과를 알려 주세요.',
              style: const TextStyle(
                color: AppTheme.planMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.planCanvas,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.planBorder),
              ),
              child: Column(
                children: [
                  _PlanActionTile(
                    icon: Icons.check_circle_outline_rounded,
                    label: '다녀왔어요',
                    onTap: () => Navigator.pop(context, _VisitResult.confirmed),
                  ),
                  _PlanActionTile(
                    icon: Icons.cancel_outlined,
                    label: '안 갔어요',
                    onTap: () =>
                        Navigator.pop(context, _VisitResult.didNotVisit),
                  ),
                  _PlanActionTile(
                    icon: Icons.help_outline_rounded,
                    label: '아직 몰라요',
                    showDivider: false,
                    onTap: () => Navigator.pop(context, _VisitResult.unknown),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PlanActionTile extends StatelessWidget {
  const _PlanActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.showDivider = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.planNegative : AppTheme.planInk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            minTileHeight: 54,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(icon, color: color, size: 21),
            title: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.planSubtle,
              size: 20,
            ),
            onTap: onTap,
          ),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 50, color: AppTheme.planBorder),
      ],
    );
  }
}

final class _IncomingCaptureCard extends StatelessWidget {
  const _IncomingCaptureCard({
    required this.controller,
    required this.captureId,
    required this.captureCount,
    required this.onDismiss,
    required this.onOpen,
  });

  final AppController controller;
  final String captureId;
  final int captureCount;
  final VoidCallback onDismiss;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final capture = controller.captureById(captureId);
        if (capture == null) {
          return const SizedBox.shrink();
        }
        final state = captureCount > 1
            ? _CaptureArrivalState.batch(captureCount)
            : _CaptureArrivalState.from(capture);

        return Material(
          color: AppTheme.surfaceRaised,
          elevation: 14,
          shadowColor: const Color(0x99000000),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: state.iconBackground,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: state.isLoading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppTheme.primary,
                            ),
                          )
                        : Icon(state.icon, color: state.iconColor, size: 23),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.title,
                          style: const TextStyle(
                            color: AppTheme.ink,
                            fontSize: 16,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          state.description,
                          style: const TextStyle(
                            color: AppTheme.muted,
                            fontSize: 13,
                            height: 1.35,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('incoming-capture-dismiss'),
                    tooltip: '닫기',
                    onPressed: onDismiss,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _CaptureArrivalState {
  const _CaptureArrivalState({
    required this.title,
    required this.description,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    this.isLoading = false,
  });

  factory _CaptureArrivalState.batch(int count) {
    return _CaptureArrivalState(
      title: '콘텐츠 $count개를 가져왔어요',
      description: '콘텐츠에서 정리 상태와 결과를 확인해 주세요',
      icon: Icons.collections_outlined,
      iconColor: AppTheme.primary,
      iconBackground: AppTheme.primarySoft,
    );
  }

  factory _CaptureArrivalState.from(CaptureRecord capture) {
    if (capture.status == CaptureStatus.sourceLimited &&
        capture.raw.attachments.isEmpty &&
        capture.normalized.completeness == MaterialCompleteness.linkOnly) {
      return const _CaptureArrivalState(
        title: '링크를 저장했어요',
        description: '게시물 내용은 전달되지 않았어요 · 스크린샷을 보내 주세요',
        icon: Icons.link_rounded,
        iconColor: AppTheme.caution,
        iconBackground: AppTheme.accentSoft,
      );
    }
    return switch (capture.status) {
      CaptureStatus.received => const _CaptureArrivalState(
        title: '캡처를 받았어요',
        description: '이미지 정리를 준비하고 있어요',
        icon: Icons.image_outlined,
        iconColor: AppTheme.primary,
        iconBackground: AppTheme.primarySoft,
      ),
      CaptureStatus.analyzing => const _CaptureArrivalState(
        title: '캡처를 받았어요',
        description: '이미지를 정리하고 있어요',
        icon: Icons.auto_awesome_rounded,
        iconColor: AppTheme.primary,
        iconBackground: AppTheme.primarySoft,
        isLoading: true,
      ),
      CaptureStatus.needsReview => const _CaptureArrivalState(
        title: '정리가 준비됐어요',
        description: '탭해서 내용을 확인해 주세요',
        icon: Icons.check_rounded,
        iconColor: AppTheme.positive,
        iconBackground: Color(0xFF15322D),
      ),
      CaptureStatus.organized => const _CaptureArrivalState(
        title: '정리를 완료했어요',
        description: '콘텐츠에 안전하게 보관했어요',
        icon: Icons.bookmark_added_rounded,
        iconColor: AppTheme.primary,
        iconBackground: AppTheme.primarySoft,
      ),
      CaptureStatus.sourceLimited ||
      CaptureStatus.failed => const _CaptureArrivalState(
        title: '내용을 확인해 주세요',
        description: '탭해서 결과를 살펴볼 수 있어요',
        icon: Icons.error_outline_rounded,
        iconColor: AppTheme.negative,
        iconBackground: Color(0xFF381D1E),
      ),
    };
  }

  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final bool isLoading;
}

final class _SourceImageChoiceSheet extends StatelessWidget {
  const _SourceImageChoiceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              child: ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: AppTheme.primarySoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.download_done_rounded,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Trun On에 안전하게 저장했어요',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              '갤러리의 원본도 남겨둘까요? 어떤 선택을 해도 Trun On 안의 복사본은 유지돼요.',
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('갤러리에 두기'),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: AppTheme.negative),
                child: const Text('갤러리 원본 삭제'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wait while a plan is being broken into to-dos.
///
/// The words change as it goes. A spinner that says the same thing for twenty
/// seconds is indistinguishable from one that has stopped, and this call sits
/// between a reader tapping save and seeing anything at all.
final class _PlanProgress extends StatefulWidget {
  const _PlanProgress();

  @override
  State<_PlanProgress> createState() => _PlanProgressState();
}

final class _PlanProgressState extends State<_PlanProgress> {
  static const _steps = <(Duration, String)>[
    (Duration.zero, '저장한 것 중에서 할 일을 찾는 중'),
    (Duration(seconds: 9), '거의 다 됐어요'),
    (Duration(seconds: 20), '조금 더 걸리고 있어요'),
  ];

  final _timers = <Timer>[];
  var _step = 0;

  @override
  void initState() {
    super.initState();
    for (var index = 1; index < _steps.length; index += 1) {
      _timers.add(
        Timer(_steps[index].$1, () {
          if (mounted) setState(() => _step = index);
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.planMauve),
            const SizedBox(height: 18),
            Text(
              _steps[_step].$2,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.planInk,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tabs, by name.
///
/// Positions move — 계획함 is only there with a plan controller, and 콘텐츠 left
/// the bar entirely — so nothing addresses a tab by number.
enum _HomeTab { home, library, shared, plans }
