import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ori_beauty/data/app_snapshot_store.dart';
import 'package:ori_beauty/data/development_backup_service.dart';
import 'package:ori_beauty/domain/models.dart';

void main() {
  test(
    'backup stores one copy of each image and a portable full snapshot',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'trun-on-backup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final image = File('${root.path}/original.jpg');
      const imageBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
      await image.writeAsBytes(imageBytes, flush: true);
      final imageSha256 = sha256.convert(imageBytes).toString();

      PersistedCapture capture(String id, CaptureOrigin origin) =>
          PersistedCapture(
            transportEventId: id,
            receivedAt: DateTime.utc(2026, 9, 6, 10),
            origin: origin,
            sharedText: '원문 $id',
            discoveredUrl: 'https://example.com/$id',
            sourcePackage: 'com.example.gallery',
            mimeType: 'image/jpeg',
            wasTruncated: false,
            originalLength: 5,
            status: CaptureStatus.needsReview,
            reviewId: null,
            reviewResolution: null,
            reviewedAt: null,
            confirmedIdentity: null,
            groupId: null,
            tagOverride: const [
              ContentTag(value: '여행·장소', source: TagSource.user),
            ],
            attachments: [
              IncomingAttachment(
                id: 'attachment-$id',
                filePath: image.path,
                mimeType: 'image/jpeg',
                byteSize: imageBytes.length,
                sha256: imageSha256.toUpperCase(),
                width: 1,
                height: 1,
              ),
            ],
          );

      final zip = await const DevelopmentBackupService().createArchive(
        captures: [
          capture('user-one', CaptureOrigin.androidShare),
          capture('user-two', CaptureOrigin.manual),
          capture('demo-one', CaptureOrigin.demo),
        ],
        tagSenses: const {
          '여행장소': ['나들이', '여행'],
        },
        outputDirectory: root,
        createdAt: DateTime(2026, 9, 6, 10, 11, 12),
      );

      expect(zip.uri.pathSegments.last, 'trun-on-backup-20260906-101112.zip');
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      expect(
        archive.files.map((file) => file.name),
        containsAll(<String>['manifest.json', 'attachments/$imageSha256.jpg']),
      );
      expect(
        archive.files.where((file) => file.name.startsWith('attachments/')),
        hasLength(1),
      );
      expect(
        (archive.findFile('attachments/$imageSha256.jpg')!.content
            as List<int>),
        imageBytes,
      );

      final manifestBytes =
          archive.findFile('manifest.json')!.content as List<int>;
      final manifest = utf8.decode(manifestBytes);
      final restored = AppSnapshotCodec.decode(manifest);
      expect(restored.map((capture) => capture.transportEventId), [
        'user-one',
        'user-two',
      ]);
      expect(restored.first.sharedText, '원문 user-one');
      expect(restored.first.discoveredUrl, 'https://example.com/user-one');
      expect(restored.first.tagOverride?.single.value, '여행·장소');
      expect(restored.first.attachments.single.sha256, imageSha256);
      expect(
        restored
            .expand((capture) => capture.attachments)
            .map((attachment) => attachment.filePath)
            .toSet(),
        {'attachments/$imageSha256.jpg'},
      );
      expect(AppSnapshotCodec.decodeTagSenses(manifest), {
        '여행장소': ['나들이', '여행'],
      });
      expect(manifest, isNot(contains(image.path)));
      expect(manifest, isNot(contains('demo-one')));
    },
  );

  test(
    'backup rejects an image whose bytes no longer match its hash',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'trun-on-corrupt-backup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final image = File('${root.path}/corrupt.jpg');
      const imageBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
      await image.writeAsBytes(imageBytes, flush: true);

      final capture = PersistedCapture(
        transportEventId: 'corrupt-user-image',
        receivedAt: DateTime.utc(2026, 9, 6),
        origin: CaptureOrigin.manual,
        sharedText: '',
        discoveredUrl: null,
        sourcePackage: 'gallery',
        mimeType: 'image/jpeg',
        wasTruncated: false,
        originalLength: 0,
        status: CaptureStatus.needsReview,
        reviewId: null,
        reviewResolution: null,
        reviewedAt: null,
        confirmedIdentity: null,
        groupId: null,
        attachments: [
          IncomingAttachment(
            id: 'corrupt-attachment',
            filePath: image.path,
            mimeType: 'image/jpeg',
            byteSize: imageBytes.length,
            sha256: sha256.convert(const [1, 2, 3, 4]).toString(),
            width: 1,
            height: 1,
          ),
        ],
      );

      await expectLater(
        const DevelopmentBackupService().createArchive(
          captures: [capture],
          tagSenses: const {},
          outputDirectory: root,
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'backup rejects malformed hashes before using them as ZIP paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'trun-on-unsafe-hash-backup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final oldBackup = File('${root.path}/trun-on-backup-20260905-090000.zip');
      await oldBackup.writeAsBytes(const [1, 2, 3], flush: true);
      final image = File('${root.path}/original.jpg');
      const imageBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
      await image.writeAsBytes(imageBytes, flush: true);
      final service = DevelopmentBackupService(
        directoryProvider: () async => root,
      );

      for (final unsafeHash in <String>[
        '../manifest.json',
        List<String>.filled(63, 'a').join(),
        '${List<String>.filled(63, 'a').join()}g',
      ]) {
        await expectLater(
          service.createArchive(
            captures: [
              _captureWithAttachment(
                id: 'unsafe-hash',
                image: image,
                imageBytes: imageBytes,
                imageSha256: unsafeHash,
              ),
            ],
            tagSenses: const {},
            createdAt: DateTime(2026, 9, 6, 10, 11, 12),
          ),
          throwsA(isA<FormatException>()),
        );
      }

      expect(await oldBackup.exists(), isTrue);
      expect(
        root.listSync().whereType<File>().map((file) => file.path),
        contains(oldBackup.path),
      );
    },
  );

  test(
    'successful temporary build keeps only the newly completed app backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'trun-on-backup-cleanup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final oldBackup = File('${root.path}/trun-on-backup-20260905-090000.zip');
      final unrelatedZip = File('${root.path}/trun-on-backup-manual.zip');
      final staleBuildDirectory = Directory(
        '${root.path}/.trun-on-backup-build-abandoned',
      );
      await oldBackup.writeAsBytes(const [1, 2, 3], flush: true);
      await unrelatedZip.writeAsBytes(const [4, 5, 6], flush: true);
      await staleBuildDirectory.create();
      await File(
        '${staleBuildDirectory.path}/partial.zip',
      ).writeAsBytes(const [7, 8, 9], flush: true);

      final image = File('${root.path}/original.jpg');
      const imageBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
      await image.writeAsBytes(imageBytes, flush: true);
      final imageSha256 = sha256.convert(imageBytes).toString();

      final zip =
          await DevelopmentBackupService(
            directoryProvider: () async => root,
          ).createArchive(
            captures: [
              _captureWithAttachment(
                id: 'new-backup',
                image: image,
                imageBytes: imageBytes,
                imageSha256: imageSha256,
              ),
            ],
            tagSenses: const {},
            createdAt: DateTime(2026, 9, 6, 10, 11, 12),
          );

      expect(zip.uri.pathSegments.last, 'trun-on-backup-20260906-101112.zip');
      expect(await zip.exists(), isTrue);
      expect(await oldBackup.exists(), isFalse);
      expect(await unrelatedZip.exists(), isTrue);
      expect(await staleBuildDirectory.exists(), isFalse);
      expect(
        root.listSync().whereType<Directory>().where(
          (directory) => directory.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('.trun-on-backup-build-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'backup can be inspected and restores verified images atomically',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'luffi-backup-restore-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final sourceDirectory = Directory('${root.path}/source')..createSync();
      final restoreDirectory = Directory('${root.path}/restored');
      final image = File('${sourceDirectory.path}/original.png');
      const imageBytes = <int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        1,
        2,
        3,
        4,
      ];
      await image.writeAsBytes(imageBytes, flush: true);
      final digest = sha256.convert(imageBytes).toString();
      final capture = _captureWithAttachment(
        id: 'restore-round-trip',
        image: image,
        imageBytes: imageBytes,
        imageSha256: digest,
        mimeType: 'image/png',
      );
      final service = DevelopmentBackupService(
        restoreDirectoryProvider: () async => restoreDirectory,
      );
      final zip = await service.createArchive(
        captures: [capture],
        tagSenses: const {
          '여행장소': ['나들이'],
        },
        outputDirectory: root,
      );

      final plan = await service.inspectArchive(zip);
      addTearDown(plan.dispose);

      expect(plan.captureCount, 1);
      expect(plan.imageCount, 1);
      expect(plan.imageBytes, imageBytes.length);
      expect(plan.tagSenses, {
        '여행장소': ['나들이'],
      });
      final restoredPath = '${restoreDirectory.path}/$digest.png';
      expect(plan.captures.single.attachments.single.filePath, restoredPath);
      expect(await File(restoredPath).exists(), isFalse);

      final installed = await plan.installAttachments();
      expect(await File(restoredPath).readAsBytes(), imageBytes);
      await installed.rollback();
      expect(await File(restoredPath).exists(), isFalse);
    },
  );

  test('restore rejects an attachment whose checksum was changed', () async {
    final root = await Directory.systemTemp.createTemp(
      'luffi-corrupt-restore-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const expectedBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
    const corruptBytes = <int>[0xff, 0xd8, 0xff, 0x00];
    final digest = sha256.convert(expectedBytes).toString();
    final image = File('${root.path}/metadata.jpg');
    await image.writeAsBytes(expectedBytes);
    final capture = _captureWithAttachment(
      id: 'corrupt-restore',
      image: image,
      imageBytes: expectedBytes,
      imageSha256: digest,
    );
    final manifestCapture = PersistedCapture.fromJson({
      ...capture.toJson(),
      'attachments': [
        {
          ...capture.attachments.single.toJson(),
          'filePath': 'attachments/$digest.jpg',
        },
      ],
    });
    final zip = await _writeArchive(
      File('${root.path}/corrupt.zip'),
      manifest: AppSnapshotCodec.encode([manifestCapture]),
      entries: {'attachments/$digest.jpg': corruptBytes},
    );
    final service = DevelopmentBackupService(
      restoreDirectoryProvider: () async => Directory('${root.path}/restore'),
    );

    await expectLater(
      service.inspectArchive(zip),
      throwsA(
        isA<DevelopmentBackupRestoreException>().having(
          (error) => error.code,
          'code',
          'attachment_checksum_failed',
        ),
      ),
    );
  });

  test('restore rejects unexpected or traversing ZIP entries', () async {
    final root = await Directory.systemTemp.createTemp(
      'luffi-unsafe-restore-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final zip = await _writeArchive(
      File('${root.path}/unsafe.zip'),
      manifest: AppSnapshotCodec.encode(const []),
      entries: const {
        '../outside.txt': [1, 2, 3],
      },
    );
    final service = DevelopmentBackupService(
      restoreDirectoryProvider: () async => Directory('${root.path}/restore'),
    );

    await expectLater(
      service.inspectArchive(zip),
      throwsA(
        isA<DevelopmentBackupRestoreException>().having(
          (error) => error.code,
          'code',
          'invalid_backup',
        ),
      ),
    );
    expect(await File('${root.parent.path}/outside.txt').exists(), isFalse);
  });

  test('restore never overwrites a different existing image', () async {
    final root = await Directory.systemTemp.createTemp(
      'luffi-conflicting-restore-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final source = File('${root.path}/source.jpg');
    const sourceBytes = <int>[0xff, 0xd8, 0xff, 0xd9];
    await source.writeAsBytes(sourceBytes);
    final digest = sha256.convert(sourceBytes).toString();
    final restoreDirectory = Directory('${root.path}/restore');
    final service = DevelopmentBackupService(
      restoreDirectoryProvider: () async => restoreDirectory,
    );
    final zip = await service.createArchive(
      captures: [
        _captureWithAttachment(
          id: 'conflicting-image',
          image: source,
          imageBytes: sourceBytes,
          imageSha256: digest,
        ),
      ],
      tagSenses: const {},
      outputDirectory: root,
    );
    final plan = await service.inspectArchive(zip);
    addTearDown(plan.dispose);
    await restoreDirectory.create();
    final existing = File('${restoreDirectory.path}/$digest.jpg');
    const existingBytes = <int>[0xff, 0xd8, 0xff, 0x00];
    await existing.writeAsBytes(existingBytes);

    await expectLater(
      plan.installAttachments(),
      throwsA(
        isA<DevelopmentBackupRestoreException>().having(
          (error) => error.code,
          'code',
          'attachment_conflict',
        ),
      ),
    );
    expect(await existing.readAsBytes(), existingBytes);
  });
}

Future<File> _writeArchive(
  File output, {
  required String manifest,
  required Map<String, List<int>> entries,
}) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string('manifest.json', manifest));
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
  return output;
}

PersistedCapture _captureWithAttachment({
  required String id,
  required File image,
  required List<int> imageBytes,
  required String imageSha256,
  String mimeType = 'image/jpeg',
}) => PersistedCapture(
  transportEventId: id,
  receivedAt: DateTime.utc(2026, 9, 6),
  origin: CaptureOrigin.manual,
  sharedText: '',
  discoveredUrl: null,
  sourcePackage: 'gallery',
  mimeType: mimeType,
  wasTruncated: false,
  originalLength: 0,
  status: CaptureStatus.needsReview,
  reviewId: null,
  reviewResolution: null,
  reviewedAt: null,
  confirmedIdentity: null,
  groupId: null,
  attachments: [
    IncomingAttachment(
      id: 'attachment-$id',
      filePath: image.path,
      mimeType: mimeType,
      byteSize: imageBytes.length,
      sha256: imageSha256,
      width: 1,
      height: 1,
    ),
  ],
);
