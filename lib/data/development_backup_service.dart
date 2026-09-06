import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'app_snapshot_store.dart';
import '../domain/models.dart';

typedef DevelopmentBackupDirectoryProvider = Future<Directory> Function();
typedef DevelopmentBackupShare = Future<void> Function(File archive);
typedef DevelopmentBackupRestoreDirectoryProvider =
    Future<Directory> Function();

final class DevelopmentBackupRestoreException implements Exception {
  const DevelopmentBackupRestoreException(this.code);

  final String code;

  @override
  String toString() => 'DevelopmentBackupRestoreException($code)';
}

final class DevelopmentBackupRestorePlan {
  DevelopmentBackupRestorePlan._(
    this._stagingDirectory,
    this._destinationDirectory, {
    required this.captures,
    required this.tagSenses,
    required this.imageCount,
    required this.imageBytes,
  });

  final List<PersistedCapture> captures;
  final Map<String, List<String>> tagSenses;
  final int imageCount;
  final int imageBytes;
  final Directory _stagingDirectory;
  final Directory _destinationDirectory;
  bool _consumed = false;

  int get captureCount => captures.length;

  Future<DevelopmentBackupInstalledFiles> installAttachments() async {
    if (_consumed) {
      throw const DevelopmentBackupRestoreException('restore_plan_consumed');
    }
    _consumed = true;
    await _destinationDirectory.create(recursive: true);
    final newlyInstalled = <File>[];
    try {
      for (final entity in _stagingDirectory.listSync(followLinks: false)) {
        if (entity is! File) {
          throw const DevelopmentBackupRestoreException('invalid_backup');
        }
        final name = entity.uri.pathSegments.last;
        final destination = File(
          '${_destinationDirectory.path}${Platform.pathSeparator}$name',
        );
        if (await destination.exists()) {
          if (await destination.length() != await entity.length() ||
              (await sha256.bind(destination.openRead()).first).toString() !=
                  (await sha256.bind(entity.openRead()).first).toString()) {
            throw const DevelopmentBackupRestoreException(
              'attachment_conflict',
            );
          }
          continue;
        }
        await entity.rename(destination.path);
        newlyInstalled.add(destination);
      }
      return DevelopmentBackupInstalledFiles._(newlyInstalled);
    } catch (_) {
      await DevelopmentBackupInstalledFiles._(newlyInstalled).rollback();
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (await _stagingDirectory.exists()) {
      await _stagingDirectory.delete(recursive: true);
    }
  }
}

final class DevelopmentBackupInstalledFiles {
  const DevelopmentBackupInstalledFiles._(this._files);

  final List<File> _files;

  Future<void> rollback() async {
    for (final file in _files.reversed) {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // The snapshot still points at the previous data. A private orphan is
        // safer than deleting an unrelated file after a rollback race.
      }
    }
  }
}

final class DevelopmentBackupRestoreResult {
  const DevelopmentBackupRestoreResult({
    required this.captureCount,
    required this.imageCount,
  });

  final int captureCount;
  final int imageCount;
}

/// Builds the deliberately temporary, development-only full-library backup.
///
/// Images are streamed into the ZIP rather than accumulated in memory. The
/// manifest uses the normal app snapshot codec, with only its device-local
/// attachment paths rewritten so the archive is portable.
final class DevelopmentBackupService {
  const DevelopmentBackupService({
    this.directoryProvider,
    this.share,
    this.restoreDirectoryProvider,
  });

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static final RegExp _completedBackupPattern = RegExp(
    r'^trun-on-backup-\d{8}-\d{6}(?:-\d+)?\.zip$',
  );
  static const String _buildDirectoryPrefix = '.trun-on-backup-build-';
  static const int maxRestoreArchiveBytes = 600 * 1024 * 1024;
  static const int maxRestoreManifestBytes = 16 * 1024 * 1024;
  static const int maxRestoreImageBytes = 512 * 1024 * 1024;
  static const int maxRestoreCaptures = 10 * 1000;

  final DevelopmentBackupDirectoryProvider? directoryProvider;
  final DevelopmentBackupShare? share;
  final DevelopmentBackupRestoreDirectoryProvider? restoreDirectoryProvider;

