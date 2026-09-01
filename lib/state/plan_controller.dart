import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/plan_recommendation_service.dart';
import '../data/trigger_plan_store.dart';
import '../data/trigger_scheduler.dart';
import '../domain/trigger_engine.dart';
import '../domain/trigger_models.dart';
import '../features/plans/plan_editor_screen.dart';
import '../features/plans/plans_screen.dart';

typedef PlanClock = DateTime Function();
typedef PlanIdFactory = String Function(DateTime now);

final class PlanLocationResolutionException implements Exception {
  const PlanLocationResolutionException(this.query);

  final String query;

  @override
  String toString() => '장소를 찾지 못했어요: $query';
}

/// Coordinates plan persistence, deterministic evaluation, and native delivery.
///
/// Capture storage intentionally stays outside this controller. A plan only
/// keeps a stable capture id in metadata, so capture migrations and trigger
/// migrations can evolve independently.
final class PlanController extends ChangeNotifier {
  PlanController({
    required TriggerPlanStore store,
    required TriggerScheduler scheduler,
    TriggerEngine engine = const TriggerEngine(),
    PlanClock? clock,
    PlanIdFactory? idFactory,
    this.locationRadiusMeters = 500,
    this.closeSchedulerOnDispose = true,
  }) : // Keep the public dependency names free of private underscores.
       // ignore: prefer_initializing_formals
       _store = store,
       // ignore: prefer_initializing_formals
       _scheduler = scheduler,
       // ignore: prefer_initializing_formals
       _engine = engine,
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? _defaultIdFactory {
    if (!locationRadiusMeters.isFinite || locationRadiusMeters <= 0) {
      throw ArgumentError.value(
        locationRadiusMeters,
        'locationRadiusMeters',
        'Must be a positive finite number.',
      );
    }
  }

  final TriggerPlanStore _store;
  final TriggerScheduler _scheduler;
  final TriggerEngine _engine;
  final PlanClock _clock;
  final PlanIdFactory _idFactory;
  final double locationRadiusMeters;
  final bool closeSchedulerOnDispose;

  final List<PersistedTriggerPlan> _records = <PersistedTriggerPlan>[];
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _initializeFuture;
  StreamSubscription<NativeTriggerOpen>? _openedSubscription;
  StreamSubscription<List<NativeTriggerOpen>>? _opensSubscription;
  StreamSubscription<List<NativeTriggerOutcome>>? _outcomesSubscription;
  NativeTriggerOpen? _pendingOpen;
  final Set<String> _consumedOpenEventIds = <String>{};
  Object? _lastError;
  bool _initialized = false;
  bool _disposed = false;
  int _eventSequence = 0;

  static const Set<TriggerPlanEventKind> _interactionEventKinds =
      <TriggerPlanEventKind>{
        TriggerPlanEventKind.sourceOpened,
        TriggerPlanEventKind.mapOpened,
        TriggerPlanEventKind.routeStarted,
        TriggerPlanEventKind.notInterested,
        TriggerPlanEventKind.visitConfirmed,
        TriggerPlanEventKind.didNotVisit,
        TriggerPlanEventKind.visitUnknown,
        TriggerPlanEventKind.notificationDisabled,
      };

  static const List<String> _planContextMetadataKeys = <String>[
    'experimentId',
    'variant',
    'scenarioId',
    'sourceCaptureId',
  ];

  static const List<String> _eventIdentityMetadataKeys = <String>[
    'eventKey',
    'deliveryId',
    'nativeOpenEventId',
  ];

  bool get isInitialized => _initialized;
  Object? get lastError => _lastError;

  List<PersistedTriggerPlan> get records =>
      List<PersistedTriggerPlan>.unmodifiable(_records);

  List<Plan> get plans =>
      List<Plan>.unmodifiable(_records.map((record) => record.plan));

  List<PlanListItem> get items {
    final result = _records.map(_toListItem).toList(growable: false);
    result.sort((first, second) {
      final statusOrder = first.status.index.compareTo(second.status.index);
      if (statusOrder != 0) return statusOrder;
      final firstPlan = planById(first.id)!;
      final secondPlan = planById(second.id)!;
      return secondPlan.createdAt.compareTo(firstPlan.createdAt);
    });
    return List<PlanListItem>.unmodifiable(result);
  }

  NativeTriggerOpen? get pendingOpen => _pendingOpen;
  String? get pendingOpenPlanId => _pendingOpen?.ruleId;

  String? get pendingSourceCaptureId {
    final open = _pendingOpen;
    if (open == null) return null;
    final plan = planById(open.ruleId);
    final sourceId = plan?.metadata['sourceCaptureId'];
    if (sourceId is String && sourceId.trim().isNotEmpty) {
      return sourceId.trim();
    }
    final destination = open.destinationId.trim();
    if (destination.isNotEmpty && destination != open.ruleId) {
      return destination;
    }
    return null;
  }

  Plan? planById(String id) {
    for (final record in _records) {
      if (record.plan.id == id) return record.plan;
    }
    return null;
  }

  PersistedTriggerPlan? recordById(String id) {
    for (final record in _records) {
      if (record.plan.id == id) return record;
    }
    return null;
  }

  Future<void> initialize() {
    return _initializeFuture ??= _initialize();
  }

  /// Reconciles persisted plans with the native scheduler again.
  ///
  /// Android users can grant background location from system settings after a
  /// plan was saved. Calling this when the app resumes activates those plans
  /// without asking the user to recreate them.
  Future<void> refreshScheduling() {
    _requireInitialized();
    return _exclusive(() async {
      try {
        await _syncPlansAndRecordPermission();
      } catch (error) {
        _rememberError(error);
      }
    });
  }

