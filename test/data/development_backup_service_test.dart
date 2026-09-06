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
}

PersistedCapture _captureWithAttachment({
  required String id,
  required File image,
  required List<int> imageBytes,
  required String imageSha256,
}) => PersistedCapture(
  transportEventId: id,
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
      id: 'attachment-$id',
      filePath: image.path,
      mimeType: 'image/jpeg',
      byteSize: imageBytes.length,
      sha256: imageSha256,
      width: 1,
      height: 1,
    ),
  ],
);
