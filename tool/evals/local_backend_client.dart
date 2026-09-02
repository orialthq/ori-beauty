import 'dart:convert';
import 'dart:io';

import 'eval_core.dart';

final class LocalBackendClient implements EvalBackend {
  LocalBackendClient({
    required Uri endpoint,
    String? apiKey,
    HttpClient? httpClient,
    this.maxImageBytes = 12 * 1024 * 1024,
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : endpoint = _validatedLocalEndpoint(endpoint),
       _authorizationHeaderValue = apiKey == null || apiKey.isEmpty
           ? null
           : 'Bearer $apiKey',
       _httpClient = httpClient ?? HttpClient();

  final Uri endpoint;
  final String? _authorizationHeaderValue;
  final HttpClient _httpClient;
  final int maxImageBytes;
  final int maxResponseBytes;

  @override
  Future<Map<String, Object?>> analyze(
    EvalSample sample,
    Directory dataDirectory, {
    EvalVocabulary? vocabulary,
  }) async {
    final imageFile = _resolvePrivateFile(
      dataDirectory,
      sample.input.imageFile,
    );
    final imageBytes = await _readBoundedBytes(
      imageFile,
      maxImageBytes,
      'image_missing',
      'image_too_large',
    );
    HttpClientRequest request;
    try {
      request = await _httpClient.postUrl(endpoint);
    } on Object {
      throw const EvalBackendException('backend_unreachable');
    }
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    if (_authorizationHeaderValue case final value?) {
      request.headers.set(HttpHeaders.authorizationHeader, value);
    }

    final requestBody = jsonEncode({
      'image': {
        'mimeType': sample.input.mimeType,
        'base64': base64Encode(imageBytes),
      },
      'capture': {
        'id': sample.sampleId,
        'sourceApp': 'private-eval',
        'sourceUrl': null,
        'capturedAt': null,
        'locale': 'ko-KR',
      },
      // An empty vocabulary is the same request as none; omitting it keeps the
      // first sample of a growing run identical to a plain run.
      if (vocabulary != null && vocabulary.entries.isNotEmpty)
        'vocabulary': vocabulary.toJson(),
    });

    HttpClientResponse response;
    try {
      request.write(requestBody);
      response = await request.close();
    } on Object {
      throw const EvalBackendException('backend_request_failed');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw EvalBackendException('backend_http_${response.statusCode}');
    }
    if (response.contentLength > maxResponseBytes) {
      await response.drain<void>();
      throw const EvalBackendException('backend_response_too_large');
    }

    final responseBytes = <int>[];
    await for (final chunk in response) {
      responseBytes.addAll(chunk);
      if (responseBytes.length > maxResponseBytes) {
        throw const EvalBackendException('backend_response_too_large');
      }
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(responseBytes));
    } on Object {
      throw const EvalBackendException('backend_response_invalid_json');
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const EvalBackendException('backend_response_invalid_shape');
    }

    final result = <String, Object?>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const EvalBackendException('backend_response_invalid_shape');
      }
      result[key] = entry.value;
    }
    return result;
  }

  void close() {
    _httpClient.close(force: true);
  }

  static Uri _validatedLocalEndpoint(Uri endpoint) {
    const localHosts = {'localhost', '127.0.0.1', '::1'};
    if (!const {'http', 'https'}.contains(endpoint.scheme) ||
        !localHosts.contains(endpoint.host) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.fragment.isNotEmpty) {
      throw const FormatException(
        'Eval endpoint must be a loopback HTTP(S) URL without credentials.',
      );
    }
    return endpoint;
  }

  static File _resolvePrivateFile(
    Directory dataDirectory,
    String relativePath,
  ) {
    final normalized = relativePath.replaceAll(r'\', '/');
    if (normalized.startsWith('/') ||
        normalized.split('/').contains('..') ||
        Uri.tryParse(relativePath)?.hasScheme == true) {
      throw const EvalBackendException('unsafe_local_path');
    }
    return File(
      '${dataDirectory.path}${Platform.pathSeparator}'
      '${normalized.replaceAll('/', Platform.pathSeparator)}',
    );
  }

  static Future<List<int>> _readBoundedBytes(
    File file,
    int maxBytes,
    String missingCode,
    String tooLargeCode,
  ) async {
    FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      throw EvalBackendException(missingCode);
    }
    if (stat.type != FileSystemEntityType.file) {
      throw EvalBackendException(missingCode);
    }
    if (stat.size > maxBytes) {
      throw EvalBackendException(tooLargeCode);
    }
    try {
      return await file.readAsBytes();
    } on Object {
      throw EvalBackendException(missingCode);
    }
  }
}