  Future<void> _initialize() async {
    try {
      final loaded = await _store.load();
      _records
        ..clear()
        ..addAll(loaded);
      _initialized = true;
      _bindSchedulerStreams();
      _notify();

      try {
        await _syncPlansAndRecordPermission();
      } catch (error) {
        _rememberError(error);
      }

      final outcomes = await _safePendingOutcomes();
      if (outcomes.isNotEmpty) await _applyNativeOutcomes(outcomes);
      final opens = await _safePendingOpens();
      if (opens.isNotEmpty) await _applyNativeOpens(opens);
    } catch (error) {
      _rememberError(error);
      rethrow;
    }
  }

  /// Creates a plan, optionally carrying the to-dos a reader kept on the
  /// suggestion screen.
  ///
  /// The to-dos ride in metadata rather than in their own store. They are what
  /// the plan is *about* rather than something the scheduler acts on — one plan
  /// still fires one notification — and metadata already persists and migrates.
  Future<Plan> create(
    PlanDraft draft, {
    List<PlanTodoSuggestion> todos = const <PlanTodoSuggestion>[],
  }) {
    _requireInitialized();
    return _exclusive(() async {
      final now = _clock();
      final id = _uniquePlanId(now);
      final resolved = await _resolveDraftLocation(draft);
      final condition = _conditionFromDraft(draft, resolved);
      final recurrence = _recurrenceFromDraft(draft.recurrence);
      final sourceCaptureId = draft.sourceCaptureId?.trim();
      final locationQuery = draft.locationQuery?.trim();
      final metadata = <String, Object?>{
        'triggerKind': draft.triggerKind.name,
        'updatedAt': now.toIso8601String(),
        'laterDelayMillis': const Duration(minutes: 30).inMilliseconds,
        if (sourceCaptureId != null && sourceCaptureId.isNotEmpty)
          'sourceCaptureId': sourceCaptureId,
        if (locationQuery != null && locationQuery.isNotEmpty)
          'locationQuery': locationQuery,
        // When the plan happens, as against when it fires. The trigger carries
        // the notification time, so reading the plan's own time back out of the
        // condition would be short by the lead — every countdown and every
        // to-do deadline off by the same amount, quietly. Read it through
        // [planStartsAt] and nowhere else.
        //
        // `leadTime` is written for an edit screen that does not exist yet:
        // nothing reads it today, and reopening a plan is not a thing the app
        // can do. It costs a string, and rebuilding it later from the gap
        // between the two times would only ever be a guess.
        if (draft.scheduledAt case final scheduledAt?) ...{
          'scheduledAt': scheduledAt.toIso8601String(),
          'leadTime': draft.leadTime.name,
        },
        // Written for that same editor, and for a re-run of the recommendation
        // that should search where the first one did. Also unread today.
        if (draft.scopes.isNotEmpty)
          'contentScopes': List<String>.from(draft.scopes),
        // Metadata rather than the rule: the scheduler still fires once, at
        // `scheduledAt`. How many days the plan covers is something only a card
        // reads — and the expiry, so a trip does not end on its first evening.
        if (draft.endsAt case final endsAt?)
          'endsAt': DateTime(
            endsAt.year,
            endsAt.month,
            endsAt.day,
          ).toIso8601String(),
        if (todos.isNotEmpty)
          'todos': todos.map((todo) => todo.toJson()).toList(growable: false),
        if (resolved != null) ...{
          'formattedAddress': resolved.formattedAddress,
          'resolvedLocation': <String, Object?>{
            'latitude': resolved.point.latitude,
            'longitude': resolved.point.longitude,
            'radiusMeters': locationRadiusMeters,
          },
        },
      };
      final plan = Plan(
        id: id,
        title: draft.title.trim(),
        rule: TriggerRule(
          condition: condition,
          recurrence: recurrence,
          cooldown: _defaultCooldown(recurrence),
          dedupeKey: id,
        ),
        lifecycle: PlanLifecycle.active,
        delivery: TriggerDelivery(
          channel: DeliveryChannel.localNotification,
          title: draft.title.trim(),
          body: _notificationBody(draft, resolved),
          payload: <String, Object?>{
            'destinationId': sourceCaptureId?.isNotEmpty == true
                ? sourceCaptureId!
                : id,
          },
        ),
        createdAt: now,
        expiresAt: _expiryFromDraft(draft),
        metadata: metadata,
      );
      final record = PersistedTriggerPlan(
        plan: plan,
        events: <TriggerPlanEvent>[
          _event(
            plan.id,
            TriggerPlanEventKind.created,
            now,
            metadata: _mergeEventMetadata(plan, const <String, Object?>{}),
          ),
        ],
      );
      _records.add(record);
      await _persistAndNotify();
      await _scheduleAndRecord(plan, resetState: true);
      return planById(plan.id)!;
    });
  }

  /// Ticks a plan's to-do off, or back on.
  ///
  /// Addressed by position because to-dos have no ids of their own: they are a
  /// list inside one plan's metadata, and nothing outside that plan refers to
  /// them. An index that no longer exists is ignored rather than thrown, since
  /// the only caller is a screen that may be a frame behind.
  Future<void> setTodoDone(String planId, int index, bool done) {
    _requireInitialized();
    return _exclusive(() async {
      final recordIndex = _recordIndex(planId);
      if (recordIndex < 0) return;
      final record = _records[recordIndex];
      final todos = _todosOf(record.plan);
      if (index < 0 || index >= todos.length) return;
      if (todos[index].done == done) return;

      final updated = <PlanTodoSuggestion>[
        for (var position = 0; position < todos.length; position += 1)
          position == index
              ? todos[position].copyWith(done: done)
              : todos[position],
      ];
      _records[recordIndex] = record.copyWith(
        plan: record.plan.copyWith(
          metadata: <String, Object?>{
            ...record.plan.metadata,
            'todos': updated
                .map((todo) => todo.toJson())
                .toList(growable: false),
          },
        ),
      );
      await _persistAndNotify();
    });
  }