  Future<DevelopmentBackupRestorePlan> inspectArchive(File archive) async {
    final destination =
        await (restoreDirectoryProvider?.call() ?? _defaultRestoreDirectory());
    await destination.parent.create(recursive: true);
    final prepared = await Isolate.run(
      () => _inspectDevelopmentBackupArchive(
        archivePath: archive.path,
        destinationDirectoryPath: destination.path,
      ),
    );
    try {
      return DevelopmentBackupRestorePlan._(
        Directory(prepared['stagingDirectory']! as String),
        destination,
        captures: (prepared['captures']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map(PersistedCapture.fromJson)
            .toList(growable: false),
        tagSenses: {
          for (final entry
              in (prepared['tagSenses']! as Map<String, Object?>).entries)
            entry.key: List<String>.unmodifiable(
              (entry.value! as List<Object?>).cast<String>(),
            ),
        },
        imageCount: prepared['imageCount']! as int,
        imageBytes: prepared['imageBytes']! as int,
      );
    } catch (_) {
      final staging = Directory(prepared['stagingDirectory']! as String);
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<File> createAndShare({
    required List<PersistedCapture> captures,
    required Map<String, List<String>> tagSenses,
  }) async {
    final archive = await createArchive(
      captures: captures,
      tagSenses: tagSenses,
    );
    final shareArchive = share;
    if (shareArchive != null) {
      await shareArchive(archive);
    } else {
      await SharePlus.instance.share(
        ShareParams(
          title: 'luffi 개발 데이터 백업',
          subject: 'luffi 개발 데이터 백업',
          text: '가져온 콘텐츠와 앱이 보관한 이미지 사본의 개발용 백업이에요.',
          files: [XFile(archive.path, mimeType: 'application/zip')],
          fileNameOverrides: [archive.uri.pathSegments.last],
        ),
      );
    }
    return archive;
  }

  Future<File> createArchive({
    required List<PersistedCapture> captures,
    required Map<String, List<String>> tagSenses,
    Directory? outputDirectory,
    DateTime? createdAt,
  }) async {
    final userCaptures = captures
        .where((capture) => capture.origin != CaptureOrigin.demo)
        .toList(growable: false);
    final destination =
        outputDirectory ??
        await (directoryProvider?.call() ?? _defaultDirectory());
    await destination.create(recursive: true);
    final timestamp = createdAt ?? DateTime.now();
    final archivePath =
        '${destination.path}${Platform.pathSeparator}'
        'trun-on-backup-${_timestamp(timestamp)}.zip';
    final completedPath = await Isolate.run(
      () => _writeDevelopmentBackupArchive(
        serializedCaptures: [
          for (final capture in userCaptures) _serializeCapture(capture),
        ],
        tagSenses: {
          for (final entry in tagSenses.entries)
            entry.key: List<String>.of(entry.value),
        },
        requestedArchivePath: archivePath,
        cleanupPreviousBackups: outputDirectory == null,
      ),
    );
    return File(completedPath);
  }

  static Future<Directory> _defaultDirectory() async => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'trun_on_development_backups',
  );

  static Future<Directory> _defaultRestoreDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}ori_library_attachments',
  );

  static String _archivePath(String sha256, String mimeType) {
    final normalizedSha256 = _normalizeSha256(sha256);
    final extension = switch (mimeType) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => throw const FormatException('Unsupported backup attachment type.'),
    };
    return 'attachments/$normalizedSha256.$extension';
  }

  static String _normalizeSha256(String sha256) {
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw const FormatException(
        'Backup attachment SHA-256 must be exactly 64 hexadecimal characters.',
      );
    }
    return sha256.toLowerCase();
  }

  static Map<String, Object?> _serializeCapture(PersistedCapture capture) {
    return <String, Object?>{
      ...capture.toJson(),
      'attachments': [
        for (final attachment in capture.attachments)
          <String, Object?>{
            ...attachment.toJson(),
            'sha256': _normalizeSha256(attachment.sha256),
          },
      ],
    };
  }

  static String _timestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }
}

