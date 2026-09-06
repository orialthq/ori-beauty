import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/app_snapshot_store.dart';
import '../data/content_analysis_service.dart';
import '../data/demo_catalog.dart';
import '../data/development_backup_service.dart';
import '../data/incoming_share_service.dart';
import '../data/portable_tip_importer.dart';
import '../data/portable_tip_service.dart';
import '../data/place_enrichment_service.dart';
import '../data/place_map_links.dart';
import '../data/remote_content_analysis_service.dart';
import '../data/tag_merge_service.dart';
import '../data/tag_sense_service.dart';
import '../domain/models.dart';
import '../domain/tag_key.dart';
import '../domain/portable_tip_package.dart';

/// One durable incoming-share import transaction.
///
/// A gallery picker can place up to 100 one-image shares in the native inbox
/// at once. The captures still remain independent for storage and analysis,
/// but the UI should react to that transaction once instead of navigating once
/// per image.
@immutable
final class IncomingCaptureBatch {
  IncomingCaptureBatch(Iterable<String> captureIds)
    : captureIds = List<String>.unmodifiable(captureIds) {
    assert(this.captureIds.isNotEmpty);
  }

  final List<String> captureIds;

  /// Matches the capture that the previous per-image event loop ultimately
  /// left visible after processing every event in insertion order.
  String get primaryCaptureId => captureIds.last;
}

final class AppController extends ChangeNotifier {
  AppController(
    this._incomingShareService, [
    this._contentAnalysisService = const BaselineContentAnalysisService(),
    AppSnapshotStore? snapshotStore,
    this._portableTipInbox,
    this._placeEnrichmentService = const NoPlaceEnrichmentService(),
    this._tagMergeService = const NoTagMergeService(),
    this._tagSenseService = const NoTagSenseService(),
    DevelopmentBackupService? developmentBackupService,
  ]) : _captures = [...DemoCatalog.captures],
       _groups = [...DemoCatalog.groups],
       _snapshotStore = snapshotStore ?? InMemoryAppSnapshotStore(),
       _developmentBackupService =
           developmentBackupService ?? const DevelopmentBackupService();

  final IncomingShareService _incomingShareService;
  final ContentAnalysisService _contentAnalysisService;
  final AppSnapshotStore _snapshotStore;
  final PortableTipInbox? _portableTipInbox;
  final PlaceEnrichmentService _placeEnrichmentService;
  final TagMergeService _tagMergeService;
  final TagSenseService _tagSenseService;
  final DevelopmentBackupService _developmentBackupService;

  /// The sense dictionary: [tagKey] to the words that lead to that tag, the
  /// thing "매운거" is matched against. Filled in the background, one ask per
  /// tag ever — an empty list is a real answer meaning "asked, nothing
  /// useful" and stops the asking.
  final Map<String, List<String>> _tagSenses = {};
  var _tagSensesInFlight = false;
  var _tagSensesQueued = false;
  final List<CaptureRecord> _captures;
  final List<ProductGroup> _groups;
  final Set<String> _durablySavedTransportIds = {};

  /// Captures this session already looked up on the web, so a place that
  /// returned nothing is not searched again on every rebuild.
  final Set<String> _attemptedPlaceEnrichment = {};
  final Set<String> _sourceDeletionAvailableCaptureIds = {};
  final Map<String, _PendingPortableTip> _pendingPortableTips = {};
  final StreamController<IncomingCaptureBatch> _incomingCaptureController =
      StreamController<IncomingCaptureBatch>.broadcast();
  final StreamController<String> _portableTipController =
      StreamController<String>.broadcast();

  StreamSubscription<void>? _incomingSubscription;
  StreamSubscription<void>? _portableTipSubscription;
  Future<void> _snapshotWriteTail = Future<void>.value();
  Future<void> _incomingDrainTail = Future<void>.value();
  Future<void> _analysisTail = Future<void>.value();
  Future<void> _portableTipDrainTail = Future<void>.value();
  final Set<String> _queuedAnalysisIds = {};
  CaptureFilter _filter = CaptureFilter.all;
  Future<void>? _initialization;

  List<CaptureRecord> get captures => List.unmodifiable(_captures);
  List<ProductGroup> get groups => List.unmodifiable(_groups);
  CaptureFilter get filter => _filter;
  Stream<IncomingCaptureBatch> get incomingCaptureAdded =>
      _incomingCaptureController.stream;
  Stream<String> get portableTipReceived => _portableTipController.stream;

  PortableTipPackage? pendingPortableTip(String transportId) =>
      _pendingPortableTips[transportId]?.tip;

  /// What other people sent that is still waiting to be decided on.
  ///
  /// Newest first, by when the sender exported it — the only time these carry.
  /// Nothing here has touched 정리함 yet, which is the whole point of the tab:
  /// receiving something is not the same as keeping it.
  ///
  /// This survives a restart without being written anywhere. The native inbox
  /// holds an envelope until it is accepted or discarded, so anything still
  /// undecided is handed over again on the next launch.
  List<SharedTipEntry> get sharedInbox {
    final entries = <SharedTipEntry>[
      for (final entry in _pendingPortableTips.entries)
        SharedTipEntry(transportId: entry.key, tip: entry.value.tip),
    ];
    entries.sort(
      (first, second) => second.tip.exportedAt.compareTo(first.tip.exportedAt),
    );
    return List<SharedTipEntry>.unmodifiable(entries);
  }

  List<CaptureRecord> get filteredCaptures {
    return _captures
        .where((capture) {
          return switch (_filter) {
            CaptureFilter.all => true,
            CaptureFilter.needsReview =>
              capture.status == CaptureStatus.needsReview,
            CaptureFilter.organized =>
              capture.status == CaptureStatus.organized,
            CaptureFilter.limitedOrFailed =>
              capture.status == CaptureStatus.sourceLimited ||
                  capture.status == CaptureStatus.failed,
          };
        })
        .toList(growable: false);
  }

  int get needsReviewCount => _captures
      .where((capture) => capture.status == CaptureStatus.needsReview)
      .length;

  int get analyzingCount => _captures
      .where((capture) => capture.status == CaptureStatus.analyzing)
      .length;

  int get organizedCount => _captures
      .where((capture) => capture.status == CaptureStatus.organized)
      .length;

  int get limitedOrFailedCount => _captures
      .where(
        (capture) =>
            capture.status == CaptureStatus.sourceLimited ||
            capture.status == CaptureStatus.failed,
      )
      .length;

  CaptureRecord? captureById(String id) {
    for (final capture in _captures) {
      if (capture.raw.id == id) {
        return capture;
      }
    }
    return null;
  }

  bool canQuickOrganize(String captureId) {
    final capture = captureById(captureId);
    if (capture == null || capture.status != CaptureStatus.needsReview) {
      return false;
    }
    if (capture.analysis?.structuredContent != null) {
      return true;
    }
    return _quickOrganizationIdentity(capture.primaryMention) != null;
  }

  Future<bool> quickOrganize(String captureId) async {
    final capture = captureById(captureId);
    if (capture == null || !canQuickOrganize(captureId)) {
      return false;
    }

    final previousCaptures = List<CaptureRecord>.of(_captures);
    final previousGroups = List<ProductGroup>.of(_groups);
    final structured = capture.analysis?.structuredContent;
    CaptureRecord? organizedCapture;
    if (structured != null) {
      organizedCapture = _applyStructuredOrganization(captureId);
    } else {
      final identity = _quickOrganizationIdentity(capture.primaryMention)!;
      organizedCapture = _applyProductOrganization(
        captureId: captureId,
        identity: identity,
      );
    }
    if (organizedCapture == null) {
      return false;
    }

    final saved = await _persistState();
    if (!saved) {
      _captures
        ..clear()
        ..addAll(previousCaptures);
      _groups
        ..clear()
        ..addAll(previousGroups);
      return false;
    }

    notifyListeners();
    await _acknowledgeAfterDurableSave(organizedCapture);
    unawaited(_topUpTagSenses());
    return true;
  }