  Future<void> pause(String planId) {
    return _changeLifecycle(
      planId,
      lifecycle: PlanLifecycle.paused,
      eventKind: TriggerPlanEventKind.paused,
      reschedule: true,
    );
  }

  Future<void> resume(String planId) {
    return _changeLifecycle(
      planId,
      lifecycle: PlanLifecycle.active,
      eventKind: TriggerPlanEventKind.resumed,
      reschedule: true,
    );
  }

  Future<void> complete(String planId) {
    _requireInitialized();
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      final record = _records[index];
      if (record.plan.lifecycle == PlanLifecycle.completed) return;
      final now = _clock();
      _records[index] = record.copyWith(
        plan: _withLifecycle(record.plan, PlanLifecycle.completed, now),
        events: <TriggerPlanEvent>[
          ...record.events,
          _event(planId, TriggerPlanEventKind.completed, now),
        ],
      );
      await _persistAndNotify();
      await _safeCancel(planId);
    });
  }

  Future<void> snooze(
    String planId, {
    Duration delay = const Duration(minutes: 30),
  }) {
    _requireInitialized();
    if (delay <= Duration.zero) {
      throw ArgumentError.value(delay, 'delay', 'Must be positive.');
    }
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      final record = _records[index];
      if (record.plan.lifecycle == PlanLifecycle.completed ||
          record.plan.lifecycle == PlanLifecycle.expired) {
        throw StateError('A completed or expired plan cannot be snoozed.');
      }
      final now = _clock();
      final until = now.add(delay);
      final delayedCondition = _delayCondition(
        record.plan.rule.condition,
        until,
      );
      final metadata = <String, Object?>{
        ...record.plan.metadata,
        'snoozedUntil': until.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      };
      final plan = record.plan.copyWith(
        lifecycle: PlanLifecycle.active,
        rule: TriggerRule(
          condition: delayedCondition,
          recurrence: record.plan.rule.recurrence,
          cooldown: record.plan.rule.cooldown,
          dedupeKey: record.plan.rule.dedupeKey,
        ),
        metadata: metadata,
      );
      _records[index] = record.copyWith(
        plan: plan,
        runtimeState: TriggerRuntimeState(),
        events: <TriggerPlanEvent>[
          ...record.events,
          _event(
            planId,
            TriggerPlanEventKind.snoozed,
            now,
            metadata: <String, Object?>{
              'snoozedUntil': until.toIso8601String(),
            },
          ),
        ],
      );
      await _persistAndNotify();
      await _scheduleAndRecord(plan, resetState: true);
    });
  }

  Future<void> delete(String planId) {
    _requireInitialized();
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      _records.removeAt(index);
      if (_pendingOpen?.ruleId == planId) _pendingOpen = null;
      await _persistAndNotify();
      await _safeCancel(planId);
    });
  }

  /// Records an analytics-safe interaction initiated by the user.
  ///
  /// Lifecycle, scheduling, eligibility, and native delivery events have
  /// dedicated controller paths and are intentionally rejected here. Stable
  /// plan context wins over caller-provided values so an interaction cannot be
  /// attributed to another experiment or source capture accidentally.
  Future<void> recordInteraction(
    String planId,
    TriggerPlanEventKind kind, [
    Map<String, Object?> metadata = const <String, Object?>{},
  ]) {
    _requireInitialized();
    if (!_interactionEventKinds.contains(kind)) {
      throw ArgumentError.value(
        kind,
        'kind',
        'Only user interaction event kinds can be recorded.',
      );
    }
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      final record = _records[index];
      final mergedMetadata = _mergeEventMetadata(record.plan, metadata);
      if (_containsEventIdentity(record.events, kind, mergedMetadata)) return;

      final updatedRecord = record.copyWith(
        events: <TriggerPlanEvent>[
          ...record.events,
          _event(planId, kind, _clock(), metadata: mergedMetadata),
        ],
      );
      _records[index] = updatedRecord;
      try {
        await _persistAndNotify();
      } catch (_) {
        // A failed write must not leave an in-memory identity that makes the
        // next retry look like an already durable interaction.
        _records[index] = record;
        rethrow;
      }
    });
  }

  /// Applies foreground facts through the same deterministic engine used by
  /// tests and future background workers.
  Future<TriggerOutcome> evaluatePlan(
    String planId, {
    required TriggerEvaluationContext context,
  }) {
    _requireInitialized();
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      final record = _records[index];
      final outcome = _engine.evaluate(
        plan: record.plan,
        context: context,
        state: record.runtimeState,
      );
      final plan = outcome.shouldFire
          ? record.plan
          : record.plan.copyWith(lifecycle: outcome.nextLifecycle);
      final runtimeState = outcome.shouldFire
          ? record.runtimeState.copyWith(
              wasInsideLocation: outcome.nextState.wasInsideLocation,
              reentrySequence: outcome.nextState.reentrySequence,
            )
          : outcome.nextState;
      final events = <TriggerPlanEvent>[...record.events];
      if (outcome.shouldFire) {
        final metadata = _mergeEventMetadata(record.plan, <String, Object?>{
          if (outcome.deliveryKey != null) ...<String, Object?>{
            'deliveryKey': outcome.deliveryKey!,
            'eventKey': outcome.deliveryKey!,
          },
          'source': 'foreground-engine',
        });
        if (!_containsEventIdentity(
          events,
          TriggerPlanEventKind.eligible,
          metadata,
        )) {
          events.add(
            _event(
              planId,
              TriggerPlanEventKind.eligible,
              outcome.evaluatedAt,
              metadata: metadata,
            ),
          );
        }
      }
      _records[index] = record.copyWith(
        plan: plan,
        runtimeState: runtimeState,
        events: events,
      );
      await _persistAndNotify();
      return outcome;
    });
  }

  NativeTriggerOpen? consumePendingOpen() {
    final value = _pendingOpen;
    if (value != null) {
      _consumedOpenEventIds.add(value.eventId);
      _pendingOpen = null;
      _notify();
    }
    return value;
  }

  void clearLastError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  Future<void> _changeLifecycle(
    String planId, {
    required PlanLifecycle lifecycle,
    required TriggerPlanEventKind eventKind,
    required bool reschedule,
  }) {
    _requireInitialized();
    return _exclusive(() async {
      final index = _requiredRecordIndex(planId);
      final record = _records[index];
      if (record.plan.lifecycle == lifecycle) return;
      if (record.plan.lifecycle == PlanLifecycle.completed ||
          record.plan.lifecycle == PlanLifecycle.expired) {
        throw StateError('A completed or expired plan cannot change state.');
      }
      final now = _clock();
      final plan = _withLifecycle(record.plan, lifecycle, now);
      _records[index] = record.copyWith(
        plan: plan,
        events: <TriggerPlanEvent>[
          ...record.events,
          _event(planId, eventKind, now),
        ],
      );
      await _persistAndNotify();
      if (reschedule) await _scheduleAndRecord(plan);
    });
  }

  Future<void> _scheduleAndRecord(Plan plan, {bool resetState = false}) async {
    final now = _clock();
    try {
      final result = await _scheduler.schedulePlan(
        plan,
        resetState: resetState,
      );
      final record = recordById(plan.id)!;
      final shouldRecordNotificationDisabled =
          result.notificationPermissionGranted == false &&
          _latestNotificationPermissionState(record.events) != false;
      final success =
          result.status == 'registered' || result.status == 'saved_disabled';
      final kind = success
          ? TriggerPlanEventKind.scheduled
          : TriggerPlanEventKind.failed;
      _appendEvent(
        plan.id,
        _event(
          plan.id,
          kind,
          now,
          metadata: <String, Object?>{
            'nativeStatus': result.status,
            if (result.notificationPermissionGranted != null)
              'notificationPermissionGranted':
                  result.notificationPermissionGranted!,
          },
        ),
      );
      if (shouldRecordNotificationDisabled) {
        _appendEvent(
          plan.id,
          _event(
            plan.id,
            TriggerPlanEventKind.notificationDisabled,
            now,
            metadata: _mergeEventMetadata(plan, <String, Object?>{
              'notificationPermissionGranted': false,
              'nativeStatus': result.status,
              'source': 'native-scheduler',
            }),
          ),
        );
      }
      await _persistAndNotify();
    } catch (error) {
      _rememberError(error);
      _appendEvent(
        plan.id,
        _event(
          plan.id,
          TriggerPlanEventKind.failed,
          now,
          metadata: <String, Object?>{'error': error.toString()},
        ),
      );
      await _persistAndNotify();
    }
  }

  Future<void> _syncPlansAndRecordPermission() async {
    final report = await _scheduler.syncPlans(
      _records.map((record) => record.plan),
    );
    final permissionGranted = report.notificationPermissionGranted;
    if (permissionGranted == null) return;

    final now = _clock();
    var changed = false;
    for (var index = 0; index < _records.length; index += 1) {
      final record = _records[index];
      if (_latestNotificationPermissionState(record.events) ==
          permissionGranted) {
        continue;
      }
      final kind = permissionGranted
          ? TriggerPlanEventKind.scheduled
          : TriggerPlanEventKind.notificationDisabled;
      _records[index] = record.copyWith(
        events: <TriggerPlanEvent>[
          ...record.events,
          _event(
            record.plan.id,
            kind,
            now,
            metadata: <String, Object?>{
              'notificationPermissionGranted': permissionGranted,
              'nativeStatus': report.status,
              'source': 'native-sync',
            },
          ),
        ],
      );
      changed = true;
    }
    if (changed) await _persistAndNotify();
  }

  void _bindSchedulerStreams() {
    _openedSubscription ??= _scheduler.opened.listen(
      (open) => unawaited(_applyNativeOpens(<NativeTriggerOpen>[open])),
      onError: _rememberError,
    );
    _opensSubscription ??= _scheduler.opensChanged.listen(
      (opens) => unawaited(_applyNativeOpens(opens)),
      onError: _rememberError,
    );
    _outcomesSubscription ??= _scheduler.outcomesChanged.listen(
      (outcomes) => unawaited(_applyNativeOutcomes(outcomes)),
      onError: _rememberError,
    );
  }

  Future<void> _applyNativeOutcomes(List<NativeTriggerOutcome> outcomes) {
    return _exclusive(() async {
      final acknowledgedIds = <String>[];
      final completedPlanIds = <String>{};
      var changed = false;
      for (final outcome in outcomes) {
        acknowledgedIds.add(outcome.eventId);
        final index = _recordIndex(outcome.ruleId);
        if (index == -1) continue;
        final record = _records[index];
        final kind = switch (outcome.kind) {
          NativeTriggerOutcomeKind.fired => TriggerPlanEventKind.fired,
          NativeTriggerOutcomeKind.done => TriggerPlanEventKind.completed,
          NativeTriggerOutcomeKind.later => TriggerPlanEventKind.snoozed,
        };
        if (_containsNativeEvent(
          record.events,
          outcome.eventId,
          kind: kind,
          eventKey: outcome.eventKey,
        )) {
          continue;
        }

        var plan = record.plan;
        var runtime = record.runtimeState;
        final eventKey = _normalizedIdentifier(outcome.eventKey);
        final metadata = _mergeEventMetadata(plan, <String, Object?>{
          'nativeEventId': outcome.eventId,
          'eventKey': ?eventKey,
          if (outcome.snoozedUntil != null)
            'snoozedUntil': outcome.snoozedUntil!.toIso8601String(),
          'source': 'native',
        });
        switch (outcome.kind) {
          case NativeTriggerOutcomeKind.fired:
            runtime = runtime.copyWith(
              lastFiredAt: outcome.occurredAt,
              fireCount: runtime.fireCount + 1,
              deliveredDedupeKeys: <String>{
                ...runtime.deliveredDedupeKeys,
                ?eventKey,
              },
            );
            if (plan.rule.recurrence == TriggerRecurrence.once) {
              plan = plan.copyWith(lifecycle: PlanLifecycle.fired);
            }
          case NativeTriggerOutcomeKind.done:
            plan = plan.copyWith(lifecycle: PlanLifecycle.completed);
            completedPlanIds.add(plan.id);
          case NativeTriggerOutcomeKind.later:
            plan = plan.copyWith(
              lifecycle: PlanLifecycle.active,
              metadata: <String, Object?>{
                ...plan.metadata,
                if (outcome.snoozedUntil != null)
                  'snoozedUntil': outcome.snoozedUntil!.toIso8601String(),
                'updatedAt': outcome.occurredAt.toIso8601String(),
              },
            );
        }
        _records[index] = record.copyWith(
          plan: plan,
          runtimeState: runtime,
          events: <TriggerPlanEvent>[
            ...record.events,
            TriggerPlanEvent(
              id: 'native-${outcome.eventId}',
              planId: plan.id,
              kind: kind,
              occurredAt: outcome.occurredAt,
              metadata: metadata,
            ),
          ],
        );
        changed = true;
      }
      if (changed) await _persistAndNotify();
      for (final id in completedPlanIds) {
        await _safeCancel(id);
      }
      if (acknowledgedIds.isNotEmpty) {
        await _scheduler.acknowledgeOutcomes(acknowledgedIds);
      }
    });
  }

  Future<void> _applyNativeOpens(List<NativeTriggerOpen> opens) {
    return _exclusive(() async {
      final acknowledgedIds = <String>[];
      var changed = false;
      for (final open in opens) {
        acknowledgedIds.add(open.eventId);
        final index = _recordIndex(open.ruleId);
        if (index != -1) {
          final record = _records[index];
          if (!_containsNativeEvent(record.events, open.eventId)) {
            _records[index] = record.copyWith(
              events: <TriggerPlanEvent>[
                ...record.events,
                TriggerPlanEvent(
                  id: 'native-open-${open.eventId}',
                  planId: open.ruleId,
                  kind: TriggerPlanEventKind.opened,
                  occurredAt: open.occurredAt,
                  metadata: _mergeEventMetadata(record.plan, <String, Object?>{
                    'nativeEventId': open.eventId,
                    'destinationId': open.destinationId,
                    'source': 'native',
                  }),
                ),
              ],
            );
            changed = true;
          }
          if (!_consumedOpenEventIds.contains(open.eventId)) {
            _pendingOpen = open;
          }
        }
      }
      if (changed) {
        await _persistAndNotify();
      } else if (opens.any((open) => _recordIndex(open.ruleId) != -1)) {
        _notify();
      }
      if (acknowledgedIds.isNotEmpty) {
        await _scheduler.acknowledgeOpens(acknowledgedIds);
      }
    });
  }

  Future<List<NativeTriggerOutcome>> _safePendingOutcomes() async {
    try {
      return await _scheduler.pendingOutcomes();
    } catch (error) {
      _rememberError(error);
      return const <NativeTriggerOutcome>[];
    }
  }

  Future<List<NativeTriggerOpen>> _safePendingOpens() async {
    try {
      return await _scheduler.pendingOpens();
    } catch (error) {
      _rememberError(error);
      return const <NativeTriggerOpen>[];
    }
  }

  Future<void> _safeCancel(String planId) async {
    try {
      await _scheduler.cancelPlan(planId);
    } catch (error) {
      _rememberError(error);
    }
  }

  Future<ResolvedTriggerLocation?> _resolveDraftLocation(
    PlanDraft draft,
  ) async {
    final usesLocation =
        draft.triggerKind == PlanDraftTriggerKind.location ||
        draft.triggerKind == PlanDraftTriggerKind.timeAndLocation;
    if (!usesLocation) return null;
    final query = draft.locationQuery?.trim() ?? '';
    final resolved = await _scheduler.resolveLocation(query);
    if (resolved == null) throw PlanLocationResolutionException(query);
    return resolved;
  }

  TriggerCondition _conditionFromDraft(
    PlanDraft draft,
    ResolvedTriggerLocation? resolved,
  ) {
    final conditions = <TriggerCondition>[];
    final usesTime =
        draft.triggerKind == PlanDraftTriggerKind.time ||
        draft.triggerKind == PlanDraftTriggerKind.timeAndLocation;
    if (usesTime) {
      conditions.add(_timeConditionFromDraft(draft));
    }
    if (resolved != null) {
      conditions.add(
        LocationCondition(
          center: resolved.point,
          radiusMeters: locationRadiusMeters,
        ),
      );
    }
    if (conditions.length == 1) return conditions.single;
    return AndCondition(conditions: conditions);
  }

  /// The condition fires at the *notification* time, not the plan's own time.
  ///
  /// Those parted company when the lead time arrived. Everything the reader
  /// reads — the countdown, a to-do's deadline — is measured from the plan's
  /// time, which is why it is written to metadata rather than being read back
  /// out of this condition.
  TimeCondition _timeConditionFromDraft(PlanDraft draft) {
    final scheduledAt = draft.notifyAt;
    if (scheduledAt == null) {
      throw StateError('A time plan requires scheduledAt.');
    }
    if (draft.recurrence == PlanDraftRecurrence.once) {
      return TimeCondition(
        notBefore: scheduledAt,
        notAfter: scheduledAt.add(const Duration(hours: 1)),
      );
    }
    final start = ClockTime(hour: scheduledAt.hour, minute: scheduledAt.minute);
    final end = ClockTime.fromMinutesSinceMidnight(
      (start.minutesSinceMidnight + 15) % ClockTime.minutesPerDay,
    );
    return TimeCondition(
      notBefore: scheduledAt,
      windowStart: start,
      windowEnd: end,
      weekdays: draft.recurrence == PlanDraftRecurrence.weekly
          ? <int>{scheduledAt.weekday}
          : const <int>{},
    );
  }

  /// When the plan stops being live.
  ///
  /// Measured from the plan's own time, not the notification's. A dinner
  /// tonight whose reminder fired at five is still tonight's dinner at six, and
  /// expiring it the moment the alarm went off would file it under 지난 계획
  /// while the reader is on their way.
  ///
  /// A plan that spans days lives to the end of its last one. Without this a
  /// five-day trip expired on the afternoon of day one.
  DateTime? _expiryFromDraft(PlanDraft draft) {
    if (draft.recurrence != PlanDraftRecurrence.once) return null;
    final scheduledAt = draft.scheduledAt;
    if (scheduledAt == null) return null;
    if (draft.endsAt case final endsAt?) {
      final lastDay = DateTime(endsAt.year, endsAt.month, endsAt.day);
      if (lastDay.isAfter(scheduledAt)) {
        return lastDay.add(const Duration(days: 1));
      }
    }
    return scheduledAt.add(const Duration(hours: 1));
  }

  String _notificationBody(PlanDraft draft, ResolvedTriggerLocation? resolved) {
    if (resolved != null && draft.scheduledAt != null) {
      return '${resolved.formattedAddress} · 지금 확인해 볼까요?';
    }
    if (resolved != null) {
      return '${resolved.formattedAddress} 근처예요. 지금 확인해 볼까요?';
    }
    return '기억해 둔 시간이 됐어요. 지금 확인해 볼까요?';
  }

  Plan _withLifecycle(Plan plan, PlanLifecycle lifecycle, DateTime now) {
    return plan.copyWith(
      lifecycle: lifecycle,
      metadata: <String, Object?>{
        ...plan.metadata,
        'updatedAt': now.toIso8601String(),
      },
    );
  }

  TriggerCondition _delayCondition(TriggerCondition condition, DateTime until) {
    switch (condition) {
      case TimeCondition():
        final delayedStart = _laterDate(condition.notBefore, until);
        final originalStart = condition.notBefore;
        final originalEnd = condition.notAfter;
        final delayedEnd =
            originalStart != null &&
                originalEnd != null &&
                delayedStart.isAfter(originalStart)
            ? delayedStart.add(originalEnd.difference(originalStart))
            : originalEnd;
        return TimeCondition(
          notBefore: delayedStart,
          notAfter: delayedEnd,
          windowStart: condition.windowStart,
          windowEnd: condition.windowEnd,
          weekdays: condition.weekdays,
        );
      case LocationCondition():
        return AndCondition(
          conditions: <TriggerCondition>[
            condition,
            TimeCondition(notBefore: until),
          ],
        );
      case AndCondition(:final conditions):
        final hasTime = conditions.any((child) => child is TimeCondition);
        if (!hasTime) {
          return AndCondition(
            conditions: <TriggerCondition>[
              ...conditions,
              TimeCondition(notBefore: until),
            ],
          );
        }
        return AndCondition(
          conditions: conditions
              .map(
                (child) => child is TimeCondition
                    ? _delayCondition(child, until)
                    : child,
              )
              .toList(growable: false),
        );
    }
  }

  PlanListItem _toListItem(PersistedTriggerPlan record) {
    final plan = record.plan;
    return PlanListItem(
      id: plan.id,
      title: plan.title,
      status: _listStatus(plan),
      triggerLabel: _triggerLabel(plan),
      recurrenceLabel: _recurrenceLabel(plan.rule.recurrence),
      sourceLabel: plan.metadata['sourceCaptureId'] is String
          ? '연결된 콘텐츠'
          : null,
      startsAt: planStartsAt(plan),
      endsAt: _dateMetadata(plan.metadata['endsAt']),
      todos: _todosOf(plan),
    );
  }

  /// When the plan happens, as against when its notification fires.
  ///
  /// Metadata first, condition second. The condition holds when the alarm goes
  /// off, which is the plan's own time only when there is no lead. The fallback
  /// is for plans made before the two parted.
  ///
  /// Every reader of the plan's own time goes through here. Asking the
  /// condition directly is how a card and the screen behind it came to print
  /// different deadlines for the same to-do: a day's lead moved one of them and
  /// not the other, and both looked right on their own.
  static DateTime? planStartsAt(Plan plan) =>
      _dateMetadata(plan.metadata['scheduledAt']) ??
      _timeCondition(plan.rule.condition)?.notBefore;

  static DateTime? _dateMetadata(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value);
  }

  static List<PlanTodoSuggestion> _todosOf(Plan plan) {
    final raw = plan.metadata['todos'];
    if (raw is! List) return const <PlanTodoSuggestion>[];
    final todos = <PlanTodoSuggestion>[];
    for (final entry in raw) {
      final todo = PlanTodoSuggestion.fromJson(entry);
      if (todo != null) todos.add(todo);
    }
    return List<PlanTodoSuggestion>.unmodifiable(todos);
  }

  PlanListStatus _listStatus(Plan plan) {
    if (plan.lifecycle == PlanLifecycle.completed ||
        plan.lifecycle == PlanLifecycle.expired) {
      return PlanListStatus.completed;
    }
    if (plan.lifecycle == PlanLifecycle.draft ||
        plan.lifecycle == PlanLifecycle.paused) {
      return PlanListStatus.upcoming;
    }
    // The plan's own time, not the alarm's. A week's lead would otherwise make
    // a plan 활성 a week before the day it is about.
    final startsAt = planStartsAt(plan);
    if (startsAt != null && startsAt.isAfter(_clock())) {
      return PlanListStatus.upcoming;
    }
    return PlanListStatus.active;
  }

  String _triggerLabel(Plan plan) {
    final time = _timeCondition(plan.rule.condition);
    final location = _locationCondition(plan.rule.condition);
    final parts = <String>[];
    if (location != null) {
      final address = plan.metadata['formattedAddress'];
      parts.add(
        address is String && address.trim().isNotEmpty
            ? address.trim()
            : '${location.radiusMeters.round()}m 안에 들어오면',
      );
    }
    if (time != null) {
      parts.add(_timeLabel(time, plan.rule.recurrence, planStartsAt(plan)));
    }
    return parts.isEmpty ? '조건을 확인하고 있어요' : parts.join(' · ');
  }

  /// [startsAt] is when the plan happens; [time] is when it fires. A card says
  /// when the dinner is, not when it will be mentioned.
  String _timeLabel(
    TimeCondition time,
    TriggerRecurrence recurrence,
    DateTime? startsAt,
  ) {
    // The window and the weekday are both cut from the alarm's clock, so a
    // repeating plan with a lead would announce the wrong hour — and, once the
    // lead crosses midnight, the wrong day of the week along with it.
    final clock = startsAt == null
        ? time.windowStart
        : ClockTime(hour: startsAt.hour, minute: startsAt.minute);
    final clockLabel = clock == null ? null : _clockLabel(clock);
    final weekday = startsAt?.weekday ?? time.weekdays.firstOrNull;
    return switch (recurrence) {
      TriggerRecurrence.once =>
        startsAt == null ? (clockLabel ?? '한 번만') : _dateTimeLabel(startsAt),
      TriggerRecurrence.daily => '매일 ${clockLabel ?? ''}'.trim(),
      TriggerRecurrence.weekly =>
        '매주 ${_weekdayLabel(weekday)} ${clockLabel ?? ''}'.trim(),
      TriggerRecurrence.onReentry =>
        clockLabel == null ? '다시 방문할 때' : '$clockLabel 무렵 다시 방문할 때',
    };
  }

  static String _recurrenceLabel(TriggerRecurrence recurrence) =>
      switch (recurrence) {
        TriggerRecurrence.once => '한 번',
        TriggerRecurrence.daily => '매일',
        TriggerRecurrence.weekly => '매주',
        TriggerRecurrence.onReentry => '재방문',
      };

  static String _dateTimeLabel(DateTime value) =>
      '${value.month}월 ${value.day}일 '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _clockLabel(ClockTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _weekdayLabel(int? weekday) => switch (weekday) {
    DateTime.monday => '월요일',
    DateTime.tuesday => '화요일',
    DateTime.wednesday => '수요일',
    DateTime.thursday => '목요일',
    DateTime.friday => '금요일',
    DateTime.saturday => '토요일',
    DateTime.sunday => '일요일',
    _ => '',
  };

  static TimeCondition? _timeCondition(TriggerCondition condition) {
    return switch (condition) {
      TimeCondition() => condition,
      LocationCondition() => null,
      AndCondition(:final conditions) =>
        conditions.whereType<TimeCondition>().firstOrNull,
    };
  }

  static LocationCondition? _locationCondition(TriggerCondition condition) {
    return switch (condition) {
      LocationCondition() => condition,
      TimeCondition() => null,
      AndCondition(:final conditions) =>
        conditions.whereType<LocationCondition>().firstOrNull,
    };
  }

  static TriggerRecurrence _recurrenceFromDraft(
    PlanDraftRecurrence recurrence,
  ) => switch (recurrence) {
    PlanDraftRecurrence.once => TriggerRecurrence.once,
    PlanDraftRecurrence.daily => TriggerRecurrence.daily,
    PlanDraftRecurrence.weekly => TriggerRecurrence.weekly,
    PlanDraftRecurrence.onReentry => TriggerRecurrence.onReentry,
  };

  static Duration _defaultCooldown(TriggerRecurrence recurrence) =>
      switch (recurrence) {
        TriggerRecurrence.once => Duration.zero,
        TriggerRecurrence.daily ||
        TriggerRecurrence.weekly => const Duration(hours: 1),
        TriggerRecurrence.onReentry => const Duration(minutes: 30),
      };

  void _appendEvent(String planId, TriggerPlanEvent event) {
    final index = _requiredRecordIndex(planId);
    final record = _records[index];
    _records[index] = record.copyWith(
      events: <TriggerPlanEvent>[...record.events, event],
    );
  }

  TriggerPlanEvent _event(
    String planId,
    TriggerPlanEventKind kind,
    DateTime occurredAt, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _eventSequence += 1;
    final index = _recordIndex(planId);
    final eventMetadata = index == -1
        ? metadata
        : _mergeEventMetadata(_records[index].plan, metadata);
    return TriggerPlanEvent(
      id:
          '$planId-${kind.name}-${occurredAt.microsecondsSinceEpoch}-'
          '$_eventSequence',
      planId: planId,
      kind: kind,
      occurredAt: occurredAt,
      metadata: eventMetadata,
    );
  }

  bool _containsNativeEvent(
    List<TriggerPlanEvent> events,
    String eventId, {
    TriggerPlanEventKind? kind,
    String? eventKey,
  }) {
    if (events.any((event) => event.metadata['nativeEventId'] == eventId)) {
      return true;
    }
    final normalizedEventKey = _normalizedIdentifier(eventKey);
    return kind != null &&
        normalizedEventKey != null &&
        events.any(
          (event) =>
              event.kind == kind &&
              _normalizedIdentifier(event.metadata['eventKey']) ==
                  normalizedEventKey,
        );
  }

  bool _containsEventIdentity(
    List<TriggerPlanEvent> events,
    TriggerPlanEventKind kind,
    Map<String, Object?> metadata,
  ) {
    for (final key in _eventIdentityMetadataKeys) {
      final value = _normalizedIdentifier(metadata[key]);
      if (value == null) continue;
      if (events.any(
        (event) =>
            event.kind == kind &&
            _normalizedIdentifier(event.metadata[key]) == value,
      )) {
        return true;
      }
    }
    return false;
  }

  bool? _latestNotificationPermissionState(List<TriggerPlanEvent> events) {
    for (final event in events.reversed) {
      final permission = event.metadata['notificationPermissionGranted'];
      if (permission is bool) return permission;
      if (event.kind == TriggerPlanEventKind.notificationDisabled) {
        return false;
      }
    }
    return null;
  }

  Map<String, Object?> _mergeEventMetadata(
    Plan plan,
    Map<String, Object?> metadata,
  ) {
    final merged = <String, Object?>{};
    for (final entry in metadata.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      final safeValue = _jsonSafeMetadataValue(
        entry.value,
        Set<Object>.identity(),
      );
      if (!identical(safeValue, _invalidMetadataValue)) {
        merged[key] = safeValue;
      }
    }

    for (final key in _planContextMetadataKeys) {
      final planValue = _normalizedIdentifier(plan.metadata[key]);
      if (planValue != null) {
        merged[key] = planValue;
      } else {
        final callerValue = _normalizedIdentifier(merged[key]);
        if (callerValue == null) {
          merged.remove(key);
        } else {
          merged[key] = callerValue;
        }
      }
    }
    for (final key in _eventIdentityMetadataKeys) {
      final value = _normalizedIdentifier(merged[key]);
      if (value == null) {
        merged.remove(key);
      } else {
        merged[key] = value;
      }
    }
    return merged;
  }

  int _recordIndex(String planId) =>
      _records.indexWhere((record) => record.plan.id == planId);

  int _requiredRecordIndex(String planId) {
    final index = _recordIndex(planId);
    if (index == -1) throw StateError('Unknown plan: $planId');
    return index;
  }

  String _uniquePlanId(DateTime now) {
    final base = _idFactory(now).trim();
    if (base.isEmpty) throw StateError('The plan id factory returned blank.');
    if (_recordIndex(base) == -1) return base;
    var suffix = 2;
    while (_recordIndex('$base-$suffix') != -1) {
      suffix += 1;
    }
    return '$base-$suffix';
  }

  Future<void> _persistAndNotify() async {
    await _store.save(List<PersistedTriggerPlan>.unmodifiable(_records));
    _notify();
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        _rememberError(error);
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('PlanController.initialize() must finish first.');
    }
  }

  void _rememberError(Object error) {
    _lastError = error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_openedSubscription?.cancel());
    unawaited(_opensSubscription?.cancel());
    unawaited(_outcomesSubscription?.cancel());
    if (closeSchedulerOnDispose) unawaited(_scheduler.close());
    super.dispose();
  }

  static String _defaultIdFactory(DateTime now) =>
      'plan-${now.microsecondsSinceEpoch}';
}

DateTime _laterDate(DateTime? first, DateTime second) {
  if (first == null || second.isAfter(first)) return second;
  return first;
}

String? _normalizedIdentifier(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

const Object _invalidMetadataValue = Object();

Object? _jsonSafeMetadataValue(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    return value.isFinite ? value : _invalidMetadataValue;
  }
  if (value is List<Object?>) {
    if (!ancestors.add(value)) return _invalidMetadataValue;
    try {
      final result = <Object?>[];
      for (final child in value) {
        final safeChild = _jsonSafeMetadataValue(child, ancestors);
        if (identical(safeChild, _invalidMetadataValue)) {
          return _invalidMetadataValue;
        }
        result.add(safeChild);
      }
      return result;
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map<Object?, Object?>) {
    if (!ancestors.add(value)) return _invalidMetadataValue;
    try {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) return _invalidMetadataValue;
        final safeChild = _jsonSafeMetadataValue(entry.value, ancestors);
        if (identical(safeChild, _invalidMetadataValue)) {
          return _invalidMetadataValue;
        }
        result[key] = safeChild;
      }
      return result;
    } finally {
      ancestors.remove(value);
    }
  }
  return _invalidMetadataValue;
}