/// Performs the expensive hashing, CRC calculation and ZIP writes away from
/// Flutter's UI isolate. Only plain JSON-like values cross the isolate boundary.
Future<String> _writeDevelopmentBackupArchive({
  required List<Map<String, Object?>> serializedCaptures,
  required Map<String, List<String>> tagSenses,
  required String requestedArchivePath,
  required bool cleanupPreviousBackups,
}) async {
  final attachmentFiles = <String, File>{};
  final attachmentSizes = <String, int>{};
  final rewritten = <PersistedCapture>[];

  for (final serialized in serializedCaptures) {
    final capture = PersistedCapture.fromJson(serialized);
    final json = Map<String, Object?>.from(serialized);
    json['attachments'] = [
      for (final attachment in capture.attachments)
        <String, Object?>{
          ...attachment.toJson(),
          'filePath': DevelopmentBackupService._archivePath(
            attachment.sha256,
            attachment.mimeType,
          ),
        },
    ];
    rewritten.add(PersistedCapture.fromJson(json));
    for (final attachment in capture.attachments) {
      final archivePath = DevelopmentBackupService._archivePath(
        attachment.sha256,
        attachment.mimeType,
      );
      final previousSize = attachmentSizes[archivePath];
      if (previousSize != null && previousSize != attachment.byteSize) {
        throw FileSystemException(
          'Backup attachments with the same hash disagree on size.',
          attachment.filePath,
        );
      }
      attachmentSizes[archivePath] = attachment.byteSize;
      attachmentFiles.putIfAbsent(archivePath, () => File(attachment.filePath));
    }
  }

  for (final entry in attachmentFiles.entries) {
    final file = entry.value;
    if (!await file.exists()) {
      throw FileSystemException('A backup attachment is missing.', file.path);
    }
    if (await file.length() != attachmentSizes[entry.key]) {
      throw FileSystemException(
        'A backup attachment does not match its metadata.',
        file.path,
      );
    }
    final digest = await sha256.bind(file.openRead()).first;
    final expectedHash = entry.key
        .split('/')
        .last
        .split('.')
        .first
        .toLowerCase();
    if (digest.toString() != expectedHash) {
      throw FileSystemException(
        'A backup attachment checksum does not match its metadata.',
        file.path,
      );
    }
  }

  final requested = File(requestedArchivePath);
  final directory = requested.parent;
  final buildDirectory = await directory.createTemp(
    DevelopmentBackupService._buildDirectoryPrefix,
  );
  final temporaryArchive = File(
    '${buildDirectory.path}${Platform.pathSeparator}backup.zip',
  );

  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    encoder.create(temporaryArchive.path);
    opened = true;
    encoder.addArchiveFile(
      ArchiveFile.string(
        'manifest.json',
        AppSnapshotCodec.encode(rewritten, tagSenses: tagSenses),
      ),
    );
    for (final entry in attachmentFiles.entries) {
      // JPEG/PNG/WebP bytes are already compressed. STORE keeps this path
      // streaming and avoids wasting CPU trying to compress them again.
      await encoder.addFile(entry.value, entry.key, ZipFileEncoder.STORE);
    }
    await encoder.close();
    opened = false;

    final archive = await _nextAvailableArchive(requested);
    await temporaryArchive.rename(archive.path);
    if (cleanupPreviousBackups) {
      await _cleanupPreviousBackups(directory, keeping: archive);
    }
    return archive.path;
  } finally {
    if (opened) {
      try {
        await encoder.close();
      } on Object {
        // The original archive error is the useful one.
      }
    }
    if (await buildDirectory.exists()) {
      try {
        await buildDirectory.delete(recursive: true);
      } on Object {
        // A later successful export also removes stale app build directories.
      }
    }
  }
}

