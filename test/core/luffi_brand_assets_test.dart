import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android development label cannot override luffi with the old brand',
    () {
      final main = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final debug = File(
        'android/app/src/debug/AndroidManifest.xml',
      ).readAsStringSync();
      expect(main, contains('android:label="luffi"'));
      expect(debug, contains('android:label="luffi DEV"'));
      expect(debug, isNot(contains('Trun On')));
      // Keep the dev package separate without losing existing installed data.
      final config = File('android/app/build.gradle.kts').readAsStringSync();
      expect(config, contains('applicationId = "com.orialthq.ori_beauty"'));
      expect(config, contains('applicationIdSuffix = ".dev"'));
    },
  );
}
