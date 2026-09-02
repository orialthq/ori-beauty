import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'analysis_server.dart';
import 'content_analysis_service.dart';

final class AnalysisServiceException implements Exception {
  const AnalysisServiceException(
    this.code, {
    this.retryable = false,
    this.requestId,
  });

  final String code;
  final bool retryable;
  final String? requestId;

  @override
  String toString() => 'AnalysisServiceException($code)';
}

/// Keeps deterministic text analysis on-device and sends only image captures to
/// the user-controlled analysis server. The OpenAI credential never enters the
/// Flutter process.
final class RemoteContentAnalysisService implements ContentAnalysisService {
  const RemoteContentAnalysisService({
    this.baseUrl,
    this.timeout = const Duration(seconds: 90),
    this.fallback = const BaselineContentAnalysisService(),
    this.vocabulary,
  });

  /// The most of the reader's words one request carries. Past this the list
  /// is longer than the model reads carefully, and the tail is the words used
  /// once, which are the ones least worth steering towards.
  static const maxVocabulary = 300;

  /// Null until a build names one, which leaves the platform default to stand.
  final String? baseUrl;
  final Duration timeout;
  final BaselineContentAnalysisService fallback;

  /// The words the reader's library already files under, asked for at the
  /// moment of each request so a capture is tagged against the library as it
  /// is then. Sent so the analysis reuses a word already in use rather than
  /// coining its own spelling of it; the model never learns which capture any
  /// word sits on. Null sends nothing, which is what a build without a
  /// library does.
  final List<TagVocabularyEntry> Function()? vocabulary;

  String get _serverUrl => baseUrl ?? defaultAnalysisBaseUrl();

  @override
  CaptureRecord analyzeShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) {
    if (share.attachments.isEmpty) {
      return fallback.analyzeShare(share, origin: origin);
    }
    return prepareShare(share, origin: origin);
  }

  @override
  CaptureRecord prepareShare(
    IncomingShare share, {
    CaptureOrigin origin = CaptureOrigin.androidShare,
  }) {
    return fallback.prepareShare(share, origin: origin);
  }

  @override
  Future<AnalysisRun> analyze(CaptureRecord capture) async {
    final startedAt = DateTime.now();
    if (capture.raw.attachments.isEmpty) {
      return fallback.analyze(capture);
    }
    if (capture.raw.attachments.length != 1) {
      throw const AnalysisServiceException('multiple_images_not_supported');
    }

    final endpoint = Uri.tryParse(_serverUrl)?.resolve('/v1/analyze');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      throw const AnalysisServiceException('invalid_server_url');
    }

    final attachment = capture.raw.attachments.first;
    if (attachment.byteSize > 12 * 1024 * 1024) {
      throw const AnalysisServiceException('image_too_large');
    }
    final file = File(attachment.filePath);
    if (!await file.exists()) {
      throw const AnalysisServiceException('source_file_missing');
    }

    final bytes = await file.readAsBytes();
    if (bytes.length != attachment.byteSize) {
      throw const AnalysisServiceException('source_file_changed');
    }
    final words = (vocabulary?.call() ?? const <TagVocabularyEntry>[])
        .where((entry) => entry.count > 0 && isValidTagName(entry.value))
        .take(maxVocabulary)
        .toList(growable: false);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(
        jsonEncode({
          'image': {
            'mimeType': attachment.mimeType,
            'base64': base64Encode(bytes),
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
        }),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      Object? decoded;
      try {
        decoded = jsonDecode(body);
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
      late final StructuredContentAnalysis structured;
      try {
        structured = StructuredContentAnalysis.fromJson(decoded);
      } on Object {
        throw const AnalysisServiceException('invalid_analysis_response');
      }
      final evidence = structured.evidence
          .map(
            (item) => EvidenceRef(
              id: item.id,
              captureId: capture.raw.id,
              kind: EvidenceKind.imageRegion,
              quote: item.text,
              attachmentId: attachment.id,
              region: item.region,
            ),
          )
          .toList(growable: false);

      return AnalysisRun(
        id:
            'analysis-${capture.raw.transportEventId}-'
            '${DateTime.now().microsecondsSinceEpoch}',
        inputId: capture.raw.id,
        normalizerVersion: capture.normalized.normalizerVersion,
        analyzerVersion: 'luna-structured-v1',
        status: AnalysisRunStatus.succeeded,
        startedAt: startedAt,
        completedAt: DateTime.now(),
        evidence: evidence,
        productMentions: const [],
        statements: const [],
        disclosure: DisclosureObservation.unknown,
        model: structured.model,
        structuredContent: structured,
      );
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

  static String? _boundedMetadata(String? value, int maxLength) {
    if (value == null || value.length > maxLength) {
      return null;
    }
    return value;
  }

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
    final root = decoded is Map<String, Object?> ? decoded : null;
    final rawError = root?['error'];
    final error = rawError is Map<String, Object?> ? rawError : null;
    final upstreamCode = error?['code'];
    final retryable = error?['retryable'] as bool? ?? false;
    final rawRequestId = error?['requestId'];
    final requestId =
        rawRequestId is String &&
            RegExp(r'^[A-Za-z0-9-]{1,80}$').hasMatch(rawRequestId)
        ? rawRequestId
        : null;
    final code = switch (upstreamCode) {
      'IMAGE_TOO_LARGE' || 'PAYLOAD_TOO_LARGE' => 'image_too_large',
      'INVALID_IMAGE' || 'UNSUPPORTED_MEDIA_TYPE' => 'invalid_image',
      'UPSTREAM_TIMEOUT' || 'REQUEST_TIMEOUT' => 'analysis_timed_out',
      'UPSTREAM_RATE_LIMITED' => 'rate_limited',
      'SERVICE_NOT_CONFIGURED' => 'analysis_service_not_configured',
      'UPSTREAM_REJECTED' => 'analysis_request_rejected',
      'INVALID_MODEL_RESPONSE' => 'invalid_analysis_response',
      'UPSTREAM_UNAVAILABLE' => 'analysis_service_unavailable',
      _ => switch (statusCode) {
        401 || 403 => 'server_auth_failed',
        413 => 'image_too_large',
        429 => 'rate_limited',
        504 => 'analysis_timed_out',
        >= 500 => 'analysis_service_unavailable',
        _ => 'analysis_request_rejected',
      },
    };
    return AnalysisServiceException(
      code,
      retryable: retryable,
      requestId: requestId,
    );
  }
}
