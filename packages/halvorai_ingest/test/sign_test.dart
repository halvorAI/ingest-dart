import 'dart:convert';
import 'dart:io';

import 'package:halvorai_ingest/src/canonical.dart';
import 'package:halvorai_ingest/src/sign.dart';
import 'package:test/test.dart';

/// The cross-language signing vector from ape-schema/conformance.
final _vector = jsonDecode(File('test/fixtures/conformance/sign-vector.json').readAsStringSync())
    as Map<String, Object?>;
final _event = _vector['event'] as Map<String, Object?>;
final _privateJwk = (_vector['private_jwk'] as Map).cast<String, Object?>();
final _publicJwk = (_vector['public_jwk'] as Map).cast<String, Object?>();

Map<String, Object?> _copy(Map<String, Object?> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, Object?>;

void main() {
  test('canonical form matches the vector', () {
    expect(canonicalize(_event), _vector['canonical_jcs']);
  });

  test('verifies the committed TypeScript signature', () async {
    expect(await verifyEvent(_event, _vector['sig'] as String, _publicJwk), isTrue);
  });

  test('re-signing produces the identical signature', () async {
    final key = SourceKey.fromJwk({..._privateJwk, 'kid': _privateJwk['kid'] ?? 'src_vector'});
    expect(await signEvent(_event, key), _vector['sig']);
  });

  test('a changed event fails verification', () async {
    final tampered = _copy(_event)..['id'] = '${_event['id']}x';
    expect(await verifyEvent(tampered, _vector['sig'] as String, _publicJwk), isFalse);
  });

  test('verifyEvent never throws on garbage', () async {
    expect(await verifyEvent(_event, 'not-a-jws', _publicJwk), isFalse);
    expect(await verifyEvent(_event, 'a.b.c', _publicJwk), isFalse);
    expect(await verifyEvent({}, _vector['sig'] as String, _publicJwk), isFalse);
    expect(await verifyEvent(_event, _vector['sig'] as String, {}), isFalse);
  });

  test('a generated key round-trips through its JWK and verifies with the public half', () async {
    final key = await SourceKey.generate(kid: 'src_test');
    final restored = SourceKey.fromJwk(key.toJwk());
    final event = _copy(_event)..['source'] = {'id': 'src_test', 'sdk': 'x', 'adapter': 'custom'};
    final sig = await signEvent(event, restored);
    expect(key.publicJwk.containsKey('d'), isFalse);
    expect(await verifyEvent(event, sig, key.publicJwk), isTrue);
  });

  test('the header kid must be event.source.id', () async {
    final key = await SourceKey.generate(kid: 'src_a');
    final event = _copy(_event)..['source'] = {'id': 'src_a', 'sdk': 'x', 'adapter': 'custom'};
    final sig = await signEvent(event, key);
    final moved = _copy(event)..['source'] = {'id': 'src_b', 'sdk': 'x', 'adapter': 'custom'};
    expect(await verifyEvent(moved, sig, key.publicJwk), isFalse);
  });

  test('rejects keys that are not private Ed25519 JWKs', () {
    expect(() => SourceKey.fromJwk(_publicJwk), throwsFormatException);
    expect(() => SourceKey.fromJwk({..._privateJwk, 'crv': 'P-256'}), throwsFormatException);
    expect(() => SourceKey.fromJwk({..._privateJwk}..remove('kid')), throwsFormatException);
  });

  test('a JWK whose x does not belong to d fails when signing', () async {
    final other = await SourceKey.generate();
    final mixed = SourceKey.fromJwk({..._privateJwk, 'kid': 'src_x', 'x': other.publicJwk['x']});
    expect(signEvent(_event, mixed), throwsFormatException);
  });
}