  Future<bool> deleteCapture(String captureId) async {
    final captureIndex = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (captureIndex == -1) {
      return false;
    }

    final previousCaptures = List<CaptureRecord>.of(_captures);
    final previousGroups = List<ProductGroup>.of(_groups);
    final sourceDeletionWasAvailable = _sourceDeletionAvailableCaptureIds
        .remove(captureId);
    final deletedCapture = _captures.removeAt(captureIndex);
    _removeCaptureFromGroups(captureId);

    final saved = await _persistState();
    if (!saved) {
      _captures
        ..clear()
        ..addAll(previousCaptures);
      _groups
        ..clear()
        ..addAll(previousGroups);
      if (sourceDeletionWasAvailable) {
        _sourceDeletionAvailableCaptureIds.add(captureId);
      }
      return false;
    }

    notifyListeners();
    if (sourceDeletionWasAvailable) {
      try {
        await _incomingShareService.keepSharedSource(
          deletedCapture.raw.transportEventId,
        );
      } catch (error, stackTrace) {
        debugPrint('Shared source keep failed: $error\n$stackTrace');
      }
    }
    await _deleteUnreferencedManagedAttachments(deletedCapture);
    return true;
  }

  int get userCaptureCount => _captures
      .where((capture) => capture.raw.origin != CaptureOrigin.demo)
      .length;

  /// Makes a portable development backup of reader-imported content only.
  ///
  /// Demo samples are intentionally omitted. The manifest is the exact same
  /// logical snapshot the app persists, while the backup service replaces
  /// device-local image paths with paths inside the ZIP before sharing it.
  Future<File> shareDevelopmentBackup() {
    final captures = _captures
        .where((capture) => capture.raw.origin != CaptureOrigin.demo)
        .toList(growable: false);
    final persisted = [
      for (final capture in captures)
        PersistedCapture.fromRecord(
          capture,
          capture.groupId == null ? null : groupById(capture.groupId!),
        ),
    ];
    final tagKeys = <String>{
      for (final capture in captures)
        for (final tag in capture.contentTags) tag.key,
    };
    final senses = <String, List<String>>{
      for (final entry in _tagSenses.entries)
        if (tagKeys.contains(entry.key)) entry.key: entry.value,
    };
    return _developmentBackupService.createAndShare(
      captures: persisted,
      tagSenses: senses,
    );
  }

