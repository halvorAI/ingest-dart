import 'dart:io';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)![1];
    expect(packageVersion, version);
    expect(sdkName, 'halvorai_ingest@$version');
    expect(sdkName.length, lessThanOrEqualTo(64), reason: 'source.sdk is at most 64 characters');
  });
}
