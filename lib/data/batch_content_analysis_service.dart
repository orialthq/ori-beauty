import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/models.dart';
import 'analysis_server.dart';
import 'remote_content_analysis_service.dart';

abstract interface class BatchContentAnalysisService {
  Future<BatchAnalysisResponse> submit(
    CaptureRecord capture, {
    required String requestId,
  });

  Future<List<BatchAnalysisResponse>> poll(List<String> requestIds);
}

final class BatchAnalysisResponse {
  const BatchAnalysisResponse({
    required this.requestId,
    required this.status,
    this.result,
    this.errorCode,
    this.retryable = false,
  });

  static const statuses = {
    'queued',
    'submitted',
    'in_progress',
    'completed',
    'failed',
    'expired',
    'cancelled',
    'submission_unknown',
    'missing',
  };

  final String requestId;
  final String status;
  final StructuredContentAnalysis? result;
  final String? errorCode;
  final bool retryable;

  factory BatchAnalysisResponse.fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    final status = json['status'];
    final rawResult = json['result'];
    final rawError = json['error'];
    if (requestId is! String ||
        !_isRequestId(requestId) ||
        status is! String ||
        !statuses.contains(status) ||
        (rawResult != null && rawResult is! Map<String, Object?>) ||
        (rawError != null && rawError is! Map<String, Object?>)) {
      throw const FormatException('Batch task is invalid.');
    }
    if ((status == 'completed') != (rawResult != null) ||
        (status == 'completed' && rawError != null)) {
      throw const FormatException('Batch task result is inconsistent.');
    }
    String? errorCode;
    var retryable = false;
    if (rawError is Map<String, Object?>) {
      final code = rawError['code'];
      final canRetry = rawError['retryable'];
      if (code is! String ||
          !RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(code) ||
          canRetry is! bool) {
        throw const FormatException('Batch task error is invalid.');
      }
      errorCode = _normalizedErrorCode(code);
      retryable = canRetry;
    }
    final result = rawResult is Map<String, Object?>
        ? StructuredContentAnalysis.fromJson(rawResult)
        : null;
    // Portable tips are a local snapshot format, never an image-model result.
    if (result != null && result.model != 'gpt-5.6-luna') {
      throw const FormatException('Batch analysis model is invalid.');
    }
    return BatchAnalysisResponse(
      requestId: requestId,
      status: status,
      result: result,
      errorCode: errorCode,
      retryable: retryable,
    );
  }

  AnalysisRun toAnalysisRun(CaptureRecord capture) {
    final structured = result;
    if (status != 'completed' ||
        structured == null ||
        capture.raw.attachments.length != 1 ||
        (capture.batchRequestId != null &&
            capture.batchRequestId != requestId)) {
      throw const AnalysisServiceException('invalid_analysis_response');
    }
    final attachment = capture.raw.attachments.single;
    return AnalysisRun(
      id: 'analysis-batch-$requestId',
      inputId: capture.raw.id,
      normalizerVersion: capture.normalized.normalizerVersion,
      analyzerVersion: 'luna-structured-batch-v1',
      status: AnalysisRunStatus.succeeded,
      completedAt: DateTime.now(),
      evidence: [
        for (final item in structured.evidence)
          EvidenceRef(
            id: item.id,
            captureId: capture.raw.id,
            kind: EvidenceKind.imageRegion,
            quote: item.text,
            attachmentId: attachment.id,
            region: item.region,
          ),
      ],
      productMentions: const [],
      statements: const [],
      disclosure: DisclosureObservation.unknown,
      model: structured.model,
      structuredContent: structured,
    );
  }
}