  /// Deletes reader-imported content while preserving demo samples, plans and
  /// every source image still in the device gallery.
  ///
  /// State is first reduced in memory and then durably saved. Any save failure
  /// rolls every affected collection back before listeners can observe it.
  /// Private retained image copies are removed only after that durable save.
  Future<bool> clearAllUserCaptures() {
    final operation = _incomingDrainTail.then(
      (_) => _clearAllUserCapturesOnce(),
    );
    // A pending-share event arriving while deletion is running chains its
    // drain after this operation. This prevents a partially retained picker
    // batch from reappearing immediately after "전체 삭제" completes.
    _incomingDrainTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Development data reset failed: $error\n$stackTrace');
      },
    );
    return operation;
  }

  Future<bool> _clearAllUserCapturesOnce() async {
    final deletedCaptures = _captures
        .where((capture) => capture.raw.origin != CaptureOrigin.demo)
        .toList(growable: false);
    if (deletedCaptures.isEmpty) return true;

    // A previously failed native acknowledge can leave an envelope behind
    // even though its Dart capture is already durable and analyzed. Remove
    // those envelopes before deleting the durable library state; otherwise a
    // restart could import a just-cleared photo again.
    try {
      await _incomingShareService.acknowledge(
        deletedCaptures.map((capture) => capture.raw.transportEventId),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Development data reset could not clear native envelopes: '
        '$error\n$stackTrace',
      );
      return false;
    }

    final deletedIds = deletedCaptures.map((capture) => capture.raw.id).toSet();
    final previousCaptures = List<CaptureRecord>.of(_captures);
    final previousGroups = List<ProductGroup>.of(_groups);
    final previousTagSenses = Map<String, List<String>>.of(_tagSenses);
    final previousSourceDeletionIds = Set<String>.of(
      _sourceDeletionAvailableCaptureIds,
    );
    final previousAttemptedEnrichmentIds = Set<String>.of(
      _attemptedPlaceEnrichment,
    );
    final previousDurablySavedIds = Set<String>.of(_durablySavedTransportIds);
    final previousFilter = _filter;

    _captures.removeWhere((capture) => deletedIds.contains(capture.raw.id));
    for (final captureId in deletedIds) {
      _removeCaptureFromGroups(captureId);
    }
    _sourceDeletionAvailableCaptureIds.removeAll(deletedIds);
    _attemptedPlaceEnrichment.removeAll(deletedIds);
    _filter = CaptureFilter.all;
    final remainingSenses = _prunedTagSenses();
    _tagSenses
      ..clear()
      ..addAll(remainingSenses);

    final saved = await _persistState();
    if (!saved) {
      _captures
        ..clear()
        ..addAll(previousCaptures);
      _groups
        ..clear()
        ..addAll(previousGroups);
      _tagSenses
        ..clear()
        ..addAll(previousTagSenses);
      _sourceDeletionAvailableCaptureIds
        ..clear()
        ..addAll(previousSourceDeletionIds);
      _attemptedPlaceEnrichment
        ..clear()
        ..addAll(previousAttemptedEnrichmentIds);
      _durablySavedTransportIds
        ..clear()
        ..addAll(previousDurablySavedIds);
      _filter = previousFilter;
      return false;
    }

    notifyListeners();
    for (final capture in deletedCaptures) {
      if (previousSourceDeletionIds.contains(capture.raw.id)) {
        try {
          // Resolve the native choice as "keep". This cleanup must never
          // delete the gallery original during a development data reset.
          await _incomingShareService.keepSharedSource(
            capture.raw.transportEventId,
          );
        } catch (error, stackTrace) {
          debugPrint('Shared source keep failed: $error\n$stackTrace');
        }
      }
      await _deleteUnreferencedManagedAttachments(capture);
    }
    return true;
  }

  bool canDeleteSharedSource(String captureId) =>
      _sourceDeletionAvailableCaptureIds.contains(captureId);

  Future<SharedSourceDeletionResult> deleteSharedSource(
    String captureId,
  ) async {
    final capture = captureById(captureId);
    if (capture == null || !canDeleteSharedSource(captureId)) {
      return SharedSourceDeletionResult.unavailable;
    }
    final result = await _incomingShareService.deleteSharedSource(
      capture.raw.transportEventId,
    );
    _sourceDeletionAvailableCaptureIds.remove(captureId);
    return result;
  }

  Future<void> keepSharedSource(String captureId) async {
    final capture = captureById(captureId);
    if (capture == null) {
      return;
    }
    _sourceDeletionAvailableCaptureIds.remove(captureId);
    await _incomingShareService.keepSharedSource(capture.raw.transportEventId);
  }

  ProductGroup? groupById(String id) {
    for (final group in _groups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  List<CaptureRecord> capturesForGroup(String groupId) {
    return _captures
        .where((capture) => capture.groupId == groupId)
        .toList(growable: false);
  }

  /// Everything the captures filed under this product are tagged with.
  ///
  /// A group has no tags of its own: it is the captures that carry them, and a
  /// product filed from three screenshots is filed under all three sets.
  List<ContentTag> tagsForGroup(String groupId) {
    return dedupedTags([
      for (final capture in _captures)
        if (capture.groupId == groupId) ...capture.contentTags,
    ]);
  }

  /// Every tag in the library, most used first.
  ///
  /// Ties fall back to the name so the order does not shuffle between builds.
  /// This is also the table a later pass will read to decide which near
  /// duplicates are worth merging.
  List<({ContentTag tag, int count})> get tagCounts {
    final counts = <String, int>{};
    final first = <String, ContentTag>{};
    void add(Iterable<ContentTag> tags) {
      for (final tag in tags) {
        counts[tag.value] = (counts[tag.value] ?? 0) + 1;
        first.putIfAbsent(tag.value, () => tag);
      }
    }

    for (final capture in organizedStructuredCaptures) {
      add(capture.contentTags);
    }
    for (final group in _groups) {
      add(tagsForGroup(group.id));
    }

    final ordered = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return List.unmodifiable([
      for (final value in ordered) (tag: first[value]!, count: counts[value]!),
    ]);
  }

  /// The library's words with their counts, most used first, for showing the
  /// analysis what is already in use. Capped where the request is capped.
  List<TagVocabularyEntry> get tagVocabulary => [
    for (final entry in tagCounts.take(
      RemoteContentAnalysisService.maxVocabulary,
    ))
      (value: entry.tag.value, count: entry.count),
  ];

  /// How the library spells each word, by [tagKey].
  ///
  /// [tagCounts] is most-used first, so the first spelling met for a key is
  /// the one under which most things are filed — the spelling that wins when
  /// another arrives.
  Map<String, String> get _spellings {
    final spellings = <String, String>{};
    for (final entry in tagCounts) {
      spellings.putIfAbsent(entry.tag.key, () => entry.tag.value);
    }
    return spellings;
  }

  /// The sense dictionary, read-only, for the search screens to match
  /// against on every keystroke.
  Map<String, List<String>> get tagSenses => UnmodifiableMapView(_tagSenses);

  /// Asks for sense words for any tag that has never been asked about.
  ///
  /// Runs after anything that can put a new word in the library, does nothing
  /// when there is nothing new, and never overlaps itself. A failure is
  /// retried by whatever changes the library next — offline, that is a cheap
  /// refused connection, and the search works from the stored dictionary
  /// meanwhile.
  Future<void> _topUpTagSenses() async {
    // A round already running takes a note rather than being raced: the tag
    // that arrived mid-round is picked up by one more round at the end,
    // instead of being dropped and waiting for the next library change.
    if (_tagSensesInFlight) {
      _tagSensesQueued = true;
      return;
    }
    _tagSensesInFlight = true;
    try {
      do {
        _tagSensesQueued = false;
        final missing = [
          for (final entry in tagVocabulary)
            if (!_tagSenses.containsKey(tagKey(entry.value))) entry,
        ];
        if (missing.isEmpty) return;
        final found = await _tagSenseService.senses(missing);
        // A failed call is not an answer. Whatever changes the library next
        // retries; spinning here would hammer a server that just said no.
        if (found.isEmpty) return;
        // The library may have been reset while the request was in flight.
        // Never let the late answer put deleted-only words back in memory.
        final currentKeys = {
          for (final entry in tagVocabulary) tagKey(entry.value),
        };
        final relevantFound = <String, List<String>>{
          for (final entry in found.entries)
            if (currentKeys.contains(entry.key)) entry.key: entry.value,
        };
        if (relevantFound.isNotEmpty) {
          _tagSenses.addAll(relevantFound);
          notifyListeners();
          await _persistState();
        }
      } while (_tagSensesQueued);
    } finally {
      _tagSensesInFlight = false;
    }
  }

  /// Strikes one word out of a tag's senses, for good.
  ///
  /// The reader saying "매운 does not lead to 이 태그" is a judgement about
  /// their own library, and it sticks: the emptied or shortened list is
  /// stored, and a tag that has an entry is never asked about again.
  Future<void> removeTagSense(String tag, String word) async {
    final key = tagKey(tag);
    final words = _tagSenses[key];
    if (words == null) return;
    final kept = [
      for (final sense in words)
        if (sense != word) sense,
    ];
    if (kept.length == words.length) return;
    _tagSenses[key] = List.unmodifiable(kept);
    notifyListeners();
    await _persistState();
  }

  /// The dictionary trimmed to words the library still has, for storing.
  ///
  /// A merged or renamed-away tag takes its senses with it; keeping them
  /// would grow the snapshot with words nothing can ever match again.
  Map<String, List<String>> _prunedTagSenses() {
    if (_tagSenses.isEmpty) return const {};
    final keep = <String>{
      for (final capture in _captures)
        for (final tag in capture.contentTags) tag.key,
    };
    return {
      for (final entry in _tagSenses.entries)
        if (keep.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Which of the library's words are one word, as far as the librarian pass
  /// can tell. Suggestions only; [renameTag] is what acts on one. A pair
  /// naming a word the library no longer has is dropped here, because the
  /// library may have changed while the answer was on its way.
  Future<List<TagMerge>> suggestTagMerges() async {
    final words = tagVocabulary;
    if (words.length < 2) return const <TagMerge>[];
    final suggested = await _tagMergeService.suggest(words);
    final known = {for (final entry in tagCounts) entry.tag.value};
    return [
      for (final merge in suggested)
        if (known.contains(merge.from) && known.contains(merge.into)) merge,
    ];
  }

  int organizedCountForTag(String tag) {
    final structuredCount = organizedStructuredCaptures
        .where((capture) => capture.hasTag(tag))
        .length;
    final groupCount = _groups
        .where((group) => tagsForGroup(group.id).any((one) => one.value == tag))
        .length;
    return structuredCount + groupCount;
  }

  List<CaptureRecord> get organizedStructuredCaptures => _captures
      .where(
        (capture) =>
            capture.status == CaptureStatus.organized &&
            capture.analysis?.structuredContent != null,
      )
      .toList(growable: false);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _restoreSnapshot();
    _incomingSubscription = _incomingShareService.pendingChanged.listen((_) {
      unawaited(_drainIncomingShares());
    });
    _portableTipSubscription = _portableTipInbox?.pendingChanged.listen((_) {
      unawaited(_drainPortableTips());
    });
    await _drainIncomingShares();
    await _drainPortableTips();
    unawaited(_topUpTagSenses());
  }

  Future<void> _drainPortableTips() {
    final operation = _portableTipDrainTail.then(
      (_) => _drainPortableTipsOnce(),
    );
    _portableTipDrainTail = operation;
    return operation;
  }

  Future<void> _drainPortableTipsOnce() async {
    final inbox = _portableTipInbox;
    if (inbox == null) return;
    try {
      final envelopes = await inbox.pending();
      if (envelopes.isEmpty) return;
      final knownTransportIds = _captures
          .map((capture) => capture.raw.transportEventId)
          .toSet();
      knownTransportIds.addAll(
        _pendingPortableTips.values.map(
          (pending) => 'portable-${pending.tip.packageId}',
        ),
      );
      final rejectedTransportIds = <String>[];
      final receivedTransportIds = <String>[];
      for (final envelope in envelopes) {
        if (_pendingPortableTips.containsKey(envelope.transportId)) continue;
        try {
          final decoded = PortableTipPackageCodec.decode(envelope.contents);
          final transportId = 'portable-${decoded.packageId}';
          if (knownTransportIds.contains(transportId)) {
            rejectedTransportIds.add(envelope.transportId);
            continue;
          }
          _pendingPortableTips[envelope.transportId] = _PendingPortableTip(
            envelope: envelope,
            tip: decoded,
          );
          knownTransportIds.add(transportId);
          receivedTransportIds.add(envelope.transportId);
        } on UnsupportedPortableTipVersionException catch (error) {
          // Keep a future-version package in the native inbox. Deleting it
          // automatically would make an app update unable to recover it.
          debugPrint('Portable tip needs an app update: $error');
        } on FormatException catch (error) {
          debugPrint('Portable tip was rejected: $error');
          rejectedTransportIds.add(envelope.transportId);
        }
      }
      if (rejectedTransportIds.isNotEmpty) {
        await inbox.acknowledge(rejectedTransportIds);
      }
      for (final transportId in receivedTransportIds) {
        _portableTipController.add(transportId);
      }
    } catch (error, stackTrace) {
      debugPrint('Portable tip drain failed: $error\n$stackTrace');
    }
  }

  Future<String?> acceptPortableTip(String transportId) async {
    final pending = _pendingPortableTips[transportId];
    final inbox = _portableTipInbox;
    if (pending == null) return null;
    final imported = PortableTipPackageCodec.import(
      pending.envelope.contents,
      createLocalId: () => 'import-${DateTime.now().microsecondsSinceEpoch}',
    );
    final capture = captureFromImportedPortableTip(imported);
    _captures.insert(0, capture);
    _filter = CaptureFilter.all;
    final saved = await _persistState();
    if (!saved) {
      _captures.removeWhere((item) => item.raw.id == capture.raw.id);
      return null;
    }
    _pendingPortableTips.remove(transportId);
    notifyListeners();
    if (pending.nativeEnvelope && inbox != null) {
      try {
        await inbox.acknowledge([transportId]);
      } catch (error, stackTrace) {
        // The content is already durably saved. Keep the successful result;
        // a later drain will recognize the package id and retry cleanup.
        debugPrint('Portable tip acknowledge failed: $error\n$stackTrace');
      }
    }
    return capture.raw.id;
  }

  Future<void> discardPortableTip(String transportId) async {
    final inbox = _portableTipInbox;
    final pending = _pendingPortableTips.remove(transportId);
    if (pending == null) return;
    if (pending.nativeEnvelope && inbox != null) {
      await inbox.acknowledge([transportId]);
    }
  }

  String stagePortableTip(String contents, {bool announce = true}) {
    final tip = PortableTipPackageCodec.decode(contents);
    final existing =
        _captures.any(
          (capture) =>
              capture.raw.transportEventId == 'portable-${tip.packageId}',
        ) ||
        _pendingPortableTips.values.any(
          (pending) => pending.tip.packageId == tip.packageId,
        );
    if (existing) {
      throw const FormatException('이미 받은 팁이에요.');
    }
    final transportId = 'manual-${DateTime.now().microsecondsSinceEpoch}';
    _pendingPortableTips[transportId] = _PendingPortableTip(
      envelope: PendingPortableTipEnvelope(
        transportId: transportId,
        contents: contents,
      ),
      tip: tip,
      nativeEnvelope: false,
    );
    if (announce) {
      _portableTipController.add(transportId);
    }
    return transportId;
  }

  void announcePortableTip(String transportId) {
    if (_pendingPortableTips.containsKey(transportId)) {
      _portableTipController.add(transportId);
    }
  }

  Future<void> _drainIncomingShares() {
    final operation = _incomingDrainTail.then(
      (_) => _drainIncomingSharesOnce(),
    );
    _incomingDrainTail = operation;
    return operation;
  }

  Future<void> _drainIncomingSharesOnce() async {
    try {
      final shares = await _incomingShareService.drainPending();
      final knownTransportIds = _captures
          .map((capture) => capture.raw.transportEventId)
          .toSet();
      final safeToAcknowledge = <String>{};
      final pendingAnalysisIds = <String>[];
      final importedCaptureIds = <String>[];
      final sourceDeletionCandidateIds = <String>[];
      final previousFilter = _filter;
      var changed = false;
      for (final share in shares) {
        if (knownTransportIds.contains(share.id)) {
          if (_durablySavedTransportIds.contains(share.id)) {
            safeToAcknowledge.add(share.id);
          }
          continue;
        }
        CaptureRecord capture;
        try {
          capture = share.attachments.isEmpty
              ? _contentAnalysisService.analyzeShare(share)
              : _contentAnalysisService.prepareShare(share);
          capture = await _retainAttachments(capture);
        } catch (error, stackTrace) {
          // One unreadable item in a large picker batch must not prevent the
          // other selected photos from being imported. Leave this native item
          // pending so a later drain can retry it or a newer build can recover
          // it.
          debugPrint(
            'Incoming share ${share.id} could not be prepared: '
            '$error\n$stackTrace',
          );
          continue;
        }
        _captures.insert(0, capture);
        importedCaptureIds.add(capture.raw.id);
        if (share.sourceDeletionAvailable) {
          sourceDeletionCandidateIds.add(capture.raw.id);
        }
        if (capture.status == CaptureStatus.analyzing) {
          pendingAnalysisIds.add(capture.raw.id);
        }
        knownTransportIds.add(share.id);
        changed = true;
      }
      var importedBatchWasSaved = false;
      if (changed) {
        _filter = CaptureFilter.all;
        final saved = await _persistState();
        if (saved) {
          importedBatchWasSaved = true;
          _sourceDeletionAvailableCaptureIds.addAll(sourceDeletionCandidateIds);
          safeToAcknowledge.addAll(
            shares
                .where((share) => _durablySavedTransportIds.contains(share.id))
                .map((share) => share.id),
          );
        } else {
          final importedIds = importedCaptureIds.toSet();
          final unsavedCaptures = _captures
              .where((capture) => importedIds.contains(capture.raw.id))
              .toList(growable: false);
          _captures.removeWhere(
            (capture) => importedIds.contains(capture.raw.id),
          );
          _filter = previousFilter;
          for (final capture in unsavedCaptures) {
            if (sourceDeletionCandidateIds.contains(capture.raw.id)) {
              try {
                await _incomingShareService.keepSharedSource(
                  capture.raw.transportEventId,
                );
              } catch (error, stackTrace) {
                debugPrint('Shared source keep failed: $error\n$stackTrace');
              }
            }
            try {
              await _deleteUnreferencedManagedAttachments(capture);
            } catch (error, stackTrace) {
              debugPrint(
                'Unsaved retained attachment cleanup failed: '
                '$error\n$stackTrace',
              );
            }
          }
        }
        if (importedBatchWasSaved) {
          notifyListeners();
          _incomingCaptureController.add(
            IncomingCaptureBatch(importedCaptureIds),
          );
        }
      }
      if (safeToAcknowledge.isNotEmpty) {
        try {
          await _incomingShareService.acknowledge(safeToAcknowledge);
        } catch (error, stackTrace) {
          // The snapshot is already durable. Keep analysis moving and leave
          // the native envelope for a later idempotent acknowledge attempt.
          debugPrint('Incoming share acknowledge failed: $error\n$stackTrace');
        }
      }
      if (importedBatchWasSaved) {
        _queueCaptureAnalysis(pendingAnalysisIds);
      }
    } catch (error, stackTrace) {
      debugPrint('Incoming share drain failed: $error\n$stackTrace');
    }
  }

  /// Runs remote image analysis one at a time without holding the incoming
  /// share drain lock. A 100-photo batch is persisted and acknowledged first,
  /// so another picker/share can be accepted while this queue keeps working.
  void _queueCaptureAnalysis(Iterable<String> captureIds) {
    for (final captureId in captureIds) {
      if (!_queuedAnalysisIds.add(captureId)) continue;
      _analysisTail = _analysisTail.then((_) async {
        try {
          await _analyzeCapture(captureId);
        } catch (error, stackTrace) {
          debugPrint(
            'Queued content analysis failed unexpectedly: '
            '$error\n$stackTrace',
          );
        } finally {
          _queuedAnalysisIds.remove(captureId);
        }
      });
    }
  }

  Future<void> _analyzeCapture(String captureId) async {
    final initial = captureById(captureId);
    if (initial == null || initial.status != CaptureStatus.analyzing) {
      return;
    }
    try {
      final analysis = _spelledLikeLibrary(
        await _contentAnalysisService.analyze(initial),
      );
      final index = _captures.indexWhere(
        (capture) => capture.raw.id == captureId,
      );
      if (index == -1) {
        return;
      }
      final current = _captures[index];
      _captures[index] = current.copyWith(
        status: _statusForCompletedAnalysis(current, analysis),
        analysis: analysis,
      );
    } catch (error) {
      final index = _captures.indexWhere(
        (capture) => capture.raw.id == captureId,
      );
      if (index == -1) {
        return;
      }
      final current = _captures[index];
      final code = error is AnalysisServiceException
          ? error.code
          : 'analysis_failed';
      _captures[index] = current.copyWith(
        status: CaptureStatus.failed,
        analysis: AnalysisRun(
          id: 'analysis-${current.raw.transportEventId}-failed',
          inputId: current.raw.id,
          normalizerVersion: current.normalized.normalizerVersion,
          analyzerVersion: 'remote-analysis-v1',
          status: AnalysisRunStatus.failed,
          completedAt: DateTime.now(),
          evidence: const [],
          productMentions: const [],
          statements: const [],
          disclosure: DisclosureObservation.unknown,
          failureCode: code,
        ),
      );
      debugPrint('Content analysis failed with code: $code');
    }
    await _persistState();
    notifyListeners();
    unawaited(_enrichPlace(captureId));
  }

  /// Adds the tags a screenshot cannot carry, once the capture is already saved
  /// and visible.
  ///
  /// Deliberately not awaited by the analysis: the reader sees the screenshot's
  /// own findings immediately, and web tags arrive on top a few seconds later.
  /// A capture with no place, or one already looked up, costs nothing.
  Future<void> _enrichPlace(String captureId) async {
    if (!_attemptedPlaceEnrichment.add(captureId)) {
      return;
    }
    final capture = captureById(captureId);
    final structured = capture?.analysis?.structuredContent;
    final placeName = structured?.place?.name?.trim();
    if (structured == null || placeName == null || placeName.isEmpty) {
      return;
    }

    // The same 상호명 + 지역 the map opens with, so a capture is looked up under
    // the words it would be searched with, including the area derived from an
    // address when the screenshot named no area of its own.
    final links = PlaceMapLinks.fromPlace(
      name: placeName,
      address: structured.place?.address,
      searchArea: structured.place?.searchArea,
    );
    final found = adoptedSpellings(
      await _placeEnrichmentService.enrich(
        name: placeName,
        searchArea: links?.area,
      ),
      _spellings,
    );
    if (found.isEmpty) {
      return;
    }

    final index = _captures.indexWhere((item) => item.raw.id == captureId);
    if (index == -1) {
      return;
    }
    final current = _captures[index];
    final currentStructured = current.analysis?.structuredContent;
    if (currentStructured == null) {
      return;
    }
    _captures[index] = current.copyWith(
      analysis: _withStructured(
        current.analysis!,
        currentStructured.withTags(found),
      ),
    );
    await _persistState();
    notifyListeners();
  }

  static CaptureStatus _statusForCompletedAnalysis(
    CaptureRecord capture,
    AnalysisRun analysis,
  ) {
    if (analysis.status == AnalysisRunStatus.failed) {
      return CaptureStatus.failed;
    }
    final structured = analysis.structuredContent;
    if (structured?.completeness == StructuredCompleteness.unsupported) {
      return CaptureStatus.sourceLimited;
    }
    return capture.normalized.completeness == MaterialCompleteness.linkOnly
        ? CaptureStatus.sourceLimited
        : CaptureStatus.needsReview;
  }

  Future<CaptureRecord> _retainAttachments(CaptureRecord capture) async {
    if (capture.raw.attachments.isEmpty) {
      return capture;
    }
    final retained = <IncomingAttachment>[];
    for (final attachment in capture.raw.attachments) {
      final source = File(attachment.filePath);
      if (source.parent.path.split(Platform.pathSeparator).last !=
          'incoming_share_attachments') {
        retained.add(attachment);
        continue;
      }
      if (!await source.exists()) {
        throw const FileSystemException('Incoming attachment is missing.');
      }

      final extension = switch (attachment.mimeType) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        _ => throw const FileSystemException(
          'Incoming attachment type is unsupported.',
        ),
      };
      final libraryDirectory = Directory(
        '${source.parent.parent.path}${Platform.pathSeparator}'
        'ori_library_attachments',
      );
      await libraryDirectory.create(recursive: true);
      final destination = File(
        '${libraryDirectory.path}${Platform.pathSeparator}'
        '${attachment.sha256}.$extension',
      );
      if (await destination.exists()) {
        if (await destination.length() != attachment.byteSize) {
          throw const FileSystemException(
            'Retained attachment does not match its metadata.',
          );
        }
      } else {
        final temporary = File(
          '${libraryDirectory.path}${Platform.pathSeparator}'
          '.${attachment.sha256}.${attachment.id}.part',
        );
        RandomAccessFile? input;
        RandomAccessFile? output;
        try {
          input = await source.open();
          output = await temporary.open(mode: FileMode.write);
          while (true) {
            final bytes = await input.read(64 * 1024);
            if (bytes.isEmpty) {
              break;
            }
            await output.writeFrom(bytes);
          }
          await output.flush();
          await output.close();
          output = null;
          if (await temporary.length() != attachment.byteSize) {
            throw const FileSystemException(
              'Retained attachment does not match its metadata.',
            );
          }
          await temporary.rename(destination.path);
        } finally {
          await input?.close();
          await output?.close();
          if (await temporary.exists()) {
            await temporary.delete();
          }
        }
      }
      retained.add(
        IncomingAttachment(
          id: attachment.id,
          filePath: destination.path,
          mimeType: attachment.mimeType,
          byteSize: attachment.byteSize,
          width: attachment.width,
          height: attachment.height,
          sha256: attachment.sha256,
        ),
      );
    }
    return CaptureRecord(
      raw: RawCapture(
        id: capture.raw.id,
        transportEventId: capture.raw.transportEventId,
        receivedAt: capture.raw.receivedAt,
        origin: capture.raw.origin,
        mimeType: capture.raw.mimeType,
        rawText: capture.raw.rawText,
        rawUrl: capture.raw.rawUrl,
        semanticFingerprint: capture.raw.semanticFingerprint,
        wasTruncated: capture.raw.wasTruncated,
        originalLength: capture.raw.originalLength,
        sourcePackage: capture.raw.sourcePackage,
        userNote: capture.raw.userNote,
        attachments: retained,
      ),
      normalized: capture.normalized,
      status: capture.status,
      analysis: capture.analysis,
      review: capture.review,
      groupId: capture.groupId,
      tagOverride: capture.tagOverride,
    );
  }

  static ConfirmedProductIdentity? _quickOrganizationIdentity(
    ProductMention? mention,
  ) {
    if (mention == null || !mention.canGroupAutomatically) {
      return null;
    }
    final brand = mention.brand.value?.trim() ?? '';
    final name = mention.name.value?.trim() ?? '';
    final category = mention.category.value?.trim() ?? '';
    final amount = mention.amount.value?.trim() ?? '';
    if (brand.isEmpty || name.isEmpty || category.isEmpty || amount.isEmpty) {
      return null;
    }
    return ConfirmedProductIdentity(
      brand: brand,
      name: name,
      category: category,
      amount: amount,
    );
  }

  void _removeCaptureFromGroups(String captureId) {
    for (var index = _groups.length - 1; index >= 0; index--) {
      final group = _groups[index];
      final sourceCaptureIds = group.sourceCaptureIds
          .where((id) => id != captureId)
          .toList(growable: false);
      final statements = group.statements
          .where((statement) => statement.captureId != captureId)
          .toList(growable: false);
      final changed =
          sourceCaptureIds.length != group.sourceCaptureIds.length ||
          statements.length != group.statements.length;
      if (!changed) {
        continue;
      }
      if (sourceCaptureIds.isEmpty) {
        _groups.removeAt(index);
        continue;
      }
      _groups[index] = ProductGroup(
        id: group.id,
        identity: group.identity,
        sourceCaptureIds: sourceCaptureIds,
        statements: statements,
        updatedAt: DateTime.now(),
        colorValue: group.colorValue,
      );
    }
  }

  Future<void> _deleteUnreferencedManagedAttachments(
    CaptureRecord deletedCapture,
  ) async {
    final referencedPaths = _captures
        .expand((capture) => capture.raw.attachments)
        .map((attachment) => attachment.filePath)
        .toSet();
    final candidates = deletedCapture.raw.attachments
        .map((attachment) => attachment.filePath)
        .where(_isManagedAttachmentPath)
        .where((path) => !referencedPaths.contains(path))
        .toSet();
    for (final path in candidates) {
      final file = File(path);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (error, stackTrace) {
        // The record is already durably deleted. A leftover private cache file
        // is safer than undoing the committed deletion or touching its source.
        debugPrint('Managed attachment cleanup failed: $error\n$stackTrace');
      }
    }
  }

  static bool _isManagedAttachmentPath(String path) =>
      File(path).parent.path.split(Platform.pathSeparator).last ==
      'ori_library_attachments';

  Future<void> _acknowledgeAfterDurableSave(CaptureRecord capture) async {
    if (capture.raw.origin != CaptureOrigin.androidShare) {
      return;
    }
    try {
      await _incomingShareService.acknowledge([capture.raw.transportEventId]);
    } catch (error, stackTrace) {
      debugPrint('Incoming share acknowledge failed: $error\n$stackTrace');
    }
  }

  void setFilter(CaptureFilter value) {
    if (_filter == value) {
      return;
    }
    _filter = value;
    notifyListeners();
  }

  String addManualInput(String text) {
    final now = DateTime.now();
    final share = IncomingShare(
      id: 'manual-${now.microsecondsSinceEpoch}',
      receivedAt: now,
      sharedText: text,
      discoveredUrl: IncomingShare.extractFirstUrl(text),
      sourcePackage: 'manual',
    );
    final capture = _contentAnalysisService.analyzeShare(
      share,
      origin: CaptureOrigin.manual,
    );
    _captures.insert(0, capture);
    unawaited(_persistState());
    notifyListeners();
    return capture.raw.id;
  }

  void addDemoInput() {
    addManualInput(
      '데이라이트 에어리 선 플루이드 50ml. 백탁이 적고 가볍게 '
      '발린다고 소개했어요. #제품제공 '
      'https://instagram.com/reel/new-daylight?utm_source=share',
    );
  }

  Future<void> confirmAndOrganize({
    required String captureId,
    required ConfirmedProductIdentity identity,
    List<ContentTag>? tags,
  }) async {
    final capture = _applyProductOrganization(
      captureId: captureId,
      identity: identity,
      tags: tags,
    );
    if (capture == null) {
      return;
    }
    notifyListeners();

    final saved = await _persistState();
    if (saved && capture.raw.origin == CaptureOrigin.androidShare) {
      await _incomingShareService.acknowledge([capture.raw.transportEventId]);
    }
  }

  CaptureRecord? _applyProductOrganization({
    required String captureId,
    required ConfirmedProductIdentity identity,
    List<ContentTag>? tags,
  }) {
    final captureIndex = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (captureIndex == -1) {
      return null;
    }
    final capture = _captures[captureIndex];
    final analysis = capture.analysis;
    if (analysis == null) {
      return null;
    }

    final candidate = capture.primaryMention;
    final corrected =
        candidate?.brand.value?.trim() != identity.brand.trim() ||
        candidate?.name.value?.trim() != identity.name.trim() ||
        (candidate?.category.value ?? '').trim() != identity.category.trim() ||
        (candidate?.amount.value ?? '').trim() != identity.amount.trim();
    final review = UserReview(
      id: 'review-${capture.raw.id}-${DateTime.now().microsecondsSinceEpoch}',
      captureId: capture.raw.id,
      analysisRunId: analysis.id,
      resolution: corrected
          ? ReviewResolution.corrected
          : ReviewResolution.confirmed,
      reviewedAt: DateTime.now(),
      candidateId: candidate?.id,
      confirmedIdentity: identity,
    );

    final hasCompleteIdentity =
        identity.brand.isNotEmpty &&
        identity.name.isNotEmpty &&
        identity.category.isNotEmpty &&
        identity.amount.isNotEmpty;
    final existingGroupIndex = hasCompleteIdentity
        ? _groups.indexWhere(
            (group) => group.identity.identityKey == identity.identityKey,
          )
        : -1;
    late final String groupId;
    if (existingGroupIndex == -1) {
      final groupKey = hasCompleteIdentity
          ? identity.identityKey
          : '${identity.identityKey}|${capture.raw.id}';
      groupId =
          'group-${BaselineContentAnalysisService.semanticFingerprint(groupKey)}';
      _groups.insert(
        0,
        ProductGroup(
          id: groupId,
          identity: identity,
          sourceCaptureIds: [capture.raw.id],
          statements: analysis.statements,
          updatedAt: DateTime.now(),
          colorValue: _colorForGroup(_groups.length),
        ),
      );
    } else {
      final existing = _groups[existingGroupIndex];
      groupId = existing.id;
      _groups[existingGroupIndex] = existing.addSource(
        captureId: capture.raw.id,
        sourceStatements: analysis.statements,
        at: DateTime.now(),
      );
    }

    // Everything filed under one product shares one set of tags. Joining an
    // existing group adopts what is already there; starting one hands the
    // group whatever this capture carried.
    final effectiveTags = dedupedTags([
      ...?tags,
      if (existingGroupIndex != -1) ...tagsForGroup(groupId),
      ...capture.contentTags,
    ]);

    _captures[captureIndex] = capture.copyWith(
      status: CaptureStatus.organized,
      review: review,
      groupId: groupId,
      tagOverride: effectiveTags,
    );
    for (var index = 0; index < _captures.length; index++) {
      final groupedCapture = _captures[index];
      if (index != captureIndex && groupedCapture.groupId == groupId) {
        _captures[index] = groupedCapture.copyWith(tagOverride: effectiveTags);
      }
    }
    return capture;
  }

  Future<void> keepUnresolved(String captureId) async {
    final captureIndex = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (captureIndex == -1) {
      return;
    }
    final capture = _captures[captureIndex];
    final analysis = capture.analysis;
    if (analysis == null) {
      return;
    }

    _captures[captureIndex] = capture.copyWith(
      status: CaptureStatus.needsReview,
      review: UserReview(
        id: 'review-${capture.raw.id}-${DateTime.now().microsecondsSinceEpoch}',
        captureId: capture.raw.id,
        analysisRunId: analysis.id,
        resolution: ReviewResolution.unresolved,
        reviewedAt: DateTime.now(),
        candidateId: capture.primaryMention?.id,
      ),
    );
    notifyListeners();

    final saved = await _persistState();
    if (saved && capture.raw.origin == CaptureOrigin.androidShare) {
      await _incomingShareService.acknowledge([capture.raw.transportEventId]);
    }
  }

  Future<void> confirmStructured(
    String captureId, {
    List<ContentTag>? tags,
  }) async {
    final capture = _applyStructuredOrganization(captureId, tags: tags);
    if (capture == null) {
      return;
    }
    notifyListeners();

    final saved = await _persistState();
    if (saved && capture.raw.origin == CaptureOrigin.androidShare) {
      await _incomingShareService.acknowledge([capture.raw.transportEventId]);
    }
    unawaited(_topUpTagSenses());
  }

  CaptureRecord? _applyStructuredOrganization(
    String captureId, {
    List<ContentTag>? tags,
  }) {
    final captureIndex = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (captureIndex == -1) {
      return null;
    }
    final capture = _captures[captureIndex];
    final analysis = capture.analysis;
    if (analysis?.structuredContent == null) {
      return null;
    }

    _captures[captureIndex] = capture.copyWith(
      status: CaptureStatus.organized,
      review: UserReview(
        id: 'review-${capture.raw.id}-${DateTime.now().microsecondsSinceEpoch}',
        captureId: capture.raw.id,
        analysisRunId: analysis!.id,
        resolution: ReviewResolution.confirmed,
        reviewedAt: DateTime.now(),
      ),
      tagOverride: tags == null
          ? capture.tagOverride
          : dedupedTags(adoptedSpellings(tags, _spellings)),
    );
    return capture;
  }

  Future<void> updateCaptureTags(
    String captureId,
    List<ContentTag> tags,
  ) async {
    final index = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (index == -1) {
      return;
    }
    _captures[index] = _captures[index].copyWith(
      tagOverride: dedupedTags(adoptedSpellings(tags, _spellings)),
    );
    notifyListeners();
    await _persistState();
    unawaited(_topUpTagSenses());
  }

  /// Retags every capture filed under one product.
  ///
  /// All of them, because the tags are the group's: a product shown on the
  /// library card carries one set, and leaving the others behind would make the
  /// same product answer differently depending on which capture was read.
  Future<void> updateGroupTags(String groupId, List<ContentTag> tags) async {
    final resolved = dedupedTags(adoptedSpellings(tags, _spellings));
    var changed = false;
    for (var index = 0; index < _captures.length; index++) {
      final capture = _captures[index];
      if (capture.groupId != groupId) {
        continue;
      }
      _captures[index] = capture.copyWith(tagOverride: resolved);
      changed = true;
    }
    if (!changed) {
      return;
    }
    notifyListeners();
    await _persistState();
    unawaited(_topUpTagSenses());
  }

  /// Renames a tag everywhere it is filed, merging when the name is taken.
  ///
  /// Renaming onto a name that already exists is a merge rather than an error.
  /// `멕시코 음식` and `멕시코음식` are one word to the reader and two to the
  /// analysis, and until an automatic pass can tell, the reader saying so is
  /// the only thing that can join them.
  ///
  /// Every tag this touches becomes the reader's own. They have said what this
  /// is called, and a later pass must not argue with it.
  ///
  /// Renaming onto a spelling of a word the library already has lands on the
  /// library's spelling of it: typing `스킨 케어` while `스킨케어` exists is a
  /// merge into `스킨케어`. Renaming a word onto another spelling of itself is
  /// the one case where the typed spelling wins, because respelling the word
  /// is the whole request and there is nothing else it could mean.
  Future<void> renameTag(String from, String to) async {
    final typed = normalizeTagName(to);
    if (!isValidTagName(typed)) {
      return;
    }
    final fromKey = tagKey(from);
    final target = tagKey(typed) == fromKey
        ? typed
        : (_spellings[tagKey(typed)] ?? typed);
    if (target == from) {
      return;
    }
    var changed = false;
    for (var index = 0; index < _captures.length; index++) {
      final capture = _captures[index];
      final tags = capture.contentTags;
      if (!tags.any((tag) => tag.key == fromKey)) {
        continue;
      }
      _captures[index] = capture.copyWith(
        // Deduping is what performs the merge: if the target name is already
        // on this capture, the renamed one collapses into it.
        tagOverride: dedupedTags([
          for (final tag in tags)
            if (tag.key == fromKey)
              tag.copyWith(value: target, source: TagSource.user)
            else
              tag,
        ]),
      );
      changed = true;
    }
    if (!changed) {
      return;
    }
    notifyListeners();
    await _persistState();
    unawaited(_topUpTagSenses());
  }

  Future<CapturePickerResult> presentCapturePicker() {
    return _incomingShareService.presentCapturePicker();
  }

  void retryAnalysis(String captureId) {
    final index = _captures.indexWhere(
      (capture) => capture.raw.id == captureId,
    );
    if (index == -1) {
      return;
    }
    final capture = _captures[index];
    final share = IncomingShare(
      id: capture.raw.transportEventId,
      receivedAt: capture.raw.receivedAt,
      sharedText: capture.raw.rawText,
      discoveredUrl: capture.raw.rawUrl,
      sourcePackage: capture.raw.sourcePackage,
      mimeType: capture.raw.mimeType,
      wasTruncated: capture.raw.wasTruncated,
      originalLength: capture.raw.originalLength,
      shareKind: capture.raw.attachments.isEmpty
          ? ShareKind.text
          : ShareKind.image,
      attachments: capture.raw.attachments,
    );
    final reanalyzedWithoutFolder = capture.raw.attachments.isEmpty
        ? _contentAnalysisService.analyzeShare(
            share,
            origin: capture.raw.origin,
          )
        : _contentAnalysisService.prepareShare(
            share,
            origin: capture.raw.origin,
          );
    final reanalyzed = reanalyzedWithoutFolder.copyWith(
      tagOverride: capture.tagOverride,
    );
    _captures[index] = reanalyzed;
    unawaited(_persistState());
    notifyListeners();
    if (reanalyzed.status == CaptureStatus.analyzing) {
      _queueCaptureAnalysis([reanalyzed.raw.id]);
    }
  }

  Future<void> _restoreSnapshot() async {
    try {
      _tagSenses.addAll(await _snapshotStore.loadTagSenses());
      final persistedCaptures = await _snapshotStore.load();
      final knownTransportIds = _captures
          .map((capture) => capture.raw.transportEventId)
          .toSet();
      final restored = <CaptureRecord>[];
      final pendingAnalysisIds = <String>[];
      for (final persisted in persistedCaptures) {
        if (!knownTransportIds.add(persisted.transportEventId)) {
          continue;
        }
        final share = persisted.toIncomingShare();
        final prepared = _contentAnalysisService.prepareShare(
          share,
          origin: persisted.origin,
        );
        final analyzedWithoutFolder = switch (persisted.analysis) {
          final analysis? => prepared.copyWith(
            status: persisted.status,
            analysis: analysis,
          ),
          null when persisted.attachments.isEmpty =>
            _contentAnalysisService.analyzeShare(
              share,
              origin: persisted.origin,
            ),
          null => prepared,
        };
        final analyzed = analyzedWithoutFolder.copyWith(
          tagOverride: persisted.tagOverride,
        );
        if (analyzed.status == CaptureStatus.analyzing) {
          pendingAnalysisIds.add(analyzed.raw.id);
        }
        final reviewResolution = persisted.reviewResolution;
        final identity = persisted.confirmedIdentity;
        final groupId = persisted.groupId;
        if (persisted.status == CaptureStatus.organized &&
            identity != null &&
            groupId != null) {
          final organized = analyzed.copyWith(
            status: CaptureStatus.organized,
            groupId: groupId,
            review: _restoredReview(
              persisted: persisted,
              analyzed: analyzed,
              resolution: reviewResolution ?? ReviewResolution.confirmed,
              identity: identity,
            ),
          );
          _restoreGroup(organized, identity, groupId);
          restored.add(organized);
          continue;
        }
        if (reviewResolution != null) {
          restored.add(
            analyzed.copyWith(
              status: persisted.status,
              review: _restoredReview(
                persisted: persisted,
                analyzed: analyzed,
                resolution: reviewResolution,
                identity: identity,
              ),
            ),
          );
          continue;
        }
        restored.add(analyzed);
      }
      if (restored.isNotEmpty) {
        _synchronizeRestoredGroupTags(restored);
        _captures.insertAll(0, restored);
        _durablySavedTransportIds.addAll(
          restored.map((capture) => capture.raw.transportEventId),
        );
        notifyListeners();
        if (_unifySpellings()) {
          await _persistState();
          notifyListeners();
        }
      }
      _queueCaptureAnalysis(pendingAnalysisIds);
    } catch (error, stackTrace) {
      debugPrint('App snapshot restore failed: $error\n$stackTrace');
    }
  }

  /// [run] carrying [structured] in place of what it read, everything else as
  /// it was.
  AnalysisRun _withStructured(
    AnalysisRun run,
    StructuredContentAnalysis structured,
  ) => AnalysisRun(
    id: run.id,
    inputId: run.inputId,
    normalizerVersion: run.normalizerVersion,
    analyzerVersion: run.analyzerVersion,
    status: run.status,
    completedAt: run.completedAt,
    evidence: run.evidence,
    productMentions: run.productMentions,
    statements: run.statements,
    disclosure: run.disclosure,
    failureCode: run.failureCode,
    model: run.model,
    startedAt: run.startedAt,
    attempt: run.attempt,
    structuredContent: structured,
  );

  /// [run] with its tags spelled the way the library already spells them.
  ///
  /// The analysis is shown the library's words and asked to reuse them, and
  /// the server rewrites a variant it emits anyway. This is the last line: a
  /// word that reaches the library is written the library's way, whatever
  /// happened upstream, so `스킨 케어` never sits beside `스킨케어`.
  AnalysisRun _spelledLikeLibrary(AnalysisRun run) {
    final structured = run.structuredContent;
    if (structured == null || structured.tags.isEmpty) return run;
    return _withStructured(
      run,
      structured.replacingTags(adoptedSpellings(structured.tags, _spellings)),
    );
  }

  /// Writes every tag in the library the way its most-used spelling is
  /// written, and says whether anything changed.
  ///
  /// A library saved before spellings were joined can hold `멕시코 음식` on
  /// one capture and `멕시코음식` on another. Joining them is done once, on
  /// the way in, in place: a capture the reader tagged keeps its own list with
  /// the spellings changed, and one still carrying the analysis's tags has
  /// those rewritten rather than being given an override — an override would
  /// freeze it, and a web tag arriving later would have nowhere to land.
  bool _unifySpellings() {
    final spellings = _spellings;
    var changed = false;
    for (var index = 0; index < _captures.length; index++) {
      final capture = _captures[index];
      final override = capture.tagOverride;
      if (override != null) {
        final adopted = adoptedSpellings(override, spellings);
        if (!_sameSpellings(adopted, override)) {
          _captures[index] = capture.copyWith(
            tagOverride: dedupedTags(adopted),
          );
          changed = true;
        }
        continue;
      }
      final run = capture.analysis;
      final structured = run?.structuredContent;
      if (run == null || structured == null) continue;
      final adopted = adoptedSpellings(structured.tags, spellings);
      if (!_sameSpellings(adopted, structured.tags)) {
        _captures[index] = capture.copyWith(
          analysis: _withStructured(run, structured.replacingTags(adopted)),
        );
        changed = true;
      }
    }
    return changed;
  }

  static bool _sameSpellings(List<ContentTag> a, List<ContentTag> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].value != b[index].value) return false;
    }
    return true;
  }

  /// Gives every capture in a group the tags one of them already carried.
  ///
  /// A snapshot stores each capture on its own, so a group whose tags were set
  /// once can come back with only the capture that was open at the time
  /// carrying them. The library card would then show a different set depending
  /// on which capture it read first.
  void _synchronizeRestoredGroupTags(List<CaptureRecord> restored) {
    final tagsByGroup = <String, List<ContentTag>>{};
    void collect(Iterable<CaptureRecord> captures) {
      for (final capture in captures) {
        final groupId = capture.groupId;
        final override = capture.tagOverride;
        if (groupId != null && override != null && override.isNotEmpty) {
          tagsByGroup.putIfAbsent(groupId, () => override);
        }
      }
    }

    collect(restored);
    collect(_captures);
    if (tagsByGroup.isEmpty) {
      return;
    }
    void apply(List<CaptureRecord> captures) {
      for (var index = 0; index < captures.length; index++) {
        final capture = captures[index];
        final tags = capture.groupId == null
            ? null
            : tagsByGroup[capture.groupId];
        if (tags != null) {
          captures[index] = capture.copyWith(tagOverride: tags);
        }
      }
    }

    apply(restored);
    apply(_captures);
  }

  UserReview _restoredReview({
    required PersistedCapture persisted,
    required CaptureRecord analyzed,
    required ReviewResolution resolution,
    required ConfirmedProductIdentity? identity,
  }) {
    return UserReview(
      id: persisted.reviewId ?? 'review-${analyzed.raw.id}-restored',
      captureId: analyzed.raw.id,
      analysisRunId: analyzed.analysis!.id,
      resolution: resolution,
      reviewedAt: persisted.reviewedAt ?? persisted.receivedAt,
      candidateId: analyzed.primaryMention?.id,
      confirmedIdentity: identity,
    );
  }

  void _restoreGroup(
    CaptureRecord capture,
    ConfirmedProductIdentity identity,
    String groupId,
  ) {
    final existingIndex = _groups.indexWhere((group) => group.id == groupId);
    if (existingIndex == -1) {
      _groups.insert(
        0,
        ProductGroup(
          id: groupId,
          identity: identity,
          sourceCaptureIds: [capture.raw.id],
          statements: [...?capture.analysis?.statements],
          updatedAt: capture.review?.reviewedAt ?? capture.raw.receivedAt,
          colorValue: _colorForGroup(_groups.length),
        ),
      );
      return;
    }
    _groups[existingIndex] = _groups[existingIndex].addSource(
      captureId: capture.raw.id,
      sourceStatements: [...?capture.analysis?.statements],
      at: capture.review?.reviewedAt ?? capture.raw.receivedAt,
    );
  }

  Future<bool> _persistState() async {
    final persisted = _captures
        .where((capture) => capture.raw.origin != CaptureOrigin.demo)
        .map(
          (capture) => PersistedCapture.fromRecord(
            capture,
            capture.groupId == null ? null : groupById(capture.groupId!),
          ),
        )
        .toList(growable: false);
    final persistedTransportIds = persisted
        .map((capture) => capture.transportEventId)
        .toSet();
    var saved = false;
    _snapshotWriteTail = _snapshotWriteTail.then((_) async {
      try {
        await _snapshotStore.save(persisted, tagSenses: _prunedTagSenses());
        _durablySavedTransportIds
          ..clear()
          ..addAll(persistedTransportIds);
        saved = true;
      } catch (error, stackTrace) {
        debugPrint('App snapshot save failed: $error\n$stackTrace');
      }
    });
    await _snapshotWriteTail;
    return saved;
  }

  static int _colorForGroup(int index) {
    const colors = [0xFFB89CD9, 0xFF8FC6A8, 0xFF89B9D5, 0xFFF0C978, 0xFFE49B8B];
    return colors[index % colors.length];
  }

  @override
  void dispose() {
    unawaited(_incomingSubscription?.cancel());
    unawaited(_portableTipSubscription?.cancel());
    unawaited(_incomingShareService.dispose());
    unawaited(_portableTipInbox?.dispose());
    unawaited(_incomingCaptureController.close());
    unawaited(_portableTipController.close());
    super.dispose();
  }
}

/// One thing waiting in 공유함, with the handle needed to accept or drop it.
final class SharedTipEntry {
  const SharedTipEntry({required this.transportId, required this.tip});

  final String transportId;
  final PortableTipPackage tip;
}

final class _PendingPortableTip {
  const _PendingPortableTip({
    required this.envelope,
    required this.tip,
    this.nativeEnvelope = true,
  });

  final PendingPortableTipEnvelope envelope;
  final PortableTipPackage tip;
  final bool nativeEnvelope;
}
