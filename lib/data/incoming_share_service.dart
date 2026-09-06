import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/models.dart';

abstract interface class IncomingShareService {
  Stream<void> get pendingChanged;

  Future<List<IncomingShare>> drainPending();

  /// Opens the platform picture picker so up to
  /// [CapturePickerResult.maxSelectionCount] screenshots can be imported from
  /// inside the app. Accepted images are staged into the same pending queue a
  /// share intent uses, so the caller waits for [pendingChanged] rather than
  /// receiving image bytes here.
  ///
  /// Supported on both iOS and Android. Android also keeps its quick settings
  /// tile as a shortcut to the same picker.
  Future<CapturePickerResult> presentCapturePicker();

  Future<void> acknowledge(Iterable<String> ids);

  Future<SharedSourceDeletionResult> deleteSharedSource(String transportId);

  Future<void> keepSharedSource(String transportId);

  Future<void> dispose();
}

/// Counts returned after one trip through the platform picture picker.
///
/// A zero [selectedCount] means the person cancelled without choosing
/// anything. Otherwise every selected image is either imported or rejected.
final class CapturePickerResult {
  const CapturePickerResult({
    required this.selectedCount,
    required this.importedCount,
    required this.rejectedCount,
  }) : assert(selectedCount >= 0),
       assert(selectedCount <= maxSelectionCount),
       assert(importedCount >= 0),
       assert(rejectedCount >= 0),
       assert(importedCount + rejectedCount == selectedCount);

  const CapturePickerResult.cancelled()
    : selectedCount = 0,
      importedCount = 0,
      rejectedCount = 0;

  static const maxSelectionCount = 100;
  static const maxBatchSizeMegabytes = 512;

  final int selectedCount;
  final int importedCount;
  final int rejectedCount;

  bool get wasCancelled => selectedCount == 0;

  /// Decodes both the current count map and the old boolean response so an app
  /// update remains compatible with a platform runner from the previous build.
  factory CapturePickerResult.fromPlatformValue(Object? value) {
    if (value == null || value == false) {
      return const CapturePickerResult.cancelled();
    }
    if (value == true) {
      return const CapturePickerResult(
        selectedCount: 1,
        importedCount: 1,
        rejectedCount: 0,
      );
    }
    if (value is! Map) {
      throw FormatException(
        'Capture picker returned ${value.runtimeType}, expected a count map.',
      );
    }

    final selected = _readCount(value, 'selectedCount');
    final imported = _readCount(value, 'importedCount');
    final rejected = _readCount(value, 'rejectedCount');
    if (selected > maxSelectionCount) {
      throw const FormatException(
        'Capture picker selectedCount exceeds the supported maximum.',
      );
    }
    if (imported + rejected != selected) {
      throw const FormatException(
        'Capture picker counts do not account for every selected image.',
      );
    }
    return CapturePickerResult(
      selectedCount: selected,
      importedCount: imported,
      rejectedCount: rejected,
    );
  }

  static int _readCount(Map<dynamic, dynamic> value, String key) {
    final count = value[key];
    if (count is! int || count < 0) {
      throw FormatException(
        'Capture picker $key must be a non-negative integer.',
      );
    }
    return count;
  }
}

enum SharedSourceDeletionResult { deleted, kept, unavailable, failed }

final class MethodChannelIncomingShareService implements IncomingShareService {
  MethodChannelIncomingShareService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingSharesChanged') {
        _pendingController.add(null);
      }
    });
  }

  static const _channel = MethodChannel(
    'com.orialthq.ori_beauty/incoming_share/v1',
  );

  final _pendingController = StreamController<void>.broadcast();

  @override
  Stream<void> get pendingChanged => _pendingController.stream;

  @override
  Future<List<IncomingShare>> drainPending() async {
    final payload = await _channel.invokeListMethod<Object?>(
      'drainPendingShares',
    );
    if (payload == null) {
      return const [];
    }

    return payload
        .whereType<Map<Object?, Object?>>()
        .map(IncomingShare.fromPlatformMap)
        .toList(growable: false);
  }

  @override
  Future<CapturePickerResult> presentCapturePicker() async {
    final value = await _channel.invokeMethod<Object?>('presentCapturePicker');
    return CapturePickerResult.fromPlatformValue(value);
  }

  @override
  Future<void> acknowledge(Iterable<String> ids) {
    return _channel.invokeMethod<void>('acknowledgeShares', <String, Object?>{
      'ids': ids.toList(growable: false),
    });
  }

  @override
  Future<SharedSourceDeletionResult> deleteSharedSource(
    String transportId,
  ) async {
    final value = await _channel.invokeMethod<String>('deleteSharedSource', {
      'transportId': transportId,
    });
    return switch (value) {
      'deleted' => SharedSourceDeletionResult.deleted,
      'kept' => SharedSourceDeletionResult.kept,
      'unavailable' => SharedSourceDeletionResult.unavailable,
      _ => SharedSourceDeletionResult.failed,
    };
  }

  @override
  Future<void> keepSharedSource(String transportId) {
    return _channel.invokeMethod<void>('keepSharedSource', {
      'transportId': transportId,
    });
  }

  @override
  Future<void> dispose() => _pendingController.close();
}

final class InMemoryIncomingShareService implements IncomingShareService {
  final _pendingController = StreamController<void>.broadcast();
  final List<IncomingShare> _shares = [];

  @override
  Stream<void> get pendingChanged => _pendingController.stream;

  void add(IncomingShare share) {
    _shares.add(share);
    _pendingController.add(null);
  }

  @override
  Future<List<IncomingShare>> drainPending() async =>
      List.unmodifiable(_shares);

  /// Number of times [presentCapturePicker] was called, for widget tests.
  int presentCapturePickerCount = 0;

  /// Value [presentCapturePicker] resolves to, for widget tests.
  CapturePickerResult capturePickerResult =
      const CapturePickerResult.cancelled();

  /// Optional platform failure thrown by [presentCapturePicker].
  PlatformException? capturePickerError;

  /// Optional delay used to keep the picker in flight during widget tests.
  Duration capturePickerDelay = Duration.zero;

  /// Compatibility control retained for existing single-image widget tests.
  bool get capturePickerAccepts => capturePickerResult.importedCount > 0;

  set capturePickerAccepts(bool value) {
    capturePickerResult = value
        ? const CapturePickerResult(
            selectedCount: 1,
            importedCount: 1,
            rejectedCount: 0,
          )
        : const CapturePickerResult.cancelled();
  }

  @override
  Future<CapturePickerResult> presentCapturePicker() async {
    presentCapturePickerCount += 1;
    if (capturePickerDelay > Duration.zero) {
      await Future<void>.delayed(capturePickerDelay);
    }
    final error = capturePickerError;
    if (error != null) throw error;
    return capturePickerResult;
  }

  @override
  Future<void> acknowledge(Iterable<String> ids) async {
    _shares.removeWhere((share) => ids.contains(share.id));
  }

  @override
  Future<SharedSourceDeletionResult> deleteSharedSource(
    String transportId,
  ) async => SharedSourceDeletionResult.unavailable;

  @override
  Future<void> keepSharedSource(String transportId) async {}

  @override
  Future<void> dispose() => _pendingController.close();
}