/// Uploads a durable task once, then polls by its opaque identity. Credentials
/// and the long-running OpenAI Batch job remain on the analysis server.
final class RemoteBatchContentAnalysisService
    implements BatchContentAnalysisService {
  const RemoteBatchContentAnalysisService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 90),
    this.vocabulary,
  });

  static const maxPollTasks = 100;
  static const _maxImageBytes = 12 * 1024 * 1024;
  static const _maxResponseBytes = 32 * 1024 * 1024;

  final String? baseUrl;
  final Duration timeout;
  final List<TagVocabularyEntry> Function()? vocabulary;

  @override
  Future<BatchAnalysisResponse> submit(
    CaptureRecord capture, {
    required String requestId,
  }) async {
    _validateRequestIds([requestId]);
    final input = await _input(capture);
    final decoded = await _post('/v1/analysis-tasks', {
      'requestId': requestId,
      'input': input,
    });
    final task = _parseTask(decoded);
    if (task.requestId != requestId) {
      throw const AnalysisServiceException('invalid_analysis_response');
    }
    return task;
  }

  @override
  Future<List<BatchAnalysisResponse>> poll(List<String> requestIds) async {
    if (requestIds.isEmpty) return const [];
    _validateRequestIds(requestIds);
    final decoded = await _post('/v1/analysis-tasks/status', {
      'requestIds': requestIds,
    });
    final rawTasks = decoded['tasks'];
    if (rawTasks is! List<Object?> || rawTasks.length != requestIds.length) {
      throw const AnalysisServiceException('invalid_analysis_response');
    }
    final expected = requestIds.toSet();
    final tasks = <String, BatchAnalysisResponse>{};
    for (final rawTask in rawTasks) {
      final task = _parseTask(rawTask);
      if (!expected.contains(task.requestId) ||
          tasks.containsKey(task.requestId)) {
        throw const AnalysisServiceException('invalid_analysis_response');
      }
      tasks[task.requestId] = task;
    }
    // Correlate by identity even when a server returns completion order.
    return [for (final id in requestIds) tasks[id]!];
  }

  Future<Map<String, Object?>> _input(CaptureRecord capture) async {
    if (capture.raw.attachments.length != 1) {
      throw const AnalysisServiceException('multiple_images_not_supported');
    }
    final attachment = capture.raw.attachments.single;
    if (attachment.byteSize > _maxImageBytes) {
      throw const AnalysisServiceException('image_too_large');
    }
    if (attachment.byteSize <= 0) {
      throw const AnalysisServiceException('invalid_image');
    }
    final file = File(attachment.filePath);
    if (!await file.exists()) {
      throw const AnalysisServiceException('source_file_missing');
    }
    try {
      if (await file.length() != attachment.byteSize) {
        throw const AnalysisServiceException('source_file_changed');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > _maxImageBytes) {
          throw const AnalysisServiceException('source_file_changed');
        }
        bytes.add(chunk);
      }
      if (bytes.length != attachment.byteSize) {
        throw const AnalysisServiceException('source_file_changed');
      }
      final words = (vocabulary?.call() ?? const <TagVocabularyEntry>[])
          .where((entry) => entry.count > 0 && isValidTagName(entry.value))
          .take(RemoteContentAnalysisService.maxVocabulary)
          .toList(growable: false);
      return {
        'image': {
          'mimeType': attachment.mimeType,
          'base64': base64Encode(bytes.takeBytes()),
        },
        'capture': {
          'id': capture.raw.id,
          'sourceApp': _boundedMetadata(capture.raw.sourcePackage, 64),
          'sourceUrl': _sourceOrigin(capture.raw.rawUrl),
          'capturedAt': capture.raw.receivedAt.toUtc().toIso8601String(),
          'locale': 'ko-KR',
        },
        if (words.isNotEmpty)
          'vocabulary': [
            for (final entry in words)
              {'value': entry.value, 'count': entry.count},
          ],
      };
    } on FileSystemException {
      throw const AnalysisServiceException('source_file_missing');
    }
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> payload,
  ) async {
    final endpoint = Uri.tryParse(
      baseUrl ?? defaultAnalysisBaseUrl(),
    )?.resolve(path);
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      throw const AnalysisServiceException('invalid_server_url');
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > _maxResponseBytes) {
          throw const AnalysisServiceException('invalid_analysis_response');
        }
        bytes.add(chunk);
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      } on FormatException {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          throw const AnalysisServiceException('invalid_analysis_response');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _serverError(response.statusCode, decoded);
      }
      if (decoded is! Map<String, Object?>) {
        throw const AnalysisServiceException('invalid_analysis_response');
      }
      return decoded;
    } on AnalysisServiceException {
      rethrow;
    } on SocketException {
      throw const AnalysisServiceException(
        'analysis_server_unreachable',
        retryable: true,
      );
    } on HttpException {
      throw const AnalysisServiceException(
        'analysis_transport_failed',
        retryable: true,
      );
    } on FormatException {
      throw const AnalysisServiceException('invalid_analysis_response');
    } on TimeoutException {
      throw const AnalysisServiceException(
        'analysis_timed_out',
        retryable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  static BatchAnalysisResponse _parseTask(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      throw const AnalysisServiceException('invalid_analysis_response');
    }
    try {
      return BatchAnalysisResponse.fromJson(decoded);
    } on FormatException {
      throw const AnalysisServiceException('invalid_analysis_response');
    }
  }

  static void _validateRequestIds(List<String> requestIds) {
    if (requestIds.length > maxPollTasks ||
        requestIds.any((id) => !_isRequestId(id)) ||
        requestIds.toSet().length != requestIds.length) {
      throw const AnalysisServiceException('invalid_batch_request_ids');
    }
  }

  static String? _boundedMetadata(String? value, int maxLength) =>
      value == null || value.length > maxLength ? null : value;

  static String? _sourceOrigin(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return Uri(scheme: uri.scheme, host: uri.host).toString();
  }

  static AnalysisServiceException _serverError(
    int statusCode,
    Object? decoded,
  ) {
    final rawError = decoded is Map<String, Object?> ? decoded['error'] : null;
    final error = rawError is Map<String, Object?> ? rawError : null;
    final rawCode = error?['code'];
    final rawRetryable = error?['retryable'];
    final code = rawCode is String
        ? _normalizedErrorCode(rawCode)
        : switch (statusCode) {
            401 || 403 => 'server_auth_failed',
            413 => 'image_too_large',
            429 => 'rate_limited',
            504 => 'analysis_timed_out',
            >= 500 => 'analysis_service_unavailable',
            _ => 'analysis_request_rejected',
          };
    return AnalysisServiceException(
      code,
      retryable: rawRetryable is bool ? rawRetryable : statusCode >= 500,
    );
  }
}

bool _isRequestId(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String _normalizedErrorCode(String code) => switch (code) {
  'IMAGE_TOO_LARGE' || 'PAYLOAD_TOO_LARGE' => 'image_too_large',
  'INVALID_IMAGE' || 'UNSUPPORTED_MEDIA_TYPE' => 'invalid_image',
  'UPSTREAM_TIMEOUT' || 'REQUEST_TIMEOUT' => 'analysis_timed_out',
  'UPSTREAM_RATE_LIMITED' => 'rate_limited',
  'SERVICE_NOT_CONFIGURED' => 'analysis_service_not_configured',
  'UPSTREAM_REJECTED' => 'analysis_request_rejected',
  'INVALID_MODEL_RESPONSE' => 'invalid_analysis_response',
  'UPSTREAM_UNAVAILABLE' => 'analysis_service_unavailable',
  'REQUEST_ID_CONFLICT' => 'batch_request_conflict',
  'TASK_NOT_FOUND' => 'batch_task_missing',
  _ =>
    RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(code)
        ? code.toLowerCase()
        : 'analysis_request_rejected',
};
