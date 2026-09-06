import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:share_plus/share_plus.dart';

import 'app_snapshot_store.dart';
import '../domain/models.dart';

typedef DevelopmentBackupDirectoryProvider = Future<Directory> Function();
typedef DevelopmentBackupShare = Future<void> Function(File archive);

/// Builds the deliberately temporary, development-only full-library backup.
///
/// Images are streamed into the ZIP rather than accumulated in memory. The
/// manifest uses the normal app snapshot codec, with only its device-local
/// attachment paths rewritten so the archive is portable.
final class DevelopmentBackupService {
  const DevelopmentBackupService({this.directoryProvider, this.share});

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static final RegExp _completedBackupPattern = RegExp(
    r'^trun-on-backup-\d{8}-\d{6}(?:-\d+)?\.zip$',
  );
  static const String _buildDirectoryPrefix = '.trun-on-backup-build-';

  final DevelopmentBackupDirectoryProvider? directoryProvider;
  final DevelopmentBackupShare? share;

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
          title: 'Trun On 개발 데이터 백업',
          subject: 'Trun On 개발 데이터 백업',
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