Future<Map<String, Object?>> _inspectDevelopmentBackupArchive({
  required String archivePath,
  required String destinationDirectoryPath,
}) async {
  final source = File(archivePath);
  if (!await source.exists()) {
    throw const DevelopmentBackupRestoreException('backup_missing');
  }
  final archiveBytes = await source.length();
  if (archiveBytes <= 0 ||
      archiveBytes > DevelopmentBackupService.maxRestoreArchiveBytes) {
    throw const DevelopmentBackupRestoreException('backup_too_large');
  }

  final input = InputFileStream(source.path);
  late final Archive decoded;
  try {
    decoded = ZipDecoder().decodeBuffer(input);
  } on Object {
    await input.close();
    throw const DevelopmentBackupRestoreException('invalid_backup');
  }

  Directory? staging;
  try {
    if (decoded.files.length >
        DevelopmentBackupService.maxRestoreCaptures + 1) {
      throw const DevelopmentBackupRestoreException('invalid_backup');
    }
    final entries = <String, ArchiveFile>{};
    var totalBytes = 0;
    for (final entry in decoded.files) {
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          entry.name.isEmpty ||
          entries.containsKey(entry.name) ||
          entry.size < 0) {
        throw const DevelopmentBackupRestoreException('invalid_backup');
      }
      final validName =
          entry.name == 'manifest.json' ||
          RegExp(
            r'^attachments/[0-9a-f]{64}\.(?:jpg|png|webp)$',
          ).hasMatch(entry.name);
      if (!validName) {
        throw const DevelopmentBackupRestoreException('invalid_backup');
      }
      totalBytes += entry.size;
      if (totalBytes >
          DevelopmentBackupService.maxRestoreImageBytes +
              DevelopmentBackupService.maxRestoreManifestBytes) {
        throw const DevelopmentBackupRestoreException('backup_too_large');
      }
      entries[entry.name] = entry;
    }

    final manifestEntry = entries['manifest.json'];
    if (manifestEntry == null ||
        manifestEntry.size <= 0 ||
        manifestEntry.size > DevelopmentBackupService.maxRestoreManifestBytes) {
      throw const DevelopmentBackupRestoreException('invalid_backup');
    }
    late final String manifest;
    try {
      manifest = utf8.decode(
        (manifestEntry.content as List<int>),
        allowMalformed: false,
      );
    } on Object {
      throw const DevelopmentBackupRestoreException('invalid_backup');
    }
    final captures = AppSnapshotCodec.decode(manifest);
    if (captures.length > DevelopmentBackupService.maxRestoreCaptures ||
        captures.any((capture) => capture.origin == CaptureOrigin.demo) ||
        captures.map((capture) => capture.transportEventId).toSet().length !=
            captures.length) {
      throw const DevelopmentBackupRestoreException('invalid_backup');
    }

    final requiredAttachments = <String, IncomingAttachment>{};
    for (final capture in captures) {
      for (final attachment in capture.attachments) {
        final expected = DevelopmentBackupService._archivePath(
          attachment.sha256,
          attachment.mimeType,
        );
        if (attachment.filePath != expected) {
          throw const DevelopmentBackupRestoreException('invalid_backup');
        }
        final previous = requiredAttachments[expected];
        if (previous != null &&
            (previous.byteSize != attachment.byteSize ||
                previous.mimeType != attachment.mimeType)) {
          throw const DevelopmentBackupRestoreException('invalid_backup');
        }
        requiredAttachments[expected] = attachment;
      }
    }
    final archivedAttachmentNames = entries.keys
        .where((name) => name.startsWith('attachments/'))
        .toSet();
    if (archivedAttachmentNames.length != requiredAttachments.length ||
        !archivedAttachmentNames.containsAll(requiredAttachments.keys)) {
      throw const DevelopmentBackupRestoreException('invalid_backup');
    }
    final imageBytes = requiredAttachments.values.fold<int>(
      0,
      (sum, attachment) => sum + attachment.byteSize,
    );
    if (imageBytes > DevelopmentBackupService.maxRestoreImageBytes) {
      throw const DevelopmentBackupRestoreException('backup_too_large');
    }

    final destination = Directory(destinationDirectoryPath);
    staging = await destination.parent.createTemp('.luffi-restore-stage-');
    for (final item in requiredAttachments.entries) {
      final entry = entries[item.key];
      final attachment = item.value;
      if (entry == null || entry.size != attachment.byteSize) {
        throw const DevelopmentBackupRestoreException(
          'attachment_checksum_failed',
        );
      }
      final filename = item.key.split('/').last;
      final stagedFile = File(
        '${staging.path}${Platform.pathSeparator}$filename',
      );
      final output = OutputFileStream(stagedFile.path);
      try {
        entry.writeContent(output);
      } on Object {
        throw const DevelopmentBackupRestoreException('invalid_backup');
      } finally {
        output.closeSync();
      }
      if (await stagedFile.length() != attachment.byteSize ||
          (await sha256.bind(stagedFile.openRead()).first).toString() !=
              attachment.sha256.toLowerCase() ||
          !await _hasExpectedBackupMagic(stagedFile, attachment.mimeType)) {
        throw const DevelopmentBackupRestoreException(
          'attachment_checksum_failed',
        );
      }
    }

    final rewritten = <Map<String, Object?>>[];
    for (final capture in captures) {
      final json = capture.toJson();
      json['attachments'] = [
        for (final attachment in capture.attachments)
          <String, Object?>{
            ...attachment.toJson(),
            'filePath':
                '$destinationDirectoryPath${Platform.pathSeparator}'
                '${DevelopmentBackupService._archivePath(attachment.sha256, attachment.mimeType).split('/').last}',
          },
      ];
      rewritten.add(PersistedCapture.fromJson(json).toJson());
    }
    return <String, Object?>{
      'captures': rewritten,
      'tagSenses': <String, Object?>{
        for (final entry in AppSnapshotCodec.decodeTagSenses(manifest).entries)
          entry.key: entry.value,
      },
      'imageCount': requiredAttachments.length,
      'imageBytes': imageBytes,
      'stagingDirectory': staging.path,
    };
  } on DevelopmentBackupRestoreException {
    if (staging != null && await staging.exists()) {
      await staging.delete(recursive: true);
    }
    rethrow;
  } on Object {
    if (staging != null && await staging.exists()) {
      await staging.delete(recursive: true);
    }
    throw const DevelopmentBackupRestoreException('invalid_backup');
  } finally {
    await input.close();
  }
}

