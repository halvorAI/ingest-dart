import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:halvorai_ingest/src/canonical.dart';
import 'package:test/test.dart';

/// Generated from the TypeScript SDK by tool/gen_jcs_vectors.mjs.
final _vectors =
    jsonDecode(File('test/fixtures/jcs-vectors.json').readAsStringSync()) as Map<String, Object?>;

double _fromBits(String hex) {
  final data = ByteData(8)
    ..setUint32(0, int.parse(hex.substring(0, 8), radix: 16))
    ..setUint32(4, int.parse(hex.substring(8), radix: 16));
  return data.getFloat64(0);
}

void main() {
  group('numbers match ECMAScript serialisation', () {
    for (final v in (_vectors['numbers'] as List).cast<Map<String, Object?>>()) {
      test(v['bits'], () {
        expect(canonicalize(_fromBits(v['bits'] as String)), v['expected']);
      });
    }
  });

  group('objects match the TypeScript canonicalize', () {
    final objects = (_vectors['objects'] as List).cast<Map<String, Object?>>();
    for (var i = 0; i < objects.length; i++) {
      test('vector $i', () {
        expect(canonicalize(jsonDecode(objects[i]['json'] as String)), objects[i]['expected']);
      });
    }
  });

  test('rejects values JSON cannot hold', () {
    expect(() => canonicalize(double.nan), throwsA(isA<CanonicalError>()));
    expect(() => canonicalize(double.infinity), throwsA(isA<CanonicalError>()));
    expect(() => canonicalize({1: 'a'}), throwsA(isA<CanonicalError>()));
    expect(() => canonicalize(DateTime(2026)), throwsA(isA<CanonicalError>()));
  });

  test('rejects integers beyond 2^53, which JavaScript cannot represent exactly', () {
    expect(canonicalize(maxSafeInteger), '9007199254740991');
    expect(() => canonicalize(maxSafeInteger + 2), throwsA(isA<CanonicalError>()));
  });
}