Future<bool> _hasExpectedBackupMagic(File file, String mimeType) async {
  final input = await file.open();
  try {
    final bytes = await input.read(12);
    return switch (mimeType) {
      'image/jpeg' =>
        bytes.length >= 3 &&
            bytes[0] == 0xff &&
            bytes[1] == 0xd8 &&
            bytes[2] == 0xff,
      'image/png' =>
        bytes.length >= 8 &&
            const <int>[
              0x89,
              0x50,
              0x4e,
              0x47,
              0x0d,
              0x0a,
              0x1a,
              0x0a,
            ].indexed.every((item) => bytes[item.$1] == item.$2),
      'image/webp' =>
        bytes.length >= 12 &&
            ascii.decode(bytes.sublist(0, 4)) == 'RIFF' &&
            ascii.decode(bytes.sublist(8, 12)) == 'WEBP',
      _ => false,
    };
  } finally {
    await input.close();
  }
}

Future<File> _nextAvailableArchive(File requested) async {
  var archive = requested;
  var suffix = 2;
  while (await FileSystemEntity.type(archive.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final base = requested.path.substring(0, requested.path.length - 4);
    archive = File('$base-$suffix.zip');
    suffix += 1;
  }
  return archive;
}

Future<void> _cleanupPreviousBackups(
  Directory directory, {
  required File keeping,
}) async {
  try {
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final isPreviousBackup =
          entity is File &&
          entity.path != keeping.path &&
          DevelopmentBackupService._completedBackupPattern.hasMatch(name);
      final isStaleBuildDirectory =
          entity is Directory &&
          name.startsWith(DevelopmentBackupService._buildDirectoryPrefix);
      if (!isPreviousBackup && !isStaleBuildDirectory) continue;
      try {
        await entity.delete(recursive: isStaleBuildDirectory);
      } on Object {
        // Stale temp exports should not make a completed backup fail.
      }
    }
  } on Object {
    // The newly completed archive is still usable if best-effort cleanup fails.
  }
}
